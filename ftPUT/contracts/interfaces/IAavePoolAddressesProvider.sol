// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}
