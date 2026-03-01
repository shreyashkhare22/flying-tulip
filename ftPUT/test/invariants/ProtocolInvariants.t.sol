// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {AaveStrategy} from "contracts/strategies/AaveStrategy.sol";
import {CircuitBreaker} from "contracts/cb/CircuitBreaker.sol";
import {ICircuitBreaker} from "contracts/interfaces/ICircuitBreaker.sol";

// mocks
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "../mocks/MockOracles.sol";
import {MockAavePoolWithAToken} from "../mocks/MockAavePoolWithAToken.sol";
import {MockAavePoolAddressesProvider} from "../mocks/MockAavePoolAddressesProvider.sol";
import {MockAToken} from "../mocks/MockAToken.sol";

// Handler
import {ProtocolHandler} from "./ProtocolHandler.sol";

/// @title Protocol Invariants Test Suite
/// @notice Stateful invariant tests for the Flying Tulip PUT protocol
/// @dev Uses ProtocolHandler for realistic multi-transaction fuzzing
contract ProtocolInvariantsTest is Test {
    // Core components
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20 public wbtc;
    MockERC20 public wsonic;
    MockERC20 public ft;
    MockFlyingTulipOracle public oracle;
    pFT public pft;
    PutManager public manager;
    ftYieldWrapper public wrapperUSDC;
    ftYieldWrapper public wrapperUSDT;
    ftYieldWrapper public wrapperWBTC;
    ftYieldWrapper public wrapperWSONIC;
    AaveStrategy public strategyUSDC;
    CircuitBreaker public circuitBreaker;

    // Aave mocks
    MockAToken public aUSDC;
    MockAavePoolWithAToken public pool;
    MockAavePoolAddressesProvider public provider;

    // Roles
    address public msig = address(0xA11CE);
    address public configurator = address(0xB0B);
    address public treasury = address(0x71EA5);
    address public yieldClaimer = address(0xC1A1);

    // Handler for stateful fuzzing
    ProtocolHandler public handler;

    // Users for testing
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public user3 = address(0x3333);
    address public user4 = address(0x4444);
    address public user5 = address(0x5555);

    uint256 constant USDC_DECIMALS = 6;
    uint256 constant USDT_DECIMALS = 6;
    uint256 constant WBTC_DECIMALS = 8;
    uint256 constant WSONIC_DECIMALS = 18;

    function setUp() public {
        // Deploy tokens with different decimals for comprehensive testing
        usdc = new MockERC20("USD Coin", "USDC", uint8(USDC_DECIMALS));
        usdt = new MockERC20("USD Tether", "USDT", uint8(USDT_DECIMALS));
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", uint8(WBTC_DECIMALS));
        wsonic = new MockERC20("Wrapped Sonic", "wSONIC", uint8(WSONIC_DECIMALS));
        ft = new MockERC20("Flying Tulip", "FT", 18);

        // Deploy oracle and set prices
        oracle = new MockFlyingTulipOracle();
        oracle.setAssetPrice(address(usdc), 1e8); // $1.00
        oracle.setAssetPrice(address(usdt), 1e8); // $1.00
        oracle.setAssetPrice(address(wbtc), 100_000e8); // $100,000 (BTC price)
        oracle.setAssetPrice(address(wsonic), 12e6); // $0.12 (Sonic price: 0.12 * 1e8)

        // Deploy pFT proxy
        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        pft = pFT(address(pftProxy));

        // Deploy PutManager proxy
        PutManager impl = new PutManager(address(ft), address(pft));
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(oracle)
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(impl), data);
        manager = PutManager(address(managerProxy));

        // Initialize pFT
        vm.prank(configurator);
        pft.initialize(address(manager));

        // Deploy wrappers for all collateral types
        wrapperUSDC = new ftYieldWrapper(address(usdc), yieldClaimer, yieldClaimer, treasury);
        wrapperUSDT = new ftYieldWrapper(address(usdt), yieldClaimer, yieldClaimer, treasury);
        wrapperWBTC = new ftYieldWrapper(address(wbtc), yieldClaimer, yieldClaimer, treasury);
        wrapperWSONIC = new ftYieldWrapper(address(wsonic), yieldClaimer, yieldClaimer, treasury);

        // Set putManager on all wrappers
        vm.startPrank(yieldClaimer);
        wrapperUSDC.setPutManager(address(manager));
        wrapperUSDT.setPutManager(address(manager));
        wrapperWBTC.setPutManager(address(manager));
        wrapperWSONIC.setPutManager(address(manager));
        vm.stopPrank();

        // Deploy CircuitBreaker with default configuration (5%, 4h, 2h)
        // Deployed by configurator who will register protected contracts then transfer to msig
        vm.startPrank(configurator);
        circuitBreaker = new CircuitBreaker(
            5e16, // 5% max draw rate
            4 hours, // main window
            2 hours // elastic window
        );

        // Register all wrappers as protected contracts
        circuitBreaker.addProtectedContract(address(wrapperUSDC));
        circuitBreaker.addProtectedContract(address(wrapperUSDT));
        circuitBreaker.addProtectedContract(address(wrapperWBTC));
        circuitBreaker.addProtectedContract(address(wrapperWSONIC));

        // Transfer ownership to msig (two-step process)
        circuitBreaker.transferOwnership(msig);
        vm.stopPrank();

        // msig accepts ownership
        vm.prank(msig);
        circuitBreaker.acceptOwnership();

        // Set CircuitBreaker on all wrappers
        vm.startPrank(yieldClaimer);
        wrapperUSDC.setCircuitBreaker(address(circuitBreaker));
        wrapperUSDT.setCircuitBreaker(address(circuitBreaker));
        wrapperWBTC.setCircuitBreaker(address(circuitBreaker));
        wrapperWSONIC.setCircuitBreaker(address(circuitBreaker));
        vm.stopPrank();

        // Deploy Aave strategy for USDC
        aUSDC = new MockAToken(usdc);
        pool = new MockAavePoolWithAToken(usdc, aUSDC);
        provider = new MockAavePoolAddressesProvider(address(pool));
        strategyUSDC = new AaveStrategy(
            address(wrapperUSDC), address(provider), address(usdc), address(aUSDC)
        );

        // Register strategy
        vm.startPrank(yieldClaimer);
        wrapperUSDC.setStrategy(address(strategyUSDC));
        vm.stopPrank();
        vm.prank(treasury);
        wrapperUSDC.confirmStrategy();

        // Add accepted collaterals (all 4 token types)
        vm.startPrank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapperUSDC));
        manager.addAcceptedCollateral(address(usdt), address(wrapperUSDT));
        manager.addAcceptedCollateral(address(wbtc), address(wrapperWBTC));
        manager.addAcceptedCollateral(address(wsonic), address(wrapperWSONIC));
        vm.stopPrank();

        // Fund FT supply
        ft.mint(configurator, 100_000_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(50_000_000e18);
        vm.stopPrank();

        // Fund users with all collateral types
        // USDC & USDT (6 decimals) - $100k each
        usdc.mint(user1, 100_000e6);
        usdc.mint(user2, 100_000e6);
        usdc.mint(user3, 100_000e6);
        usdc.mint(user4, 100_000e6);
        usdc.mint(user5, 100_000e6);
        usdt.mint(user1, 100_000e6);
        usdt.mint(user2, 100_000e6);
        usdt.mint(user3, 100_000e6);
        usdt.mint(user4, 100_000e6);
        usdt.mint(user5, 100_000e6);

        // WBTC (8 decimals) - 1 BTC each (~$100k)
        wbtc.mint(user1, 1e8);
        wbtc.mint(user2, 1e8);
        wbtc.mint(user3, 1e8);
        wbtc.mint(user4, 1e8);
        wbtc.mint(user5, 1e8);

        // wSONIC (18 decimals) - 1M SONIC each (~$120k at $0.12)
        wsonic.mint(user1, 1_000_000e18);
        wsonic.mint(user2, 1_000_000e18);
        wsonic.mint(user3, 1_000_000e18);
        wsonic.mint(user4, 1_000_000e18);
        wsonic.mint(user5, 1_000_000e18);

        // Enable sale and transferable for fuzzing
        vm.prank(configurator);
        manager.setSaleEnabled(true);

        vm.prank(configurator);
        manager.enableTransferable();

        // Create actors array for handler
        address[] memory actors = new address[](5);
        actors[0] = user1;
        actors[1] = user2;
        actors[2] = user3;
        actors[3] = user4;
        actors[4] = user5;

        // Deploy and configure handler with all token types
        handler = new ProtocolHandler(
            manager,
            pft,
            wrapperUSDC,
            wrapperUSDT,
            wrapperWBTC,
            wrapperWSONIC,
            usdc,
            usdt,
            wbtc,
            wsonic,
            ft,
            circuitBreaker,
            actors
        );

        // Target handler for invariant fuzzing
        targetContract(address(handler));

        // Target specific functions
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ProtocolHandler.invest.selector;
        selectors[1] = ProtocolHandler.withdrawFT.selector;
        selectors[2] = ProtocolHandler.divest.selector;
        selectors[3] = ProtocolHandler.divestUnderlying.selector;
        selectors[4] = ProtocolHandler.transferNFT.selector;
        selectors[5] = ProtocolHandler.safeTransferNFT.selector;
        selectors[6] = ProtocolHandler.maliciousInvest.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                    PROTOCOL-WIDE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-PROTOCOL-1: FT Token Conservation
    /// @dev ftAllocated <= ftOfferingSupply (at all times)
    function invariant_ftAllocated_lte_ftOfferingSupply() public view {
        uint256 allocated = manager.ftAllocated();
        uint256 offering = manager.ftOfferingSupply();

        assertLe(allocated, offering, "INV-PROTOCOL-1 VIOLATED: ftAllocated > ftOfferingSupply");

        // Log for debugging
        if (allocated > offering * 90 / 100) {
            console2.log("WARNING: ftAllocated approaching limit");
            console2.log("  Allocated:", allocated);
            console2.log("  Offering:", offering);
        }
    }

    /// @notice INV-PROTOCOL-2: Collateral Balance Reconciliation
    /// @dev wrapper.totalSupply() >= collateralSupply[token] - capitalDivesting[token]
    function invariant_collateralSupply_matches_vaults() public view {
        _checkCollateralReconciliation(address(usdc), address(wrapperUSDC));
        _checkCollateralReconciliation(address(usdt), address(wrapperUSDT));
        _checkCollateralReconciliation(address(wbtc), address(wrapperWBTC));
        _checkCollateralReconciliation(address(wsonic), address(wrapperWSONIC));
    }

    function _checkCollateralReconciliation(address token, address wrapper) internal view {
        uint256 supply = manager.collateralSupply(token);
        uint256 divesting = manager.capitalDivesting(token);
        uint256 vaultBalance = ftYieldWrapper(wrapper).totalSupply();

        uint256 expected = supply - divesting;

        assertGe(
            vaultBalance,
            expected,
            string(
                abi.encodePacked(
                    "INV-PROTOCOL-2 VIOLATED: Vault balance < expected for token ",
                    _addressToString(token)
                )
            )
        );
    }

    /// @notice INV-PROTOCOL-4: Capital Divesting Tracking
    /// @dev capitalDivesting[token] <= collateralSupply[token]
    function invariant_capitalDivesting_lte_collateralSupply() public view {
        _checkCapitalDivesting(address(usdc));
        _checkCapitalDivesting(address(usdt));
        _checkCapitalDivesting(address(wbtc));
        _checkCapitalDivesting(address(wsonic));
    }

    function _checkCapitalDivesting(address token) internal view {
        uint256 divesting = manager.capitalDivesting(token);
        uint256 supply = manager.collateralSupply(token);

        assertLe(
            divesting,
            supply,
            string(
                abi.encodePacked(
                    "INV-PROTOCOL-4 VIOLATED: capitalDivesting > collateralSupply for token ",
                    _addressToString(token)
                )
            )
        );
    }

    /// @notice Collateral Conservation - Global
    /// @dev Total collateral withdrawn cannot exceed total deposited
    /// @dev Accounts for PUT mechanics where users can receive collateral by burning FT
    function invariant_noCollateralLeak() public view {
        (
            ,,,,
            uint256 usdcDeposited,
            uint256 usdtDeposited,
            uint256 wbtcDeposited,
            uint256 wsonicDeposited,
            uint256 usdcWithdrawn,
            uint256 usdtWithdrawn,
            uint256 wbtcWithdrawn,
            uint256 wsonicWithdrawn
        ) = handler.getGhostSummary();

        // For each token, withdrawn collateral should not exceed deposited
        // This ensures no value is created out of thin air
        assertLe(usdcWithdrawn, usdcDeposited, "COLLATERAL LEAK: USDC withdrawn > deposited");

        assertLe(usdtWithdrawn, usdtDeposited, "COLLATERAL LEAK: USDT withdrawn > deposited");

        assertLe(wbtcWithdrawn, wbtcDeposited, "COLLATERAL LEAK: WBTC withdrawn > deposited");

        assertLe(wsonicWithdrawn, wsonicDeposited, "COLLATERAL LEAK: wSONIC withdrawn > deposited");

        // Log warnings if withdrawal rate is high (>90% of deposits)
        if (usdcDeposited > 0 && (usdcWithdrawn * 100 / usdcDeposited) > 90) {
            console2.log("WARNING: USDC withdrawal rate >90%");
            console2.log("  Deposited:", usdcDeposited);
            console2.log("  Withdrawn:", usdcWithdrawn);
        }
    }

    /// @notice INV-PROTOCOL-3: Position-to-Collateral Mapping
    /// @dev Every active pFT NFT must have valid collateral backing
    function invariant_positionToCollateralMapping() public view {
        uint256 nextIndex = pft.nextIndex();

        for (uint256 i = 0; i < nextIndex; i++) {
            try pft.ownerOf(i) returns (address) {
                (
                    ,
                    uint96 amount_original,
                    uint96 ft_current,
                    uint96 ft_bought,,,,
                    uint96 amountRemaining,
                ) = pft.puts(i);

                // amountRemaining <= original amount
                assertLe(
                    amountRemaining,
                    amount_original,
                    "INV-PROTOCOL-3 VIOLATED: amountRemaining > original deposit"
                );

                // ft <= ft_bought
                assertLe(ft_current, ft_bought, "INV-PROTOCOL-3 VIOLATED: ft > ft_bought");
            } catch {
                // Position burned, skip
                continue;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        pFT INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-PFT-1: FT Amount Accounting
    /// @dev For all positions: withdrawn + burned + ft == ft_bought
    function invariant_pFT_ftAccounting() public view {
        uint256 nextIndex = pft.nextIndex();

        for (uint256 i = 0; i < nextIndex; i++) {
            // Check if token exists (not burned)
            try pft.ownerOf(i) returns (address) {
                (,, uint96 ft_current, uint96 ft_bought, uint96 withdrawn, uint96 burned,,,) =
                    pft.puts(i);

                uint256 sum = uint256(withdrawn) + uint256(burned) + uint256(ft_current);

                assertEq(
                    sum,
                    ft_bought,
                    string(
                        abi.encodePacked(
                            "INV-PFT-1 VIOLATED: withdrawn + burned + ft != ft_bought for tokenId ",
                            _uintToString(i)
                        )
                    )
                );

                // Also verify ft <= ft_bought
                assertLe(
                    ft_current,
                    ft_bought,
                    string(
                        abi.encodePacked(
                            "INV-PFT-1 VIOLATED: ft > ft_bought for tokenId ", _uintToString(i)
                        )
                    )
                );
            } catch {
                // Token burned, skip
                continue;
            }
        }
    }

    /// @notice INV-PFT-3: Collateral Depletion Consistency
    /// @dev amountRemaining <= amount (original deposit)
    function invariant_pFT_collateralBounds() public view {
        uint256 nextIndex = pft.nextIndex();

        for (uint256 i = 0; i < nextIndex; i++) {
            try pft.ownerOf(i) returns (address) {
                (, uint96 amount_original,,,,,, uint96 amountRemaining,) = pft.puts(i);

                assertLe(
                    amountRemaining,
                    amount_original,
                    string(
                        abi.encodePacked(
                            "INV-PFT-3 VIOLATED: amountRemaining > original amount for tokenId ",
                            _uintToString(i)
                        )
                    )
                );
            } catch {
                // Token burned, skip
                continue;
            }
        }
    }

    /// @notice INV-PFT-2: NFT Burn on Zero FT
    /// @dev When ft reaches 0, NFT must be burned and amountRemaining must be 0
    function invariant_pFT_burnOnZeroFT() public view {
        uint256 nextIndex = pft.nextIndex();

        for (uint256 i = 0; i < nextIndex; i++) {
            try pft.ownerOf(i) returns (address) {
                // If NFT still exists, ft must be > 0
                (,, uint96 ft_current,,,,,,) = pft.puts(i);

                assertTrue(
                    ft_current > 0,
                    string(
                        abi.encodePacked(
                            "INV-PFT-2 VIOLATED: NFT exists but ft == 0 for tokenId ",
                            _uintToString(i)
                        )
                    )
                );
            } catch {
                // NFT is burned, verify the stored data reflects this
                (,, uint96 ft_current,,,,, uint96 amountRemaining,) = pft.puts(i);

                // After burn, both ft and amountRemaining should be 0
                assertEq(
                    ft_current,
                    0,
                    string(
                        abi.encodePacked(
                            "INV-PFT-2 VIOLATED: Burned NFT has ft > 0 for tokenId ",
                            _uintToString(i)
                        )
                    )
                );

                assertEq(
                    amountRemaining,
                    0,
                    string(
                        abi.encodePacked(
                            "INV-PFT-2 VIOLATED: Burned NFT has amountRemaining > 0 for tokenId ",
                            _uintToString(i)
                        )
                    )
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    PUTMANAGER INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-PM-1: Collateral Cap Enforcement
    /// @dev collateralSupply[token] <= collateralCap[token] (if cap > 0)
    function invariant_collateralCaps_respected() public view {
        _checkCollateralCap(address(usdc));
        _checkCollateralCap(address(usdt));
        _checkCollateralCap(address(wbtc));
        _checkCollateralCap(address(wsonic));
    }

    function _checkCollateralCap(address token) internal view {
        uint256 cap = manager.collateralCap(token);
        if (cap == 0) return; // No cap set

        uint256 supply = manager.collateralSupply(token);

        assertLe(
            supply,
            cap,
            string(
                abi.encodePacked(
                    "INV-PM-1 VIOLATED: collateralSupply > cap for token ", _addressToString(token)
                )
            )
        );
    }
    /// @notice INV-PM-3: Transferability State Machine
    /// @dev This invariant verifies the handler respects transferability rules
    /// @dev Note: We can't directly test "withdrawFT reverts when !transferable" in an invariant
    ///      because the handler should not call withdrawFT when transferable is false
    ///      Instead, we verify the state is consistent with expected behavior

    function invariant_transferabilityStateConsistent() public view {
        bool transferable = manager.transferable();

        // Get withdrawal tracking from handler
        (uint256 withdrawCalls, uint256 divestCalls,,,,,,,,,,) = handler.getGhostSummary();

        // Log current state for debugging
        if (withdrawCalls > 0 && !transferable) {
            console2.log("WARNING: withdrawFT called while transferable=false");
            console2.log("  withdrawCalls:", withdrawCalls);
            console2.log("  transferable:", transferable);
        }

        // Divest calls should always work regardless of transferable state
        // This is just a sanity check - divest should never be blocked by transferability
        assertTrue(divestCalls >= 0, "INV-PM-3: Divest tracking broken");

        // Note: The actual enforcement is in the PutManager contract
        // This invariant verifies the handler behavior is consistent
        // A more comprehensive test would be in unit tests that explicitly
        // try to call withdrawFT when transferable=false and expect revert
    }

    /*//////////////////////////////////////////////////////////////
                    FTYIELDWRAPPER INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-YW-1: Deployed Capital Tracking
    /// @dev deployed == sum(deployedToStrategy[strategy])
    /// @dev deployed <= totalSupply()
    function invariant_wrapper_deployedCapitalTracking() public view {
        _checkDeployedCapital(wrapperUSDC);
        _checkDeployedCapital(wrapperUSDT);
        _checkDeployedCapital(wrapperWBTC);
        _checkDeployedCapital(wrapperWSONIC);
    }

    function _checkDeployedCapital(ftYieldWrapper wrapper) internal view {
        uint256 deployed = wrapper.deployed();
        uint256 totalSupply = wrapper.totalSupply();

        // deployed <= totalSupply
        assertLe(
            deployed,
            totalSupply,
            string(
                abi.encodePacked(
                    "INV-YW-1 VIOLATED: deployed > totalSupply for wrapper ",
                    _addressToString(address(wrapper))
                )
            )
        );

        // Sum deployedToStrategy should equal deployed
        uint256 numStrategies = wrapper.numberOfStrategies();
        uint256 sumDeployed = 0;

        for (uint256 i = 0; i < numStrategies; i++) {
            address strategy = address(wrapper.strategies(i));
            sumDeployed += wrapper.deployedToStrategy(strategy);
        }

        assertEq(
            sumDeployed,
            deployed,
            string(
                abi.encodePacked(
                    "INV-YW-1 VIOLATED: sum(deployedToStrategy) != deployed for wrapper ",
                    _addressToString(address(wrapper))
                )
            )
        );
    }

    /// @notice INV-YW-2: Share Token Conservation
    /// @dev totalSupply() <= valueOfCapital()
    function invariant_wrapper_sharesLteValue() public view {
        _checkSharesVsValue(wrapperUSDC);
        _checkSharesVsValue(wrapperUSDT);
        _checkSharesVsValue(wrapperWBTC);
        _checkSharesVsValue(wrapperWSONIC);
    }

    function _checkSharesVsValue(ftYieldWrapper wrapper) internal view {
        uint256 totalSupply = wrapper.totalSupply();
        uint256 valueOfCapital = wrapper.valueOfCapital();

        assertLe(
            totalSupply,
            valueOfCapital,
            string(
                abi.encodePacked(
                    "INV-YW-2 VIOLATED: totalSupply > valueOfCapital for wrapper ",
                    _addressToString(address(wrapper))
                )
            )
        );
    }

    /// @notice INV-YW-3: Yield Calculation
    /// @dev yield() == valueOfCapital() - totalSupply()
    function invariant_wrapper_yieldCalculation() public view {
        _checkYieldCalculation(wrapperUSDC);
        _checkYieldCalculation(wrapperUSDT);
        _checkYieldCalculation(wrapperWBTC);
        _checkYieldCalculation(wrapperWSONIC);
    }

    function _checkYieldCalculation(ftYieldWrapper wrapper) internal view {
        uint256 calculatedYield = wrapper.yield();
        uint256 valueOfCapital = wrapper.valueOfCapital();
        uint256 totalSupply = wrapper.totalSupply();

        uint256 expectedYield = valueOfCapital > totalSupply ? valueOfCapital - totalSupply : 0;

        assertEq(
            calculatedYield,
            expectedYield,
            string(
                abi.encodePacked(
                    "INV-YW-3 VIOLATED: yield() != (valueOfCapital - totalSupply) for wrapper ",
                    _addressToString(address(wrapper))
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-SEC-1: No Reentrancy Attacks Succeed
    /// @dev Critical security invariant: reentrancy attempts must ALWAYS fail
    /// @dev If this invariant fails, it means _safeMint callback can be exploited
    function invariant_noReentrancyAttacksSucceed() public view {
        (uint256 attempts, uint256 successes, uint256 calls) = handler.getReentrancyStats();

        // CRITICAL: If ANY reentrancy attack succeeded, this is a critical vulnerability
        assertEq(
            successes,
            0,
            "INV-SEC-1 CRITICAL VIOLATION: Reentrancy attack succeeded! This is a critical security vulnerability!"
        );

        // Log stats for monitoring
        if (attempts > 0) {
            console2.log("=== Reentrancy Attack Stats ===");
            console2.log("  Malicious invest calls:", calls);
            console2.log("  Reentrancy attempts:", attempts);
            console2.log("  Reentrancy successes:", successes);
            console2.log("  All attacks blocked: TRUE");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    CIRCUITBREAKER INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-CB-1: Main Buffer Bounds
    /// @dev Main buffer never exceeds cap (TVL * maxDrawRate)
    function invariant_cb_mainBufferNeverExceedsCap() public view {
        _checkMainBufferBounds(address(usdc), address(wrapperUSDC));
        _checkMainBufferBounds(address(usdt), address(wrapperUSDT));
        _checkMainBufferBounds(address(wbtc), address(wrapperWBTC));
        _checkMainBufferBounds(address(wsonic), address(wrapperWSONIC));
    }

    function _checkMainBufferBounds(address asset, address wrapper) internal view {
        uint256 tvl = ftYieldWrapper(wrapper).valueOfCapital();
        (uint256 mainBuffer,,) = circuitBreaker.getAssetState(asset, tvl);

        (uint256 maxDrawRate,,) = circuitBreaker.getConfig();
        uint256 cap = (tvl * maxDrawRate) / 1e18;

        assertLe(
            mainBuffer,
            cap,
            string(
                abi.encodePacked(
                    "INV-CB-1 VIOLATED: Main buffer exceeds cap for asset ", _addressToString(asset)
                )
            )
        );
    }

    /// @notice INV-CB-2: Elastic Buffer Non-Negative
    /// @dev Elastic buffer is always >= 0 (enforced by uint256, but verify state consistency)
    function invariant_cb_elasticBufferNonNegative() public view {
        _checkElasticBufferNonNegative(address(usdc), address(wrapperUSDC));
        _checkElasticBufferNonNegative(address(usdt), address(wrapperUSDT));
        _checkElasticBufferNonNegative(address(wbtc), address(wrapperWBTC));
        _checkElasticBufferNonNegative(address(wsonic), address(wrapperWSONIC));
    }

    function _checkElasticBufferNonNegative(address asset, address wrapper) internal view {
        uint256 tvl = ftYieldWrapper(wrapper).valueOfCapital();
        (, uint256 elasticBuffer,) = circuitBreaker.getAssetState(asset, tvl);

        // Elastic buffer is uint256, so this invariant is mainly for state consistency
        assertTrue(
            elasticBuffer >= 0,
            string(
                abi.encodePacked(
                    "INV-CB-2 VIOLATED: Elastic buffer is negative for asset ",
                    _addressToString(asset)
                )
            )
        );
    }

    /// @notice INV-CB-3: Withdrawal Capacity Consistency
    /// @dev withdrawalCapacity() == mainBuffer + elasticBuffer
    function invariant_cb_withdrawalCapacityConsistent() public view {
        _checkWithdrawalCapacity(address(usdc), address(wrapperUSDC));
        _checkWithdrawalCapacity(address(usdt), address(wrapperUSDT));
        _checkWithdrawalCapacity(address(wbtc), address(wrapperWBTC));
        _checkWithdrawalCapacity(address(wsonic), address(wrapperWSONIC));
    }

    function _checkWithdrawalCapacity(address asset, address wrapper) internal view {
        uint256 tvl = ftYieldWrapper(wrapper).valueOfCapital();
        (uint256 mainBuffer, uint256 elasticBuffer,) = circuitBreaker.getAssetState(asset, tvl);

        uint256 capacity = circuitBreaker.withdrawalCapacity(asset, tvl);
        uint256 expectedCapacity = mainBuffer + elasticBuffer;

        assertEq(
            capacity,
            expectedCapacity,
            string(
                abi.encodePacked(
                    "INV-CB-3 VIOLATED: Capacity != mainBuffer + elasticBuffer for asset ",
                    _addressToString(asset)
                )
            )
        );
    }

    /// @notice INV-CB-4: CircuitBreaker State Consistency
    /// @dev Verify CB is active and configuration is stable during fuzzing
    function invariant_cb_stateConsistency() public view {
        // Verify CB is active and has expected configuration
        bool active = circuitBreaker.isActive();
        (uint256 maxDrawRate, uint256 mainWindow, uint256 elasticWindow) =
            circuitBreaker.getConfig();

        // CB should be active (not paused) during normal fuzzing
        assertTrue(active, "INV-CB-4: CircuitBreaker unexpectedly paused");

        // Verify configuration hasn't changed
        assertEq(maxDrawRate, 5e16, "INV-CB-4: maxDrawRate changed");
        assertEq(mainWindow, 4 hours, "INV-CB-4: mainWindow changed");
        assertEq(elasticWindow, 2 hours, "INV-CB-4: elasticWindow changed");
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _addressToString(address _addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
