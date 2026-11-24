#!/usr/bin/env bash
# The tests of script/deploy-betting.sh. They need no secret and no node of ours: a throwaway git repository with
# a made-up commit and plan, a plain local anvil on chain id 137 with no fork, the pinned cast behind a stand-in
# that adds what a test asks, and a stand-in forge that records what it was given and prints what a test asks. No
# line whose first word is live is run: live mode's refusals are proved on the wrapper's own check functions,
# sourced with made-up values.
#
#   bash script/test-deploy-betting.sh
#   bash script/test-deploy-betting.sh console <forge's printed output> <the known hashes> [<a test's name>]
#
# Each refusal is proved beside a positive control that passes the same check, so a check that refuses
# everything cannot pass. Prints one line per case and exits non-zero on any failure.
#
# The second form checks the script's own console, as forge printed it in a run of test/betting/DeployBetting.t.sol,
# against the hashes that test derived for itself and wrote beside its plan: no http, and no 64-hex word that is not
# one of them. A test cannot read the console itself: forge answers the console's calls before any cheatcode sees one.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="$HERE/deploy-betting.sh"
PINNED="80ae59941ada986c49e05f2a8412c3fc1f9075d0"
SENTINEL="0xE06B6A8ff1a62CF18ca244EeCb4c43c5a803a4F6"
DEPLOYER="0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30"
FORK_GO="0x9575ee8093561ec60b3c163aea383818"
MADE_UP_NODE="https://made-up-node.example.invalid/v2/abcdefghijklmnop0123456789"
# Every variable from which the pinned forge and cast take a signer, read in their source at the pin: the four the
# wallet options read with no flag, and the cloud signers' with --aws, --gcp or --turnkey.
SIGNER_VARIABLES=(ETH_FROM ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD AWS_KMS_KEY_ID AWS_KMS_KEY_IDS GCP_PROJECT_ID
    GCP_LOCATION GCP_KEY_RING GCP_KEY_NAME GCP_KEY_VERSION TURNKEY_API_PRIVATE_KEY TURNKEY_ORGANIZATION_ID TURNKEY_ADDRESS)
# The ten other settings the pinned forge and cast read from the environment, none of them a signer: a send's tip,
# price, gas and blob price; the waits; the headers and the token sent to the node; the explorer's key; the chain.
# Each planted value is made up, and each parses, so a run that let them through would still reach forge.
OTHER_PLANTED=(ETH_PRIORITY_GAS_PRICE=1 ETH_GAS_PRICE=1 ETH_GAS_LIMIT=1000000 ETH_BLOB_GAS_PRICE=1 ETH_TIMEOUT=45
    ETH_RPC_TIMEOUT=45 "ETH_RPC_HEADERS=X-Made-Up: a-made-up-value"
    ETH_RPC_JWT_SECRET=abababababababababababababababababababababababababababababababab ETHERSCAN_API_KEY=a-made-up-key
    CHAIN=137)

# forge, cast and anvil read a .env file in the working folder and in the project's root before any flag, and it
# can name a signer. One there stops the tests before any tool starts, the version reads included. It is never
# opened.
for dir in "$(pwd)" "$(cd "$HERE/.." && pwd)"; do
    [ ! -e "$dir/.env" ] || { echo "a .env file in $dir: forge, cast and anvil would read it before any flag"; exit 2; }
done

# ── The script's console ──────────────────────────────────────────────────────────────────────────────────────────

# console_check <forge's printed output> <the known hashes, one to a line> [<a test's name>]: the console holds no
# http, and no 64-hex word that is not one of the known hashes. A 64-hex word is a run of exactly 64 hex digits, with
# or without 0x; an address and a call's bytes are not one. With a test's name, only that test's lines are read.
# It prints counts, never a word it refuses.
console_check() {
    local output="$1" known="$2" name="${3:-}" text http words found unknown
    [ -f "$output" ] && [ -f "$known" ] || { echo "console: it needs forge's output and the known hashes"; return 2; }
    if [ -n "$name" ]; then
        text=$(awk -v n="[PASS] $name(" 'index($0, n) == 1 { on = 1; next } on && /^(\[PASS\]|\[FAIL|Suite result|Ran [0-9])/ { on = 0 } on' "$output")
        [ -n "$text" ] || { echo "console: no lines of $name in the output"; return 2; }
    else
        text=$(cat "$output")
    fi
    http=$(printf '%s\n' "$text" | grep -ci 'http' || true)
    words=$(printf '%s\n' "$text" | perl -ne 'while (/(?<![0-9A-Fa-f])(?:0x)?([0-9A-Fa-f]{64})(?![0-9A-Fa-f])/g) { print lc("0x$1"), "\n" }')
    found=$(printf '%s\n' "$words" | grep -c . || true)
    unknown=$(printf '%s\n' "$words" | grep . | grep -cvixF -f <(tr -d '\r' < "$known" | grep .) || true)
    echo "console: $(printf '%s\n' "$text" | wc -l | tr -d ' ') lines; http in $http; 64-hex words $found, not known $unknown"
    [ "$http" -eq 0 ] && [ "$unknown" -eq 0 ]
}

if [ "${1:-}" = console ]; then
    shift
    console_check "$@"
    exit $?
fi

REAL_CAST="$(command -v cast)"
REAL_ANVIL="$(command -v anvil)"
[ -n "$REAL_CAST" ] && [ -n "$REAL_ANVIL" ] || { echo "the tests need cast and anvil on the PATH"; exit 2; }
"$REAL_CAST" --version | grep -q "^Commit SHA: $PINNED$" || { echo "the tests need the pinned cast ($PINNED)"; exit 2; }

TMP="$(mktemp -d)"
REPO="$TMP/repo"
STUB="$TMP/bin"
RECORD="$TMP/forge-record.txt"
# Every start of the stand-in forge, its version line included.
STARTS="$TMP/forge-starts.txt"
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
[ -n "${STUB_STARTS:-}" ] && echo "started: $*" >> "$STUB_STARTS"
if [ "${1:-}" = "--version" ]; then
    echo "forge Version: 1.6.0-nightly"
    echo "Commit SHA: ${STUB_FORGE_COMMIT}"
    exit 0
fi
{
    echo "args: $*"
    for v in ETH_FROM ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD AWS_KMS_KEY_ID AWS_KMS_KEY_IDS GCP_PROJECT_ID \
        GCP_LOCATION GCP_KEY_RING GCP_KEY_NAME GCP_KEY_VERSION TURNKEY_API_PRIVATE_KEY TURNKEY_ORGANIZATION_ID \
        TURNKEY_ADDRESS ETH_RPC_URL FOUNDRY_ETH_RPC_URL ETH_PRIORITY_GAS_PRICE ETH_GAS_PRICE ETH_GAS_LIMIT \
        ETH_BLOB_GAS_PRICE ETH_TIMEOUT ETH_RPC_TIMEOUT ETH_RPC_HEADERS ETH_RPC_JWT_SECRET ETHERSCAN_API_KEY CHAIN \
        STUB_PROBE; do
        if [ -n "${!v+x}" ]; then echo "env $v: set"; else echo "env $v: absent"; fi
    done
    echo "TEMPO_HOME entries: $(ls -A "${TEMPO_HOME:-/nonexistent}" 2>/dev/null | wc -l | tr -d ' ')"
    echo "env prefixed: $(compgen -e | grep -E '^(FOUNDRY_|DAPP_)' | sort | tr '\n' ' ' | sed 's/ $//')"
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
# A sending run: forge keeps its record of the sends, each with the node it was sent to, under
# <its cache folder>/<the script's file>/<chain>/, as forge 80ae599 does: cache/, or FOUNDRY_CACHE_PATH when it is
# set. The stand-in plants a made-up node there.
case "$*" in
    *--broadcast*)
        seq_dir="${FOUNDRY_CACHE_PATH:-cache}/DeployBetting.s.sol/137"
        mkdir -p "$seq_dir"
        echo '{"transactions":[{"rpc":"https://made-up-node.example.invalid/sequence"}]}' > "$seq_dir/run-latest.json"
        echo "forge's record of the sends written" >> "$STUB_RECORD"
        ;;
esac
[ -n "${STUB_FORGE_FAIL:-}" ] && exit 1
exit 0
STUBEOF
# The pinned cast, after what a test asks of it: a planted line on its error stream, a balance read that fails, a
# client of its own, no anvil method, another commit line.
printf '#!/usr/bin/env bash\nREAL_CAST=%q\n' "$REAL_CAST" > "$STUB/cast"
cat >> "$STUB/cast" <<'STUBEOF'
# A planted line on the error stream: at every read, or only at the one STUB_CAST_ERR_ON names.
if [ -n "${STUB_CAST_ERR:-}" ] && { [ -z "${STUB_CAST_ERR_ON:-}" ] || [ "${1:-}" = "$STUB_CAST_ERR_ON" ]; }; then
    echo "cast errs: $STUB_CAST_ERR" >&2
fi
# The read STUB_CAST_FAIL names fails, its error naming the node STUB_CAST_FAIL_AT.
if [ -n "${STUB_CAST_FAIL:-}" ] && [ "${1:-}" = "$STUB_CAST_FAIL" ]; then
    echo "Error: the $1 read failed at ${STUB_CAST_FAIL_AT:-a made-up node}" >&2
    exit 1
fi
case "${1:-}" in
    --version)
        if [ -n "${STUB_CAST_COMMIT:-}" ]; then echo "cast Version: 1.6.0-nightly"; echo "Commit SHA: $STUB_CAST_COMMIT"; exit 0; fi ;;
    client)
        if [ -n "${STUB_CAST_CLIENT:-}" ]; then echo "$STUB_CAST_CLIENT"; exit 0; fi ;;
    rpc)
        if [ "${2:-}" = anvil_nodeInfo ] && [ -n "${STUB_CAST_NO_ANVIL:-}" ]; then
            echo "Error: the method anvil_nodeInfo does not exist" >&2
            exit 1
        fi ;;
esac
exec "$REAL_CAST" "$@"
STUBEOF
chmod +x "$STUB/forge" "$STUB/cast"

cp "$WRAPPER_SRC" "$REPO/script/deploy-betting.sh"
echo "// a stand-in for the script, in the throwaway repository" > "$REPO/script/DeployBetting.s.sol"
printf '[profile.default]\nsrc = "src"\n\n[profile.ci]\nsolc = "0.8.26"\n' > "$REPO/foundry.toml"
printf 'forge-std/=lib/forge-std/src/\n' > "$REPO/remappings.txt"
# The real repository ignores .env files and forge's cache too, so neither leaves the tree unclean.
printf 'deployments/\n.env\ncache/\n' > "$REPO/.gitignore"
git -C "$REPO" init -q
# One submodule, so the manifest's record of it is tested: a one-commit repository beside the throwaway one.
SUBSRC="$TMP/a-library"
git init -q "$SUBSRC"
echo "a made-up library" > "$SUBSRC/README"
git -C "$SUBSRC" -c user.name=test -c user.email=test@example.invalid add README
git -C "$SUBSRC" -c user.name=test -c user.email=test@example.invalid commit -q -m "a made-up library"
SUB_COMMIT="$(git -C "$SUBSRC" rev-parse HEAD)"
git -C "$REPO" -c protocol.file.allow=always submodule add -q "$SUBSRC" lib/a-library > /dev/null 2>&1
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
    (cd "$REPO" && env DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_STARTS="$STARTS" \
        STUB_FORGE_COMMIT="${STUB_FORGE_COMMIT:-$PINNED}" bash script/deploy-betting.sh "$@")
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
    && grep -q -- "--no-storage-caching" "$RECORD" && grep -q "FOUNDRY_PROFILE: ci" "$RECORD" \
    && ok "predict ran forge with --skip test, no storage cache, the ci profile and CI's flags" \
    || fail "predict's forge line: $(cat "$RECORD")"
MANIFEST="$REPO/deployments/betting-set/137/manifest.json"
if grep -qF "\"submodule.lib/a-library\": \"$SUB_COMMIT\"" "$MANIFEST"; then
    ok "the manifest records the submodule's commit under its path"
else
    fail "the manifest's submodule lines: $(grep submodule "$MANIFEST")"
fi

# A git status that fails says nothing about the tree: an index git cannot read, with HEAD still readable.
cp "$REPO/.git/index" "$TMP/index.kept"
printf 'not an index\n' > "$REPO/.git/index"
expect_refused "a git status that fails" "git status failed" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
cp "$TMP/index.kept" "$REPO/.git/index"
expect_passed "the index restored, the same predict (the positive control)" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
STUB_CAST_COMMIT="0000000000000000000000000000000000000000" \
    expect_refused "another cast's commit line, forge's the pinned one" "cast's commit line is not the pinned one" \
    fork predict "$HEAD_COMMIT" --rpc-url "$NODE"

# A .env file is read by forge, cast and anvil before any flag, and it can name a signer. An ignored one in the
# project's root is refused before any of them starts, and the clean tree does not hide it.
printf 'ETH_KEYSTORE_ACCOUNT=a-made-up-wallet\n' > "$REPO/.env"
: > "$STARTS"
expect_refused "an ignored .env in the project's root" "a .env file in" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
if [ ! -s "$STARTS" ]; then ok "the .env refusal: forge never started"; else fail "the .env refusal: forge started: $(cat "$STARTS")"; fi
rm -f "$REPO/.env"
: > "$STARTS"
expect_passed "no .env, the same tree (the positive control)" fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE"
if [ -s "$STARTS" ]; then ok "the positive control: forge started"; else fail "the positive control: forge never started"; fi
expect_refused "an unknown stage" "unknown stage '4'" fork check "0x$(printf '%040d' 1)" 1 4 --rpc-url "$NODE"
: > "$RECORD"
expect_passed "a known stage (the positive control)" fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE"

# A .env in the folder the wrapper is started from, below the project's root and not in it: refused before any tool
# starts. The same folder with none passes the same check, sourced.
printf 'ETH_KEYSTORE_ACCOUNT=a-made-up-wallet\n' > "$REPO/script/.env"
: > "$STARTS"
out=$(cd "$REPO/script" && env DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_STARTS="$STARTS" \
    STUB_FORGE_COMMIT="$PINNED" bash deploy-betting.sh fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE" 2>&1)
status=$?
if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -F "REFUSED:" | grep -qF "a .env file in $REPO/script" && [ ! -s "$STARTS" ]; then
    ok "a .env in a folder below the root, where the wrapper starts: refused, and forge never started"
else
    fail "a .env below the root (exit $status): $out; started: $(cat "$STARTS")"
fi
rm -f "$REPO/script/.env"
out=$(cd "$REPO/script" && bash -c 'source ./deploy-betting.sh; require_no_dotenv' 2>&1) \
    && ok "no .env below the root: the same check passes (the positive control)" || fail "no .env below the root: $out"

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

# Every variable from which the pinned forge and cast take a signer, each planted with a made-up value: forge runs
# with none of them.
: > "$RECORD"
planted=()
for v in "${SIGNER_VARIABLES[@]}"; do planted+=("$v=a-made-up-value"); done
(cd "$REPO" && env "${planted[@]}" DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" STUB_PROBE=1 \
    bash script/deploy-betting.sh fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE" > /dev/null 2>&1)
reached=0
for v in "${SIGNER_VARIABLES[@]}"; do grep -q "env $v: absent" "$RECORD" || reached=$((reached + 1)); done
if grep -q "env STUB_PROBE: set" "$RECORD" && [ "$reached" -eq 0 ]; then
    ok "each of the ${#SIGNER_VARIABLES[@]} signer variables set: forge runs with none of them"
else
    fail "each of the ${#SIGNER_VARIABLES[@]} signer variables set: $reached of them reached forge: $(grep '^env' "$RECORD")"
fi

# The two node defaults forge and cast would take when a line names no node, planted: forge runs with neither.
: > "$RECORD"
(cd "$REPO" && env ETH_RPC_URL="$MADE_UP_NODE" FOUNDRY_ETH_RPC_URL="$MADE_UP_NODE" DEPLOY_FOUNDRY_BIN="$STUB" \
    STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" STUB_PROBE=1 \
    bash script/deploy-betting.sh fork check "0x$(printf '%040d' 1)" 1 3 --rpc-url "$NODE" > /dev/null 2>&1)
if grep -q "env STUB_PROBE: set" "$RECORD" && grep -q "env ETH_RPC_URL: absent" "$RECORD" \
    && grep -q "env FOUNDRY_ETH_RPC_URL: absent" "$RECORD"; then
    ok "both node defaults set: forge runs with neither"
else
    fail "a node default reached forge: $(grep '^env' "$RECORD")"
fi

# The ten other settings, each planted: none reaches forge, on a run that does not send and on one that does.
for line in "check 0x$(printf '%040d' 1) 1 3" "create $D32 1"; do
    : > "$RECORD"
    # shellcheck disable=SC2086
    (cd "$REPO" && env "${OTHER_PLANTED[@]}" DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" \
        STUB_PROBE=1 bash script/deploy-betting.sh fork $line --rpc-url "$NODE" > /dev/null 2>&1)
    reached=0
    for planted in "${OTHER_PLANTED[@]}"; do grep -q "env ${planted%%=*}: absent" "$RECORD" || reached=$((reached + 1)); done
    if grep -q "env STUB_PROBE: set" "$RECORD" && [ "$reached" -eq 0 ]; then
        ok "each of the ten other settings set, fork ${line%% *}: forge runs with none of them"
    else
        fail "each of the ten other settings set, fork ${line%% *}: $reached of them reached forge: $(grep '^env' "$RECORD" | tr '\n' ' ')"
    fi
done

# Every FOUNDRY_ and DAPP_ variable, which forge's config loader reads as any of its settings: the cache's folder,
# a node header, as a list the loader parses, the explorer's key in its DAPP_ form, and a made-up name under each
# prefix. Forge runs with none but the two the wrapper sets itself, on a run that does not send and on one that does.
PREFIX_PLANTED=("FOUNDRY_CACHE_PATH=$TMP/elsewhere-cache" 'FOUNDRY_ETH_RPC_HEADERS=["X-Made-Up: a-made-up-value"]'
    DAPP_ETHERSCAN_API_KEY=a-made-up-key FOUNDRY_A_MADE_UP_NAME=1 DAPP_A_MADE_UP_NAME=1)
for line in "check 0x$(printf '%040d' 1) 1 3" "create $D32 1"; do
    : > "$RECORD"
    # shellcheck disable=SC2086
    (cd "$REPO" && env "${PREFIX_PLANTED[@]}" DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" \
        STUB_PROBE=1 bash script/deploy-betting.sh fork $line --rpc-url "$NODE" > /dev/null 2>&1)
    seen=$(sed -n 's/^env prefixed: //p' "$RECORD" | tail -1)
    if grep -q "env STUB_PROBE: set" "$RECORD" && [ "$seen" = "FOUNDRY_DISABLE_NIGHTLY_WARNING FOUNDRY_PROFILE" ]; then
        ok "every FOUNDRY_ and DAPP_ variable set, fork ${line%% *}: forge runs with none but the wrapper's own"
    else
        fail "every FOUNDRY_ and DAPP_ variable set, fork ${line%% *}: forge ran with: $seen"
    fi
done
rm -rf "$TMP/elsewhere-cache"

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

# The manifest holds labels only: the node's role and the signer's method, never a node's address. A made-up node
# value that forge prints on a manifest line reaches the manifest only as the filter's label.
(cd "$REPO" && env DEPLOY_FOUNDRY_BIN="$STUB" STUB_RECORD="$RECORD" STUB_FORGE_COMMIT="$PINNED" \
    POLYGON_RPC_URL="$MADE_UP_NODE" STUB_EMIT="manifest.declared.planted: $MADE_UP_NODE" \
    bash script/deploy-betting.sh fork predict "$HEAD_COMMIT" --rpc-url "$NODE" > /dev/null 2>&1)
if grep -qF '"planted": "<POLYGON_RPC_URL>"' "$MANIFEST"; then
    ok "the planted manifest line reached the manifest as the filter's label (the positive control)"
else
    fail "the planted manifest line: $(grep planted "$MANIFEST")"
fi
if grep -qF '"node": "fork"' "$MANIFEST" && grep -qF '"signer": "unlocked impersonation on the fork"' "$MANIFEST" \
    && ! grep -q -e "made-up-node" -e "abcdefghijklmnop" -e "127\.0\.0\.1" "$MANIFEST"; then
    ok "the manifest holds the node's and the signer's labels, and no node address"
else
    fail "the manifest's node fields: $(grep -e node -e signer -e planted "$MANIFEST")"
fi

# ── Every cast read, through the filter, and its status checked ───────────────────────────────────────────────

# leaked <text>: true when a made-up node's value is in the text, the screen's, the kept logs' or the manifest's.
leaked() { printf '%s' "$1" | grep -q -e "made-up-node" -e "abcdefghijklmnop"; }
kept_and_manifest() { cat "$REPO"/deployments/betting-set/137/runs/*.log "$MANIFEST" 2>/dev/null; }

# A cast that prints the planted node on its error stream at every read: setup's and predict's reads included.
rm -rf "$REPO/deployments/betting-set/137/runs"
screen=$( (POLYGON_RPC_URL="$MADE_UP_NODE" STUB_CAST_ERR="$MADE_UP_NODE" wrap fork setup --rpc-url "$NODE";
    POLYGON_RPC_URL="$MADE_UP_NODE" STUB_CAST_ERR="$MADE_UP_NODE" wrap fork predict "$HEAD_COMMIT" --rpc-url "$NODE") 2>&1)
if printf '%s' "$screen" | grep -q "cast errs: <POLYGON_RPC_URL>"; then
    ok "cast's error stream reached the screen as the filter's label (the positive control)"
else
    fail "cast's planted line did not pass the filter: $screen"
fi
if leaked "$screen" || leaked "$(kept_and_manifest)"; then
    fail "cast's error stream: a made-up node address reached the screen, the kept log or the manifest"
else
    ok "cast's error stream: a made-up node address in neither the screen, the kept log nor the manifest"
fi

# Each read's own error stream, alone: it reaches the screen as the filter's label, and its value nowhere.
for read in code chain-id client; do
    rm -rf "$REPO/deployments/betting-set/137/runs"
    screen=$(POLYGON_RPC_URL="$MADE_UP_NODE" STUB_CAST_ERR="$MADE_UP_NODE" STUB_CAST_ERR_ON="$read" \
        wrap fork predict "$HEAD_COMMIT" --rpc-url "$NODE" 2>&1)
    if printf '%s' "$screen" | grep -q "cast errs: <POLYGON_RPC_URL>" && ! leaked "$screen" && ! leaked "$(kept_and_manifest)"; then
        ok "the $read read's error stream: on the screen as the filter's label, its value nowhere"
    else
        fail "the $read read's error stream: $(printf '%s' "$screen" | sed 's/made-up-node[^ ]*/<the planted node>/g')"
    fi
done

# refused_and_unleaked <case> <the read that fails> <words of the refusal> <wrapper arguments...>: refused by name,
# with no written report, and no made-up node anywhere. The stand-in cast's read fails, naming the planted node.
refused_and_unleaked() {
    local name="$1" read="$2" words="$3" out status
    shift 3
    out=$(POLYGON_RPC_URL="$MADE_UP_NODE" STUB_CAST_FAIL="$read" STUB_CAST_FAIL_AT="$MADE_UP_NODE" wrap "$@" 2>&1); status=$?
    if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -F "REFUSED:" | grep -qF "$words" \
        && ! printf '%s' "$out" | grep -q "^written: " && ! leaked "$out" && ! leaked "$(kept_and_manifest)"; then
        ok "$name"
    else
        fail "$name (exit $status): $(printf '%s' "$out" | sed 's/made-up-node[^ ]*/<the planted node>/g')"
    fi
}
refused_and_unleaked "setup's balance read fails: refused, nothing leaked" balance "the deployer's balance could not be read" \
    fork setup --rpc-url "$NODE"
refused_and_unleaked "predict's balance read fails: refused, no manifest written, nothing leaked" balance \
    "the deployer's balance could not be read" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
refused_and_unleaked "predict's client read fails: refused, no manifest written, nothing leaked" client \
    "the node's client version could not be read" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
expect_passed "the same predict, every read answered (the positive control)" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
grep -qE '"deployer\.balanceAtPlan": "[0-9]+"' "$MANIFEST" && grep -qE '"anvil\.version": "anvil' "$MANIFEST" \
    && ok "the balance at the plan, a number, and the node's client are in the manifest" \
    || fail "the balance and the client at the plan: $(grep -e balanceAtPlan -e anvil.version "$MANIFEST")"

# ── A fork's top-up, in the manifest when setup runs before the first predict ─────────────────────────────────

rm -rf "$REPO/deployments/betting-set/137"
"$REAL_CAST" rpc anvil_setBalance "$DEPLOYER" 0x1 --rpc-url "$NODE" > /dev/null
expect_passed "setup on a fresh checkout, the deployer short" fork setup --rpc-url "$NODE"
expect_passed "the first predict after it" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
if grep -qF '"fork.topUp": "1 -> 20000000000000000000"' "$MANIFEST"; then
    ok "the top-up before the first predict is in the manifest, from and to"
else
    fail "the top-up before the first predict: $(grep -i topup "$MANIFEST")"
fi
rm -rf "$REPO/deployments/betting-set/137"
expect_passed "setup on a fresh checkout, the deployer funded" fork setup --rpc-url "$NODE"
expect_passed "the first predict after it, again" fork predict "$HEAD_COMMIT" --rpc-url "$NODE"
if grep -qF '"fork.topUp": "none: the deployer held 20000000000000000000 wei"' "$MANIFEST"; then
    ok "no top-up: the manifest says none (the control)"
else
    fail "no top-up: $(grep -i topup "$MANIFEST")"
fi

# ── forge's own record of the sends, which keeps the node: gone when forge returns ────────────────────────────

SEQUENCE="$REPO/cache/DeployBetting.s.sol"
mkdir -p "$REPO/cache"
echo '{"a made-up compiler cache": true}' > "$REPO/cache/solidity-files-cache.json"
: > "$RECORD"
expect_passed "a sending run that succeeds" fork create "$D32" 1 --rpc-url "$NODE"
# Polygon charges more for a cold storage read than the pinned forge counts: each send's gas limit is twice forge's
# own count.
if grep -q -- "--gas-estimate-multiplier 200" "$RECORD"; then
    ok "a sending run gives each send twice forge's own gas count as its limit"
else
    fail "a sending run gives each send twice forge's own gas count as its limit: $(grep '^args' "$RECORD")"
fi
if grep -q "forge's record of the sends written" "$RECORD" && [ ! -e "$SEQUENCE" ]; then
    ok "after a sending run that succeeded: forge's record of the sends is gone"
else
    fail "after a sending run that succeeded: $(ls -R "$SEQUENCE" 2>&1)"
fi
: > "$RECORD"
out=$(STUB_FORGE_FAIL=1 wrap fork create "$D32" 1 --rpc-url "$NODE" 2>&1); status=$?
if [ "$status" -ne 0 ] && grep -q "forge's record of the sends written" "$RECORD" && [ ! -e "$SEQUENCE" ]; then
    ok "after a sending run that failed: forge's record of the sends is gone"
else
    fail "after a sending run that failed (exit $status): $(ls -R "$SEQUENCE" 2>&1)"
fi
[ -f "$REPO/cache/solidity-files-cache.json" ] && ok "the compiler's cache beside it stays (the control)" \
    || fail "the compiler's cache was removed"
# The same two runs with FOUNDRY_CACHE_PATH planted: the record of the sends is gone from both folders after each.
ELSEWHERE="$TMP/elsewhere-cache"
: > "$RECORD"
FOUNDRY_CACHE_PATH="$ELSEWHERE" expect_passed "a sending run with FOUNDRY_CACHE_PATH planted" fork create "$D32" 1 --rpc-url "$NODE"
if grep -q "forge's record of the sends written" "$RECORD" && [ ! -e "$SEQUENCE" ] && [ ! -e "$ELSEWHERE/DeployBetting.s.sol" ]; then
    ok "FOUNDRY_CACHE_PATH planted, after a sending run that succeeded: forge's record of the sends is gone"
else
    fail "FOUNDRY_CACHE_PATH planted, after a sending run that succeeded: $(ls -R "$ELSEWHERE" "$SEQUENCE" 2>&1 | head -4 | tr '\n' ' ')"
fi
: > "$RECORD"
out=$(FOUNDRY_CACHE_PATH="$ELSEWHERE" STUB_FORGE_FAIL=1 wrap fork create "$D32" 1 --rpc-url "$NODE" 2>&1); status=$?
if [ "$status" -ne 0 ] && grep -q "forge's record of the sends written" "$RECORD" && [ ! -e "$SEQUENCE" ] \
    && [ ! -e "$ELSEWHERE/DeployBetting.s.sol" ]; then
    ok "FOUNDRY_CACHE_PATH planted, after a sending run that failed: forge's record of the sends is gone"
else
    fail "FOUNDRY_CACHE_PATH planted, after a sending run that failed (exit $status): $(ls -R "$ELSEWHERE" "$SEQUENCE" 2>&1 | head -4 | tr '\n' ' ')"
fi
rm -rf "$ELSEWHERE"
refused_and_unleaked "a sending run whose go hash fails: refused, nothing leaked" keccak \
    "the go value's hash could not be computed" fork create "$D32" 1 --rpc-url "$NODE"
grep -qE '"go\.create": "keccak256 0x[0-9a-f]{64}"' "$MANIFEST" \
    && ok "a sending run that succeeded recorded the go value's hash (the control)" \
    || fail "the go value's hash in the manifest: $(grep go.create "$MANIFEST")"

# ── compare ───────────────────────────────────────────────────────────────────────────────────────────────────

M="$TMP/m"
mkdir -p "$M"
manifest() {
    printf '{\n  "mustEqual": {\n    "commit": "%s",\n    "digest": "%s"\n  },\n  "declared": {\n    "node": "%s"\n  }\n}\n' "$1" "$2" "$3"
}
manifest c1 d1 fork > "$M/a.json"
manifest c1 d1 live > "$M/b.json"
manifest c1 d2 fork > "$M/c.json"
manifest c2 d1 fork > "$M/d.json"
(cd "$REPO" && bash script/deploy-betting.sh compare "$M/a.json" "$M/b.json" > /dev/null 2>&1) && ok "compare: a declared difference alone is equal" || fail "compare refused a declared difference"
(cd "$REPO" && bash script/deploy-betting.sh compare "$M/a.json" "$M/c.json" > /dev/null 2>&1) && fail "compare passed a must-equal difference" || ok "compare: a must-equal difference fails"
(cd "$REPO" && bash script/deploy-betting.sh compare "$M/a.json" "$M/d.json" > /dev/null 2>&1) && fail "compare passed a differing commit" || ok "compare: a differing commit alone fails"

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

# This machine's own address, in each of its spellings, refused in live mode; a node elsewhere passes the same check.
for own in "http://127.0.0.1:8545" "http://localhost:8545" "http://[::1]:8545" "https://LOCALHOST/" "ws://127.0.0.1:8546" \
    "http://127.0.0.2:8545"; do
    out=$(live_check "RPC_URL='$own'; require_not_loopback")
    [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "live mode on this machine's own address" \
        && ok "live: this machine's own address refused, as $own" || fail "live: this machine's own address refused, as $own: $out"
done
out=$(live_check "RPC_URL='$MADE_UP_NODE'; require_not_loopback"); [ $? -eq 0 ] \
    && ok "live: a node elsewhere passes (the positive control)" || fail "live: a node elsewhere refused: $out"

# A local test node, a fork that never ran setup: the suite's own anvil is refused by its client version; a client
# that does not say anvil is refused when the node answers anvil's own method; one that does neither passes.
out=$(live_check "RPC_URL=$NODE; require_not_test_node"); [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "the node's client" \
    && ok "live: a node whose client names anvil refused" || fail "live: a node whose client names anvil refused: $out"
out=$(STUB_CAST_CLIENT="bor/v2.2.9-stable/linux-amd64/go1.24" live_check "RPC_URL=$NODE; require_not_test_node")
[ $? -ne 0 ] && printf '%s' "$out" | grep -qF "answers anvil_nodeInfo" \
    && ok "live: another client that answers anvil_nodeInfo refused" || fail "live: another client that answers anvil_nodeInfo refused: $out"
out=$(STUB_CAST_CLIENT="bor/v2.2.9-stable/linux-amd64/go1.24" STUB_CAST_NO_ANVIL=1 live_check "RPC_URL=$NODE; require_not_test_node")
[ $? -eq 0 ] && ok "live: a client that is not a test node, with no anvil method, passes (the positive control)" \
    || fail "live: a node that is not a test node refused: $out"

# ── The script's console check, on harmless fixtures ──────────────────────────────────────────────────────────

CON="$TMP/console"
mkdir -p "$CON"
KNOWN_WORD="0x$(printf '%064d' 0 | tr 0 a)"
OTHER_WORD="0x$(printf '%064d' 0 | tr 0 b)"
printf '%s\n' "$KNOWN_WORD" > "$CON/known.txt"
# made_up_console <a line in the test's logs, or none>: forge's printed output of a made-up test.
made_up_console() {
    echo "Ran 1 test for test/betting/DeployBetting.t.sol:DeployBettingForkTest"
    echo "[PASS] test_aMadeUpRun() (gas: 1)"
    echo "Logs:"
    echo "  the plan's digest $KNOWN_WORD"
    echo "  deployer $DEPLOYER at nonce 4356"
    echo "  for K to send to the timelock (schedule): 0x$(printf '%0200d' 0 | tr 0 c)"
    [ -n "${1:-}" ] && echo "  $1"
    echo ""
    echo "Suite result: ok. 1 passed; 0 failed; 0 skipped"
}
made_up_console > "$CON/clean.txt"
console_check "$CON/clean.txt" "$CON/known.txt" test_aMadeUpRun > /dev/null \
    && ok "console: a clean console passes, an address and a call's bytes beside a known hash (the positive control)" \
    || fail "console: a clean console refused: $(console_check "$CON/clean.txt" "$CON/known.txt" test_aMadeUpRun)"
made_up_console "read from $MADE_UP_NODE" > "$CON/http.txt"
console_check "$CON/http.txt" "$CON/known.txt" test_aMadeUpRun > /dev/null \
    && fail "console: a planted http line passed" || ok "console: a planted http line refused"
made_up_console "a made-up word $OTHER_WORD" > "$CON/word.txt"
console_check "$CON/word.txt" "$CON/known.txt" test_aMadeUpRun > /dev/null \
    && fail "console: a planted 64-hex word passed" || ok "console: a planted 64-hex word that is not a known hash refused"
printf '%s\n' "$OTHER_WORD" >> "$CON/known.txt"
console_check "$CON/word.txt" "$CON/known.txt" test_aMadeUpRun > /dev/null \
    && ok "console: the same word, once it is a known hash, passes (the control)" || fail "console: a known word refused"

echo "cases: $cases, failures: $failures"
[ "$failures" -eq 0 ]
