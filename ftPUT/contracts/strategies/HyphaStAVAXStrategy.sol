// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

// OZ
import {
    IERC20,
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStrategyWithQueue} from "../interfaces/IStrategy.sol";

// =============================
// Minimal Hypha / stAVAX + WAVAX interfaces
// =============================

interface IWAVAX is IERC20Metadata {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

// stAVAX token (TokenggAVAX). Try ERC-4626-style conversions first, then common AVAX LST names.
interface IStAVAX is IERC20Metadata {
    // ERC-4626 style
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    // Legacy-style (used by some AVAX LSTs)
    function getPooledAvaxByShares(uint256 shares) external view returns (uint256 avax);
    function getSharesByPooledAvax(uint256 avax) external view returns (uint256 shares);
}

// Hypha Staking: accepts native AVAX, mints stAVAX to receiver
interface IHyphaStaking {
    function depositAVAX(address receiver) external payable returns (uint256 stAvaxMinted);
}

// Hypha WithdrawQueue: enqueues stAVAX for AVAX redemption, later claimable
interface IHyphaWithdrawQueue {
    function requestWithdraw(
        uint256 stAvaxShares,
        address owner
    )
        external
        returns (uint256 requestId, uint256 avaxLocked);

    function claim(uint256 requestId, address payable recipient) external returns (uint256 avaxOut);

    function cancel(uint256 requestId) external returns (uint256 stAvaxReturned);
}

// Optional wrapper interface (same pattern as your example)
interface IftYield {
    function treasury() external view returns (address);
}

/*
    Hypha stAVAX deposit strategy using wAVAX as underlying

    - Users/wrapper deposit wAVAX -> strategy unwraps to AVAX -> stakes into Hypha (stAVAX)
    - Withdraw:
        * Atomic from AVAX buffer (if enough)
        * Else enqueue via WithdrawQueue and pay AVAX when claimable
        * Or user can opt to withdraw stAVAX directly (value-equal, not 1:1 tokens)
    - Principal 1:1 (shares == AVAX units); yield skimmed to treasury in stAVAX
*/
contract HyphaStAVAXStrategy is IStrategyWithQueue, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    // ----------- Immutable protocol addresses (Avalanche C-Chain mainnet) -----------
    IWAVAX public immutable wAVAX; // underlying ERC20
    IStAVAX public immutable stAVAX; // TokenggAVAX proxy
    IHyphaStaking public immutable staking; // Hypha Staking
    IHyphaWithdrawQueue public immutable withdrawQ; // Hypha WithdrawQueue

    // Wrapper pattern as in AaveStrategy
    address public ftYieldWrapper;

    modifier onlyftYieldWrapper() {
        if (msg.sender != ftYieldWrapper) revert StrategyNotYieldWrapper();
        _;
    }

    constructor(
        address _ftYieldWrapper,
        address _wAVAX,
        address _staking,
        address _stAVAX,
        address _withdrawQ
    )
        ERC20("Flying Tulip Hypha stAVAX", "ftHyphaAVAX")
    {
        if (
            _ftYieldWrapper == address(0) || _wAVAX == address(0) || _staking == address(0)
                || _stAVAX == address(0) || _withdrawQ == address(0)
        ) revert StrategyZeroAddress();

        ftYieldWrapper = _ftYieldWrapper;
        wAVAX = IWAVAX(_wAVAX);
        staking = IHyphaStaking(_staking);
        stAVAX = IStAVAX(_stAVAX);
        withdrawQ = IHyphaWithdrawQueue(_withdrawQ);

        emit Transfer(address(0x0), address(this), 0);
    }

    // ----------------- Admin (wrapper-controlled, mirroring your pattern) -----------------

    function setftYieldWrapper(address _ftYieldWrapper) external onlyftYieldWrapper {
        if (_ftYieldWrapper == address(0)) revert StrategyZeroAddress();
        ftYieldWrapper = _ftYieldWrapper;
        emit UpdateftYieldWrapper(_ftYieldWrapper);
    }

    // ----------------- Accounting views -----------------

    /// @notice Principal only (1:1 shares:AVAX)
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice Underlying token for in/out at the wrapper boundary (wAVAX)
    function token() public view returns (address) {
        return address(wAVAX);
    }

    /// @notice Current total asset value (principal + yield), counting:
    /// - AVAX float held by this
    /// - stAVAX held by this (converted at current rate)
    /// - AVAX amounts already locked in Hypha WithdrawQueue (fixed at request time)
    function valueOfCapital() public view returns (uint256) {
        uint256 avaxFloat = address(this).balance;
        uint256 stBal = stAVAX.balanceOf(address(this));
        uint256 avaxFromSt = _sharesToAssets(stBal);
        return avaxFloat + avaxFromSt;
    }

    function yield() public view returns (uint256) {
        uint256 v = valueOfCapital();
        uint256 t = totalSupply();
        return (v > t) ? (v - t) : 0;
    }

    /// @notice How much AVAX is immediately withdrawable atomically (buffer only)
    function availableToWithdraw() public view returns (uint256) {
        uint256 stBal = stAVAX.balanceOf(address(this));
        return stBal + address(this).balance;
    }

    function maxAbleToWithdraw(uint256 amount) public view returns (uint256) {
        uint256 bal = availableToWithdraw();
        return bal > amount ? amount : bal;
    }

    // ----------------- Core: deposit & withdraw -----------------

    /// @notice Deposit wAVAX; unwrap to AVAX; stake into Hypha; keep AVAX buffer.
    ///         Mints 1:1 shares to the wrapper (shares == AVAX principal units).
    function deposit(uint256 amount) external nonReentrant onlyftYieldWrapper {
        if (amount == 0) revert StrategyAmountZero();

        // Pull wAVAX from caller
        IERC20(address(wAVAX)).safeTransferFrom(msg.sender, address(this), amount);

        // Unwrap full amount to have AVAX for both buffer and staking (1 SSTORE cheaper than 2 withdraws)
        IWAVAX(address(wAVAX)).withdraw(amount);
        staking.depositAVAX{value: amount}(address(this));

        // Mint principal shares 1:1
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw AVAX 1:1.
    /// - If buffer has enough AVAX, send instantly.
    /// - Else enqueue via Hypha WithdrawQueue; later anyone can claim and pay.
    /// Returns the AVAX immediately sent (0 if fully queued).
    function withdraw(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        if (amount == 0) revert StrategyAmountZero();
        uint256 wavaxBal = wAVAX.balanceOf(address(this));
        uint256 avaxBal = address(this).balance;
        if (wavaxBal + avaxBal < amount) revert StrategyInsufficientLiquidity();

        _burn(msg.sender, amount);

        if (wavaxBal < amount) {
            uint256 needed = amount - wavaxBal;
            // we know avaxBal >= needed from the earlier check
            wAVAX.deposit{value: needed}();
        }

        // Transfer wAVAX to the user
        IERC20(address(wAVAX)).safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
        return amount;
    }

    /// @notice Optional: withdraw as stAVAX immediately (value-equal to AVAX principal).
    function withdrawUnderlying(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 sharesOut)
    {
        _burn(msg.sender, amount);
        sharesOut = _assetsToShares(amount);
        IERC20(address(stAVAX)).safeTransfer(msg.sender, sharesOut);
    }

    /// @notice Skim yield to treasury in stAVAX: send the surplus stAVAX not needed to cover principal.
    function claimYield(address treasury)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 claimed)
    {
        claimed = yield();
        if (claimed != 0) {
            uint256 sharesRequired = _assetsToShares(claimed);
            IERC20(address(stAVAX)).safeTransfer(treasury, sharesRequired);
            emit YieldClaimed(msg.sender, treasury, address(stAVAX), sharesRequired);
        }
        if (valueOfCapital() < totalSupply()) {
            revert StrategyCapitalMustNotChange();
        }
    }

    // --- Queue-based withdrawals ---
    mapping(uint256 id => uint256 regId) public queue; // id => data
    uint256 public head;
    uint256 public tail;

    function withdrawQueued(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 id)
    {
        if (amount == 0) revert StrategyAmountZero();
        _burn(msg.sender, amount);

        uint256 sharesNeeded = _assetsToShares(amount);
        IERC20(address(stAVAX)).safeIncreaseAllowance(address(withdrawQ), sharesNeeded);

        id = tail;
        (uint256 regId,) = withdrawQ.requestWithdraw(sharesNeeded, address(this));
        queue[id] = regId;
        tail++;

        emit WithdrawQueued(msg.sender, amount, id);
    }

    function claimQueued(uint256 id) external nonReentrant returns (uint256 received) {
        uint256 regId = queue[id];
        received = withdrawQ.claim(regId, payable(address(this)));
        wAVAX.deposit{value: received}();
        head = id;
        IERC20(address(wAVAX)).safeTransfer(msg.sender, received);
        emit WithdrawClaimed(msg.sender, received, id);
    }

    // ----------------- Helpers -----------------

    // adapter: prefer ERC-4626 convertToAssets/convertToShares; fallback to AVAX LST names
    function _sharesToAssets(uint256 shares) internal view returns (uint256) {
        // try ERC-4626
        try stAVAX.convertToAssets(shares) returns (uint256 a) {
            return a;
        } catch {}
        // fallback common LST
        try stAVAX.getPooledAvaxByShares(shares) returns (uint256 a2) {
            return a2;
        } catch {}
        revert("Rate: shares->assets not supported");
    }

    function _assetsToShares(uint256 assets) internal view returns (uint256) {
        // try ERC-4626
        try stAVAX.convertToShares(assets) returns (uint256 s) {
            return s;
        } catch {}
        // fallback common LST
        try stAVAX.getSharesByPooledAvax(assets) returns (uint256 s2) {
            return s2;
        } catch {}
        revert("Rate: assets->shares not supported");
    }

    receive() external payable {} // receives AVAX (queue claims and unwraps)

    // Ensure ERC20 decimals equal AVAX decimals (18). stAVAX & wAVAX are 18.
    function decimals() public pure override(IERC20Metadata, ERC20) returns (uint8) {
        return 18;
    }

    // Optional "godmode" passthrough (points/airdrop farming) that cannot touch staking or withdrawQ
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        onlyftYieldWrapper
        returns (bool success, bytes memory result)
    {
        if (to == address(stAVAX) || to == address(staking) || to == address(withdrawQ)) {
            revert StrategyCantInteractWithCoreAssets();
        }
        (success, result) = to.call{value: value}(data);
        if (valueOfCapital() < totalSupply()) revert StrategyCapitalMustNotChange();
    }

    /// @dev Address of the strategy's position token (stAVAX)
    function positionToken() external view returns (address) {
        return address(stAVAX);
    }
}
