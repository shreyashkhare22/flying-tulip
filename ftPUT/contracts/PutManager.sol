// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IERC20MetadataBurnable,
    IERC20Metadata,
    IERC20
} from "./interfaces/IERC20MetadataBurnable.sol";
import {IFlyingTulipOracle} from "./interfaces/IFlyingTulipOracle.sol";
import {IftYieldWrapper} from "./interfaces/IftYieldWrapper.sol";
import {IftACL} from "./interfaces/IftACL.sol";
import {IftPut} from "./interfaces/IftPut.sol";

// put manager will be a proxy
contract PutManager is ReentrancyGuardTransientUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;
    using SafeERC20 for IERC20MetadataBurnable;

    // ---- Constants (readability, avoid magic numbers) ----
    uint256 private constant ORACLE_DECIMALS = 1e8; // aaveOracle price scale
    uint256 private constant ONE_E18 = 1e18;

    event Invested(
        address investor,
        address recipient,
        uint256 id,
        uint256 amount,
        uint256 strike,
        address token,
        uint256 amountInvested
    );
    event Divested(
        address divestor,
        uint256 id,
        uint256 amount,
        uint256 strike,
        address token,
        uint256 amountDivested
    );
    event Withdraw(address owner, uint256 id, uint256 amount);
    event CapitalDivested(address owner, uint256 id, uint256 amount, address token);
    event AddCollateral(address msig, address collateral, uint256 currentPrice);
    event WithdrawDivestedCapital(address msig, address token, uint256 amount);
    event FTLiquidityAdded(uint256 amount, uint256 totalAvailable);
    event ExitPosition(
        address owner, uint256 id, uint256 ftReturned, address token, uint256 collateralAmount
    );
    event RemainderFTSent(uint256 amount);
    event TransferableEnabled();
    event MsigUpdateScheduled(address indexed nextMsig, uint256 effectiveTime);
    event MsigUpdated(address indexed newMsig);
    event CollateralCapsUpdated(address indexed token, uint256 cap);
    event ConfiguratorUpdated(address indexed newConfigurator);
    event ACLUpdated(address indexed newACL);
    event SaleEnabledUpdated(bool saleEnabled);
    event OracleUpdated(address indexed newOracle);

    error ftPutManagerZeroAddress();
    error ftPutManagerNotMsig();
    error ftPutManagerOracleError();
    error ftPutManagerInvalidMsig();
    error ftPutManagerInvalidInvestmentAsset();
    error ftPutManagerInvalidDecimals();
    error ftPutManagerNotConfigurator();
    error ftPutManagerInsufficientFTLiquidity();
    error ftPutManagerInvalidState();
    error ftPutManagerInvalidAmount();
    error ftPutManagerNoFTRemaining();
    error ftPutManagerCollateralCapExceeded();
    error ftPutManagerNotWhitelisted();
    error ftPutManagerAlreadyTransferable();

    IERC20MetadataBurnable immutable FT;
    IftPut immutable pFT;

    // --- Core configuration/storage (reordered; not deployed yet) ---
    // Addresses and pointers
    IFlyingTulipOracle public ftOracle; // pricing oracle (upgradeable via setter)
    address public msig; // admin multisig
    address public configurator; // protocol configurator
    address public nextMsig; // pending msig during rotation delay

    // Timers and flags
    uint64 public delayMsig; // Timestamp fits in uint64 (good until year 584942417)
    bool public transferable;
    bool public saleEnabled;

    // Accounting
    uint256 public ftOfferingSupply; // Total FT supply designated for the public offering
    uint256 public ftAllocated; // FT already allocated to positions
    IftACL public ftACL; // ACL whitelist, or zero to disable

    uint256 internal constant DELAY_MULTISIG = 1 hours; // 1 days in production

    // Collateral registry
    mapping(address token => bool isCollateral) public isCollateral;
    mapping(address token => uint256 amount) public capitalDivesting;
    mapping(address token => address vault) public vaults;
    mapping(address token => uint256 supply) public collateralSupply; // total collateral deposited (during offering)
    mapping(address => uint8) public collateralDecimals;
    address[] public getCollateral;

    mapping(address token => uint256 cap) public collateralCap;

    modifier onlyMsig() {
        if (msg.sender != msig) revert ftPutManagerNotMsig();
        _;
    }

    modifier onlyConfigurator() {
        if (msg.sender != configurator) revert ftPutManagerNotConfigurator();
        _;
    }

    function pause() external onlyMsig {
        _pause();
    }

    function unpause() external onlyMsig {
        _unpause();
    }

    constructor(address _ft, address _ftPut) {
        // Set immutables
        if (_ft == address(0x0)) revert ftPutManagerZeroAddress();
        if (_ftPut == address(0x0)) revert ftPutManagerZeroAddress();

        FT = IERC20MetadataBurnable(_ft);
        pFT = IftPut(_ftPut);

        // All other state variables use initializer
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param _configurator The address of the protocol configurator
     * @param _msig The address of the admin multisig
     * @param _oracle The address of the pricing oracle
     */
    function initialize(
        address _configurator,
        address _msig,
        address _oracle
    )
        external
        initializer
    {
        if (_msig == address(0x0)) revert ftPutManagerZeroAddress();
        if (_oracle == address(0x0)) revert ftPutManagerZeroAddress();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuardTransient_init();

        // set msig to the provided multisig address
        _updateMsig(_msig);
        _setConfigurator(_configurator);
        // set oracle
        ftOracle = IFlyingTulipOracle(_oracle);
        emit OracleUpdated(_oracle);
        // transferable defaults to false; no need to set
        _setSaleEnabled(true);
    }

    // step 1: existing msig calls with new msig
    function setMsig(address _msig) external onlyMsig {
        if (_msig == address(0x0)) revert ftPutManagerZeroAddress();
        if (_msig == msig || _msig == nextMsig) revert ftPutManagerInvalidMsig();
        uint256 effectiveTime = block.timestamp + DELAY_MULTISIG;
        emit MsigUpdateScheduled(_msig, effectiveTime);
        nextMsig = _msig;
        delayMsig = uint64(effectiveTime);
    }

    // step 2: new msig calls after delay to accept and update
    function acceptMsig() external {
        if (msg.sender != nextMsig || block.timestamp < delayMsig) {
            revert ftPutManagerInvalidMsig();
        }
        _updateMsig(nextMsig);
        // clear pending state
        nextMsig = address(0);
        delayMsig = 0;
    }

    // called from initializer and accept to emit events
    function _updateMsig(address _msig) internal {
        msig = _msig;
        emit MsigUpdated(_msig);
    }

    // if needed to migrate put manager for new deployment rules
    function setPutManager(address _putManager) external onlyMsig {
        if (_putManager == address(0x0)) revert ftPutManagerZeroAddress();
        pFT.setPutManager(_putManager);
    }

    // only callable by msig
    function setConfigurator(address _configurator) external onlyMsig {
        _setConfigurator(_configurator);
    }

    // called from initializer and setter to validate/emit events
    function _setConfigurator(address _configurator) internal {
        if (_configurator == address(0)) revert ftPutManagerZeroAddress();
        configurator = _configurator;
        emit ConfiguratorUpdated(_configurator);
    }

    /**
     * @dev Update the oracle address used for pricing.
     * @notice Only callable by msig. Emits OracleUpdated.
     */
    function setOracle(address _oracle) external onlyMsig {
        if (_oracle == address(0)) revert ftPutManagerZeroAddress();
        ftOracle = IFlyingTulipOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    /**
     * @dev Set or update the ACL contract
     * @notice Only callable by msig
     * @param _ftACL The address of the ACL contract (or zero to disable)
     */
    function setACL(address _ftACL) external onlyMsig {
        _setACL(_ftACL);
    }

    // called from initializer and setter to emit events
    function _setACL(address _ftACL) internal {
        ftACL = IftACL(_ftACL);
        emit ACLUpdated(_ftACL);
    }

    function enableTransferable() external onlyConfigurator {
        if (transferable) revert ftPutManagerAlreadyTransferable();
        transferable = true;
        emit TransferableEnabled();
    }

    function setSaleEnabled(bool _saleEnabled) external onlyConfigurator {
        _setSaleEnabled(_saleEnabled);
    }

    function _setSaleEnabled(bool _saleEnabled) internal {
        saleEnabled = _saleEnabled;
        emit SaleEnabledUpdated(_saleEnabled);
    }

    function addFTLiquidity(uint256 amount) external onlyConfigurator {
        if (amount == 0) revert ftPutManagerInvalidAmount();
        FT.safeTransferFrom(msg.sender, address(this), amount);
        ftOfferingSupply += amount;
        emit FTLiquidityAdded(amount, ftOfferingSupply);
    }

    function sendRemainderFTtoConfigurator() external onlyConfigurator {
        uint256 remainder = ftOfferingSupply - ftAllocated;
        if (remainder == 0) revert ftPutManagerNoFTRemaining();

        // Reduce offering supply to match what was actually sold
        ftOfferingSupply = ftAllocated;
        FT.safeTransfer(configurator, remainder);
        emit RemainderFTSent(remainder);
    }

    // Token decimals need to be <= 18 to be accepted as collateral
    function addAcceptedCollateral(address _collateral, address _vault) external onlyMsig {
        if (_collateral == address(0x0) || _vault == address(0x0)) {
            revert ftPutManagerZeroAddress();
        }

        uint256 _assetToUSD = ftOracle.getAssetPrice(_collateral);
        if (_assetToUSD == 0) revert ftPutManagerOracleError();

        uint8 d = IERC20Metadata(_collateral).decimals();
        if (d > 18) {
            revert ftPutManagerInvalidDecimals();
        }
        collateralDecimals[_collateral] = d;

        if (isCollateral[_collateral]) {
            revert ftPutManagerInvalidInvestmentAsset();
        }

        // ensure the supplied vault manages the same token
        if (address(IftYieldWrapper(_vault).token()) != _collateral) {
            revert ftPutManagerInvalidInvestmentAsset();
        }

        isCollateral[_collateral] = true;
        vaults[_collateral] = _vault;
        getCollateral.push(_collateral);
        emit AddCollateral(msg.sender, _collateral, _assetToUSD);
    }

    function setCollateralCaps(address token, uint256 cap_) external onlyConfigurator {
        if (!isCollateral[token]) revert ftPutManagerInvalidInvestmentAsset();
        collateralCap[token] = cap_;
        emit CollateralCapsUpdated(token, cap_);
    }

    function collateralIndex() external view returns (uint256) {
        return getCollateral.length;
    }

    function getFTAddress() public view returns (address) {
        return address(FT);
    }

    function invest(
        address token,
        uint256 amount,
        uint256 proofAmount,
        bytes32[] calldata proofWL
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        id = _invest(token, amount, msg.sender, msg.sender, proofAmount, proofWL);
    }

    function invest(
        address token,
        uint256 amount,
        address recipient,
        uint256 proofAmount,
        bytes32[] calldata proofWL
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (recipient == address(0)) revert ftPutManagerZeroAddress();
        id = _invest(token, amount, msg.sender, recipient, proofAmount, proofWL);
    }

    function _invest(
        address token,
        uint256 amount,
        address payer,
        address recipient,
        uint256 proofAmount,
        bytes32[] calldata proofWL
    )
        internal
        returns (uint256 id)
    {
        if (!saleEnabled) {
            revert ftPutManagerInvalidState();
        }

        if (
            address(ftACL) != address(0) && !ftACL.isWhitelisted(payer, token, proofAmount, proofWL)
        ) {
            revert ftPutManagerNotWhitelisted();
        }

        if (amount == 0) revert ftPutManagerInvalidAmount();
        if (!isCollateral[token]) revert ftPutManagerInvalidInvestmentAsset();

        uint256 projected = collateralSupply[token] + amount;
        if (collateralCap[token] != 0 && projected > collateralCap[token]) {
            revert ftPutManagerCollateralCapExceeded();
        }

        (uint256 ftOut, uint256 strike, uint64 ftPerUSD) =
            getAssetFTPrice(token, amount, collateralDecimals[token]);
        if (ftOut == 0) {
            revert ftPutManagerOracleError();
        }
        // Check if we have enough FT liquidity to sell
        uint256 availableFT = ftOfferingSupply - ftAllocated;
        if (ftOut > availableFT) {
            revert ftPutManagerInsufficientFTLiquidity();
        }
        // Update ACL invested amount to see if a cap has been reached (only if ACL is set)
        if (address(ftACL) != address(0) && proofAmount != 0) {
            // msg.sender instead of payer, because msg.sender is using up their allocation
            ftACL.invest(msg.sender, token, amount, proofAmount);
        }

        // Pull collateral
        IERC20(token).safeTransferFrom(payer, address(this), amount);

        // Approve vault (use forceApprove for USDT-like tokens)
        IftYieldWrapper _vault = IftYieldWrapper(vaults[token]);
        IERC20(token).forceApprove(address(_vault), amount);

        // Deposit into vault
        _vault.deposit(amount);

        // Update allocated FT (global) and collateral supply (cap is in native token units)
        ftAllocated += ftOut;
        collateralSupply[token] = projected;

        id = pFT.mint(recipient, amount, ftOut, strike, token, ftPerUSD);
        emit Invested(payer, recipient, id, ftOut, strike, token, amount);
    }

    // Withdraw FT (invalidating PUT position) after sale completed and tokens are transferable
    function withdrawFT(uint256 id, uint256 amount) external nonReentrant {
        if (!transferable) {
            revert ftPutManagerInvalidState();
        }
        (address token,,,,,, uint256 strike,, uint64 ftPerUSD) = pFT.puts(id);
        if (!isCollateral[token]) {
            revert ftPutManagerInvalidInvestmentAsset();
        }
        ftOfferingSupply -= amount;
        ftAllocated -= amount;

        // collateral to divest = amountFT * (1e8 * 10^d) / (strike * 10 * 1e18)
        uint256 _capitalDivesting =
            collateralFromFT(amount, strike, collateralDecimals[token], ftPerUSD);
        if (_capitalDivesting == 0) revert ftPutManagerInvalidAmount();

        pFT.withdrawFT(msg.sender, id, amount, _capitalDivesting);
        FT.safeTransfer(msg.sender, amount);

        // Track capital to be withdrawn later by msig (buybacks, etc.)
        capitalDivesting[token] += _capitalDivesting;

        emit Withdraw(msg.sender, id, amount);
        emit CapitalDivested(msg.sender, id, _capitalDivesting, token);
        emit ExitPosition(msg.sender, id, amount, token, _capitalDivesting);
    }

    function withdrawDivestedCapital(address token, uint256 amount) external nonReentrant onlyMsig {
        if (amount == 0) {
            revert ftPutManagerInvalidAmount();
        }
        if (amount > capitalDivesting[token]) {
            amount = capitalDivesting[token];
        }
        capitalDivesting[token] -= amount;
        collateralSupply[token] -= amount;

        // Withdraw token from vault
        IftYieldWrapper _vault = IftYieldWrapper(vaults[token]);
        _vault.withdraw(amount, msig);

        emit WithdrawDivestedCapital(msig, token, amount);
    }

    function canDivest(
        uint256 id,
        uint256 _amount
    )
        external
        view
        returns (bool divestable, uint256 amount)
    {
        (uint256 _ft, uint256 _strike, address _token, uint64 _ftPerUSD) = pFT.divestable(id);
        if (!isCollateral[_token]) return (false, 0); // defensive
        if (_amount > _ft) return (false, 0);

        // Calculate collateral amount from FT amount (mulDiv-safe)
        uint256 _collateralAmount =
            collateralFromFT(_amount, _strike, collateralDecimals[_token], _ftPerUSD);
        if (_collateralAmount == 0) return (false, 0);

        IftYieldWrapper _vault = IftYieldWrapper(vaults[_token]);
        if (!_vault.canWithdraw(_collateralAmount)) return (false, 0);
        return (true, _amount);
    }

    function maxDivestable(
        uint256 id,
        uint256 _amount
    )
        external
        view
        returns (bool divestable, uint256 amount)
    {
        (uint256 _ft, uint256 _strike, address _token, uint64 _ftPerUSD) = pFT.divestable(id);

        if (!isCollateral[_token]) return (false, 0); // defensive
        if (_ft == 0) return (false, 0);
        if (_ft < _amount) _amount = _ft;

        // Calculate collateral amount from FT amount (mulDiv-safe)
        uint8 d = collateralDecimals[_token];
        uint256 _collateralAmount = collateralFromFT(_amount, _strike, d, _ftPerUSD);
        if (_collateralAmount == 0) return (false, 0);

        IftYieldWrapper _vault = IftYieldWrapper(vaults[_token]);
        uint256 _maxCollateral = _vault.maxAbleToWithdraw(_collateralAmount);

        // If vault can't provide full amount, calculate how much FT that represents (mulDiv-safe)
        if (_maxCollateral < _collateralAmount) {
            amount = ftFromCollateral(_maxCollateral, _strike, d, _ftPerUSD);
        } else {
            // Vault has sufficient liquidity, return the requested amount
            amount = _amount;
        }

        return (true, amount);
    }

    // amount as measured as portion of tokens
    // execute the PUT
    function divest(uint256 id, uint256 amount_ft) external nonReentrant {
        (address token,,,,,, uint256 strike,, uint64 ftPerUSD) = pFT.puts(id);
        if (!isCollateral[token]) {
            revert ftPutManagerInvalidInvestmentAsset();
        }

        // collateral to withdraw = amountFT * (1e8 * 10^d) / (strike * 10 * 1e18)
        uint256 _capitalDivesting =
            collateralFromFT(amount_ft, strike, collateralDecimals[token], ftPerUSD);
        if (_capitalDivesting == 0) revert ftPutManagerInvalidAmount();

        ftAllocated -= amount_ft;
        collateralSupply[token] -= _capitalDivesting;
        pFT.divest(msg.sender, id, amount_ft, _capitalDivesting);

        IftYieldWrapper _vault = IftYieldWrapper(vaults[token]);
        _vault.withdraw(_capitalDivesting, msg.sender);

        emit Divested(msg.sender, id, amount_ft, strike, token, _capitalDivesting);
        emit ExitPosition(msg.sender, id, amount_ft, token, _capitalDivesting);
    }

    // amount as measured as portion of tokens
    // execute the PUT
    function divestUnderlying(uint256 id, uint256 amount_ft) external nonReentrant {
        (address token,,,,,, uint256 strike,, uint64 ftPerUSD) = pFT.puts(id);
        if (!isCollateral[token]) {
            revert ftPutManagerInvalidInvestmentAsset();
        }

        // collateral to withdraw = amountFT * (1e8 * 10^d) / (strike * 10 * 1e18)
        uint256 _capitalDivesting =
            collateralFromFT(amount_ft, strike, collateralDecimals[token], ftPerUSD);
        if (_capitalDivesting == 0) revert ftPutManagerInvalidAmount();

        ftAllocated -= amount_ft;
        collateralSupply[token] -= _capitalDivesting;

        pFT.divest(msg.sender, id, amount_ft, _capitalDivesting);

        IftYieldWrapper _vault = IftYieldWrapper(vaults[token]);
        _vault.withdrawUnderlying(_capitalDivesting, msg.sender);

        emit Divested(msg.sender, id, amount_ft, strike, token, _capitalDivesting);
        emit ExitPosition(msg.sender, id, amount_ft, token, _capitalDivesting);
    }

    // Oracle methods for compatibility

    function getAssetPrice(address token) public view returns (uint256) {
        return ftOracle.getAssetPrice(token);
    }

    function getOracleAddress() external view returns (address) {
        return address(ftOracle);
    }

    // --- Pricing helpers (single source of truth for formulas) ---

    /// @notice Converts FT to collateral amount using oracle pricing.
    /// @dev Formula (with ftPerUSD scaled to 1e8):
    ///      collateral = ftAmount * (1e8^2 * 10^d) / (strike * ftPerUSD * 1e18)
    /// @param ftAmount Amount of FT to convert.
    /// @param strike Oracle price of the collateral (scaled to 1e8).
    /// @param tokenDecimals Collateral token decimals (<= 18).
    /// @param ftPerUSD FT per 1 USD scaled to 1e8 (same base as oracle).
    /// @return The exact collateral amount implied by ftAmount.
    function collateralFromFT(
        uint256 ftAmount,
        uint256 strike,
        uint8 tokenDecimals,
        uint64 ftPerUSD
    )
        public
        pure
        returns (uint256)
    {
        // ftPerUSD is scaled to 1e8; include an extra ORACLE_DECIMALS factor
        uint256 numScale = ORACLE_DECIMALS * ORACLE_DECIMALS * (10 ** tokenDecimals);
        uint256 den = strike * ftPerUSD * ONE_E18;
        return Math.mulDiv(ftAmount, numScale, den);
    }

    /// @notice Converts collateral amount to FT using oracle pricing.
    /// @dev Formula (with ftPerUSD scaled to 1e8):
    ///      ft = collateral * (strike * ftPerUSD * 1e18) / (1e8^2 * 10^d)
    /// @param collateral Amount of collateral to convert.
    /// @param strike Oracle price of the collateral (scaled to 1e8).
    /// @param tokenDecimals Collateral token decimals (<= 18).
    /// @param ftPerUSD FT per 1 USD scaled to 1e8 (same base as oracle).
    /// @return The exact FT implied by the collateral amount.
    function ftFromCollateral(
        uint256 collateral,
        uint256 strike,
        uint8 tokenDecimals,
        uint64 ftPerUSD
    )
        public
        pure
        returns (uint256)
    {
        // ftPerUSD is scaled to 1e8; include an extra ORACLE_DECIMALS factor
        uint256 num = strike * ftPerUSD * ONE_E18;
        uint256 den = ORACLE_DECIMALS * ORACLE_DECIMALS * (10 ** tokenDecimals);
        return Math.mulDiv(collateral, num, den);
    }

    /// @notice Price helper returning FT required for a given collateral amount.
    /// @dev Returns oracle strike (1e8 scale) and ftPerUSD (1e8 scale).
    /// @param token Collateral token address.
    /// @param amount Collateral amount (token native decimals).
    /// @param tokenDecimals Collateral token decimals (<= 18).
    /// @return ftOut The FT to allocate for `amount` of collateral.
    /// @return strike The oracle price (1e8 scale).
    /// @return ftPerUSD FT per USD scaled to 1e8 (same base as oracle).
    function getAssetFTPrice(
        address token,
        uint256 amount,
        uint8 tokenDecimals
    )
        public
        view
        returns (uint256 ftOut, uint256 strike, uint64 ftPerUSD)
    {
        strike = ftOracle.getAssetPrice(token);
        ftPerUSD = uint64(ftOracle.ftPerUSD());
        ftOut = ftFromCollateral(amount, strike, tokenDecimals, ftPerUSD);
    }

    // Backwards-compatible overload using registered decimals
    /// @notice Overload using registered decimals for `token`.
    /// @dev Returns oracle strike (1e8 scale) and ftPerUSD (1e8 scale).
    /// @param token Collateral token address.
    /// @param amount Collateral amount (token native decimals).
    /// @return ftOut The FT to allocate for `amount` of collateral.
    /// @return strike The oracle price (1e8 scale).
    /// @return ftPerUSD FT per USD scaled to 1e8 (same base as oracle).
    function getAssetFTPrice(
        address token,
        uint256 amount
    )
        public
        view
        returns (uint256 ftOut, uint256 strike, uint64 ftPerUSD)
    {
        return getAssetFTPrice(token, amount, collateralDecimals[token]);
    }

    // UUPS upgradeability authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyMsig {}
}
