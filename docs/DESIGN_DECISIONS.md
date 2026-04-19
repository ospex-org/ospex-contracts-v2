# Ospex Protocol — Design Decisions

> Intentional behaviors from the hardening cycle. Each section documents a decision that looks unusual on first read but is correct by design. This is a reference doc for reviewers, auditors, and agents.

---

## Zero-Admin: One-Shot Deployment, No Upgrade Path

**What it is.** OspexCore uses a bootstrap-then-finalize pattern. The deployer registers all 12 modules via `bootstrapModules()`, then calls `finalize()` which permanently locks the registry. After finalization, the deployer has zero on-chain privileges. There are no admin functions, no role-based access control, no module swap capability, no parameter setters.

**What might look wrong.** A protocol with no upgrade path and no emergency controls looks reckless. Every other trust-model doc in DeFi has a "what the admin can do" section.

**Why it's right.** The previous model retained admin powers as a safety net, but every admin power is also an attack vector. The hardening cycle concluded that the risk of admin key compromise or misuse outweighed the value of hotfix capability. Every parameter (fees, void cooldown, protocol receiver, approved signer) is set in constructors and cannot change. The cost is that bugs require full redeployment.

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

**What might look wrong.** Self-matching looks like wash trading. Most exchanges and prediction markets explicitly prohibit it.

**Why it's right.** Self-match prevention at the protocol layer is trivially bypassable with two wallets. Enforcing it on-chain adds gas cost for zero security benefit. If volume-based incentives or rewards are added in the future, wash-trade prevention should be enforced at the incentive/leaderboard layer where it can use richer signals (behavioral patterns, reputation) rather than a single `maker != taker` check.

**What an agent/user should know.** Self-matching is not blocked. It's economically neutral at the protocol level (you pay yourself). If you're evaluating trading volume, treat self-matches as noise.

---

## Permissionless Scoring — Contest Creator May Abandon

**What it is.** Oracle calls (`createContestFromOracle`, `updateContestMarketsFromOracle`, `scoreContestFromOracle`) are permissionless — anyone can call them by paying LINK. The contest creator has no obligation to score. If nobody scores a contest before the void cooldown elapses, `settleSpeculation()` auto-voids all speculations on that contest.

**What might look wrong.** A contest creator could create a contest, attract positions, and then never score it — locking user funds until the void cooldown expires.

**Why it's right.** Making scoring permissionless means no single party can hold scoring hostage. Anyone with the JS source code and LINK can trigger scoring. The void cooldown (7 days on mainnet) provides a deterministic fallback — positions are never permanently locked. The JS source hashes are stored per-contest, so only verified code can be executed.

**What an agent/user should know.** If the primary scorer service is down, you can score contests yourself by calling `scoreContestFromOracle()` with the correct JS source and LINK payment. If nobody scores before the void cooldown, call `settleSpeculation()` to void and recover your risk amount.

---

## Triple-Source Oracle Verification

**What it is.** The Chainlink Functions JavaScript source for contest creation and scoring queries three independent sports data APIs (The Rundown, Sportspage Feeds, JSONOdds). The script requires unanimous agreement across all three sources. If any source returns different data — different scores, different teams, different start times — the script throws and no on-chain state is written.

**What might look wrong.** Three API sources seems redundant.

**Why it's right.** Single-source oracles create a single point of failure. If one API has a data error, stale cache, or is temporarily compromised, the protocol would accept incorrect data. Triple-source consensus means a single corrupted feed cannot affect settlement. The cost is higher API latency and occasional legitimate disagreements (different reporting windows, delayed score finalization), but the safety guarantee is substantial: an attacker would need to compromise three independent providers simultaneously.

**What an agent/user should know.** Scoring may occasionally fail due to source disagreement (one API reporting "final" before others). This is expected and safe — the scorer retries until all three agree. Source code is public at [`ospex-org/ospex-source-files-and-other`](https://github.com/ospex-org/ospex-source-files-and-other).

---

## IPFS-Pin Commitment for Script Preimages

**What it is.** The on-chain contracts store keccak256 hashes of the JavaScript source files used for contest creation, market updates, and scoring. The protocol intends to publish the plaintext source files with their hashes for public consumption, with the details of the distribution mechanism (IPFS pinning or equivalent) to be finalized.

**What might look wrong.** Storing only hashes on-chain means users must trust that the approved scripts are correct. Without access to the preimages, the hashes are opaque.

**Why it's right.** The scripts are already open source on GitHub. The hash commitment ensures that what runs on Chainlink Functions is exactly what was approved — no runtime substitution is possible. Public pinning of the preimages (planned) will allow anyone to independently verify: hash the published source, compare against the on-chain hash, confirm they match. This creates a verifiable chain from approved signer → script hash → published source → actual execution.

**What an agent/user should know.** The source files are currently available at [`ospex-org/ospex-source-files-and-other/src/`](https://github.com/ospex-org/ospex-source-files-and-other/tree/master/src). You can verify any contest's script hashes by hashing the source with `keccak256` and comparing against the values stored in the Contest struct on-chain.

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

## Script Approvals Are Permanent (Unless Expiry Set)

**What it is.** EIP-712 script approvals signed by `i_approvedSigner` include a `validUntil` field. If `validUntil == 0`, the approval is permanent — it never expires. Once a contest is created with approved script hashes, those hashes are stored on-chain and the approval is never re-checked.

**What might look wrong.** Permanent approvals mean a script hash approved today is valid forever, even if the approved signer's key is later compromised.

**Why it's right.** Script approvals are checked at contest creation time only. After creation, scoring validates the JS source against the per-contest stored hash — the signer is not consulted. This means signer rotation and approval expiry cannot retroactively affect live contests, which is critical for settlement finality. For time-bounded governance, use `validUntil > 0`. For stable, well-tested scripts, `validUntil == 0` avoids the operational risk of expired approvals blocking contest creation.

**What an agent/user should know.** The approved signer is immutable (`i_approvedSigner` is set in the OracleModule constructor). Governance over which scripts are approved is exercised through signer discipline — the signer must carefully review scripts before signing approvals.

---

## Oracle Scores Are Final Once Written

**What it is.** `ContestModule.setScores()` can only be called once per contest (it requires `ContestStatus.Verified`; after scoring, status becomes `Scored`). There is no `overrideScores()`, no `correctScores()`, no dispute mechanism.

**What might look wrong.** Every other settlement system has an appeals process or correction window. What if the oracle submits wrong scores?

**Why it's right.** Mutable scores create a second-order trust problem: who decides the correction is correct? The protocol accepts oracle risk and mitigates it upstream (triple-source verification, public source code, hash-locked scripts) rather than downstream (on-chain disputes). If the triple-source oracle unanimously agrees on a wrong score, that's an extremely unlikely scenario that the protocol treats as oracle risk rather than building complexity to handle.

**What an agent/user should know.** Scores are final. The triple-source verification makes incorrect scores very unlikely, but the protocol provides no on-chain recourse if it happens. If the contest is never scored, the void cooldown provides a deterministic fallback — positions void and risk is returned.

---

## Protocol Receiver Address Is Immutable

**What it is.** `TreasuryModule.i_protocolReceiver` is set in the constructor and declared `immutable`. All protocol fees (contest creation, speculation creation, leaderboard creation) are transferred directly to this address. There is no `setProtocolReceiver()`.

**What might look wrong.** What if the receiver address is compromised, or the protocol wants to transition to a DAO treasury?

**Why it's right.** A mutable receiver is an admin-key attack vector — whoever can change it can redirect all fee revenue. Making it immutable eliminates this vector entirely. The trade-off is that transitioning to a new treasury requires redeploying the protocol. For a zero-admin protocol, this is consistent: if you can't change anything else, you shouldn't be able to change where money goes either.

**What an agent/user should know.** Protocol fees go to a fixed address that cannot be changed. Verify `i_protocolReceiver` on-chain if you want to know where fees are flowing.

---

*See also: [TRUST_MODEL.md](./TRUST_MODEL.md) for the full trust model, [RISKS.md](./RISKS.md) for remaining risk factors.*
