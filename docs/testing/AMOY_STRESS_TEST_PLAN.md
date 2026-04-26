# Amoy Stress Test Plan v4 — R4 contracts (post-redeploy 2026-04-25)

Status: **R4 CONTRACTS DEPLOYED — TEST CYCLE STARTING.** R4 contracts deployed 2026-04-25 at block 37285105. Supabase amoy data wiped, indexer config updated to R4 addresses, indexer caught up to chain head. Awaiting Phase 1 game selection approval.

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

### Events Explicitly NOT Handled by Indexer

The contracts emit 27 distinct CoreEventEmitted event types. The indexer handles 25. Two are intentionally excluded:

| Event | Emitted By | Reason Not Handled |
|-------|-----------|-------------------|
| `LEADERBOARD_FUNDED` | TreasuryModule | Internal accounting event. Prize pool state is already captured via `rpc_user_registered` (which increments prize_pool on USER_REGISTERED). No additional projected row needed. |
| `LEADERBOARD_ENTRY_FEE_PROCESSED` | TreasuryModule | Fee-processing detail event. Entry fee amount is already stored in `leaderboards.entry_fee` and reflected in prize_pool updates. No consumer needs this event separately. |

These events DO land in chain_events if the indexer encounters them (the main loop inserts all CoreEventEmitted logs), but no handler dispatches — the indexer logs a `No handler registered` warning. This is expected. Phase A does NOT test these two events.

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
| `chain_events` row exists | event_type="MIN_NONCE_UPDATED", tx_hash matches | |
| `maker_nonce_floors` row exists | maker=MAKER, source_block = tx block | |
| `indexer_cursor.last_confirmed_block` advanced | >= tx block - 128 (confirmation depth) | |
| `pending_events` count for this event | 0 | |
| Indexer logs clean | No errors in last 50 lines | |

**Pass/Fail:**

**Evidence:**

**Notes:** If ANY check fails, stop. Diagnose the indexer before proceeding. Do not burn LINK on A-01 until the canary passes. The canary uses contestId=999 (doesn't need to exist — raiseMinNonce doesn't validate the contest).

---

## PHASE A: HANDLER COVERAGE

**Goal:** Fire each of the 25 handled CoreEventEmitted events at least once and verify the indexer writes correct Supabase state. (2 additional events — LEADERBOARD_FUNDED, LEADERBOARD_ENTRY_FEE_PROCESSED — are intentionally unhandled; see Architecture Context.)

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

### Priority 2 — Speculation + Commitment Lifecycle (Track 1)

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
- `chain_events` row: event_type="LEADERBOARD_CREATED"
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
- `chain_events` row: event_type="LEADERBOARD_PRIZE_CLAIMED"
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
- `chain_events` row: event_type="SALE_PROCEEDS_CLAIMED"
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

**PR #11-13 commitment invalidation check:** After this test, query commitments for this maker/speculation_key. If indexer-created commitment rows exist from A-06 matches (which used nonces 1-2), verify `nonce_invalidated=true` on those rows. This confirms the MIN_NONCE_UPDATED handler's best-effort invalidation works on indexer-created rows, not just agent-created ones.

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
SELECT event_type, COUNT(*)
FROM chain_events
WHERE network = 'amoy' AND tx_hash = '<TX_HASH>'
GROUP BY event_type;
```
Compare against the expected events for that test (e.g., A-06 expects exactly 3: SPECULATION_CREATED, COMMITMENT_MATCHED, POSITION_MATCHED_PAIR).

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
