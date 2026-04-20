# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Phase:** Step 3 — Execution IN PROGRESS. **BLOCKED on webhook delivery issue.**

**Next action:** Investigate why Alchemy webhook only delivers partial events from multi-event transactions (block 36999466 had 4 CoreEventEmitted events, only 1 was delivered).

## CRITICAL FINDING: Webhook Partial Delivery

**Severity:** HIGH — causes Supabase state to diverge from chain.

**What happened:**
- Match transaction `0x28278af5...` emitted 4 CoreEventEmitted events in block 36999466
- Alchemy webhook only delivered 1 event (the fee event, log_index likely 0)
- SPECULATION_CREATED, POSITION_MATCHED_PAIR, COMMITMENT_MATCHED were NOT delivered
- On-chain state is correct (speculation ID=1, positions exist)
- Supabase: `speculations` empty, `positions` empty — state diverged

**Impact:** Any transaction emitting multiple CoreEventEmitted events may lose events. This affects matchCommitment (4 events), secondary market sales (2 events), and any other multi-event paths.

**Investigation needed:**
1. Check Alchemy webhook configuration (address filter, topic filter, log limit per delivery)
2. Check if this is a timing issue (events delivered later in subsequent webhook calls)
3. Review webhook logs in Firebase Functions for what was actually received
4. Possible fix: webhook retry/backfill mechanism

## Test Results

| Test ID | Description | Result | Notes |
|---------|-------------|--------|-------|
| A-01 | CONTEST_CREATED | **PASS** | Contest 3 (NBA Raptors @ Cavaliers) created, indexed in Supabase |
| A-01 | CONTEST_CREATED (MLB) | PASS (with caveat) | Contests 1,2 created but oracle callback failed — MLB team name parsing issue in contestCreation.js |
| A-02 | CONTEST_VERIFIED | **PASS** | Contest 3 verified via Chainlink callback, league_id set, start_time set |
| A-04 | COMMITMENT_MATCHED + SPECULATION_CREATED + POSITION_MATCHED_PAIR | **FAIL (webhook)** | On-chain: SUCCESS. Supabase: MISSING. Webhook only delivered 1 of 4 events. |
| B-07 | Oracle Failure Path | **PASS** | MLB contests remain "unverified", no corrupt downstream state |

## Blocking Items

| Item | Status | Notes |
|------|--------|-------|
| Webhook partial delivery | **BLOCKING** | Must resolve before continuing — all multi-event tests will fail |
| MLB team name parsing | NON-BLOCKING | NBA works fine, MLB contestCreation.js has NaN error on team ID lookup |

## Test Infrastructure

| Item | Status |
|---|---|
| Test wallets funded | DONE |
| USDC approvals set | DONE |
| LINK approved for deployer | DONE |
| Helper scripts (create-contest.js, match-commitment.js) | DONE |
| NBA games verified working for oracle | DONE |

## On-Chain State (Amoy)

| Entity | Count | Notes |
|--------|-------|-------|
| Contests | 3 | #1 MLB (unverified/failed), #2 MLB (unverified/failed), #3 NBA (verified) |
| Speculations | 1 | Contest 3, moneyline, line=0 |
| Positions | 2 | Maker: Upper 10 USDC risk, Taker: Lower 9.1 USDC risk |

## Time-Sensitive Tests Tracking

| Test | Contest/Leaderboard | Created At | Eligible At | Status |
|------|---------------------|------------|-------------|--------|
| A-22 (CONTEST_VOIDED) | Contest 3 | 2026-04-20 22:38 UTC | 2026-04-21 23:00 UTC (startTime + 1 day) | PENDING |
| B-01 (Post-cooldown rejection) | Contest 3 | Same | Same | PENDING |

## Session History

### Session 1 — 2026-04-20 (Plan + Setup)

**Accomplished:**
- Created comprehensive test plan
- Fixed NBA/NHL monitoring dates (PR #18 merged)
- Generated test wallets, funded, approved

### Session 2 — 2026-04-20 (Execution Start)

**Accomplished:**
- Incorporated OC review feedback (11 new test cases)
- Fixed C-08 push/leaderboard documentation error
- Executed A-01 (3 contests created)
- Executed A-02 (NBA contest verified successfully)
- Executed A-04 (match commitment — on-chain success)
- Discovered B-07 naturally (oracle failure path — no corrupt state)

**Key findings:**
- Oracle callbacks work for NBA games but FAIL for MLB (team name NaN parsing error in contestCreation.js)
- **CRITICAL: Alchemy webhook only delivering partial events from multi-event transactions**
- All on-chain operations working correctly
- Gas needs: createContestFromOracle requires ~1.2M gas, matchCommitment requires ~512K gas

**Decisions needed from Vince:**
1. Investigate the webhook delivery gap — check Alchemy webhook config / Firebase logs
2. Decide whether to fix MLB contestCreation.js team legend or continue with NBA only
