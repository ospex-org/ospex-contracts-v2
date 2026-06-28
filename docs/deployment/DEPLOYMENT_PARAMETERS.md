# Deployment Parameters — Ospex R5 (Zero-Admin, Chainlink CRE oracle)

All values are immutable after `finalize()`. There is no upgrade path — a mistake means redeploying the entire protocol.

> **Oracle:** R5 replaces the retired Chainlink Functions `OracleModule` with `CreOracleReceiver` (in the `CRE_ORACLE_RECEIVER` slot). The non-oracle params (fees, void cooldown, USDC, fee receiver, approved deployer) are unchanged from R4; only the oracle params changed — from Functions (LINK / Functions Router / DON ID / subscription / approved signer / script approvals) to CRE (KeystoneForwarder / Workflow Owner / Workflow Name). There is no LINK, no Functions Router, no DON ID, no Functions subscription, and no approved signer.

## Constructor Parameters

| Parameter | Anvil | Amoy | Mainnet | Description | Notes |
|-----------|-------|------|---------|-------------|-------|
| **Protocol Receiver** | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (Anvil #0) | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` (deployer) | `0xdaC630aE52b868FF0A180458eFb9ac88e7425114` | TreasuryModule `protocolReceiver_` — receives all protocol fees | Confirmed |
| **Void Cooldown** | `3 days` (259200) | `1 days` (86400) | `7 days` (604800) | SpeculationModule `voidCooldown` — time after which an unmatched speculation can be voided | Confirmed — differentiated per network for fast Amoy testing and conservative mainnet window |
| **Contest Creation Fee** | `1_000_000` | `1_000_000` | `1_000_000` | TreasuryModule `contestCreationFeeRate` — 1.00 USDC | Same across all networks |
| **Speculation Creation Fee** | `500_000` | `500_000` | `500_000` | TreasuryModule `speculationCreationFeeRate` — 0.50 USDC split between maker and taker | Same across all networks |
| **Leaderboard Creation Fee** | `500_000` | `500_000` | `500_000` | TreasuryModule `leaderboardCreationFeeRate` — 0.50 USDC | Same across all networks |
| **KeystoneForwarder** | CRE Amoy forwarder (script default) | CRE Amoy forwarder (script default) | **`KEYSTONE_FORWARDER` env — no default** | CreOracleReceiver `forwarder` — the trusted Chainlink KeystoneForwarder, the only valid `onReport` caller | Mainnet value is deliberately NOT hardcoded/guessed; it MUST be set to the real Polygon-mainnet forwarder and human-confirmed before deploy (the script reverts on a zero/unset value) |
| **Workflow Owner** | `WORKFLOW_OWNER` env | `WORKFLOW_OWNER` env | `WORKFLOW_OWNER` env — no default | CreOracleReceiver `workflowOwner` — the expected report-metadata workflow owner | On a governed mainnet deploy this is the `OspexCreTimelock` address on Ethereum mainnet (the timelock that is the direct linked owner of the WorkflowRegistry, deployed via `DeployOspexCreTimelock`). MUST be set to the real value |
| **Workflow Name** | `WORKFLOW_NAME` env (0 = off) | `WORKFLOW_NAME` env (0 = off) | `WORKFLOW_NAME` env (0 = off; pin RECOMMENDED for mainnet) | CreOracleReceiver `workflowName` (bytes10) — optional immutable pin; enforced when non-zero | **bytes10 of the SHA256-derived metadata value, NOT plaintext.** The CRE engine stamps `SHA256(name)` → first 10 hex chars → those 10 ASCII chars as bytes. Passing the plaintext name would make `onReport` reject every report (permanent brick). Must equal SHA256 of the exact name registered via the timelocked `upsertWorkflow` on the WorkflowRegistry (default `"osverify"`). 0 = name not enforced (owner-only binding) |

## External Contract Addresses

| Parameter | Anvil | Amoy | Mainnet | Description |
|-----------|-------|------|---------|-------------|
| **USDC** | Mock ERC20 (deployed by script) | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | Token for TreasuryModule, PositionModule, SecondaryMarketModule |

The CRE oracle has no external token or router dependency — there is no LINK token and no Functions Router. The only external oracle dependency is the **KeystoneForwarder** (see the Constructor Parameters table above), which is set per-network via the `KEYSTONE_FORWARDER` env.

## Hardcoded Constants (not configurable)

These are baked into the contracts and cannot be changed at deployment. Listed for reference.

| Constant | Value | Location | Description |
|----------|-------|----------|-------------|
| ODDS_SCALE | `100` | MatchingModule, RulesModule | 1.91 odds = 191 ticks. Minimum riskAmount granularity = 100 (0.0001 USDC) |
| MIN_ODDS | `101` | MatchingModule | Minimum valid odds tick (1.01x) |
| EIP-712 Domain (Matching) | name="Ospex", version="1" | MatchingModule | Commitment signature domain. chainId and verifyingContract auto-set |

## Post-Finalize Setup (not constructor params)

These are runtime operations done after deployment, not baked into constructors.

| Step | Anvil | Amoy | Mainnet | Notes |
|------|-------|------|---------|-------|
| Deploy / register the CRE workflow | N/A | `ospex-cre` workflow on Amoy | `ospex-cre` workflow, owned directly by the `OspexCreTimelock` | Point the workflow config (`receiverAddress` + `eventAddress`) at this `CreOracleReceiver` |
| Point the workflow at the receiver | N/A | Direct workflow update | Timelocked raw `linkOwner` + `upsertWorkflow` registry calls via the `OspexCreTimelock` (schedule/execute, 7-day delay + 2-of-3 Safe gate) | The receiver's `workflowOwner` must match the registered workflow owner |
| Fund the CRE workflow **off-chain** | N/A | Workflow-owner CRE balance | Workflow-owner CRE balance | No per-call LINK and no on-chain subscription — the workflow run is funded off-chain at the workflow owner |
| Provision data-provider secrets | N/A | CRE secrets | CRE secrets | API keys for The Rundown / Sportspage / JSONOdds, held by the CRE workflow (not on-chain) |
| Update downstream services | N/A | indexer, read API, market data writer, market maker, frontend | indexer, read API, market data writer, market maker, frontend | New contract addresses in each service's config |
