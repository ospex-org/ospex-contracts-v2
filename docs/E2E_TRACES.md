# Ospex Protocol — End-to-End Traces

> **Audience**: engineers and agents evaluating the protocol from source.
> **Purpose**: each trace below lists the exact contracts and functions on one protocol process, in execution order, with what is enforced at each hop and which module enforces it. Reading the contracts cold requires discovering these hop sequences yourself; this document is the road map so you can go straight to the code that matters.

How to use: pick the process you want to verify, open the listed functions in order, and check the noted enforcement at each hop. Cross-module checkpoints call out invariants that are **split across contracts** — the places where reading one file in isolation gives an incomplete (or misleading) picture.

Companion documents: [ARCHITECTURE.md](./ARCHITECTURE.md) (module reference, USDC approvals), [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md) (why unusual-looking behavior is intentional — several hops below link to it), [TRUST_MODEL.md](./TRUST_MODEL.md), [RISKS.md](./RISKS.md).

## Conventions you need once

- **Module resolution & authorization.** Modules find each other live through `OspexCore.getModule(keccak256("MODULE_TYPE"))`, and inter-module authorization is an exact-caller check — usually `msg.sender == <the registered X module>`. Two exceptions: OspexCore's own entrypoints (`emitCoreEvent` and the fee routers) accept **any** registered module, and TreasuryModule's fee functions check `msg.sender == OspexCore` (reachable only through those routers). The registry is written once at deploy and permanently frozen by `OspexCore.finalize()` — the dynamic lookups can never resolve to different addresses. See [TRUST_MODEL.md](./TRUST_MODEL.md).
- **Dual events.** Every state change emits a typed local event **and** an `OspexCore.emitCoreEvent(bytes32 eventType, abi.encode(...))` mirror, so an indexer can subscribe to the single OspexCore address and see everything. The mirror payloads are positional ABI encodings — see [DESIGN_DECISIONS.md → Dual Event Emission](./DESIGN_DECISIONS.md#dual-event-emission).
- **USDC approvals.** Three different contracts pull USDC directly from user wallets depending on the action. See [ARCHITECTURE.md → USDC Approvals](./ARCHITECTURE.md#usdc-approvals-who-is-the-spender) before integrating — under-approving only PositionModule is the most common integration mistake.

---

## Trace 1 — Contest creation → verification (oracle round trip)

1. **`CreOracleReceiver.createContestAndRequestVerify(rundownId, sportspageId, jsonoddsId)`** — permissionless. Creates the contest via ContestModule, latches `s_verifyRequested[contestId]` (binds the future verify report to this request), and emits `CreOracleRequested` for the off-chain workflow's log trigger.
2. **`ContestModule.createContest(...)`** — callable only by the registered CRE_ORACLE_RECEIVER. Requires at least one non-empty provider ID; charges the caller the contest-creation fee (`OspexCore.processFee` → `TreasuryModule.processFee`, pulled from the caller's wallet by TreasuryModule). Contest starts `Unverified`. There is **no uniqueness check** on provider IDs — duplicate contests for the same real-world game are possible, and each duplicate carries its own verify request, so the workflow will independently verify every one of them into parallel `Verified` contests; deduplication is an off-chain concern (creators and consumers must converge on one canonical contest).
3. **Off-chain**: the CRE workflow (public [`ospex-cre`](https://github.com/ospex-org/ospex-cre) repo) resolves the game against three providers (3-of-3 agreement) and reports back through the KeystoneForwarder.
4. **`CreOracleReceiver.onReport(metadata, report)`** — the trust funnel, in order: (a) `msg.sender` is the immutable KeystoneForwarder; (b) report-metadata workflow **owner** (and optional **name** pin) match; (c) per-report idempotency latch on `keccak256(report)` (set before dispatch; a handler revert rolls it back so a failed first delivery is retryable); (d) envelope decode + `chainId`/receiver domain check; (e) dispatch by request type → `_handleVerify`.
5. **`_handleVerify(payload)`** — fail-closed request binding: requires `s_verifyRequested[contestId]`, then calls `ContestModule.setContestLeagueIdAndStartTime`.
6. **`ContestModule.setContestLeagueIdAndStartTime(contestId, leagueId, startTime)`** — the one-shot `Unverified → Verified` transition. Requires a non-Unknown league and a non-zero start time; pins the start time.

**Cross-module checkpoints**

- Duplicate-verify protection does **not** live in the receiver (its `s_verifyRequested` latch is never cleared) — it lives in ContestModule's one-shot status transition. Conversely, "verify a contest that was never created" is blocked only by the receiver's request latch, not by ContestModule. Each contract covers the other's gap; neither is safe alone.
- The contest start time lives in its own mapping (`ContestModule.s_contestStartTimes`), **not** inside the `Contest` struct — consumers needing status + start time make two reads.

---

## Trace 2 — Reference market data ("odds of record")

1. **`CreOracleReceiver.requestMarketUpdate(contestId)`** — permissionless; requires the contest be `Verified`; increments `s_marketNonce[contestId]` and emits the request.
2. **`onReport` funnel** (steps a–d above) → **`_handleMarket(payload, requestNonce)`** — accepts a nonce in the window `(s_lastAppliedMarketNonce, s_marketNonce]`: a **range**, not exact-match-latest. This gives two properties at once: an already-applied (or older-than-applied) report can never overwrite fresher odds, and permissionless request spam cannot invalidate a legitimate in-flight report.
3. **`ContestModule.updateContestMarkets(...)`** — `Verified`-only; **all-or-nothing across all three market types** (all six odds must be non-zero, total line ≥ 0); rows are keyed by scorer contract **address**.

**Cross-module checkpoints**

- These odds/lines are **never a settlement input**. Their only on-chain consumer is RulesModule's leaderboard gates (`validateOdds`, `validateNumber`). Matching ignores them entirely — prices come from maker commitments.
- A Verified contest whose markets were never pushed has zeroed `ContestMarket` rows. If a leaderboard enables odds enforcement, registration against such a contest fails as `OddsTooFavorable` (or as `NumberDeviationTooLarge` for spread/total markets when a deviation rule is also set — the number gate runs first, against the zeroed line) — there is no distinct "market data missing" result, so debug that failure by checking `ContestModule.getContestMarket` first, not your odds math.

---

## Trace 3 — Match → fill (the money path)

**Preconditions**: the maker has signed an EIP-712 `OspexCommitment` (domain `Ospex`/`1`); maker and taker have approved **PositionModule** for their stakes; on a first fill of a new market, both additionally need an allowance to **TreasuryModule** for the split creation fee (see [USDC Approvals](./ARCHITECTURE.md#usdc-approvals-who-is-the-spender)).

1. **`MatchingModule.matchCommitment(commitment, signature, takerDesiredRisk)`** — permissionless; the taker is `msg.sender` (self-matching intentionally allowed — [DESIGN_DECISIONS](./DESIGN_DECISIONS.md#self-matching-allowed-by-design)). Gates, in order:
   - odds tick in `[101, 10100]`; `takerDesiredRisk != 0`;
   - `ContestModule.isContestTerminal` — no fills on Scored/Voided contests;
   - `SpeculationModule.isContestPastCooldown` — no new money into contests overdue for scoring ([DESIGN_DECISIONS](./DESIGN_DECISIONS.md#cooldown-period-matching-rejection));
   - `_validateCommitment`: maker non-zero → `|lineTicks| ≤ 1,000,000` → not expired → `riskAmount` a multiple of the 100-unit lot → nonce ≥ the maker's per-(contest, scorer, line) floor → not individually cancelled → ECDSA-recovered signer == maker.
   - **Not checked here**: contest existence or Verified status. That gate runs downstream, at speculation creation, on the first fill only (see checkpoint below).
2. **Fill sizing** — takerDesiredRisk is converted to maker risk (ceil-divide), floored to the 100-unit lot, converted back to `takerRisk`, and clipped down to `takerDesiredRisk`. Over-capacity requests **revert rather than auto-clip** ([DESIGN_DECISIONS](./DESIGN_DECISIONS.md#revert-or-exact-fill)). `s_filledRisk` is incremented before the external call (checks-effects-interactions).
3. **`PositionModule.recordFill(...)`** — callable only by the registered MatchingModule. Find-or-create: `SpeculationModule.getSpeculationId(contestId, scorer, lineTicks)`; if `0`, →
4. **(first fill only) `SpeculationModule.createSpeculation(...)`** — callable only by PositionModule. Enforces: line-tick bound, one speculation per (contest, scorer, line), **contest is `Verified`**, scorer is one of the three approved scorers (`OspexCore.isApprovedScorer`), per-scorer line shape (moneyline line == 0; total line ≥ 0). Charges the split creation fee: `OspexCore.processSplitFee` → `TreasuryModule.processSplitFee` — **TreasuryModule pulls half from the maker's wallet and half from the taker's wallet** via its own `safeTransferFrom`.
5. **`PositionModule._recordFill(...)`** — the speculation must be `Open` (modifier evaluated after find-or-create, which is why the check isn't visible on the external entrypoint). Ledger entries are mirrored — each side's `profitAmount` equals the other side's `riskAmount` (the zero-vig invariant) — then USDC is pulled: `safeTransferFrom(maker → PositionModule)` and `safeTransferFrom(taker → PositionModule)`.

**Cross-module checkpoints**

- **Money is accepted at hop 5, but the Verified gate that admits it runs at hop 4 — and only on the first fill of a market.** Later fills on the same market rely on hop 1's terminal/cooldown gates plus the speculation's `Open` status. To convince yourself no fill lands on an unverified contest, you need hops 1, 4, and 5 together; no single contract states it.
- **Commitment identity is the full struct hash.** Two commitments with identical fields (including nonce and expiry) are literally the same order on-chain: one shared fill counter, one shared cancel flag. Off-chain order management must differentiate orders via nonce/expiry.

---

## Trace 4 — Scoring → settlement → claim

1. **`CreOracleReceiver.requestScore(contestId)`** — permissionless; requires `Verified` and `block.timestamp ≥ startTime`; latches `s_scoreRequested[contestId]`.
2. **`onReport` funnel** → **`_handleScore(payload)`** (fail-closed on the request latch) → **`ContestModule.setScores(contestId, awayScore, homeScore)`** — the one-shot `Verified → Scored` transition. Scores are capped at `MAX_SCORE = 1,000,000` per team (guards the scorers' int32 arithmetic against a garbage oracle value permanently locking settlement) and are **immutable once written** ([DESIGN_DECISIONS](./DESIGN_DECISIONS.md#oracle-scores-are-final-once-written)). Note: the revert for calling `setScores` on a non-Verified contest is named `ContestModule__AlreadyScored`, but it fires for never-verified and voided contests too.
3. **`SpeculationModule.settleSpeculation(speculationId)`** — permissionless, for each market on the contest. In order: ID bounds check → start time must have passed → not already `Closed` → then one of two paths:
   - **Scored path**: contest is `Scored` → `Scorer.determineWinSide(contestId, lineTicks)` (each scorer is gated `onlySpeculationModule`; scorers are status-blind and safe only under this Scored precondition) → speculation `Closed` with the returned `winSide`.
   - **Void path**: the void cooldown (`startTime + i_voidCooldown`; immutable, 7 days on mainnet) has elapsed and the contest is still `Verified` → **`ContestModule.voidContest` voids the ENTIRE contest** — permanently blocking `setScores` for it — and this speculation closes as `Void`. Sibling speculations on the contest then settle as `Void` individually.
4. **`PositionModule.claimPosition(speculationId, positionType)`** — holder-initiated; requires the speculation be `Closed` and the position unclaimed. Payout: winner = risk + profit; `Push`/`Void` = risk refunded; loser = revert (`NoPayout`). Losing positions are never zeroed — `claimed == true` means "was paid," not "is resolved"; to classify a position you must re-derive the payout from the speculation's `winSide`.

**Cross-module checkpoints**

- **Score vs. void is a race with permanent stakes**: `Scored` and `Voided` are mutually exclusive terminal states, and whichever transition lands first wins forever. A late-but-correct score report loses to any keeper who settles one speculation after the cooldown.
- The single immutable `i_voidCooldown` does double duty: it is both the fill cutoff (Trace 3, hop 1) and the auto-void trigger — which is exactly why past-cooldown voiding is safe (no fresh money can have entered).

---

## Trace 5 — Secondary-market sale

1. **`SecondaryMarketModule.listPositionForSale(speculationId, positionType, price, riskAmount, profitAmount)`** — holder-initiated; speculation must be `Open`; amounts must not exceed the live position; **non-proportional slices are allowed** — solvency holds because `transferPosition` conserves totals: what leaves the seller's position is exactly what the buyer receives. Re-listing silently overwrites an existing listing (the hash commitment protects buyers). A listing-state hash is emitted for buyers. Sellers can also modify a live listing via `updateListing` (a zero argument keeps that field's current value) or remove it via `cancelListing`; every mutation rotates the listing hash, so a buyer who committed to the old state reverts safely.
2. **`SecondaryMarketModule.buyPosition(speculationId, seller, positionType, riskAmount, expectedHash)`** — recomputes the listing hash and reverts (`ListingStateChanged`) if the seller changed anything after the buyer committed. Pulls `purchasePrice` from the buyer (**allowance to SecondaryMarketModule**), credits it to the seller's pull-payment balance, then →
3. **`PositionModule.transferPosition(...)`** — callable only by the registered SecondaryMarketModule. Enforces: speculation `Open` **and** contest not `Scored`/`Voided` (no trading once the outcome is publicly known); amounts within the seller's live position; and the **leaderboard transfer lock**: reads `LeaderboardModule.s_lockedRisk` / `s_lockedProfit` and reverts (`TransferLocked`) if the seller's remaining position would fall below any leaderboard-snapshotted amount. The destination position inherits the earlier `firstFillTimestamp` and is permanently flagged `acquiredViaSecondaryMarket` ([DESIGN_DECISIONS](./DESIGN_DECISIONS.md#secondary-market-positions-permanently-ineligible-for-leaderboards)).
4. **`SecondaryMarketModule.claimSaleProceeds()`** — the seller pulls accumulated sale proceeds.

**Cross-module checkpoints**

- Half of `buyPosition`'s failure modes live in PositionModule, and one (`TransferLocked`) originates from LeaderboardModule state that SecondaryMarketModule's source never mentions. A "valid-looking" listing can be unbuyable because the seller registered that position for a leaderboard: the locks are keyed by speculation (global across leaderboards), are high-water marks, and are never released.
- `cancelListing` reverts once the seller's position has been **claimed** (paid out) — so a listing whose position was claimed after settlement becomes permanently inert storage: unbuyable because the speculation is no longer `Open`, uncancellable because of the claimed guard. Listings on unclaimed positions — including losing positions, which can never be claimed — remain cancellable after settlement, since `cancelListing` never checks speculation status. Harmless either way, but know which case you are in before expecting cleanup calls to succeed.

---

## Trace 6 — Leaderboard lifecycle

1. **`LeaderboardModule.createLeaderboard(entryFee, startTime, endTime, safetyPeriodDuration, roiSubmissionWindow)`** — permissionless; creation fee pulled by TreasuryModule. Config is immutable after creation.
2. **`RulesModule.set*` (nine setters)** — creator-only, strictly **before** `startTime`. Unset defaults are load-bearing: max bet = 100% of bankroll, min bet = 0, min positions = effectively 1, odds/deviation enforcement **off**, live betting **off**, moneyline+spread pairing **restricted**. See [RISKS.md](./RISKS.md) for creator configuration guidance.
3. **`LeaderboardModule.addLeaderboardSpeculation(leaderboardId, speculationId)`** — the creator whitelists eligible markets, only before the underlying contest starts.
4. **`LeaderboardModule.registerUser(leaderboardId, declaredBankroll)`** — bankroll is **declared, not escrowed** (it is the ROI denominator; its teeth are the creator's bankroll bounds and bet-percentage rules in RulesModule). Entry fee goes entirely to the prize pool in TreasuryModule.
5. **`LeaderboardModule.registerPositionForLeaderboard(speculationId, positionType, leaderboardId)`** — reads the live position from PositionModule; rejects positions first-filled before `startTime`, positions acquired via the secondary market, and duplicate (contest, scorer) slots; **silently caps** oversized risk to the rules max bet with proportional profit rescale ([DESIGN_DECISIONS](./DESIGN_DECISIONS.md#leaderboards-silently-cap-oversized-bets)); validates via `RulesModule.validateLeaderboardPosition` (which requires the speculation be creator-whitelisted, and calls back into LeaderboardModule views); stores the immutable snapshot; and **ratchets the transfer locks** consumed in Trace 5, hop 3.
6. **`LeaderboardModule.submitLeaderboardROI(leaderboardId)`** — only inside `[endTime + safetyPeriodDuration, + roiSubmissionWindow)`; **one-shot and final** per user. Iterates every registered position, reading each speculation's **live** `winSide`: `TBD` contributes zero and does not count toward the minimum-positions gate — and a scored-but-unsettled speculation still reads `TBD`, so **settle all your speculations (permissionless, Trace 4 hop 3) before submitting** ([DESIGN_DECISIONS](./DESIGN_DECISIONS.md#leaderboard-roi-submission-is-one-shot-and-timing-dependent)). Winner bookkeeping: a strictly higher ROI clears and replaces the winner list; an exact tie appends to it.
7. **`LeaderboardModule.claimLeaderboardPrize(leaderboardId)`** — after the ROI window closes; scans the winner list for membership; the prize pool is snapshotted at the **first** claim; each winner receives `snapshot / winners.length` exactly once, disbursed by `TreasuryModule.claimPrizePool` (callable only by LeaderboardModule).

**Cross-module checkpoints**

- Submission gas grows linearly with the user's registered position count (~20k gas per position, measured) and there is no pagination and no prospective-ROI view — see [RISKS.md → Leaderboard Scaling & Configuration Bounds](./RISKS.md) for the quantified ceilings and creator guidance.
- Prize-pool funding (`TreasuryModule.fundLeaderboard`, permissionless sponsorship) is gated to before `endTime`, which is what makes the first-claim pool snapshot safe: nothing can top up the pool between the snapshot and later claims.

---

## Seam index — state written in one module, consumed in another

The protocol's most cognitively expensive property is that several fields have zero consumers in the file that writes them. This index is the shortcut:

| State | Written by | Consumed by | Meaning |
|-------|-----------|-------------|---------|
| `s_lockedRisk` / `s_lockedProfit` | `LeaderboardModule.registerPositionForLeaderboard` (high-water mark) | `PositionModule.transferPosition` | Floor below which a leaderboard-registered position cannot be transferred away. Keyed by speculation (global across leaderboards); never released. |
| `Position.firstFillTimestamp` | `PositionModule._recordFill` (fresh fills), `transferPosition` (min-merge on transfer-in) | `LeaderboardModule.registerPositionForLeaderboard` | Rejects positions opened before the leaderboard's start (anti-backdating). |
| `Position.acquiredViaSecondaryMarket` | `PositionModule.transferPosition` (set permanently on any transfer-in) | `LeaderboardModule.registerPositionForLeaderboard` | Hard leaderboard ineligibility for purchased positions. Note: a later primary re-fill of an emptied slot re-stamps the timestamp but the flag stays set. |
| `ContestMarket` (odds/lines) | `ContestModule.updateContestMarkets` (oracle only) | `RulesModule.validateOdds` / `validateNumber` **only** | Leaderboard "odds of record." Never a settlement input; ignored by matching. |
| `s_contestStartTimes` | `ContestModule.setContestLeagueIdAndStartTime` | `SpeculationModule` (settle gate, cooldown math), `MatchingModule` (via `isContestPastCooldown`), `RulesModule` (live-betting gate), `LeaderboardModule.addLeaderboardSpeculation` (contest-not-started gate), `CreOracleReceiver.requestScore` (premature-request gate) | Single verified start-time of record, stored outside the Contest struct. |
| `Speculation.winSide` | `SpeculationModule.settleSpeculation` | `PositionModule._calculatePayout`, `LeaderboardModule._calculateROI` | The settlement outcome. The Upper↔{Away, Over} / Lower↔{Home, Under} winner mapping is applied independently in both consumers. |

---

*This document describes the R5 Polygon mainnet deployment. If a trace and the code ever disagree, the code is authoritative — please open an issue.*
