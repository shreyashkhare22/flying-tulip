# AGENTS.md

This document gives agent models (like you) practical guidance for making safe, correct, and minimal changes in this repository. It captures project conventions, architecture, invariants, and how to run and extend tests.

## Scope & Goals

- Primary domain: on‑chain options “PUT” flow with interest‑bearing collateral.
- Core guarantees:
  - Principal is protected (no yield leakage from user capital).
  - Yield accrues in strategies and is periodically sent to the treasury.
  - Users can: buy a `pFT` NFT during the offering, later either withdraw FT (invalidate the put, capital goes to msig) or execute the put (burn FT and receive underlying back).
- You must preserve economic safety and non‑reentrancy when editing.

## Repository Layout

- `contracts/`
  - `PutManager.sol` — orchestrates offering, NFT flow, collateral registry, and user actions.
  - `pFT.sol` — ERC721Enumerable PUT token (upgradeable pattern via initializer).
  - `ftYieldWrapper.sol` — single‑asset wrapper that mints 1:1 “shares” for principal, coordinates strategies, and handles withdrawals.
  - `interfaces/` — canonical interfaces. Do not diverge signatures casually.
  - `strategies/` — strategy adapters (e.g., `AaveStrategy.sol`). They hold position tokens and expose a uniform API.
- `test/`
  - Foundry tests (unit/integration) and comprehensive mocks in `test/mocks/`.
- `script/` — deployment helpers.

## Versions & Libraries

- Solidity: `^0.8.30` (OZ v5). Use OZ utilities such as `ReentrancyGuardTransient`, `SafeERC20`, and `Math`.
- Foundry for testing: `forge build`, `forge test` (install Foundry toolchain locally when running tests).

## Core Contract Responsibilities

### PutManager
- States: `IN_PUB_OFFERING` → `AFTER_PUB_OFFERING`.
- Invest (during offering):
  - Pulls user collateral, deposits into the wrapper (which mints wrapper shares 1:1 to `PutManager`).
  - Mints `pFT` to the user and accounts FT allocation under caps and price bounds.
- Exit (during offering): burns NFT and returns full collateral via wrapper exact withdraw to the user.
- After offering:
  - `withdrawFT`: user redeems FT, PUT becomes invalid; underlying amount is earmarked and msig later pulls the capital to itself.
  - `divest`: executes PUT by burning FT and withdrawing exact underlying to the user.
  - `divestUnderlying`: executes PUT but returns position tokens (in‑kind) to the user via the wrapper.
- Governance: manages collateral registry, price bounds, caps, and msig/configurator.

### ftYieldWrapper
- ERC20 “shares” equal to principal provided (1:1, no yield embedded).
- Deploys capital to one or more strategies and tracks deployed amounts.
- Withdraws:
  - Underlying: `withdraw(uint256 amount, address to)`—atomic and exact; fails if not fully available.
  - In‑kind: `withdrawUnderlying(uint256 amount, address to)`—returns position tokens (e.g., aTokens) to `to` and burns wrapper shares.
- Selection logic: greedily drains the most liquid strategy, hardened with try/catch around view calls to avoid DoS from misbehaving strategies.
- Yield:
  - `claimYield(strategy)` or `claimYields()` moves surplus position tokens to `treasury` without reducing principal.
- Roles:
  - `yieldClaimer`/`subYieldClaimer` perform deploy/claim/ops.
  - `strategyManager`/`treasury` confirm role changes and manage strategies.

### Strategies (e.g., AaveStrategy)
- Hold position tokens (e.g., aTokens) and mint/burn strategy shares 1:1 with principal.
- Expose uniform API:
  - `deposit(amount)`, `withdraw(amount)`, `withdrawUnderlying(amount)` (in‑kind), `positionToken()`.
  - `valueOfCapital() >= totalSupply()` invariant preserved by `execute` guard.
- Never allow `execute` to touch core assets (position token, protocol pool) and enforce post‑call solvency.

### pFT (PUT NFT)
- Upgradeable pattern with `initialize(address putManager)`; constructor disables initializers.
- Stores per‑position collateral token, amounts, FT balances, and strike. Only `PutManager` can mutate.

## Critical Invariants & Threat Model

- Reentrancy: All external state‑changing flows use `nonReentrant` (Wrapper, PutManager, Strategies).
- Principal Safety: Wrapper and strategies mint/burn shares 1:1 with principal; yield is separate.
- Exact Withdrawals: Wrapper `withdraw` and `withdrawUnderlying` are exact—either full amount is delivered or call reverts.
- Strategy DoS Hardening: View calls used for liquidity selection are wrapped in try/catch; failures are treated as zero liquidity.
- Governance Delays: Strategy add uses a configurable delay (set to 0 in this repo; use non‑zero in production).
- Oracle Trust: `PutManager` uses `IAaveOracle` price; there is min/max guard, but no staleness check—be aware when modifying.

## Development Guidelines

- Keep changes minimal and scoped; do not change interface signatures unless absolutely necessary and you update all implementations and tests.
- Use custom errors (already present) for reverts; prefer exact, deterministic behavior (no partials) on core withdraw paths.
- Maintain non‑reentrancy on public/external mutating functions.
- When touching strategy selection, preserve the greedy “most liquid” behavior and the try/catch hardening.
- Do not add license headers unless requested.

## Running & Writing Tests

- Build: `forge build`
- Run tests: `forge test` (add `-vvv` for verbose traces).
- Tests live under `test/`; mocks under `test/mocks/`.
- Example end‑to‑end flows: see `test/PutFlow.t.sol`.
- If adding a strategy:
  - Add unit tests for deposit/withdraw/yield and in‑kind withdrawal.
  - Add integration tests through the wrapper and PutManager.

## Strategy Integration Checklist

1. Implement `token()`, `positionToken()`, `deposit`, `withdraw`, `withdrawUnderlying`, `valueOfCapital`, `maxAbleToWithdraw`.
2. Guard with `nonReentrant` and `onlyftYieldWrapper`.
3. Ensure `execute` forbids calls touching core assets and enforces `valueOfCapital() >= totalSupply()` post‑call.
4. Confirm decimals match underlying.
5. Add to wrapper via `setStrategy` → `confirmStrategy` (respect delays in production).
6. Add tests.

## Wrapper Changes Checklist

- If modifying withdraw logic:
  - Keep exactness (no partial burns).
  - Continue forwarding to the `to` recipient consistently (idle + strategy withdrawals).
  - Preserve try/catch around view calls and external withdraw calls.
- If changing roles or delays, update tests and this doc.

## PutManager Changes Checklist

- Maintain offering state gates (`IN_PUB_OFFERING` vs `AFTER_PUB_OFFERING`).
- Keep collateral registry validation (token match with wrapper’s `token()`).
- Do not transfer tokens post‑withdraw if wrapper now sends directly to `to`.
- If modifying events, ensure they reflect delivered amounts (or enforce exact to avoid drift).

## pFT & Proxies in Tests

- `pFT` uses `initialize` and disables initializers in the constructor. When you need to test with a proxied `pFT`, deploy a `TransparentUpgradeableProxy` pointing at `pFT` implementation and call `initialize` from a non‑admin address.

## Common Gotchas

- Do not assume partial withdrawals; wrapper reverts on shortfall.
- Strategy misbehavior must not DoS user withdrawals—keep try/catch.
- Ensure all SafeERC20 `forceApprove` patterns are used when interacting with non‑standard tokens.
- If you add price logic, maintain min/max bounds, and consider staleness where applicable.

## PR / Patch Style

- Keep diffs focused; update interfaces and all call sites together.
- Update or add tests near the code you change.
- Document behavior changes in commit messages (call out BREAKING CHANGES where needed).

