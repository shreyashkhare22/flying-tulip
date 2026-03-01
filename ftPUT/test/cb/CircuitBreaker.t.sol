// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../contracts/cb/CircuitBreaker.sol";
import "../mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CircuitBreakerTest is Test {
    CircuitBreaker public cb;
    MockERC20 public asset;

    address public admin;
    address public wrapper;
    address public attacker;

    // Default config: 5% max draw rate, 4 hours main window, 2 hours elastic window
    uint256 constant DEFAULT_MAX_DRAW_RATE = 0.05e18; // 5%
    uint256 constant DEFAULT_MAIN_WINDOW = 4 hours;
    uint256 constant DEFAULT_ELASTIC_WINDOW = 2 hours;

    // Mirror events for expectEmit
    event Inflow(address indexed asset, uint256 amount, uint256 newTvl);
    event Outflow(address indexed asset, uint256 amount, uint256 newTvl);
    event RateLimitTriggered(address indexed asset, uint256 requested, uint256 available);
    event ConfigUpdated(uint256 maxDrawRateWad, uint256 mainWindow, uint256 elasticWindow);
    event CircuitBreakerPaused(address indexed by);
    event CircuitBreakerUnpaused(address indexed by);
    event EmergencyOverride(address indexed asset, uint256 amount);
    event ProtectedContractAdded(address indexed protectedContract);
    event ProtectedContractRemoved(address indexed protectedContract);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        admin = address(this);
        wrapper = makeAddr("wrapper");
        attacker = makeAddr("attacker");

        asset = new MockERC20("Test Asset", "TST", 18);
        cb = new CircuitBreaker(DEFAULT_MAX_DRAW_RATE, DEFAULT_MAIN_WINDOW, DEFAULT_ELASTIC_WINDOW);

        // Register wrapper as protected contract
        cb.addProtectedContract(wrapper);
    }

    // ============ Constructor Tests ============

    function test_Constructor_ValidParameters() public {
        CircuitBreaker newCb = new CircuitBreaker(0.05e18, 4 hours, 2 hours);

        (uint256 maxDrawRate, uint256 mainWindow, uint256 elasticWindow) = newCb.getConfig();
        assertEq(maxDrawRate, 0.05e18);
        assertEq(mainWindow, 4 hours);
        assertEq(elasticWindow, 2 hours);
        assertEq(newCb.owner(), address(this));
        assertEq(newCb.paused(), false);
    }

    function test_Constructor_RevertMaxDrawRateZero() public {
        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        new CircuitBreaker(0, 4 hours, 2 hours);
    }

    function test_Constructor_RevertMaxDrawRateOver100Percent() public {
        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        new CircuitBreaker(1.01e18, 4 hours, 2 hours);
    }

    function test_Constructor_RevertMainWindowZero() public {
        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        new CircuitBreaker(0.05e18, 0, 2 hours);
    }

    function test_Constructor_RevertElasticWindowZero() public {
        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        new CircuitBreaker(0.05e18, 4 hours, 0);
    }

    function test_Constructor_EmitsConfigUpdated() public {
        vm.expectEmit(true, true, true, true);
        emit ConfigUpdated(0.05e18, 4 hours, 2 hours);
        new CircuitBreaker(0.05e18, 4 hours, 2 hours);
    }

    // ============ Access Control Tests ============

    function test_AddProtectedContract_Success() public {
        address newWrapper = makeAddr("newWrapper");

        vm.expectEmit(true, true, true, true);
        emit ProtectedContractAdded(newWrapper);
        cb.addProtectedContract(newWrapper);

        assertTrue(cb.protectedContracts(newWrapper));
    }

    function test_AddProtectedContract_RevertZeroAddress() public {
        vm.expectRevert(CircuitBreaker.CircuitBreakerZeroAddress.selector);
        cb.addProtectedContract(address(0));
    }

    function test_AddProtectedContract_RevertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        cb.addProtectedContract(makeAddr("newWrapper"));
    }

    function test_RemoveProtectedContract_Success() public {
        vm.expectEmit(true, true, true, true);
        emit ProtectedContractRemoved(wrapper);
        cb.removeProtectedContract(wrapper);

        assertFalse(cb.protectedContracts(wrapper));
    }

    function test_RemoveProtectedContract_RevertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        cb.removeProtectedContract(wrapper);
    }

    function test_RecordInflow_RevertNotProtectedContract() public {
        vm.prank(attacker);
        vm.expectRevert(CircuitBreaker.CircuitBreakerNotProtectedContract.selector);
        cb.recordInflow(address(asset), 100e18, 1000e18);
    }

    function test_CheckAndRecordOutflow_RevertNotProtectedContract() public {
        vm.prank(attacker);
        vm.expectRevert(CircuitBreaker.CircuitBreakerNotProtectedContract.selector);
        cb.checkAndRecordOutflow(address(asset), 100e18, 1000e18);
    }

    // ============ Inflow Tests ============

    function test_RecordInflow_FirstDeposit() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 100e18;

        vm.expectEmit(true, true, true, true);
        emit Inflow(address(asset), depositAmount, tvl + depositAmount);

        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        // Check state was initialized
        (uint256 mainBuffer, uint256 elasticBuffer, uint256 lastUpdate) =
            cb.getRawAssetState(address(asset));
        uint256 expectedCap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;
        assertEq(mainBuffer, expectedCap, "Main buffer should be at cap");
        assertEq(elasticBuffer, depositAmount, "Elastic buffer should equal deposit");
        assertEq(lastUpdate, block.timestamp, "Timestamp should be current");
    }

    function test_RecordInflow_SubsequentDeposit() public {
        uint256 tvl = 1000e18;

        // First deposit
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);

        // Second deposit
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, true, true, true);
        emit Inflow(address(asset), 50e18, tvl + 100e18 + 50e18);

        vm.prank(wrapper);
        cb.recordInflow(address(asset), 50e18, tvl + 100e18);

        (, uint256 elasticBuffer,) = cb.getRawAssetState(address(asset));
        // Elastic buffer decays over time, then increases by new deposit
        // After 1 hour with 2 hour window: decay = 100 * 1/2 = 50
        // Remaining = 100 - 50 = 50
        // New elastic = 50 + 50 = 100
        assertApproxEqAbs(
            elasticBuffer, 100e18, 1e18, "Elastic buffer should account for decay and new deposit"
        );
    }

    // ============ Outflow Tests ============

    function test_CheckAndRecordOutflow_UnderLimit() public {
        uint256 tvl = 1000e18;
        uint256 withdrawAmount = 10e18;

        // Initialize with deposit
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);

        vm.expectEmit(true, true, true, true);
        emit Outflow(address(asset), withdrawAmount, tvl - withdrawAmount);

        vm.prank(wrapper);
        (bool allowed, uint256 available) =
            cb.checkAndRecordOutflow(address(asset), withdrawAmount, tvl);

        assertTrue(allowed, "Withdrawal should be allowed");
        assertGt(available, withdrawAmount, "Available should exceed withdrawal");
    }

    function test_CheckAndRecordOutflow_OverLimit() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18; // 50e18
        uint256 excessiveWithdrawal = cap + 100e18;

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        // Note: No event expected - wrapper will revert on denied withdrawal,

        vm.prank(wrapper);
        (bool allowed, uint256 available) =
            cb.checkAndRecordOutflow(address(asset), excessiveWithdrawal, tvl);

        assertFalse(allowed, "Withdrawal should be denied");
        assertEq(available, cap, "Available should equal cap");
    }

    function test_CheckAndRecordOutflow_ConsumesElasticFirst() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 20e18;
        uint256 withdrawAmount = 15e18;

        // Deposit to add elastic buffer
        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        (uint256 mainBefore, uint256 elasticBefore,) = cb.getRawAssetState(address(asset));

        // Withdraw less than elastic buffer
        vm.prank(wrapper);
        cb.checkAndRecordOutflow(address(asset), withdrawAmount, tvl);

        (uint256 mainAfter, uint256 elasticAfter,) = cb.getRawAssetState(address(asset));

        assertEq(mainAfter, mainBefore, "Main buffer should be unchanged");
        assertEq(elasticAfter, elasticBefore - withdrawAmount, "Elastic buffer should be reduced");
    }

    function test_CheckAndRecordOutflow_ConsumesElasticThenMain() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 20e18;
        uint256 withdrawAmount = 30e18; // More than elastic

        // Deposit to add elastic buffer
        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        (uint256 mainBefore, uint256 elasticBefore,) = cb.getRawAssetState(address(asset));

        // Withdraw more than elastic buffer
        vm.prank(wrapper);
        cb.checkAndRecordOutflow(address(asset), withdrawAmount, tvl);

        (uint256 mainAfter, uint256 elasticAfter,) = cb.getRawAssetState(address(asset));

        assertEq(elasticAfter, 0, "Elastic buffer should be fully consumed");
        assertEq(
            mainAfter,
            mainBefore - (withdrawAmount - elasticBefore),
            "Main buffer reduced by remainder"
        );
    }

    // ============ Buffer Mechanics Tests ============

    function test_MainBuffer_ReplenishesOverTime() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18; // 50e18

        // Initialize and deplete main buffer
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);
        cb.checkAndRecordOutflow(address(asset), cap, tvl); // Fully deplete
        vm.stopPrank();

        (uint256 mainAfterDepletion,,) = cb.getRawAssetState(address(asset));
        assertEq(mainAfterDepletion, 0, "Main buffer should be depleted");

        // Wait half the main window
        vm.warp(block.timestamp + DEFAULT_MAIN_WINDOW / 2);

        // Check capacity (triggers buffer recalculation)
        uint256 capacity = cb.withdrawalCapacity(address(asset), tvl);

        // Should have replenished ~50% of cap
        assertApproxEqRel(capacity, cap / 2, 0.01e18, "Buffer should replenish ~50% in half window");
    }

    function test_MainBuffer_NeverExceedsCap() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        // Wait way longer than main window
        vm.warp(block.timestamp + DEFAULT_MAIN_WINDOW * 10);

        uint256 capacity = cb.withdrawalCapacity(address(asset), tvl);

        assertEq(capacity, cap, "Capacity should not exceed cap even after long time");
    }

    function test_ElasticBuffer_DecaysOverTime() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 100e18;

        // Deposit to create elastic buffer
        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        (, uint256 elasticBefore,) = cb.getRawAssetState(address(asset));
        assertEq(elasticBefore, depositAmount);

        // Wait half the elastic window
        vm.warp(block.timestamp + DEFAULT_ELASTIC_WINDOW / 2);

        // Trigger recalculation with another deposit
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        (, uint256 elasticAfter,) = cb.getRawAssetState(address(asset));

        // Should have decayed ~50%
        assertApproxEqRel(
            elasticAfter, depositAmount / 2, 0.01e18, "Elastic should decay ~50% in half window"
        );
    }

    function test_ElasticBuffer_FullyDecaysAfterWindow() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 100e18;

        // Deposit to create elastic buffer
        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        // Wait full elastic window
        vm.warp(block.timestamp + DEFAULT_ELASTIC_WINDOW);

        // Trigger recalculation
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        (, uint256 elasticAfter,) = cb.getRawAssetState(address(asset));

        assertEq(elasticAfter, 0, "Elastic should fully decay after full window");
    }

    // ============ Flashloan DoS Resistance ============

    function test_FlashloanDoS_MainBufferUnaffected() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        (uint256 mainBefore,,) = cb.getRawAssetState(address(asset));

        // Simulate flashloan: huge deposit then immediate withdrawal
        uint256 flashloanAmount = 100_000e18;
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), flashloanAmount, tvl);
        cb.checkAndRecordOutflow(address(asset), flashloanAmount, tvl + flashloanAmount);
        vm.stopPrank();

        (uint256 mainAfter,,) = cb.getRawAssetState(address(asset));

        assertEq(mainAfter, mainBefore, "Main buffer should be unchanged by flashloan");
    }

    // ============ Admin Function Tests ============

    function test_Pause_AllowsAllTransactions() public {
        uint256 tvl = 1000e18;

        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerPaused(admin);
        cb.pause();

        assertTrue(cb.paused());
        assertFalse(cb.isActive());

        // Huge withdrawal should be allowed when paused
        vm.prank(wrapper);
        (bool allowed, uint256 available) =
            cb.checkAndRecordOutflow(address(asset), type(uint256).max, tvl);

        assertTrue(allowed);
        assertEq(available, type(uint256).max);
    }

    function test_Unpause_ReEnablesLimits() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        cb.pause();

        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerUnpaused(admin);
        cb.unpause();

        assertFalse(cb.paused());
        assertTrue(cb.isActive());

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        // Excessive withdrawal should be blocked
        vm.prank(wrapper);
        (bool allowed,) = cb.checkAndRecordOutflow(address(asset), cap + 1e18, tvl);

        assertFalse(allowed);
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        cb.pause();
    }

    function test_UpdateConfig_Success() public {
        uint256 newRate = 0.1e18; // 10%
        uint256 newMainWindow = 8 hours;
        uint256 newElasticWindow = 4 hours;

        vm.expectEmit(true, true, true, true);
        emit ConfigUpdated(newRate, newMainWindow, newElasticWindow);
        cb.updateConfig(newRate, newMainWindow, newElasticWindow);

        (uint256 rate, uint256 main, uint256 elastic) = cb.getConfig();
        assertEq(rate, newRate);
        assertEq(main, newMainWindow);
        assertEq(elastic, newElasticWindow);
    }

    function test_UpdateConfig_RevertInvalidParameters() public {
        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        cb.updateConfig(0, 4 hours, 2 hours); // Zero rate

        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        cb.updateConfig(1.01e18, 4 hours, 2 hours); // Over 100%

        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        cb.updateConfig(0.05e18, 0, 2 hours); // Zero main window

        vm.expectRevert(CircuitBreaker.CircuitBreakerInvalidConfig.selector);
        cb.updateConfig(0.05e18, 4 hours, 0); // Zero elastic window
    }

    function test_EmergencyOverride_AddsToMainBuffer() public {
        uint256 tvl = 1000e18;
        uint256 overrideAmount = 100e18;

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        (uint256 mainBefore,,) = cb.getRawAssetState(address(asset));

        vm.expectEmit(true, true, true, true);
        emit EmergencyOverride(address(asset), overrideAmount);
        cb.emergencyOverride(address(asset), overrideAmount);

        (uint256 mainAfter,,) = cb.getRawAssetState(address(asset));

        assertEq(
            mainAfter, mainBefore + overrideAmount, "Main buffer should increase by override amount"
        );
    }

    function test_TransferOwnership_TwoStepProcess() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(admin, newOwner);
        cb.transferOwnership(newOwner);

        assertEq(cb.pendingOwner(), newOwner);
        assertEq(cb.owner(), admin, "Owner should not change yet");

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(admin, newOwner);
        vm.prank(newOwner);
        cb.acceptOwnership();

        assertEq(cb.owner(), newOwner);
        assertEq(cb.pendingOwner(), address(0));
    }

    function test_TransferOwnership_ZeroAddressCancelsPending() public {
        // In Ownable2Step, transferring to address(0) cancels any pending transfer
        address newOwner = makeAddr("newOwner");

        // Start a transfer
        cb.transferOwnership(newOwner);
        assertEq(cb.pendingOwner(), newOwner);

        // Cancel by transferring to address(0)
        cb.transferOwnership(address(0));
        assertEq(cb.pendingOwner(), address(0));
        assertEq(cb.owner(), admin, "Owner should remain unchanged");
    }

    function test_AcceptOwnership_RevertNotPendingOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        cb.acceptOwnership();
    }

    // ============ View Function Tests ============

    function test_WithdrawalCapacity_ReturnsCorrectValue() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 20e18;

        // Initialize with deposit
        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        uint256 capacity = cb.withdrawalCapacity(address(asset), tvl);
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        // Capacity should be cap + elastic buffer
        assertEq(capacity, cap + depositAmount);
    }

    function test_WithdrawalCapacity_WhenPaused() public {
        cb.pause();

        uint256 capacity = cb.withdrawalCapacity(address(asset), 1000e18);

        assertEq(capacity, type(uint256).max);
    }

    function test_IsActive_ReflectsPausedState() public {
        assertTrue(cb.isActive());

        cb.pause();
        assertFalse(cb.isActive());

        cb.unpause();
        assertTrue(cb.isActive());
    }

    function test_GetConfig_ReturnsCurrentConfig() public {
        (uint256 rate, uint256 main, uint256 elastic) = cb.getConfig();

        assertEq(rate, DEFAULT_MAX_DRAW_RATE);
        assertEq(main, DEFAULT_MAIN_WINDOW);
        assertEq(elastic, DEFAULT_ELASTIC_WINDOW);
    }

    // ============ Edge Case Tests ============

    function test_ZeroTvl_HandledCorrectly() public {
        // Initialize with zero TVL
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, 0);

        (uint256 mainBuffer,,) = cb.getRawAssetState(address(asset));
        assertEq(mainBuffer, 0, "Main buffer should be 0 when TVL is 0");

        // Should allow zero withdrawal
        vm.prank(wrapper);
        (bool allowed,) = cb.checkAndRecordOutflow(address(asset), 0, 0);
        assertTrue(allowed);
    }

    function test_VerySmallAmounts_NoUnderflow() public {
        uint256 tvl = 100; // Very small
        uint256 amount = 1;

        vm.prank(wrapper);
        cb.recordInflow(address(asset), amount, tvl);

        vm.prank(wrapper);
        (bool allowed,) = cb.checkAndRecordOutflow(address(asset), amount, tvl);
        assertTrue(allowed);
    }

    function test_MultipleAssetsIndependent() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);

        uint256 tvl1 = 1000e18;
        uint256 tvl2 = 500e18;

        // Initialize both assets
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl1);
        cb.recordInflow(address(asset2), 50e18, tvl2);
        vm.stopPrank();

        // Deplete asset1
        vm.prank(wrapper);
        cb.checkAndRecordOutflow(address(asset), (tvl1 * DEFAULT_MAX_DRAW_RATE) / 1e18, tvl1);

        // asset2 should still have full capacity
        uint256 capacity2 = cb.withdrawalCapacity(address(asset2), tvl2);
        uint256 expectedCap2 = (tvl2 * DEFAULT_MAX_DRAW_RATE) / 1e18;

        assertEq(capacity2, expectedCap2 + 50e18, "Asset2 capacity should be independent");
    }

    // ============ Decimal Agnostic Tests ============
    // These tests prove that the CircuitBreaker works correctly with tokens of any decimal precision.
    // The design is inherently decimal-agnostic because it uses percentage-based calculations
    // where all values (amount, TVL, cap, buffers) are in the same denomination.

    function test_Decimals6_USDC_RateLimitCalculation() public {
        // USDC has 6 decimals
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // 1 million USDC = 1_000_000e6 = 1_000_000_000_000 (1 trillion base units)
        uint256 tvl = 1_000_000e6;
        uint256 depositAmount = 100_000e6; // 100k USDC

        // Expected cap = 5% of 1M = 50k USDC = 50_000e6
        uint256 expectedCap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;
        assertEq(expectedCap, 50_000e6, "Cap should be 50k USDC");

        // Initialize with deposit
        vm.prank(wrapper);
        cb.recordInflow(address(usdc), depositAmount, tvl);

        // Check state
        (uint256 mainBuffer, uint256 elasticBuffer,) = cb.getRawAssetState(address(usdc));
        assertEq(mainBuffer, expectedCap, "Main buffer should be 50k USDC");
        assertEq(elasticBuffer, depositAmount, "Elastic buffer should be 100k USDC");

        // Total capacity = main + elastic = 50k + 100k = 150k USDC
        uint256 capacity = cb.withdrawalCapacity(address(usdc), tvl);
        assertEq(capacity, expectedCap + depositAmount, "Total capacity should be 150k USDC");

        // Withdraw 40k USDC (under limit) - should succeed
        vm.prank(wrapper);
        (bool allowed,) = cb.checkAndRecordOutflow(address(usdc), 40_000e6, tvl);
        assertTrue(allowed, "40k withdrawal should be allowed");

        // Try to withdraw 200k USDC (over limit) - should fail
        vm.prank(wrapper);
        (bool allowed2, uint256 available) = cb.checkAndRecordOutflow(address(usdc), 200_000e6, tvl);
        assertFalse(allowed2, "200k withdrawal should be denied");
        assertLt(available, 200_000e6, "Available should be less than requested");
    }

    function test_Decimals8_WBTC_RateLimitCalculation() public {
        // WBTC has 8 decimals
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // 100 WBTC = 100e8 = 10_000_000_000 (10 billion base units)
        uint256 tvl = 100e8;
        uint256 depositAmount = 10e8; // 10 WBTC

        // Expected cap = 5% of 100 WBTC = 5 WBTC = 5e8
        uint256 expectedCap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;
        assertEq(expectedCap, 5e8, "Cap should be 5 WBTC");

        // Initialize with deposit
        vm.prank(wrapper);
        cb.recordInflow(address(wbtc), depositAmount, tvl);

        // Check state
        (uint256 mainBuffer, uint256 elasticBuffer,) = cb.getRawAssetState(address(wbtc));
        assertEq(mainBuffer, expectedCap, "Main buffer should be 5 WBTC");
        assertEq(elasticBuffer, depositAmount, "Elastic buffer should be 10 WBTC");

        // Total capacity = main + elastic = 5 + 10 = 15 WBTC
        uint256 capacity = cb.withdrawalCapacity(address(wbtc), tvl);
        assertEq(capacity, expectedCap + depositAmount, "Total capacity should be 15 WBTC");

        // Withdraw 4 WBTC (under limit) - should succeed
        vm.prank(wrapper);
        (bool allowed,) = cb.checkAndRecordOutflow(address(wbtc), 4e8, tvl);
        assertTrue(allowed, "4 WBTC withdrawal should be allowed");
    }

    function test_Decimals6_BufferReplenishment() public {
        // Test that buffer replenishment works correctly with 6 decimals
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        uint256 tvl = 1_000_000e6; // 1M USDC
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18; // 50k USDC

        // Initialize and deplete main buffer
        vm.startPrank(wrapper);
        cb.recordInflow(address(usdc), 0, tvl);
        cb.checkAndRecordOutflow(address(usdc), cap, tvl); // Fully deplete
        vm.stopPrank();

        (uint256 mainAfterDepletion,,) = cb.getRawAssetState(address(usdc));
        assertEq(mainAfterDepletion, 0, "Main buffer should be depleted");

        // Wait half the main window
        vm.warp(block.timestamp + DEFAULT_MAIN_WINDOW / 2);

        // Check capacity - should have replenished ~50%
        uint256 capacity = cb.withdrawalCapacity(address(usdc), tvl);
        assertApproxEqRel(capacity, cap / 2, 0.01e18, "Buffer should replenish ~50% (25k USDC)");
    }

    function test_Decimals8_ElasticBufferDecay() public {
        // Test that elastic buffer decay works correctly with 8 decimals
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        uint256 tvl = 100e8; // 100 WBTC
        uint256 depositAmount = 10e8; // 10 WBTC

        // Deposit to create elastic buffer
        vm.prank(wrapper);
        cb.recordInflow(address(wbtc), depositAmount, tvl);

        (, uint256 elasticBefore,) = cb.getRawAssetState(address(wbtc));
        assertEq(elasticBefore, depositAmount, "Elastic should be 10 WBTC");

        // Wait half the elastic window
        vm.warp(block.timestamp + DEFAULT_ELASTIC_WINDOW / 2);

        // Trigger recalculation
        vm.prank(wrapper);
        cb.recordInflow(address(wbtc), 0, tvl);

        (, uint256 elasticAfter,) = cb.getRawAssetState(address(wbtc));
        assertApproxEqRel(
            elasticAfter, depositAmount / 2, 0.01e18, "Elastic should decay to ~5 WBTC"
        );
    }

    function test_Decimals6_FlashloanProtection() public {
        // Test flashloan protection with 6 decimal token
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        uint256 tvl = 1_000_000e6; // 1M USDC

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(usdc), 0, tvl);

        (uint256 mainBefore,,) = cb.getRawAssetState(address(usdc));

        // Simulate flashloan: huge deposit then immediate withdrawal
        uint256 flashloanAmount = 100_000_000e6; // 100M USDC flashloan
        vm.startPrank(wrapper);
        cb.recordInflow(address(usdc), flashloanAmount, tvl);
        cb.checkAndRecordOutflow(address(usdc), flashloanAmount, tvl + flashloanAmount);
        vm.stopPrank();

        (uint256 mainAfter,,) = cb.getRawAssetState(address(usdc));

        // Main buffer should be unchanged - flashloan only affects elastic buffer
        assertEq(mainAfter, mainBefore, "Main buffer should be unchanged by flashloan");
    }

    function test_MixedDecimals_MultipleAssets() public {
        // Test multiple assets with different decimals simultaneously
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        // asset from setUp is 18 decimals

        uint256 tvlUsdc = 1_000_000e6; // 1M USDC
        uint256 tvlWbtc = 100e8; // 100 WBTC
        uint256 tvlDai = 1_000_000e18; // 1M DAI (18 decimals)

        // Initialize all three
        vm.startPrank(wrapper);
        cb.recordInflow(address(usdc), 50_000e6, tvlUsdc);
        cb.recordInflow(address(wbtc), 5e8, tvlWbtc);
        cb.recordInflow(address(asset), 50_000e18, tvlDai);
        vm.stopPrank();

        // Verify each has correct cap based on its decimals
        uint256 capUsdc = (tvlUsdc * DEFAULT_MAX_DRAW_RATE) / 1e18;
        uint256 capWbtc = (tvlWbtc * DEFAULT_MAX_DRAW_RATE) / 1e18;
        uint256 capDai = (tvlDai * DEFAULT_MAX_DRAW_RATE) / 1e18;

        assertEq(capUsdc, 50_000e6, "USDC cap should be 50k");
        assertEq(capWbtc, 5e8, "WBTC cap should be 5");
        assertEq(capDai, 50_000e18, "DAI cap should be 50k");

        // Verify capacities are independent
        uint256 capacityUsdc = cb.withdrawalCapacity(address(usdc), tvlUsdc);
        uint256 capacityWbtc = cb.withdrawalCapacity(address(wbtc), tvlWbtc);
        uint256 capacityDai = cb.withdrawalCapacity(address(asset), tvlDai);

        assertEq(capacityUsdc, capUsdc + 50_000e6, "USDC capacity = cap + elastic");
        assertEq(capacityWbtc, capWbtc + 5e8, "WBTC capacity = cap + elastic");
        assertEq(capacityDai, capDai + 50_000e18, "DAI capacity = cap + elastic");

        // Deplete USDC, verify others unaffected
        vm.prank(wrapper);
        cb.checkAndRecordOutflow(address(usdc), capacityUsdc, tvlUsdc);

        uint256 capacityWbtcAfter = cb.withdrawalCapacity(address(wbtc), tvlWbtc);
        uint256 capacityDaiAfter = cb.withdrawalCapacity(address(asset), tvlDai);

        assertEq(capacityWbtcAfter, capacityWbtc, "WBTC capacity unchanged");
        assertEq(capacityDaiAfter, capacityDai, "DAI capacity unchanged");
    }

    function test_Decimals2_ExoticToken() public {
        // Test with an exotic 2-decimal token (like some fiat-pegged tokens)
        MockERC20 exotic = new MockERC20("Exotic Token", "EXO", 2);

        // 10,000 tokens = 10_000e2 = 1_000_000 base units
        uint256 tvl = 10_000e2;
        uint256 depositAmount = 1_000e2;

        // Expected cap = 5% of 10,000 = 500 tokens = 500e2
        uint256 expectedCap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;
        assertEq(expectedCap, 500e2, "Cap should be 500 tokens");

        vm.prank(wrapper);
        cb.recordInflow(address(exotic), depositAmount, tvl);

        uint256 capacity = cb.withdrawalCapacity(address(exotic), tvl);
        assertEq(capacity, expectedCap + depositAmount, "Capacity should be 1500 tokens");
    }

    function test_VeryLargeAmounts_NoOverflow() public {
        // Use realistic large amounts within uint96 bounds (~7.9e28 max)
        // 10 billion tokens with 18 decimals = 1e28
        uint256 tvl = 100_000_000_000e18; // 100 billion tokens
        uint256 amount = 10_000_000_000e18; // 10 billion tokens

        // Should handle very large amounts without overflow
        vm.prank(wrapper);
        cb.recordInflow(address(asset), amount, tvl);

        // Verify state was updated
        (, uint256 elasticBuffer,) = cb.getRawAssetState(address(asset));
        assertEq(elasticBuffer, amount, "Should handle large amounts");
    }

    function test_LongTimeElapsed_NoOverflow() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        // Warp far into future
        vm.warp(block.timestamp + 365 days);

        // Should handle gracefully due to overflow protection
        uint256 capacity = cb.withdrawalCapacity(address(asset), tvl);
        assertLe(capacity, cap, "Capacity should not overflow");
    }

    function test_Pause_NoStateChanges() public {
        uint256 tvl = 1000e18;

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);

        (uint256 mainBefore, uint256 elasticBefore, uint256 lastUpdateBefore) =
            cb.getRawAssetState(address(asset));

        cb.pause();

        // Attempt withdrawal while paused
        vm.prank(wrapper);
        cb.checkAndRecordOutflow(address(asset), 50e18, tvl);

        (uint256 mainAfter, uint256 elasticAfter, uint256 lastUpdateAfter) =
            cb.getRawAssetState(address(asset));

        // State should be unchanged
        assertEq(mainAfter, mainBefore, "Main buffer unchanged when paused");
        assertEq(elasticAfter, elasticBefore, "Elastic buffer unchanged when paused");
        assertEq(lastUpdateAfter, lastUpdateBefore, "Timestamp unchanged when paused");
    }

    function test_Pause_RecordInflowSkipped() public {
        uint256 tvl = 1000e18;

        // Initialize
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);

        (uint256 mainBefore, uint256 elasticBefore, uint256 lastUpdateBefore) =
            cb.getRawAssetState(address(asset));

        cb.pause();

        // Record inflow while paused - should be skipped
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 500e18, tvl);

        (uint256 mainAfter, uint256 elasticAfter, uint256 lastUpdateAfter) =
            cb.getRawAssetState(address(asset));

        // State should be unchanged (inflow was skipped)
        assertEq(mainAfter, mainBefore, "Main buffer unchanged when paused");
        assertEq(elasticAfter, elasticBefore, "Elastic buffer unchanged - inflow skipped");
        assertEq(lastUpdateAfter, lastUpdateBefore, "Timestamp unchanged when paused");
    }

    function test_Pause_StateFreezeThenResume() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        // Initialize and partially deplete
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);
        cb.checkAndRecordOutflow(address(asset), cap / 2, tvl); // Deplete 50%
        vm.stopPrank();

        (uint256 mainBefore,,) = cb.getRawAssetState(address(asset));
        assertEq(mainBefore, cap / 2, "Should be 50% depleted");

        // Pause
        cb.pause();

        // Wait for what would be full replenishment time
        vm.warp(block.timestamp + DEFAULT_MAIN_WINDOW);

        // Try deposit and withdrawal while paused
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl); // Skipped
        cb.checkAndRecordOutflow(address(asset), 10e18, tvl); // Allowed but no state change
        vm.stopPrank();

        // State still frozen
        (uint256 mainStillFrozen,,) = cb.getRawAssetState(address(asset));
        assertEq(mainStillFrozen, cap / 2, "Main buffer should still be at 50%");

        // Unpause
        cb.unpause();

        // Now on first interaction, buffer should replenish
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 10e18, tvl);

        (uint256 mainAfterUnpause, uint256 elasticAfter,) = cb.getRawAssetState(address(asset));

        // Main buffer fully replenished (time capped at mainWindow)
        assertEq(mainAfterUnpause, cap, "Main buffer should be fully replenished after unpause");
        // Elastic buffer is from the 10e18 deposit after unpause
        assertEq(elasticAfter, 10e18, "Only post-unpause deposit counted");
    }

    // ============ Monitoring Function Tests ============

    function test_GetProtectedContracts_Empty() public {
        CircuitBreaker newCb = new CircuitBreaker(0.05e18, 4 hours, 2 hours);
        address[] memory contracts = newCb.getProtectedContracts();
        assertEq(contracts.length, 0);
        assertEq(newCb.protectedContractCount(), 0);
    }

    function test_GetProtectedContracts_AfterAdd() public {
        address wrapper2 = makeAddr("wrapper2");
        cb.addProtectedContract(wrapper2);

        address[] memory contracts = cb.getProtectedContracts();
        assertEq(contracts.length, 2);
        assertEq(cb.protectedContractCount(), 2);
        assertTrue(contracts[0] == wrapper || contracts[0] == wrapper2);
        assertTrue(contracts[1] == wrapper || contracts[1] == wrapper2);
    }

    function test_GetProtectedContracts_AfterRemove() public {
        address wrapper2 = makeAddr("wrapper2");
        address wrapper3 = makeAddr("wrapper3");
        cb.addProtectedContract(wrapper2);
        cb.addProtectedContract(wrapper3);

        assertEq(cb.protectedContractCount(), 3);

        // Remove middle element
        cb.removeProtectedContract(wrapper2);

        address[] memory contracts = cb.getProtectedContracts();
        assertEq(contracts.length, 2);
        assertEq(cb.protectedContractCount(), 2);

        // Verify wrapper2 is not in the list
        bool foundWrapper2 = false;
        for (uint256 i = 0; i < contracts.length; i++) {
            if (contracts[i] == wrapper2) foundWrapper2 = true;
        }
        assertFalse(foundWrapper2, "wrapper2 should be removed");
    }

    function test_AddProtectedContract_DuplicateIsNoop() public {
        uint256 countBefore = cb.protectedContractCount();

        // Try to add wrapper again (already added in setUp)
        cb.addProtectedContract(wrapper);

        assertEq(
            cb.protectedContractCount(), countBefore, "Count should not increase for duplicate"
        );
    }

    function test_RemoveProtectedContract_NonExistentIsNoop() public {
        uint256 countBefore = cb.protectedContractCount();
        address nonExistent = makeAddr("nonExistent");

        cb.removeProtectedContract(nonExistent);

        assertEq(cb.protectedContractCount(), countBefore, "Count should not change");
    }

    function test_GetTrackedAssets_Empty() public {
        CircuitBreaker newCb = new CircuitBreaker(0.05e18, 4 hours, 2 hours);
        address[] memory assets = newCb.getTrackedAssets();
        assertEq(assets.length, 0);
        assertEq(newCb.trackedAssetCount(), 0);
    }

    function test_GetTrackedAssets_AfterInflow() public {
        uint256 tvl = 1000e18;

        // Record inflow for first asset
        vm.prank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);

        address[] memory assets = cb.getTrackedAssets();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(asset));
        assertEq(cb.trackedAssetCount(), 1);
        assertTrue(cb.isTrackedAsset(address(asset)));
    }

    function test_GetTrackedAssets_MultipleAssets() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);
        MockERC20 asset3 = new MockERC20("Asset 3", "A3", 18);

        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 100e18, 1000e18);
        cb.recordInflow(address(asset2), 50e18, 500e18);
        cb.recordInflow(address(asset3), 25e18, 250e18);
        vm.stopPrank();

        address[] memory assets = cb.getTrackedAssets();
        assertEq(assets.length, 3);
        assertEq(cb.trackedAssetCount(), 3);
        assertTrue(cb.isTrackedAsset(address(asset)));
        assertTrue(cb.isTrackedAsset(address(asset2)));
        assertTrue(cb.isTrackedAsset(address(asset3)));
    }

    function test_GetTrackedAssets_NoDuplicates() public {
        uint256 tvl = 1000e18;

        // Multiple inflows for same asset
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);
        cb.recordInflow(address(asset), 50e18, tvl + 100e18);
        cb.recordInflow(address(asset), 25e18, tvl + 150e18);
        vm.stopPrank();

        address[] memory assets = cb.getTrackedAssets();
        assertEq(assets.length, 1, "Should only track asset once");
        assertEq(cb.trackedAssetCount(), 1);
    }

    function test_GetAssetHealth_FullCapacity() public {
        uint256 tvl = 1000e18;

        vm.prank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);

        (
            uint256 mainUtilizationBps,
            uint256 elasticBuffer,
            uint256 totalCapacity,
            uint256 maxCapacity,
            uint256 secondsUntilFull
        ) = cb.getAssetHealth(address(asset), tvl);

        uint256 expectedCap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18;

        assertEq(mainUtilizationBps, 0, "Should be 0% utilized at full capacity");
        assertEq(elasticBuffer, 0, "No elastic buffer without deposit");
        assertEq(totalCapacity, expectedCap, "Total capacity equals max");
        assertEq(maxCapacity, expectedCap, "Max capacity calculation");
        assertEq(secondsUntilFull, 0, "Already at full capacity");
    }

    function test_GetAssetHealth_PartiallyDepleted() public {
        uint256 tvl = 1000e18;
        uint256 cap = (tvl * DEFAULT_MAX_DRAW_RATE) / 1e18; // 50e18

        // Initialize and partially deplete
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 0, tvl);
        cb.checkAndRecordOutflow(address(asset), cap / 2, tvl); // Deplete 50%
        vm.stopPrank();

        (
            uint256 mainUtilizationBps,,
            uint256 totalCapacity,
            uint256 maxCapacity,
            uint256 secondsUntilFull
        ) = cb.getAssetHealth(address(asset), tvl);

        assertEq(mainUtilizationBps, 5000, "Should be 50% utilized");
        assertEq(totalCapacity, cap / 2, "Half capacity remaining");
        assertEq(maxCapacity, cap, "Max capacity unchanged");
        assertGt(secondsUntilFull, 0, "Should need time to replenish");
        assertApproxEqRel(
            secondsUntilFull,
            DEFAULT_MAIN_WINDOW / 2,
            0.01e18,
            "Should need ~half window to replenish"
        );
    }

    function test_GetAssetHealth_WithElasticBuffer() public {
        uint256 tvl = 1000e18;
        uint256 depositAmount = 100e18;

        vm.prank(wrapper);
        cb.recordInflow(address(asset), depositAmount, tvl);

        (
            uint256 mainUtilizationBps,
            uint256 elasticBuffer,
            uint256 totalCapacity,
            uint256 maxCapacity,
        ) = cb.getAssetHealth(address(asset), tvl);

        assertEq(mainUtilizationBps, 0, "Main buffer at full capacity");
        assertEq(elasticBuffer, depositAmount, "Elastic buffer equals deposit");
        assertEq(totalCapacity, maxCapacity + depositAmount, "Total includes elastic");
    }

    function test_GetAssetHealth_WhenPaused() public {
        cb.pause();

        (
            uint256 mainUtilizationBps,
            uint256 elasticBuffer,
            uint256 totalCapacity,
            uint256 maxCapacity,
            uint256 secondsUntilFull
        ) = cb.getAssetHealth(address(asset), 1000e18);

        assertEq(mainUtilizationBps, 0);
        assertEq(elasticBuffer, type(uint256).max);
        assertEq(totalCapacity, type(uint256).max);
        assertEq(maxCapacity, type(uint256).max);
        assertEq(secondsUntilFull, 0);
    }

    function test_GetSystemStatus() public {
        uint256 tvl = 1000e18;

        // Add more protected contracts
        address wrapper2 = makeAddr("wrapper2");
        cb.addProtectedContract(wrapper2);

        // Track some assets
        vm.startPrank(wrapper);
        cb.recordInflow(address(asset), 100e18, tvl);
        vm.stopPrank();

        (
            bool active,
            address adminAddr,
            uint256 maxDrawRateBps,
            uint256 mainWindowSecs,
            uint256 elasticWindowSecs,
            uint256 numProtected,
            uint256 numTracked
        ) = cb.getSystemStatus();

        assertTrue(active);
        assertEq(adminAddr, admin);
        assertEq(maxDrawRateBps, 500); // 5% = 500 bps
        assertEq(mainWindowSecs, DEFAULT_MAIN_WINDOW);
        assertEq(elasticWindowSecs, DEFAULT_ELASTIC_WINDOW);
        assertEq(numProtected, 2);
        assertEq(numTracked, 1);
    }

    function test_GetSystemStatus_WhenPaused() public {
        cb.pause();

        (bool active,,,,,,) = cb.getSystemStatus();

        assertFalse(active);
    }
}
