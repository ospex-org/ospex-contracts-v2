# Post-Deploy Event Smoke Test

Run after any contract redeployment. Confirms the indexer decodes all event payloads correctly with the new ABIs.

## Pre-checks

- [ ] Contract addresses updated in indexer config
- [ ] ABIs updated in ospex-indexer `events.ts` (DATA_SCHEMAS + PARAM_NAMES)
- [ ] Oracle consumer/subscription updated (if OracleModule address changed)
- [ ] Oracle script hashes/signatures/secrets regenerated (if module addresses or domain assumptions changed)
- [ ] Any hardcoded known-event lists in scripts/tools updated

## Event smoke sequence

Execute in order. For each step, verify `chain_events` in Supabase contains the decoded event with correct param names, and the relevant projection table reflects the state change.

| Step | Action | Events to verify | Key fields to spot-check |
|------|--------|-----------------|------------------------|
| 1 | Create contest via `createContestFromOracle` | `CONTEST_CREATED`, `SCRIPT_APPROVAL_VERIFIED` x3, `FEE_PROCESSED` | contestId, jsonoddsId, contestCreator |
| 2 | Wait for oracle callback (verification) | `CONTEST_VERIFIED` | **leagueId** (new field), startTime |
| 3 | Trigger market update | `CONTEST_MARKETS_UPDATED` | all odds ticks, spread/total lines |
| 4 | Match commitment (first fill, auto-creates speculation) | `SPLIT_FEE_PROCESSED`, `SPECULATION_CREATED`, `POSITION_MATCHED_PAIR`, `COMMITMENT_MATCHED` | **scorer, lineTicks, commitmentRiskAmount, nonce, expiry** (new fields), makerRisk, takerRisk (renamed) |
| 5 | Cancel a commitment | `COMMITMENT_CANCELLED` | **contestId, scorer, lineTicks, positionType, oddsTick, riskAmount, nonce, expiry** (new fields) |
| 6 | Raise min nonce | `MIN_NONCE_UPDATED` | **contestId, scorer, lineTicks** (decomposed from opaque hash), newMinNonce, speculationKey |
| 7 | Score contest | `CONTEST_SCORES_SET` | awayScore, homeScore |
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
