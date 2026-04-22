# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Phase:** RESET — Restarting from zero with ospex-indexer.

**Next action:** Clean Supabase state, pause webhook, wait for indexer to catch up to head, then re-execute full test plan from A-01.

---

## Testing Reset (2026-04-22)

**Reason:** The indexing infrastructure changed from push-based webhook (ospex-fdb) to pull-based indexer (ospex-indexer). All previous test results validated the webhook, not the indexer. The test plan is being re-executed from scratch against the new system.

**What changed:**
- ospex-indexer is a pull-based worker (eth_getLogs polling) replacing the Alchemy webhook
- Pending events system handles dependency ordering (no more lost events)
- Deterministic recovery model for reorgs and backfill
- All 25 event types handled with Supabase RPCs for complex cases

**Pre-test checklist:**
- [ ] Pause Alchemy webhook (Alchemy Dashboard → Webhooks → pause the insightWebhook)
- [ ] Clean Supabase test data from previous rounds (see SQL below)
- [ ] Confirm indexer is caught up to head (`heroku logs --app ospex-indexer --tail`)
- [ ] Confirm no errors in indexer logs

**Supabase cleanup SQL (run in SQL Editor):**
```sql
-- Delete all test data from previous webhook-based testing rounds.
-- This gives the indexer a clean slate.
-- Order: children first (FK safety)
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

After running the cleanup, restart the indexer:
```bash
heroku ps:restart worker --app ospex-indexer
```

**Indexer-specific validation (add to each test):**
- `source_block` is populated (NOT NULL) on every projected row
- `chain_events` row exists for every event
- No rows in `pending_events` (all dependencies resolved)
- No errors in `heroku logs --app ospex-indexer`

---

## Test Results Summary

| Test ID | Description | Result | Notes |
|---------|-------------|--------|-------|
| A-01 | CONTEST_CREATED | NOT TESTED | Reset — re-execute with indexer |
| A-02 | CONTEST_VERIFIED | NOT TESTED | |
| A-03 | CONTEST_MARKETS_UPDATED | NOT TESTED | |
| A-04 | COMMITMENT_MATCHED + SPECULATION_CREATED + POSITION_MATCHED_PAIR | NOT TESTED | |
| A-05 | CONTEST_SCORES_SET | NOT TESTED | |
| A-06 | SPECULATION_SETTLED | NOT TESTED | |
| A-07 | POSITION_CLAIMED | NOT TESTED | |
| A-08 | POSITION_TRANSFERRED | NOT TESTED | |
| A-09 | COMMITMENT_CANCELLED | NOT TESTED | |
| A-10 | MIN_NONCE_UPDATED | NOT TESTED | |
| A-11 | LEADERBOARD_CREATED | NOT TESTED | |
| A-12 | USER_REGISTERED | NOT TESTED | |
| A-13 | LEADERBOARD_SPECULATION_ADDED | NOT TESTED | |
| A-14 | LEADERBOARD_POSITION_ADDED | NOT TESTED | |
| A-15 | LEADERBOARD_ROI_SUBMITTED | NOT TESTED | |
| A-16 | LEADERBOARD_NEW_HIGHEST_ROI | NOT TESTED | |
| A-17 | LEADERBOARD_PRIZE_CLAIMED | NOT TESTED | |
| A-18 | CONTEST_VOIDED | NOT TESTED | |
| A-19 | POSITION_LISTED | NOT TESTED | |
| A-20 | LISTING_UPDATED | NOT TESTED | |
| A-21 | POSITION_SOLD | NOT TESTED | |
| A-22 | LISTING_CANCELLED | NOT TESTED | |
| A-23 | SALE_PROCEEDS_CLAIMED | NOT TESTED | |
| A-24 | Multi-fill single commitment | NOT TESTED | |
| A-25 | Rapid-fire multi-event block | NOT TESTED | |

---

## Archived: Previous Webhook Test Results (pre-reset)

The following results were from testing against ospex-fdb (webhook). Archived for reference only — they do not validate the indexer.

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
