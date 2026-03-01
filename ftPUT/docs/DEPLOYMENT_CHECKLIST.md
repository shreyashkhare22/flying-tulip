# Deployment Checklist

Quick reference checklist for deploying ftPUT protocol to production.

## Pre-Deployment

- [ ] Create encrypted keystore: `cast wallet import deployer --interactive`
- [ ] Fund deployer address with gas tokens (5+ S for Sonic)
- [ ] Copy `.env.example` to `.env`
- [ ] Set `RPC_URL=<rpc-url>` in `.env`
- [ ] Set `ETHERSCAN_API_KEY=<key>` in `.env`
- [ ] Also set these variables in your local terminal to run commands
- [ ] Run `forge build`


## Configure Deployment

Edit `script/config/deployments.toml` for your target chain:

- [ ] Verify chain ID section exists (146 for Sonic mainnet)
- [ ] Set all role addresses (msig, configurator, treasury, yield_claimer, strategy_manager)
- [ ] Verify token addresses (usdc, wNative, ft)
- [ ] Verify Aave v3 addresses (aave_pool_provider, aave_oracle, aave_ausdc, aave_awnative)
- [ ] Set collateral caps (cap_usdc, cap_wnative) - 0 = unlimited
- [ ] Set initial_ft_supply (default: "10000000000000000000000000000" = 10B FT)
- [ ] Set `is_production = true` for mainnet
- [ ] Configure ACL: set `disable_acl = false` and `merkle_root` if using whitelist
- [ ] If using whitelist: Verify merkle_root is NOT 0x0

## Verify External Dependencies

Check that all external contracts are operational:
NOTE: export $RPC_URL in your terminal

# Verify USDC
cast code 0x29219dd400f2Bf60E5a23d13Be72B486D4038894 --rpc-url $RPC_URL
cast call 0x29219dd400f2Bf60E5a23d13Be72B486D4038894 "name()(string)" --rpc-url $RPC_URL
cast call 0x29219dd400f2Bf60E5a23d13Be72B486D4038894 "decimals()(uint8)" --rpc-url $RPC_URL

# Verify Aave oracle returns prices
cast call 0xD63f7658C66B2934Bd234D79D06aEF5290734B30 "getAssetPrice(address)(uint256)" 0x29219dd400f2Bf60E5a23d13Be72B486D4038894 --rpc-url $RPC_URL
```

- [ ] FT token contract address is correct along with name (or set to 0x0 to deploy mock)
- [ ] **FT token is NOT paused** (paused() returns false) - **CRITICAL for deployment**
- [ ] FT token has 18 decimals
- [ ] USDC contract is correct and has 6 decimals
- [ ] wS (wrapped Sonic) contract is correct
- [ ] Aave oracle returns valid prices (non-zero)
- [ ] Aave pool is operational

**⚠️ IMPORTANT:** If the FT token is paused, the deployment will fail with `EnforcedPause()` error when trying to add FT liquidity. You must unpause the FT token before deployment or set `ft = "0x0000000000000000000000000000000000000000"` in deployments.toml to deploy a mock token for testing.

## Dry Run (No Broadcast)

Test deployment configuration without broadcasting:

```bash
forge script script/DeployFtPut.s.sol:DeployFtPut \
  --rpc-url $RPC_URL \
  --account deployer  \
  --sender $(cast wallet address --account deployer) \
  -vvvv
```

NOTE: this needs an archive node to work in fork mode

**At the prompt:**
- Type `p` to print the configuration summary (script exits afterward).
- Review the summary (checklist below). If everything is correct, rerun the dry run or the real deployment and type `y` when prompted.

**Configuration summary review:**
- [ ] Chain ID is correct
- [ ] All role addresses are correct
- [ ] Token addresses are correct
- [ ] FT address provided, will NOT deploy mock
- [ ] Caps and supply values are correct
- [ ] ACL configuration is correct
- [ ] No CRITICAL WARNING about merkle root (or acknowledged)
- [ ] Auth method shows "Keystore (Recommended)" for production

**Optional: run against Tenderly Virtual Testnet**

```bash
forge script script/DeployFtPut.s.sol:DeployFtPut \
  --slow \
  --verify \
  --verifier-url $TENDERLY_VIRTUAL_TESTNET_RPC/verify/etherscan \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC_URL \
  --account tenderly-sim \
  --sender $(cast wallet address --account tenderly-sim) \
  --etherscan-api-key $TENDERLY_ACCESS_TOKEN \
  --broadcast
```

This broadcasts to Tenderly’s virtual environment so you can inspect traces, verification, and contract addresses without touching a live chain.

NOTE: tenderly verifier url should point to this = $TENDERLY_VIRTUAL_TESTNET_RPC/verify/etherscan


## Deploy

```bash
forge script script/DeployFtPut.s.sol:DeployFtPut \
  --rpc-url $RPC_URL \
  --account deployer \
  --sender $(cast wallet address --account deployer) \
  --broadcast \
  --verify \
  -vvv
```

NOTE: if theres a failure on receipt response try executing again with `--resume` option
can also consider adding `--slow` option if hitting rate limit issues in RPC

**During deployment:**
- [ ] Carefully review DEPLOYMENT CONFIGURATION SUMMARY
- [ ] Type "y" to confirm (anything else cancels)
- [ ] Enter keystore password when prompted
- [ ] Monitor all transactions complete successfully
- [ ] No reverted transactions

**Auto-verification checklist (all handled by deployment script):**
- ✅ FT Token deployed (or mock deployed if ft = 0x0 and this is a test deployment)
- ✅ pFT (ERC721) proxy deployed and initialized
- ✅ PutManager proxy deployed and initialized
- ✅ pFT.putManager configured to point to PutManager
- ✅ FlyingTulipOracle deployed
- ✅ ACL deployed and configured (if enabled)
- ✅ ftYieldWrapper contracts deployed (USDC and wNative)
- ✅ AaveStrategy contracts deployed
- ✅ Wrappers linked to PutManager
- ✅ Strategies configured and confirmed on wrappers
- ✅ Collaterals registered in PutManager
- ✅ Collateral caps set
- ✅ FT liquidity added (for mock deployments only)
- ✅ Ownership/role transfers initiated:
  - ✅ Treasury: **Auto-confirmed during deployment**
  - ✅ StrategyManager: **Auto-confirmed during deployment**
  - ⏳ YieldClaimer: Pending post-deployment confirmation
  - ⏳ PutManager MSIG: Pending post-deployment acceptance (with time delay)
  - ⏳ Oracle MSIG: Pending post-deployment acceptance (with time delay)
- ✅ All contracts verified on block explorer

**Save all deployed addresses from DEPLOYMENT SUMMARY**

## Post-Deployment Actions

**The deployment script handles ALL configuration automatically!** The deployer completes all setup, then initiates ownership/role transfers at the end. Review the deployment output's "POST-DEPLOYMENT ACTIONS REQUIRED" section for specific steps.

### Verify Deployment State

**Before accepting ownership, run the verification script to validate the deployment:**

```bash
# Set deployed addresses from deployment output
PUTMANAGER_PROXY=<deployed_putmanager_proxy_address>
PFT_PROXY=<deployed_pft_proxy_address>

# Run verification script
forge script script/VerifyDeployment.s.sol:VerifyDeployment \
  --rpc-url $RPC_URL \
  -s "run(address,address)" $PUTMANAGER_PROXY $PFT_PROXY \
  -vvv
```

NOTE: Source code verification on blockexplorer e.g soniscan may need further steps for proxies e.g PutManager, pFT, check <more options> button in contract tab section for instructions to verify those contracts.

**Verification checklist - Review the output for:**
- [ ] ✓ All expected roles match on-chain state (msig, configurator, treasury, etc.)
- [ ] ✓ Treasury and StrategyManager: Should be **auto-confirmed** (not pending)
- [ ] ⚠ YieldClaimer: Should be **pending** (requires post-deployment confirmation)
- [ ] ✓ Collateral caps match configuration
- [ ] ⚠ FT supply: Should be 0 immediately after deployment (liquidity added post-deployment by FT configurator)
- [ ] ✓ Contract state is correct (not paused, sale enabled)
- [ ] ✓ Oracle addresses are correct
- [ ] ✓ ACL/whitelist configuration matches expectations
- [ ] ⚠ Review all PENDING items and time delays (PutManager MSIG, Oracle MSIG, YieldClaimer)
- [ ] ✗ No MISMATCH errors (if any, investigate before accepting)
- [ ] ⚠ FT configurator has sufficient balance to add liquidity

**The verification script will:**
- Load expected configuration from `deployments.toml`
- Compare on-chain state with expected values
- Show all pending ownership transfers
- Calculate time remaining for msig acceptance
- List all required confirmation actions

### Add FT Liquidity (Required Post-Deployment Action)

**IMPORTANT:** The deployment script does NOT add FT liquidity when using a real FT token. The FT token's configurator (a multisig) must manually add liquidity after deployment.

**FT Token Configurator Multisig Actions:**

1. **Approve PutManager to spend FT tokens**
   - Contract: `<FT_TOKEN_ADDRESS>` (from deployments.toml)
   - Function: `approve(address,uint256)`
   - Parameters:
     - `spender`: `<PUTMANAGER_PROXY_ADDRESS>` (from deployment output)
     - `amount`: `<INITIAL_FT_SUPPLY>` (e.g., 10000000000000000000000000000)

2. **Add FT liquidity to PutManager**
   - Contract: `<PUTMANAGER_PROXY_ADDRESS>` (from deployment output)
   - Function: `addFTLiquidity(uint256)`
   - Parameters:
     - `amount`: `<INITIAL_FT_SUPPLY>` (same as above)

3. **Verify FT liquidity was added**
   - Call: `PutManager.ftOfferingSupply()` should return the expected amount

**Checklist:**
- [ ] FT configurator multisig approved PutManager to spend FT tokens
- [ ] FT configurator multisig called addFTLiquidity()
- [ ] FT offering supply verified on-chain matches expected amount

### Role Acceptance Required

**IMPORTANT:** The deployment script auto-confirms Treasury and StrategyManager roles to avoid circular dependencies. Only the following roles require post-deployment actions:

**1. MSIG Ownership (if deployer != msig):**

PutManager Ownership:
- [ ] Wait for time delay to expire (check `PutManager.delayMsig()`)
- [ ] MSIG must call `PutManager.acceptMsig()`

Oracle Ownership:
- [ ] Wait for time delay to expire (check `FlyingTulipOracle.delayMsig()`)
- [ ] MSIG must call `FlyingTulipOracle.acceptMsig()`

**2. YieldClaimer Confirmation (if yieldClaimer != deployer):**

Note: Treasury and StrategyManager were **auto-confirmed during deployment**. Only YieldClaimer requires manual confirmation.

- [ ] Treasury OR StrategyManager calls `wrapperUSDC.confirmYieldClaimer()`
- [ ] Treasury OR StrategyManager calls `wrapperWNative.confirmYieldClaimer()` (if WNative enabled)

**Roles that do NOT require post-deployment action:**
- ✅ Treasury: Auto-confirmed during deployment
- ✅ StrategyManager: Auto-confirmed during deployment
- ✅ Configurator: Directly transferred (no confirmation needed)

**Note:** The deployment summary will print exact contract addresses and function calls needed.

### Safe Multisig Transaction Details

Post-deployment actions require the following Safe multisig transactions:

#### 1. MSIG Ownership Acceptance (2 transactions)

**Transaction 1: Accept PutManager ownership**
- Contract: `<PUTMANAGER_PROXY_ADDRESS>` (from deployment output)
- Function: `acceptMsig()`
- Parameters: None
- Caller: MSIG Safe
- Prerequisites: Wait for time delay to expire (check `delayMsig()`)

**Transaction 2: Accept Oracle ownership**
- Contract: `<ORACLE_ADDRESS>` (FlyingTulipOracle from deployment output)
- Function: `acceptMsig()`
- Parameters: None
- Caller: MSIG Safe
- Prerequisites: Wait for time delay to expire (check `delayMsig()`)

#### 2. YieldClaimer Confirmation (2 transactions if WNative enabled)

**Transaction 1: Confirm YieldClaimer for USDC wrapper**
- Contract: `<WRAPPER_USDC_ADDRESS>` (from deployment output)
- Function: `confirmYieldClaimer()`
- Parameters: None
- Caller: Treasury Safe OR StrategyManager Safe

**Transaction 2: Confirm YieldClaimer for WNative wrapper** (if WNative enabled)
- Contract: `<WRAPPER_WNATIVE_ADDRESS>` (from deployment output)
- Function: `confirmYieldClaimer()`
- Parameters: None
- Caller: Treasury Safe OR StrategyManager Safe

#### Summary of Post-Deployment Transactions

**Total transactions needed:** 2-4 depending on configuration
- 2 MSIG ownership acceptances (PutManager + Oracle)
- 1-2 YieldClaimer confirmations (USDC + optionally WNative)

**Roles that do NOT need transactions:**
- ✅ Treasury: Already confirmed during deployment
- ✅ StrategyManager: Already confirmed during deployment
- ✅ Configurator: Direct transfer, no confirmation needed

## Final Verification

Verify deployed state after all post-deployment actions are complete:

```bash
PUTMANAGER=<deployed_putmanager_address>
PFT=<deployed_pft_address>
USDC=<usdc_address_from_config>
WRAPPER_USDC=<wrapper_usdc_address>

# Check PutManager owner (should be MSIG after acceptance)
cast call $PUTMANAGER "msig()(address)" --rpc-url $RPC_URL

# Check pFT putManager is set
cast call $PFT "putManager()(address)" --rpc-url $RPC_URL

# Check FT offering supply
cast call $PUTMANAGER "ftOfferingSupply()(uint256)" --rpc-url $RPC_URL

# Check USDC collateral registered
cast call $PUTMANAGER "acceptedCollaterals(address)(bool,address)" $USDC --rpc-url $RPC_URL

# Check USDC cap
cast call $PUTMANAGER "collateralCaps(address)(uint256)" $USDC --rpc-url $RPC_URL

# Verify wrapper roles are all confirmed
cast call $WRAPPER_USDC "treasury()(address)" --rpc-url $RPC_URL
cast call $WRAPPER_USDC "strategyManager()(address)" --rpc-url $RPC_URL
cast call $WRAPPER_USDC "yieldClaimer()(address)" --rpc-url $RPC_URL
cast call $WRAPPER_USDC "pendingTreasury()(address)" --rpc-url $RPC_URL
cast call $WRAPPER_USDC "pendingStrategyManager()(address)" --rpc-url $RPC_URL
cast call $WRAPPER_USDC "pendingYieldClaimer()(address)" --rpc-url $RPC_URL
```

**Expected final state after all post-deployment actions:**
- ✅ PutManager msig: Multisig address (after MSIG acceptance)
- ✅ pFT putManager: PutManager proxy address
- ✅ FT offering supply: Expected amount (e.g., 10,000,000,000 FT)
- ✅ USDC collateral: Accepted and wrapper configured
- ✅ Collateral caps: Set as configured
- ✅ All wrappers have strategies confirmed
- ✅ Oracle configured correctly
- ✅ Wrapper treasury: Expected treasury address (auto-confirmed)
- ✅ Wrapper strategyManager: Expected strategyManager address (auto-confirmed)
- ✅ Wrapper yieldClaimer: Expected yieldClaimer address (confirmed post-deployment)
- ✅ All pending* fields should be address(0) - no pending transfers remaining

## Verify on Block Explorer

Check the appropriate block explorer for your chain.

**For each deployed contract:**
- [ ] Source code verified
- [ ] Contract addresses saved
- [ ] Constructor args correct
- [ ] Proxy implementations correct
- [ ] Owner/role addresses correct

**Key contracts to verify:**
- [ ] PutManager proxy
- [ ] pFT proxy
- [ ] FlyingTulipOracle
- [ ] ftYieldWrapper (USDC)
- [ ] ftYieldWrapper (wNative)
- [ ] AaveStrategy (USDC)
- [ ] AaveStrategy (wNative)
- [ ] ftACL (if deployed)

## Integration Test

Test with small amounts:

```bash
# Test investment (requires whitelisted address if ACL enabled)
# Use small amount: 1 USDC = 1000000 (6 decimals)
```

- [ ] Invest small amount of USDC (1 USDC)
- [ ] Verify pFT NFT minted
- [ ] Check collateral routed to Aave (aUSDC balance increased)
- [ ] Test divest functionality
- [ ] Verify ACL works (if enabled)

## Record Deployment

Save deployment information:

```bash
# Example format - save to deployment log
echo "Chain: <chain_name> (<chain_id>)"
echo "Timestamp: $(date)"
echo "Deployer: $(cast wallet address --account deployer)"
echo "FT Token: <address>"
echo "pFT Proxy: <address>"
echo "PutManager Proxy: <address>"
echo "Oracle: <address>"
echo "USDC Wrapper: <address>"
echo "WNative Wrapper: <address>"
echo "USDC Strategy: <address>"
echo "WNative Strategy: <address>"
echo "ACL: <address>"
```

- [ ] All contract addresses recorded
- [ ] Transaction hashes saved
- [ ] Block numbers noted
- [ ] Gas costs documented
- [ ] Update README with deployed addresses
- [ ] Update frontend config with contract addresses

## ✅ Deployment Complete

All contracts deployed, verified, ownership configured, and functionality tested.

---

## Quick Command Reference

```bash
# Check deployer balance
cast balance $(cast wallet address --account deployer) --rpc-url $RPC_URL

# Dry run (no broadcast)
forge script script/DeployFtPut.s.sol:DeployFtPut \
  --rpc-url $RPC_URL \
  --account deployer \
  --sender $(cast wallet address --account deployer) \
  -vvv

# Deploy with verification
forge script script/DeployFtPut.s.sol:DeployFtPut \
  --rpc-url $RPC_URL \
  --account deployer \
  --sender $(cast wallet address --account deployer) \
  --broadcast \
  --verify \
  -vvv

# Verify specific contract manually
forge verify-contract <ADDRESS> <CONTRACT_NAME> --chain <CHAIN_ID> --watch

# Check contract state
cast call <CONTRACT> "<FUNCTION_SIG>" [ARGS] --rpc-url $RPC_URL
```

---

## Network-Specific Notes

### Sonic (Chain ID: 146)
- RPC: Use `$RPC_URL` from `.env` (set to Sonic RPC endpoint)
- Explorer: https://sonicscan.org
- Native token: S (for gas)
- USDC: 0x29219dd400f2Bf60E5a23d13Be72B486D4038894
- wS: 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38

### Sonic Testnet (Chain ID: 64165)
- RPC: Use `$SONIC_TESTNET_RPC_URL` from `.env`
- Explorer: https://testnet.sonicscan.org
- Native token: testnet S
- Configure testnet addresses in `deployments.toml`

### Other Chains
- Add configuration to `script/config/deployments.toml`
- Update RPC URL in `.env`
- Verify Aave v3 is deployed on target chain
- Update chain-specific token addresses
