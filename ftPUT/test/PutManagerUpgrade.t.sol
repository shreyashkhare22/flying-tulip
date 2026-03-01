// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFlyingTulipOracle} from "./mocks/MockOracles.sol";
import {MockYieldWrapper} from "./mocks/MockYieldWrapper.sol";
import {pFT} from "contracts/pFT.sol";
import {ftACL} from "contracts/ftACL.sol";
import {PutManager} from "contracts/PutManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MerkleHelper} from "./helpers/MerkleHelper.sol";

/// @notice A minimal V2 implementation that keeps PutManager behavior and exposes a new function
contract PutManagerV2 is PutManager {
    constructor(address _ft, address _ftPut) PutManager(_ft, _ftPut) {}

    // New helper to detect we've upgraded to V2
    function version() external pure returns (uint256) {
        return 2;
    }

    // Migration helper callable during upgradeToAndCall to flip saleEnabled
    function migrateSetSaleEnabled(bool _val) external {
        _setSaleEnabled(_val);
    }
}

// Non-UUPS implementation (no proxiableUUID) to test invalid implementation rejection
contract NonUUPS {}

contract PutManagerUpgradeTest is Test {
    address msig = address(0xA11CE);
    address configurator = address(0xB0B);

    MockERC20 ft;
    MockFlyingTulipOracle oracle;
    pFT pft;

    function setUp() public {
        ft = new MockERC20("Flying Tulip", "FT", 18);
        oracle = new MockFlyingTulipOracle();
        pFT pftImpl = new pFT();
        ERC1967Proxy pftProxy = new ERC1967Proxy(address(pftImpl), bytes(""));
        pft = pFT(address(pftProxy));
    }

    function _deployProxy() internal returns (PutManager manager, address implAddr) {
        PutManager impl = new PutManager(address(ft), address(pft));
        bytes memory init = abi.encodeWithSelector(
            PutManager.initialize.selector, configurator, msig, address(oracle)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        manager = PutManager(address(proxy));

        // initialize pFT from non-admin
        vm.prank(configurator);
        pft.initialize(address(manager));

        implAddr = address(impl);
    }

    function test_onlyMsigCanUpgrade() public {
        (PutManager manager,) = _deployProxy();

        // Deploy V2 implementation
        PutManagerV2 v2 = new PutManagerV2(address(ft), address(pft));

        // Sanity: ensure new implementation advertises proxiableUUID
        bytes32 expected = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(IProxiable(address(v2)).proxiableUUID(), expected);

        // Sanity: proxy msig should be set correctly
        assertEq(manager.msig(), msig);

        // Non-msig attempt should revert with ftPutManagerNotMsig
        vm.prank(address(0xDEAD));
        vm.expectRevert(PutManager.ftPutManagerNotMsig.selector);
        manager.upgradeToAndCall(address(v2), "");

        // msig can upgrade (use low-level call so we can surface revert data if it fails)
        vm.prank(msig);
        (bool ok2, bytes memory reason2) = address(manager)
            .call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(v2), ""));
        if (!ok2) {
            // If there's no revert data, surface a generic message
            if (reason2.length == 0) revert("upgradeTo failed with empty revert data");

            // Extract first 4 bytes (selector)
            bytes4 sel;
            assembly {
                sel := mload(add(reason2, 32))
            }

            // Map common error selectors to readable messages
            bytes4 sel_UUPSUnauthorized = bytes4(keccak256("UUPSUnauthorizedCallContext()"));
            bytes4 sel_UUPSUnsupportedUUID =
                bytes4(keccak256("UUPSUnsupportedProxiableUUID(bytes32)"));
            bytes4 sel_ERC1967InvalidImpl =
                bytes4(keccak256("ERC1967InvalidImplementation(address)"));
            bytes4 sel_ftPutManagerNotMsig = bytes4(keccak256("ftPutManagerNotMsig()"));

            if (sel == sel_UUPSUnauthorized) {
                revert("upgrade reverted: UUPSUnauthorizedCallContext");
            } else if (sel == sel_UUPSUnsupportedUUID) {
                revert("upgrade reverted: UUPSUnsupportedProxiableUUID");
            } else if (sel == sel_ERC1967InvalidImpl) {
                revert("upgrade reverted: ERC1967InvalidImplementation");
            } else if (sel == sel_ftPutManagerNotMsig) {
                revert("upgrade reverted: ftPutManagerNotMsig");
            } else {
                // Unknown selector: bubble raw
                revert("upgrade reverted: unknown selector");
            }
        }

        // After upgrade, proxy should expose V2's version() function
        uint256 v = PutManagerV2(address(manager)).version();
        assertEq(v, 2);
    }

    function test_stateIsPreservedAcrossUpgrade() public {
        (PutManager manager,) = _deployProxy();

        // Set some state via msig/configurator flows
        MockYieldWrapper vault = new MockYieldWrapper(address(ft));
        vm.prank(msig);
        manager.addAcceptedCollateral(address(ft), address(vault));

        // Ensure msig value present
        assertEq(manager.msig(), msig);

        // Deploy V2 and upgrade
        PutManagerV2 v2 = new PutManagerV2(address(ft), address(pft));
        vm.prank(msig);
        IUpgradeable(address(manager)).upgradeToAndCall(address(v2), "");

        // State should remain the same
        assertEq(manager.msig(), msig);
        // New function available
        assertEq(PutManagerV2(address(manager)).version(), 2);
    }

    function test_upgradeToSameImplementationIsAllowed() public {
        (PutManager manager, address implAddr) = _deployProxy();

        // Upgrading to the same implementation address should be allowed by msig
        vm.prank(msig);
        IUpgradeable(address(manager)).upgradeToAndCall(implAddr, "");
    }

    function test_upgradeRevertsForZeroAddress() public {
        (PutManager manager,) = _deployProxy();

        vm.prank(msig);
        vm.expectRevert();
        IUpgradeable(address(manager)).upgradeToAndCall(address(0), "");
    }

    function test_upgradeToNonUUPSImplementationReverts() public {
        (PutManager manager,) = _deployProxy();

        NonUUPS non = new NonUUPS();
        vm.prank(msig);
        vm.expectRevert();
        IUpgradeable(address(manager)).upgradeToAndCall(address(non), "");
    }

    function test_upgradeToAndCall_runsMigration() public {
        (PutManager manager,) = _deployProxy();

        // Ensure saleEnabled initially true (initializer sets it)
        assertEq(manager.saleEnabled(), true);

        PutManagerV2 v2 = new PutManagerV2(address(ft), address(pft));

        // Prepare calldata to call migrateSetSaleEnabled(false)
        bytes memory data =
            abi.encodeWithSelector(PutManagerV2.migrateSetSaleEnabled.selector, false);

        vm.prank(msig);
        IUpgradeable(address(manager)).upgradeToAndCall(address(v2), data);

        // After migration, saleEnabled should be false
        assertEq(manager.saleEnabled(), false);
    }
}

interface IUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
}

interface IProxiable {
    function proxiableUUID() external view returns (bytes32);
}
