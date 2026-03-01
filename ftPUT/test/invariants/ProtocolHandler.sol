// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {ftYieldWrapper} from "contracts/ftYieldWrapper.sol";
import {CircuitBreaker} from "contracts/cb/CircuitBreaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MaliciousReentrancyReceiver} from "../mocks/MaliciousReentrancyReceiver.sol";

/// @title Protocol Invariant Test Handler
/// @notice Actor contract for stateful fuzzing of the Flying Tulip PUT protocol
/// @dev Performs realistic user actions with bounded inputs for invariant testing
/// @dev Tests all user-facing flows: invest, divest, withdrawFT, and ERC721 transfers
contract ProtocolHandler is Test {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    PutManager public manager;
    pFT public pft;
    ftYieldWrapper public wrapperUSDC;
    ftYieldWrapper public wrapperUSDT;
    ftYieldWrapper public wrapperWBTC;
    ftYieldWrapper public wrapperWSONIC;
    CircuitBreaker public circuitBreaker;
    IERC20 public usdc;
    IERC20 public usdt;
    IERC20 public wbtc;
    IERC20 public wsonic;
    IERC20 public ft;

    // Actor addresses
    address[] public actors;
    address public currentActor;

    // Ghost variables for tracking aggregate state
    uint256 public ghost_totalInvested;
    uint256 public ghost_totalDivested;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_ftAllocatedSum;
    uint256 public ghost_collateralDepositedUSDC;
    uint256 public ghost_collateralDepositedUSDT;
    uint256 public ghost_collateralDepositedWBTC;
    uint256 public ghost_collateralDepositedWSONIC;
    uint256 public ghost_collateralWithdrawnUSDC;
    uint256 public ghost_collateralWithdrawnUSDT;
    uint256 public ghost_collateralWithdrawnWBTC;
    uint256 public ghost_collateralWithdrawnWSONIC;

    // Tracking for active positions
    uint256[] public activePositions;
    mapping(uint256 => bool) public isPositionActive;

    // Call counters for debugging
    uint256 public calls_invest;
    uint256 public calls_withdrawFT;
    uint256 public calls_divest;
    uint256 public calls_divestUnderlying;
    uint256 public calls_transferFrom;
    uint256 public calls_safeTransferFrom;
    uint256 public calls_maliciousInvest;

    // Reentrancy attack tracking
    uint256 public ghost_reentrancyAttempts;
    uint256 public ghost_reentrancySuccesses;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        PutManager _manager,
        pFT _pft,
        ftYieldWrapper _wrapperUSDC,
        ftYieldWrapper _wrapperUSDT,
        ftYieldWrapper _wrapperWBTC,
        ftYieldWrapper _wrapperWSONIC,
        IERC20 _usdc,
        IERC20 _usdt,
        IERC20 _wbtc,
        IERC20 _wsonic,
        IERC20 _ft,
        CircuitBreaker _circuitBreaker,
        address[] memory _actors
    ) {
        manager = _manager;
        pft = _pft;
        wrapperUSDC = _wrapperUSDC;
        wrapperUSDT = _wrapperUSDT;
        wrapperWBTC = _wrapperWBTC;
        wrapperWSONIC = _wrapperWSONIC;
        circuitBreaker = _circuitBreaker;
        usdc = _usdc;
        usdt = _usdt;
        wbtc = _wbtc;
        wsonic = _wsonic;
        ft = _ft;
        actors = _actors;

        // Approve tokens for all actors
        for (uint256 i = 0; i < _actors.length; i++) {
            vm.startPrank(_actors[i]);
            usdc.approve(address(manager), type(uint256).max);
            usdt.approve(address(manager), type(uint256).max);
            wbtc.approve(address(manager), type(uint256).max);
            wsonic.approve(address(manager), type(uint256).max);
            ft.approve(address(manager), type(uint256).max);
            vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ACTOR SELECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Select actor based on seed
    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Handler for invest() - deposit collateral to buy PUT position
    /// @dev Bounds inputs to realistic ranges, tests multiple decimal tokens
    function invest(
        uint256 actorSeed,
        uint256 amountSeed,
        uint256 tokenSeed
    )
        public
        useActor(actorSeed)
    {
        // Only invest if sale is enabled
        if (!manager.saleEnabled()) return;

        // Select token based on seed (0=USDC, 1=USDT, 2=WBTC, 3=wSONIC)
        address token;
        uint256 decimals;
        uint256 minAmount;
        uint256 maxAmount;

        uint256 tokenChoice = bound(tokenSeed, 0, 3);

        if (tokenChoice == 0) {
            token = address(usdc);
            decimals = 6;
            minAmount = 1e6; // $1 USDC
            maxAmount = 100_000e6; // $100k USDC
        } else if (tokenChoice == 1) {
            token = address(usdt);
            decimals = 6;
            minAmount = 1e6; // $1 USDT
            maxAmount = 100_000e6; // $100k USDT
        } else if (tokenChoice == 2) {
            token = address(wbtc);
            decimals = 8;
            minAmount = 1e5; // 0.001 WBTC (~$100 at $100k BTC)
            maxAmount = 10e8; // 10 WBTC (~$1M at $100k BTC)
        } else {
            token = address(wsonic);
            decimals = 18;
            minAmount = 1e18; // 1 wSONIC
            maxAmount = 100_000e18; // 100k wSONIC
        }

        // Check if collateral is accepted
        if (manager.vaults(token) == address(0)) return;

        // Bound amount based on token type and balance
        uint256 balance = IERC20(token).balanceOf(currentActor);
        if (balance == 0) return;

        // Ensure min <= max for bound
        uint256 boundedMax = min(balance, maxAmount);
        if (boundedMax < minAmount) return; // Not enough balance

        uint256 amount = bound(amountSeed, minAmount, boundedMax);

        // Check if we have enough FT liquidity
        uint256 ftAvailable = manager.ftOfferingSupply() - manager.ftAllocated();
        if (ftAvailable < 1000e18) return; // Need at least 1000 FT

        // Check collateral cap
        uint256 cap = manager.collateralCap(token);
        if (cap > 0) {
            uint256 currentSupply = manager.collateralSupply(token);
            if (currentSupply + amount > cap) {
                // Adjust amount to fit within cap
                if (currentSupply >= cap) return;
                amount = cap - currentSupply;
            }
        }

        // Attempt investment
        try manager.invest(token, amount, currentActor, 0, new bytes32[](0)) returns (
            uint256 tokenId
        ) {
            // Track successful investment
            calls_invest++;
            ghost_totalInvested += amount;

            (,, uint96 ftCurrent,,,,,,) = pft.puts(tokenId);
            ghost_ftAllocatedSum += ftCurrent;

            // Track collateral by token type
            if (token == address(usdc)) {
                ghost_collateralDepositedUSDC += amount;
            } else if (token == address(usdt)) {
                ghost_collateralDepositedUSDT += amount;
            } else if (token == address(wbtc)) {
                ghost_collateralDepositedWBTC += amount;
            } else if (token == address(wsonic)) {
                ghost_collateralDepositedWSONIC += amount;
            }

            // Track active position
            activePositions.push(tokenId);
            isPositionActive[tokenId] = true;

            console2.log("INVEST SUCCESS tokenId:", tokenId);
        } catch {
            // Expected failures are OK (insufficient FT, cap reached, etc.)
        }
    }

    /// @notice Handler for withdrawFT() - withdraw FT tokens from position
    function withdrawFT(
        uint256 actorSeed,
        uint256 positionSeed,
        uint256 amountSeed
    )
        public
        useActor(actorSeed)
    {
        // Only withdraw if transferable
        if (!manager.transferable()) return;

        // Select a random active position
        if (activePositions.length == 0) return;
        uint256 posIndex = bound(positionSeed, 0, activePositions.length - 1);
        uint256 tokenId = activePositions[posIndex];

        // Check if position still exists and caller owns it
        try pft.ownerOf(tokenId) returns (address owner) {
            if (owner != currentActor) return;
        } catch {
            // Position burned, remove from active list
            _removePosition(posIndex);
            return;
        }

        // Get current FT balance of position
        (,, uint96 ftCurrent,,,,,,) = pft.puts(tokenId);
        if (ftCurrent == 0) return;

        // Bound withdrawal amount (1% to 100% of current FT)
        uint256 amount = bound(amountSeed, max(1, uint256(ftCurrent) / 100), uint256(ftCurrent));

        // Attempt withdrawal
        try manager.withdrawFT(tokenId, amount) {
            calls_withdrawFT++;
            ghost_totalWithdrawn += amount;

            console2.log("WITHDRAW SUCCESS tokenId:", tokenId);

            // Check if position was burned (ft reached 0)
            try pft.ownerOf(tokenId) {
            // Position still exists
            }
            catch {
                // Position burned
                _removePosition(posIndex);
            }
        } catch {
            // Expected failures are OK
        }
    }

    /// @notice Handler for divest() - exercise PUT option and receive collateral
    function divest(
        uint256 actorSeed,
        uint256 positionSeed,
        uint256 amountSeed
    )
        public
        useActor(actorSeed)
    {
        // Select a random active position
        if (activePositions.length == 0) return;
        uint256 posIndex = bound(positionSeed, 0, activePositions.length - 1);
        uint256 tokenId = activePositions[posIndex];

        // Check if position still exists and caller owns it
        try pft.ownerOf(tokenId) returns (address owner) {
            if (owner != currentActor) return;
        } catch {
            _removePosition(posIndex);
            return;
        }

        // Get current FT balance of position
        (address token,, uint96 ftCurrent,,,,,,) = pft.puts(tokenId);
        if (ftCurrent == 0) return;

        // Bound divest amount (1% to 100% of current FT)
        uint256 amount = bound(amountSeed, max(1, uint256(ftCurrent) / 100), uint256(ftCurrent));

        // Track collateral before
        uint256 balanceBefore = IERC20(token).balanceOf(currentActor);

        // Attempt divestment
        try manager.divest(tokenId, amount) {
            calls_divest++;
            ghost_totalDivested += amount;

            uint256 balanceAfter = IERC20(token).balanceOf(currentActor);
            uint256 collateralReceived = balanceAfter - balanceBefore;

            // Track withdrawn collateral by token type
            if (token == address(usdc)) {
                ghost_collateralWithdrawnUSDC += collateralReceived;
            } else if (token == address(usdt)) {
                ghost_collateralWithdrawnUSDT += collateralReceived;
            } else if (token == address(wbtc)) {
                ghost_collateralWithdrawnWBTC += collateralReceived;
            } else if (token == address(wsonic)) {
                ghost_collateralWithdrawnWSONIC += collateralReceived;
            }

            console2.log("DIVEST SUCCESS tokenId:", tokenId);

            // Check if position was burned
            try pft.ownerOf(tokenId) {
            // Position still exists
            }
            catch {
                _removePosition(posIndex);
            }
        } catch {
            // Expected failures are OK
        }
    }

    /// @notice Handler for divestUnderlying() - exercise PUT and receive underlying tokens
    function divestUnderlying(
        uint256 actorSeed,
        uint256 positionSeed,
        uint256 amountSeed
    )
        public
        useActor(actorSeed)
    {
        // Select a random active position
        if (activePositions.length == 0) return;
        uint256 posIndex = bound(positionSeed, 0, activePositions.length - 1);
        uint256 tokenId = activePositions[posIndex];

        // Check if position still exists and caller owns it
        try pft.ownerOf(tokenId) returns (address owner) {
            if (owner != currentActor) return;
        } catch {
            _removePosition(posIndex);
            return;
        }

        // Get current FT balance of position
        (address token,, uint96 ftCurrent,,,,,,) = pft.puts(tokenId);
        if (ftCurrent == 0) return;

        // Bound divest amount
        uint256 amount = bound(amountSeed, max(1, uint256(ftCurrent) / 100), uint256(ftCurrent));

        // Track collateral before
        uint256 balanceBefore = IERC20(token).balanceOf(currentActor);

        // Attempt divestment
        try manager.divestUnderlying(tokenId, amount) {
            calls_divestUnderlying++;
            ghost_totalDivested += amount;

            uint256 balanceAfter = IERC20(token).balanceOf(currentActor);
            uint256 collateralReceived = balanceAfter - balanceBefore;

            // Track withdrawn collateral by token type
            if (token == address(usdc)) {
                ghost_collateralWithdrawnUSDC += collateralReceived;
            } else if (token == address(usdt)) {
                ghost_collateralWithdrawnUSDT += collateralReceived;
            } else if (token == address(wbtc)) {
                ghost_collateralWithdrawnWBTC += collateralReceived;
            } else if (token == address(wsonic)) {
                ghost_collateralWithdrawnWSONIC += collateralReceived;
            }

            console2.log("DIVEST_UNDERLYING SUCCESS tokenId:", tokenId);

            // Check if position was burned
            try pft.ownerOf(tokenId) {
            // Position still exists
            }
            catch {
                _removePosition(posIndex);
            }
        } catch {
            // Expected failures are OK
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ERC721 TRANSFER HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Handler for transferFrom() - transfer NFT position to another user
    /// @dev Tests if transfers can break invariants or affect position operations
    function transferNFT(
        uint256 fromActorSeed,
        uint256 toActorSeed,
        uint256 positionSeed
    )
        public
        useActor(fromActorSeed)
    {
        // Don't transfer to self
        address toActor = actors[bound(toActorSeed, 0, actors.length - 1)];
        if (toActor == currentActor) return;

        // Select a random active position
        if (activePositions.length == 0) return;
        uint256 posIndex = bound(positionSeed, 0, activePositions.length - 1);
        uint256 tokenId = activePositions[posIndex];

        // Check if position exists and caller owns it
        try pft.ownerOf(tokenId) returns (address owner) {
            if (owner != currentActor) return;
        } catch {
            _removePosition(posIndex);
            return;
        }

        // Attempt transfer
        try pft.transferFrom(currentActor, toActor, tokenId) {
            calls_transferFrom++;
            console2.log("TRANSFER SUCCESS tokenId:", tokenId);

            // Position still active, just different owner
            // New owner should be able to withdraw/divest
        } catch {
            // Expected failures are OK (position may not be transferable yet)
        }
    }

    /// @notice Handler for safeTransferFrom() - safe transfer NFT position
    function safeTransferNFT(
        uint256 fromActorSeed,
        uint256 toActorSeed,
        uint256 positionSeed
    )
        public
        useActor(fromActorSeed)
    {
        // Don't transfer to self
        address toActor = actors[bound(toActorSeed, 0, actors.length - 1)];
        if (toActor == currentActor) return;

        // Select a random active position
        if (activePositions.length == 0) return;
        uint256 posIndex = bound(positionSeed, 0, activePositions.length - 1);
        uint256 tokenId = activePositions[posIndex];

        // Check if position exists and caller owns it
        try pft.ownerOf(tokenId) returns (address owner) {
            if (owner != currentActor) return;
        } catch {
            _removePosition(posIndex);
            return;
        }

        // Attempt safe transfer
        try pft.safeTransferFrom(currentActor, toActor, tokenId) {
            calls_safeTransferFrom++;
            console2.log("SAFE_TRANSFER SUCCESS tokenId:", tokenId);
        } catch {
            // Expected failures are OK
        }
    }

    /// @notice Handler for approve() + transferFrom() - test approval flow
    function approveAndTransfer(
        uint256 fromActorSeed,
        uint256 approvedActorSeed,
        uint256 positionSeed
    )
        public
    {
        // Get owner and approved addresses
        address owner = actors[bound(fromActorSeed, 0, actors.length - 1)];
        address approved = actors[bound(approvedActorSeed, 0, actors.length - 1)];
        if (owner == approved) return;

        // Select a position
        if (activePositions.length == 0) return;
        uint256 posIndex = bound(positionSeed, 0, activePositions.length - 1);
        uint256 tokenId = activePositions[posIndex];

        // Check if position exists and owner owns it
        try pft.ownerOf(tokenId) returns (address actualOwner) {
            if (actualOwner != owner) return;
        } catch {
            _removePosition(posIndex);
            return;
        }

        // Owner approves the approved address
        vm.prank(owner);
        try pft.approve(approved, tokenId) {
            // Approved address transfers to themselves or another actor
            vm.prank(approved);
            try pft.transferFrom(owner, approved, tokenId) {
                calls_transferFrom++;
                console2.log("APPROVE_TRANSFER SUCCESS tokenId:", tokenId);
            } catch {
                // Expected failures
            }
        } catch {
            // Expected failures
        }
    }

    /*//////////////////////////////////////////////////////////////
                    REENTRANCY ATTACK HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Handler for testing reentrancy via malicious ERC721 receiver
    /// @dev Creates a malicious contract that attempts to reenter during onERC721Received
    function maliciousInvest(
        uint256 actorSeed,
        uint256 amountSeed,
        uint256 tokenSeed,
        uint256 attackTypeSeed
    )
        public
        useActor(actorSeed)
    {
        // Only invest if sale is enabled
        if (!manager.saleEnabled()) return;

        // Select token based on seed
        address token;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 tokenChoice = bound(tokenSeed, 0, 3);

        if (tokenChoice == 0) {
            token = address(usdc);
            minAmount = 1e6;
            maxAmount = 10_000e6;
        } else if (tokenChoice == 1) {
            token = address(usdt);
            minAmount = 1e6;
            maxAmount = 10_000e6;
        } else if (tokenChoice == 2) {
            token = address(wbtc);
            minAmount = 1e5;
            maxAmount = 1e8;
        } else {
            token = address(wsonic);
            minAmount = 1e18;
            maxAmount = 10_000e18;
        }

        // Check if collateral is accepted
        if (manager.vaults(token) == address(0)) return;

        // Check balance
        uint256 balance = IERC20(token).balanceOf(currentActor);
        if (balance == 0) return;

        // Select attack type first to determine funding needs
        uint256 attackTypeChoice = bound(attackTypeSeed, 0, 5);

        // For INVEST_AGAIN attack, we need 2x the amount
        uint256 requiredAmount = (attackTypeChoice == 5) ? 2 : 1;

        uint256 boundedMax = min(balance / requiredAmount, maxAmount);
        if (boundedMax < minAmount) return;

        uint256 amount = bound(amountSeed, minAmount, boundedMax);

        // Check FT availability
        uint256 ftAvailable = manager.ftOfferingSupply() - manager.ftAllocated();
        if (ftAvailable < 1000e18) return;

        // Deploy malicious receiver from current actor's address
        MaliciousReentrancyReceiver attacker =
            new MaliciousReentrancyReceiver(address(manager), address(pft));

        attacker.setAttackType(MaliciousReentrancyReceiver.AttackType(attackTypeChoice));

        // Fund the attacker contract with tokens
        if (attackTypeChoice == 5) {
            // INVEST_AGAIN attack needs 2x amount
            attacker.setToken(token);
            IERC20(token).transfer(address(attacker), amount * 2);
        } else {
            // Other attacks need 1x amount
            IERC20(token).transfer(address(attacker), amount);
        }

        // Track before state
        uint256 beforeAttempts = attacker.reentrancyAttempts();

        // Attacker tries to invest
        vm.stopPrank(); // Stop actor prank
        vm.startPrank(address(attacker));

        try attacker.investAndAttack(token, amount) {
            calls_maliciousInvest++;

            // Check if reentrancy was attempted and succeeded
            uint256 afterAttempts = attacker.reentrancyAttempts();
            ghost_reentrancyAttempts += (afterAttempts - beforeAttempts);

            if (attacker.attackSucceeded()) {
                // Attack type 4 is TRANSFER - this is safe (state updated before callback)
                if (attackTypeChoice == 4) {
                    console2.log("Transfer during mint succeeded (safe behavior)");
                    console2.log("  Attack type:", attackTypeChoice);
                } else {
                    // Critical: other attack types should NOT succeed
                    ghost_reentrancySuccesses++;
                    console2.log("REENTRANCY ATTACK SUCCEEDED - CRITICAL!");
                    console2.log("  Attack type:", attackTypeChoice);
                }
            } else if (afterAttempts > beforeAttempts) {
                console2.log("Reentrancy blocked successfully");
                console2.log("  Attack type:", attackTypeChoice);
                console2.log("  Failure reason:", attacker.failureReason());
            }

            // Track the position if created
            uint256 receivedTokenId = attacker.receivedTokenId();
            if (receivedTokenId > 0) {
                try pft.ownerOf(receivedTokenId) returns (address owner) {
                    if (owner == address(attacker)) {
                        activePositions.push(receivedTokenId);
                        isPositionActive[receivedTokenId] = true;
                    }
                } catch {
                    // Position doesn't exist
                }
            }
        } catch {
            // Expected failures
        }

        vm.stopPrank();
        vm.startPrank(currentActor); // Resume actor prank
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Remove position from active tracking
    function _removePosition(uint256 index) internal {
        uint256 tokenId = activePositions[index];
        isPositionActive[tokenId] = false;

        // Swap with last and pop
        activePositions[index] = activePositions[activePositions.length - 1];
        activePositions.pop();
    }

    /// @notice Helper to get minimum of two numbers
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Helper to get maximum of two numbers
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get number of active positions
    function getActivePositionCount() external view returns (uint256) {
        return activePositions.length;
    }

    /// @notice Get all active positions
    function getActivePositions() external view returns (uint256[] memory) {
        return activePositions;
    }

    /// @notice Get call statistics
    function getCallStats()
        external
        view
        returns (
            uint256 investCalls,
            uint256 withdrawCalls,
            uint256 divestCalls,
            uint256 divestUnderlyingCalls,
            uint256 transferCalls,
            uint256 safeTransferCalls
        )
    {
        return (
            calls_invest,
            calls_withdrawFT,
            calls_divest,
            calls_divestUnderlying,
            calls_transferFrom,
            calls_safeTransferFrom
        );
    }

    /// @notice Get ghost variable summary
    function getGhostSummary()
        external
        view
        returns (
            uint256 totalInvested,
            uint256 totalDivested,
            uint256 totalWithdrawn,
            uint256 ftAllocated,
            uint256 usdcDeposited,
            uint256 usdtDeposited,
            uint256 wbtcDeposited,
            uint256 wsonicDeposited,
            uint256 usdcWithdrawn,
            uint256 usdtWithdrawn,
            uint256 wbtcWithdrawn,
            uint256 wsonicWithdrawn
        )
    {
        return (
            ghost_totalInvested,
            ghost_totalDivested,
            ghost_totalWithdrawn,
            ghost_ftAllocatedSum,
            ghost_collateralDepositedUSDC,
            ghost_collateralDepositedUSDT,
            ghost_collateralDepositedWBTC,
            ghost_collateralDepositedWSONIC,
            ghost_collateralWithdrawnUSDC,
            ghost_collateralWithdrawnUSDT,
            ghost_collateralWithdrawnWBTC,
            ghost_collateralWithdrawnWSONIC
        );
    }

    /// @notice Get reentrancy attack statistics
    function getReentrancyStats()
        external
        view
        returns (uint256 attempts, uint256 successes, uint256 maliciousCalls)
    {
        return (ghost_reentrancyAttempts, ghost_reentrancySuccesses, calls_maliciousInvest);
    }
}
