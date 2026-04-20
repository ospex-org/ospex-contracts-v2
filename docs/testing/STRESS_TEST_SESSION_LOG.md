# Stress Test Session Log

Tracks progress across sessions. Updated after each test execution.

## Current Status

**Phase:** Step 1 — Test plan written, awaiting Vince review.

**Next action:** Vince reviews `AMOY_STRESS_TEST_PLAN.md`. After approval, proceed to wallet setup and Phase A execution.

## Blocking Items

| Item | Status | Notes |
|------|--------|-------|
| Test plan review | AWAITING | Vince must approve before execution |
| Test wallet generation | NOT STARTED | Need MAKER + TAKER wallets |
| Helper scripts (EIP-712 signer) | NOT STARTED | Required for A-04 |
| Real game ID for oracle tests | NOT STARTED | Need a completed game with valid API IDs |

## Time-Sensitive Tests Tracking

| Test | Contest/Leaderboard | Created At | Eligible At | Status |
|------|---------------------|------------|-------------|--------|
| A-22 (CONTEST_VOIDED) | — | — | startTime + 1 day | NOT STARTED |
| B-01 (Post-cooldown rejection) | — | — | startTime + 1 day | NOT STARTED |
| A-14/15/16 (Leaderboard ROI+Prize) | — | — | endTime + safety + roi window | NOT STARTED |

## Session History

### Session 1 — 2026-04-20

**Accomplished:**
- Explored contract architecture, deployment artifacts, indexer handlers
- Verified toolchain (cast v1.6.0-nightly) and Amoy connectivity
- Confirmed deployer balances: 37.8 POL, ~1B USDC, 5.32 LINK
- Confirmed contest counter = 0 (clean slate)
- Confirmed MockERC20 has permissionless mint()
- Created comprehensive test plan (AMOY_STRESS_TEST_PLAN.md)

**Key findings:**
- All contracts deployed and finalized on Amoy (2026-04-19)
- Script approvals are pre-signed, expire 2026-07-19
- Void cooldown is 1 day (means some tests require 24h wait)
- Oracle calls require real Chainlink Functions (no mock router on Amoy)
- Need real game IDs for oracle API calls to succeed

**Decisions needed from Vince:**
1. Review and approve the test plan
2. Choose approach for oracle tests: real game IDs vs. some alternative
3. Confirm whether I should generate test wallets now
