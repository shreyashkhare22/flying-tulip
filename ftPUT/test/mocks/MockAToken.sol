// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAToken is ERC20 {
    MockERC20 public underlying;
    address public pool;

    constructor(MockERC20 _underlying)
        ERC20(string.concat("Aave ", _underlying.name()), string.concat("a", _underlying.symbol()))
    {
        underlying = _underlying;
    }

    function setPool(address _pool) external {
        pool = _pool;
    }

    function deposit(address from, uint256 amount) external {
        underlying.transferFrom(from, address(this), amount);
        _mint(from, amount);
    }

    function withdraw(address to, uint256 amount) external returns (uint256) {
        // If called by pool, burn from 'to' (the original caller)
        // Otherwise burn from msg.sender
        if (msg.sender == pool && to != address(0)) {
            // This is a special case for pool withdrawals
            // We need to get the actual owner from somewhere
            // For simplicity, we'll require the pool to handle this
            _burn(msg.sender, amount);
        } else {
            _burn(msg.sender, amount);
        }
        underlying.transfer(to, amount);
        return amount;
    }

    function burnFrom(address from, uint256 amount) external returns (uint256) {
        require(msg.sender == pool, "Only pool can burnFrom");
        _burn(from, amount);
        underlying.transfer(msg.sender, amount);
        return amount;
    }

    function addYield(address to, uint256 yield) external {
        underlying.transfer(msg.sender, yield);
        _mint(to, yield);
    }

    function decimals() public view override returns (uint8) {
        return underlying.decimals();
    }
}
