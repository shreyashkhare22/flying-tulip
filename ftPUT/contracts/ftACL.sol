// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IftACL} from "./interfaces/IftACL.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ftACL is IftACL, Ownable {
    bytes32 public merkleRoot;
    address public putManager;

    mapping(address account => mapping(address token => uint256 invested)) public amountInvested;

    event MerkleRootUpdated(bytes32 indexed newRoot);

    error ftACLNotPutManager();
    error ftACLCapReached();
    error ftACLZeroAddress();
    error ftACLZeroRoot();

    modifier onlyPutManager() {
        if (msg.sender != putManager) {
            revert ftACLNotPutManager();
        }
        _;
    }

    constructor(bytes32 root, address _putManager) Ownable(msg.sender) {
        if (_putManager == address(0)) revert ftACLZeroAddress();
        putManager = _putManager;
        _updateMerkleRoot(root);
    }

    /**
     * @dev Verify if an address is whitelisted using merkle proof
     * Tries all possible combinations of parameters:
     * - asset can be: actual asset or address(0)
     * - amount can be: actual amount or 0
     *
     * @param who The address to check
     * @param asset The asset address
     * @param amount The amount limit
     * @param proof The merkle proof for the address
     */
    function isWhitelisted(
        address who,
        address asset,
        uint256 amount,
        bytes32[] calldata proof
    )
        external
        view
        override
        returns (bool)
    {
        bytes32 leaf;

        // 1. Exact match: specific asset, and amount
        leaf = keccak256(bytes.concat(keccak256(abi.encode(who, asset, amount))));
        if (MerkleProof.verify(proof, merkleRoot, leaf)) {
            return true;
        }

        // 2. Specific asset, any amount
        leaf = keccak256(bytes.concat(keccak256(abi.encode(who, asset, uint256(0)))));
        if (MerkleProof.verify(proof, merkleRoot, leaf)) {
            return true;
        }

        // 3. Any asset & amount
        leaf = keccak256(bytes.concat(keccak256(abi.encode(who, address(0), uint256(0)))));
        if (MerkleProof.verify(proof, merkleRoot, leaf)) {
            return true;
        }
        return false;
    }

    /**
     * @dev Record an investment for an account and token.
     * If there are multiple leaves for the same account, then
     * the cap for the token will be which ever has the highest amount.
     * @param account The investor's address
     * @param token The token address
     * @param amount The amount invested
     */
    function invest(
        address account,
        address token,
        uint256 amount,
        uint256 proofAmount
    )
        external
        onlyPutManager
    {
        uint256 newInvestedAmount = amountInvested[account][token] + amount;
        if (newInvestedAmount > proofAmount) {
            revert ftACLCapReached();
        }

        amountInvested[account][token] = newInvestedAmount;
    }

    /**
     * @dev Update the merkle root (admin only)
     * @param newRoot The new merkle root
     */
    function updateMerkleRoot(bytes32 newRoot) external onlyOwner {
        _updateMerkleRoot(newRoot);
    }

    /**
     * @dev Get the current merkle root
     */
    function getMerkleRoot() external view override returns (bytes32) {
        return merkleRoot;
    }

    /**
     * @dev Update the merkle root
     */
    function _updateMerkleRoot(bytes32 newRoot) internal {
        if (newRoot == bytes32(0)) revert ftACLZeroRoot();
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }
}
