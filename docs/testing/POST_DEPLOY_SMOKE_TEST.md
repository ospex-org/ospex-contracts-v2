# Post-Deploy Event Smoke Test

Run after any contract redeployment. Confirms the indexer decodes all event payloads correctly with the new ABIs.

## Pre-checks

- [ ] Contract addresses updated in indexer config
- [ ] ABIs updated in ospex-indexer `events.ts` (DATA_SCHEMAS + PARAM_NAMES)
- [ ] CRE workflow pointed at the new `CreOracleReceiver` (receiver + event address) and the receiver's workflow owner matches the registered workflow owner
- [ ] CRE workflow funded off-chain and data-provider secrets provisioned (no on-chain subscription / LINK)
- [ ] Any hardcoded known-event lists in scripts/tools updated

## Event smoke sequence

Execute in order. For each step, verify `chain_events` in Supabase contains the decoded event with correct param names, and the relevant projection table reflects the state change.

| Step | Action | Events to verify | Key fields to spot-check |
|------|--------|-----------------|------------------------|
| 1 | Create contest + request verify via `createContestAndRequestVerify` | `CONTEST_CREATED`, `ORACLE_REQUESTED` (verify), `FEE_PROCESSED` | contestId, jsonoddsId, contestCreator |
| 2 | Wait for CRE verify report (`onReport`) | `CONTEST_VERIFIED`, `ORACLE_REPORT_PROCESSED` | **leagueId** (new field), startTime |
| 3 | Trigger market update via `requestMarketUpdate` → CRE report | `ORACLE_REQUESTED` (market), `CONTEST_MARKETS_UPDATED`, `ORACLE_REPORT_PROCESSED` | all odds ticks, spread/total lines, requestNonce |
| 4 | Match commitment (first fill, auto-creates speculation) | `SPLIT_FEE_PROCESSED`, `SPECULATION_CREATED`, `POSITION_MATCHED_PAIR`, `COMMITMENT_MATCHED` | **scorer, lineTicks, commitmentRiskAmount, nonce, expiry** (new fields), makerRisk, takerRisk (renamed) |
| 5 | Cancel a commitment | `COMMITMENT_CANCELLED` | **contestId, scorer, lineTicks, positionType, oddsTick, riskAmount, nonce, expiry** (new fields) |
| 6 | Raise min nonce | `MIN_NONCE_UPDATED` | **contestId, scorer, lineTicks** (decomposed from opaque hash), newMinNonce, speculationKey |
| 7 | Request score via `requestScore` → CRE report | `ORACLE_REQUESTED` (score), `CONTEST_SCORES_SET`, `ORACLE_REPORT_PROCESSED` | awayScore, homeScore |
| 8 | Settle speculation | `SPECULATION_SETTLED` | winSideValue, scorer |
| 9 | Claim position | `POSITION_CLAIMED` | user, positionType, payout |

## What changed (emit audit, 2026-04-25)

**MatchingModule:**
- `CommitmentMatched`: added scorer, lineTicks, commitmentRiskAmount, nonce, expiry. Renamed makerProfitAmount/takerProfitAmount to makerRisk/takerRisk.
- `CommitmentCancelled`: added full commitment fields (was just hash + maker).
- `MinNonceUpdated`: decomposed opaque speculationKey into contestId, scorer, lineTicks. Key retained as trailing field.

**ContestModule:**
- `ContestVerified`: added leagueId (resolves Unknown -> specific league from oracle callback).

**TreasuryModule:**
- `processSplitFee`: native event changed from two `FeeProcessed` to one `SplitFeeProcessed`. CoreEvent payload unchanged (SPLIT_FEE_PROCESSED was already correct).
