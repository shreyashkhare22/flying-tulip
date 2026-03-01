// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IftACL {
    function isWhitelisted(
        address who,
        address asset,
        uint256 amount,
        bytes32[] calldata proof
    )
        external
        view
        returns (bool);

    function invest(address account, address token, uint256 amount, uint256 proofAmount) external;

    function getMerkleRoot() external view returns (bytes32);
}
