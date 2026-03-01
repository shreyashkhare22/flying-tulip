// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IFlyingTulipOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    // FT per USD scaled to 1e8 (same base as oracle)
    function ftPerUSD() external view returns (uint64);
}
