#!/usr/bin/env bash
# The one way the betting set's deploy script is run: on a local fork for the rehearsal, and on the chain on deploy
# day. Every phase of script/DeployBetting.s.sol goes through here.
#
#   script/deploy-betting.sh fork setup                               --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh fork predict   <commit>                  --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh fork create    <digest> <maxFee>         --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh fork bootstrap <digest> <maxFee>         --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh fork finalize  <digest> <maxFee>         --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh fork check     <core> <block> <stage>    --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh fork signpostCall <deployBlock>          --rpc-url http://127.0.0.1:<port>
#   script/deploy-betting.sh live <phase> ... <go> ...                --rpc-url <node> [--account <name>]
#   script/deploy-betting.sh compare <manifest a> <manifest b>
#
# In live mode a sending phase takes the go value before the maximum fee, and --account. <stage> is 1 (created),
# 2 (bootstrapped) or 3 (finalized). <maxFee> is the maximum fee per gas, in wei. --timeout <seconds> may follow a
# sending phase: forge's wait for each receipt.
#
# Before every phase it refuses unless: HEAD is the commit (the plan's, once a plan exists); the tree is clean,
# submodules included, by a git status that succeeded; forge's and cast's commit line is the pinned one; the
# profile is ci, with CI's flags; the node is named on the line and not inherited; no signer, none of the other
# settings forge and cast read from the environment and no FOUNDRY_ or DAPP_ variable comes from it; and no .env
# file sits where forge would read one. forge keeps no storage cache of the node it
# reads, and the record of the sends it keeps under cache/, which holds the node, is removed when forge returns. In
# fork mode the node must be this machine's loopback, so nothing of the rehearsal can reach a live node, and the
# sentinel's code must be on it after setup. In live mode the node must be neither this machine's own address, in
# any of its spellings, nor a local test node; the sentinel must be absent; and the go value must not be the fork's.
#
# Every line forge and cast write, on the output and the error stream, passes the filter before it reaches the
# screen or the run's log: each node address it knows (the line's own, POLYGON_RPC_URL, ETHEREUM_RPC_URL) is
# replaced, with its host and the long parts of its path. A cast read's status is checked, and its answer passes
# the filter before anything keeps it. No unfiltered log is kept. The wrapper holds no keystore name, no node
# address and no go value: those exist only on a command line.
set -euo pipefail

PINNED_FOUNDRY_COMMIT="80ae59941ada986c49e05f2a8412c3fc1f9075d0"
# The first sixteen bytes of keccak256("fork"): the fork's go value, a fixture, refused in live mode.
FORK_GO="0x9575ee8093561ec60b3c163aea383818"
DEPLOYER="0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30"
# address(uint160(uint256(keccak256("ospex betting rehearsal sentinel")))): code only the local fork holds.
SENTINEL="0xE06B6A8ff1a62CF18ca244EeCb4c43c5a803a4F6"
SCRIPT="script/DeployBetting.s.sol:DeployBetting"
FORGE_FLAGS=(--via-ir --optimize)
# What the fork's deployer is topped up to, and only when it holds less: twice the spend bound, in wei.
FORK_TOP_UP_WEI="20000000000000000000"
# forge's record of a sending run's transactions, each with the node it was sent to, under the profile's cache
# folder: it is removed when forge returns. The record under broadcast/ holds no node and stays.
SEQUENCE_CACHE="cache/DeployBetting.s.sol"
# A send's gas limit is forge's own count of its gas, times this, in percent. Since Polygon's Chicago fork the chain
# charges more for a cold storage read than the pinned forge counts: the lock's estimate on the chain is 137% of
# forge's count. Twice forge's count, as the spend rule's reserve in hand is twice its sum.
GAS_MULTIPLIER=200
# Every variable from which the pinned forge and cast take a signer: the four the wallet options read with no flag,
# and the cloud signers' read with --aws, --gcp or --turnkey.
SIGNER_VARIABLES=(ETH_FROM ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD AWS_KMS_KEY_ID AWS_KMS_KEY_IDS GCP_PROJECT_ID
    GCP_LOCATION GCP_KEY_RING GCP_KEY_NAME GCP_KEY_VERSION TURNKEY_API_PRIVATE_KEY TURNKEY_ORGANIZATION_ID TURNKEY_ADDRESS)
# The ten other settings the pinned forge and cast read from the environment: a send's tip, price, gas and blob
# price; the waits; the headers and the token sent to the node; the explorer's key; the chain. None comes from it.
OTHER_VARIABLES=(ETH_PRIORITY_GAS_PRICE ETH_GAS_PRICE ETH_GAS_LIMIT ETH_BLOB_GAS_PRICE ETH_TIMEOUT ETH_RPC_TIMEOUT
    ETH_RPC_HEADERS ETH_RPC_JWT_SECRET ETHERSCAN_API_KEY CHAIN)

# The pinned forge's and cast's folder, from DEPLOY_FOUNDRY_BIN. Its name has no FOUNDRY_ prefix: every variable
# with that prefix is cleared before a phase.
DEPLOY_BIN_DIR="${DEPLOY_FOUNDRY_BIN:-}"
forge_bin() { if [ -n "$DEPLOY_BIN_DIR" ]; then echo "$DEPLOY_BIN_DIR/forge"; else echo forge; fi; }
cast_bin() { if [ -n "$DEPLOY_BIN_DIR" ]; then echo "$DEPLOY_BIN_DIR/cast"; else echo cast; fi; }

die() {
    echo "deploy-betting: REFUSED: $*" >&2
    exit 2
}

# ── The filter ────────────────────────────────────────────────────────────────────────────────────────────────

# Every node address the run knows, replaced before a line reaches a file or the screen: the address whole; its
# scheme and host; its host; each part of its path or query of twelve characters or more. The values are read
# from the environment inside perl and never printed.
filter() {
    DEPLOY_FILTER_NODE="${RPC_URL:-}" perl -e '
        use strict; use warnings; $| = 1;
        my @pairs;
        for my $name ("DEPLOY_FILTER_NODE", "POLYGON_RPC_URL", "ETHEREUM_RPC_URL") {
            my $url = defined $ENV{$name} ? $ENV{$name} : "";
            next unless length $url;
            next if $url =~ m{^https?://127\.0\.0\.1(:[0-9]+)?/?$};
            my $label = $name eq "DEPLOY_FILTER_NODE" ? "NODE" : $name;
            push @pairs, [$url, "<$label>"];
            if ($url =~ m{^([A-Za-z][A-Za-z0-9+.-]*://([^/?#]+))(.*)$}) {
                my ($origin, $host, $rest) = ($1, $2, $3);
                push @pairs, [$origin, "<$label:origin>"];
                push @pairs, [$host, "<$label:host>"] if length($host) >= 4;
                for my $part (split m{[/?&=#]}, $rest) {
                    push @pairs, [$part, "<$label:part>"] if length($part) >= 12;
                }
            }
        }
        @pairs = sort { length($b->[0]) <=> length($a->[0]) } @pairs;
        my @compiled = map { [qr/\Q$_->[0]\E/, $_->[1]] } @pairs;
        while (my $line = <STDIN>) {
            for my $p (@compiled) { $line =~ s/$p->[0]/$p->[1]/g; }
            print $line;
        }
    '
}

# Runs a command with both of its streams through the filter, into the screen and the run's log. Returns the
# command's own exit status.
run_filtered() {
    local status
    set +e
    "$@" 2>&1 | filter | tee -a "$RUN_LOG"
    status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

# A cast read: its answer on the output stream, kept apart from its error stream, which passes the filter into the
# screen and the run's log. The answer passes the filter too. Returns cast's own status: the caller checks it.
cast_read() {
    local out status
    set +e
    out=$( { "$(cast_bin)" "$@" 2>&1 1>&3 3>&- | filter | tee -a "${RUN_LOG:-/dev/null}" >&2; exit "${PIPESTATUS[0]}"; } 3>&1 )
    status=$?
    set -e
    [ "$status" -eq 0 ] || return "$status"
    printf '%s' "$out" | filter
}

# ── The checks every phase makes ──────────────────────────────────────────────────────────────────────────────

require_commit_line() {
    local tool="$1" line
    line=$("$tool" --version 2>/dev/null | grep '^Commit SHA: ' || true)
    [ "$line" = "Commit SHA: $PINNED_FOUNDRY_COMMIT" ] || die "$tool's commit line is not the pinned one ($PINNED_FOUNDRY_COMMIT)"
}

# forge, cast and anvil read a .env file in the working folder and in the project's root before they read any
# flag, and it can name a signer. One there is refused before any of them starts; it is never opened here.
require_no_dotenv() {
    local dir root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    for dir in "$(pwd)" "$root"; do
        [ ! -e "$dir/.env" ] || die "a .env file in $dir: forge, cast and anvil would read it before any flag"
    done
}

require_clean_environment() {
    # Every variable whose name begins FOUNDRY_ or DAPP_, which forge's config loader reads as any of its settings,
    # before the wrapper sets its own.
    local v
    for v in $(compgen -v); do case "$v" in FOUNDRY_* | DAPP_*) unset "$v" ;; esac; done
    unset ETH_RPC_URL FOUNDRY_ETH_RPC_URL
    unset "${SIGNER_VARIABLES[@]}"
    unset "${OTHER_VARIABLES[@]}"
    WALLET_HOME=$(mktemp -d)
    trap 'rmdir "$WALLET_HOME" 2>/dev/null || true' EXIT
    export TEMPO_HOME="$WALLET_HOME"
    [ -z "$(ls -A "$TEMPO_HOME")" ] || die "the wallet home is not empty"
    export FOUNDRY_PROFILE=ci
    export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
}

require_tree() {
    local commit="$1"
    [ -n "$(git rev-parse --git-dir 2>/dev/null)" ] || die "not in a git checkout"
    [ "$(git rev-parse HEAD)" = "$commit" ] || die "HEAD is not the commit $commit"
    local status_out
    status_out=$(git status --porcelain --ignore-submodules=none 2>/dev/null) || die "git status failed: the tree's state is not known"
    [ -z "$status_out" ] || die "the tree is not clean"
}

require_rpc_given() {
    [ -n "${RPC_URL:-}" ] || die "no --rpc-url on the line"
}

require_loopback() {
    [[ "$RPC_URL" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || die "fork mode takes only this machine's loopback node, http://127.0.0.1:<port>"
}

# Live mode never uses this machine's own address, the rehearsal's node, however it is written: any of
# 127.0.0.0/8, localhost or [::1].
require_not_loopback() {
    local url
    url=$(printf '%s' "$RPC_URL" | tr 'A-Z' 'a-z')
    if [[ "$url" =~ ^[a-z][a-z0-9+.-]*://(127(\.[0-9]{1,3}){3}|localhost|\[::1\])([:/?#]|$) ]]; then
        die "live mode on this machine's own address: that is the rehearsal's node"
    fi
}

# Live mode refuses a local test node: a fork of Polygon has chain id 137 and no sentinel until setup runs on it.
# Its client version names anvil or hardhat, or it answers anvil's own method.
require_not_test_node() {
    local client
    client=$(cast_read client --rpc-url "$RPC_URL") || die "the node did not answer its client version"
    if printf '%s' "$client" | grep -qiE 'anvil|hardhat'; then
        die "the node's client, $client, is a local test node: a fork, not the chain"
    fi
    if cast_read rpc anvil_nodeInfo --rpc-url "$RPC_URL" > /dev/null 2>&1; then
        die "the node answers anvil_nodeInfo: a fork, not the chain"
    fi
}

sentinel_code() {
    local code
    code=$(cast_read code "$SENTINEL" --rpc-url "$RPC_URL") || die "the node did not answer the sentinel's read"
    printf '%s' "$code" | tr -d '[:space:]'
}

require_sentinel_present() {
    local code
    code=$(sentinel_code) || exit 2
    [ "$code" = "0x00" ] || die "the sentinel's code is not on the node: not the rehearsal's fork (run fork setup)"
}

require_sentinel_absent() {
    local code
    code=$(sentinel_code) || exit 2
    [ "$code" = "0x" ] || die "the node holds the sentinel's code: a fork, not the chain"
}

require_hex() {
    local value="$1" bytes="$2" what="$3"
    [[ "$value" =~ ^0x[0-9a-fA-F]{$((bytes * 2))}$ ]] || die "$what is not $bytes bytes of hex"
}

require_number() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "$2 is not a number"
}

# The go value: sixteen bytes, not zero; in live mode, not the fork's. It acknowledges that a value was given and
# authenticates nothing: on deploy day the operator reads the comment it names against the plan first.
require_go() {
    local mode="$1" go="$2"
    require_hex "$go" 16 "the go value"
    [[ "$go" =~ ^0x0+$ ]] && die "the go value is zero"
    if [ "$mode" = live ] && [ "$(echo "$go" | tr 'A-F' 'a-f')" = "$FORK_GO" ]; then
        die "the fork's go value in live mode"
    fi
    return 0
}

# True when the decimal a is below the decimal b, both with no leading zero: by length, then by digits.
less_than() {
    local a="$1" b="$2"
    if [ "${#a}" -ne "${#b}" ]; then [ "${#a}" -lt "${#b}" ]; else [[ "$a" < "$b" ]]; fi
}

plan_dir() {
    local chain
    chain=$(cast_read chain-id --rpc-url "$RPC_URL") || die "the node did not answer its chain id"
    chain=$(printf '%s' "$chain" | tr -d '[:space:]')
    [ "$chain" = "137" ] || die "the node's chain id is not 137"
    echo "deployments/betting-set/$chain"
}

# HEAD is the plan's commit, on a clean tree.
require_plan_commit() {
    local commit
    commit=$(plan_commit "$PLAN_DIR") || exit 2
    require_tree "$commit"
}

plan_commit() {
    local plan="$1/prediction.json" c
    [ -f "$plan" ] || die "no plan: run predict first"
    c=$(tr -d '\n\r ' < "$plan" | grep -o '"commit":"0x[0-9a-fA-F]\{40\}"' | sed 's/.*"0x/0x/; s/"$//' || true)
    [ -n "$c" ] || die "the plan has no commit"
    echo "${c#0x}"
}

# ── The manifest ──────────────────────────────────────────────────────────────────────────────────────────────

# manifest.json beside the plan, in two classes. It is rebuilt from manifest.lines, one "class<TAB>key<TAB>value"
# per line, each key once.
manifest_set() {
    local class="$1" key="$2" value="$3" lines="$PLAN_DIR/manifest.lines"
    touch "$lines"
    awk -F '\t' -v k="$key" '$2 != k' "$lines" > "$lines.tmp"
    printf '%s\t%s\t%s\n' "$class" "$key" "$value" >> "$lines.tmp"
    sort -t "$(printf '\t')" -k1,1 -k2,2 "$lines.tmp" > "$lines"
    rm -f "$lines.tmp"
    write_manifest
}

write_manifest() {
    local lines="$PLAN_DIR/manifest.lines" out="$PLAN_DIR/manifest.json"
    {
        echo "{"
        for class in mustEqual declared; do
            echo "  \"$class\": {"
            awk -F '\t' -v c="$class" '$1 == c { printf "    \"%s\": \"%s\",\n", $2, $3 }' "$lines" | sed '$ s/,$//'
            if [ "$class" = mustEqual ]; then echo "  },"; else echo "  }"; fi
        done
        echo "}"
    } > "$out"
}

# The toolchain's half of the must-equal class.
manifest_toolchain() {
    local forge_out
    manifest_set mustEqual commit "$(git rev-parse HEAD)"
    manifest_set mustEqual tree "$(git rev-parse 'HEAD^{tree}')"
    # Each line of `git submodule status` is the commit, with a one-character state before it when the submodule
    # is not checked out at the recorded commit, then the path, then a description.
    local sha path
    while read -r sha path _; do
        sha="${sha#[-+U]}"
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "a submodule's status line does not start with its commit: $sha $path"
        manifest_set mustEqual "submodule.$path" "$sha"
    done < <(git submodule status)
    manifest_set mustEqual lib.chainlink "$(git -C lib/chainlink rev-parse HEAD 2>/dev/null || echo absent)"
    manifest_set mustEqual sha256.wrapper "$(sha256sum script/deploy-betting.sh | cut -d' ' -f1)"
    manifest_set mustEqual sha256.script "$(sha256sum script/DeployBetting.s.sol | cut -d' ' -f1)"
    manifest_set mustEqual sha256.foundryToml "$(sha256sum foundry.toml | cut -d' ' -f1)"
    manifest_set mustEqual sha256.remappings "$(sha256sum remappings.txt | cut -d' ' -f1)"
    manifest_set mustEqual forge.commit "$PINNED_FOUNDRY_COMMIT"
    manifest_set mustEqual forge.profileAndFlags "FOUNDRY_PROFILE=ci ${FORGE_FLAGS[*]}"
    forge_out=$("$(forge_bin)" --version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
    manifest_set declared forge.version "$forge_out"
    manifest_set declared lib.toolkit "$(git -C lib/foundry-chainlink-toolkit rev-parse HEAD 2>/dev/null || echo absent)"
}

# The lines the script prints for the manifest: "manifest.<class>.<key>: <value>".
manifest_from_run() {
    local log="$1"
    while IFS= read -r line; do
        local body="${line#*manifest.}"
        local class="${body%%.*}"
        local rest="${body#*.}"
        local key="${rest%%: *}"
        local value="${rest#*: }"
        manifest_set "$class" "$key" "$value"
    done < <(grep -oE 'manifest\.(mustEqual|declared)\.[A-Za-z0-9_.]+: .*$' "$log" || true)
}

# ── compare ───────────────────────────────────────────────────────────────────────────────────────────────────

compare_manifests() {
    local a="$1" b="$2" status=0
    [ -f "$a" ] && [ -f "$b" ] || die "compare takes two manifest files"
    section() { awk -v s="\"$2\": {" '$0 ~ s { on = 1; next } on && /^  }/ { on = 0 } on' "$1" | sed 's/,$//'; }
    if ! diff <(section "$a" mustEqual) <(section "$b" mustEqual) > /dev/null; then
        echo "compare: the must-equal class DIFFERS:"
        diff <(section "$a" mustEqual) <(section "$b" mustEqual) || true
        status=1
    else
        echo "compare: the must-equal class is equal ($(section "$a" mustEqual | wc -l) fields)"
    fi
    echo "compare: the declared differences, recorded and not compared:"
    diff <(section "$a" declared) <(section "$b" declared) || true
    return "$status"
}

# ── The phases ────────────────────────────────────────────────────────────────────────────────────────────────

forge_script() {
    local status=0
    run_filtered "$(forge_bin)" script "$SCRIPT" --rpc-url "$RPC_URL" --skip test --no-storage-caching "${FORGE_FLAGS[@]}" "$@" || status=$?
    rm -rf "$SEQUENCE_CACHE"
    return "$status"
}

main() {
    [ "$#" -ge 1 ] || die "no mode: fork, live or compare"
    local mode="$1"
    shift
    if [ "$mode" = compare ]; then
        [ "$#" -eq 2 ] || die "compare takes two manifest files"
        compare_manifests "$1" "$2"
        return
    fi
    [ "$mode" = fork ] || [ "$mode" = live ] || die "unknown mode '$mode': fork, live or compare"
    [ "$#" -ge 1 ] || die "no phase"
    local phase="$1"
    shift

    # The positional arguments, then the flags.
    local -a args=()
    RPC_URL=""
    local account="" timeout=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --rpc-url) [ "$#" -ge 2 ] || die "--rpc-url needs a value"; RPC_URL="$2"; shift 2 ;;
            --account) [ "$#" -ge 2 ] || die "--account needs a value"; account="$2"; shift 2 ;;
            --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; require_number "$2" "--timeout"; timeout="$2"; shift 2 ;;
            --*) die "unknown flag '$1'" ;;
            *) args+=("$1"); shift ;;
        esac
    done

    require_no_dotenv
    require_clean_environment
    require_rpc_given
    require_commit_line "$(forge_bin)"
    require_commit_line "$(cast_bin)"
    if [ "$mode" = fork ]; then
        require_loopback
        [ -z "$account" ] || die "fork mode takes no --account"
    else
        require_not_loopback
        require_not_test_node
    fi
    PLAN_DIR=$(plan_dir)
    mkdir -p "$PLAN_DIR/runs"
    RUN_LOG="$PLAN_DIR/runs/$mode-$phase-$(date -u +%Y%m%dT%H%M%SZ).log"
    : > "$RUN_LOG"

    case "$phase" in
        setup)
            [ "$mode" = fork ] || die "setup is the fork's alone"
            [ "${#args[@]}" -eq 0 ] || die "setup takes no arguments"
            require_tree "$(git rev-parse HEAD)"
            run_filtered "$(cast_bin)" rpc anvil_setCode "$SENTINEL" 0x00 --rpc-url "$RPC_URL" > /dev/null
            require_sentinel_present
            run_filtered "$(cast_bin)" rpc anvil_impersonateAccount "$DEPLOYER" --rpc-url "$RPC_URL" > /dev/null
            local balance top_up_hex
            balance=$(cast_read balance "$DEPLOYER" --rpc-url "$RPC_URL") || die "the deployer's balance could not be read"
            balance=$(printf '%s' "$balance" | tr -d '[:space:]')
            require_number "$balance" "the deployer's balance"
            if less_than "$balance" "$FORK_TOP_UP_WEI"; then
                top_up_hex=$(cast_read to-hex "$FORK_TOP_UP_WEI") || die "the top-up could not be written in hex"
                run_filtered "$(cast_bin)" rpc anvil_setBalance "$DEPLOYER" "$top_up_hex" --rpc-url "$RPC_URL" > /dev/null
                echo "fork setup: the deployer held $balance wei, topped up to $FORK_TOP_UP_WEI" | tee -a "$RUN_LOG"
                # Recorded at once, before any plan: predict keeps the manifest's lines.
                manifest_set declared fork.topUp "$balance -> $FORK_TOP_UP_WEI"
            else
                echo "fork setup: the deployer holds $balance wei, no top-up" | tee -a "$RUN_LOG"
                # A top-up an earlier setup made stays on the record.
                grep -q "$(printf '\tfork.topUp\t')" "$PLAN_DIR/manifest.lines" 2>/dev/null \
                    || manifest_set declared fork.topUp "none: the deployer held $balance wei"
            fi
            echo "fork setup: the sentinel $SENTINEL holds 0x00; the deployer is impersonated" | tee -a "$RUN_LOG"
            ;;
        predict)
            [ "${#args[@]}" -eq 1 ] || die "predict takes the commit"
            local commit="${args[0]#0x}"
            [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "the commit is not forty hex digits"
            require_tree "$commit"
            if [ "$mode" = fork ]; then require_sentinel_present; else require_sentinel_absent; fi
            forge_script --sig "predict(bytes20)" "0x$commit"
            # The node's two reads first, each checked, so that a failed one writes no manifest.
            local client="" balance
            if [ "$mode" = fork ]; then
                client=$(cast_read client --rpc-url "$RPC_URL") || die "the node's client version could not be read: no manifest is written"
                client=$(printf '%s' "$client" | tr -d '\r\n')
            fi
            balance=$(cast_read balance "$DEPLOYER" --rpc-url "$RPC_URL") || die "the deployer's balance could not be read: no manifest is written"
            balance=$(printf '%s' "$balance" | tr -d '[:space:]')
            require_number "$balance" "the deployer's balance"
            manifest_toolchain
            manifest_from_run "$RUN_LOG"
            manifest_set declared node "$mode"
            manifest_set declared signer "$([ "$mode" = fork ] && echo 'unlocked impersonation on the fork' || echo 'the keystore named on the line')"
            if [ "$mode" = fork ]; then
                manifest_set declared anvil.version "$client"
            fi
            manifest_set declared deployer.balanceAtPlan "$balance"
            echo "written: $PLAN_DIR/manifest.json" | tee -a "$RUN_LOG"
            ;;
        create | bootstrap | finalize)
            local digest go maxfee
            if [ "$mode" = fork ]; then
                [ "${#args[@]}" -eq 2 ] || die "$phase takes the digest and the maximum fee"
                digest="${args[0]}"; go="$FORK_GO"; maxfee="${args[1]}"
            else
                [ "${#args[@]}" -eq 3 ] || die "$phase takes the digest, the go value and the maximum fee"
                digest="${args[0]}"; go="${args[1]}"; maxfee="${args[2]}"
                [ -n "$account" ] || die "live $phase takes --account"
            fi
            require_hex "$digest" 32 "the digest"
            require_number "$maxfee" "the maximum fee"
            require_go "$mode" "$go"
            require_plan_commit
            if [ "$mode" = fork ]; then require_sentinel_present; else require_sentinel_absent; fi
            local -a signer=()
            if [ "$mode" = fork ]; then signer=(--unlocked --sender "$DEPLOYER"); else signer=(--account "$account"); fi
            local -a wait=()
            [ -n "$timeout" ] && wait=(--timeout "$timeout")
            forge_script --sig "$phase(bytes32,bytes16,uint256)" "$digest" "$go" "$maxfee" \
                --broadcast --slow --with-gas-price "$maxfee" --gas-estimate-multiplier "$GAS_MULTIPLIER" "${signer[@]}" "${wait[@]}"
            manifest_from_run "$RUN_LOG"
            local go_hash
            go_hash=$(cast_read keccak "$go") || die "the go value's hash could not be computed"
            require_hex "$go_hash" 32 "the go value's hash"
            manifest_set declared "go.$phase" "keccak256 $go_hash"
            manifest_set declared "maxFee.$phase" "$maxfee"
            ;;
        check)
            [ "${#args[@]}" -eq 3 ] || die "check takes the core, its creation block and the stage"
            require_hex "${args[0]}" 20 "the core"
            require_number "${args[1]}" "the creation block"
            [[ "${args[2]}" =~ ^[123]$ ]] || die "unknown stage '${args[2]}': 1, 2 or 3"
            require_plan_commit
            if [ "$mode" = fork ]; then require_sentinel_present; else require_sentinel_absent; fi
            forge_script --sig "check(address,uint256,uint8)" "${args[0]}" "${args[1]}" "${args[2]}"
            ;;
        signpostCall)
            [ "${#args[@]}" -eq 1 ] || die "signpostCall takes the deploy block"
            require_number "${args[0]}" "the deploy block"
            require_plan_commit
            if [ "$mode" = fork ]; then require_sentinel_present; else require_sentinel_absent; fi
            forge_script --sig "signpostCall(uint64)" "${args[0]}"
            ;;
        *)
            die "unknown phase '$phase'"
            ;;
    esac
}

# Sourced by its tests, it defines the checks and runs nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
