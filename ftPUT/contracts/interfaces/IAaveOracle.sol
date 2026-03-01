// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}
