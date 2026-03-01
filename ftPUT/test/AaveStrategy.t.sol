// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AaveStrategy} from "contracts/strategies/AaveStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {MockAavePoolWithAToken} from "./mocks/MockAavePoolWithAToken.sol";
import {MockAavePoolAddressesProvider} from "./mocks/MockAavePoolAddressesProvider.sol";
import {MockftYieldWrapper} from "./mocks/MockftYieldWrapper.sol";
import {EvilTaker} from "./mocks/EvilTaker.sol";

import {IStrategy} from "../contracts/interfaces/IStrategy.sol";

contract AaveStrategyTest is Test {
    AaveStrategy public strategy;
    MockERC20 public usdc;
    MockAToken public aUSDC;
    MockAavePoolWithAToken public aavePool;
    MockAavePoolAddressesProvider public poolProvider;
    MockftYieldWrapper public ftYieldWrapper;

    address public owner;
    address public treasury;
    address public user;
    address public attacker;

    event YieldClaimed(address yieldClaimer, address treasury, address token, uint256 amount);
    event Deposit(address owner, uint256 amount);
    event Withdraw(address owner, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUSDC = new MockAToken(usdc);
        aavePool = new MockAavePoolWithAToken(usdc, aUSDC);
        poolProvider = new MockAavePoolAddressesProvider(address(aavePool));
        ftYieldWrapper = new MockftYieldWrapper(treasury);

        // Deploy AaveStrategy
        strategy = new AaveStrategy(
            address(ftYieldWrapper), address(poolProvider), address(usdc), address(aUSDC)
        );
    }

    function test_Execute_WithdrawDonatedToken() public {
        MockERC20 randomToken = new MockERC20("Random Token", "RND", 18);
        randomToken.mint(address(strategy), 1000e18);

        // Prepare transfer call to withdraw donated tokens
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", treasury, 500e18);

        vm.prank(address(ftYieldWrapper));
        (bool success,) = strategy.execute(address(randomToken), 0, data);

        assertTrue(success);
        assertEq(randomToken.balanceOf(treasury), 500e18);
        assertEq(randomToken.balanceOf(address(strategy)), 500e18);
    }

    function test_Execute_RevertIfNotYieldWrapper() public {
        MockERC20 randomToken = new MockERC20("Random Token", "RND", 18);
        randomToken.mint(address(strategy), 1000e18);

        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", treasury, 500e18);

        vm.prank(attacker);
        vm.expectRevert(IStrategy.StrategyNotYieldWrapper.selector);
        strategy.execute(address(randomToken), 0, data);
    }

    function test_Execute_RevertIfTargetIsAToken() public {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", treasury, 100);

        vm.prank(address(ftYieldWrapper));
        vm.expectRevert(IStrategy.StrategyCantInteractWithCoreAssets.selector);
        strategy.execute(address(aUSDC), 0, data);
    }

    function test_Execute_RevertIfTargetIsPool() public {
        bytes memory data = abi.encodeWithSignature(
            "withdraw(address,uint256,address)", address(usdc), 100, treasury
        );

        vm.prank(address(ftYieldWrapper));
        vm.expectRevert(IStrategy.StrategyCantInteractWithCoreAssets.selector);
        strategy.execute(address(aavePool), 0, data);
    }

    function test_Execute_RevertIfCapitalDecreases() public {
        usdc.mint(address(ftYieldWrapper), 1_000e6);

        vm.startPrank(address(ftYieldWrapper));
        usdc.approve(address(strategy), 1000e6);
        strategy.deposit(1000e6);
        vm.stopPrank();

        EvilTaker evilTaker = new EvilTaker(address(aUSDC));

        // HACK: Use prank to make the strategy approve the EvilTaker to spend 1 aUSDC
        vm.prank(address(strategy));
        aUSDC.approve(address(evilTaker), 1);

        // Now try to execute EvilTaker.take() which will steal 1 aUSDC
        // This should revert because it decreases capital
        bytes memory takeData = abi.encodeWithSignature("take()");

        vm.expectRevert(IStrategy.StrategyCapitalMustNotChange.selector);
        vm.prank(address(ftYieldWrapper));
        strategy.execute(address(evilTaker), 0, takeData);
    }

    function test_CanWithdraw() public {
        usdc.mint(address(ftYieldWrapper), 1_000e6);

        vm.startPrank(address(ftYieldWrapper));
        usdc.approve(address(strategy), 1_000e6);
        strategy.deposit(1_000e6);
        vm.stopPrank();

        assertTrue(strategy.canWithdraw(500e6));
        assertTrue(strategy.canWithdraw(1_000e6));
        assertFalse(strategy.canWithdraw(1_001e6));
    }

    function test_MaxAbleToWithdraw() public {
        usdc.mint(address(ftYieldWrapper), 1_000e6);

        vm.startPrank(address(ftYieldWrapper));
        usdc.approve(address(strategy), 1_000e6);
        strategy.deposit(1_000e6);
        vm.stopPrank();

        assertEq(strategy.maxAbleToWithdraw(500e6), 500e6);
        assertEq(strategy.maxAbleToWithdraw(1_000e6), 1_000e6);
        assertEq(strategy.maxAbleToWithdraw(2_000e6), 1_000e6);
    }

    function test_YieldAccumulationAndClaim() public {
        usdc.mint(address(ftYieldWrapper), 1_000e6);

        vm.startPrank(address(ftYieldWrapper));
        usdc.approve(address(strategy), 1_000e6);
        strategy.deposit(1_000e6);
        vm.stopPrank();

        assertEq(strategy.capital(), 1_000e6);
        assertEq(strategy.valueOfCapital(), 1_000e6);
        assertEq(strategy.yield(), 0);

        // Simulate yield
        aUSDC.addYield(address(strategy), 10e6);

        assertEq(strategy.capital(), 1_000e6);
        assertEq(strategy.valueOfCapital(), 1_010e6);
        assertEq(strategy.yield(), 10e6);

        vm.prank(address(ftYieldWrapper));
        uint256 claimedYield = strategy.claimYield(treasury);

        assertEq(claimedYield, 10e6);
        assertEq(strategy.yield(), 0);

        assertEq(strategy.totalSupply(), 1000e6);
        assertEq(strategy.balanceOf(address(ftYieldWrapper)), 1_000e6);
        assertEq(aUSDC.balanceOf(address(treasury)), 10e6);
    }
}
