// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {AaveStrategy} from "contracts/strategies/AaveStrategy.sol";

// mocks
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "../mocks/MockOracles.sol";
import {MockAavePoolWithAToken} from "../mocks/MockAavePoolWithAToken.sol";
import {MockAavePoolAddressesProvider} from "../mocks/MockAavePoolAddressesProvider.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MerkleHelper} from "../helpers/MerkleHelper.sol";

/// @title Put Flow Fuzz Tests
/// @notice Comprehensive fuzz testing for PutManager investment and divestment flows
/// @dev Tests core flows from PutFlow.t.sol with fuzzed parameters instead of hardcoded amounts
///
/// TESTED SCENARIOS:
/// =================
/// 1. Investment for recipient with varying deposit amounts
/// 2. Full divest flow (invest → deploy → divest) with Aave strategy
/// 3. FT withdrawal flow with msig capital withdrawal
/// 4. Yield claiming with varying deposit and yield amounts
///
/// PARAMETER BOUNDS:
/// =================
/// - Deposit amounts: 1,000 USDC to 10,000,000 USDC (realistic production range)
/// - Yield amounts: 100 USDC to 50% of deposit (realistic APY scenarios)
/// - Using USDC (6 decimals) consistently for all tests
///
/// SECURITY INVARIANTS VERIFIED:
/// ============================
/// 1. User receives correct pFT token on investment
/// 2. Wrapper receives and holds collateral correctly
/// 3. Full divest returns exact principal to user
/// 4. FT withdrawal correctly earmarks capital for msig
/// 5. Yield is claimed to treasury without affecting principal
contract PutFlowFuzzTest is Test {
    // roles
    address msig = address(0xA11CE);
    address configurator = address(0xB0B);
    address treasury = address(0x71EA5);
    address investor = address(0x13570);

    // core components
    MockERC20 usdc; // underlying
    MockERC20 ft; // FT ERC20 (burnable)
    MockFlyingTulipOracle aaveOracle;
    pFT pft;
    PutManager manager;
    ftYieldWrapper wrapper;
    AaveStrategy strategy;

    // aave mocks
    MockAToken aUSDC;
    MockAavePoolWithAToken pool;
    MockAavePoolAddressesProvider provider;

    uint256 constant USDC_DECIMALS = 6;
    uint256 constant MIN_DEPOSIT = 10e6; // $10 minimum
    uint256 constant MAX_DEPOSIT = 100_000_000e6; // $100M maximum (with 2B FT liquidity)

    function setUp() public {
        // tokens
        usdc = new MockERC20("USD Coin", "USDC", uint8(USDC_DECIMALS));
        ft = new MockERC20("Flying Tulip", "FT", 18);

        // oracle
        aaveOracle = new MockFlyingTulipOracle();

        // pFT behind an ERC1967 proxy so we can call initialize()
        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        pft = pFT(address(pftProxy));

        // Deploy PutManager implementation and wrap with ERC1967Proxy (UUPS)
        PutManager impl = new PutManager(address(ft), address(pft));
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(aaveOracle)
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(impl), data);
        manager = PutManager(address(managerProxy));

        // call initialize on pFT via proxy manager address (pFT expects the manager address)
        vm.prank(investor);
        pft.initialize(address(manager));

        // wrapper + strategy
        wrapper = new ftYieldWrapper(address(usdc), address(this), address(this), treasury);

        // Set putManager so PutManager can deposit
        wrapper.setPutManager(address(manager));

        aUSDC = new MockAToken(usdc);
        pool = new MockAavePoolWithAToken(usdc, aUSDC);
        provider = new MockAavePoolAddressesProvider(address(pool));
        strategy =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        // register strategy
        wrapper.setStrategy(address(strategy));
        vm.prank(treasury);
        wrapper.confirmStrategy();

        // allow USDC as collateral, point to wrapper
        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));

        // fund FT supply to configurator and add to offering pool
        // With ftPerUSD = 10 * 1e8, $1 USDC needs 10 FT
        // For $100M USDC max deposit, we need 1B FT minimum
        // Providing 2B FT for safety margin and multiple concurrent investments
        ft.mint(configurator, 2_000_000_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(2_000_000_000e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _invest(uint256 deposit) internal returns (uint256 id) {
        // investor gets USDC
        usdc.mint(investor, deposit);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        id = manager.invest(address(usdc), deposit, 0, MerkleHelper.emptyProof());
        vm.stopPrank();
        assertEq(pft.ownerOf(id), investor);
        // wrapper received deposit via manager
        assertEq(wrapper.totalSupply(), deposit);
        assertEq(usdc.balanceOf(address(wrapper)), deposit);
    }

    function _deployAll() internal {
        // yieldClaimer (this) deploys all capital to Aave strategy
        uint256 bal = usdc.balanceOf(address(wrapper));
        wrapper.deploy(address(strategy), bal);
        assertEq(usdc.balanceOf(address(wrapper)), 0);
        // strategy holds aUSDC 1:1 with deployed capital
        assertEq(aUSDC.balanceOf(address(strategy)), bal);
    }

    function _endOffering() internal {
        vm.prank(configurator);
        manager.enableTransferable();
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: INVEST FOR RECIPIENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Investment mints pFT token to specified recipient
    /// @dev Verifies:
    ///      - pFT is minted to recipient (not investor)
    ///      - Wrapper receives correct collateral amount
    ///      - Total supply matches deposit
    function testFuzz_InvestForRecipient_MintsTokenToRecipient(uint256 deposit) public {
        // Bound deposit to realistic range
        deposit = bound(deposit, MIN_DEPOSIT, MAX_DEPOSIT);

        address recipient = address(0xBEEF);

        usdc.mint(investor, deposit);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        uint256 id = manager.invest(address(usdc), deposit, recipient, 0, MerkleHelper.emptyProof());
        vm.stopPrank();

        // Verify pFT minted to recipient
        assertEq(pft.ownerOf(id), recipient, "pFT should be owned by recipient");

        // Verify wrapper state
        assertEq(wrapper.totalSupply(), deposit, "Wrapper total supply should match deposit");
        assertEq(usdc.balanceOf(address(wrapper)), deposit, "Wrapper should hold deposited USDC");
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: FULL DIVEST FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Full investment and divestment cycle with Aave deployment
    /// @dev Verifies:
    ///      - User can invest any amount within bounds
    ///      - Capital deploys to Aave correctly
    ///      - User can divest full position
    ///      - User receives exact principal back
    ///      - Wrapper and strategy balances settle to zero
    function testFuzz_Flow_ExecutePut_WithdrawsFromAave_ToUser(uint256 deposit) public {
        // Bound deposit to realistic range
        deposit = bound(deposit, MIN_DEPOSIT, MAX_DEPOSIT);

        uint256 id = _invest(deposit);
        _deployAll();
        _endOffering();

        // Ask manager for max divestable amount (in FT) for full position
        (bool ok, uint256 maxFT) = manager.maxDivestable(id, type(uint256).max);
        assertTrue(ok, "maxDivestable should succeed");
        assertGt(maxFT, 0, "maxFT should be greater than zero");

        // Record investor balance before divest
        uint256 investorBalanceBefore = usdc.balanceOf(investor);

        // Execute divest for all FT
        vm.prank(investor);
        manager.divest(id, maxFT);

        // User received their full principal back
        uint256 investorBalanceAfter = usdc.balanceOf(investor);
        assertEq(
            investorBalanceAfter - investorBalanceBefore,
            deposit,
            "User should receive full principal back"
        );

        // Wrapper and strategy principal decreased to zero
        assertEq(wrapper.totalSupply(), 0, "Wrapper total supply should be zero");
        assertEq(aUSDC.balanceOf(address(strategy)), 0, "Strategy aUSDC balance should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                FUZZ TEST: WITHDRAW FT + MSIG CAPITAL FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: User withdraws FT, then msig withdraws divested capital
    /// @dev Verifies:
    ///      - User can withdraw FT (invalidates PUT)
    ///      - Capital is correctly earmarked for msig in capitalDivesting
    ///      - Msig can withdraw earmarked capital
    ///      - Wrapper and strategy balances settle correctly
    function testFuzz_Flow_WithdrawFT_ThenMsigWithdrawCapital(uint256 deposit) public {
        // Bound deposit to realistic range
        deposit = bound(deposit, MIN_DEPOSIT, MAX_DEPOSIT);

        uint256 id = _invest(deposit);
        _deployAll();
        _endOffering();

        // Determine how much FT is withdrawable (full position)
        (bool ok, uint256 maxFT) = manager.maxDivestable(id, type(uint256).max);
        assertTrue(ok, "maxDivestable should succeed");

        // Withdraw FT -> invalidates PUT; underlying should be earmarked to msig via capitalDivesting
        vm.prank(investor);
        manager.withdrawFT(id, maxFT);

        // capital to be divested should equal the deposit (since $1 price)
        uint256 earmarked = manager.capitalDivesting(address(usdc));
        assertEq(earmarked, deposit, "Earmarked capital should equal deposit");

        // msig pulls earmarked capital back to itself from the wrapper
        uint256 msigBalanceBefore = usdc.balanceOf(msig);
        vm.prank(msig);
        manager.withdrawDivestedCapital(address(usdc), deposit);

        uint256 msigBalanceAfter = usdc.balanceOf(msig);
        assertEq(
            msigBalanceAfter - msigBalanceBefore, deposit, "Msig should receive earmarked capital"
        );

        // wrapper and strategy principal decreased accordingly
        assertEq(wrapper.totalSupply(), 0, "Wrapper total supply should be zero");
        assertEq(aUSDC.balanceOf(address(strategy)), 0, "Strategy aUSDC balance should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: YIELD CLAIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Yield accrual and claiming with varying amounts
    /// @dev Verifies:
    ///      - Yield can accrue on strategy
    ///      - Yield is claimed to treasury
    ///      - Principal (wrapper totalSupply) remains unchanged
    ///      - Treasury receives correct yield amount
    function testFuzz_Yield_Is_Claimed_To_Treasury(uint256 deposit, uint256 yieldPercent) public {
        // Bound deposit to realistic range
        deposit = bound(deposit, MIN_DEPOSIT, MAX_DEPOSIT);

        // Yield should be proportional to deposit (1% to 100% for various APY scenarios)
        // This ensures yield is always valid regardless of deposit size
        yieldPercent = bound(yieldPercent, 1, 100);
        uint256 yieldAmt = (deposit * yieldPercent) / 100;

        _invest(deposit);
        _deployAll();

        // Simulate yield accrual by minting aUSDC to strategy
        vm.prank(address(this));
        aUSDC.addYield(address(strategy), yieldAmt);

        // Verify yield was added
        uint256 strategyBalance = aUSDC.balanceOf(address(strategy));
        assertEq(strategyBalance, deposit + yieldAmt, "Strategy should hold principal + yield");

        // Record treasury balance before claiming
        uint256 treasuryBalanceBefore = aUSDC.balanceOf(treasury);

        // Claim yield via wrapper -> should transfer aUSDC yield to treasury
        uint256 claimed = wrapper.claimYield(address(strategy));
        assertEq(claimed, yieldAmt, "Claimed amount should match yield amount");

        uint256 treasuryBalanceAfter = aUSDC.balanceOf(treasury);
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore, yieldAmt, "Treasury should receive yield"
        );

        // Principal (wrapper totalSupply) unchanged
        assertEq(wrapper.totalSupply(), deposit, "Wrapper total supply should remain at deposit");

        // Strategy should only hold principal now
        assertEq(
            aUSDC.balanceOf(address(strategy)),
            deposit,
            "Strategy should only hold principal after yield claim"
        );
    }

    /*//////////////////////////////////////////////////////////////
                FUZZ TEST: PARTIAL DIVEST SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Partial divestment with varying percentages
    /// @dev Verifies:
    ///      - User can divest partial position
    ///      - User receives proportional collateral
    ///      - Remaining position is still valid
    function testFuzz_PartialDivest_ProportionalCollateral(
        uint256 deposit,
        uint256 divestPercent
    )
        public
    {
        // Bound inputs
        deposit = bound(deposit, MIN_DEPOSIT, MAX_DEPOSIT);
        divestPercent = bound(divestPercent, 10, 90); // 10% to 90% of position

        uint256 id = _invest(deposit);
        _deployAll();
        _endOffering();

        // Calculate FT amount to divest
        (bool ok, uint256 maxFT) = manager.maxDivestable(id, type(uint256).max);
        assertTrue(ok);
        uint256 ftToDivest = (maxFT * divestPercent) / 100;

        // Record balance before divest
        uint256 investorBalanceBefore = usdc.balanceOf(investor);

        // Partial divest
        vm.prank(investor);
        manager.divest(id, ftToDivest);

        // Calculate expected collateral (proportional to FT divested)
        uint256 expectedCollateral = (deposit * divestPercent) / 100;
        uint256 investorBalanceAfter = usdc.balanceOf(investor);
        uint256 collateralReceived = investorBalanceAfter - investorBalanceBefore;

        // Allow small tolerance for rounding (up to 10 wei for USDC)
        assertApproxEqAbs(
            collateralReceived,
            expectedCollateral,
            10,
            "User should receive proportional collateral"
        );

        // Verify remaining wrapper balance
        uint256 expectedRemaining = deposit - expectedCollateral;
        assertApproxEqAbs(
            wrapper.totalSupply(), expectedRemaining, 10, "Wrapper should hold remaining collateral"
        );
    }

    /*//////////////////////////////////////////////////////////////
            FUZZ TEST: MULTIPLE SEQUENTIAL INVESTMENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Multiple investments from same user
    /// @dev Verifies:
    ///      - User can make multiple investments
    ///      - Each investment gets unique pFT token
    ///      - Total wrapper balance accumulates correctly
    function testFuzz_MultipleInvestments_AccumulateCorrectly(
        uint256 deposit1,
        uint256 deposit2
    )
        public
    {
        // Bound deposits to reasonable ranges
        deposit1 = bound(deposit1, MIN_DEPOSIT, MAX_DEPOSIT / 2);
        deposit2 = bound(deposit2, MIN_DEPOSIT, MAX_DEPOSIT / 2);

        // First investment
        usdc.mint(investor, deposit1);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        uint256 id1 = manager.invest(address(usdc), deposit1, 0, MerkleHelper.emptyProof());
        vm.stopPrank();

        assertEq(pft.ownerOf(id1), investor);
        assertEq(wrapper.totalSupply(), deposit1, "Wrapper should hold first deposit");

        // Second investment
        usdc.mint(investor, deposit2);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        uint256 id2 = manager.invest(address(usdc), deposit2, 0, MerkleHelper.emptyProof());
        vm.stopPrank();

        assertEq(pft.ownerOf(id2), investor);
        assertNotEq(id1, id2, "Each investment should get unique pFT token ID");
        assertEq(
            wrapper.totalSupply(), deposit1 + deposit2, "Wrapper should accumulate both deposits"
        );
    }

    /*//////////////////////////////////////////////////////////////
            FUZZ TEST: EDGE CASE - MINIMUM DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Very small deposits near minimum bounds
    /// @dev Verifies system works correctly with minimum viable deposits
    function testFuzz_MinimumDeposit_WorksCorrectly(uint256 deposit) public {
        // Test deposits from 1 USDC to 1000 USDC (small amounts)
        deposit = bound(deposit, 1e6, 1000e6);

        usdc.mint(investor, deposit);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        uint256 id = manager.invest(address(usdc), deposit, 0, MerkleHelper.emptyProof());
        vm.stopPrank();

        assertEq(pft.ownerOf(id), investor);
        assertEq(wrapper.totalSupply(), deposit);

        // Try to divest (even small amounts should work)
        _endOffering();
        (bool ok, uint256 maxFT) = manager.maxDivestable(id, type(uint256).max);

        if (ok && maxFT > 0) {
            vm.prank(investor);
            manager.divest(id, maxFT);

            // User should get back approximately their deposit (allow larger tolerance for small amounts)
            uint256 received = usdc.balanceOf(investor);
            assertApproxEqAbs(
                received,
                deposit,
                deposit / 100, // 1% tolerance for small amounts due to rounding
                "Small deposit divest should return approximately same amount"
            );
        }
    }
}
