# Mainnet VERIFY ScriptApproval — keystore signing

The Chainlink Functions VERIFY source (`contestCreation.js`) gained the Athletics MLB
`teamLegend` entry, so its keccak256 changed to
`0xec6a7e9cdffa09fdcaa611220e2c99ba0ec58cc082812a01b5d321ccc1e5ebcf`. The mainnet
`APPROVED_SIGNER` (`0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886`) must re-sign an
EIP-712 `ScriptApproval` for that hash before contests involving the A's can be created.
This folder signs it using a **Foundry keystore** (no raw key on the command line).

## One-time keystore setup (already done as `ospex-mainnet-signer`)

```
cast wallet import ospex-mainnet-signer --interactive
cast wallet address --account ospex-mainnet-signer   # must print 0xfd6C…5886
```

## Sign

On the machine holding the keystore, from the repo root:

```
bash script-approvals/sign-verify-approval.sh
```

Enter the keystore password when prompted. The script:
- (if online) re-fetches `contestCreation.js` and re-checks its hash,
- signs the EIP-712 approval in `verify-approval-712.json`,
- writes the signed approval to `verify-approval-result.txt`.

Then commit **only** the result file and push:

```
git add script-approvals/verify-approval-result.txt
git commit -m "sign verify ScriptApproval (Athletics MLB fix)"
git push
```

> ⚠️ Public repo. Never `git add -A` here, and never commit `~/.foundry/keystores/`,
> `.env`, or the keystore password. The signature/hash/struct in the result file are
> the only things that should be pushed.

## Files

| file | what |
|------|------|
| `verify-approval-712.json` | EIP-712 typed data that gets signed (public constants; domain `OspexOracle` v1 / chain 137 / OracleModule `0x7e1397eD…`). |
| `sign-verify-approval.sh`  | runs `cast wallet sign` with the keystore; writes the result. |
| `verify-approval-result.txt` | produced by the script — the signed approval (`scriptHash`, `purpose`, `leagueId`, `version`, `validUntil`, `signature`). |

## Re-signing later (≈ every 6 months, before `validUntil` 1795737600 = 2026-11-27)

Copy `verify-approval-712.json`, bump `validUntil` (and `scriptHash`, if the JS source
changed), and re-run. Market-update and score approvals are permanent — they never expire.
