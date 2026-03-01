// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

contract CallTarget {
    uint256 public lastValue;
    bytes public lastData;
    address public lastCaller;

    event Ping(address indexed caller, uint256 value, bytes data, bytes32 response);

    function ping(uint256 value, bytes calldata data) external returns (bytes32) {
        lastCaller = msg.sender;
        lastValue = value;
        lastData = data;
        bytes32 response = keccak256(abi.encodePacked(msg.sender, value, data));
        emit Ping(msg.sender, value, data, response);
        return response;
    }
}
