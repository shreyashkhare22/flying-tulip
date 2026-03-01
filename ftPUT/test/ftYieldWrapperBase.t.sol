// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockFailingERC20} from "./mocks/MockFailingERC20.sol";
import {CallTarget} from "./mocks/CallTarget.sol";
import {MockAccruingStrategy} from "./mocks/MockAccruingStrategy.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";

contract FtYieldWrapperTest is Test {
    ftYieldWrapper internal wrapper;
    MockERC20 internal token;
    MockStrategy internal strategyA;
    MockStrategy internal strategyB;
    CallTarget internal callTarget;

    address internal yieldClaimer;
    address internal strategyManager;
    address internal treasury;
    address internal subYieldClaimer;
    address internal user;
    address internal other;

    uint256 internal constant DECIMALS = 6;

    function setUp() public {
        yieldClaimer = makeAddr("yieldClaimer");
        strategyManager = makeAddr("strategyManager");
        treasury = makeAddr("treasury");
        subYieldClaimer = makeAddr("subYieldClaimer");
        user = makeAddr("user");
        other = makeAddr("other");

        token = new MockERC20("USD Coin", "USDC", uint8(DECIMALS));
        wrapper = new ftYieldWrapper(address(token), yieldClaimer, strategyManager, treasury);
        strategyA = new MockStrategy(address(token));
        strategyB = new MockStrategy(address(token));
        callTarget = new CallTarget();

        vm.prank(strategyManager);
        wrapper.setPutManager(user);
        vm.prank(strategyManager);
        wrapper.setDepositor(other);

        _mintAndApprove(user, toUSDC(100_000));
        _mintAndApprove(other, toUSDC(100_000));
        _mintAndApprove(strategyManager, toUSDC(100_000));
    }

    function toUSDC(uint256 amount) internal pure returns (uint256) {
        return amount * 10 ** DECIMALS;
    }

    function _mintAndApprove(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(wrapper), type(uint256).max);
    }

    function _addStrategy(MockStrategy strategy) internal {
        vm.prank(strategyManager);
        wrapper.setStrategy(address(strategy));
        vm.prank(treasury);
        wrapper.confirmStrategy();
        assertEq(wrapper.pendingStrategy(), address(0));
        strategy.setftYieldWrapper(address(wrapper));
    }

    function testDeploymentInitialisesMetadata() public view {
        assertEq(wrapper.symbol(), string.concat("ft", token.symbol()));
        assertEq(wrapper.name(), string.concat("Flying Tulip ", token.name()));
        assertEq(wrapper.decimals(), token.decimals());
        assertEq(wrapper.totalSupply(), 0);
        assertEq(wrapper.deployed(), 0);
        assertEq(wrapper.yieldClaimer(), yieldClaimer);
        assertEq(wrapper.strategyManager(), strategyManager);
        assertEq(wrapper.treasury(), treasury);
        assertEq(wrapper.numberOfStrategies(), 0);
    }

    function testDepositMintsShares() public {
        uint256 amount = toUSDC(1_000);
        uint256 balanceBefore = token.balanceOf(user);
        vm.prank(user);
        wrapper.deposit(amount);
        assertEq(wrapper.balanceOf(user), amount);
        assertEq(wrapper.totalSupply(), amount);
        assertEq(token.balanceOf(address(wrapper)), amount);
        assertEq(token.balanceOf(user), balanceBefore - amount);
    }

    function testSetAndConfirmYieldClaimer() public {
        address newClaimer = makeAddr("newClaimer");

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimer.selector);
        vm.prank(other);
        wrapper.setYieldClaimer(newClaimer);

        vm.startPrank(yieldClaimer);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        wrapper.setYieldClaimer(address(0));
        wrapper.setYieldClaimer(newClaimer);
        assertEq(wrapper.pendingYieldClaimer(), newClaimer);
        vm.stopPrank();

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimConfirmer.selector);
        vm.prank(other);
        wrapper.confirmYieldClaimer();

        vm.prank(treasury);
        wrapper.confirmYieldClaimer();
        assertEq(wrapper.yieldClaimer(), newClaimer);
    }

    function testConfirmYieldClaimerRequiresChange() public {
        vm.prank(yieldClaimer);
        wrapper.setYieldClaimer(yieldClaimer);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperSettingUnchanged.selector);
        vm.prank(treasury);
        wrapper.confirmYieldClaimer();

        address newClaimer = makeAddr("pendingClaimer");
        vm.prank(yieldClaimer);
        wrapper.setYieldClaimer(newClaimer);
        vm.prank(treasury);
        wrapper.confirmYieldClaimer();

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        vm.prank(treasury);
        wrapper.confirmYieldClaimer();
    }

    function testSetSubYieldClaimer() public {
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimer.selector);
        vm.prank(other);
        wrapper.setSubYieldClaimer(subYieldClaimer);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        vm.prank(yieldClaimer);
        wrapper.setSubYieldClaimer(address(0));

        vm.prank(yieldClaimer);
        wrapper.setSubYieldClaimer(subYieldClaimer);
        assertEq(wrapper.subYieldClaimer(), subYieldClaimer);
    }

    function testSetAndConfirmStrategyManager() public {
        address newManager = makeAddr("newManager");

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategyManager.selector);
        vm.prank(other);
        wrapper.setStrategyManager(newManager);

        vm.prank(strategyManager);
        wrapper.setStrategyManager(newManager);
        assertEq(wrapper.pendingStrategyManager(), newManager);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotConfirmer.selector);
        vm.prank(other);
        wrapper.confirmStrategyManager();

        vm.prank(treasury);
        wrapper.confirmStrategyManager();
        assertEq(wrapper.strategyManager(), newManager);
    }

    function testConfirmStrategyManagerRequiresChange() public {
        vm.prank(strategyManager);
        wrapper.setStrategyManager(strategyManager);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperSettingUnchanged.selector);
        vm.prank(treasury);
        wrapper.confirmStrategyManager();

        address newManager = makeAddr("pendingManager");
        vm.prank(strategyManager);
        wrapper.setStrategyManager(newManager);
        vm.prank(treasury);
        wrapper.confirmStrategyManager();

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        vm.prank(treasury);
        wrapper.confirmStrategyManager();
    }

    function testSetAndConfirmTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotSetter.selector);
        vm.prank(other);
        wrapper.setTreasury(newTreasury);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        vm.prank(treasury);
        wrapper.setTreasury(address(0));

        vm.prank(treasury);
        wrapper.setTreasury(newTreasury);
        assertEq(wrapper.pendingTreasury(), newTreasury);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotConfirmer.selector);
        vm.prank(other);
        wrapper.confirmTreasury();

        vm.prank(strategyManager);
        wrapper.confirmTreasury();
        assertEq(wrapper.treasury(), newTreasury);
    }

    function testConfirmStrategyRequiresPending() public {
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        vm.prank(treasury);
        wrapper.confirmStrategy();
    }

    function testAddStrategyAndSetSplit() public {
        _addStrategy(strategyA);
        assertEq(wrapper.numberOfStrategies(), 1);
        assertTrue(wrapper.isStrategy(address(strategyA)));

        _addStrategy(strategyB);
        assertEq(wrapper.numberOfStrategies(), 2);
    }

    function testSetStrategyRejectsMismatchedToken() public {
        MockFailingERC20 otherToken = new MockFailingERC20("Other", "OTH", 6);
        MockStrategy wrongStrategy = new MockStrategy(address(otherToken));
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategy.selector);
        vm.prank(strategyManager);
        wrapper.setStrategy(address(wrongStrategy));
    }

    function testDeployAllocatesAcrossStrategies() public {
        _addStrategy(strategyA);
        _addStrategy(strategyB);

        vm.prank(user);
        wrapper.deposit(toUSDC(1_000));

        vm.startPrank(yieldClaimer);
        wrapper.deploy(address(strategyA), toUSDC(700));
        wrapper.deploy(address(strategyB), toUSDC(300));
        vm.stopPrank();

        assertEq(token.balanceOf(address(strategyA)), toUSDC(700));
        assertEq(token.balanceOf(address(strategyB)), toUSDC(300));
        assertEq(token.balanceOf(address(wrapper)), 0);
    }

    function testDeployRequiresLiquidityAndManager() public {
        _addStrategy(strategyA);

        vm.prank(user);
        wrapper.deposit(toUSDC(200));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimer.selector);
        vm.prank(other);
        wrapper.deploy(address(strategyA), toUSDC(100));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInsufficientLiquidity.selector);
        vm.prank(yieldClaimer);
        wrapper.deploy(address(strategyA), toUSDC(500));
    }

    function testWithdrawInsufficientLiquidityReverts() public {
        vm.prank(user);
        wrapper.deposit(toUSDC(100));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInsufficientLiquidity.selector);
        vm.prank(user);
        wrapper.withdraw(toUSDC(150), user);
    }

    function testValueAndYieldCalculations() public {
        _addStrategy(strategyA);
        _addStrategy(strategyB);

        vm.prank(user);
        wrapper.deposit(toUSDC(1_000));
        vm.startPrank(yieldClaimer);
        wrapper.deploy(address(strategyA), toUSDC(700));
        wrapper.deploy(address(strategyB), toUSDC(300));
        vm.stopPrank();

        assertEq(wrapper.valueOfCapital(), toUSDC(1_000));
        assertEq(wrapper.yield(), 0);

        token.mint(address(strategyA), toUSDC(200));
        assertEq(wrapper.valueOfCapital(), toUSDC(1_200));
        assertEq(wrapper.yield(), toUSDC(200));
    }

    function testClaimYieldSingleStrategy() public {
        _addStrategy(strategyA);

        vm.prank(user);
        wrapper.deposit(toUSDC(500));
        vm.prank(yieldClaimer);
        wrapper.deploy(address(strategyA), toUSDC(500));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNoYield.selector);
        vm.prank(yieldClaimer);
        wrapper.claimYield(address(strategyA));

        token.mint(address(strategyA), toUSDC(120));
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(yieldClaimer);
        wrapper.claimYield(address(strategyA));
        assertEq(token.balanceOf(treasury), treasuryBefore + toUSDC(120));
    }

    function testClaimYieldsAggregates() public {
        _addStrategy(strategyA);
        _addStrategy(strategyB);

        vm.prank(user);
        wrapper.deposit(toUSDC(800));
        vm.prank(yieldClaimer);
        wrapper.deploy(address(strategyA), toUSDC(800));

        token.mint(address(strategyA), toUSDC(20));
        token.mint(address(strategyB), toUSDC(30));

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(yieldClaimer);
        wrapper.claimYields();
        assertEq(token.balanceOf(treasury), treasuryBefore + toUSDC(50));
    }

    function testSweepIdleYieldRevertsWhenNoExcess() public {
        _addStrategy(strategyA);

        vm.prank(user);
        wrapper.deposit(toUSDC(200));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimers.selector);
        vm.prank(user);
        wrapper.sweepIdleYield();

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNoYield.selector);
        vm.prank(yieldClaimer);
        wrapper.sweepIdleYield();
    }

    function testSweepIdleYieldAfterForceWithdrawMultipleStrategies() public {
        MockAccruingStrategy accruingA = new MockAccruingStrategy(address(token));
        MockAccruingStrategy accruingB = new MockAccruingStrategy(address(token));

        _addStrategy(accruingA);
        _addStrategy(accruingB);

        vm.prank(user);
        wrapper.deposit(toUSDC(1_000));

        vm.startPrank(yieldClaimer);
        wrapper.deploy(address(accruingA), toUSDC(600));
        wrapper.deploy(address(accruingB), toUSDC(400));
        vm.stopPrank();

        accruingA.simulateYield(toUSDC(30));
        accruingB.simulateYield(toUSDC(45));

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.startPrank(yieldClaimer);
        wrapper.forceWithdrawToWrapper(address(accruingA), toUSDC(630));
        wrapper.forceWithdrawToWrapper(address(accruingB), toUSDC(445));
        uint256 swept = wrapper.sweepIdleYield();
        vm.stopPrank();

        assertEq(swept, toUSDC(75));
        assertEq(wrapper.deployed(), 0);
        assertEq(wrapper.deployedToStrategy(address(accruingA)), 0);
        assertEq(wrapper.deployedToStrategy(address(accruingB)), 0);
        assertEq(token.balanceOf(address(wrapper)), toUSDC(1_000));
        assertEq(token.balanceOf(treasury), treasuryBefore + toUSDC(75));
        assertEq(wrapper.yield(), 0);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNoYield.selector);
        vm.prank(yieldClaimer);
        wrapper.sweepIdleYield();
    }

    function testSubYieldClaimerCanSweepIdleYield() public {
        MockAccruingStrategy accruing = new MockAccruingStrategy(address(token));
        _addStrategy(accruing);

        vm.prank(user);
        wrapper.deposit(toUSDC(500));
        vm.prank(yieldClaimer);
        wrapper.deploy(address(accruing), toUSDC(500));

        accruing.simulateYield(toUSDC(20));

        vm.prank(yieldClaimer);
        wrapper.forceWithdrawToWrapper(address(accruing), toUSDC(520));

        vm.prank(yieldClaimer);
        wrapper.setSubYieldClaimer(subYieldClaimer);

        uint256 treasuryBalance = token.balanceOf(treasury);
        vm.prank(subYieldClaimer);
        uint256 swept = wrapper.sweepIdleYield();

        assertEq(swept, toUSDC(20));
        assertEq(token.balanceOf(address(wrapper)), toUSDC(500));
        assertEq(token.balanceOf(treasury), treasuryBalance + toUSDC(20));
        assertEq(wrapper.yield(), 0);
    }

    function testExecuteForwardsCall() public {
        _addStrategy(strategyA);

        bytes memory payload =
            abi.encodeWithSelector(CallTarget.ping.selector, uint256(123), bytes("data"));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotYieldClaimers.selector);
        vm.prank(other);
        wrapper.execute(address(strategyA), address(callTarget), 0, payload);

        vm.prank(yieldClaimer);
        wrapper.setSubYieldClaimer(subYieldClaimer);

        vm.prank(yieldClaimer);
        wrapper.execute(address(strategyA), address(callTarget), 0, payload);

        assertEq(strategyA.lastExecuteTarget(), address(callTarget));
        assertEq(strategyA.lastExecuteData(), payload);
        assertEq(callTarget.lastCaller(), address(strategyA));
    }

    function testShareTransfersAndApprovals() public {
        vm.prank(user);
        wrapper.deposit(toUSDC(500));

        vm.prank(user);
        wrapper.transfer(other, toUSDC(200));
        assertEq(wrapper.balanceOf(other), toUSDC(200));
        assertEq(wrapper.balanceOf(user), toUSDC(300));

        vm.prank(user);
        wrapper.approve(other, toUSDC(150));
        vm.prank(other);
        wrapper.transferFrom(user, other, toUSDC(100));
        assertEq(wrapper.allowance(user, other), toUSDC(50));

        vm.prank(user);
        wrapper.approve(other, type(uint256).max);
        vm.prank(other);
        wrapper.transferFrom(user, other, toUSDC(50));
        assertEq(wrapper.allowance(user, other), type(uint256).max);
    }

    function testDepositRevertsWhenTransferFromFails() public {
        MockFailingERC20 failing = new MockFailingERC20("Bad", "BAD", 6);
        ftYieldWrapper badWrapper =
            new ftYieldWrapper(address(failing), yieldClaimer, strategyManager, treasury);

        vm.prank(strategyManager);
        badWrapper.setDepositor(user);

        failing.mint(user, toUSDC(100));
        vm.prank(user);
        failing.approve(address(badWrapper), toUSDC(100));
        failing.setFailures(false, true);

        vm.expectRevert(
            abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(failing))
        );
        vm.prank(user);
        badWrapper.deposit(toUSDC(100));
    }

    function testWithdrawRevertsWhenTransferFails() public {
        MockFailingERC20 failing = new MockFailingERC20("Bad", "BAD", 6);
        ftYieldWrapper badWrapper =
            new ftYieldWrapper(address(failing), yieldClaimer, strategyManager, treasury);

        vm.prank(strategyManager);
        badWrapper.setDepositor(user);

        failing.mint(user, toUSDC(50));
        vm.prank(user);
        failing.approve(address(badWrapper), toUSDC(50));
        vm.prank(user);
        badWrapper.deposit(toUSDC(50));

        failing.setFailures(true, false);
        vm.expectRevert(
            abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(failing))
        );
        vm.prank(user);
        badWrapper.withdraw(toUSDC(50), user);
    }
}
