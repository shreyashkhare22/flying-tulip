// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AaveStrategy} from "contracts/strategies/AaveStrategy.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {MockAavePoolWithAToken} from "./mocks/MockAavePoolWithAToken.sol";
import {MockAavePoolAddressesProvider} from "./mocks/MockAavePoolAddressesProvider.sol";

contract ReproIssueTest is Test {
    ftYieldWrapper public yieldWrapper;
    AaveStrategy public strategy1;
    AaveStrategy public strategy2;

    MockERC20 public usdc;
    MockAToken public aUSDC;
    MockAavePoolWithAToken public aavePool;
    MockAavePoolAddressesProvider public poolProvider;

    address public treasury;
    address public user1;
    address public user2;

    function setUp() public {
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        usdc = new MockERC20("USD Coin", "USDC", 6);

        aUSDC = new MockAToken(usdc);
        aavePool = new MockAavePoolWithAToken(usdc, aUSDC);
        poolProvider = new MockAavePoolAddressesProvider(address(aavePool));

        yieldWrapper = new ftYieldWrapper(address(usdc), treasury, treasury, treasury);

        strategy1 = new AaveStrategy(
            address(yieldWrapper), address(poolProvider), address(usdc), address(aUSDC)
        );

        strategy2 = new AaveStrategy(
            address(yieldWrapper), address(poolProvider), address(usdc), address(aUSDC)
        );

        vm.startPrank(treasury);
        yieldWrapper.setStrategy(address(strategy1));
        yieldWrapper.confirmStrategy();
        yieldWrapper.setStrategy(address(strategy2));
        yieldWrapper.confirmStrategy();
        yieldWrapper.setPutManager(user1);
        yieldWrapper.setDepositor(user2);
        vm.stopPrank();

        // Setup initial state:
        // 100 USDC in each strategy with 5 USDC profit
        usdc.mint(address(user1), 105e6);
        usdc.mint(address(user2), 95e6);

        vm.startPrank(user1);
        usdc.approve(address(yieldWrapper), 105e6);
        yieldWrapper.deposit(105e6);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(yieldWrapper), 95e6);
        yieldWrapper.deposit(95e6);
        vm.stopPrank();

        vm.startPrank(treasury);
        yieldWrapper.deploy(address(strategy1), 100e6);
        yieldWrapper.deploy(address(strategy2), 100e6);
        aUSDC.addYield(address(strategy1), 5e6);
        aUSDC.addYield(address(strategy2), 5e6);
        vm.stopPrank();
    }

    function test_ReproYieldClaimIssue() public {
        // Verify initial state
        console2.log("=== Initial State ===");
        console2.log("Strategy1 capital:", strategy1.capital());
        console2.log("Strategy1 valueOfCapital:", strategy1.valueOfCapital());
        console2.log("Strategy1 yield:", strategy1.yield());
        console2.log("Strategy1 totalSupply:", strategy1.totalSupply());

        console2.log("Strategy2 capital:", strategy2.capital());
        console2.log("Strategy2 valueOfCapital:", strategy2.valueOfCapital());
        console2.log("Strategy2 yield:", strategy2.yield());
        console2.log("Strategy2 totalSupply:", strategy2.totalSupply());

        assertEq(strategy1.capital(), 100e6, "Strategy1 should have 100 USDC capital");
        assertEq(strategy1.valueOfCapital(), 105e6, "Strategy1 should have 105 USDC value");
        assertEq(strategy1.yield(), 5e6, "Strategy1 should have 5 USDC yield");
        assertEq(strategy1.totalSupply(), 100e6, "Strategy1 totalSupply should be 100");

        assertEq(strategy2.capital(), 100e6, "Strategy2 should have 100 USDC capital");
        assertEq(strategy2.valueOfCapital(), 105e6, "Strategy2 should have 105 USDC value");
        assertEq(strategy2.yield(), 5e6, "Strategy2 should have 5 USDC yield");
        assertEq(strategy2.totalSupply(), 100e6, "Strategy2 totalSupply should be 100");

        console2.log("User1 shares after deposit:", yieldWrapper.balanceOf(user1));
        assertEq(yieldWrapper.balanceOf(user1), 105e6, "User1 should have 105 shares");

        // User1 claims yield to withdraw all his capital only from strat 1
        uint256 treasuryBalanceBefore = strategy1.balanceOf(treasury);
        vm.prank(treasury);
        yieldWrapper.claimYield(address(strategy1));
        vm.prank(user1);
        uint256 treasuryBalanceAfter = strategy1.balanceOf(treasury);

        console2.log("Treasury balance before claim:", treasuryBalanceBefore);
        console2.log("Treasury balance after claim:", treasuryBalanceAfter);
        console2.log("Yield claimed:", treasuryBalanceAfter - treasuryBalanceBefore);

        console2.log("Strategy1 totalSupply after claim:", strategy1.totalSupply());
        console2.log("Strategy1 capital after claim:", strategy1.capital());
        console2.log("Strategy1 yield after claim:", strategy1.yield());

        assertEq(strategy1.totalSupply(), 100e6, "Strategy1 totalSupply should be 100 after claim");
        assertEq(strategy1.yield(), 0, "Strategy1 yield should be 0 after claim");

        // User withdraws all 105 USDC
        console2.log("\n=== User Withdraws All 105 USDC ===");
        uint256 userUSDCBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        yieldWrapper.withdraw(105e6, user1);
        uint256 userUSDCAfter = usdc.balanceOf(user1);

        console2.log("User USDC withdrawn:", userUSDCAfter - userUSDCBefore);
        console2.log("User shares after withdrawal:", yieldWrapper.balanceOf(user1));

        assertEq(yieldWrapper.balanceOf(user1), 0, "User should have 0 shares");
        assertEq(userUSDCAfter - userUSDCBefore, 105e6, "User should have withdrawn 105 USDC");

        // Check final state
        console2.log("\n=== Final State ===");
        console2.log("Strategy1 capital:", strategy1.capital());
        console2.log("Strategy1 totalSupply:", strategy1.totalSupply());
        console2.log(
            "Strategy1 balanceOf(yieldWrapper):", strategy1.balanceOf(address(yieldWrapper))
        );
        console2.log("Strategy1 balanceOf(treasury):", strategy1.balanceOf(treasury));

        console2.log("Strategy2 capital:", strategy2.capital());
        console2.log("Strategy2 totalSupply:", strategy2.totalSupply());
        console2.log("Strategy2 yield still unclaimed:", strategy2.yield());

        // Treasury should have 5 aUSDC, but when user withdrew
        assertEq(strategy1.balanceOf(treasury), 0, "Treasury should not get shares");
        assertEq(aUSDC.balanceOf(treasury), 5e6, "Treasury should have gotten 5 aUSDC");
        assertEq(strategy1.totalSupply(), 0, "Strategy1 should have 0 total supply");
        assertEq(strategy1.capital(), 0, "Strategy1 should have 0 capital after full withdrawal");

        // Strategy2 still has unclaimed yield
        assertEq(strategy2.yield(), 5e6, "Strategy2 should still have 5 aUSDC unclaimed yield");
    }
}
