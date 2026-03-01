// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAccruingStrategy} from "./mocks/MockAccruingStrategy.sol";

contract ForceWithdrawStuckTest is Test {
    ftYieldWrapper internal wrapper;
    MockERC20 internal usdc;
    MockAccruingStrategy internal strategy;

    address internal yieldClaimer;
    address internal strategyManager;
    address internal treasury;
    address internal user;

    uint256 internal constant DECIMALS = 6;

    function setUp() public {
        yieldClaimer = makeAddr("yieldClaimer");
        strategyManager = makeAddr("strategyManager");
        treasury = makeAddr("treasury");
        user = makeAddr("user");

        usdc = new MockERC20("USD Coin", "USDC", uint8(DECIMALS));
        wrapper = new ftYieldWrapper(address(usdc), yieldClaimer, strategyManager, treasury);
        strategy = new MockAccruingStrategy(address(usdc));

        vm.prank(strategyManager);
        wrapper.setStrategy(address(strategy));
        vm.prank(treasury);
        wrapper.confirmStrategy();
        strategy.setftYieldWrapper(address(wrapper));

        usdc.mint(user, 10_000 * 1e6);
        vm.prank(user);
        usdc.approve(address(wrapper), type(uint256).max);

        vm.prank(strategyManager);
        wrapper.setDepositor(user);
    }

    function testForceWithdrawLeavesYieldStuck() public {
        uint256 depositAmount = 500 * 1e6;
        uint256 simulatedYield = 50 * 1e6;

        vm.prank(user);
        wrapper.deposit(depositAmount);
        assertEq(wrapper.balanceOf(user), depositAmount, "shares mismatch after deposit");

        vm.prank(yieldClaimer);
        wrapper.deploy(address(strategy), depositAmount);

        strategy.simulateYield(simulatedYield);
        assertEq(
            strategy.balanceOf(address(wrapper)),
            depositAmount + simulatedYield,
            "shares should reflect accrued yield"
        );

        vm.prank(yieldClaimer);
        wrapper.forceWithdrawToWrapper(address(strategy), depositAmount + simulatedYield);

        assertEq(
            usdc.balanceOf(address(wrapper)),
            depositAmount + simulatedYield,
            "wrapper should hold all capital + yield"
        );
        assertEq(
            wrapper.deployedToStrategy(address(strategy)), 0, "tracking of deployed funds incorrect"
        );
        assertEq(wrapper.deployed(), 0, "global deployed tracker incorrect");

        uint256 userPre = usdc.balanceOf(user);
        vm.prank(user);
        wrapper.withdraw(depositAmount, user);
        uint256 userReceived = usdc.balanceOf(user) - userPre;
        assertEq(userReceived, depositAmount, "user should only receive principal back");

        assertEq(wrapper.balanceOf(user), 0, "user shares should be burned");
        assertEq(wrapper.totalSupply(), 0, "all shares should be burned");
        assertEq(usdc.balanceOf(address(wrapper)), simulatedYield, "yield remains stuck in wrapper");
        assertEq(wrapper.yield(), simulatedYield, "wrapper reports outstanding yield");

        vm.prank(yieldClaimer);
        uint256 swept = wrapper.sweepIdleYield();
        assertEq(swept, simulatedYield, "sweep should return full idle yield amount");
        assertEq(usdc.balanceOf(treasury), simulatedYield, "treasury should receive swept yield");
        assertEq(usdc.balanceOf(address(wrapper)), 0, "wrapper should no longer hold idle yield");
        assertEq(wrapper.yield(), 0, "yield should be zero after sweep");
    }
}
