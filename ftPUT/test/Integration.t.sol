// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {pFT} from "contracts/pFT.sol";
import {PutManager} from "contracts/PutManager.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";

contract IntegrationTest is Test {
    uint256 internal constant INITIAL_USDC_BALANCE = 1_000_000 * 1e6;
    uint256 internal constant DEFAULT_FT_LIQUIDITY = 200_000 * 1e18;
    uint256 internal constant DEFAULT_INVEST_AMOUNT = 3_000 * 1e6;

    struct Context {
        address msig;
        address configurator;
        address yieldClaimer;
        address strategyManager;
        address treasury;
        address investor1;
        address investor2;
        address outsider;
        MockERC20 ftToken;
        MockERC20 usdc;
        MockERC20 altToken;
        ftYieldWrapper wrapper;
        ftYieldWrapper wrapperAlt;
        MockFlyingTulipOracle oracle;
        pFT ftput;
        PutManager putManager;
        MockStrategy strategy;
    }

    struct Position {
        uint256 id;
        uint256 initialFt;
        uint256 strike;
        uint256 amount;
    }

    function _deployFixture() internal returns (Context memory ctx) {
        ctx.msig = makeAddr("msig");
        ctx.configurator = makeAddr("configurator");
        ctx.yieldClaimer = makeAddr("yieldClaimer");
        ctx.strategyManager = makeAddr("strategyManager");
        ctx.treasury = makeAddr("treasury");
        ctx.investor1 = makeAddr("investor1");
        ctx.investor2 = makeAddr("investor2");
        ctx.outsider = makeAddr("outsider");

        ctx.ftToken = new MockERC20("Flying Tulip", "FT", 18);
        ctx.usdc = new MockERC20("USD Coin", "USDC", 6);
        ctx.altToken = new MockERC20("Alt USD", "ALT", 18);

        ctx.wrapper = new ftYieldWrapper(
            address(ctx.usdc), ctx.yieldClaimer, ctx.strategyManager, ctx.treasury
        );
        ctx.wrapperAlt = new ftYieldWrapper(
            address(ctx.altToken), ctx.yieldClaimer, ctx.strategyManager, ctx.treasury
        );

        ctx.oracle = new MockFlyingTulipOracle();
        ctx.oracle.setAssetPrice(address(ctx.usdc), 1e8);
        ctx.oracle.setAssetPrice(address(ctx.altToken), 5e7);

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        ctx.ftput = pFT(address(pftProxy));

        // Deploy PutManager implementation and wrap with ERC1967Proxy (UUPS)
        PutManager impl = new PutManager(address(ctx.ftToken), address(ctx.ftput));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, ctx.configurator, ctx.msig, address(ctx.oracle)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ctx.putManager = PutManager(address(proxy));

        // Initialize pFT from non-admin (not MSIG)
        vm.prank(ctx.configurator);
        ctx.ftput.initialize(address(ctx.putManager));

        // Set putManager on wrappers so PutManager can deposit
        vm.prank(ctx.strategyManager);
        ctx.wrapper.setPutManager(address(ctx.putManager));
        vm.prank(ctx.strategyManager);
        ctx.wrapperAlt.setPutManager(address(ctx.putManager));

        ctx.strategy = new MockStrategy(address(ctx.usdc));
        ctx.strategy.setftYieldWrapper(address(ctx.wrapper));

        ctx.ftToken.mint(ctx.configurator, 1_000_000 * 1e18);
        vm.startPrank(ctx.configurator);
        ctx.ftToken.approve(address(ctx.putManager), type(uint256).max);
        vm.stopPrank();

        ctx.usdc.mint(ctx.investor1, INITIAL_USDC_BALANCE);
        ctx.usdc.mint(ctx.investor2, INITIAL_USDC_BALANCE);
        ctx.altToken.mint(ctx.investor1, 50_000 * 1e18);

        vm.startPrank(ctx.investor1);
        ctx.usdc.approve(address(ctx.wrapper), type(uint256).max);
        ctx.usdc.approve(address(ctx.wrapperAlt), type(uint256).max);
        ctx.usdc.approve(address(ctx.putManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(ctx.investor2);
        ctx.usdc.approve(address(ctx.putManager), type(uint256).max);

        return ctx;
    }

    function _addCollateralAndLiquidity(Context memory ctx, uint256 ftLiquidity) internal {
        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));
        vm.prank(ctx.configurator);
        ctx.putManager.setCollateralCaps(address(ctx.usdc), type(uint256).max);
        vm.prank(ctx.configurator);
        ctx.putManager.addFTLiquidity(ftLiquidity);
    }

    function _addCollateralAndLiquidity(Context memory ctx) internal {
        _addCollateralAndLiquidity(ctx, DEFAULT_FT_LIQUIDITY);
    }

    function _investPosition(
        Context memory ctx,
        uint256 amount
    )
        internal
        returns (Position memory pos)
    {
        vm.prank(ctx.investor1);
        uint256 id = ctx.putManager.invest(address(ctx.usdc), amount, 0, MerkleHelper.emptyProof());
        (uint256 ftAmount, uint256 strike,) =
            ctx.putManager.getAssetFTPrice(address(ctx.usdc), amount);
        pos = Position({id: id, initialFt: ftAmount, strike: strike, amount: amount});
    }

    function _investPosition(Context memory ctx) internal returns (Position memory pos) {
        return _investPosition(ctx, DEFAULT_INVEST_AMOUNT);
    }

    function _setupPostOffering() internal returns (Context memory ctx, Position memory pos) {
        ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);
        pos = _investPosition(ctx);
        vm.prank(ctx.configurator);
        ctx.putManager.enableTransferable();
    }

    function collateralFromFT(
        uint256 amountFt,
        uint256 strike,
        uint256 decimals
    )
        internal
        pure
        returns (uint256)
    {
        uint256 scale = 10 ** decimals;
        return (amountFt * 1e8 * scale) / (strike * 10 * 1e18);
    }

    function testInitialisesWiring() public {
        Context memory ctx = _deployFixture();

        assertEq(ctx.putManager.msig(), ctx.msig);
        assertEq(ctx.putManager.configurator(), ctx.configurator);
        assertEq(ctx.putManager.ftOfferingSupply(), 0);
        assertEq(ctx.putManager.ftAllocated(), 0);
        assertEq(ctx.putManager.getFTAddress(), address(ctx.ftToken));
        assertEq(ctx.putManager.getOracleAddress(), address(ctx.oracle));
        assertEq(ctx.putManager.getAssetPrice(address(ctx.usdc)), 1e8);
        assertEq(ctx.putManager.collateralIndex(), 0);
    }

    function testInvestFlow() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);

        (uint256 expectedFt, uint256 strike,) =
            ctx.putManager.getAssetFTPrice(address(ctx.usdc), DEFAULT_INVEST_AMOUNT);
        Position memory pos = _investPosition(ctx);

        assertEq(pos.initialFt, expectedFt);
        assertEq(pos.strike, strike);
        assertEq(ctx.putManager.ftAllocated(), expectedFt);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), DEFAULT_INVEST_AMOUNT);
    }

    function testExitDuringPublicOffering() public {
        Context memory ctx = _deployFixture();
        _addCollateralAndLiquidity(ctx);
        Position memory pos = _investPosition(ctx);

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        assertEq(ctx.putManager.ftAllocated(), 0);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), 0);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", pos.id));
        ctx.ftput.ownerOf(pos.id);
    }

    function testPostOfferingDivestFlow() public {
        (Context memory ctx, Position memory pos) = _setupPostOffering();

        uint256 _partial = pos.initialFt / 2;
        vm.prank(ctx.investor1);
        ctx.putManager.withdrawFT(pos.id, _partial);

        uint256 expectedCollateral = collateralFromFT(_partial, pos.strike, 6);
        assertEq(ctx.putManager.capitalDivesting(address(ctx.usdc)), expectedCollateral);

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt - _partial);

        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", pos.id));
        ctx.ftput.ownerOf(pos.id);
        uint256 expectedWrapperBalance =
            pos.amount - collateralFromFT(pos.initialFt - _partial, pos.strike, 6);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), expectedWrapperBalance);

        vm.prank(ctx.msig);
        ctx.putManager.withdrawDivestedCapital(address(ctx.usdc), type(uint256).max);
        assertEq(ctx.putManager.capitalDivesting(address(ctx.usdc)), 0);
    }
}
