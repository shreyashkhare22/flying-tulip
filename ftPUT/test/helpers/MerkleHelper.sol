// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Merkle} from "murky/Merkle.sol";

/**
 * @title MerkleHelper
 * @notice Helper library for working with Merkle trees in tests and scripts
 * @dev Uses Murky for tree/proof generation and OZ 5.4 standard leaf encoding
 *
 * Usage:
 *   import {MerkleHelper} from "./helpers/MerkleHelper.sol";
 *
 *   // Create ACL entries
 *   MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](2);
 *   entries[0] = MerkleHelper.ACLEntry(addr1, address(0), 0); // Any asset, amount
 *   entries[1] = MerkleHelper.ACLEntry(addr2, tokenAddr, 1000); // Specific restrictions
 *
 *   bytes32 root = MerkleHelper.generateRoot(entries);
 *   bytes32[] memory proof = MerkleHelper.generateProof(entries, targetIndex);
 *
 *   // For no ACL scenarios
 *   bytes32[] memory emptyProof = MerkleHelper.emptyProof();
 *   bytes32 emptyRoot = MerkleHelper.emptyRoot();
 */
library MerkleHelper {
    error EmptyEntryArray();
    error IndexOutOfBounds();

    /**
     * @notice ACL entry with granular permissions
     * @param who The address being granted access
     * @param asset The asset address (address(0) = any asset)
     * @param amount The amount limit (0 = any amount)
     */
    struct ACLEntry {
        address who;
        address asset;
        uint256 amount;
    }

    /**
     * @notice Returns an empty proof array
     * @dev Used when no ACL is set or for single-leaf trees
     */
    function emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /**
     * @notice Returns empty merkle root (zero bytes32)
     * @dev Used to represent no whitelist or disabled ACL
     */
    function emptyRoot() internal pure returns (bytes32) {
        return bytes32(0);
    }

    /**
     * @notice Convert ACL entry to OZ 5.4 standard leaf
     * @param entry The ACL entry (who, asset, amount)
     * @return bytes32 The leaf hash
     */
    function toLeaf(ACLEntry memory entry) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(entry.who, entry.asset, entry.amount))));
    }

    /**
     * @notice Convert ACL entries to OZ 5.4 standard leaves
     * @param entries Array of ACL entries to convert
     * @return bytes32[] Array of leaf hashes
     */
    function toLeaves(ACLEntry[] memory entries) internal pure returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            leaves[i] = toLeaf(entries[i]);
        }
        return leaves;
    }

    /**
     * @notice Generate merkle root from ACL entries using Murky
     * @param entries Array of ACL entries to include in tree
     * @return bytes32 The merkle root
     * @dev For single entry, returns the leaf itself (no tree needed)
     *      Each entry can have granular asset and amount restrictions
     */
    function generateRoot(ACLEntry[] memory entries) internal returns (bytes32) {
        if (entries.length == 0) {
            return emptyRoot();
        }

        // Single entry case - root is just the leaf
        if (entries.length == 1) {
            return toLeaf(entries[0]);
        }

        // Multiple entries - use Murky
        Merkle m = new Merkle();
        bytes32[] memory leaves = toLeaves(entries);
        return m.getRoot(leaves);
    }

    /**
     * @notice Generate merkle proof for ACL entry at index using Murky
     * @param entries All ACL entries in the tree
     * @param index Index of the entry to generate proof for
     * @return bytes32[] The merkle proof
     * @dev For single entry, returns empty proof (leaf is the root)
     */
    function generateProof(
        ACLEntry[] memory entries,
        uint256 index
    )
        internal
        returns (bytes32[] memory)
    {
        require(entries.length > 0, EmptyEntryArray());
        require(index < entries.length, IndexOutOfBounds());

        // Single entry case - empty proof (leaf is the root)
        if (entries.length == 1) {
            return emptyProof();
        }

        // Multiple entries - use Murky
        Merkle m = new Merkle();
        bytes32[] memory leaves = toLeaves(entries);
        return m.getProof(leaves, index);
    }
}
