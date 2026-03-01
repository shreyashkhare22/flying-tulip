// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLossStrategy} from "./mocks/MockLossStrategy.sol";
import {MockGainStrategy} from "./mocks/MockGainStrategy.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {pFT} from "contracts/pFT.sol";
import {PutManager} from "contracts/PutManager.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";

contract StrategyLossTest is Test {
    MockERC20 ftToken;
    MockERC20 usdc;
    ftYieldWrapper wrapper;
    MockFlyingTulipOracle oracle;
    pFT ftput;
    PutManager putManager;
    MockLossStrategy lossStrategy;
    MockGainStrategy gainStrategy;

    address msig = makeAddr("msig");
    address configurator = makeAddr("configurator");
    address yieldClaimer = makeAddr("yieldClaimer");
    address strategyManager = makeAddr("strategyManager");
    address treasury = makeAddr("treasury");
    address investor = makeAddr("investor");

    uint256 constant FT_LIQUIDITY = 200_000 * 1e18;

    function setUp() public {
        // Deploy tokens
        ftToken = new MockERC20("Flying Tulip", "FT", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        wrapper = new ftYieldWrapper(address(usdc), yieldClaimer, strategyManager, treasury);
        oracle = new MockFlyingTulipOracle();
        oracle.setAssetPrice(address(usdc), 1e8);

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        ftput = pFT(address(pftProxy));

        // Deploy implementation and proxy for PutManager (UUPS)
        PutManager impl = new PutManager(address(ftToken), address(ftput));
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(oracle)
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(impl), data);
        putManager = PutManager(address(managerProxy));

        vm.prank(configurator);
        ftput.initialize(address(putManager));

        lossStrategy = new MockLossStrategy(address(usdc));
        lossStrategy.setftYieldWrapper(address(wrapper));
        gainStrategy = new MockGainStrategy(address(usdc));
        gainStrategy.setftYieldWrapper(address(wrapper));

        ftToken.mint(configurator, 1_000_000 * 1e18);
        usdc.mint(investor, 10_000 * 1e6);

        vm.prank(configurator);
        ftToken.approve(address(putManager), type(uint256).max);
        vm.prank(investor);
        usdc.approve(address(putManager), type(uint256).max);

        vm.prank(strategyManager);
        wrapper.setPutManager(address(putManager));
        vm.prank(msig);
        putManager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        putManager.setCollateralCaps(address(usdc), type(uint256).max);
        vm.prank(configurator);
        putManager.addFTLiquidity(FT_LIQUIDITY);

        // Setting up two strategies will require doing one by one through the treasury
        vm.prank(strategyManager);
        wrapper.setStrategy(address(lossStrategy));
        vm.prank(treasury);
        wrapper.confirmStrategy();
        vm.prank(strategyManager);
        wrapper.setStrategy(address(gainStrategy));
        vm.prank(treasury);
        wrapper.confirmStrategy();
    }

    function testMultipleStrategiesWithPartialLossesSingleInvestor() public {
        uint256 investAmount = 10_000 * 1e6;

        vm.prank(investor);
        uint256 positionId =
            putManager.invest(address(usdc), investAmount, 0, MerkleHelper.emptyProof());
        (uint256 ftAmount,,) = putManager.getAssetFTPrice(address(usdc), investAmount);

        vm.prank(configurator);
        putManager.enableTransferable();

        vm.startPrank(yieldClaimer);
        wrapper.deploy(address(lossStrategy), investAmount / 2);
        wrapper.deploy(address(gainStrategy), investAmount / 2);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(lossStrategy)), investAmount / 2);
        assertEq(usdc.balanceOf(address(gainStrategy)), investAmount / 2);

        // Simulate 50% loss and 40% gain
        lossStrategy.simulateLoss();
        gainStrategy.simulateGain();

        assertEq(usdc.balanceOf(address(lossStrategy)), 2_500 * 1e6);
        assertEq(usdc.balanceOf(address(gainStrategy)), 7_000 * 1e6);
        assertEq(wrapper.availableToWithdraw(), 7_500 * 1e6);

        // Net loss: 10,000 - 7,500 = 2,500 USDC (gains not returned)
        assertEq(investAmount - wrapper.availableToWithdraw(), 2_500 * 1e6);

        // Attempt to withdraw full amount fails due to insufficient funds
        vm.prank(investor);
        vm.expectRevert();
        putManager.divest(positionId, ftAmount);

        (bool divestable, uint256 divestableAmount) =
            putManager.maxDivestable(positionId, 75_000 * 1e18);
        assertTrue(divestable);
        assertEq(divestableAmount, 75_000 * 1e18); // 75% of the original FT amount

        vm.prank(investor);
        putManager.divest(positionId, divestableAmount);
        assertEq(ftToken.balanceOf(address(investor)), 0);
        assertEq(usdc.balanceOf(address(investor)), 7_500 * 1e6);
    }

    function testMultipleStrategiesOneWithLossAndOneWithGainTwoInvestors() public {
        uint256 investAmount = 20_000 * 1e6;

        // Need more FT liquidity for larger investments
        vm.prank(configurator);
        putManager.addFTLiquidity(200_000 * 1e18);

        // Setup second investor
        address investor2 = makeAddr("investor2");
        usdc.mint(investor2, investAmount);
        vm.prank(investor2);
        usdc.approve(address(putManager), type(uint256).max);

        // Need more USDC for first investor too
        usdc.mint(investor, 10_000 * 1e6);

        // Both investors deposit same amount
        vm.prank(investor);
        uint256 positionId1 =
            putManager.invest(address(usdc), investAmount, 0, MerkleHelper.emptyProof());
        (uint256 ftAmount1,,) = putManager.getAssetFTPrice(address(usdc), investAmount);

        vm.prank(investor2);
        uint256 positionId2 =
            putManager.invest(address(usdc), investAmount, 0, MerkleHelper.emptyProof());
        (uint256 ftAmount2,,) = putManager.getAssetFTPrice(address(usdc), investAmount);

        vm.prank(configurator);
        putManager.enableTransferable();

        // Deploy total capital (40k) to strategies
        vm.startPrank(yieldClaimer);
        wrapper.deploy(address(lossStrategy), investAmount);
        wrapper.deploy(address(gainStrategy), investAmount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(lossStrategy)), investAmount);
        assertEq(usdc.balanceOf(address(gainStrategy)), investAmount);

        // Simulate 50% loss and 40% gain
        lossStrategy.simulateLoss();
        gainStrategy.simulateGain();

        assertEq(usdc.balanceOf(address(lossStrategy)), 10_000 * 1e6);
        assertEq(usdc.balanceOf(address(gainStrategy)), 28_000 * 1e6);
        assertEq(wrapper.availableToWithdraw(), 30_000 * 1e6);

        // Net loss: 40,000 - 30,000 = 10,000 USDC (gains not returned)
        assertEq(investAmount * 2 - wrapper.availableToWithdraw(), 10_000 * 1e6);

        // Check maxDivestable for both investors
        (bool divestable1, uint256 divestableAmount1) =
            putManager.maxDivestable(positionId1, ftAmount1);
        (bool divestable2, uint256 divestableAmount2) =
            putManager.maxDivestable(positionId2, ftAmount2);

        assertTrue(divestable1);
        assertTrue(divestable2);
        // Since each invested 20k and got 200k FT, but wrapper has 30k total
        // Each can technically withdraw their full 20k if they go first
        assertEq(divestableAmount1, ftAmount1);
        assertEq(divestableAmount2, ftAmount2);

        // First investor withdraws - gets their full 20k but depletes 2/3 of liquidity
        vm.prank(investor);
        putManager.divest(positionId1, divestableAmount1);
        uint256 investor1Balance = usdc.balanceOf(address(investor));
        assertEq(investor1Balance, 20_000 * 1e6);

        // Check remaining liquidity after first withdrawal
        assertEq(wrapper.availableToWithdraw(), 10_000 * 1e6);

        // Second investor cannot withdraw their full amount - insufficient liquidity
        vm.prank(investor2);
        vm.expectRevert();
        putManager.divest(positionId2, divestableAmount2);

        // But second investor can check how much they can actually withdraw
        (bool divestable2After, uint256 divestableAmount2After) =
            putManager.maxDivestable(positionId2, ftAmount2 / 2);
        assertTrue(divestable2After);
        assertEq(divestableAmount2After, 100_000 * 1e18); // Can divest 100% (20k/20k)

        // Second investor withdraws what's available
        vm.prank(investor2);
        putManager.divest(positionId2, divestableAmount2After);
        uint256 investor2Balance = usdc.balanceOf(address(investor2));
        assertEq(investor2Balance, 10_000 * 1e6);

        // Total withdrawn equals total available
        assertEq(investor1Balance + investor2Balance, 30_000 * 1e6);
    }
}
