# Ospex Matched Pairs

**Status.** This README describes v2, the contracts deployed on Polygon mainnet today, except its last section. v2 is run as a lab and is not yet open to outside users (see "Why this way" in [docs/spec-v3.md](docs/spec-v3.md)). v3, the next version, is being built: its games set is deployed and its betting set is not. See [v3: being built](#v3-being-built).

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

## v3: being built

Everything above describes v2, the contracts live today. The next version is specified in [docs/spec-v3.md](docs/spec-v3.md), which controls wherever code and spec differ. It has two pieces: the games set (games, the reporters that write them, and how each game ends) and the betting set deployed beside it. Each piece is built in stages, reviewed, and deployed once, as a whole.

v3 says game where v2 said contest, and market where v2 said speculation; a position is a position in both.

- `src/signpost/`: the signpost, the public list of each set of contracts and its state. Deployed.
- `src/games/`: the games set's games contract. Anyone creates a game; each game copies the approved reporters and its league's terms at its creation; one report call takes a start, a score, a void and a dispute record; five reads say what happened. The approved list and the per-league terms change only through the timelock, after its delay. A retired reporter writes to no game, and neither does one whose code no longer hashes as it did when it was approved. An approval checks on chain that a reporter has the code its queued call named, and records what the reporter reports of itself; that its behaviour is fixed and its values true is for review, before the call is queued. A creation takes the game's creation fee, which the game holds until it ends. Every game ends once, as a score, a void or a release, and after its end nothing more is written to it. A score and a void are reports and credit the fee to the payout address in the report; a void is taken from start + n, and on a disputed game only once the day-7 clock has run. A dispute record is a report that ends nothing and credits nothing: the first starts the day-7 clock, later ones are updates, and a disputed game still takes a score. Anyone releases a game that has not ended once its day-30 clock has run from the date given at creation, which no write moves, or at once when every one of its reporters that could still write to it is retired; from that clock the release is the only door, and it credits the fee back to the creator. The games set refuses a report its own readings contradict: a score read as a final by fewer of its readings than the scoring program scores on at that clock, three inside n, two after it, three on a disputed game; a void over that many finals that agree, at either clock; two readings for one seat. The address credited withdraws later, so no coin moves inside an end. Whatever picks a game up to score it reads the game, never its events: the games set stores a game's identity at creation (the league, the teams, the date and the hints, as given), the readings its start report carried and the readings its score or void carried, and each seat's last vote from its dispute records and updates, and keeps a list of the games not yet ended, which a game joins at creation and leaves at its end, read by page as rows that carry what a reader decides on; three reads return them, the list whole or by page. A dispute report that repeats the game's latest one is refused, since it would write no vote; any other is taken, a return to earlier readings included. Deployed on Polygon mainnet on 2026-10-31 at `0x1b424d0dDB5C4aa4551845898093ae8D58052fD3`, and listed on the signpost (`0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A`) as its second entry, `getEntry(1)`, which holds the set's state.
- `src/games/OspexChainlinkReporter.sol`: the Chainlink reporter, the one contract that knows Chainlink. Its forwarder, its workflow owner, its workflow id and the games contract are fixed at deploy; it takes a report only from that forwarder, only when the report's metadata names that owner and that id, and only when the report's bytes are the one shape's own encoding of what they decode to; it passes the report to the games contract in the one report shape, with the payout address as the report carries it. No owner, no setter, no storage. Deployed on Polygon mainnet on 2026-10-31 at `0x2Fa61B65Cd1CC04b2B910fB665FCc48237561c01`, the second contract of the games set's signpost entry.
- `src/betting/`: the betting set, cut from v2 and deployed beside the games set, being built. Its core, `OspexBetting`, holds the set's two deploy values, the games set it settles on and the coin the bets are held in, and the registry of its six modules, which finalize locks once it holds exactly the required set, each module checked at its registration against the type it is registered under and against the core's own values: the core it names, its games set and its coin, a market contract on its games set alone. The markets module draws a market at its first fill, on a verified or disputed game of the games set that has not ended, and settles it on the game's own status alone: a scored game settles it through its market contract, which reads the two scores from the games set, the home team's then the away team's; a voided or a released game voids it; a game still in play, a dispute record included, settles nothing. The three market contracts: the moneyline, the spread, whose line is the home team's handicap (home covers when home + homeLine > away), and the total; side A is the home team, or over. The positions module holds, for each account on each market, that account's worst loss on the market and no more: at a fill it pulls the resting account what lifts its held amount to its worst loss, and nothing when the fill lowers it; after the walk it pulls the taking account once the same way and pays every account of the Cross held above its worst loss the difference, to the account, a pay-back the coin refuses staying held and failing nothing; each pull reverts unless its balance rose by at least the amount pulled, and a held total per market is checked at every pay-back and every claim. A settled position is paid out once, to its owner, by any address that sends the claim: what is held for the account plus its net on the outcome, the whole on the winning record and, on a push or a void, side A's record up to its risk and side B's the rest. The matching module holds the signed order, the Cross, the three cancels, each account's one approved agent and each account's couriers. The signed order is `OspexOrder`: ten fields, the first the account whose money backs it and the last its minimum fill, the least it fills for in one Cross unless the fill completes it, signed under the domain "Ospex", version "3"; the same order rests or takes. A courier is an address an account names to send the fills of its orders: an account registers one and drops one with a call from its own address (`registerCourier`, `unregisterCourier`), may hold several, and has none by default; `isCourier` reads a pair. The Cross, `cross(taking, resting)`, is the one route a signed order fills by. Its sender lists a taking order and the resting orders it is to fill against, in order, each with its signature, and decides nothing else: no price, size, market, deadline or recipient. An order never fills through a courier its account has not registered: the taking account must have registered the sender, or the call reverts, and a resting order whose account has not is skipped. Each leg fills at the resting order's price, to the unit, in lots of 100 units of resting stake, with neither stake under 100 units. A resting order is skipped, with its reason recorded, when its account has not registered the sender, when it is cancelled, by its mark, its floor or its account's version, when its grant is gone, when it is expired or full, when nothing fits the lot, when the leg would take less than its minimum fill and leave a lot or more, and when the coin refuses its account's pull; the rest fill. A Cross that fills nothing reverts, its refusal carrying each order's reason; a Cross that leaves its taking order short of its minimum fill, with a lot or more left, reverts by name too, its refusal carrying each listed order's fate; and a skip record exists only for a Cross that filled. Bets close when the game scores or at its start + n: from then the markets module refuses every fill, and before a game's start is written it draws no market and takes no fill. While a Cross runs, the matching module refuses another Cross, every cancel, every grant call, a registration, a drop and the cap's lift. An order's nonce holds three numbers: the account's version, which `cancelAll(account)` moves, killing every order signed under the old one, whoever signed it; the number of the grant it was signed under, 0 for the account's own orders; and an order number, which `raiseFloor` cancels below. An account grants one agent from its own address (`grantAgent`, `revokeAgent`, or `grantAgentAndRegisterCourier` for the grant and a courier in one step), naming a stake cap, an end and an optional list of lines; the agent signs orders for the account under the grant's number and sends the three cancels for it, and nothing else: it moves no money, and every payout goes to the account. An order's signer is its account at grant 0 and the grant's agent otherwise, and the fill verifies that key's signature alone: no wallet, agent or verifier is ever asked, so a contract account trades through a key it granted. Until the switch, a taking order signs at most one cent, 10,000 units: a taking order signed for more is refused before anything moves; the cap is the taking side's alone, a resting stake is not under it, and an agent's order is bound in either role by its grant's stake cap. The switch, `liftTakingStakeCap`, is the Polygon timelock's call, once and never back; the matching module reads the timelock once from the games set when it is deployed, and keeps it. Beside the set, `OspexCourierRelay` is the address an account registers as the Ospex courier: a relay, not a key. Its `cross(taking, resting)` is open to its one sender alone and hands the call's bytes to the matching module unchanged; a refusal of the matching module comes back whole, and the matching module sees the relay as the Cross's sender. The Polygon timelock sets the sender (`setSender`), after its delay and never to zero, so the key that sends can be replaced and nothing any account registered changes; the relay reads the timelock once from the matching module when it is deployed, and keeps it. It is no module of the core, moves no coin and takes no native money. No fee is taken at a fill, and nothing of v2's leaderboards, rules, secondary market, treasury or reference odds comes across. How its contracts call one another, call by call, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#v3-the-betting-sets-seams). Not deployed.
- `script/DeployGames.s.sol`: deploy day for the games set, in order. It predicts the reporter's and the games contract's addresses from the deployer's nonce, takes the workflow id from the scoring program's reproducible build (in ospex-cre) once that build's record names both addresses under the keys the program reads, waits for the id to be registered at Chainlink's workflow registry under the owner, active, moves one fee through the coin as a check, deploys the reporter and then the games contract with the launch terms and the reporter as its one first-n reporter, and writes the signpost call for the timelock's key to schedule. The chain decides what is left: a run after a partial one sends what is missing and refuses what is done. The deployer keeps nothing.

Deploy day for the games set, the checklist beside the script's own order:

1. The deployer is the operator's working wallet, the address the box's lanes send from. Before the plan is written, stop whatever sends from it on the box (the postgame timer first), and keep it stopped until the three sends are mined; its nonce is the plan.
2. The coin is Polygon USDC at the pinned address. The coin check proves that a transfer of the fee arrives as the fee at that address, and nothing about any other coin: a coin other than Polygon USDC gets its own review (exact transfer, no fee, no rebase, decimals) before the script is pointed at it.
3. The RPC serves `eth_getLogs` in 10,000-block windows and the state of the current block; the script reads the timelock's whole log history (its roles replayed to today's holders; what it has done since never refuses) and the coin's transfers since the plan.
4. `predict` with the deployer as `--sender`, no broadcast: the plan records the addresses, the block, both coin balances and the reporter's build; the reproducible build in ospex-cre with both predicted addresses, its JSON saved beside the plan; the owner registers the id at Chainlink; `deploy` with `--broadcast`, from the same checkout of this script; the receipts are forge's broadcast log; `signpostCall` with the games contract's creation block and the commit; the key schedules the call.

- `script/DeployBetting.s.sol` and `script/deploy-betting.sh`: deploy day for the betting set. Ten sends from one deployer, at its nonces k to k + 9, from one plan: the core, its six modules and the courier relay, whose first sender is the Polygon timelock's own address until the courier is live; then the bootstrap of the six; then the lock. `predict` names the eight addresses by the deployer's nonce, writes the plan and prints its digest. The sends are three runs, `create`, `bootstrap` and `finalize`, because a script's sends are broadcast after the script has run. Each run reads the chain before it sends: the steps already proven at the finalized block, by their effect; the deployer's latest and pending nonces; and, before the bootstrap, every identity, build and wiring check, with the code at each address exactly the plan's and the timelock's scheduled calls read to the node's latest block, by its number and hash, for any that names the matching module or the relay. Before the bootstrap and the lock are sent, the head is read again and the blocks mined since are read too; no script can see a call scheduled after that last read and before its own transaction is mined. A run sends only what the chain has not proven, and holds on anything it cannot place. From the bootstrap's block the set takes bets, whether or not the lock has run and whether or not the signpost lists it. The cap bounds each taking order's signed stake, at one cent; the maker's stake in such a bet can be up to 100 times that, a dollar at tick 101, and a maker's quote can be taken by many such bets. `check` reads a set back at a stage; `signpostCall` writes the entry the key schedules on the timelock. Every run goes through the wrapper. It refuses another commit, a dirty tree, another forge, a signer from the environment and a `.env` file where forge would read one; it clears the ten other settings forge and cast read from the environment, `ETH_PRIORITY_GAS_PRICE`, `ETH_GAS_PRICE`, `ETH_GAS_LIMIT`, `ETH_BLOB_GAS_PRICE`, `ETH_TIMEOUT`, `ETH_RPC_TIMEOUT`, `ETH_RPC_HEADERS`, `ETH_RPC_JWT_SECRET`, `ETHERSCAN_API_KEY` and `CHAIN`, and every variable whose name begins `FOUNDRY_` or `DAPP_` in any letter case, which forge reads as any of its settings, before it sets its own; it keeps the rehearsal on this machine's own loopback node, keeps no storage cache of the node it reads, filters every node address out of what it prints and keeps, and writes the run's manifest in two classes, the values two runs must share and the ones they may differ in. `compare` reads two manifests. `script/test-deploy-betting.sh` tests the wrapper.
- `docs/betting-events.json`: the betting set's events by position, for whoever reads the core's hub. For each type the hub carries: its name and keccak256, the module that emits it, the typed event's signature and topic 0, and the payload's fields in order with their ABI types; then the core's own four events and the relay's one. `script/BettingEventsSchema.s.sol` writes it from the build's artifacts, and `test/betting/BettingEventsSchema.t.sol` builds it again and requires the file to match.

Deploy day for the betting set, the checklist beside the script's own order. `<node>` is the sending machine's node, `<account>` the deployer's keystore, and each run's output names the values the next line takes.

The lines the wrapper does not run, anvil's start and the second machine's `cast` reads, each run by one recipe from the checkout's root, with the node given as `"$POLYGON_RPC_URL"`. Sourced, the wrapper runs nothing: the recipe refuses a `.env` where the tool would read one, clears every signer variable, those ten settings and every `FOUNDRY_` and `DAPP_` variable in any letter case, and passes both streams through the wrapper's filter before the screen and the log:

```
bash -c 'source script/deploy-betting.sh && require_no_dotenv && require_clean_environment && "$@" 2>&1 | filter | tee -a <the log>' _ <the line>
```

1. Hold whatever sends from the deployer on the sending machine, every timer and trigger; the deployer's nonce is the plan. The hold lasts through the signpost entry's execute, its reconciliation and its read-backs, and ends only at the day's own release. A run that stopped, or whose state is not known, stays held. A hold means the deployer's key sends nothing more, by any tool, until the day's order says so: `bootstrapModules` and `finalize` are never called by hand.
2. `script/deploy-betting.sh live predict <commit> --rpc-url <node>`, with `<commit>` checked out on a clean tree. It writes the plan and the manifest, and prints the digest. The plan, `prediction.json`, is never deleted: a second `predict` after a set exists is a new decision of the day's order.
3. The rehearsal, in a second checkout of the same commit, on this machine's own anvil forked at the plan's block plus one, started by the recipe: `anvil --fork-url "$POLYGON_RPC_URL" --fork-block-number <the plan's block + 1> --quiet --no-storage-caching`. Then these lines, with an `anvil_mine 64` before each `check`. A fork's sending line takes no go value and no `--account`: the wrapper gives the fork's own go value and sends as the deployer, unlocked.
   ```
   script/deploy-betting.sh fork setup                                          --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork predict      <commit>                          --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork create       <digest> <maxFee>                 --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork check        <core> <the core's creation block> 1 --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork bootstrap    <digest> <maxFee>                 --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork check        <core> <the core's creation block> 2 --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork finalize     <digest> <maxFee>                 --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork check        <core> <the core's creation block> 3 --rpc-url http://127.0.0.1:<port>
   script/deploy-betting.sh fork signpostCall <the core's creation block>         --rpc-url http://127.0.0.1:<port>
   ```
   Then `script/deploy-betting.sh compare <the rehearsal's manifest.json> <the plan's manifest.json>`: equal in the must-equal class.
4. Go, on the plan's digest, its maximum fee and its spend bound. The go value names the comment that gives them, which the operator reads against the plan before the first send. The maximum fee caps what a send can pay, and no tip set in the environment applies: if the node's suggested tip is above it, the send fails before anything is mined, and the fee is raised within the ceiling and the phase run again. The spend rule sums the gas the pinned forge counts for each remaining send, not the gas the chain charges: since Polygon's Chicago fork the chain charges more for a cold storage read, by a measurement on the chain 1.3% more for the ten sends and 37% more for the lock alone. Twice that sum in hand still covers the chain's charge, and the wrapper gives each send twice forge's count as its gas limit.
5. The three sending phases, each after the one before is final, each followed by its stage check:
   - `script/deploy-betting.sh live create <digest> <go> <maxFee> --rpc-url <node> --account <account>`, then `script/deploy-betting.sh live check <core> <the core's creation block> 1 --rpc-url <node>`;
   - `live bootstrap`, the same three values, then `check … 2`;
   - `live finalize`, the same three values, then `check … 3`.
6. `script/deploy-betting.sh live signpostCall <the core's creation block> --rpc-url <node>`. It writes `signpost-call.json` beside the plan.
7. A second machine rebuilds the entry's call with `cast` alone, from its own reads through a node chosen apart from the sending machine's, each line by the recipe. No input is copied from `signpost-call.json`, the file being checked. `<deployer>`, `<timelock>` and `<signpost>` are the script's table for chain 137, and each other input has its own source:
   ```
   # One final block F for every read below: its number and hash, and its hash again after the last read, unchanged.
   cast block finalized --field number --rpc-url "$POLYGON_RPC_URL"
   cast block <F> --field hash --rpc-url "$POLYGON_RPC_URL"
   # The commit: the reviewed commit's tag, in this machine's own clone.
   git rev-parse <the tag>^{commit}
   # The core's creation block, from its creation receipt. The transaction's hash, from the sending machine's
   # broadcast record, only finds the receipt: it must name the deployer as its sender, the core as its contract,
   # and a block at or below F whose hash is the one the receipt gives.
   cast receipt <the core's creation transaction> --rpc-url "$POLYGON_RPC_URL"
   cast tx <the core's creation transaction> nonce --rpc-url "$POLYGON_RPC_URL"                (k)
   cast compute-address <deployer> --nonce <k>                                                  (the core)
   cast block <the receipt's block number> --field hash --rpc-url "$POLYGON_RPC_URL"
   # The coin, from the core's own read, and the six modules, from its registry, all at F.
   cast call <core> "i_token()(address)" --block <F> --rpc-url "$POLYGON_RPC_URL"
   cast call <core> "getModule(bytes32)(address)" $(cast keccak MARKET_MODULE) --block <F> --rpc-url "$POLYGON_RPC_URL"
     (the same for POSITION_MODULE, MATCHING_MODULE, MONEYLINE_SCORER_MODULE, SPREAD_SCORER_MODULE and TOTAL_SCORER_MODULE)
   # The relay, by the deployer's nonce; its matching contract, from its own read, must be the registry's.
   cast compute-address <deployer> --nonce <k + 7>
   cast call <relay> "i_matching()(address)" --block <F> --rpc-url "$POLYGON_RPC_URL"
   cast call <timelock> "getMinDelay()(uint256)" --block <F> --rpc-url "$POLYGON_RPC_URL"
   # The call, field by field.
   cast calldata "addEntry(uint8,address,address[],bytes20,uint64)" 1 <coin> "[<core>,<markets>,<positions>,<matching>,<moneyline>,<spread>,<total>,<relay>]" <commit> <the core's creation block>
   cast keccak $(cast abi-encode "f(string,address)" "betting set" <core>)                     (the salt)
   cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" <signpost> 0 <addEntry> <32 zero bytes> <salt> <delay>
   cast calldata "execute(address,uint256,bytes,bytes32,bytes32)" <signpost> 0 <addEntry> <32 zero bytes> <salt>
   cast call <timelock> "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" <signpost> 0 <addEntry> <32 zero bytes> <salt> --block <F> --rpc-url "$POLYGON_RPC_URL"
   cast keccak <schedule>
   ```
   Every field must agree with `signpost-call.json`: the timelock, the signpost, the eight contracts, the commit, the creation block, the delay, the salt, the `addEntry`, `schedule` and `execute` calls, the operation id and the hash of the schedule's calldata. Its `previewId`, `finalizedBlock` and `finalizedHash` are what the sending machine's run saw: they are labelled apart, and not compared.
8. The key schedules the call on the timelock.
9. After the delay, anyone executes it.
10. The entry's id is the one the execute's `EntryAdded` log gives, and the entry is read back with `getEntry(<id>)`. The preview id in `signpost-call.json` is a preview, never an argument.

Build on the sending machine with the pinned forge, under the `ci` profile and CI's flags.

## License

[BUSL-1.1](LICENSE.md) — Business Source License 1.1. Converts to GPL-2.0-or-later on February 20, 2028.
