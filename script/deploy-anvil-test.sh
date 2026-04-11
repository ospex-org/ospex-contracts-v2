#!/usr/bin/env bash
# deploy-anvil-test.sh — Fork Amoy and run the full deploy script locally.
#
# This verifies the deployment sequence completes without reverts before
# touching live Amoy. The fork pulls live state for:
#   - USDC contract at 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8
#   - LINK contract at 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904
#   - Chainlink Functions Router at 0xC22a79eBA640940ABB6dF0f7982cc119578E11De
#
# If any of these addresses are empty or behave differently on the fork,
# the deploy may succeed but post-deploy oracle calls would fail.
# That's expected — Chainlink Functions callbacks can't work on a local fork.
# The goal here is to verify the deployment sequence itself, not oracle integration.
#
# Prerequisites:
#   - Foundry installed (forge, anvil, cast)
#   - An Amoy RPC URL (free tier from Alchemy/Infura works)
#
# Usage:
#   ./script/deploy-anvil-test.sh
#   AMOY_RPC=https://polygon-amoy.g.alchemy.com/v2/YOUR_KEY ./script/deploy-anvil-test.sh

set -euo pipefail

# ---- Configuration ----
AMOY_RPC="${AMOY_RPC:-https://rpc-amoy.polygon.technology}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
ANVIL_PID=""

# Anvil's default account #0 — prefunded with 10000 ETH on the fork.
DEPLOYER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# ---- Cleanup on exit ----
cleanup() {
  if [ -n "$ANVIL_PID" ]; then
    echo "Stopping anvil (PID $ANVIL_PID)..."
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---- Step 1: Start anvil fork ----
echo "============================================================"
echo "  Starting Anvil fork of Polygon Amoy"
echo "  RPC: $AMOY_RPC"
echo "  Port: $ANVIL_PORT"
echo "============================================================"

anvil --fork-url "$AMOY_RPC" --port "$ANVIL_PORT" --silent &
ANVIL_PID=$!

# Wait for anvil to be ready
echo "Waiting for anvil to start..."
for i in $(seq 1 30); do
  if cast block-number --rpc-url "http://127.0.0.1:$ANVIL_PORT" &>/dev/null; then
    echo "Anvil ready at block $(cast block-number --rpc-url "http://127.0.0.1:$ANVIL_PORT")"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Anvil did not start within 30 seconds"
    exit 1
  fi
  sleep 1
done

# ---- Step 2: Fund the Amoy deployer on the fork ----
# The deploy script defaults to 0x89fe...Dfa3. Fund it with POL from Anvil's default account
# so the script runs with the same deployer address it would use on live Amoy.
AMOY_DEPLOYER="0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3"
echo ""
echo "Funding Amoy deployer ($AMOY_DEPLOYER) with 100 POL..."
cast send --rpc-url "http://127.0.0.1:$ANVIL_PORT" \
  --private-key "$DEPLOYER_PK" \
  "$AMOY_DEPLOYER" \
  --value 100ether \
  >/dev/null

echo "Deployer balance: $(cast balance --rpc-url "http://127.0.0.1:$ANVIL_PORT" "$AMOY_DEPLOYER") wei"

# ---- Step 3: Run the deployment ----
echo ""
echo "============================================================"
echo "  Running DeployAmoy.s.sol against Anvil fork"
echo "============================================================"

# We impersonate the Amoy deployer. The --unlocked flag tells forge to skip
# private key signing (anvil auto-impersonates any address).
DEPLOYER_ADDRESS="$AMOY_DEPLOYER" forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url "http://127.0.0.1:$ANVIL_PORT" \
  --broadcast \
  --unlocked \
  --sender "$AMOY_DEPLOYER" \
  -vvvv

echo ""
echo "============================================================"
echo "  Anvil fork deployment SUCCEEDED"
echo "============================================================"
echo ""
echo "Live-state dependencies that exist on the fork but matter for real Amoy:"
echo "  - USDC (mock): 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8"
echo "  - LINK token:  0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904"
echo "  - Chainlink Functions Router: 0xC22a79eBA640940ABB6dF0f7982cc119578E11De"
echo ""
echo "Things that WON'T work on the fork (expected):"
echo "  - Chainlink Functions callbacks (no DON on local fork)"
echo "  - LINK payments to OracleModule (subscription not configured)"
echo ""
echo "If this passes, you're clear to deploy to live Amoy."
