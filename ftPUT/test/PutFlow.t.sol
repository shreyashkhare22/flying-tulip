// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
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
import {MerkleHelper} from "./helpers/MerkleHelper.sol";

contract PutFlowTest is Test {
    // roles
    address msig = address(0xA11CE);
    address configurator = address(0xB0B);
    address treasury = address(0x71EA5);
    address investor = address(0x13570);

    // core components
    MockERC20 usdc; // underlying
    MockERC20 ft; // FT ERC20 (burnable)
    MockFlyingTulipOracle aaveOracle;
    pFT pft;
    PutManager manager;
    ftYieldWrapper wrapper;
    AaveStrategy strategy;

    // aave mocks
    MockAToken aUSDC;
    MockAavePoolWithAToken pool;
    MockAavePoolAddressesProvider provider;

    uint256 constant USDC_DECIMALS = 6;

    function setUp() public {
        // tokens
        usdc = new MockERC20("USD Coin", "USDC", uint8(USDC_DECIMALS));
        ft = new MockERC20("Flying Tulip", "FT", 18);

        // oracle
        aaveOracle = new MockFlyingTulipOracle();

        // pFT behind an ERC1967 proxy so we can call initialize()
        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        pft = pFT(address(pftProxy));

        // Deploy PutManager implementation and wrap with ERC1967Proxy (UUPS)
        PutManager impl = new PutManager(address(ft), address(pft));
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(aaveOracle)
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(impl), data);
        manager = PutManager(address(managerProxy));

        // call initialize on pFT via proxy manager address (pFT expects the manager address)
        vm.prank(investor);
        pft.initialize(address(manager));

        // wrapper + strategy
        wrapper = new ftYieldWrapper(address(usdc), address(this), address(this), treasury);

        // Set putManager so PutManager can deposit
        wrapper.setPutManager(address(manager));

        aUSDC = new MockAToken(usdc);
        pool = new MockAavePoolWithAToken(usdc, aUSDC);
        provider = new MockAavePoolAddressesProvider(address(pool));
        strategy =
            new AaveStrategy(address(wrapper), address(provider), address(usdc), address(aUSDC));

        // register strategy
        wrapper.setStrategy(address(strategy));
        vm.prank(treasury);
        wrapper.confirmStrategy();

        // allow USDC as collateral, point to wrapper
        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));

        // fund FT supply to configurator and add to offering pool
        ft.mint(configurator, 10_000_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(5_000_000e18);
        vm.stopPrank();
    }

    function _invest(uint256 deposit) internal returns (uint256 id) {
        // investor gets USDC
        usdc.mint(investor, deposit);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        id = manager.invest(address(usdc), deposit, 0, MerkleHelper.emptyProof());
        vm.stopPrank();
        assertEq(pft.ownerOf(id), investor);
        // wrapper received deposit via manager
        assertEq(wrapper.totalSupply(), deposit);
        assertEq(usdc.balanceOf(address(wrapper)), deposit);
    }

    function _deployAll() internal {
        // yieldClaimer (this) deploys all capital to Aave strategy
        uint256 bal = usdc.balanceOf(address(wrapper));
        wrapper.deploy(address(strategy), bal);
        assertEq(usdc.balanceOf(address(wrapper)), 0);
        // strategy holds aUSDC 1:1 with deployed capital
        assertEq(aUSDC.balanceOf(address(strategy)), bal);
    }

    function _endOffering() internal {
        vm.prank(configurator);
        manager.enableTransferable();
    }

    function test_InvestForRecipient_MintsTokenToRecipient() public {
        address recipient = address(0xBEEF);
        uint256 deposit = 25_000e6;

        usdc.mint(investor, deposit);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        uint256 id = manager.invest(address(usdc), deposit, recipient, 0, MerkleHelper.emptyProof());
        vm.stopPrank();

        assertEq(pft.ownerOf(id), recipient);
        assertEq(wrapper.totalSupply(), deposit);
        assertEq(usdc.balanceOf(address(wrapper)), deposit);
    }

    function test_InvestForRecipient_RevertZeroRecipient() public {
        uint256 deposit = 1_000e6;

        usdc.mint(investor, deposit);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        vm.expectRevert(PutManager.ftPutManagerZeroAddress.selector);
        manager.invest(address(usdc), deposit, address(0), 0, MerkleHelper.emptyProof());
        vm.stopPrank();
    }

    function test_Flow_ExecutePut_WithdrawsFromAave_ToUser() public {
        uint256 deposit = 100_000e6; // 100k USDC
        uint256 id = _invest(deposit);
        _deployAll();
        _endOffering();

        // Ask manager for max divestable amount (in FT) for full position
        (bool ok, uint256 maxFT) = manager.maxDivestable(id, type(uint256).max);
        assertTrue(ok);
        assertGt(maxFT, 0);

        // Execute divest for all FT with enforceExact
        vm.prank(investor);
        manager.divest(id, maxFT);

        // User received their full principal back
        assertEq(usdc.balanceOf(investor), deposit);
        // Wrapper and strategy principal decreased accordingly
        assertEq(wrapper.totalSupply(), 0);
        assertEq(aUSDC.balanceOf(address(strategy)), 0);
    }

    function test_Flow_WithdrawFT_ThenMsigWithdrawCapital() public {
        uint256 deposit = 50_000e6; // 50k USDC
        uint256 id = _invest(deposit);
        _deployAll();
        _endOffering();

        // Determine how much FT is withdrawable (full position)
        (bool ok, uint256 maxFT) = manager.maxDivestable(id, type(uint256).max);
        assertTrue(ok);

        // Withdraw FT -> invalidates PUT; underlying should be earmarked to msig via capitalDivesting
        vm.prank(investor);
        manager.withdrawFT(id, maxFT);

        // capital to be divested should equal the deposit (since $1 price)
        uint256 earmarked = manager.capitalDivesting(address(usdc));
        assertEq(earmarked, deposit);

        // msig pulls earmarked capital back to itself from the wrapper
        vm.prank(msig);
        manager.withdrawDivestedCapital(address(usdc), deposit);

        assertEq(usdc.balanceOf(msig), deposit);
        // wrapper and strategy principal decreased accordingly
        assertEq(wrapper.totalSupply(), 0);
        assertEq(aUSDC.balanceOf(address(strategy)), 0);
    }

    function test_Yield_Is_Claimed_To_Treasury() public {
        uint256 deposit = 10_000e6; // 10k USDC
        _invest(deposit);
        _deployAll();

        // Simulate 1k USDC worth of aUSDC yield minted to strategy
        uint256 yieldAmt = 1_000e6;
        vm.prank(address(this));
        aUSDC.addYield(address(strategy), yieldAmt);

        // Claim yield via wrapper -> should transfer aUSDC yield to treasury
        uint256 claimed = wrapper.claimYield(address(strategy));
        assertEq(claimed, yieldAmt);
        assertEq(aUSDC.balanceOf(treasury), yieldAmt);

        // Principal (wrapper totalSupply) unchanged
        assertEq(wrapper.totalSupply(), deposit);
    }
}
