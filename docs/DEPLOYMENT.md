# Deployment

## Mainnet Contract Addresses (Polygon, Chain ID 137)

| Contract | Address |
|----------|---------|
| OspexCore | [`0x8016b2C5f161e84940E25Bb99479aAca19D982aD`](https://polygonscan.com/address/0x8016b2C5f161e84940E25Bb99479aAca19D982aD) |
| PositionModule | [`0xF717aa8fe4BEDcA345B027D065DA0E1a31465B1A`](https://polygonscan.com/address/0xF717aa8fe4BEDcA345B027D065DA0E1a31465B1A) |
| SpeculationModule | [`0x599FFd7A5A00525DD54BD247f136f99aF6108513`](https://polygonscan.com/address/0x599FFd7A5A00525DD54BD247f136f99aF6108513) |
| ContestModule | [`0x9E56311029F8CC5e2708C4951011697b9Bb40A09`](https://polygonscan.com/address/0x9E56311029F8CC5e2708C4951011697b9Bb40A09) |
| OracleModule | [`0x5105b835365dB92e493B430635e374E16f3C8249`](https://polygonscan.com/address/0x5105b835365dB92e493B430635e374E16f3C8249) |
| LeaderboardModule | [`0xEA6FF671Bc70e1926af9915aEF9D38AD2548066b`](https://polygonscan.com/address/0xEA6FF671Bc70e1926af9915aEF9D38AD2548066b) |
| RulesModule | [`0xEfDf69ef9f3657d6571bb9c979D2Ce3D7Afb6891`](https://polygonscan.com/address/0xEfDf69ef9f3657d6571bb9c979D2Ce3D7Afb6891) |
| TreasuryModule | [`0x48Fe67B7b866Ce87eA4B6f45BF7Bcc3cf868ccD0`](https://polygonscan.com/address/0x48Fe67B7b866Ce87eA4B6f45BF7Bcc3cf868ccD0) |
| SecondaryMarketModule | [`0x85E25F3BC29fAD936824ED44624f1A6200F3816E`](https://polygonscan.com/address/0x85E25F3BC29fAD936824ED44624f1A6200F3816E) |
| MoneylineScorerModule | [`0x82c93AAf547fC809646A7bEd5D8A9D4B72Db3045`](https://polygonscan.com/address/0x82c93AAf547fC809646A7bEd5D8A9D4B72Db3045) |
| SpreadScorerModule | [`0x4377A09760b3587dAf1717F094bf7bd455daD4af`](https://polygonscan.com/address/0x4377A09760b3587dAf1717F094bf7bd455daD4af) |
| TotalScorerModule | [`0xD7b35DE1bbFD03625a17F38472d3FBa7b77cBeCf`](https://polygonscan.com/address/0xD7b35DE1bbFD03625a17F38472d3FBa7b77cBeCf) |
| MatchingModule | (update after next mainnet deploy) |

**Token:** Native USDC ([`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)), 6 decimals

---

## Network Configuration

| Parameter | Mainnet (Polygon) | Testnet (Amoy) |
|-----------|-------------------|----------------|
| Chain ID | 137 | 80002 |
| LINK Token | `0xb0897686c545045aFc77CF20eC7A532E3120E0F1` | `0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904` |
| Chainlink Functions Router | `0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10` | `0xC22a79eBA640940ABB6dF0f7982cc119578E11De` |
| Chainlink DON ID | `fun-polygon-mainnet-1` | `fun-polygon-amoy-1` |
| Chainlink Subscription | [191](https://functions.chain.link/polygon/191) | [416](https://functions.chain.link/polygon-amoy/416) |
| Token | Native USDC (6 decimals) | Mock USDC (6 decimals) |
| USDC Address | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` |

---

## Local Anvil Fork Test (Run This First)

Before deploying to live Amoy, validate the full deployment sequence on a local fork:

```bash
cd ospex-foundry-matched-pairs
./script/deploy-anvil-test.sh
```

Or with a custom RPC:

```bash
AMOY_RPC=https://polygon-amoy.g.alchemy.com/v2/YOUR_KEY ./script/deploy-anvil-test.sh
```

The script:
1. Starts `anvil --fork-url <AMOY_RPC>` to pull live Amoy state
2. Funds the Amoy deployer address on the fork
3. Runs `DeployAmoy.s.sol` against the fork with full verbosity
4. Reports success/failure

**What depends on live Amoy state (pulled by the fork):**
- Mock USDC contract at `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8`
- LINK token at `0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904`
- Chainlink Functions Router at `0xC22a79eBA640940ABB6dF0f7982cc119578E11De`

**What won't work on the fork (expected):**
- Chainlink Functions callbacks (no DON on local fork)
- LINK payments to OracleModule (subscription not configured locally)

If the fork deployment succeeds, you're clear to deploy to live Amoy.

---

## Testnet Deployment (Polygon Amoy, Chain ID 80002)

### Prerequisites

1. [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
2. Submodules initialized: `git submodule update --init --recursive`
3. Deployer wallet funded with POL for gas ([Polygon Faucet](https://faucet.polygon.technology/))
4. Chainlink subscription 416 funded with LINK

### Deploy Command

```bash
forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url https://rpc-amoy.polygon.technology \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  --via-ir \
  --optimize \
  -vvvv
```

To use a different deployer wallet, set `DEPLOYER_ADDRESS`:

```bash
DEPLOYER_ADDRESS=0xYourWallet forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url https://rpc-amoy.polygon.technology \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  --via-ir \
  --optimize \
  -vvvv
```

### Post-Deploy Checklist (Amoy)

- [ ] Deployment script completed without reverts
- [ ] All 12 module registrations verified (script checks this automatically)
- [ ] All 3 scorer modules recognized by `isApprovedScorer()` (script checks this automatically)
- [ ] Save all deployed contract addresses from the console output
- [ ] Add OracleModule address as consumer on [Chainlink subscription 416](https://functions.chain.link/polygon-amoy/416)
- [ ] Fund OracleModule with LINK tokens for Chainlink Functions requests
- [ ] Upload offchain-secrets for Amoy (see `scripts/` directory)
- [ ] Update ospex-fdb Firebase functions with new contract addresses
- [ ] Update ospex-agent-server `.env` with new contract addresses
- [ ] Update ospex-lovable frontend config with new contract addresses
- [ ] Test end-to-end: contest creation -> speculation -> position -> scoring

---

## Mainnet Deployment (Polygon, Chain ID 137)

### Deploy Command

```bash
DEPLOYER_ADDRESS=0xYourMainnetWallet forge script script/DeployPolygon.s.sol:DeployPolygon \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  --via-ir \
  --optimize \
  -vvvv
```

> **Do NOT use `https://polygon-rpc.com`** — it returns 401 as of March 2026. Use your Alchemy RPC URL from `.env`.

### Mainnet Readiness — Config Swap

The Amoy deploy script (`DeployAmoy.s.sol`) is annotated with `// MAINNET:` comments on every chain-specific value. To find all values that need changing:

```bash
grep -n "MAINNET:" script/DeployAmoy.s.sol
```

Key swaps:

| Value | Amoy | Mainnet |
|-------|------|---------|
| LINK | `0x0Fd9e8...1904` | `0xb08976...E0F1` |
| Functions Router | `0xC22a79...11De` | `0xdc2AAF...3F10` |
| USDC | `0xB1D1c0...eaF8` (mock) | `0x3c499c...3359` (native) |
| DON ID | `fun-polygon-amoy-1` | `fun-polygon-mainnet-1` |
| Subscription | 416 | 191 |
| Fee Receiver | deployer | `0xdaC630...5114` |
| Source Hashes | Amoy hashes | Regenerate from mainnet JS source |

### Post-Deploy Checklist (Mainnet)

- [ ] Deployment script completed without reverts
- [ ] All 12 module registrations verified
- [ ] All 3 scorer modules recognized by `isApprovedScorer()`
- [ ] Contract source code verified on Polygonscan
- [ ] Add OracleModule as consumer on [Chainlink subscription 191](https://functions.chain.link/polygon/191)
- [ ] Fund OracleModule with LINK
- [ ] Upload mainnet offchain-secrets
- [ ] Update all downstream services (ospex-fdb, ospex-agent-server, ospex-lovable)
- [ ] Test with small positions before announcing

---

## Deployment Order

The deploy scripts create contracts in this order:

1. **OspexCore** — immutable core registry and event hub
2. **ContestModule** — sports events (needs OspexCore)
3. **LeaderboardModule** — competitions, ROI tracking, prizes
4. **RulesModule** — leaderboard eligibility rules
5. **MoneylineScorerModule** — moneyline bet scoring
6. **SpreadScorerModule** — spread bet scoring
7. **TotalScorerModule** — over/under scoring
8. **MatchingModule** — EIP-712 signed-order matching
9. **TreasuryModule** — fee collection and prize pools (needs USDC + fee receiver)
10. **SpeculationModule** — market lifecycle (needs void cooldown)
11. **PositionModule** — user fund escrow (needs USDC)
12. **SecondaryMarketModule** — position trading (needs USDC)
13. **OracleModule** — Chainlink Functions (needs router + LINK + DON ID + approved signer)

After deployment: all 12 modules registered with OspexCore via `bootstrapModules()`, then `finalize()` permanently locks the registry. No admin key remains.

See [TRUST_MODEL.md](TRUST_MODEL.md) for the full trust model.

---

## EIP-712 Domain Separator

`MatchingModule` uses OpenZeppelin's `EIP712("Ospex", "1")` which computes the domain separator from `block.chainid` at runtime. No hardcoded chain ID anywhere — it's automatically 80002 on Amoy and 137 on mainnet.

---

## Known Amoy Testnet Quirks

Amoy is a checkpoint, not a destination. These are known issues — **do not rabbit-hole on them**:

- **Gas estimation oddities**: Amoy gas estimates can be wildly inaccurate. If a transaction fails with "out of gas" but works on the Anvil fork, try bumping the gas limit manually with `--gas-limit`.
- **Event indexing delays / out-of-order events**: Amoy's block production is irregular. Events may appear out of order or with significant delays. The ospex-fdb listener may see events late — this is Amoy, not a bug.
- **RPC flakiness**: `rpc-amoy.polygon.technology` drops connections periodically. If `forge script` fails mid-broadcast, check the broadcast log (`broadcast/`) for which transactions landed and resume manually.
- **Contract verification failures**: Polygonscan Amoy verification can time out or return spurious errors. Retry, or verify manually via the Polygonscan UI.
- **Chainlink Functions latency**: Functions callbacks on Amoy can take 2-5 minutes (vs ~30s on mainnet). Don't assume scoring is broken if it's slow.

**Rule of thumb**: If it works on the Anvil fork but acts weird on live Amoy, it's probably Amoy. Move on to mainnet when the deployment sequence and contract registrations are confirmed.

---

## Local Deployment (Pure Anvil, No Fork)

For pure local testing with mock tokens and mock Chainlink contracts:

```bash
anvil

forge script script/DeployAnvilFull.s.sol:DeployAnvilFull \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --interactive \
  -vvvv
```

This deploys MockERC20, MockLinkToken, MockFunctionsRouter, plus all protocol contracts. Useful for unit-testing contract interactions without any external dependencies.
