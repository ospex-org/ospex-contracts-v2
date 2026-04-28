# Amoy Stress Test Plan v4.3 — R4 testing complete

Status: **R4 TESTING COMPLETE.** Every test in the master plan has been exercised. Final test (Session 3 — A-05 + B-01 on Contest 4) executed 2026-04-27 ~12:42 PM CDT. Optional remaining items: LB 1 Apr 30+ ROI/claim as a production-realistic timeline duplicate of LB 3's compressed Session 4; B-04 (PositionAlreadyExistsForSpeculation, plan v4.2); ContestPastCooldown revert path (must be exercised between cooldown elapse and void). Indexer PRs #16-23 all merged; PR #23 verified live. New findings #14 (indexer `LEADERBOARD_PRIZE_CLAIMED` handler doesn't decrement `leaderboards.prize_pool`) and #15 (`MatchingModule__ContestAlreadyScored` is misleadingly named — fires for any terminal contest) documented.

---

## Supersedes

This plan **supersedes** v2/v2.1 and all prior Session 1 results. Supabase was wiped on 2026-04-23 after merging indexer PRs 8-15. All prior pass/fail results are stale.

### PRs merged since last test run

| PR | What it fixes | New verification |
|----|--------------|-----------------|
| #8 | league_id derived from contest_reference sport, not approvedLeagueId | Verify `contests.league_id` is "nba"/"mlb"/etc., not "unknown" |
| #9 | POSITION_TRANSFERRED sets acquired_via_secondary_market + first_fill_timestamp | Verify buyer position has `acquired_via_secondary_market=true` and `first_fill_timestamp` = sender's original fill time |
| #10 | Backfill CLI atomic with dependency closure | C-04 test can now run (after Alchemy chunking addressed) |
| #11 | COMMITMENT_MATCHED upserts commitment row | Verify `commitments` table populated after match (even without agent server) |
| #12 | COMMITMENT_CANCELLED upserts, recompute creates missing rows | Verify `commitments` row after cancel of unknown hash |
| #13 | Preservation test + canonicality docs | Agent-enriched fields preserved on indexer upsert |
| #14 | Sold listing snapshots (sold_price/risk/profit) | Verify `sold_price`, `sold_risk_amount`, `sold_profit_amount` on full sale |
| #15 | CI checks on main | Automated typecheck + test + lint |
| #16 | Finality gap instrumentation (Step 1) | Papertrail logs `finality-gap` line every ~60s with head/finalized deltas |
| #17 | **35-event recognition (was 25)** — adds 10 missing TreasuryModule/RulesModule/OracleModule event types to `events.ts`/`ingest.ts`/`registry.ts` | Verify all 35 event types appear in `chain_events` when emitted on-chain (especially `SPLIT_FEE_PROCESSED` on first-fill, `FEE_PROCESSED` on contest creation, `LEADERBOARD_ENTRY_FEE_PROCESSED` on registration, oracle/script-approval events on Chainlink callbacks) |
| #18 | Event schema enrichments (R4 contract emissions) | Decoded payload fields match enriched ABI: COMMITMENT_MATCHED has `scorer/lineTicks/commitmentRiskAmount/nonce/expiry/makerRisk/takerRisk`; COMMITMENT_CANCELLED has full commitment field set; MIN_NONCE_UPDATED has `contestId/scorer/lineTicks/speculationKey`; CONTEST_VERIFIED has `leagueId` |
| #19 | Use `finalized` block tag for safe-head (replaces `head − 128` heuristic) | Indexer cursor now ~2-4 blocks behind head (~4-8s), not ~128 blocks (~5 min) |
| #20 | `PENDING_MAX_ATTEMPTS` cap on retry worker (default 360 = ~1h at 10s tick) | C-01 retry-cap test: pending row deleted (or skipped) after MAX attempts; no log spam thereafter |
| #21 | **COMMITMENT_MATCHED/CANCELLED full R4 field coverage + `speculation_key` derivation** | After COMMITMENT_MATCHED: `commitments` row has `nonce/expiry/risk_amount/speculation_key` populated (not 0/null). After COMMITMENT_CANCELLED (cancel-only path): full R4 fields populated, not just hash/maker. After MIN_NONCE_UPDATED: indexer-created rows below floor get `nonce_invalidated=true` (works because nonce is now real, not 0). |
| #22 | **Project R4 partial events into typed tables** — FEE_PROCESSED + SPLIT_FEE_PROCESSED → `fees`; LEADERBOARD_FUNDED → `leaderboard_fundings` + atomic `prize_pool` increment; RULE_SET → `leaderboard_rules`; DEVIATION_RULE_SET → `leaderboard_deviation_rules`. Also fixes recovery.ts source_block on existing rows during recompute. | After replay/backfill of R4 history: 5 new tables populated. SCRIPT_APPROVAL_VERIFIED, ORACLE_RESPONSE, ORACLE_REQUEST_FAILED remain audit-only (chain_events row, no projection). LEADERBOARD_ENTRY_FEE_PROCESSED + PRIZE_POOL_CLAIMED also audit-only (handlers are noops; their state already covered elsewhere). |

### New verification steps (add to each relevant test)

After A-01/A-02: `contests.league_id` must be a real sport slug (e.g., "nba"), NOT "unknown".

After A-06 (first match): `commitments` table must have a row for the commitment hash with `source='indexer'`, `contest_id`, `scorer`, `odds_tick` populated.

After A-19 (POSITION_SOLD + POSITION_TRANSFERRED):
- Buyer's position: `acquired_via_secondary_market=true`
- Buyer's position: `first_fill_timestamp` = seller's original fill time (NOT the transfer block time)
- Listing: `sold_price`, `sold_risk_amount`, `sold_profit_amount` populated with pre-sale values; live columns zeroed

After A-22 (COMMITMENT_CANCELLED): `commitments` table must have a row for the cancelled hash with `status='cancelled'`, `source='indexer'`.

### Findings that still apply
- **Oracle verify script rejects non-scheduled games** — use future games (24-72h out)
- **Rundown API transient failures** — retry scoring on callback failure
- **Future contests only** constraint still stands for end-to-end scenarios

---

## Architecture Context

The indexer is a **pull-based polling worker** (ospex-indexer on Heroku) that replaces the push-based Alchemy webhook.

| Property | Value |
|----------|-------|
| Polling interval | **15000ms (`POLL_INTERVAL_MS`) — minimum.** Alchemy free-tier rate limits prevent shorter intervals; the running indexer was set to 2000ms in earlier docs but was throttling. |
| Block chunk size | 2000 blocks (`BLOCK_RANGE_CHUNK`) |
| Safe-head source | **Chain `finalized` block tag (PR #19)** — Heimdall v2 milestone finality, ~2-5s behind head. Replaces the older `head − CONFIRMATION_DEPTH` heuristic (~5 min). `CONFIRMATION_DEPTH=128` is still consumed for the reorg-detection scan window, not for safe-head. |
| Cursor table | `indexer_cursor` (PK: network) |
| Event deduplication | UNIQUE on `(network, tx_hash, log_index)` in `chain_events` |
| Dependency handling | `pending_events` table + retry worker (10s interval). Capped per `PENDING_MAX_ATTEMPTS` (default 360, ~1h) — see PR #20. |
| Reorg recovery | Automatic fork detection, state rollback, entity rebuild |
| CLIs | `yarn reconcile`, `yarn backfill` |

**Every test must validate** (standard checklist applied to all tests):
1. `chain_events` row exists with correct `event_name`, `entity_type`, `entity_id` (note: the chain_events column is `event_name`; `pending_events` has its own `event_type` column — don't confuse the two)
2. `source_block IS NOT NULL` on every **inserted** projected row (UPDATEs don't change source_block)
3. `pending_events` table has zero rows for this event after processing
4. No errors in indexer logs: `heroku logs --app ospex-indexer --num 50`

### Event Coverage — 35 CoreEventEmitted Types (Post-PR #17/#22)

Contracts emit **35 distinct CoreEventEmitted event types**. After PR #17 (recognition) and PR #22 (partials projection), every type is registered in the indexer. 30 have projection logic; 5 are recorded in `chain_events` for audit-only.

**Projecting (30):** `CONTEST_CREATED`, `CONTEST_VERIFIED`, `CONTEST_MARKETS_UPDATED`, `CONTEST_SCORES_SET`, `CONTEST_VOIDED`, `SPECULATION_CREATED`, `SPECULATION_SETTLED`, `POSITION_MATCHED_PAIR`, `POSITION_CLAIMED`, `POSITION_TRANSFERRED`, `COMMITMENT_MATCHED`, `COMMITMENT_CANCELLED`, `MIN_NONCE_UPDATED`, `LEADERBOARD_CREATED`, `LEADERBOARD_SPECULATION_ADDED`, `USER_REGISTERED`, `LEADERBOARD_ROI_SUBMITTED`, `LEADERBOARD_NEW_HIGHEST_ROI`, `LEADERBOARD_PRIZE_CLAIMED`, `LEADERBOARD_POSITION_ADDED`, `POSITION_LISTED`, `LISTING_UPDATED`, `POSITION_SOLD`, `LISTING_CANCELLED`, `SALE_PROCEEDS_CLAIMED`, `FEE_PROCESSED` (→ `fees`, single shape), `SPLIT_FEE_PROCESSED` (→ `fees`, split shape), `LEADERBOARD_FUNDED` (→ `leaderboard_fundings` + atomic `prize_pool` increment), `RULE_SET` (→ `leaderboard_rules`), `DEVIATION_RULE_SET` (→ `leaderboard_deviation_rules`).

**Audit-only — chain_events row, no projection (5):**

| Event | Emitted By | Reason |
|-------|-----------|--------|
| `LEADERBOARD_ENTRY_FEE_PROCESSED` | TreasuryModule | Fee detail. Entry fee amount already stored in `leaderboards.entry_fee` and reflected in `prize_pool` via `rpc_user_registered`. |
| `PRIZE_POOL_CLAIMED` | TreasuryModule | Tracking detail. `LEADERBOARD_PRIZE_CLAIMED` already records the claim in `leaderboard_registrations`/`leaderboard_winners`. |
| `ORACLE_RESPONSE` | OracleModule | Diagnostic — corresponding state changes are emitted as `CONTEST_VERIFIED` / `CONTEST_MARKETS_UPDATED` / `CONTEST_SCORES_SET`. |
| `ORACLE_REQUEST_FAILED` | OracleModule | Diagnostic — observed when a Chainlink callback fails (R4 finding #1). Useful for debugging; no projection state change. |
| `SCRIPT_APPROVAL_VERIFIED` | OracleModule | Diagnostic — fires alongside oracle calls to attest the script-hash signature was valid. |

The indexer's main loop inserts all CoreEventEmitted logs, so audit-only events still produce a `chain_events` row even though their handler is a no-op.

---

## Constraint: Future Contests Only

Verification scripts reject games whose `start_time` has already passed. All end-to-end scenarios must use contests scheduled 24-72 hours out. For tests that only need a contest to exist (not a full lifecycle), any open contest is fine.

**Implication:** The full lifecycle (create → verify → score → settle → claim) spans multiple days. Session boundaries are documented in the Execution Strategy section.

---

## Constraint: Multi-Sport Coverage

Every testing session must include at least one contest per available sport in `contest_reference`. Currently available sports:

| Sport ID | League | Typical Season |
|----------|--------|----------------|
| 0 | MLB | April–October |
| 1 | NBA | October–June |
| 5 | NHL | October–June |

Update this table as the monitor populates new sports.

**If any available sport lacks same-day-settleable contests** (no games scheduled within the session's lifecycle window), **halt the session with an explicit error** explaining which sport is missing and why. Do not silently substitute another sport or skip coverage.

**Rationale:** Session 1 (v3) only tested NBA + NHL (finding #9). Sport-specific differences in oracle behavior, scoring APIs, and `league_id` mapping are real failure vectors that silent substitution masks.

---

## Constraint: Game Selection Review Gate

After the T-00 canary passes and games have been identified for each track/sport, **Claude Code must pause and present the selected games for user review** before proceeding with on-chain contest creation.

The review presentation must include:
- Game matchup (away @ home, using actual team names)
- Sport / league
- **Local start time in CST/CDT** (explicitly labeled)
- **Expected end time in CST/CDT** (based on typical game duration for the sport)
- Which track/contest role (A, B, C) the game is assigned to
- JSONOdds ID

**Do not proceed with contest creation until the user explicitly approves the game selections.**

**Rationale:** We have repeatedly mis-parsed game times from search results — assuming UTC when times are local, or vice versa. A human review gate before burning testnet gas and LINK is cheap insurance.

---

## Test Tracks

The tests are split into 4 independent tracks with different timing requirements. Each track uses its own contest(s) to avoid incompatible timing assumptions.

**Track 1 — Score/Settle/Claim** (multi-day)
- Contest A: future game 24-72h out
- Day 1: Create → verify → market update → match commitments (moneyline + spread + total)
- Day 2+: Score → settle → claim
- Tests: A-01, A-02, A-03, A-04, A-06, A-07, A-08, A-09, A-24, A-25

**Track 2 — Leaderboard** (multi-day, depends on Track 1 settling)
- Uses Contest A's speculation(s) from Track 1
- Creates leaderboard with endTime AFTER game is expected to end (e.g., endTime = now + 4 days)
- startTime: near-future (e.g., now + 5 minutes) so positions can be registered on Day 1
- Day 1: Create leaderboard → add speculation → register user → (wait for startTime) → add position
- Day 2+ (after Track 1 settles): Submit ROI → claim prize
- Tests: A-11, A-12, A-13, A-14, A-15, A-16

**Track 3 — Secondary Market** (Day 1, single session)
- Contest B: separate future game (or same game, different speculation)
- Must stay unsettled throughout the secondary market tests
- Match commitments → list → update → buy → cancel → claim proceeds
- Also covers POSITION_TRANSFERRED and hardening checks (B-02, B-03)
- Tests: A-17, A-18, A-19, A-20, A-21, A-10, B-02, B-03

**Track 4 — Void/Cooldown** (multi-day)
- Contest C: game that has already started (or is about to start) — will be verified with a start_time in the near past
- Create + verify on Day 1, match a commitment so a speculation exists
- Wait 24h+ for void cooldown
- Day 2+: Settle → auto-void, then attempt post-cooldown match (B-01)
- Tests: A-05, B-01

**Independent (any time):** A-22 (COMMITMENT_CANCELLED), A-23 (MIN_NONCE_UPDATED), T-00 (canary), all Phase C and D tests

---

## Prerequisites

### Signing Keys

| Role | Address | Status |
|------|---------|--------|
| Deployer | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` | READY |
| MAKER | TBD (generate) | PENDING |
| TAKER | TBD (generate) | PENDING |

MAKER and TAKER wallets: generate via `cast wallet new`, fund with POL from deployer, mint USDC via `MockERC20.mint(address,uint256)`.

### Contract Addresses (Amoy, R4 deployed 2026-04-25, first block 37285105)

| Contract | R4 Address | Prior R3 |
|----------|------------|----------|
| OspexCore | `0xD47456F17b8f1D232799aE8670330b76A924422e` | `0x44fEDE66279D0609d43061Ac40D43704dDb392D7` |
| ContestModule | `0xB6dbd31fc14841777CF3c5e06b31685630D08b69` | `0x0b4B56fD4cb7848f804204B052A3e72d90213B52` |
| SpeculationModule | `0x8a757a818b765A8fCB483042Af2F514aeB647580` | `0x6f32665DD97482e6C89D8B9bf025d483184F5553` |
| PositionModule | `0xb7E1c99BB4490Be17c9bf4003C0ADa6b3b3C6480` | `0xf769BEC6960Ed367320549FdD5A30f7C687DB2ee` |
| MatchingModule | `0x36BC5693ee30cD65f8DCE51bd48BC03815091A26` | `0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9` |
| OracleModule | `0x0508D9147D1f4C34866550A6f5877Bb3aA57A33e` | `0x08d1F10572071271983CE800ad63663f71A71512` |
| TreasuryModule | `0x85478F81d395EaF8819119491B1257E6DbF1f662` | `0xC30C74edeEB3cbF2460D8a4a6BaddEBEe9D3ab1e` |
| LeaderboardModule | `0x274Fc351AA6960A5742bD997B75490A9aC324e23` | `0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37` |
| RulesModule | `0x2bCD9098ADd5E3AecEa27d2E4d72F9Fb18738634` | `0x657804cEcBC4c16c0eC4A8Bc384dd515EA2D462C` |
| SecondaryMarketModule | `0x988707212e45d26E8635356ec6650150Fc9466Ae` | `0x0e7b7C218db7f0e34521833e98f0Af261D204aED` |
| MoneylineScorerModule | `0x2E6Fd04Bf32E2fFd46AAd9549D86Ab619938167b` | `0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC` |
| SpreadScorerModule | `0x0dE8B42Fe14Bf008ef26A510E45f663f083eBd77` | `0x36F3f4A6757cB2E822A1AfCea0b3092fFcaE6c30` |
| TotalScorerModule | `0xAc2Ec406C3F1aDe03f5e25233B7379FAA0FAE85b` | `0xB814f3779A79c6470a904f8A12670D1B13874fDE` |
| Mock USDC | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` | (unchanged) |
| LINK Token | `0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904` | (unchanged) |
| Chainlink Functions Router | `0xC22a79eBA640940ABB6dF0f7982cc119578E11De` | (unchanged) |

**R4 deployment context:** see `deployments/amoy-R4-20260425.md`. New OracleModule registered as Chainlink consumer (sub 416, tx `0x9766afe...`, block 37285185). Old R3 consumers not pruned — left dormant.

**Pre-flight: stress-test scripts pinning R3 addresses must be updated to R4 before Phase 2 execution.** Files known to need update: `scripts/stress-test/match-commitment.js`, `scripts/stress-test/market-update.js`, `scripts/stress-test/score-contest.js`. (`create-contest.js` already R4.)

### Protocol Parameters

| Parameter | Value |
|-----------|-------|
| Void Cooldown | 86400s (1 day) |
| Contest Creation Fee | 1.00 USDC |
| Speculation Creation Fee | 0.50 USDC (0.25 maker + 0.25 taker) |
| Leaderboard Creation Fee | 0.50 USDC |
| LINK per oracle call | 0.004 LINK |
| Chainlink Subscription ID | 416 |
| DON ID | `fun-polygon-amoy-1` |
| ODDS_SCALE | 100 |
| EIP-712 Domain (MatchingModule) | name="Ospex", version="1", chainId=80002 |

### Script Approvals

The R3 script approval signatures (in git history) bind the script hash + signer; they survive contract redeploys as long as (a) the JS source is unchanged and (b) the approved signer is unchanged. Approved signer for R4 is `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` (same as R3). **Verify R3 signatures are still valid against R4 OracleModule before Phase 2 execution** — re-run `scripts/sign-script-approval.js` if the JS sources changed since R3.

R3 reference (from prior plan; expire 2026-07-19, may need re-signing):

| Purpose | Script Hash | Signature |
|---------|-------------|-----------|
| VERIFY (0) | `0x01c48e15068b68b7d5986d5013edd83a243ac31a761567e9db0e57b513c26c01` | `0x1c5c2a40b19a56ed5c7ed0b5f3cd999232018de58b657ef168db9bf4badf820f7dc21fc4feba4c08ec8a4a0f4b8ccdd4685057ca12af049cc9d48084556c846b1c` |
| MARKET_UPDATE (1) | `0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4` | `0x12f15b125eae373d76fb154ef6e42b60a8c93c4c99dc82c0c22d566b9ff7376041e3e096018ffbd3f6095d8c3cd0deab4d71b109ae29e29dceb1532371cef86d1c` |
| SCORE (2) | `0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd` | `0x860e0611a506988a66a686558f2bf3818decbfd8f22c507d122473ef9699ae175477ee99c648cdda7dff7c37b3483f606f1f0458b90436471bb314943a5e43041b` |

### Pre-Flight Checklist

- [ ] Pause Alchemy webhook (Alchemy Dashboard → Webhooks → pause insightWebhook) — prevent duplicate indexing
- [ ] Clean Supabase amoy test data (see cleanup SQL in session log)
- [ ] Restart indexer: `heroku ps:restart worker --app ospex-indexer`
- [ ] Confirm indexer caught up: `heroku logs --app ospex-indexer --tail` — look for "processed chunk" at head
- [ ] Confirm no errors/stuck pending_events in logs
- [ ] Generate MAKER + TAKER wallets, fund with POL and USDC
- [ ] Approve USDC for PositionModule + TreasuryModule (both wallets)
- [ ] Approve USDC for SecondaryMarketModule (TAKER wallet, for buying)
- [ ] Ensure `contest_reference` rows exist in Supabase for chosen game(s) — the CONTEST_CREATED handler depends on this
- [ ] Verify `contest_reference` has games for all required sports (currently 0=MLB, 1=NBA, 5=NHL) — **halt if any sport is missing**
- [ ] Confirm deployer has LINK approved for OracleModule, USDC approved for TreasuryModule

### Required Approvals (per wallet)

```bash
# MAKER approvals
cast send $USDC "approve(address,uint256)" $POSITION_MODULE $(cast max-uint) --private-key $MAKER_PK --rpc-url $AMOY_RPC
cast send $USDC "approve(address,uint256)" $TREASURY_MODULE $(cast max-uint) --private-key $MAKER_PK --rpc-url $AMOY_RPC

# TAKER approvals
cast send $USDC "approve(address,uint256)" $POSITION_MODULE $(cast max-uint) --private-key $TAKER_PK --rpc-url $AMOY_RPC
cast send $USDC "approve(address,uint256)" $TREASURY_MODULE $(cast max-uint) --private-key $TAKER_PK --rpc-url $AMOY_RPC
cast send $USDC "approve(address,uint256)" $SECONDARY_MARKET_MODULE $(cast max-uint) --private-key $TAKER_PK --rpc-url $AMOY_RPC
```

### Helper Scripts

The following scripts handle complex ABI encoding and are needed before execution. They were created during the v1 session and should be recovered from the `docs/stress-test-session-results` branch or recreated:

1. **Contest creation script** — handles `createContestFromOracle` ABI encoding with script approvals
2. **Commitment signing script** — EIP-712 OspexCommitment signer (Node.js + ethers.js)
3. **Match commitment script** — calls `matchCommitment` with signed commitment
4. **Score contest script** — handles `scoreContestFromOracle` ABI encoding

---

## T-00: INDEXER LIVENESS CANARY

**Goal:** Confirm the full indexer pipeline works before spending LINK on expensive oracle calls.

Fire one cheap event, verify it flows through the entire pipeline: on-chain tx → indexer picks up → chain_events insert → projection write → cursor advances → no stuck pending rows.

**Action:**
```bash
# MIN_NONCE_UPDATED is the cheapest event — no oracle, no LINK, no fees, no dependencies.
cast send $MATCHING_MODULE \
  "raiseMinNonce(uint256,address,int32,uint256)" \
  999 $MONEYLINE_SCORER 0 1 \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

Record the tx hash and block number.

**Checklist:**

| Check | Expected | Actual |
|-------|----------|--------|
| Tx confirmed on-chain | tx hash + block number | |
| `chain_events` row exists | event_name="MIN_NONCE_UPDATED", tx_hash matches | |
| `maker_nonce_floors` row exists | maker=MAKER, source_block = tx block | |
| `indexer_cursor.last_confirmed_block` advanced | >= tx block - 128 (confirmation depth) | |
| `pending_events` count for this event | 0 | |
| Indexer logs clean | No errors in last 50 lines | |

**Pass/Fail:**

**Evidence:**

**Notes:** If ANY check fails, stop. Diagnose the indexer before proceeding. Do not burn LINK on A-01 until the canary passes. The canary uses contestId=999 (doesn't need to exist — raiseMinNonce doesn't validate the contest).

---

## PHASE A: HANDLER COVERAGE

**Goal:** Fire each of the 35 recognized CoreEventEmitted events at least once and verify the indexer writes correct Supabase state. 30 events have projection logic; 5 are audit-only (chain_events row, no projection — see Architecture Context). Tests A-01..A-25 cover the original 25 lifecycle handlers; **tests A-26..A-31 (added in v4.1) cover the 5 partial-projections from PR #22 plus the audit-only landing check.**

### Priority 1 — Contest Lifecycle (Track 1 + Track 4)

---

#### A-01: CONTEST_CREATED

**Description:** Create a contest via `OracleModule.createContestFromOracle`. Emits CONTEST_CREATED immediately; Chainlink callback follows.

**Prerequisites:**
- Deployer has LINK approved for OracleModule, USDC approved for TreasuryModule
- Target game is 24-72h out and has `STATUS_SCHEDULED` in JSONOdds/Rundown/Sportspage APIs
- `contest_reference` row exists in Supabase for the target game's `jsonodds_id` (populated by monitor or manual insert)

**Action:**
```bash
# Use helper script — handles complex tuple encoding
node scripts/stress-test/create-contest.js \
  --rundownId "RD_GAME_ID" \
  --sportspageId "SP_GAME_ID" \
  --jsonoddsId "JO_GAME_ID"
```

Or raw cast (see v1 plan A-01 for full tuple structure).

**Expected on-chain outcome:**
- `ContestModule.s_contestIdCounter()` increments
- Contest struct stored with status=Unverified
- CoreEventEmitted with eventType=CONTEST_CREATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_name="CONTEST_CREATED", entity_type="contest"
- `contests` row: contest_id=N, contest_status="unverified", jsonodds_id matches, away_team/home_team from contest_reference, source_block set
- No pending_events rows for this event

**Pass/Fail:**

**Evidence:**

**Notes:** If `contest_reference` is missing, the event will go to `pending_events` with reason `missing_contest_reference`. This is expected and is tested explicitly in C-01. For this test, ensure the reference exists first.

---

#### A-02: CONTEST_VERIFIED

**Description:** Chainlink callback from A-01 verifies the contest (sets leagueId, startTime). Fires CONTEST_VERIFIED.

**Prerequisites:** A-01 completed. Chainlink callback arrives (~30-60s on Amoy).

**Action:** Wait for callback. Monitor via:
```bash
cast call $CONTEST_MODULE "getContest(uint256)" CONTEST_ID --rpc-url $AMOY_RPC
# Or watch indexer logs for CONTEST_VERIFIED
```

**Expected on-chain outcome:**
- Contest status = Verified, leagueId and startTime populated

**Expected Supabase outcome:**
- `chain_events` row: event_name="CONTEST_VERIFIED"
- `contests` row updated: contest_status="verified", start_time set, league_id set (check `LEAGUE_ID_MAP` for correctness), verified_at set
- source_block NOT changed (UPDATE, not INSERT)

**Pass/Fail:**

**Evidence:**

**Notes:** league_id mapped via `LEAGUE_ID_MAP` in indexer. NBA=4, MLB=3, NFL=2, etc. If the numeric value isn't in the map, it stores "unknown". v1 saw "unknown" — verify the map covers the sport being tested.

---

#### A-03: CONTEST_MARKETS_UPDATED

**Description:** Update market data (odds, lines) for the verified contest via oracle.

**Prerequisites:** A-02 completed (contest is Verified).

**Action:**
```bash
# Use helper script or raw cast
node scripts/stress-test/market-update.js --contestId CONTEST_ID
```

Wait for Chainlink callback to deliver market data.

**Expected on-chain outcome:**
- Contest market fields populated (spread_line, total_line, ML/spread/total odds)
- CoreEventEmitted with eventType=CONTEST_MARKETS_UPDATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_name="CONTEST_MARKETS_UPDATED"
- `contests` row updated: `spread_line_ticks`, `total_line_ticks`, `ml_upper_odds`, `ml_lower_odds`, `spread_upper_odds`, `spread_lower_odds`, `total_upper_odds`, `total_lower_odds`, `markets_updated_at` all populated
- Verify all 8 fields are non-null and reasonable

**Pass/Fail:**

**Evidence:**

**Notes:** Market data is packed into a uint256 by the oracle JS. Skipped in v1 session; should be tested this round.

---

#### A-04: CONTEST_SCORES_SET

**Description:** Score the contest after the game ends. Fires CONTEST_SCORES_SET.

**Prerequisites:** A-02 completed. **Game must have ended** (start_time + typical sport game duration has passed) AND the scoring API reports the game as FINAL. This test runs in a later session (Day 2+).

> ⚠️ **Settlement gate (mandatory pre-flight before A-04 / A-08 / A-09):**
>
> 1. Read the contest's on-chain `start_time` directly: `cast call $CONTEST_MODULE "getContest(uint256)" CONTEST_ID --rpc-url $AMOY_RPC` and parse `startTime`. **Do not trust earlier session log entries — those have been wrong before** (e.g., R4 Contest 5: log line says `~3 PM CDT` but on-chain `startTime` was `2026-04-26T22:00:00Z` = 5:00 PM CDT). The on-chain value is canonical.
> 2. Confirm `block.timestamp >= startTime + typical_game_duration` (NBA ≈ 2.5h, NHL ≈ 2.5h, MLB ≈ 3h).
> 3. **Confirm the game is FINAL via the scoring API** before invoking `scoreContestFromOracle`. Calling `scoreContestFromOracle` for an in-progress game burns 0.004 LINK and either returns NaN (silent failure path noted in v1) or fires `ORACLE_REQUEST_FAILED` (R4 finding #1) — there is no on-chain retry.
> 4. If the game is not yet final, **wait, do not score**. Document the wait gate in the session log; do not attempt scoring until the API confirms the result.

**Action:**
```bash
node scripts/stress-test/score-contest.js --contestId CONTEST_ID
```

Wait for Chainlink callback to deliver scores.

**Expected on-chain outcome:**
- Contest awayScore/homeScore set, status=Scored

**Expected Supabase outcome:**
- `chain_events` row: event_name="CONTEST_SCORES_SET"
- `contests` row: contest_status="scored", away_score and home_score populated, scored_at set
- `speculations` rows (if any exist for this contest): scored_at denormalized (UPDATE, not INSERT)

**Pass/Fail:**

**Evidence:**

**Notes:** Requires game to have completed. If Chainlink callback fails (transient API error), retry. v1 required 2 attempts for scoring.

---

#### A-05: CONTEST_VOIDED

**Description:** Void a contest by settling a speculation after the void cooldown (86400s) has elapsed without scores.

**Prerequisites:** A separate contest must exist in Verified state where: `block.timestamp >= startTime + 86400` AND the contest has NOT been scored. Create this contest early in testing specifically for voiding.

**Action:**
```bash
# Settle any speculation on the voided contest — triggers auto-void
cast send $SPECULATION_MODULE "settleSpeculation(uint256)" SPEC_ID \
  --private-key $DEPLOYER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Contest status = Voided
- CONTEST_VOIDED event fires (alongside SPECULATION_SETTLED with winSide=Void)

**Expected Supabase outcome:**
- `chain_events` row: event_name="CONTEST_VOIDED"
- `contests` row: contest_status="voided", voided_at set

**Pass/Fail:**

**Evidence:**

**Notes:** **Requires 24h real-time wait.** Strategy: create a contest on Day 1 for a game whose start_time is in the near past (use a just-started game). After 24+ hours, return and trigger void. Document expected void-ready time.

---

### Priority 2 — Speculation + Commitment Lifecycle (Track 1)

---

#### A-06: SPLIT_FEE_PROCESSED + SPECULATION_CREATED + POSITION_MATCHED_PAIR + COMMITMENT_MATCHED

**Description:** Match a commitment (first fill for a new contestId/scorer/lineTicks combination). Single transaction fires 4 CoreEvents — the speculation-creation fee split (`SPLIT_FEE_PROCESSED`) is emitted alongside the three lifecycle events.

**Prerequisites:**
- A-02 completed (verified contest exists)
- MAKER has USDC, approved PositionModule + TreasuryModule
- TAKER has USDC, approved PositionModule + TreasuryModule

**Action:**
1. MAKER signs EIP-712 OspexCommitment:
   ```
   maker: MAKER_ADDRESS
   contestId: CONTEST_ID
   scorer: $MONEYLINE_SCORER (R4: 0x2E6Fd04Bf32E2fFd46AAd9549D86Ab619938167b)
   lineTicks: 0 (moneyline)
   positionType: 0 (Upper = Away)
   oddsTick: 191 (1.91x)
   riskAmount: 10000000 (10 USDC)
   nonce: 1
   expiry: now + 1 hour
   ```
2. TAKER calls matchCommitment:
   ```bash
   # takerDesiredRisk = makerProfit = (10000000 * 91) / 100 = 9100000
   cast send $MATCHING_MODULE \
     "matchCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256),bytes,uint256)" \
     "(MAKER_ADDR,CONTEST_ID,$MONEYLINE_SCORER,0,0,191,10000000,1,EXPIRY)" \
     "SIG_HEX" 9100000 \
     --private-key $TAKER_PK --rpc-url $AMOY_RPC
   ```

**Expected on-chain outcome:**
- SpeculationModule counter increments (new speculationId)
- Maker USDC decreases by 10.25 USDC (10 risk + 0.25 fee)
- Taker USDC decreases by 9.35 USDC (9.1 risk + 0.25 fee)

**Expected Supabase outcome:**
- `chain_events`: **4 rows** — SPECULATION_CREATED, COMMITMENT_MATCHED, POSITION_MATCHED_PAIR, **SPLIT_FEE_PROCESSED** (the speculation-creation fee split, emitted alongside the three lifecycle events; recognized + projected to `fees` since indexer PR #17/#22)
- `speculations` row: speculation_id=N, contest_id, market_type="moneyline", speculation_status="open", line_ticks=0, win_side="tbd", source_block set
- `positions` row (maker): user_address=MAKER, position_type="upper", risk_amount="10000000", profit_amount="9100000", source_block set
- `positions` row (taker): user_address=TAKER, position_type="lower", risk_amount="9100000", profit_amount="10000000", source_block set
- `position_fills` row: commitment_hash, maker, taker, odds_tick=191
- `commitments` row (PR #21): `nonce=1`, `expiry`, `risk_amount=10000000`, `speculation_key` populated (NOT 0/null), source_block set
- `fees` row (PR #22, split shape; schema per migration `032_partials_projection.sql:41-61`): `fee_event_type='split'`, `fee_type='speculation_creation'`, `payer1=MAKER`, `payer2=TAKER`, `amount=250000` + `second_amount=250000` (0.25 USDC maker share + 0.25 USDC taker share), `total_amount=500000` (generated)

**Pass/Fail:**

**Evidence:**

**Notes:** This is the most complex single-transaction test — 4 events (including `SPLIT_FEE_PROCESSED` from the speculation-creation fee split), 5+ table writes. Verify all four chain_events rows have correct log_index ordering.

---

#### A-07: COMMITMENT_MATCHED + POSITION_MATCHED_PAIR (Accumulation)

**Description:** Match a second fill on the SAME speculation (same contestId/scorer/lineTicks). Only 2 events fire (no new SPECULATION_CREATED). Verifies position accumulation logic.

**Prerequisites:** A-06 completed (speculation exists with first fill).

**Action:** MAKER signs new commitment (nonce=2, same scorer/lineTicks). TAKER matches.

**Expected Supabase outcome:**
- `chain_events`: 2 new rows — COMMITMENT_MATCHED, POSITION_MATCHED_PAIR
- `positions`: existing MAKER and TAKER rows have risk_amount/profit_amount **incremented** (BigInt addition, not replaced)
- `position_fills`: new fill row linked to same speculation_id
- No new `speculations` row (reuses existing)

**Pass/Fail:**

**Evidence:**

**Notes:** Critical accumulation test. Verify positions show cumulative totals, not just the latest fill.

---

#### A-08: SPECULATION_SETTLED

**Description:** Settle the speculation after the contest is scored.

**Prerequisites:** A-04 completed (contest scored). Speculation from A-06 exists and is Open.

**Action:**
```bash
cast send $SPECULATION_MODULE "settleSpeculation(uint256)" SPEC_ID \
  --private-key $DEPLOYER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Speculation status = Closed, winSide determined by scores + scorer logic

**Expected Supabase outcome:**
- `chain_events` row: event_name="SPECULATION_SETTLED"
- `speculations` row: speculation_status="closed", win_side populated (e.g., "away"/"home"), settled_at set, voided=false

**Pass/Fail:**

**Evidence:**

**Notes:** win_side mapped via `WIN_SIDE_MAP`: 0=tbd, 1=away, 2=home, 3=over, 4=under, 5=push, 6=void.

---

### Priority 3 — Position Lifecycle (Track 1 + Track 3)

---

#### A-09: POSITION_CLAIMED

**Description:** Winner claims their position payout.

**Prerequisites:** A-08 completed (speculation settled with a winner).

**Action:**
```bash
# Claim for the winning side. If home won, taker (lower) claims.
cast send $POSITION_MODULE "claimPosition(uint256,uint8)" SPEC_ID POSITION_TYPE \
  --private-key $WINNER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Winner receives risk + profit USDC
- Position marked claimed

**Expected Supabase outcome:**
- `chain_events` row: event_name="POSITION_CLAIMED"
- `positions` row: claimed=true, claimed_amount populated (risk + profit in winner's favor), claimed_at set
- source_block NOT changed (UPDATE, not INSERT)

**Pass/Fail:**

**Evidence:**

**Notes:** claimed_amount should equal risk_amount + profit_amount for the winning side.

---

#### A-10: POSITION_TRANSFERRED

**Description:** Transfer a position via secondary market purchase. Fires from `buyPosition()`.

**Prerequisites:** A-18 completed (listing exists) or tested as part of A-18.

**Action:** Tested as part of A-18 (POSITION_SOLD + POSITION_TRANSFERRED fire together). Documented separately here for handler coverage tracking.

**Expected Supabase outcome:**
- `positions`: seller's position reduced by transferred amount, buyer's position created/increased
- Buyer's position has `acquired_via_secondary_market` flag set (via `rpc_position_transferred`)
- source_block set on buyer's new position row

**Pass/Fail:**

**Evidence:**

**Notes:** POSITION_TRANSFERRED handler calls `rpc_position_transferred` RPC which handles the position split. Verify both seller decrement and buyer creation.

---

### Priority 4 — Leaderboard Lifecycle (Track 2)

---

#### A-11: LEADERBOARD_CREATED

**Description:** Create a new leaderboard.

**Prerequisites:** Any wallet with USDC approved for TreasuryModule. Contest A (Track 1) must already exist with at least one speculation.

**Action:**
```bash
# Track 2 timing: startTime soon (so we can register positions on Day 1),
# endTime far enough out to cover the game ending + scoring + settling.
# Game is 24-72h out, so endTime should be ~4 days from now.
# Safety + ROI windows: minimum 24 hours each (see policy note in A-11 Notes).
START=$(( $(date +%s) + 300 ))       # 5 minutes from now
END=$(( $(date +%s) + 345600 ))      # 4 days from now
SAFETY=86400                          # 24 hours (minimum)
ROI_WINDOW=86400                      # 24 hours (minimum)

cast send $LEADERBOARD_MODULE \
  "createLeaderboard(uint256,uint32,uint32,uint32,uint32)" \
  5000000 $START $END $SAFETY $ROI_WINDOW \
  --private-key $DEPLOYER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Leaderboard ID increments, 0.50 USDC creation fee charged

**Expected Supabase outcome:**
- `chain_events` row: event_name="LEADERBOARD_CREATED"
- `leaderboards` row: leaderboard_id=N, entry_fee="5000000", start_time, end_time, safety_period_duration=86400, roi_submission_window=86400, prize_pool=0, current_participants=0, total_positions=0, source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** endTime is set 4 days out so the leaderboard stays open through the game ending (Track 1). startTime is 5 minutes from creation so we can register positions on Day 1. Safety period and ROI submission window are each 24 hours (the production-realistic minimum). A-15 (ROI) executes on Day 5+ after endTime + 24h safety elapses. A-16 (prize claim) executes on Day 6+ after endTime + 24h safety + 24h ROI window elapses.

**Minimum window policy:** Safety period and ROI submission window must each be at minimum 24 hours (86400 seconds). Shorter windows are unusable in production — real users and agents cannot reliably hit a 60-second window. If a testing session requires shorter windows to fit a time budget, flag this as an issue rather than silently shortening.

---

#### A-12: LEADERBOARD_SPECULATION_ADDED

**Description:** Add a speculation to the leaderboard's eligible list.

**Prerequisites:** A-11 (leaderboard exists), A-06 (speculation exists).

**Action:**
```bash
cast send $LEADERBOARD_MODULE "addLeaderboardSpeculation(uint256,uint256)" \
  LEADERBOARD_ID SPEC_ID \
  --private-key $DEPLOYER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="LEADERBOARD_SPECULATION_ADDED"
- `leaderboard_speculations` row: leaderboard_id, speculation_id, added_at, source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** Only the leaderboard creator can call this.

---

#### A-13: USER_REGISTERED

**Description:** Register a user for the leaderboard with a declared bankroll.

**Prerequisites:** A-11 (leaderboard exists). User has USDC for entry fee.

**Action:**
```bash
cast send $LEADERBOARD_MODULE "registerUser(uint256,uint256)" \
  LEADERBOARD_ID 100000000 \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="USER_REGISTERED"
- `leaderboard_registrations` row: leaderboard_id, user_address=MAKER, declared_bankroll="100000000", source_block set
- `leaderboards` row: current_participants incremented, prize_pool updated (via `rpc_user_registered`)

**Pass/Fail:**

**Evidence:**

**Notes:** Entry fee (5 USDC) charged and added to prize pool.

---

#### A-14: LEADERBOARD_POSITION_ADDED

**Description:** Register a position for the leaderboard.

**Prerequisites:** A-12 (speculation added), A-13 (user registered), A-06 (user has position). **Leaderboard must be active** (after startTime).

**Action:**
```bash
# Wait for startTime to pass, then register position
cast send $LEADERBOARD_MODULE \
  "registerPositionForLeaderboard(uint256,uint8,uint256)" \
  SPEC_ID 0 LEADERBOARD_ID \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="LEADERBOARD_POSITION_ADDED"
- `leaderboard_positions` row: leaderboard_id, speculation_id, user_address=MAKER, position_type="upper", risk_amount, profit_amount, source_block set
- `leaderboards` row: total_positions incremented (via `rpc_leaderboard_position_added`)

**Pass/Fail:**

**Evidence:**

**Notes:** Must be called after leaderboard startTime. Risk/profit may be capped by maxBetPercentage.

---

#### A-15: LEADERBOARD_ROI_SUBMITTED + LEADERBOARD_NEW_HIGHEST_ROI

**Description:** Submit ROI after submission window opens. If this is the first/highest ROI, LEADERBOARD_NEW_HIGHEST_ROI fires in the same transaction.

**Prerequisites:** A-14 completed. All speculations the user has positions on must be settled. Wait for: endTime + safetyPeriod (endTime + 24 hours).

**Action:**
```bash
cast send $LEADERBOARD_MODULE "submitLeaderboardROI(uint256)" LEADERBOARD_ID \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events`: 2 rows — LEADERBOARD_ROI_SUBMITTED, LEADERBOARD_NEW_HIGHEST_ROI
- `leaderboard_registrations` row: submitted_roi set, roi_submitted_at set
- `leaderboard_winners` row: leaderboard_id, winner=MAKER, roi (via `rpc_leaderboard_new_highest_roi`), source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** Requires BOTH: (a) the speculation to be settled (Track 1 must have scored + settled), and (b) endTime + safetyPeriodDuration to have elapsed. With 4-day endTime + 24h safety, this runs on Day 5+. The speculation settlement is the real gate — the leaderboard timing is configurable but must respect the 24-hour minimum window policy (see A-11 notes).

---

#### A-16: LEADERBOARD_PRIZE_CLAIMED

**Description:** Winner claims their prize share.

**Prerequisites:** A-15 completed. ROI window must have closed (endTime + safetyPeriod + roiWindow).

**Action:**
```bash
cast send $LEADERBOARD_MODULE "claimLeaderboardPrize(uint256)" LEADERBOARD_ID \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="LEADERBOARD_PRIZE_CLAIMED"
- `leaderboard_registrations`: claimed flag set (via `rpc_leaderboard_prize_claimed`)
- `leaderboard_winners`: claimed flag set

**Pass/Fail:**

**Evidence:**

**Notes:** Requires endTime + safetyPeriod + roiWindow to have elapsed. With 4-day endTime + 24h safety + 24h ROI, this is Day 6+. Runs after A-15 (ROI must be submitted during the 24h ROI window before prize claim is possible).

---

### Priority 5 — Secondary Market (Track 3)

All secondary market tests use **Contest B** — a separate unsettled speculation that stays open throughout Day 1. Contest B can be the same game as Contest A or a different one; the key is that its speculation must NOT be settled during secondary market testing.

---

#### A-17: POSITION_LISTED

**Description:** List a position for sale on the secondary market.

**Prerequisites:** MAKER has a position on an unsettled speculation. MAKER hasn't already listed this position.

**Action:**
```bash
cast send $SECONDARY_MARKET_MODULE \
  "listPositionForSale(uint256,uint8,uint256,uint256,uint256)" \
  SPEC_ID 0 12000000 10000000 9100000 \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="POSITION_LISTED"
- `secondary_market_listings` row: speculation_id, seller=MAKER, position_type="upper", price="12000000", risk_amount="10000000", profit_amount="9100000", listing_hash set, status="active", source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** Listing uses upsert on `(network, speculation_id, seller, position_type)` — re-listing after cancellation is safe.

---

#### A-18: LISTING_UPDATED

**Description:** Update the price on an active listing.

**Prerequisites:** A-17 completed (active listing exists).

**Action:**
```bash
cast send $SECONDARY_MARKET_MODULE \
  "updateListing(uint256,uint8,uint256,uint256,uint256)" \
  SPEC_ID 0 11000000 0 0 \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="LISTING_UPDATED"
- `secondary_market_listings` row: price updated to "11000000", listing_hash updated, updated_at_chain set

**Pass/Fail:**

**Evidence:**

**Notes:** Passing 0 for risk/profit amounts keeps them unchanged on-chain.

---

#### A-19: POSITION_SOLD + POSITION_TRANSFERRED

**Description:** Buyer purchases the listed position. Two events fire: POSITION_SOLD and POSITION_TRANSFERRED.

**Prerequisites:** A-17 (listing active). TAKER has USDC approved for SecondaryMarketModule.

**Action:**
```bash
LISTING_HASH=$(cast call $SECONDARY_MARKET_MODULE \
  "getListingHash(uint256,address,uint8)(bytes32)" \
  SPEC_ID MAKER_ADDR 0 --rpc-url $AMOY_RPC)

# CAVEAT: the 4th arg is `riskAmount` (how much position-risk to buy — allows
# partial purchases up to listing.riskAmount), NOT `maxPriceToPay`. The price
# is set by the listing itself (listing.price) and pulled from buyer's USDC
# allowance. Passing a value > listing.riskAmount reverts with
# `SecondaryMarketModule__AmountAboveMaximum(uint256)`. To buy the FULL
# position, pass the seller's full risk (e.g., 10_000_000 = 10 USDC risk for
# a typical first-fill at 1.91x odds, which is what the example below shows).
cast send $SECONDARY_MARKET_MODULE \
  "buyPosition(uint256,address,uint8,uint256,bytes32)" \
  SPEC_ID MAKER_ADDR 0 10000000 $LISTING_HASH \
  --private-key $TAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events`: 2 rows — POSITION_SOLD, POSITION_TRANSFERRED
- `secondary_market_listings`: status updated (via `rpc_position_sold`)
- `positions`: MAKER's position reduced, TAKER's position created with `acquired_via_secondary_market` flag
- `positions` (buyer): source_block set on new row

**Pass/Fail:**

**Evidence:**

**Notes:** This covers both A-10 (POSITION_TRANSFERRED) and the secondary market sale path. Verify the `acquired_via_secondary_market` flag — critical for B-02/B-03.

---

#### A-20: LISTING_CANCELLED

**Description:** Cancel an active listing.

**Prerequisites:** An active listing exists. Create a new listing if needed (list TAKER's newly acquired position, or re-list from MAKER if they have remaining position).

**Action:**
```bash
cast send $SECONDARY_MARKET_MODULE "cancelListing(uint256,uint8)" SPEC_ID POSITION_TYPE \
  --private-key $SELLER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="LISTING_CANCELLED"
- `secondary_market_listings` row: status="cancelled", cancelled_at set

**Pass/Fail:**

**Evidence:**

**Notes:**

---

#### A-20b: RELIST AFTER SALE — sold_* cleared (PR #14 relist fix)

**Description:** After A-19 (full sale) and A-20 (cancel), relist on the same (network, speculation_id, seller, position_type) key. Verify that stale sold_* columns from the prior sale are cleared.

**Prerequisites:** A-19 completed (listing sold with sold_price/risk/profit populated). Seller has remaining position to relist.

**Action:** List the same position key again (POSITION_LISTED fires, upsert on conflict).

**Expected Supabase outcome:**
- `secondary_market_listings` row: status="active", price/risk/profit set to new values
- `sold_price` = null, `sold_risk_amount` = null, `sold_profit_amount` = null, `sold_at` = null

**Pass/Fail:**

**Evidence:**

**Notes:** This is the relist fix from PR #14 review. The POSITION_LISTED upsert explicitly nulls sold_* columns on conflict.

---

#### A-21: SALE_PROCEEDS_CLAIMED

**Description:** Seller claims accumulated proceeds from sales.

**Prerequisites:** A-19 completed (MAKER has pending proceeds from the sale).

**Action:**
```bash
cast send $SECONDARY_MARKET_MODULE "claimSaleProceeds()" \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="SALE_PROCEEDS_CLAIMED"
- No additional table writes (handler is no-op beyond chain_events)

**Pass/Fail:**

**Evidence:**

**Notes:** Handler at `secondary-market.ts:106` is explicitly a no-op. Verify chain_events row exists but no other table changes.

---

### Priority 6 — Commitment Edge Cases (Independent)

---

#### A-22: COMMITMENT_CANCELLED

**Description:** Cancel a specific commitment by hash.

**Prerequisites:** MAKER has signed a commitment (doesn't need to have been matched).

**Action:**
```bash
cast send $MATCHING_MODULE \
  "cancelCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256))" \
  "(MAKER_ADDR,CONTEST_ID,$MONEYLINE_SCORER,0,0,191,10000000,NONCE,EXPIRY)" \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome (post-indexer-PR #21):**
- `chain_events` row: event_name="COMMITMENT_CANCELLED"
- `commitments` row exists (UPSERT — created if missing, updated if present) with **all R4 fields populated from the event payload**:
  - `commitment_hash`, `maker`
  - `contest_id`, `scorer`, `line_ticks`, `position_type`, `odds_tick`, `risk_amount`, `nonce`, `expiry`
  - `speculation_key` derived as `keccak256(abi.encode(uint256, address, int32))` — same scheme as `MatchingModule.raiseMinNonce` and `_validateCommitment`
  - `market_type` derived from scorer→type mapping (works for cancel-only — no speculation lookup)
  - `status='cancelled'`, `source='indexer'`, `source_block` set

**R4.1 retest verification (post-PR #21 deploy):**
- Replay/recovery path: rerun the COMMITMENT_CANCELLED row from R4 Session 1 A-22 (block 37305539, hash `0x5790469bd7...`) through `recovery.ts` and confirm the previously null fields (`contest_id`, `scorer`, `line_ticks`, `position_type`, `odds_tick`, `risk_amount`, `nonce`, `expiry`, `speculation_key`) are now populated. PR #21 made backfill produce the same shape as live indexing.
- Live path (if testing fresh): cancel a new commitment after PR #21 is deployed; confirm row populated on first insert.

**Pass/Fail:**

**Evidence:**

**Notes:** Indexer PR #21 closed the R4 Session 1 finding #6 gap (cancel-only rows had nulls). The handler is now full-fidelity, no longer "best-effort" — every cancel produces a fully-populated row.

---

#### A-23: MIN_NONCE_UPDATED

**Description:** Raise min nonce for a speculation key to invalidate outstanding commitments.

**Prerequisites:** Any funded wallet.

**Action:**
```bash
cast send $MATCHING_MODULE \
  "raiseMinNonce(uint256,address,int32,uint256)" \
  CONTEST_ID $MONEYLINE_SCORER 0 5 \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="MIN_NONCE_UPDATED"
- `maker_nonce_floors` row: maker=MAKER, speculation_key=hash, min_nonce=5, source_block set
- `commitments`: any rows with `nonce < 5` for this `(maker, speculation_key)` have `nonce_invalidated=true`

**PR #21 invalidation check (was R4 Session 1 finding #7):** Indexer PR #11-#13 wrote indexer-created commitment rows with `nonce=0` because the contract event didn't include nonce — so `MIN_NONCE_UPDATED` had nothing to compare against and the invalidation was a no-op for indexer-created rows. **PR #21 fixed this** by extracting `nonce`, `expiry`, `risk_amount`, and deriving `speculation_key` on COMMITMENT_MATCHED. After replay/redeploy, indexer-created rows have real nonces and `nonce_invalidated=true` lands correctly when their nonce is below the new floor.

**R4.1 retest verification (post-PR #21):** Identify indexer-created commitments from R4 Session 1 (A-06/A-07/D-01 matches) and confirm `nonce` matches the on-chain commitment payload (not 0) and `speculation_key` is populated. Then either replay A-23's MIN_NONCE_UPDATED at block 37305554 or trigger a fresh raiseMinNonce above the matched nonce; assert `nonce_invalidated=true` on the affected rows.

**Pass/Fail:**

**Evidence:**

**Notes:** Uses upsert on `(network, maker, speculation_key)`. Also performs best-effort invalidation of affected commitments.

---

### Supplementary — Scorer Variants

These verify that different scorer modules produce correct `market_type` values. Can share contests from A-01/A-02.

---

#### A-24: SPREAD LIFECYCLE

**Description:** Match a commitment using SpreadScorerModule. Verify `market_type="spread"` and `line_ticks` indexed correctly.

**Prerequisites:** Verified contest, MAKER/TAKER funded.

**Action:** Sign commitment with:
- scorer: `$SPREAD_SCORER` (R4: `0x0dE8B42Fe14Bf008ef26A510E45f663f083eBd77`)
- lineTicks: -30 (spread of -3.0)
- positionType: 0 (Upper = Away covers)

**Expected Supabase outcome:**
- `speculations` row: market_type="spread", line_ticks=-30
- `positions` rows for both sides

**Pass/Fail:**

**Evidence:**

**Notes:** Scorer address mapped in `speculations.ts:9-14`. After game ends and scoring: settle and verify win_side reflects spread outcome (away - home vs line).

---

#### A-25: TOTAL LIFECYCLE

**Description:** Match a commitment using TotalScorerModule. Verify `market_type="total"` and `line_ticks` indexed correctly.

**Prerequisites:** Verified contest, MAKER/TAKER funded.

**Action:** Sign commitment with:
- scorer: `$TOTAL_SCORER` (R4: `0xAc2Ec406C3F1aDe03f5e25233B7379FAA0FAE85b`)
- lineTicks: 2150 (total of 215.0)
- positionType: 0 (Upper = Over)

**Expected Supabase outcome:**
- `speculations` row: market_type="total", line_ticks=2150
- `positions` rows for both sides

**Pass/Fail:**

**Evidence:**

**Notes:** After game ends: settle and verify win_side reflects total outcome (away + home vs line).

---

### Priority 7 — Treasury / Rules / Leaderboard Funding (added in v4.1 — indexer PR #22 projections)

These tests target the 5 partials that PR #22 introduced typed-table projections for. Most of the underlying events already fire as side-effects of A-01/A-06/A-13 (i.e., the chain_events rows already exist for R4 history); these tests assert the **typed-table projection** lands correctly. The replay/backfill path of R4.1 should reproduce all of these from existing R4 chain_events without any new on-chain action.

---

#### A-26: FEE_PROCESSED projection → `fees` table

**Description:** Verify single-shape fee events project to the `fees` table. `TreasuryModule.processFee()` emits `FEE_PROCESSED` (single shape, payer1 only) for two distinct fee types in R4 Session 1: **contest creation** (1.00 USDC, fired on every `A-01` / `OracleModule.createContestFromOracle`) AND **leaderboard creation** (0.50 USDC, fired on every `A-11` / `LeaderboardModule.createLeaderboard`). The `speculation_creation` fee always fires as `SPLIT_FEE_PROCESSED` instead (see A-27).

**Prerequisites:** R4 Session 1 already produced FEE_PROCESSED for: Contests 2/3/4/5 (4× contest_creation) and LB 1 (1× leaderboard_creation).

**Action:** No new on-chain action required for replay validation. For a fresh trigger, run any A-01 (1 USDC + 0.004 LINK) or A-11 (0.50 USDC).

**Expected Supabase outcome:**
- `chain_events` rows: `event_name="FEE_PROCESSED"` — one per fee call (Contests 2/3/4/5 → 4 rows; LB 1 → 1 row).
- `fees` rows (single shape — per migration `032_partials_projection.sql:41-61`):
  - `fee_event_type='single'`, `payer1=<contest creator or LB creator>`, `payer2=NULL`, `amount=<fee amount>`, `second_amount=NULL`, `total_amount=<amount>` (generated column).
  - `fee_type='contest_creation'` (`amount=1000000` for 1.00 USDC) for the 4 contest creations.
  - `fee_type='leaderboard_creation'` (`amount=500000` for 0.50 USDC) for LB 1's creation.
  - `tx_hash`, `log_index`, `block_number`, `block_time`, `source_block` populated.
- The CHECK `chk_fees_split_shape` enforces that `single` rows have `payer2 IS NULL` AND `second_amount IS NULL`.

**Pass/Fail:**

**Evidence:**

**Notes:** Indexer PR #22 introduced the `fee_type` Postgres enum with three values (`'contest_creation' | 'speculation_creation' | 'leaderboard_creation'`) — these match the `FeeType` enum in `TreasuryModule.sol`. The `fee_event_type` column is a separate `text` discriminator with values `'single'` or `'split'`. `total_amount` is a STORED generated column = `amount + COALESCE(second_amount, 0)`. Idempotent re-insert via PK `(network, tx_hash, log_index)` (Postgres 23505) is silently ignored — replay-safe.

---

#### A-27: SPLIT_FEE_PROCESSED projection → `fees` table

**Description:** Verify split-shape fee events project to the same `fees` table. The speculation-creation fee (0.50 USDC) is processed via `TreasuryModule.processSplitFee(payer1, payer2, FeeType.SpeculationCreation)` which transfers 0.25 USDC from each of MAKER and TAKER → 1 row in `fees` with both halves.

**Prerequisites:** A-06 already executed (R4 Session 1 produced 7 first-fill txs — see session log; 7 SPLIT_FEE_PROCESSED rows expected).

**Action:** No new on-chain action required for replay validation.

**Expected Supabase outcome:**
- `chain_events` row: `event_name="SPLIT_FEE_PROCESSED"` — one per first-fill (7 in R4 Session 1).
- `fees` rows (split shape — per migration `032_partials_projection.sql:41-61`):
  - `fee_event_type='split'`, `fee_type='speculation_creation'`, `payer1=<MAKER>`, `payer2=<TAKER>`, `amount=250000`, `second_amount=250000`, `total_amount=500000` (generated).
  - Asymmetric halves (if any production case ever splits non-50/50 — current contract always halves evenly via `totalAmount/2` + remainder) are preserved as-is — the row stores `amount` and `second_amount` independently.
- The CHECK `chk_fees_split_shape` enforces that `split` rows have `payer2 IS NOT NULL` AND `second_amount IS NOT NULL`.

**Pass/Fail:**

**Evidence:**

**Notes:** Pre-PR #17, this event was silently dropped (`decodeLog()` returned null for unknown topic[1]). All 7 R4 Session 1 first-fills initially recorded 3 `chain_events` rows; after PR #17 deploy + replay/backfill, all 7 should show 4. Verify via the per-tx event count check (D-02).

---

#### A-28: LEADERBOARD_FUNDED → `leaderboard_fundings` + atomic prize_pool increment

**Description:** External sponsor funds an existing leaderboard via `TreasuryModule.fundLeaderboard()`. PR #22 atomically (a) appends a row to `leaderboard_fundings` with the funder/amount/tx/block, AND (b) increments `leaderboards.prize_pool` — same idempotency pattern as `rpc_user_registered` (only increments on genuine new rows).

**Prerequisites:** Existing leaderboard (R4 Session 1 created LB 1; LB 1 is fine for A-28 because `fundLeaderboard()` is permissionless and has no pre-start gate). Funder wallet has USDC approved for TreasuryModule.

**Action:** R4 Session 1 did NOT include a `fundLeaderboard()` call, so this event has not yet fired on R4. To trigger:
```bash
cast send $TREASURY_MODULE "fundLeaderboard(uint256,uint256)" \
  1 5000000 \
  --private-key $DEPLOYER_PK --rpc-url $AMOY_RPC
```
(LB id=1, funding 5 USDC.)

**Expected Supabase outcome:**
- `chain_events` row: event_name="LEADERBOARD_FUNDED"
- `leaderboard_fundings` row: `leaderboard_id=1`, `funder=$DEPLOYER`, `amount=5000000`, `tx_hash`, `block_number`, `source_block` set
- `leaderboards.prize_pool` incremented by 5000000 (atomic with the insert — verify via `rpc_leaderboard_funded`)

**On-chain effect (per `TreasuryModule.fundLeaderboard()`):** USDC is transferred from the funder to the TreasuryModule and credited to `s_leaderboardPrizePools[leaderboardId]`. **The funder does NOT directly recover this USDC** — it becomes part of the prize pool distributed to leaderboard winners on prize claim. The funder only "recovers" the funding if they themselves win and claim. Plan accordingly when picking the funder wallet (the test deployer is fine; the funding remains on-chain in the LB pool until the prize is claimed by the highest-ROI submitter).

**Pass/Fail:**

**Evidence:**

**Notes:** Indexer PR #22 explicitly says: "if the dispatch produces no new row (idempotent re-insert), prize_pool is NOT double-incremented." Verify by running the same handler twice and asserting prize_pool only increases once. Replay/backfill is also idempotent.

---

#### A-29: RULE_SET → `leaderboard_rules` table

**Description:** Set a rule on a leaderboard via `RulesModule`. PR #22 upserts into `leaderboard_rules` keyed on `(network, leaderboard_id, rule_type)`.

**Prerequisites:**
- A leaderboard whose `startTime` has **NOT** elapsed — `RulesModule` setters use the `onlyCreatorBeforeStart` modifier (`block.timestamp >= lb.startTime → revert RulesModule__LeaderboardStarted`).
- Caller must be the leaderboard creator (`msg.sender != lb.creator → revert RulesModule__NotCreator`).
- **R4 Session 1 LB 1 startTime has already elapsed → CANNOT be used for A-29.** A-29/A-30 require a fresh leaderboard with a future startTime (e.g., create a new test LB with `startTime = now + 30 minutes`, then run rule setters before that elapses).

**Action:** R4 Session 1 did NOT include any `RULE_SET` event. The contract has no generic `setRule(uint256,string,uint256)` function; rules are set via per-rule functions that all emit `RuleSet(leaderboardId, ruleType, value)`. Signatures verified against `src/modules/RulesModule.sol:164-334`:
- `setMinBankroll(uint256 leaderboardId, uint256 value)` → emits `RuleSet(_, "minBankroll", value)`
- `setMaxBankroll(uint256 leaderboardId, uint256 value)` → emits `RuleSet(_, "maxBankroll", value)`
- `setMinBetPercentage(uint256 leaderboardId, uint16 value)` (bps; ≤10000 via `valueNotExceedingMaxBps`) → `"minBetPercentage"`
- `setMaxBetPercentage(uint256 leaderboardId, uint16 value)` (bps; ≤10000) → `"maxBetPercentage"`
- `setMinBets(uint256 leaderboardId, uint16 value)` (value > 0) → `"minBets"`
- `setOddsEnforcementBps(uint256 leaderboardId, uint16 value)` (bps; ≤10000) → `"oddsEnforcementBps"`
- `setAllowLiveBetting(uint256 leaderboardId, bool value)` → `"allowLiveBetting"` (1 or 0)
- `setAllowMoneylineSpreadPairing(uint256 leaderboardId, bool value)` → `"allowMoneylineSpreadPairing"` (1 or 0)

Note: the `value` arg is `uint16` (not `uint256`) on the four percentage/bps/min-bets setters — a `cast send` call with `uint256` will revert at the ABI decode. Use the literal Solidity types when crafting the `cast` call.

Example (after creating new pre-start LB N from the LB creator wallet):
```bash
# Set minBankroll = 50 USDC on new LB N
cast send $RULES_MODULE "setMinBankroll(uint256,uint256)" \
  N 50000000 \
  --private-key $LB_CREATOR_PK --rpc-url $AMOY_RPC
```

**Expected Supabase outcome:**
- `chain_events` row: event_name="RULE_SET"
- `leaderboard_rules` row: `leaderboard_id=N`, `rule_type='minBankroll'` (verbatim from contract — string), `value=50000000`, source_block set

**Re-fire same key:** Second `RULE_SET` event with the same `(leaderboard_id, rule_type)` UPSERTs — does NOT duplicate. Verify via tests/partials.test.ts coverage.

**Pass/Fail:**

**Evidence:**

**Notes:** PR #22 stores `rule_type` verbatim as `text` (not an enum) so future contract additions don't need a coordinated DB migration. The contract emits string literals (`"minBankroll"`, `"maxBankroll"`, etc.) directly — listing of literals above is exhaustive as of R4 contracts.

**ML+Spread pairing default (added v4.2 — finding #12 from R4.1 evening):** `setAllowMoneylineSpreadPairing(lb, value)` defaults to **false**. While the LB is open for registration, a user with an existing LB position on a Moneyline spec for some contest CANNOT register an additional position on a Spread spec for the same contest (and vice versa) unless the LB creator has explicitly enabled cross-pairing via this setter — and the setter (like all RulesModule setters) is gated by `onlyCreatorBeforeStart`. **If you intend to test multi-market-type aggregation per user (e.g., MAKER takes ML + Spread on the same contest, both registered for one LB), call `setAllowMoneylineSpreadPairing(lb, true)` BEFORE the LB's startTime elapses.** Once the LB has started, the default is locked in and aggregation across market types is impossible for that LB. Same-market-type aggregation (e.g., 2 ML positions on the same contest) is also impossible — see B-04 / finding #13 for the per-scorer uniqueness defense.

---

#### A-30: DEVIATION_RULE_SET → `leaderboard_deviation_rules` table

**Description:** Set a deviation rule (max odds deviation by league/scorer/position type) on a leaderboard. PR #22 upserts into `leaderboard_deviation_rules` keyed on `(network, leaderboard_id, league_id, scorer, position_type)`.

**Prerequisites:** Same as A-29 — pre-start leaderboard, called from the creator wallet, before `lb.startTime`. **R4 Session 1 LB 1 cannot be used; reuse the new LB N created for A-29.**

**Action:** R4 Session 1 did NOT include any `DEVIATION_RULE_SET` event. Contract signature (`src/modules/RulesModule.sol:291`):
```solidity
function setDeviationRule(
    uint256 leaderboardId,
    LeagueId leagueId,        // enum (uint8 ABI)
    address scorer,
    PositionType positionType, // enum (uint8 ABI: 0=Upper, 1=Lower)
    int32 maxDeviation         // bps; reverts if < 0
) external onlyCreatorBeforeStart(leaderboardId);
```

```bash
# Example: max deviation 200bps for NBA moneyline upper on new LB N
cast send $RULES_MODULE \
  "setDeviationRule(uint256,uint8,address,uint8,int32)" \
  N 4 $MONEYLINE_SCORER 0 200 \
  --private-key $LB_CREATOR_PK --rpc-url $AMOY_RPC
```
(LB N, leagueId=4=NBA per LeagueId enum, scorer=Moneyline, positionType=0=Upper, maxDeviation=200bps.)

**Expected Supabase outcome:**
- `chain_events` row: event_name="DEVIATION_RULE_SET"
- `leaderboard_deviation_rules` row: `leaderboard_id=N`, `league_id='nba'` (slug), `scorer`, `position_type='upper'` (slug), `max_deviation=200`, source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** `max_deviation` is `int32` in the event but the contract reverts on negative values, so DB stores as `integer NOT NULL CHECK (max_deviation >= 0)`. `leagueId` and `positionType` are slug-mapped (unknown leagueId → `'unknown'`).

---

#### A-31: Audit-only events land in `chain_events`

**Description:** Verify that the 5 audit-only event types still produce `chain_events` rows even though their handlers are noops. These were silently dropped pre-PR #17.

**Prerequisites:** R4 history contains examples of each (R4 Session 1 captured `SCRIPT_APPROVAL_VERIFIED` and `ORACLE_REQUEST_FAILED`; A-13 captures `LEADERBOARD_ENTRY_FEE_PROCESSED`; `ORACLE_RESPONSE` fires on every successful Chainlink callback; `PRIZE_POOL_CLAIMED` fires alongside `LEADERBOARD_PRIZE_CLAIMED`).

**Action:** Replay-only verification.

**Expected Supabase outcome:**
- `chain_events` rows present for: `LEADERBOARD_ENTRY_FEE_PROCESSED`, `PRIZE_POOL_CLAIMED`, `ORACLE_RESPONSE`, `ORACLE_REQUEST_FAILED`, `SCRIPT_APPROVAL_VERIFIED`
- No projection-table writes from these events (handlers are noops)
- No `pending_events` rows for these events

**Pass/Fail:**

**Evidence:**

**Notes:** Pre-PR #17, the indexer's `decodeLog()` returned null for these unknown `topic[1]` hashes and skipped them entirely. After PR #17 they're recognized; their registry entries are explicit `noop` handlers. Use this test to prove the visibility regression closed.

---

## PHASE B: HARDENING PATH VERIFICATION

**Goal:** Confirm specific hardening fixes produce correct indexer state (or correct rejection).

---

#### B-01: Post-Cooldown Match Rejection

**Description:** Attempt to match a commitment on a contest that has passed its void cooldown. Expected: transaction reverts.

**Prerequisites:** A contest exists where `block.timestamp >= startTime + 86400`. Same contest used for A-05.

**Action:**
```bash
# Attempt match against expired contest — should revert
cast send $MATCHING_MODULE \
  "matchCommitment(...)" ... \
  --private-key $TAKER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Transaction REVERTS with `MatchingModule__ContestPastCooldown()`

**Expected Supabase outcome:**
- NO new rows in any table

**Pass/Fail:**

**Evidence:**

**Notes:** Requires same 24h wait as A-05. Execute after A-05.

---

#### B-02: Secondary Market acquiredViaSecondaryMarket Flag

**Description:** Verify the buyer's position is flagged as acquired via secondary market after A-19.

**Prerequisites:** A-19 completed (position was sold).

**Action:** Query Supabase:
```sql
SELECT acquired_via_secondary_market
FROM positions
WHERE network = 'amoy'
  AND speculation_id = SPEC_ID
  AND user_address = 'TAKER_ADDR'
  AND position_type = 'upper';
```

**Expected Supabase outcome:**
- `acquired_via_secondary_market = true`

**Pass/Fail:**

**Evidence:**

**Notes:** Read-only verification of A-19's POSITION_TRANSFERRED handler outcome.

---

#### B-03: Secondary Market Position Rejected from Leaderboard

**Description:** Attempt to register a secondary-market-acquired position for a leaderboard. Expected: revert.

**Prerequisites:** B-02 confirmed. Leaderboard exists where that speculation is eligible. TAKER is registered.

**Action:**
```bash
cast send $LEADERBOARD_MODULE \
  "registerPositionForLeaderboard(uint256,uint8,uint256)" \
  SPEC_ID 0 LEADERBOARD_ID \
  --private-key $TAKER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Transaction REVERTS (RulesModule rejects secondary market positions)

**Expected Supabase outcome:**
- NO new `leaderboard_positions` row

**Pass/Fail:**

**Evidence:**

**Notes:** The actual revert error is `LeaderboardModule__SecondaryMarketPositionIneligible()` raised at `LeaderboardModule.sol:437-438` (a direct check inside `registerPositionForLeaderboard`, BEFORE the RulesModule.validateLeaderboardPosition call). Buyer's position must be acquired via secondary market AND must clear the `firstFillTimestamp >= lb.startTime` check (otherwise `PositionPredatesLeaderboard` fires first and we never reach the SM check).

**Buyer-selection caveat (added v4.2):** the buyer must NOT already have an LB position on the same `(contestId, scorer)` for the same LB — otherwise `PositionAlreadyExistsForSpeculation` fires (see B-04 / finding #13) before the SM check. Likewise, if the buyer already has a position on a DIFFERENT scorer for the same contest, `setAllowMoneylineSpreadPairing=false` (default) blocks pairing across market types (finding #12). For a clean B-03 test, use a fresh wallet that isn't otherwise positioned on the same contest's LB-eligible specs. (R4.1 evening session used DEPLOYER as the buyer because TAKER had Spec X1 Lower already registered for LB 3.)

---

#### B-04: PositionAlreadyExistsForSpeculation revert (anti-Over+Under exploit)

**Description:** A user cannot register a SECOND position for the same `(leaderboardId, user, contestId, scorer)` tuple — even at different `lineTicks` and even on the OPPOSITE side. The contract enforces this via `LeaderboardModule.sol:440-446`, blocking:

- The **Over+Under exploit**: take both Upper (Over) and Lower (Under) on the same total spec → zero-P&L registrations that would otherwise satisfy minBets/totalPositions thresholds for free.
- **Ladder betting** on the same direction (e.g., Total 220 + Total 230 on same contest) — both share `(contest, TotalScorer)` key.
- The keying is `(lbId, user, contestId, scorer)` — does NOT include `lineTicks` and does NOT include `positionType`. **One LB position per user per (contest, scorer) per LB. Period.**

**Prerequisites:** A user has already registered ONE LB position on `(contestId, scorer)` (e.g., Spec X1 Upper Total 220 for some leaderboard). User must hold a second position on the SAME `(contestId, scorer)` — either the opposite side of the same spec (matched-pair reverse fill) OR a different spec at a different lineTicks but same scorer (ladder).

**Setup options:**
1. **Same-spec opposite side (true Over+Under exploit attempt):** user is the maker of Spec X1 Upper (already registered) AND is the taker of a separate fill on Spec X1 Lower. They now own both Upper and Lower positions on Spec X1.
2. **Same-scorer different lineTicks:** user has Spec X1 Upper (Total 220 — already registered) AND Spec X2 Upper (Total 230 — different speculation, same TotalScorer).

**Action (option 2 example):**
```bash
# After Spec X1 (Total 220) Upper already registered for LB N…
# Match a separate Total spec at lineTicks=2300 (creates Spec X2)
node scripts/stress-test/match-commitment.js CONTEST_ID total 2300 0 191 10000000 NEW_NONCE

# Add Spec X2 to LB N
cast send $LEADERBOARD_MODULE "addLeaderboardSpeculation(uint256,uint256)" LB_ID X2_SPEC \
  --private-key $LB_CREATOR_PK --rpc-url $AMOY_RPC

# Attempt to register MAKER's Upper on Spec X2 → expected revert
cast send $LEADERBOARD_MODULE \
  "registerPositionForLeaderboard(uint256,uint8,uint256)" \
  X2_SPEC 0 LB_ID \
  --private-key $MAKER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Transaction REVERTS with `LeaderboardModule__PositionAlreadyExistsForSpeculation()` (4-byte selector deterministic from the error name).

**Expected Supabase outcome:**
- NO new `leaderboard_positions` row for Spec X2 / user.
- Existing Spec X1 LB position record unchanged.

**Pass/Fail:**

**Evidence:**

**Notes:** This is a layered defense WITH `setAllowMoneylineSpreadPairing` (which gates ML+Spread cross-scorer pairing). Together:
- Per-scorer uniqueness (this test, B-04): at most 1 LB position per user per `(contest, scorer)` per LB.
- Cross-scorer pairing gate: ML+Spread allowed only if creator opts in via `setAllowMoneylineSpreadPairing(lb, true)` BEFORE startTime.

Combined: a user can have at most {1 of each market type that's permitted to pair}, with sensible defaults that prevent obvious exploits like zero-P&L registrations.

---

## PHASE C: INDEXER-SPECIFIC CORRECTNESS

**Goal:** Validate indexer-unique features that didn't exist in the webhook architecture.

---

#### C-01: Pending Events Dependency Flow

**Description:** Trigger a CONTEST_CREATED event where the `contest_reference` row is missing. Verify: event defers to pending_events, retry worker picks it up after the reference is inserted, pending_events row is deleted on success.

**Prerequisites:** A game ID that does NOT yet have a `contest_reference` row in Supabase.

**Action:**
1. Create a contest on-chain using a jsonodds_id with no contest_reference row
2. Wait ~30s. Verify `pending_events` has a row with reason="missing_contest_reference"
3. Insert the `contest_reference` row manually via Supabase SQL Editor
4. Wait for retry worker (~10s cycle). Verify:
   - `contests` row now exists
   - `pending_events` row is deleted
   - `chain_events` row exists

**Expected Supabase outcome (step 2):**
- `pending_events` row: event_type="CONTEST_CREATED", reason="missing_contest_reference", attempts >= 1

**Expected Supabase outcome (step 4):**
- `contests` row created with correct data
- `pending_events` row deleted
- `chain_events` row exists

**Pass/Fail:**

**Evidence:**

**Notes:** This is the highest-value indexer test — validates the entire dependency resolution system. The retry worker runs every 10s. If the event has been retried > 20 times or exists > 1 hour, the indexer logs a warning (early signal); after `PENDING_MAX_ATTEMPTS` (default 360, ~1h at 10s tick) the row is **deleted** by default (or **skipped** if `PENDING_MAX_ATTEMPTS_ACTION=skip` — preserves audit trail). See PR #20.

**R4 Session 1 status:** C-01 was NOT triggered organically (every selected game already had a `contest_reference` row). **R4.1 must run this manually:**
1. Pick a `jsonodds_id` with no `contest_reference` row (e.g., a random UUID).
2. Run `OracleModule.createContestFromOracle(...)` with the bogus id (1 USDC + 0.004 LINK on testnet — permissionless entry point, no game-timing concern).
3. Verify `pending_events` row appears with `reason='missing_contest_reference'`, attempts increment.
4. Insert the missing `contest_reference` row in Supabase.
5. Verify `pending_events` row deleted on next retry tick (~10s) and `contests` row created.

**C-01b: Retry-cap behavior (PR #20).** Variant: do NOT insert the `contest_reference` row in step 4. Instead, lower `PENDING_MAX_ATTEMPTS` temporarily on Heroku (e.g., 5) and confirm the row is deleted (default action) or stops being retried (skip action) at attempts ≥ MAX. Verify no log spam after the cap is hit. Restore `PENDING_MAX_ATTEMPTS` to its production default after the test.

---

#### C-02: source_block Population

**Description:** Verify every projected row from Phase A tests has `source_block IS NOT NULL` on INSERT-created rows.

**Prerequisites:** Phase A tests completed (at least A-01 through A-06).

**Action:**
```sql
-- Check all INSERT-created tables for null source_block
SELECT 'contests' as tbl, COUNT(*) as null_count FROM contests WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'speculations', COUNT(*) FROM speculations WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'positions', COUNT(*) FROM positions WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboards', COUNT(*) FROM leaderboards WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_speculations', COUNT(*) FROM leaderboard_speculations WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_registrations', COUNT(*) FROM leaderboard_registrations WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_positions', COUNT(*) FROM leaderboard_positions WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_winners', COUNT(*) FROM leaderboard_winners WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'secondary_market_listings', COUNT(*) FROM secondary_market_listings WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'maker_nonce_floors', COUNT(*) FROM maker_nonce_floors WHERE network='amoy' AND source_block IS NULL;
```

**Expected outcome:** All counts = 0.

**Pass/Fail:**

**Evidence:**

**Notes:** source_block is set on INSERTs, NOT on UPDATEs. Tables that are only updated (not inserted) by later events won't have source_block checked here — that's correct. The source_block is the block number where the row was first created, used for reorg-safe deletion.

---

#### C-03: Reconcile CLI

**Description:** Run the reconcile CLI and verify zero drift between indexer state and canonical schema.

**Prerequisites:** Phase A tests completed. Both schemas (`public` and `indexer_shadow` if applicable) populated.

**Action:**
```bash
cd /c/Users/vince/Documents/solidity/ospex-matched-pairs/ospex-indexer
SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... CHAIN_ID=80002 \
  yarn reconcile
```

**Expected outcome:**
- Exit code 0 (no drift detected)
- Console output shows all 13 tables compared with zero discrepancies

**Pass/Fail:**

**Evidence:**

**Notes:** If the reconcile compares `public` vs `indexer_shadow`, both schemas must be populated. If only one schema exists (likely `public`), this test may need adaptation — check the reconcile CLI's defaults and available schemas. The CLI compares: contests, speculations, positions, position_fills, commitments, maker_nonce_floors, leaderboards, leaderboard_registrations, leaderboard_speculations, leaderboard_winners, leaderboard_positions, secondary_market_listings, chain_events.

---

#### C-04: Backfill CLI

**Description:** Run the backfill CLI on a known block range and verify projections are idempotently reproduced.

**Prerequisites:** At least A-01 through A-06 completed. Know the block range containing those events.

**Action:**
1. Record current Supabase state (row counts + key field values) for affected tables
2. Run backfill (R4 contract addresses — see plan §"Contract Addresses (Amoy, R4 deployed 2026-04-25)"):
   ```bash
   cd /c/Users/vince/Documents/solidity/ospex-matched-pairs/ospex-indexer
   ALCHEMY_RPC_URL=... SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... CHAIN_ID=80002 \
     EMITTER_ALLOWLIST=0xD47456F17b8f1D232799aE8670330b76A924422e \
     SCORER_MONEYLINE=0x2E6Fd04Bf32E2fFd46AAd9549D86Ab619938167b \
     SCORER_SPREAD=0x0dE8B42Fe14Bf008ef26A510E45f663f083eBd77 \
     SCORER_TOTAL=0xAc2Ec406C3F1aDe03f5e25233B7379FAA0FAE85b \
     yarn backfill --from FROM_BLOCK --to TO_BLOCK
   ```
   For R4.1 replay, `FROM_BLOCK=37285105` (R4 deploy) and `TO_BLOCK=<head>`. For partial replays, choose a block range that covers a complete entity lifecycle (FK closure — see PR #10 atomic backfill RPC).
3. Compare Supabase state to pre-backfill snapshot

**Expected outcome:**
- All projected rows match pre-backfill state (idempotent)
- Row counts identical
- Field values identical
- chain_events re-inserted with same data

**Post-backfill invariant checks (PR #10):**

C-04a: **No orphaned projections** — every projected row with `source_block` in the backfill range must have at least one corresponding `chain_events` row at that block. Query:
```sql
SELECT 'contests' as tbl, source_block FROM contests WHERE network='amoy' AND source_block BETWEEN FROM AND TO
EXCEPT
SELECT 'contests', block_number FROM chain_events WHERE network='amoy' AND block_number BETWEEN FROM AND TO;
-- Must return zero rows. Repeat for speculations, positions, etc.
```

C-04b: **Leaderboard rows complete** — if the backfill range touched speculations that are referenced by leaderboard_speculations or leaderboard_positions, those leaderboard rows must still be present after backfill. The RPC's dependency closure should have expanded to include the parent leaderboard for rebuild.

C-04c: **Commitment fields correct** — for each commitment hash in the backfill range, verify `filled_risk_amount`, `applied_fills`, and `status` match the chain_events-derived state. The recompute step should have created missing commitment rows and computed correct fill totals.

**Pass/Fail:**

**Evidence:**

**Notes:** The backfill CLI now uses `rpc_backfill_range` (PR #10) — all deletes + inserts in one Postgres transaction. If the RPC fails, nothing changes. Rebuild runs after the RPC commits. The consistency check runs automatically at the end of every successful backfill.

---

#### C-05: Cursor Advancement

**Description:** Verify `indexer_cursor` advances correctly after each test batch.

**Prerequisites:** Any test that produces events.

**Action:**
```sql
SELECT * FROM indexer_cursor WHERE network = 'amoy';
```

Compare `last_confirmed_block` against the block number of the most recent test transaction.

**Expected outcome:**
- `last_confirmed_block >= (test tx block - CONFIRMATION_DEPTH)` (cursor trails head by confirmation depth)
- `last_confirmed_hash` matches the chain hash at `last_confirmed_block`

**Pass/Fail:**

**Evidence:**

**Notes:** The cursor trails the chain head by 128 blocks (confirmation depth). Run this after each batch. Also verify cursor hash matches on-chain: `cast block BLOCK_NUM --field hash --rpc-url $AMOY_RPC`.

---

#### C-06: Chain Events Deduplication

**Description:** Verify that duplicate events are rejected by the unique constraint and don't produce duplicate projected rows.

**Prerequisites:** At least one event processed.

**Action:**
1. Query a `chain_events` row — note its tx_hash and log_index
2. Manually attempt to insert a duplicate:
   ```sql
   INSERT INTO chain_events (network, tx_hash, log_index, ...)
   VALUES ('amoy', 'EXISTING_TX_HASH', EXISTING_LOG_INDEX, ...);
   ```
3. Verify: Postgres error 23505 (unique violation)
4. Verify: no duplicate projected rows

**Expected outcome:**
- Duplicate insert rejected
- Projected tables unchanged

**Pass/Fail:**

**Evidence:**

**Notes:** The indexer handles error code 23505 silently (treats as "already processed, skip handler"). This is the core idempotency guarantee.

---

## PHASE D: VOLUME / CONCURRENCY

**Goal:** Drive multiple operations in parallel and confirm no data loss or corruption.

---

#### D-01: Rapid-Fire Multi-Match

**Description:** Submit 3+ matchCommitment transactions targeting the same or consecutive blocks. Confirm all events index correctly.

**Prerequisites:** 3+ signed commitments (different nonces). Funded MAKER + TAKER.

**Action:**
```bash
# Send 3 match txs in rapid succession
for NONCE in 10 11 12; do
  cast send $MATCHING_MODULE "matchCommitment(...)" ... --async
done
```

**Expected Supabase outcome:**
- All events in `chain_events` with correct ordering (by log_index within block)
- `positions`: all fills correctly accumulated (BigInt addition)
- No duplicate or missing rows
- No stuck `pending_events` rows

**Pass/Fail:**

**Evidence:**

**Notes:** On Amoy (2-second blocks), sending within 2s may land in same block. Even across blocks, tests the indexer's multi-event-per-chunk handling.

---

#### D-02: Per-Transaction Reconciliation

**Description:** Tighter reconciliation than simple row counts. For each test transaction, verify exactly the expected events and projected rows were written — no more, no fewer.

Row-count equality gets noisy after secondary transfers (one POSITION_SOLD can create/modify multiple position rows). Instead, assert per-tx:

**Action:** For every test transaction executed in Phase A, run the following checks:

**Check 1 — Per-tx event count:**
```sql
-- For each test tx, verify exact event count
-- NOTE: the chain_events column is `event_name`, not `event_type`. (pending_events
-- has its own `event_type` column — different table, different column.)
SELECT event_name, COUNT(*)
FROM chain_events
WHERE network = 'amoy' AND tx_hash = '<TX_HASH>'
GROUP BY event_name;
```
Compare against the expected events for that test (e.g., **A-06 expects exactly 4: SPECULATION_CREATED, COMMITMENT_MATCHED, POSITION_MATCHED_PAIR, SPLIT_FEE_PROCESSED** — the speculation-creation fee split fires in the same tx; A-07 accumulation expects exactly 2: COMMITMENT_MATCHED, POSITION_MATCHED_PAIR).

**Check 2 — Exact target-row assertions:**
For each event, verify the specific projected row(s) exist with correct field values. Not just "row exists" but "row has risk_amount=10000000, position_type=upper, source_block=BLOCK".

**Check 3 — Duplicate check:**
```sql
-- No duplicate chain_events (should be impossible via UNIQUE constraint, but verify)
SELECT tx_hash, log_index, COUNT(*)
FROM chain_events
WHERE network = 'amoy'
GROUP BY tx_hash, log_index
HAVING COUNT(*) > 1;

-- No duplicate positions (same user + speculation + position_type)
SELECT speculation_id, user_address, position_type, COUNT(*)
FROM positions
WHERE network = 'amoy'
GROUP BY speculation_id, user_address, position_type
HAVING COUNT(*) > 1;
```

**Check 4 — Replay-derived consistency:**
For a sample of chain_events rows, decode the `payload` and verify it contains enough information to reconstruct the projected row. This validates the replay/recovery path.

**Expected outcome:**
- Check 1: every tx has exactly the expected event count
- Check 2: every projected row matches expected values
- Check 3: zero duplicates
- Check 4: decoded payloads match projected state
- `pending_events` count = 0

**Pass/Fail:**

**Evidence:**

**Notes:** Build the per-tx expected event map as tests are executed (each test records its tx hash + expected events). The map becomes the reconciliation input.

---

#### D-03: Value Reconciliation (USDC Accounting)

**Description:** Full accounting pass — on-chain USDC balances must match indexed economic state. **Per `TreasuryModule.sol`, fee income flows to the protocol receiver, NOT to TreasuryModule itself; TreasuryModule custodies leaderboard prize pools.** Reconcile each balance against the right source.

**Action:**
```bash
# On-chain balances
cast call $USDC "balanceOf(address)(uint256)" $POSITION_MODULE --rpc-url $AMOY_RPC
cast call $USDC "balanceOf(address)(uint256)" $TREASURY_MODULE --rpc-url $AMOY_RPC
cast call $USDC "balanceOf(address)(uint256)" $PROTOCOL_RECEIVER --rpc-url $AMOY_RPC   # immutable i_protocolReceiver
cast call $USDC "balanceOf(address)(uint256)" $SECONDARY_MARKET_MODULE --rpc-url $AMOY_RPC
```

Reconcile against:
- **PositionModule balance** = sum of (unclaimed winning positions: `risk + profit`) + (unclaimed push positions: `risk`) − (already claimed). Source: `positions` table (filter on `claimed=false` and matching speculation `win_side`).
- **TreasuryModule balance** = `Σ s_leaderboardPrizePools[leaderboardId]` over all LBs = `Σ (entry fees + LEADERBOARD_FUNDED amounts) − Σ claimed prize amounts`. Source: `leaderboards.prize_pool` for each LB; cross-check against `leaderboard_registrations` (entry fee × paid registrations) + `leaderboard_fundings` (sum of `amount`) − `leaderboard_winners.claimed_amount` (or equivalent claim total). Equivalent SQL: `SELECT SUM(prize_pool) FROM leaderboards WHERE network='amoy';`
- **ProtocolReceiver balance delta** (since R4 deploy) = sum of all `fees.total_amount` for `network='amoy'`. Per `TreasuryModule.processFee()` and `processSplitFee()`, all `FEE_PROCESSED` and `SPLIT_FEE_PROCESSED` USDC is transferred to `i_protocolReceiver`. Equivalent SQL: `SELECT COALESCE(SUM(total_amount),0) FROM fees WHERE network='amoy';`
- **SecondaryMarketModule balance** = sum of unclaimed sale proceeds (sales recorded in `secondary_market_listings.sold_*` minus `SALE_PROCEEDS_CLAIMED` events).

**Expected outcome:** All balance ↔ indexed-state pairs reconcile to zero discrepancy.

**Pass/Fail:**

**Evidence:**

**Notes:** The earlier "TreasuryModule balance = 1.00 USDC × contests + …" formulation was wrong — those fees never sat in TreasuryModule. They moved straight to `i_protocolReceiver` on the same tx. Any discrepancy = missed event or incorrect handler arithmetic.

---

## PHASE E: R4.1 REPLAY / PROJECTION VALIDATION (NEW IN v4.1)

**Goal:** Validate that the indexer (post-PRs #16–#22) can replay/backfill R4 history (block 37285105 → head) and reproduce all projection state cleanly. This is the primary workstream for R4.1 — only fall back to a full new on-chain round if replay/reconcile fails to repair state.

**Scope decision tree:**
1. Run E-01 / E-02 / E-03 below.
2. If they pass → continue Round 4 (Sessions 2/3/4 proceed as planned in the original session log).
3. If E-01 (replay) reproduces state but E-02 (reconcile) shows drift → file a targeted fix in ospex-indexer; do NOT wipe.
4. If replay cannot repair state at all → wipe `amoy*` Supabase data and rerun the backfill from block 37285105. **Only then** consider starting a new on-chain round.

---

#### E-01: Indexer Replay/Backfill from R4 deployment block

**Description:** Run `yarn backfill --from 37285105 --to <head>` against the R4 history. Verify that **every event that fired during R4 Session 1** lands in `chain_events`, all projection-handler events produce typed-table rows (especially the 5 new partials projected by PR #22 for events that fired), and all audit-only events that fired produce chain_events rows with no projection writes.

> ⚠️ **"All 35 events" caveat:** Replay can only validate events that already fired on-chain. Of the 35 recognized event types: `PRIZE_POOL_CLAIMED` cannot be validated until a leaderboard prize is claimed (Session 4+); `LEADERBOARD_FUNDED`, `RULE_SET`, `DEVIATION_RULE_SET` did not fire in R4 Session 1 and require the §4 / Phase E-04 targeted triggers. **Use the §1 checklist below as the authoritative list of events expected from R4 history.**

**Prerequisites:** Indexer deployed at PR #22 or later. Alchemy RPC with chunking respected (`BLOCK_RANGE_CHUNK`). `EMITTER_ALLOWLIST` set to **R4 OspexCore only** — that's the only contract that emits `CoreEventEmitted` (every other module emits via `i_ospexCore.emitCoreEvent(...)`). The three scorer addresses live in separate env vars `SCORER_MONEYLINE` / `SCORER_SPREAD` / `SCORER_TOTAL` (see `ospex-indexer/src/config.ts:52,116-122`); these are used to map scorer addresses to market types in handlers, NOT to filter ingested logs.

**Action:**
```bash
cd /c/Users/vince/Documents/solidity/ospex-matched-pairs/ospex-indexer
ALCHEMY_RPC_URL=... SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... CHAIN_ID=80002 \
  EMITTER_ALLOWLIST=0xD47456F17b8f1D232799aE8670330b76A924422e \
  SCORER_MONEYLINE=0x2E6Fd04Bf32E2fFd46AAd9549D86Ab619938167b \
  SCORER_SPREAD=0x0dE8B42Fe14Bf008ef26A510E45f663f083eBd77 \
  SCORER_TOTAL=0xAc2Ec406C3F1aDe03f5e25233B7379FAA0FAE85b \
  yarn backfill --from 37285105 --to <head>
```

**Expected outcome (events that DID fire in R4 Session 1):**
- `chain_events` populated for the full R4 range with at least these event types: CONTEST_CREATED, CONTEST_VERIFIED, CONTEST_MARKETS_UPDATED, SPECULATION_CREATED, COMMITMENT_MATCHED, POSITION_MATCHED_PAIR, SPLIT_FEE_PROCESSED, FEE_PROCESSED, POSITION_LISTED, LISTING_UPDATED, POSITION_SOLD, POSITION_TRANSFERRED, LISTING_CANCELLED, SALE_PROCEEDS_CLAIMED, COMMITMENT_CANCELLED, MIN_NONCE_UPDATED, LEADERBOARD_CREATED, LEADERBOARD_SPECULATION_ADDED, USER_REGISTERED, LEADERBOARD_ENTRY_FEE_PROCESSED, LEADERBOARD_POSITION_ADDED, ORACLE_RESPONSE, ORACLE_REQUEST_FAILED, SCRIPT_APPROVAL_VERIFIED. (24 distinct types confirmed by the Session 1 log; replay must match.)
- Typed tables (`fees` for FEE_PROCESSED + SPLIT_FEE_PROCESSED) populated with PR #22 schema.
- `leaderboard_fundings`, `leaderboard_rules`, `leaderboard_deviation_rules` are **expected empty** post-replay — those events did not fire during R4 Session 1 and must be triggered separately in §4.
- Audit-only events (`LEADERBOARD_ENTRY_FEE_PROCESSED`, `ORACLE_RESPONSE`, `ORACLE_REQUEST_FAILED`, `SCRIPT_APPROVAL_VERIFIED`) have `chain_events` rows but no projection writes. `PRIZE_POOL_CLAIMED` has no rows yet (no prize claim has occurred).
- All 7 R4 first-fill txs from Session 1 show **4 chain_events** rows (not 3) — the previously-dropped `SPLIT_FEE_PROCESSED` is now present.
- All COMMITMENT_MATCHED rows have `nonce`, `expiry`, `risk_amount`, `speculation_key` populated (PR #21).
- The R4 Session 1 A-22 cancelled commitment row (hash `0x5790469bd7...`) has full R4 fields populated post-recovery, not just hash/maker.

**Events not validated by E-01 (require §4 triggers):** `LEADERBOARD_FUNDED`, `RULE_SET`, `DEVIATION_RULE_SET`, `C-01` pending-events flow + `C-01b` retry cap. `PRIZE_POOL_CLAIMED` deferred to Session 4 prize claim. `CONTEST_SCORES_SET`, `SPECULATION_SETTLED`, `POSITION_CLAIMED`, `CONTEST_VOIDED`, `LEADERBOARD_ROI_SUBMITTED`, `LEADERBOARD_NEW_HIGHEST_ROI`, `LEADERBOARD_PRIZE_CLAIMED` deferred to Sessions 2/3/4 game-timing-gated tests.

**Pass/Fail:**

**Evidence:**

**Notes:** PR #22 made `recovery.ts` set `source_block` on both new and pre-existing rows during recompute, so this replay should produce a clean state with no NULL `source_block` even on rows that pre-existed the partials projection migration.

---

#### E-02: Reconcile (C-03) post-replay + explicit SQL for new PR #22 tables

**Description:** Run `yarn reconcile`. After E-01 it should pass with zero drift across the 13 tables it covers. The 4 PR #22 tables (`fees`, `leaderboard_fundings`, `leaderboard_rules`, `leaderboard_deviation_rules`) are **NOT yet** in the reconcile CLI's `TABLES` array (see `ospex-indexer/src/cli/reconcile.ts:30-44`) — they require explicit SQL checks until the CLI is extended.

**Action — Part A: existing reconcile CLI:** Run C-03 (see Phase C). Expect exit 0, zero drift across the original 13 tables: `contests`, `speculations`, `positions`, `position_fills`, `commitments`, `maker_nonce_floors`, `leaderboards`, `leaderboard_registrations`, `leaderboard_speculations`, `leaderboard_winners`, `leaderboard_positions`, `secondary_market_listings`, `chain_events`.

**Action — Part B: explicit SQL for PR #22 tables.** Run these checks in the Supabase SQL Editor against the `amoy*` schema (or whichever R4 schema is active):

```sql
-- B1. fees: every FEE_PROCESSED + SPLIT_FEE_PROCESSED chain_event must have a fees row.
-- NOTE: chain_events column is `event_name` (NOT `event_type`).
SELECT ce.tx_hash, ce.log_index, ce.event_name
FROM chain_events ce
WHERE ce.network = 'amoy'
  AND ce.event_name IN ('FEE_PROCESSED','SPLIT_FEE_PROCESSED')
  AND NOT EXISTS (
    SELECT 1 FROM fees f
    WHERE f.network = ce.network
      AND f.tx_hash = ce.tx_hash
      AND f.log_index = ce.log_index
  );
-- Expect: zero rows.

-- B2. fees: shape correctness — single shape has second_amount NULL, split shape has second_amount NOT NULL.
SELECT fee_type, COUNT(*) AS rows,
       COUNT(second_amount) AS split_count,
       COUNT(*) - COUNT(second_amount) AS single_count
FROM fees WHERE network='amoy'
GROUP BY fee_type;
-- Cross-check: split_count should equal SPLIT_FEE_PROCESSED chain_events count;
-- single_count should equal FEE_PROCESSED chain_events count.

-- B3. leaderboard_fundings: every LEADERBOARD_FUNDED chain_event must have a row, and the
--     atomic prize_pool increment must equal the sum of fundings for that LB.
SELECT ce.tx_hash, ce.log_index
FROM chain_events ce
WHERE ce.network='amoy' AND ce.event_name='LEADERBOARD_FUNDED'
  AND NOT EXISTS (
    SELECT 1 FROM leaderboard_fundings lf
    WHERE lf.network=ce.network AND lf.tx_hash=ce.tx_hash AND lf.log_index=ce.log_index
  );
-- Expect: zero rows.

SELECT lf.leaderboard_id, SUM(lf.amount) AS funded_total,
       l.prize_pool, l.prize_pool >= SUM(lf.amount) AS pool_at_least_funded
FROM leaderboard_fundings lf
JOIN leaderboards l ON l.network=lf.network AND l.leaderboard_id=lf.leaderboard_id
WHERE lf.network='amoy'
GROUP BY lf.leaderboard_id, l.prize_pool;
-- Expect: pool_at_least_funded = true for every LB (prize_pool also includes entry fees).

-- B4. leaderboard_rules: every RULE_SET chain_event must produce/update a row keyed on
--     (network, leaderboard_id, rule_type). UPSERT semantics → no duplicates.
SELECT network, leaderboard_id, rule_type, COUNT(*) AS rows
FROM leaderboard_rules
WHERE network='amoy'
GROUP BY 1,2,3
HAVING COUNT(*) > 1;
-- Expect: zero rows.

-- B5. leaderboard_deviation_rules: same shape, keyed on (network, lb, league, scorer, position_type).
SELECT network, leaderboard_id, league_id, scorer, position_type, COUNT(*) AS rows
FROM leaderboard_deviation_rules
WHERE network='amoy'
GROUP BY 1,2,3,4,5
HAVING COUNT(*) > 1;
-- Expect: zero rows.

-- B6. source_block populated on inserts (PR #22 recovery.ts fix applies to all new tables).
SELECT 'fees' AS tbl, COUNT(*) AS null_source_block FROM fees WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_fundings', COUNT(*) FROM leaderboard_fundings WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_rules', COUNT(*) FROM leaderboard_rules WHERE network='amoy' AND source_block IS NULL
UNION ALL
SELECT 'leaderboard_deviation_rules', COUNT(*) FROM leaderboard_deviation_rules WHERE network='amoy' AND source_block IS NULL;
-- Expect: every count = 0.
```

**Expected outcome:** `yarn reconcile` exits 0, AND every SQL check above returns the expected (typically zero) rows.

**Follow-up issue:** File ospex-indexer issue/PR to add the 4 PR #22 tables to `reconcile.ts:TABLES` so future reconcile runs cover them automatically.

---

#### E-03: Per-tx + USDC value reconciliation post-replay

**Description:** Same as D-02 + D-03 — run per-tx event count assertions and USDC balance reconciliation. R4 first-fill txs now expect **4 events** (PR #17/#22), not 3.

**Action:** Run D-02 and D-03 (see Phase D). Recompute the per-tx expected-event map for R4 Session 1's tx hashes using the corrected expectations:
- **All 7 first-fill txs** (Specs 1–7 — every speculation creation in R4 Session 1: A-06 ×3 across Tracks 1/3/4, A-24 spread, A-25 total, helper match Spec 6, helper match Spec 7): expect **4 events** each — SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR + SPLIT_FEE_PROCESSED.
- A-07 accumulations and D-01 rapid-fire: expect 2 events each (COMMITMENT_MATCHED + POSITION_MATCHED_PAIR; no new SPECULATION_CREATED, no SPLIT_FEE_PROCESSED).
- A-01 contest creations: expect CONTEST_CREATED + 3× SCRIPT_APPROVAL_VERIFIED + FEE_PROCESSED + (eventually) ORACLE_RESPONSE/CONTEST_VERIFIED on callback.
- A-11 leaderboard creation: expect LEADERBOARD_CREATED + FEE_PROCESSED (single, fee_type='leaderboard_creation').
- A-13 user registration: expect USER_REGISTERED + LEADERBOARD_ENTRY_FEE_PROCESSED.

**USDC reconciliation (corrected — see D-03):**
- `PositionModule.balanceOf(USDC)` = unclaimed positions (winners: risk+profit, pushes: risk) − claimed.
- `TreasuryModule.balanceOf(USDC)` = `SELECT SUM(prize_pool) FROM leaderboards WHERE network='amoy'` (= entry fees + LEADERBOARD_FUNDED − claimed prizes).
- `protocolReceiver.balanceOf(USDC)` delta since R4 deploy block = `SELECT SUM(total_amount) FROM fees WHERE network='amoy'`.
- `SecondaryMarketModule.balanceOf(USDC)` = unclaimed sale proceeds.

**Expected outcome:** Zero per-tx event-count discrepancies and zero discrepancy on each balance ↔ indexed-state pair above.

---

#### E-04: Targeted re-tests for events not yet on R4 chain

**Description:** Five event types did not fire during R4 Session 1 and so cannot be validated by replay alone. They are: `LEADERBOARD_FUNDED` (A-28), `RULE_SET` (A-29), `DEVIATION_RULE_SET` (A-30), and the C-01 `pending_events` flow + retry cap. **Trigger each on-chain via the cheapest possible call** and verify the new projections.

**Action:** Run A-28, A-29, A-30, C-01, C-01b. None of these have game-timing dependencies — they're free-running on-chain operations against the existing R4 deployment.

**Cost:** A-28 ~5 USDC into `prize_pool` (custodied by TreasuryModule, distributed to the leaderboard winner on prize claim — funder does NOT directly recover it). New pre-start LB N for A-29/A-30 setup costs 0.50 USDC creation fee + 5 USDC entry fees if registering users. A-29/A-30 themselves are free (just gas). C-01 ~1 USDC + 0.004 LINK for the bogus contest creation (permissionless entry).

**Expected outcome:** All 5 typed tables populated as described in the per-test sections above.

---

## EXECUTION STRATEGY

### Contests to Create

Each session must cover every available sport in `contest_reference` (see Multi-Sport Coverage constraint). Assign contests to tracks so that each sport appears at least once. Current sport → track mapping:

| Contest | Track | Sport | Purpose | Game Selection |
|---------|-------|-------|---------|----------------|
| Contest A | 1, 2 | Varies (rotate per session) | Score/settle/claim lifecycle + leaderboard speculation source | Future game 24-72h out (STATUS_SCHEDULED) |
| Contest B | 3 | Varies (different sport from A) | Secondary market (must stay unsettled through Day 1) | Future game |
| Contest C | 4 | Varies (remaining sport) | Void/cooldown (intentionally left unscored for 24h) | Game whose start_time is near-past or imminent |

If more than 3 sports are available, create additional contests to cover them (any track that accepts multiple contests).

**After selecting games, present them for user review before contest creation** (see Game Selection Review Gate constraint).

### Session Plan by Track

**Session 1 — Day 1 (all tracks, ~3 hours)**

| Order | Track | Tests | Notes |
|-------|-------|-------|-------|
| 0:00 | — | Pre-flight checklist | Cleanup, wallets, approvals, contest_reference rows |
| 0:15 | — | T-00 | Indexer liveness canary. **Stop if this fails.** |
| 0:17 | — | Game selection review | Identify games for each sport/track. Present to user with CST times. **Wait for approval.** |
| 0:25 | 1 | A-01, A-02, A-03 | Contest A: create/verify/markets. Wait for Chainlink callbacks. |
| 0:50 | 1 | A-06, A-07 | Match commitments on Contest A (moneyline, accumulation). |
| 1:05 | 1 | A-24, A-25 | Spread + total matches on Contest A. |
| 1:15 | 3 | Contest B create/verify/match | Set up Contest B + speculation for secondary market. |
| 1:30 | 3 | A-17, A-18, A-19, A-20, A-21 | Full secondary market cycle on Contest B. |
| 1:50 | 3 | B-02, B-03 | Verify acquiredViaSecondaryMarket flag + leaderboard rejection. |
| 2:00 | 2 | A-11, A-12, A-13 | Leaderboard create + add speculation (from Track 1) + register user. |
| 2:05 | 2 | Wait 5min | Leaderboard startTime. |
| 2:10 | 2 | A-14 | Register position for leaderboard. |
| 2:15 | 4 | Contest C create/verify/match | Set up Contest C for void (game near start_time). |
| 2:20 | — | A-22, A-23 | Commitment cancel + min nonce (independent). |
| 2:30 | — | C-01 | Pending events dependency flow test. |
| 2:45 | — | C-02, C-05, C-06 | source_block, cursor, deduplication checks. |
| 3:00 | — | D-01 | Rapid-fire concurrency test. |

**Session 2 — Day 2-3 (after game A ends)**

| Order | Track | Tests | Notes |
|-------|-------|-------|-------|
| 0:00 | 1 | A-04 | Score Contest A (Chainlink callback). |
| 0:15 | 1 | A-08 | Settle speculation(s) on Contest A. |
| 0:20 | 1 | A-09 | Claim position (winner). |
| 0:30 | — | D-02 | Per-tx reconciliation (all tests so far). |
| 0:45 | — | D-03 | USDC value reconciliation. |
| 1:00 | — | C-03 | Reconcile CLI. |
| 1:15 | — | C-04 | Backfill CLI on known block range. |

**Session 3 — Day 2-3 (24h+ after Contest C start_time)**

| Order | Track | Tests | Notes |
|-------|-------|-------|-------|
| 0:00 | 4 | A-05 | Void Contest C (24h cooldown elapsed). |
| 0:10 | 4 | B-01 | Post-cooldown match rejection on Contest C. |

**Session 4 — Day 6+ (after leaderboard endTime + 24h safety + 24h ROI window)**

| Order | Track | Tests | Notes |
|-------|-------|-------|-------|
| 0:00 | 2 | A-15 | Submit ROI (speculation must be settled from Session 2). |
| 0:05 | 2 | A-16 | Claim leaderboard prize. |
| 0:10 | — | Final D-02 | Final per-tx reconciliation sweep. |

### Time Dependencies

| Test | Waiting For | Gate |
|------|-------------|------|
| A-04 | Game A to end | 24-72h from creation |
| A-05 | Contest C start_time + 86400s | 24h from Contest C creation |
| A-08 | A-04 (contest scored) | Same session |
| A-14 | Leaderboard startTime | 5 min from A-11 |
| A-15 | Track 1 settled AND leaderboard endTime + safety elapsed | 5 days from A-11 (4d endTime + 24h safety) |
| A-16 | A-15 AND roiWindow elapsed | 6 days from A-11 (4d endTime + 24h safety + 24h ROI) |
| B-01 | Same as A-05 | Same session |

---

## REVISION LOG

| Date | Change |
|------|--------|
| 2026-04-22 | v2 plan created. Supersedes v1 (webhook-based). Restructured for ospex-indexer: added Phase C (indexer-specific), removed aspirational agent integration (old Phase D), added pending_events/source_block/reconcile/backfill tests, incorporated future-contests-only constraint, documented all 25 handlers with exact Supabase table targets from indexer source code. |
| 2026-04-22 | v2.1 feedback incorporated: (1) Split linear flow into 4 independent tracks (score/settle, leaderboard, secondary market, void/cooldown) to avoid incompatible timing assumptions — leaderboard endTime extended to 4 days. (2) Added T-00 indexer liveness canary before expensive oracle calls. (3) Explicitly documented 2 unhandled events (LEADERBOARD_FUNDED, LEADERBOARD_ENTRY_FEE_PROCESSED) with rationale. (4) Replaced row-count reconciliation (D-02) with per-tx event assertions, exact target-row checks, duplicate detection, and replay-derived consistency. |
| 2026-04-22 | Session 1 executed (now stale — superseded by v3 re-test). |
| 2026-04-23 | v3 plan: Supabase wiped after PRs 8-15 merged. Added new verification steps for league_id, acquired_via_secondary_market, first_fill_timestamp, commitment upserts, sold_* snapshot. All pass/fail reset. |
| 2026-04-23 | OC review additions: (1) A-20b relist check — verify sold_* cleared on relist. (2) C-04a/b/c — explicit backfill invariants: no orphaned projections, leaderboard rows complete, commitment fields correct. (3) A-23 commitment invalidation check — verify nonce_invalidated on indexer-created commitments. (4) Annotated "commitments empty by design" finding as superseded by PRs 11-13. |
| 2026-04-24 | Leaderboard minimum window policy: safety period and ROI submission window must each be at minimum 24 hours (86400s). Updated A-11 from 60s to 86400s for both windows. Updated all downstream timing references (A-15, A-16, Session 4 header, time dependencies table). Rationale: shorter windows are unusable in production and make testing hostile. |
| 2026-04-24 | Multi-sport coverage + game selection review gate: (1) Every session must include at least one contest per available sport in contest_reference (currently 0=MLB, 1=NBA, 5=NHL). Halt if any sport is missing. (2) After T-00 canary, present selected games with CST times for user review before contest creation. Rationale: Session 1 v3 only tested 2 of 3 sports; repeated time zone parsing errors have wasted testnet gas. |
| 2026-04-26 | **v4.1** — R4 Session 1 Day 1 surfaced doc gaps closed by indexer PRs #16–#22. Changes: (1) Event count corrected from 27/26 to **35** with explicit projecting (30) vs audit-only (5) split. (2) Polling interval corrected from 2000ms to **15000ms minimum** — Alchemy free-tier rate-limits enforce this. (3) **A-06 / D-02 first-fill expectation corrected from 3 events to 4** — `SPLIT_FEE_PROCESSED` was silently dropped pre-PR #17. (4) **A-22 expected outcome rewritten** — post-PR #21, COMMITMENT_CANCELLED upserts a fully populated row (contest_id/scorer/lineTicks/positionType/oddsTick/riskAmount/nonce/expiry/speculation_key), not best-effort hash/maker only. (5) **A-23 expected outcome updated** — post-PR #21, indexer-created commitments have real nonces (not 0), so `nonce_invalidated` works on them. (6) **Added A-26..A-31** — explicit tests for FEE_PROCESSED, SPLIT_FEE_PROCESSED, LEADERBOARD_FUNDED (PR #22 → `leaderboard_fundings`), RULE_SET (PR #22 → `leaderboard_rules`), DEVIATION_RULE_SET (PR #22 → `leaderboard_deviation_rules`), and audit-only landing check. (7) **Added Phase E (R4.1 replay/backfill validation)** — primary R4.1 workstream: replay R4 history block 37285105 → head, run reconcile + per-tx + USDC value, then targeted re-tests for events not yet on R4 chain. (8) Updated C-01 with PR #20 retry-cap details and explicit manual-trigger procedure (R4 Session 1 didn't trigger C-01 organically). (9) Safe-head source updated to chain `finalized` block tag per PR #19. |
| 2026-04-27 | **v4.2** — R4.1 evening session findings rolled into the plan. Changes: (1) Status banner updated — R4 testing essentially complete except Mon void test. (2) **Added B-04** — PositionAlreadyExistsForSpeculation revert test, the contract-level defense against the Over+Under exploit and ladder betting (per-scorer uniqueness on `(lb, user, contest, scorer)`). Documents finding #13. (3) **A-19 caveat** — explicit note that the 4th arg of `buyPosition` is `riskAmount` (how much position-risk to buy, not maxPriceToPay); passing a value > listing.riskAmount reverts with `SecondaryMarketModule__AmountAboveMaximum(uint256)`. Surfaced when DEPLOYER's first B-03 buy attempt reverted in the evening session. (4) **A-29 default-pairing note** — `setAllowMoneylineSpreadPairing` defaults to `false`. Cross-market-type aggregation per user requires the LB creator to enable it BEFORE startTime (`onlyCreatorBeforeStart` modifier). Documents finding #12, surfaced when TAKER's Spec 9 Lower register reverted on LB 3 (where MAKER+TAKER already had ML positions). (5) **B-03 caveats** — added explicit note about choosing the SM buyer carefully (must not have any other LB position on the same contest, or `PositionAlreadyExistsForSpeculation` / pairing-disallowed will fire before the SM check). The R4.1 evening session used DEPLOYER as a clean buyer for this reason. |
| 2026-04-27 | **v4.3** — Session 3 (final test) executed; R4 testing complete. Changes: (1) Status banner updated — R4 testing complete. (2) **B-01 expected revert clarification** — actual revert is `MatchingModule__ContestAlreadyScored()` (`0xd2d52b55`), NOT `ContestPastCooldown()` as previously documented. The contract's matching uses `isContestTerminal()` which fires for ANY terminal contest (Scored OR Voided). Since A-05 voids the contest before B-01 attempts a match, the terminal check fires first. Spirit of B-01 (post-cooldown match rejection) is satisfied. Documents finding #15. (3) Added open finding #14: `LEADERBOARD_PRIZE_CLAIMED` handler in ospex-indexer doesn't decrement `leaderboards.prize_pool` — breaks `TreasuryModule.balanceOf == SUM(prize_pool)` invariant after any LB prize claim. (4) Added open finding #15: `ContestAlreadyScored` is misleadingly named in MatchingModule. |
