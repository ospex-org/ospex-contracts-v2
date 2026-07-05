# Ospex Protocol — Design Decisions

> **As of commit**: `b3d6647`
>
> Intentional behaviors from the hardening cycle. Each section documents a decision that looks unusual on first read but is correct by design. This is a reference doc for reviewers, auditors, and agents.

---

## Zero-Admin: One-Shot Deployment, No Upgrade Path

**What it is.** OspexCore uses a bootstrap-then-finalize pattern. The deployer registers all 12 modules via `bootstrapModules()`, then calls `finalize()` which permanently locks the registry. After finalization, the deployer has zero on-chain privileges. There are no admin functions, no role-based access control, no module swap capability, no parameter setters.

**What might look wrong.** A protocol with no upgrade path and no emergency controls looks reckless. Every other trust-model doc in DeFi has a "what the admin can do" section.

**Why it's right.** The previous model retained admin powers as a safety net, but every admin power is also an attack vector. The hardening cycle concluded that the risk of admin key compromise or misuse outweighed the value of hotfix capability. Every parameter (fees, void cooldown, protocol receiver, and the CreOracleReceiver's oracle trust roots — KeystoneForwarder, workflow owner, optional workflow-name pin) is set in constructors and cannot change. The cost is that bugs require full redeployment.

**What an agent/user should know.** There is no admin to contact, no governance to appeal to, no emergency shutdown. The contracts do exactly what the code says, permanently.

---

## Live Betting Allowed via Commitment Expiry

**What it is.** The MatchingModule does not check contest start time when executing a match. The only temporal guard on commitments is the `expiry` field set by the maker. If a maker signs a commitment with an expiry after the contest starts, that commitment can be matched during the live game.

**What might look wrong.** Most traditional platforms prohibit or heavily restrict live betting. An AI agent reviewing the matching flow will flag the absence of a start-time check as a potential bug.

**Why it's right.** The protocol is designed to support pre-contest-start speculation as its primary mode, but intentionally does not prohibit post-start matching at the protocol layer. Restricting live betting is a policy decision that belongs at the application layer (agent configuration, UX) or the leaderboard layer (RulesModule's `setAllowLiveBetting`), not hardcoded into the matching engine. Makers control their exposure via expiry timestamps — a maker who doesn't want live fills sets expiry before game start.

**What an agent/user should know.** The protocol is currently optimized for pre-contest-start speculation. Makers should set commitment expiry timestamps conservatively. Leaderboard creators can prohibit live betting for their competitions via RulesModule.

---

## Cooldown-Period Matching Rejection

**What it is.** `matchCommitment()` checks `isContestPastCooldown()` and reverts with `MatchingModule__ContestPastCooldown` if the contest's void cooldown has elapsed. This prevents new fills on contests that are approaching or past their auto-void window.

**What might look wrong.** There are two separate timestamp checks in `matchCommitment` — `isContestTerminal` (scored/voided) and `isContestPastCooldown` — and the second one is less obvious. Reviewers may wonder why a not-yet-voided contest would reject fills.

**Why it's right.** Without this check, a taker could match a commitment on a contest that is seconds away from auto-voiding, creating a position that will immediately void and return risk to both parties — a pointless transaction that wastes gas and fees. The cooldown check ensures that new capital only enters contests that have a reasonable chance of reaching settlement. It's a boundary guard: once the protocol considers a contest "overdue for scoring," no new exposure should be created.

**What an agent/user should know.** If you see `ContestPastCooldown` reverts, the contest has exceeded its void cooldown and is no longer accepting new positions. This is not a bug — the contest is effectively dead and will void when `settleSpeculation()` is called.

---

## Self-Matching Allowed by Design

**What it is.** `matchCommitment()` does not check whether `maker == msg.sender`. A user can sign a commitment and then match against it themselves.

**What might look wrong.** Self-matching looks like wash trading. More specifically: a user controlling multiple wallets can self-match across them, then selectively register only the winning positions for leaderboard competitions — a cherry-picking strategy that inflates apparent ROI.

**Why it's right.** Self-matching exists primarily so that users can participate in leaderboards without depending on external liquidity. If no counterparty is available for a market, a user can self-match to take a position and register it for a leaderboard. Blocking `maker == taker` at the protocol layer would not prevent cross-wallet self-matching (trivially bypassable with two wallets), so it would cost gas for zero security benefit while removing a legitimate liquidity-access use case.

The leaderboard abuse surface is real but bounded by the existing rules engine. LeaderboardModule and RulesModule enforce several constraints that limit cherry-picking advantage: odds enforcement (`oddsEnforcementBps`) prevents taking unrealistically favorable odds; minimum positions (`minBets`) requires a threshold of qualifying outcomes, making pure cherry-picking expensive; bet sizing caps (`maxBetPercentage`) limit the ROI impact of any single position; one-position-per-contest-per-scorer prevents registering both sides of the same market; and positions acquired via secondary market are permanently ineligible. These are imperfect — a sufficiently capitalized attacker self-matching across many markets could still gain a statistical edge — but the cost (fees + gas on every losing side, minimum position requirements) bounds the advantage relative to the prize pool.

**What an agent/user should know.** Self-matching is not blocked at the protocol layer. At the position level it is economically neutral (you pay both sides, net zero minus fees). The residual risk is at the leaderboard layer, where cross-wallet cherry-picking is possible but bounded by the rules engine. Leaderboard creators should configure odds enforcement and minimum position requirements to raise the cost of cherry-picking strategies. If you're evaluating trading volume, treat self-matches as noise.

---

## Permissionless Scoring — Contest Creator May Abandon

**What it is.** The CreOracleReceiver request entrypoints (`createContestAndRequestVerify`, `requestMarketUpdate`, `requestScore`) are permissionless — anyone can call them, with no per-call LINK and no on-chain subscription. The contest creator has no obligation to request scoring. If nobody requests a score (and the CRE workflow therefore never reports one) before the void cooldown elapses, `settleSpeculation()` auto-voids all speculations on that contest.

**What might look wrong.** A contest creator could create a contest, attract positions, and then never request scoring — locking user funds until the void cooldown expires.

**Why it's right.** Making the request permissionless means no single party can hold scoring hostage. Anyone can call `requestScore()`, which emits the on-chain request the off-chain CRE workflow resolves. The void cooldown (7 days on mainnet) provides a deterministic fallback — positions are never permanently locked.

**What an agent/user should know.** If the primary requester is down, you can request scoring yourself by calling `requestScore(contestId)`. Actual scoring depends on the CRE workflow still running and being funded; if it is not, the contest auto-voids after the cooldown. If nobody scores before the cooldown, call `settleSpeculation()` to void and recover your risk amount.

---

## Triple-Source Oracle Verification

**What it is.** The off-chain CRE workflow for contest verification and scoring queries three independent sports data APIs (The Rundown, Sportspage Feeds, JSONOdds). The workflow requires unanimous agreement across all three sources. If any source returns different data — different scores, different teams, different start times — no report is produced and no on-chain state is written.

**What might look wrong.** Three API sources seems redundant.

**Why it's right.** Single-source oracles create a single point of failure. If one API has a data error, stale cache, or is temporarily compromised, the protocol would accept incorrect data. Triple-source consensus means a single corrupted feed cannot affect settlement. The cost is higher API latency and occasional legitimate disagreements (different reporting windows, delayed score finalization), but the safety guarantee is substantial: an attacker would need to compromise three independent providers simultaneously.

**What an agent/user should know.** Scoring may occasionally fail due to source disagreement (one API reporting "final" before others). This is expected and safe — the workflow retries until all three agree. The CRE workflow source lives in the `ospex-cre` repo.

---

## Leaderboard Creator Controls Participation

**What it is.** Leaderboard creation is permissionless (anyone, pays 0.50 USDC). The creator controls which speculations are eligible (`addLeaderboardSpeculation`, creator-only), and sets all rules (bankroll limits, bet sizing, odds enforcement, live betting, number deviation) via RulesModule before the leaderboard starts. Rules are immutable once the leaderboard is active.

**What might look wrong.** Giving a single address control over competition rules and eligible markets looks like a centralization risk.

**Why it's right.** Leaderboards are opt-in competitions, not protocol-level constraints. The creator designs the competition; users choose whether to enter. Rules are locked before start (the `onlyCreatorBeforeStart` modifier prevents mid-competition changes). Entry fees go entirely to the prize pool, not the creator. The creator cannot extract funds, modify rules mid-competition, or prevent winners from claiming.

**What an agent/user should know.** Read the leaderboard rules before entering. Rules cannot change after the start time. The creator cannot touch the prize pool — it's held by TreasuryModule and disbursed by LeaderboardModule to verified winners.

---

## Secondary-Market Positions Permanently Ineligible for Leaderboards

**What it is.** When a position is transferred via `SecondaryMarketModule.buyPosition()`, the recipient's position is flagged with `acquiredViaSecondaryMarket = true`. This flag is permanent and cannot be cleared. Positions with this flag are rejected by `registerPositionForLeaderboard()`.

**What might look wrong.** This seems overly restrictive. Why can't a buyer participate in leaderboards with a legitimately purchased position?

**Why it's right.** Leaderboard ROI measures a participant's prediction skill. Buying a position on the secondary market at a negotiated price is a different economic action than taking a directional bet at market odds. Allowing secondary-market positions would let participants game leaderboard ROI by buying already-winning positions near settlement, artificially inflating their returns. The permanent flag is simpler and more robust than trying to price-adjust secondary acquisitions.

**What an agent/user should know.** If you plan to compete in leaderboards, take positions directly via MatchingModule. Secondary market purchases cannot be registered for any leaderboard, ever.

---

## Min-Positions Outcome Filter

**What it is.** When submitting leaderboard ROI, positions with `WinSide.TBD` (unscored) or `WinSide.Void` (voided) do not count toward the minimum positions requirement. Only Win, Loss, and Push outcomes qualify.

**What might look wrong.** Excluding void/TBD from the count means a user who bet on 5 contests where 3 got voided might not meet a `minBets = 3` requirement, even though they made 5 bets.

**Why it's right.** The minimum positions requirement exists to prevent "one lucky bet" strategies. Counting voided positions would let participants meet the minimum by betting on contests that are more likely to void. TBD positions are excluded because their outcome isn't known — including them would make ROI unreliable. The leaderboard creator sets `safetyPeriodDuration` long enough that unresolved positions are expected to be rare by the ROI submission window.

**What an agent/user should know.** Plan for the possibility of voided contests when calculating how many positions you need. Only resolved Win/Loss/Push outcomes count toward the minimum.

---

## Leaderboards Silently Cap Oversized Bets

**What it is.** When registering a position for a leaderboard, if `riskAmount > maxBet` (derived from `maxBetPercentage * bankroll`), the leaderboard entry records `cappedRiskAmount = maxBet` and scales `profitAmount` proportionally. The position is not rejected — it's accepted at the capped size.

**What might look wrong.** Silently modifying the recorded bet size without telling the user could be surprising. A strict implementation would reject oversized bets.

**Why it's right.** Rejecting oversized bets would force users to take smaller positions specifically for leaderboard eligibility, fragmenting their actual market exposure from their leaderboard exposure. Capping preserves the user's ability to take whatever position size they want in the market while ensuring the leaderboard records a rule-compliant subset. The cap is deterministic and verifiable — users can compute it from `maxBetPercentage` and their declared bankroll.

**What an agent/user should know.** Your leaderboard position may record a smaller risk/profit than your actual position. Check `maxBetPercentage` and your bankroll to understand the effective cap. `maxBetPercentage` defaults to 100% (10000 BPS) if unset, meaning no cap unless the creator explicitly sets one.

---

## Speculation Lazy Creation

**What it is.** Speculations are not created in advance. When `MatchingModule.matchCommitment()` executes a fill, `PositionModule.recordFill()` checks whether a speculation exists for the (contestId, scorer, lineTicks) triple. If not, it calls `SpeculationModule.createSpeculation()` atomically within the same transaction. The speculation creation fee is split between maker and taker.

**What might look wrong.** Creating market infrastructure as a side effect of the first trade seems fragile. Most exchanges create markets explicitly before trading begins.

**Why it's right.** Explicit market creation would require someone to pay the creation fee and gas for markets that might never attract any volume. Lazy creation means markets only exist when there's actual demand. The first fill atomically creates the speculation, records both positions, and transfers USDC — there's no window where the speculation exists without positions. The split fee ensures neither party bears the full cost of market creation.

**What an agent/user should know.** The first fill on a new (contest, scorer, line) combination will cost slightly more gas and incur the speculation creation fee (0.50 USDC split between maker and taker). Subsequent fills on the same speculation do not pay this fee.

---

## Revert-or-Exact-Fill

**What it is.** `matchCommitment()` does not auto-clip to the remaining commitment capacity. If `fillMakerRisk` (derived from `takerDesiredRisk`) exceeds `makerRiskRemaining`, the transaction reverts with `MatchingModule__InvalidFillMakerRisk`. Off-chain callers must read `s_filledRisk` and size their `takerDesiredRisk` accordingly.

**What might look wrong.** Most exchange matching engines auto-clip partial fills to the remaining quantity. Reverting seems unnecessarily strict.

**Why it's right.** Auto-clipping creates dust positions at unintended economics. If a commitment has 50 units remaining and a taker requests 10,000, auto-clipping would create a 50-unit position that the taker may not want. Revert-or-exact-fill ensures every fill is intentional and correctly sized. The off-chain matching service reads the chain state and sizes requests precisely.

**What an agent/user should know.** Always check `s_filledRisk[commitmentHash]` before submitting a match. If your `takerDesiredRisk` would result in a `fillMakerRisk` exceeding remaining capacity, reduce it. The MatchingModule will not fill you partially by default.

---

## Oracle Scores Are Final Once Written

**What it is.** `ContestModule.setScores()` can only be called once per contest (it requires `ContestStatus.Verified`; after scoring, status becomes `Scored`). There is no `overrideScores()`, no `correctScores()`, no dispute mechanism.

**What might look wrong.** Every other settlement system has an appeals process or correction window. What if the oracle submits wrong scores?

**Why it's right.** Mutable scores create a second-order trust problem: who decides the correction is correct? The protocol accepts oracle risk and mitigates it upstream (triple-source verification, public CRE workflow source, timelock-governed workflow updates) rather than downstream (on-chain disputes). If the triple-source oracle unanimously agrees on a wrong score, that's an extremely unlikely scenario that the protocol treats as oracle risk rather than building complexity to handle.

**What an agent/user should know.** Scores are final. The triple-source verification makes incorrect scores very unlikely, but the protocol provides no on-chain recourse if it happens. If the contest is never scored, the void cooldown provides a deterministic fallback — positions void and risk is returned.

---

## Protocol Receiver Address Is Immutable

**What it is.** `TreasuryModule.i_protocolReceiver` is set in the constructor and declared `immutable`. All protocol fees (contest creation, speculation creation, leaderboard creation) are transferred directly to this address. There is no `setProtocolReceiver()`.

**What might look wrong.** What if the receiver address is compromised, or the protocol wants to transition to a DAO treasury?

**Why it's right.** A mutable receiver is an admin-key attack vector — whoever can change it can redirect all fee revenue. Making it immutable eliminates this vector entirely. The trade-off is that transitioning to a new treasury requires redeploying the protocol. For a zero-admin protocol, this is consistent: if you can't change anything else, you shouldn't be able to change where money goes either.

**What an agent/user should know.** Protocol fees go to a fixed address that cannot be changed. Verify `i_protocolReceiver` on-chain if you want to know where fees are flowing.

---

## Dual Event Emission

**What it is.** Every state change in every module emits two events: a native, typed Solidity event on the emitting module, and a mirror routed through `OspexCore.emitCoreEvent(bytes32 eventType, bytes eventData)` carrying the same fields as a positional `abi.encode` payload under a `keccak256` string tag. `emitCoreEvent` is restricted to registered modules, so the `CoreEventEmitted` event's `emitter` field is trustworthy provenance.

**What might look wrong.** Two event systems doing one job doubles log gas on every hot path; the mirror payloads have no on-chain schema (each field layout exists only as the argument list at its emit site); and in a few cases the two names diverge — most notably the native fill event is `PositionFilled` while its mirror tag is `POSITION_MATCHED_PAIR`; CreOracleReceiver's `CreOracleRequested`/`CreReportProcessed` likewise mirror as `ORACLE_REQUESTED`/`ORACLE_REPORT_PROCESSED`.

**Why it's right.** The hub gives off-chain infrastructure a single-address subscription: one log filter on OspexCore sees every protocol event regardless of which module emitted it, which keeps the indexer's chain-watching surface to one contract. The native events remain because they are the typed, human-readable form that block explorers and per-module tooling decode for free.

**What an agent/user should know.** The positional layout of each core-event payload is a hard compatibility contract with off-chain consumers — treat the `abi.encode` argument order at each emit site as frozen. If you are building an indexer, subscribe to `CoreEventEmitted` on OspexCore and dispatch on `eventType`; the authoritative encoding for each type is the emitting function's source. When searching for fill events, remember the naming split noted above.

---

## Leaderboard ROI Submission Is One-Shot and Timing-Dependent

**What it is.** `submitLeaderboardROI` may be called exactly once per user per leaderboard, only inside the ROI submission window. It computes ROI from each registered speculation's **live** `winSide` at the moment of submission: `TBD` — which means unscored **or scored-but-not-yet-settled** — contributes zero profit/loss and does not count toward the minimum-positions requirement. There is no resubmission and no correction path.

**What might look wrong.** Two users holding identical positions can record different ROIs depending on *when* they submit — and a user who submits while one of their speculations is scored but unsettled silently forfeits that position's contribution forever.

**Why it's right.** One-shot submission is what makes the winner bookkeeping and the prize-pool snapshot safe: allowing resubmission would let participants watch the current highest ROI and re-time their own, and would reopen already-recorded winner sets. Reading live outcomes (rather than maintaining per-position settlement callbacks into the leaderboard) keeps the module simple and gas-flat outside the submission itself. The cost is that settlement ordering becomes the submitter's responsibility — a deliberate trade, since `settleSpeculation()` is permissionless and costs only gas.

**What an agent/user should know.** Before submitting: call `settleSpeculation()` on every speculation you registered (anyone can — see [E2E_TRACES.md](./E2E_TRACES.md), Trace 4), confirm each reads `Closed`, then submit. Prefer submitting after outcomes are final rather than early in the window. Leaderboard creators should size `safetyPeriodDuration` so that scoring and settlement comfortably precede the ROI window.

---

*See also: [TRUST_MODEL.md](./TRUST_MODEL.md) for the full trust model, [RISKS.md](./RISKS.md) for remaining risk factors.*
