// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IERC20Metadata,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStrategy, IStrategyWithQueue} from "./interfaces/IStrategy.sol";
import {IftYieldWrapper} from "./interfaces/IftYieldWrapper.sol";
import {ICircuitBreaker} from "./interfaces/ICircuitBreaker.sol";

// Single asset per chain wrapper
contract ftYieldWrapper is IftYieldWrapper, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    uint256 public deployed; // default to 0

    address public immutable token;

    address public yieldClaimer;
    address public pendingYieldClaimer;
    address public strategyManager;
    address public pendingStrategyManager;
    address public treasury;
    address public pendingTreasury;
    address public subYieldClaimer;
    address public putManager;
    address public depositor;
    address public circuitBreaker;

    IStrategy[] public strategies;
    mapping(address strategy => uint256 deployed) public deployedToStrategy;

    // must be submitted by strategyManager
    address public pendingStrategy;
    uint256 public delayStrategy;
    uint256 internal constant DELAY = 0; // 1 days in production

    event Deployed(address strategy, uint256 allocation);
    event YieldClaimed(address yieldClaimer, address token, uint256 amount);
    event Deposit(address owner, uint256 amount);
    event Withdraw(address owner, uint256 amount);
    event WithdrawUnderlying(address owner, uint256 amount);
    event QueuedToWrapper(address strategyManager, address strategy, uint256 amount);
    event WithdrawToWrapper(address strategyManager, address strategy, uint256 amount);

    event PendingYieldClaimer(address yieldClaimer, address pendingYieldClaimer);
    event PendingStrategyManager(address strategyManager, address pendingStrategyManager);
    event PendingTreasury(address treasury, address pendingTreasuy);
    event PendingStrategy(address strategyManager, address pendingStrategy);

    event UpdateYieldClaimer(address newYieldClaimer);
    event UpdateStrategyManager(address newStrategyManager);
    event UpdateTreasury(address newTreasury);
    event UpdateSubYieldClaimer(address yieldClaimer, address subYieldClaimer);
    event UpdatePutManager(address newPutManager);
    event UpdateDepositor(address newDepositor);

    event AddedStrategy(address strategyManager, address strategy);
    event RemovedStrategy(address strategyManager, address strategy);
    event StrategiesReordered(address[] newOrder);
    event YieldSwept(address caller, address token, uint256 amount);
    event CircuitBreakerUpdated(address indexed newCircuitBreaker);

    error ftYieldWrapperInsufficientLiquidity();
    error ftYieldWrapperNotYieldClaimer();
    error ftYieldWrapperNotYieldClaimers();
    error ftYieldWrapperDelayNotExpired();
    error ftYieldWrapperNotStrategyManager();
    error ftYieldWrapperZeroAddress();
    error ftYieldWrapperNotSetter();
    error ftYieldWrapperNotConfirmer();
    error ftYieldWrapperNotYieldClaimConfirmer();
    error ftYieldWrapperSettingUnchanged();
    error ftYieldWrapperNotStrategy();
    error ftYieldWrapperNoYield();
    error ftYieldWrapperInvalidStrategyIndex();
    error ftYieldWrapperInvalidStrategiesOrder();
    error ftYieldWrapperNotPutManagerOrDepositor();
    error ftYieldWrapperRateLimitExceeded(uint256 requested, uint256 available);

    modifier onlyYieldClaimer() {
        if (msg.sender != yieldClaimer) revert ftYieldWrapperNotYieldClaimer();
        _;
    }

    modifier onlyStrategyManager() {
        if (msg.sender != strategyManager) {
            revert ftYieldWrapperNotStrategyManager();
        }
        _;
    }

    modifier onlyYieldClaimers() {
        if (msg.sender != yieldClaimer && msg.sender != subYieldClaimer) {
            revert ftYieldWrapperNotYieldClaimers();
        }
        _;
    }

    modifier onlyPutManagerOrDepositor() {
        if (msg.sender != putManager && msg.sender != depositor) {
            revert ftYieldWrapperNotPutManagerOrDepositor();
        }
        _;
    }

    constructor(
        address _token,
        address _yieldClaimer,
        address _strategyManager,
        address _treasury
    )
        ERC20(
            string.concat("Flying Tulip ", IERC20Metadata(_token).name()),
            string.concat("ft", IERC20Metadata(_token).symbol())
        )
    {
        if (_token == address(0x0)) revert ftYieldWrapperZeroAddress();
        if (_yieldClaimer == address(0x0)) revert ftYieldWrapperZeroAddress();
        if (_strategyManager == address(0x0)) {
            revert ftYieldWrapperZeroAddress();
        }
        if (_treasury == address(0x0)) revert ftYieldWrapperZeroAddress();

        token = _token;
        yieldClaimer = _yieldClaimer;
        strategyManager = _strategyManager;
        treasury = _treasury;
        // putManager defaults to 0x0
        // depositor defaults to 0x0

        emit Transfer(address(0x0), address(this), 0);
    }

    function setYieldClaimer(address _yieldClaimer) external onlyYieldClaimer {
        if (_yieldClaimer == address(0x0)) revert ftYieldWrapperZeroAddress();
        pendingYieldClaimer = _yieldClaimer;
        emit PendingYieldClaimer(yieldClaimer, pendingYieldClaimer);
    }

    function setSubYieldClaimer(address _subYieldClaimer) external onlyYieldClaimer {
        if (_subYieldClaimer == address(0x0)) {
            revert ftYieldWrapperZeroAddress();
        }
        subYieldClaimer = _subYieldClaimer;
        emit UpdateSubYieldClaimer(yieldClaimer, subYieldClaimer);
    }

    function confirmYieldClaimer() external {
        if (msg.sender != treasury && msg.sender != strategyManager) {
            revert ftYieldWrapperNotYieldClaimConfirmer();
        }
        if (pendingYieldClaimer == address(0x0)) {
            revert ftYieldWrapperZeroAddress();
        }
        if (yieldClaimer == pendingYieldClaimer) {
            revert ftYieldWrapperSettingUnchanged();
        }
        yieldClaimer = pendingYieldClaimer;
        pendingYieldClaimer = address(0x0);
        emit UpdateYieldClaimer(yieldClaimer);
    }

    function setStrategyManager(address _strategyManager) external onlyStrategyManager {
        if (_strategyManager == address(0x0)) {
            revert ftYieldWrapperZeroAddress();
        }
        pendingStrategyManager = _strategyManager;
        emit PendingStrategyManager(strategyManager, pendingStrategyManager);
    }

    function confirmStrategyManager() external {
        if (msg.sender != treasury && msg.sender != yieldClaimer) {
            revert ftYieldWrapperNotConfirmer();
        }
        if (pendingStrategyManager == address(0x0)) {
            revert ftYieldWrapperZeroAddress();
        }
        if (strategyManager == pendingStrategyManager) {
            revert ftYieldWrapperSettingUnchanged();
        }
        strategyManager = pendingStrategyManager;
        pendingStrategyManager = address(0x0);
        emit UpdateStrategyManager(strategyManager);
    }

    function setTreasury(address _treasury) external {
        if (msg.sender != treasury) revert ftYieldWrapperNotSetter();
        if (_treasury == address(0x0)) revert ftYieldWrapperZeroAddress();
        pendingTreasury = _treasury;
        emit PendingTreasury(treasury, pendingTreasury);
    }

    function confirmTreasury() external {
        if (msg.sender != strategyManager && msg.sender != yieldClaimer) {
            revert ftYieldWrapperNotConfirmer();
        }
        if (pendingTreasury == address(0x0)) revert ftYieldWrapperZeroAddress();
        if (treasury == pendingTreasury) {
            revert ftYieldWrapperSettingUnchanged();
        }
        treasury = pendingTreasury;
        pendingTreasury = address(0x0);
        emit UpdateTreasury(treasury);
    }

    function setPutManager(address _putManager) external onlyStrategyManager {
        if (_putManager == address(0x0)) revert ftYieldWrapperZeroAddress();
        putManager = _putManager;
        emit UpdatePutManager(_putManager);
    }

    function setDepositor(address _depositor) external onlyStrategyManager {
        depositor = _depositor;
        emit UpdateDepositor(_depositor);
    }

    /// @notice Set or disable the circuit breaker
    /// @dev Only callable by strategy manager. Set to address(0) to disable.
    /// @param _circuitBreaker Address of circuit breaker, or address(0) to disable
    function setCircuitBreaker(address _circuitBreaker) external onlyStrategyManager {
        circuitBreaker = _circuitBreaker;
        emit CircuitBreakerUpdated(_circuitBreaker);
    }

    function setStrategy(address _strategy) external onlyStrategyManager {
        if (_strategy == address(0x0)) revert ftYieldWrapperZeroAddress();
        if (isStrategy(_strategy) || IStrategy(_strategy).token() != token) {
            revert ftYieldWrapperNotStrategy();
        }
        uint256 effectiveTime = block.timestamp + DELAY;
        pendingStrategy = _strategy;
        delayStrategy = effectiveTime;
        emit PendingStrategy(strategyManager, pendingStrategy);
    }

    function confirmStrategy() external {
        if (msg.sender != treasury) revert ftYieldWrapperNotConfirmer();
        if (pendingStrategy == address(0x0)) revert ftYieldWrapperZeroAddress();
        if (delayStrategy > block.timestamp) revert ftYieldWrapperDelayNotExpired();
        strategies.push(IStrategy(pendingStrategy));
        emit AddedStrategy(strategyManager, pendingStrategy);
        // Ensure strategy wrapper pointer is set (no-op if already this wrapper)
        try IStrategy(pendingStrategy).setftYieldWrapper(address(this)) {
        // ok
        }
            catch {
            // strategies are expected to support this; ignore to avoid bricking
        }
        pendingStrategy = address(0x0);
        delayStrategy = 0;
        emit PendingStrategy(strategyManager, pendingStrategy);
    }

    /// @notice Remove a strategy whose wrapper share balance is zero.
    function removeStrategy(uint256 index) external onlyStrategyManager {
        uint256 len = strategies.length;
        if (index >= len) {
            revert ftYieldWrapperInvalidStrategyIndex();
        }

        IStrategy s = strategies[index];
        if (deployedToStrategy[address(s)] != 0) {
            revert ftYieldWrapperNotStrategy();
        }

        address removed = address(s);
        // swap & pop
        if (index != len - 1) {
            strategies[index] = strategies[len - 1];
        }
        strategies.pop();
        emit RemovedStrategy(msg.sender, removed);
    }

    /**
     * @dev Check if an address is a registered strategy
     * @param _strategy The address to check
     * @return bool True if the address is a registered strategy, false otherwise
     */
    function isStrategy(address _strategy) public view returns (bool) {
        uint256 strategiesLength = strategies.length;
        for (uint256 i = 0; i < strategiesLength; i++) {
            if (address(strategies[i]) == _strategy) return true;
        }
        return false;
    }

    /**
     * @dev Reorder strategies for withdrawal priority
     * @notice Can only be called by strategy manager
     * @param _newOrder Array of strategy addresses in the desired order
     */
    function setStrategiesOrder(address[] calldata _newOrder) external onlyStrategyManager {
        uint256 currentLength = strategies.length;

        // Check that array sizes match
        if (_newOrder.length != currentLength) {
            revert ftYieldWrapperInvalidStrategiesOrder();
        }

        // Verify all addresses are existing strategies and check for duplicates
        for (uint256 i = 0; i < currentLength; i++) {
            if (!isStrategy(_newOrder[i])) {
                revert ftYieldWrapperInvalidStrategiesOrder();
            }
            // Check for duplicates
            for (uint256 j = i + 1; j < currentLength; j++) {
                if (_newOrder[i] == _newOrder[j]) {
                    revert ftYieldWrapperInvalidStrategiesOrder();
                }
            }
        }

        // Update strategies array with new order
        for (uint256 i = 0; i < currentLength; i++) {
            strategies[i] = IStrategy(_newOrder[i]);
        }

        emit StrategiesReordered(_newOrder);
    }

    /**
     * @dev Claim yield from a specific strategy
     * @notice Can only be called by registered strategies
     * @param _strategy The strategy to claim yield from
     * @return _yield The amount of yield claimed
     */
    function claimYield(address _strategy) external onlyYieldClaimers returns (uint256 _yield) {
        if (!isStrategy(_strategy)) revert ftYieldWrapperNotStrategy();
        _yield = IStrategy(_strategy).claimYield(treasury);
        if (_yield == 0) revert ftYieldWrapperNoYield();
        emit YieldClaimed(msg.sender, address(token), _yield);
    }

    /**
     * @dev Claim yield from all registered strategies
     * @return _yield The total amount of yield claimed
     */
    function claimYields() external onlyYieldClaimers returns (uint256 _yield) {
        uint256 strategiesLength = strategies.length;
        address _treasury = treasury;
        for (uint256 i = 0; i < strategiesLength; i++) {
            _yield += IStrategy(strategies[i]).claimYield(_treasury);
        }
        if (_yield == 0) revert ftYieldWrapperNoYield();
        emit YieldClaimed(msg.sender, address(token), _yield);
    }

    function sweepIdleYield() external nonReentrant onlyYieldClaimers returns (uint256 amount) {
        uint256 idleBalance = IERC20(token).balanceOf(address(this));
        uint256 liabilities = totalSupply();
        if (idleBalance <= liabilities) revert ftYieldWrapperNoYield();
        amount = idleBalance - liabilities;
        IERC20(token).safeTransfer(treasury, amount);
        emit YieldSwept(msg.sender, address(token), amount);
    }

    function execute(
        address _strategy,
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        onlyYieldClaimers
        returns (bool success, bytes memory result)
    {
        if (!isStrategy(_strategy)) revert ftYieldWrapperNotStrategy();
        return IStrategy(_strategy).execute(to, value, data);
    }

    /**
     * @dev Get the number of registered strategies
     * @return uint The number of strategies
     */
    function numberOfStrategies() external view returns (uint256) {
        return strategies.length;
    }

    // simply a 1:1 mapping of capital provided
    /**
     * @dev Get the total capital managed by the wrapper
     * @notice This is equal to totalSupply() of the wrapper token
     * @return uint The total capital (in underlying token) managed by the wrapper
     */
    function capital() external view returns (uint256) {
        return totalSupply();
    }

    // capital + yield
    function valueOfCapital() public view returns (uint256 _capital) {
        _capital = IERC20(token).balanceOf(address(this));
        uint256 strategiesLength = strategies.length;
        for (uint256 i = 0; i < strategiesLength; i++) {
            _capital += strategies[i].valueOfCapital();
        }
    }

    function yield() public view returns (uint256) {
        uint256 _capital = valueOfCapital();
        uint256 _totalSupply = totalSupply();
        return (_capital > _totalSupply) ? (_capital - _totalSupply) : 0;
    }

    // helper functions for strategy management
    function availableToWithdraw(address strategy) public view returns (uint256 liquidity) {
        // Only consider registered strategies; unrecognized addresses return zero
        if (!isStrategy(strategy)) return 0;
        // Defensive: treat failing strategies as having zero liquidity
        uint256 shares;
        try IStrategy(strategy).balanceOf(address(this)) returns (uint256 sb) {
            shares = sb;
        } catch {
            return 0;
        }
        try IStrategy(strategy).maxAbleToWithdraw(shares) returns (uint256 m) {
            liquidity = m;
        } catch {
            return 0;
        }
    }

    // helper functions for put servicing
    function availableToWithdraw() public view returns (uint256 liquidity) {
        liquidity = IERC20(token).balanceOf(address(this));
        uint256 strategiesLength = strategies.length;
        for (uint256 i = 0; i < strategiesLength; i++) {
            // Defensive view calls
            uint256 shares;
            try strategies[i].balanceOf(address(this)) returns (uint256 sb) {
                shares = sb;
            } catch {
                shares = 0;
            }
            if (shares != 0) {
                try strategies[i].maxAbleToWithdraw(shares) returns (uint256 m) {
                    liquidity += m;
                } catch {
                    // treat as zero
                }
            }
        }
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        // NOTE: returns availability in underlying only (does not count position-token fallback)
        return (availableToWithdraw() >= amount);
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 _liquidity = availableToWithdraw();
        return _liquidity > amount ? amount : _liquidity;
    }

    /**
     * @dev Deposit underlying tokens into the wrapper and receive wrapper tokens
     * @param amount The amount of underlying tokens to deposit
     * @notice Mints wrapper tokens to the depositor based on the amount of underlying tokens deposited
     * @notice we do not support fee on transfer tokens
     * @notice this is simply a 1:1 mapping of capital provided, it does not provide a share
     */
    function deposit(uint256 amount) external nonReentrant onlyPutManagerOrDepositor {
        if (amount == 0) revert ftYieldWrapperInsufficientLiquidity();

        // Circuit breaker: record inflow (fail-open)
        address _cb = circuitBreaker;
        if (_cb != address(0)) {
            uint256 preTvl = valueOfCapital();
            try ICircuitBreaker(_cb).recordInflow(token, amount, preTvl) {} catch {}
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount, address to) external nonReentrant onlyPutManagerOrDepositor {
        // Circuit breaker: check rate limit (fail-open)
        address _cb = circuitBreaker;
        if (_cb != address(0)) {
            uint256 preTvl = valueOfCapital();
            try ICircuitBreaker(_cb).checkAndRecordOutflow(token, amount, preTvl) returns (
                bool allowed, uint256 available
            ) {
                if (!allowed) {
                    revert ftYieldWrapperRateLimitExceeded(amount, available);
                }
            } catch {}
        }

        uint256 initialTarget = amount;
        uint256 remaining = amount;

        // 1) Use idle underlying on the wrapper first (accumulate, transfer at end)
        uint256 idle = IERC20(token).balanceOf(address(this));
        if (idle != 0) {
            uint256 toTake = idle > remaining ? remaining : idle;
            remaining -= toTake;
        }

        // 2) Drain strategies in order
        uint256 _strategiesLength = strategies.length;
        for (uint256 i = 0; i < _strategiesLength && remaining != 0; i++) {
            // Check available liquidity for this strategy (defensive)
            uint256 shareBal;
            try strategies[i].balanceOf(address(this)) returns (uint256 sb) {
                shareBal = sb;
            } catch {
                continue;
            }
            if (shareBal == 0) {
                continue;
            }

            uint256 avail;
            try strategies[i].maxAbleToWithdraw(shareBal) returns (uint256 m) {
                avail = m;
            } catch {
                continue;
            }
            if (avail == 0) {
                continue;
            }

            // Withdraw what we can from this strategy
            uint256 toRequest = avail > remaining ? remaining : avail;
            try strategies[i].withdraw(toRequest) returns (uint256 received) {
                if (received != 0) {
                    // Protect against underflow if strategy returns more than deployed
                    uint256 currentDeployed = deployedToStrategy[address(strategies[i])];
                    uint256 toReduce = received > currentDeployed ? currentDeployed : received;

                    deployedToStrategy[address(strategies[i])] -= toReduce;
                    // Also cap the global deployed reduction
                    if (toReduce > deployed) {
                        deployed = 0;
                    } else {
                        deployed -= toReduce;
                    }
                    // Cap remaining reduction to avoid underflow
                    if (received > remaining) {
                        remaining = 0;
                    } else {
                        remaining -= received;
                    }
                }
            } catch {
                // Skip failing strategies and continue
            }
        }

        uint256 totalDelivered = initialTarget - remaining;
        if (remaining != 0) {
            revert ftYieldWrapperInsufficientLiquidity();
        }

        // Burn shares equal to what was actually delivered (no-op if zero)
        if (totalDelivered != 0) {
            _burn(msg.sender, totalDelivered);
        }

        // Single transfer at end (clamp to exact requested amount)
        // Defensive: in case any strategy returned more than requested,
        // only transfer exactly what was requested overall.
        if (totalDelivered != 0) {
            IERC20(token).safeTransfer(to, totalDelivered);
        }
        emit Withdraw(msg.sender, totalDelivered);
    }

    function withdrawUnderlying(
        uint256 amount,
        address to
    )
        external
        nonReentrant
        onlyPutManagerOrDepositor
    {
        // Circuit breaker: check rate limit (fail-open)
        address _cb = circuitBreaker;
        if (_cb != address(0)) {
            uint256 preTvl = valueOfCapital();
            try ICircuitBreaker(_cb).checkAndRecordOutflow(token, amount, preTvl) returns (
                bool allowed, uint256 available
            ) {
                if (!allowed) {
                    revert ftYieldWrapperRateLimitExceeded(amount, available);
                }
            } catch {}
        }

        uint256 initialTarget = amount;

        uint256 remaining = amount;
        uint256 _strategiesLength = strategies.length;

        if (remaining != 0) {
            for (uint256 i = 0; i < _strategiesLength && remaining != 0; ++i) {
                uint256 shareBal = strategies[i].balanceOf(address(this));
                if (shareBal == 0) continue;

                uint256 toExit = shareBal > remaining ? remaining : shareBal;

                // Try exit-in-kind via the lightweight extension
                // (if strategy doesn't implement, call reverts and we skip)
                try strategies[i].withdrawUnderlying(toExit) returns (uint256 got) {
                    if (got != 0) {
                        // Protect against underflow if more is withdrawn than deployed
                        uint256 currentDeployed = deployedToStrategy[address(strategies[i])];
                        uint256 toReduce = toExit > currentDeployed ? currentDeployed : toExit;

                        deployedToStrategy[address(strategies[i])] -= toReduce;
                        // Also cap the global deployed reduction
                        if (toReduce > deployed) {
                            deployed = 0;
                        } else {
                            deployed -= toReduce;
                        }
                        remaining -= toExit;
                        IERC20(strategies[i].positionToken()).safeTransfer(to, got);
                    }
                } catch {
                    // strategy doesn't support exit-in-position-token or failed; skip
                }
            }
        }
        uint256 totalDelivered = initialTarget - remaining;
        // If enforceExact, we must hit exact target (underlying + position tokens)
        if (remaining != 0) {
            revert ftYieldWrapperInsufficientLiquidity();
        }

        // Burn shares equal to what was actually delivered (no-op if zero)
        if (totalDelivered != 0) {
            _burn(msg.sender, totalDelivered);
        }
        emit WithdrawUnderlying(msg.sender, totalDelivered);
    }

    function availableToDeposit() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @dev Deploy capital to registered strategy
     * @param amount The total amount of underlying tokens to deploy
     * @notice Can only be called by the yield claimer
     */
    function deploy(address strategy, uint256 amount) external nonReentrant onlyYieldClaimer {
        if (!isStrategy(strategy)) revert ftYieldWrapperNotStrategy();
        if (IERC20(token).balanceOf(address(this)) < amount) {
            revert ftYieldWrapperInsufficientLiquidity();
        }
        IERC20(token).forceApprove(address(strategy), amount);
        IStrategy(strategy).deposit(amount);
        deployedToStrategy[strategy] += amount;
        deployed += amount;
        emit Deployed(strategy, amount);
    }

    /**
     * @dev Withdraw capital from registered strategy
     * @param amount The total amount of underlying tokens to withdraw
     * @notice Can only be called by the yield claimer
     */
    function forceWithdrawToWrapper(
        address strategy,
        uint256 amount
    )
        external
        nonReentrant
        onlyYieldClaimer
    {
        if (!isStrategy(strategy)) revert ftYieldWrapperNotStrategy();

        uint256 _withdrawn = IStrategy(strategy).withdraw(amount);

        // Protect against underflow if strategy returns more than deployed
        uint256 currentDeployed = deployedToStrategy[strategy];
        uint256 toReduce = _withdrawn > currentDeployed ? currentDeployed : _withdrawn;

        deployedToStrategy[strategy] -= toReduce;
        // Also cap the global deployed reduction
        if (toReduce > deployed) {
            deployed = 0;
        } else {
            deployed -= toReduce;
        }

        emit WithdrawToWrapper(msg.sender, strategy, _withdrawn);
    }

    function withdrawQueued(
        address strategy,
        uint256 amount
    )
        external
        nonReentrant
        onlyYieldClaimer
        returns (uint256 id)
    {
        if (!isStrategy(strategy)) revert ftYieldWrapperNotStrategy();

        id = IStrategyWithQueue(strategy).withdrawQueued(amount);
        emit QueuedToWrapper(msg.sender, strategy, amount);
    }

    function claimQueued(
        address strategy,
        uint256 id
    )
        external
        nonReentrant
        onlyYieldClaimer
        returns (uint256 received)
    {
        if (!isStrategy(strategy)) revert ftYieldWrapperNotStrategy();

        received = IStrategyWithQueue(strategy).claimQueued(id);

        // Protect against underflow if more is claimed than deployed
        uint256 currentDeployed = deployedToStrategy[strategy];
        uint256 toReduce = received > currentDeployed ? currentDeployed : received;

        deployedToStrategy[strategy] -= toReduce;
        // Also cap the global deployed reduction
        if (toReduce > deployed) {
            deployed = 0;
        } else {
            deployed -= toReduce;
        }

        emit WithdrawToWrapper(msg.sender, strategy, received);
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return IERC20Metadata(token).decimals();
    }
}
