// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockStrategy} from "./MockStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAccruingStrategy is MockStrategy {
    constructor(address token_) MockStrategy(token_) {}

    function simulateYield(uint256 amount) external {
        MockERC20(address(underlying)).mint(address(this), amount);
        _mint(ftYieldWrapper, amount);
    }
}
