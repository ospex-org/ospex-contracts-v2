# Amoy Stress Test Plan v2 — ospex-indexer

Status: **AWAITING REVIEW** (Step 1 complete — do not execute until approved)

---

## Supersedes

This plan **supersedes** the prior v1 plan in its entirety. All v1 test results were validated against the Alchemy-webhook/ospex-fdb pipeline, which has been retired. Those results are archived in `STRESS_TEST_SESSION_LOG.md` under "Archived: Previous Webhook Test Results" for reference only — they do not validate the indexer.

Key v1 findings that remain relevant:
- **Oracle verify script rejects non-scheduled games** — still true. Only `STATUS_SCHEDULED` games pass verification. All end-to-end tests must use future games (24-72h out).
- **Rundown API transient failures** — still possible. Retry scoring if Chainlink callback returns error.

Key v1 findings no longer applicable:
- Firebase Functions scorer config mismatch — webhook-specific.
- Alchemy webhook auto-pause on 500s — no webhook.
- Cascading FK violations from lost events — addressed by pending_events system.

---

## Architecture Context

The indexer is a **pull-based polling worker** (ospex-indexer on Heroku) that replaces the push-based Alchemy webhook.

| Property | Value |
|----------|-------|
| Polling interval | 2000ms (`POLL_INTERVAL_MS`) |
| Block chunk size | 2000 blocks (`BLOCK_RANGE_CHUNK`) |
| Confirmation depth | 128 blocks (`CONFIRMATION_DEPTH`) |
| Cursor table | `indexer_cursor` (PK: network) |
| Event deduplication | UNIQUE on `(network, tx_hash, log_index)` in `chain_events` |
| Dependency handling | `pending_events` table + retry worker (10s interval) |
| Reorg recovery | Automatic fork detection, state rollback, entity rebuild |
| CLIs | `yarn reconcile`, `yarn backfill` |

**Every test must validate** (standard checklist applied to all tests):
1. `chain_events` row exists with correct `event_type`, `entity_type`, `entity_id`
2. `source_block IS NOT NULL` on every **inserted** projected row (UPDATEs don't change source_block)
3. `pending_events` table has zero rows for this event after processing
4. No errors in indexer logs: `heroku logs --app ospex-indexer --num 50`

---

## Constraint: Future Contests Only

Verification scripts reject games whose `start_time` has already passed. All end-to-end scenarios must use contests scheduled 24-72 hours out. For tests that only need a contest to exist (not a full lifecycle), any open contest is fine.

**Implication:** The full lifecycle (create → verify → score → settle → claim) spans multiple days. Session boundaries are documented in the Execution Strategy section.

---

## Prerequisites

### Signing Keys

| Role | Address | Status |
|------|---------|--------|
| Deployer | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` | READY |
| MAKER | TBD (generate) | PENDING |
| TAKER | TBD (generate) | PENDING |

MAKER and TAKER wallets: generate via `cast wallet new`, fund with POL from deployer, mint USDC via `MockERC20.mint(address,uint256)`.

### Contract Addresses (Amoy, deployed 2026-04-19)

| Contract | Address |
|----------|---------|
| OspexCore | `0x44fEDE66279D0609d43061Ac40D43704dDb392D7` |
| ContestModule | `0x0b4B56fD4cb7848f804204B052A3e72d90213B52` |
| SpeculationModule | `0x6f32665DD97482e6C89D8B9bf025d483184F5553` |
| PositionModule | `0xf769BEC6960Ed367320549FdD5A30f7C687DB2ee` |
| MatchingModule | `0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9` |
| OracleModule | `0x08d1F10572071271983CE800ad63663f71A71512` |
| TreasuryModule | `0xC30C74edeEB3cbF2460D8a4a6BaddEBEe9D3ab1e` |
| LeaderboardModule | `0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37` |
| RulesModule | `0x657804cEcBC4c16c0eC4A8Bc384dd515EA2D462C` |
| SecondaryMarketModule | `0x0e7b7C218db7f0e34521833e98f0Af261D204aED` |
| MoneylineScorerModule | `0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC` |
| SpreadScorerModule | `0x36F3f4A6757cB2E822A1AfCea0b3092fFcaE6c30` |
| TotalScorerModule | `0xB814f3779A79c6470a904f8A12670D1B13874fDE` |
| Mock USDC | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` |
| LINK Token | `0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904` |
| Chainlink Functions Router | `0xC22a79eBA640940ABB6dF0f7982cc119578E11De` |

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

### Script Approvals (Pre-signed, expire 2026-07-19)

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

## PHASE A: HANDLER COVERAGE

**Goal:** Fire each of the 25 CoreEventEmitted events at least once and verify the indexer writes correct Supabase state.

### Priority 1 — Contest Lifecycle

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
- `chain_events` row: event_type="CONTEST_CREATED", entity_type="contest"
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
- `chain_events` row: event_type="CONTEST_VERIFIED"
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
- `chain_events` row: event_type="CONTEST_MARKETS_UPDATED"
- `contests` row updated: `spread_line_ticks`, `total_line_ticks`, `ml_upper_odds`, `ml_lower_odds`, `spread_upper_odds`, `spread_lower_odds`, `total_upper_odds`, `total_lower_odds`, `markets_updated_at` all populated
- Verify all 8 fields are non-null and reasonable

**Pass/Fail:**

**Evidence:**

**Notes:** Market data is packed into a uint256 by the oracle JS. Skipped in v1 session; should be tested this round.

---

#### A-04: CONTEST_SCORES_SET

**Description:** Score the contest after the game ends. Fires CONTEST_SCORES_SET.

**Prerequisites:** A-02 completed. **Game must have ended** (start_time + game duration has passed). This test runs in a later session (Day 2+).

**Action:**
```bash
node scripts/stress-test/score-contest.js --contestId CONTEST_ID
```

Wait for Chainlink callback to deliver scores.

**Expected on-chain outcome:**
- Contest awayScore/homeScore set, status=Scored

**Expected Supabase outcome:**
- `chain_events` row: event_type="CONTEST_SCORES_SET"
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
- `chain_events` row: event_type="CONTEST_VOIDED"
- `contests` row: contest_status="voided", voided_at set

**Pass/Fail:**

**Evidence:**

**Notes:** **Requires 24h real-time wait.** Strategy: create a contest on Day 1 for a game whose start_time is in the near past (use a just-started game). After 24+ hours, return and trigger void. Document expected void-ready time.

---

### Priority 2 — Speculation + Commitment Lifecycle

---

#### A-06: SPECULATION_CREATED + COMMITMENT_MATCHED + POSITION_MATCHED_PAIR

**Description:** Match a commitment (first fill for a new contestId/scorer/lineTicks combination). Single transaction fires 3 events.

**Prerequisites:**
- A-02 completed (verified contest exists)
- MAKER has USDC, approved PositionModule + TreasuryModule
- TAKER has USDC, approved PositionModule + TreasuryModule

**Action:**
1. MAKER signs EIP-712 OspexCommitment:
   ```
   maker: MAKER_ADDRESS
   contestId: CONTEST_ID
   scorer: 0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC (MoneylineScorer)
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
- `chain_events`: 3 rows — SPECULATION_CREATED, COMMITMENT_MATCHED, POSITION_MATCHED_PAIR
- `speculations` row: speculation_id=N, contest_id, market_type="moneyline", speculation_status="open", line_ticks=0, win_side="tbd", source_block set
- `positions` row (maker): user_address=MAKER, position_type="upper", risk_amount="10000000", profit_amount="9100000", source_block set
- `positions` row (taker): user_address=TAKER, position_type="lower", risk_amount="9100000", profit_amount="10000000", source_block set
- `position_fills` row: commitment_hash, maker, taker, odds_tick=191
- `commitments` row: status via rpc_commitment_matched, source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** This is the most complex single-transaction test — 3 events, 5+ table writes. Verify all three chain_events rows have correct log_index ordering.

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
- `chain_events` row: event_type="SPECULATION_SETTLED"
- `speculations` row: speculation_status="closed", win_side populated (e.g., "away"/"home"), settled_at set, voided=false

**Pass/Fail:**

**Evidence:**

**Notes:** win_side mapped via `WIN_SIDE_MAP`: 0=tbd, 1=away, 2=home, 3=over, 4=under, 5=push, 6=void.

---

### Priority 3 — Position Lifecycle

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
- `chain_events` row: event_type="POSITION_CLAIMED"
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

### Priority 4 — Leaderboard Lifecycle

---

#### A-11: LEADERBOARD_CREATED

**Description:** Create a new leaderboard.

**Prerequisites:** Any wallet with USDC approved for TreasuryModule.

**Action:**
```bash
# Short timing for practical testing:
# startTime = now + 5 minutes, endTime = now + 10 minutes
# safetyPeriod = 60s, roiWindow = 60s
START=$(( $(date +%s) + 300 ))
END=$(( $(date +%s) + 600 ))

cast send $LEADERBOARD_MODULE \
  "createLeaderboard(uint256,uint32,uint32,uint32,uint32)" \
  5000000 $START $END 60 60 \
  --private-key $DEPLOYER_PK --rpc-url $AMOY_RPC
```

**Expected on-chain outcome:**
- Leaderboard ID increments, 0.50 USDC creation fee charged

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_CREATED"
- `leaderboards` row: leaderboard_id=N, entry_fee="5000000", start_time, end_time, safety_period_duration=60, roi_submission_window=60, prize_pool=0, current_participants=0, total_positions=0, source_block set

**Pass/Fail:**

**Evidence:**

**Notes:** Use SHORT timing (5min start, 10min end, 60s safety, 60s ROI) to collapse the leaderboard lifecycle into ~12 minutes.

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
- `chain_events` row: event_type="LEADERBOARD_SPECULATION_ADDED"
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
- `chain_events` row: event_type="USER_REGISTERED"
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
- `chain_events` row: event_type="LEADERBOARD_POSITION_ADDED"
- `leaderboard_positions` row: leaderboard_id, speculation_id, user_address=MAKER, position_type="upper", risk_amount, profit_amount, source_block set
- `leaderboards` row: total_positions incremented (via `rpc_leaderboard_position_added`)

**Pass/Fail:**

**Evidence:**

**Notes:** Must be called after leaderboard startTime. Risk/profit may be capped by maxBetPercentage.

---

#### A-15: LEADERBOARD_ROI_SUBMITTED + LEADERBOARD_NEW_HIGHEST_ROI

**Description:** Submit ROI after submission window opens. If this is the first/highest ROI, LEADERBOARD_NEW_HIGHEST_ROI fires in the same transaction.

**Prerequisites:** A-14 completed. All speculations the user has positions on must be settled. Wait for: endTime + safetyPeriod (with short timing: ~11 minutes from leaderboard creation).

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

**Notes:** Requires endTime + safetyPeriodDuration to have passed. With short timing (10min end + 60s safety), this is ~11 minutes from creation. The speculation MUST be settled before this can succeed.

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
- `chain_events` row: event_type="LEADERBOARD_PRIZE_CLAIMED"
- `leaderboard_registrations`: claimed flag set (via `rpc_leaderboard_prize_claimed`)
- `leaderboard_winners`: claimed flag set

**Pass/Fail:**

**Evidence:**

**Notes:** With short timing: ~12 minutes from leaderboard creation (10min end + 60s safety + 60s ROI).

---

### Priority 5 — Secondary Market

All secondary market tests require a **separate unsettled speculation** (distinct from the one used for scoring/claiming). Create a second contest + speculation specifically for these tests.

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
- `chain_events` row: event_type="POSITION_LISTED"
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
- `chain_events` row: event_type="LISTING_UPDATED"
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
- `chain_events` row: event_type="LISTING_CANCELLED"
- `secondary_market_listings` row: status="cancelled", cancelled_at set

**Pass/Fail:**

**Evidence:**

**Notes:**

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
- `chain_events` row: event_type="SALE_PROCEEDS_CLAIMED"
- No additional table writes (handler is no-op beyond chain_events)

**Pass/Fail:**

**Evidence:**

**Notes:** Handler at `secondary-market.ts:106` is explicitly a no-op. Verify chain_events row exists but no other table changes.

---

### Priority 6 — Commitment Edge Cases

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

**Expected Supabase outcome:**
- `chain_events` row: event_type="COMMITMENT_CANCELLED"
- `commitments` row (if exists): status="cancelled" (best-effort update — handler only updates if row exists with status "open" or "partially_filled")

**Pass/Fail:**

**Evidence:**

**Notes:** Best-effort handler — if commitment doesn't exist in Supabase, the handler logs a warning and succeeds. Cancelling prevents future matching.

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
- `chain_events` row: event_type="MIN_NONCE_UPDATED"
- `maker_nonce_floors` row: maker=MAKER, speculation_key=hash, min_nonce=5, source_block set
- `commitments`: any rows with nonce < 5 for this maker/speculation_key have `nonce_invalidated=true` (best-effort)

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
- scorer: `0x36F3f4A6757cB2E822A1AfCea0b3092fFcaE6c30` (SpreadScorerModule)
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
- scorer: `0xB814f3779A79c6470a904f8A12670D1B13874fDE` (TotalScorerModule)
- lineTicks: 2150 (total of 215.0)
- positionType: 0 (Upper = Over)

**Expected Supabase outcome:**
- `speculations` row: market_type="total", line_ticks=2150
- `positions` rows for both sides

**Pass/Fail:**

**Evidence:**

**Notes:** After game ends: settle and verify win_side reflects total outcome (away + home vs line).

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

**Notes:** The RulesModule.validateLeaderboardPosition check returns non-Valid for secondary-market positions.

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

**Notes:** This is the highest-value indexer test — validates the entire dependency resolution system. The retry worker runs every 10s. If the event has been retried > 20 times or exists > 1 hour, the indexer logs an alert.

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
2. Run backfill:
   ```bash
   cd /c/Users/vince/Documents/solidity/ospex-matched-pairs/ospex-indexer
   ALCHEMY_RPC_URL=... SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... CHAIN_ID=80002 \
     EMITTER_ALLOWLIST=0x44fEDE66279D0609d43061Ac40D43704dDb392D7 \
     SCORER_MONEYLINE=0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC \
     SCORER_SPREAD=0x36F3f4A6757cB2E822A1AfCea0b3092fFcaE6c30 \
     SCORER_TOTAL=0xB814f3779A79c6470a904f8A12670D1B13874fDE \
     yarn backfill --from FROM_BLOCK --to TO_BLOCK
   ```
3. Compare Supabase state to pre-backfill snapshot

**Expected outcome:**
- All projected rows match pre-backfill state (idempotent)
- Row counts identical
- Field values identical
- chain_events re-inserted with same data

**Pass/Fail:**

**Evidence:**

**Notes:** The backfill process: deletes chain_events + projected rows in range, re-fetches logs from chain, re-inserts chain_events, rebuilds projected state from complete history. Tests the 10-step repair sequence. Critical for production recovery confidence.

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

#### D-02: Cross-Table Consistency

**Description:** After completing Phase A, verify row counts match expected totals.

**Action:**
```sql
-- Counts by event type
SELECT event_type, COUNT(*) FROM chain_events WHERE network='amoy' GROUP BY event_type ORDER BY event_type;

-- Projected table counts
SELECT 'contests' as tbl, COUNT(*) as cnt FROM contests WHERE network='amoy'
UNION ALL SELECT 'speculations', COUNT(*) FROM speculations WHERE network='amoy'
UNION ALL SELECT 'positions', COUNT(*) FROM positions WHERE network='amoy'
UNION ALL SELECT 'position_fills', COUNT(*) FROM position_fills WHERE network='amoy'
UNION ALL SELECT 'commitments', COUNT(*) FROM commitments WHERE network='amoy'
UNION ALL SELECT 'leaderboards', COUNT(*) FROM leaderboards WHERE network='amoy'
UNION ALL SELECT 'leaderboard_speculations', COUNT(*) FROM leaderboard_speculations WHERE network='amoy'
UNION ALL SELECT 'leaderboard_registrations', COUNT(*) FROM leaderboard_registrations WHERE network='amoy'
UNION ALL SELECT 'leaderboard_positions', COUNT(*) FROM leaderboard_positions WHERE network='amoy'
UNION ALL SELECT 'leaderboard_winners', COUNT(*) FROM leaderboard_winners WHERE network='amoy'
UNION ALL SELECT 'secondary_market_listings', COUNT(*) FROM secondary_market_listings WHERE network='amoy'
UNION ALL SELECT 'maker_nonce_floors', COUNT(*) FROM maker_nonce_floors WHERE network='amoy'
UNION ALL SELECT 'pending_events', COUNT(*) FROM pending_events WHERE network='amoy';
```

**Expected outcome:**
- CONTEST_CREATED count == contests count
- SPECULATION_CREATED count == speculations count
- pending_events count == 0 (all resolved)
- Document baseline for ongoing monitoring

**Pass/Fail:**

**Evidence:**

**Notes:** Any mismatch = handler drift or lost events.

---

#### D-03: Value Reconciliation (USDC Accounting)

**Description:** Full accounting pass — on-chain USDC balances must match indexed economic state.

**Action:**
```bash
# On-chain balances
cast call $USDC "balanceOf(address)(uint256)" $POSITION_MODULE --rpc-url $AMOY_RPC
cast call $USDC "balanceOf(address)(uint256)" $TREASURY_MODULE --rpc-url $AMOY_RPC
cast call $USDC "balanceOf(address)(uint256)" $SECONDARY_MARKET_MODULE --rpc-url $AMOY_RPC
```

Compare against:
- **PositionModule balance** = sum of (unclaimed winning positions: risk+profit) + (unclaimed push: risk) - (already claimed)
- **TreasuryModule balance** = (1.00 USDC × contests) + (0.50 USDC × speculations) + (0.50 USDC × leaderboards)
- **SecondaryMarketModule balance** = unclaimed sale proceeds

**Expected outcome:** All balances reconcile to zero discrepancy.

**Pass/Fail:**

**Evidence:**

**Notes:** Document reconciliation formulas. Any discrepancy = missed event or incorrect handler arithmetic.

---

## EXECUTION STRATEGY

### Session Boundaries

**Session 1 (Day 1):**
| Time | Tests | Notes |
|------|-------|-------|
| 0:00 | Pre-flight checklist | Cleanup, wallet setup, approvals |
| 0:30 | A-01, A-02, A-03 | Contest create/verify/markets. Wait for Chainlink callbacks. |
| 1:00 | A-06, A-07 | Match commitments (moneyline). Speculation + position creation. |
| 1:15 | A-24, A-25 | Spread + total matches (scorer variants). |
| 1:30 | A-22, A-23 | Commitment cancel + min nonce update. |
| 1:45 | A-17, A-18, A-19, A-20, A-21 | Full secondary market cycle (on second speculation). |
| 2:15 | A-11, A-12, A-13 | Leaderboard create + add speculation + register user. |
| 2:20 | Wait 5min | Leaderboard startTime. |
| 2:25 | A-14 | Register position for leaderboard (after startTime). |
| 2:30 | C-01 | Pending events dependency flow test. |
| 2:45 | C-02, C-05, C-06 | source_block, cursor, deduplication checks. |
| 3:00 | D-01 | Rapid-fire concurrency test. |

**Session 2 (Day 2-3, after game ends):**
| Time | Tests | Notes |
|------|-------|-------|
| 0:00 | A-04 | Score contest (Chainlink callback). |
| 0:15 | A-08 | Settle speculation. |
| 0:20 | A-09 | Claim position (winner). |
| 0:30 | A-15 | Leaderboard ROI + new highest ROI. Note: leaderboard endTime + safety + ROI window must have passed. If using short timing from Day 1, this should be long resolved. |
| 0:35 | A-16 | Leaderboard prize claimed. |
| 0:40 | B-02, B-03 | Secondary market flag + leaderboard rejection. |
| 0:50 | D-02 | Cross-table consistency. |
| 1:00 | D-03 | USDC value reconciliation. |
| 1:15 | C-03 | Reconcile CLI. |
| 1:30 | C-04 | Backfill CLI. |

**Session 3 (Day 2-3, 24h+ after contest start):**
| Time | Tests | Notes |
|------|-------|-------|
| 0:00 | A-05 | Void contest (24h cooldown elapsed). |
| 0:10 | B-01 | Post-cooldown match rejection. |

### Time Dependencies

| Test | Waiting For | Estimated Wait |
|------|-------------|----------------|
| A-04 | Game to end | 24-72h from creation |
| A-05 | startTime + 86400s (void cooldown) | 24h |
| A-08 | A-04 (contest scored) | Same session as A-04 |
| A-14 | Leaderboard startTime | 5 min (if short timing) |
| A-15 | endTime + safetyPeriod | ~11 min (if short timing) |
| A-16 | endTime + safetyPeriod + roiWindow | ~12 min (if short timing) |
| B-01 | Same as A-05 | 24h |

### Contests to Create

| Contest | Purpose | Game Selection |
|---------|---------|----------------|
| Contest A | Main lifecycle (A-01→A-09) + leaderboard tests | NBA/NFL game 24-72h out |
| Contest B | Secondary market tests (A-17→A-21) + B-02/B-03 | Same or different game, must stay unsettled through Day 1 |
| Contest C | Void test (A-05, B-01) | Game whose start_time is soon (or just passed) — wait 24h for void cooldown |

---

## REVISION LOG

| Date | Change |
|------|--------|
| 2026-04-22 | v2 plan created. Supersedes v1 (webhook-based). Restructured for ospex-indexer: added Phase C (indexer-specific), removed aspirational agent integration (old Phase D), added pending_events/source_block/reconcile/backfill tests, incorporated future-contests-only constraint, documented all 25 handlers with exact Supabase table targets from indexer source code. |
