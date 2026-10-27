# Ospex Matched Pairs

**Status.** This README describes v2, the contracts deployed on Polygon mainnet today, except its last section. v2 is run as a lab and is not yet open to outside users (see "Why this way" in [docs/spec-v3.md](docs/spec-v3.md)). v3, the next version, is being built and is not deployed: see [v3: being built, not deployed](#v3-being-built-not-deployed).

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
| [E2E_TRACES.md](docs/E2E_TRACES.md) | Function-by-function trace of every protocol process — start here to verify from source |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module-by-module function reference, protocol flow, USDC approvals, security model |
| [DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md) | Intentional non-obvious behaviors and the reasoning behind them |
| [TRUST_MODEL.md](docs/TRUST_MODEL.md) | Zero-admin trust model — what cannot change after `finalize()` |
| [RISKS.md](docs/RISKS.md) | Self-assessed risk register (no professional audit yet) |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Deployment instructions and Polygon mainnet contract addresses |

## Deployment

Live on Polygon mainnet (chain ID 137). See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for contract addresses and the per-round deploy records under [docs/deployment/](docs/deployment/).

## v3: being built, not deployed

Everything above describes v2, the contracts live today. The next version is specified in [docs/spec-v3.md](docs/spec-v3.md), which controls wherever code and spec differ. It has two pieces: the games set (games, the reporters that write them, and how each game ends) and the betting set deployed beside it. Each piece is built in stages, reviewed, and deployed once, as a whole.

v3 says game where v2 said contest, and market where v2 said speculation; a position is a position in both.

- `src/signpost/`: the signpost, the public list of each set of contracts and its state. Deployed.
- `src/games/`: the games set's games contract, built so far. Anyone creates a game; each game copies the approved reporters and its league's terms at its creation; one report call takes a start, a score, a void and a dispute record; five reads say what happened. The approved list and the per-league terms change only through the timelock, after its delay. A retired reporter writes to no game, and neither does one whose code no longer hashes as it did when it was approved. An approval checks on chain that a reporter has the code its queued call named, and records what the reporter reports of itself; that its behaviour is fixed and its values true is for review, before the call is queued. A creation takes the game's creation fee, which the game holds until it ends. Every game ends once, as a score, a void or a release, and after its end nothing more is written to it. A score and a void are reports and credit the fee to the payout address in the report; a void is taken from start + n, and on a disputed game only once the day-7 clock has run. A dispute record is a report that ends nothing and credits nothing: the first starts the day-7 clock, later ones are updates, and a disputed game still takes a score. Anyone releases a game that has not ended once its day-30 clock has run from the date given at creation, which no write moves, or at once when every one of its reporters that could still write to it is retired; from that clock the release is the only door, and it credits the fee back to the creator. The games set refuses a report its own readings contradict: a score no final reads, a disputed game's score on fewer than three agreeing finals, a void over three finals that agree at either clock, two readings for one seat. The address credited withdraws later, so no coin moves inside an end. Not deployed.
- `src/games/OspexChainlinkReporter.sol`: the Chainlink reporter, the one contract that knows Chainlink. Its forwarder, its workflow owner, its workflow id and the games contract are fixed at deploy; it takes a report only from that forwarder, only when the report's metadata names that owner and that id, and only when the report's bytes are the one shape's own encoding of what they decode to; it passes the report to the games contract in the one report shape, with the payout address as the report carries it. No owner, no setter, no storage. Not deployed.
- `script/DeployGames.s.sol`: deploy day for the games set, in order. It predicts the reporter's and the games contract's addresses from the deployer's nonce, takes the workflow id from the scoring program's reproducible build (in ospex-cre) once that build's record names both addresses under the keys the program reads, waits for the id to be registered at Chainlink's workflow registry under the owner, active, moves one fee through the coin as a check, deploys the reporter and then the games contract with the launch terms and the reporter as its one first-n reporter, and writes the signpost call for the timelock's key to schedule. The chain decides what is left: a run after a partial one sends what is missing and refuses what is done. The deployer keeps nothing.

Deploy day for the games set, the checklist beside the script's own order:

1. The deployer is the operator's working wallet, the address the box's lanes send from. Before the plan is written, stop whatever sends from it on the box (the postgame timer first), and keep it stopped until the three sends are mined; its nonce is the plan.
2. The coin is Polygon USDC at the pinned address. The coin check proves that a transfer of the fee arrives as the fee at that address, and nothing about any other coin: a coin other than Polygon USDC gets its own review (exact transfer, no fee, no rebase, decimals) before the script is pointed at it.
3. The RPC serves `eth_getLogs` in 10,000-block windows and the state of the current block; the script reads the timelock's whole log history (its roles replayed to today's holders; what it has done since never refuses) and the coin's transfers since the plan.
4. `predict` with the deployer as `--sender`, no broadcast: the plan records the addresses, the block, both coin balances and the reporter's build; the reproducible build in ospex-cre with both predicted addresses, its JSON saved beside the plan; the owner registers the id at Chainlink; `deploy` with `--broadcast`, from the same checkout of this script; the receipts are forge's broadcast log; `signpostCall` with the games contract's creation block and the commit; the key schedules the call.

## License

[BUSL-1.1](LICENSE.md) — Business Source License 1.1. Converts to GPL-2.0-or-later on February 20, 2028.
