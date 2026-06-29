# Deployment

## Mainnet Contract Addresses (Polygon, Chain ID 137)

**Current deploy:** Round 5 (CRE oracle migration), 2026-06-28 (first tx block 89322650). R5 replaces the Chainlink Functions `OracleModule` with `CreOracleReceiver` in the `CRE_ORACLE_RECEIVER` slot, governed by an `OspexCreTimelock` on **Ethereum mainnet**. The prior round (R4) is archived; see [`deployment/POLYGON_MAINNET_R4.md`](deployment/POLYGON_MAINNET_R4.md) for its full record.

> The address table below is the **live R5 deploy** (the current address-of-record), finalized and zero-admin. The oracle slot is now `CreOracleReceiver` (the R4 Functions `OracleModule` is retired). Ethereum-mainnet governance addresses are in the **Governance** subsection below the table.

| Contract | Address |
|----------|---------|
| OspexCore | [`0x40047BAFcdEd16C938058b7b67186299a2893561`](https://polygonscan.com/address/0x40047BAFcdEd16C938058b7b67186299a2893561) |
| ContestModule | [`0x0f838AF735E95625905c6acFB887a2E9f4DB9216`](https://polygonscan.com/address/0x0f838AF735E95625905c6acFB887a2E9f4DB9216) |
| SpeculationModule | [`0xEA21b58E91eDcA41d0c42A8655234F8A64fa31bc`](https://polygonscan.com/address/0xEA21b58E91eDcA41d0c42A8655234F8A64fa31bc) |
| PositionModule | [`0x3C71fdB8ABF41487a512440e5ce6490158C26e56`](https://polygonscan.com/address/0x3C71fdB8ABF41487a512440e5ce6490158C26e56) |
| MatchingModule | [`0x46Af20B6307Aa0Ec13de10EF58a02c5F1b5C9559`](https://polygonscan.com/address/0x46Af20B6307Aa0Ec13de10EF58a02c5F1b5C9559) |
| CreOracleReceiver (CRE_ORACLE_RECEIVER) | [`0x06e3470012039797119Ae30e1236169304F9220C`](https://polygonscan.com/address/0x06e3470012039797119Ae30e1236169304F9220C) |
| TreasuryModule | [`0x07f357e67cc9B48D029b1E4C9B7F45569a2eB85C`](https://polygonscan.com/address/0x07f357e67cc9B48D029b1E4C9B7F45569a2eB85C) |
| LeaderboardModule | [`0x02228F4bAB35d9631296C47C2103789474aD72ee`](https://polygonscan.com/address/0x02228F4bAB35d9631296C47C2103789474aD72ee) |
| RulesModule | [`0x5a5662C8246Ed3dC2422Cc8f773564fA41b34723`](https://polygonscan.com/address/0x5a5662C8246Ed3dC2422Cc8f773564fA41b34723) |
| SecondaryMarketModule | [`0xf779d82E9a11234767921A73913dAd429F140aFB`](https://polygonscan.com/address/0xf779d82E9a11234767921A73913dAd429F140aFB) |
| MoneylineScorerModule | [`0x59555106D4B5f1A797f3552f60ac418Eb6B6f6BD`](https://polygonscan.com/address/0x59555106D4B5f1A797f3552f60ac418Eb6B6f6BD) |
| SpreadScorerModule | [`0x8f293da716164d5A32dc087A85e5164D929ae9D4`](https://polygonscan.com/address/0x8f293da716164d5A32dc087A85e5164D929ae9D4) |
| TotalScorerModule | [`0xB4B1E2A2a75C34e9E4C5D3BB8A432aff973DaDa0`](https://polygonscan.com/address/0xB4B1E2A2a75C34e9E4C5D3BB8A432aff973DaDa0) |

**Token:** Native USDC ([`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)), 6 decimals — unchanged from R4

### Governance (Ethereum mainnet, Chain ID 1)

The CRE workflow owner / oracle governance is the `OspexCreTimelock`, deployed on **Ethereum mainnet** (where the CRE WorkflowRegistry 2.0.0 lives). It is the sole controller behind a **7-day delay** (with a 1-second fast lane for the `allowlistRequest` key-rotation op), self-administered, deployer renounced.

| Contract | Chain | Address |
|----------|-------|---------|
| OspexCreTimelock (workflow owner / governance) | Ethereum mainnet | [`0x40047BAFcdEd16C938058b7b67186299a2893561`](https://etherscan.io/address/0x40047BAFcdEd16C938058b7b67186299a2893561) |

> ⚠ **Same-address note:** the timelock's Ethereum address (`0x40047BAF…`) is the same string as the Polygon `OspexCore` above. This is expected, not an error — both were the first contract (nonce 0) deployed by the same one-time deployer, and CREATE addresses depend only on `(deployer, nonce)`, not the chain. They are **distinct contracts on distinct chains**. The CRE workflow is `osverify` (workflow id `0097efdade80ff0a9557d927a1c07075a453bba9cd0fae7e22519c613ec47805`); `WORKFLOW_NAME` enforcement is OFF (owner-only binding).

---

## Network Configuration

> **R5 (Chainlink CRE) configuration.** The R4 Chainlink Functions config (LINK token, Functions Router, DON ID, subscription 191/416) is **retired** — the oracle is now the `CreOracleReceiver` driven by an off-chain Chainlink CRE workflow. The receiver is wired to a trusted **KeystoneForwarder** and a **workflow owner** (the `OspexCreTimelock`), with an optional immutable **workflow-name** pin. CRE execution is funded **off-chain** at the workflow owner — there is no on-chain LINK subscription and no LINK-per-call.

| Parameter | Mainnet (Polygon) | Testnet (Amoy) |
|-----------|-------------------|----------------|
| Chain ID | 137 | 80002 |
| KeystoneForwarder (`KEYSTONE_FORWARDER`) | **no default — required** (Polygon mainnet production forwarder; must be human-confirmed) | CRE Amoy production forwarder (script default; overridable) |
| Workflow Owner (`WORKFLOW_OWNER`) | the `OspexCreTimelock` (the direct linked owner, from `DeployOspexCreTimelock` on Ethereum mainnet) | the CRE workflow owner address |
| Workflow Name (`WORKFLOW_NAME`, immutable) | optional pin — `0`/empty = owner-only binding; if enforced, the **SHA256-derived bytes10** the CRE engine stamps into report metadata (NOT bytes10 of the plaintext name) | same posture |
| Token | Native USDC (6 decimals) | Mock USDC (6 decimals) |
| USDC Address | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` |

> **Workflow-name footgun:** `WORKFLOW_NAME` is **immutable** on the receiver. If you enforce it, it MUST be the SHA256-derived bytes10 that the CRE engine stamps into report metadata (i.e. `SHA256(name)` → first 10 hex chars → those 10 ASCII chars as bytes), **not** `bytes10` of the plaintext name. Passing the plaintext value makes `onReport` reject every report and **permanently bricks the immutable receiver**. The plaintext name registered via the timelocked `upsertWorkflow` on the WorkflowRegistry (default `"osverify"`) and the name whose SHA256-bytes10 the receiver enforces **must be the same name** — this is a hard cross-component invariant.

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

The R5 oracle is a Chainlink CRE workflow whose on-chain receiver (`CreOracleReceiver`) is governed directly by a per-action timelock (`OspexCreTimelock`). Deploy in this order:

1. **Deploy governance on Ethereum mainnet FIRST.** `DeployOspexCreTimelock.s.sol` deploys the `OspexCreTimelock` — a per-action timelock that is the DIRECT raw-call linked owner of the CRE workflow in the WorkflowRegistry (there is no adapter and no OZ `TimelockController`). It is two-phase: `deploy()` stands up the timelock in its bootstrap state (global delay 0), then `configureAndLockdown()` raises the global delay to 7 days, sets the registry `allowlistRequest` fast lane to 1s, and hands ADMIN to the timelock itself. Record the **timelock address** — it becomes `WORKFLOW_OWNER` for the protocol deploy.

   ```bash
   DEPLOYER_ADDRESS=0xMainnetGasPayer \
   OSPEX_TIMELOCK_SAFE=0xTwoOfThreeSafe \
   forge script script/DeployOspexCreTimelock.s.sol:DeployOspexCreTimelock --sig 'deploy()' \
     --rpc-url $ETH_MAINNET_RPC --broadcast -vvvv
   ```

   Env: `WORKFLOW_REGISTRY` (default `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`, Ethereum-mainnet WorkflowRegistry 2.0.0); `OSPEX_TIMELOCK_SAFE` (the 2-of-3 Safe holding proposer/executor/canceller — required); `DEPLOYER_ADDRESS` (temporary admin / gas payer — required); `OSPEX_TIMELOCK_FINAL_DELAY` in seconds (default `604800` = 7d, applied in `configureAndLockdown()`). `deploy()` stands up the single timelock in its bootstrap state (global delay 0); the registry `linkOwner` + `upsertWorkflow` (and the `allowlistRequest` secret op) are separate calls the timelock issues via schedule/execute, then `configureAndLockdown()` raises the delay to 7d and locks down admin. The workflow name comes from the registered `upsertWorkflow`, not from this script.

2. **Deploy the protocol** with `DeployAmoyCre.s.sol` (testnet) / `DeployPolygonCre.s.sol` (mainnet) — deploys `CreOracleReceiver` into the `CRE_ORACLE_RECEIVER` slot wired to the forwarder + workflow owner from step 1.

3. **Deploy + register the CRE workflow** (separate `ospex-cre` repo) and point it at the receiver via the registry's timelocked `linkOwner` + `upsertWorkflow` (issued by the `OspexCreTimelock`). Fund the CRE workflow owner **off-chain** (there is no on-chain LINK subscription).

### CreOracleReceiver env values (read exactly as the scripts read them)

| Env | Meaning |
|-----|---------|
| `KEYSTONE_FORWARDER` | Trusted KeystoneForwarder that delivers CRE reports. **No mainnet default — required.** The receiver reverts on the zero address. |
| `WORKFLOW_OWNER` | **Required.** The `OspexCreTimelock` address from step 1. The receiver enforces this against the report-metadata owner. |
| `WORKFLOW_NAME` | **Immutable.** `0`/empty = owner-only binding (name not enforced). If enforced it MUST be the **SHA256-derived bytes10** the CRE engine stamps into report metadata, **NOT** `bytes10` of the plaintext name — a wrong value permanently bricks the immutable receiver. Must match the plaintext name registered via the timelocked `upsertWorkflow` on the WorkflowRegistry (default `"osverify"`). |
| `DEPLOYER_ADDRESS` | The funded EOA that broadcasts (gas payer). On mainnet it must equal the approved deployer (hard guard). |

---

## Testnet Deployment (Polygon Amoy, Chain ID 80002)

### Prerequisites

1. [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
2. Submodules initialized: `git submodule update --init --recursive`
3. Deployer wallet funded with POL for gas ([Polygon Faucet](https://faucet.polygon.technology/))
4. CRE governance deployed (step 1 of the CRE Deploy Flow) — you have the `WORKFLOW_OWNER` timelock address
5. CRE workflow owner funded **off-chain** (no on-chain LINK subscription)

### Deploy Command

```bash
WORKFLOW_OWNER=0xOspexCreTimelock \
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
- [ ] Confirm the deployed receiver's workflow owner == `WORKFLOW_OWNER` (the `OspexCreTimelock`)
- [ ] Deploy/register the CRE workflow (`ospex-cre`) and point it at this receiver via the registry's timelocked `linkOwner` + `upsertWorkflow`
- [ ] Fund the CRE workflow owner **off-chain**
- [ ] Update downstream services (indexer, read API, market data writer, market maker, frontend) with the new contract addresses
- [ ] Run the post-deploy event smoke test from [`testing/POST_DEPLOY_SMOKE_TEST.md`](testing/POST_DEPLOY_SMOKE_TEST.md) — confirms downstream consumers decode every event payload correctly

---

## Mainnet Deployment (Polygon, Chain ID 137)

### Prerequisites

1. CRE governance deployed on **Ethereum mainnet** (step 1 of the CRE Deploy Flow) — you have the `WORKFLOW_OWNER` timelock address
2. The real Polygon-mainnet production **KeystoneForwarder** address, human-confirmed (`DeployPolygonCre` has **no default** for it)
3. `DEPLOYER_ADDRESS` equal to the approved mainnet deployer (hard guard in the script)
4. CRE workflow owner funded **off-chain**

### Deploy Command

```bash
DEPLOYER_ADDRESS=0xApprovedMainnetDeployer \
KEYSTONE_FORWARDER=0xPolygonMainnetForwarder \
WORKFLOW_OWNER=0xOspexCreTimelock \
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

> To pin the immutable workflow name, also set `WORKFLOW_NAME` to the SHA256-derived bytes10 value (see the CreOracleReceiver env table). The plaintext name must match the one registered via the timelocked `upsertWorkflow` on the WorkflowRegistry (default `"osverify"`).

### Mainnet vs. Amoy Configuration

`DeployPolygonCre.s.sol` carries the canonical mainnet constants. The full per-network parameter list (with rationale) is in [`deployment/DEPLOYMENT_PARAMETERS.md`](deployment/DEPLOYMENT_PARAMETERS.md). Before any future redeploy, diff the script's constants against that reference. Headline values:

| Value | Amoy | Mainnet |
|-------|------|---------|
| KeystoneForwarder | CRE Amoy forwarder (script default) | **no default — set `KEYSTONE_FORWARDER`, human-confirmed** |
| Workflow Owner | `OspexCreTimelock` | `OspexCreTimelock` (Ethereum-mainnet governance) |
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
- [ ] Confirm the deployed receiver's workflow owner == `WORKFLOW_OWNER` (the Ethereum-mainnet `OspexCreTimelock`)
- [ ] Deploy/register the CRE workflow (`ospex-cre`) and point it at this receiver via the registry's timelocked `linkOwner` + `upsertWorkflow`
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
