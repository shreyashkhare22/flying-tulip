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

contract PutManagerUnitTest is Test {
    uint256 internal constant ONE_USD = 1e8;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant HOUR = 1 hours;

    event AddCollateral(address msig, address collateral, uint256 currentPrice);
    event CollateralCapsUpdated(address token, uint256 cap);
    event FTLiquidityAdded(uint256 amount, uint256 totalAvailable);
    event Invested(
        address investor,
        address recipient,
        uint256 id,
        uint256 amount,
        uint256 strike,
        address token,
        uint256 amountInvested
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
    event Withdraw(address owner, uint256 id, uint256 amount);
    event CapitalDivested(address owner, uint256 id, uint256 amount, address token);
    event WithdrawDivestedCapital(address msig, address token, uint256 amount);

    // Events from PutManager used in tests
    event MsigUpdateScheduled(address indexed nextMsig, uint256 effectiveTime);
    event MsigUpdated(address indexed newMsig);
    event ConfiguratorUpdated(address indexed newConfigurator);
    event SaleEnabledUpdated(bool saleEnabled);
    event TransferableEnabled();
    event OracleUpdated(address indexed newOracle);

    struct Fixture {
        address msig;
        address configurator;
        address investor;
        address investor2;
        address other;
        address newMsig;
        address stranger;
        MockERC20 ft;
        MockERC20 usdc;
        MockERC20 weth;
        MockERC20 weirdToken;
        MockFlyingTulipOracle oracle;
        MockYieldWrapper usdcVault;
        MockYieldWrapper wethVault;
        MockYieldWrapper mismatchedVault;
        PutManager manager;
        pFT ftput;
    }

    function _deployFixture() internal returns (Fixture memory fix) {
        fix.msig = makeAddr("msig");
        fix.configurator = makeAddr("configurator");
        fix.investor = makeAddr("investor");
        fix.investor2 = makeAddr("investor2");
        fix.other = makeAddr("other");
        fix.newMsig = makeAddr("newMsig");
        fix.stranger = makeAddr("stranger");

        fix.ft = new MockERC20("Flying Tulip", "FT", 18);
        fix.usdc = new MockERC20("USD Coin", "USDC", 6);
        fix.weth = new MockERC20("Wrapped Ether", "WETH", 18);
        fix.weirdToken = new MockERC20("Weird Token", "WEIRD", 19);

        fix.oracle = new MockFlyingTulipOracle();
        fix.oracle.setAssetPrice(address(fix.usdc), ONE_USD);
        fix.oracle.setAssetPrice(address(fix.weth), ONE_USD * 2);

        fix.usdcVault = new MockYieldWrapper(address(fix.usdc));
        fix.wethVault = new MockYieldWrapper(address(fix.weth));
        fix.mismatchedVault = new MockYieldWrapper(address(fix.weth));

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        fix.ftput = pFT(address(pftProxy));

        PutManager impl = new PutManager(address(fix.ft), address(fix.ftput));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, fix.configurator, fix.msig, address(fix.oracle)
        );
        vm.prank(fix.msig);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        fix.manager = PutManager(address(proxy));

        vm.prank(fix.configurator);
        fix.ftput.initialize(address(fix.manager));

        return fix;
    }

    function _addCollateral(
        Fixture memory fix,
        MockERC20 token,
        MockYieldWrapper vault,
        uint256 price
    )
        internal
    {
        fix.oracle.setAssetPrice(address(token), price);
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(token), address(vault));
        vm.prank(fix.configurator);
        fix.manager.setCollateralCaps(address(token), type(uint256).max);
    }

    function _addCollateral(Fixture memory fix, MockERC20 token, MockYieldWrapper vault) internal {
        _addCollateral(fix, token, vault, ONE_USD);
    }

    function _provideFtLiquidity(Fixture memory fix, uint256 amount) internal {
        fix.ft.mint(fix.configurator, amount);
        vm.startPrank(fix.configurator);
        fix.ft.approve(address(fix.manager), type(uint256).max);
        fix.manager.addFTLiquidity(amount);
        vm.stopPrank();
    }

    function _approveForManager(
        Fixture memory fix,
        address account,
        MockERC20 token,
        uint256 amount
    )
        internal
    {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(fix.manager), type(uint256).max);
    }

    function _expectedCapital(
        uint256 amountFt,
        uint256 strike,
        uint8 decimals
    )
        internal
        pure
        returns (uint256)
    {
        uint256 scale = 10 ** uint256(decimals);
        return (amountFt * ONE_USD * scale) / (strike * 10 * 1e18);
    }

    function _expectedFtAmount(
        uint256 collateralAmount,
        uint8 decimals,
        uint256 price
    )
        internal
        pure
        returns (uint256)
    {
        require(decimals <= 18, "decimals>18");
        uint256 normalized = collateralAmount * 10 ** (18 - uint256(decimals));
        return (normalized * 10 * price) / ONE_USD;
    }

    function _preparePosition()
        internal
        returns (Fixture memory fix, uint256 deposit, uint256 ftNeeded, uint256 strike)
    {
        fix = _deployFixture();
        deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (ftNeeded, strike,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 3);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
    }

    function testDeploymentInitialisesConfiguration() public {
        Fixture memory fix = _deployFixture();

        assertEq(fix.manager.msig(), fix.msig);
        assertEq(fix.manager.configurator(), fix.configurator);
        assertEq(fix.manager.ftOfferingSupply(), 0);
        assertEq(fix.manager.ftAllocated(), 0);
        assertEq(fix.manager.getFTAddress(), address(fix.ft));
        assertEq(fix.manager.getOracleAddress(), address(fix.oracle));
        assertEq(fix.ftput.putManager(), address(fix.manager));
    }

    function testMsigCanQueueAndAcceptNewMsig() public {
        Fixture memory fix = _deployFixture();

        vm.prank(fix.msig);
        fix.manager.setMsig(fix.newMsig);
        assertEq(fix.manager.nextMsig(), fix.newMsig);
        uint256 delay = fix.manager.delayMsig();
        assertGt(delay, block.timestamp);

        vm.expectRevert(PutManager.ftPutManagerInvalidMsig.selector);
        vm.prank(fix.newMsig);
        fix.manager.acceptMsig();

        skip(HOUR + 1);

        vm.prank(fix.newMsig);
        fix.manager.acceptMsig();
        assertEq(fix.manager.msig(), fix.newMsig);
    }

    function testMsigTimelockLogic() public {
        Fixture memory fix = _deployFixture();
        vm.prank(fix.msig);
        fix.manager.setMsig(fix.newMsig);

        uint256 delayTime = fix.manager.delayMsig();
        assertGt(delayTime, block.timestamp, "Delay should be in the future");

        // Test 1: Should revert when trying to accept immediately (delayMsig > block.timestamp)
        vm.expectRevert(PutManager.ftPutManagerInvalidMsig.selector);
        vm.prank(fix.newMsig);
        fix.manager.acceptMsig();

        // Test 2: Should succeed after waiting (delayMsig <= block.timestamp)
        vm.warp(delayTime + 1);
        vm.prank(fix.newMsig);
        fix.manager.acceptMsig();

        assertEq(fix.manager.msig(), fix.newMsig, "Msig should be updated after delay");
        assertEq(fix.manager.nextMsig(), address(0), "NextMsig should be cleared");
        assertEq(fix.manager.delayMsig(), 0, "Delay should be reset");
    }

    function testSetMsigRequiresMsig() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(fix.configurator);
        fix.manager.setMsig(fix.newMsig);
    }

    function testSetMsigZeroAddressReverts() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerZeroAddress.selector);
        vm.prank(fix.msig);
        fix.manager.setMsig(address(0));
    }

    function testMsigCanUpdateConfigurator() public {
        Fixture memory fix = _deployFixture();

        vm.prank(fix.msig);
        fix.manager.setConfigurator(fix.other);
        assertEq(fix.manager.configurator(), fix.other);
    }

    function testSetConfiguratorRequiresMsig() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(fix.configurator);
        fix.manager.setConfigurator(fix.other);
    }

    function testSetConfiguratorZeroAddressReverts() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerZeroAddress.selector);
        vm.prank(fix.msig);
        fix.manager.setConfigurator(address(0));
    }

    function testMsigCanMigratePutManager() public {
        Fixture memory fix = _deployFixture();

        vm.prank(fix.msig);
        fix.manager.setPutManager(fix.other);
        assertEq(fix.ftput.putManager(), fix.other);
    }

    function testSetPutManagerGuards() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(fix.configurator);
        fix.manager.setPutManager(fix.configurator);

        vm.expectRevert(PutManager.ftPutManagerZeroAddress.selector);
        vm.prank(fix.msig);
        fix.manager.setPutManager(address(0));
    }

    function testTokenURIRequiresBaseAndMsigControl() public {
        (Fixture memory fix,,,) = _preparePosition();

        vm.expectRevert(pFT.pFTBaseURINotSet.selector);
        fix.ftput.tokenURI(0);

        vm.prank(fix.msig);
        fix.ftput.setBaseTokenURI("");
        assertEq(fix.ftput.baseTokenURI(), "");

        vm.expectRevert(pFT.pFTBaseURINotSet.selector);
        fix.ftput.tokenURI(0);

        string memory base = "https://cdn.flyingtulip.xyz/metadata/";
        vm.prank(fix.msig);
        fix.ftput.setBaseTokenURI(base);

        assertEq(fix.ftput.baseTokenURI(), base);
        assertFalse(fix.ftput.appendTokenIdInURI());
        assertEq(fix.ftput.tokenURI(0), base);

        vm.expectRevert(pFT.pFTNotMsig.selector);
        vm.prank(fix.configurator);
        fix.ftput.setBaseTokenURI(base);

        vm.prank(fix.msig);
        fix.ftput.setAppendTokenIdInURI(true);
        assertTrue(fix.ftput.appendTokenIdInURI());
        string memory expectedPerToken = string.concat(base, "0");
        assertEq(fix.ftput.tokenURI(0), expectedPerToken);
    }

    function testTokenURISettersEnforceMsigAccessControl() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(pFT.pFTNotMsig.selector);
        vm.prank(fix.configurator);
        fix.ftput.setBaseTokenURI("https://example.com/");

        vm.expectRevert(pFT.pFTNotMsig.selector);
        vm.prank(fix.configurator);
        fix.ftput.setAppendTokenIdInURI(true);

        vm.prank(fix.msig);
        fix.ftput.setBaseTokenURI("https://cdn.flyingtulip.xyz/");
        assertEq(fix.ftput.baseTokenURI(), "https://cdn.flyingtulip.xyz/");

        vm.prank(fix.msig);
        fix.ftput.setAppendTokenIdInURI(true);
        assertTrue(fix.ftput.appendTokenIdInURI());

        vm.prank(fix.msig);
        fix.ftput.setAppendTokenIdInURI(false);
        assertFalse(fix.ftput.appendTokenIdInURI());
    }

    function testEndOfferingRequiresConfigurator() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(fix.msig);
        fix.manager.enableTransferable();
    }

    function testAddFTLiquidityDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        uint256 amount = 1_000e18;

        fix.ft.mint(fix.configurator, amount);
        vm.prank(fix.configurator);
        fix.ft.approve(address(fix.manager), amount);

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit FTLiquidityAdded(amount, amount);
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(amount);

        assertEq(fix.manager.ftOfferingSupply(), amount);
    }

    function testAddFTLiquidityGuards() public {
        Fixture memory fix = _deployFixture();
        uint256 amount = 100e18;

        fix.ft.mint(fix.configurator, amount);
        vm.prank(fix.configurator);
        fix.ft.approve(address(fix.manager), amount);

        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(fix.msig);
        fix.manager.addFTLiquidity(amount);

        vm.expectRevert(PutManager.ftPutManagerInvalidAmount.selector);
        vm.prank(fix.configurator);
        fix.manager.addFTLiquidity(0);

        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
    }

    function testSendRemainderFlow() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        uint256 liquidity = ftNeeded * 3;

        _provideFtLiquidity(fix, liquidity);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        assertEq(fix.ft.balanceOf(address(fix.manager)), liquidity);
        assertEq(fix.ft.balanceOf(fix.configurator), 0);

        uint256 remainder = liquidity - ftNeeded;

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit RemainderFTSent(remainder);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();

        assertEq(fix.ft.balanceOf(fix.configurator), remainder);
        assertEq(fix.manager.ftOfferingSupply(), ftNeeded);

        uint256 secondAmount = 1_000 * 1e18;
        _provideFtLiquidity(fix, secondAmount);
        assertEq(fix.manager.ftOfferingSupply(), ftNeeded + secondAmount);

        uint256 investAmount2 = 100 * ONE_USDC;
        _approveForManager(fix, fix.investor2, fix.usdc, investAmount2);
        vm.prank(fix.investor2);
        fix.manager.invest(address(fix.usdc), investAmount2, 0, MerkleHelper.emptyProof());

        assertEq(fix.manager.ftAllocated(), fix.manager.ftOfferingSupply());

        vm.expectRevert(PutManager.ftPutManagerNoFTRemaining.selector);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
    }

    function testSendRemainderRequiresRemainder() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNoFTRemaining.selector);
        vm.prank(fix.configurator);
        fix.manager.sendRemainderFTtoConfigurator();
    }

    function testSendRemainderRequiresConfigurator() public {
        Fixture memory fix = _deployFixture();
        _provideFtLiquidity(fix, 1_000e18);

        vm.expectRevert(PutManager.ftPutManagerNotConfigurator.selector);
        vm.prank(fix.msig);
        fix.manager.sendRemainderFTtoConfigurator();
    }

    function testAddCollateralTracksMetadata() public {
        Fixture memory fix = _deployFixture();

        vm.recordLogs();
        _addCollateral(fix, fix.usdc, fix.usdcVault);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 2);

        Vm.Log memory addLog = entries[0];
        assertEq(addLog.emitter, address(fix.manager));
        assertEq(addLog.topics[0], keccak256("AddCollateral(address,address,uint256)"));
        (address msigEmitted, address collateralEmitted, uint256 currentPrice) =
            abi.decode(addLog.data, (address, address, uint256));
        assertEq(msigEmitted, fix.msig);
        assertEq(collateralEmitted, address(fix.usdc));
        assertEq(currentPrice, ONE_USD);

        Vm.Log memory capLog = entries[1];
        assertEq(capLog.emitter, address(fix.manager));
        assertEq(capLog.topics.length, 2);
        assertEq(capLog.topics[0], keccak256("CollateralCapsUpdated(address,uint256)"));
        assertEq(address(uint160(uint256(capLog.topics[1]))), address(fix.usdc));
        uint256 cap = abi.decode(capLog.data, (uint256));
        assertEq(cap, type(uint256).max);

        assertTrue(fix.manager.isCollateral(address(fix.usdc)));
        assertEq(fix.manager.vaults(address(fix.usdc)), address(fix.usdcVault));
        assertEq(fix.manager.collateralIndex(), 1);
        assertEq(fix.manager.getCollateral(0), address(fix.usdc));
    }

    function testAddCollateralRequiresMsig() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(fix.configurator);
        fix.manager.addAcceptedCollateral(address(fix.usdc), address(fix.usdcVault));
    }

    function testAddCollateralValidations() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerInvalidDecimals.selector);
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(fix.weirdToken), address(fix.usdcVault));

        fix.oracle.setAssetPrice(address(fix.usdc), 0);
        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit AddCollateral(fix.msig, address(fix.usdc), ONE_USD);
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(fix.usdc), address(fix.usdcVault));
    }

    function testAddCollateralDuplicateAndPostOffering() public {
        Fixture memory fix = _deployFixture();
        _addCollateral(fix, fix.usdc, fix.usdcVault);

        vm.expectRevert(PutManager.ftPutManagerInvalidInvestmentAsset.selector);
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(fix.usdc), address(fix.usdcVault));

        vm.expectRevert(PutManager.ftPutManagerInvalidInvestmentAsset.selector);
        vm.prank(fix.msig);
        fix.manager.addAcceptedCollateral(address(fix.usdc), address(fix.mismatchedVault));

        vm.prank(fix.configurator);
        fix.manager.enableTransferable();

        _addCollateral(fix, fix.weth, fix.wethVault);
        assertTrue(fix.manager.isCollateral(address(fix.weth)));
    }

    function testSetCollateralCapUpdatesValue() public {
        Fixture memory fix = _deployFixture();
        _addCollateral(fix, fix.usdc, fix.usdcVault);

        vm.prank(fix.configurator);
        fix.manager.setCollateralCaps(address(fix.usdc), 1_000e6);
        assertEq(fix.manager.collateralCap(address(fix.usdc)), 1_000e6);
    }

    function testInvestDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded, uint256 strike,) =
            fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 5);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit Invested(fix.investor, fix.investor, 0, ftNeeded, strike, address(fix.usdc), deposit);
        vm.prank(fix.investor);
        uint256 positionId =
            fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        assertEq(positionId, 0);
        assertEq(fix.manager.ftAllocated(), ftNeeded);
        assertEq(fix.usdcVault.totalDeposited(), deposit);
        assertEq(fix.usdc.balanceOf(address(fix.manager)), 0);
        assertEq(fix.usdc.balanceOf(fix.investor), 0);
        assertEq(fix.ftput.ownerOf(0), fix.investor);
    }

    function testInvestRejectsInvalidInput() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);

        vm.expectRevert(PutManager.ftPutManagerInvalidAmount.selector);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), 0, 0, MerkleHelper.emptyProof());

        vm.expectRevert(PutManager.ftPutManagerInvalidInvestmentAsset.selector);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.weth), deposit, 0, MerkleHelper.emptyProof());
    }

    function testInvestRevertsWhenInsufficientLiquidityOrStateInvalid() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded - 1);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);

        vm.expectRevert(PutManager.ftPutManagerInsufficientFTLiquidity.selector);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        _provideFtLiquidity(fix, ftNeeded * 2);
        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
    }

    function testInvestUsesFallbackPrice() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded, uint256 strike,) =
            fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);

        fix.oracle.setAssetPrice(address(fix.usdc), 0);

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit Invested(fix.investor, fix.investor, 0, ftNeeded, strike, address(fix.usdc), deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());
    }

    function testInvestRequiresBalanceAndAllowance() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);

        vm.expectRevert();
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.usdc.approve(address(fix.manager), 0);

        vm.expectRevert();
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());
    }

    function testExitDuringPublicOffering() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        vm.prank(fix.investor);
        fix.manager.divest(0, ftNeeded);

        assertEq(fix.manager.ftAllocated(), 0);
        assertEq(fix.usdcVault.totalDeposited(), 0);
        assertEq(fix.usdc.balanceOf(fix.investor), deposit);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 0));
        fix.ftput.ownerOf(0);
    }

    function testExitRevertsForWrongCallerOrState() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        vm.expectRevert(pFT.pFTOnlyPutOwner.selector);
        vm.prank(fix.other);
        fix.manager.divest(0, ftNeeded);

        vm.prank(fix.configurator);
        fix.manager.enableTransferable();
        vm.prank(fix.investor);
        fix.manager.divest(0, ftNeeded);
    }

    function testWithdrawFTRecordsCapital() public {
        (Fixture memory fix,, uint256 ftNeeded, uint256 strike) = _preparePosition();
        uint256 withdrawAmount = ftNeeded / 2;
        uint256 managerBalanceBefore = fix.ft.balanceOf(address(fix.manager));
        uint8 decimals = fix.usdc.decimals();
        uint256 expected = _expectedCapital(withdrawAmount, strike, decimals);

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit Withdraw(fix.investor, 0, withdrawAmount);

        vm.recordLogs();
        vm.prank(fix.investor);
        fix.manager.withdrawFT(0, withdrawAmount);

        assertEq(fix.ft.balanceOf(address(fix.manager)), managerBalanceBefore - withdrawAmount);
        assertEq(fix.ft.balanceOf(fix.investor), withdrawAmount);

        assertEq(fix.manager.capitalDivesting(address(fix.usdc)), expected);

        (
            address tokenAddr,
            uint256 amount,
            uint256 ft,
            uint256 ftBought,
            uint256 withdrawn,
            uint256 burned,
            uint256 strike2,
            uint256 amountRemaining,
            uint256 ftPerUSD
        ) = fix.ftput.puts(0);
        assertEq(tokenAddr, address(fix.usdc));
        assertEq(uint256(ft), ftNeeded - withdrawAmount);
        assertEq(uint256(ftBought), ftNeeded);
        assertEq(uint256(withdrawn), withdrawAmount);

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
            assertEq(owner, fix.investor);
            assertEq(loggedId, 0);
            assertEq(ftReturned, withdrawAmount);
            assertEq(token, address(fix.usdc));
            assertEq(collateral, expected);
            found = true;
            break;
        }
        assertTrue(found, "ExitPosition not emitted for withdrawFT");
    }

    function testWithdrawFTGuards() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        vm.expectRevert(PutManager.ftPutManagerInvalidState.selector);
        vm.prank(fix.investor);
        fix.manager.withdrawFT(0, ftNeeded / 2);

        vm.prank(fix.configurator);
        fix.manager.enableTransferable();

        vm.expectRevert(pFT.pFTOnlyPutOwner.selector);
        vm.prank(fix.other);
        fix.manager.withdrawFT(0, ftNeeded / 2);
    }

    function testWithdrawFTCannotExceedPosition() public {
        (Fixture memory fix,, uint256 ftNeeded,) = _preparePosition();

        vm.expectRevert();
        vm.prank(fix.investor);
        fix.manager.withdrawFT(0, ftNeeded + 1);
    }

    function testDivestEligibilityHelpers() public {
        (Fixture memory fix, uint256 deposit, uint256 ftNeeded, uint256 strike) = _preparePosition();
        uint256 portion = ftNeeded / 4;

        (bool canDivestPortion, uint256 amountPortion) = fix.manager.canDivest(0, portion);
        assertTrue(canDivestPortion);
        assertEq(amountPortion, portion);

        (bool canDivestTooLarge, uint256 amountTooLarge) = fix.manager.canDivest(0, ftNeeded + 1);
        assertFalse(canDivestTooLarge);
        assertEq(amountTooLarge, 0);

        (bool maxOk, uint256 maxAmount) = fix.manager.maxDivestable(0, portion);
        assertTrue(maxOk);
        assertEq(maxAmount, portion);

        (bool maxFull, uint256 maxFullAmount) = fix.manager.maxDivestable(0, ftNeeded * 2);
        assertTrue(maxFull);
        assertEq(maxFullAmount, ftNeeded);

        uint256 collateralAmount = fix.usdcVault.totalDeposited();
        vm.prank(fix.msig);
        fix.usdcVault.withdraw(collateralAmount, fix.msig);

        (bool canAfter,) = fix.manager.canDivest(0, portion);
        assertFalse(canAfter);

        uint8 decimals = fix.usdc.decimals();
        uint256 collateralNeeded = _expectedCapital(portion, strike, decimals);
        assertEq(collateralNeeded, deposit / 4);
    }

    function testCanDivestDuringOfferingFalse() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        (bool canDivestBefore,) = fix.manager.canDivest(0, ftNeeded / 2);
        assertTrue(canDivestBefore);
    }

    function testMaxDivestableWithLimitedLiquidity() public {
        (Fixture memory fix,, uint256 ftNeeded,) = _preparePosition();

        // Simulate limited liquidity: drain 70% of vault funds
        uint256 vaultBalance = fix.usdc.balanceOf(address(fix.usdcVault));
        uint256 toDrain = (vaultBalance * 70) / 100;
        vm.prank(address(fix.usdcVault));
        fix.usdc.transfer(address(0xdead), toDrain);

        // Expected: Should return 30% of ftNeeded since only 30% liquidity available
        uint256 expectedMax = (ftNeeded * 30) / 100;
        (, uint256 maxAmount) = fix.manager.maxDivestable(0, ftNeeded);

        assertEq(maxAmount, expectedMax);
    }

    function testDivestTransfersCollateralAndBurns() public {
        (Fixture memory fix,/* uint256 deposit */, uint256 ftNeeded, uint256 strike) =
            _preparePosition();
        uint256 burnAmount = ftNeeded / 3;
        uint256 managerBalanceBefore = fix.manager.ftAllocated();
        uint256 collateralBalanceBefore = fix.usdc.balanceOf(fix.investor);
        uint8 decimals = fix.usdc.decimals();
        uint256 expectedCollateral = _expectedCapital(burnAmount, strike, decimals);

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit Divested(fix.investor, 0, burnAmount, strike, address(fix.usdc), expectedCollateral);

        vm.recordLogs();
        vm.prank(fix.investor);
        fix.manager.divest(0, burnAmount);

        assertEq(fix.usdc.balanceOf(fix.investor), collateralBalanceBefore + expectedCollateral);
        assertEq(fix.manager.ftAllocated(), managerBalanceBefore - burnAmount);
        assertEq(fix.manager.capitalDivesting(address(fix.usdc)), 0);

        (
            address _t,
            uint256 _a,
            uint256 ftRemaining,
            uint256 _fb,
            uint256 _w,
            uint256 burned,
            uint256 _s,
            uint256 _ar,
            uint256 _fpu
        ) = fix.ftput.puts(0);
        assertEq(uint256(ftRemaining), ftNeeded - burnAmount);
        assertEq(uint256(burned), burnAmount);

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
            assertEq(owner, fix.investor);
            assertEq(loggedId, 0);
            assertEq(ftReturned, burnAmount);
            assertEq(token, address(fix.usdc));
            assertEq(collateral, expectedCollateral);
            found = true;
            break;
        }
        assertTrue(found, "ExitPosition not emitted for divest");
    }

    function testDivestGuards() public {
        Fixture memory fix = _deployFixture();
        uint256 deposit = ONE_USDC;
        _addCollateral(fix, fix.usdc, fix.usdcVault);
        (uint256 ftNeeded,,) = fix.manager.getAssetFTPrice(address(fix.usdc), deposit);
        _provideFtLiquidity(fix, ftNeeded * 2);
        _approveForManager(fix, fix.investor, fix.usdc, deposit);
        vm.prank(fix.investor);
        fix.manager.invest(address(fix.usdc), deposit, 0, MerkleHelper.emptyProof());

        vm.prank(fix.investor);
        fix.manager.divest(0, ftNeeded / 2);

        vm.prank(fix.configurator);
        fix.manager.enableTransferable();

        vm.expectRevert(pFT.pFTOnlyPutOwner.selector);
        vm.prank(fix.other);
        fix.manager.divest(0, ftNeeded / 2);

        vm.expectRevert();
        vm.prank(fix.investor);
        fix.manager.divest(0, ftNeeded + 1);

        vm.prank(fix.msig);
        fix.usdcVault.withdraw(fix.usdcVault.totalDeposited(), fix.msig);

        vm.expectRevert("Insufficient balance");
        vm.prank(fix.investor);
        fix.manager.divest(0, ftNeeded / 2);
    }

    function testWithdrawDivestedCapital() public {
        (Fixture memory fix,, uint256 ftNeeded, uint256 strike) = _preparePosition();
        uint256 withdrawAmount = ftNeeded / 2;
        uint8 decimals = fix.usdc.decimals();

        vm.prank(fix.investor);
        fix.manager.withdrawFT(0, withdrawAmount);
        uint256 expected = _expectedCapital(withdrawAmount, strike, decimals);
        fix.usdc.mint(address(fix.manager), expected);

        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit WithdrawDivestedCapital(fix.msig, address(fix.usdc), expected);
        vm.prank(fix.msig);
        fix.manager.withdrawDivestedCapital(address(fix.usdc), type(uint256).max);

        assertEq(fix.usdc.balanceOf(fix.msig), expected);
        assertEq(fix.manager.capitalDivesting(address(fix.usdc)), 0);
    }

    function testWithdrawDivestedCapitalGuards() public {
        Fixture memory fix = _deployFixture();

        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        vm.prank(fix.configurator);
        fix.manager.withdrawDivestedCapital(address(fix.usdc), type(uint256).max);
    }

    function testViewHelpersReturnData() public {
        Fixture memory fix = _deployFixture();
        fix.oracle.setAssetPrice(address(fix.weth), 123);

        assertEq(fix.manager.getAssetPrice(address(fix.weth)), 123);
        assertEq(fix.manager.getFTAddress(), address(fix.ft));
        assertEq(fix.manager.getOracleAddress(), address(fix.oracle));

        _addCollateral(fix, fix.usdc, fix.usdcVault);
        _addCollateral(fix, fix.weth, fix.wethVault);
        assertEq(fix.manager.collateralIndex(), 2);

        uint256 amount = 2e18;
        uint256 customPrice = 5e7;
        fix.oracle.setAssetPrice(address(fix.weth), customPrice);
        (uint256 ftAmount, uint256 strike,) = fix.manager.getAssetFTPrice(address(fix.weth), amount);
        uint256 expected = _expectedFtAmount(amount, fix.weth.decimals(), strike);
        assertEq(ftAmount, expected);
    }

    function testInitializerEmitsEvents() public {
        // Deploy impl and proxy with expectEmit for initializer events
        address msig = makeAddr("msig_init");
        address configurator = makeAddr("config_init");

        MockERC20 ft = new MockERC20("FT", "FT", 18);
        MockFlyingTulipOracle oracle = new MockFlyingTulipOracle();
        pFT pftImplX = new pFT();
        ERC1967Proxy pftProxyX = new ERC1967Proxy(address(pftImplX), bytes(""));
        pFT pft = pFT(address(pftProxyX));

        PutManager impl = new PutManager(address(ft), address(pft));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(oracle)
        );

        // Expect MsigUpdated, ConfiguratorUpdated, OracleUpdated, and SaleEnabledUpdated emitted during initialize
        vm.expectEmit(true, false, false, true);
        emit MsigUpdated(msig);
        vm.expectEmit(true, false, false, true);
        emit ConfiguratorUpdated(configurator);
        vm.expectEmit(true, false, false, true);
        emit OracleUpdated(address(oracle));
        vm.expectEmit(false, false, false, true);
        emit SaleEnabledUpdated(true);

        vm.prank(msig);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);

        PutManager manager = PutManager(address(proxy));

        // initialize pFT from non-admin
        vm.prank(configurator);
        pft.initialize(address(manager));
    }

    function testSetMsigAndAcceptEmitEvents() public {
        Fixture memory fix = _deployFixture();

        // expect MsigUpdateScheduled when calling setMsig
        // only check indexed topics (oldMsig, nextMsig) — do not assert effectiveTime
        vm.expectEmit(true, false, false, false, address(fix.manager));
        emit MsigUpdateScheduled(fix.newMsig, 0);
        vm.prank(fix.msig);
        fix.manager.setMsig(fix.newMsig);

        // fast forward beyond delay
        skip(HOUR + 1);

        // expect MsigUpdated on accept
        vm.expectEmit(true, false, false, false, address(fix.manager));
        emit MsigUpdated(fix.newMsig);
        vm.prank(fix.newMsig);
        fix.manager.acceptMsig();
    }

    function testSetConfiguratorAndEnableTransferableEmitEvents() public {
        Fixture memory fix = _deployFixture();

        // expect ConfiguratorUpdated when set by msig
        vm.expectEmit(true, false, false, true, address(fix.manager));
        emit ConfiguratorUpdated(fix.other);
        vm.prank(fix.msig);
        fix.manager.setConfigurator(fix.other);

        // expect TransferableEnabled when called by configurator
        vm.expectEmit(false, false, false, true, address(fix.manager));
        emit TransferableEnabled();
        vm.prank(fix.other);
        fix.manager.enableTransferable();
    }
}
