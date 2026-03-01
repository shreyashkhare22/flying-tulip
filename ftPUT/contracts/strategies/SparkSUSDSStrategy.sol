// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {
    IERC20Metadata,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/*
    Spark sUSDS deposit strategy (principal 1:1, yield to treasury in sUSDS).
    Mirrors your AaveStrategy surface where sensible, adds optional withdrawal queue and sUSDS exits.
*/
contract SparkSUSDSStrategy is IStrategy, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    address public immutable token; // USDS (asset)
    IERC4626 public immutable susds; // sUSDS (ERC-4626 vault)

    // ftYieldWrapper has no access to sUSDS directly; it coordinates deposits/claims
    address public ftYieldWrapper;

    modifier onlyftYieldWrapper() {
        if (msg.sender != ftYieldWrapper) revert StrategyNotYieldWrapper();
        _;
    }

    constructor(
        address _ftYieldWrapper,
        address _usds,
        address _susds
    )
        ERC20("Flying Tulip Spark sUSDS ", "ftSparkUSDS")
    {
        if (_ftYieldWrapper == address(0) || _usds == address(0) || _susds == address(0)) {
            revert StrategyZeroAddress();
        }
        ftYieldWrapper = _ftYieldWrapper;
        token = _usds;
        susds = IERC4626(_susds);

        // Sanity: sUSDS must wrap USDS
        if (susds.asset() != address(token)) revert StrategyZeroAddress();

        emit Transfer(address(0x0), address(this), 0);
    }

    // --- Admin ---
    function setftYieldWrapper(address _ftYieldWrapper) external onlyftYieldWrapper {
        if (_ftYieldWrapper == address(0)) revert StrategyZeroAddress();
        ftYieldWrapper = _ftYieldWrapper;
        emit UpdateftYieldWrapper(_ftYieldWrapper);
    }

    // --- Accounting views (principal vs value) ---
    // simply a 1:1 mapping of capital provided
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    // capital + yield (in USDS units)
    function valueOfCapital() public view returns (uint256) {
        uint256 shares = IERC20(address(susds)).balanceOf(address(this));
        return susds.convertToAssets(shares);
    }

    function yield() public view returns (uint256) {
        uint256 v = valueOfCapital();
        uint256 t = totalSupply();
        return (v > t) ? (v - t) : 0;
    }

    // Helper for withdrawal servicing (USDS units)
    function availableToWithdraw() public view returns (uint256) {
        // Respect vault solvency constraints and queued fairness
        uint256 vaultLimit = susds.maxWithdraw(address(this));
        uint256 _capital = totalSupply();
        if (vaultLimit > _capital) vaultLimit = _capital;
        // Also cannot exceed our actual USDS value
        uint256 ownedAssets = valueOfCapital();
        if (vaultLimit > ownedAssets) vaultLimit = ownedAssets;
        return vaultLimit;
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        return availableToWithdraw() >= amount;
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 a = availableToWithdraw();
        return (a > amount) ? amount : a;
    }

    // --- Core actions ---

    // Deposit USDS => sUSDS; mint 1:1 principal tokens to caller (wrapper)
    function deposit(uint256 amount) external nonReentrant onlyftYieldWrapper {
        if (amount == 0) revert StrategyAmountZero();

        // Pull USDS then deposit to sUSDS
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(susds), amount);
        susds.deposit(amount, address(this));

        // Mint principal 1:1 to the wrapper (or whoever called)
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount);
    }

    // Attempt atomic USDS withdrawal; on success burn user's principal.
    // If insufficient instantaneous liquidity, revert with hint to use queue or sUSDS exit.
    function withdraw(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        // Pre-check to avoid revert (best-effort; still non-binding)
        uint256 avail = availableToWithdraw();
        if (amount == 0 || amount > avail) {
            revert StrategyInsufficientLiquidity();
        }

        // Burn principal from msg.sender to keep principal invariant
        _burn(msg.sender, amount);

        // Withdraw USDS out of sUSDS to user (returns shares burned, not assets)
        susds.withdraw(amount, msg.sender, address(this));
        // If the vault misbehaved we'd revert above; we rely on ERC-4626 semantics

        emit Withdraw(msg.sender, amount);
        return amount;
    }

    // Optional immediate alternative: withdraw principal as sUSDS (no USDS redemption).
    // Hardened: use convertToShares(amount) (round down) to avoid giving more than
    // value‑equivalent shares via previewWithdraw rounding‑up. Enforce minimal shortfall.
    function withdrawUnderlying(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 shares)
    {
        if (amount == 0) revert StrategyAmountZero();

        // Compute shares by rounding down to avoid overpayment
        shares = susds.convertToShares(amount);
        if (shares == 0) revert StrategyInsufficientLiquidity();

        // Accept at most 1 unit of asset shortfall due to rounding
        uint256 assetsBack = susds.convertToAssets(shares);
        if (assetsBack + 1 < amount) revert StrategyInsufficientLiquidity();

        // Safety clamp: ensure we have enough shares
        uint256 ourShares = IERC20(address(susds)).balanceOf(address(this));
        if (shares > ourShares) revert StrategyInsufficientLiquidity();

        // Burn user's principal and transfer sUSDS shares
        _burn(msg.sender, amount);
        IERC20(address(susds)).safeTransfer(msg.sender, shares);
        emit WithdrawUnderlying(msg.sender, amount);
    }

    // --- Yield ---

    // Treasury claims accrued yield as sUSDS (ERC-4626 shares), leaving principal intact.
    function claimYield(address treasury)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 assetsYield)
    {
        assetsYield = yield();
        if (assetsYield == 0) return 0;

        // Shares needed to represent `assetsYield` (round up so we don't dip below principal)
        uint256 sharesNeeded = susds.previewWithdraw(assetsYield);

        // Transfer shares to treasury
        IERC20(address(susds)).safeTransfer(treasury, sharesNeeded);

        // Invariant: valueOfCapital() must remain >= totalSupply() (principal)
        if (valueOfCapital() < totalSupply()) {
            revert StrategyCapitalMustNotChange();
        }

        emit YieldClaimed(msg.sender, treasury, address(susds), sharesNeeded);
        return assetsYield;
    }

    // --- Utility / Guardrail ---

    // "Godmode" for points / offchain value, forbidden from interacting with USDS or sUSDS; invariant protected
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
        if (to == address(susds) || to == address(token)) {
            revert StrategyCantInteractWithCoreAssets();
        }
        (success, result) = to.call{value: value}(data);
        if (valueOfCapital() < totalSupply()) {
            revert StrategyCapitalMustNotChange();
        }
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    /// @dev Address of the strategy's position token (e.g., aToken, stETH, etc)
    function positionToken() external view returns (address) {
        return address(susds);
    }
}
