# Amoy Stress Test Plan

Status: **RESET — Re-executing from zero with ospex-indexer**

## Context

The indexing infrastructure has been replaced. The push-based webhook (ospex-fdb via Alchemy) is being replaced by a pull-based indexer (ospex-indexer via eth_getLogs polling). All previous test results validated the webhook and are archived in the session log. This plan is being re-executed from A-01 against the new indexer.

**Indexer details:** ospex-indexer deployed on Heroku (worker dyno), polls Alchemy every 10s, 10-block chunks (free tier limit), 128-block confirmation depth. All 25 CoreEventEmitted event types handled.

**Validation additions for indexer:** Every test should confirm:
- `source_block IS NOT NULL` on projected rows (proves indexer wrote them, not webhook)
- `chain_events` row exists with correct payload
- No rows in `pending_events` after test completes
- No errors in `heroku logs --app ospex-indexer`

## Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| Amoy RPC access | READY | Alchemy endpoint in .env |
| Deployer key | READY | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` — 37.8 POL, ~1B USDC, 5.32 LINK |
| Test wallet: MAKER | PENDING | Need to generate and fund |
| Test wallet: TAKER | PENDING | Need to generate and fund |
| USDC approved for PositionModule | PENDING | Each wallet must `approve(PositionModule, max)` |
| USDC approved for TreasuryModule | PENDING | Each wallet must `approve(TreasuryModule, max)` |
| USDC approved for SecondaryMarketModule | PENDING | Buyer wallet must `approve(SecondaryMarketModule, max)` |
| LINK approved for OracleModule | READY | Deployer already approved |
| Forge/cast installed | READY | cast v1.6.0-nightly |
| Supabase read access | READY | via ospex-fdb .env |
| Contest ID counter | 0 | No existing contests — clean slate |

### Test Wallets

Generate two wallets for maker/taker roles. The deployer will fund them with USDC and POL.

```
MAKER_PRIVATE_KEY=<to be generated>
TAKER_PRIVATE_KEY=<to be generated>
```

MockERC20 has a permissionless `mint(address,uint256)` function, so any wallet can mint USDC to itself. POL for gas must be transferred from the deployer.

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
| Void Cooldown | 1 day (86400s) |
| Contest Creation Fee | 1.00 USDC |
| Speculation Creation Fee | 0.50 USDC (split maker/taker: 0.25 each) |
| Leaderboard Creation Fee | 0.50 USDC |
| LINK per oracle call | 0.004 LINK |
| Chainlink Subscription ID | 416 |
| DON ID | `fun-polygon-amoy-1` |
| ODDS_SCALE | 100 |
| EIP-712 Domain (MatchingModule) | name="Ospex", version="1", chainId=80002 |
| EIP-712 Domain (OracleModule) | name="OspexOracle", version="1", chainId=80002 |

### Script Approvals (Pre-signed, expire 2026-07-19)

| Purpose | Script Hash | Signature |
|---------|-------------|-----------|
| VERIFY (0) | `0x01c48e15068b68b7d5986d5013edd83a243ac31a761567e9db0e57b513c26c01` | `0x1c5c2a40b19a56ed5c7ed0b5f3cd999232018de58b657ef168db9bf4badf820f7dc21fc4feba4c08ec8a4a0f4b8ccdd4685057ca12af049cc9d48084556c846b1c` |
| MARKET_UPDATE (1) | `0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4` | `0x12f15b125eae373d76fb154ef6e42b60a8c93c4c99dc82c0c22d566b9ff7376041e3e096018ffbd3f6095d8c3cd0deab4d71b109ae29e29dceb1532371cef86d1c` |
| SCORE (2) | `0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd` | `0x860e0611a506988a66a686558f2bf3818decbfd8f22c507d122473ef9699ae175477ee99c648cdda7dff7c37b3483f606f1f0458b90436471bb314943a5e43041b` |

---

## PHASE A: HANDLER COVERAGE

Goal: every event handler fires at least once and produces expected Supabase state.

Tests are ordered so earlier ones set up state for later ones (minimal repeated setup).

---

### A-01: CONTEST_CREATED

**Description:** Create a contest via `OracleModule.createContestFromOracle`. This triggers a Chainlink Functions call; the callback verifies the contest and emits CONTEST_CREATED.

**Prerequisites:** Deployer has LINK approved for OracleModule, USDC approved for TreasuryModule.

**Action:**
```bash
# From deployer wallet. The createContestFromOracle function:
# 1. Charges LINK (0.004) for the Chainlink call
# 2. Charges 1.00 USDC contest creation fee
# 3. Creates the contest in ContestModule (Unverified status)
# 4. Emits CONTEST_CREATED event via CoreEventEmitted
# 5. Sends Chainlink Functions request; callback will verify

cast send 0x08d1F10572071271983CE800ad63663f71A71512 \
  "createContestFromOracle((string,string,string,string,bytes,uint64,uint32),bytes32,bytes32,((bytes32,uint8,uint8,uint16,uint64),bytes,(bytes32,uint8,uint8,uint16,uint64),bytes,(bytes32,uint8,uint8,uint16,uint64),bytes))" \
  "(\"RD_TEST_001\",\"SP_TEST_001\",\"JO_TEST_001\",\"<VERIFY_JS_SOURCE>\",\"<ENCRYPTED_SECRETS>\",416,300000)" \
  "0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4" \
  "0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd" \
  "((0x01c48e15068b68b7d5986d5013edd83a243ac31a761567e9db0e57b513c26c01,0,0,1,1784435872),0x1c5c2a40b19a56ed5c7ed0b5f3cd999232018de58b657ef168db9bf4badf820f7dc21fc4feba4c08ec8a4a0f4b8ccdd4685057ca12af049cc9d48084556c846b1c,(0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4,1,0,1,1784436310),0x12f15b125eae373d76fb154ef6e42b60a8c93c4c99dc82c0c22d566b9ff7376041e3e096018ffbd3f6095d8c3cd0deab4d71b109ae29e29dceb1532371cef86d1c,(0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd,2,0,1,1784437583),0x860e0611a506988a66a686558f2bf3818decbfd8f22c507d122473ef9699ae175477ee99c648cdda7dff7c37b3483f606f1f0458b90436471bb314943a5e43041b)" \
  --private-key $PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

Note: The `VERIFY_JS_SOURCE` must be the exact source code from `https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestCreation.js` — its keccak256 must equal the verify scriptHash. The `ENCRYPTED_SECRETS` is the encrypted secrets URL for Amoy (from offchain-secrets files).

**Expected on-chain outcome:**
- ContestModule.s_contestIdCounter() increments to 1
- Contest struct stored with status=Unverified, rundownId="RD_TEST_001", etc.
- CoreEventEmitted with eventType=CONTEST_CREATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="CONTEST_CREATED", entity_type="contest", entity_id="1"
- `contests` row: contest_id=1, status="unverified", rundown_id="RD_TEST_001", sportspage_id="SP_TEST_001", jsonodds_id="JO_TEST_001", network="amoy"

**Pass/Fail:** NOT TESTED (reset)

**Notes:** Three contests created. Contests 1-2 (MLB) created successfully but oracle verification failed (see notes below). Contest 3 (NBA Raptors @ Cavaliers, jsonodds=0aa3aa26) created and verified. Tx: `0x5a88bd2a...`, block 36999394. Gas: 1,189,749. Helper script at `scripts/stress-test/create-contest.js` handles the complex ABI encoding. Gas limit must be ≥2,500,000 for the Chainlink Functions router.

**FINDING — MLB oracle verification failure:** The `contestCreation.js` verify script only processes games with `STATUS_SCHEDULED`. Contests 1-2 failed because: contest 1 (Tigers @ Red Sox) was `STATUS_FINAL`, contest 2 (Astros @ Guardians) was `STATUS_IN_PROGRESS`. The fallback path silently leaves all return values as `undefined`, which becomes NaN in the BigInt conversion: `RangeError: The number NaN cannot be converted to a BigInt`. This is sport-agnostic — any game that's not pre-start will fail. NBA game worked because we submitted before its start time.

---

### A-02: CONTEST_VERIFIED

**Description:** The Chainlink callback from A-01 verifies the contest (sets leagueId and startTime). This fires CONTEST_VERIFIED.

**Prerequisites:** A-01 completed (contest exists in Unverified state). Chainlink callback must arrive.

**Action:** Wait for Chainlink Functions callback (~30-60 seconds on Amoy). The callback decodes the response, extracts leagueId and startTime, and calls `ContestModule.setContestLeagueIdAndStartTime`.

**Expected on-chain outcome:**
- Contest status changes to Verified
- Contest has leagueId set (e.g., NBA=4) and startTime set
- CoreEventEmitted with eventType=CONTEST_VERIFIED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="CONTEST_VERIFIED"
- `contests` row updated: status="verified", start_time set, league_id set

**Pass/Fail:** NOT TESTED (reset)

**Notes:** Chainlink callback arrived ~6 blocks after creation (block 36999400). Contest 3 verified with start_time=2026-04-20T23:00:00Z. Callback latency ~14 seconds on Amoy. league_id stored as "unknown" in Supabase — the indexer LEAGUE_ID_MAP may not cover the numeric value returned by the oracle.

---

### A-03: CONTEST_MARKETS_UPDATED

**Description:** Update market data (odds, lines) for the verified contest via `OracleModule.updateContestMarketsFromOracle`.

**Prerequisites:** A-02 completed (contest is Verified).

**Action:**
```bash
# The market update source JS must hash to 0x7f5ce705...
# Fetch it from the GitHub raw URL and pass as the source parameter
cast send 0x08d1F10572071271983CE800ad63663f71A71512 \
  "updateContestMarketsFromOracle(uint256,string,bytes,uint64,uint32)" \
  1 \
  "<MARKET_UPDATE_JS_SOURCE>" \
  "<ENCRYPTED_SECRETS>" \
  416 \
  300000 \
  --private-key $PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

Wait for Chainlink callback to deliver market data.

**Expected on-chain outcome:**
- Contest market data populated (moneyline odds, spread line, total line, spread/total odds)
- CoreEventEmitted with eventType=CONTEST_MARKETS_UPDATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="CONTEST_MARKETS_UPDATED"
- `contests` row updated: ml_upper_odds, ml_lower_odds, spread_line, total_line, spread_upper_odds, spread_lower_odds, over_odds, under_odds all populated

**Pass/Fail:** NOT TESTED

**Notes:** Market data returned by Chainlink is packed into a uint256. The indexer decodes the packed fields. Verify all 8 fields are correct. Skipped in this session — not required for matching (commitments specify their own odds). Can be tested independently.

---

### A-04: COMMITMENT_MATCHED + SPECULATION_CREATED + POSITION_MATCHED_PAIR

**Description:** Match a commitment (first fill on this contest/scorer/line creates the speculation). This single transaction fires 3 events: COMMITMENT_MATCHED, SPECULATION_CREATED, and POSITION_MATCHED_PAIR.

**Prerequisites:** 
- A-02 completed (verified contest with known contestId)
- MAKER wallet has USDC, approved PositionModule and TreasuryModule
- TAKER wallet has USDC, approved PositionModule and TreasuryModule

**Action:**
1. MAKER signs an EIP-712 OspexCommitment off-chain:
   ```
   maker: MAKER_ADDRESS
   contestId: 1
   scorer: 0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC (MoneylineScorer)
   lineTicks: 0 (moneyline has no line)
   positionType: 0 (Upper = Away)
   oddsTick: 191 (1.91 odds)
   riskAmount: 10000000 (10 USDC, must be multiple of 100)
   nonce: 1
   expiry: <now + 1 hour>
   ```

2. TAKER calls `MatchingModule.matchCommitment(commitment, signature, takerDesiredRisk)`:
   ```bash
   # takerDesiredRisk = makerProfit = (10000000 * 91) / 100 = 9100000 (9.1 USDC)
   cast send 0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9 \
     "matchCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256),bytes,uint256)" \
     "(MAKER_ADDRESS,1,0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC,0,0,191,10000000,1,EXPIRY)" \
     "SIGNATURE_HEX" \
     9100000 \
     --private-key $TAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
   ```

**Expected on-chain outcome:**
- SpeculationModule counter increments (speculationId = 1)
- Maker's USDC decreases by 10.25 USDC (10 risk + 0.25 creation fee)
- Taker's USDC decreases by 9.35 USDC (9.1 risk + 0.25 creation fee)
- Position recorded for both maker (Upper, risk=10, profit=9.1) and taker (Lower, risk=9.1, profit=10)

**Expected Supabase outcome:**
- `chain_events`: 3 rows (COMMITMENT_MATCHED, SPECULATION_CREATED, POSITION_MATCHED_PAIR)
- `speculations` row: speculation_id=1, contest_id=1, market_type="moneyline", status="open", line_ticks=0
- `positions` row (maker): speculation_id=1, user=MAKER, position_type="upper", risk_amount="10000000", profit_amount="9100000"
- `positions` row (taker): speculation_id=1, user=TAKER, position_type="lower", risk_amount="9100000", profit_amount="10000000"
- `position_fills` row: commitment_hash, maker, taker, odds_tick=191, fill_maker_risk
- `commitments` row: status updated via fill_commitment RPC

**Pass/Fail:** NOT TESTED (reset) (with findings)

**Notes:** Four match transactions executed (nonces 1-4, totaling 20 USDC maker risk / 18.2 USDC taker risk). On-chain: all 4 fills accumulated correctly. Supabase: only 2 of 4 fills indexed due to cascading failure (see FINDINGS below). Helper script at `scripts/stress-test/match-commitment.js`.

**FINDING — Firebase Functions scorer config mismatch:** The SPECULATION_CREATED handler crashed with `Unknown scorer address: 0x4cdf8cc2b0dcae9bfff34846e2bcb3a88675edec`. Root cause: `functions.config().scorers.*` had OLD deployment addresses. Fixed by running `firebase functions:config:set scorers.moneyline="0x4CDf8cc2..." scorers.spread="0x36F3f4..." scorers.total="0xB814f3..."` and redeploying. The crash returned 500 to the webhook, which caused Alchemy to auto-pause the webhook after repeated failures.

**FINDING — Alchemy webhook auto-pause:** After receiving multiple 500 responses, Alchemy suspended the webhook ("failed to return a 2xx HTTP status over 24 hours"). Events from 2 of 4 match txs were permanently lost — Alchemy does not replay after unpausing. Required manual insertion of the missing speculation row to unblock the FK dependency, then a fresh match tx to verify the pipeline.

**FINDING — Cascading FK violation:** After the scorer fix, POSITION_MATCHED_PAIR failed with `fk_position_speculation` violation because the SPECULATION_CREATED row was never created (lost during the crash). Had to manually insert the speculation row via Supabase REST API.

---

### A-05: CONTEST_SCORES_SET

**Description:** Score the contest after it has started and finished.

**Prerequisites:** A-02 completed. Contest start time must have passed.

**Action:** Used helper script `scripts/stress-test/score-contest.js` to call `scoreContestFromOracle` with the scoring JS source.

**Expected on-chain outcome:**
- Contest awayScore and homeScore set
- Contest status = Scored
- CoreEventEmitted with eventType=CONTEST_SCORES_SET fires

**Expected Supabase outcome:**
- `chain_events` row: event_name="CONTEST_SCORES_SET"
- `contests` row: status="scored", away_score and home_score populated, scored_at set
- `speculations` rows: scored_at field populated (denormalized)

**Pass/Fail:** NOT TESTED (reset)

**Notes:** First scoring attempt failed with "Error: Rundown API error:" (transient API failure). Second attempt succeeded — Chainlink callback delivered scores correctly. Contest 3: away_score=105 (Raptors), home_score=115 (Cavaliers). Supabase updated: contest_status="scored", scored_at="2026-04-21T05:53:28Z".

---

### A-06: SPECULATION_SETTLED

**Description:** Settle the speculation after the contest is scored.

**Prerequisites:** A-05 completed (contest scored). Speculation exists and is Open.

**Action:**
```bash
# Permissionless — anyone can call this
cast send 0x6f32665DD97482e6C89D8B9bf025d483184F5553 \
  "settleSpeculation(uint256)" \
  1 \
  --private-key $PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Speculation status changes to Closed
- winSide determined (e.g., Away=1, Home=2, depending on scores and scorer logic)
- CoreEventEmitted with eventType=SPECULATION_SETTLED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="SPECULATION_SETTLED"
- `speculations` row: status="closed", win_side populated (e.g., "away" or "home")

**Pass/Fail:** NOT TESTED (reset)

**Notes:** Tx `0xdf9406f3...`, gas 96,099. Speculation settled with win_side="home" (Cavaliers won 115-105). Supabase updated: speculation_status="closed", win_side="home", settled_at="2026-04-21T05:54:14Z".

---

### A-07: POSITION_CLAIMED

**Description:** Winner claims their position payout.

**Prerequisites:** A-06 completed (speculation settled with a winner).

**Action:** Taker (Lower/Home) claims — Home won.
```bash
cast send 0xf769BEC6960Ed367320549FdD5A30f7C687DB2ee \
  "claimPosition(uint256,uint8)" \
  1 \
  1 \
  --private-key $TAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Winner receives risk + profit USDC
- Position marked as claimed on-chain
- CoreEventEmitted with eventType=POSITION_CLAIMED fires

**Expected Supabase outcome:**
- `chain_events` row: event_name="POSITION_CLAIMED"
- `positions` row: claimed=true, claimed_amount populated, claimed_at timestamp set

**Pass/Fail:** NOT TESTED (reset)

**Notes:** Tx `0x9fb9bbfb...`, gas 67,592. Taker claimed 38,200,000 (38.2 USDC = 18.2 risk + 20.0 profit). USDC transferred from PositionModule to taker. Supabase: claimed=true, claimed_amount=38200000, claimed_at="2026-04-21T05:54:37Z". Note: Supabase position amounts reflect only 2 of 4 fills (7 USDC risk vs 20 USDC on-chain) due to earlier event loss, but the claimed_amount correctly reflects the on-chain payout.

---

### A-08: MIN_NONCE_UPDATED

**Description:** Raise min nonce for a speculation key to invalidate outstanding commitments.

**Prerequisites:** None beyond a funded wallet.

**Action:**
```bash
# MAKER raises min nonce for contestId=1, MoneylineScorer, lineTicks=0
cast send 0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9 \
  "raiseMinNonce(uint256,address,int32,uint256)" \
  1 \
  0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC \
  0 \
  5 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- s_minNonces[maker][speculationKey] = 5
- CoreEventEmitted with eventType=MIN_NONCE_UPDATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="MIN_NONCE_UPDATED"
- `maker_nonce_floors` row: maker=MAKER_ADDRESS, speculation_key=<hash>, min_nonce=5

**Pass/Fail:**

**Notes:** Already validated in prior session. Running as regression.

---

### A-09: COMMITMENT_CANCELLED

**Description:** Cancel a specific commitment by hash.

**Prerequisites:** MAKER has a commitment (no need for it to be on-chain, just signs one and cancels it).

**Action:**
```bash
# MAKER cancels a commitment they signed
# The commitment struct must be passed (contract hashes it to determine which to cancel)
cast send 0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9 \
  "cancelCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256))" \
  "(MAKER_ADDRESS,1,0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC,0,0,191,10000000,2,EXPIRY)" \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- s_cancelledCommitments[commitmentHash] = true
- CoreEventEmitted with eventType=COMMITMENT_CANCELLED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="COMMITMENT_CANCELLED"
- `commitments` row (if exists): status="cancelled"

**Pass/Fail:**

**Notes:** The commitment doesn't need to have been matched — cancelling prevents future matching.

---

### A-10: LEADERBOARD_CREATED

**Description:** Create a new leaderboard.

**Prerequisites:** Deployer or any wallet with USDC approved for TreasuryModule.

**Action:**
```bash
# Create a leaderboard with:
#   entryFee: 5 USDC (5000000)
#   startTime: now + 5 minutes
#   endTime: now + 2 days
#   safetyPeriodDuration: 1 hour (3600)
#   roiSubmissionWindow: 1 hour (3600)
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "createLeaderboard(uint256,uint32,uint32,uint32,uint32)" \
  5000000 \
  START_TIME \
  END_TIME \
  3600 \
  3600 \
  --private-key $PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Leaderboard ID 1 created
- 0.50 USDC creation fee charged
- CoreEventEmitted with eventType=LEADERBOARD_CREATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_CREATED"
- `leaderboards` row: leaderboard_id=1, entry_fee="5000000", start_time, end_time, safety_period_duration=3600, roi_submission_window=3600

**Pass/Fail:**

**Notes:**

---

### A-11: LEADERBOARD_SPECULATION_ADDED

**Description:** Add a speculation to the leaderboard's eligible list.

**Prerequisites:** A-10 (leaderboard exists), A-04 (speculation exists).

**Action:**
```bash
# Only leaderboard creator can call this
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "addLeaderboardSpeculation(uint256,uint256)" \
  1 \
  1 \
  --private-key $PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Speculation 1 registered for leaderboard 1
- CoreEventEmitted with eventType=LEADERBOARD_SPECULATION_ADDED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_SPECULATION_ADDED"
- `leaderboard_speculations` row: leaderboard_id=1, speculation_id=1

**Pass/Fail:**

**Notes:**

---

### A-12: USER_REGISTERED

**Description:** Register a user for the leaderboard with a declared bankroll.

**Prerequisites:** A-10 (leaderboard exists), user has USDC for entry fee.

**Action:**
```bash
# MAKER registers for leaderboard 1 with bankroll of 100 USDC
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "registerUser(uint256,uint256)" \
  1 \
  100000000 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- User registered for leaderboard 1
- Entry fee (5 USDC) charged and added to prize pool
- CoreEventEmitted with eventType=USER_REGISTERED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="USER_REGISTERED"
- `leaderboard_registrations` row: leaderboard_id=1, user=MAKER_ADDRESS, declared_bankroll="100000000"
- `leaderboards` row: participants incremented, prize_pool updated

**Pass/Fail:**

**Notes:**

---

### A-13: LEADERBOARD_POSITION_ADDED

**Description:** Register a position for the leaderboard.

**Prerequisites:** A-11 (speculation added to leaderboard), A-12 (user registered), A-04 (user has position on that speculation). Leaderboard must be active (after startTime).

**Action:**
```bash
# MAKER registers their position (Upper) on speculation 1 for leaderboard 1
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "registerPositionForLeaderboard(uint256,uint8,uint256)" \
  1 \
  0 \
  1 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- LeaderboardPosition created (risk/profit amounts may be capped by maxBetPercentage)
- CoreEventEmitted with eventType=LEADERBOARD_POSITION_ADDED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_POSITION_ADDED"
- `leaderboard_positions` row: leaderboard_id=1, speculation_id=1, user=MAKER, risk_amount, profit_amount, position_type="upper"
- `leaderboards` row: total_positions incremented

**Pass/Fail:**

**Notes:** Must be called after leaderboard startTime. If startTime is in the future, wait.

---

### A-14: LEADERBOARD_ROI_SUBMITTED

**Description:** Submit ROI for the leaderboard after the submission window opens.

**Prerequisites:** A-13 (position added), all speculations the user has positions on must be settled, safety period elapsed, ROI window open.

**Action:**
```bash
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "submitLeaderboardROI(uint256)" \
  1 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- ROI calculated and stored
- CoreEventEmitted with eventType=LEADERBOARD_ROI_SUBMITTED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_ROI_SUBMITTED"
- `leaderboard_registrations` row: roi updated

**Pass/Fail:**

**Notes:** Requires waiting for: endTime + safetyPeriodDuration. This test has significant time dependencies.

---

### A-15: LEADERBOARD_NEW_HIGHEST_ROI

**Description:** When a user submits the highest ROI, this event fires.

**Prerequisites:** A-14 completed — if this is the first (or highest) ROI submission, it fires automatically.

**Action:** Happens automatically during A-14 if the submitted ROI is the new highest.

**Expected on-chain outcome:**
- Winner array updated
- CoreEventEmitted with eventType=LEADERBOARD_NEW_HIGHEST_ROI fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_NEW_HIGHEST_ROI"
- `leaderboard_winners` row: leaderboard_id=1, winner=MAKER_ADDRESS, roi
- `leaderboard_registrations` and `leaderboards` updated

**Pass/Fail:**

**Notes:** Fires alongside A-14 in the same transaction.

---

### A-16: LEADERBOARD_PRIZE_CLAIMED

**Description:** Winner claims their prize share.

**Prerequisites:** A-15 (winner determined), ROI window closed.

**Action:**
```bash
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "claimLeaderboardPrize(uint256)" \
  1 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Prize share transferred to winner
- CoreEventEmitted with eventType=LEADERBOARD_PRIZE_CLAIMED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LEADERBOARD_PRIZE_CLAIMED"
- `leaderboard_registrations`: claimed flag set
- `leaderboard_winners`: claimed flag set
- `leaderboards`: claimed count updated, prize pool snapshot

**Pass/Fail:**

**Notes:** Requires endTime + safetyPeriodDuration + roiSubmissionWindow to have elapsed.

---

### A-17: POSITION_LISTED

**Description:** List a position for sale on the secondary market.

**Prerequisites:** A-04 (user has a position). Position must be on an unsettled speculation.

**Action:**
```bash
# MAKER lists their Upper position on speculation 1 for 12 USDC
# riskAmount and profitAmount define the slice being sold
cast send 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "listPositionForSale(uint256,uint8,uint256,uint256,uint256)" \
  1 \
  0 \
  12000000 \
  10000000 \
  9100000 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- SaleListing created with price=12 USDC, riskAmount=10, profitAmount=9.1
- CoreEventEmitted with eventType=POSITION_LISTED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="POSITION_LISTED"
- `secondary_market_listings` row: speculation_id=1, seller=MAKER, position_type="upper", price="12000000", risk_amount="10000000", profit_amount="9100000", status="active"

**Pass/Fail:**

**Notes:** Must run on a SEPARATE speculation/contest that hasn't been settled yet. The speculation from the main test flow (A-04) may be settled by the time we reach this test. **Strategy:** Create a second contest+speculation specifically for secondary market tests.

---

### A-18: LISTING_UPDATED

**Description:** Update the price/amounts on an active listing.

**Prerequisites:** A-17 (active listing exists).

**Action:**
```bash
# MAKER updates their listing: new price = 11 USDC, keep risk/profit same
cast send 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "updateListing(uint256,uint8,uint256,uint256,uint256)" \
  SPECULATION_ID \
  0 \
  11000000 \
  0 \
  0 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Listing price updated to 11 USDC
- CoreEventEmitted with eventType=LISTING_UPDATED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LISTING_UPDATED"
- `secondary_market_listings` row: price updated to "11000000"

**Pass/Fail:**

**Notes:**

---

### A-19: POSITION_SOLD + POSITION_TRANSFERRED

**Description:** Buyer purchases the listed position. This fires both POSITION_SOLD and POSITION_TRANSFERRED.

**Prerequisites:** A-17 (listing active), TAKER has USDC approved for SecondaryMarketModule.

**Action:**
```bash
# Get listing hash first
LISTING_HASH=$(cast call 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "getListingHash(uint256,address,uint8)(bytes32)" \
  SPECULATION_ID MAKER_ADDRESS 0 --rpc-url $AMOY_RPC_URL)

# TAKER buys the full position
cast send 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "buyPosition(uint256,address,uint8,uint256,bytes32)" \
  SPECULATION_ID \
  MAKER_ADDRESS \
  0 \
  10000000 \
  $LISTING_HASH \
  --private-key $TAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Position transferred from MAKER to TAKER
- Listing marked sold (or partially sold)
- TAKER's USDC decreases by purchase price
- Sale proceeds credited to MAKER (pending claim)
- CoreEventEmitted fires: POSITION_SOLD and POSITION_TRANSFERRED

**Expected Supabase outcome:**
- `chain_events`: 2 rows (POSITION_SOLD, POSITION_TRANSFERRED)
- `secondary_market_listings` row: status="sold" (or remaining amounts reduced for partial)
- `positions`: MAKER's position reduced, TAKER's position created/increased with acquiredViaSecondaryMarket flag

**Pass/Fail:**

**Notes:**

---

### A-20: LISTING_CANCELLED

**Description:** Cancel an active listing.

**Prerequisites:** An active listing exists (create a new listing for this test if needed).

**Action:**
```bash
# First create a new listing, then cancel it
cast send 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "cancelListing(uint256,uint8)" \
  SPECULATION_ID \
  0 \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Listing removed/cancelled
- CoreEventEmitted with eventType=LISTING_CANCELLED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="LISTING_CANCELLED"
- `secondary_market_listings` row: status="cancelled"

**Pass/Fail:**

**Notes:**

---

### A-21: SALE_PROCEEDS_CLAIMED

**Description:** Seller claims accumulated proceeds from sales.

**Prerequisites:** A-19 completed (MAKER has pending proceeds from the sale).

**Action:**
```bash
cast send 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "claimSaleProceeds()" \
  --private-key $MAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Pending proceeds transferred to MAKER
- CoreEventEmitted with eventType=SALE_PROCEEDS_CLAIMED fires

**Expected Supabase outcome:**
- `chain_events` row: event_type="SALE_PROCEEDS_CLAIMED"
- No additional table writes (handler is no-op beyond chain_events)

**Pass/Fail:**

**Notes:** Handler is documented as best-effort/no-op for the target table.

---

### A-22: CONTEST_VOIDED

**Description:** Void a contest by settling a speculation after the void cooldown has elapsed without scores.

**Prerequisites:** A contest must exist in Verified state with a start time in the past, AND the void cooldown (1 day) must have elapsed since start time, AND the contest must NOT be scored.

**Action:**
```bash
# Create a new contest specifically for voiding (with a start time that's already past)
# Wait 1 day after start time
# Call settleSpeculation on any speculation attached to it — this triggers auto-void

cast send 0x6f32665DD97482e6C89D8B9bf025d483184F5553 \
  "settleSpeculation(uint256)" \
  SPECULATION_ID_FOR_VOID \
  --private-key $PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Contest voided (status = Voided via ContestModule.voidContest)
- Speculation winSide = Void (value 6)
- Speculation status = Closed
- CoreEventEmitted fires: CONTEST_VOIDED and SPECULATION_SETTLED (winSide=Void)

**Expected Supabase outcome:**
- `chain_events`: rows for CONTEST_VOIDED and SPECULATION_SETTLED
- `contests` row: status="voided"
- `speculations` row: status="closed", win_side="void"

**Pass/Fail:**

**Notes:** **Requires 1 day of real time passage.** Strategy: Create a contest early in testing with a near-past start time. After 24+ hours, return and trigger void. Document the expected completion time.

---

### A-23: SPREAD FULL LIFECYCLE

**Description:** Complete end-to-end spread market lifecycle: create contest, match with SpreadScorer, score contest, settle spread speculation, claim.

**Prerequisites:** Verified contest exists (can reuse contest from A-01/A-02 or create a new one). MAKER and TAKER funded.

**Action:**
1. MAKER signs commitment with:
   - scorer: `0x36F3f4A6757cB2E822A1AfCea0b3092fFcaE6c30` (SpreadScorerModule)
   - lineTicks: -30 (spread of -3.0, stored as 10x)
   - positionType: 0 (Upper = Away covers)
   - oddsTick: 191
2. TAKER matches the commitment
3. After contest scores, settle the spread speculation
4. Winner claims

**Expected on-chain outcome:**
- Speculation created with scorer=SpreadScorer, lineTicks=-30
- After scoring: winSide determined by comparing (awayScore - homeScore) against the spread line
  - If awayScore - homeScore > spread → Away covers → Upper wins
  - If awayScore - homeScore < spread → Home covers → Lower wins
  - If awayScore - homeScore == spread → Push

**Expected Supabase outcome:**
- `speculations` row: market_type="spread", line_ticks="-30" (or equivalent)
- `positions` rows for both sides with correct risk/profit
- After settlement: win_side reflects spread outcome
- After claim: claimed=true on winner's position

**Pass/Fail:**

**Notes:** Use a real game where we know the final margin to predict the outcome. Verifies SpreadScorerModule integration end-to-end.

---

### A-24: TOTAL FULL LIFECYCLE

**Description:** Complete end-to-end total (over/under) market lifecycle.

**Prerequisites:** Verified contest exists. MAKER and TAKER funded.

**Action:**
1. MAKER signs commitment with:
   - scorer: `0xB814f3779A79c6470a904f8A12670D1B13874fDE` (TotalScorerModule)
   - lineTicks: 2150 (total of 215.0, stored as 10x — check encoding per contract)
   - positionType: 0 (Upper = Over)
   - oddsTick: 191
2. TAKER matches the commitment
3. After contest scores, settle the total speculation
4. Winner claims

**Expected on-chain outcome:**
- Speculation created with scorer=TotalScorer, lineTicks=total line
- After scoring: winSide determined by comparing (awayScore + homeScore) against total
  - If total > line → Over wins (Upper)
  - If total < line → Under wins (Lower)
  - If total == line → Push

**Expected Supabase outcome:**
- `speculations` row: market_type="total", line_ticks set
- Full position lifecycle reflected in Supabase

**Pass/Fail:**

**Notes:** Use a game where combined score is known to predict over/under outcome.

---

### A-25: PUSH SETTLEMENT PATH

**Description:** Trigger a push outcome (neither side wins) and verify indexer handles it correctly.

**Prerequisites:** Need a spread or total that exactly matches the game outcome to produce a push.

**Action:**
- Create a spread speculation where lineTicks exactly matches the actual scoring margin
- OR create a total speculation where the total line exactly matches awayScore + homeScore
- Score the contest → settle → both sides should get their risk back

**Strategy:** Use a completed game where we know the exact margin. For example, if a game ended 110-105 (margin = 5), use lineTicks = -50 (spread of -5.0) for the favored team. This guarantees a push.

**Expected on-chain outcome:**
- Speculation settles with winSide = Push (value 5)
- Both positions can claim (each gets back exactly their riskAmount — no profit, no loss)

**Expected Supabase outcome:**
- `speculations` row: win_side="push"
- `positions` rows: both sides show claimed=true, claimed_amount = riskAmount (no profit)

**Pass/Fail:**

**Notes:** Push is a critical path that must be tested live. Leaderboard positions on pushed speculations DO count toward minBets (only TBD and Void are excluded). Verify this if running alongside leaderboard tests.

---

## PHASE B: HARDENING PATH VALIDATION

Goal: confirm specific fixes from the hardening cycle produce correct indexer state (or correct rejection).

---

### B-01: Post-Cooldown Match Rejection

**Description:** Attempt to match a commitment on a contest that has passed its void cooldown. Expected: transaction reverts with ContestPastCooldown.

**Prerequisites:** A contest exists where block.timestamp >= startTime + voidCooldown (1 day). This is the same contest we'll use for A-22. Must have a speculation to target OR create a new commitment against it.

**Action:**
```bash
# Attempt matchCommitment against the expired contest
# This should revert with MatchingModule__ContestPastCooldown
cast send 0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9 \
  "matchCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256),bytes,uint256)" \
  "(MAKER_ADDRESS,EXPIRED_CONTEST_ID,0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC,0,0,191,10000000,10,EXPIRY)" \
  "SIGNATURE_HEX" \
  9100000 \
  --private-key $TAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Transaction REVERTS with `MatchingModule__ContestPastCooldown()`
- No state change

**Expected Supabase outcome:**
- NO new rows in any table (transaction reverted)

**Pass/Fail:**

**Notes:** Runs after A-22 (requires same 1-day wait). Confirm revert selector matches expected error.

---

### B-02: Secondary Market Position Becomes Ineligible

**Description:** After buying a position on the secondary market, verify the buyer's position is flagged as acquired via secondary market.

**Prerequisites:** A-19 completed (position was sold to TAKER via secondary market).

**Action:** Query Supabase after A-19 completes.

**Expected Supabase outcome:**
- `positions` row for TAKER on the sold speculation: a field indicating `acquired_via_secondary_market = true` (or equivalent flag set by POSITION_TRANSFERRED handler)

**Pass/Fail:**

**Notes:** This is a read-only verification of A-19's outcome. The indexer's POSITION_TRANSFERRED handler should set this flag.

---

### B-03: Secondary Market Position Rejected from Leaderboard

**Description:** Attempt to register a secondary-market-acquired position for a leaderboard. Expected: transaction reverts with SecondaryMarketPositionIneligible.

**Prerequisites:** B-02 confirmed (TAKER has a secondary-market position). A leaderboard exists where that speculation is eligible. TAKER is registered for the leaderboard.

**Action:**
```bash
# TAKER (who acquired position via secondary market) tries to register it
cast send 0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37 \
  "registerPositionForLeaderboard(uint256,uint8,uint256)" \
  SPECULATION_ID \
  0 \
  LEADERBOARD_ID \
  --private-key $TAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Transaction REVERTS (RulesModule validation fails — secondary market position ineligible)
- No state change

**Expected Supabase outcome:**
- NO new `leaderboard_positions` row for TAKER

**Pass/Fail:**

**Notes:** The exact revert reason comes from RulesModule.validateLeaderboardPosition returning a non-Valid result, which LeaderboardModule propagates as a revert.

---

### B-04: Void Padding Fails (Min-Positions Outcome Filter)

**Description:** Register for a leaderboard with min_bets rule. Create positions on speculations that resolve as Void. Attempt ROI submission with insufficient non-void positions. Expected: revert.

**Prerequisites:** 
- Leaderboard with minBets > 1 set via RulesModule
- User registered with positions only on voided speculations

**Action:**
1. Create leaderboard with `setMinBets(leaderboardId, 3)` (requires 3 non-void positions)
2. Register user
3. Create positions on speculations that later void (insufficient non-void positions)
4. Attempt `submitLeaderboardROI` → should revert

**Expected on-chain outcome:**
- submitLeaderboardROI REVERTS (insufficient qualifying positions)

**Expected Supabase outcome:**
- No `leaderboard_registrations` ROI update

**Pass/Fail:**

**Notes:** Complex setup. Requires multiple voided speculations. May need to create a dedicated contest with short timing to trigger voids. **Deferred — requires multiple 1-day waits for voided contests.**

---

### B-05: maxBetPercentage Default Caps at 100%

**Description:** Register for leaderboard with bankroll=100 USDC. Create a position with 150 USDC risk. Verify leaderboard_positions shows capped risk of 100 USDC while positions table shows actual 150 USDC.

**Prerequisites:**
- Leaderboard exists with maxBetPercentage = 10000 (100% in BPS)
- User registered with bankroll = 100 USDC
- User has a position with risk > 100 USDC (i.e., 150 USDC)
- Speculation is registered for the leaderboard

**Action:**
1. Set maxBetPercentage on leaderboard: `RulesModule.setMaxBetPercentage(leaderboardId, 10000)`
2. User registers with bankroll 100 USDC (100000000 in 6 decimals)
3. User creates a large position (150 USDC risk) via matchCommitment
4. User registers position for leaderboard

**Expected on-chain outcome:**
- LeaderboardPosition created with capped riskAmount = 100 USDC (100000000)
- Underlying position still shows 150 USDC risk

**Expected Supabase outcome:**
- `leaderboard_positions` row: risk_amount = "100000000" (capped)
- `positions` row: risk_amount = "150000000" (actual)

**Pass/Fail:**

**Notes:** Verify the proportional scaling of profitAmount as well.

---

### B-06: MIN_NONCE_UPDATED Invalidates Commitments

**Description:** Post a commitment with nonce N. Raise min nonce above N. Verify commitment is invalidated. Attempt to match it — expected revert.

**Prerequisites:** MAKER wallet funded. A verified contest exists.

**Action:**
1. MAKER signs commitment with nonce=3
2. MAKER raises min nonce to 5: `raiseMinNonce(contestId, scorer, lineTicks, 5)`
3. TAKER attempts to match the nonce=3 commitment → should revert with NonceTooLow
4. Verify Supabase: commitment status shows nonce_invalidated (or equivalent)

**Expected on-chain outcome:**
- raiseMinNonce succeeds (A-08)
- matchCommitment REVERTS with `MatchingModule__NonceTooLow()`

**Expected Supabase outcome:**
- `maker_nonce_floors` row: min_nonce=5
- Matching attempt produces no new rows (reverted)
- If commitments table has the nonce=3 entry, it should be invalidated by the indexer

**Pass/Fail:**

**Notes:** The indexer's MIN_NONCE_UPDATED handler invalidates commitments in Supabase with nonce below the new floor. Verify this side effect.

---

### B-07: Oracle Failure Path

**Description:** Trigger an intentional oracle failure and verify no bad downstream state is produced. This is one of the highest-value live tests — mainnet risk is bad/missing callback behavior, not just happy paths.

**Prerequisites:** Deployer has LINK and USDC. Use a non-existent game ID that will cause the Chainlink Functions JS to error.

**Action:**
```bash
# Create a contest with invalid game IDs that the APIs won't recognize
# The verify JS will fail to find the game and return an error
cast send 0x08d1F10572071271983CE800ad63663f71A71512 \
  "createContestFromOracle(...)" \
  # Use rundownId="INVALID_000", sportspageId="INVALID_000", jsonoddsId="INVALID_000"
  # All other params (script approvals, LINK, etc.) are valid
```

**Expected on-chain outcome:**
- Contest IS created (with Unverified status — creation happens before the oracle call)
- Chainlink callback arrives with error bytes
- OracleRequestFailed event emitted
- Contest remains Unverified (never verified, never scored)
- No corrupt state — the contest exists but is inert

**Expected Supabase outcome:**
- `chain_events` row for CONTEST_CREATED (this fires at creation time, before callback)
- `contests` row: status="unverified" — stays this way permanently
- NO CONTEST_VERIFIED event (callback failed)
- Verify: no downstream speculations, positions, or other state from this contest

**Pass/Fail:** NOT TESTED (reset) (tested naturally, not intentionally)

**Notes:** Observed naturally during A-01 execution. Contests 1 and 2 (MLB) had oracle callbacks fail with `RangeError: The number NaN cannot be converted to a BigInt`. Both contests remain status="unverified" with no downstream state (no speculations, no positions). Contest 3 (NBA) created after the failures verified successfully — confirming oracle failures don't block subsequent calls. Additionally, a scoring attempt for contest 3 also triggered a transient Rundown API failure (ORACLE_REQUEST_FAILED emitted), followed by a successful retry — confirming the scoring failure path is also clean.

---

### B-08: Secondary Market Partial Buy

**Description:** Buy only a portion of a listed position (not the full amount). Verify the listing is correctly decremented and the partial transfer is indexed.

**Prerequisites:** MAKER has a position listed for sale (e.g., 10 USDC risk listed). TAKER has USDC approved for SecondaryMarketModule.

**Action:**
```bash
# Get listing hash
LISTING_HASH=$(cast call 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "getListingHash(uint256,address,uint8)(bytes32)" \
  SPECULATION_ID MAKER_ADDRESS 0 --rpc-url $AMOY_RPC_URL)

# TAKER buys only 4 USDC of the 10 USDC listing
cast send 0x0e7b7C218db7f0e34521833e98f0Af261D204aED \
  "buyPosition(uint256,address,uint8,uint256,bytes32)" \
  SPECULATION_ID \
  MAKER_ADDRESS \
  0 \
  4000000 \
  $LISTING_HASH \
  --private-key $TAKER_PRIVATE_KEY --rpc-url $AMOY_RPC_URL
```

**Expected on-chain outcome:**
- Partial transfer: 4 USDC risk moved from MAKER to TAKER
- Listing still active with remaining 6 USDC risk
- Purchase price proportionally calculated

**Expected Supabase outcome:**
- `secondary_market_listings` row: risk_amount decremented to remaining (6 USDC), status still "active"
- `positions`: MAKER risk reduced by 4, TAKER risk increased by 4
- Profit amounts scaled proportionally

**Pass/Fail:**

**Notes:** This tests the indexer's partial-sale handling, which involves BigInt arithmetic to decrement remaining amounts.

---

### B-09: Stale Listing Hash After Update

**Description:** Capture a listing hash, update the listing (changing the price), then attempt to buy with the old hash. Expected: revert.

**Prerequisites:** B-08 or A-17 completed (active listing exists).

**Action:**
1. Get listing hash before update
2. Update listing price via `updateListing`
3. Attempt `buyPosition` with the pre-update hash

**Expected on-chain outcome:**
- `buyPosition` REVERTS (listing hash mismatch — stale state)
- No state change beyond the listing update

**Expected Supabase outcome:**
- `secondary_market_listings`: price updated (from step 2)
- No POSITION_SOLD event (step 3 reverted)

**Pass/Fail:**

**Notes:** This is a critical safety check — the expectedHash parameter prevents front-running and stale-state purchases.

---

### B-10: Stale Listing Hash After Partial Buy

**Description:** After a partial buy changes the listing state, attempt another buy with the pre-partial-buy hash. Expected: revert.

**Prerequisites:** B-08 completed (partial buy reduced the listing).

**Action:**
1. Record listing hash before partial buy (from B-08 setup)
2. Execute partial buy (B-08)
3. Attempt another `buyPosition` using the hash from step 1

**Expected on-chain outcome:**
- Second `buyPosition` REVERTS (listing hash changed after partial buy)

**Expected Supabase outcome:**
- Only the first partial buy is reflected. Second attempt produces no state change.

**Pass/Fail:**

**Notes:** This validates that the listing hash changes after every partial fill, preventing stale-state exploitation.

---

### B-11: Cooldown Boundary Timing

**Description:** Test behavior at the exact cooldown boundary — attempt a match just before and just after the cooldown expires.

**Prerequisites:** A contest with known startTime. Must wait until block.timestamp is near startTime + voidCooldown (86400s).

**Action:**
1. Create a contest with a startTime that allows us to hit the boundary during testing
2. Just before cooldown expires: attempt matchCommitment → should SUCCEED
3. After cooldown expires: attempt matchCommitment → should REVERT with ContestPastCooldown

**Expected on-chain outcome:**
- Pre-boundary: match succeeds, position created
- Post-boundary: revert

**Pass/Fail:**

**Notes:** **Requires precise timing.** On Amoy (2-second blocks), the boundary is soft — we can't guarantee we hit the exact block. Strategy: attempt multiple rapid txs near the boundary and observe which succeed/fail. This is a live sanity check of the repo's integration test `MatchingPostCooldownRejection`.

---

### B-12: ROI Window Boundary Timing

**Description:** Test ROI submission at the exact boundaries of the submission window.

**Prerequisites:** A leaderboard with short timing (endTime=now+10min, safetyPeriod=60s, roiWindow=120s).

**Action:**
1. Before safety period ends: attempt `submitLeaderboardROI` → should REVERT
2. During ROI window: submit → should SUCCEED
3. After ROI window closes: attempt another submission → should REVERT (already submitted or window closed)

**Expected on-chain outcome:**
- Step 1: revert (too early)
- Step 2: success
- Step 3: revert (window closed or already submitted)

**Pass/Fail:**

**Notes:** Use short leaderboard timing to make this practical within a single session.

---

## PHASE C: CANONICAL-POSTURE STRESS

Goal: confirm Supabase stays in sync with chain under pressure.

---

### C-01: Rapid-Fire Events in Single Block

**Description:** Submit multiple matchCommitment transactions targeting the same block. Confirm all events index correctly and no ordering issues cause drift.

**Prerequisites:** Multiple commitments signed by MAKER for different amounts/nonces.

**Action:**
```bash
# Send 3 matchCommitment txs in rapid succession (same block if possible)
# Each with different takerDesiredRisk but same commitment (partial fills)
# OR different commitments (different nonces)

# Tx 1: match commitment A for 5 USDC
# Tx 2: match commitment B for 3 USDC
# Tx 3: match commitment C for 7 USDC

# Use --gas-price and timing to try to land in same block
for i in 1 2 3; do
  cast send ... --async
done
```

**Expected on-chain outcome:**
- All 3 transactions succeed in the same (or consecutive) block(s)
- 3 COMMITMENT_MATCHED + 3 POSITION_MATCHED_PAIR events (possibly 3 SPECULATION_CREATED if different scorer/lines)

**Expected Supabase outcome:**
- All events appear in `chain_events` with correct ordering (by log_index within block)
- `positions` table: all fills correctly accumulated (BigInt addition)
- No duplicate or missing rows

**Pass/Fail:**

**Notes:** On Amoy, block time is ~2 seconds. Sending all 3 within 2 seconds may land them in the same block. Even if they don't, the rapid-fire nature tests the indexer's ability to handle multiple events per webhook delivery.

---

### C-02: Cross-Table Consistency

**Description:** After running the complete contest lifecycle, query Supabase and verify row counts match expected totals.

**Prerequisites:** All Phase A tests completed.

**Action:** Run the following Supabase queries:
```sql
-- Count chain_events by type
SELECT event_type, COUNT(*) FROM chain_events WHERE network='amoy' GROUP BY event_type;

-- Count contests vs CONTEST_CREATED events
SELECT COUNT(*) FROM contests WHERE network='amoy';
SELECT COUNT(*) FROM chain_events WHERE network='amoy' AND event_type='CONTEST_CREATED';

-- Count speculations vs SPECULATION_CREATED events
SELECT COUNT(*) FROM speculations WHERE network='amoy';
SELECT COUNT(*) FROM chain_events WHERE network='amoy' AND event_type='SPECULATION_CREATED';

-- Count positions vs unique position tuples from fills
SELECT COUNT(*) FROM positions WHERE network='amoy';
```

**Expected outcome:**
- contests count == CONTEST_CREATED chain_events count
- speculations count == SPECULATION_CREATED chain_events count
- positions count matches unique (speculation_id, user, position_type) combinations from all POSITION_MATCHED_PAIR events

**Pass/Fail:**

**Notes:** Any mismatch indicates handler drift or missed events.

---

### C-03: Reconciliation Query

**Description:** Build and run a comprehensive reconciliation query comparing chain_events to target tables.

**Prerequisites:** Phase A completed.

**Action:** Execute a script that:
1. Counts chain_events by event_type
2. Counts rows in each target table
3. Compares and reports discrepancies

```sql
WITH event_counts AS (
  SELECT event_type, COUNT(*) as cnt
  FROM chain_events WHERE network='amoy'
  GROUP BY event_type
),
table_counts AS (
  SELECT 'contests' as tbl, COUNT(*) as cnt FROM contests WHERE network='amoy'
  UNION ALL
  SELECT 'speculations', COUNT(*) FROM speculations WHERE network='amoy'
  UNION ALL
  SELECT 'positions', COUNT(*) FROM positions WHERE network='amoy'
  UNION ALL
  SELECT 'commitments', COUNT(*) FROM commitments WHERE network='amoy'
  UNION ALL
  SELECT 'leaderboards', COUNT(*) FROM leaderboards WHERE network='amoy'
  UNION ALL
  SELECT 'leaderboard_speculations', COUNT(*) FROM leaderboard_speculations WHERE network='amoy'
  UNION ALL
  SELECT 'leaderboard_registrations', COUNT(*) FROM leaderboard_registrations WHERE network='amoy'
  UNION ALL
  SELECT 'leaderboard_positions', COUNT(*) FROM leaderboard_positions WHERE network='amoy'
  UNION ALL
  SELECT 'secondary_market_listings', COUNT(*) FROM secondary_market_listings WHERE network='amoy'
  UNION ALL
  SELECT 'maker_nonce_floors', COUNT(*) FROM maker_nonce_floors WHERE network='amoy'
)
SELECT * FROM event_counts;
SELECT * FROM table_counts;
```

**Expected outcome:** Documented baseline counts. Template for ongoing health checks.

**Pass/Fail:**

**Notes:** Save this query as a reusable script for future reconciliation.

---

### C-04: sync_state Advancement

**Description:** After each test batch, query sync_state and confirm last_processed_block matches the latest block containing events.

**Prerequisites:** Any test that produces events.

**Action:**
```sql
SELECT * FROM sync_state WHERE network='amoy' ORDER BY updated_at DESC LIMIT 1;
```

Compare `last_processed_block` against the block number of the most recent test transaction.

**Expected outcome:** sync_state.last_processed_block >= block number of latest test tx.

**Pass/Fail:**

**Notes:** Run this after each batch of tests, not just once at the end.

---

### C-05: Replay Capability Smoke Test

**Description:** Pick a chain_event row, decode its payload manually, and confirm it matches the corresponding Supabase target table row.

**Prerequisites:** At least one event processed (e.g., CONTEST_CREATED from A-01).

**Action:**
1. Query chain_events for a specific event (e.g., the CONTEST_CREATED from A-01)
2. Read the `payload` field (ABI-encoded event data)
3. Decode it using the event's dataSchema
4. Compare decoded fields to the `contests` table row

**Expected outcome:** All fields match — the chain_events payload contains enough data to reconstruct the handler output.

**Pass/Fail:**

**Notes:** This validates the "replay from chain_events" recovery path. If the payload is sufficient to reconstruct state, we can always re-derive tables from chain_events alone.

---

### C-06: Replay/Idempotency Drill

**Description:** Re-send the same webhook payload (simulating a provider retry or indexer restart mid-stream) and confirm no duplicate rows or broken aggregates.

**Prerequisites:** At least one event has been successfully processed.

**Action:**
1. Query `chain_events` for a processed event (get the raw webhook payload / tx_hash + log_index)
2. Re-trigger the webhook endpoint with the same payload
3. Verify: no duplicate chain_events rows (UNIQUE constraint on network, tx_hash, log_index should reject)
4. Verify: no duplicate rows in target tables (e.g., positions not double-accumulated)
5. Verify: handler returns success (idempotent — already processed)

**Expected outcome:**
- Duplicate detection (Postgres error 23505) is caught and logged silently
- No new rows created
- No aggregate values changed (e.g., position risk_amount not doubled)
- Webhook returns 200 (not 500 — retries would be infinite otherwise)

**Pass/Fail:**

**Notes:** This tests the idempotency guarantee. The indexer uses UNIQUE constraints and "exists before insert" checks. Critical for production ops where webhook retries are common. Also test: if we delete a chain_events row and replay, does it correctly re-process?

---

### C-07: Value Reconciliation (USDC Accounting)

**Description:** Full accounting pass verifying that on-chain USDC balances match the sum of all indexed economic events. Numbers must net out, not just rows.

**Prerequisites:** Full lifecycle tests completed (Phase A).

**Action:** Query and compare:

1. **PositionModule USDC balance** (on-chain) vs sum of all:
   - unclaimed winning positions (risk + profit for winners)
   - unclaimed push positions (risk returned)
   - minus already-claimed amounts

2. **TreasuryModule USDC balance** vs sum of all fees:
   - Contest creation fees (1 USDC × contests created)
   - Speculation creation fees (0.50 USDC × speculations created)
   - Leaderboard creation fees (0.50 USDC × leaderboards created)

3. **SecondaryMarketModule USDC balance** vs sum of:
   - Unclaimed sale proceeds

4. **LeaderboardModule prize pools** vs sum of:
   - Entry fees collected minus prizes already claimed

```bash
# On-chain balance checks
cast call $USDC "balanceOf(address)(uint256)" $POSITION_MODULE --rpc-url $AMOY_RPC_URL
cast call $USDC "balanceOf(address)(uint256)" $TREASURY_MODULE --rpc-url $AMOY_RPC_URL
cast call $USDC "balanceOf(address)(uint256)" $SECONDARY_MARKET_MODULE --rpc-url $AMOY_RPC_URL
```

**Expected outcome:** All balances reconcile. Any discrepancy indicates a missed event or incorrect handler arithmetic.

**Pass/Fail:**

**Notes:** Document the reconciliation formula clearly so it can be automated for ongoing monitoring.

---

### C-08: Leaderboard Outcome Filter — Push Counts, Void Does Not

**Description:** Verify that push-resolved positions DO count toward the minBets requirement, while void-resolved positions do NOT.

**Prerequisites:** A leaderboard with minBets=2. Speculations that can be settled as push and void.

**Action:**
1. Create leaderboard with minBets=2
2. Register user
3. User has 1 win position + 1 void position = 2 total positions but only 1 qualifying
4. Attempt submitLeaderboardROI → should REVERT (only 1 qualifying position — void excluded)
5. User adds 1 push position (now: 1 win + 1 push + 1 void = 2 qualifying)
6. Attempt submitLeaderboardROI → should SUCCEED (push counts)

**Expected on-chain outcome:**
- Step 4: revert (1 win + 1 void = only 1 qualifying, void excluded)
- Step 6: success (1 win + 1 push = 2 qualifying, push counts)

**Expected Supabase outcome:**
- After step 6: ROI submitted, winner determined

**Pass/Fail:**

**Notes:** Contract logic at LeaderboardModule._calculateROI(): `if (spec.winSide != WinSide.TBD && spec.winSide != WinSide.Void) { qualifyingCount++; }`. Push (value 5) passes this filter. Only TBD (0) and Void (6) are excluded.

---

## PHASE D: AGENT INTEGRATION (Aspirational — Do Not Execute)

Goal: Michelle and Dan can run against the deployment.

These are readiness criteria for a future workstream. Not executed in this session.

---

### D-01: Michelle Connects and Signs Commitments

**Criteria:** Michelle agent-server process connects to Amoy RPC, reads contest data from Supabase, and produces EIP-712 signed commitments against the new MatchingModule (domain separator `0x8968ff...`).

**What success looks like:** Michelle logs show commitment generation with correct contract addresses and domain separator.

---

### D-02: Dan Discovers and Matches Commitments

**Criteria:** Degen Dan reads Michelle's commitments from Supabase (or mempool), validates them, and submits matchCommitment transactions that succeed.

**What success looks like:** On-chain COMMITMENT_MATCHED events where maker=Michelle and taker=Dan.

---

### D-03: Both Read State from Supabase

**Criteria:** Neither agent reads state directly from chain (no RPC calls to ContestModule.getContest, etc.). All reads go through Supabase.

**What success looks like:** Agent logs show Supabase queries, no ethers.js contract.call() for state reads.

---

### D-04: End-to-End Cycle

**Criteria:** Michelle posts commitment -> Dan matches -> position creates -> contest scores -> position claims. Full lifecycle with no manual intervention.

**What success looks like:** chain_events shows the complete sequence for one contest, triggered entirely by agents.

---

### D-05: Multi-Day Operation Without Drift

**Criteria:** Run both agents for 3+ days. At end of each day, run C-03 reconciliation query. Zero discrepancies.

**What success looks like:** Reconciliation passes every day. No manual intervention needed.

---

## EXECUTION NOTES

### Ordering Strategy

The tests are designed to be executed in order. Key dependencies:

1. **A-01 through A-07** form a complete moneyline lifecycle (create → verify → match → score → settle → claim)
2. **A-08, A-09** are independent of the lifecycle (can run anytime)
3. **A-10 through A-16** form a leaderboard lifecycle (depends on having a position from A-04)
4. **A-17 through A-21** form a secondary market lifecycle (needs a SEPARATE unsettled speculation)
5. **A-22** requires 1 day wait (create contest early, return later)
6. **A-23, A-24** are spread and total full lifecycles (can share a contest with A-04 or use new ones)
7. **A-25** is the push path (requires specific line selection to guarantee push outcome)
8. **Phase B** mostly requires waiting (B-01, B-11 need 1 day; B-04 needs multiple voids)
9. **Phase C** runs after all Phase A tests complete

### Time Dependencies

| Test | Waiting For | Estimated Wait |
|------|-------------|----------------|
| A-22 | Void cooldown (1 day after contest start) | 24 hours |
| B-01 | Same as A-22 | 24 hours |
| B-04 | Multiple voided contests | 24+ hours |
| B-11 | Cooldown boundary | 24 hours (precise timing) |
| B-12 | ROI window boundary | ~12 minutes (short leaderboard) |
| A-13 | Leaderboard startTime | 5 minutes (configurable) |
| A-14 | endTime + safetyPeriod | 2 days + 1 hour (configurable) |
| A-15 | Same as A-14 | Same |
| A-16 | endTime + safetyPeriod + roiWindow | 2 days + 2 hours |

**Strategy for time-sensitive tests:** Create contests/leaderboards with the shortest possible windows. For leaderboards, use startTime=now+5min, endTime=now+10min, safetyPeriod=60s, roiWindow=60s to collapse the wait to ~12 minutes total.

### Oracle Callback Handling

Contest creation (A-01), verification (A-02), market updates (A-03), and scoring (A-05) all require Chainlink Functions callbacks. The JS source fetches from real APIs (JSONOdds, Rundown, Sportspage).

**Strategy for testing:**
- Use a REAL game ID (one that has already completed) so the APIs return valid data
- The verify callback needs to return a valid leagueId + startTime
- The score callback needs to return valid scores

If Chainlink Functions fail (API errors, timeout), we'll see an OracleRequestFailed event. In that case, we may need to retry or use different game IDs.

### Helper Scripts Needed

Before execution, the following helper scripts must be created:

1. **EIP-712 Commitment Signer** — Signs commitments for the MAKER wallet (Node.js using ethers.js)
2. **Supabase Query Runner** — Queries Supabase tables and formats results (Node.js)
3. **Wallet Setup Script** — Generates test wallets, mints USDC, approves contracts

---

## REVISION LOG

| Date | Change |
|------|--------|
| 2026-04-20 | Initial plan created (Step 1) |
| 2026-04-20 | OC review incorporated: added A-23/24/25 (spread, total, push lifecycles), B-07 (oracle failure), B-08/09/10 (secondary partial + stale hash), B-11/12 (boundary timing), C-06 (replay/idempotency), C-07 (value reconciliation), C-08 (push leaderboard effect). Confirmed conditional gap events (RULE_SET, FEE_PROCESSED, etc.) are intentionally not handled by indexer. |
| 2026-04-20 | Fixed C-08: push positions DO count toward leaderboard minBets (only TBD and Void excluded). |
| 2026-04-21 | Execution results: A-01 PASS, A-02 PASS, A-03 NOT TESTED, A-04 PASS (with findings), A-05 PASS, A-06 PASS, A-07 PASS, B-07 PASS (natural). Three critical findings: (1) Firebase Functions scorer config mismatch caused handler crash, (2) Alchemy webhook auto-paused after repeated 500s with no replay on unpause, (3) cascading FK violation when parent event lost. |
