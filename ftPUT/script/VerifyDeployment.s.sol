// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftACL} from "contracts/ftACL.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {FlyingTulipOracle} from "contracts/FlyingTulipOracle.sol";
import {CircuitBreaker} from "contracts/cb/CircuitBreaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Interface for querying FT token configurator
interface IFTToken {
    function configurator() external view returns (address);
}

/// @notice Verification script to validate deployed contract state against expected config
/// @dev Run this after deployment to verify configuration before accepting ownership
///      Compares on-chain state with expected values from deployments.toml
///      Automatically detects and validates CircuitBreaker if deployed
///
/// Usage:
///   forge script script/VerifyDeployment.s.sol:VerifyDeployment \
///     --rpc-url $RPC_URL \
///     -s "run(address,address)" <PUT_MANAGER_PROXY> <PFT_PROXY> \
///     -vvv
///
/// Example:
///   forge script script/VerifyDeployment.s.sol:VerifyDeployment \
///     --rpc-url $RPC_URL \
///     -s "run(address,address)" 0x1234...PutManager 0x5678...pFT \
///     -vvv
///
/// Validates:
///   - PutManager: ownership, collateral configuration, caps, FT supply
///   - pFT: access control, PUT manager linkage
///   - Collateral: wrapper/strategy deployment, registration, role assignments
///   - Oracle: ownership, price feed configuration
///   - ACL: merkle root, membership validation (if enabled)
///   - CircuitBreaker: config values, ownership, pause state, wrapper registrations (if deployed)
///   - Pending Actions: lists all required post-deployment ownership transfers
contract VerifyDeployment is Script {
    string internal constant CONFIG_PATH = "script/config/deployments.toml";

    // Circuit Breaker recommended defaults (same as deploy script)
    // 5% max draw rate, 4h main window, 2h elastic window
    uint256 internal constant CB_MAX_DRAW_RATE_WAD = 5e16; // 5% (50000000000000000)
    uint256 internal constant CB_MAIN_WINDOW = 14400; // 4 hours in seconds
    uint256 internal constant CB_ELASTIC_WINDOW = 7200; // 2 hours in seconds

    struct ExpectedConfig {
        address usdc;
        address wNative;
        address usdt;
        address usds;
        address usdtb;
        address usde;
        address ft;
        address aavePoolProvider;
        address aaveOracle;
        address aaveAUSDC;
        address aaveAWNative;
        address aaveAUSDT;
        address aaveAUSDS;
        address aaveAUSDTb;
        address aaveAUSDe;
        address msig;
        address configurator;
        address treasury;
        address yieldClaimer;
        address strategyManager;
        uint256 capUSDC;
        uint256 capWNative;
        uint256 capUSDT;
        uint256 capUSDS;
        uint256 capUSDTb;
        uint256 capUSDe;
        uint256 initialFTSupply;
        bool disableACL;
        bytes32 merkleRoot;
        bool isProduction;
        // Circuit Breaker
        bool deployCircuitBreaker;
        uint256 cbMaxDrawRateWad;
        uint256 cbMainWindow;
        uint256 cbElasticWindow;
    }

    function run(address putManagerProxy, address pftProxy) external view {
        console.log("");
        console.log(
            "================================================================================"
        );
        console.log("                    DEPLOYMENT VERIFICATION REPORT");
        console.log(
            "================================================================================"
        );
        console.log("");
        console.log("Chain ID:         ", block.chainid);
        console.log("Block Number:     ", block.number);
        console.log("Current Time:     ", block.timestamp);
        console.log("PutManager Proxy: ", putManagerProxy);

        // Get PutManager implementation address from EIP-1967 storage slot
        bytes32 IMPLEMENTATION_SLOT =
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address putManagerImpl =
            address(uint160(uint256(vm.load(putManagerProxy, IMPLEMENTATION_SLOT))));
        console.log("PutManager Implementation:", putManagerImpl);

        console.log("pFT Proxy:        ", pftProxy);

        // Get pFT implementation address from EIP-1967 storage slot
        address pftImpl = address(uint160(uint256(vm.load(pftProxy, IMPLEMENTATION_SLOT))));
        console.log("pFT Implementation:", pftImpl);

        console.log("");

        // Load expected configuration from deployments.toml
        ExpectedConfig memory expected = _loadExpectedConfig();

        PutManager manager = PutManager(putManagerProxy);

        _validatePutManagerState(manager, expected);
        _validatePftState(pftProxy, address(manager), expected);
        _validateCollateralState(manager, expected);
        _validateOracleState(manager, expected);
        _validateACLState(manager, expected);

        // Get CircuitBreaker address from first available wrapper
        address circuitBreakerAddr = _getCircuitBreakerAddress(manager, expected);
        _validateCircuitBreakerState(circuitBreakerAddr, manager, expected);
        _printPendingActions(manager, expected, circuitBreakerAddr);

        console.log("");
        console.log(
            "================================================================================"
        );
        console.log("                    VERIFICATION COMPLETE");
        console.log(
            "================================================================================"
        );
        console.log("");
    }

    function _loadExpectedConfig() internal view returns (ExpectedConfig memory cfg) {
        uint256 chainId = block.chainid;
        string memory chainIdStr = vm.toString(chainId);
        string memory raw = vm.readFile(CONFIG_PATH);

        console.log("Loading expected config from:", CONFIG_PATH);
        console.log("For chain ID:", chainId);
        console.log("");

        // Load core token addresses
        // Load USDC (optional - use try/catch to handle missing keys)
        try vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.usdc")) returns (
            address _usdc
        ) {
            cfg.usdc = _usdc;
        } catch {}
        // Load wNative (optional - use try/catch to handle missing keys)
        try vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.wNative")) returns (
            address _wNative
        ) {
            cfg.wNative = _wNative;
        } catch {}

        // Load additional token addresses (optional)
        try vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.usdt")) returns (
            address _usdt
        ) {
            cfg.usdt = _usdt;
        } catch {}
        try vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.usds")) returns (
            address _usds
        ) {
            cfg.usds = _usds;
        } catch {}
        try vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.usdtb")) returns (
            address _usdtb
        ) {
            cfg.usdtb = _usdtb;
        } catch {}
        try vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.usde")) returns (
            address _usde
        ) {
            cfg.usde = _usde;
        } catch {}

        cfg.ft = vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.ft"));
        cfg.aavePoolProvider =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.aave_pool_provider"));
        cfg.aaveOracle =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.aave_oracle"));
        // Load aave_ausdc (optional - use try/catch to handle missing keys)
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausdc")
        ) returns (
            address _aaveAUSDC
        ) {
            cfg.aaveAUSDC = _aaveAUSDC;
        } catch {}
        // Load aave_awnative (optional - use try/catch to handle missing keys)
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_awnative")
        ) returns (
            address _aaveAWNative
        ) {
            cfg.aaveAWNative = _aaveAWNative;
        } catch {}

        // Load additional aToken addresses (optional)
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausdt")
        ) returns (
            address _aUSDT
        ) {
            cfg.aaveAUSDT = _aUSDT;
        } catch {}
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausds")
        ) returns (
            address _aUSDS
        ) {
            cfg.aaveAUSDS = _aUSDS;
        } catch {}
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausdtb")
        ) returns (
            address _aUSDTb
        ) {
            cfg.aaveAUSDTb = _aUSDTb;
        } catch {}
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausde")
        ) returns (
            address _aUSDe
        ) {
            cfg.aaveAUSDe = _aUSDe;
        } catch {}

        // Load roles
        cfg.msig = vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.msig"));
        cfg.configurator =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.configurator"));
        cfg.treasury = vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.treasury"));
        cfg.yieldClaimer =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.yield_claimer"));
        cfg.strategyManager =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.strategy_manager"));

        // Load uints
        // Load cap_usdc (optional - use try/catch to handle missing keys)
        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cap_usdc")) returns (
            uint256 _capUSDC
        ) {
            cfg.capUSDC = _capUSDC;
        } catch {}
        // Load cap_wnative (optional - use try/catch to handle missing keys)
        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cap_wnative")) returns (
            uint256 _capWNative
        ) {
            cfg.capWNative = _capWNative;
        } catch {}

        // Load additional caps (optional)
        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cap_usdt")) returns (
            uint256 _capUSDT
        ) {
            cfg.capUSDT = _capUSDT;
        } catch {}
        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cap_usds")) returns (
            uint256 _capUSDS
        ) {
            cfg.capUSDS = _capUSDS;
        } catch {}
        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cap_usdtb")) returns (
            uint256 _capUSDTb
        ) {
            cfg.capUSDTb = _capUSDTb;
        } catch {}
        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cap_usde")) returns (
            uint256 _capUSDe
        ) {
            cfg.capUSDe = _capUSDe;
        } catch {}

        string memory initialSupplyStr =
            vm.parseTomlString(raw, string.concat(".", chainIdStr, ".uint.initial_ft_supply"));
        cfg.initialFTSupply = vm.parseUint(initialSupplyStr);

        // Load bools
        cfg.isProduction =
            vm.parseTomlBool(raw, string.concat(".", chainIdStr, ".bool.is_production"));
        cfg.disableACL = vm.parseTomlBool(raw, string.concat(".", chainIdStr, ".bool.disable_acl"));

        // Load bytes32
        cfg.merkleRoot =
            vm.parseTomlBytes32(raw, string.concat(".", chainIdStr, ".bytes32.merkle_root"));

        // Load circuit breaker flag (optional - defaults to false)
        try vm.parseTomlBool(
            raw, string.concat(".", chainIdStr, ".bool.deploy_circuit_breaker")
        ) returns (
            bool _deployCircuitBreaker
        ) {
            cfg.deployCircuitBreaker = _deployCircuitBreaker;
        } catch {}

        // Load circuit breaker config (optional - defaults to 0 = disabled)
        try vm.parseTomlUint(
            raw, string.concat(".", chainIdStr, ".uint.cb_max_draw_rate_wad")
        ) returns (
            uint256 _cbMaxDrawRateWad
        ) {
            cfg.cbMaxDrawRateWad = _cbMaxDrawRateWad;
        } catch {}

        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cb_main_window")) returns (
            uint256 _cbMainWindow
        ) {
            cfg.cbMainWindow = _cbMainWindow;
        } catch {}

        try vm.parseTomlUint(
            raw, string.concat(".", chainIdStr, ".uint.cb_elastic_window")
        ) returns (
            uint256 _cbElasticWindow
        ) {
            cfg.cbElasticWindow = _cbElasticWindow;
        } catch {}

        // Apply defaults if CB is enabled but values are 0 or omitted
        if (cfg.deployCircuitBreaker) {
            if (cfg.cbMaxDrawRateWad == 0) {
                cfg.cbMaxDrawRateWad = CB_MAX_DRAW_RATE_WAD;
            }
            if (cfg.cbMainWindow == 0) {
                cfg.cbMainWindow = CB_MAIN_WINDOW;
            }
            if (cfg.cbElasticWindow == 0) {
                cfg.cbElasticWindow = CB_ELASTIC_WINDOW;
            }
        }
    }

    function _validatePutManagerState(
        PutManager manager,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        console.log(
            "================================================================================"
        );
        console.log("                    PUTMANAGER VALIDATION");
        console.log(
            "================================================================================"
        );
        console.log("");

        // Check msig ownership
        address currentMsig = manager.msig();
        address nextMsig = manager.nextMsig();
        uint64 delayMsig = manager.delayMsig();

        console.log("--- Msig Ownership ---");
        console.log("Expected msig:     ", expected.msig);
        console.log("Current msig:      ", currentMsig);

        if (currentMsig == expected.msig) {
            console.log("Status:            [OK] CORRECT - Msig ownership transferred");
        } else if (nextMsig == expected.msig) {
            console.log("Next msig:         ", nextMsig);
            console.log("Delay until:       ", delayMsig);
            if (block.timestamp >= delayMsig) {
                console.log("Status:            [WARN] PENDING - Ready to accept NOW");
                console.log("Action:            Call PutManager.acceptMsig() from msig");
                console.log("                   Msig address:", expected.msig);
            } else {
                uint256 waitTime = delayMsig - block.timestamp;
                console.log("Wait time (sec):  ", waitTime);
                console.log("Wait time (hrs):  ", waitTime / 3600);
                console.log("Status:            [WARN] PENDING - Waiting for time delay");
            }
        } else {
            console.log("Status:            [ERROR] MISMATCH - Unexpected msig address");
            console.log("                   Current:", currentMsig);
            console.log("                   Expected:", expected.msig);
        }
        console.log("");

        // Check configurator
        address currentConfigurator = manager.configurator();
        console.log("--- Configurator ---");
        console.log("Expected:          ", expected.configurator);
        console.log("Current:           ", currentConfigurator);
        if (currentConfigurator == expected.configurator) {
            console.log("Status:            [OK] CORRECT");
        } else {
            console.log("Status:            [ERROR] MISMATCH");
        }
        console.log("");

        // Check contract state
        console.log("--- Contract State ---");
        bool paused = manager.paused();
        bool saleEnabled = manager.saleEnabled();
        bool transferable = manager.transferable();

        console.log("Paused:           ", paused ? "YES" : "NO");
        if (paused) {
            console.log("                   [WARN] WARNING: Contract is paused!");
        }

        console.log("Sale Enabled:     ", saleEnabled ? "YES" : "NO");
        if (!saleEnabled) {
            console.log("                   [WARN] WARNING: Sales are disabled!");
        }

        console.log("Transferable:     ", transferable ? "YES" : "NO");
        console.log("");

        // Check FT supply
        console.log("--- FT Supply ---");
        uint256 ftOfferingSupply = manager.ftOfferingSupply();
        uint256 ftAllocated = manager.ftAllocated();
        console.log("Expected Supply:  ", expected.initialFTSupply);
        console.log("Current Supply:   ", ftOfferingSupply);
        console.log("Allocated:        ", ftAllocated);
        console.log("Available:        ", ftOfferingSupply - ftAllocated);

        if (ftOfferingSupply == 0) {
            console.log("Status:            [WARN] FT liquidity NOT YET ADDED");
            console.log("");
            console.log("REQUIRED ACTION: FT token configurator must add liquidity");

            // Try to get FT configurator address and balance
            if (expected.ft != address(0)) {
                try IFTToken(expected.ft).configurator() returns (address ftConfigurator) {
                    console.log("  FT Configurator:", ftConfigurator);
                    try IERC20(expected.ft).balanceOf(ftConfigurator) returns (uint256 balance) {
                        console.log("  FT Balance:     ", balance);
                        console.log("  Required:       ", expected.initialFTSupply);
                        if (balance >= expected.initialFTSupply) {
                            console.log(
                                "  Status:          Sufficient balance - ready to add liquidity"
                            );
                        } else {
                            console.log("  Status:          [ERROR] Insufficient balance!");
                        }
                    } catch {}
                } catch {}
            }
        } else if (ftOfferingSupply == expected.initialFTSupply) {
            console.log("Status:            [OK] CORRECT - Liquidity added");
        } else {
            console.log("Status:            [WARN] MISMATCH - Supply differs from expected");
        }
        console.log("");
    }

    function _validatePftState(
        address pftAddr,
        address expectedPutManager,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        console.log(
            "================================================================================"
        );
        console.log("                    pFT (ERC721) VALIDATION");
        console.log(
            "================================================================================"
        );
        console.log("");

        console.log("pFT Proxy Address:", pftAddr);

        if (pftAddr == address(0)) {
            console.log("Status:            [ERROR] ERROR - No pFT provided!");
            console.log("");
            return;
        }

        pFT nft = pFT(pftAddr);

        // Check putManager link from pFT
        address pftPutManager = nft.putManager();
        console.log("pFT's PutManager: ", pftPutManager);
        console.log("Expected:         ", expectedPutManager);

        if (pftPutManager == expectedPutManager) {
            console.log("Status:            [OK] CORRECT - pFT linked to PutManager");
        } else {
            console.log("Status:            [ERROR] MISMATCH - pFT not linked correctly!");
            console.log("");
            return;
        }

        // Check msig control (pFT is controlled via its putManager's msig)
        console.log("");
        console.log("--- pFT Control (via PutManager's Msig) ---");
        PutManager pftManager = PutManager(pftPutManager);
        address pftManagerMsig = pftManager.msig();
        console.log("pFT's PutManager Msig:", pftManagerMsig);
        console.log("Expected Msig:        ", expected.msig);

        if (pftManagerMsig == expected.msig) {
            console.log("Control Status:        [OK] CORRECT - pFT controlled by expected msig");
        } else {
            address nextMsig = pftManager.nextMsig();
            if (nextMsig == expected.msig) {
                console.log("Control Status:        [WARN] PENDING - Msig transfer pending");
            } else {
                console.log("Control Status:        [ERROR] MISMATCH - Unexpected msig!");
            }
        }

        console.log("");
    }

    function _validateCollateralState(
        PutManager manager,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        console.log(
            "================================================================================"
        );
        console.log("                    COLLATERAL VALIDATION");
        console.log(
            "================================================================================"
        );
        console.log("");

        // Check USDC collateral
        if (expected.usdc != address(0)) {
            _validateCollateral(manager, expected.usdc, "USDC", expected.capUSDC, expected);
        }

        // Check wNative collateral
        if (expected.wNative != address(0)) {
            _validateCollateral(manager, expected.wNative, "wNative", expected.capWNative, expected);
        }

        // Check additional collaterals
        if (expected.usdt != address(0)) {
            _validateCollateral(manager, expected.usdt, "USDT", expected.capUSDT, expected);
        }

        if (expected.usds != address(0)) {
            _validateCollateral(manager, expected.usds, "USDS", expected.capUSDS, expected);
        }

        if (expected.usdtb != address(0)) {
            _validateCollateral(manager, expected.usdtb, "USDTb", expected.capUSDTb, expected);
        }

        if (expected.usde != address(0)) {
            _validateCollateral(manager, expected.usde, "USDe", expected.capUSDe, expected);
        }
    }

    function _validateCollateral(
        PutManager manager,
        address token,
        string memory name,
        uint256 expectedCap,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        console.log("--- Collateral:", name, "---");
        console.log("Token Address:    ", token);

        bool isRegistered = manager.isCollateral(token);
        console.log("Registered:       ", isRegistered ? "YES" : "NO");

        if (!isRegistered) {
            console.log("Status:            [ERROR] ERROR - Collateral not registered!");
            console.log("");
            return;
        }

        address wrapper = manager.vaults(token);
        uint256 cap = manager.collateralCap(token);
        uint256 supply = manager.collateralSupply(token);

        console.log("Wrapper:          ", wrapper);
        console.log("Cap:              ", _formatCap(cap));
        console.log("Expected Cap:     ", _formatCap(expectedCap));

        if (cap == expectedCap) {
            console.log("Cap Status:        [OK] CORRECT");
        } else {
            console.log("Cap Status:        [WARN] MISMATCH");
        }

        console.log("Supply:           ", supply);
        console.log("");

        // Validate wrapper configuration
        if (wrapper != address(0)) {
            _validateWrapper(wrapper, token, name, expected);
        } else {
            console.log("                   [ERROR] ERROR - No wrapper deployed!");
        }

        console.log("");
    }

    function _validateWrapper(
        address wrapperAddr,
        address token,
        string memory name,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        ftYieldWrapper wrapper = ftYieldWrapper(wrapperAddr);

        console.log("  Wrapper Roles for", name, ":");

        // Check YieldClaimer
        address currentYieldClaimer = wrapper.yieldClaimer();
        address pendingYieldClaimer = wrapper.pendingYieldClaimer();
        console.log("  YieldClaimer:");
        console.log("    Expected:       ", expected.yieldClaimer);
        console.log("    Current:        ", currentYieldClaimer);

        if (currentYieldClaimer == expected.yieldClaimer) {
            console.log("    Status:          [OK] CORRECT");
        } else if (pendingYieldClaimer == expected.yieldClaimer) {
            console.log("    Pending:        ", pendingYieldClaimer);
            console.log("    Status:          [WARN] PENDING - Needs confirmation");
            console.log(
                "    Action:          treasury OR strategyManager must call confirmYieldClaimer()"
            );
        } else {
            console.log("    Status:          [ERROR] MISMATCH");
        }

        // Check StrategyManager
        address currentStrategyManager = wrapper.strategyManager();
        address pendingStrategyManager = wrapper.pendingStrategyManager();
        console.log("  StrategyManager:");
        console.log("    Expected:       ", expected.strategyManager);
        console.log("    Current:        ", currentStrategyManager);

        if (currentStrategyManager == expected.strategyManager) {
            console.log("    Status:          [OK] CORRECT - Auto-confirmed during deployment");
        } else if (pendingStrategyManager == expected.strategyManager) {
            console.log("    Pending:        ", pendingStrategyManager);
            console.log("    Status:          [ERROR] UNEXPECTED - Should be auto-confirmed!");
            console.log(
                "    Note:            Deployment script should have confirmed this automatically"
            );
        } else {
            console.log("    Status:          [ERROR] MISMATCH");
        }

        // Check Treasury
        address currentTreasury = wrapper.treasury();
        address pendingTreasury = wrapper.pendingTreasury();
        console.log("  Treasury:");
        console.log("    Expected:       ", expected.treasury);
        console.log("    Current:        ", currentTreasury);

        if (currentTreasury == expected.treasury) {
            console.log("    Status:          [OK] CORRECT - Auto-confirmed during deployment");
        } else if (pendingTreasury == expected.treasury) {
            console.log("    Pending:        ", pendingTreasury);
            console.log("    Status:          [ERROR] UNEXPECTED - Should be auto-confirmed!");
            console.log(
                "    Note:            Deployment script should have confirmed this automatically"
            );
        } else {
            console.log("    Status:          [ERROR] MISMATCH");
        }

        // Check strategy (assuming 1 strategy per wrapper)
        uint256 numStrategies = wrapper.numberOfStrategies();
        if (numStrategies > 0) {
            address strategy = address(wrapper.strategies(0));
            bool confirmed = wrapper.isStrategy(strategy);
            console.log("  Strategy:        ", strategy);
            console.log("  Confirmed:       ", confirmed ? "YES" : "NO");
            if (!confirmed) {
                console.log("                   [WARN] WARNING - Strategy not confirmed!");
            }
        } else {
            console.log("  Strategy:         [WARN] NO STRATEGY DEPLOYED!");
        }
    }

    function _validateOracleState(
        PutManager manager,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        console.log(
            "================================================================================"
        );
        console.log("                    ORACLE VALIDATION");
        console.log(
            "================================================================================"
        );
        console.log("");

        address oracleAddr = address(manager.ftOracle());
        console.log("Oracle Address:   ", oracleAddr);

        if (oracleAddr == address(0)) {
            console.log("Status:            [ERROR] ERROR - No oracle configured!");
            console.log("");
            return;
        }

        FlyingTulipOracle oracle = FlyingTulipOracle(oracleAddr);
        address oracleMsig = oracle.msig();
        address nextOracleMsig = oracle.nextMsig();
        uint64 delayOracleMsig = oracle.delayMsig();
        address aaveOracle = oracle.getAaveOracleAddress();

        console.log("Current Msig:     ", oracleMsig);
        console.log("Expected Msig:    ", expected.msig);

        // Check oracle msig status (2-step transfer like PutManager)
        if (oracleMsig == expected.msig) {
            console.log("Msig Status:       [OK] CORRECT - Oracle ownership transferred");
        } else if (nextOracleMsig == expected.msig) {
            console.log("Next Msig:        ", nextOracleMsig);
            console.log("Delay until:      ", delayOracleMsig);
            if (block.timestamp >= delayOracleMsig) {
                console.log("Msig Status:       [WARN] PENDING - Ready to accept NOW");
                console.log("Action:            Call FlyingTulipOracle.acceptMsig() from msig");
                console.log("                   Msig address:", expected.msig);
            } else {
                uint256 waitTime = delayOracleMsig - block.timestamp;
                console.log("Wait time (sec):  ", waitTime);
                console.log("Wait time (hrs):  ", waitTime / 3600);
                console.log("Msig Status:       [WARN] PENDING - Waiting for time delay");
            }
        } else {
            console.log("Msig Status:       [ERROR] MISMATCH - Unexpected oracle msig");
            console.log("                   Current:", oracleMsig);
            console.log("                   Expected:", expected.msig);
        }

        console.log("");
        console.log("Aave Oracle:      ", aaveOracle);
        console.log("Expected:         ", expected.aaveOracle);

        if (aaveOracle == expected.aaveOracle) {
            console.log("Aave Status:       [OK] CORRECT");
        } else {
            console.log("Aave Status:       [ERROR] MISMATCH");
        }

        console.log("");
    }

    function _validateACLState(PutManager manager, ExpectedConfig memory expected) internal view {
        console.log(
            "================================================================================"
        );
        console.log("                    ACL (WHITELIST) VALIDATION");
        console.log(
            "================================================================================"
        );
        console.log("");

        address aclAddr = address(manager.ftACL());
        console.log("Expected ACL:     ", expected.disableACL ? "DISABLED" : "ENABLED");
        console.log("ACL Address:      ", aclAddr);

        if (expected.disableACL) {
            if (aclAddr == address(0)) {
                console.log("Status:            [OK] CORRECT - ACL disabled as expected");
            } else {
                console.log(
                    "Status:            [WARN] WARNING - ACL deployed but expected to be disabled"
                );
            }
        } else {
            if (aclAddr == address(0)) {
                console.log("Status:            [ERROR] ERROR - ACL not deployed but expected!");
                if (expected.isProduction) {
                    console.log(
                        "                   [WARN] CRITICAL: Production deployment without ACL!"
                    );
                }
            } else {
                ftACL acl = ftACL(aclAddr);
                bytes32 merkleRoot = acl.merkleRoot();
                console.log("Merkle Root:      ", vm.toString(merkleRoot));
                console.log("Expected Root:    ", vm.toString(expected.merkleRoot));

                if (merkleRoot == expected.merkleRoot) {
                    console.log("Status:            [OK] CORRECT");
                } else {
                    console.log("Status:            [ERROR] MISMATCH - Merkle root differs!");
                }
            }
        }

        console.log("");
    }

    function _printPendingActions(
        PutManager manager,
        ExpectedConfig memory expected,
        address circuitBreakerAddr
    )
        internal
        view
    {
        console.log(
            "================================================================================"
        );
        console.log("                    PENDING ACTIONS SUMMARY");
        console.log(
            "================================================================================"
        );
        console.log("");

        bool hasPendingActions = false;

        // Check PutManager msig
        address nextMsig = manager.nextMsig();
        uint256 actionNum = 1;
        if (nextMsig != address(0) && nextMsig == expected.msig) {
            hasPendingActions = true;
            uint64 delayMsig = manager.delayMsig();
            console.log("1. PUTMANAGER MSIG TRANSFER");
            console.log("   Action:          Call PutManager.acceptMsig()");
            console.log("   Caller:         ", expected.msig);
            console.log("   Contract:       ", address(manager));

            if (block.timestamp >= delayMsig) {
                console.log("   Status:          [OK] CAN ACCEPT NOW");
            } else {
                uint256 waitTime = delayMsig - block.timestamp;
                console.log("   Status:          Waiting", waitTime, "seconds");
            }
            console.log("");
            actionNum = 2;
        }

        // Check Oracle msig
        address oracleAddr = address(manager.ftOracle());
        if (oracleAddr != address(0)) {
            FlyingTulipOracle oracle = FlyingTulipOracle(oracleAddr);
            address nextOracleMsig = oracle.nextMsig();
            if (nextOracleMsig != address(0) && nextOracleMsig == expected.msig) {
                hasPendingActions = true;
                uint64 delayOracleMsig = oracle.delayMsig();
                console.log(string.concat(vm.toString(actionNum), ". ORACLE MSIG TRANSFER"));
                console.log("   Action:          Call FlyingTulipOracle.acceptMsig()");
                console.log("   Caller:         ", expected.msig);
                console.log("   Contract:       ", oracleAddr);

                if (block.timestamp >= delayOracleMsig) {
                    console.log("   Status:          [OK] CAN ACCEPT NOW");
                } else {
                    uint256 waitTime = delayOracleMsig - block.timestamp;
                    console.log("   Status:          Waiting", waitTime, "seconds");
                }
                console.log("");
                actionNum++;
            }
        }

        // Check CircuitBreaker ownership
        if (circuitBreakerAddr != address(0)) {
            CircuitBreaker cb = CircuitBreaker(circuitBreakerAddr);
            address cbPendingOwner = cb.pendingOwner();
            if (cbPendingOwner == expected.strategyManager) {
                hasPendingActions = true;
                console.log(string.concat(vm.toString(actionNum), ". CIRCUIT BREAKER OWNERSHIP"));
                console.log("   Action:          Call CircuitBreaker.acceptOwnership()");
                console.log("   Caller:         ", expected.strategyManager);
                console.log("   Contract:       ", circuitBreakerAddr);
                console.log("   Status:          [OK] CAN ACCEPT NOW");
                console.log("");
                actionNum++;
            }
        }

        // Check wrapper roles for all configured tokens

        if (expected.usdc != address(0)) {
            actionNum =
                _printWrapperPendingActions(manager, expected.usdc, "USDC", expected, actionNum);
        }

        if (expected.wNative != address(0)) {
            actionNum = _printWrapperPendingActions(
                manager, expected.wNative, "wNative", expected, actionNum
            );
        }

        if (expected.usdt != address(0)) {
            actionNum =
                _printWrapperPendingActions(manager, expected.usdt, "USDT", expected, actionNum);
        }

        if (expected.usds != address(0)) {
            actionNum =
                _printWrapperPendingActions(manager, expected.usds, "USDS", expected, actionNum);
        }

        if (expected.usdtb != address(0)) {
            actionNum =
                _printWrapperPendingActions(manager, expected.usdtb, "USDTb", expected, actionNum);
        }

        if (expected.usde != address(0)) {
            actionNum =
                _printWrapperPendingActions(manager, expected.usde, "USDe", expected, actionNum);
        }

        if (!hasPendingActions && actionNum == 1) {
            console.log("[OK] No pending actions - All ownership transfers complete!");
            console.log("");
            console.log("The deployment is ready for use.");
        }

        console.log("");
    }

    function _printWrapperPendingActions(
        PutManager manager,
        address token,
        string memory name,
        ExpectedConfig memory expected,
        uint256 startNum
    )
        internal
        view
        returns (uint256)
    {
        address wrapperAddr = manager.vaults(token);
        if (wrapperAddr == address(0)) return startNum;

        ftYieldWrapper wrapper = ftYieldWrapper(wrapperAddr);
        bool hasPending = false;
        uint256 actionNum = startNum;

        if (wrapper.pendingYieldClaimer() == expected.yieldClaimer) {
            console.log(string.concat(vm.toString(actionNum), ". ", name, " WRAPPER ROLES"));
            console.log("   Wrapper:        ", wrapperAddr);
            console.log("   - YieldClaimer:  Call confirmYieldClaimer()");
            console.log("     From:          treasury OR strategyManager");
            hasPending = true;
        }

        // Treasury and StrategyManager should already be confirmed during deployment
        // Only report if they're unexpectedly still pending
        if (wrapper.pendingStrategyManager() == expected.strategyManager) {
            if (!hasPending) {
                console.log(string.concat(vm.toString(actionNum), ". ", name, " WRAPPER ROLES"));
                console.log("   Wrapper:        ", wrapperAddr);
                hasPending = true;
            }
            console.log("   - StrategyMgr:   [ERROR] UNEXPECTED PENDING");
            console.log("     Note:          Should have been auto-confirmed during deployment");
        }

        if (wrapper.pendingTreasury() == expected.treasury) {
            if (!hasPending) {
                console.log(string.concat(vm.toString(actionNum), ". ", name, " WRAPPER ROLES"));
                console.log("   Wrapper:        ", wrapperAddr);
                hasPending = true;
            }
            console.log("   - Treasury:      [ERROR] UNEXPECTED PENDING");
            console.log("     Note:          Should have been auto-confirmed during deployment");
        }

        if (hasPending) {
            console.log("");
            actionNum++;
        }

        return actionNum;
    }

    /// @notice Get CircuitBreaker address from first available wrapper
    /// @dev Returns address(0) if no wrappers have a circuit breaker set
    ///      Uses try/catch for backwards compatibility with older deployments
    function _getCircuitBreakerAddress(
        PutManager manager,
        ExpectedConfig memory expected
    )
        internal
        view
        returns (address)
    {
        // Try USDC wrapper first
        if (expected.usdc != address(0)) {
            address wrapperAddr = manager.vaults(expected.usdc);
            if (wrapperAddr != address(0)) {
                try ftYieldWrapper(wrapperAddr).circuitBreaker() returns (address cbAddr) {
                    return cbAddr;
                } catch {
                    // Wrapper doesn't have circuitBreaker() - older deployment
                }
            }
        }

        // Try wNative wrapper
        if (expected.wNative != address(0)) {
            address wrapperAddr = manager.vaults(expected.wNative);
            if (wrapperAddr != address(0)) {
                try ftYieldWrapper(wrapperAddr).circuitBreaker() returns (address cbAddr) {
                    return cbAddr;
                } catch {
                    // Wrapper doesn't have circuitBreaker() - older deployment
                }
            }
        }

        // Try additional tokens
        if (expected.usdt != address(0)) {
            address wrapperAddr = manager.vaults(expected.usdt);
            if (wrapperAddr != address(0)) {
                try ftYieldWrapper(wrapperAddr).circuitBreaker() returns (address cbAddr) {
                    return cbAddr;
                } catch {
                    // Wrapper doesn't have circuitBreaker() - older deployment
                }
            }
        }

        return address(0);
    }

    function _validateCircuitBreakerState(
        address cbAddr,
        PutManager manager,
        ExpectedConfig memory expected
    )
        internal
        view
    {
        console.log(
            "================================================================================"
        );
        console.log("                    CIRCUIT BREAKER VALIDATION");
        console.log(
            "================================================================================"
        );
        console.log("");

        // CB is expected if flag is true OR if numeric params are explicitly set
        bool cbExpected = expected.deployCircuitBreaker
            || (expected.cbMaxDrawRateWad > 0
                && expected.cbMainWindow > 0
                && expected.cbElasticWindow > 0);

        console.log("Expected CB:      ", cbExpected ? "ENABLED" : "DISABLED");
        console.log("CB Address:       ", cbAddr);

        // Case 1: CB disabled in config
        if (!cbExpected) {
            if (cbAddr == address(0)) {
                console.log("Status:            [OK] CORRECT - CB disabled as expected");
            } else {
                console.log("Status:            [WARN] WARNING - CB deployed but expected disabled");
            }
            console.log("");
            return;
        }

        // Case 2: CB expected but not deployed
        if (cbAddr == address(0)) {
            console.log("Status:            [ERROR] ERROR - CB expected but not found on wrappers!");
            console.log("");
            return;
        }

        // Case 3: Validate CB configuration
        CircuitBreaker cb = CircuitBreaker(cbAddr);

        // Check config
        (uint64 maxDrawRate, uint48 mainWindow, uint48 elasticWindow) = cb.config();

        console.log("--- Configuration ---");
        console.log("Max Draw Rate:");
        console.log("  Expected:       ", expected.cbMaxDrawRateWad, " (WAD)");
        console.log("  Actual:         ", maxDrawRate, " (WAD)");
        if (maxDrawRate == expected.cbMaxDrawRateWad) {
            console.log("  Status:          [OK] CORRECT");
        } else {
            console.log("  Status:          [ERROR] MISMATCH");
        }

        console.log("Main Window:");
        console.log("  Expected:       ", expected.cbMainWindow, " seconds");
        console.log("  Actual:         ", mainWindow, " seconds");
        if (mainWindow == expected.cbMainWindow) {
            console.log("  Status:          [OK] CORRECT");
        } else {
            console.log("  Status:          [ERROR] MISMATCH");
        }

        console.log("Elastic Window:");
        console.log("  Expected:       ", expected.cbElasticWindow, " seconds");
        console.log("  Actual:         ", elasticWindow, " seconds");
        if (elasticWindow == expected.cbElasticWindow) {
            console.log("  Status:          [OK] CORRECT");
        } else {
            console.log("  Status:          [ERROR] MISMATCH");
        }
        console.log("");

        // Check ownership
        console.log("--- Ownership ---");
        address cbOwner = cb.owner();
        address cbPendingOwner = cb.pendingOwner();
        console.log("Expected Owner:   ", expected.strategyManager);
        console.log("Current Owner:    ", cbOwner);

        if (cbOwner == expected.strategyManager) {
            console.log("Status:            [OK] CORRECT - Ownership transferred");
        } else if (cbPendingOwner == expected.strategyManager) {
            console.log("Pending Owner:    ", cbPendingOwner);
            console.log("Status:            [WARN] PENDING - Needs acceptOwnership()");
            console.log(
                "Action:            strategy_manager must call CircuitBreaker.acceptOwnership()"
            );
        } else {
            console.log("Status:            [ERROR] MISMATCH - Unexpected owner");
        }
        console.log("");

        // Check pause state
        console.log("--- State ---");
        bool isPaused = cb.paused();
        console.log("Paused:           ", isPaused ? "YES" : "NO");
        if (isPaused) {
            console.log(
                "                   [WARN] WARNING: CB is paused - all withdrawals allowed!"
            );
        }
        console.log("");

        // Validate wrapper registrations
        console.log("--- Protected Contracts ---");
        _validateWrapperCBRegistration(manager, expected.usdc, "USDC", cb);
        _validateWrapperCBRegistration(manager, expected.wNative, "wNative", cb);
        _validateWrapperCBRegistration(manager, expected.usdt, "USDT", cb);
        _validateWrapperCBRegistration(manager, expected.usds, "USDS", cb);
        _validateWrapperCBRegistration(manager, expected.usdtb, "USDTb", cb);
        _validateWrapperCBRegistration(manager, expected.usde, "USDe", cb);

        console.log("");
    }

    function _validateWrapperCBRegistration(
        PutManager manager,
        address token,
        string memory name,
        CircuitBreaker cb
    )
        internal
        view
    {
        if (token == address(0)) return;

        address wrapperAddr = manager.vaults(token);
        if (wrapperAddr == address(0)) return;

        ftYieldWrapper wrapper = ftYieldWrapper(wrapperAddr);

        // Check 1: Wrapper is registered as protected contract in CB
        bool isProtected = cb.protectedContracts(wrapperAddr);

        // Check 2: Wrapper has CB address set (use try/catch for backwards compatibility)
        address wrapperCB;
        try wrapper.circuitBreaker() returns (address cbAddr) {
            wrapperCB = cbAddr;
        } catch {
            // Older wrapper deployment without circuitBreaker() function
            wrapperCB = address(0);
        }

        console.log(name, "Wrapper (", wrapperAddr, "):");

        if (isProtected && wrapperCB == address(cb)) {
            console.log("  Status:          [OK] CORRECT - Registered and configured");
        } else {
            if (!isProtected) {
                console.log("  Protected:       [ERROR] NOT REGISTERED in CB");
            } else {
                console.log("  Protected:       [OK] Registered");
            }

            if (wrapperCB != address(cb)) {
                console.log("  Wrapper CB:      [ERROR] MISMATCH");
                console.log("    Expected:     ", address(cb));
                console.log("    Actual:       ", wrapperCB);
            } else {
                console.log("  Wrapper CB:      [OK] Correct");
            }
        }
    }

    function _formatCap(uint256 cap) internal pure returns (string memory) {
        if (cap == 0 || cap == type(uint256).max) {
            return "UNLIMITED";
        }
        return vm.toString(cap);
    }
}
