// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {
    IERC20Metadata,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAavePoolAddressesProvider} from "../interfaces/IAavePoolAddressesProvider.sol";
import {IAavePoolInstance} from "../interfaces/IAavePoolInstance.sol";

import {IStrategy} from "../interfaces/IStrategy.sol";

/*
    Generic Aave deposit strategy
*/
contract AaveStrategy is IStrategy, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    IAavePoolAddressesProvider public immutable poolAddressProvider;
    address public immutable token;
    IERC20 public immutable aToken;

    uint16 internal constant REFERRAL_CODE = 7;

    // ftYieldWrapper has no access to aToken, simply a passthrough for ftYieldWrapper
    address public ftYieldWrapper;

    modifier onlyftYieldWrapper() {
        if (msg.sender != ftYieldWrapper) {
            revert StrategyNotYieldWrapper();
        }
        _;
    }

    constructor(
        address _ftYieldWrapper,
        address _poolAddressProvider,
        address _token,
        address _aToken
    )
        ERC20(
            string.concat("Flying Tulip Aave ", IERC20Metadata(_token).name()),
            string.concat("ftAave", IERC20Metadata(_token).symbol())
        )
    {
        if (
            _ftYieldWrapper == address(0) || _poolAddressProvider == address(0)
                || _token == address(0) || _aToken == address(0)
        ) revert StrategyZeroAddress();

        // Basic sanity: ensure token/aToken decimals match to reduce misconfiguration risk
        if (IERC20Metadata(_token).decimals() != IERC20Metadata(_aToken).decimals()) {
            revert StrategyZeroAddress();
        }

        ftYieldWrapper = _ftYieldWrapper;
        poolAddressProvider = IAavePoolAddressesProvider(_poolAddressProvider);
        token = _token;
        aToken = IERC20(_aToken);

        emit Transfer(address(0x0), address(this), 0);
    }

    function setftYieldWrapper(address _ftYieldWrapper) external onlyftYieldWrapper {
        if (_ftYieldWrapper == address(0)) revert StrategyZeroAddress();
        ftYieldWrapper = _ftYieldWrapper;
        emit UpdateftYieldWrapper(_ftYieldWrapper);
    }

    function pool() public view returns (IAavePoolInstance) {
        return IAavePoolInstance(poolAddressProvider.getPool());
    }

    // simply a 1:1 mapping of capital provided
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    // capital + yield
    function valueOfCapital() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function yield() public view returns (uint256) {
        uint256 v = valueOfCapital();
        uint256 t = totalSupply();
        return (v > t) ? (v - t) : 0;
    }

    // helper functions for put servicing
    function availableToWithdraw() public view returns (uint256) {
        // Only report the minimum of:
        // - what this strategy actually owns (aToken.balanceOf(this))
        // - what the pool currently has available (token.balanceOf(aToken))
        // - the capital invested (totalSupply)
        uint256 owned = aToken.balanceOf(address(this));
        uint256 poolLiquidity = IERC20(token).balanceOf(address(aToken));
        uint256 _capital = totalSupply();

        // Return the minimum of all three values
        uint256 min = owned < poolLiquidity ? owned : poolLiquidity;
        return min < _capital ? min : _capital;
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        return (availableToWithdraw() >= amount);
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 _liquidity = availableToWithdraw();
        return _liquidity > amount ? amount : _liquidity;
    }

    function deposit(uint256 amount) external nonReentrant onlyftYieldWrapper {
        if (amount == 0) revert StrategyAmountZero();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IAavePoolInstance _pool = pool();
        IERC20(token).forceApprove(address(_pool), amount);
        _pool.supply(address(token), amount, address(this), REFERRAL_CODE);
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        _burn(msg.sender, amount);
        received = pool().withdraw(address(token), amount, msg.sender);
        if (received != amount) revert StrategyInsufficientLiquidity();
        emit Withdraw(msg.sender, amount);
    }

    // ===== New: support "exit underlying" by sending aToken directly =====

    /// @notice Address of the position token (aToken).
    function positionToken() external view returns (address) {
        return address(aToken);
    }

    /// @notice Burns wrapper shares and transfers `amount` aToken to `to` (1:1 with shares).
    function withdrawUnderlying(uint256 amount)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 received)
    {
        _burn(msg.sender, amount);
        aToken.safeTransfer(msg.sender, amount);
        // After burning and transfer, valueOfCapital() - totalSupply() remains unchanged (yield preserved)
        received = amount;
        emit Withdraw(msg.sender, amount);
    }

    function claimYield(address treasury)
        external
        nonReentrant
        onlyftYieldWrapper
        returns (uint256 _yield)
    {
        _yield = yield();
        // transfer surplus yield tokens to treasury
        if (_yield != 0) {
            aToken.safeTransfer(treasury, _yield);
            emit YieldClaimed(msg.sender, treasury, address(token), _yield);
        }
    }

    // godmode function (can't drain underlying) for claiming points or other offchain values
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        nonReentrant
        onlyftYieldWrapper
        returns (bool success, bytes memory result)
    {
        if (to == address(aToken) || to == address(pool())) {
            revert StrategyCantInteractWithCoreAssets();
        }
        (success, result) = to.call{value: value}(data);
        if (valueOfCapital() < totalSupply()) {
            revert StrategyCapitalMustNotChange();
        }
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return IERC20Metadata(token).decimals();
    }
}
