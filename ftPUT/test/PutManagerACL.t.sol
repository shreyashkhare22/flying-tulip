// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "test/mocks/MockOracles.sol";
import {MockYieldWrapper} from "test/mocks/MockYieldWrapper.sol";
import {ftACL} from "contracts/ftACL.sol";

contract PutManagerACLTest is Test {
    address msig = makeAddr("msig");
    address configurator = makeAddr("configurator");
    address investor = makeAddr("investor");

    MockERC20 ft;
    MockERC20 usdc;
    MockFlyingTulipOracle oracle;
    MockYieldWrapper usdcVault;
    pFT ftput;
    PutManager manager;

    function setUp() public {
        ft = new MockERC20("Flying Tulip", "FT", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockFlyingTulipOracle();
        usdcVault = new MockYieldWrapper(address(usdc));

        // Deploy PutManager (UUPS behind ERC1967Proxy)
        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        ftput = pFT(address(pftProxy));
        PutManager impl = new PutManager(address(ft), address(ftput));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(oracle)
        );
        vm.prank(msig);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        manager = PutManager(address(proxy));

        // Wire pFT to manager
        vm.prank(configurator);
        ftput.initialize(address(manager));

        // Collateral setup
        vm.prank(msig);
        manager.addAcceptedCollateral(address(usdc), address(usdcVault));

        // Provide FT liquidity
        uint256 liquidity = 1_000_000e18;
        ft.mint(configurator, liquidity);
        vm.startPrank(configurator);
        ft.approve(address(manager), type(uint256).max);
        manager.addFTLiquidity(liquidity);
        vm.stopPrank();

        // Investor approvals
        usdc.mint(investor, 10_000e6);
        vm.startPrank(investor);
        usdc.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function test_Invest_Succeeds_WhenACLUnset_EvenWithProofAmount() public {
        // ACL is unset by default. Use a non-zero proofAmount with empty proof.
        uint256 deposit = 1_000e6;
        (uint256 ftNeeded,,) = manager.getAssetFTPrice(address(usdc), deposit);

        vm.startPrank(investor);
        uint256 id = manager.invest(
            address(usdc),
            deposit,
            /*proofAmount*/
            ftNeeded,
            new bytes32[](0)
        );
        vm.stopPrank();

        // Position was created and wrapper received the capital
        assertEq(ftput.ownerOf(id), investor);
        assertEq(usdcVault.totalDeposited(), deposit);
        assertEq(manager.ftAllocated(), ftNeeded);
    }

    function test_Invest_Reverts_NotWhitelisted_WhenACLSet() public {
        // Set an ACL with a merkle root that does not whitelist the investor
        bytes32 fakeRoot = keccak256(abi.encodePacked("root"));
        ftACL acl = new ftACL(fakeRoot, address(manager));
        vm.prank(msig);
        manager.setACL(address(acl));

        uint256 deposit = 500e6;
        (uint256 ftNeeded,,) = manager.getAssetFTPrice(address(usdc), deposit);

        vm.startPrank(investor);
        vm.expectRevert(PutManager.ftPutManagerNotWhitelisted.selector);
        manager.invest(
            address(usdc),
            deposit,
            /*proofAmount*/
            ftNeeded,
            new bytes32[](0)
        );
        vm.stopPrank();
    }
}
