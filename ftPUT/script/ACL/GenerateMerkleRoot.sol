// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {PresaleWhitelistCSVParser} from "../helpers/PresaleWhitelistCSVParser.sol";
import {MerkleHelper} from "../../test/helpers/MerkleHelper.sol";

contract GenerateMerkleRootScript is Script {
    function run() external {
        string memory whitelistPath;
        try vm.envString("PRESALE_WHITELIST_PATH") returns (string memory v) {
            whitelistPath = v;
        } catch {
            whitelistPath = "script/ACL/presaleWhitelist.csv";
        }
        string memory csv = vm.readFile(whitelistPath);
        MerkleHelper.ACLEntry[] memory entries = PresaleWhitelistCSVParser.parseACL(csv, vm);
        bytes32 merkleRoot = MerkleHelper.generateRoot(entries);
        console.log("Generated Merkle Root:");
        console.logBytes32(merkleRoot);
    }
}
