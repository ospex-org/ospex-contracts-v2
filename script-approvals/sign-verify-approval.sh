#!/usr/bin/env bash
#
# Sign the Ospex mainnet VERIFY ScriptApproval (Athletics MLB fix) using the
# Foundry keystore account "ospex-mainnet-signer".
#
# The raw private key never touches the command line — cast prompts only for the
# keystore password. The signature it produces is PUBLIC data (it goes into public
# docs and on-chain calldata), so the result file is safe to commit to this public repo.
#
# Usage (on the machine holding the keystore, from the repo root):
#     bash script-approvals/sign-verify-approval.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT="ospex-mainnet-signer"
JSON="$DIR/verify-approval-712.json"
OUT="$DIR/verify-approval-result.txt"
EXPECTED_HASH="0xec6a7e9cdffa09fdcaa611220e2c99ba0ec58cc082812a01b5d321ccc1e5ebcf"
SIGNER="0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886"
SRC_URL="https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestCreation.js"

command -v cast >/dev/null 2>&1 || { echo "ERROR: 'cast' (Foundry) not found in PATH." >&2; exit 1; }
[ -f "$JSON" ] || { echo "ERROR: $JSON not found (run from a fresh checkout)." >&2; exit 1; }

echo "=== Ospex mainnet VERIFY ScriptApproval signer ==="
echo "keystore account : $ACCOUNT"
echo "scriptHash       : $EXPECTED_HASH"
echo "expected signer  : $SIGNER"
echo "validUntil       : 1795737600 (2026-11-27T00:00:00Z)"
echo

# Optional integrity re-check: fetch the canonical JS and confirm its hash matches.
HASHCHECK="skipped (offline, or curl/xxd missing)"
if command -v xxd >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  TMP="$(mktemp)"
  if curl -sfL "$SRC_URL" -o "$TMP" 2>/dev/null; then
    GOT="$(cast keccak "0x$(xxd -p "$TMP" | tr -d '\n')")"
    if [ "$GOT" = "$EXPECTED_HASH" ]; then
      HASHCHECK="OK"
    else
      rm -f "$TMP"
      echo "ABORT: fetched script hash $GOT does not match expected $EXPECTED_HASH" >&2
      exit 1
    fi
  fi
  rm -f "$TMP"
fi
echo "source hash recheck : $HASHCHECK"
echo

echo "Enter the keystore password when prompted by cast:"
SIG="$(cast wallet sign --account "$ACCOUNT" --data --from-file "$JSON")"

# A 65-byte signature is 0x + 130 hex chars. Refuse to write anything else.
if ! printf '%s' "$SIG" | grep -Eq '^0x[0-9a-fA-F]{130}$'; then
  echo "ERROR: unexpected signature output (refusing to write): $SIG" >&2
  exit 1
fi

cat > "$OUT" <<EOF
# Ospex mainnet VERIFY ScriptApproval — signed result
# PUBLIC data (signature/hash/struct fields) — safe to commit to this public repo.
# Athletics MLB fix. Produced by script-approvals/sign-verify-approval.sh
scriptHash=$EXPECTED_HASH
purpose=0
leagueId=0
version=1
validUntil=1795737600
signer=$SIGNER
signature=$SIG
sourceHashRecheck=$HASHCHECK
EOF

echo
echo "Wrote $OUT:"
echo "------------------------------------------------------------"
cat "$OUT"
echo "------------------------------------------------------------"
echo
echo "Everything above is PUBLIC. Commit ONLY this file and push:"
echo "    git add script-approvals/verify-approval-result.txt"
echo "    git commit -m 'sign verify ScriptApproval (Athletics MLB fix)'"
echo "    git push"
echo
echo "!! Do NOT 'git add -A' here — never commit .env, the keystore, or the password."
