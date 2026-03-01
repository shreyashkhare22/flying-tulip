// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../contracts/ftYieldWrapper.sol";
import "../contracts/strategies/AaveStrategy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAavePool.sol";
import "./mocks/MockAavePoolWithAToken.sol";
import "./mocks/MockAToken.sol";

contract MockAavePoolAddressesProvider {
    address public poolAddr;

    constructor(address _pool) {
        poolAddr = _pool;
    }

    function getPool() external view returns (address) {
        return poolAddr;
    }
}

contract ftYieldWrapperTest is Test {
    // Mirror the wrapper event so vm.expectEmit can validate it in tests
    event YieldClaimed(address yieldClaimer, address token, uint256 amount);
    event StrategiesReordered(address[] newOrder);
    event UpdatePutManager(address newPutManager);
    event UpdateDepositor(address newDepositor);

    // Helper to deploy wrapper + two strategies with a given provider and aTokens
    function _deployWrapperAndStrategies(
        MockERC20 usdc,
        MockERC20 aUSDC,
        MockAavePool pool
    )
        internal
        returns (ftYieldWrapper wrapper, AaveStrategy strategy1, AaveStrategy strategy2)
    {
        wrapper = new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        wrapper.setPutManager(address(this)); // Allow test contract to deposit/withdraw
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        strategy1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(strategy1));
        assertEq(wrapper.pendingStrategy(), address(strategy1));
        wrapper.confirmStrategy();
        assertEq(wrapper.pendingStrategy(), address(0));
        strategy2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(strategy2));
        assertEq(wrapper.pendingStrategy(), address(strategy2));
        wrapper.confirmStrategy();
        assertEq(wrapper.pendingStrategy(), address(0));
        return (wrapper, strategy1, strategy2);
    }

    function test_Withdraw_AggregateLiquiditySucceeds() public {
        // Arrange: mimic previous WrapperWithdraw setup where this test contract deposits and deploys only to strategy2
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        (ftYieldWrapper wrapper, AaveStrategy s1, AaveStrategy s2) =
            _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // Fund this contract and approve
        usdc.mint(address(this), 1_000_000_000);
        usdc.approve(address(wrapper), type(uint256).max);

        // Deposit and deploy
        wrapper.deposit(1_000_000_000);
        assertEq(usdc.balanceOf(address(wrapper)), 1_000_000_000);
        wrapper.deploy(address(s1), 500_000_000);
        wrapper.deploy(address(s2), 500_000_000);
        assertEq(usdc.balanceOf(address(wrapper)), 0);

        // Simulate aToken minting for strategy2 and pool liquidity
        aUSDC.mint(address(s2), 1_000_000_000);
        usdc.mint(address(aUSDC), 100_000_000);

        // Act
        wrapper.withdraw(10_000_000, address(this));

        // Assert: this contract received the funds
        assertEq(usdc.balanceOf(address(this)), 10_000_000);
    }

    function test_ProportionalLossShared() public {
        // Arrange: equal splits and two depositing users
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        (ftYieldWrapper wrapper, AaveStrategy s1, AaveStrategy s2) =
            _deployWrapperAndStrategies(usdc, aUSDC, pool);

        address user1 = address(0x1001);
        address user2 = address(0x1002);

        wrapper.setPutManager(user1);
        vm.startPrank(user1);
        usdc.mint(user1, 500_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(500_000_000);
        vm.stopPrank();

        wrapper.setDepositor(user2);
        vm.startPrank(user2);
        usdc.mint(user2, 500_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(500_000_000);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(wrapper)), 1_000_000_000);
        wrapper.deploy(address(s1), 500_000_000);
        wrapper.deploy(address(s2), 500_000_000);

        aUSDC.mint(address(s1), 500_000_000);
        aUSDC.mint(address(s2), 500_000_000);
        usdc.mint(address(aUSDC), 1_000_000_000);

        // Act: simulate loss on strategy1
        vm.prank(address(s1));
        aUSDC.burn(200_000_000);

        uint256 totalAssets = wrapper.valueOfCapital();
        uint256 totalSupply = wrapper.totalSupply();
        uint256 user1Shares = wrapper.balanceOf(user1);
        uint256 expectedPerUser = (user1Shares * totalAssets) / totalSupply;

        vm.prank(user1);
        wrapper.withdraw(expectedPerUser, user1);
        vm.prank(user2);
        wrapper.withdraw(expectedPerUser, user2);

        assertEq(usdc.balanceOf(user1), expectedPerUser);
        assertEq(usdc.balanceOf(user2), expectedPerUser);
        assertEq(usdc.balanceOf(user1) + usdc.balanceOf(user2), totalAssets);
    }

    function test_WithdrawUsesWrapperBalanceFirst() public {
        // Arrange using proportional setup
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (ftYieldWrapper wrapper, AaveStrategy s1, AaveStrategy s2) =
            _deployWrapperAndStrategies(usdc, aUSDC, pool);

        address user1 = address(0x1001);
        address user2 = address(0x1002);

        wrapper.setPutManager(user1);
        vm.startPrank(user1);
        usdc.mint(user1, 500_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(500_000_000);
        vm.stopPrank();

        wrapper.setDepositor(user2);
        vm.startPrank(user2);
        usdc.mint(user2, 500_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(500_000_000);
        vm.stopPrank();

        wrapper.deploy(address(s1), 500_000_000);
        wrapper.deploy(address(s2), 500_000_000);
        aUSDC.mint(address(s1), 500_000_000);
        aUSDC.mint(address(s2), 500_000_000);
        usdc.mint(address(aUSDC), 1_000_000_000);

        // Give wrapper a direct balance to use
        usdc.mint(address(wrapper), 100_000_000);

        uint256 withdrawAmt = 50_000_000;
        uint256 preUser = usdc.balanceOf(user1);
        uint256 preWrapper = usdc.balanceOf(address(wrapper));

        vm.prank(user1);
        wrapper.withdraw(withdrawAmt, user1);

        assertEq(usdc.balanceOf(user1), preUser + withdrawAmt);
        assertEq(usdc.balanceOf(address(wrapper)), preWrapper - withdrawAmt);
    }

    function test_WithdrawRevertsWhenInsufficientLiquidity() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));
        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();

        address depositor = address(0x2001);
        wrapper.setPutManager(depositor);
        vm.startPrank(depositor);
        usdc.mint(depositor, 100_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(100_000_000);
        vm.stopPrank();

        wrapper.deploy(address(s1), 100_000_000);

        vm.prank(depositor);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInsufficientLiquidity.selector);
        wrapper.withdraw(10_000_000, depositor);
    }

    function test_DesiredSharesRoundingToOne() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        address large = address(0x3001);
        address tiny = address(0x3002);

        wrapper.setPutManager(large);
        vm.startPrank(large);
        usdc.mint(large, 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        wrapper.setDepositor(tiny);
        vm.startPrank(tiny);
        usdc.mint(tiny, 1);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1);
        vm.stopPrank();

        uint256 preTinyShares = wrapper.balanceOf(tiny);
        assertGt(preTinyShares, 0);

        // inflate underlying held by wrapper (without minting shares)
        usdc.mint(address(wrapper), 1_000_000_000);

        vm.prank(tiny);
        wrapper.withdraw(1, tiny);

        uint256 postTinyShares = wrapper.balanceOf(tiny);
        assertEq(postTinyShares, preTinyShares - 1);
    }

    // New test: verify wrapper handles tokens with different decimals correctly
    function test_DifferentTokenDecimals() public {
        // Arrange: create USDC (6 decimals) and a mock 18-decimal token
        MockERC20 usdc6 = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC6 = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool6 = new MockAavePool();

        MockERC20 token18 = new MockERC20("Mock Token", "MTK", 18);
        MockERC20 aToken18 = new MockERC20("Aave MTK", "aMTK", 18);
        MockAavePool pool18 = new MockAavePool();

        // Deploy wrapper + strategies for 6-decimal
        (ftYieldWrapper wrapper6, AaveStrategy s1_6, AaveStrategy s2_6) =
            _deployWrapperAndStrategies(usdc6, aUSDC6, pool6);

        // Coverage: ensure wrapper.decimals() delegates to underlying token
        assertEq(wrapper6.decimals(), usdc6.decimals());

        // Deposit 1,000 USDC (scaled to 6 decimals)
        usdc6.mint(address(this), 1_000_000_000); // 1,000 * 10^6
        usdc6.approve(address(wrapper6), type(uint256).max);
        wrapper6.deposit(1_000_000_000);

        // Deploy funds to strategies and simulate aTokens
        wrapper6.deploy(address(s1_6), 500_000_000);
        wrapper6.deploy(address(s2_6), 500_000_000);
        aUSDC6.mint(address(s1_6), 500_000_000);
        aUSDC6.mint(address(s2_6), 500_000_000);
        usdc6.mint(address(aUSDC6), 1_000_000_000);

        // Withdraw a portion and assert precise accounting (in token units)
        uint256 preBal = usdc6.balanceOf(address(this));
        wrapper6.withdraw(250_000_000, address(this)); // withdraw 250 * 10^6
        uint256 postBal = usdc6.balanceOf(address(this));
        assertEq(postBal - preBal, 250_000_000);

        // Now do the same flow for a 18-decimal token
        (ftYieldWrapper wrapper18, AaveStrategy s1_18, AaveStrategy s2_18) =
            _deployWrapperAndStrategies(token18, aToken18, pool18);

        // Coverage: ensure wrapper.decimals() delegates to underlying token
        assertEq(wrapper18.decimals(), token18.decimals());

        // Deposit 1,000 tokens with 18 decimals
        token18.mint(address(this), 1_000 * 10 ** 18);
        token18.approve(address(wrapper18), type(uint256).max);
        wrapper18.deposit(1_000 * 10 ** 18);

        wrapper18.deploy(address(s1_18), 500 * 10 ** 18);
        wrapper18.deploy(address(s2_18), 500 * 10 ** 18);
        aToken18.mint(address(s1_18), 500 * 10 ** 18);
        aToken18.mint(address(s2_18), 500 * 10 ** 18);
        token18.mint(address(aToken18), 1_000 * 10 ** 18);

        uint256 preBal18 = token18.balanceOf(address(this));
        wrapper18.withdraw(250 * 10 ** 18, address(this));
        uint256 postBal18 = token18.balanceOf(address(this));
        assertEq(postBal18 - preBal18, 250 * 10 ** 18);
    }

    // Coverage: ensure view helper functions return expected values
    function test_ViewFunctionsNumberOfStrategiesAndCapital() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        // Deploy wrapper + two strategies
        (
            ftYieldWrapper wrapper,, /* AaveStrategy s1 */ /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // numberOfStrategies should be 2
        assertEq(wrapper.numberOfStrategies(), 2);

        // capital should reflect totalSupply (which is zero initially)
        assertEq(wrapper.capital(), wrapper.totalSupply());

        // Do a deposit and ensure capital increases (totalSupply increases)
        usdc.mint(address(this), 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000_000);
        assertEq(wrapper.capital(), wrapper.totalSupply());
        assertEq(wrapper.capital(), 1_000_000);
    }

    // Cover set/confirm flow for yield claimer and sub-yield claimer
    function test_SetAndConfirmYieldClaimerAndSetSubYieldClaimer() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (
            ftYieldWrapper wrapper,, /* AaveStrategy s1 */ /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // Initially, yieldClaimer is address(this) (deployed that way via helper)
        address newYieldClaimer = address(0xCAFE);
        wrapper.setYieldClaimer(newYieldClaimer);
        assertEq(wrapper.pendingYieldClaimer(), newYieldClaimer);

        // confirmYieldClaimer must be called by treasury or strategyManager (both address(this) here)
        wrapper.confirmYieldClaimer();
        assertEq(wrapper.yieldClaimer(), newYieldClaimer);

        // Now set sub yield claimer (only callable by current yieldClaimer)
        // Prank as the new yield claimer to set sub yield claimer
        address newSub = address(0xBEEF);
        vm.prank(newYieldClaimer);
        wrapper.setSubYieldClaimer(newSub);
        assertEq(wrapper.subYieldClaimer(), newSub);
    }

    // Cover set/confirm flow for strategy manager
    function test_SetAndConfirmStrategyManager() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (
            ftYieldWrapper wrapper,, /* AaveStrategy s1 */ /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        address newManager = address(0x1234);
        // setStrategyManager is only callable by current strategyManager (address(this))
        wrapper.setStrategyManager(newManager);
        assertEq(wrapper.pendingStrategyManager(), newManager);

        // confirmStrategyManager must be called by treasury or yieldClaimer (both address(this) initially)
        wrapper.confirmStrategyManager();
        assertEq(wrapper.strategyManager(), newManager);
    }

    // Cover set/confirm flow for treasury
    function test_SetAndConfirmTreasury() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (
            ftYieldWrapper wrapper,, /* AaveStrategy s1 */ /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        address newTreasury = address(0x4321);
        // setTreasury must be called by current treasury (address(this))
        wrapper.setTreasury(newTreasury);
        assertEq(wrapper.pendingTreasury(), newTreasury);

        // confirmTreasury must be called by strategyManager or yieldClaimer (both address(this) initially)
        wrapper.confirmTreasury();
        assertEq(wrapper.treasury(), newTreasury);
    }

    // Cover yield(), availableToWithdraw(), canWithdraw(), and maxAbleToWithdraw()
    function test_YieldAndLiquidityHelpers() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        (ftYieldWrapper wrapper, AaveStrategy s1, AaveStrategy s2) =
            _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // Deposit 1,000,000 and deploy to strategies
        usdc.mint(address(this), 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000_000);
        wrapper.deploy(address(s1), 500_000);
        wrapper.deploy(address(s2), 500_000);

        // Simulate aTokens minted to strategies
        aUSDC.mint(address(s1), 400_000);
        aUSDC.mint(address(s2), 400_000);

        // Simulate pool liquidity smaller than individual strategy balances
        usdc.mint(address(aUSDC), 300_000);

        // Give wrapper an on-hand balance so availableToWithdraw includes it
        usdc.mint(address(wrapper), 50_000);

        // availableToWithdraw should equal wrapper balance + sum(min(aToken.balanceOf(strategy), token.balanceOf(aToken)))
        uint256 expectedPerStrategy = aUSDC.balanceOf(address(s1)) < usdc.balanceOf(address(aUSDC))
            ? aUSDC.balanceOf(address(s1))
            : usdc.balanceOf(address(aUSDC));
        uint256 expectedLiquidity =
            usdc.balanceOf(address(wrapper)) + expectedPerStrategy + expectedPerStrategy;
        assertEq(wrapper.availableToWithdraw(), expectedLiquidity);

        // canWithdraw: amount greater than liquidity -> false; equal or less -> true
        assertEq(wrapper.canWithdraw(expectedLiquidity + 1), false);
        assertEq(wrapper.canWithdraw(expectedLiquidity), true);

        // maxAbleToWithdraw: when amount < liquidity returns amount; when amount > liquidity returns liquidity
        assertEq(wrapper.maxAbleToWithdraw(expectedLiquidity - 10), expectedLiquidity - 10);
        assertEq(wrapper.maxAbleToWithdraw(expectedLiquidity + 1000), expectedLiquidity);

        // Now check yield(): increase wrapper's underlying (simulate earned yield)
        uint256 beforeYield = wrapper.yield();
        // Mint enough to push valueOfCapital above totalSupply (deficit + 1)
        uint256 valCap = wrapper.valueOfCapital();
        uint256 totSupply = wrapper.totalSupply();
        if (valCap <= totSupply) {
            uint256 deficit = totSupply - valCap + 1;
            usdc.mint(address(wrapper), deficit);
        } else {
            // already positive yield, add a small amount
            usdc.mint(address(wrapper), 1);
        }
        uint256 afterYield = wrapper.yield();
        assertGt(afterYield, beforeYield);
        // yield() should equal valueOfCapital - totalSupply
        uint256 expectedYield = wrapper.valueOfCapital() - wrapper.totalSupply();
        assertEq(wrapper.yield(), expectedYield);
    }

    // claimYield should revert if called for an address that's not a registered strategy
    function test_ClaimYieldRevertsForUnregisteredStrategy() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (
            ftYieldWrapper wrapper,, /* AaveStrategy s1 */ /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // pick an address that's not a strategy
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategy.selector);
        wrapper.claimYield(address(0xDEAD));
    }

    // claimYield should revert when strategy has no yield
    function test_ClaimYieldRevertsWhenNoYield() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (
            ftYieldWrapper wrapper,
            AaveStrategy s1, /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // Ensure strategy exists but has no aToken yield
        // Attempting to claim should revert
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNoYield.selector);
        wrapper.claimYield(address(s1));
    }

    // claimYields should aggregate yields across strategies and mint yield tokens to treasury
    function test_ClaimYieldsAggregatesAndMintsToTreasury() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (ftYieldWrapper wrapper, AaveStrategy s1, AaveStrategy s2) =
            _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // Deposit and deploy to create strategy totalSupply
        usdc.mint(address(this), 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000_000);
        wrapper.deploy(address(s1), 500_000);
        wrapper.deploy(address(s2), 500_000);

        // After deploy, each strategy totalSupply will reflect its allocated deposits (wrapper calls deposit on strategies)
        uint256 s1Total = s1.totalSupply();
        uint256 s2Total = s2.totalSupply();

        // Now mint aToken balances to strategies larger than their totalSupply to simulate yield
        uint256 yield1 = 10_000;
        uint256 yield2 = 20_000;
        // Mint base aToken balances: totalSupply + yield
        aUSDC.mint(address(s1), s1Total + yield1);
        aUSDC.mint(address(s2), s2Total + yield2);

        // Set pool liquidity so availableToWithdraw in strategies is at least totalSupply + yield
        usdc.mint(address(aUSDC), s1Total + yield1 + s2Total + yield2);

        // Expect the wrapper to emit YieldClaimed with the aggregate amount
        vm.expectEmit(true, true, true, true);
        emit YieldClaimed(address(this), address(usdc), yield1 + yield2);
        // Claim yields via wrapper - should return sum(yield1, yield2)
        uint256 totalClaimed = wrapper.claimYields();
        assertEq(totalClaimed, yield1 + yield2);

        // And strategy ERC20s should have minted yield tokens to treasury (which is address(this) in helper)
        assertEq(aUSDC.balanceOf(address(this)), yield1 + yield2);
    }

    // claimYield success path: emits and returns amount
    function test_ClaimYieldEmitsAndMintsForSingleStrategy() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();
        (
            ftYieldWrapper wrapper,
            AaveStrategy s1, /* AaveStrategy s2 */
        ) = _deployWrapperAndStrategies(usdc, aUSDC, pool);

        // Deposit and deploy
        usdc.mint(address(this), 200_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(200_000);
        wrapper.deploy(address(s1), 200_000);

        uint256 s1Total = s1.totalSupply();
        uint256 yield1 = 5_000;
        aUSDC.mint(address(s1), s1Total + yield1);
        usdc.mint(address(aUSDC), s1Total + yield1);

        // Expect event from wrapper for this single claim
        vm.expectEmit(true, true, true, true);
        emit YieldClaimed(address(this), address(usdc), yield1);
        uint256 claimed = wrapper.claimYield(address(s1));
        assertEq(claimed, yield1);
        // strategy should have minted yield tokens to treasury (address(this))
        assertEq(aUSDC.balanceOf(address(this)), yield1);
    }

    function test_SetStrategiesOrder_Success() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        // Deploy wrapper with three strategies
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s3 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s3));
        wrapper.confirmStrategy();

        assertEq(address(wrapper.strategies(0)), address(s1));
        assertEq(address(wrapper.strategies(1)), address(s2));
        assertEq(address(wrapper.strategies(2)), address(s3));

        address[] memory newOrder = new address[](3);
        newOrder[0] = address(s3);
        newOrder[1] = address(s1);
        newOrder[2] = address(s2);

        vm.expectEmit(true, true, true, true);
        emit StrategiesReordered(newOrder);
        wrapper.setStrategiesOrder(newOrder);

        assertEq(address(wrapper.strategies(0)), address(s3));
        assertEq(address(wrapper.strategies(1)), address(s1));
        assertEq(address(wrapper.strategies(2)), address(s2));
    }

    function test_SetStrategiesOrder_RevertNotStrategyManager() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        address strategyManager = address(0x1234);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), strategyManager, address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        vm.prank(strategyManager);
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();

        address[] memory newOrder = new address[](1);
        newOrder[0] = address(s1);

        // Try to reorder as non-strategy manager
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategyManager.selector);
        wrapper.setStrategiesOrder(newOrder);
    }

    function test_SetStrategiesOrder_RevertWrongLength() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s3 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();

        // Try with wrong length (too few)
        address[] memory shortOrder = new address[](1);
        shortOrder[0] = address(s1);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInvalidStrategiesOrder.selector);
        wrapper.setStrategiesOrder(shortOrder);

        // Try with wrong length (too many)
        address[] memory longOrder = new address[](3);
        longOrder[0] = address(s1);
        longOrder[1] = address(s2);
        longOrder[2] = address(s3);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInvalidStrategiesOrder.selector);
        wrapper.setStrategiesOrder(longOrder);
    }

    function test_SetStrategiesOrder_RevertDuplicates() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();

        // Try with duplicate strategies
        address[] memory duplicateOrder = new address[](2);
        duplicateOrder[0] = address(s2);
        duplicateOrder[1] = address(s2);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInvalidStrategiesOrder.selector);
        wrapper.setStrategiesOrder(duplicateOrder);
    }

    function test_SetStrategiesOrder_RevertNonExistentStrategy() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s3 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();

        address[] memory invalidOrder = new address[](2);
        invalidOrder[0] = address(s3);
        invalidOrder[1] = address(s1);

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperInvalidStrategiesOrder.selector);
        wrapper.setStrategiesOrder(invalidOrder);
    }

    function test_SetStrategiesOrder_EmptyStrategies() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        address[] memory emptyOrder = new address[](0);

        wrapper.setStrategiesOrder(emptyOrder);
    }

    function test_SetStrategiesOrder_SingleStrategy() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aUSDC = new MockERC20("Aave USDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool();

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();

        address[] memory singleOrder = new address[](1);
        singleOrder[0] = address(s1);

        wrapper.setStrategiesOrder(singleOrder);
        assertEq(address(wrapper.strategies(0)), address(s1));
    }

    function test_WithdrawUsesSequentialOrder() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAToken aUSDC = new MockAToken(usdc);
        MockAavePoolWithAToken pool = new MockAavePoolWithAToken(usdc, aUSDC);

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s3 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s3));
        wrapper.confirmStrategy();

        address user = address(0x1234);
        wrapper.setPutManager(user);
        usdc.mint(user, 8000e6);
        vm.startPrank(user);
        usdc.approve(address(wrapper), 8000e6);
        wrapper.deposit(8_000e6);
        vm.stopPrank();

        wrapper.deploy(address(s1), 3_000e6);
        wrapper.deploy(address(s2), 3_500e6);
        wrapper.deploy(address(s3), 1_500e6);

        // Sequential order should drain: s1 (3000) -> s2 (1500, partial)
        vm.prank(user);
        wrapper.withdraw(4_500e6, user);

        assertEq(wrapper.deployedToStrategy(address(s1)), 0); // Check that s2 was partially drained (3500 - 1500 = 2000 remaining)
        assertEq(wrapper.deployedToStrategy(address(s2)), 2_000e6);
        assertEq(wrapper.deployedToStrategy(address(s3)), 1_500e6);

        assertEq(usdc.balanceOf(user), 4_500e6);
    }

    function test_WithdrawWithReorderedStrategies() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAToken aUSDC = new MockAToken(usdc);
        MockAavePoolWithAToken pool = new MockAavePoolWithAToken(usdc, aUSDC);

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s3 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s3));
        wrapper.confirmStrategy();

        address user = address(0x1234);
        wrapper.setPutManager(user);
        usdc.mint(user, 8_000e6);
        vm.startPrank(user);
        usdc.approve(address(wrapper), 8_000e6);
        wrapper.deposit(8_000e6);
        vm.stopPrank();

        wrapper.deploy(address(s1), 1_000e6);
        wrapper.deploy(address(s2), 5_000e6);
        wrapper.deploy(address(s3), 2_000e6);

        address[] memory newOrder = new address[](3);
        newOrder[0] = address(s2);
        newOrder[1] = address(s3);
        newOrder[2] = address(s1);
        wrapper.setStrategiesOrder(newOrder);

        // Now withdraw 6_000 USDC
        // Should drain in new order: s2 (5_000) -> s3 (1_000, partial)
        vm.prank(user);
        wrapper.withdraw(6_000e6, user);

        assertEq(wrapper.deployedToStrategy(address(s2)), 0);
        assertEq(wrapper.deployedToStrategy(address(s3)), 1_000e6);
        assertEq(wrapper.deployedToStrategy(address(s1)), 1_000e6);

        assertEq(usdc.balanceOf(user), 6_000e6);
    }

    function test_AddThreeStrategiesReorderAndRemove() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAToken aUSDC = new MockAToken(usdc);
        MockAavePoolWithAToken pool = new MockAavePoolWithAToken(usdc, aUSDC);

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s2 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        AaveStrategy s3 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s2));
        wrapper.confirmStrategy();
        wrapper.setStrategy(address(s3));
        wrapper.confirmStrategy();

        address[] memory order1 = new address[](3);
        order1[0] = address(s3);
        order1[1] = address(s1);
        order1[2] = address(s2);
        wrapper.setStrategiesOrder(order1);

        address user = address(0x1234);
        wrapper.setPutManager(user);
        usdc.mint(user, 9_000e6);
        vm.startPrank(user);
        usdc.approve(address(wrapper), 9_000e6);
        wrapper.deposit(9_000e6);
        vm.stopPrank();

        wrapper.deploy(address(s3), 3_000e6);
        wrapper.deploy(address(s1), 2_000e6);
        wrapper.deploy(address(s2), 4_000e6);

        address[] memory order2 = new address[](3);
        order2[0] = address(s2);
        order2[1] = address(s3);
        order2[2] = address(s1);
        wrapper.setStrategiesOrder(order2);

        vm.prank(user);
        wrapper.withdraw(7_000e6, user);

        // After withdrawing 7_000:
        // s2 should be drained (4_000), s3 should be drained (3_000), s1 untouched (2_000)
        assertEq(wrapper.deployedToStrategy(address(s2)), 0);
        assertEq(wrapper.deployedToStrategy(address(s3)), 0);
        assertEq(wrapper.deployedToStrategy(address(s1)), 2_000e6);

        // Remove strategy s3 (which has zero balance now)
        // s3 is at index 1 in current order
        wrapper.removeStrategy(1);
        assertEq(wrapper.numberOfStrategies(), 2);
        assertEq(address(wrapper.strategies(0)), address(s2));
        assertEq(address(wrapper.strategies(1)), address(s1));

        address[] memory order3 = new address[](2);
        order3[0] = address(s1);
        order3[1] = address(s2);
        wrapper.setStrategiesOrder(order3);

        // Remove strategy s2 (also has zero balance)
        wrapper.removeStrategy(1);
        assertEq(wrapper.numberOfStrategies(), 1);
        assertEq(address(wrapper.strategies(0)), address(s1));

        vm.prank(user);
        wrapper.withdraw(2_000e6, user);
        assertEq(wrapper.deployedToStrategy(address(s1)), 0);
        assertEq(usdc.balanceOf(user), 9_000e6);
    }

    // Access Control Tests

    function test_Deposit_PutManager_Succeeds() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address putManager = address(0x1234);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        // Set putManager via setter
        wrapper.setPutManager(putManager);

        usdc.mint(putManager, 1_000_000);
        vm.startPrank(putManager);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(putManager), 1_000_000);
        assertEq(usdc.balanceOf(address(wrapper)), 1_000_000);
    }

    function test_Deposit_Depositor_Succeeds() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address depositor = address(0x5678);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        // Set depositor
        wrapper.setDepositor(depositor);
        assertEq(wrapper.depositor(), depositor);

        usdc.mint(depositor, 1_000_000);
        vm.startPrank(depositor);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(depositor), 1_000_000);
        assertEq(usdc.balanceOf(address(wrapper)), 1_000_000);
    }

    function test_Deposit_Unauthorized_Reverts() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address putManager = address(0x1234);
        address unauthorized = address(0x9999);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        wrapper.setPutManager(putManager);

        usdc.mint(unauthorized, 1_000_000);
        vm.startPrank(unauthorized);
        usdc.approve(address(wrapper), 1_000_000);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotPutManagerOrDepositor.selector);
        wrapper.deposit(1_000_000);
        vm.stopPrank();
    }

    function test_Withdraw_PutManager_Succeeds() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address putManager = address(0x1234);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        wrapper.setPutManager(putManager);

        // Deposit as putManager
        usdc.mint(putManager, 1_000_000);
        vm.startPrank(putManager);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);

        // Withdraw as putManager
        wrapper.withdraw(500_000, putManager);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(putManager), 500_000);
        assertEq(usdc.balanceOf(putManager), 500_000);
    }

    function test_Withdraw_Depositor_Succeeds() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address depositor = address(0x5678);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        // Set depositor
        wrapper.setDepositor(depositor);

        // Deposit as depositor
        usdc.mint(depositor, 1_000_000);
        vm.startPrank(depositor);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);

        // Withdraw as depositor
        wrapper.withdraw(500_000, depositor);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(depositor), 500_000);
        assertEq(usdc.balanceOf(depositor), 500_000);
    }

    function test_Withdraw_Unauthorized_Reverts() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address putManager = address(0x1234);
        address unauthorized = address(0x9999);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        wrapper.setPutManager(putManager);

        // Deposit as putManager first
        usdc.mint(putManager, 1_000_000);
        vm.startPrank(putManager);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        // Try to withdraw as unauthorized
        vm.prank(unauthorized);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotPutManagerOrDepositor.selector);
        wrapper.withdraw(500_000, unauthorized);
    }

    function test_WithdrawUnderlying_PutManager_Succeeds() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAToken aUSDC = new MockAToken(usdc);
        MockAavePoolWithAToken pool = new MockAavePoolWithAToken(usdc, aUSDC);
        address putManager = address(0x1234);

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        wrapper.setPutManager(putManager);

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();

        // Deposit as putManager and deploy to strategy
        usdc.mint(putManager, 1_000_000);
        vm.startPrank(putManager);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        wrapper.deploy(address(s1), 1_000_000);

        // Withdraw underlying as putManager
        vm.prank(putManager);
        wrapper.withdrawUnderlying(500_000, putManager);

        assertEq(wrapper.balanceOf(putManager), 500_000);
    }

    function test_WithdrawUnderlying_Depositor_Succeeds() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAToken aUSDC = new MockAToken(usdc);
        MockAavePoolWithAToken pool = new MockAavePoolWithAToken(usdc, aUSDC);
        address depositor = address(0x5678);

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();

        // Set depositor
        wrapper.setDepositor(depositor);

        // Deposit as depositor and deploy to strategy
        usdc.mint(depositor, 1_000_000);
        vm.startPrank(depositor);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        wrapper.deploy(address(s1), 1_000_000);

        // Withdraw underlying as depositor
        vm.prank(depositor);
        wrapper.withdrawUnderlying(500_000, depositor);

        assertEq(wrapper.balanceOf(depositor), 500_000);
    }

    function test_WithdrawUnderlying_Unauthorized_Reverts() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAToken aUSDC = new MockAToken(usdc);
        MockAavePoolWithAToken pool = new MockAavePoolWithAToken(usdc, aUSDC);
        address putManager = address(0x1234);
        address unauthorized = address(0x9999);

        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));
        MockAavePoolAddressesProvider provider = new MockAavePoolAddressesProvider(address(pool));

        wrapper.setPutManager(putManager);

        AaveStrategy s1 =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));
        wrapper.setStrategy(address(s1));
        wrapper.confirmStrategy();

        // Deposit as putManager and deploy to strategy
        usdc.mint(putManager, 1_000_000);
        vm.startPrank(putManager);
        usdc.approve(address(wrapper), 1_000_000);
        wrapper.deposit(1_000_000);
        vm.stopPrank();

        wrapper.deploy(address(s1), 1_000_000);

        // Try to withdraw underlying as unauthorized
        vm.prank(unauthorized);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotPutManagerOrDepositor.selector);
        wrapper.withdrawUnderlying(500_000, unauthorized);
    }

    function test_SetDepositor_FromZeroAddress() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        assertEq(wrapper.depositor(), address(0x0));

        address newDepositor = address(0x5678);
        vm.expectEmit(false, false, false, true);
        emit UpdateDepositor(newDepositor);
        wrapper.setDepositor(newDepositor);

        assertEq(wrapper.depositor(), newDepositor);
    }

    function test_SetDepositor_ToZeroAddress() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address depositor = address(0x5678);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        wrapper.setDepositor(depositor);
        assertEq(wrapper.depositor(), depositor);

        // Set back to 0x0
        vm.expectEmit(false, false, false, true);
        emit UpdateDepositor(address(0x0));
        wrapper.setDepositor(address(0x0));

        assertEq(wrapper.depositor(), address(0x0));
    }

    function test_SetPutManager_Success() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address oldPutManager = address(0x1234);
        address newPutManager = address(0x5678);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        wrapper.setPutManager(oldPutManager);
        assertEq(wrapper.putManager(), oldPutManager);

        vm.expectEmit(true, false, false, true);
        emit UpdatePutManager(newPutManager);
        wrapper.setPutManager(newPutManager);

        assertEq(wrapper.putManager(), newPutManager);
    }

    function test_SetPutManager_ZeroAddress_Reverts() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), address(this), address(this));

        vm.expectRevert(ftYieldWrapper.ftYieldWrapperZeroAddress.selector);
        wrapper.setPutManager(address(0x0));
    }

    function test_SetDepositor_OnlyStrategyManager() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address strategyManager = address(0x1234);
        address unauthorized = address(0x9999);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), strategyManager, address(this));

        vm.prank(unauthorized);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategyManager.selector);
        wrapper.setDepositor(address(0x5678));
    }

    function test_SetPutManager_OnlyStrategyManager() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address strategyManager = address(0x1234);
        address unauthorized = address(0x9999);
        ftYieldWrapper wrapper =
            new ftYieldWrapper(address(usdc), address(this), strategyManager, address(this));

        vm.prank(unauthorized);
        vm.expectRevert(ftYieldWrapper.ftYieldWrapperNotStrategyManager.selector);
        wrapper.setPutManager(address(0x5678));
    }
}
