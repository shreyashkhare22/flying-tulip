// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "../mocks/MockOracles.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {pFT} from "contracts/pFT.sol";
import {PutManager} from "contracts/PutManager.sol";
import {CircuitBreaker} from "contracts/cb/CircuitBreaker.sol";
import {ICircuitBreaker} from "contracts/interfaces/ICircuitBreaker.sol";
import {MerkleHelper} from "../helpers/MerkleHelper.sol";

/// @notice Integration tests for CircuitBreaker with full protocol stack
contract CircuitBreakerIntegrationTest is Test {
    // Target 1B TVL for realistic testing
    // FT Token Price: $0.10 per FT
    // 1B USDC investment requires 10B FT tokens at $0.10 price
    uint256 internal constant INITIAL_USDC_BALANCE = 500_000_000 * 1e6; // 500M per investor
    uint256 internal constant DEFAULT_FT_LIQUIDITY = 10_000_000_000 * 1e18; // 10B FT at $0.10 = $1B
    uint256 internal constant DEFAULT_INVEST_AMOUNT = 1_000_000_000 * 1e6; // 1B USDC TVL

    // Circuit breaker defaults: 5% rate, 4h main window, 2h elastic window
    uint256 internal constant CB_MAX_DRAW_RATE = 5e16; // 5%
    uint256 internal constant CB_MAIN_WINDOW = 4 hours;
    uint256 internal constant CB_ELASTIC_WINDOW = 2 hours;

    struct Context {
        address msig;
        address configurator;
        address yieldClaimer;
        address strategyManager;
        address treasury;
        address investor1;
        address investor2;
        address cbAdmin;
        MockERC20 ftToken;
        MockERC20 usdc;
        ftYieldWrapper wrapper;
        MockFlyingTulipOracle oracle;
        pFT ftput;
        PutManager putManager;
        CircuitBreaker circuitBreaker;
    }

    struct Position {
        uint256 id;
        uint256 initialFt;
        uint256 strike;
        uint256 amount;
    }

    function _deployFixture() internal returns (Context memory ctx) {
        ctx.msig = makeAddr("msig");
        ctx.configurator = makeAddr("configurator");
        ctx.yieldClaimer = makeAddr("yieldClaimer");
        ctx.strategyManager = makeAddr("strategyManager");
        ctx.treasury = makeAddr("treasury");
        ctx.investor1 = makeAddr("investor1");
        ctx.investor2 = makeAddr("investor2");
        ctx.cbAdmin = makeAddr("cbAdmin");

        ctx.ftToken = new MockERC20("Flying Tulip", "FT", 18);
        ctx.usdc = new MockERC20("USD Coin", "USDC", 6);

        ctx.wrapper = new ftYieldWrapper(
            address(ctx.usdc), ctx.yieldClaimer, ctx.strategyManager, ctx.treasury
        );

        ctx.oracle = new MockFlyingTulipOracle();
        ctx.oracle.setAssetPrice(address(ctx.usdc), 1e8);

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        ctx.ftput = pFT(address(pftProxy));

        PutManager impl = new PutManager(address(ctx.ftToken), address(ctx.ftput));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, ctx.configurator, ctx.msig, address(ctx.oracle)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ctx.putManager = PutManager(address(proxy));

        vm.prank(ctx.configurator);
        ctx.ftput.initialize(address(ctx.putManager));

        vm.prank(ctx.strategyManager);
        ctx.wrapper.setPutManager(address(ctx.putManager));

        // Deploy CircuitBreaker
        vm.prank(ctx.cbAdmin);
        ctx.circuitBreaker = new CircuitBreaker(CB_MAX_DRAW_RATE, CB_MAIN_WINDOW, CB_ELASTIC_WINDOW);

        // Register wrapper as protected contract
        vm.prank(ctx.cbAdmin);
        ctx.circuitBreaker.addProtectedContract(address(ctx.wrapper));

        // Set CircuitBreaker on wrapper
        vm.prank(ctx.strategyManager);
        ctx.wrapper.setCircuitBreaker(address(ctx.circuitBreaker));

        // Mint 10B FT tokens to configurator (enough for 1B USDC at $0.10/FT price)
        ctx.ftToken.mint(ctx.configurator, 10_000_000_000 * 1e18);
        vm.startPrank(ctx.configurator);
        ctx.ftToken.approve(address(ctx.putManager), type(uint256).max);
        vm.stopPrank();

        ctx.usdc.mint(ctx.investor1, INITIAL_USDC_BALANCE);
        ctx.usdc.mint(ctx.investor2, INITIAL_USDC_BALANCE);

        vm.prank(ctx.investor1);
        ctx.usdc.approve(address(ctx.putManager), type(uint256).max);

        vm.prank(ctx.investor2);
        ctx.usdc.approve(address(ctx.putManager), type(uint256).max);

        return ctx;
    }

    function _addCollateralAndLiquidity(Context memory ctx, uint256 ftLiquidity) internal {
        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));
        vm.prank(ctx.configurator);
        ctx.putManager.setCollateralCaps(address(ctx.usdc), type(uint256).max);
        vm.prank(ctx.configurator);
        ctx.putManager.addFTLiquidity(ftLiquidity);
    }

    function _addCollateralAndLiquidity(Context memory ctx) internal {
        _addCollateralAndLiquidity(ctx, DEFAULT_FT_LIQUIDITY);
    }

    function _investPosition(
        Context memory ctx,
        uint256 amount
    )
        internal
        returns (Position memory pos)
    {
        vm.prank(ctx.investor1);
        uint256 id = ctx.putManager.invest(address(ctx.usdc), amount, 0, MerkleHelper.emptyProof());
        (uint256 ftAmount, uint256 strike,) =
            ctx.putManager.getAssetFTPrice(address(ctx.usdc), amount);
        pos = Position({id: id, initialFt: ftAmount, strike: strike, amount: amount});
    }

    function _investPosition(Context memory ctx) internal returns (Position memory pos) {
        // Default to invest 500M from investor1 (half their balance)
        return _investPosition(ctx, 500_000_000 * 1e6);
    }

    function _setupPostOffering() internal returns (Context memory ctx, Position memory pos) {
        ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);
        pos = _investPosition(ctx);
        vm.prank(ctx.configurator);
        ctx.putManager.enableTransferable();
    }

    function collateralFromFT(
        uint256 amountFt,
        uint256 strike,
        uint256 decimals
    )
        internal
        pure
        returns (uint256)
    {
        uint256 scale = 10 ** decimals;
        return (amountFt * 1e8 * scale) / (strike * 10 * 1e18);
    }

    // ============ Integration Tests ============

    function test_InvestFlow_WithCB_RecordsInflow() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        uint256 tvlBefore = ctx.wrapper.valueOfCapital();

        Position memory pos = _investPosition(ctx);

        // Verify position was created
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), 500_000_000 * 1e6);
        assertEq(ctx.putManager.ftAllocated(), pos.initialFt);

        // Verify CB elastic buffer increased (invested 500M)
        uint256 tvlAfter = ctx.wrapper.valueOfCapital();
        (, uint256 elasticBuffer,) = ctx.circuitBreaker.getAssetState(address(ctx.usdc), tvlAfter);
        assertEq(elasticBuffer, 500_000_000 * 1e6, "Elastic buffer should match deposit");
    }

    function test_DivestFlow_WithCB_ChecksOutflow() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);
        Position memory pos = _investPosition(ctx);

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        // Verify position burned
        assertEq(ctx.putManager.ftAllocated(), 0);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), 0);

        // Verify investor received USDC back
        assertGt(ctx.usdc.balanceOf(ctx.investor1), 0, "Investor should have received USDC");
    }

    function test_PostOfferingDivest_WithCB_ChecksOutflow() public {
        (Context memory ctx, Position memory pos) = _setupPostOffering();

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        // Verify position burned
        assertEq(ctx.putManager.ftAllocated(), 0);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), 0);

        // Verify investor received USDC
        assertGt(ctx.usdc.balanceOf(ctx.investor1), 0, "Investor should have received USDC");
    }

    function test_MultipleInvestors_WithCB_IndependentTracking() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Investor1 invests 500M
        Position memory pos1 = _investPosition(ctx, 500_000_000 * 1e6);
        uint256 tvlAfter1 = ctx.wrapper.valueOfCapital();

        // Check elastic buffer after first deposit
        (, uint256 elastic1,) = ctx.circuitBreaker.getAssetState(address(ctx.usdc), tvlAfter1);
        assertEq(elastic1, 500_000_000 * 1e6);

        // Investor2 invests 500M
        vm.prank(ctx.investor2);
        ctx.putManager.invest(address(ctx.usdc), 500_000_000 * 1e6, 0, MerkleHelper.emptyProof());
        uint256 tvlAfter2 = ctx.wrapper.valueOfCapital();

        // Check elastic buffer accumulated both deposits (1B total)
        (, uint256 elastic2,) = ctx.circuitBreaker.getAssetState(address(ctx.usdc), tvlAfter2);
        assertEq(elastic2, 1_000_000_000 * 1e6, "Elastic buffer should accumulate deposits");

        // Investor1 divests
        uint256 collateral1 = collateralFromFT(pos1.initialFt, pos1.strike, 6);
        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos1.id, pos1.initialFt);

        // Verify investor1's position burned and CB consumed elastic buffer first
        assertEq(
            ctx.usdc.balanceOf(ctx.investor1),
            INITIAL_USDC_BALANCE - 500_000_000 * 1e6 + collateral1
        );
    }

    function test_RateLimit_WithCB_BlocksExcessiveWithdrawal() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Investor1 deposits 500M
        Position memory pos = _investPosition(ctx);
        uint256 tvl = ctx.wrapper.valueOfCapital();

        // Calculate rate limit: 5% of 500M TVL = 25M
        uint256 maxWithdrawal = (tvl * CB_MAX_DRAW_RATE) / 1e18;
        assertEq(maxWithdrawal, 25_000_000 * 1e6, "Max withdrawal should be 25M (5% of 500M)");

        // Warp time to deplete elastic buffer
        vm.warp(block.timestamp + CB_ELASTIC_WINDOW + 1);

        // Try to withdraw entire 500M (far exceeds 25M limit)
        uint256 excessiveAmount = collateralFromFT(pos.initialFt, pos.strike, 6);
        assertGt(excessiveAmount, maxWithdrawal, "Test should withdraw more than limit");

        // Attempt divest - should be blocked by rate limit
        vm.expectRevert();
        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        // Verify position still exists (divest failed)
        assertGt(
            ctx.putManager.ftAllocated(), 0, "Position should still exist after failed withdrawal"
        );
    }

    function test_CB_Paused_AllowsAllTransactions() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Investor deposits 1B
        Position memory pos = _investPosition(ctx);

        // Warp time to deplete elastic buffer
        vm.warp(block.timestamp + CB_ELASTIC_WINDOW + 1);

        // Pause CB
        vm.prank(ctx.cbAdmin);
        ctx.circuitBreaker.pause();

        // Divest entire 1B should succeed even though it normally exceeds rate limit
        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        // Verify divest succeeded
        assertEq(ctx.putManager.ftAllocated(), 0);
    }

    function test_CB_Disabled_AllowsAllTransactions() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Investor deposits 1B
        Position memory pos = _investPosition(ctx);

        // Warp time to deplete elastic buffer
        vm.warp(block.timestamp + CB_ELASTIC_WINDOW + 1);

        // Disable CB by setting to address(0)
        vm.prank(ctx.strategyManager);
        ctx.wrapper.setCircuitBreaker(address(0));

        // Divest entire 1B should succeed without CB checks
        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        assertEq(ctx.putManager.ftAllocated(), 0);
    }

    function test_FailOpen_MaliciousCB_AllowsTransactions() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Deploy malicious CB that always reverts
        MaliciousCircuitBreaker maliciousCB = new MaliciousCircuitBreaker();

        // Set malicious CB on wrapper
        vm.prank(ctx.strategyManager);
        ctx.wrapper.setCircuitBreaker(address(maliciousCB));

        // Deposit should succeed despite CB reverting (fail-open on inflow)
        Position memory pos = _investPosition(ctx, 100_000_000 * 1e6); // 100M
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), 100_000_000 * 1e6);

        // Withdrawal should succeed despite CB reverting (fail-open on outflow returns false)
        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);
        assertEq(ctx.putManager.ftAllocated(), 0);
    }

    function test_BufferReplenishment_AllowsWithdrawalAfterWait() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Investor deposits 500M
        Position memory pos = _investPosition(ctx);

        // Warp time to deplete elastic buffer (500M elastic decays to 0)
        vm.warp(block.timestamp + CB_ELASTIC_WINDOW + 1);

        // Get current TVL and capacity
        uint256 tvlNow = ctx.wrapper.valueOfCapital();
        uint256 capacityBefore = ctx.circuitBreaker.withdrawalCapacity(address(ctx.usdc), tvlNow);

        // Warp time to allow main buffer to fully replenish
        vm.warp(block.timestamp + CB_MAIN_WINDOW);

        // Capacity should still be at 5% of current TVL (main buffer fully replenished)
        uint256 capacityAfter = ctx.circuitBreaker.withdrawalCapacity(address(ctx.usdc), tvlNow);
        assertGe(capacityAfter, capacityBefore, "Capacity should not decrease after time passes");

        // Small withdrawal should succeed
        uint256 ftToWithdraw = pos.initialFt / 20; // Withdraw 5% of position

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, ftToWithdraw);

        assertGt(ctx.usdc.balanceOf(ctx.investor1), 0, "Should have received USDC");
    }

    function test_EmergencyOverride_IncreasesCapacity() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        // Investor deposits 500M
        Position memory pos = _investPosition(ctx);
        uint256 tvl = ctx.wrapper.valueOfCapital();

        // Warp time to deplete elastic buffer
        vm.warp(block.timestamp + CB_ELASTIC_WINDOW + 1);

        // Check capacity before override
        uint256 capacityBefore = ctx.circuitBreaker.withdrawalCapacity(address(ctx.usdc), tvl);

        // Admin uses emergency override
        vm.prank(ctx.cbAdmin);
        ctx.circuitBreaker.emergencyOverride(address(ctx.usdc), 100_000_000 * 1e6); // Add 100M

        // Capacity should have increased
        uint256 capacityAfter = ctx.circuitBreaker.withdrawalCapacity(address(ctx.usdc), tvl);
        assertGt(capacityAfter, capacityBefore, "Emergency override should increase capacity");

        // Small withdrawal should now succeed (withdraw 2% which should be within new capacity)
        uint256 ftToWithdraw = pos.initialFt / 50;

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, ftToWithdraw);

        assertGt(ctx.usdc.balanceOf(ctx.investor1), 0, "Should have received USDC");
    }
}

/// @notice Malicious CircuitBreaker that always reverts to test fail-open behavior
contract MaliciousCircuitBreaker {
    error MaliciousRevert();

    function recordInflow(address, uint256, uint256) external pure {
        revert MaliciousRevert();
    }

    function checkAndRecordOutflow(address, uint256, uint256)
        external
        pure
        returns (bool, uint256)
    {
        revert MaliciousRevert();
    }

    function withdrawalCapacity(address, uint256) external pure returns (uint256) {
        revert MaliciousRevert();
    }

    function isActive() external pure returns (bool) {
        revert MaliciousRevert();
    }
}
