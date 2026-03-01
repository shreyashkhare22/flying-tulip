# Privileged Access and Roles

This document lists all privileged roles in the Flying Tulip PUT system, who controls them, and what each role can do in plain English. It covers the core contracts:

- `contracts/PutManager.sol`
- `contracts/pFT.sol`
- `contracts/ftYieldWrapper.sol`
- `contracts/strategies/*`

The goal is to make operational responsibilities and risks clear for reviewers, integrators, and governance.

## Summary Table

| Contract       | Role/Capability     | Who controls it            | What it allows (plain English) |
|----------------|---------------------|----------------------------|---------------------------------|
| PutManager     | `msig`              | Protocol governance        | Pause/unpause; list collateral and vaults; set oracle/ACL; rotate addresses; withdraw divested capital post‑sale. |
| PutManager     | `configurator`      | Ops/config multisig        | Control sale: FT liquidity, sale flags, collateral caps, send unsold FT back. |
| PutManager     | End‑user            | Investors (EOA/contracts)  | Buy PUTs (`invest`), then post‑sale either `withdrawFT`, `divest`, or `divestUnderlying`. |
| pFT            | `onlyPutManager`    | PutManager                 | Mint/burn/adjust PUT positions; enforces ownership checks; burns NFT when FT reaches zero. |
| ftYieldWrapper | `yieldClaimer`      | Governance‑assigned        | Deploy/maintain; claim yields; perform guarded `execute` on strategies. |
| ftYieldWrapper | `subYieldClaimer`   | Delegated by `yieldClaimer`| Secondary maintenance / `execute`. |
| ftYieldWrapper | `strategyManager`   | Governance‑assigned        | Register/reorder/remove strategies (2‑step add), rotate roles. |
| ftYieldWrapper | `treasury`          | Treasury account           | Confirms rotations; receives yield. |

## Contract‑by‑Contract Details

### PutManager.sol

- Roles
  - `msig` (onlyMsig)
    - `pause()` / `unpause()` — stop/resume new `invest` calls.
    - `setMsig()` / `acceptMsig()` — schedule and accept multisig rotation.
    - `setConfigurator(address)` — rotate the configurator.
    - `setPutManager(address)` — reassign the pFT manager in `pFT` (for migrations).
    - `setOracle(address)` — update pricing oracle (`IFlyingTulipOracle`).
    - `setACL(address)` — set or clear ACL contract for whitelisting.
    - `addAcceptedCollateral(token, vault)` — list collateral with vault; checks oracle price > 0, decimals <= 18, and `vault.token()` matches.
    - `withdrawDivestedCapital(token, amount)` — withdraws capital earmarked via `withdrawFT` from the vault to `msig`.
  - `configurator` (onlyConfigurator)
    - `setSaleEnabled(bool)` — gate the public sale (`invest`).
    - `enableTransferable()` — enable post‑sale flows and transferability.
    - `addFTLiquidity(amount)` — transfer FT to the manager to be sold.
    - `setCollateralCaps(token, cap)` — set per‑token cap (token units) for collateral during sale.
    - `sendRemainderFTtoConfigurator()` — return unsold FT and normalize offering supply.
- Users
  - `invest(token, amount, [recipient], proofAmount, proofWL)` — buy PUTs during sale; collateral is pulled, deposited into the vault, FT allocated, and a pFT NFT is minted.
  - `withdrawFT(id, amount)` — post‑sale, withdraw FT and earmark corresponding collateral in `capitalDivesting`.
  - `divest(id, amountFT)` — post‑sale, burn FT and receive underlying withdrawn from the vault.
  - `divestUnderlying(id, amountFT)` — post‑sale, burn FT and receive position tokens in‑kind.
- Other notes
  - Uses `SafeERC20` and normalizes pricing with an Aave‑sourced 1e8 oracle wrapped by `FlyingTulipOracle` (`ftPerUSD` is also 1e8‑scaled).
  - Enforces token decimals <= 18 for new collateral and checks vault token matches.

### pFT.sol (ERC721 PUT token)

- Role: `onlyPutManager`
  - `mint(owner, amount, ft, usd, token, ftPerUSD)` — create a new PUT position and mint the NFT.
  - `withdrawFT(owner, id, amount, amountDivested)` — reduce FT in a position (post‑sale), burn NFT if FT goes to zero.
  - `divest(owner, id, amount, amountDivested)` — burn FT against collateral (post‑sale), burn NFT if FT goes to zero.
  - `burn(owner, id)` — legacy helper; not called by current `PutManager` flows.
  - `setPutManager(address)` — rotate the PutManager (called via PutManager governance).
- End‑users
  - Must be the `ownerOf(id)` for any manager action affecting their token (enforced inside pFT).

### ftYieldWrapper.sol (ERC20 wrapper)

- Roles & rotations are 2‑step with a pending slot and a confirmer:
  - `yieldClaimer`: set `setYieldClaimer(new)` [only current]; confirm `confirmYieldClaimer()` [by `treasury` or `strategyManager`]. `setSubYieldClaimer(address)` sets a secondary claimer.
  - `strategyManager`: set `setStrategyManager(new)` [only current]; confirm `confirmStrategyManager()` [by `treasury` or `yieldClaimer`].
  - `treasury`: set `setTreasury(new)` [only current]; confirm `confirmTreasury()` [by `strategyManager` or `yieldClaimer`].
  - Strategies: add `setStrategy(strategy)` [only `strategyManager`] → confirm `confirmStrategy()` [only `treasury`]; reorder via `setStrategiesOrder(...)`; remove via `removeStrategy(index)` (only when zero deployed).
  - Put service: `setPutManager(address)` and optional `setDepositor(address)` define who may call `deposit/withdraw` paths.
- Capital management
  - Deposit: `deposit(amount)` [only `putManager`/`depositor`] — pulls underlying from caller and mints wrapper tokens 1:1 to caller.
  - Withdraw underlying (exact): `withdraw(amount, to)` — uses idle first, then greedily drains strategies (try/catch on views); reverts if not exact; burns caller’s wrapper shares.
  - Withdraw in‑kind: `withdrawUnderlying(amount, to)` — transfers position tokens to `to`; burns wrapper shares; exact or revert.
  - Deployment: `deploy(strategy, amount)` [only `yieldClaimer`].
  - Yield: `claimYield(strategy)` / `claimYields()` send surplus to `treasury`; `sweepIdleYield()` moves idle surplus to `treasury`; `execute(...)` for maintenance.
- DoS hardening
  - Liquidity selection wraps `balanceOf`/`maxAbleToWithdraw` in try/catch; failing strategies are treated as zero‑liquidity and skipped.

### Strategies (e.g., AaveStrategy)

- Role: callable only by `ftYieldWrapper`.
  - `deposit`, `withdraw` (underlying), `withdrawUnderlying` (in‑kind), `claimYield`, and `execute` guarded by `onlyftYieldWrapper` and `nonReentrant`.
  - Guardrails:
    - Post‑`execute` check enforces `valueOfCapital() >= totalSupply()`.
    - Forbids interacting with core assets (position token/pool) inside `execute`.
    - `availableToWithdraw()`/`maxAbleToWithdraw()` reflect real liquidity to avoid over‑reporting.

## Plain‑English Risk/Ability Matrix

- Governance (`msig`)
  - Can list new collateral and vaults; if misused, could list a malicious vault and block withdrawals. Operationally sensitive: requires audits/allowlisting.
  - Can pause invests in emergencies.
  - Can withdraw post‑sale divested capital to `msig` (accounting action).
  - Can rotate addresses; use timelocks/2‑of‑N multisig per ops policy.

- Configurator
  - Controls the sale lifecycle (flags, FT supply, collateral caps). Incorrect caps or premature state changes can block user activity.

- Put owners (end‑users)
  - Post‑sale: can `withdrawFT`, `divest`, or `divestUnderlying` to receive collateral (or position tokens) directly via the wrapper.

- Wrapper roles
  - Yield Claimer / Sub‑Claimer: Can harvest strategy yield and perform non‑capital `execute` calls (including external reward claims). If compromised, cannot drain principal; strategy guardrails prevent capital reductions.
  - Strategy Manager: Registers strategies; capital is moved by wrapper functions only. Misuse can allocate to a poor strategy but cannot steal funds (withdrawal path returns to wrapper).
  - Treasury: Confirms role rotations and receives all yields/rewards.

- Strategy invariants
  - Only wrapper can move funds; `execute` cannot reduce strategy capital.

## Practical Guidance

- Use audited vaults/strategies whose `token()` matches the intended collateral.
- Keep `msig` and `configurator` keys in separate multisigs; rotate via the built‑in pending/confirm flows.
- Monitor events: `Invested`, `ExitPosition`, `Divested`, `Withdraw`, `CapitalDivested`, `WithdrawDivestedCapital`, wrapper `Deposit`/`Withdraw`, and role rotation events.
- Prefer standard ERC20s for collateral (no rebasing/fee‑on‑transfer); decimals must be <= 18.

