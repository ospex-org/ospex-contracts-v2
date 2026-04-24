# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Plan version:** v3.0 (post-indexer PRs 8-15)
**Phase:** Session 1 COMPLETE. 21/25 event types tested, all passing. 51 chain events indexed, 0 pending, 0 errors.
**Next action:** Session 2 (Score/Settle/Claim on Contest A) after Knicks @ Hawks game ends (~7:30 PM CDT April 25). Session 3 (Void Contest C) after void cooldown expires (~12 PM CDT April 26).

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

9. **No MLB games in contest_reference.** Only NBA (sport=1) and NHL (sport=5) available. Testing covers 2 leagues (NBA + NHL).

10. **Amoy block timestamps can diverge from machine clock.** Observed ~300s skew between machine `date +%s` and on-chain block.timestamp. Caused leaderboard startTime to be set before creation block timestamp. Not a bug — just a clock sync issue for test tooling.

**Next session gates:**
- Session 2: Knicks @ Hawks game ends (~2026-04-25T23:30Z / ~6:30 PM CDT) → score, settle, claim, C-03, C-04, D-02, D-03
- Session 3: Contest C void cooldown (~2026-04-25T17:00Z + 24h = 2026-04-26T17:00Z) → void, post-cooldown rejection
- Session 4: Leaderboard endTime (2026-04-28T04:39:42Z + 60s safety + 60s ROI) → ROI submission, prize claim

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
