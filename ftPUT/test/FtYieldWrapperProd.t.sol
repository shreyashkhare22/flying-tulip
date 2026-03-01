// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";

contract FtYieldWrapperProdTest is Test {
    ftYieldWrapper internal wrapper;
    MockERC20 internal token;
    MockStrategy internal strategy;

    address internal yieldClaimer;
    address internal strategyManager;
    address internal treasury;
    address internal user;
    address internal other;

    uint256 internal constant DECIMALS = 6;

    function setUp() public {
        yieldClaimer = makeAddr("yieldClaimer");
        strategyManager = makeAddr("strategyManager");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        other = makeAddr("other");

        token = new MockERC20("USD Coin", "USDC", uint8(DECIMALS));
        wrapper = new ftYieldWrapper(address(token), yieldClaimer, strategyManager, treasury);
        strategy = new MockStrategy(address(token));

        vm.prank(strategyManager);
        wrapper.setDepositor(user);

        _mintAndApprove(user, toUSDC(10_000));
        _mintAndApprove(other, toUSDC(10_000));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   Helpers
    //////////////////////////////////////////////////////////////////////////*/

    function toUSDC(uint256 amount) internal pure returns (uint256) {
        return amount * 10 ** DECIMALS;
    }

    function _mintAndApprove(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(wrapper), type(uint256).max);
    }

    function _addStrategy() internal {
        vm.prank(strategyManager);
        wrapper.setStrategy(address(strategy));
        assertEq(wrapper.pendingStrategy(), address(strategy));

        vm.prank(treasury);
        wrapper.confirmStrategy();
        assertEq(wrapper.pendingStrategy(), address(0));

        strategy.setftYieldWrapper(address(wrapper));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Tests
    //////////////////////////////////////////////////////////////////////////*/

    function testDeploymentInitialisesImmutableConfiguration() public view {
        assertEq(wrapper.yieldClaimer(), yieldClaimer);
        assertEq(wrapper.strategyManager(), strategyManager);
        assertEq(wrapper.treasury(), treasury);
        assertEq(wrapper.symbol(), string.concat("ft", token.symbol()));
        assertEq(wrapper.name(), string.concat("Flying Tulip ", token.name()));
        assertEq(wrapper.decimals(), token.decimals());
    }

    function testDepositMintsShares() public {
        uint256 amount = toUSDC(1_000);

        vm.prank(user);
        wrapper.deposit(amount);

        assertEq(wrapper.balanceOf(user), amount);
        assertEq(wrapper.totalSupply(), amount);
        assertEq(token.balanceOf(address(wrapper)), amount);
    }

    function testWithdrawBurnsShares() public {
        uint256 amount = toUSDC(1_000);

        vm.prank(user);
        wrapper.deposit(amount);

        vm.prank(user);
        wrapper.withdraw(amount, user);

        assertEq(wrapper.balanceOf(user), 0);
        assertEq(wrapper.totalSupply(), 0);
        assertEq(token.balanceOf(user), toUSDC(10_000));
    }

    function testDeployPushesCapitalIntoStrategy() public {
        _addStrategy();

        uint256 depositAmount = toUSDC(2_000);
        vm.prank(user);
        wrapper.deposit(depositAmount);

        vm.prank(yieldClaimer);
        wrapper.deploy(address(strategy), depositAmount);

        assertEq(token.balanceOf(address(strategy)), depositAmount);
        assertEq(token.balanceOf(address(wrapper)), 0);
    }

    function testClaimYieldTransfersToTreasury() public {
        _addStrategy();

        uint256 depositAmount = toUSDC(1_000);
        vm.prank(user);
        wrapper.deposit(depositAmount);

        vm.prank(yieldClaimer);
        wrapper.deploy(address(strategy), depositAmount);

        token.mint(address(strategy), toUSDC(250));
        vm.prank(yieldClaimer);
        wrapper.claimYield(address(strategy));

        assertEq(token.balanceOf(treasury), toUSDC(250));
    }
}
