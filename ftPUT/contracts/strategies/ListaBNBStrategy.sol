// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {
    IERC20,
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStrategyWithQueue} from "../interfaces/IStrategy.sol";

interface IListaStakeManager {
    function deposit() external payable; // stake native BNB -> mint slisBNB to caller
    function requestWithdraw(uint256 amountInSlisBnb) external; // queue withdraw slis -> later claim BNB
}

// wBNB interface (ERC20 + wrap/unwrap)
interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// Abstract rate provider so we do not lock to a particular ABI.
// Implementations must return 1e18-scaled rates:
// - bnbPerSlis(): how many wei of BNB one slisBNB unit is worth
// - slisPerBnb(): how many slisBNB per 1 wei of BNB
interface IRateProvider {
    function bnbPerSlis() external view returns (uint256); // 1 slis -> ? wei BNB (1e18 scale)
    function slisPerBnb() external view returns (uint256); // 1 wei BNB -> ? slis (1e18 scale)
}

/**
 * @title ListaBNBStrategy
 * @notice Strategy that stakes BNB into ListaDAO (via StakeManager) to receive slisBNB.
 *         Users get 1:1 principal shares (1 share = 1 BNB of principal); yield is the slis/BNB rate drift
 *         and is claimable to a treasury in slisBNB.
 *
 * Withdrawals:
 *   - Atomic BNB if buffer is available (after covering queued obligations)
 *   - Else queue via StakeManager.requestWithdraw
 *   - Users may choose to redeem principal as slisBNB instantly (atomic)
 *
 * Roles:
 *   - ftYieldWrapper: only address allowed to call deposit() and yield/ops functions (mirrors your pattern)
 *   - Anyone may call processQueue/claimFromStakeManager to help progress the queue
 */
contract ListaBNBStrategy is IStrategyWithQueue, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    // ===== Immutable protocol wiring =====
    IListaStakeManager public immutable stakeManager; // e.g., 0x1adB...7fE6 (BSC)
    IERC20Metadata public immutable slisBNB; // e.g., 0xB0b8...4A1B (BSC)
    IWBNB public immutable wbnb; // canonical wBNB

    // ===== Configurable aux contracts =====
    IRateProvider public rateProvider; // e.g., SlisBNBOracle adapter

    // ===== Integration / accounting =====
    address public ftYieldWrapper; // gate for privileged calls (mirrors your AaveStrategy shape)

    // We track slisBNB locked due to pending withdrawal requests
    uint256 public slisLockedForQueue;

    // We also track BNB obligations already queued (to prevent line-jumping on atomic withdrawals)
    uint256 public bnbQueuedOwed;

    error NoRateProvider();
    error BNBTransferFailed();
    error StakeManagerClaimFailed();

    // ===== Withdraw queue (FIFO) =====
    struct Withdrawal {
        address user;
        uint256 bnbOwed; // principal owed in wei
        uint256 slisLocked; // slis amount used for the request
        uint64 createdAt;
        bool settled; // BNB delivered to user
    }

    uint256 public nextQueueId;
    uint256 public headQueueId; // first unsettled id
    mapping(uint256 => Withdrawal) public queue;

    // ===== Events =====
    event UpdateRateProvider(address newProvider);

    modifier onlyftYieldWrapper() {
        if (msg.sender != ftYieldWrapper) revert StrategyNotYieldWrapper();
        _;
    }

    constructor(
        address _ftYieldWrapper,
        address _stakeManager,
        address _slisBNB,
        address _wbnb,
        address _rateProvider // can be address(0) initially; set later
    )
        ERC20("Strategy Lista BNB", "ftListaBNB")
    {
        if (
            _ftYieldWrapper == address(0) || _stakeManager == address(0) || _slisBNB == address(0)
                || _wbnb == address(0)
        ) {
            revert StrategyZeroAddress();
        }
        ftYieldWrapper = _ftYieldWrapper;
        stakeManager = IListaStakeManager(_stakeManager);
        slisBNB = IERC20Metadata(_slisBNB);
        wbnb = IWBNB(_wbnb);
        rateProvider = IRateProvider(_rateProvider);
    }

    // ===== Admin (wrapper) =====
    function setftYieldWrapper(address _wrapper) external onlyftYieldWrapper {
        if (_wrapper == address(0)) revert StrategyZeroAddress();
        emit UpdateftYieldWrapper(_wrapper);
        ftYieldWrapper = _wrapper;
    }

    function setRateProvider(address _provider) external onlyftYieldWrapper {
        emit UpdateRateProvider(_provider);
        rateProvider = IRateProvider(_provider);
    }

    // ===== Strategy views =====

    /// @notice principal (1:1 shares) — identical to your AaveStrategy.capital()
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice total economic value in BNB terms: free BNB buffer + free slisBNB * rate
    function valueOfCapital() public view returns (uint256) {
        uint256 bnbBuf = address(this).balance;
        uint256 slisFree = slisBNB.balanceOf(address(this));
        if (address(rateProvider) == address(0)) {
            // Cannot compute slis leg without rate; return buffer only (conservative).
            return bnbBuf;
        }
        uint256 bnbFromSlis = (slisFree * rateProvider.bnbPerSlis()) / 1e18;
        return bnbBuf + bnbFromSlis;
    }

    function yield() public view returns (uint256) {
        uint256 v = valueOfCapital();
        uint256 t = totalSupply();
        return (v > t) ? (v - t) : 0;
    }

    /// @notice Max BNB we can pay *atomically right now*, honoring queued obligations (FIFO).
    function availableToWithdraw() public view returns (uint256) {
        uint256 buf = address(this).balance;
        uint256 freeBuf = buf > bnbQueuedOwed ? (buf - bnbQueuedOwed) : 0;
        uint256 cap = totalSupply();
        return freeBuf < cap ? freeBuf : cap;
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        return availableToWithdraw() >= amount;
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 liq = availableToWithdraw();
        return liq > amount ? amount : liq;
    }

    // ----- Conversions (rely on rate provider) -----
    function _slisPerBnb(uint256 bnbWei) internal view returns (uint256) {
        if (address(rateProvider) == address(0)) revert NoRateProvider();
        return (bnbWei * rateProvider.slisPerBnb()) / 1e18;
    }

    function _bnbPerSlis(uint256 slisAmount) internal view returns (uint256) {
        if (address(rateProvider) == address(0)) revert NoRateProvider();
        return (slisAmount * rateProvider.bnbPerSlis()) / 1e18;
    }

    // ===== Flows =====

    /**
     * @notice Deposit using wBNB. The contract pulls `amount` wBNB, unwraps to BNB, and stakes via StakeManager.
     * @dev Mints 1:1 principal shares to the wrapper (msg.sender).
     */
    function deposit(uint256 amount) external nonReentrant onlyftYieldWrapper {
        if (amount == 0) revert StrategyAmountZero();

        // Pull wBNB from caller
        IERC20(address(wbnb)).safeTransferFrom(msg.sender, address(this), amount);

        // Unwrap to native BNB
        wbnb.withdraw(amount);

        // Stake BNB -> slisBNB minted to this contract
        stakeManager.deposit{value: amount}();

        // Mint strategy shares (1:1 principal in BNB)
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount);

        // Capital must not go down because of deposit
        if (valueOfCapital() < totalSupply()) revert StrategyCapitalMustNotChange();
    }

    /// @notice User chooses to withdraw principal as slisBNB (atomic). Always 1:1 principal mapping.
    function withdrawUnderlying(uint256 principalBNB)
        external
        nonReentrant
        returns (uint256 slisNeeded)
    {
        _burn(msg.sender, principalBNB);
        slisNeeded = _slisPerBnb(principalBNB);

        uint256 free = slisBNB.balanceOf(address(this)) - slisLockedForQueue;
        if (free < slisNeeded) revert StrategyInsufficientLiquidity();

        slisBNB.safeTransfer(msg.sender, slisNeeded);
        emit WithdrawUnderlying(msg.sender, principalBNB);
    }

    /// @notice Attempt atomic BNB payout; if insufficient free buffer (after covering queued obligations), queue an unstake.
    function withdraw(uint256 amount) external nonReentrant returns (uint256 received) {
        _burn(msg.sender, amount);

        uint256 buf = address(this).balance;
        uint256 freeBuf = buf > bnbQueuedOwed ? (buf - bnbQueuedOwed) : 0;

        if (freeBuf >= amount) {
            // Atomic: pay immediately
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, BNBTransferFailed());
            emit WithdrawQueued(msg.sender, type(uint256).max, amount); // sentinel id for atomic
            return amount;
        }

        // Async path: lock slis and request withdraw at StakeManager
        uint256 slisNeeded = _slisPerBnb(amount);
        uint256 freeSlis = slisBNB.balanceOf(address(this)) - slisLockedForQueue;
        if (freeSlis < slisNeeded) revert StrategyInsufficientLiquidity();

        slisLockedForQueue += slisNeeded;
        bnbQueuedOwed += amount;

        slisBNB.safeIncreaseAllowance(address(stakeManager), slisNeeded);
        stakeManager.requestWithdraw(slisNeeded);

        uint256 id = nextQueueId++;
        queue[id] = Withdrawal({
            user: msg.sender,
            bnbOwed: amount,
            slisLocked: slisNeeded,
            createdAt: uint64(block.timestamp),
            settled: false
        });
        emit WithdrawQueued(msg.sender, amount, id);
    }

    /// @notice Attempt atomic BNB payout; if insufficient free buffer (after covering queued obligations), queue an unstake.
    function withdrawQueued(uint256 amount) external nonReentrant returns (uint256 received) {
        _burn(msg.sender, amount);

        uint256 buf = address(this).balance;
        uint256 freeBuf = buf > bnbQueuedOwed ? (buf - bnbQueuedOwed) : 0;

        if (freeBuf >= amount) {
            // Atomic: pay immediately
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, BNBTransferFailed());
            emit WithdrawQueued(msg.sender, type(uint256).max, amount); // sentinel id for atomic
            return amount;
        }

        // Async path: lock slis and request withdraw at StakeManager
        uint256 slisNeeded = _slisPerBnb(amount);
        uint256 freeSlis = slisBNB.balanceOf(address(this)) - slisLockedForQueue;
        if (freeSlis < slisNeeded) revert StrategyInsufficientLiquidity();

        slisLockedForQueue += slisNeeded;
        bnbQueuedOwed += amount;

        slisBNB.safeIncreaseAllowance(address(stakeManager), slisNeeded);
        stakeManager.requestWithdraw(slisNeeded);

        uint256 id = nextQueueId++;
        queue[id] = Withdrawal({
            user: msg.sender,
            bnbOwed: amount,
            slisLocked: slisNeeded,
            createdAt: uint64(block.timestamp),
            settled: false
        });
        emit WithdrawQueued(msg.sender, amount, id);
    }

    /// @notice Keeper hook: claim matured withdrawals from StakeManager and fulfill FIFO queue.
    /// @dev First call `claimFromStakeManager(...)` as needed to pull unlocked BNB to this contract, then call this.
    function claimQueued(uint256 maxItems) public nonReentrant returns (uint256 count) {
        count;
        while (count < maxItems && headQueueId < nextQueueId) {
            Withdrawal storage w = queue[headQueueId];
            if (w.settled) {
                headQueueId++;
                continue;
            }

            uint256 buf = address(this).balance;
            if (buf < w.bnbOwed) break; // not enough unlocked BNB yet

            // Pay user
            (bool ok,) = w.user.call{value: w.bnbOwed}("");
            require(ok, BNBTransferFailed());

            // Release slis lock and queued obligations
            if (w.slisLocked <= slisLockedForQueue) {
                slisLockedForQueue -= w.slisLocked;
            } else {
                slisLockedForQueue = 0; // defensive
            }
            if (w.bnbOwed <= bnbQueuedOwed) {
                bnbQueuedOwed -= w.bnbOwed;
            } else {
                bnbQueuedOwed = 0; // defensive
            }

            w.settled = true;
            //emit WithdrawClaimed(headQueueId, w.user, w.bnbOwed);

            headQueueId++;
            count++;
        }
    }

    /// @notice Flexible “claim” entrypoint. Send ABI-encoded payload for the StakeManager to release matured BNB to this contract.
    /// @dev Example payload: abi.encodeWithSignature("claimWithdraw(uint256[])", ids)
    function claimFromStakeManager(bytes calldata data)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 bnbBeforeAfterDelta)
    {
        uint256 beforeBal = address(this).balance;

        (
            bool ok, /*bytes memory ret*/
        ) = address(stakeManager).call(data);
        require(ok, StakeManagerClaimFailed());

        uint256 afterBal = address(this).balance;
        bnbBeforeAfterDelta = (afterBal > beforeBal) ? (afterBal - beforeBal) : 0;
        //emit StakeManagerClaim(data, bnbBeforeAfterDelta);
    }

    /// @notice Skim yield to the provided treasury in slisBNB units.
    function claimYield(address treasury)
        external
        onlyftYieldWrapper
        nonReentrant
        returns (uint256 slisToTreasury)
    {
        if (treasury == address(0)) revert StrategyZeroAddress();

        uint256 yBnb = yield();
        if (yBnb == 0) return 0;

        uint256 freeSlis = slisBNB.balanceOf(address(this)) - slisLockedForQueue;
        uint256 neededSlis = _slisPerBnb(yBnb);
        slisToTreasury = neededSlis <= freeSlis ? neededSlis : freeSlis;

        if (slisToTreasury != 0) {
            slisBNB.safeTransfer(treasury, slisToTreasury);
            emit YieldClaimed(msg.sender, treasury, address(slisBNB), slisToTreasury);
        }

        // Invariant: after skimming, valueOfCapital() must remain >= totalSupply()
        if (valueOfCapital() < totalSupply()) revert StrategyCapitalMustNotChange();
    }

    /**
     * @notice Limited "godmode" for claiming points or interacting with allowlisted systems.
     *         Cannot target slisBNB, StakeManager, or wBNB. Capital must never drop below principal.
     */
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        onlyftYieldWrapper
        nonReentrant
        returns (bool success, bytes memory result)
    {
        if (to == address(slisBNB) || to == address(stakeManager) || to == address(wbnb)) {
            revert StrategyCantInteractWithCoreAssets();
        }
        (success, result) = to.call{value: value}(data);
        if (valueOfCapital() < totalSupply()) revert StrategyCapitalMustNotChange();
    }

    // ===== ERC20 / IStrategy helpers =====
    function decimals() public view override(IERC20Metadata, ERC20) returns (uint8) {
        // Match slisBNB decimals to keep 1:1 accounting intuitive
        return slisBNB.decimals();
    }

    /// @dev Address of the strategy's position token (the asset that actually accrues yield)
    function token() external view returns (address) {
        return address(slisBNB);
    }

    /// @dev Address of the strategy's position token (the asset that actually accrues yield)
    function positionToken() external view returns (address) {
        return address(slisBNB);
    }

    // Accept BNB from StakeManager claims (and potential unwraps)
    receive() external payable {}
}
