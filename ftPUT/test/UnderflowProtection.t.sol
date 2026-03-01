// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../contracts/ftYieldWrapper.sol";
import "./mocks/MockERC20.sol";

// Faulty strategy that returns more than it should
contract FaultyStrategy {
    address public immutable token;
    address public immutable wrapper;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _wrapper, address _token) {
        wrapper = _wrapper;
        token = _token;
    }

    function deposit(uint256 amount) external {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
    }

    // Faulty: returns more than requested
    function withdraw(uint256 amount) external returns (uint256) {
        uint256 faultyAmount = amount * 2;
        MockERC20(token).mint(address(this), faultyAmount);
        MockERC20(token).transfer(msg.sender, faultyAmount);

        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;

        return faultyAmount;
    }

    function valueOfCapital() external view returns (uint256) {
        return MockERC20(token).balanceOf(address(this));
    }

    function maxAbleToWithdraw(uint256) external view returns (uint256) {
        return MockERC20(token).balanceOf(address(this));
    }

    function yield() external pure returns (uint256) {
        return 0;
    }

    function claimYield(address) external pure returns (uint256) {
        return 0;
    }

    function execute(address, uint256, bytes calldata) external pure returns (bool, bytes memory) {
        return (false, "");
    }
}

contract UnderflowProtectionTest is Test {
    ftYieldWrapper wrapper;
    MockERC20 usdc;
    FaultyStrategy faultyStrategy;
    address user = address(0x1234);
    address admin = address(this);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wrapper = new ftYieldWrapper(address(usdc), admin, admin, admin);
        faultyStrategy = new FaultyStrategy(address(wrapper), address(usdc));
        wrapper.setDepositor(user);
    }

    function test_UnderflowProtection_ForceWithdraw() public {
        wrapper.setStrategy(address(faultyStrategy));
        wrapper.confirmStrategy();

        usdc.mint(user, 1_000e6);
        vm.startPrank(user);
        usdc.approve(address(wrapper), 1_000e6);
        wrapper.deposit(1_000e6);
        vm.stopPrank();

        wrapper.deploy(address(faultyStrategy), 1_000e6);

        // Force withdraw - strategy will try to return 2x (2000e6 instead of 1000e6)
        wrapper.forceWithdrawToWrapper(address(faultyStrategy), 1_000e6);

        // Verify underflow protection worked:
        assertEq(wrapper.deployedToStrategy(address(faultyStrategy)), 0);
        assertEq(wrapper.deployed(), 0);
        assertEq(usdc.balanceOf(address(wrapper)), 2_000e6);
    }

    function test_UnderflowProtection_UserWithdraw() public {
        wrapper.setStrategy(address(faultyStrategy));
        wrapper.confirmStrategy();

        usdc.mint(user, 1_000e6);
        vm.startPrank(user);
        usdc.approve(address(wrapper), 1_000e6);
        wrapper.deposit(1_000e6);
        vm.stopPrank();

        wrapper.deploy(address(faultyStrategy), 1_000e6);

        vm.prank(user);
        wrapper.withdraw(1_000e6, user);

        // Verify underflow protection worked:
        assertEq(wrapper.deployedToStrategy(address(faultyStrategy)), 0);
        assertEq(wrapper.deployed(), 0);

        // With clamped transfer, user receives exactly the requested amount
        // (any extra returned by a faulty strategy remains in the wrapper)
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(wrapper.balanceOf(user), 0);
    }

    function test_UnderflowProtection_PartialDeployment() public {
        wrapper.setStrategy(address(faultyStrategy));
        wrapper.confirmStrategy();

        usdc.mint(user, 1_000e6);
        vm.startPrank(user);
        usdc.approve(address(wrapper), 1_000e6);
        wrapper.deposit(1_000e6);
        vm.stopPrank();

        wrapper.deploy(address(faultyStrategy), 500e6);

        assertEq(wrapper.deployedToStrategy(address(faultyStrategy)), 500e6);
        assertEq(wrapper.deployed(), 500e6);

        wrapper.forceWithdrawToWrapper(address(faultyStrategy), 500e6);

        // Verify underflow protection:
        assertEq(wrapper.deployedToStrategy(address(faultyStrategy)), 0);
        assertEq(wrapper.deployed(), 0);
        assertEq(usdc.balanceOf(address(wrapper)), 1_500e6);
    }
}
