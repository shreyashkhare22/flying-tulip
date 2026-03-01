// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IERC20,
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStrategyWithQueue} from "../interfaces/IStrategy.sol";

/* ──────────────────────────────────────────────────────────────────────────────
   Minimal Lido interfaces
   ───────────────────────────────────────────────────────────────────────────── */
interface IStETH is IERC20 {
    function submit(address _referral) external payable returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IWithdrawalQueueERC721 {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function requestWithdrawals(
        uint256[] calldata _amounts,
        address _owner
    )
        external
        returns (uint256[] memory requestIds);

    function claimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external;

    function getLastCheckpointIndex() external view returns (uint256);
    function findCheckpointHints(
        uint256[] calldata _requestIds,
        uint256 _firstIndex,
        uint256 _lastIndex
    )
        external
        view
        returns (uint256[] memory);

    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    function getClaimableEther(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    )
        external
        view
        returns (uint256[] memory claimableEthValues);

    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
}

/* ──────────────────────────────────────────────────────────────────────────────
   Canonical WETH9 interface
   ───────────────────────────────────────────────────────────────────────────── */
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// Note: no additional wrapper interfaces required here

/*
    Strategy: WETH <-> (unwrap) ETH -> stETH (Lido), with optional Lido Withdrawal Queue exit.
    - Shares are 1:1 to deposited principal (WETH amount).
    - Yield (Lido rebase surplus of stETH) is claimable by treasury in stETH.
    - Withdraw options:
        * atomic WETH (wrap ETH buffer to WETH and transfer)
        * queue via Lido to receive ETH later (unstETH NFTs go to recipient)
        * instant stETH transfer
*/
contract StEthStrategy is IStrategyWithQueue, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStETH;
    using SafeERC20 for IWETH;

    // ── immutables & config ────────────────────────────────────────────────────
    IWETH public immutable WETH;
    IStETH public immutable stETH;
    IWithdrawalQueueERC721 public immutable withdrawalQueue;

    // wrapper allowed to call deposit & yield-claim (mirrors your model)
    address public ftYieldWrapper;

    // optional referral for Lido `submit`
    address public lidoReferral;

    // ── events (parity with your AaveStrategy ergonomics) ──────────────────────
    event UpdateReferral(address newReferral);

    modifier onlyftYieldWrapper() {
        if (msg.sender != ftYieldWrapper) revert StrategyNotYieldWrapper();
        _;
    }

    constructor(
        address _ftYieldWrapper,
        address _weth,
        address _stETH,
        address _withdrawalQueue,
        address _lidoReferral // can be zero
    )
        ERC20("Flying Tulip Lido WETH Strategy", "ftLidoWETH")
    {
        if (
            _ftYieldWrapper == address(0) || _weth == address(0) || _stETH == address(0)
                || _withdrawalQueue == address(0)
        ) revert StrategyZeroAddress();

        ftYieldWrapper = _ftYieldWrapper;
        WETH = IWETH(_weth);
        stETH = IStETH(_stETH);
        withdrawalQueue = IWithdrawalQueueERC721(_withdrawalQueue);
        lidoReferral = _lidoReferral;

        emit Transfer(address(0), address(this), 0);
    }

    // ── admin (wrapper) ────────────────────────────────────────────────────────

    function setftYieldWrapper(address _ftYieldWrapper) external onlyftYieldWrapper {
        if (_ftYieldWrapper == address(0)) revert StrategyZeroAddress();
        ftYieldWrapper = _ftYieldWrapper;
        emit UpdateftYieldWrapper(_ftYieldWrapper);
    }

    function setLidoReferral(address _ref) external onlyftYieldWrapper {
        lidoReferral = _ref;
        emit UpdateReferral(_ref);
    }

    // ── accounting views (parity with AaveStrategy naming) ─────────────────────

    /// @notice 1:1 mapping of capital provided
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice capital + current rebase surplus (stETH held by this contract)
    function valueOfCapital() public view returns (uint256) {
        uint256 liquid = WETH.balanceOf(address(this)) + address(this).balance;
        return liquid + stETH.balanceOf(address(this));
    }

    function yield() public view returns (uint256) {
        uint256 v = valueOfCapital();
        uint256 t = totalSupply();
        return (v > t) ? (v - t) : 0;
    }

    /// @notice Immediate *WETH* that can be paid out atomically **right now**.
    /// Equals WETH balance + ETH buffer (wrappable) but capped by totalSupply (principal).
    function availableToWithdraw() public view returns (uint256) {
        uint256 liquid = WETH.balanceOf(address(this)) + address(this).balance; // ETH can be wrapped to WETH
        uint256 _capital = totalSupply();
        return liquid < _capital ? liquid : _capital;
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        return availableToWithdraw() >= amount;
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 liq = availableToWithdraw();
        return liq < amount ? liq : amount;
    }

    // ── core flows ─────────────────────────────────────────────────────────────

    /// @notice Deposit WETH -> unwrap to ETH -> stake to stETH; mint 1:1 principal shares to caller (wrapper).
    function deposit(uint256 amount) external nonReentrant onlyftYieldWrapper {
        if (amount == 0) revert StrategyAmountZero();

        // Pull WETH from wrapper
        WETH.safeTransferFrom(msg.sender, address(this), amount);

        // Unwrap to ETH
        WETH.withdraw(amount); // sends ETH to this contract

        // Stake to Lido; stETH minted to this contract
        stETH.submit{value: amount}(lidoReferral);

        // Mint ft-shares 1:1 to the caller (wrapper)
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Standard IStrategy-style withdraw: pay out WETH atomically (wrapping ETH buffer if needed).
    /// Reverts if there isn't enough immediate liquidity (use queue or stETH path instead).
    function withdraw(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        if (amount == 0) revert StrategyAmountZero();

        // Check immediate liquidity (WETH + ETH buffer)
        uint256 wethBal = WETH.balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        if (wethBal + ethBal < amount) revert StrategyInsufficientLiquidity();

        // Burn principal shares 1:1
        _burn(msg.sender, amount);

        // Top-up WETH by wrapping ETH if necessary
        if (wethBal < amount) {
            uint256 needed = amount - wethBal;
            // we know ethBal >= needed from the earlier check
            WETH.deposit{value: needed}();
        }

        // Transfer WETH to the user
        WETH.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);

        return amount;
    }

    /// @notice Withdraw principal as stETH immediately (no queue), 1:1 burn->transfer.
    function withdrawUnderlying(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256)
    {
        if (amount == 0) revert StrategyAmountZero();
        _burn(msg.sender, amount);
        stETH.safeTransfer(msg.sender, amount);
        emit WithdrawUnderlying(msg.sender, amount);
        return amount;
    }

    mapping(uint256 id => uint256[] requestIds) public queue; // id => data
    uint256 public head;
    uint256 public tail;

    /// @notice Withdraw to ETH via Lido queue if no atomic liquidity; unstETH NFTs minted to `recipient`.
    function withdrawQueued(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 id)
    {
        if (amount == 0) revert StrategyAmountZero();
        _burn(msg.sender, amount);

        stETH.safeIncreaseAllowance(address(withdrawalQueue), amount);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        id = tail;
        queue[id] = withdrawalQueue.requestWithdrawals(amounts, address(this));
        tail++;

        // Reset allowance to zero
        stETH.forceApprove(address(withdrawalQueue), 0);

        emit WithdrawQueued(msg.sender, amount, id);
    }

    function claimQueued(uint256 id)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        uint256[] memory requestIds = queue[id];
        IWithdrawalQueueERC721.WithdrawalRequestStatus[] memory statuses =
            withdrawalQueue.getWithdrawalStatus(requestIds);
        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].isFinalized == false) {
                revert StrategyInsufficientLiquidity();
            }
        }
        uint256 last = withdrawalQueue.getLastCheckpointIndex();
        uint256[] memory hints = withdrawalQueue.findCheckpointHints(requestIds, 1, last);
        uint256[] memory reserved = withdrawalQueue.getClaimableEther(requestIds, hints);
        for (uint256 i = 0; i < reserved.length; i++) {
            received += reserved[i];
        }
        head = id;
        withdrawalQueue.claimWithdrawals(requestIds, hints);
        WETH.deposit{value: received}();
        WETH.safeTransfer(msg.sender, received);
        emit WithdrawClaimed(msg.sender, received, id);
    }

    /// @notice Treasury harvests rebase surplus (in stETH). Principal is untouched.
    function claimYield(address treasury)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 claimed)
    {
        if (treasury == address(0)) revert StrategyZeroAddress();
        claimed = yield();
        if (claimed != 0) {
            stETH.safeTransfer(treasury, claimed);
            emit YieldClaimed(msg.sender, treasury, address(stETH), claimed);
        }
        if (valueOfCapital() < totalSupply()) {
            revert StrategyCapitalMustNotChange();
        }
    }

    // receive ETH from WETH.unwind and/or Lido claims / buffer funding
    receive() external payable {}

    // decimals match ETH/stETH
    function decimals() public pure override(IERC20Metadata, ERC20) returns (uint8) {
        return 18;
    }

    function token() external view returns (address) {
        return address(WETH);
    }

    function positionToken() external view returns (address) {
        return address(stETH);
    }

    // ── Guarded execution hook (points/partners), with capital invariant ───────
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        nonReentrant
        onlyftYieldWrapper
        returns (bool success, bytes memory result)
    {
        // Forbid calling core assets to avoid accidental/griefing drains
        if (to == address(stETH) || to == address(withdrawalQueue) || to == address(WETH)) {
            revert StrategyCantInteractWithCoreAssets();
        }

        (success, result) = to.call{value: value}(data);

        // Capital invariant: the stETH balance (valueOfCapital) must not drop
        // below totalSupply (principal). This prevents principal loss.
        if (valueOfCapital() < totalSupply()) {
            revert StrategyCapitalMustNotChange();
        }
    }
}
