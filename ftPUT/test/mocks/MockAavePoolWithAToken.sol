// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockAavePool} from "./MockAavePool.sol";
import {MockAToken} from "./MockAToken.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAavePoolWithAToken is MockAavePool {
    MockAToken public aToken;
    MockERC20 public underlying;

    constructor(MockERC20 _underlying, MockAToken _aToken) {
        underlying = _underlying;
        aToken = _aToken;
        // Set this pool as the authorized pool for the aToken
        _aToken.setPool(address(this));
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        require(asset == address(underlying), "Wrong asset");
        underlying.transferFrom(msg.sender, address(this), amount);
        underlying.approve(address(aToken), amount);
        aToken.deposit(address(this), amount);
        aToken.transfer(onBehalfOf, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    )
        external
        override
        returns (uint256)
    {
        require(asset == address(underlying), "Wrong asset");

        // Use the special burnFrom function that only the pool can call
        uint256 withdrawn = aToken.burnFrom(msg.sender, amount);

        // Send underlying to the recipient
        underlying.transfer(to, withdrawn);
        return withdrawn;
    }
}
