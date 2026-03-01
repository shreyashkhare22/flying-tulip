# Flying Tulip PUT (pFT) — Overview

This README summarizes the current architecture, flows, and how to build/test. For detailed role/privilege mappings, see `PRIVILEGES.md`.

**Goal**
- Cash‑secured put product where collateral (e.g., USDC) is deployed to yield strategies via a wrapper. Principal is protected; yield accrues to treasury.

**Core Contracts**
- `contracts/PutManager.sol` — Entry point. Orchestrates the sale, accounting, collateral registry, and user flows. Prices using `IFlyingTulipOracle` and routes collateral via `ftYieldWrapper`.
- `contracts/pFT.sol` — ERC721 PUT NFT (upgradeable via initializer). Only `PutManager` can mint/burn/adjust.
- `contracts/ftYieldWrapper.sol` — ERC20 wrapper over the underlying collateral. Mints/burns 1:1 shares with principal, deploys to strategies, withdraws underlying or in‑kind position tokens.
- `contracts/strategies/*` — Strategy adapters (e.g., Aave). 1:1 shares with principal; yield remains in position tokens; strict guardrails.

**Lifecycle (PutManager as entry point)**
- Sale control
  - `setSaleEnabled(bool)` [configurator] — gates `invest` during the public sale. Defaults to enabled in `initialize`.
  - `enableTransferable()` [configurator] — marks positions transferable and enables post‑sale flows.
  - `addFTLiquidity(amount)` [configurator] — transfers FT into the manager to be sold; tracked in `ftOfferingSupply`.
  - `sendRemainderFTtoConfigurator()` [configurator] — returns unsold FT and normalizes offering supply to actual sold amount.
- Collateral registry
  - `addAcceptedCollateral(token, vault)` [msig] — lists collateral with its wrapper. Verifies oracle price > 0, token decimals <= 18, and `vault.token()` matches.
  - `setCollateralCaps(token, cap)` [configurator] — optional per‑token cap (native token units) during sale.
- Investing (during sale)
  - `invest(token, amount, proofAmount, proofWL)` or `invest(token, amount, recipient, proofAmount, proofWL)` [user]
    - Optional ACL whitelist via `IftACL.isWhitelisted` and tracked via `ftACL.invest`.
    - Pulls collateral to `PutManager`, approves the vault, and `vault.deposit(amount)` (wrapper mints 1:1 shares to `PutManager`).
    - Prices using `IFlyingTulipOracle` `getAssetPrice(token)` and `ftPerUSD()`. Allocates FT and mints `pFT` to user/recipient.
    - Enforces available FT liquidity (`ftOfferingSupply - ftAllocated`).
- Post‑sale (after `enableTransferable()`)
  - `withdrawFT(id, amount)` [owner] — returns FT to owner and books the corresponding collateral in `capitalDivesting[token]` for later msig withdrawal. Exact conversion via `collateralFromFT`.
  - `divest(id, amountFT)` [owner] — burns FT and withdraws exact underlying to the owner via the wrapper.
  - `divestUnderlying(id, amountFT)` [owner] — burns FT and returns position tokens (in‑kind) to the owner via the wrapper.
  - `withdrawDivestedCapital(token, amount)` [msig] — pulls earmarked collateral from the wrapper to `msig` and updates accounting.

Note: The former “exit during offering” flow has been removed from `PutManager`. Post‑sale actions are `withdrawFT`, `divest`, and `divestUnderlying`.

**Pricing (single source of truth)**
- Oracle: `IFlyingTulipOracle` exposes `getAssetPrice(token)` (1e8 scale) and `ftPerUSD()` (FT per USD, 1e8 scale).
- Helpers in `PutManager`:
  - `ftFromCollateral(amount, strike, tokenDecimals, ftPerUSD)` → FT allocated for collateral.
  - `collateralFromFT(ftAmount, strike, tokenDecimals, ftPerUSD)` → exact collateral required for FT.
- Convenience: `getAssetFTPrice(token, amount[, tokenDecimals])` returns `(ftOut, strike, ftPerUSD)`.

**Wrapper/Strategy Behavior**
- Underlying withdraws (exact): `ftYieldWrapper.withdraw(amount, to)` uses idle balance first, then greedily drains the most liquid strategies (try/catch on strategy views); reverts on shortfall; burns caller’s wrapper shares.
- In‑kind withdraws: `ftYieldWrapper.withdrawUnderlying(amount, to)` transfers position tokens directly to `to`; burns wrapper shares; exact or revert.
- Yield: `claimYield(strategy)` / `claimYields()` move surplus to `treasury`; principal is unaffected. `sweepIdleYield()` moves idle surplus to `treasury`.

**Roles (high‑level)**
- PutManager
  - `msig`: pause/unpause, rotate roles, set oracle/ACL, list collateral/vaults, withdraw `capitalDivesting` post‑sale.
  - `configurator`: control sale flags, FT liquidity, collateral caps, and post‑sale remainder.
  - Optional `ftACL`: whitelist gating and allocation tracking for invests.
- Wrapper (`ftYieldWrapper`)
  - `yieldClaimer`/`subYieldClaimer`: deploy/maintain/claim yield; `execute(...)` maintenance hooks on strategies.
  - `strategyManager`/`treasury`: manage and confirm strategies, reorder priorities.
  - `putManager`/`depositor`: allowed to call `deposit/withdraw/withdrawUnderlying` (burn/mint wrapper shares 1:1 with principal).
- pFT: only `PutManager` may mutate positions.

**Build & Test (Foundry)**
- Build: `forge build`
- Test: `forge test`
- Tests: see `test/` for end‑to‑end flows (`test/PutFlow.t.sol`) and wrapper/strategy unit tests.

**Developer Notes**
- See `AGENTS.md` for invariants, change checklists, and strategy integration guidance.

