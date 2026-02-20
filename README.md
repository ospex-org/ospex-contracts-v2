# Ospex Matched Pairs

On-chain orderbook contracts for peer-to-peer sports event speculation on Polygon. Participants create positions at custom odds, get matched against counterparties, and claim outcomes after oracle-verified results. Zero fees, no custody, fully permissionless.

## Architecture

Minimal core registry with modular plug-ins. OspexCore manages access control and module registration. All business logic lives in independent modules:

| Module | Purpose |
|--------|---------|
| PositionModule | Position creation, matching, claiming |
| SpeculationModule | Market lifecycle and settlement |
| ContestModule | Event creation and scoring |
| LeaderboardModule | ROI-based competitions with prizes |
| RulesModule | Position eligibility validation |
| TreasuryModule | Fee collection and prize pools |
| OracleModule | Chainlink Functions integration |
| SecondaryMarketModule | Position trading |
| ContributionModule | Priority queue ordering |
| Scorer Modules | Moneyline, spread, and total scoring |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for full details.

## Protocol Flow

```
Contest (event) → Speculation (market) → Position (participant stake)
```

1. A contest is created for a sports event
2. Speculations (markets) are created on that contest — moneyline, spread, or total
3. Participants create positions at their desired odds, depositing USDC
4. Counterparties match against existing positions at reciprocal odds
5. Event starts, speculation locks
6. Event ends, Chainlink oracle fetches scores
7. Scorer module determines the outcome
8. Participants claim settled positions

Odds use 1e7 precision (e.g., 1.80 = 18,000,000). Positions are typed as Upper (away/over) or Lower (home/under).

## Trust Model

- No pause mechanism in any contract
- No proxy/upgrade pattern
- PositionModule (fund escrow) has zero admin functions — deployer cannot withdraw, redirect, or freeze funds
- Module swap capability exists for bug fixes (see [docs/ADMIN_PRIVILEGES.md](docs/ADMIN_PRIVILEGES.md) for the full trust model and renouncement plan)

## Build

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/ospex-org/ospex-foundry-matched-pairs.git
cd ospex-foundry-matched-pairs
git submodule update --init --recursive
forge build --via-ir --optimize
```

## Test

```bash
forge test --via-ir --optimize -vvv
```

365 tests covering all modules, including fuzz tests for solvency invariants.

## Coverage

```bash
forge coverage --ir-minimum
```

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — AccessControl, SafeERC20, ReentrancyGuard
- [Chainlink](https://github.com/smartcontractkit/chainlink) — FunctionsClient for oracle requests
- [Forge Std](https://github.com/foundry-rs/forge-std) — Testing framework

## Documentation

| Document | Contents |
|----------|----------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Contract design, module responsibilities, security model |
| [ADMIN_PRIVILEGES.md](docs/ADMIN_PRIVILEGES.md) | Every admin function, role holders, fund flow, renouncement plan |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Deployment instructions and contract addresses |
| [FLOW.md](docs/FLOW.md) | User flow diagrams |

## Deployment

Live on Polygon mainnet (chain ID 137). See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for contract addresses.

## License

[BUSL-1.1](LICENSE.md) — Business Source License 1.1. Converts to GPL-2.0-or-later on February 20, 2028.