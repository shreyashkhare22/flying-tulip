# PUT Sale End-to-End Dry-Run Test Plan

This checklist is executed against already deployed contracts to rehearse the complete sale lifecycle (PutManager, ftYieldWrapper, pFT) using the current deployment tooling.

---

## Scope & Prerequisites

- Latest deployment artifacts (proxy + implementation addresses) recorded and exported for scripts/UI.  
- PutManager initialized with live oracle, configurator, multisig, and connected wrappers/pFT.  
- At least one collateral wrapper funded with strategy liquidity and an oracle price > 0.  
- Test wallets mapped to roles: multisig, configurator, yield claimer, scripted buyers, UI buyers.  
- Tooling ready: Foundry (`forge`, `cast`), block explorer, product UI on the same RPC.  
- Capture baseline metrics: `ftOfferingSupply`, `ftAllocated`, `collateralSupply[token]`, wrapper `totalSupply()`, etc.  

---

## Stage 0 – Pre-Flight Verification (Deployment Completed)

- [ ] **Deployment script completed** – Confirm `forge script script/DeployFtPut.s.sol:DeployFtPut --broadcast --verify ...` finished without errors and the summary output was archived.  
- [ ] **Run verification helpers** – Execute:
  ```bash
  forge script script/VerifyDeployment.s.sol:VerifyDeployment \
    --rpc-url $RPC_URL \
    -s "run(address,address)" $PUTMANAGER_PROXY $PFT_PROXY \
    -vvv
  ```
  Review any `[WARN]` or `[ACTION REQUIRED]` items.  
- [ ] **Manual state checks** – Re-run the post-deploy cast calls (owner, collateral registry, caps, FT supply) and log results.  
- [ ] **ACL wiring (recommended)** – If a whitelist will be used in production, deploy a minimal test Merkle tree (or reuse the real root) and validate proofs succeed for allowed wallets and revert for disallowed ones.  
- [ ] **Pause/unpause rehearsal** – Record tx hashes for `pause()` / `unpause()` to demonstrate administrative control.  

---

## Stage 1 – Public Offering Active (`saleEnabled = true`, `transferable = false`)

- [ ] **Primary purchase** – Buyer deposits collateral via UI and `cast send ... invest(...)`; verify pFT mint, `ftAllocated` increment, events.  
- [ ] **Purchase on behalf** – Payer != recipient; confirm NFT ownership and collateral accounting.  
- [ ] **ACL enforcement** – Attempt purchases at, below, and above allowances to show expected reverts or success.  
- [ ] **Collateral cap guard** – Push wrapper totals to cap and capture revert when exceeding it.  
- [ ] **FT liquidity exhaustion** – Drain offering supply to trigger `ftPutManagerInsufficientFTLiquidity`, ensuring UI handles “sold out”.  
- [ ] **Investor exit (collateral)** – Call `divest` during sale; verify collateral return, NFT burn, and events.  
- [ ] **Investor exit (in-kind)** – Call `divestUnderlying`; confirm strategy tokens received and wrapper share burn.  
- [ ] **Partial exercise** – Perform multiple partial divests and inspect `pFT.puts(id)` for updated `ft`/`amountRemaining`.  
- [ ] **Price sanity checks** – Compare `getAssetFTPrice` outputs against UI quotes for several ticket sizes.  
- [ ] **Pause stress test** – Pause during sale, attempt invests to capture reverts, then unpause and repeat successful purchase.  

---

## Stage 2 – Transition to After Offering (`transferable = true`)

- [ ] **Close sale** – Record `configurator.enableTransferable()`; ensure new invests revert and UI disables purchase actions.  
- [ ] **Redeem FT** – Execute partial + full `withdrawFT`; confirm FT transfers, `capitalDivesting` accumulation, NFT burn.  
- [ ] **Treasury pullback** – `msig.withdrawDivestedCapital` drains collateral back to treasury, clearing `capitalDivesting`.  
- [ ] **Return remainder FT** – `sendRemainderFTtoConfigurator()` post-sale; verify `ftOfferingSupply == ftAllocated`.  
- [ ] **Exercise PUT (collateral)** – Post-offering `divest` returns exact collateral; confirm accounting & events.  
- [ ] **Exercise PUT (in-kind)** – Post-offering `divestUnderlying` returns strategy tokens via wrapper.  
- [ ] **Secondary transfers** – Transfer pFT between wallets, then exercise from new owner to validate access control.  
- [ ] **ACL sunset** – If whitelist used, optionally `setACL(address(0))` and demonstrate unrestricted flows.  

---

## Stage 3 – Post-Sale Operations & Observability

- [ ] **Strategy liquidity checks** – Call `canDivest` / `maxDivestable` to document available liquidity reporting.  
- [ ] **Yield claim flow** – `ftYieldWrapper.claimYields()`; capture treasury receipts and confirm principal remains intact.  
- [ ] **Oracle rotation fallback** – Execute `setOracle` to a new feed and confirm pricing updates propagate.  
- [ ] **Pause during redemption** – Pause while transferable = true; attempt `withdrawFT`/`divest` (expect revert), then unpause.  
- [ ] **Metrics reconciliation** – Compare on-chain counters (`ftAllocated`, `collateralSupply`, wrapper `totalSupply`) against UI/off-chain analytics.  

---

## Reporting & Acceptance

- Record tx hashes and events (`Invested`, `Divested`, `Withdraw`, `CapitalDivested`, `ExitPosition`, etc.) for each scenario.  
- Log state deltas after each stage (allocations, wrapper balances, outstanding NFTs).  
- Document UI edge cases (loading states, errors) and supporting scripts/commands.  
- **Exit criteria:** every scenario completes without unexpected reverts, invariants hold, and UI reflects on-chain state within tolerance.  