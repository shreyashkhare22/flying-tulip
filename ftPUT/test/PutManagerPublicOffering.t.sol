// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {MockYieldWrapper} from "./mocks/MockYieldWrapper.sol";
import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";

contract PutManagerPublicOfferingTest is Test {
    uint256 internal constant INITIAL_FT_SUPPLY = 1_000_000 * 1e18;
    uint256 internal constant INITIAL_USDC_BALANCE = 10_000 * 1e6;
    uint256 internal constant DEFAULT_FT_LIQUIDITY = 100_000 * 1e18;
    uint256 internal constant DEFAULT_INVEST_AMOUNT = 1_000 * 1e6;

    event AddCollateral(address msig, address collateral, uint256 currentPrice);
    event FTLiquidityAdded(uint256 amount, uint256 totalAvailable);
    event Invested(
        address investor,
        address recipient,
        uint256 id,
        uint256 amount,
        uint256 strike,
        address token
    );
    event ExitPosition(
        address owner, uint256 id, uint256 ftReturned, address token, uint256 collateralAmount
    );
    event Divested(
        address divestor,
        uint256 id,
        uint256 amount,
        uint256 strike,
        address token,
        uint256 amountDivested
    );
    event RemainderFTSent(uint256 amount);

    struct Fixture {
        address msig;
        address configurator;
        address user1;
        address user2;
        MockERC20 ft;
        MockERC20 usdc;
        MockFlyingTulipOracle oracle;
        MockYieldWrapper wrapper;
        pFT pft;
        PutManager manager;
    }

    struct Position {
        uint256 id;
        uint256 ftAmount;
        uint256 strike;
        uint256 collateral;
    }

    function _deployFixture() internal returns (Fixture memory fix) {
        fix.msig = makeAddr("msig");
        fix.configurator = makeAddr("configurator");
        fix.user1 = makeAddr("user1");
        fix.user2 = makeAddr("user2");

        fix.ft = new MockERC20("Flying Tulip", "FT", 18);
        fix.usdc = new MockERC20("USD Coin", "USDC", 6);

        fix.oracle = new MockFlyingTulipOracle();
        fix.wrapper = new MockYieldWrapper(address(fix.usdc));

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        fix.pft = pFT(address(pftProxy));

        // Deploy PutManager implementation and proxy (UUPS)
        PutManager impl = new PutManager(address(fix.ft), address(fix.pft));
        bytes memory data = abi.encodeWithSelector(
            PutManager.initialize.selector, fix.configurator, fix.msig, address(fix.oracle)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        fix.manager = PutManager(address(proxy));

        vm.prank(fix.configurator);
        fix.pft.initialize(address(fix.manager));

        fix.oracle.setAssetPrice(address(fix.usdc), 1e8);

        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(fix.usdc), address(fix.wrapper));

        vm.prank(fix.configurator);
        fix.manager.setCollateralCaps(address(fix.usdc), type(uint256).max);

        fix.ft.mint(fix.configurator, INITIAL_FT_SUPPLY);
        vm.prank(fix.configurator);
        fix.ft.approve(address(fix.manager), type(uint256).max);

        fix.usdc.mint(fix.user1, INITIAL_USDC_BALANCE);
        fix.usdc.mint(fix.user2, INITIAL_USDC_BALANCE);

        vm.prank(fix.user1);
        fix.usdc.approve(address(fix.manager), type(uint256).max);
        vm.prank(fix.user2);
        fix.usdc.approve(address(fix.manager), type(uint256).max);

        return fix;
    }

    function _addFTLiquidity(Fixture memory fix, uint256 amount) internal {
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(amount);
    }

    function _addFTLiquidity(Fixture memory fix) internal returns (uint256) {
        _addFTLiquidity(fix, DEFAULT_FT_LIQUIDITY);
        return DEFAULT_FT_LIQUIDITY;
    }

    function _openPosition(
        Fixture memory fix,
        address investor,
        uint256 amount
    )
        internal
        returns (Position memory pos)
    {
        vm.prank(investor);
        uint256 id = fix.manager.invest(address(fix.usdc), amount, 0, MerkleHelper.emptyProof());
        (uint256 ftAmount, uint256 strike, address _token, uint64 _ftPerUSD) =
            fix.pft.divestable(id);
        pos = Position({id: id, ftAmount: ftAmount, strike: strike, collateral: amount});
    }

    function _preparePostOffering(Fixture memory fix) internal returns (Position memory pos) {
        _addFTLiquidity(fix);
        pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
    }

    function testStateStartsInPublicOffering() public {
        Fixture memory fix = _deployFixture();
        assertEq(fix.manager.transferable(), false);
    }

    function testConfiguratorCanEndPublicOffering() public {
        Fixture memory fix = _deployFixture();
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        assertEq(fix.manager.transferable(), true);
    }

    function testEndPublicOfferingRequiresConfigurator() public {
        Fixture memory fix = _deployFixture();
        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(fix.user1);
        fix.manager.enableTransferable();
    }

    function testEndPublicOfferingCannotBeCalledTwice() public {
        Fixture memory fix = _deployFixture();
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        vm.prank(fix.configurator);
        vm.expectRevert(PutManager.ftPutManagerAlreadyTransferable.selector);
        fix.manager.enableTransferable();
    }

    function testAddCollateralDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        MockERC20 newToken = new MockERC20("New Token", "NEW", 6);
        MockYieldWrapper newWrapper = new MockYieldWrapper(address(newToken));
        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit AddCollateral(fix.msig, address(newToken), 1e8);
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(newToken), address(newWrapper));
        assertTrue(fix.manager.isCollateral(address(newToken)));
    }

    function testAddCollateralAfterOfferingStillAllowed() public {
        Fixture memory fix = _deployFixture();
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        MockERC20 newToken = new MockERC20("New Token", "NEW", 6);
        MockYieldWrapper newWrapper = new MockYieldWrapper(address(newToken));
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(newToken), address(newWrapper));
        assertTrue(fix.manager.isCollateral(address(newToken)));
    }

    function testAddFTLiquidityDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        uint256 amount = 100_000 * 1e18;
        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit FTLiquidityAdded(amount, amount);
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(amount);
        assertEq(fix.manager.ftOfferingSupply(), amount);
    }

    function testAddFTLiquidityRequiresConfigurator() public {
        Fixture memory fix = _deployFixture();
        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(fix.user1);
        fix.manager.addFTLiquidity(1);
    }

    function testAddFTLiquidityAfterOfferingReverts() public {
        Fixture memory fix = _deployFixture();
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(1);
    }

    function testInvestDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        (uint256 expectedFt,,) =
            fix.manager.getAssetFTPrice(address(fix.usdc), DEFAULT_INVEST_AMOUNT);
        vm.prank(fix.user1);
        uint256 positionId = fix.manager
            .invest(address(fix.usdc), DEFAULT_INVEST_AMOUNT, 0, MerkleHelper.emptyProof());
        assertEq(positionId, 0);
        assertEq(fix.manager.ftAllocated(), expectedFt);
    }

    function testInvestRevertsWhenInsufficientFTLiquidity() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix, 1_000 * 1e18);
        vm.expectRevert(PutManager.ftPutManagerInsufficientFTLiquidity.selector);
        vm.prank(fix.user1);
        fix.manager.invest(address(fix.usdc), 500_000 * 1e6, 0, MerkleHelper.emptyProof());
    }

    function testInvestRevertsAfterOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        vm.prank(fix.user1);
        fix.manager.invest(address(fix.usdc), DEFAULT_INVEST_AMOUNT, 0, MerkleHelper.emptyProof());
    }

    function testExitDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        uint256 allocatedBefore = fix.manager.ftAllocated();
        uint256 balanceBefore = fix.usdc.balanceOf(fix.user1);
        vm.prank(fix.user1);
        fix.manager.divest(pos.id, pos.ftAmount);
        assertEq(fix.manager.ftAllocated(), allocatedBefore - pos.ftAmount);
        assertEq(fix.usdc.balanceOf(fix.user1), balanceBefore + pos.collateral);
        assertEq(fix.pft.balanceOf(fix.user1), 0);
    }

    function testExitAfterOfferingReverts() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        vm.prank(fix.user1);
        fix.manager.divest(pos.id, pos.ftAmount);
    }

    function testExitRequiresPositionOwner() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        vm.expectRevert(pFT.pFTOnlyPutOwner.selector);
        vm.prank(fix.user2);
        fix.manager.divest(pos.id, pos.ftAmount);
    }

    function testWithdrawDivestedCapitalRevertsDuringOffering() public {
        Fixture memory fix = _deployFixture();
        vm.prank(fix.msig);
        fix.manager.withdrawDivestedCapital(address(fix.usdc), type(uint256).max);
    }

    function testWithdrawDivestedCapitalSucceedsAfterOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();

        vm.prank(fix.user1);
        fix.manager.withdrawFT(pos.id, pos.ftAmount / 2);
        uint256 capital = fix.manager.capitalDivesting(address(fix.usdc));
        assertGt(capital, 0);

        uint256 msigBalanceBefore = fix.usdc.balanceOf(fix.msig);
        vm.prank(fix.msig);
        fix.manager.withdrawDivestedCapital(address(fix.usdc), type(uint256).max);

        assertEq(fix.manager.capitalDivesting(address(fix.usdc)), 0);
        assertEq(fix.usdc.balanceOf(fix.msig), msigBalanceBefore + capital);
    }

    function testCanDivestReturnsFalseDuringOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        (bool allowed,) = fix.manager.canDivest(pos.id, pos.ftAmount);
        assertTrue(allowed);
    }

    function testMaxDivestableReturnsZeroDuringOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        (bool allowed,) = fix.manager.maxDivestable(pos.id, pos.ftAmount);
        assertTrue(allowed);
    }

    function testDivestRevertsDuringOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        vm.prank(fix.user1);
        fix.manager.divest(pos.id, pos.ftAmount);
    }

    function testWithdrawFTRevertsDuringOffering() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        Position memory pos = _openPosition(fix, fix.user1, DEFAULT_INVEST_AMOUNT);
        vm.prank(fix.user1);
        vm.expectRevert(PutManager.ftPutManagerInvalidState.selector);
        fix.manager.withdrawFT(pos.id, 1);
    }

    function testDivestSucceedsAfterOffering() public {
        Fixture memory fix = _deployFixture();
        Position memory pos = _preparePostOffering(fix);
        uint256 managerBalanceBefore = fix.manager.ftAllocated();
        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit Divested(
            fix.user1, pos.id, pos.ftAmount, pos.strike, address(fix.usdc), pos.collateral
        );
        vm.recordLogs();
        vm.prank(fix.user1);
        fix.manager.divest(pos.id, pos.ftAmount);
        assertEq(fix.pft.balanceOf(fix.user1), 0);
        assertEq(fix.usdc.balanceOf(fix.user1), INITIAL_USDC_BALANCE);
        assertEq(fix.manager.ftAllocated(), managerBalanceBefore - pos.ftAmount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 exitSig = keccak256("ExitPosition(address,uint256,uint256,address,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(fix.manager)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != exitSig) continue;
            (
                address owner,
                uint256 loggedId,
                uint256 ftReturned,
                address token,
                uint256 collateral
            ) = abi.decode(logs[i].data, (address, uint256, uint256, address, uint256));
            assertEq(owner, fix.user1);
            assertEq(loggedId, pos.id);
            assertEq(ftReturned, pos.ftAmount);
            assertEq(token, address(fix.usdc));
            assertEq(collateral, pos.collateral);
            found = true;
            break;
        }
        assertTrue(found, "ExitPosition not emitted for divest (public offering)");
    }

    function testCanDivestReturnsTrueAfterOffering() public {
        Fixture memory fix = _deployFixture();
        Position memory pos = _preparePostOffering(fix);
        (bool allowed, uint256 amount) = fix.manager.canDivest(pos.id, pos.ftAmount);
        assertTrue(allowed);
        assertEq(amount, pos.ftAmount);
    }

    function testMaxDivestableReturnsPositiveAfterOffering() public {
        Fixture memory fix = _deployFixture();
        Position memory pos = _preparePostOffering(fix);
        (bool allowed, uint256 amount) = fix.manager.maxDivestable(pos.id, pos.ftAmount);
        assertTrue(allowed);
        assertEq(amount, pos.ftAmount);
    }

    function testFullIntegrationRemainderFlow() public {
        Fixture memory fix = _deployFixture();
        uint256 firstAmount = 100 * 1e18;
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(firstAmount);
        assertEq(fix.manager.ftOfferingSupply(), firstAmount);
        assertEq(fix.manager.ftAllocated(), 0);

        uint256 investAmount1 = 5 * 1e6;
        vm.prank(fix.user1);
        fix.manager.invest(address(fix.usdc), investAmount1, 0, MerkleHelper.emptyProof());
        (uint256 allocatedAfter,,) = fix.manager.getAssetFTPrice(address(fix.usdc), investAmount1);
        assertEq(fix.manager.ftAllocated(), allocatedAfter);

        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
        assertEq(fix.manager.ftOfferingSupply(), fix.manager.ftAllocated());

        uint256 secondAmount = 1_000 * 1e18;
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(secondAmount);
        assertEq(fix.manager.ftOfferingSupply(), fix.manager.ftAllocated() + secondAmount);

        uint256 investAmount2 = 100 * 1e6;
        vm.prank(fix.user2);
        fix.manager.invest(address(fix.usdc), investAmount2, 0, MerkleHelper.emptyProof());
        (uint256 ftForSecond,,) = fix.manager.getAssetFTPrice(address(fix.usdc), investAmount2);
        assertEq(fix.manager.ftAllocated(), allocatedAfter + ftForSecond);
        assertEq(fix.manager.ftOfferingSupply(), allocatedAfter + ftForSecond);

        vm.expectRevert(PutManager.ftPutManagerNoFTRemaining.selector);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
    }

    function testSendRemainderFt() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix, 100_000 * 1e18);
        vm.prank(fix.user1);
        fix.manager.invest(address(fix.usdc), 100 * 1e6, 0, MerkleHelper.emptyProof());
        uint256 offeringBefore = fix.manager.ftOfferingSupply();
        uint256 allocated = fix.manager.ftAllocated();
        uint256 remainder = offeringBefore - allocated;
        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit RemainderFTSent(remainder);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
        assertEq(fix.manager.ftOfferingSupply(), allocated);
    }

    function testSendRemainderRequiresRemainder() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
        vm.expectRevert(PutManager.ftPutManagerNoFTRemaining.selector);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
    }

    function testSendRemainderRequiresConfigurator() public {
        Fixture memory fix = _deployFixture();
        _addFTLiquidity(fix);
        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(fix.user1);
        fix.manager.sendRemainderFTtoConfigurator();
    }
}
