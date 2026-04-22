# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Plan version:** v2 (ospex-indexer)
**Phase:** AWAITING APPROVAL — Plan written, pending review before execution.
**Next action:** Review `AMOY_STRESS_TEST_PLAN.md` v2 and approve for execution.

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
- [ ] Pause Alchemy webhook
- [ ] Clean Supabase test data (see cleanup SQL below)
- [ ] Restart indexer and confirm caught up
- [ ] Generate + fund MAKER/TAKER wallets
- [ ] Create contest_reference rows for target games
- [ ] Confirm contract approvals

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

## Test Results Summary (v2)

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

### Phase B: Hardening

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| B-01 | Post-cooldown match rejection | | |
| B-02 | acquiredViaSecondaryMarket flag | | |
| B-03 | Secondary market position rejected from leaderboard | | |

### Phase C: Indexer-Specific

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| C-01 | Pending events dependency flow | | |
| C-02 | source_block population | | |
| C-03 | Reconcile CLI | | |
| C-04 | Backfill CLI | | |
| C-05 | Cursor advancement | | |
| C-06 | Chain events deduplication | | |

### Phase D: Volume / Concurrency

| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| D-01 | Rapid-fire multi-match | | |
| D-02 | Cross-table consistency | | |
| D-03 | Value reconciliation (USDC) | | |

---

## Session Execution Log

### Session 1 — Day 1 (TBD)

_Execution not yet started. Awaiting plan approval._

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
