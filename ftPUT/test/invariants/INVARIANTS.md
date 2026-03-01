# Protocol Invariants - Flying Tulip PUT

**Purpose**: This document catalogs all protocol invariants identified for the Flying Tulip PUT protocol, their implementation status, and testing coverage.

**Target Audience**: Developers, Security Auditors, Protocol Reviewers

**Last Updated**: 2025-11-28

---

## Table of Contents

1. [Protocol-Wide Invariants](#1-protocol-wide-invariants)
2. [pFT.sol Invariants](#2-pft-invariants)
3. [PutManager.sol Invariants](#3-putmanager-invariants)
4. [ftYieldWrapper.sol Invariants](#4-ftyieldwrapper-invariants)
5. [CircuitBreaker.sol Invariants](#5-circuitbreaker-invariants)
6. [Implementation Status Summary](#6-implementation-status-summary)
7. [Test Coverage](#7-test-coverage)

---

## 1. Protocol-Wide Invariants

### INV-PROTOCOL-1: FT Token Conservation ✅ IMPLEMENTED

**Description**: Total FT tokens allocated to positions must never exceed the offering supply.

**Formula**:
```solidity
ftAllocated <= ftOfferingSupply (at all times)
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_ftAllocated_lte_ftOfferingSupply()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)

**Enforcement Points**:
- After `invest()` in PutManager (increases ftAllocated)
- After `withdrawFT()` in PutManager (decreases ftAllocated)
- After `divest()` in PutManager (decreases ftAllocated)

**Violation Impact**: Protocol could over-allocate FT tokens, leading to insolvency when users attempt to withdraw.

---

### INV-PROTOCOL-2: Collateral Balance Reconciliation ✅ IMPLEMENTED

**Description**: Total collateral in vaults must equal the sum of all position collateral.

**Formula**:
```solidity
For each token:
  wrapper.totalSupply() >= collateralSupply[token] - capitalDivesting[token]
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_collateralSupply_matches_vaults()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Tokens**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- After `invest()` (deposits to vault)
- After `divest()` / `divestUnderlying()` (withdraws from vault)
- After `withdrawDivestedCapital()` by msig

**Violation Impact**: Collateral mismatch could lead to inability to honor divest requests.

---

### INV-PROTOCOL-3: Position-to-Collateral Mapping ✅ IMPLEMENTED

**Description**: Every active pFT NFT must have valid collateral backing.

**Formula**:
```solidity
For each tokenId where pFT exists:
  puts[tokenId].amountRemaining <= amount (original deposit)
  puts[tokenId].ft <= puts[tokenId].ft_bought
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_positionToCollateralMapping()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)

**Enforcement Points**:
- After `withdrawFT()` in pFT (decreases amountRemaining)
- After `divest()` in pFT (decreases amountRemaining)
- After `mint()` in pFT (sets initial values)

**Violation Impact**: Users could extract more collateral than originally deposited.

---

### INV-PROTOCOL-4: Capital Divesting Tracking ✅ IMPLEMENTED

**Description**: Capital marked for divestment must not exceed collateral supply.

**Formula**:
```solidity
For each token:
  capitalDivesting[token] <= collateralSupply[token]
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_capitalDivesting_lte_collateralSupply()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Tokens**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- After `withdrawFT()` (increases capitalDivesting)
- After `withdrawDivestedCapital()` (decreases capitalDivesting)

**Violation Impact**: Accounting mismatch could allow msig to withdraw more than entitled.

---

### Custom: No Collateral Leak ✅ IMPLEMENTED

**Description**: Total collateral withdrawn cannot exceed total deposited across all operations.

**Formula**:
```solidity
For each token:
  totalWithdrawn <= totalDeposited
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_noCollateralLeak()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tracked via**: Ghost variables in ProtocolHandler

**Enforcement Points**:
- All invest operations (track deposits)
- All divest operations (track withdrawals)
- All withdrawFT operations (track withdrawals)

**Violation Impact**: Value leak - protocol loses funds to users without proper backing.

---

## 2. pFT Invariants

### INV-PFT-1: FT Amount Accounting ✅ IMPLEMENTED

**Description**: FT token accounting must remain consistent across all operations.

**Formula**:
```solidity
For each tokenId:
  puts[tokenId].withdrawn + puts[tokenId].burned + puts[tokenId].ft == puts[tokenId].ft_bought
  puts[tokenId].ft <= puts[tokenId].ft_bought
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_pFT_ftAccounting()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)

**Enforcement Points**:
- After `withdrawFT()` (decreases ft, increases withdrawn)
- After `divest()` (decreases ft, increases burned)

**Violation Impact**: FT tokens could be created or destroyed improperly.

---

### INV-PFT-2: NFT Burn on Zero FT ✅ IMPLEMENTED

**Description**: When FT balance reaches zero, NFT must be burned and collateral zeroed.

**Formula**:
```solidity
For each tokenId:
  If NFT exists => ft > 0
  If NFT burned => ft == 0 AND amountRemaining == 0
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_pFT_burnOnZeroFT()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)

**Enforcement Points**:
- After `withdrawFT()` when ft reaches 0
- After `divest()` when ft reaches 0

**Violation Impact**: Orphaned collateral that cannot be claimed, or zombie NFTs with no value.

---

### INV-PFT-3: Collateral Depletion Consistency ✅ IMPLEMENTED

**Description**: Remaining collateral must never exceed original deposit.

**Formula**:
```solidity
For each tokenId:
  puts[tokenId].amountRemaining <= puts[tokenId].amount (original deposit)
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_pFT_collateralBounds()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)

**Enforcement Points**:
- After `withdrawFT()` (decreases amountRemaining)
- After `divest()` (decreases amountRemaining)

**Violation Impact**: Users could withdraw more collateral than deposited.

---

### INV-PFT-4: PutManager Exclusive Access ⚠️ NOT TESTED (Contract-Level)

**Description**: Only the designated PutManager can call state-changing functions.

**Formula**:
```solidity
All mint/withdraw/divest/burn operations must come from putManager address
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **Contract**: Enforced by `onlyPutManager` modifier on all state-changing functions
- **Invariant Test**: Not applicable (access control tested via unit tests)

**Enforcement Points**:
- All functions with `onlyPutManager` modifier

**Violation Impact**: Unauthorized minting/burning of NFTs, collateral theft.

**Note**: This is enforced at the contract level via access control modifiers. Invariant tests focus on state consistency rather than access control.

---

## 3. PutManager Invariants

### INV-PM-1: Collateral Cap Enforcement ✅ IMPLEMENTED

**Description**: Total collateral supply must respect configured caps.

**Formula**:
```solidity
For each token with collateralCap[token] > 0:
  collateralSupply[token] <= collateralCap[token]
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_collateralCaps_respected()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Tokens**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- Before accepting deposits in `_invest()`

**Violation Impact**: Protocol could exceed risk limits for specific collateral types.

---

### INV-PM-2: Oracle Price Consistency ✅ IMPLEMENTED

**Description**: Strike prices stored in positions must be reasonable and within expected bounds.

**Formula**:
```solidity
For each position:
  0 < strike <= $10,000,000 (in 1e8 scale)
  0.001 <= ftPerUSD <= 10,000 (in 1e8 scale)
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_oraclePriceConsistency()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Additional**: Logs warnings when prices deviate >50% from current oracle

**Enforcement Points**:
- During `_invest()` when calling `getAssetFTPrice()`

**Violation Impact**: Incorrect strike prices could lead to unfair PUT valuations.

**Note**: Exact oracle price matching at investment time is verified via unit tests. Invariant test validates stored prices remain reasonable.

---

### INV-PM-3: Transferability State Machine ✅ IMPLEMENTED

**Description**: Position transfers respect the transferable flag state.

**Formula**:
```solidity
If !transferable:
  withdrawFT() should be blocked
If always:
  divest() operations work (PUT exercise allowed anytime)
```

**Criticality**: 🟡 MEDIUM

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_transferabilityStateConsistent()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tracks**: withdrawFT and divest call counts via ghost variables

**Enforcement Points**:
- `withdrawFT()` checks transferable flag
- `divest()` / `divestUnderlying()` ignore transferable

**Violation Impact**: Users could bypass intended transfer restrictions.

**Note**: The invariant verifies handler behavior consistency. Actual enforcement is contract-level via `requireTransferable` modifier.

---

### INV-PM-4: Sale State Enforcement ⚠️ NOT TESTED (Contract-Level)

**Description**: New investments only allowed when saleEnabled is true.

**Formula**:
```solidity
_invest() reverts if !saleEnabled
```

**Criticality**: 🟡 MEDIUM

**Implementation**:
- **Contract**: Enforced by `requireSaleEnabled` modifier
- **Invariant Test**: Not applicable (tested via unit tests)

**Enforcement Points**:
- First check in `_invest()`

**Violation Impact**: Investments accepted when sale should be closed.

**Note**: This is a state gate tested at the contract level. Handler respects the flag in invariant tests.

---

### INV-PM-5: Pricing Formula Consistency ✅ EXTENSIVELY TESTED

**Description**: FT-to-collateral and collateral-to-FT conversions must be mathematical inverses.

**Formula**:
```solidity
collateralFromFT(ftFromCollateral(x, params), params) ≈ x (within precision bounds)
ftFromCollateral(collateralFromFT(y, params), params) ≈ y (within precision bounds)
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/fuzz/PricingPrecisionFuzz.t.sol`
- **Tests**: 13 comprehensive fuzz tests
- **Runs per test**: 256
- **Status**: ✅ All passing
- **Coverage**:
  - Collateral→FT→Collateral direction (0.01% tolerance)
  - FT→Collateral→FT direction (0.5% tolerance, skips dust)
  - Multi-decimal tokens (USDC:6, WBTC:8, wSONIC:18)
  - Strike ranges: $0.01 to $10,000
  - Edge cases with dust amounts

**Additional Testing**:
- **File**: `test/fuzz/FTRoundTripProof.t.sol`
- **Purpose**: Mathematical proof that users cannot gain from round-trips
- **Result**: 0 exploitable cases found in 265 fuzz runs

**Enforcement Points**:
- All conversions in `invest()`, `withdrawFT()`, `divest()`

**Violation Impact**: Precision loss could be exploited to drain protocol funds.

**Note**: Extensive testing shows ALL precision loss favors the protocol. Users always lose or break even.

---

### INV-PM-6: Msig Rotation Timelock ⚠️ NOT TESTED (Unit Test Coverage)

**Description**: Msig changes must respect timelock delay.

**Formula**:
```solidity
acceptMsig() only succeeds if:
  block.timestamp >= delayMsig
  msg.sender == nextMsig
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **Contract**: Enforced in `acceptMsig()` function
- **Invariant Test**: Not applicable (time-based test)

**Enforcement Points**:
- `acceptMsig()` function checks

**Violation Impact**: Malicious msig change without timelock protection.

**Note**: Time-based invariants are difficult to test in stateful fuzzing. Covered by unit tests.

---

### INV-PM-7: ACL Whitelist Enforcement ⚠️ NOT TESTED (Feature Not Enabled)

**Description**: If ACL is set, investments must pass whitelist checks.

**Formula**:
```solidity
If ftACL != address(0):
  ftACL.isWhitelisted(payer, token, proofAmount, proofWL) must return true
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **Contract**: Enforced in early `_invest()` flow
- **Invariant Test**: Not tested (ACL not configured in test setup)

**Enforcement Points**:
- Early in `_invest()` flow

**Violation Impact**: Bypassing access control restrictions.

**Note**: Invariant tests run with ACL disabled. Should be tested when ACL is deployed.

---

## 4. ftYieldWrapper Invariants

### INV-YW-1: Deployed Capital Tracking ✅ IMPLEMENTED

**Description**: Deployed capital accounting must be accurate across all strategies.

**Formula**:
```solidity
deployed == sum(deployedToStrategy[strategy] for all strategies)
deployed <= totalSupply()
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_wrapper_deployedCapitalTracking()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Wrappers**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- After `deploy()` to strategy
- After `forceWithdrawToWrapper()` / `withdraw()` / `withdrawUnderlying()`

**Violation Impact**: Capital tracking mismatch could lead to stuck funds or over-withdrawal.

---

### INV-YW-2: Share Token Conservation ✅ IMPLEMENTED

**Description**: Total supply must not exceed capital value.

**Formula**:
```solidity
totalSupply() <= valueOfCapital()
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_wrapper_sharesLteValue()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Wrappers**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- After `deposit()` (mint shares)
- After `withdraw()` / `withdrawUnderlying()` (burn shares)

**Violation Impact**: Shares could represent more value than actual capital, leading to bank run scenarios.

---

### INV-YW-3: Yield Calculation ✅ IMPLEMENTED

**Description**: Yield must equal the difference between capital value and liabilities.

**Formula**:
```solidity
yield() == valueOfCapital() - totalSupply()
yield() >= 0 (never negative)
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_wrapper_yieldCalculation()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Wrappers**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- `sweepIdleYield()` checks this
- Should hold after any operation

**Violation Impact**: Incorrect yield calculation could lead to over-claiming or under-reporting.

---

### INV-YW-4: Strategy Registration ⏳ PLANNED

**Description**: Operations on strategies only allowed for registered strategies.

**Formula**:
```solidity
For any strategy operation:
  isStrategy(strategy) must return true
  All strategies with deployedToStrategy[strategy] > 0 are registered
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **Status**: ⏳ Not yet implemented
- **Planned**: Add to ProtocolInvariants.t.sol

**Enforcement Points**:
- All functions operating on strategies check `isStrategy()`

**Violation Impact**: Operations on unregistered strategies could bypass safety checks.

---

### INV-YW-5: Withdrawal Priority Order ⚠️ NOT TESTED (Logic Flow)

**Description**: Withdrawals drain idle balance first, then strategies in order.

**Formula**:
```solidity
withdraw() first uses IERC20(token).balanceOf(this)
Then drains strategies[0], strategies[1], ... in sequence
```

**Criticality**: 🟡 MEDIUM

**Implementation**:
- **Contract**: Enforced in withdrawal logic
- **Invariant Test**: Not applicable (ordering verification requires tracing)

**Enforcement Points**:
- `withdraw()` logic flow
- `withdrawUnderlying()` logic flow

**Violation Impact**: Suboptimal withdrawal strategy, potentially higher gas costs.

**Note**: Order verification requires detailed execution tracing. Better suited for integration tests.

---

### INV-YW-6: PutManager/Depositor Exclusive Access ⚠️ NOT TESTED (Contract-Level)

**Description**: Only putManager or depositor can deposit/withdraw.

**Formula**:
```solidity
deposit(), withdraw(), withdrawUnderlying() restricted to putManager || depositor
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **Contract**: Enforced by `onlyPutManagerOrDepositor` modifier
- **Invariant Test**: Not applicable (access control)

**Enforcement Points**:
- `onlyPutManagerOrDepositor` modifier on entry points

**Violation Impact**: Unauthorized deposits/withdrawals.

**Note**: Access control tested via unit tests, not stateful invariant tests.

---

### INV-YW-7: Role Change Multi-Sig ⚠️ NOT TESTED (Governance)

**Description**: Critical role changes require confirmation from other roles.

**Formula**:
```solidity
yieldClaimer change requires confirmYieldClaimer() from treasury OR strategyManager
strategyManager change requires confirmStrategyManager() from treasury OR yieldClaimer
treasury change requires confirmTreasury() from strategyManager OR yieldClaimer
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **Contract**: Enforced in confirmation functions
- **Invariant Test**: Not applicable (governance flow)

**Enforcement Points**:
- `confirmYieldClaimer()`, `confirmStrategyManager()`, `confirmTreasury()`

**Violation Impact**: Single point of failure for critical role changes.

**Note**: Governance flows tested via unit tests, not stateful invariants.

---

### INV-YW-8: Strategy Timelock ⚠️ NOT TESTED (Unit Test Coverage)

**Description**: New strategies must wait for timelock before confirmation.

**Formula**:
```solidity
confirmStrategy() only succeeds if block.timestamp >= delayStrategy
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **Contract**: Enforced in `confirmStrategy()` checks
- **Invariant Test**: Not applicable (time-based)

**Enforcement Points**:
- `confirmStrategy()` checks

**Violation Impact**: Malicious strategy deployment without review period.

**Note**: Time-based invariants tested via unit tests.

---

## 5. CircuitBreaker Invariants

### INV-CB-1: Main Buffer Bounds ✅ IMPLEMENTED

**Description**: The main buffer never exceeds its configured cap based on TVL and max draw rate.

**Formula**:
```solidity
For each asset:
  mainBuffer <= (currentTVL * maxDrawRateWad) / 1e18
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_cb_mainBufferNeverExceedsCap()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Assets**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- After `recordInflow()` (main buffer replenishment)
- After `checkAndRecordOutflow()` (main buffer consumption)
- During time-based replenishment in `_updateBuffers()`

**Violation Impact**: Buffer overflow could allow unlimited withdrawals, bypassing rate limits entirely.

---

### INV-CB-2: Elastic Buffer Non-Negative ✅ IMPLEMENTED

**Description**: The elastic buffer must always be >= 0 (verified for state consistency).

**Formula**:
```solidity
For each asset:
  elasticBuffer >= 0
```

**Criticality**: 🟠 HIGH

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_cb_elasticBufferNonNegative()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Assets**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- After `recordInflow()` (elastic buffer increase)
- After `checkAndRecordOutflow()` (elastic buffer consumption)
- During time-based decay in `_updateBuffers()`

**Violation Impact**: Negative buffer would indicate state corruption and incorrect capacity calculations.

**Note**: While uint256 prevents negative values at the type level, this invariant verifies state consistency after complex operations.

---

### INV-CB-3: Withdrawal Capacity Consistency ✅ IMPLEMENTED

**Description**: The withdrawal capacity must equal the sum of main and elastic buffers.

**Formula**:
```solidity
For each asset:
  withdrawalCapacity(asset, tvl) == mainBuffer + elasticBuffer
```

**Criticality**: 🔴 CRITICAL

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_cb_withdrawalCapacityConsistent()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)
- **Tested Assets**: USDC, USDT, WBTC, wSONIC

**Enforcement Points**:
- `withdrawalCapacity()` view function
- After any buffer state update

**Violation Impact**: Incorrect capacity calculation could allow either too many or too few withdrawals.

---

### INV-CB-4: CircuitBreaker State Consistency ✅ IMPLEMENTED

**Description**: CircuitBreaker remains active with stable configuration during normal operations.

**Formula**:
```solidity
isActive() == true (not paused)
maxDrawRateWad == 5e16 (5%)
mainWindow == 4 hours
elasticWindow == 2 hours
```

**Criticality**: 🟡 MEDIUM

**Implementation**:
- **File**: `test/invariants/ProtocolInvariants.t.sol`
- **Function**: `invariant_cb_stateConsistency()`
- **Status**: ✅ Passing (64 runs, 32,000 calls)

**Enforcement Points**:
- Verified at every invariant check
- Configuration should remain stable unless admin explicitly updates

**Violation Impact**: Unexpected configuration changes could weaken or break rate limiting.

**Note**: This invariant verifies the CB is not unexpectedly paused or misconfigured during fuzzing.

---

## 6. Implementation Status Summary

### By Criticality

**🔴 CRITICAL (11 total)**
- ✅ Implemented: 9
- ⏳ Planned: 1 (INV-YW-4)
- ⚠️ Contract-Level: 1 (INV-PFT-4, INV-YW-6)

**🟠 HIGH (11 total)**
- ✅ Implemented: 7
- ⚠️ Not Tested: 4 (access control, time-based, governance)

**🟡 MEDIUM (4 total)**
- ✅ Implemented: 2
- ⚠️ Not Tested: 2 (logic flow, state gates)

### By Status

| Status | Count | Description |
|--------|-------|-------------|
| ✅ Implemented & Passing | 18 | Actively tested in invariant suite |
| ⏳ Planned | 1 | Identified but not yet implemented |
| ⚠️ Contract-Level | 8 | Enforced by contract, tested via unit tests |

**Total Invariants Identified**: 27

---

## 7. Test Coverage

### Invariant Test Suite

**File**: `test/invariants/ProtocolInvariants.t.sol`

**Configuration**:
- Runs per invariant: 64
- Calls per run: 500 (32,000 total per invariant)
- Total invariants: 18
- Handler functions: 6 (invest, divest, divestUnderlying, withdrawFT, transferNFT, safeTransferNFT)
- Tokens tested: USDC (6 decimals), USDT (6 decimals), WBTC (8 decimals), wSONIC (18 decimals)
- Actors: 5 users with funded accounts
- CircuitBreaker: Enabled with 5% rate, 4h main window, 2h elastic window
- Total test duration: ~46 seconds

**Results**: ✅ All 18 invariants passing across all runs

### Pricing Precision Test Suite

**File**: `test/fuzz/PricingPrecisionFuzz.t.sol`

**Configuration**:
- Tests: 13
- Runs per test: 256
- Focus: Round-trip precision, edge cases, multi-decimal tokens
- Dust handling: Skips scenarios with intermediate collateral < $0.01

**Key Findings**:
- ✅ Precision loss always favors protocol
- ✅ Zero user gains across 3,328 test runs (13 × 256)
- ✅ Production-safe bounds: Strike $0.01 to $10,000, amounts > $0.01
- ✅ Extended bounds verified: Strike $0.00000001 to $1,000,000 (see LOW-STRIKE-SECURITY-AUDIT.md)

### Additional Security Tests

**Files**:
- `test/fuzz/DustMathAnalysis.t.sol` - Dust amount security (4 tests, all passing)
- `test/fuzz/FTRoundTripProof.t.sol` - Mathematical proofs (4 tests, 265 fuzz runs, 0 exploits)
- `test/fuzz/LowStrikeSecurityTest.t.sol` - Low strike security (5 tests, 528 runs, 0 issues)

**Documentation**:
- `DUST-AMOUNT-SECURITY-ANALYSIS.md` - Comprehensive dust analysis
- `LOW-STRIKE-SECURITY-AUDIT.md` - Low strike security audit
- `FT-COLLATERAL-FT-ANALYSIS.md` - FT round-trip analysis
- `DUST-COLLATERAL-TEST-STRATEGY.md` - Test strategy for dust scenarios

---

## 7. Audit Recommendations

### For Auditors

1. **Focus Areas**:
   - ✅ Pricing precision and round-trip conversions are extensively tested
   - ✅ Collateral accounting invariants have comprehensive coverage
   - ⚠️ Access control and governance flows rely on contract-level enforcement (verify modifiers)
   - ⚠️ Time-based invariants (timelocks) require manual verification

2. **High-Value Review Targets**:
   - Multi-decimal token support (6, 8, 18 decimals tested)
   - Strategy deployment and withdrawal logic in ftYieldWrapper
   - Capital divesting flow and msig withdrawal rights
   - Oracle price consistency during volatile market conditions

3. **Test Gaps** (Not Suitable for Stateful Fuzzing):
   - Access control modifiers (unit test coverage)
   - Time-based timelocks (unit test coverage)
   - Governance multi-sig flows (integration test coverage)
   - ACL whitelist enforcement (not configured in test environment)

### For Developers

1. **Adding New Invariants**:
   - Add to `ProtocolInvariants.t.sol`
   - Follow naming convention: `invariant_<category>_<description>()`
   - Document in this file with status and criticality
   - Ensure handler in `ProtocolHandler.sol` covers necessary actions

2. **Modifying Contracts**:
   - Run full invariant suite: `forge test --match-contract ProtocolInvariantsTest`
   - Run pricing tests: `forge test --match-contract PricingPrecisionFuzzTest`
   - Verify all 14 invariants still pass after changes
   - Update this documentation if adding new state variables or operations

3. **Performance Benchmarks**:
   - Full invariant suite: ~47 seconds
   - Pricing tests: ~2 seconds
   - CI should run both test suites on every PR

---

## 8. References

### Test Files
- `test/invariants/ProtocolInvariants.t.sol` - Main invariant test suite
- `test/invariants/ProtocolHandler.sol` - Fuzzing handler with ghost variables
- `test/fuzz/PricingPrecisionFuzz.t.sol` - Pricing precision tests
- `test/fuzz/FTRoundTripProof.t.sol` - Mathematical proof tests
- `test/fuzz/LowStrikeSecurityTest.t.sol` - Low strike security tests
- `test/fuzz/DustMathAnalysis.t.sol` - Dust amount security tests

### Documentation
- `testing-security-plan.md` - Original security testing plan
- `DUST-AMOUNT-SECURITY-ANALYSIS.md` - Dust amount security analysis
- `LOW-STRIKE-SECURITY-AUDIT.md` - Low strike security audit report
- `FT-COLLATERAL-FT-ANALYSIS.md` - FT round-trip precision analysis
- `DUST-COLLATERAL-TEST-STRATEGY.md` - Dust testing strategy
- `PRICING-PRECISION-TEST-RESOLUTION.md` - Pricing test fixes and resolutions

### Contracts
- `contracts/pFT.sol` - ERC721 PUT position NFT
- `contracts/PutManager.sol` - Core PUT logic
- `contracts/ftYieldWrapper.sol` - Yield-bearing wrapper

---

**Document Version**: 1.0
**Status**: Active
**Maintained By**: Protocol Development Team
