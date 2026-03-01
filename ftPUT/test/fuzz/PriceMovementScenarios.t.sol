// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";

// mocks
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "../mocks/MockOracles.sol";

/// @title Price Movement Scenarios Fuzz Test
/// @notice Tests protocol behavior under realistic price movements
/// @dev Verifies:
///      1. Strike price immutability - users get back the SAME collateral amount regardless of price changes
///      2. WBTC scenario: $100k → $200k increase, user still gets back 1 BTC (not less)
///      3. USDC scenario: $1.00 → $0.67 depeg, PUT goes in-the-money
///      4. Users cannot extract more collateral than deposited
contract PriceMovementScenariosTest is Test {
    // Core components
    MockERC20 public usdc;
    MockERC20 public wbtc;
    MockERC20 public ft;
    MockFlyingTulipOracle public oracle;
    pFT public pft;
    PutManager public manager;
    ftYieldWrapper public wrapperUSDC;
    ftYieldWrapper public wrapperWBTC;

    // Roles
    address public msig = address(0xA11CE);
    address public configurator = address(0xB0B);
    address public treasury = address(0x71EA5);
    address public yieldClaimer = address(0xC1A1);

    // Test users
    address public alice = address(0x1111);
    address public bob = address(0x2222);

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        ft = new MockERC20("Flying Tulip", "FT", 18);

        // Deploy oracle
        oracle = new MockFlyingTulipOracle();
        oracle.setAssetPrice(address(usdc), 1e8); // $1.00
        oracle.setAssetPrice(address(wbtc), 100_000e8); // $100,000
        // ftPerUSD defaults to 10 * 1e8 in the mock

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

        // Deploy wrappers
        wrapperUSDC = new ftYieldWrapper(address(usdc), yieldClaimer, yieldClaimer, treasury);
        wrapperWBTC = new ftYieldWrapper(address(wbtc), yieldClaimer, yieldClaimer, treasury);

        // Set putManager on wrappers
        vm.startPrank(yieldClaimer);
        wrapperUSDC.setPutManager(address(manager));
        wrapperWBTC.setPutManager(address(manager));
        vm.stopPrank();

        // Add accepted collaterals
        vm.startPrank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapperUSDC));
        manager.addAcceptedCollateral(address(wbtc), address(wrapperWBTC));
        vm.stopPrank();

        // Fund FT supply
        ft.mint(configurator, 100_000_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(50_000_000e18);
        vm.stopPrank();

        // Enable sale and transferable
        vm.startPrank(configurator);
        manager.setSaleEnabled(true);
        manager.enableTransferable();
        vm.stopPrank();

        // Fund users
        usdc.mint(alice, 10_000_000e6); // 10M USDC
        usdc.mint(bob, 10_000_000e6);
        wbtc.mint(alice, 100e8); // 100 WBTC
        wbtc.mint(bob, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                    WBTC PRICE INCREASE SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: WBTC price increases from $100k to $200k
    /// @dev User should receive back SAME amount of BTC, not less
    ///      Strike price is immutable - user gets 1 BTC regardless of current price
    function testFuzz_WBTC_priceIncrease_userGetsSameBTC(
        uint256 wbtcAmount,
        uint256 newPrice
    )
        public
    {
        // Bound inputs
        wbtcAmount = bound(wbtcAmount, 0.01e8, 10e8); // 0.01 to 10 WBTC
        newPrice = bound(newPrice, 100_000e8, 200_000e8); // $100k to $200k

        // Alice invests WBTC at $100k
        vm.startPrank(alice);
        wbtc.approve(address(manager), wbtcAmount);
        uint256 tokenId = manager.invest(address(wbtc), wbtcAmount, alice, 0, new bytes32[](0));
        vm.stopPrank();

        // Record initial state
        uint256 wbtcBalanceBefore = wbtc.balanceOf(alice);
        (uint256 ftBefore, uint256 strike, address token, uint64 ftPerUSD) = pft.divestable(tokenId);

        // Simulate WBTC price increase
        oracle.setAssetPrice(address(wbtc), newPrice);

        // Alice divests - should get back SAME wbtcAmount
        vm.startPrank(alice);
        manager.divest(tokenId, ftBefore);
        vm.stopPrank();

        uint256 wbtcBalanceAfter = wbtc.balanceOf(alice);
        uint256 wbtcReceived = wbtcBalanceAfter - wbtcBalanceBefore;

        // CRITICAL: User should get back EXACTLY the same WBTC amount
        // This verifies strike price immutability and correct PUT mechanics
        assertEq(
            wbtcReceived,
            wbtcAmount,
            "User should receive same WBTC amount regardless of price increase"
        );

        // Log for debugging
        console2.log("WBTC deposited:", wbtcAmount);
        console2.log("Price at divest:", newPrice);
        console2.log("WBTC received:", wbtcReceived);
    }

    /// @notice Test: User cannot extract more WBTC than deposited (price increase scenario)
    function testFuzz_WBTC_cannotExtractMore(uint256 wbtcAmount, uint256 newPrice) public {
        wbtcAmount = bound(wbtcAmount, 0.01e8, 10e8);
        newPrice = bound(newPrice, 100_000e8, 200_000e8);

        vm.startPrank(alice);
        wbtc.approve(address(manager), wbtcAmount);
        uint256 tokenId = manager.invest(address(wbtc), wbtcAmount, alice, 0, new bytes32[](0));
        vm.stopPrank();

        uint256 wbtcBalanceBefore = wbtc.balanceOf(alice);
        oracle.setAssetPrice(address(wbtc), newPrice);

        (uint256 ftAmount,,,) = pft.divestable(tokenId);

        vm.startPrank(alice);
        manager.divest(tokenId, ftAmount);
        vm.stopPrank();

        uint256 wbtcReceived = wbtc.balanceOf(alice) - wbtcBalanceBefore;

        // User should NEVER receive more than they deposited
        assertLe(wbtcReceived, wbtcAmount, "User cannot extract more WBTC than deposited");
    }

    /*//////////////////////////////////////////////////////////////
                    USDC DEPEG SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: USDC depegs from $1.00 to $0.67
    /// @dev User should receive SAME USDC amount regardless of external market depeg
    ///      If Alice deposits 1000 USDC at $1.00, she gets back 1000 USDC even if market price is $0.67
    ///      The contract maintains collateral amount immutability, not USD value
    function testFuzz_USDC_depeg_scenario(uint256 usdcAmount, uint256 newPrice) public {
        // Bound inputs
        usdcAmount = bound(usdcAmount, 1000e6, 1_000_000e6); // $1k to $1M USDC
        newPrice = bound(newPrice, 0.67e8, 1e8); // $0.67 to $1.00 (depeg scenario)

        // Alice invests USDC at $1.00
        vm.startPrank(alice);
        usdc.approve(address(manager), usdcAmount);
        uint256 tokenId = manager.invest(address(usdc), usdcAmount, alice, 0, new bytes32[](0));
        vm.stopPrank();

        // Record initial state
        uint256 usdcBalanceBefore = usdc.balanceOf(alice);
        (uint256 ftBefore, uint256 strike, address token, uint64 ftPerUSD) = pft.divestable(tokenId);

        // Simulate USDC depeg
        oracle.setAssetPrice(address(usdc), newPrice);

        // Alice divests
        vm.startPrank(alice);
        manager.divest(tokenId, ftBefore);
        vm.stopPrank();

        uint256 usdcBalanceAfter = usdc.balanceOf(alice);
        uint256 usdcReceived = usdcBalanceAfter - usdcBalanceBefore;

        // CRITICAL: User should get back EXACTLY the same USDC amount
        // External market depeg doesn't matter - contract returns same token amount
        // Those 1000 USDC might be worth less in external market ($670), but user gets 1000 USDC back
        assertEq(
            usdcReceived, usdcAmount, "User should receive same USDC amount regardless of depeg"
        );

        // Log for debugging
        console2.log("USDC deposited:", usdcAmount);
        console2.log("Price at divest:", newPrice);
        console2.log("USDC received:", usdcReceived);
    }

    /// @notice Test: User cannot extract more USDC than deposited (depeg scenario)
    /// @dev Same as WBTC test - collateral amount is immutable regardless of price
    function testFuzz_USDC_depeg_cannotExtractMore(uint256 usdcAmount, uint256 newPrice) public {
        usdcAmount = bound(usdcAmount, 1000e6, 1_000_000e6);
        newPrice = bound(newPrice, 0.67e8, 1e8);

        vm.startPrank(alice);
        usdc.approve(address(manager), usdcAmount);
        uint256 tokenId = manager.invest(address(usdc), usdcAmount, alice, 0, new bytes32[](0));
        vm.stopPrank();

        uint256 usdcBalanceBefore = usdc.balanceOf(alice);

        oracle.setAssetPrice(address(usdc), newPrice);

        (uint256 ftAmount,,,) = pft.divestable(tokenId);

        vm.startPrank(alice);
        manager.divest(tokenId, ftAmount);
        vm.stopPrank();

        uint256 usdcReceived = usdc.balanceOf(alice) - usdcBalanceBefore;

        // User should NEVER receive more USDC tokens than they deposited
        // (even though those USDC might be worth less in external market)
        assertLe(usdcReceived, usdcAmount, "User cannot extract more USDC than deposited");
    }

    /*//////////////////////////////////////////////////////////////
                    CROSS-USER SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Multiple users with price movements
    /// @dev Ensures one user's divest doesn't affect another user's position
    function testFuzz_multiUser_priceMovement_isolation(
        uint256 aliceWBTC,
        uint256 bobWBTC,
        uint256 priceChange
    )
        public
    {
        // Bound inputs
        aliceWBTC = bound(aliceWBTC, 0.1e8, 5e8);
        bobWBTC = bound(bobWBTC, 0.1e8, 5e8);
        priceChange = bound(priceChange, 100_000e8, 200_000e8);

        // Both users invest at $100k
        vm.startPrank(alice);
        wbtc.approve(address(manager), aliceWBTC);
        uint256 aliceTokenId = manager.invest(address(wbtc), aliceWBTC, alice, 0, new bytes32[](0));
        vm.stopPrank();

        vm.startPrank(bob);
        wbtc.approve(address(manager), bobWBTC);
        uint256 bobTokenId = manager.invest(address(wbtc), bobWBTC, bob, 0, new bytes32[](0));
        vm.stopPrank();

        // Price changes
        oracle.setAssetPrice(address(wbtc), priceChange);

        // Alice divests first
        uint256 aliceBalanceBefore = wbtc.balanceOf(alice);
        (uint256 aliceFT,,,) = pft.divestable(aliceTokenId);
        vm.prank(alice);
        manager.divest(aliceTokenId, aliceFT);
        uint256 aliceReceived = wbtc.balanceOf(alice) - aliceBalanceBefore;

        // Bob divests after
        uint256 bobBalanceBefore = wbtc.balanceOf(bob);
        (uint256 bobFT,,,) = pft.divestable(bobTokenId);
        vm.prank(bob);
        manager.divest(bobTokenId, bobFT);
        uint256 bobReceived = wbtc.balanceOf(bob) - bobBalanceBefore;

        // Both should receive their original amounts
        assertEq(aliceReceived, aliceWBTC, "Alice should receive original WBTC");
        assertEq(bobReceived, bobWBTC, "Bob should receive original WBTC");

        console2.log("Alice deposited:", aliceWBTC);
        console2.log("Alice received:", aliceReceived);
        console2.log("Bob deposited:", bobWBTC);
        console2.log("Bob received:", bobReceived);
    }

    /*//////////////////////////////////////////////////////////////
                    PARTIAL DIVEST SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Partial divest with price movements
    /// @dev User should receive proportional collateral on partial divest
    function testFuzz_partial_divest_with_priceChange(
        uint256 wbtcAmount,
        uint256 divestPercent,
        uint256 newPrice
    )
        public
    {
        wbtcAmount = bound(wbtcAmount, 0.1e8, 10e8);
        divestPercent = bound(divestPercent, 10, 90); // 10% to 90%
        newPrice = bound(newPrice, 100_000e8, 200_000e8);

        vm.startPrank(alice);
        wbtc.approve(address(manager), wbtcAmount);
        uint256 tokenId = manager.invest(address(wbtc), wbtcAmount, alice, 0, new bytes32[](0));
        vm.stopPrank();

        oracle.setAssetPrice(address(wbtc), newPrice);

        (uint256 ftTotal,,,) = pft.divestable(tokenId);
        uint256 ftToDivest = (ftTotal * divestPercent) / 100;

        uint256 wbtcBefore = wbtc.balanceOf(alice);
        vm.prank(alice);
        manager.divest(tokenId, ftToDivest);
        uint256 wbtcReceived = wbtc.balanceOf(alice) - wbtcBefore;

        // User should receive proportional WBTC
        uint256 expectedWBTC = (wbtcAmount * divestPercent) / 100;

        // Allow small tolerance for rounding
        assertApproxEqAbs(
            wbtcReceived,
            expectedWBTC,
            2, // 2 satoshi tolerance
            "Partial divest should return proportional WBTC"
        );

        console2.log("Total WBTC:", wbtcAmount);
        console2.log("Divest %:", divestPercent);
        console2.log("Expected WBTC:", expectedWBTC);
        console2.log("Received WBTC:", wbtcReceived);
    }
}
