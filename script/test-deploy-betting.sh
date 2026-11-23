#!/usr/bin/env bash
# The tests of script/deploy-betting.sh. They need no secret and no node of ours: a throwaway git repository with
# a made-up commit and plan, a plain local anvil on chain id 137 with no fork, the pinned cast, and a stand-in
# forge that records what it was given and prints what a test asks. No line whose first word is live is run:
# live mode's refusals are proved on the wrapper's own check functions, sourced with made-up values.
#
#   bash script/test-deploy-betting.sh
#
# Each refusal is proved beside a positive control that passes the same check, so a check that refuses
# everything cannot pass. Prints one line per case and exits non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="$HERE/deploy-betting.sh"
PINNED="80ae59941ada986c49e05f2a8412c3fc1f9075d0"
SENTINEL="0xE06B6A8ff1a62CF18ca244EeCb4c43c5a803a4F6"
FORK_GO="0x9575ee8093561ec60b3c163aea383818"
MADE_UP_NODE="https://made-up-node.example.invalid/v2/abcdefghijklmnop0123456789"

REAL_CAST="$(command -v cast)"
REAL_ANVIL="$(command -v anvil)"
[ -n "$REAL_CAST" ] && [ -n "$REAL_ANVIL" ] || { echo "the tests need cast and anvil on the PATH"; exit 2; }
"$REAL_CAST" --version | grep -q "^Commit SHA: $PINNED$" || { echo "the tests need the pinned cast ($PINNED)"; exit 2; }

TMP="$(mktemp -d)"
REPO="$TMP/repo"
STUB="$TMP/bin"
RECORD="$TMP/forge-record.txt"
ANVIL_PID=""
failures=0
cases=0

cleanup() {
    if [ -n "$ANVIL_PID" ]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

ok() { cases=$((cases + 1)); echo "ok   $1"; }
fail() { cases=$((cases + 1)); failures=$((failures + 1)); echo "FAIL $1"; }

# ── The stand-ins and the throwaway repository ────────────────────────────────────────────────────────────────

mkdir -p "$STUB" "$REPO/script"
cat > "$STUB/forge" <<'STUBEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    echo "forge Version: 1.6.0-nightly"
    echo "Commit SHA: ${STUB_FORGE_COMMIT}"
    exit 0
fi
{
    echo "args: $*"
    for v in ETH_FROM ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD ETH_RPC_URL FOUNDRY_ETH_RPC_URL STUB_PROBE; do
        if [ -n "${!v+x}" ]; then echo "env $v: set"; else echo "env $v: absent"; fi
    done
    echo "TEMPO_HOME entries: $(ls -A "${TEMPO_HOME:-/nonexistent}" 2>/dev/null | wc -l | tr -d ' ')"
    echo "FOUNDRY_PROFILE: ${FOUNDRY_PROFILE:-}"
} >> "$STUB_RECORD"
if [ -n "${STUB_EMIT:-}" ]; then
    echo "forge says: $STUB_EMIT"
    echo "forge errs: $STUB_EMIT" >&2
fi
case "$*" in
    *"predict(bytes20)"*)
        all="$*"; commit="${all##*predict(bytes20) }"; commit="${commit%% *}"
        mkdir -p deployments/betting-set/137
        printf '{"commit":"%s","nonce":1}\n' "$commit" > deployments/betting-set/137/prediction.json
        echo "manifest.mustEqual.digest: 0x$(printf '%064d' 7)"
        ;;
esac
exit 0
STUBEOF
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_CAST" > "$STUB/cast"
chmod +x "$STUB/forge" "$STUB/cast"

cp "$WRAPPER_SRC" "$REPO/script/deploy-betting.sh"
echo "// a stand-in for the script, in the throwaway repository" > "$REPO/script/DeployBetting.s.sol"
printf '[profile.default]\nsrc = "src"\n\n[profile.ci]\nsolc = "0.8.26"\n' > "$REPO/foundry.toml"
printf 'forge-std/=lib/forge-std/src/\n' > "$REPO/remappings.txt"
printf 'deployments/\n' > "$REPO/.gitignore"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid add .
git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -q -m "a made-up commit"
HEAD_COMMIT="$(git -C "$REPO" rev-parse HEAD)"

# ── The local node ────────────────────────────────────────────────────────────────────────────────────────────

PORT=$((20000 + RANDOM % 9000))
"$REAL_ANVIL" --chain-id 137 --port "$PORT" --quiet > "$TMP/anvil.log" 2>&1 &
ANVIL_PID=$!
NODE="http://127.0.0.1:$PORT"
for _ in $(seq 1 60); do
    "$REAL_CAST" chain-id --rpc-url "$NODE" > /dev/null 2>&1 && break
    sleep 0.5
done
[ "$("$REAL_CAST" chain-id --rpc-url "$NODE" 2>/dev/null)" = 137 ] || { echo "the local node did not start"; exit 2; }

# Runs the wrapper in the throwaway repository with the stand-ins, its streams captured.
wrap() {
    (cd "$REPO" && env DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="${STUB_FORGE_COMMIT:-$PINNED}" \
        bash script/deploy-betting.sh "$@")
}

# expect_refused <case> <words of the refusal> <wrapper arguments...>
expect_refused() {
    local name="$1" words="$2" out status
    shift 2
    : > "$RECORD"
    out=$(wrap "$@" 2>&1); status=$?
    if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -F "REFUSED:" | grep -qF "$words"; then ok "$name"; else fail "$name (exit $status): $out"; fi
}

# expect_passed <case> <wrapper arguments...>
expect_passed() {
    local name="$1" out status
    shift
    out=$(wrap "$@" 2>&1); status=$?
    if [ "$status" -eq 0 ]; then ok "$name"; else fail "$name (exit $status): $out"; fi
}

D32="0x$(printf '%064d' 7)"

# ── Words ─────────────────────────────────────────────────────────────────────────────────────────────────────

expect_refused "an unknown mode" "unknown mode 'nope'" nope setup --rpc-url "$NODE"
expect_refused "an unknown phase" "unknown phase 'nope'" fork nope --rpc-url "$NODE"
expect_refused "an unknown flag" "unknown flag '--legacy'" fork setup --rpc-url "$NODE" --legacy

# ── Fork mode: the node ───────────────────────────────────────────────────────────────────────────────────────

: > "$RECORD"
expect_refused "a node that is not loopback, in fork mode" "fork mode takes only this machine's loopback node" \
    fork setup --rpc-url "http://example.invalid:8545"
if [ ! -s "$RECORD" ] && [ "$("$REAL_CAST" code "$SENTINEL" --rpc-url "$NODE")" = "0x" ]; then
    ok "the refused node: nothing run, nothing written"
else
    fail "the refused node: something ran or was written"
fi
expect_refused "a missing sentinel, before setup" "the sentinel's code is not on the node" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
expect_passed "setup on this machine's loopback (the positive control)" fork setup --rpc-url "$NODE"
[ "$("$REAL_CAST" code "$SENTINEL" --rpc-url "$NODE")" = "0x00" ] && ok "setup wrote the sentinel" || fail "setup wrote no sentinel"

# ── The commit, the tree, forge ───────────────────────────────────────────────────────────────────────────────

expect_refused "a commit that is not HEAD" "HEAD is not the commit" fork predict "0x$(printf '%040d' 1)" --rpc-url "$NODE"
touch "$REPO/stray-file"
expect_refused "a dirty tree" "the tree is not clean" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
rm -f "$REPO/stray-file"
STUB_FORGE_COMMIT="0000000000000000000000000000000000000000" \
    expect_refused "another forge's commit line" "commit line is not the pinned one" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
: > "$RECORD"
expect_passed "the commit, a clean tree, the pinned forge (the positive control)" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
grep -q "predict(bytes20) 0x$HEAD_COMMIT" "$RECORD" && grep -q -- "--skip test" "$RECORD" && grep -q -- "--via-ir --optimize" "$RECORD" \
    && grep -q "FOUNDRY_PROFILE: ci" "$RECORD" && ok "predict ran forge with --skip test, the ci profile and CI's flags" \
    || fail "predict's forge line: $(cat "$RECORD")"
expect_refused "an unknown stage" "unknown stage '4'" fork check "0x$(printf '%040d' 1)" 1 4 --rpc-url "$NODE"
: > "$RECORD"
expect_passed "a known stage (the positive control)" fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE"

# ── The signer's environment ──────────────────────────────────────────────────────────────────────────────────

: > "$RECORD"
(cd "$REPO" && env DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" \
    ETH_FROM=0x0000000000000000000000000000000000000001 ETH_KEYSTORE_ACCOUNT=a-made-up-name ETH_KEYSTORE=/a/made/up/path \
    ETH_PASSWORD=/a/made/up/file STUB_PROBE=1 \
    bash script/deploy-betting.sh fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE" > /dev/null 2>&1)
if grep -q "env STUB_PROBE: set" "$RECORD"; then ok "the stand-in sees a variable it is given (the positive control)"; else fail "the stand-in sees nothing: $(cat "$RECORD")"; fi
if grep -q "env ETH_FROM: absent" "$RECORD" && grep -q "env ETH_KEYSTORE: absent" "$RECORD" \
    && grep -q "env ETH_KEYSTORE_ACCOUNT: absent" "$RECORD" && grep -q "env ETH_PASSWORD: absent" "$RECORD" \
    && grep -q "TEMPO_HOME entries: 0" "$RECORD"; then
    ok "a signer variable set: forge runs with none of them, and an empty wallet home"
else
    fail "a signer variable reached forge: $(cat "$RECORD")"
fi

# ── The filter, on both streams, into the screen and the kept log ─────────────────────────────────────────────

rm -rf "$REPO/deployments/betting-set/137/runs"
screen=$(cd "$REPO" && env DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" \
    POLYGON_RPC_URL="$MADE_UP_NODE" STUB_EMIT="$MADE_UP_NODE" \
    bash script/deploy-betting.sh fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE" 2>&1)
kept=$(cat "$REPO"/deployments/betting-set/137/runs/*.log 2>/dev/null)
if printf '%s' "$screen" | grep -q "forge says: <POLYGON_RPC_URL>" && printf '%s' "$screen" | grep -q "forge errs: <POLYGON_RPC_URL>"; then
    ok "the filter's marker reached the screen on both streams (the positive control)"
else
    fail "the lines did not pass the filter: $screen"
fi
if printf '%s\n%s' "$screen" "$kept" | grep -q -e "made-up-node" -e "abcdefghijklmnop"; then
    fail "a made-up node address reached the screen or the kept log"
else
    ok "a made-up node address: in neither the screen nor the kept log"
fi
[ -n "$kept" ] && ok "the run's log was kept" || fail "no run log was kept"

# ── compare ───────────────────────────────────────────────────────────────────────────────────────────────────

M="$TMP/m"
mkdir -p "$M"
manifest() {
    printf '{\n  "mustEqual": {\n    "commit": "%s",\n    "digest": "%s"\n  },\n  "declared": {\n    "node": "%s"\n  }\n}\n' "$1" "$2" "$3"
}
manifest c1 d1 fork > "$M/a.json"
manifest c1 d1 live > "$M/b.json"
manifest c1 d2 fork > "$M/c.json"
(cd "$REPO" && bash script/deploy-betting.sh compare "$M/a.json" "$M/b.json" > /dev/null 2>&1) && ok "compare: a declared difference alone is equal" || fail "compare refused a declared difference"
(cd "$REPO" && bash script/deploy-betting.sh compare "$M/a.json" "$M/c.json" > /dev/null 2>&1) && fail "compare passed a must-equal difference" || ok "compare: a must-equal difference fails"

# ── Live mode's refusals, on the sourced functions, with made-up values ───────────────────────────────────────

live_check() {
    (cd "$REPO" && DEPLOY_FOUNDRY_BIN="$STUB" STUB_FORGE_COMMIT="$PINNED" bash -c "source script/deploy-betting.sh; $1" 2>&1)
}
out=$(live_check "require_go live $FORK_GO"); [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "the fork's go value in live mode" && ok "live: the fork's go value refused" || fail "live: the fork's go value: $out"
out=$(live_check "require_go live 0x$(printf '%032d' 5)"); [ $? -eq 0 ] && ok "live: another go value passes (the positive control)" || fail "live: a go value refused: $out"
out=$(live_check "require_go live 0x$(printf '%032d' 0)"); [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "the go value is zero" && ok "live: a zero go value refused" || fail "live: a zero go value: $out"
out=$(live_check "require_go fork $FORK_GO"); [ $? -eq 0 ] && ok "fork: the fork's go value passes" || fail "fork: the fork's go value refused: $out"
out=$(live_check "RPC_URL=$NODE; require_sentinel_absent"); [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "the node holds the sentinel's code" && ok "live: a node holding the sentinel refused" || fail "live: the sentinel: $out"
"$REAL_CAST" rpc anvil_setCode "$SENTINEL" 0x --rpc-url "$NODE" > /dev/null
out=$(live_check "RPC_URL=$NODE; require_sentinel_absent"); [ $? -eq 0 ] && ok "live: a node without the sentinel passes (the positive control)" || fail "live: no sentinel refused: $out"

echo "cases: $cases, failures: $failures"
[ "$failures" -eq 0 ]
