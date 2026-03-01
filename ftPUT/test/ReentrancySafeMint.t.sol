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
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {MockAavePoolWithAToken} from "./mocks/MockAavePoolWithAToken.sol";
import {MockAavePoolAddressesProvider} from "./mocks/MockAavePoolAddressesProvider.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {MaliciousReentrancyReceiver} from "./mocks/MaliciousReentrancyReceiver.sol";

/// @title Reentrancy Protection Tests for _safeMint
/// @notice Verifies that _safeMint callback cannot be exploited for reentrancy attacks
/// @dev Tests all attack vectors: withdrawFT, divest, divestUnderlying, transfer, nested invest
contract ReentrancySafeMintTest is Test {
    // Core components
    MockERC20 public usdc;
    MockERC20 public ft;
    MockFlyingTulipOracle public oracle;
    pFT public pft;
    PutManager public manager;
    ftYieldWrapper public wrapperUSDC;
    AaveStrategy public strategyUSDC;

    // Aave mocks
    MockAToken public aUSDC;
    MockAavePoolWithAToken public pool;
    MockAavePoolAddressesProvider public provider;

    // Roles
    address public msig = address(0xA11CE);
    address public configurator = address(0xB0B);
    address public treasury = address(0x71EA5);
    address public yieldClaimer = address(0xC1A1);

    // Test user
    address public user = address(0x1111);

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        ft = new MockERC20("Flying Tulip", "FT", 18);

        // Deploy oracle
        oracle = new MockFlyingTulipOracle();
        oracle.setAssetPrice(address(usdc), 1e8); // $1.00

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

        // Deploy wrapper
        wrapperUSDC = new ftYieldWrapper(address(usdc), yieldClaimer, yieldClaimer, treasury);

        // Set putManager on wrapper
        vm.prank(yieldClaimer);
        wrapperUSDC.setPutManager(address(manager));

        // Deploy Aave strategy
        aUSDC = new MockAToken(usdc);
        pool = new MockAavePoolWithAToken(usdc, aUSDC);
        provider = new MockAavePoolAddressesProvider(address(pool));
        strategyUSDC = new AaveStrategy(
            address(wrapperUSDC), address(provider), address(usdc), address(aUSDC)
        );

        // Register strategy
        vm.startPrank(yieldClaimer);
        wrapperUSDC.setStrategy(address(strategyUSDC));
        vm.stopPrank();
        vm.prank(treasury);
        wrapperUSDC.confirmStrategy();

        // Add accepted collateral
        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapperUSDC));

        // Fund FT supply
        ft.mint(configurator, 100_000_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(50_000_000e18);
        vm.stopPrank();

        // Fund user
        usdc.mint(user, 100_000e6);

        // Enable sale
        vm.prank(configurator);
        manager.setSaleEnabled(true);

        vm.prank(configurator);
        manager.enableTransferable();
    }

    /*//////////////////////////////////////////////////////////////
                    REENTRANCY ATTACK TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Attacker cannot reenter via withdrawFT during _safeMint callback
    function test_ReentrancyBlocked_WithdrawFT() public {
        MaliciousReentrancyReceiver attacker =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        attacker.setAttackType(MaliciousReentrancyReceiver.AttackType.WITHDRAW_FT);

        uint256 amount = 10_000e6;
        usdc.mint(address(attacker), amount);

        vm.startPrank(address(attacker));
        usdc.approve(address(manager), amount);
        attacker.investAndAttack(address(usdc), amount);
        vm.stopPrank();

        // Verify attack was attempted (callback triggered) but blocked by nonReentrant
        assertGt(attacker.reentrancyAttempts(), 0, "Callback should trigger attack attempt");
        assertFalse(attacker.attackSucceeded(), "CRITICAL: Reentrancy attack succeeded!");

        console2.log("[PASS] WithdrawFT reentrancy blocked");
        console2.log("  Failure reason:", attacker.failureReason());
    }

    /// @notice Test: Attacker cannot reenter via divest during _safeMint callback
    function test_ReentrancyBlocked_Divest() public {
        MaliciousReentrancyReceiver attacker =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        attacker.setAttackType(MaliciousReentrancyReceiver.AttackType.DIVEST);

        uint256 amount = 10_000e6;
        usdc.mint(address(attacker), amount);

        vm.startPrank(address(attacker));
        usdc.approve(address(manager), amount);
        attacker.investAndAttack(address(usdc), amount);
        vm.stopPrank();

        assertGt(attacker.reentrancyAttempts(), 0, "Callback should trigger attack attempt");
        assertFalse(attacker.attackSucceeded(), "CRITICAL: Reentrancy attack succeeded!");

        console2.log("[PASS] Divest reentrancy blocked");
        console2.log("  Failure reason:", attacker.failureReason());
    }

    /// @notice Test: Attacker cannot reenter via divestUnderlying during _safeMint callback
    function test_ReentrancyBlocked_DivestUnderlying() public {
        MaliciousReentrancyReceiver attacker =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        attacker.setAttackType(MaliciousReentrancyReceiver.AttackType.DIVEST_UNDERLYING);

        uint256 amount = 10_000e6;
        usdc.mint(address(attacker), amount);

        vm.startPrank(address(attacker));
        usdc.approve(address(manager), amount);
        attacker.investAndAttack(address(usdc), amount);
        vm.stopPrank();

        assertGt(attacker.reentrancyAttempts(), 0, "Callback should trigger attack attempt");
        assertFalse(attacker.attackSucceeded(), "CRITICAL: Reentrancy attack succeeded!");

        console2.log("[PASS] DivestUnderlying reentrancy blocked");
        console2.log("  Failure reason:", attacker.failureReason());
    }

    /// @notice Test: NFT transfer during _safeMint callback is allowed but safe
    /// @dev Transfer succeeds because state is fully updated before _safeMint is called
    /// @dev This is safe: Put struct is written (line 142-152) before _safeMint (line 154)
    /// @dev Transfer doesn't compromise protocol - can't reenter invest/divest/withdraw
    function test_Transfer_DuringMint_IsSafe() public {
        MaliciousReentrancyReceiver attacker =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        attacker.setAttackType(MaliciousReentrancyReceiver.AttackType.TRANSFER);

        uint256 amount = 10_000e6;
        usdc.mint(address(attacker), amount);

        vm.startPrank(address(attacker));
        usdc.approve(address(manager), amount);
        attacker.investAndAttack(address(usdc), amount);
        vm.stopPrank();

        assertGt(attacker.reentrancyAttempts(), 0, "Callback should trigger transfer attempt");
        assertTrue(attacker.attackSucceeded(), "Transfer should succeed");

        // Verify NFT was transferred to 0xdead
        uint256 tokenId = attacker.receivedTokenId();
        assertEq(pft.ownerOf(tokenId), address(0xdead), "NFT should be at 0xdead");

        // Verify Put data is intact (proving state was set before transfer)
        (,, uint96 ft,,,,,,) = pft.puts(tokenId);
        assertGt(ft, 0, "Put data should be valid");

        console2.log("[PASS] Transfer during mint is safe - state updated before callback");
        console2.log("  NFT transferred to 0xdead, Put data intact");
    }

    /// @notice Test: Attacker cannot invest again during _safeMint callback (FT drain attack)
    function test_ReentrancyBlocked_NestedInvest() public {
        MaliciousReentrancyReceiver attacker =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        attacker.setAttackType(MaliciousReentrancyReceiver.AttackType.INVEST_AGAIN);
        attacker.setToken(address(usdc));

        uint256 amount = 10_000e6;
        // Fund attacker with 2x amount for nested invest attempt
        usdc.mint(address(attacker), amount * 2);

        vm.startPrank(address(attacker));
        usdc.approve(address(manager), type(uint256).max);
        attacker.investAndAttack(address(usdc), amount);
        vm.stopPrank();

        assertGt(attacker.reentrancyAttempts(), 0, "Callback should trigger attack attempt");
        assertFalse(attacker.attackSucceeded(), "CRITICAL: Reentrancy attack succeeded!");

        console2.log("[PASS] Nested invest reentrancy blocked");
        console2.log("  Failure reason:", attacker.failureReason());
    }

    /*//////////////////////////////////////////////////////////////
                    POSITIVE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Normal contract receiver works fine without attack
    function test_SafeMint_BenignReceiver() public {
        MaliciousReentrancyReceiver receiver =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        receiver.setAttackType(MaliciousReentrancyReceiver.AttackType.NONE);

        uint256 amount = 10_000e6;
        usdc.mint(address(receiver), amount);

        vm.startPrank(address(receiver));
        usdc.approve(address(manager), amount);
        uint256 tokenId =
            manager.invest(address(usdc), amount, address(receiver), 0, new bytes32[](0));
        vm.stopPrank();

        assertEq(pft.ownerOf(tokenId), address(receiver), "Receiver should own NFT");
        assertEq(receiver.reentrancyAttempts(), 0, "No attack attempted");

        console2.log("[PASS] Benign contract receiver works correctly");
    }

    /// @notice Test: Multiple investments from same contract work
    function test_SafeMint_MultipleInvestments() public {
        MaliciousReentrancyReceiver receiver =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        receiver.setAttackType(MaliciousReentrancyReceiver.AttackType.NONE);

        uint256 amount = 5_000e6;
        usdc.mint(address(receiver), amount * 3);

        vm.startPrank(address(receiver));
        usdc.approve(address(manager), type(uint256).max);

        uint256 tokenId1 =
            manager.invest(address(usdc), amount, address(receiver), 0, new bytes32[](0));
        uint256 tokenId2 =
            manager.invest(address(usdc), amount, address(receiver), 0, new bytes32[](0));
        uint256 tokenId3 =
            manager.invest(address(usdc), amount, address(receiver), 0, new bytes32[](0));

        vm.stopPrank();

        assertEq(pft.balanceOf(address(receiver)), 3, "Should have 3 NFTs");
        assertEq(pft.ownerOf(tokenId1), address(receiver));
        assertEq(pft.ownerOf(tokenId2), address(receiver));
        assertEq(pft.ownerOf(tokenId3), address(receiver));

        console2.log("[PASS] Multiple sequential investments work correctly");
    }

    /// @notice Test: EOA recipient still works (no callback)
    function test_SafeMint_EOARecipient() public {
        uint256 amount = 10_000e6;

        vm.startPrank(user);
        usdc.approve(address(manager), amount);
        uint256 tokenId = manager.invest(address(usdc), amount, user, 0, new bytes32[](0));
        vm.stopPrank();

        assertEq(pft.ownerOf(tokenId), user, "User should own NFT");

        console2.log("[PASS] EOA recipient works correctly");
    }
}
