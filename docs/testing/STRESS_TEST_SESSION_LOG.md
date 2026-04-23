# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Plan version:** v3.0 (post-indexer PRs 8-15)
**Phase:** SUPABASE WIPED — ready for clean Session 1 re-test.
**Next action:** Confirm indexer redeployed with migrations 025-029 + league_id fix. Wait for cursor to catch up. Then execute Session 1 from scratch.

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
| T-00 | Indexer liveness canary (MIN_NONCE_UPDATED) | | |

### Phase A: Handler Coverage

| Test ID | Event(s) | Track | Result | Evidence |
|---------|----------|-------|--------|----------|
| A-01 | CONTEST_CREATED | 1 | | |
| A-02 | CONTEST_VERIFIED | 1 | | |
| A-03 | CONTEST_MARKETS_UPDATED | 1 | | |
| A-04 | CONTEST_SCORES_SET | 1 | | |
| A-05 | CONTEST_VOIDED | 4 | | |
| A-06 | SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR | 1 | | |
| A-07 | COMMITMENT_MATCHED + POSITION_MATCHED_PAIR (accumulation) | 1 | | |
| A-08 | SPECULATION_SETTLED | 1 | | |
| A-09 | POSITION_CLAIMED | 1 | | |
| A-10 | POSITION_TRANSFERRED | 3 | | |
| A-11 | LEADERBOARD_CREATED | 2 | | |
| A-12 | LEADERBOARD_SPECULATION_ADDED | 2 | | |
| A-13 | USER_REGISTERED | 2 | | |
| A-14 | LEADERBOARD_POSITION_ADDED | 2 | | |
| A-15 | LEADERBOARD_ROI_SUBMITTED + LEADERBOARD_NEW_HIGHEST_ROI | 2 | | |
| A-16 | LEADERBOARD_PRIZE_CLAIMED | 2 | | |
| A-17 | POSITION_LISTED | 3 | | |
| A-18 | LISTING_UPDATED | 3 | | |
| A-19 | POSITION_SOLD + POSITION_TRANSFERRED | 3 | | |
| A-20 | LISTING_CANCELLED | 3 | | |
| A-21 | SALE_PROCEEDS_CLAIMED | 3 | | |
| A-22 | COMMITMENT_CANCELLED | — | | |
| A-23 | MIN_NONCE_UPDATED | — | | |
| A-24 | SPREAD lifecycle | 1 | | |
| A-25 | TOTAL lifecycle | 1 | | |

### New field verifications (PRs 8-15)

| After test | Field | Expected | Result | Evidence |
|------------|-------|----------|--------|----------|
| A-01/A-02 | contests.league_id | Real sport slug (e.g., "nba"), NOT "unknown" | | |
| A-06 | commitments row exists | source='indexer', contest_id/scorer/odds_tick populated | | |
| A-19 | positions.acquired_via_secondary_market | true for buyer | | |
| A-19 | positions.first_fill_timestamp | = seller's original fill time | | |
| A-19 | listings.sold_price/risk/profit | Pre-sale values populated | | |
| A-22 | commitments row for cancelled hash | status='cancelled', source='indexer' | | |

### Phase B: Hardening

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| B-01 | Post-cooldown match rejection | | |
| B-02 | acquiredViaSecondaryMarket flag | | |
| B-03 | Secondary market position rejected from leaderboard | | |

### Phase C: Indexer-Specific

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| C-01 | Pending events dependency flow | | Deferred — requires contest with missing contest_reference. |
| C-02 | source_block population | **PASS** | Zero null source_block across 9 tables (33 rows). |
| C-03 | Reconcile CLI | **PASS** | All 13 tables compared, zero drift. Exit code 0. |
| C-04 | Backfill CLI | **BLOCKED** | Two issues: (1) Alchemy free tier limits eth_getLogs to 10-block ranges, CLI doesn't chunk. (2) Partial-range backfill hits FK constraints when parent rows have children outside the range. See findings. |
| C-05 | Cursor advancement | **PASS** | Cursor at block 37129455, hash matches on-chain exactly. Lag=135 blocks (~128 depth + processing). |
| C-06 | Chain events deduplication | **PASS** | Zero duplicates across chain_events (46 rows), positions (14), speculations (6). pending_events=0. |

### Phase D: Volume / Concurrency

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| D-01 | Rapid-fire multi-match | | |
| D-02 | Cross-table consistency | | |
| D-03 | Value reconciliation (USDC) | | |

---

## Session Execution Log

### Session 1 — 2026-04-22 (Day 1)

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

7. **commitments table empty by design.** The `rpc_commitment_matched` RPC writes to `position_fills` (9 rows) but not `commitments`. The `commitments` table is populated by the agent server when off-chain commitments are created (Michelle posts them). The indexer only updates existing commitment rows (via COMMITMENT_CANCELLED and MIN_NONCE_UPDATED). Stress tests created commitments purely on-chain, bypassing the agent pipeline.

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
