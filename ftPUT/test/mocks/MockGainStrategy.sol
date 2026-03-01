// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockStrategy} from "./MockStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockGainStrategy is MockStrategy {
    uint256 public gainPercentage = 40;

    constructor(address token_) MockStrategy(token_) {}

    function setGainPercentage(uint256 _gainPercentage) external {
        gainPercentage = _gainPercentage;
    }

    function simulateGain() external {
        uint256 currentBalance = underlying.balanceOf(address(this));
        uint256 gainAmount = (currentBalance * gainPercentage) / 100;

        if (gainAmount > 0) {
            MockERC20(address(underlying)).mint(address(this), gainAmount);
        }
    }
}
