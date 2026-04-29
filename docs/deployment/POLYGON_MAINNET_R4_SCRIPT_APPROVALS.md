# Ospex Round 4 — Polygon Mainnet Script Approvals

EIP-712 signed `ScriptApproval` structs for the three Chainlink Functions JS sources consumed by `OracleModule.createContestFromOracle(...)`. Each entry below is the exact data that must be passed in the `ScriptApprovals` calldata struct when creating a contest.

**Signed:** 2026-04-29
**Signer:** `0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886` (mainnet `APPROVED_SIGNER`)
**OracleModule:** `0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb`
**Chain ID:** 137 (Polygon mainnet)
**EIP-712 domain:** `OspexOracle` v1
**Tooling:** [`scripts/sign-script-approval.js`](../../scripts/sign-script-approval.js)
**JS source repo:** [`ospex-org/ospex-source-files-and-other`](https://github.com/ospex-org/ospex-source-files-and-other)

All three signatures verified locally (recovered signer matches `APPROVED_SIGNER`).

---

## 1. Verify (`contestCreation.js`)

| Field | Value |
|-------|-------|
| Source | https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestCreation.js |
| `scriptHash` | `0x01c48e15068b68b7d5986d5013edd83a243ac31a761567e9db0e57b513c26c01` |
| `purpose` | `0` (VERIFY) |
| `leagueId` | `0` (Unknown — wildcard, all leagues) |
| `version` | `1` |
| `validUntil` | `1793030835` (2026-10-26T16:07:15Z, **180 days**) |
| `signature` | `0xe34d613dd3901b6cf6f72dd5d7fac7dbae044e204d0b8853ecc91359292d2511757bf50d94d7513214c34aef5591b3ad5fb54efd17293c7e7b931d1b68ab51661b` |

**Re-sign reminder:** before 2026-10-26. After expiry, `createContestFromOracle` reverts; existing contests are unaffected.

---

## 2. Market Update (`contestMarketsUpdate.js`)

| Field | Value |
|-------|-------|
| Source | https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestMarketsUpdate.js |
| `scriptHash` | `0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4` |
| `purpose` | `1` (MARKET_UPDATE) |
| `leagueId` | `0` (Unknown — wildcard, all leagues) |
| `version` | `1` |
| `validUntil` | `0` (permanent — no expiry) |
| `signature` | `0x29658d908ba488863afb292eb15de7004f34c3a76a2fe14a8c098d776dc9499027b678f1308c45cc196587f291657235d641e842a19e183277ad711a2c7d16631c` |

---

## 3. Score (`contestScoring.js`)

| Field | Value |
|-------|-------|
| Source | https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestScoring.js |
| `scriptHash` | `0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd` |
| `purpose` | `2` (SCORE) |
| `leagueId` | `0` (Unknown — wildcard, all leagues) |
| `version` | `1` |
| `validUntil` | `0` (permanent — no expiry) |
| `signature` | `0x3e72c199479665aa148cb1ac05bc4261b74b8581447adcb9165bdb67f6f6c99b7753a7a6186ac5fc4046ba9f626954cfefe47a6d9ce8437204feb109bb9713791b` |

---

## Notes

- **Hash continuity with Amoy R4:** all three `scriptHash` values are identical to the Amoy R4 signed approvals — confirms the JS sources at the GitHub URLs are unchanged across the testnet → mainnet boundary. Only the signatures differ (different EIP-712 domain: chainId + verifyingContract).
- **Approvals are consumed at contest creation.** Once `OracleModule.createContestFromOracle(...)` accepts these, the three script hashes are baked into the contest. Subsequent operations (oracle callbacks for verify, market-update, score) validate by hash only — no further signature checks. Per-contest, the approval gate is a one-time thing.
- **Expiry impact (verify only):** if `validUntil` for verify passes without re-signing, no new contests can be created. Existing contests continue functioning. Re-signing is a single command on the deployer machine.
- **Permanent approvals (market-update + score):** these scripts have been stable for years. Permanent expiry preserves a rollback path — if a future market-update or score script revision has a bug, the previous approval can still be used to create contests against the previous hash.
- **Trust model:** `APPROVED_SIGNER` is immutable post-finalize. The protocol is permanently bound to the deployer EOA as the only entity that can authorize script sources. No multisig migration possible without a fresh OracleModule deploy.
