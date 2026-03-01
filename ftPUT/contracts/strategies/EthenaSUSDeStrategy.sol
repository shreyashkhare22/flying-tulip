// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {
    IERC20Metadata,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IStrategyWithQueue} from "../interfaces/IStrategy.sol";

/* ─────────────────────────────────────────────────────────────────────────────
   Minimal interfaces for Ethena's StakedUSDeV2 (ERC4626 + cooldowns)
   Verified on Etherscan at 0x9d39...A3497 (contract name: StakedUSDeV2).
   Methods reflect its code & OpenZeppelin ERC4626 base.
   ───────────────────────────────────────────────────────────────────────────── */
interface IStakedUSDeV2Like is IERC20 {
    /* ERC4626 */
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        external
        returns (uint256 shares);
    function maxRedeem(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        external
        returns (uint256 assets);

    /* Cooldown extensions (V2) */
    function cooldownDuration() external view returns (uint24);

    /// Cooldown state per address (public in StakedUSDeV2)
    /// struct UserCooldown { uint104 cooldownEnd; uint152 underlyingAmount; }
    function cooldowns(address user)
        external
        view
        returns (uint104 cooldownEnd, uint152 underlyingAmount);

    function cooldownAssets(uint256 assets) external returns (uint256 shares);
    function cooldownShares(uint256 shares) external returns (uint256 assets);
    function unstake(address receiver) external;
}

/* ─────────────────────────────────────────────────────────────────────────────
   A single‑use escrow that
     1) holds sUSDe shares,
     2) starts its own cooldown,
     3) later calls unstake(receiver) to release USDe from USDeSilo to user.
   Each escrow isolates cooldownEnd so multiple users can withdraw in parallel.
   ───────────────────────────────────────────────────────────────────────────── */
contract SUSDeCoolingEscrow is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IStakedUSDeV2Like public immutable sUSDe;
    address public immutable strategy;
    address public immutable beneficiary; // user to ultimately receive USDe

    bool public started;
    uint104 public cooldownEndSnapshot; // cached for convenience

    error EscrowOnlyStrategy();
    error EscrowAlreadyStarted();
    error EscrowNotMature();

    modifier onlyStrategy() {
        if (msg.sender != strategy) revert EscrowOnlyStrategy();
        _;
    }

    constructor(IStakedUSDeV2Like _sUSDe, address _strategy, address _beneficiary) {
        sUSDe = _sUSDe;
        strategy = _strategy;
        beneficiary = _beneficiary;
    }

    /// @dev Strategy transfers sUSDe shares here first, then calls startCooldown(assets).
    function startCooldown(uint256 assets)
        external
        onlyStrategy
        nonReentrant
        returns (uint104 cooldownEnd)
    {
        if (started) revert EscrowAlreadyStarted();
        started = true;

        // Burns this escrow's shares and moves USDe to Silo; records this escrow's cooldown
        sUSDe.cooldownAssets(assets);

        (cooldownEnd,) = sUSDe.cooldowns(address(this));
        cooldownEndSnapshot = cooldownEnd;
    }

    /// @dev Anyone can trigger claim via the strategy once mature; sends USDe to the beneficiary.
    function claimToBeneficiary()
        external
        onlyStrategy
        nonReentrant
        returns (uint256 assetsReceived)
    {
        (uint104 end, uint152 underlying) = sUSDe.cooldowns(address(this));
        if (!(block.timestamp >= end || sUSDe.cooldownDuration() == 0)) revert EscrowNotMature();

        // unstake transfers the underlying USDe from Silo directly to `beneficiary`
        sUSDe.unstake(beneficiary);
        return uint256(underlying);
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
   Strategy: deposits USDe into sUSDe, accrues yield, and supports atomic/queued
   withdrawals. Matches your AaveStrategy shape (events, 1:1 shares, wrapper).
   ───────────────────────────────────────────────────────────────────────────── */
contract EthenaSUSDeStrategy is IStrategyWithQueue, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata public immutable usde;
    IStakedUSDeV2Like public immutable sUSDe;

    // ftYieldWrapper has no direct access to sUSDe; it interacts via this strategy.
    address public ftYieldWrapper;

    modifier onlyftYieldWrapper() {
        if (msg.sender != ftYieldWrapper) revert StrategyNotYieldWrapper();
        _;
    }

    constructor(
        address _ftYieldWrapper,
        address _usde,
        address _sUSDe
    )
        ERC20(
            string.concat("Flying Tulip Ethena ", IERC20Metadata(_usde).name()),
            string.concat("ftEthena", IERC20Metadata(_usde).symbol())
        )
    {
        if (_ftYieldWrapper == address(0) || _usde == address(0) || _sUSDe == address(0)) {
            revert StrategyZeroAddress();
        }

        ftYieldWrapper = _ftYieldWrapper;
        usde = IERC20Metadata(_usde);
        sUSDe = IStakedUSDeV2Like(_sUSDe);

        emit Transfer(address(0x0), address(this), 0);
    }

    /* ------------------------------ Admin ------------------------------- */

    function setftYieldWrapper(address _ftYieldWrapper) external onlyftYieldWrapper {
        if (_ftYieldWrapper == address(0)) revert StrategyZeroAddress();
        ftYieldWrapper = _ftYieldWrapper;
        emit UpdateftYieldWrapper(_ftYieldWrapper);
    }

    /* ----------------------------- Views -------------------------------- */

    /// 1:1 mapping of capital provided (in USDe units)
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    /// Capital + yield (value of all sUSDe held here, in USDe units)
    function valueOfCapital() public view returns (uint256) {
        uint256 sharesHeld = sUSDe.balanceOf(address(this));
        return sUSDe.convertToAssets(sharesHeld);
    }

    function yield() public view returns (uint256) {
        uint256 v = valueOfCapital();
        uint256 t = totalSupply();
        return (v > t) ? (v - t) : 0;
    }

    /// Liquidity available for **atomic USDe** withdrawals right now
    function availableToWithdraw() public view returns (uint256) {
        return usde.balanceOf(address(this));
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        return (availableToWithdraw() >= amount);
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 liq = availableToWithdraw();
        return liq > amount ? amount : liq;
    }

    function token() public view returns (address) {
        return address(usde);
    }

    function decimals() public view override(IERC20Metadata, ERC20) returns (uint8) {
        return usde.decimals();
    }

    /* ---------------------------- Core flows ---------------------------- */

    /// Deposit USDe → stake into sUSDe; mint 1:1 strategy shares to wrapper.
    function deposit(uint256 amount) external nonReentrant onlyftYieldWrapper {
        if (amount == 0) revert StrategyAmountZero();

        usde.safeTransferFrom(msg.sender, address(this), amount);
        usde.forceApprove(address(sUSDe), amount);
        sUSDe.deposit(amount, address(this)); // sUSDe shares accrue here
        _mint(msg.sender, amount); // 1:1 strategy IOU
        emit Deposit(msg.sender, amount);
    }

    /// Withdraw USDe, **atomic path**
    function withdraw(uint256 amount)
        public
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        _burn(msg.sender, amount);
        usde.safeTransfer(msg.sender, amount);
        received = amount;
        emit Withdraw(msg.sender, amount);
    }

    /* -------------------- Queued withdraw with escrows ------------------ */

    mapping(uint256 id => address escrow) public queue; // id => data
    uint256 public head;
    uint256 public tail;

    /// Queue a withdraw under Ethena's cooldown (creates a dedicated escrow).
    /// Returns queue id so UIs can track status.
    function withdrawQueued(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 id)
    {
        if (amount == 0) revert StrategyAmountZero();
        _burn(msg.sender, amount);

        // Compute shares needed to cover `amount` as assets under current PPS
        uint256 shares = sUSDe.previewWithdraw(amount);

        // Spin up a dedicated escrow for this request
        SUSDeCoolingEscrow esc = new SUSDeCoolingEscrow(sUSDe, address(this), msg.sender);
        // Move the shares to escrow and start cooldown
        IERC20(address(sUSDe)).safeTransfer(address(esc), shares);
        esc.startCooldown(amount);
        id = tail;
        queue[id] = address(esc);
        tail++;

        emit WithdrawQueued(msg.sender, amount, id);
    }

    /// Claim a matured queued withdrawal (escrow will call unstake to send USDe directly to the user).
    function claimQueued(uint256 id)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        address q = queue[id];
        head = id;
        received = SUSDeCoolingEscrow(q).claimToBeneficiary(); // sends USDe to q.owner
        emit WithdrawClaimed(msg.sender, received, id);
    }

    /* ----------------------- sUSDe immediate exit ----------------------- */

    /// Optional fast path: get sUSDe instead of USDe for a USDe‑denominated amount.
    /// Hardened: use convertToShares(amount) (rounds down) to avoid giving
    /// more than value‑equivalent shares via previewWithdraw rounding‑up.
    /// Also require shares > 0 and value shortfall ≤ 1 unit to avoid dust exploits.
    function withdrawUnderlying(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 shares)
    {
        if (amount == 0) revert StrategyAmountZero();

        // Compute shares by rounding down to avoid overpayment
        shares = sUSDe.convertToShares(amount);
        if (shares == 0) revert StrategyInsufficientLiquidity();

        // Accept at most 1 unit of asset shortfall due to rounding
        uint256 assetsBack = sUSDe.convertToAssets(shares);
        if (assetsBack + 1 < amount) revert StrategyInsufficientLiquidity();

        // Safety clamp: ensure we have enough shares
        uint256 ourShares = IERC20(address(sUSDe)).balanceOf(address(this));
        if (shares > ourShares) revert StrategyInsufficientLiquidity();

        _burn(msg.sender, amount);
        IERC20(address(sUSDe)).safeTransfer(msg.sender, shares);

        emit WithdrawUnderlying(msg.sender, shares);
    }

    /* ----------------------------- Yield -------------------------------- */

    /// Claim the accrued yield **in sUSDe shares** to a treasury.
    /// Returns the number of sUSDe shares transferred.
    function claimYield(address treasury)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 sharesToTreasury)
    {
        uint256 yAssets = yield();
        if (yAssets == 0) return 0;

        // Determine shares representing exactly the yield
        sharesToTreasury = sUSDe.previewWithdraw(yAssets);
        IERC20(address(sUSDe)).safeTransfer(treasury, sharesToTreasury);
        emit YieldClaimed(msg.sender, treasury, address(sUSDe), sharesToTreasury);
    }

    /* ---------------------- Safety / maintenance ------------------------ */

    /// Optional: restricted generic executor that cannot touch sUSDe or USDe.
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
        if (to == address(sUSDe) || to == address(usde)) {
            revert StrategyCantInteractWithCoreAssets();
        }
        (success, result) = to.call{value: value}(data);
        // Ensure solvency: strategy value must never drop below capital
        if (valueOfCapital() < totalSupply()) revert StrategyCapitalMustNotChange();
    }

    /// @dev Address of the strategy's position token (e.g., aToken, stETH, etc)
    function positionToken() external view returns (address) {
        return address(sUSDe);
    }
}
