# Deployment

## Mainnet Contract Addresses (Polygon, Chain ID 137)

**Current deploy:** Round 4, 2026-04-28 (first tx block 86135682). See [`deployment/POLYGON_MAINNET_R4.md`](deployment/POLYGON_MAINNET_R4.md) for the full deploy summary, broadcast log, and verification output.

> The address table below is the **live R4 deploy** (the current address-of-record). The `OracleModule` row is the R4 Chainlink Functions oracle; the R5 CRE migration replaces it with `CreOracleReceiver` in the `CRE_ORACLE_RECEIVER` slot. The R5 deploy flow is documented in the sections below — its mainnet addresses will be recorded here when R5 ships.

| Contract | Address |
|----------|---------|
| OspexCore | [`0xECD12Af197FBF4C9F706B5Eb11a19c40Cfd643db`](https://polygonscan.com/address/0xECD12Af197FBF4C9F706B5Eb11a19c40Cfd643db) |
| ContestModule | [`0x1Eb0048650380369C6F4239dE070114463626102`](https://polygonscan.com/address/0x1Eb0048650380369C6F4239dE070114463626102) |
| SpeculationModule | [`0xd757387893E779AC35451CeA639a408A537b9a1B`](https://polygonscan.com/address/0xd757387893E779AC35451CeA639a408A537b9a1B) |
| PositionModule | [`0x0DCd42f8609cd7884ddBa3481b03a78dfc88366c`](https://polygonscan.com/address/0x0DCd42f8609cd7884ddBa3481b03a78dfc88366c) |
| MatchingModule | [`0x1B93579B044f0eE3c4C8a9F479A323DeF7770712`](https://polygonscan.com/address/0x1B93579B044f0eE3c4C8a9F479A323DeF7770712) |
| OracleModule | [`0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb`](https://polygonscan.com/address/0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb) |
| TreasuryModule | [`0xCB56CD2c509301e888965DD3A2E5C486Fe03a56e`](https://polygonscan.com/address/0xCB56CD2c509301e888965DD3A2E5C486Fe03a56e) |
| LeaderboardModule | [`0x63f76D5796296FFB94132C6f70d3ff9c3c5a0DEF`](https://polygonscan.com/address/0x63f76D5796296FFB94132C6f70d3ff9c3c5a0DEF) |
| RulesModule | [`0x05aF3d55F44CfaFA59c3B152A1547b5219d90f93`](https://polygonscan.com/address/0x05aF3d55F44CfaFA59c3B152A1547b5219d90f93) |
| SecondaryMarketModule | [`0xaD2B4437296B46a1b107Bb2dB7AC4082182b6059`](https://polygonscan.com/address/0xaD2B4437296B46a1b107Bb2dB7AC4082182b6059) |
| MoneylineScorerModule | [`0xd846B7FdbD8C9F67d1580B2C6a8Bd7Fdcb15390b`](https://polygonscan.com/address/0xd846B7FdbD8C9F67d1580B2C6a8Bd7Fdcb15390b) |
| SpreadScorerModule | [`0x99c5fF5131F269cA178e2Ea78f2a2A222a3a7d5e`](https://polygonscan.com/address/0x99c5fF5131F269cA178e2Ea78f2a2A222a3a7d5e) |
| TotalScorerModule | [`0xC141679f09413EDe38E3Cd36a3e4aDE423827972`](https://polygonscan.com/address/0xC141679f09413EDe38E3Cd36a3e4aDE423827972) |

**Token:** Native USDC ([`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)), 6 decimals

---

## Network Configuration

> **R5 (Chainlink CRE) configuration.** The R4 Chainlink Functions config (LINK token, Functions Router, DON ID, subscription 191/416) is **retired** — the oracle is now the `CreOracleReceiver` driven by an off-chain Chainlink CRE workflow. The receiver is wired to a trusted **KeystoneForwarder** and a **workflow owner** (the governance adapter), with an optional immutable **workflow-name** pin. CRE execution is funded **off-chain** at the workflow owner — there is no on-chain LINK subscription and no LINK-per-call.

| Parameter | Mainnet (Polygon) | Testnet (Amoy) |
|-----------|-------------------|----------------|
| Chain ID | 137 | 80002 |
| KeystoneForwarder (`KEYSTONE_FORWARDER`) | **no default — required** (Polygon mainnet production forwarder; must be human-confirmed) | CRE Amoy production forwarder (script default; overridable) |
| Workflow Owner (`WORKFLOW_OWNER`) | the `CreWorkflowOwner` governance adapter (from `DeployCreGovernance` on Ethereum mainnet) | the CRE workflow owner address |
| Workflow Name (`WORKFLOW_NAME`, immutable) | optional pin — `0`/empty = owner-only binding; if enforced, the **SHA256-derived bytes10** the CRE engine stamps into report metadata (NOT bytes10 of the plaintext name) | same posture |
| Token | Native USDC (6 decimals) | Mock USDC (6 decimals) |
| USDC Address | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` |

> **Workflow-name footgun:** `WORKFLOW_NAME` is **immutable** on the receiver. If you enforce it, it MUST be the SHA256-derived bytes10 that the CRE engine stamps into report metadata (i.e. `SHA256(name)` → first 10 hex chars → those 10 ASCII chars as bytes), **not** `bytes10` of the plaintext name. Passing the plaintext value makes `onReport` reject every report and **permanently bricks the immutable receiver**. The plaintext name pinned in `DeployCreGovernance` (default `"osverify"`) and the name whose SHA256-bytes10 the receiver enforces **must be the same name** — this is a hard cross-script invariant.

---

## Local Anvil Fork Test (Run This First)

Before deploying to live Amoy, validate the full deployment sequence on a local fork. Start an Anvil fork of Amoy, then run `DeployAmoyCre.s.sol` against it:

```bash
# 1. Start an Anvil fork pulling live Amoy state (in a separate terminal):
anvil --fork-url $AMOY_RPC

# 2. Deploy against the fork (set the CRE receiver env values — see Testnet Deployment below):
WORKFLOW_OWNER=0xYourWorkflowOwner \
forge script script/DeployAmoyCre.s.sol:DeployAmoyCre \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --via-ir \
  --optimize \
  -vvvv
```

Set `AMOY_RPC` to your Alchemy Amoy RPC URL (e.g. `https://polygon-amoy.g.alchemy.com/v2/YOUR_KEY`). The fork pulls live Amoy state so the deploy exercises the real token/forwarder addresses.

**What depends on live Amoy state (pulled by the fork):**
- Mock USDC contract at `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8`
- The CRE production KeystoneForwarder (`DeployAmoyCre` default, or `KEYSTONE_FORWARDER` override)

**What won't work on the fork (expected):**
- CRE workflow reports (no DON / KeystoneForwarder write-back on a local fork) — the receiver deploys and registers, but no off-chain workflow will report into it locally.

If the fork deployment succeeds (all modules registered, `finalize()` clean), you're clear to deploy to live Amoy.

---

## CRE Deploy Flow (read first — order matters)

The R5 oracle is a Chainlink CRE workflow whose on-chain receiver (`CreOracleReceiver`) is governed by a timelocked adapter. Deploy in this order:

1. **Deploy governance on Ethereum mainnet FIRST.** `DeployCreGovernance.s.sol` stands up an OZ `TimelockController` fronting a `CreWorkflowOwner` adapter (the linked owner of the CRE workflow in the WorkflowRegistry). Record the **adapter address** — it becomes `WORKFLOW_OWNER` for the protocol deploy.

   ```bash
   TIMELOCK_PROPOSER=0xGovernanceWallet \
   TIMELOCK_MIN_DELAY=604800 \
   DEPLOYER_ADDRESS=0xMainnetGasPayer \
   forge script script/DeployCreGovernance.s.sol:DeployCreGovernance \
     --rpc-url $ETH_MAINNET_RPC --broadcast -vvvv
   ```

   Env: `WORKFLOW_REGISTRY` (default `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`, Ethereum-mainnet WorkflowRegistry 2.0.0); `WORKFLOW_NAME` (default `"osverify"` — plaintext, pinned in the adapter); `TIMELOCK_PROPOSER` (required); `TIMELOCK_MIN_DELAY` in seconds (e.g. `604800` = 7d). The script deploys the two contracts only; `linkSelfAsOwner` + `updateWorkflow` are separate **timelocked** operations.

2. **Deploy the protocol** with `DeployAmoyCre.s.sol` (testnet) / `DeployPolygonCre.s.sol` (mainnet) — deploys `CreOracleReceiver` into the `CRE_ORACLE_RECEIVER` slot wired to the forwarder + workflow owner from step 1.

3. **Deploy + register the CRE workflow** (separate `ospex-cre` repo) and point it at the receiver via the timelocked `linkSelfAsOwner` + `updateWorkflow`. Fund the CRE workflow owner **off-chain** (there is no on-chain LINK subscription).

### CreOracleReceiver env values (read exactly as the scripts read them)

| Env | Meaning |
|-----|---------|
| `KEYSTONE_FORWARDER` | Trusted KeystoneForwarder that delivers CRE reports. **No mainnet default — required.** The receiver reverts on the zero address. |
| `WORKFLOW_OWNER` | **Required.** The `CreWorkflowOwner` governance-adapter address from step 1. The receiver enforces this against the report-metadata owner. |
| `WORKFLOW_NAME` | **Immutable.** `0`/empty = owner-only binding (name not enforced). If enforced it MUST be the **SHA256-derived bytes10** the CRE engine stamps into report metadata, **NOT** `bytes10` of the plaintext name — a wrong value permanently bricks the immutable receiver. Must match the plaintext name pinned in `DeployCreGovernance` (default `"osverify"`). |
| `DEPLOYER_ADDRESS` | The funded EOA that broadcasts (gas payer). On mainnet it must equal the approved deployer (hard guard). |

---

## Testnet Deployment (Polygon Amoy, Chain ID 80002)

### Prerequisites

1. [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
2. Submodules initialized: `git submodule update --init --recursive`
3. Deployer wallet funded with POL for gas ([Polygon Faucet](https://faucet.polygon.technology/))
4. CRE governance deployed (step 1 of the CRE Deploy Flow) — you have the `WORKFLOW_OWNER` adapter address
5. CRE workflow owner funded **off-chain** (no on-chain LINK subscription)

### Deploy Command

```bash
WORKFLOW_OWNER=0xWorkflowOwnerAdapter \
forge script script/DeployAmoyCre.s.sol:DeployAmoyCre \
  --rpc-url https://rpc-amoy.polygon.technology \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  --via-ir \
  --optimize \
  -vvvv
```

`DeployAmoyCre` uses the CRE Amoy production KeystoneForwarder as its default; override with `KEYSTONE_FORWARDER=0x...` if needed. To use a different deployer wallet, prefix `DEPLOYER_ADDRESS=0xYourWallet`. To pin the immutable workflow name, set `WORKFLOW_NAME` to the SHA256-derived bytes10 value (see the CRE env table above).

### Post-Deploy Checklist (Amoy)

- [ ] Deployment script completed without reverts
- [ ] All module registrations verified (script checks this automatically)
- [ ] All 3 scorer modules recognized by `isApprovedScorer()` (script checks this automatically)
- [ ] Save all deployed contract addresses from the console output
- [ ] Confirm `CreOracleReceiver` is registered in the `CRE_ORACLE_RECEIVER` slot (script asserts this automatically)
- [ ] Confirm the deployed receiver's workflow owner == `WORKFLOW_OWNER` (the governance adapter)
- [ ] Deploy/register the CRE workflow (`ospex-cre`) and point it at this receiver via the timelocked `linkSelfAsOwner` + `updateWorkflow`
- [ ] Fund the CRE workflow owner **off-chain**
- [ ] Update downstream services (indexer, read API, market data writer, market maker, frontend) with the new contract addresses
- [ ] Run the post-deploy event smoke test from [`testing/POST_DEPLOY_SMOKE_TEST.md`](testing/POST_DEPLOY_SMOKE_TEST.md) — confirms downstream consumers decode every event payload correctly

---

## Mainnet Deployment (Polygon, Chain ID 137)

### Prerequisites

1. CRE governance deployed on **Ethereum mainnet** (step 1 of the CRE Deploy Flow) — you have the `WORKFLOW_OWNER` adapter address
2. The real Polygon-mainnet production **KeystoneForwarder** address, human-confirmed (`DeployPolygonCre` has **no default** for it)
3. `DEPLOYER_ADDRESS` equal to the approved mainnet deployer (hard guard in the script)
4. CRE workflow owner funded **off-chain**

### Deploy Command

```bash
DEPLOYER_ADDRESS=0xApprovedMainnetDeployer \
KEYSTONE_FORWARDER=0xPolygonMainnetForwarder \
WORKFLOW_OWNER=0xWorkflowOwnerAdapter \
forge script script/DeployPolygonCre.s.sol:DeployPolygonCre \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  --via-ir \
  --optimize \
  -vvvv
```

> **Do NOT use `https://polygon-rpc.com`** — it returns 401 as of March 2026. Use your Alchemy RPC URL from `.env`.

> To pin the immutable workflow name, also set `WORKFLOW_NAME` to the SHA256-derived bytes10 value (see the CreOracleReceiver env table). The plaintext name must match the one pinned in `DeployCreGovernance` (default `"osverify"`).

### Mainnet vs. Amoy Configuration

`DeployPolygonCre.s.sol` carries the canonical mainnet constants. The full per-network parameter list (with rationale) is in [`deployment/DEPLOYMENT_PARAMETERS.md`](deployment/DEPLOYMENT_PARAMETERS.md). Before any future redeploy, diff the script's constants against that reference. Headline values:

| Value | Amoy | Mainnet |
|-------|------|---------|
| KeystoneForwarder | CRE Amoy forwarder (script default) | **no default — set `KEYSTONE_FORWARDER`, human-confirmed** |
| Workflow Owner | `CreWorkflowOwner` adapter | `CreWorkflowOwner` adapter (Ethereum-mainnet governance) |
| Workflow Name | optional pin (SHA256-bytes10) | optional pin (SHA256-bytes10) |
| USDC | `0xB1D1c0...eaF8` (mock) | `0x3c499c...3359` (native) |
| Fee Receiver | deployer | `0xdaC630...5114` |
| Void cooldown | 1 day | 7 days |

### Post-Deploy Checklist (Mainnet)

- [ ] Deployment script completed without reverts
- [ ] All module registrations verified
- [ ] All 3 scorer modules recognized by `isApprovedScorer()`
- [ ] Contract source code verified on Polygonscan
- [ ] Confirm `CreOracleReceiver` is registered in the `CRE_ORACLE_RECEIVER` slot (script asserts this automatically)
- [ ] Confirm the deployed receiver's workflow owner == `WORKFLOW_OWNER` (the Ethereum-mainnet governance adapter)
- [ ] Deploy/register the CRE workflow (`ospex-cre`) and point it at this receiver via the timelocked `linkSelfAsOwner` + `updateWorkflow`
- [ ] Fund the CRE workflow owner **off-chain**
- [ ] Update all downstream services (indexer, read API, market data writer, market maker, frontend) with the new contract addresses
- [ ] Run the post-deploy event smoke test from [`testing/POST_DEPLOY_SMOKE_TEST.md`](testing/POST_DEPLOY_SMOKE_TEST.md)
- [ ] Test with small positions before announcing

---

## Deployment Order

The deploy scripts create contracts in this order:

1. **OspexCore** — immutable core registry and event hub
2. **ContestModule** — sports events (needs OspexCore)
3. **LeaderboardModule** — competitions, ROI tracking, prizes
4. **RulesModule** — leaderboard eligibility rules
5. **MoneylineScorerModule** — moneyline bet scoring
6. **SpreadScorerModule** — spread bet scoring
7. **TotalScorerModule** — over/under scoring
8. **MatchingModule** — EIP-712 signed-order matching
9. **TreasuryModule** — fee collection and prize pools (needs USDC + fee receiver)
10. **SpeculationModule** — market lifecycle (needs void cooldown)
11. **PositionModule** — user fund escrow (needs USDC)
12. **SecondaryMarketModule** — position trading (needs USDC)
13. **CreOracleReceiver** — Chainlink CRE oracle receiver (needs KeystoneForwarder + workflow owner + optional immutable workflow name)

After deployment: all modules registered with OspexCore via `bootstrapModules()`, then `finalize()` permanently locks the registry. No admin key remains.

See [TRUST_MODEL.md](TRUST_MODEL.md) for the full trust model.

---

## EIP-712 Domain Separator

`MatchingModule` uses OpenZeppelin's `EIP712("Ospex", "1")` which computes the domain separator from `block.chainid` at runtime. No hardcoded chain ID anywhere — it's automatically 80002 on Amoy and 137 on mainnet.

---

## Known Amoy Testnet Quirks

Amoy is a checkpoint, not a destination. These are known issues — **do not rabbit-hole on them**:

- **Gas estimation oddities**: Amoy gas estimates can be wildly inaccurate. If a transaction fails with "out of gas" but works on the Anvil fork, try bumping the gas limit manually with `--gas-limit`.
- **Event indexing delays / out-of-order events**: Amoy's block production is irregular. Events may appear out of order or with significant delays. Downstream indexers may see events late on Amoy — this is the network, not a bug.
- **RPC flakiness**: `rpc-amoy.polygon.technology` drops connections periodically. If `forge script` fails mid-broadcast, check the broadcast log (`broadcast/`) for which transactions landed and resume manually.
- **Contract verification failures**: Polygonscan Amoy verification can time out or return spurious errors. Retry, or verify manually via the Polygonscan UI.
- **CRE report latency / log-trigger lag**: CRE workflow reports on Amoy can take minutes. There is also a registration-lag gotcha — emit oracle requests several minutes *after* `cre workflow deploy` (no backfill of pre-deploy events). Don't assume scoring is broken if it's slow.

**Rule of thumb**: If it works on the Anvil fork but acts weird on live Amoy, it's probably Amoy. Move on to mainnet when the deployment sequence and contract registrations are confirmed.

---

## Local Deployment

The Functions-era pure-Anvil script (`DeployAnvilFull.s.sol`, with `MockLinkToken` / `MockFunctionsRouter` mocks) was removed in the R5 CRE migration — CRE has no on-chain LINK/router to mock. For local end-to-end testing, run `DeployAmoyCre.s.sol` against an Anvil **fork** of Amoy (see [Local Anvil Fork Test](#local-anvil-fork-test-run-this-first) above): the fork supplies the real token + KeystoneForwarder addresses the receiver needs. Note that CRE workflow reports do not arrive on a local fork (no DON write-back), so scoring is exercised against live Amoy / mainnet, not locally.

For unit-testing contract interactions without any external dependencies, use the Foundry test suite (`forge test`), which constructs all modules and mocks in-memory.
