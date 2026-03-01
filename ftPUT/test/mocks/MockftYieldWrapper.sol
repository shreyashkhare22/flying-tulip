// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

contract MockftYieldWrapper {
    address public treasury;

    constructor(address _treasury) {
        treasury = _treasury;
    }
}
