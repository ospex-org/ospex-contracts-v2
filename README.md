# Ospex Matched Pairs

Peer-to-peer sports event speculation on Polygon. Makers sign EIP-712 commitments off-chain; takers match them on-chain via the MatchingModule. Positions are then settled against oracle-verified scores. Zero vigorish, no custody beyond escrow, fully permissionless.

## Architecture

Immutable core registry with modular plug-ins. OspexCore manages module registration and event emission. All business logic lives in independent modules registered once during deployment and permanently locked via `finalize()` — there is no admin key, no module swap, no upgrade path.

| Module | Purpose |
|--------|---------|
| MatchingModule | EIP-712 commitment verification and atomic match execution |
| PositionModule | User fund escrow and claims (zero admin functions) |
| SpeculationModule | Market lifecycle and settlement |
| ContestModule | Sports events and scoring |
| CreOracleReceiver | Chainlink CRE oracle integration |
| TreasuryModule | Fee collection and prize-pool accounting |
| LeaderboardModule | ROI-based competitions with prizes |
| RulesModule | Leaderboard eligibility rules |
| SecondaryMarketModule | Position trading before settlement |
| MoneylineScorerModule | Winner/loser scoring |
| SpreadScorerModule | Point-spread scoring |
| TotalScorerModule | Over/under scoring |

12 modules total, plus the OspexCore registry. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for full module-by-module detail.

## Protocol Flow

```
Contest (event) → Speculation (market) → Position (participant stake)
```

1. A contest is created on-chain via CreOracleReceiver (permissionless).
2. The Chainlink CRE oracle verifies the contest against three independent sports data APIs and sets its league and start time.
3. A maker signs an EIP-712 `OspexCommitment` off-chain specifying contest, scorer, line, position type, odds, risk amount, nonce, and expiry.
4. A taker calls `MatchingModule.matchCommitment(...)` on-chain. USDC is pulled from both parties via `safeTransferFrom`. The speculation auto-creates on the first fill.
5. The contest concludes; the oracle records final scores (permissionless, triple-source verified).
6. Anyone calls `SpeculationModule.settleSpeculation()`. The scorer module determines the winning side.
7. Participants claim payouts from PositionModule.

If a contest is never scored, `settleSpeculation()` auto-voids all speculations after the void cooldown (7 days on mainnet) and risk amounts are returned.

Odds are expressed as uint16 ticks with `ODDS_SCALE = 100` (1.91 odds = 191 ticks). Valid range: 101 (1.01x) to 10100 (101.00x). Risk amounts in USDC (6 decimals) must be exact multiples of `ODDS_SCALE`. Positions are typed as `Upper` (away/over) or `Lower` (home/under).

## Trust Model

- No pause mechanism in any contract
- No proxy/upgrade pattern
- Module registry permanently locked after `finalize()` — no module swap
- All fee rates, the protocol fee receiver, and the void cooldown are immutable constructor parameters. The CreOracleReceiver's oracle trust roots — the Chainlink KeystoneForwarder, the CRE workflow owner, and an optional workflow-name pin — are likewise immutable constructor parameters (there is no approved signer)
- PositionModule (fund escrow) has zero admin functions — the deployer cannot withdraw, redirect, or freeze user funds
- After deployment, the deployer wallet has no on-chain privileges

See [docs/TRUST_MODEL.md](docs/TRUST_MODEL.md) for the full trust-model breakdown and [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md) for the rationale behind intentional non-obvious behaviors.

## Build

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/ospex-org/ospex-contracts-v2.git
cd ospex-contracts-v2
git submodule update --init --recursive
forge build --via-ir --optimize
```

## Test

```bash
forge test --via-ir --optimize -vvv
```

A comprehensive Foundry test suite covers all modules, including fuzz tests for solvency invariants. Run `forge test` for the current count.

## Coverage

```bash
forge coverage --ir-minimum
```

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — ReentrancyGuard, SafeERC20, EIP712, ECDSA
- [Chainlink](https://github.com/smartcontractkit/chainlink) — CRE integration for oracle requests
- [Forge Std](https://github.com/foundry-rs/forge-std) — Testing framework

## Documentation

| Document | Contents |
|----------|----------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module-by-module function reference, protocol flow, security model |
| [DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md) | Intentional non-obvious behaviors and the reasoning behind them |
| [TRUST_MODEL.md](docs/TRUST_MODEL.md) | Zero-admin trust model — what cannot change after `finalize()` |
| [RISKS.md](docs/RISKS.md) | Self-assessed risk register (no professional audit yet) |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Deployment instructions and Polygon mainnet contract addresses |
| [SELL_MATCHED_PAIR.md](docs/SELL_MATCHED_PAIR.md) | Secondary-market sell flow diagram |

## Deployment

Live on Polygon mainnet (chain ID 137). See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for contract addresses and [docs/deployment/POLYGON_MAINNET_R4.md](docs/deployment/POLYGON_MAINNET_R4.md) for the round-4 deploy snapshot.

## License

[BUSL-1.1](LICENSE.md) — Business Source License 1.1. Converts to GPL-2.0-or-later on February 20, 2028.
