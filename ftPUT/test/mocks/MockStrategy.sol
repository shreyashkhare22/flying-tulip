// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategy} from "../../contracts/interfaces/IStrategy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract MockStrategy is IStrategy, ERC20 {
    IERC20Metadata public immutable underlying;
    address public ftYieldWrapper;
    uint256 public capitalBase;
    uint256 public manualAvailableLimit = type(uint256).max;

    uint256 public lastDepositAmount;
    uint256 public lastWithdrawAmount;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public lastClaimedYield;
    address public lastClaimTreasury;
    address public lastExecuteTarget;
    uint256 public lastExecuteValue;
    bytes public lastExecuteData;

    bool public failDeposit;
    bool public failWithdraw;
    bool public failClaim;
    bool public failExecute;

    event StrategyDeposit(address indexed caller, uint256 amount);
    event StrategyWithdraw(address indexed caller, uint256 amount);
    event StrategyClaim(address indexed caller, address indexed treasury, uint256 amount);
    event StrategyExecute(address indexed caller, address to, uint256 value, bytes data);

    constructor(address token_) ERC20("MockStrategy", "MSTR") {
        underlying = IERC20Metadata(token_);
    }

    function setFailureFlags(
        bool depositFail,
        bool withdrawFail,
        bool claimFail,
        bool executeFail
    )
        external
    {
        failDeposit = depositFail;
        failWithdraw = withdrawFail;
        failClaim = claimFail;
        failExecute = executeFail;
    }

    function token() external view override returns (address) {
        return address(underlying);
    }

    function positionToken() external view override returns (address) {
        return address(underlying);
    }

    function valueOfCapital() external view override returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function setftYieldWrapper(address _ftYieldWrapper) external override {
        ftYieldWrapper = _ftYieldWrapper;
    }

    function capital() external view override returns (uint256) {
        return capitalBase;
    }

    function yield() external view override returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        return bal > capitalBase ? bal - capitalBase : 0;
    }

    function claimYield(address treasury) external override returns (uint256) {
        require(!failClaim, "claim blocked");
        uint256 bal = underlying.balanceOf(address(this));
        uint256 currentYield = bal > capitalBase ? bal - capitalBase : 0;
        if (currentYield > 0) {
            require(underlying.transfer(treasury, currentYield), "transfer failed");
        }
        lastClaimTreasury = treasury;
        lastClaimedYield = currentYield;
        emit StrategyClaim(msg.sender, treasury, currentYield);
        return currentYield;
    }

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        override
        returns (bool success, bytes memory result)
    {
        require(!failExecute, "execute blocked");
        lastExecuteTarget = to;
        lastExecuteValue = value;
        lastExecuteData = data;
        emit StrategyExecute(msg.sender, to, value, data);
        (success, result) = to.call{value: value}(data);
    }

    function maxAbleToWithdraw(uint256 amount) external view override returns (uint256) {
        uint256 bal = availableToWithdraw();
        return amount > bal ? bal : amount;
    }

    function availableToWithdraw() public view override returns (uint256) {
        // Follow AaveStrategy pattern: return minimum of balance, capital, and manual limit
        uint256 bal = underlying.balanceOf(address(this));

        // First get minimum of balance and capital (no profits returned)
        uint256 min = bal < capitalBase ? bal : capitalBase;

        // Then apply manual limit if set
        return min < manualAvailableLimit ? min : manualAvailableLimit;
    }

    function setManualAvailable(uint256 limit) external {
        manualAvailableLimit = limit;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        require(!failWithdraw, "withdraw blocked");
        uint256 bal = underlying.balanceOf(address(this));
        uint256 toSend = amount < bal ? amount : bal;
        if (capitalBase > toSend) {
            capitalBase -= toSend;
        } else {
            capitalBase = 0;
        }
        lastWithdrawAmount = toSend;
        totalWithdrawn += toSend;
        emit StrategyWithdraw(msg.sender, toSend);
        require(underlying.transfer(msg.sender, toSend), "transfer failed");
        _burn(msg.sender, toSend);
        return toSend;
    }

    function withdrawUnderlying(uint256 amount) external returns (uint256 received) {
        require(!failWithdraw, "withdraw blocked");
        uint256 bal = underlying.balanceOf(address(this));
        uint256 toSend = amount < bal ? amount : bal;
        if (capitalBase > toSend) {
            capitalBase -= toSend;
        } else {
            capitalBase = 0;
        }
        lastWithdrawAmount = toSend;
        totalWithdrawn += toSend;
        emit StrategyWithdraw(msg.sender, toSend);
        require(underlying.transfer(msg.sender, toSend), "transfer failed");
        _burn(msg.sender, toSend);
        return toSend;
    }

    function deposit(uint256 amount) external override {
        require(!failDeposit, "deposit blocked");
        capitalBase += amount;
        totalDeposited += amount;
        lastDepositAmount = amount;
        emit StrategyDeposit(msg.sender, amount);
        require(underlying.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        _mint(msg.sender, amount);
    }

    function setManualCapital(uint256 newCapital) external {
        capitalBase = newCapital;
    }
}
