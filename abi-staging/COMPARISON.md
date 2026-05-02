# ABI Staging — Local `out/` vs. Deployed Truth

**Audit date:** 2026-05-02
**Network:** Polygon mainnet (chain id 137)
**Deployed release:** R4 (deploy block 86135682, deploy date 2026-04-28)
**Audit branch:** `audit/abi-staging-comparison`

## TL;DR

All 13 deployed contracts are verified on Polygonscan, and **every Polygonscan ABI is byte-identical to the local `out/<Contract>.sol/<Contract>.json` artifact** after sorting/normalization. The local Foundry artifacts in this repo accurately reflect what is deployed on-chain. The `abi-staging/<Contract>.json` files in this directory are the Polygonscan-verified ABIs and are the canonical source for the SDK's M1 build.

## Source of truth

For every deployed contract, **the Polygonscan-verified ABI is the deployed truth.** Local `out/` is regenerated on `forge build` and could in principle diverge if anyone rebuilds against a different commit; the verified ABI on Polygonscan was published from the exact bytecode that lives at the deployed address.

The 13 JSON files in this directory were fetched directly from Polygonscan and saved with the same `ContractName` Polygonscan reports, so the SDK can copy them in as-is at M1 time.

## Pre-flight findings

### Spec source vs. reality: `/v1/protocol/info`

The task brief said `GET /v1/protocol/info` returns "the deployed addresses for OspexCore, all modules, and scorers." The live response from `https://ospex-core-api-195f635df864.herokuapp.com/v1/protocol/info` actually returns only **4 of the 13 deployed contracts**:

```json
{
  "name": "Ospex",
  "network": "polygon",
  "chainId": 137,
  "contracts": {
    "matchingModule": "0x1B93579B044f0eE3c4C8a9F479A323DeF7770712",
    "scorers": {
      "moneyline": "0xd846B7FdbD8C9F67d1580B2C6a8Bd7Fdcb15390b",
      "spread":    "0x99c5fF5131F269cA178e2Ea78f2a2A222a3a7d5e",
      "total":     "0xC141679f09413EDe38E3Cd36a3e4aDE423827972"
    }
  },
  "supportedSports": ["NBA","NHL","NCAAB","NFL","MLB"],
  "fees": {"platformFeePct":0,"description":"No platform fees. Stakes match peer-to-peer at signed odds."}
}
```

`OspexCore` and the other 8 modules (Contest, Speculation, Position, Oracle, Treasury, Leaderboard, Rules, SecondaryMarket) are not exposed. The 4 addresses that are returned exactly match the canonical deployment artifact (cross-checked against `docs/deployment/POLYGON_MAINNET_R4_output.txt` and `POLYGON_MAINNET_R4.md`), so no contradiction — the public endpoint is just a strict subset.

To get the full set of 13 addresses, this audit used `docs/deployment/POLYGON_MAINNET_R4.md` (Foundry deploy artifact, committed to this repo) as the canonical list. Either `/v1/protocol/info` should be expanded to expose `ospexCore` + every module address, or future tooling should keep using the deploy artifact as the source of record. **Recommended:** expand the endpoint before M1 ships so the SDK has a single dynamic source of truth instead of two.

### Polygonscan API: V1 endpoint deprecated

The task brief gave `https://api.polygonscan.com/api?...` (V1). That endpoint is now hard-deprecated and returns:

```
{"status":"0","message":"NOTOK","result":"You are using a deprecated V1 endpoint, switch to Etherscan API V2 using https://docs.etherscan.io/v2-migration"}
```

This audit used the V2 multichain endpoint instead: `https://api.etherscan.io/v2/api?chainid=137&...`. The Etherscan/Polygonscan API key in `.env` (`ETHERSCAN_API_KEY`) works on both V1 and V2 — Etherscan unified keys across networks. Future tooling that hits Polygonscan from this repo should default to V2.

### Verification status

Every one of the 13 contracts is verified on Polygonscan (non-empty `SourceCode` field on `getsourcecode`, and a non-empty parsed ABI from `getabi`). No contract is unverified. No need to verify anything before proceeding.

## Per-contract result

All 13 ABIs match the local Foundry artifacts. The "ABI entries" column counts every entry in the ABI array (functions, events, errors, constructor).

| # | Contract | Address | Verified | ABI entries (live = local) | Result |
|---|---|---|---|---|---|
| 1 | `OspexCore`             | `0xECD12Af197FBF4C9F706B5Eb11a19c40Cfd643db` | yes | 37 | match |
| 2 | `ContestModule`         | `0x1Eb0048650380369C6F4239dE070114463626102` | yes | 40 | match |
| 3 | `SpeculationModule`     | `0xd757387893E779AC35451CeA639a408A537b9a1B` | yes | 32 | match |
| 4 | `PositionModule`        | `0x0DCd42f8609cd7884ddBa3481b03a78dfc88366c` | yes | 33 | match |
| 5 | `MatchingModule`        | `0x1B93579B044f0eE3c4C8a9F479A323DeF7770712` | yes | 49 | match |
| 6 | `OracleModule`          | `0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb` | yes | 45 | match |
| 7 | `TreasuryModule`        | `0xCB56CD2c509301e888965DD3A2E5C486Fe03a56e` | yes | 34 | match |
| 8 | `LeaderboardModule`     | `0x63f76D5796296FFB94132C6f70d3ff9c3c5a0DEF` | yes | 67 | match |
| 9 | `RulesModule`           | `0x05aF3d55F44CfaFA59c3B152A1547b5219d90f93` | yes | 50 | match |
| 10 | `SecondaryMarketModule` | `0xaD2B4437296B46a1b107Bb2dB7AC4082182b6059` | yes | 40 | match |
| 11 | `MoneylineScorerModule` | `0xd846B7FdbD8C9F67d1580B2C6a8Bd7Fdcb15390b` | yes | 8 | match |
| 12 | `SpreadScorerModule`    | `0x99c5fF5131F269cA178e2Ea78f2a2A222a3a7d5e` | yes | 8 | match |
| 13 | `TotalScorerModule`     | `0xC141679f09413EDe38E3Cd36a3e4aDE423827972` | yes | 8 | match |

**Mismatches: 0.** No diff to report.

## Method

For each address:

1. `GET https://api.etherscan.io/v2/api?chainid=137&module=contract&action=getsourcecode&address=<addr>` → confirm `SourceCode` is non-empty (verified) and capture `ContractName`. Used to choose the staging filename.
2. `GET https://api.etherscan.io/v2/api?chainid=137&module=contract&action=getabi&address=<addr>` → fetch the verified ABI. Parse the JSON-encoded string into an array.
3. Read local artifact at `out/<ContractName>.sol/<ContractName>.json` and extract the `abi` field (just the array, not the surrounding Foundry metadata).
4. Normalize both sides:
   - Sort entries by `(type, name, canonical-input-tuple, canonical-output-tuple)` so order doesn't affect equality.
   - For tuple types, recurse into `components` and emit `(t1,t2,...)` form so internal struct names don't perturb the comparison.
   - Stable JSON-stringify with sorted object keys.
5. Equal stringified forms → `match`. Otherwise compute three sets:
   - `onlyLive` (live has it, local doesn't) — i.e. functions/events/errors deployed but missing from local out/.
   - `onlyLocal` (local has it, live doesn't) — i.e. local out/ ahead of deployment.
   - `changed` (same `(type, name, inputs)`, different shape — e.g. return type or stateMutability changed).

Result: zero mismatches, so the diff sets above are empty for every contract.

The audit was driven by a one-shot Node script (`.tmp-abi-audit/abi_audit.mjs` outside this repo) — not committed because it was scaffolding and the repo's `scripts/` directory is gitignored except for `sign-script-approval.js`.

## SDK consumption (M1)

When the SDK build starts, point it at `ospex-foundry-matched-pairs/abi-staging/` and copy each `<Contract>.json` straight in. The filenames already match the verified `ContractName` reported by Polygonscan, so import paths in the SDK can mirror the contract names 1:1.

## What was deliberately not done

Per the task brief:

- `forge build` was not run.
- No `.sol` source files were modified.
- `out/` was not modified — the staged ABIs live only in `abi-staging/`.
- No SDK / M1 work was started.

## Unconfirmed assumptions

- **`abi-staging/` is intentionally tracked in git.** The brief says `abi-staging/.gitignore is unnecessary; we want these committed.` This commit follows that. If the canonical-repo policy later changes to "no committed binaries/JSON", this directory should move into the SDK repo proper at M1 time.
- **`.env`'s `ETHERSCAN_API_KEY` is the right key to use for Polygonscan V2.** Empirically it worked for all 26 calls in this audit (13 × `getsourcecode` + 13 × `getabi`), but I did not separately verify whether a project-specific `POLYGONSCAN_API_KEY` exists somewhere else. If that's preferred, swap it in — the unified key worked because Etherscan now serves Polygonscan via the V2 multichain endpoint with the same key namespace.
- **The 13-contract list is complete.** Sourced from `docs/deployment/POLYGON_MAINNET_R4.md` and cross-checked against `POLYGON_MAINNET_R4_output.txt`. Not separately re-confirmed against `OspexCore.s_modules` reads on-chain; if a module was added or replaced post-deploy that wasn't recorded in deployment docs, this audit would miss it. The protocol is `Finalized` per the deploy log, which forecloses adding new modules — but a module *replacement* via a hypothetical admin-less upgrade path would still be invisible here. This is a low-risk assumption given the immutable, finalized design.
- **No Amoy testnet artifacts were audited.** Per `network-config`, no R4 deploy artifact exists for Amoy yet, so there's nothing to compare. When Amoy R4 lands, run this same audit against `chainid=80002`.
