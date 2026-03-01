// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {pFT} from "contracts/pFT.sol";
import {PutManager} from "contracts/PutManager.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";

contract PutManagerIntegrationTest is Test {
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
        MockERC20 weirdToken;
        ftYieldWrapper wrapper;
        ftYieldWrapper wrapperAlt;
        MockFlyingTulipOracle oracle;
        pFT ftput;
        PutManager putManager;
    }

    struct Position {
        uint256 id;
        uint256 initialFt;
        uint256 strike;
        uint256 amount;
    }

    function _deploy() internal returns (Context memory ctx) {
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
        ctx.weirdToken = new MockERC20("Weird", "WRD", 19);

        ctx.wrapper = new ftYieldWrapper(
            address(ctx.usdc), ctx.yieldClaimer, ctx.strategyManager, ctx.treasury
        );
        ctx.wrapperAlt = new ftYieldWrapper(
            address(ctx.altToken), ctx.yieldClaimer, ctx.strategyManager, ctx.treasury
        );

        ctx.oracle = new MockFlyingTulipOracle();
        ctx.oracle.setAssetPrice(address(ctx.usdc), 1e8);
        ctx.oracle.setAssetPrice(address(ctx.altToken), 2e8);

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        ctx.ftput = pFT(address(pftProxy));

        // Deploy PutManager implementation and proxy (UUPS)
        PutManager impl = new PutManager(address(ctx.ftToken), address(ctx.ftput));
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, ctx.configurator, ctx.msig, address(ctx.oracle)
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(impl), data);
        ctx.putManager = PutManager(address(managerProxy));

        vm.prank(ctx.configurator);
        ctx.ftput.initialize(address(ctx.putManager));

        // Set putManager on wrappers so PutManager can deposit
        vm.prank(ctx.strategyManager);
        ctx.wrapper.setPutManager(address(ctx.putManager));
        vm.prank(ctx.strategyManager);
        ctx.wrapperAlt.setPutManager(address(ctx.putManager));

        ctx.ftToken.mint(ctx.configurator, 500_000 * 1e18);
        vm.startPrank(ctx.configurator);
        ctx.ftToken.approve(address(ctx.putManager), type(uint256).max);
        vm.stopPrank();

        ctx.usdc.mint(ctx.investor1, INITIAL_USDC_BALANCE);
        ctx.usdc.mint(ctx.investor2, INITIAL_USDC_BALANCE);
        ctx.altToken.mint(ctx.investor1, 50_000 * 1e18);

        vm.startPrank(ctx.investor1);
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
        ctx = _deploy();
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

    function testDeploymentInitialisesCoreState() public {
        Context memory ctx = _deploy();

        assertEq(ctx.putManager.msig(), ctx.msig);
        assertEq(ctx.putManager.configurator(), ctx.configurator);
        assertEq(ctx.putManager.ftOfferingSupply(), 0);
        assertEq(ctx.putManager.ftAllocated(), 0);
        assertEq(ctx.putManager.getFTAddress(), address(ctx.ftToken));
        assertEq(ctx.putManager.getOracleAddress(), address(ctx.oracle));
        assertEq(ctx.putManager.getAssetPrice(address(ctx.usdc)), 1e8);
        assertEq(ctx.putManager.collateralIndex(), 0);
    }

    function testRoleManagement() public {
        Context memory ctx = _deploy();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(ctx.outsider);
        ctx.putManager.setConfigurator(ctx.outsider);

        vm.expectRevert(PutManager.ftPutManagerZeroAddress.selector);
        vm.prank(ctx.msig);
        ctx.putManager.setConfigurator(address(0));

        vm.prank(ctx.msig);
        ctx.putManager.setConfigurator(ctx.outsider);
        assertEq(ctx.putManager.configurator(), ctx.outsider);

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(ctx.outsider);
        ctx.putManager.setMsig(ctx.msig);

        vm.prank(ctx.msig);
        ctx.putManager.setMsig(ctx.outsider);

        vm.expectRevert(PutManager.ftPutManagerInvalidMsig.selector);
        vm.prank(ctx.outsider);
        ctx.putManager.acceptMsig();

        vm.warp(block.timestamp + 3605);
        vm.prank(ctx.outsider);
        ctx.putManager.acceptMsig();
        assertEq(ctx.putManager.msig(), ctx.outsider);

        vm.prank(ctx.outsider);
        ctx.putManager.setConfigurator(ctx.configurator);
        assertEq(ctx.putManager.configurator(), ctx.configurator);
    }

    function testCollateralConfiguration() public {
        Context memory ctx = _deploy();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(ctx.configurator);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));

        vm.expectRevert(PutManager.ftPutManagerZeroAddress.selector);
        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(0), address(ctx.wrapper));

        vm.expectRevert(PutManager.ftPutManagerInvalidInvestmentAsset.selector);
        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.altToken), address(ctx.wrapper));

        vm.expectRevert(PutManager.ftPutManagerInvalidDecimals.selector);
        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.weirdToken), address(ctx.wrapper));

        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));
        assertEq(ctx.putManager.collateralIndex(), 1);

        vm.expectRevert(PutManager.ftPutManagerInvalidInvestmentAsset.selector);
        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));

        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.altToken), address(ctx.wrapperAlt));
        assertEq(ctx.putManager.collateralIndex(), 2);
    }

    function testFTLiquidityManagement() public {
        Context memory ctx = _deploy();

        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(ctx.msig);
        ctx.putManager.addFTLiquidity(DEFAULT_FT_LIQUIDITY);

        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));

        vm.expectRevert(PutManager.ftPutManagerInvalidAmount.selector);
        vm.prank(ctx.configurator);
        ctx.putManager.addFTLiquidity(0);

        vm.prank(ctx.configurator);
        ctx.putManager.addFTLiquidity(DEFAULT_FT_LIQUIDITY);

        assertEq(ctx.putManager.ftOfferingSupply(), DEFAULT_FT_LIQUIDITY);
        assertEq(ctx.ftToken.balanceOf(address(ctx.putManager)), DEFAULT_FT_LIQUIDITY);
    }

    function testInvestRequiresCollateralAndLiquidity() public {
        Context memory ctx = _deploy();

        vm.expectRevert(PutManager.ftPutManagerInvalidInvestmentAsset.selector);
        vm.prank(ctx.investor1);
        ctx.putManager
            .invest(
                address(ctx.usdc),
                DEFAULT_INVEST_AMOUNT,
                DEFAULT_INVEST_AMOUNT,
                MerkleHelper.emptyProof()
            );

        vm.prank(ctx.msig);
        ctx.putManager.addAcceptedCollateral(address(ctx.usdc), address(ctx.wrapper));
        vm.prank(ctx.configurator);
        ctx.putManager.setCollateralCaps(address(ctx.usdc), type(uint256).max);

        vm.expectRevert(PutManager.ftPutManagerInsufficientFTLiquidity.selector);
        vm.prank(ctx.investor1);
        ctx.putManager
            .invest(
                address(ctx.usdc),
                DEFAULT_INVEST_AMOUNT,
                DEFAULT_INVEST_AMOUNT,
                MerkleHelper.emptyProof()
            );

        vm.prank(ctx.configurator);
        ctx.putManager.addFTLiquidity(DEFAULT_FT_LIQUIDITY);

        vm.expectRevert(PutManager.ftPutManagerInvalidAmount.selector);
        vm.prank(ctx.investor1);
        ctx.putManager.invest(address(ctx.usdc), 0, 0, MerkleHelper.emptyProof());

        Position memory pos = _investPosition(ctx);

        (
            address tokenAddr,
            uint256 amount,
            uint256 ft,
            uint256 ftBought,
            uint256 withdrawn,
            uint256 burned,
            uint256 strike,
            uint256 amountRemaining,
            uint256 ftPerUSD
        ) = ctx.ftput.puts(pos.id);
        assertEq(amount, DEFAULT_INVEST_AMOUNT);
        assertEq(ft, pos.initialFt);
        assertEq(withdrawn, 0);
        assertEq(burned, 0);
        assertEq(strike, pos.strike);
        assertEq(tokenAddr, address(ctx.usdc));
        assertEq(ctx.putManager.ftAllocated(), pos.initialFt);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), DEFAULT_INVEST_AMOUNT);
    }

    function testAllowsExitDuringPublicOffering() public {
        Context memory ctx = _deploy();
        _addCollateralAndLiquidity(ctx);
        Position memory pos = _investPosition(ctx);

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);

        assertEq(ctx.putManager.ftAllocated(), 0);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), 0);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", pos.id));
        ctx.ftput.ownerOf(pos.id);
    }

    function testSendsFTRemainderBackToConfigurator() public {
        Context memory ctx = _deploy();
        _addCollateralAndLiquidity(ctx);
        _investPosition(ctx, 1_000 * 1e6);

        uint256 remainder = ctx.putManager.ftOfferingSupply() - ctx.putManager.ftAllocated();
        uint256 balanceBefore = ctx.ftToken.balanceOf(ctx.configurator);

        vm.prank(ctx.configurator);
        ctx.putManager.sendRemainderFTtoConfigurator();

        assertEq(ctx.ftToken.balanceOf(ctx.configurator), balanceBefore + remainder);
        assertEq(ctx.putManager.ftOfferingSupply(), ctx.putManager.ftAllocated());
        assertGt(remainder, 0);
    }

    function testPostOfferingBlocksPublicOfferingCalls() public {
        (Context memory ctx, Position memory pos) = _setupPostOffering();

        vm.prank(ctx.configurator);
        ctx.putManager.addFTLiquidity(1);

        vm.prank(ctx.investor1);
        ctx.putManager.invest(address(ctx.usdc), pos.amount, 0, MerkleHelper.emptyProof());

        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, pos.initialFt);
    }

    function testPostOfferingWithdrawTracksCapital() public {
        (Context memory ctx, Position memory pos) = _setupPostOffering();
        uint256 _partial = pos.initialFt / 2;

        vm.expectRevert(pFT.pFTOnlyPutOwner.selector);
        vm.prank(ctx.investor2);
        ctx.putManager.withdrawFT(pos.id, _partial);

        vm.prank(ctx.investor1);
        ctx.putManager.withdrawFT(pos.id, _partial);

        assertEq(ctx.ftToken.balanceOf(ctx.investor1), _partial);

        uint256 expectedCollateral = collateralFromFT(_partial, pos.strike, 6);
        assertEq(ctx.putManager.capitalDivesting(address(ctx.usdc)), expectedCollateral);

        (
            address _t,
            uint256 _a,
            uint256 ftRemaining,
            uint256 _fb,
            uint256 withdrawn,
            uint256 _b,
            uint256 _s,
            uint256 _ar,
            uint256 _fpu
        ) = ctx.ftput.puts(pos.id);
        assertEq(ftRemaining, pos.initialFt - _partial);
        assertEq(withdrawn, _partial);

        (bool canAfter, uint256 amountAfter) =
            ctx.putManager.canDivest(pos.id, pos.initialFt - _partial);
        assertTrue(canAfter);
        assertEq(amountAfter, pos.initialFt - _partial);

        (bool maxOk, uint256 maxAmount) =
            ctx.putManager.maxDivestable(pos.id, pos.initialFt - _partial);
        assertTrue(maxOk);
        assertEq(maxAmount, pos.initialFt - _partial);
    }

    function testPostOfferingDivestSettlesAccounting() public {
        (Context memory ctx, Position memory pos) = _setupPostOffering();
        uint256 _partial = pos.initialFt / 2;

        vm.prank(ctx.investor1);
        ctx.putManager.withdrawFT(pos.id, _partial);
        uint256 expectedCollateral = collateralFromFT(_partial, pos.strike, 6);

        uint256 remainder = pos.initialFt - _partial;
        uint256 ftBefore = ctx.putManager.ftAllocated();
        vm.prank(ctx.investor1);
        ctx.putManager.divest(pos.id, remainder);

        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", pos.id));
        ctx.ftput.ownerOf(pos.id);

        uint256 expectedWrapperBalance = pos.amount - collateralFromFT(remainder, pos.strike, 6);
        assertEq(ctx.wrapper.balanceOf(address(ctx.putManager)), expectedWrapperBalance);

        uint256 expectedUsdcBalance =
            INITIAL_USDC_BALANCE - pos.amount + collateralFromFT(remainder, pos.strike, 6);
        assertEq(ctx.usdc.balanceOf(ctx.investor1), expectedUsdcBalance);

        uint256 ftBalance = ctx.putManager.ftAllocated();
        assertEq(ftBalance, ftBefore - remainder);

        ctx.usdc.mint(address(ctx.putManager), expectedCollateral);
        vm.prank(ctx.msig);
        ctx.putManager.withdrawDivestedCapital(address(ctx.usdc), type(uint256).max);
        assertEq(ctx.putManager.capitalDivesting(address(ctx.usdc)), 0);
    }

    function testPostOfferingDivestmentHelpers() public {
        (Context memory ctx, Position memory pos) = _setupPostOffering();

        (bool canBefore, uint256 amountBefore) = ctx.putManager.canDivest(pos.id, pos.initialFt);
        assertTrue(canBefore);
        assertEq(amountBefore, pos.initialFt);

        vm.prank(ctx.investor1);
        ctx.putManager.withdrawFT(pos.id, pos.initialFt / 2);

        (bool canAfter, uint256 amountAfter) = ctx.putManager.canDivest(pos.id, pos.initialFt / 2);
        assertTrue(canAfter);
        assertEq(amountAfter, pos.initialFt / 2);

        (bool maxOk, uint256 maxAmount) = ctx.putManager.maxDivestable(pos.id, pos.initialFt / 2);
        assertTrue(maxOk);
        assertEq(maxAmount, pos.initialFt / 2);

        uint256 collateralNeeded = collateralFromFT(pos.initialFt / 2, pos.strike, 6);
        assertEq(collateralNeeded, DEFAULT_INVEST_AMOUNT / 2);
    }
}
