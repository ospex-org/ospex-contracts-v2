# Ospex Protocol — Risk Assessment

> **Last updated**: 2026-02-20
> **Chain**: Polygon mainnet (chain ID 137)
> **OspexCore**: [`0x8016b2C5f161e84940E25Bb99479aAca19D982aD`](https://polygonscan.com/address/0x8016b2C5f161e84940E25Bb99479aAca19D982aD)

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

The smart contracts have not been professionally audited. All 12 deployed contracts (OspexCore + 11 modules) were developed by a solo founder with peer review from an experienced developer.

**What this means:**
- There may be undiscovered vulnerabilities in the contract logic — reentrancy paths, integer edge cases, incorrect access control, or economic exploits that a professional audit would catch.
- The protocol uses established libraries (OpenZeppelin AccessControl, SafeERC20, ReentrancyGuard) and follows Checks-Effects-Interactions, but these mitigations are only as good as their application.
- Every other risk in this document is amplified by the absence of an audit.

**Mitigation:**
- Source code is publicly available for review.
- The deployer retains `MODULE_ADMIN_ROLE` to swap modules if a bug is discovered (see [Admin Key Centralization](#2-admin-key-centralization--high)).
- A professional audit is planned but has not been scheduled.

**User guidance:** Do not deposit funds you cannot afford to lose.

---

## 2. Admin Key Centralization — HIGH

All admin power is held by a single deployer wallet (`0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886`). There is no multisig, no timelock, and no governance mechanism.

**What the deployer can do:**
- **Swap any module** via `registerModule()` — this is the most significant risk. A module swap could introduce a malicious replacement for new deposits, or temporarily block claims on existing positions (see [ADMIN_PRIVILEGES.md](./ADMIN_PRIVILEGES.md#module-swap-risk) for full analysis).
- **Redirect protocol fee revenue** via `setProtocolReceiver()` — affects fee income, not escrowed funds.
- **Sweep unclaimed leaderboard prizes** via `adminSweep()` — only after the claim window expires.
- **Adjust fee rates, position limits, and oracle parameters.**

**What the deployer cannot do:**
- Withdraw escrowed USDC from PositionModule (zero admin functions on that contract).
- Pause any contract (no pause mechanism exists).
- Upgrade contracts via proxy pattern (none is used).

**Mitigation:**
- PositionModule has zero admin functions — user funds in escrow are not directly accessible to the deployer.
- Planned: timelock on module swap operations. This would give users advance notice before any module change takes effect.
- The deployer intends to renounce `MODULE_ADMIN_ROLE` after sufficient confidence in contract correctness (extended production runtime or professional audit).

**See also:** [ADMIN_PRIVILEGES.md](./ADMIN_PRIVILEGES.md) for per-contract admin function inventory and role table.

---

## 3. Oracle & Settlement — HIGH

Contest outcomes are determined by an off-chain scorer service that calls Chainlink Functions to write scores on-chain. The scorer is a centralized service operated by the protocol developer.

**Risk factors:**
- The scorer is a single point of failure. If it goes down, contests are not scored, and speculations cannot be resolved. User funds remain locked in PositionModule until scoring occurs.
- A compromised or buggy scorer could submit incorrect scores, though there is a manual scoring window and void cooldown (see below).
- Chainlink Functions has its own availability and rate-limit constraints. Extended Chainlink downtime would delay scoring.

**Mitigation:**
- The scorer source code is open source at [`ospex-org/ospex-source-files-and-other`](https://github.com/ospex-org/ospex-source-files-and-other). Anyone can verify the scoring logic or run their own instance.
- Oracle requests are permissionless — `createContestFromOracle`, `updateContestMarketsFromOracle`, and `scoreContestFromOracle` on OracleModule can be called by anyone (the caller pays LINK). Source code hashes are validated against ContestModule's stored hashes, preventing arbitrary code execution.
- ContestModule has `scoreContestManually()` as a fallback — requires `SCORE_MANAGER_ROLE` and a 2-day waiting period. This role is currently not granted to anyone but can be assigned by the deployer if automated scoring fails.
- SpeculationModule has `forfeitSpeculation()` as a last-resort cancellation — requires `SPECULATION_MANAGER_ROLE` and a configurable void cooldown (minimum 1 day). Also currently unassigned.

**Residual risk:** Users must trust that the scorer submits correct scores. While the source is verifiable, there is no on-chain dispute mechanism or multi-oracle consensus.

---

## 4. Smart Contract Design Notes — MEDIUM

Known edge cases and design decisions that users should be aware of.

### Solvency Dust

When a position is fully matched and settled, rounding in the odds calculation (1e7 precision) can leave small USDC dust amounts (typically < 0.01 USDC) in PositionModule. This dust is permanently locked — there is no sweep function, and this is by design (adding an admin sweep for PositionModule would create a fund extraction vector). Over a long enough timeline, dust accumulates but remains negligible relative to protocol volume.

### Implicit Half-Point on Spreads and Totals

All spread and total speculations use implicit half-point scoring. The on-chain scorer modules (SpreadScorerModule, TotalScorerModule) do not produce push outcomes — every speculation resolves to a winning side. This eliminates push-related edge cases but means the effective line always has a half-point built in (e.g., a spread of -3 behaves as -3.5 for scoring purposes).

### Secondary Market Inactive

SecondaryMarketModule is deployed but `MARKET_ROLE` has not been granted, so `buyPosition` → `transferPosition` reverts. Users cannot trade matched positions before resolution. This is intentional — the secondary market will be activated after additional testing.

### Prize Pool Dust

Leaderboard prize distribution divides the pool among winners. Rounding can leave small amounts in TreasuryModule. The deployer can sweep these via `adminSweep` after the claim window, but only the leftover — not active prize pools.

---

## 5. Liquidity & Market Risks — HIGH

Ospex is a peer-to-peer protocol. Positions require a counterparty.

**Thin Order Book:**
- The protocol currently has limited organic liquidity. Most markets have few or no resting orders from human participants.
- A single automated market maker (agent "Michelle") provides the majority of liquidity. If this agent goes offline, most markets would have no counterparty available.
- Users creating positions at unpopular odds or on low-interest events may find no match.

**Unmatched Position Risk:**
- Unmatched positions can be withdrawn by the participant at any time before the event starts. The user must execute a transaction to call `adjustUnmatchedPair()` — there is no automatic cancellation or refund.
- Once a position is matched, it is locked until the speculation is resolved (scored) or cancelled. There is no early exit for matched positions (secondary market is not yet active).

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
- The deployer wallet and agent wallet private keys are stored without hardware security module (HSM) or multisig protection. Compromise of the deployer key would give an attacker full admin access.

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
- During periods of high Polygon network congestion, transaction costs increase and confirmation times lengthen. This could delay position creation, matching, claiming, and scoring. In extreme cases, users might miss the window to withdraw unmatched positions before an event starts.

**Gas Costs:**
- While Polygon gas is typically inexpensive, complex operations (creating positions with leaderboard validation, scoring contests) consume meaningful gas. A sustained spike in MATIC price or base fees could make small positions uneconomical.

**Chainlink LINK Costs:**
- Oracle requests require LINK payment. The protocol's Chainlink subscription must be funded. If LINK price spikes or the subscription runs dry, contest creation and scoring are blocked until refunded.

---

## Positive Properties

What the protocol does right:

- **Zero vigorish.** There is no built-in house edge on odds — users set their own prices.
- **No proxy pattern.** Contracts are not upgradeable via proxy. There is no `delegatecall` to an implementation contract that can be silently swapped. Module replacement is explicit and visible on-chain.
- **ReentrancyGuard on all fund-transferring functions.** PositionModule, TreasuryModule, and LeaderboardModule all use OpenZeppelin's ReentrancyGuard.
- **SafeERC20 for all token transfers.** No raw `.transfer()` calls.
- **Checks-Effects-Interactions pattern** used throughout.
- **PositionModule has zero admin functions.** The contract that holds all user funds has no role-gated functions. The deployer cannot withdraw, redirect, or freeze escrowed USDC.
- **Open-source scorer.** The scoring logic is publicly available at [`ospex-org/ospex-source-files-and-other`](https://github.com/ospex-org/ospex-source-files-and-other). Anyone can verify how contest outcomes are determined.
- **Permissionless oracle calls.** Anyone can trigger contest creation, market updates, or scoring by calling OracleModule directly and paying LINK. Source code hashes prevent arbitrary code execution.
- **No pause mechanism.** There is no admin kill switch that can freeze the protocol. This is a double-edged sword (the deployer cannot halt an exploit in progress), but it means users cannot be locked out by admin action.
- **Individual module replaceability.** If a bug is found in one module, that module can be replaced without redeploying the entire protocol. OspexCore itself is immutable.

---

## Companion Documents

- [ADMIN_PRIVILEGES.md](./ADMIN_PRIVILEGES.md) — Per-contract admin function inventory, role table, fund flow, module swap analysis
- [ARCHITECTURE.md](./ARCHITECTURE.md) — Smart contract architecture and module overview
- [DEPLOYMENT.md](./DEPLOYMENT.md) — Contract addresses and network configuration

---

*This document will be updated as risks change. It reflects the protocol's state as of the date above.*
