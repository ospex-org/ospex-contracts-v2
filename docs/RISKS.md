# Ospex Protocol — Risk Assessment

> **Last updated**: 2026-04-19
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

The smart contracts have not been professionally audited. All 13 deployed contracts (OspexCore + 12 modules) were developed by a solo founder with peer review from an experienced developer and an extensive hardening cycle (562 tests passing, zero HIGH findings in self-review).

**What this means:**
- There may be undiscovered vulnerabilities — reentrancy paths, integer edge cases, incorrect access control, or economic exploits that a professional audit would catch.
- The protocol uses established libraries (OpenZeppelin ReentrancyGuard, SafeERC20, EIP712, ECDSA) and follows Checks-Effects-Interactions, but these mitigations are only as good as their application.
- Every other risk in this document is amplified by the absence of an audit.
- **The zero-admin model means there is no upgrade path.** If a critical bug is found, the only recourse is deploying new contracts and migrating users. The deployer cannot hotfix, pause, or swap modules.

**Mitigation:**
- Source code is publicly available for review.
- The hardening cycle eliminated all admin powers, reducing the attack surface to contract logic bugs only.
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

Contest outcomes are determined by Chainlink Functions executing JavaScript code that queries three independent sports data APIs. The scorer service that triggers these oracle calls is a centralized service operated by the protocol developer.

**Risk factors:**
- The scorer service is a single point of failure. If it goes down, contests are not scored, and speculations cannot be settled. User funds remain locked in PositionModule until scoring or voiding occurs.
- Chainlink Functions has its own availability and rate-limit constraints. Extended Chainlink downtime would delay scoring.
- The approved signer (`i_approvedSigner`) must correctly vet scripts before signing approvals. A malicious or buggy approved script could submit incorrect data.

**Mitigation:**
- **Triple-source verification**: The scoring JS queries three independent APIs (The Rundown, Sportspage Feeds, JSONOdds) and requires unanimous agreement. If any source disagrees, the script throws and no on-chain state is written. An attacker would need to compromise three independent providers simultaneously.
- **Permissionless oracle calls**: `scoreContestFromOracle()` can be called by anyone (caller pays LINK). If the primary scorer service is down, any party with the JS source and LINK can trigger scoring.
- **Auto-void fallback**: If a contest is never scored, `settleSpeculation()` auto-voids all speculations after the void cooldown (1 day on Amoy, 7 days on mainnet). Users recover their risk amounts.
- **Hash-locked scripts**: Scoring JS must match the per-contest stored hash. Runtime substitution is impossible.
- **Source code is public**: The oracle JS is available at [`ospex-org/ospex-source-files-and-other`](https://github.com/ospex-org/ospex-source-files-and-other). Anyone can verify the scoring logic.

**Residual risk:** Users must trust that the triple-source oracle submits correct scores. While unlikely, a simultaneous data error across all three providers would result in incorrect settlement with no on-chain recourse — scores are final once written.

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

---

## 5. Liquidity & Market Risks — HIGH

Ospex is a peer-to-peer protocol. Positions require a counterparty.

**Thin Order Book:**
- The protocol currently has limited organic liquidity. Most markets have few or no resting commitments from human participants.
- A single automated market maker (agent "Michelle") provides the majority of liquidity. If this agent goes offline, most markets would have no counterparty available.
- Makers who set long expiry timestamps or unfavorable odds may find no taker.

**Commitment Expiry Risk:**
- Signed commitments are valid until their expiry timestamp. A maker must actively cancel (via `cancelCommitment` or `raiseMinNonce`) or wait for expiry to withdraw from a market. There is no automatic cancellation.
- Once a commitment is matched and a position is filled, it is locked until the speculation is settled or the position is sold on the secondary market.

**Single Market Maker Dependency:**
- The automated market maker is operated by the protocol developer. Its pricing, risk limits, and availability are controlled by a single party.
- If the market maker's strategy has a flaw, it could create systematically mispriced markets.

---

## 6. Infrastructure & Operational — HIGH

The protocol's off-chain infrastructure has no redundancy.

**Single Developer:**
- All smart contracts, the scorer service, the agent server, the API server, and the frontend are built and maintained by one person.

**Hosting:**
- The agent server, API server, and scorer run on Heroku. A Heroku outage would take down automated market making and contest scoring simultaneously.
- No failover deployment exists on a second provider.
- Firebase (Google Cloud) stores off-chain contest and position metadata. A Firebase outage would degrade the frontend but would not affect on-chain funds or contract logic.

**Monitoring:**
- Production logs are available via Papertrail (SolarWinds) with ~2-day retention. There are no automated alerts for critical failures (e.g., scorer downtime, agent crashes).

**Key Management:**
- The approved signer key (used for script approvals) is a trust dependency. Compromise would allow an attacker to approve malicious scripts for new contests. The signer address is immutable — it cannot be rotated.
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

**Chainlink LINK Costs:**
- Oracle requests require LINK payment. The protocol's Chainlink subscription must be funded. If LINK price spikes or the subscription runs dry, contest creation and scoring are blocked until refunded.

---

## Other Properties

- **Zero vigorish.** There is no built-in house edge on odds — users set their own prices via EIP-712 signed commitments.
- **Zero admin.** After `finalize()`, no address has any privileged on-chain capability. There is no admin key to compromise, no governance to capture, no multisig to social-engineer.
- **No proxy pattern.** Contracts are not upgradeable via proxy. There is no `delegatecall` to an implementation contract that can be silently swapped.
- **PositionModule has zero admin functions.** The contract that holds all user funds has no privileged functions. USDC leaves only via user claims or secondary market transfers.
- **ReentrancyGuard on all fund-transferring functions.** PositionModule, TreasuryModule, LeaderboardModule, SecondaryMarketModule, OracleModule, and MatchingModule all use OpenZeppelin's ReentrancyGuard.
- **SafeERC20 for all token transfers.** No raw `.transfer()` calls.
- **EIP-712 signatures.** Commitment signatures (MatchingModule) and script approvals (OracleModule) use typed structured data signing.
- **Triple-source oracle.** Contest creation and scoring require unanimous agreement from three independent sports data APIs.
- **Permissionless oracle calls.** Anyone can trigger contest creation, market updates, or scoring by calling OracleModule directly and paying LINK.
- **No pause mechanism.** There is no admin kill switch that can freeze the protocol. Users cannot be locked out by admin action.
- **Hash-locked scripts.** Oracle JS is validated against per-contest stored hashes. Runtime substitution is impossible.
- **Auto-void fallback.** Unscored contests are automatically voided after the cooldown, returning risk to all participants.

---

## Companion Documents

- [TRUST_MODEL.md](./TRUST_MODEL.md) — Zero-admin trust model, what can and can't change, fund safety
- [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md) — Intentional behaviors and hardening decisions
- [ARCHITECTURE.md](./ARCHITECTURE.md) — Smart contract architecture and module overview
- [DEPLOYMENT.md](./DEPLOYMENT.md) — Contract addresses and network configuration

---

*This document will be updated as risks change. It reflects the protocol's state as of the date above.*
