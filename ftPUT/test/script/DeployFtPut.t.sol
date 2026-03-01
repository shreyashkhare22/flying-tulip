// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {DeployFtPut} from "script/DeployFtPut.s.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {FlyingTulipOracle} from "contracts/FlyingTulipOracle.sol";
import {ftACL} from "contracts/ftACL.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveOracle} from "contracts/interfaces/IAaveOracle.sol";
import {IAavePoolAddressesProvider} from "contracts/interfaces/IAavePoolAddressesProvider.sol";
import {IAavePoolInstance} from "contracts/interfaces/IAavePoolInstance.sol";
import {CircuitBreaker} from "contracts/cb/CircuitBreaker.sol";

contract MockAaveOracle is IAaveOracle {
    mapping(address token => uint256 price) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getAssetPrice(address token) external view returns (uint256) {
        return prices[token];
    }
}

contract MockAavePool is IAavePoolInstance {
    function supply(address, uint256, address, uint16) external pure override {}

    function withdraw(address, uint256 amount, address) external pure override returns (uint256) {
        return amount;
    }
}

contract MockAavePoolAddressesProvider is IAavePoolAddressesProvider {
    address internal pool;

    constructor(address initialPool) {
        pool = initialPool;
    }

    function setPool(address newPool) external {
        pool = newPool;
    }

    function getPool() external view override returns (address) {
        return pool;
    }
}

contract DeployFtPutHarness is DeployFtPut {
    function exposedLoadConfig(address deployer) external view returns (Config memory cfg) {
        cfg = _loadConfig(deployer);
    }

    function exposedValidateConfig(Config memory cfg) external pure {
        _validateConfig(cfg);
    }

    function exposedDeploy(
        Config memory cfg,
        address deployer
    )
        external
        returns (DeploymentArtifacts memory art)
    {
        bool willDeployMockFT = (cfg.ft == address(0));
        bool willDeployACL = !cfg.disableACL && cfg.merkleRoot != bytes32(0);
        vm.startPrank(deployer);
        art = _deployCore(cfg, deployer, willDeployMockFT, willDeployACL);
        vm.stopPrank();
    }

    function exposedBuildConfig(
        address usdc,
        address wNative,
        address aavePoolProvider,
        address aaveOracle,
        address aaveAUSDC,
        address aaveAWNative,
        address msig,
        address configurator,
        address treasury,
        address yieldClaimer,
        address strategyManager,
        uint256 capUSDC,
        uint256 capWNative,
        uint256 initialFTSupply,
        bool disableACL,
        bytes32 merkleRoot,
        bool isProduction,
        address ft,
        bool deployCircuitBreaker,
        uint256 cbMaxDrawRateWad,
        uint256 cbMainWindow,
        uint256 cbElasticWindow
    )
        external
        pure
        returns (Config memory cfg)
    {
        cfg.ft = ft;
        cfg.usdc = usdc;
        cfg.wNative = wNative;
        cfg.aavePoolProvider = aavePoolProvider;
        cfg.aaveOracle = aaveOracle;
        cfg.aaveAUSDC = aaveAUSDC;
        cfg.aaveAWNative = aaveAWNative;
        cfg.msig = msig;
        cfg.configurator = configurator;
        cfg.treasury = treasury;
        cfg.yieldClaimer = yieldClaimer;
        cfg.strategyManager = strategyManager;
        cfg.capUSDC = capUSDC;
        cfg.capWNative = capWNative;
        cfg.initialFTSupply = initialFTSupply;
        cfg.disableACL = disableACL;
        cfg.merkleRoot = merkleRoot;
        cfg.isProduction = isProduction;
        cfg.deployCircuitBreaker = deployCircuitBreaker;
        cfg.cbMaxDrawRateWad = cbMaxDrawRateWad;
        cfg.cbMainWindow = cbMainWindow;
        cfg.cbElasticWindow = cbElasticWindow;
        // accept defaults for unused fields (prims default to zero)
    }

    function exposedBuildConfigWithAdditionalTokens(
        address usdc,
        address wNative,
        address usdt,
        address usds,
        address aavePoolProvider,
        address aaveOracle,
        address aaveAUSDC,
        address aaveAWNative,
        address aaveAUSDT,
        address aaveAUSDS,
        address msig,
        address configurator,
        address treasury,
        address yieldClaimer,
        address strategyManager,
        uint256 capUSDC,
        uint256 capWNative,
        uint256 capUSDT,
        uint256 capUSDS,
        uint256 initialFTSupply,
        bool disableACL,
        bytes32 merkleRoot,
        bool isProduction,
        address ft,
        bool deployCircuitBreaker,
        uint256 cbMaxDrawRateWad,
        uint256 cbMainWindow,
        uint256 cbElasticWindow
    )
        external
        pure
        returns (Config memory cfg)
    {
        cfg.ft = ft;
        cfg.usdc = usdc;
        cfg.wNative = wNative;
        cfg.usdt = usdt;
        cfg.usds = usds;
        cfg.aavePoolProvider = aavePoolProvider;
        cfg.aaveOracle = aaveOracle;
        cfg.aaveAUSDC = aaveAUSDC;
        cfg.aaveAWNative = aaveAWNative;
        cfg.aaveAUSDT = aaveAUSDT;
        cfg.aaveAUSDS = aaveAUSDS;
        cfg.msig = msig;
        cfg.configurator = configurator;
        cfg.treasury = treasury;
        cfg.yieldClaimer = yieldClaimer;
        cfg.strategyManager = strategyManager;
        cfg.capUSDC = capUSDC;
        cfg.capWNative = capWNative;
        cfg.capUSDT = capUSDT;
        cfg.capUSDS = capUSDS;
        cfg.initialFTSupply = initialFTSupply;
        cfg.disableACL = disableACL;
        cfg.merkleRoot = merkleRoot;
        cfg.isProduction = isProduction;
        cfg.deployCircuitBreaker = deployCircuitBreaker;
        cfg.cbMaxDrawRateWad = cbMaxDrawRateWad;
        cfg.cbMainWindow = cbMainWindow;
        cfg.cbElasticWindow = cbElasticWindow;
    }
}

contract DeployFtPutConfigTest is Test {
    DeployFtPutHarness internal harness;

    address internal constant DUMMY_DEPLOYER = address(uint160(uint256(keccak256("deployer"))));
    uint256 internal constant INITIAL_SUPPLY = 10_000_000_000 ether;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal constant SONIC_USDC = 0x29219dd400f2Bf60E5a23d13Be72B486D4038894;
    address internal constant SONIC_WNATIVE = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
    address internal constant SONIC_AAVE_POOL_PROVIDER = 0x5C2e738F6E27bCE0F7558051Bf90605dD6176900;
    address internal constant SONIC_AAVE_ORACLE = 0xD63f7658C66B2934Bd234D79D06aEF5290734B30;
    address internal constant SONIC_AAVE_AUSDC = 0x578Ee1ca3a8E1b54554Da1Bf7C583506C4CD11c6;
    address internal constant SONIC_AAVE_AWNATIVE = 0x6C5E14A212c1C3e4Baf6f871ac9B1a969918c131;

    function setUp() public {
        harness = new DeployFtPutHarness();
    }

    function testValidateConfigRevertsWhenAUSDCProvidedButUSDCDisabled() public {
        DeployFtPut.Config memory cfg;
        cfg.msig = address(1);
        cfg.configurator = address(2);
        cfg.treasury = address(3);
        cfg.yieldClaimer = address(4);
        cfg.strategyManager = address(5);
        cfg.aavePoolProvider = address(6);
        cfg.aaveOracle = address(7);
        cfg.aaveAUSDC = address(8); // aUSDC provided but usdc is disabled
        cfg.wNative = address(9); // Provide wNative to satisfy "at least one collateral" requirement
        cfg.aaveAWNative = address(10);
        cfg.initialFTSupply = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployFtPut.InvalidConfiguration.selector, "ausdc provided while usdc disabled"
            )
        );
        harness.exposedValidateConfig(cfg);
    }

    function testValidateConfigRevertsWhenAWNativeMissing() public {
        DeployFtPut.Config memory cfg;
        cfg.usdc = address(10);
        cfg.msig = address(1);
        cfg.configurator = address(2);
        cfg.treasury = address(3);
        cfg.yieldClaimer = address(4);
        cfg.strategyManager = address(5);
        cfg.aavePoolProvider = address(6);
        cfg.aaveOracle = address(7);
        cfg.aaveAUSDC = address(8);
        cfg.initialFTSupply = 1;
        cfg.wNative = address(9);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployFtPut.InvalidConfiguration.selector, "awnative address is zero"
            )
        );
        harness.exposedValidateConfig(cfg);
    }

    function testValidateConfigRevertsWhenMismatchedATokens() public {
        // Test case 1: USDC provided but aave_ausdc is zero
        DeployFtPut.Config memory cfg;
        cfg.usdc = address(10); // USDC is set
        cfg.msig = address(1);
        cfg.configurator = address(2);
        cfg.treasury = address(3);
        cfg.yieldClaimer = address(4);
        cfg.strategyManager = address(5);
        cfg.aavePoolProvider = address(6);
        cfg.aaveOracle = address(7);
        // aaveAUSDC is NOT set (address(0))
        cfg.wNative = address(9);
        cfg.aaveAWNative = address(11);
        cfg.initialFTSupply = 1;
        vm.expectRevert(
            abi.encodeWithSelector(DeployFtPut.InvalidConfiguration.selector, "aave_ausdc is zero")
        );
        harness.exposedValidateConfig(cfg);
    }

    function testDeployCoreConfiguresContractsWithMockFT() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wNative = new MockERC20("Wrapped Native", "WNT", 18);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockERC20 aWNative = new MockERC20("Aave WNative", "aWNT", 18);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wNative), 2e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(wNative),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(aWNative),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            500_000 ether,
            250_000 ether,
            1_000_000 ether,
            false,
            bytes32(uint256(0x1234)),
            false,
            address(0),
            false, // deployCircuitBreaker
            0, // cbMaxDrawRateWad (0 = use default)
            0, // cbMainWindow (0 = use default)
            0 // cbElasticWindow (0 = use default)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        assertTrue(art.deployedMockFT, "expected mock FT deployment");
        assertTrue(art.ftToken != address(0), "ft token not set");
        assertTrue(art.acl != address(0), "ACL should be deployed");
        assertTrue(art.wrapperWNative != address(0), "wNative wrapper missing");
        assertTrue(art.strategyWNative != address(0), "wNative strategy missing");

        address pftImpl = address(uint160(uint256(vm.load(art.pftProxy, IMPLEMENTATION_SLOT))));
        assertEq(pftImpl, art.pftImplementation, "pFT implementation mismatch");

        address managerImpl =
            address(uint160(uint256(vm.load(art.putManagerProxy, IMPLEMENTATION_SLOT))));
        assertEq(managerImpl, art.putManagerImplementation, "PutManager implementation mismatch");

        pFT PFTProxy = pFT(art.pftProxy);
        assertEq(PFTProxy.putManager(), art.putManagerProxy, "pFT manager mismatch");

        // Verify deployment configured everything (deployer did all setup)
        PutManager manager = PutManager(art.putManagerProxy);
        assertEq(address(manager.ftOracle()), art.ftOracle, "manager oracle mismatch");
        assertEq(manager.msig(), deployer, "manager msig should still be deployer (pending)");
        assertEq(manager.nextMsig(), msig, "nextMsig should be set");
        assertEq(manager.configurator(), configurator, "manager configurator should be transferred");
        assertTrue(manager.isCollateral(cfg.usdc), "USDC collateral not registered");
        assertEq(manager.vaults(cfg.usdc), art.wrapperUSDC, "USDC vault mismatch");
        assertEq(
            manager.collateralCap(cfg.usdc), cfg.capUSDC, "USDC cap should be set by deployment"
        );
        assertTrue(manager.isCollateral(cfg.wNative), "wNative collateral not registered");
        assertEq(manager.vaults(cfg.wNative), art.wrapperWNative, "wNative vault mismatch");
        assertEq(
            manager.collateralCap(cfg.wNative),
            cfg.capWNative,
            "wNative cap should be set by deployment"
        );
        assertEq(
            manager.ftOfferingSupply(),
            cfg.initialFTSupply,
            "offering supply should be set by deployment"
        );
        assertEq(address(manager.ftACL()), art.acl, "ACL mismatch");

        // Wrappers fully configured - treasury and strategyManager auto-confirmed, yieldClaimer pending
        ftYieldWrapper wrapper = ftYieldWrapper(art.wrapperUSDC);
        assertEq(wrapper.putManager(), art.putManagerProxy, "wrapper putManager should be set");
        assertEq(
            wrapper.strategyManager(),
            strategyManager,
            "wrapper strategy manager should be transferred and confirmed"
        );
        assertEq(
            wrapper.pendingStrategyManager(),
            address(0),
            "pending strategyManager should be cleared after confirmation"
        );
        assertEq(
            wrapper.yieldClaimer(), deployer, "wrapper yield claimer should be deployer (pending)"
        );
        assertEq(wrapper.pendingYieldClaimer(), yieldClaimer, "pending yieldClaimer should be set");
        assertEq(
            wrapper.treasury(), treasury, "wrapper treasury should be transferred and confirmed"
        );
        assertEq(
            wrapper.pendingTreasury(),
            address(0),
            "pending treasury should be cleared after confirmation"
        );
        assertEq(wrapper.token(), cfg.usdc, "wrapper token mismatch");
        assertTrue(wrapper.isStrategy(art.strategyUSDC), "strategy should be confirmed");

        ftYieldWrapper wrapperNative = ftYieldWrapper(art.wrapperWNative);
        assertEq(
            wrapperNative.putManager(),
            art.putManagerProxy,
            "wrapper native putManager should be set"
        );
        assertEq(
            wrapperNative.strategyManager(),
            strategyManager,
            "wrapper native strategy manager should be transferred and confirmed"
        );
        assertEq(
            wrapperNative.pendingStrategyManager(),
            address(0),
            "pending native strategyManager should be cleared after confirmation"
        );
        assertEq(
            wrapperNative.yieldClaimer(),
            deployer,
            "wrapper native yield claimer should be deployer (pending)"
        );
        assertEq(
            wrapperNative.pendingYieldClaimer(),
            yieldClaimer,
            "pending native yieldClaimer should be set"
        );
        assertEq(
            wrapperNative.treasury(),
            treasury,
            "wrapper native treasury should be transferred and confirmed"
        );
        assertEq(
            wrapperNative.pendingTreasury(),
            address(0),
            "pending native treasury should be cleared after confirmation"
        );
        assertEq(wrapperNative.token(), cfg.wNative, "wrapper native token mismatch");
        assertTrue(
            wrapperNative.isStrategy(art.strategyWNative), "native strategy should be confirmed"
        );

        // Verify FT tokens
        IERC20 ftToken = IERC20(art.ftToken);
        assertEq(
            ftToken.balanceOf(art.putManagerProxy),
            cfg.initialFTSupply,
            "manager should hold FT supply"
        );

        FlyingTulipOracle ftOracle = FlyingTulipOracle(art.ftOracle);
        assertEq(ftOracle.msig(), deployer, "oracle msig should be deployer (pending)");
        assertEq(ftOracle.getAaveOracleAddress(), address(oracle), "oracle source mismatch");

        address acl = art.acl;
        if (acl != address(0)) {
            assertEq(ftACL(acl).putManager(), art.putManagerProxy, "ACL putManager mismatch");
        }
    }

    function testProxiesRejectReinitializationAndUnauthorizedUpgrade() public {
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(0),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(0),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            0,
            0,
            1_000_000 ether,
            true,
            bytes32(0),
            false,
            address(0),
            false, // deployCircuitBreaker
            0,
            0,
            0 // CB params (use defaults)
        );

        harness.exposedValidateConfig(cfg);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, msig);

        // Re-initialization should revert
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pFT(art.pftProxy).initialize(msig);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PutManager(art.putManagerProxy).initialize(configurator, msig, art.ftOracle);

        // Unauthorized upgrade attempts
        address attacker = makeAddr("attacker");
        pFT newPftImpl = new pFT();
        vm.expectRevert(pFT.pFTNotMsig.selector);
        vm.prank(attacker);
        pFT(art.pftProxy).upgradeToAndCall(address(newPftImpl), bytes(""));

        PutManager newManagerImpl = new PutManager(art.ftToken, art.pftProxy);
        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(attacker);
        PutManager(art.putManagerProxy).upgradeToAndCall(address(newManagerImpl), bytes(""));
    }

    function testDeployCoreWithPreexistingFTToken() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 ftToken = new MockERC20("Flying Tulip", "FT", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(0),
            address(provider),
            address(oracle),
            address(usdc), // reuse as aToken for simplicity
            address(0),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            0,
            0,
            1_000_000 ether,
            true,
            bytes32(0),
            false,
            address(ftToken),
            false, // deployCircuitBreaker
            0,
            0,
            0 // CB params (use defaults)
        );

        harness.exposedValidateConfig(cfg);

        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        assertEq(art.ftToken, address(ftToken), "expected supplied FT token");
        assertFalse(art.deployedMockFT, "should not deploy mock FT");

        // For real FT tokens, deployment does NOT add liquidity (manual post-deployment action)
        PutManager manager = PutManager(art.putManagerProxy);
        assertEq(manager.ftOfferingSupply(), 0, "offering supply should NOT be set by deployment");

        // No ACL, no wNative paths
        assertEq(art.acl, address(0), "ACL should not be deployed");
        assertEq(art.wrapperWNative, address(0), "wNative wrapper should be absent");

        // Manager should NOT hold FT tokens yet (liquidity not added)
        assertEq(
            ftToken.balanceOf(art.putManagerProxy),
            0,
            "manager should NOT hold FT tokens (not added during deployment)"
        );
    }

    function testDeploymentWithPendingOwnershipTransfers() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wNative = new MockERC20("Wrapped Native", "WNT", 18);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockERC20 aWNative = new MockERC20("Aave WNative", "aWNT", 18);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wNative), 2e8);

        // All roles different from deployer - should result in pending transfers
        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(wNative),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(aWNative),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            500_000 ether,
            250_000 ether,
            1_000_000 ether,
            false,
            bytes32(uint256(0x1234)),
            false,
            address(0),
            false, // deployCircuitBreaker
            0,
            0,
            0 // CB params (use defaults)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        // === VERIFY DEPLOYMENT DOES NOT DEPEND ON DEPLOYER ===

        // PutManager: msig should be in pending state, configurator should be transferred
        PutManager manager = PutManager(art.putManagerProxy);
        assertEq(manager.msig(), deployer, "msig should still be deployer (pending transfer)");
        assertEq(manager.nextMsig(), msig, "nextMsig should be set to target msig");
        assertTrue(manager.delayMsig() > 0, "delayMsig should be set");
        assertEq(
            manager.configurator(), configurator, "configurator should be directly transferred"
        );

        // Oracle: msig should be in pending state
        FlyingTulipOracle ftOracle = FlyingTulipOracle(art.ftOracle);
        assertEq(
            ftOracle.msig(), deployer, "oracle msig should still be deployer (pending transfer)"
        );
        assertEq(ftOracle.nextMsig(), msig, "oracle nextMsig should be set to target msig");
        assertTrue(ftOracle.delayMsig() > 0, "oracle delayMsig should be set");

        // Note: deployer is still temporary msig until time delay passes and msig accepts
        // So deployer can still perform msig operations at this stage
        vm.prank(deployer);
        manager.pause();
        assertTrue(manager.paused(), "deployer (temporary msig) should be able to pause");
        vm.prank(deployer);
        manager.unpause();

        // Wrappers: treasury and strategyManager auto-confirmed, yieldClaimer pending
        ftYieldWrapper wrapper = ftYieldWrapper(art.wrapperUSDC);
        assertEq(
            wrapper.yieldClaimer(), deployer, "yieldClaimer should still be deployer (pending)"
        );
        assertEq(wrapper.pendingYieldClaimer(), yieldClaimer, "pendingYieldClaimer should be set");
        assertEq(
            wrapper.strategyManager(),
            strategyManager,
            "strategyManager should be transferred and confirmed"
        );
        assertEq(
            wrapper.pendingStrategyManager(), address(0), "pendingStrategyManager should be cleared"
        );
        assertEq(wrapper.treasury(), treasury, "treasury should be transferred and confirmed");
        assertEq(wrapper.pendingTreasury(), address(0), "pendingTreasury should be cleared");

        ftYieldWrapper wrapperNative = ftYieldWrapper(art.wrapperWNative);
        assertEq(
            wrapperNative.yieldClaimer(),
            deployer,
            "native yieldClaimer should still be deployer (pending)"
        );
        assertEq(
            wrapperNative.pendingYieldClaimer(),
            yieldClaimer,
            "native pendingYieldClaimer should be set"
        );
        assertEq(
            wrapperNative.strategyManager(),
            strategyManager,
            "native strategyManager should be transferred and confirmed"
        );
        assertEq(
            wrapperNative.pendingStrategyManager(),
            address(0),
            "native pendingStrategyManager should be cleared"
        );
        assertEq(
            wrapperNative.treasury(),
            treasury,
            "native treasury should be transferred and confirmed"
        );
        assertEq(
            wrapperNative.pendingTreasury(), address(0), "native pendingTreasury should be cleared"
        );

        // Verify deployment is fully configured despite pending transfers
        assertEq(wrapper.putManager(), art.putManagerProxy, "wrapper putManager should be set");
        assertTrue(wrapper.isStrategy(art.strategyUSDC), "USDC strategy should be confirmed");
        assertEq(
            wrapperNative.putManager(),
            art.putManagerProxy,
            "native wrapper putManager should be set"
        );
        assertTrue(
            wrapperNative.isStrategy(art.strategyWNative), "native strategy should be confirmed"
        );
        assertEq(
            manager.collateralCap(cfg.usdc), cfg.capUSDC, "USDC cap should be set by deployment"
        );
        assertEq(
            manager.collateralCap(cfg.wNative),
            cfg.capWNative,
            "native cap should be set by deployment"
        );
        assertEq(
            manager.ftOfferingSupply(),
            cfg.initialFTSupply,
            "offering supply should be set by deployment"
        );

        // === VERIFY OWNERSHIP TRANSFER COMPLETION WORKS ===

        // Complete PutManager msig transfer
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(msig);
        manager.acceptMsig();
        assertEq(manager.msig(), msig, "msig should be transferred after accept");
        assertEq(manager.nextMsig(), address(0), "nextMsig should be cleared");
        assertEq(manager.delayMsig(), 0, "delayMsig should be cleared");

        // Complete Oracle msig transfer
        vm.prank(msig);
        ftOracle.acceptMsig();
        assertEq(ftOracle.msig(), msig, "oracle msig should be transferred after accept");
        assertEq(ftOracle.nextMsig(), address(0), "oracle nextMsig should be cleared");
        assertEq(ftOracle.delayMsig(), 0, "oracle delayMsig should be cleared");

        // Verify msig can now perform admin operations
        vm.prank(msig);
        manager.pause();
        assertTrue(manager.paused(), "manager should be paused by new msig");
        vm.prank(msig);
        manager.unpause();
        assertFalse(manager.paused(), "manager should be unpaused by new msig");

        // Complete wrapper yieldClaimer transfer (treasury or strategyManager confirms)
        // Since treasury and strategyManager were auto-confirmed during deployment,
        // use one of them to confirm yieldClaimer
        vm.prank(treasury); // treasury was transferred and confirmed during deployment
        wrapper.confirmYieldClaimer();
        assertEq(wrapper.yieldClaimer(), yieldClaimer, "yieldClaimer should be transferred");
        assertEq(wrapper.pendingYieldClaimer(), address(0), "pendingYieldClaimer should be cleared");

        vm.prank(strategyManager); // strategyManager was transferred and confirmed during deployment
        wrapperNative.confirmYieldClaimer();
        assertEq(
            wrapperNative.yieldClaimer(), yieldClaimer, "native yieldClaimer should be transferred"
        );
        assertEq(
            wrapperNative.pendingYieldClaimer(),
            address(0),
            "native pendingYieldClaimer should be cleared"
        );
        assertEq(
            wrapperNative.pendingTreasury(), address(0), "native pendingTreasury should be cleared"
        );

        // Verify deployer is completely removed from all contracts
        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(deployer);
        manager.pause();

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimer.selector);
        vm.prank(deployer);
        wrapper.setSubYieldClaimer(makeAddr("sub"));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategyManager.selector);
        vm.prank(deployer);
        wrapper.setPutManager(makeAddr("newManager"));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotSetter.selector);
        vm.prank(deployer);
        wrapper.setTreasury(makeAddr("newTreasury"));
    }

    function testDeploymentPutManagerStateConfiguration() public {
        address deployer = makeAddr("deployer");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(0), // no wNative
            address(provider),
            address(oracle),
            address(aUsdc),
            address(0), // no aWNative
            deployer,
            deployer,
            deployer,
            deployer,
            deployer,
            0, // unlimited cap
            0,
            1_000_000 ether,
            true, // disable ACL
            bytes32(0),
            false,
            address(0),
            false, // deployCircuitBreaker
            0,
            0,
            0 // CB params (use defaults)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        PutManager manager = PutManager(art.putManagerProxy);

        // Verify initial state after deployment
        assertFalse(manager.paused(), "PutManager should not be paused after deployment");
        // Chain 31337 has sale_enabled = false in TOML config
        assertFalse(manager.saleEnabled(), "PutManager sale should be disabled per TOML config");
        assertFalse(
            manager.transferable(), "PutManager transferable should be false after deployment"
        );

        // Verify msig can control pause state
        vm.prank(deployer);
        manager.pause();
        assertTrue(manager.paused(), "PutManager should be paused after msig pause");

        vm.prank(deployer);
        manager.unpause();
        assertFalse(manager.paused(), "PutManager should be unpaused after msig unpause");

        // Verify only msig can pause
        address attacker = makeAddr("attacker");
        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(attacker);
        manager.pause();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(attacker);
        manager.unpause();
    }

    function testMixedOwnershipScenario() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address treasury = makeAddr("treasury");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);

        // Mixed scenario: msig and treasury differ, others same as deployer
        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(0),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(0),
            msig, // different
            deployer, // same
            treasury, // different
            deployer, // same
            deployer, // same
            0,
            0,
            1_000_000 ether,
            true,
            bytes32(0),
            false,
            address(0),
            false, // deployCircuitBreaker
            0, // cbMaxDrawRateWad (use defaults)
            0, // cbMainWindow (use defaults)
            0 // cbElasticWindow (use defaults)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        PutManager manager = PutManager(art.putManagerProxy);
        ftYieldWrapper wrapper = ftYieldWrapper(art.wrapperUSDC);

        // Verify PutManager: msig pending, configurator transferred
        assertEq(manager.msig(), deployer, "msig should be deployer (pending)");
        assertEq(manager.nextMsig(), msig, "nextMsig should be set");
        assertEq(manager.configurator(), deployer, "configurator should be deployer (no transfer)");

        // Verify wrapper: treasury auto-confirmed (different from deployer), others unchanged
        assertEq(wrapper.treasury(), treasury, "treasury should be transferred and confirmed");
        assertEq(wrapper.pendingTreasury(), address(0), "pendingTreasury should be cleared");
        assertEq(wrapper.yieldClaimer(), deployer, "yieldClaimer should be deployer (no transfer)");
        assertEq(wrapper.pendingYieldClaimer(), address(0), "no pending yieldClaimer");
        assertEq(
            wrapper.strategyManager(), deployer, "strategyManager should be deployer (no transfer)"
        );
        assertEq(wrapper.pendingStrategyManager(), address(0), "no pending strategyManager");

        // Complete msig transfer
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(msig);
        manager.acceptMsig();
        assertEq(manager.msig(), msig, "msig transferred");

        // Treasury was auto-confirmed during deployment, verify it's already transferred
        assertEq(wrapper.treasury(), treasury, "treasury auto-confirmed during deployment");
        assertEq(wrapper.pendingTreasury(), address(0), "no pending treasury");

        // Verify final state: msig and treasury transferred, others remain with deployer
        assertEq(manager.configurator(), deployer, "configurator still deployer");
        assertEq(wrapper.yieldClaimer(), deployer, "yieldClaimer still deployer");
        assertEq(wrapper.strategyManager(), deployer, "strategyManager still deployer");
    }

    /// @notice Phase 1.5: Test deployment with only wNative (no USDC) - BNB Chain scenario
    function testDeployCoreWithOnlyWNative() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 wNative = new MockERC20("Wrapped BNB", "wBNB", 18);
        MockERC20 aWNative = new MockERC20("Aave wBNB", "awBNB", 18);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(wNative), 300e8); // BNB price

        // Config with USDC disabled (address(0)), only wNative
        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(0), // USDC disabled
            address(wNative),
            address(provider),
            address(oracle),
            address(0), // no aUSDC
            address(aWNative),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            0, // no USDC cap
            500_000 ether, // wNative cap
            1_000_000 ether,
            true, // disable ACL
            bytes32(0),
            false,
            address(0), // mock FT
            false, // deployCircuitBreaker
            0, // cbMaxDrawRateWad (use defaults)
            0, // cbMainWindow (use defaults)
            0 // cbElasticWindow (use defaults)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        // Verify USDC wrapper/strategy NOT deployed
        assertEq(art.wrapperUSDC, address(0), "USDC wrapper should NOT be deployed");
        assertEq(art.strategyUSDC, address(0), "USDC strategy should NOT be deployed");

        // Verify wNative wrapper/strategy deployed
        assertTrue(art.wrapperWNative != address(0), "wNative wrapper should be deployed");
        assertTrue(art.strategyWNative != address(0), "wNative strategy should be deployed");

        // Verify PutManager configuration
        PutManager manager = PutManager(art.putManagerProxy);
        assertFalse(manager.isCollateral(address(0)), "USDC (address 0) should NOT be collateral");
        assertTrue(manager.isCollateral(cfg.wNative), "wNative should be registered as collateral");
        assertEq(manager.vaults(cfg.wNative), art.wrapperWNative, "wNative vault should be set");
        assertEq(
            manager.collateralCap(cfg.wNative), cfg.capWNative, "wNative cap should be configured"
        );

        // Verify wNative wrapper configured correctly
        ftYieldWrapper wrapper = ftYieldWrapper(art.wrapperWNative);
        assertEq(wrapper.putManager(), art.putManagerProxy, "wrapper putManager should be set");
        assertEq(wrapper.token(), cfg.wNative, "wrapper token should be wNative");
        assertTrue(wrapper.isStrategy(art.strategyWNative), "wNative strategy should be confirmed");

        // Verify FT liquidity added (mock deployment)
        assertEq(
            manager.ftOfferingSupply(), cfg.initialFTSupply, "FT offering supply should be set"
        );
    }

    /// @notice Phase 1.6: Test validation reverts when no collateral provided
    function testValidateConfigRevertsWhenNoCollateral() public {
        DeployFtPut.Config memory cfg;
        cfg.usdc = address(0); // USDC disabled
        cfg.wNative = address(0); // wNative disabled
        cfg.msig = address(1);
        cfg.configurator = address(2);
        cfg.treasury = address(3);
        cfg.yieldClaimer = address(4);
        cfg.strategyManager = address(5);
        cfg.aavePoolProvider = address(6);
        cfg.aaveOracle = address(7);
        cfg.initialFTSupply = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployFtPut.InvalidConfiguration.selector,
                "at least one collateral required (usdc or wNative)"
            )
        );
        harness.exposedValidateConfig(cfg);
    }

    /// @notice Phase 2.7: Test deployment with additional tokens (USDT, USDS)
    function testDeployCoreWithAdditionalTokens() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wNative = new MockERC20("Wrapped Native", "WNT", 18);
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);
        MockERC20 usds = new MockERC20("USDS Stablecoin", "USDS", 18);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockERC20 aWNative = new MockERC20("Aave WNative", "aWNT", 18);
        MockERC20 aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);
        MockERC20 aUsds = new MockERC20("Aave USDS", "aUSDS", 18);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wNative), 2e8);
        oracle.setPrice(address(usdt), 1e8);
        oracle.setPrice(address(usds), 1e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfigWithAdditionalTokens(
            address(usdc),
            address(wNative),
            address(usdt),
            address(usds),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(aWNative),
            address(aUsdt),
            address(aUsds),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            500_000 ether,
            250_000 ether,
            100_000 ether,
            150_000 ether,
            1_000_000 ether,
            true,
            bytes32(0),
            false,
            address(0),
            false, // deployCircuitBreaker
            0, // cbMaxDrawRateWad (use defaults)
            0, // cbMainWindow (use defaults)
            0 // cbElasticWindow (use defaults)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        // Verify all 4 wrappers deployed
        assertTrue(art.wrapperUSDC != address(0), "USDC wrapper should be deployed");
        assertTrue(art.wrapperWNative != address(0), "wNative wrapper should be deployed");
        assertTrue(art.wrapperUSDT != address(0), "USDT wrapper should be deployed");
        assertTrue(art.wrapperUSDS != address(0), "USDS wrapper should be deployed");

        // Verify all 4 strategies deployed (all AaveStrategy)
        assertTrue(art.strategyUSDC != address(0), "USDC strategy should be deployed");
        assertTrue(art.strategyWNative != address(0), "wNative strategy should be deployed");
        assertTrue(art.strategyUSDT != address(0), "USDT strategy should be deployed");
        assertTrue(art.strategyUSDS != address(0), "USDS strategy should be deployed");

        // Verify PutManager configuration for all 4 tokens
        PutManager manager = PutManager(art.putManagerProxy);
        assertTrue(manager.isCollateral(cfg.usdc), "USDC should be registered as collateral");
        assertTrue(manager.isCollateral(cfg.wNative), "wNative should be registered as collateral");
        assertTrue(manager.isCollateral(cfg.usdt), "USDT should be registered as collateral");
        assertTrue(manager.isCollateral(cfg.usds), "USDS should be registered as collateral");

        assertEq(manager.vaults(cfg.usdc), art.wrapperUSDC, "USDC vault mismatch");
        assertEq(manager.vaults(cfg.wNative), art.wrapperWNative, "wNative vault mismatch");
        assertEq(manager.vaults(cfg.usdt), art.wrapperUSDT, "USDT vault mismatch");
        assertEq(manager.vaults(cfg.usds), art.wrapperUSDS, "USDS vault mismatch");

        assertEq(manager.collateralCap(cfg.usdc), cfg.capUSDC, "USDC cap should be set");
        assertEq(manager.collateralCap(cfg.wNative), cfg.capWNative, "wNative cap should be set");
        assertEq(manager.collateralCap(cfg.usdt), cfg.capUSDT, "USDT cap should be set");
        assertEq(manager.collateralCap(cfg.usds), cfg.capUSDS, "USDS cap should be set");

        // Verify wrappers configured correctly
        ftYieldWrapper wrapperUSDT = ftYieldWrapper(art.wrapperUSDT);
        assertEq(
            wrapperUSDT.putManager(), art.putManagerProxy, "USDT wrapper putManager should be set"
        );
        assertEq(wrapperUSDT.token(), cfg.usdt, "USDT wrapper token should be usdt");
        assertTrue(wrapperUSDT.isStrategy(art.strategyUSDT), "USDT strategy should be confirmed");

        ftYieldWrapper wrapperUSDS = ftYieldWrapper(art.wrapperUSDS);
        assertEq(
            wrapperUSDS.putManager(), art.putManagerProxy, "USDS wrapper putManager should be set"
        );
        assertEq(wrapperUSDS.token(), cfg.usds, "USDS wrapper token should be usds");
        assertTrue(wrapperUSDS.isStrategy(art.strategyUSDS), "USDS strategy should be confirmed");

        // Verify FT liquidity added (mock deployment)
        assertEq(
            manager.ftOfferingSupply(), cfg.initialFTSupply, "FT offering supply should be set"
        );
    }

    /// @notice Phase 3.4: Test deployment with real FT token and zero initial_ft_supply
    /// @dev This test verifies that:
    /// - Deployment succeeds with real FT and zero supply (validation passes)
    /// - ftOfferingSupply remains 0 (not added during deployment)
    /// - Real FT token is used (not mock deployed)
    function testDeployCoreWithRealFTZeroSupply() public {
        // Use a separate helper to avoid stack too deep
        _testRealFTZeroSupplyImpl();
    }

    /// @dev Implementation helper to avoid stack too deep in main test function
    function _testRealFTZeroSupplyImpl() internal {
        address deployer = makeAddr("deployer");

        // Create minimal mock infrastructure
        MockERC20 ftToken = new MockERC20("Flying Tulip", "FT", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);

        // Build config directly to avoid parameter explosion
        DeployFtPut.Config memory cfg;
        cfg.ft = address(ftToken); // Real FT token
        cfg.usdc = address(usdc);
        cfg.aavePoolProvider = address(provider);
        cfg.aaveOracle = address(oracle);
        cfg.aaveAUSDC = address(aUsdc);
        cfg.initialFTSupply = 0; // Zero supply - key test condition
        cfg.disableACL = true;
        cfg.msig = deployer;
        cfg.configurator = deployer;
        cfg.treasury = deployer;
        cfg.yieldClaimer = deployer;
        cfg.strategyManager = deployer;

        // Validate should pass (zero supply allowed for real FT)
        harness.exposedValidateConfig(cfg);

        // Deploy
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);

        // Verify real FT was used (not mock deployed)
        assertEq(art.ftToken, address(ftToken), "should use provided FT token");
        assertFalse(art.deployedMockFT, "should NOT deploy mock FT");

        // Verify ftOfferingSupply is 0 (liquidity not added)
        PutManager manager = PutManager(art.putManagerProxy);
        assertEq(
            manager.ftOfferingSupply(),
            0,
            "offering supply should be 0 for real FT with zero supply"
        );

        // Verify FT balance is 0 (no automatic liquidity)
        assertEq(ftToken.balanceOf(art.putManagerProxy), 0, "manager should have 0 FT balance");
    }

    /// @notice Phase 3: Test that mock FT deployment still requires non-zero supply
    function testValidateConfigRevertsWhenMockFTZeroSupply() public {
        DeployFtPut.Config memory cfg;
        cfg.ft = address(0); // Mock FT
        cfg.usdc = address(1);
        cfg.aavePoolProvider = address(2);
        cfg.aaveOracle = address(3);
        cfg.aaveAUSDC = address(4);
        cfg.initialFTSupply = 0; // Zero supply - should fail for mock FT
        cfg.msig = address(5);
        cfg.configurator = address(6);
        cfg.treasury = address(7);
        cfg.yieldClaimer = address(8);
        cfg.strategyManager = address(9);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployFtPut.InvalidConfiguration.selector,
                "initial_ft_supply required for mock FT deployment"
            )
        );
        harness.exposedValidateConfig(cfg);
    }

    /// @notice Test deployment with circuit breaker enabled
    function testDeployCoreWithCircuitBreaker() public {
        address deployer = makeAddr("deployer");
        address msig = makeAddr("msig");
        address configurator = makeAddr("configurator");
        address treasury = makeAddr("treasury");
        address yieldClaimer = makeAddr("yieldClaimer");
        address strategyManager = makeAddr("strategyManager");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wNative = new MockERC20("Wrapped Native", "WNT", 18);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockERC20 aWNative = new MockERC20("Aave WNative", "aWNT", 18);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wNative), 2e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(wNative),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(aWNative),
            msig,
            configurator,
            treasury,
            yieldClaimer,
            strategyManager,
            500_000 ether,
            250_000 ether,
            1_000_000 ether,
            true, // disable ACL
            bytes32(0),
            false,
            address(0),
            true, // deployCircuitBreaker = ENABLED
            0, // cbMaxDrawRateWad (use defaults: 5%)
            0, // cbMainWindow (use defaults: 4 hours)
            0 // cbElasticWindow (use defaults: 2 hours)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        // Verify circuit breaker deployed
        assertTrue(art.circuitBreaker != address(0), "CircuitBreaker should be deployed");

        // Verify circuit breaker config (recommended defaults)
        CircuitBreaker cb = CircuitBreaker(art.circuitBreaker);
        (uint64 maxDrawRate, uint48 mainWindow, uint48 elasticWindow) = cb.config();
        assertEq(maxDrawRate, 5e16, "Max draw rate should be 5%");
        assertEq(mainWindow, 14400, "Main window should be 4 hours");
        assertEq(elasticWindow, 7200, "Elastic window should be 2 hours");

        // Verify wrappers registered as protected contracts
        assertTrue(cb.protectedContracts(art.wrapperUSDC), "USDC wrapper should be registered");
        assertTrue(
            cb.protectedContracts(art.wrapperWNative), "WNative wrapper should be registered"
        );

        // Verify wrappers have circuit breaker set
        ftYieldWrapper wrapperUSDC = ftYieldWrapper(art.wrapperUSDC);
        ftYieldWrapper wrapperWNative = ftYieldWrapper(art.wrapperWNative);
        assertEq(wrapperUSDC.circuitBreaker(), art.circuitBreaker, "USDC wrapper CB mismatch");
        assertEq(wrapperWNative.circuitBreaker(), art.circuitBreaker, "WNative wrapper CB mismatch");

        // Verify ownership transfer initiated to strategy_manager
        assertEq(cb.owner(), deployer, "CB owner should be deployer initially");
        assertEq(cb.pendingOwner(), strategyManager, "CB pending owner should be strategy_manager");

        // Complete ownership transfer
        vm.prank(strategyManager);
        cb.acceptOwnership();
        assertEq(cb.owner(), strategyManager, "CB owner should be strategy_manager after accept");
    }

    /// @notice Test deployment with circuit breaker disabled
    function testDeployCoreWithCircuitBreakerDisabled() public {
        address deployer = makeAddr("deployer");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.setPrice(address(usdc), 1e8);

        DeployFtPut.Config memory cfg = harness.exposedBuildConfig(
            address(usdc),
            address(0),
            address(provider),
            address(oracle),
            address(aUsdc),
            address(0),
            deployer,
            deployer,
            deployer,
            deployer,
            deployer,
            0,
            0,
            1_000_000 ether,
            true,
            bytes32(0),
            false,
            address(0),
            false, // deployCircuitBreaker = DISABLED
            0, // cbMaxDrawRateWad (unused when disabled)
            0, // cbMainWindow (unused when disabled)
            0 // cbElasticWindow (unused when disabled)
        );

        harness.exposedValidateConfig(cfg);
        vm.startPrank(deployer);
        DeployFtPut.DeploymentArtifacts memory art = harness.exposedDeploy(cfg, deployer);
        vm.stopPrank();

        // Verify circuit breaker NOT deployed
        assertEq(art.circuitBreaker, address(0), "CircuitBreaker should NOT be deployed");

        // Verify wrapper has no circuit breaker set
        ftYieldWrapper wrapper = ftYieldWrapper(art.wrapperUSDC);
        assertEq(wrapper.circuitBreaker(), address(0), "Wrapper should have no CB");
    }
}

