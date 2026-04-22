# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Phase:** Step 3 — Execution IN PROGRESS.

**Next action:** Continue with remaining Phase A tests (A-08 through A-25), then Phase B and C.

## Test Results Summary

| Test ID | Description | Result | Notes |
|---------|-------------|--------|-------|
| A-01 | CONTEST_CREATED | **PASS** | 3 contests created (2 MLB + 1 NBA). All indexed. |
| A-02 | CONTEST_VERIFIED | **PASS** | NBA contest verified via Chainlink callback in ~14s. |
| A-03 | CONTEST_MARKETS_UPDATED | NOT TESTED | Skipped — not required for matching. |
| A-04 | COMMITMENT_MATCHED + SPECULATION_CREATED + POSITION_MATCHED_PAIR | **PASS** | On-chain: 4 fills, 20 USDC total. Supabase: 2 fills indexed after config fix. |
| A-05 | CONTEST_SCORES_SET | **PASS** | Raptors 105, Cavaliers 115. Required 2 attempts (Rundown API transient failure). |
| A-06 | SPECULATION_SETTLED | **PASS** | win_side="home". Gas: 96,099. |
| A-07 | POSITION_CLAIMED | **PASS** | Taker claimed 38.2 USDC (18.2 risk + 20.0 profit). |
| B-07 | Oracle Failure Path | **PASS** | Observed naturally. No corrupt state. Subsequent contests unaffected. |

## Critical Findings

### FINDING 1: Firebase Functions Scorer Config Mismatch (RESOLVED)

**Severity:** HIGH — caused complete indexer failure for matching events.

**Root cause:** `functions.config().scorers.*` had addresses from the previous v2.3/v2.4 deployment. The SPECULATION_CREATED handler called `scorerToMarketType()` with the new MoneylineScorerModule address which didn't match.

**Impact:** Handler crash → 500 → Alchemy auto-paused webhook → events permanently lost.

**Fix:** `firebase functions:config:set scorers.moneyline="0x4CDf8cc2..." scorers.spread="0x36F3f4..." scorers.total="0xB814f3..."` + redeploy.

**Lesson:** Firebase Functions runtime config must be updated whenever contract addresses change. Add to deployment checklist.

### FINDING 2: Alchemy Webhook Auto-Pause with No Replay

**Severity:** HIGH — events permanently lost on pause.

**Root cause:** After receiving repeated 500 responses, Alchemy auto-paused the webhook. Message: "This webhook was disabled because it failed to return a 2xx HTTP status over 24 hours."

**Impact:** Events from 2 of 4 match transactions were permanently lost. Alchemy does not replay queued events after unpausing — only new events are delivered.

**Lesson:** Need a backfill mechanism that can re-process events from chain_events or directly from chain. The idempotency design (chain_events as audit log) is the right foundation but replay tooling doesn't exist yet.

### FINDING 3: Cascading FK Violation

**Severity:** MEDIUM — downstream handlers fail when parent event was lost.

**Root cause:** SPECULATION_CREATED row never created (lost during Finding 1). Subsequent POSITION_MATCHED_PAIR tried to insert a position referencing the nonexistent speculation → FK violation.

**Impact:** Required manual insertion of the speculation row via Supabase REST API to unblock.

**Lesson:** Handlers should consider whether parent entities exist and either create them or fail gracefully with clear error messages pointing at the missing dependency.

### FINDING 4: Oracle Verify Script Rejects Non-Scheduled Games

**Severity:** LOW — by design, but error handling is poor.

**Root cause:** `contestCreation.js` checks `event_status === 'STATUS_SCHEDULED'` for Rundown and `status === 'scheduled'` for Sportspage. When a game is in progress or final, the data extraction blocks are skipped silently, leaving all return values as `undefined`. The final comparison `undefined === undefined` passes, then `BigInt(NaN)` throws.

**Impact:** Cannot create contests for in-progress or completed games. This is intentional behavior but the error message is misleading — should throw "Game is not in scheduled status" instead of falling through to a NaN error.

### FINDING 5: Rundown API Transient Failure

**Severity:** LOW — self-resolving on retry.

**Root cause:** First scoring attempt for contest 3 failed with "Error: Rundown API error:" — the RapidAPI endpoint returned an error. Second attempt succeeded.

**Impact:** Scoring required a retry. The ORACLE_REQUEST_FAILED event was emitted correctly. No corrupt state.

## On-Chain State (Amoy)

| Entity | ID | Details |
|--------|-----|---------|
| Contest 1 | MLB Tigers @ Red Sox | status=unverified (oracle failed) |
| Contest 2 | MLB Astros @ Guardians | status=unverified (oracle failed) |
| Contest 3 | NBA Raptors @ Cavaliers | status=scored, 105-115 |
| Speculation 1 | Moneyline on contest 3 | status=closed, win_side=home |
| Maker position | Upper (Away/Raptors) | 20 USDC risk, 18.2 profit, NOT claimed (loser) |
| Taker position | Lower (Home/Cavaliers) | 18.2 USDC risk, 20 profit, CLAIMED 38.2 USDC |

## Test Infrastructure

| Item | Status |
|---|---|
| Test wallets funded (MAKER + TAKER) | DONE |
| USDC approvals (Position, Treasury, Secondary) | DONE |
| LINK approved for deployer | DONE |
| Helper script: create-contest.js | DONE |
| Helper script: match-commitment.js | DONE |
| Helper script: score-contest.js | DONE |
| Firebase Functions scorer config | FIXED |
| Alchemy webhook | ACTIVE |

## Time-Sensitive Tests Tracking

| Test | Contest/Entity | Created At | Eligible At | Status |
|------|----------------|------------|-------------|--------|
| A-22 (CONTEST_VOIDED) | Contest 3 | 2026-04-20 22:38 UTC | 2026-04-21 23:00 UTC | ELIGIBLE (startTime + 1 day) |
| B-01 (Post-cooldown rejection) | Contest 3 | Same | Same | ELIGIBLE |
| B-11 (Cooldown boundary) | Needs new contest | — | — | NOT STARTED |

## Session History

### Session 1 — 2026-04-20 (Plan + Setup)

- Created comprehensive test plan
- Fixed NBA/NHL monitoring dates (ospex-firebase PR #18 merged)
- Generated test wallets, funded with POL + USDC, set approvals
- Created PR #5 for test plan docs (merged)

### Session 2 — 2026-04-20 (Execution Start)

- Incorporated OC review feedback (11 new test cases)
- Fixed C-08 push/leaderboard documentation error
- Executed A-01: 3 contests created (2 MLB, 1 NBA). MLB oracle failures diagnosed.
- Executed A-02: NBA contest verified via Chainlink callback.
- Executed A-04: Match commitment — on-chain success. Discovered Firebase config mismatch (Finding 1).
- Discovered B-07 naturally (oracle failure path — no corrupt state).
- Diagnosed webhook auto-pause (Finding 2), fixed scorer config, redeployed Firebase Functions.
- Manual speculation row insertion to unblock FK cascade (Finding 3).
- Verified full pipeline with fresh match transaction.

### Session 3 — 2026-04-21 (Scoring + Settlement + Claim)

- Executed A-05: Contest 3 scored (Raptors 105, Cavaliers 115). Required retry due to Rundown API transient failure.
- Executed A-06: Speculation 1 settled. win_side=home.
- Executed A-07: Taker claimed 38.2 USDC. Full moneyline lifecycle complete.
- All chain_events correctly indexed: CONTEST_SCORES_SET, SPECULATION_SETTLED, POSITION_CLAIMED.
