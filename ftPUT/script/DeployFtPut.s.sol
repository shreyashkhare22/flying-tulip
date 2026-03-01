// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftACL} from "contracts/ftACL.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {AaveStrategy} from "contracts/strategies/AaveStrategy.sol";
import {FlyingTulipOracle} from "contracts/FlyingTulipOracle.sol";
import {CircuitBreaker} from "contracts/cb/CircuitBreaker.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MerkleHelper} from "../test/helpers/MerkleHelper.sol";

/// @dev Interfaces for querying FT token state
interface IPausable {
    function paused() external view returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
}

interface IERC20Metadata {
    function name() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IFTToken {
    function configurator() external view returns (address);
}

/// Multi-network deployment using config files
///
/// Configuration is loaded from: script/config/deployments.toml
/// Sensitive data (RPC URLs, API keys, private keys) in: .env
///
/// Usage with keystore (RECOMMENDED for production):
///   forge script script/DeployFtPut.s.sol:DeployFtPut \
///     --rpc-url $RPC_URL \
///     --account <keystore-account-name> \
///     --sender <address> \
///     --broadcast \
///     --verify \
///     -vvv
///
/// Usage with private key (NOT RECOMMENDED for production):
///   forge script script/DeployFtPut.s.sol:DeployFtPut \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     -vvv
///
/// The script automatically detects the chain ID and loads the appropriate
/// configuration from deployments.toml. Currently supported networks:
///   - 146: Sonic Mainnet
///   - 64165: Sonic Testnet
///   - 11155111: Sepolia Testnet
///   - 31337: Local/Anvil
///  NOTE: to add new networks, update the deployments.toml file
contract DeployFtPut is Script {
    error UnsupportedChain();
    error InvalidConfiguration(string reason);

    string internal constant CONFIG_PATH = "script/config/deployments.toml";

    // Circuit Breaker recommended defaults (from spec)
    // 5% max draw rate, 4h main window, 2h elastic window
    uint256 internal constant CB_MAX_DRAW_RATE_WAD = 5e16; // 5% (50000000000000000)
    uint256 internal constant CB_MAIN_WINDOW = 14400; // 4 hours
    uint256 internal constant CB_ELASTIC_WINDOW = 7200; // 2 hours

    struct Config {
        // Tokens
        address ft;
        address usdc;
        address wNative;
        // Additional tokens (optional, all use AaveStrategy)
        address usdt;
        address usds;
        address usdtb;
        address usde;
        // Aave
        address aavePoolProvider;
        address aaveOracle;
        address aaveAUSDC;
        address aaveAWNative;
        // Aave aTokens for additional tokens
        address aaveAUSDT;
        address aaveAUSDS;
        address aaveAUSDTb;
        address aaveAUSDe;
        // Roles
        address msig;
        address configurator;
        address treasury;
        address yieldClaimer;
        address strategyManager;
        // Caps
        uint256 capUSDC;
        uint256 capWNative;
        uint256 capUSDT;
        uint256 capUSDS;
        uint256 capUSDTb;
        uint256 capUSDe;
        uint256 initialFTSupply;
        // ACL
        bool disableACL;
        bytes32 merkleRoot;
        // Metadata
        bool isProduction;
        // Circuit Breaker
        bool deployCircuitBreaker;
        uint256 cbMaxDrawRateWad; // 0 = use default (5%)
        uint256 cbMainWindow; // 0 = use default (4 hours)
        uint256 cbElasticWindow; // 0 = use default (2 hours)
    }

    struct DeploymentArtifacts {
        address ftToken;
        bool deployedMockFT;
        address ftOracle;
        address pftImplementation;
        address pftProxy;
        address putManagerImplementation;
        address putManagerProxy;
        address acl;
        address wrapperUSDC;
        address wrapperWNative;
        address strategyUSDC;
        address strategyWNative;
        // Additional token wrappers and strategies
        address wrapperUSDT;
        address wrapperUSDS;
        address wrapperUSDTb;
        address wrapperUSDe;
        address strategyUSDT;
        address strategyUSDS;
        address strategyUSDTb;
        address strategyUSDe;
        // Circuit Breaker
        address circuitBreaker;
    }

    function run() external {
        // Determine deployment method:
        // - If PRIVATE_KEY env is set: use it (for testing/development)
        // - Otherwise: use keystore via --account flag (production, msg.sender is set by foundry)
        address deployer;
        bool usePrivateKey = false;
        uint256 pk;

        try vm.envUint("PRIVATE_KEY") returns (uint256 privateKey) {
            // PRIVATE_KEY is set - use it
            pk = privateKey;
            deployer = vm.addr(pk);
            usePrivateKey = true;
            console.log("Using PRIVATE_KEY from environment variable");
            console.log("Deployer address:", deployer);
        } catch {
            // No PRIVATE_KEY - use keystore (default, recommended for production)
            deployer = msg.sender;
            console.log("Using keystore account (--account flag required)");
            console.log("Deployer address:", deployer);
        }

        // Load configuration from deployments.toml
        Config memory cfg = _loadConfig(deployer);
        _validateConfig(cfg);

        // Determine deployment flags
        bool willDeployMockFT = (cfg.ft == address(0));
        bool willDeployACL = !cfg.disableACL && cfg.merkleRoot != bytes32(0);

        _printDeploymentConfigSummary(cfg, deployer, usePrivateKey, willDeployMockFT, willDeployACL);

        // Prompt for confirmation with an option to inspect configuration again
        string memory promptMessage =
            "Type 'y' to continue deployment or 'p' to review config summary and exit, or anything else to abort:";
        string memory confirmation = vm.prompt(promptMessage);

        bytes32 yesHash = keccak256(abi.encodePacked("y"));
        bytes32 printHash = keccak256(abi.encodePacked("p"));
        bytes32 answerHash = keccak256(abi.encodePacked(confirmation));

        if (answerHash == printHash) {
            console.log("");
            console.log("Reprinting deployment configuration summary (deployment aborted)...");
            _printDeploymentConfigSummary(
                cfg, deployer, usePrivateKey, willDeployMockFT, willDeployACL
            );
            revert("User requested config summary");
        }

        if (answerHash != yesHash) {
            console.log("");
            console.log("Deployment cancelled by user.");
            revert("User cancelled deployment");
        }

        console.log("Starting deployment...");
        console.log("");

        DeploymentArtifacts memory art =
            _startDeployment(cfg, deployer, usePrivateKey, pk, willDeployMockFT, willDeployACL);

        _finishDeploymentSummary(cfg, art, deployer);
    }

    /// @notice Load configuration from deployments.toml for current chain
    function _loadConfig(address deployer) internal view returns (Config memory cfg) {
        uint256 chainId = block.chainid;
        string memory chainIdStr = vm.toString(chainId);
        string memory raw = vm.readFile(CONFIG_PATH);

        // Load addresses
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

        // Load additional tokens (optional - use try/catch to handle missing keys)
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

        // Load additional aTokens (optional)
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausdt")
        ) returns (
            address _aaveAUSDT
        ) {
            cfg.aaveAUSDT = _aaveAUSDT;
        } catch {}
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausds")
        ) returns (
            address _aaveAUSDS
        ) {
            cfg.aaveAUSDS = _aaveAUSDS;
        } catch {}
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausdtb")
        ) returns (
            address _aaveAUSDTb
        ) {
            cfg.aaveAUSDTb = _aaveAUSDTb;
        } catch {}
        try vm.parseTomlAddress(
            raw, string.concat(".", chainIdStr, ".address.aave_ausde")
        ) returns (
            address _aaveAUSDe
        ) {
            cfg.aaveAUSDe = _aaveAUSDe;
        } catch {}

        // Load roles (use deployer if address is 0x0)
        address msig = vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.msig"));
        cfg.msig = msig == address(0) ? deployer : msig;

        address configurator =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.configurator"));
        cfg.configurator = configurator == address(0) ? deployer : configurator;

        address treasury =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.treasury"));
        cfg.treasury = treasury == address(0) ? deployer : treasury;

        address yieldClaimer =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.yield_claimer"));
        cfg.yieldClaimer = yieldClaimer == address(0) ? deployer : yieldClaimer;

        address strategyManager =
            vm.parseTomlAddress(raw, string.concat(".", chainIdStr, ".address.strategy_manager"));
        cfg.strategyManager = strategyManager == address(0) ? deployer : strategyManager;

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

        // Load additional token caps (optional)
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

        // Load circuit breaker config (optional - defaults to false/0)
        try vm.parseTomlBool(
            raw, string.concat(".", chainIdStr, ".bool.deploy_circuit_breaker")
        ) returns (
            bool _deployCircuitBreaker
        ) {
            cfg.deployCircuitBreaker = _deployCircuitBreaker;
        } catch {}

        // CB parameters (optional - 0 means use defaults)
        try vm.parseTomlUint(
            raw, string.concat(".", chainIdStr, ".uint.cb_max_draw_rate_wad")
        ) returns (
            uint256 _val
        ) {
            cfg.cbMaxDrawRateWad = _val;
        } catch {}

        try vm.parseTomlUint(raw, string.concat(".", chainIdStr, ".uint.cb_main_window")) returns (
            uint256 _val
        ) {
            cfg.cbMainWindow = _val;
        } catch {}

        try vm.parseTomlUint(
            raw, string.concat(".", chainIdStr, ".uint.cb_elastic_window")
        ) returns (
            uint256 _val
        ) {
            cfg.cbElasticWindow = _val;
        } catch {}

        // Load bytes32
        cfg.merkleRoot =
            vm.parseTomlBytes32(raw, string.concat(".", chainIdStr, ".bytes32.merkle_root"));
    }

    function _validateConfig(Config memory cfg) internal pure {
        // Require at least one collateral token
        if (cfg.usdc == address(0) && cfg.wNative == address(0)) {
            revert InvalidConfiguration("at least one collateral required (usdc or wNative)");
        }

        // Validate USDC configuration (USDC is now optional)
        if (cfg.usdc != address(0)) {
            // If USDC is provided, aaveAUSDC must also be provided
            if (cfg.aaveAUSDC == address(0)) {
                revert InvalidConfiguration("aave_ausdc is zero");
            }
        } else {
            // If USDC is disabled, aaveAUSDC should not be set
            if (cfg.aaveAUSDC != address(0)) {
                revert InvalidConfiguration("ausdc provided while usdc disabled");
            }
        }

        // Validate wNative configuration
        if (cfg.wNative == address(0)) {
            if (cfg.aaveAWNative != address(0)) {
                revert InvalidConfiguration("awnative provided while wNative disabled");
            }
        } else if (cfg.aaveAWNative == address(0)) {
            revert InvalidConfiguration("awnative address is zero");
        }

        // Validate additional token configurations (optional tokens)
        if (cfg.usdt != address(0)) {
            if (cfg.aaveAUSDT == address(0)) {
                revert InvalidConfiguration("aave_ausdt is zero");
            }
        } else if (cfg.aaveAUSDT != address(0)) {
            revert InvalidConfiguration("ausdt provided while usdt disabled");
        }

        if (cfg.usds != address(0)) {
            if (cfg.aaveAUSDS == address(0)) {
                revert InvalidConfiguration("aave_ausds is zero");
            }
        } else if (cfg.aaveAUSDS != address(0)) {
            revert InvalidConfiguration("ausds provided while usds disabled");
        }

        if (cfg.usdtb != address(0)) {
            if (cfg.aaveAUSDTb == address(0)) {
                revert InvalidConfiguration("aave_ausdtb is zero");
            }
        } else if (cfg.aaveAUSDTb != address(0)) {
            revert InvalidConfiguration("ausdtb provided while usdtb disabled");
        }

        if (cfg.usde != address(0)) {
            if (cfg.aaveAUSDe == address(0)) {
                revert InvalidConfiguration("aave_ausde is zero");
            }
        } else if (cfg.aaveAUSDe != address(0)) {
            revert InvalidConfiguration("ausde provided while usde disabled");
        }

        if (cfg.aavePoolProvider == address(0)) {
            revert InvalidConfiguration("aave_pool_provider is zero");
        }
        if (cfg.aaveOracle == address(0)) revert InvalidConfiguration("aave_oracle is zero");

        // Validate initial_ft_supply conditionally
        // For mock FT deployments, initial_ft_supply is required (used to mint and add liquidity)
        // For real FT deployments, initial_ft_supply is optional (liquidity is added manually)
        if (cfg.ft == address(0) && cfg.initialFTSupply == 0) {
            revert InvalidConfiguration("initial_ft_supply required for mock FT deployment");
        }

        if (cfg.yieldClaimer == address(0)) revert InvalidConfiguration("yield_claimer is zero");
        if (cfg.strategyManager == address(0)) {
            revert InvalidConfiguration("strategy_manager is zero");
        }
        if (cfg.treasury == address(0)) revert InvalidConfiguration("treasury is zero");
    }

    function _formatCap(uint256 cap) internal pure returns (string memory) {
        if (cap == 0 || cap == type(uint256).max) {
            return "UNLIMITED";
        }
        return Strings.toString(cap);
    }

    function _printDeploymentConfigSummary(
        Config memory cfg,
        address deployer,
        bool usePrivateKey,
        bool willDeployMockFT,
        bool willDeployACL
    )
        internal
        view
    {
        console.log("");
        console.log(
            "================================================================================"
        );
        console.log("                    DEPLOYMENT CONFIGURATION SUMMARY");
        console.log(
            "================================================================================"
        );
        console.log("");
        console.log("Chain ID:        ", block.chainid);
        console.log("Config Source: ", CONFIG_PATH);
        console.log("Deployer:        ", deployer);
        console.log(
            "Auth Method:     ",
            usePrivateKey ? "PRIVATE_KEY (NOT RECOMMENDED)" : "Keystore (Recommended)"
        );
        console.log("Environment:     ", cfg.isProduction ? "PRODUCTION" : "TESTNET/DEV");
        console.log("");
        console.log("--- Roles ---");
        console.log("MSIG:            ", cfg.msig);
        console.log("Configurator:    ", cfg.configurator);
        console.log("Treasury:        ", cfg.treasury);
        console.log("Yield Claimer:   ", cfg.yieldClaimer);
        console.log("Strategy Manager:", cfg.strategyManager);
        console.log("");
        console.log("--- Tokens ---");
        if (willDeployMockFT) {
            console.log("FT Token:         WILL DEPLOY MOCK (config ft address is 0x0)");
        } else {
            console.log("FT Token:        ", cfg.ft);
            // Query FT token state
            try IERC20(cfg.ft).balanceOf(address(0)) returns (uint256) {
                // Token exists, check metadata and state
                try IERC20Metadata(cfg.ft).name() returns (string memory _name) {
                    console.log("  Name:          ", _name);
                } catch {
                    console.log("  Name:           N/A");
                }

                try IERC20Metadata(cfg.ft).decimals() returns (uint8 _decimals) {
                    console.log("  Decimals:      ", _decimals);
                } catch {
                    console.log("  Decimals:       N/A");
                }

                try IPausable(cfg.ft).paused() returns (bool _paused) {
                    console.log("  Paused:        ", _paused ? "YES" : "NO");
                } catch {
                    console.log("  Paused:         N/A (token does not implement paused())");
                }

                try IOwnable(cfg.ft).owner() returns (address _owner) {
                    console.log("  Owner:         ", _owner);
                } catch {
                    console.log("  Owner:          N/A (token does not implement owner())");
                }

                // Check FT token's configurator (who has the FT supply)
                console.log("");
                console.log("  FT Token Configurator (will add liquidity post-deployment):");
                try IFTToken(cfg.ft).configurator() returns (address ftConfigurator) {
                    console.log("    Address:     ", ftConfigurator);
                    try IERC20(cfg.ft).balanceOf(ftConfigurator) returns (uint256 balance) {
                        console.log("    FT Balance:  ", balance);
                        console.log("    Required:    ", cfg.initialFTSupply);
                        if (balance < cfg.initialFTSupply) {
                            console.log("    WARNING: Insufficient FT balance!");
                            uint256 shortfall = cfg.initialFTSupply - balance;
                            console.log("    Shortfall:   ", shortfall);
                        } else {
                            console.log("    Status:       Sufficient balance");
                        }
                    } catch {
                        console.log("    FT Balance:   Could not query");
                    }
                } catch {
                    console.log("    Could not query FT token configurator()");
                }

                console.log("");
                console.log("  NOTE: FT token configurator (ft.configurator()) must manually");
                console.log("        call PutManager.addFTLiquidity() after deployment completes");
            } catch {
                console.log("  Warning: Could not query FT token state (token may not exist yet)");
            }
        }
        console.log(
            "USDC:            ", cfg.usdc == address(0) ? "DISABLED" : vm.toString(cfg.usdc)
        );
        console.log(
            "Wrapped Native:  ", cfg.wNative == address(0) ? "DISABLED" : vm.toString(cfg.wNative)
        );
        console.log(
            "USDT:            ", cfg.usdt == address(0) ? "DISABLED" : vm.toString(cfg.usdt)
        );
        console.log(
            "USDS:            ", cfg.usds == address(0) ? "DISABLED" : vm.toString(cfg.usds)
        );
        console.log(
            "USDTb:           ", cfg.usdtb == address(0) ? "DISABLED" : vm.toString(cfg.usdtb)
        );
        console.log(
            "USDe:            ", cfg.usde == address(0) ? "DISABLED" : vm.toString(cfg.usde)
        );
        console.log("");
        console.log("--- Aave Protocol ---");
        console.log("Pool Provider:   ", cfg.aavePoolProvider);
        console.log("Oracle:          ", cfg.aaveOracle);
        console.log(
            "aUSDC:           ", cfg.usdc == address(0) ? "DISABLED" : vm.toString(cfg.aaveAUSDC)
        );
        console.log(
            "aWNative:        ",
            cfg.wNative == address(0) ? "DISABLED" : vm.toString(cfg.aaveAWNative)
        );
        console.log(
            "aUSDT:           ", cfg.usdt == address(0) ? "DISABLED" : vm.toString(cfg.aaveAUSDT)
        );
        console.log(
            "aUSDS:           ", cfg.usds == address(0) ? "DISABLED" : vm.toString(cfg.aaveAUSDS)
        );
        console.log(
            "aUSDTb:          ", cfg.usdtb == address(0) ? "DISABLED" : vm.toString(cfg.aaveAUSDTb)
        );
        console.log(
            "aUSDe:           ", cfg.usde == address(0) ? "DISABLED" : vm.toString(cfg.aaveAUSDe)
        );
        console.log("");
        console.log("--- Collateral Caps ---");
        console.log(
            "USDC Cap:        ", cfg.usdc == address(0) ? "DISABLED" : _formatCap(cfg.capUSDC)
        );
        console.log(
            "WNative Cap:     ", cfg.wNative == address(0) ? "DISABLED" : _formatCap(cfg.capWNative)
        );
        console.log(
            "USDT Cap:        ", cfg.usdt == address(0) ? "DISABLED" : _formatCap(cfg.capUSDT)
        );
        console.log(
            "USDS Cap:        ", cfg.usds == address(0) ? "DISABLED" : _formatCap(cfg.capUSDS)
        );
        console.log(
            "USDTb Cap:       ", cfg.usdtb == address(0) ? "DISABLED" : _formatCap(cfg.capUSDTb)
        );
        console.log(
            "USDe Cap:        ", cfg.usde == address(0) ? "DISABLED" : _formatCap(cfg.capUSDe)
        );
        console.log("");
        console.log("--- Offering Configuration ---");
        console.log("Initial FT Supply:", cfg.initialFTSupply);
        console.log("");
        console.log("--- ACL / Whitelist ---");
        if (willDeployACL) {
            console.log("ACL:              ENABLED");
            console.log("Merkle Root:     ", vm.toString(cfg.merkleRoot));
        } else if (cfg.disableACL) {
            console.log("ACL:              DISABLED (config disable_acl=true)");
        } else {
            console.log("ACL:              DISABLED (merkle root is zero)");
            if (cfg.isProduction) {
                console.log("WARNING: Production deployment without ACL/whitelist!");
            }
        }
        console.log("");
        console.log("--- Circuit Breaker ---");
        if (cfg.deployCircuitBreaker) {
            uint256 maxDrawRate =
                cfg.cbMaxDrawRateWad > 0 ? cfg.cbMaxDrawRateWad : CB_MAX_DRAW_RATE_WAD;
            uint256 mainWindow = cfg.cbMainWindow > 0 ? cfg.cbMainWindow : CB_MAIN_WINDOW;
            uint256 elasticWindow =
                cfg.cbElasticWindow > 0 ? cfg.cbElasticWindow : CB_ELASTIC_WINDOW;
            bool usingDefaults =
                cfg.cbMaxDrawRateWad == 0 && cfg.cbMainWindow == 0 && cfg.cbElasticWindow == 0;

            console.log(
                "CircuitBreaker:   ENABLED", usingDefaults ? "(using defaults)" : "(custom config)"
            );
            console.log("  Max Draw Rate: ", maxDrawRate, "(WAD)");
            console.log("  Main Window:   ", mainWindow, "seconds");
            console.log("  Elastic Window:", elasticWindow, "seconds");
            console.log("  Owner:          strategy_manager (after acceptOwnership)");
        } else {
            console.log("CircuitBreaker:   DISABLED");
        }
        console.log("");
        console.log("--- Warnings & Required Actions ---");

        if (cfg.isProduction && cfg.merkleRoot == bytes32(0) && !cfg.disableACL) {
            console.log("CRITICAL WARNING: Merkle root is 0x0 for PRODUCTION deployment!");
            console.log(
                "                  Update deployments.toml [",
                vm.toString(block.chainid),
                "].bytes32.merkle_root"
            );
            console.log("                  or set disable_acl=true if no whitelist is intended");
        }

        if (deployer != cfg.msig) {
            console.log("WARNING: Deployer != MSIG");
            console.log("         Post-deployment: MSIG must call PutManager.acceptMsig()");
        }
        if (usePrivateKey && cfg.isProduction) {
            console.log("WARNING: Using PRIVATE_KEY for PRODUCTION deployment!");
            console.log(
                "         This is NOT RECOMMENDED. Use --account flag with keystore instead."
            );
        }
        if (!willDeployMockFT && cfg.initialFTSupply == 0) {
            console.log("WARNING: initial_ft_supply is 0 for real FT deployment");
            console.log("         FT liquidity must be added manually post-deployment");
            console.log("         Ensure this is intentional");
        }
        console.log("");
        console.log(
            "================================================================================"
        );
        console.log("");
    }

    function _startDeployment(
        Config memory cfg,
        address deployer,
        bool usePrivateKey,
        uint256 pk,
        bool willDeployMockFT,
        bool willDeployACL
    )
        internal
        returns (DeploymentArtifacts memory art)
    {
        if (usePrivateKey) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }
        art = _deployCore(cfg, deployer, willDeployMockFT, willDeployACL);
        vm.stopBroadcast();
    }

    function _finishDeploymentSummary(
        Config memory cfg,
        DeploymentArtifacts memory art,
        address deployer
    )
        internal
        view
    {
        PutManager managerSummary = PutManager(art.putManagerProxy);

        console.log("");
        console.log(
            "================================================================================"
        );
        console.log("                         DEPLOYMENT SUMMARY");
        console.log(
            "================================================================================"
        );
        console.log("");
        console.log("Chain ID:        ", block.chainid);
        console.log("Deployer:        ", deployer);
        console.log("");
        console.log("--- Deployed Contracts ---");
        console.log("FT Token:        ", art.ftToken);
        console.log("Mock FT Deployed:", art.deployedMockFT ? "YES" : "NO");
        console.log("pFT Impl:        ", art.pftImplementation);
        console.log("pFT Proxy:       ", art.pftProxy);
        console.log("PutManager Impl: ", art.putManagerImplementation);
        console.log("PutManager Proxy:", art.putManagerProxy);
        console.log("ACL:             ", art.acl);
        console.log("FT Oracle:       ", art.ftOracle);
        console.log("");
        console.log("--- Wrappers ---");
        console.log(
            "USDC Wrapper:    ",
            art.wrapperUSDC == address(0) ? "DISABLED" : vm.toString(art.wrapperUSDC)
        );
        console.log(
            "WNative Wrapper: ",
            art.wrapperWNative == address(0) ? "DISABLED" : vm.toString(art.wrapperWNative)
        );
        console.log(
            "USDT Wrapper:    ",
            art.wrapperUSDT == address(0) ? "DISABLED" : vm.toString(art.wrapperUSDT)
        );
        console.log(
            "USDS Wrapper:    ",
            art.wrapperUSDS == address(0) ? "DISABLED" : vm.toString(art.wrapperUSDS)
        );
        console.log(
            "USDTb Wrapper:   ",
            art.wrapperUSDTb == address(0) ? "DISABLED" : vm.toString(art.wrapperUSDTb)
        );
        console.log(
            "USDe Wrapper:    ",
            art.wrapperUSDe == address(0) ? "DISABLED" : vm.toString(art.wrapperUSDe)
        );
        console.log("");
        console.log("--- Strategies ---");
        console.log(
            "USDC Strategy:   ",
            art.strategyUSDC == address(0) ? "DISABLED" : vm.toString(art.strategyUSDC)
        );
        console.log(
            "WNative Strategy:",
            art.strategyWNative == address(0) ? "DISABLED" : vm.toString(art.strategyWNative)
        );
        console.log(
            "USDT Strategy:   ",
            art.strategyUSDT == address(0) ? "DISABLED" : vm.toString(art.strategyUSDT)
        );
        console.log(
            "USDS Strategy:   ",
            art.strategyUSDS == address(0) ? "DISABLED" : vm.toString(art.strategyUSDS)
        );
        console.log(
            "USDTb Strategy:  ",
            art.strategyUSDTb == address(0) ? "DISABLED" : vm.toString(art.strategyUSDTb)
        );
        console.log(
            "USDe Strategy:   ",
            art.strategyUSDe == address(0) ? "DISABLED" : vm.toString(art.strategyUSDe)
        );
        console.log("");
        console.log("--- Circuit Breaker ---");
        if (art.circuitBreaker != address(0)) {
            console.log("CircuitBreaker:  ", art.circuitBreaker);
            // Read actual values from deployed contract
            (uint64 maxDrawRate, uint48 mainWindow, uint48 elasticWindow) =
                CircuitBreaker(art.circuitBreaker).config();
            console.log("  Max Draw Rate: ", maxDrawRate, "(WAD)");
            console.log("  Main Window:   ", mainWindow, "seconds");
            console.log("  Elastic Window:", elasticWindow, "seconds");
        } else {
            console.log("CircuitBreaker:   DISABLED");
        }
        console.log("");
        console.log("--- Configuration ---");
        console.log("MSIG:            ", cfg.msig);
        console.log("Configurator:    ", cfg.configurator);
        console.log("Treasury:        ", cfg.treasury);
        console.log("Yield Claimer:   ", cfg.yieldClaimer);
        console.log("Strategy Manager:", cfg.strategyManager);
        console.log("");
        console.log("Offering Supply: ", managerSummary.ftOfferingSupply());
        console.log("");

        // Post-deployment actions section
        bool needsCBOwnershipTransfer =
            art.circuitBreaker != address(0) && cfg.strategyManager != deployer;
        bool needsPostDeployment = (cfg.msig != deployer) || (cfg.configurator != deployer)
            || (cfg.yieldClaimer != deployer) || (cfg.strategyManager != deployer)
            || (cfg.treasury != deployer) || needsCBOwnershipTransfer;

        if (needsPostDeployment) {
            console.log(
                "================================================================================"
            );
            console.log("                    POST-DEPLOYMENT ACTIONS REQUIRED");
            console.log(
                "================================================================================"
            );
            console.log("");

            // MSIG Actions
            if (cfg.msig != deployer) {
                console.log("--- MULTISIG (", cfg.msig, ") ---");
                console.log("1. Wait for time delay to expire (check PutManager.delayMsig())");
                console.log("2. Call: PutManager.acceptMsig()");
                console.log("   Contract:", art.putManagerProxy);
                console.log("");
            }

            // Circuit Breaker ownership transfer
            if (needsCBOwnershipTransfer) {
                console.log("--- CIRCUIT BREAKER OWNERSHIP ---");
                console.log("Strategy Manager (", cfg.strategyManager, ") must call:");
                console.log("  CircuitBreaker.acceptOwnership()");
                console.log("  Contract:", art.circuitBreaker);
                console.log("");
            }

            // Wrapper confirmations
            if (cfg.yieldClaimer != deployer) {
                console.log("--- WRAPPER ROLE CONFIRMATIONS ---");
                console.log(
                    "NOTE: Treasury and StrategyManager transfers completed automatically during deployment"
                );
                console.log("      Only YieldClaimer requires post-deployment confirmation");
                console.log("");

                console.log("YieldClaimer Transfer (pending:", cfg.yieldClaimer, ")");
                if (art.wrapperUSDC != address(0)) {
                    console.log(
                        "  - Treasury OR StrategyManager must call: wrapperUSDC.confirmYieldClaimer()"
                    );
                    console.log("    USDC Wrapper:", art.wrapperUSDC);
                }
                if (art.wrapperWNative != address(0)) {
                    console.log(
                        "  - Treasury OR StrategyManager must call: wrapperWNative.confirmYieldClaimer()"
                    );
                    console.log("    WNative Wrapper:", art.wrapperWNative);
                }
                if (art.wrapperUSDT != address(0)) {
                    console.log(
                        "  - Treasury OR StrategyManager must call: wrapperUSDT.confirmYieldClaimer()"
                    );
                    console.log("    USDT Wrapper:", art.wrapperUSDT);
                }
                if (art.wrapperUSDS != address(0)) {
                    console.log(
                        "  - Treasury OR StrategyManager must call: wrapperUSDS.confirmYieldClaimer()"
                    );
                    console.log("    USDS Wrapper:", art.wrapperUSDS);
                }
                if (art.wrapperUSDTb != address(0)) {
                    console.log(
                        "  - Treasury OR StrategyManager must call: wrapperUSDTb.confirmYieldClaimer()"
                    );
                    console.log("    USDTb Wrapper:", art.wrapperUSDTb);
                }
                if (art.wrapperUSDe != address(0)) {
                    console.log(
                        "  - Treasury OR StrategyManager must call: wrapperUSDe.confirmYieldClaimer()"
                    );
                    console.log("    USDe Wrapper:", art.wrapperUSDe);
                }
                console.log("");
            }

            console.log(
                "================================================================================"
            );
            console.log("");
        }

        console.log(
            "================================================================================"
        );
        console.log("");
    }

    function _deployCore(
        Config memory cfg,
        address deployer,
        bool willDeployMockFT,
        bool willDeployACL
    )
        internal
        returns (DeploymentArtifacts memory art)
    {
        // 1) FT token to be sold during the offering
        address FT_ADDR = cfg.ft;
        MockERC20 FT;
        bool deployedMockFT;
        if (willDeployMockFT) {
            FT = new MockERC20("Flying Tulip Test", "FTT", 18);
            FT_ADDR = address(FT);
            deployedMockFT = true;
        }
        art.ftToken = FT_ADDR;
        art.deployedMockFT = deployedMockFT;

        // 2) Deploy FlyingTulipOracle (wraps Aave Oracle and holds ftPerUSD + bounds)
        FlyingTulipOracle ftOracle = new FlyingTulipOracle(cfg.aaveOracle);
        art.ftOracle = address(ftOracle);

        // 3) Deploy pFT implementation and ERC1967Proxy; initialize atomically to DEPLOYER
        //    (will transfer to msig at end after all setup is complete)
        pFT pftImpl = new pFT();
        art.pftImplementation = address(pftImpl);
        bytes memory pftInit = abi.encodeWithSelector(pFT.initialize.selector, deployer);
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), pftInit);
        pFT PFT = pFT(address(pftProxy));
        art.pftProxy = address(PFT);

        // 4) Deploy PutManager (wire FT, pFT); initialize with DEPLOYER as both configurator and msig
        //    (will transfer roles at end after all setup is complete)
        PutManager impl = new PutManager(FT_ADDR, address(PFT));
        art.putManagerImplementation = address(impl);
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, deployer, deployer, address(ftOracle)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        PutManager manager = PutManager(address(proxy));
        art.putManagerProxy = address(manager);

        // 5) Deploy ACL if needed and set it immediately (deployer is msig at this point)
        ftACL acl;
        if (willDeployACL) {
            acl = new ftACL(cfg.merkleRoot, address(manager));
            art.acl = address(acl);
            manager.setACL(address(acl));
            console.log("ACL deployed and configured:", address(acl));
        }

        // 6) Set PutManager on pFT (deployer is pFT's putManager at this point)
        PFT.setPutManager(address(manager));
        console.log("pFT.setPutManager configured:", address(manager));

        // 6.5) Set sale enabled/disabled from TOML config
        // Note: initialize() sets saleEnabled=true by default
        bool saleEnabled = true; // default
        try vm.parseTomlBool(
            vm.readFile(CONFIG_PATH),
            string.concat(".", vm.toString(block.chainid), ".bool.sale_enabled")
        ) returns (
            bool _saleEnabled
        ) {
            saleEnabled = _saleEnabled;
        } catch {}

        if (!saleEnabled) {
            manager.setSaleEnabled(false);
            console.log("Sale disabled per config");
        } else {
            console.log("Sale enabled (default or per config)");
        }

        // 7) Deploy wrappers with DEPLOYER as strategyManager temporarily
        //    (will set pending roles at end for actual role holders to accept)
        ftYieldWrapper wrapperUSDC;
        if (cfg.usdc != address(0)) {
            wrapperUSDC = new ftYieldWrapper(cfg.usdc, deployer, deployer, deployer);
            art.wrapperUSDC = address(wrapperUSDC);
        }

        ftYieldWrapper wrapperWNative;
        if (cfg.wNative != address(0)) {
            wrapperWNative = new ftYieldWrapper(cfg.wNative, deployer, deployer, deployer);
            art.wrapperWNative = address(wrapperWNative);
        }

        // Deploy additional token wrappers (all optional)
        ftYieldWrapper wrapperUSDT;
        if (cfg.usdt != address(0)) {
            wrapperUSDT = new ftYieldWrapper(cfg.usdt, deployer, deployer, deployer);
            art.wrapperUSDT = address(wrapperUSDT);
        }

        ftYieldWrapper wrapperUSDS;
        if (cfg.usds != address(0)) {
            wrapperUSDS = new ftYieldWrapper(cfg.usds, deployer, deployer, deployer);
            art.wrapperUSDS = address(wrapperUSDS);
        }

        ftYieldWrapper wrapperUSDTb;
        if (cfg.usdtb != address(0)) {
            wrapperUSDTb = new ftYieldWrapper(cfg.usdtb, deployer, deployer, deployer);
            art.wrapperUSDTb = address(wrapperUSDTb);
        }

        ftYieldWrapper wrapperUSDe;
        if (cfg.usde != address(0)) {
            wrapperUSDe = new ftYieldWrapper(cfg.usde, deployer, deployer, deployer);
            art.wrapperUSDe = address(wrapperUSDe);
        }

        // 8) Deploy strategies
        AaveStrategy stratUSDC;
        if (address(wrapperUSDC) != address(0)) {
            stratUSDC = new AaveStrategy(
                address(wrapperUSDC), cfg.aavePoolProvider, cfg.usdc, cfg.aaveAUSDC
            );
            art.strategyUSDC = address(stratUSDC);
        }

        AaveStrategy stratWNative;
        if (address(wrapperWNative) != address(0)) {
            stratWNative = new AaveStrategy(
                address(wrapperWNative), cfg.aavePoolProvider, cfg.wNative, cfg.aaveAWNative
            );
            art.strategyWNative = address(stratWNative);
        }

        // Deploy additional token strategies (all use AaveStrategy)
        AaveStrategy stratUSDT;
        if (address(wrapperUSDT) != address(0)) {
            stratUSDT = new AaveStrategy(
                address(wrapperUSDT), cfg.aavePoolProvider, cfg.usdt, cfg.aaveAUSDT
            );
            art.strategyUSDT = address(stratUSDT);
        }

        AaveStrategy stratUSDS;
        if (address(wrapperUSDS) != address(0)) {
            stratUSDS = new AaveStrategy(
                address(wrapperUSDS), cfg.aavePoolProvider, cfg.usds, cfg.aaveAUSDS
            );
            art.strategyUSDS = address(stratUSDS);
        }

        AaveStrategy stratUSDTb;
        if (address(wrapperUSDTb) != address(0)) {
            stratUSDTb = new AaveStrategy(
                address(wrapperUSDTb), cfg.aavePoolProvider, cfg.usdtb, cfg.aaveAUSDTb
            );
            art.strategyUSDTb = address(stratUSDTb);
        }

        AaveStrategy stratUSDe;
        if (address(wrapperUSDe) != address(0)) {
            stratUSDe = new AaveStrategy(
                address(wrapperUSDe), cfg.aavePoolProvider, cfg.usde, cfg.aaveAUSDe
            );
            art.strategyUSDe = address(stratUSDe);
        }

        // 9) Configure wrappers and strategies (deployer is strategyManager/treasury temporarily)
        if (address(wrapperUSDC) != address(0)) {
            wrapperUSDC.setPutManager(address(manager));
            wrapperUSDC.setStrategy(address(stratUSDC));
            wrapperUSDC.confirmStrategy();
            console.log("USDC wrapper and strategy configured");
        }

        if (address(wrapperWNative) != address(0)) {
            wrapperWNative.setPutManager(address(manager));
            wrapperWNative.setStrategy(address(stratWNative));
            wrapperWNative.confirmStrategy();
            console.log("WNative wrapper and strategy configured");
        }

        // Configure additional token wrappers and strategies
        if (address(wrapperUSDT) != address(0)) {
            wrapperUSDT.setPutManager(address(manager));
            wrapperUSDT.setStrategy(address(stratUSDT));
            wrapperUSDT.confirmStrategy();
            console.log("USDT wrapper and strategy configured");
        }

        if (address(wrapperUSDS) != address(0)) {
            wrapperUSDS.setPutManager(address(manager));
            wrapperUSDS.setStrategy(address(stratUSDS));
            wrapperUSDS.confirmStrategy();
            console.log("USDS wrapper and strategy configured");
        }

        if (address(wrapperUSDTb) != address(0)) {
            wrapperUSDTb.setPutManager(address(manager));
            wrapperUSDTb.setStrategy(address(stratUSDTb));
            wrapperUSDTb.confirmStrategy();
            console.log("USDTb wrapper and strategy configured");
        }

        if (address(wrapperUSDe) != address(0)) {
            wrapperUSDe.setPutManager(address(manager));
            wrapperUSDe.setStrategy(address(stratUSDe));
            wrapperUSDe.confirmStrategy();
            console.log("USDe wrapper and strategy configured");
        }

        // 10) Register collaterals (deployer is msig temporarily)
        if (address(wrapperUSDC) != address(0)) {
            manager.addAcceptedCollateral(cfg.usdc, address(wrapperUSDC));
            console.log("USDC collateral registered");
        }

        if (address(wrapperWNative) != address(0)) {
            manager.addAcceptedCollateral(cfg.wNative, address(wrapperWNative));
            console.log("WNative collateral registered");
        }

        // Register additional token collaterals
        if (address(wrapperUSDT) != address(0)) {
            manager.addAcceptedCollateral(cfg.usdt, address(wrapperUSDT));
            console.log("USDT collateral registered");
        }

        if (address(wrapperUSDS) != address(0)) {
            manager.addAcceptedCollateral(cfg.usds, address(wrapperUSDS));
            console.log("USDS collateral registered");
        }

        if (address(wrapperUSDTb) != address(0)) {
            manager.addAcceptedCollateral(cfg.usdtb, address(wrapperUSDTb));
            console.log("USDTb collateral registered");
        }

        if (address(wrapperUSDe) != address(0)) {
            manager.addAcceptedCollateral(cfg.usde, address(wrapperUSDe));
            console.log("USDe collateral registered");
        }

        // 11) Set caps (deployer is configurator temporarily)
        if (address(wrapperUSDC) != address(0)) {
            manager.setCollateralCaps(cfg.usdc, cfg.capUSDC);
            console.log("USDC cap set:", cfg.capUSDC);
        }

        if (address(wrapperWNative) != address(0)) {
            manager.setCollateralCaps(cfg.wNative, cfg.capWNative);
            console.log("WNative cap set:", cfg.capWNative);
        }

        // Set caps for additional tokens
        if (address(wrapperUSDT) != address(0)) {
            manager.setCollateralCaps(cfg.usdt, cfg.capUSDT);
            console.log("USDT cap set:", cfg.capUSDT);
        }

        if (address(wrapperUSDS) != address(0)) {
            manager.setCollateralCaps(cfg.usds, cfg.capUSDS);
            console.log("USDS cap set:", cfg.capUSDS);
        }

        if (address(wrapperUSDTb) != address(0)) {
            manager.setCollateralCaps(cfg.usdtb, cfg.capUSDTb);
            console.log("USDTb cap set:", cfg.capUSDTb);
        }

        if (address(wrapperUSDe) != address(0)) {
            manager.setCollateralCaps(cfg.usde, cfg.capUSDe);
            console.log("USDe cap set:", cfg.capUSDe);
        }

        // 12) FT liquidity - only add for mock deployments
        if (deployedMockFT) {
            // For mock FT, mint to deployer and add liquidity immediately
            FT.mint(deployer, cfg.initialFTSupply);
            IERC20(FT_ADDR).approve(address(manager), type(uint256).max);
            manager.addFTLiquidity(cfg.initialFTSupply);
            console.log("Initial FT liquidity added (mock):", cfg.initialFTSupply);
        } else {
            // For real FT, the FT token's configurator role will add liquidity post-deployment
            console.log("");
            console.log("IMPORTANT: FT liquidity NOT added during deployment");
            console.log("           FT token configurator (ft.configurator()) must manually:");
            console.log("           1. Approve PutManager to spend FT tokens");
            console.log("           2. Call PutManager.addFTLiquidity(amount)");
            console.log("              Amount:", cfg.initialFTSupply);
            console.log("           This is a required post-deployment action!");
        }

        // 13) Circuit Breaker deployment (optional)
        CircuitBreaker cb;
        if (cfg.deployCircuitBreaker) {
            // Use config values if provided, otherwise fall back to defaults
            uint256 maxDrawRate =
                cfg.cbMaxDrawRateWad > 0 ? cfg.cbMaxDrawRateWad : CB_MAX_DRAW_RATE_WAD;
            uint256 mainWindow = cfg.cbMainWindow > 0 ? cfg.cbMainWindow : CB_MAIN_WINDOW;
            uint256 elasticWindow =
                cfg.cbElasticWindow > 0 ? cfg.cbElasticWindow : CB_ELASTIC_WINDOW;

            // Deploy CircuitBreaker (admin = deployer initially)
            cb = new CircuitBreaker(maxDrawRate, mainWindow, elasticWindow);
            art.circuitBreaker = address(cb);
            console.log("");
            console.log("CircuitBreaker deployed:", address(cb));
            console.log("  Max Draw Rate:", maxDrawRate, "(WAD)");
            console.log("  Main Window:  ", mainWindow, "seconds");
            console.log("  Elastic Window:", elasticWindow, "seconds");

            // Register each wrapper as protected contract and set CB on wrapper
            if (address(wrapperUSDC) != address(0)) {
                cb.addProtectedContract(address(wrapperUSDC));
                wrapperUSDC.setCircuitBreaker(address(cb));
                console.log("  USDC wrapper registered with CB");
            }

            if (address(wrapperWNative) != address(0)) {
                cb.addProtectedContract(address(wrapperWNative));
                wrapperWNative.setCircuitBreaker(address(cb));
                console.log("  WNative wrapper registered with CB");
            }

            if (address(wrapperUSDT) != address(0)) {
                cb.addProtectedContract(address(wrapperUSDT));
                wrapperUSDT.setCircuitBreaker(address(cb));
                console.log("  USDT wrapper registered with CB");
            }

            if (address(wrapperUSDS) != address(0)) {
                cb.addProtectedContract(address(wrapperUSDS));
                wrapperUSDS.setCircuitBreaker(address(cb));
                console.log("  USDS wrapper registered with CB");
            }

            if (address(wrapperUSDTb) != address(0)) {
                cb.addProtectedContract(address(wrapperUSDTb));
                wrapperUSDTb.setCircuitBreaker(address(cb));
                console.log("  USDTb wrapper registered with CB");
            }

            if (address(wrapperUSDe) != address(0)) {
                cb.addProtectedContract(address(wrapperUSDe));
                wrapperUSDe.setCircuitBreaker(address(cb));
                console.log("  USDe wrapper registered with CB");
            }
        } else {
            console.log("");
            console.log("CircuitBreaker: DISABLED (deploy_circuit_breaker = false)");
        }

        // ===== PHASE 2: TRANSFER OWNERSHIP & ROLES =====
        console.log("");
        console.log("========== TRANSFERRING OWNERSHIP & ROLES ==========");

        // 14) Transfer PutManager msig (2-step process with time delay)
        if (cfg.msig != deployer) {
            manager.setMsig(cfg.msig);
            console.log("PutManager msig transfer initiated to:", cfg.msig);
            console.log("  MSIG must call PutManager.acceptMsig() after time delay");
        } else {
            console.log("PutManager msig: deployer (no transfer needed)");
        }

        // 15) Transfer PutManager configurator (direct transfer, no pending)
        if (cfg.configurator != deployer) {
            manager.setConfigurator(cfg.configurator);
            console.log("PutManager configurator transferred to:", cfg.configurator);
        } else {
            console.log("PutManager configurator: deployer (no transfer needed)");
        }

        // 16) Transfer Oracle msig (2-step process with time delay)
        if (cfg.msig != deployer) {
            ftOracle.setMsig(cfg.msig);
            console.log("Oracle msig transfer initiated to:", cfg.msig);
            console.log("  MSIG must call FlyingTulipOracle.acceptMsig() after time delay");
        } else {
            console.log("Oracle msig: deployer (no transfer needed)");
        }

        // 17) Transfer CircuitBreaker ownership to strategy_manager (2-step process)
        if (address(cb) != address(0) && cfg.strategyManager != deployer) {
            cb.transferOwnership(cfg.strategyManager);
            console.log("CircuitBreaker ownership transfer initiated to:", cfg.strategyManager);
            console.log("  Strategy manager must call CircuitBreaker.acceptOwnership()");
        } else if (address(cb) != address(0)) {
            console.log("CircuitBreaker owner: deployer (no transfer needed)");
        }

        // 18) Transfer wrapper roles (using pending pattern)
        //     NOTE: Treasury and StrategyManager are confirmed automatically by deployer
        //     to avoid circular dependency (msig in pending cannot confirm roles).
        //     Deployer (who holds all 3 roles initially) confirms as yieldClaimer since:
        //     - confirmTreasury() accepts strategyManager OR yieldClaimer
        //     - confirmStrategyManager() accepts treasury OR yieldClaimer
        //     YieldClaimer is left pending for post-deployment confirmation.

        // USDC Wrapper (if deployed)
        if (address(wrapperUSDC) != address(0)) {
            if (cfg.treasury != deployer) {
                wrapperUSDC.setTreasury(cfg.treasury);
                // deployer as yieldClaimer confirms treasury transfer
                wrapperUSDC.confirmTreasury();
                console.log("USDC wrapper treasury transferred to:", cfg.treasury);
            }
            if (cfg.strategyManager != deployer) {
                wrapperUSDC.setStrategyManager(cfg.strategyManager);
                // deployer as yieldClaimer confirms strategyManager transfer
                wrapperUSDC.confirmStrategyManager();
                console.log("USDC wrapper strategyManager transferred to:", cfg.strategyManager);
            }
            if (cfg.yieldClaimer != deployer) {
                wrapperUSDC.setYieldClaimer(cfg.yieldClaimer);
                console.log("USDC wrapper yieldClaimer pending:", cfg.yieldClaimer);
                console.log(
                    "  Treasury or StrategyManager must call wrapperUSDC.confirmYieldClaimer()"
                );
            }
        }

        // WNative Wrapper (if deployed)
        if (address(wrapperWNative) != address(0)) {
            if (cfg.treasury != deployer) {
                wrapperWNative.setTreasury(cfg.treasury);
                // deployer as yieldClaimer confirms treasury transfer
                wrapperWNative.confirmTreasury();
                console.log("WNative wrapper treasury transferred to:", cfg.treasury);
            }
            if (cfg.strategyManager != deployer) {
                wrapperWNative.setStrategyManager(cfg.strategyManager);
                // deployer as yieldClaimer confirms strategyManager transfer
                wrapperWNative.confirmStrategyManager();
                console.log("WNative wrapper strategyManager transferred to:", cfg.strategyManager);
            }
            if (cfg.yieldClaimer != deployer) {
                wrapperWNative.setYieldClaimer(cfg.yieldClaimer);
                console.log("WNative wrapper yieldClaimer pending:", cfg.yieldClaimer);
                console.log(
                    "  Treasury or StrategyManager must call wrapperWNative.confirmYieldClaimer()"
                );
            }
        }

        // Additional Token Wrappers (if deployed)
        if (address(wrapperUSDT) != address(0)) {
            if (cfg.treasury != deployer) {
                wrapperUSDT.setTreasury(cfg.treasury);
                wrapperUSDT.confirmTreasury();
                console.log("USDT wrapper treasury transferred to:", cfg.treasury);
            }
            if (cfg.strategyManager != deployer) {
                wrapperUSDT.setStrategyManager(cfg.strategyManager);
                wrapperUSDT.confirmStrategyManager();
                console.log("USDT wrapper strategyManager transferred to:", cfg.strategyManager);
            }
            if (cfg.yieldClaimer != deployer) {
                wrapperUSDT.setYieldClaimer(cfg.yieldClaimer);
                console.log("USDT wrapper yieldClaimer pending:", cfg.yieldClaimer);
                console.log(
                    "  Treasury or StrategyManager must call wrapperUSDT.confirmYieldClaimer()"
                );
            }
        }

        if (address(wrapperUSDS) != address(0)) {
            if (cfg.treasury != deployer) {
                wrapperUSDS.setTreasury(cfg.treasury);
                wrapperUSDS.confirmTreasury();
                console.log("USDS wrapper treasury transferred to:", cfg.treasury);
            }
            if (cfg.strategyManager != deployer) {
                wrapperUSDS.setStrategyManager(cfg.strategyManager);
                wrapperUSDS.confirmStrategyManager();
                console.log("USDS wrapper strategyManager transferred to:", cfg.strategyManager);
            }
            if (cfg.yieldClaimer != deployer) {
                wrapperUSDS.setYieldClaimer(cfg.yieldClaimer);
                console.log("USDS wrapper yieldClaimer pending:", cfg.yieldClaimer);
                console.log(
                    "  Treasury or StrategyManager must call wrapperUSDS.confirmYieldClaimer()"
                );
            }
        }

        if (address(wrapperUSDTb) != address(0)) {
            if (cfg.treasury != deployer) {
                wrapperUSDTb.setTreasury(cfg.treasury);
                wrapperUSDTb.confirmTreasury();
                console.log("USDTb wrapper treasury transferred to:", cfg.treasury);
            }
            if (cfg.strategyManager != deployer) {
                wrapperUSDTb.setStrategyManager(cfg.strategyManager);
                wrapperUSDTb.confirmStrategyManager();
                console.log("USDTb wrapper strategyManager transferred to:", cfg.strategyManager);
            }
            if (cfg.yieldClaimer != deployer) {
                wrapperUSDTb.setYieldClaimer(cfg.yieldClaimer);
                console.log("USDTb wrapper yieldClaimer pending:", cfg.yieldClaimer);
                console.log(
                    "  Treasury or StrategyManager must call wrapperUSDTb.confirmYieldClaimer()"
                );
            }
        }

        if (address(wrapperUSDe) != address(0)) {
            if (cfg.treasury != deployer) {
                wrapperUSDe.setTreasury(cfg.treasury);
                wrapperUSDe.confirmTreasury();
                console.log("USDe wrapper treasury transferred to:", cfg.treasury);
            }
            if (cfg.strategyManager != deployer) {
                wrapperUSDe.setStrategyManager(cfg.strategyManager);
                wrapperUSDe.confirmStrategyManager();
                console.log("USDe wrapper strategyManager transferred to:", cfg.strategyManager);
            }
            if (cfg.yieldClaimer != deployer) {
                wrapperUSDe.setYieldClaimer(cfg.yieldClaimer);
                console.log("USDe wrapper yieldClaimer pending:", cfg.yieldClaimer);
                console.log(
                    "  Treasury or StrategyManager must call wrapperUSDe.confirmYieldClaimer()"
                );
            }
        }

        console.log("========== OWNERSHIP TRANSFER PHASE COMPLETE ==========");
        console.log("");

        return art;
    }
}
