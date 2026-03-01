// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {MockYieldWrapper} from "./mocks/MockYieldWrapper.sol";
import {MerkleHelper} from "./helpers/MerkleHelper.sol";
import {ftACL} from "contracts/ftACL.sol";
import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";

contract FtACLTest is Test {
    uint256 internal constant ONE_USD = 1e8;
    uint256 internal constant ONE_USDC = 1e6;

    function _deploy()
        internal
        returns (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        )
    {
        msig = makeAddr("msig");
        configurator = makeAddr("config");
        investor = makeAddr("investor");

        ft = new MockERC20("FT", "FT", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        MockFlyingTulipOracle oracle = new MockFlyingTulipOracle();
        oracle.setAssetPrice(address(usdc), ONE_USD);

        wrapper = new MockYieldWrapper(address(usdc));

        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        pFT pft = pFT(address(pftProxy));

        PutManager impl = new PutManager(address(ft), address(pft));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(oracle)
        );
        vm.prank(msig);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        manager = PutManager(address(proxy));

        // Initialize pFT from non-admin (not MSIG)
        vm.prank(configurator);
        pft.initialize(address(manager));

        return (manager, ft, usdc, wrapper, msig, configurator, investor);
    }

    function testInvestNotBlockedWhenPresaleAndNoACL() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(investor);
        manager.invest(address(usdc), ONE_USDC, 0, MerkleHelper.emptyProof());
    }

    function testWhitelistedCanInvestDuringPresale() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(0), 0);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        uint256 id = manager.invest(address(usdc), ONE_USDC, 0, proof);
        assertEq(id, 0);
    }

    function testNonWhitelistedCannotInvestDuringPresale() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        address whitelistedUser = makeAddr("whitelisted");

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(whitelistedUser, address(0), 0);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(investor);
        vm.expectRevert(PutManager.ftPutManagerNotWhitelisted.selector);
        manager.invest(address(usdc), ONE_USDC, 0, MerkleHelper.emptyProof());
    }

    function testWhitelistedCanInvestWithMultipleAddressesInTree() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        address investor2 = makeAddr("investor2");

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
        entries[0] = MerkleHelper.ACLEntry(investor, address(0), 0);
        entries[1] = MerkleHelper.ACLEntry(investor2, address(0), 0);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        uint256 id = manager.invest(address(usdc), ONE_USDC, 0, proof);
        assertEq(id, 0);
    }

    function testUpdateMerkleRoot() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MerkleHelper.ACLEntry[] memory initialEntries = new MerkleHelper.ACLEntry[](1);
        initialEntries[0] = MerkleHelper.ACLEntry(investor, address(0), 0);
        bytes32 initialRoot = MerkleHelper.generateRoot(initialEntries);

        ftACL acl = new ftACL(initialRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        address newInvestor = makeAddr("newInvestor");
        MerkleHelper.ACLEntry[] memory newEntries = new MerkleHelper.ACLEntry[](1);
        newEntries[0] = MerkleHelper.ACLEntry(newInvestor, address(0), 0);
        bytes32 newRoot = MerkleHelper.generateRoot(newEntries);

        acl.updateMerkleRoot(newRoot);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(investor);
        vm.expectRevert(PutManager.ftPutManagerNotWhitelisted.selector);
        manager.invest(address(usdc), ONE_USDC, 0, MerkleHelper.emptyProof());

        usdc.mint(newInvestor, ONE_USDC);
        vm.prank(newInvestor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(newEntries, 0);
        vm.prank(newInvestor);
        uint256 id = manager.invest(address(usdc), ONE_USDC, 0, proof);
        assertEq(id, 0);
    }

    function testUpdateMerkleRootRevertsOnZeroRoot() public {
        (PutManager manager,,,,,, address investor) = _deploy();

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(0), 0);
        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);

        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.expectRevert(ftACL.ftACLZeroRoot.selector);
        acl.updateMerkleRoot(bytes32(0));
    }

    function testManyAddressesInTree() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](10);
        entries[0] = MerkleHelper.ACLEntry(investor, address(0), 0);
        for (uint256 i = 1; i < 10; ++i) {
            address addr = makeAddr(string(abi.encodePacked("investor", vm.toString(i))));
            entries[i] = MerkleHelper.ACLEntry(addr, address(0), 0);
        }

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        uint256 id = manager.invest(address(usdc), ONE_USDC, 0, proof);
        assertEq(id, 0);
    }

    function testSpecificAssetRestriction() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), 0);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        uint256 id = manager.invest(address(usdc), ONE_USDC, 0, proof);
        assertEq(id, 0);
    }

    function testSpecificAmountRestriction() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), ONE_USDC);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        uint256 id = manager.invest(address(usdc), ONE_USDC, ONE_USDC, proof);
        assertEq(id, 0);
    }

    // ========== NEW TESTS FOR INVESTMENT CAP TRACKING ==========

    function testInvestmentCapEnforcement() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        uint256 cap = 5 * ONE_USDC;
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), cap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 10 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        // First investment should succeed (3 USDC)
        vm.prank(investor);
        manager.invest(address(usdc), 3 * ONE_USDC, cap, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 3 * ONE_USDC);

        // Second investment should succeed (2 USDC, total 5)
        vm.prank(investor);
        manager.invest(address(usdc), 2 * ONE_USDC, cap, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 5 * ONE_USDC);

        // Third investment should fail (would exceed cap)
        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, cap, proof);
    }

    function testInvestmentCapExactMatch() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        uint256 cap = 10 * ONE_USDC;
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), cap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 10 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        uint256 id = manager.invest(address(usdc), 10 * ONE_USDC, cap, proof);
        assertEq(id, 0);

        assertEq(acl.amountInvested(investor, address(usdc)), 10 * ONE_USDC);
    }

    function testInvestmentAmountDifferentFromProofAmount() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        uint256 proofAmount = 10 * ONE_USDC;
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), proofAmount);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 10 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        // Invest 3 USDC with proofAmount of 10 USDC - should succeed
        vm.prank(investor);
        manager.invest(address(usdc), 3 * ONE_USDC, proofAmount, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 3 * ONE_USDC);

        // Can invest 7 more to reach cap
        vm.prank(investor);
        manager.invest(address(usdc), 7 * ONE_USDC, proofAmount, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 10 * ONE_USDC);
    }

    function testInvestmentCapPerToken() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockFlyingTulipOracle oracle = MockFlyingTulipOracle(manager.getOracleAddress());
        oracle.setAssetPrice(address(dai), ONE_USD);
        MockYieldWrapper daiWrapper = new MockYieldWrapper(address(dai));

        uint256 usdcCap = 5 * ONE_USDC;
        uint256 daiCap = 10e18;

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), usdcCap);
        entries[1] = MerkleHelper.ACLEntry(investor, address(dai), daiCap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(msig);
        manager.addAcceptedCollateral(address(dai), address(daiWrapper));

        vm.startPrank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);
        manager.setCollateralCaps(address(dai), type(uint256).max);
        vm.stopPrank();

        ft.mint(configurator, 1_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(1_000e18);
        vm.stopPrank();

        usdc.mint(investor, 10 * ONE_USDC);
        dai.mint(investor, 20e18);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        dai.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        bytes32[] memory usdcProof = MerkleHelper.generateProof(entries, 0);
        bytes32[] memory daiProof = MerkleHelper.generateProof(entries, 1);

        vm.prank(investor);
        manager.invest(address(usdc), usdcCap, usdcCap, usdcProof);
        assertEq(acl.amountInvested(investor, address(usdc)), usdcCap);

        vm.prank(investor);
        manager.invest(address(dai), daiCap, daiCap, daiProof);
        assertEq(acl.amountInvested(investor, address(dai)), daiCap);

        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, usdcCap, usdcProof);

        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(dai), 1e18, daiCap, daiProof);
    }

    function testZeroProofAmountBypassesCapCheck() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), 0);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 100 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        manager.invest(address(usdc), 50 * ONE_USDC, 0, proof);

        vm.prank(investor);
        manager.invest(address(usdc), 50 * ONE_USDC, 0, proof);

        assertEq(acl.amountInvested(investor, address(usdc)), 0);
    }

    function testInvestmentCapIndependentPerUser() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        address investor2 = makeAddr("investor2");

        uint256 cap = 10 * ONE_USDC;
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), cap);
        entries[1] = MerkleHelper.ACLEntry(investor2, address(usdc), cap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 20 * ONE_USDC);
        usdc.mint(investor2, 20 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(investor2);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof1 = MerkleHelper.generateProof(entries, 0);
        bytes32[] memory proof2 = MerkleHelper.generateProof(entries, 1);

        vm.prank(investor);
        manager.invest(address(usdc), cap, cap, proof1);

        vm.prank(investor2);
        manager.invest(address(usdc), cap, cap, proof2);

        assertEq(acl.amountInvested(investor, address(usdc)), cap);
        assertEq(acl.amountInvested(investor2, address(usdc)), cap);

        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, cap, proof1);

        vm.prank(investor2);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, cap, proof2);
    }

    function testPartialInvestmentsThenFullCap() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        uint256 cap = 100 * ONE_USDC;
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), cap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 10_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(10_000e18);

        usdc.mint(investor, 200 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        // Multiple partial investments should all succeed
        vm.prank(investor);
        manager.invest(address(usdc), 25 * ONE_USDC, cap, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 25 * ONE_USDC);

        vm.prank(investor);
        manager.invest(address(usdc), 50 * ONE_USDC, cap, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 75 * ONE_USDC);

        vm.prank(investor);
        manager.invest(address(usdc), 25 * ONE_USDC, cap, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), 100 * ONE_USDC);

        // Now at cap, further investment should fail
        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, cap, proof);
    }

    function testDifferentUsersWithDifferentCaps() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        address whale = makeAddr("whale");
        address retail = makeAddr("retail");

        uint256 whaleCap = 1000 * ONE_USDC;
        uint256 retailCap = 10 * ONE_USDC;

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
        entries[0] = MerkleHelper.ACLEntry(whale, address(usdc), whaleCap);
        entries[1] = MerkleHelper.ACLEntry(retail, address(usdc), retailCap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 100_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(100_000e18);

        usdc.mint(whale, 2000 * ONE_USDC);
        usdc.mint(retail, 20 * ONE_USDC);
        vm.prank(whale);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(retail);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory whaleProof = MerkleHelper.generateProof(entries, 0);
        bytes32[] memory retailProof = MerkleHelper.generateProof(entries, 1);

        vm.prank(whale);
        manager.invest(address(usdc), whaleCap, whaleCap, whaleProof);
        assertEq(acl.amountInvested(whale, address(usdc)), whaleCap);

        vm.prank(retail);
        manager.invest(address(usdc), retailCap, retailCap, retailProof);
        assertEq(acl.amountInvested(retail, address(usdc)), retailCap);

        vm.prank(whale);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, whaleCap, whaleProof);

        vm.prank(retail);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, retailCap, retailProof);
    }

    function testMixedUnlimitedAndCappedInvestors() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        address unlimited = makeAddr("unlimited");
        address capped = makeAddr("capped");

        uint256 cappedAmount = 10 * ONE_USDC;

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
        entries[0] = MerkleHelper.ACLEntry(unlimited, address(usdc), 0);
        entries[1] = MerkleHelper.ACLEntry(capped, address(usdc), cappedAmount);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 10_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(10_000e18);

        usdc.mint(unlimited, 1000 * ONE_USDC);
        usdc.mint(capped, 20 * ONE_USDC);
        vm.prank(unlimited);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(capped);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory unlimitedProof = MerkleHelper.generateProof(entries, 0);
        bytes32[] memory cappedProof = MerkleHelper.generateProof(entries, 1);

        vm.prank(unlimited);
        manager.invest(address(usdc), 100 * ONE_USDC, 0, unlimitedProof);

        vm.prank(unlimited);
        manager.invest(address(usdc), 200 * ONE_USDC, 0, unlimitedProof);

        assertEq(acl.amountInvested(unlimited, address(usdc)), 0);

        vm.prank(capped);
        manager.invest(address(usdc), cappedAmount, cappedAmount, cappedProof);
        assertEq(acl.amountInvested(capped, address(usdc)), cappedAmount);

        vm.prank(capped);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, cappedAmount, cappedProof);
    }

    function testACLDisabledAllowsUnrestrictedInvestment() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 100 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(investor);
        manager.invest(address(usdc), 50 * ONE_USDC, 0, MerkleHelper.emptyProof());

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(0), 0);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        assertEq(acl.amountInvested(investor, address(usdc)), 0);
    }

    // Helper function to reduce stack depth
    function _setupMultipleTokens(
        PutManager manager,
        MockERC20 usdc,
        MockYieldWrapper wrapper,
        address msig,
        address configurator
    )
        internal
        returns (MockERC20 dai, MockERC20 usdt, uint256 usdcCap, uint256 daiCap, uint256 usdtCap)
    {
        dai = new MockERC20("DAI", "DAI", 18);
        usdt = new MockERC20("USDT", "USDT", 6);

        MockFlyingTulipOracle oracle = MockFlyingTulipOracle(manager.getOracleAddress());
        oracle.setAssetPrice(address(dai), ONE_USD);
        oracle.setAssetPrice(address(usdt), ONE_USD);

        MockYieldWrapper daiWrapper = new MockYieldWrapper(address(dai));
        MockYieldWrapper usdtWrapper = new MockYieldWrapper(address(usdt));

        usdcCap = 100 * ONE_USDC;
        daiCap = 50e18;
        usdtCap = 25 * ONE_USDC;

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(msig);
        manager.addAcceptedCollateral(address(dai), address(daiWrapper));
        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdt), address(usdtWrapper));

        vm.startPrank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);
        manager.setCollateralCaps(address(dai), type(uint256).max);
        manager.setCollateralCaps(address(usdt), type(uint256).max);
        vm.stopPrank();

        return (dai, usdt, usdcCap, daiCap, usdtCap);
    }

    function testMultipleTokensAccumulateIndependently() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        (MockERC20 dai, MockERC20 usdt, uint256 usdcCap, uint256 daiCap, uint256 usdtCap) =
            _setupMultipleTokens(manager, usdc, wrapper, msig, configurator);

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](3);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), usdcCap);
        entries[1] = MerkleHelper.ACLEntry(investor, address(dai), daiCap);
        entries[2] = MerkleHelper.ACLEntry(investor, address(usdt), usdtCap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        ft.mint(configurator, 10_000e18);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(10_000e18);
        vm.stopPrank();

        usdc.mint(investor, 200 * ONE_USDC);
        dai.mint(investor, 100e18);
        usdt.mint(investor, 50 * ONE_USDC);

        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        dai.approve(address(manager), type(uint256).max);
        usdt.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        bytes32[] memory usdcProof = MerkleHelper.generateProof(entries, 0);
        bytes32[] memory daiProof = MerkleHelper.generateProof(entries, 1);
        bytes32[] memory usdtProof = MerkleHelper.generateProof(entries, 2);

        vm.prank(investor);
        manager.invest(address(usdc), usdcCap, usdcCap, usdcProof);

        vm.prank(investor);
        manager.invest(address(dai), daiCap, daiCap, daiProof);

        vm.prank(investor);
        manager.invest(address(usdt), usdtCap, usdtCap, usdtProof);

        assertEq(acl.amountInvested(investor, address(usdc)), usdcCap);
        assertEq(acl.amountInvested(investor, address(dai)), daiCap);
        assertEq(acl.amountInvested(investor, address(usdt)), usdtCap);

        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdc), 1 * ONE_USDC, usdcCap, usdcProof);

        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(dai), 1e18, daiCap, daiProof);

        vm.prank(investor);
        vm.expectRevert(ftACL.ftACLCapReached.selector);
        manager.invest(address(usdt), 1 * ONE_USDC, usdtCap, usdtProof);
    }

    function testInvestWithWrongProofFails() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        address investor2 = makeAddr("investor2");

        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), 10 * ONE_USDC);
        entries[1] = MerkleHelper.ACLEntry(investor2, address(usdc), 20 * ONE_USDC);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 30 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory wrongProof = MerkleHelper.generateProof(entries, 1);

        vm.prank(investor);
        vm.expectRevert(PutManager.ftPutManagerNotWhitelisted.selector);
        manager.invest(address(usdc), 10 * ONE_USDC, 10 * ONE_USDC, wrongProof);
    }

    function testSwitchingFromACLToNoACL() public {
        (
            PutManager manager,
            MockERC20 ft,
            MockERC20 usdc,
            MockYieldWrapper wrapper,
            address msig,
            address configurator,
            address investor
        ) = _deploy();

        uint256 cap = 10 * ONE_USDC;
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](1);
        entries[0] = MerkleHelper.ACLEntry(investor, address(usdc), cap);

        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        ftACL acl = new ftACL(merkleRoot, address(manager));

        vm.prank(msig);
        manager.setACL(address(acl));

        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(wrapper));
        vm.prank(configurator);
        manager.setCollateralCaps(address(usdc), type(uint256).max);

        ft.mint(configurator, 1_000e18);
        vm.prank(configurator);
        ft.approve(address(manager), type(uint256).max);
        vm.prank(configurator);
        manager.addFTLiquidity(1_000e18);

        usdc.mint(investor, 100 * ONE_USDC);
        vm.prank(investor);
        usdc.approve(address(manager), type(uint256).max);

        bytes32[] memory proof = MerkleHelper.generateProof(entries, 0);

        vm.prank(investor);
        manager.invest(address(usdc), cap, cap, proof);
        assertEq(acl.amountInvested(investor, address(usdc)), cap);

        vm.prank(msig);
        manager.setACL(address(0));

        vm.prank(investor);
        manager.invest(address(usdc), 50 * ONE_USDC, 0, MerkleHelper.emptyProof());

        assertEq(acl.amountInvested(investor, address(usdc)), cap);
    }
}
