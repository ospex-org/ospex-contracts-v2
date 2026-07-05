# Ospex Protocol — Risk Assessment

> **As of commit**: `b3d6647`
> **Last updated**: 2026-07-05
> **Chain**: Polygon mainnet (chain ID 137) / Polygon Amoy testnet (chain ID 80002)
> **Trust model**: Zero-admin (bootstrap-then-finalize)

> **Disclaimer**: This is a self-assessment written by the protocol developer. It has not been reviewed, validated, or endorsed by any independent auditor or security firm. It should not be treated as a substitute for a professional audit. The purpose of this document is to honestly surface known risks so that users and integrators can make informed decisions.

---

## Severity Scale

| Severity | Definition |
|----------|------------|
| **Critical** | Could result in total loss of user funds or protocol-wide failure. Requires immediate attention or acceptance of existential risk. |
| **High** | Could result in partial loss of funds, prolonged service disruption, or significant trust degradation. Active mitigation planned or in progress. |
| **Medium** | Could cause inconvenience, minor fund lockups, or degraded functionality. Workarounds exist or impact is bounded. |
| **Low** | Unlikely to cause material harm under normal conditions. Theoretical or dependent on external system failures. |

---

## 1. No Professional Audit — CRITICAL

The smart contracts have not been professionally audited. All 13 deployed contracts (OspexCore + 12 modules) were developed by a solo founder with peer review from an experienced developer and an extensive hardening cycle (a comprehensive passing test suite, zero HIGH findings in self-review).

**What this means:**
- There may be undiscovered vulnerabilities — reentrancy paths, integer edge cases, incorrect access control, or economic exploits that a professional audit would catch.
- The protocol uses established libraries (OpenZeppelin ReentrancyGuard, SafeERC20, EIP712, ECDSA) and follows Checks-Effects-Interactions, but these mitigations are only as good as their application.
- **The zero-admin model means there is no upgrade path.** If a critical bug is found, the only recourse is deploying new contracts and migrating users. The deployer cannot hotfix, pause, or swap modules.

**Mitigation:**
- Source code is publicly available for review, with function-level process maps in [E2E_TRACES.md](./E2E_TRACES.md) to make independent review practical.
- The hardening cycle eliminated all admin powers, reducing the attack surface to contract logic bugs only.
- The protocol is under active maintenance and review: an internal adversarial engineering review (2026-07-05; 32 independent review agents, 253 source-verified claims) found no fund-safety issues, and its findings — documentation gaps and the leaderboard scaling bounds in §4 — are incorporated into this document set. This is not a substitute for an independent audit.
- A professional audit is planned but has not been scheduled.

**User guidance:** Do not deposit funds you cannot afford to lose.

---

## 2. No Emergency Response Capability — HIGH

The zero-admin model means the protocol has no emergency controls. There is no pause, no module swap, no admin override.

**What this means:**
- If a critical vulnerability is discovered, the deployer cannot halt the protocol to prevent exploitation.
- If a module has a bug, it cannot be replaced — the module registry is permanently locked after `finalize()`.
- If fee rates need adjustment, they cannot be changed — they are set in the TreasuryModule constructor.

**What the deployer cannot do:**
- Pause any contract (no pause mechanism exists)
- Swap or replace any module (registry is finalized)
- Change fee rates, void cooldown, or protocol receiver (all immutable)
- Withdraw escrowed USDC from PositionModule (zero admin functions)
- Override or correct oracle scores (scores are final once set)

**Mitigation:**
- The hardening cycle eliminated admin-key risk entirely — there is no key to compromise, no admin to bribe, no governance to capture.
- The protocol's attack surface is limited to contract logic. Admin-key attacks, governance attacks, and module-swap attacks are structurally impossible.
- If a critical bug is found, a new deployment can be prepared while existing funds remain safe (PositionModule has no extraction vector — funds can only leave via user claims or secondary market transfers).

**See also:** [TRUST_MODEL.md](./TRUST_MODEL.md) for the full trust model and trade-off analysis.

---

## 3. Oracle & Settlement — HIGH

Contest outcomes are determined by an off-chain Chainlink CRE workflow that queries three independent sports data APIs and reports back through a trusted KeystoneForwarder to `CreOracleReceiver`. The CRE workflow is operated and funded off-chain by the protocol developer.

**Risk factors:**
- The CRE workflow (and the data-provider API access it depends on) is a single point of liveness. If the operator stops running or funding it, contests are not scored, and speculations cannot be settled until scoring or voiding occurs.
- A compromise of the CRE governance controller could, after the 7-day timelock delay, push a malicious workflow update or pause the workflow (see §6, Key Management).

**Mitigation:**
- **Triple-source verification**: The CRE workflow queries three independent APIs (The Rundown, Sportspage Feeds, JSONOdds) and requires unanimous agreement. If any source disagrees, no report is produced and no on-chain state is written. An attacker would need to compromise three independent providers simultaneously.
- **Permissionless requests**: `requestScore()` (and the verify/market entrypoints) can be called by anyone — there is no per-call LINK and no on-chain subscription. The CRE workflow run is funded off-chain by the workflow owner.
- **Auto-void fallback**: If a contest is never scored, `settleSpeculation()` auto-voids all speculations after the void cooldown (1 day on Amoy, 7 days on mainnet). Users recover their risk amounts permissionlessly — there is no operator gate on settle/claim.
- **Passive on-chain validation**: `CreOracleReceiver` accepts a report only from the immutable KeystoneForwarder, with matching workflow owner/name, correct chain/receiver, per-report idempotency, and fail-closed request binding (a report must correspond to a receiver-emitted request). There are no on-chain script approvals.
- **Timelock-governed workflow**: The CRE workflow is owned directly by an `OspexCreTimelock` per-action timelock (a close port of Chainlink's audited `Timelock.sol`), whose proposer/executor/canceller is held by a single cold-wallet controller, with a 7-day mainnet delay on workflow code updates — so any change to the verification/scoring logic is observable on-chain before it can take effect.

**Residual risk:** Users must trust that the triple-source CRE workflow reports correct scores. While unlikely, a simultaneous data error across all three providers would result in incorrect settlement with no on-chain recourse — scores are final once written. The operator can halt scoring (triggering auto-void/refund) but cannot steal or trap funds.

---

## 4. Smart Contract Design Notes — MEDIUM

Known edge cases and design decisions that users should be aware of.

### Solvency Dust

When a position is filled and settled, rounding in the odds calculation (oddsTick with ODDS_SCALE = 100) can leave small USDC dust amounts (typically < 0.01 USDC) in PositionModule. This dust is permanently locked — there is no sweep function, and this is by design (adding a sweep for PositionModule would create a fund extraction vector). Over a long enough timeline, dust accumulates but remains negligible relative to protocol volume.

### Commitment Expiry as Sole Temporal Guard

The MatchingModule does not check contest start time when executing a match. Commitments are valid as long as they haven't expired (`block.timestamp < expiry`). This means live betting is technically possible if makers set long expiry timestamps. The protocol is currently optimized for pre-contest-start speculation. See [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md#live-betting-allowed-via-commitment-expiry) for full rationale.

### Secondary Market Active but Leaderboard-Ineligible

SecondaryMarketModule is deployed and functional. Positions transferred via the secondary market are permanently flagged (`acquiredViaSecondaryMarket = true`) and cannot be registered for any leaderboard.

### Prize Pool Dust

Leaderboard prize distribution divides the pool among winners. Rounding can leave small amounts in TreasuryModule. There is no admin sweep — this dust remains in the contract indefinitely.

### Leaderboard Scaling & Configuration Bounds

The leaderboard layer is the only part of the protocol whose transaction gas grows with user input (the core match/fill/settle/claim paths are all constant-cost). Measured with Foundry against the deployed source, under cold-storage conditions:

- **ROI submission is linear in registered positions.** `submitLeaderboardROI` costs ≈ 142k gas plus ≈ 20.4k gas per registered position (worst case — every position a winner). It is one-shot, non-paginated, and must fit in a single transaction inside the fixed ROI window: against a 30M gas ceiling that is roughly 1,400 positions; against Polygon's current 160M block gas limit, roughly 7,800. A user who registers more positions than fit in one transaction cannot submit at all and forfeits — there is no pagination and no alternate claim path. Because each registered position requires a distinct creator-whitelisted (contest, scorer) slot, ordinary leaderboards sit far below these bounds; creators should still keep eligible-market counts sane (hundreds, not thousands).
- **There is no prospective-ROI view function.** To preview ROI before submitting, simulate `submitLeaderboardROI` via `eth_call` (subject to the RPC provider's gas cap, commonly 50M ≈ roughly 2,400 positions).
- **Settle before you submit.** ROI reads each speculation's live outcome at submission time; a scored-but-not-yet-settled speculation still reads as TBD and contributes zero — permanently, since submission is final. Call the permissionless `settleSpeculation()` on every market you registered before submitting. See [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md#leaderboard-roi-submission-is-one-shot-and-timing-dependent).
- **Exact-ROI ties are reproducible** (identical declared bankroll and identical positions produce identical ROI), and tie handling has two costs that grow with the tie-cohort size: the next strictly-higher submitter pays to clear the previous tied-winner list inside their own transaction, and every prize claimant pays a linear membership scan. A deliberately manufactured mega-tie (thousands of sybil entries at the same ROI) could make out-submitting the cohort prohibitively expensive inside the fixed window. **Creator guidance:** for leaderboards with meaningful prize pools, set a non-zero entry fee and a non-zero minimum bet percentage — both make sybil ties expensive — and prefer curated, bounded speculation whitelists.

---

## 5. Liquidity & Market Risks — HIGH

Ospex is a peer-to-peer protocol. Positions require a counterparty.

**Thin Order Book:**
- The protocol currently has limited organic liquidity. Most markets have few or no resting commitments from human participants.
- A single automated market maker provides the majority of resting commitments. If it goes offline, most markets would have no counterparty available.
- Makers who set long expiry timestamps or unfavorable odds may find no taker.

**Commitment Expiry Risk:**
- Signed commitments are valid until their expiry timestamp. A maker must actively cancel (via `cancelCommitment` or `raiseMinNonce`) or wait for expiry to withdraw from a market. There is no automatic cancellation.
- Once a commitment is matched and a position is filled, it is locked until the speculation is settled or the position is sold on the secondary market.

**Single Market Maker Dependency:**
- The primary market maker is operated by the protocol developer. Its pricing, risk limits, and availability are controlled by a single party.
- If the market maker's strategy has a flaw, it could create systematically mispriced markets.

---

## 6. Infrastructure & Operational — HIGH

The protocol's off-chain infrastructure has no redundancy.

**Single Developer:**
- All smart contracts, the off-chain market data writer, the indexer, the read API, the market maker, and the frontend are built and maintained by one person.

**Hosting:**
- All off-chain services (writer, indexer, read API, market maker) run on Heroku. A Heroku outage would take down automated market making and contest scoring simultaneously.
- No failover deployment exists on a second provider.
- Supabase (Postgres + Realtime) stores off-chain contest, commitment, and position metadata projected from on-chain events. A Supabase outage would degrade the frontend, market maker, and read API but would not affect on-chain funds or contract logic — settled positions can still be claimed directly from PositionModule.

**Monitoring:**
- There is no centralized log aggregation or automated alerting for critical failures (e.g., scorer downtime, market maker crashes). Service-level logs are accessed per-app via the Heroku CLI.

**Key Management:**

- **CRE workflow-owner / governance compromise**: The CRE workflow is owned directly by an `OspexCreTimelock` per-action timelock (a close port of Chainlink's audited `Timelock.sol`), whose proposer/executor/canceller is held by a single cold-wallet controller. A compromise of that controller could, after the 7-day timelock delay, push a malicious workflow update or pause the workflow. It **cannot pause the oracle quickly** (pause is reachable but inherits the 7-day delay — only Vault secret allowlist requests have the 1-second fast lane) and **cannot touch protocol funds** (settlement is immutable; PositionModule has zero admin functions). *Mitigations:* every code/lifecycle operation must be scheduled on-chain and is observable for the full 7-day window before it can take effect, so a malicious operation can be seen — and cancelled, or the protocol exited — before it lands; the auto-void/refund floor still returns principal permissionlessly regardless. As the protocol matures, the controller roles can be migrated to a multisig via a 7-day governance operation to remove the single-key dependency.
- **Residual operator-liveness risk:** The operator can **halt scoring** (e.g. by not running the workflow), which causes affected contests to **auto-void and refund** after the cooldown. Principal is always recoverable permissionlessly — no operator gate on settle/claim.
- Agent wallet private keys are stored without hardware security module (HSM) or multisig protection.

---

## 7. Regulatory — MEDIUM

Ospex is a peer-to-peer sports speculation protocol. Its legal status varies by jurisdiction.

**United States:**
- The U.S. Commodity Futures Trading Commission (CFTC) has asserted jurisdiction over event contracts and binary options. Ospex does not hold any CFTC registration or exemption. Users in the United States should assess their own legal risk.

**Global:**
- Sports prediction and event contract regulations differ significantly across jurisdictions. Some countries prohibit online betting entirely; others require licensed operators. This document does not attempt to cover all jurisdictions.
- The protocol has no KYC/AML process. Any wallet can interact with the contracts.

**This section is informational, not legal advice.** Users are responsible for understanding and complying with the laws of their own jurisdiction.

---

## 8. Economic — LOW

External economic factors that could affect the protocol under unusual conditions.

**USDC Depeg:**
- All positions are denominated in native USDC on Polygon. A USDC depeg event would affect the real-world value of all escrowed funds. The protocol has no mechanism to hedge or respond to a depeg — positions would continue to settle in USDC regardless of its market price.

**Polygon Congestion:**
- During periods of high Polygon network congestion, transaction costs increase and confirmation times lengthen. This could delay position matching, claiming, and scoring. In extreme cases, users might miss commitment expiry windows.

**Gas Costs:**
- While Polygon gas is typically inexpensive, complex operations (matching with speculation auto-creation, scoring contests) consume meaningful gas. A sustained spike in POL price or base fees could make small positions uneconomical.

**CRE Workflow Funding:**
- Oracle work runs off-chain in the Chainlink CRE workflow, funded off-chain by the workflow owner. There is no per-call LINK and no on-chain Chainlink subscription. If the workflow owner stops funding the workflow, scoring halts — affected Verified contests then auto-void and refund after the cooldown rather than locking funds.

---

## Other Properties

- **Zero vigorish.** There is no built-in house edge on odds — users set their own prices via EIP-712 signed commitments.
- **Zero admin.** After `finalize()`, no address has any privileged on-chain capability. There is no admin key to compromise, no governance to capture, no multisig to social-engineer.
- **No proxy pattern.** Contracts are not upgradeable via proxy. There is no `delegatecall` to an implementation contract that can be silently swapped.
- **PositionModule has zero admin functions.** The contract that holds all user funds has no privileged functions. USDC leaves only via user claims or secondary market transfers.
- **ReentrancyGuard on all fund-transferring functions.** PositionModule, TreasuryModule, LeaderboardModule, SecondaryMarketModule, and MatchingModule all use OpenZeppelin's ReentrancyGuard.
- **SafeERC20 for all token transfers.** No raw `.transfer()` calls.
- **EIP-712 signatures.** Commitment signatures (MatchingModule) use typed structured data signing.
- **Triple-source oracle.** Contest verification and scoring require unanimous agreement from three independent sports data APIs, enforced inside the off-chain CRE workflow.
- **Permissionless oracle requests.** Anyone can trigger contest creation, market updates, or scoring via the CreOracleReceiver request entrypoints — there is no per-call LINK and no on-chain subscription.
- **Passive on-chain oracle validation.** `CreOracleReceiver` has no admin function; it accepts a report only when it clears the `onReport` trust funnel (trusted KeystoneForwarder, matching workflow owner/name, domain separation, per-report idempotency, fail-closed request binding). There are no on-chain script approvals.
- **No pause mechanism.** There is no admin kill switch that can freeze the protocol. Users cannot be locked out by admin action.
- **Timelock-governed oracle workflow.** The off-chain CRE workflow is owned directly by an `OspexCreTimelock` per-action timelock (a close port of Chainlink's audited `Timelock.sol`), with proposer/executor/canceller held by a single cold-wallet controller. Pause, code-update, delete, and other lifecycle ops are reachable but timelocked 7 days; only Vault secret allowlist requests (every `cre secrets` op) have a 1-second fast lane.
- **Auto-void fallback.** Unscored contests are automatically voided after the cooldown, returning risk to all participants.

---

## Companion Documents

- [TRUST_MODEL.md](./TRUST_MODEL.md) — Zero-admin trust model, what can and can't change, fund safety
- [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md) — Intentional behaviors and hardening decisions
- [ARCHITECTURE.md](./ARCHITECTURE.md) — Smart contract architecture and module overview
- [DEPLOYMENT.md](./DEPLOYMENT.md) — Contract addresses and network configuration

---

*This document will be updated as risks change. It reflects the protocol's state as of the date above.*
