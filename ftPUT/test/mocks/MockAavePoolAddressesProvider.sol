// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {
    IAavePoolAddressesProvider
} from "../../contracts/interfaces/IAavePoolAddressesProvider.sol";

contract MockAavePoolAddressesProvider is IAavePoolAddressesProvider {
    address public pool;

    constructor(address _pool) {
        pool = _pool;
    }

    function getPool() external view returns (address) {
        return pool;
    }

    function setPool(address _pool) external {
        pool = _pool;
    }
}
