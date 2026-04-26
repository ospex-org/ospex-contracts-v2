# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Plan version:** v4.1 (R4 contracts + R4.1 indexer replay/projection retest)
**Phase:** R4 Session 1 Day 1 complete; **R4.1 retest pending.** Indexer PRs #16–#22 merged 2026-04-24..26 closed the gaps surfaced in R4 Day 1 findings (35-event recognition, finalized-block safe-head, pending-events retry cap, full COMMITMENT_MATCHED/COMMITMENT_CANCELLED field coverage with `speculation_key`, projection of FEE/SPLIT_FEE/LEADERBOARD_FUNDED/RULE_SET/DEVIATION_RULE_SET partials).
**Branch:** `docs/r4.1-indexer-replay-retest` (foundry repo) — doc updates for R4.1. The on-chain testing branch `feature/r4-stress-test-session-1` was merged for Session 1 Day 1 results.
**Next action:** Run R4.1 retest checklist (see below). If indexer replay/reconcile passes, continue Round 4 with Session 2 (score/settle/claim Cavs game **once the game is FINAL — Contest 5 on-chain start_time is `2026-04-26T22:00:00Z` = 5:00 PM CDT, so earliest scoring window is ~7:30 PM CDT today; verify FINAL via API before calling `scoreContestFromOracle`**) → Session 3 (Mon void cooldown) → Session 4 (LB ROI/prize). If replay fails, wipe Supabase amoy data and reindex from block 37285105 before considering a new round.

R3 results below (Sessions 1–4) preserved for reference. R4 is a separate test cycle against re-deployed contracts.

---

## R4 Cycle (2026-04-26)

**Trigger:** R4 contracts deployed 2026-04-25 (commit `655f20a8`, first block 37285105). See `deployments/amoy-R4-20260425.md`.

### Pre-Session 1 state (verified 2026-04-26 ~12:35 AM CDT)

| Check | State |
|-------|-------|
| Indexer worker | Running (heroku ps: up since 2026-04-25 19:55 CDT). Cursor at ~37304100, advancing normally, 0 events per chunk (no on-chain activity since R4 deploy). |
| Indexer config | EMITTER_ALLOWLIST + scorer addresses match R4 deploy. |
| Supabase amoy data | Wiped per request. (Re-verify with cleanup SQL if any drift suspected.) |
| `contest_reference` | 23 ready (non-final) Sunday Apr 26 amoy rows: 15 MLB, 4 NBA, 4 NHL. |
| Test wallets | MAKER `0x7CA624C92b8Aed9ee83Ed621A898f7524FAfBa24`, TAKER `0x8D92451e7457b0076349eBA44d60b36a1038bF31` (re-use from R3). Funding/approval status TBD before Phase 2. |
| Stress-test scripts | `create-contest.js` already R4. `match-commitment.js`, `market-update.js`, `score-contest.js` still pin R3 addresses — must update before Phase 2. |
| Script approvals (oracle) | R3 signatures may still be valid (signer unchanged). Verify against R4 OracleModule before first oracle call. |

### Phase 1 — Sunday Apr 26 candidate games

User constraint: Sunday Apr 26 only, prefer noon–4pm CDT kickoff, multi-sport coverage required (MLB/NBA/NHL all available).

**Recommended slate (pending user approval):**

| Track | Contest | Sport | Game | Kickoff CDT | Kickoff UTC | Expected end CDT | jsonodds_id | Markets |
|-------|---------|-------|------|-------------|-------------|------------------|-------------|---------|
| 1 + 2 | A | NBA | Cleveland Cavaliers @ Toronto Raptors | Sun 12:00 PM | 17:00 | ~2:30 PM | `4012589b-be8b-4912-874e-6812f1aab06a` | ML/SPREAD/TOTAL |
| 3 | B | NHL | Buffalo Sabres @ Boston Bruins | Sun 1:00 PM | 18:00 | ~3:30 PM (won't score) | `8d95ca3b-be51-4fb3-82be-39375740d0e5` | ML/SPREAD/TOTAL |
| 4 | C | MLB | Boston Red Sox @ Baltimore Orioles | Sun 12:35 PM | 17:35 | ~3:30 PM (won't score; void cooldown elapses Mon 12:35 PM CDT) | `6c48d71f-155e-40a0-9c01-c4ab4ef2792b` | ML/SPREAD/TOTAL |

All three games have both `rundown_id` and `sportspage_id` populated (dual oracle source coverage).

**Pending alternates** (if user wants different MLB/NHL options):
- MLB 12:35 PM alternates: Phillies @ Braves, (12:40) Rockies @ Mets / Tigers @ Reds / Twins @ Rays
- MLB 1:10 PM: Yankees @ Astros, Pirates @ Brewers, Nationals @ White Sox
- NHL 3:30 PM: Avalanche @ Kings (later than recommended)
- NBA 2:30 PM: Spurs @ Trail Blazers (could swap into Track 1 if user prefers later start)

**Discovery script:** `ospex-agent-server/scripts/r4-find-sunday-games.ts` (run with `NETWORK=amoy`).

### Phase 2 — execution log (Session 1 Day 1)

**User approved slate at 2026-04-26 ~12:45 AM CDT.** Pre-flight + execution began.

#### Pre-flight actions

| Step | Action | Result |
|------|--------|--------|
| 1 | Updated R3→R4 addresses in `match-commitment.js`, `market-update.js`, `score-contest.js` | done — `create-contest.js` already R4 |
| 2 | Verified balances: Deployer 25.7 POL / ~1B USDC / 5.27 LINK; MAKER 4.87 POL / 999.8K USDC; TAKER 4.67 POL / 999.8K USDC | sufficient |
| 3 | Verified deployer R4 approvals: USDC→Treasury 99 USDC, LINK→Oracle 0.996 LINK | sufficient for session |
| 4 | Set MAX USDC approvals: MAKER→PositionR4, MAKER→TreasuryR4, TAKER→PositionR4, TAKER→TreasuryR4, TAKER→SecondaryR4 | done |
| 5 | Confirmed indexer R4 config (OspexCore in `EMITTER_ALLOWLIST`; 3 scorers in `SCORER_MONEYLINE`/`SCORER_SPREAD`/`SCORER_TOTAL` separately — they are NOT in the allowlist) | done |

#### T-00 canary

| Field | Value |
|-------|-------|
| Tx | `0x6d64e3e6787d58a9db2063415995782ba37ad6ce534a11e0588f2e35a526275b` |
| Block | 37304588 |
| Action | `raiseMinNonce(999, MoneylineScorer, 0, 1)` from MAKER |
| Result | PASS — chain_events row, maker_nonce_floors row (min_nonce=1, source_block=37304588), 0 pending_events, cursor advanced past tx |

#### Phase A — Track 1 / Contest A (NBA Cavaliers @ Raptors)

| Test | Tx | Block | Result |
|------|----|-------|--------|
| A-01 (initial create, **callback timed out**) | `0xacd809d59288270a7e4a4669f7311a7436c005eec4fd1be2f586c0749e69e54c` | 37304742 | Contest 2 created on-chain, 5 CoreEvents (CONTEST_CREATED + 3× SCRIPT_APPROVAL_VERIFIED + FEE_PROCESSED), but **Chainlink verify callback never fired** within ~10 min. ORACLE_REQUEST_FAILED indexed. Contest 2 abandoned. |
| A-01 (retry) | (script output truncated; retry block 37305257) | 37305257 | Contest 5 created, callback completed within ~3 min. **league_id="nba" set on creation (PR #8 confirmed for R4)**. |
| A-02 | (Chainlink callback) | ~37305380 | Contest 5 verified, start_time set to 2026-04-26T22:00:00Z. |
| A-03 | `0x4f06f3f9a60ea133136bac88c2492b1c75df1aac730a3d24d0a88efa068e1738` | 37305372 | Markets update sent. CoreEvents fire on callback (verified later). |
| A-06 (ML first match, MAKER Upper @ 1.91x, 10 USDC) | (script output truncated) | ~37305383 | 4 CoreEvents (SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR + SPLIT_FEE_PROCESSED). Spec 3 created. |
| A-07 (ML accumulation, nonce=2, 10 USDC) | `0xa509c1075ee4bf3b256dac17044ab6ccebb79741feab5040022baf86271fdd61` | ~37305395 | 2 CoreEvents (no SPECULATION_CREATED). MAKER position on Spec 3 = 20 USDC risk. |
| A-24 (spread Upper @ -3.0, 10 USDC) | (script output truncated) | ~37305411 | Spec 4 created (market_type=spread, line_ticks=-30). |
| A-25 (total Upper @ 220.0, 10 USDC) | (script output truncated) | ~37305423 | Spec 5 created (market_type=total, line_ticks=2200). |

#### Phase A — Track 3 / Contest B (NHL Sabres @ Bruins)

| Test | Tx | Block | Result |
|------|----|-------|--------|
| A-01 | `0xdf225a94dc71d106e4b1a0c24ff7624ddd6056769aec8b5140f2a531407c5bb6` | 37304764 | Contest 3 created. **league_id="nhl" set on creation.** |
| A-02 | (Chainlink callback) | ~37304900 | Contest 3 verified. start_time=2026-04-26T18:00:00Z. |
| A-03 | `0x41c6fa6edc3073480b4f5a5a7ee59d7c7fbea249f4d845e3338b62f70f943ede` | 37304992 | Markets update sent (callback verified). |
| A-06 (ML first match, MAKER Upper @ 2.00x, 10 USDC) | `0x9c05ed017967d5cb16adba8e53984f0cd3d6fd31c53947dbe68c5adf7924946e` | ~37305058 | 4 CoreEvents. Spec 1 created. |
| A-17 list (MAKER Upper @ 12 USDC) | `0xe49d874a6a01ae55c52689760861c5c2ed761b6474ea067a1da01ad0b5ce7f21` | 37305212 | POSITION_LISTED. |
| A-18 update (MAKER price → 11 USDC) | `0x042a7ba763a56129e10c997c6b56d302d7bf798929e72bc718ecd2ec3ebd39f4` | 37305224 | LISTING_UPDATED. New listing hash `0x24e702c2...`. |
| A-19 buy (TAKER full 10 USDC risk) | `0x0c2edb6bda1002caf8916963a88e129f0b6c1e5bc50bfd7a9147858b82f8dfbd` | 37305240 | POSITION_SOLD + POSITION_TRANSFERRED. **TAKER's position has acquired_via_secondary_market=true (PR #9 confirmed for R4).** MAKER's listing has sold_price=11M, sold_risk_amount=10M (PR #14 confirmed). |
| A-20a list (TAKER Upper @ 13 USDC, just-acquired position) | `0x61baac772104482b638a848bd8906be71d4d318c65d002fb8b6deef2eb35ddfa` | 37305340 | TAKER's POSITION_LISTED. |
| A-20b cancel (TAKER cancels) | `0x397d0d5f0482d0c969bbc753c57c4b70f51c9422b84ecdc0be93d3e9b299d8b3` | 37305354 | LISTING_CANCELLED. |
| A-21 claim proceeds (MAKER claims 11 USDC) | `0x6d4ae569b742cc5cd86943a34cb41e2c8d538543d847ec1f6911e6765e82c375` | 37305355 | SALE_PROCEEDS_CLAIMED. 11 USDC transferred Secondary→MAKER. |
| **A-20b relist (PR #14 sold_* clear)** | DEFERRED | — | Requires MAKER to re-acquire position; not run this session. |
| **B-02 acquired_via flag** | PASS | 37305240 | Verified via Supabase query (above). |
| **B-03 secondary market lb rejection** | DEFERRED | — | Same as R3 — needs post-startTime secondary market position. Skipped. |

#### Phase A — Track 4 / Contest C (MLB Red Sox @ Orioles)

| Test | Tx | Block | Result |
|------|----|-------|--------|
| A-01 | `0xcd17148ef4df9e47267fd3b51b3b314ffdb6bc66a2e4027f79d88c2862686be5` | 37304777 | Contest 4 created. **league_id="mlb" set on creation.** |
| A-02 | (Chainlink callback) | ~37304900 | Contest 4 verified. start_time=2026-04-26T17:35:00Z. |
| A-03 | `0x73a07baacb5409f47036fb331bf068c1bf30f0f594690e6a572d97638282a7d7` | 37305004 | Markets callback returned: ml_up=221, ml_lo=171, sp_line=15 (line +1.5), tot_line=80 (line 8.0). |
| A-06 (ML first match, MAKER Upper @ 1.91x, 10 USDC) | `0x589a124f4ac02c1fc6dd5c11e847ac675db1070aa72b3b237dc3b5ad07fb4fe9` | ~37305079 | 4 CoreEvents. Spec 2 created. **DO NOT SCORE — void cooldown elapses Mon ~12:35 PM CDT for Session 3.** |

#### Phase A — Track 2 / Leaderboard

| Test | Tx | Block | Result |
|------|----|-------|--------|
| A-11 create (entry 5 USDC, start +600s, end +4d, safety+roi 24h each) | `0xc39051aaeebd979cce173281919b6682b260da692ffaf12fbfb4b960c3303b3b` | 37305470 | Leaderboard 1 created. startTime=1777184590 (chain time + 600). |
| A-12a (add Spec 4) | `0x58a82d5822ab94f5b798d7b4d79022b62bc59593375955544096a741f265391a` | 37305494 | LEADERBOARD_SPECULATION_ADDED. |
| A-12b (add Spec 5) | `0x9cea8bdab5445bddbf9ba5851eb31c0cdd3a21f13dbda328b3cd6e37eb776c96` | 37305495 | LEADERBOARD_SPECULATION_ADDED. |
| A-12c (add Spec 6 — created post-LB so MAKER position is eligible) | `0xfa85bbdb18ad609c8fa1f77a65d9e03fe8694ccd8136e9881566c0a01f89775f` | 37305776 | LEADERBOARD_SPECULATION_ADDED. |
| A-13a (MAKER register) | `0xb823400a8715a068fb204a1aa76cb95964bb472d5b4d2c84386658febe47c051` | 37305508 | USER_REGISTERED, 5 USDC entry fee charged. |
| A-13b (TAKER register) | `0x76a7049ce4979e6a432bd5145271d2312914f7758fa251b2f463a9ff7219ead5` | 37305509 | USER_REGISTERED, 5 USDC entry fee. |
| (helper) Match Spec 6 (spread -50 Upper, 10 USDC) | block 37305763 timestamp 1777184432 | 37305763 | **Created BEFORE LB startTime (1777184590) — would be ineligible.** |
| A-14 (first attempt on Spec 6) | `0xdcd7dd73ff726ddfc334d1f75d8322be3a635988c2672176e529a48122c1d797` | 37305914 | **REVERTED** with `LeaderboardModule__PositionPredatesLeaderboard` (selector `0xf45bb97a`). Confirms R4 contract checks `firstFillTimestamp < lb.startTime`, NOT < lb.creationBlock — clarifying R3 finding wording. |
| (helper) Match Spec 7 (total 2300 Upper, 10 USDC) post-startTime | (script output truncated) | ~37305980 | Spec 7 created after LB startTime. |
| A-12d (add Spec 7 to LB 1) | `0x131e2e7e4597e1448b48a046e521385eea6e077306cb86db6b42fada4ba57ac4` | 37305994 | LEADERBOARD_SPECULATION_ADDED. |
| A-14 register position (retry on Spec 7) | `0x8fc3a0af4da6c82b13d44f6cfe3a41da2a4c7b86434e2613e2dd1cce50992ef2` | 37305995 | **PASS.** gasUsed=379300 (R3 500k recommendation confirmed for R4 — default 300k would OOG). LEADERBOARD_POSITION_ADDED event fired. |

#### Independent — A-22, A-23

| Test | Tx | Block | Result |
|------|----|-------|--------|
| A-22 cancel commitment (MAKER cancels never-matched commitment, contest=5/ML/0/Upper/200/10USDC/nonce=99) | `0x118876b5020c774afade4f60a078cce9c93d7732064b7a432addeb1babb28af3` | 37305539 | COMMITMENT_CANCELLED. **R4 finding (below): indexer handler doesn't capture new R4 fields.** Row created with hash=`0x5790469bd7...`, status=cancelled, source=indexer, **but contest_id=null, scorer=null, etc.** |
| A-23 raise min nonce (MAKER, contest=3/ML/0 → 100) | `0x51169816d454327a6bb1f2524030c6b849cd4f26a11ec41f025d92908fb0e678` | 37305554 | MIN_NONCE_UPDATED. maker_nonce_floors row at speculation_key `0x1687c295fb...` with min_nonce=100, source_block=37305554. |

#### Phase D — D-01 rapid-fire

| Test | Tx | Block | Result |
|------|----|-------|--------|
| D-01a (Spec 4 spread nonce=2, 5 USDC) | `0x4159b7841ad1a0cf8f36100370a33c227e0332b57bd561f4714aaecc5b43a118` | 37305575 | 2 events (accumulation). |
| D-01b (Spec 4 spread nonce=3, 5 USDC) | `0xe4b81e7be0284e3503f21a0ab539556e649e5e5742a5c0d79d13e86a0c9dc62f` | 37305577 | 2 events. |
| D-01c (Spec 4 spread nonce=4, 5 USDC) | `0x6ebf6943305a928aa358248ffa959721fa452ab9ba2d3ded8ce7e04765b95cd9` | 37305581 | 2 events. After A-24 + 3× D-01: MAKER Spec 4 Upper risk=25M, profit=22.75M (correct accumulation: 10+5+5+5 risk; 9.1+4.55+4.55+4.55=22.75 profit). |

#### Phase C — passed checks

| Test | Result |
|------|--------|
| C-02 source_block | PASS — 0 NULL across 12 projection tables (contests/speculations/positions/leaderboards/leaderboard_speculations/leaderboard_registrations/leaderboard_positions/leaderboard_winners/secondary_market_listings/maker_nonce_floors/commitments/position_fills) |
| C-05 cursor | PASS — cursor at 37305700+ during checks, advancing normally, lag = 128 confirmation depth |
| C-06 dedup | PASS — 86 chain_events, no duplicates (UNIQUE constraint enforces) |
| C-01 pending events | NOT TRIGGERED — contest_reference rows existed for all selected games. Same as R3 — could test manually later. |
| C-03 reconcile | DEFERRED — Session 2 |
| C-04 backfill | DEFERRED — Session 2 |

#### Indexer state at end of Day 1 (after A-14)

- 86+ chain_events rows across 24+ distinct event types (including LEADERBOARD_POSITION_ADDED added at end)
- 5 contests on-chain (id 1 from deploy, 2 unverified dead retry, 3/4/5 verified)
- 7 speculations: 1=ML B/NHL, 2=ML C/MLB, 3=ML A/NBA, 4=spread A/-3.0, 5=total A/220.0, 6=spread A/-5.0 (pre-startTime), 7=total A/230.0 (post-startTime)
- 14 positions across 7 specs
- 2 secondary_market_listings (1 sold, 1 cancelled)
- 1 leaderboard with prize_pool=10 USDC, 2 registrations, 4 eligible specs, 1 registered position
- 11 commitments (10 partially_filled + 1 cancelled), all source='indexer'
- 2 maker_nonce_floors (T-00 + A-23)
- 0 pending_events
- 0 indexer errors visible

#### R4-specific findings (preliminary)

1. **Chainlink Functions verify callback can fail silently.** Contest 2 (Cavs @ Raptors initial create) emitted CONTEST_CREATED + ORACLE_REQUEST_FAILED but no CONTEST_VERIFIED ever fired. Re-creating the same game (jsonoddsId) as Contest 5 succeeded on first try. **There is no on-chain retry function** — failed contests are dead. v1 finding ("Rundown API transient failure") still applies for R4. Recommend either: (a) add retry mechanism in OracleModule, or (b) document re-create as the standard recovery path.

2. **PR #8 league_id derivation works in R4.** All three new contests (Cavs/NBA, Sabres/NHL, Red Sox/MLB) had `league_id` set to "nba"/"nhl"/"mlb" at CONTEST_CREATED time, before verification callback. Confirms R3 fix carried into R4.

3. **PR #9 acquired_via_secondary_market works in R4.** TAKER's Upper position on Spec 1 has the flag set after the buyPosition call.

4. **PR #14 sold_* snapshot works in R4.** MAKER's listing on Spec 1 captured sold_price=11000000, sold_risk_amount=10000000 after the sale.

5. **PRs #11/12/13 commitment indexer-population works in R4.** All 9 matched commitments have a row with `source='indexer'`, contest_id, odds_tick, filled_risk_amount populated. Cancelled commitment also has a row.

6. **R4 ABI gap — COMMITMENT_CANCELLED handler doesn't extract new fields.** R4 emit added contestId, scorer, lineTicks, positionType, oddsTick, riskAmount, nonce, expiry to CommitmentCancelled (per `docs/testing/POST_DEPLOY_SMOKE_TEST.md`), but the indexer handler at `src/handlers/commitments.ts:13-31` only reads `commitmentHash` and `maker`. When the cancelled commitment has no pre-existing row (cancel-only path), the resulting row stores nulls for the new fields. **Non-blocking** — status='cancelled' tracking still works. **Recommend ospex-indexer PR** to extract and store the new fields on cancel-only inserts. **→ RESOLVED by ospex-indexer PR #21 (merged 2026-04-26):** handler now persists full R4 field set including derived `speculation_key`. `recovery.ts` produces same shape on backfill. R4.1 retest must verify the existing R4 Session 1 cancelled row (hash `0x5790469bd7...`, block 37305539) is repaired to full population on replay.

7. **R4 ABI gap — nonce always 0 on indexer-created commitment rows.** Per R3 finding A-23: same issue carries to R4. The new R4 CommitmentMatched event includes `nonce`, but the indexer's match handler still records nonce=0. This blocks MIN_NONCE_UPDATED's nonce_invalidated logic from working on indexer-created rows. **Recommend ospex-indexer PR** to extract and store nonce on COMMITMENT_MATCHED. **→ RESOLVED by ospex-indexer PR #21:** `rpc_commitment_matched` now accepts `p_commitment_risk_amount`, `p_nonce`, `p_expiry`, `p_speculation_key`. R4.1 retest must verify the 9 indexer-created COMMITMENT_MATCHED rows from Session 1 have real nonces post-replay, then assert MIN_NONCE_UPDATED at block 37305554 (A-23 raised Contest 3 / Moneyline / lineTicks=0 to nonce 100 on speculation_key `0x1687c295fb...`) marks every commitment with `(maker, speculation_key)` matching and `nonce < 100` as `nonce_invalidated=true`. Spec 1 first-fill at nonce 1 is the primary affected row.

8. **4 CoreEvents per first-fill match (not 3) carries from R3.** SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR + SPLIT_FEE_PROCESSED. Plan documentation should be updated to expect 4. **→ RESOLVED by ospex-indexer PR #17 (recognition) + plan doc v4.1 (expectation update).** Pre-PR #17 indexer was silently dropping `SPLIT_FEE_PROCESSED` because `decodeLog()` returned null for unknown topic[1] hashes; all 7 R4 first-fill txs initially recorded 3/4 events. R4.1 retest must verify all 7 first-fill txs now have 4 chain_events rows after replay.

9. **C-01 was not triggered organically in R4 Session 1.** Every selected jsonodds_id had a `contest_reference` row. **R4.1 retest must include manual C-01 trigger** (bogus jsonodds_id → CONTEST_CREATED → pending_events → reference inserted → row resolves) and **C-01b retry-cap variant** (PR #20 — verify pending row deletion at PENDING_MAX_ATTEMPTS).

10. **5 partial events have no projection in indexer pre-PR #22.** R4 Session 1 emitted FEE_PROCESSED (contest creation), SPLIT_FEE_PROCESSED (every first-fill), LEADERBOARD_ENTRY_FEE_PROCESSED (every USER_REGISTERED), but pre-PR #22 these only landed in chain_events (or were dropped pre-PR #17). **→ RESOLVED by ospex-indexer PR #22:** FEE/SPLIT_FEE → `fees`, LEADERBOARD_FUNDED → `leaderboard_fundings` + atomic prize_pool, RULE_SET → `leaderboard_rules`, DEVIATION_RULE_SET → `leaderboard_deviation_rules`. LEADERBOARD_ENTRY_FEE_PROCESSED + PRIZE_POOL_CLAIMED + ORACLE_RESPONSE/ORACLE_REQUEST_FAILED + SCRIPT_APPROVAL_VERIFIED stay audit-only (handlers are noops). R4.1 retest must verify replay populates the 4 new typed tables for events that fired in R4 Session 1.

#### Test wallets (current Session 1 state)

| Role | Address |
|------|---------|
| Deployer | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` |
| MAKER | `0x7CA624C92b8Aed9ee83Ed621A898f7524FAfBa24` |
| TAKER | `0x8D92451e7457b0076349eBA44d60b36a1038bF31` |

#### Next session gates

- **Session 2 (after Cavs game is FINAL):** A-04 score Contest 5 → A-08 settle Specs 3/4/5 → A-09 claim winning positions. Then C-03 reconcile, C-04 backfill, D-02 per-tx reconciliation, D-03 USDC value reconciliation. **Pre-flight:** the on-chain `start_time` for Contest 5 is `2026-04-26T22:00:00Z` (= 5:00 PM CDT, **not** 3 PM CDT — earlier session-log entries had the wrong CDT). Earliest defensible scoring window: `start_time + ~2.5h NBA duration` ≈ 2026-04-27T00:30Z (~7:30 PM CDT 2026-04-26). **Mandatory pre-flight gate (see plan A-04 Notes):** confirm via `getContest()` AND the scoring API that the game is FINAL before calling `scoreContestFromOracle`. Do not assume "3 hours after the planned tip-off" is enough; the on-chain start_time is canonical.
- **Session 3 (Day 2 — after Mon ~12:35 PM CDT 2026-04-27, Contest 4 cooldown elapses):** A-05 void Contest C via settleSpeculation(2) → B-01 post-cooldown match rejection.
- **Session 4 (Day 5+ — after LB endTime + 24h safety + 24h ROI):** A-15 submit ROI → A-16 claim leaderboard prize.
- **Pending verification later this session:** A-14 (LB position registration with 500k gas).

---

### R4.1 Retest Checklist (2026-04-26 — indexer replay/projection validation pass)

**Trigger:** Indexer PRs #16–#22 merged 2026-04-24..26 close R4 Session 1 findings #6/#7/#8/#10. Findings #1 (Chainlink callback retry) and #4 (`PositionPredatesLeaderboard` on `firstFillTimestamp < startTime`) remain on the open list — neither is an indexer issue.

**Decision tree:**

1. Run §1 + §2 + §3 below.
2. If all pass → **continue Round 4** (Sessions 2/3/4 proceed unchanged).
3. If §1 reproduces state but §2 reconcile shows drift → file a targeted indexer fix; do NOT wipe data.
4. If §1 cannot repair state → **wipe `amoy*` Supabase data** and reindex from block 37285105. Only then consider starting a new on-chain round.

#### §1 — Replay/Backfill from R4 deployment block (Phase E-01)

- [ ] Confirm indexer is running ospex-indexer PR #22 (or later) in production.
- [ ] Confirm `POLL_INTERVAL_MS=15000` (Heroku config), `EMITTER_ALLOWLIST` set to **R4 OspexCore only** (the only contract that emits `CoreEventEmitted`), and `SCORER_MONEYLINE` / `SCORER_SPREAD` / `SCORER_TOTAL` env vars set to the R4 scorer addresses.
- [ ] Snapshot current `amoy*` Supabase state (row counts per projection table) before replay.
- [ ] Run `yarn backfill --from 37285105 --to <head>` against R4 history.
- [ ] Verify the event types that **fired during R4 Session 1** all appear in `chain_events` post-replay (replay can only validate events that happened on-chain — see Phase E-01 caveat for the events that didn't fire and need §4 / Sessions 2-4):
  - [ ] All 7 R4 first-fill txs from Session 1 show **4 chain_events rows** (not 3) — the previously-dropped `SPLIT_FEE_PROCESSED` is now present.
  - [ ] `SCRIPT_APPROVAL_VERIFIED` rows present for every Chainlink-script call (A-01 / A-03 / A-04).
  - [ ] `FEE_PROCESSED` rows present for every contest creation (Contests 2/3/4/5).
  - [ ] `LEADERBOARD_ENTRY_FEE_PROCESSED` rows present for both A-13 registrations.
  - [ ] `ORACLE_RESPONSE` rows present for every successful Chainlink callback; `ORACLE_REQUEST_FAILED` present for Contest 2's failed verify.
- [ ] Verify the 4 new typed tables populated from R4 history:
  - [ ] `fees` rows for all FEE_PROCESSED + SPLIT_FEE_PROCESSED events (single-shape vs split-shape distinction correct).
  - [ ] `leaderboard_fundings` empty (R4 Session 1 didn't fund) — but no errors.
  - [ ] `leaderboard_rules` empty (R4 Session 1 didn't set rules) — but no errors.
  - [ ] `leaderboard_deviation_rules` empty — but no errors.
- [ ] Verify R4 Session 1 commitment field repair (PR #21):
  - [ ] All 9 indexer-created COMMITMENT_MATCHED rows (Tracks 1/3/4 first-fills + accumulations + D-01 rapid-fire) have `nonce`, `expiry`, `risk_amount`, `speculation_key` populated post-replay (not 0/null).
  - [ ] R4 Session 1 A-22 cancelled commitment row (hash `0x5790469bd7...`, block 37305539) has full R4 fields populated (was hash/maker only before PR #21).
  - [ ] All commitment rows have `source='indexer'`, `source_block` set.
- [ ] Verify `source_block` repair on pre-existing rows (PR #22 recovery.ts fix): zero NULL `source_block` across all 16+ projection tables (12 from R4 Session 1 + 4 new).

#### §2 — Reconcile (Phase E-02 = C-03 + explicit SQL for new tables)

- [ ] `yarn reconcile` exit 0, zero drift across the 13 tables it covers (`contests`, `speculations`, `positions`, `position_fills`, `commitments`, `maker_nonce_floors`, `leaderboards`, `leaderboard_registrations`, `leaderboard_speculations`, `leaderboard_winners`, `leaderboard_positions`, `secondary_market_listings`, `chain_events`).
- [ ] **`yarn reconcile` does NOT cover the 4 PR #22 tables.** Run the explicit SQL queries from Phase E-02 Part B in the test plan against `fees`, `leaderboard_fundings`, `leaderboard_rules`, `leaderboard_deviation_rules`. Expect zero unmatched chain_events, zero key-duplicates, zero NULL `source_block`.
- [ ] File ospex-indexer follow-up to add the 4 new tables to `reconcile.ts:TABLES`.
- [ ] Cursor at chain head, no stuck `pending_events`.

#### §3 — Per-tx + USDC value reconciliation (Phase E-03 = D-02 + D-03)

- [ ] Per-tx event counts match the **corrected** A-06 = 4 / A-07 = 2 expectation.
- [ ] No duplicate `chain_events` rows.
- [ ] **USDC reconciliation (per-balance, see D-03 / E-03 for formulas):**
  - [ ] `PositionModule.balanceOf(USDC)` = sum of unclaimed positions (winners: risk + profit; push: risk only).
  - [ ] `TreasuryModule.balanceOf(USDC)` = `SUM(leaderboards.prize_pool)` (= entry fees + LEADERBOARD_FUNDED amounts − claimed prizes). **Fees DO NOT live here — they go straight to `i_protocolReceiver`.**
  - [ ] `protocolReceiver.balanceOf(USDC)` delta since R4 deploy block = `SUM(fees.total_amount)`.
  - [ ] `SecondaryMarketModule.balanceOf(USDC)` = sum of unclaimed sale proceeds.

#### §4 — Targeted re-tests for events not yet on R4 chain (Phase E-04)

These five events did not fire in R4 Session 1 and so cannot be validated by replay alone. **Each is a free-running on-chain operation against the existing R4 deployment — no game-timing dependency.** A-29/A-30 require a **new pre-start leaderboard** (LB 1 has already started; rule setters revert with `RulesModule__LeaderboardStarted` once `block.timestamp >= lb.startTime`, so they cannot run on LB 1).

- [ ] **A-28 LEADERBOARD_FUNDED:** `TreasuryModule.fundLeaderboard(1, 5_000_000)` from any funder (LB 1 is fine — `fundLeaderboard()` is permissionless and has no pre-start gate). Verify `leaderboard_fundings` row + atomic `leaderboards.prize_pool += 5_000_000`. Cost: 5 USDC into LB 1's prize pool — funder does NOT directly recover it; it's distributed to the leaderboard winner on prize claim.
- [ ] **(Setup for A-29/A-30) Create new pre-start LB N:** `LeaderboardModule.createLeaderboard(...)` with `startTime = now + 1800` (30 min from creation), 4-day endTime, 24h+ safety + 24h+ ROI windows. Cost: 0.50 USDC creation fee. From a wallet that will be `lb.creator` for the rule setters.
- [ ] **A-29 RULE_SET:** call any `RulesModule.set*` from the LB N creator wallet **before its startTime**. The contract has no `setRule(uint256,string,uint256)` — use the actual setters: `setMinBankroll(N, 50_000_000)` is the simplest. Verify `leaderboard_rules` row, `rule_type='minBankroll'` stored verbatim. Re-fire same key → UPSERT (no duplicate).
- [ ] **A-30 DEVIATION_RULE_SET:** `RulesModule.setDeviationRule(N, NBA(=4), MoneylineScorer, Upper(=0), 200)` from LB N creator wallet **before LB N startTime**. Verify `leaderboard_deviation_rules` row keyed on `(network, lb, league, scorer, position_type)` with slug-mapped fields and `max_deviation=200`.
- [ ] **C-01 pending_events flow:** trigger CONTEST_CREATED with bogus `jsonodds_id` (no contest_reference row); confirm `pending_events` row appears with `reason='missing_contest_reference'`; insert reference; confirm row clears within ~10s. Cost: 1 USDC + 0.004 LINK.
- [ ] **C-01b retry-cap (PR #20):** repeat C-01 but do NOT insert the reference; lower `PENDING_MAX_ATTEMPTS` to 5 on Heroku temporarily; confirm pending row deleted (default action) at attempts ≥ 5; restore default after.

#### §5 — Open R4 findings (not closed by R4.1)

- [ ] Finding #1 — **Chainlink Functions verify callback can fail silently with no on-chain retry path.** Contest 2 emitted ORACLE_REQUEST_FAILED and was abandoned. Decide: (a) add a retry function in `OracleModule`, or (b) document re-create as standard recovery and add a monitor alert when `ORACLE_REQUEST_FAILED` lands. **Owner: Vince + smart-contract review.**
- [ ] Finding #4 — `PositionPredatesLeaderboard` checks `firstFillTimestamp < lb.startTime`, not `lb.creationBlock`. Doc-only clarification — already noted in plan v4.1.
- [ ] Deferred from R4 Session 1: **A-20b relist-after-sale** (requires MAKER to re-acquire position), **B-03 secondary-market leaderboard rejection** (requires post-startTime secondary market position). Both can run in any post-R4.1 session that produces the right setup.

#### §6 — On exit

- [ ] If §1–§4 all pass, mark R4.1 complete in this log and proceed to R4 Session 2 (score Cavs game, settle, claim, reconcile) **only after the Cavs game is FINAL**.
- [ ] **Settlement gate (mandatory for Session 2):** before calling `scoreContestFromOracle(5)`:
  - [ ] Read on-chain `start_time` via `cast call $CONTEST_MODULE "getContest(uint256)" 5` — for R4 Contest 5 this is `1777240800` (`2026-04-26T22:00:00Z` = 5:00 PM CDT, earliest defensible scoring at ~2026-04-27T00:30Z = ~7:30 PM CDT).
  - [ ] `block.timestamp >= start_time + 9000` (≥ 2.5 hours after start, NBA typical).
  - [ ] Game status from a scoring API (Rundown / Sportspage / JSONOdds) explicitly reports the game as FINAL.
  - [ ] If any of the above fails, **do not score**. Document the wait-gate in the session log and check again later.
- [ ] If any §1–§3 step fails, file ospex-indexer issue with reproducer + Supabase row dump; do not proceed to §4.
- [ ] If §4 events trigger but the typed-table projections don't land, file ospex-indexer issue; do not assume the handler is correct.

#### Testing-agent guidance (post-doc-fix)

- Do NOT restart R4. R4.1 is replay/projection validation against existing R4 history.
- Do NOT run A-04 / A-08 / A-09 (settlement / claim) until §6 settlement gate confirms the Cavs game is FINAL.
- First: run §1 replay/backfill from block 37285105 with the indexer at PR #22 or later.
- Verify: fired R4 events, commitment-row repair (full R4 fields including `speculation_key`), `fees` rows for FEE_PROCESSED + SPLIT_FEE_PROCESSED, no duplicate or missing first-fill SPLIT_FEE_PROCESSED.
- Run the explicit SQL queries from §2 Part B for the 4 PR #22 tables (reconcile CLI does NOT cover them yet).
- Only after the Cavs game is FINAL via the scoring API, continue Session 2 scoring/settlement/claim.

---

## Testing Reset (2026-04-22)

**Reason:** The indexing infrastructure changed from push-based webhook (ospex-fdb) to pull-based indexer (ospex-indexer). All previous test results validated the webhook, not the indexer. The test plan has been rewritten as v2 and will be re-executed from scratch.

**What changed (v1 → v2):**
- Replaced webhook architecture with pull-based polling indexer
- Added pending_events dependency resolution system (eliminates cascading FK failures)
- Added source_block column on all INSERT-created rows (enables reorg-safe deletion)
- Added reconcile CLI and backfill CLI for operational recovery
- Added Phase C (indexer-specific correctness) covering: pending_events flow, source_block, reconcile, backfill, cursor, deduplication
- Replaced aspirational agent Phase D with concrete volume/concurrency tests
- Incorporated future-contests-only constraint throughout
- All 25 handlers mapped to exact Supabase table writes from indexer source code

**Pre-execution checklist:**
- [x] Pause Alchemy webhook — already paused from prior session
- [x] Clean Supabase test data — already clean (cleanup ran prior, cursor past old blocks)
- [x] Restart indexer and confirm caught up — running, cursor advancing at head
- [x] Generate + fund MAKER/TAKER wallets — MAKER 0x7CA6... (~5 POL, ~1B USDC), TAKER 0x8D92... (~5 POL, ~1B USDC)
- [x] Create contest_reference rows for target games — monitor already populated ~50 games
- [x] Confirm contract approvals — all max(uint256) approvals confirmed

**Supabase cleanup SQL (run in SQL Editor):**
```sql
-- Delete all amoy test data. Order: children first (FK safety).
DELETE FROM leaderboard_positions WHERE network = 'amoy';
DELETE FROM leaderboard_speculations WHERE network = 'amoy';
DELETE FROM leaderboard_winners WHERE network = 'amoy';
DELETE FROM leaderboard_registrations WHERE network = 'amoy';
DELETE FROM leaderboards WHERE network = 'amoy';
DELETE FROM position_fills WHERE network = 'amoy';
DELETE FROM secondary_market_listings WHERE network = 'amoy';
DELETE FROM positions WHERE network = 'amoy';
DELETE FROM speculations WHERE network = 'amoy';
DELETE FROM contests WHERE network = 'amoy';
DELETE FROM commitments WHERE network = 'amoy';
DELETE FROM maker_nonce_floors WHERE network = 'amoy';
DELETE FROM chain_events WHERE network = 'amoy';
DELETE FROM pending_events WHERE network = 'amoy';
DELETE FROM indexer_cursor WHERE network = 'amoy';
```

After cleanup, restart the indexer:
```bash
powershell -Command "heroku ps:restart worker --app ospex-indexer"
```

---

## Test Results Summary (v3 — clean re-test)

Prior Session 1 results (2026-04-22) are archived below. This section is for the clean re-test after PRs 8-15 and Supabase wipe.

### T-00: Canary

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| T-00 | Indexer liveness canary (MIN_NONCE_UPDATED) | PASS | tx 0xf3c729..., block 37186158. chain_events row, maker_nonce_floors row (min_nonce=100, source_block=37186158), 0 pending_events. |

### Phase A: Handler Coverage

| Test ID | Event(s) | Track | Result | Evidence |
|---------|----------|-------|--------|----------|
| A-01 | CONTEST_CREATED | 1 | PASS | 3 contests (IDs 7,8,9), blocks 37186208/236/248 |
| A-02 | CONTEST_VERIFIED | 1 | PASS | All 3 verified via Chainlink callbacks within ~30s |
| A-03 | CONTEST_MARKETS_UPDATED | 1 | PASS | ML 180/205, spread -15 (189/193), total 2145 (191/191) |
| A-04 | CONTEST_SCORES_SET | 1 | | Session 2 — after game ends |
| A-05 | CONTEST_VOIDED | 4 | | Session 3 — 24h cooldown |
| A-06 | SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR | 1 | PASS | Spec 8, 4 events (3+treasury), positions + fills correct |
| A-07 | COMMITMENT_MATCHED + POSITION_MATCHED_PAIR (accumulation) | 1 | PASS | Maker risk accumulated to 20000000 (2×10 USDC), 2 events |
| A-08 | SPECULATION_SETTLED | 1 | | Session 2 — after scoring |
| A-09 | POSITION_CLAIMED | 1 | | Session 2 — after settling |
| A-10 | POSITION_TRANSFERRED | 3 | PASS | Via A-19 buyPosition, TAKER received position |
| A-11 | LEADERBOARD_CREATED | 2 | PASS | LB 2, entry_fee=5 USDC, start+5min, end+4d |
| A-12 | LEADERBOARD_SPECULATION_ADDED | 2 | PASS | Specs 13,14 added to LB 2 |
| A-13 | USER_REGISTERED | 2 | PASS | MAKER+TAKER registered, participants=2, prize_pool updated |
| A-14 | LEADERBOARD_POSITION_ADDED | 2 | PASS | Spec 14 position registered after startTime. Gas: 379k (>300k default!) |
| A-15 | LEADERBOARD_ROI_SUBMITTED + LEADERBOARD_NEW_HIGHEST_ROI | 2 | | Session 4 — after settling + endTime |
| A-16 | LEADERBOARD_PRIZE_CLAIMED | 2 | | Session 4 — after ROI window |
| A-17 | POSITION_LISTED | 3 | PASS | Spec 11 listed at 12 USDC by MAKER |
| A-18 | LISTING_UPDATED | 3 | PASS | Price updated to 11 USDC |
| A-19 | POSITION_SOLD + POSITION_TRANSFERRED | 3 | PASS | TAKER bought for 11 USDC, 2 CoreEventEmitted |
| A-20 | LISTING_CANCELLED | 3 | PASS | TAKER listed then cancelled |
| A-21 | SALE_PROCEEDS_CLAIMED | 3 | PASS | MAKER claimed 11 USDC proceeds |
| A-22 | COMMITMENT_CANCELLED | — | PASS | Hash 0x2eb039..., status=cancelled in Supabase |
| A-23 | MIN_NONCE_UPDATED | — | PASS | Nonce raised to 200 on Contest 7 moneyline |
| A-24 | SPREAD lifecycle | 1 | PASS | Spec 9, market_type=spread, line_ticks=-15 |
| A-25 | TOTAL lifecycle | 1 | PASS | Spec 10, market_type=total, line_ticks=2145 |

### New field verifications (PRs 8-15)

| After test | Field | Expected | Result | Evidence |
|------------|-------|----------|--------|----------|
| A-01/A-02 | contests.league_id | Real sport slug (e.g., "nba"), NOT "unknown" | PASS | Contest 7,9: "nba", Contest 8: "nhl". PR #8 fix confirmed. |
| A-06 | commitments row exists | source='indexer', contest_id/scorer/odds_tick populated | PASS | 11 commitment rows, all source='indexer' |
| A-19 | positions.acquired_via_secondary_market | true for buyer | PASS | TAKER spec 11 upper: acquired_via_secondary_market=true |
| A-19 | positions.first_fill_timestamp | = seller's original fill time | DEFERRED | Needs manual Supabase query to verify exact timestamp |
| A-19 | listings.sold_price/risk/profit | Pre-sale values populated | PASS | Verified via listing status transition |
| A-20 relist | listings.sold_* after relist | sold_price/risk/profit/at ALL null on new active listing | PASS | Relisted listing: sold_price=null, sold_risk_amount=null. PR #14 fix confirmed. |
| A-22 | commitments row for cancelled hash | status='cancelled', source='indexer' | PASS | Hash 0x2eb039..., status=cancelled, source=indexer |
| A-23 | commitments.nonce_invalidated | Commitments below nonce floor marked invalidated (if present) | N/A | All indexer-created commitments have nonce=0 (event data doesn't include nonce). MIN_NONCE_UPDATED handler can't invalidate rows without real nonce values. Feature only works on agent-created commitments. |

### Phase B: Hardening

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| B-01 | Post-cooldown match rejection | | Session 3 — after 24h cooldown |
| B-02 | acquiredViaSecondaryMarket flag | PASS | TAKER spec 11 upper: acquired_via_secondary_market=true |
| B-03 | Secondary market position rejected from leaderboard | PARTIAL | Reverts with PositionPredatesLeaderboard (position was pre-startTime). SecondaryMarketPositionIneligible check runs second — would need post-startTime secondary market purchase to test. |

### Phase C: Indexer-Specific

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| C-01 | Pending events dependency flow | SKIPPED | No missing contest_reference scenario arose (monitor populated all games) — can test manually later |
| C-02 | source_block population | PASS | Zero null source_block across contests, speculations, positions, leaderboards, leaderboard_registrations, leaderboard_positions |
| C-03 | Reconcile CLI | | Session 2 |
| C-04 | Backfill CLI (PR #10 atomic RPC) | | Session 2 |
| C-04a | Backfill: no orphaned projections | | Session 2 |
| C-04b | Backfill: leaderboard rows complete | | Session 2 |
| C-04c | Backfill: commitment fields correct | | Session 2 |
| C-05 | Cursor advancement | PASS | Cursor at 37187170, advancing normally at chain head |
| C-06 | Chain events deduplication | PASS | 51 events, zero duplicates, UNIQUE constraint active |

### Phase D: Volume / Concurrency

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| D-01 | Rapid-fire multi-match | PASS | 3 sequential matches on spec 8 lower (nonces 210,213,214). Parallel attempt failed with nonce collision (expected). All 3 accumulated correctly: risk=15M, profit=13.65M. |
| D-02 | Cross-table consistency | | Session 2 |
| D-03 | Value reconciliation (USDC) | | Session 2 |

---

## Session Execution Log

### Session 1 (v3) — 2026-04-24 (Day 1, clean re-test)

**Duration:** ~1.5 hours (04:15–05:00 UTC)

**Contests created:**

| Contest | ID | Game | jsonodds_id | start_time | Track |
|---------|----|------|-------------|------------|-------|
| A | 7 | New York Knicks @ Atlanta Hawks | `17ceee94-f056-4ce2-a70b-5dbe49cfa159` | 2026-04-25T22:00:00Z | 1 (score/settle) |
| B | 8 | Dallas Stars @ Minnesota Wild | `549139ba-380b-440d-ae3e-30ae53f3b71d` | 2026-04-25T21:30:00Z | 3 (secondary market) |
| C | 9 | Detroit Pistons @ Orlando Magic | `7b460416-0632-440d-96a5-e92746383776` | 2026-04-25T17:00:00Z | 4 (void/cooldown) |

**Speculation IDs created:**

| Spec ID | Contest | Market | Notes |
|---------|---------|--------|-------|
| 8 | A (7) | moneyline | Track 1 primary. lineTicks=0. 2 fills (20 USDC total maker risk). |
| 9 | A (7) | spread | lineTicks=-15 (-1.5). A-24. |
| 10 | A (7) | total | lineTicks=2145 (214.5). A-25. |
| 11 | B (8) | moneyline | Track 3. Secondary market sale + relist. |
| 12 | C (9) | moneyline | Track 4. Void cooldown. |
| 13 | A (7) | spread | lineTicks=-30 (-3.0). Pre-startTime, ineligible for LB. |
| 14 | A (7) | total | lineTicks=2200 (220.0). Post-startTime, registered for LB 2. |

**Leaderboard:**

| ID | startTime | endTime | safety | roiWindow | Speculations | Participants |
|----|-----------|---------|--------|-----------|-------------|--------------|
| 2 | 2026-04-24T04:44:42Z | 2026-04-28T04:39:42Z | 60s | 60s | 13, 14 | 2 (MAKER, TAKER) |

**Indexer state at end of session:**
- 51 chain_events rows (18 distinct event types)
- 7 speculations (IDs 8-14)
- 17 position rows across 7 speculations
- 11 commitments (all source=indexer, 1 cancelled)
- 2 maker_nonce_floors
- 2 secondary_market_listings (1 active relist, 1 cancelled)
- 1 leaderboard, 2 registrations, 2 eligible speculations, 1 position
- 10 position_fills
- 0 pending_events
- Cursor at block ~37187170, advancing normally
- Zero indexer errors

**Findings:**

1. **league_id fix confirmed (PR #8).** Contest 7,9 = "nba", Contest 8 = "nhl". The on-chain LeagueId enum maps correctly now: 4→nba, 6→nhl. Prior Session 1 had "unknown" for all.

2. **Commitments populated by indexer (PRs #11-#13).** 11 commitment rows created with source='indexer'. Status tracking works: 10 partially_filled, 1 cancelled. This was empty in prior Session 1.

3. **acquired_via_secondary_market flag works (PR #9).** TAKER's position on spec 11 correctly shows acquired_via_secondary_market=true after buyPosition.

4. **sold_* cleared on relist (PR #14).** After MAKER sold spec 11 position and relisted, sold_price/sold_risk_amount are null on the new active listing. Relist upsert correctly nulls stale sold_* columns.

5. **4 CoreEventEmitted per first-fill match (not 3).** The plan expected 3 events (SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR) but 4 fire. The 4th event topic is `0x2f8c9d74...` — likely a treasury fee or internal tracking event. Accumulation fills correctly emit only 2.

6. **registerPositionForLeaderboard requires 500k gas.** Default 300k gas limit causes OOG revert. The function reads position data, validates rules, and emits events — needs higher gas. Used 379k actual.

7. **LeaderboardModule time check precedes secondary market check.** B-03 test hit PositionPredatesLeaderboard (position created before startTime) before reaching SecondaryMarketPositionIneligible. Both checks work, but testing the secondary market rejection requires a position acquired after leaderboard startTime.

8. **Nonce collision in parallel tx submission.** D-01 parallel attempt (3 txs from same sender) failed for 2 of 3 with "replacement fee too low" — expected behavior since all get same nonce. Sequential rapid-fire (within seconds) works correctly.

9. **No MLB games in contest_reference.** Only NBA (sport=1) and NHL (sport=5) available. Testing covers 2 leagues (NBA + NHL). **Post-session policy:** Multi-sport coverage is now mandatory — future sessions must halt if any available sport is missing. See AMOY_STRESS_TEST_PLAN.md "Constraint: Multi-Sport Coverage".

10. **Amoy block timestamps can diverge from machine clock.** Observed ~300s skew between machine `date +%s` and on-chain block.timestamp. Caused leaderboard startTime to be set before creation block timestamp. Not a bug — just a clock sync issue for test tooling.

**Next session gates:**
- Session 2: Knicks @ Hawks game ends (~2026-04-25T23:30Z / ~6:30 PM CDT) → score, settle, claim, C-03, C-04, D-02, D-03
- Session 3: Contest C void cooldown (~2026-04-25T17:00Z + 24h = 2026-04-26T17:00Z) → void, post-cooldown rejection
- Session 4: Leaderboard endTime (2026-04-28T04:39:42Z + 60s safety + 60s ROI) → ROI submission, prize claim
  - **Note:** Leaderboard 2 was created with 60s safety/ROI windows before the 24-hour minimum policy was established. Future leaderboards must use ≥86400s for both. See AMOY_STRESS_TEST_PLAN.md A-11 notes.

---

### Session 1 (prior, stale) — 2026-04-22 (Day 1)

**Duration:** ~2.5 hours (20:00–22:55 UTC)

**Contests created:**

| Contest | ID | Game | jsonodds_id | start_time | Track |
|---------|----|------|-------------|------------|-------|
| A | 4 | Cleveland Cavaliers @ Toronto Raptors | `14ae309a-522d-4b96-aaf1-4f6110390566` | 2026-04-24T00:00:00Z | 1 (score/settle) |
| B | 5 | Boston Celtics @ Philadelphia 76ers | `81d367a7-a471-41c9-b027-09a8a983fdda` | 2026-04-24T23:00:00Z | 3 (secondary market) |
| C | 6 | Orlando Magic @ Detroit Pistons | `67181d02-aaec-4ebd-82a7-d317cfe461bd` | 2026-04-22T23:00:00Z | 4 (void/cooldown) |

**Speculation IDs created:**

| Spec ID | Contest | Market | Notes |
|---------|---------|--------|-------|
| 1 | Old (webhook era) | — | Pre-existing from prior testing. Not in Supabase (cleanup ran). On-chain only. |
| 2 | C (6) | moneyline | First new match. Track 4. |
| 3 | A (4) | moneyline | Track 1 primary. Accumulation test + secondary market sale. |
| 4 | B (5) | moneyline | Track 3. |
| 5 | A (4) | spread | lineTicks=-30. |
| 6 | A (4) | total | lineTicks=2150. |
| 7 | A (4) | spread | lineTicks=-50. Created post-leaderboard for A-14 registration. |

**Test wallets:**

| Role | Address |
|------|---------|
| Deployer | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` |
| MAKER | `0x7CA624C92b8Aed9ee83Ed621A898f7524FAfBa24` |
| TAKER | `0x8D92451e7457b0076349eBA44d60b36a1038bF31` |

**Leaderboard:**

| ID | startTime | endTime | safety | roiWindow | Speculations |
|----|-----------|---------|--------|-----------|-------------|
| 1 | 2026-04-22T22:46:14Z | 2026-04-26T22:41:14Z | 60s | 60s | 2, 3, 7 |

**Indexer state at end of session:**
- 36 chain_events rows (16 distinct event types)
- 5 speculations (IDs 2-6, plus 7 created late)
- 11 position rows across 6 speculations
- 0 pending_events
- Cursor at block ~37115100, advancing normally
- Zero indexer errors

**Findings:**

1. **league_id="unknown" on all contests.** The oracle returns a numeric leagueId value that does not appear in the indexer's `LEAGUE_ID_MAP`. NBA should map to 4→"nba", but "unknown" was stored. Investigate the oracle callback's actual leagueId encoding vs the indexer's mapping. Non-blocking for testing.

2. **Speculation 1 is from the webhook era.** The on-chain speculation counter was at 1 before Session 1 started (from old contest 1-3 testing). Our new speculations start at ID 2. Speculation 1 exists on-chain but not in Supabase (cleanup deleted it, cursor past those blocks).

3. **LeaderboardModule__PositionPredatesLeaderboard.** Positions created before the leaderboard was created cannot be registered. Required creating a new speculation (ID 7) after leaderboard creation (block 37114594) to have an eligible position. This is correct contract behavior — leaderboards enforce that positions were taken after the leaderboard was created.

4. **LeaderboardModule__ContestAlreadyStarted.** Attempting to add speculation 1 (from old webhook-era contest) to the leaderboard failed because that old contest's start_time had already passed. This is expected — the contract prevents adding speculations from already-started contests to new leaderboards.

5. **Backfill CLI does not chunk eth_getLogs.** The live indexer uses `BLOCK_RANGE_CHUNK=10` (Heroku config) to respect Alchemy free-tier limits. The backfill CLI sends the full range in one call, which fails on free-tier Alchemy with >10 blocks. Fix: add chunking to the backfill CLI, or use a PAYG RPC for backfills.

6. **Backfill CLI partial-range FK violation.** When backfilling a range that contains a parent row (contest) but not its children (speculations in later blocks), the delete step fails with `fk_speculation_contest`. The CLI needs to either: (a) expand the affected set to include dependent rows outside the range, or (b) use `CASCADE` deletes, or (c) require full-entity-lifecycle ranges. This is a real limitation that would affect production recovery scenarios.

7. **~~commitments table empty by design~~** — SUPERSEDED by PRs #11-#13. The indexer now upserts commitment rows on COMMITMENT_MATCHED and COMMITMENT_CANCELLED. The commitments table should be populated after any on-chain match or cancel, even without the agent server. This finding from Session 1 no longer applies.

**Next session gates:**
- Session 2: Cavaliers @ Raptors game ends (~2026-04-24T02:30Z) → score, settle, claim
- Session 3: Contest C void cooldown (~2026-04-23T23:00Z + 24h = 2026-04-24T23:00Z) → void, post-cooldown rejection
- Session 4: Leaderboard endTime (2026-04-26T22:41:14Z + 60s safety + 60s ROI) → ROI submission, prize claim

---

## Archived: Previous Webhook Test Results (v1, pre-reset)

The following results were from testing against ospex-fdb (webhook). Archived for reference only.

| Test ID | Description | Result | Notes |
|---------|-------------|--------|-------|
| A-01 | CONTEST_CREATED | PASS (webhook) | 3 contests created. MLB oracle failures noted. |
| A-02 | CONTEST_VERIFIED | PASS (webhook) | NBA contest verified via Chainlink callback. |
| A-03 | CONTEST_MARKETS_UPDATED | SKIPPED | Not required for matching. |
| A-04 | COMMITMENT_MATCHED + SPECULATION_CREATED + POSITION_MATCHED_PAIR | PASS (webhook) | 4 fills, 20 USDC total. 2 fills lost to webhook pause. |
| A-05 | CONTEST_SCORES_SET | PASS (webhook) | Required 2 attempts (Rundown API transient failure). |
| A-06 | SPECULATION_SETTLED | PASS (webhook) | win_side="home". |
| A-07 | POSITION_CLAIMED | PASS (webhook) | Taker claimed 38.2 USDC. |
| B-07 | Oracle Failure Path | PASS (webhook) | Observed naturally. |

### Archived Critical Findings (webhook-era)

1. **Firebase Functions Scorer Config Mismatch** — RESOLVED. Webhook-specific config issue.
2. **Alchemy Webhook Auto-Pause** — NO LONGER APPLICABLE. Pull indexer doesn't use webhooks.
3. **Cascading FK Violations** — ADDRESSED by pending_events system in indexer.
4. **Oracle Verify Script Rejects Non-Scheduled Games** — STILL RELEVANT. Oracle limitation, not indexer-specific.
5. **Rundown API Transient Failure** — STILL RELEVANT. External API flakiness.
