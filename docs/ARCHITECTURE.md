# Ospex Protocol Architecture

> **As of commit**: `b3d6647`
>
> This document describes v2, the contracts deployed on Polygon mainnet today, except its last section, [v3: the betting set's seams](#v3-the-betting-sets-seams).

Ospex is a decentralized peer-to-peer sports speculation protocol on Polygon. Zero vigorish — users set their own odds.

## Design Pattern

**Immutable Core Registry + Modular Plug-ins**

OspexCore serves as the central registry, event hub, and fee router. All business logic lives in independent modules that are registered once during deployment and permanently locked via `finalize()`.

```
OspexCore (Registry, Event Hub, Fee Router)
    |
    +-- MatchingModule         - EIP-712 commitment matching
    +-- PositionModule         - User fund escrow & claims
    +-- SpeculationModule      - Market lifecycle & settlement
    +-- ContestModule          - Sports events & scoring
    +-- CreOracleReceiver      - Chainlink CRE oracle integration
    +-- LeaderboardModule      - Competitions, ROI tracking, prizes
    +-- RulesModule            - Leaderboard eligibility rules
    +-- TreasuryModule         - Fee collection & prize pools
    +-- SecondaryMarketModule  - Position trading
    +-- MoneylineScorerModule  - Winner/loser scoring
    +-- SpreadScorerModule     - Point spread scoring
    +-- TotalScorerModule      - Over/under scoring
```

12 modules total. No upgrade path — see [TRUST_MODEL.md](./TRUST_MODEL.md).

---

## Core

### OspexCore.sol

Immutable core contract. Manages the module registry, cross-module event emission, and fee routing.

**Key Functions:**
- `bootstrapModules()` — One-time bulk registration of all modules (deployer only, before finalize)
- `finalize()` — Permanently locks the registry; deployer loses all privileges
- `emitCoreEvent()` — Unified event hub for off-chain indexing (registered modules only)
- `processFee()` / `processSplitFee()` — Routes fees to TreasuryModule
- `isApprovedScorer()` / `isSecondaryMarket()` — Module identity queries

### OspexTypes.sol

Shared type definitions:
- `Contest` — Sports event with away/home scores, league, status, creator, and the three provider external IDs (rundownId, sportspageId, jsonoddsId)
- `Speculation` — Market on a contest (moneyline, spread, total)
- `Position` — User stake with risk/profit amounts, fill timestamp, secondary market flag
- `SaleListing` — Secondary market position listing
- `Leaderboard` — Competition with entry fees, time windows, prize pools

**Key Enums:**
- `SpeculationStatus`: `Open`, `Closed`
- `WinSide`: `TBD`, `Away`, `Home`, `Over`, `Under`, `Push`, `Void`
- `PositionType`: `Upper` (away/over), `Lower` (home/under)
- `FeeType`: `ContestCreation`, `SpeculationCreation`, `LeaderboardCreation`
- `OracleRequestType`: `ContestCreate`, `ContestMarketsUpdate`, `ContestScore`

---

## Modules

### MatchingModule.sol

EIP-712 signed commitment matching engine. Makers sign off-chain commitments specifying contest, scorer, line, odds, risk amount, nonce, and expiry. Takers match on-chain via `matchCommitment()`.

**Key Functions:**
- `matchCommitment()` — Verifies signature, validates commitment, records fill via PositionModule. Auto-creates the speculation if it doesn't exist yet.
- `cancelCommitment()` — Maker cancels a specific commitment by hash
- `raiseMinNonce()` — Maker invalidates all commitments below a nonce threshold (per-speculation scope)

**Odds:** Expressed as oddsTick with `ODDS_SCALE = 100`. Example: 1.91 odds = 191 ticks, 2.50 odds = 250 ticks. Valid range: 101 (1.01x) to 10100 (101.00x). Risk amounts must be multiples of `ODDS_SCALE` (100).

**Design Notes:**
- Self-matching (maker == taker) is intentionally allowed
- Commitment expiry is the sole temporal guard — no contest start time check at match time
- Revert-or-exact-fill: does not auto-clip to remaining capacity
- See [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md) for rationale

### PositionModule.sol

User fund escrow. All USDC for matched positions sits here. Zero admin functions.

**Key Functions:**
- `recordFill()` — Records a fill for both maker and taker. Only callable by MatchingModule. Pulls USDC from both parties via `safeTransferFrom`.
- `claimPosition()` — User claims payout after speculation is settled (Closed status). Winners get risk + profit, push/void returns risk, losers get nothing.
- `transferPosition()` — Transfers position between addresses. Only callable by SecondaryMarketModule. Flags recipient as `acquiredViaSecondaryMarket`.

**Position Struct:** `{ riskAmount, profitAmount, positionType, claimed, firstFillTimestamp, acquiredViaSecondaryMarket }`

### SpeculationModule.sol

Market lifecycle. Speculations are auto-created on first fill (lazy creation) and settled permissionlessly.

**Key Functions:**
- `createSpeculation()` — Called by PositionModule during first fill. Charges split creation fee.
- `settleSpeculation()` — Permissionless. Scores via the speculation's scorer module if contest is scored, or auto-voids if the void cooldown has elapsed.
- `getSpeculationId()` — Reverse lookup: (contestId, scorer, lineTicks) → speculationId

**Status Flow:** `Open → Closed` (with winSide set to the outcome: Away/Home/Over/Under/Push/Void)

### ContestModule.sol

Sports events. Contests must be created and verified before speculations can exist.

All contest mutations are gated by the `onlyCreOracleReceiver` modifier — callable only by the module occupying the `CRE_ORACLE_RECEIVER` registry slot (the CreOracleReceiver).

**Key Functions:**
- `createContest()` — Creates event with the three provider external IDs. Only callable by the CreOracleReceiver.
- `setContestLeagueIdAndStartTime()` — Sets league and start time from the oracle report. Moves status to Verified. Only callable by the CreOracleReceiver.
- `setScores()` — Records final scores. Immutable once set — scores cannot be overwritten. Only callable by the CreOracleReceiver.
- `updateContestMarkets()` — Stores reference odds/lines from the oracle report. Only callable by the CreOracleReceiver.
- `voidContest()` — Marks contest as Voided. Only callable by SpeculationModule (during auto-void).

**Contest Status Flow:** `Unverified → Verified → Scored` (or `Verified → Voided`)

### CreOracleReceiver.sol

The Chainlink CRE oracle, occupying the `CRE_ORACLE_RECEIVER` registry slot. It replaces the retired R4 Chainlink Functions `OracleModule`. It has two halves: permissionless **request** entrypoints that emit a `CreOracleRequested` event, and a **receive** callback (`onReport`) the trusted KeystoneForwarder invokes with the off-chain workflow's signed report.

**Request entrypoints (permissionless):**
- `createContestAndRequestVerify()` — Creates the contest (Unverified) and emits a verify request. The caller pays the USDC contest-creation fee; the CRE workflow run itself is funded off-chain by the workflow owner.
- `requestMarketUpdate()` — Emits a market-update request for an existing Verified contest, bumping that contest's market request nonce.
- `requestScore()` — Emits a score request for an existing Verified contest (after its start time).

Each emits `CreOracleRequested` (watched off-chain by the CRE workflow via an EVM log trigger) and mirrors the request through the OspexCore hub.

**Receive — `onReport()` trust funnel:** The KeystoneForwarder delivers the DON's signed report; `onReport` enforces, in order:
1. `msg.sender` is the immutable KeystoneForwarder.
2. The report metadata's workflow **owner** (and the optional immutable workflow **name**) match the deployed workflow. (The workflow **ID** is intentionally not pinned — CRE rotates it on every update.)
3. The report's `chainId` and receiver match this chain/contract (domain separation).
4. Per-report idempotency: `keccak256(report)` applies at most once.
5. Fail-closed request/report binding: a **verify** or **score** report requires the matching per-contest request flag (set when the request was emitted); a **market** report must carry a nonce that was actually requested and not yet superseded (dual-nonce freshness — stale odds cannot overwrite fresh ones, and permissionless request spam cannot invalidate an in-flight legitimate report).

It then dispatches on the report's `requestType` and applies the verified result via ContestModule.

**Off-chain verification:** The off-chain CRE workflow (the separate `ospex-cre` repo) performs the triple-source verification (The Rundown + Sportspage + JSONOdds, 3-of-3 agreement) and scoring, then reports back through the KeystoneForwarder. There is no on-chain LINK subscription and no per-call LINK payment.

**Immutable constructor parameters:** `ospexCore`, `forwarder` (the trusted KeystoneForwarder), `workflowOwner`, and an optional `workflowName` pin. There is no approved signer, no script-hash storage, and no Ownable/setter.

**Governance (Ethereum mainnet):** The CRE workflow is owned directly by `OspexCreTimelock`, a per-action timelock (a close port of Chainlink's audited `Timelock.sol`). Every workflow operation — code update (`upsertWorkflow`), `deleteWorkflow`, `pauseWorkflow`, lifecycle — is timelocked 7 days; the only 1-second fast lane is the WorkflowRegistry's `allowlistRequest` (Vault secret allowlisting, behind every `cre secrets` command). A single cold-wallet controller holds proposer/executor/canceller, and the timelock self-administers after `configureAndLockdown()`. A compromised controller could push a malicious workflow change only after the 7-day window — and can never touch protocol funds. Full trust analysis: [TRUST_MODEL.md](./TRUST_MODEL.md).

### TreasuryModule.sol

Fee collection and prize pool accounting.

**Key Functions:**
- `processFee()` — Transfers flat fee directly to immutable `i_protocolReceiver`. Only callable by OspexCore.
- `processSplitFee()` — Splits fee between two payers. Used for speculation creation (maker + taker).
- `fundLeaderboard()` — Permissionless sponsorship: anyone can add USDC to a leaderboard's prize pool.
- `processLeaderboardEntryFee()` — Entry fees go entirely to the prize pool, not the protocol receiver.
- `claimPrizePool()` — Disburses prizes. Only callable by LeaderboardModule.

**Fee Rates:** Set at constructor time, immutable. Contest creation: 1.00 USDC. Speculation creation: 0.50 USDC (split). Leaderboard creation: 0.50 USDC.

### LeaderboardModule.sol

Permissionless competitions with ROI-based scoring. Anyone can create a leaderboard (pays creation fee). Winner-take-all: user(s) with the single highest ROI share the prize pool equally.

**Key Functions:**
- `createLeaderboard()` — Permissionless. Sets entry fee, time window, safety period, ROI submission window.
- `addLeaderboardSpeculation()` — Creator registers eligible speculations (creator-only, before end time)
- `registerUser()` — User joins with a declared bankroll and pays entry fee
- `registerPositionForLeaderboard()` — Snapshots position economics at registration time. Rejects positions acquired via secondary market or predating leaderboard start.
- `submitLeaderboardROI()` — Computes and records ROI during the submission window
- `claimLeaderboardPrize()` — Winners claim their share after the ROI window closes

### RulesModule.sol

Configurable rules engine for leaderboard participation. All rules are set by the leaderboard creator before start and locked once the leaderboard is active.

**Available Rules:**
- Min/max bankroll
- Min/max bet percentage (BPS of bankroll)
- Minimum positions (qualifying outcomes only)
- Odds enforcement (max BPS above market reference odds)
- Live betting toggle
- Number deviation limits (per league, scorer, position type)
- Moneyline/spread pairing restriction

### SecondaryMarketModule.sol

Position trading before settlement. Sellers list positions with a price; buyers commit using a hash of the listing state to prevent front-running.

**Key Functions:**
- `listPositionForSale()` — List with price, risk amount, profit amount
- `buyPosition()` — Buy with hash commitment (reverts if listing state changed)
- `updateListing()` — Modify price or amounts
- `cancelListing()` — Remove listing
- `claimSaleProceeds()` — Seller claims accumulated USDC from sales

**Design:** Non-proportional listings allowed. Partial buys scale price/profit proportionally. Payment flows through the contract; sellers claim proceeds separately. Transferred positions are flagged as leaderboard-ineligible.

### Scorer Modules

Determine outcomes from contest scores:

| Module | Purpose | lineTicks |
|--------|---------|-----------|
| MoneylineScorerModule | Winner/loser (no spread) | Always 0 |
| SpreadScorerModule | Point spread outcomes | Positive or negative |
| TotalScorerModule | Over/under total points | Always positive |

Each implements `determineWinSide(contestId, lineTicks)` returning which side won.

---

## Position Types

| Type | Value | Meaning |
|------|-------|---------|
| Upper | 0 | Away team or Over |
| Lower | 1 | Home team or Under |

---

## Protocol Flow

```
1. Oracle verifies contest (sports event created, start time set)
2. Oracle publishes market data (odds, lines)
3. Maker signs EIP-712 commitment (off-chain)
4. Taker matches commitment on-chain → speculation auto-created on first fill
5. USDC escrowed in PositionModule
6. Game ends → oracle scores contest (triple-source verification)
7. Anyone calls settleSpeculation() → scorer determines winning side
8. Users claim payouts from PositionModule
```

For the function-by-function version of each step — the exact contracts, gates, and cross-module hand-offs, in execution order — see [E2E_TRACES.md](./E2E_TRACES.md). That document is the recommended starting point for anyone verifying a protocol process from source.

---

## USDC Approvals (who is the spender?)

Three different contracts pull USDC directly from user wallets via `safeTransferFrom`, depending on the action. Approving only PositionModule is the most common integration mistake — a first fill on a new market will revert on the fee pull without a TreasuryModule allowance.

| Action | Approve (spender) | What is pulled |
|--------|-------------------|----------------|
| Match / fill (both sides' stakes) | **PositionModule** | `makerRisk` / `takerRisk` into escrow |
| First fill of a new market (speculation creation fee) | **TreasuryModule** | Half the fee from the maker, half from the taker |
| Create a contest (via `createContestAndRequestVerify`) | **TreasuryModule** | Contest-creation fee from the caller |
| Create a leaderboard | **TreasuryModule** | Leaderboard-creation fee from the creator |
| Register for a leaderboard (entry fee) | **TreasuryModule** | `entryFee` into the prize pool |
| Sponsor a prize pool (`fundLeaderboard`) | **TreasuryModule** | Sponsorship amount into the prize pool |
| Buy on the secondary market | **SecondaryMarketModule** | `purchasePrice` (escrowed, then claimable by the seller) |

Protocol fees are pulled by TreasuryModule (routed through OspexCore's `processFee`/`processSplitFee` relays) and go directly to the immutable protocol receiver; they never sit in TreasuryModule. Prize-pool money (entry fees, sponsorships) is held by TreasuryModule until winners claim.

---

## Security Model

- **ReentrancyGuard** on all fund-transferring functions (PositionModule, TreasuryModule, LeaderboardModule, SecondaryMarketModule, MatchingModule)
- **SafeERC20** for all token transfers
- **EIP-712** for commitment signatures (MatchingModule)
- **Checks-Effects-Interactions** pattern throughout
- **Zero admin functions** on PositionModule (user fund escrow)
- **Bootstrap-then-finalize** — no admin key after deployment
- **CreOracleReceiver passive validation** — the oracle has no admin function; it only accepts a DON report that clears the `onReport` trust funnel (trusted KeystoneForwarder, matching workflow owner/name, domain separation, per-report idempotency, fail-closed request binding). There are no on-chain script approvals.
- **Timelock-governed CRE workflow** — workflow ownership sits behind `OspexCreTimelock` (7-day delay on all workflow operations; see the CreOracleReceiver governance note above and [TRUST_MODEL.md](./TRUST_MODEL.md)).
- **Operator can halt, not steal** — an operator that stops running/funding the workflow can only stall scoring, which lets affected Verified contests auto-void and refund permissionlessly after the cooldown; settlement is immutable and settle/claim are permissionless.

---

## Network Deployments

See [DEPLOYMENT.md](./DEPLOYMENT.md) for addresses and deployment instructions.

| Network | Status |
|---------|--------|
| Local (Anvil) | Development |
| Polygon Amoy | Testnet |
| Polygon | Mainnet |

---

## v3: the betting set's seams

Everything above describes v2. This section describes `src/betting/`, the betting set of v3, as it stands: it is being built and is not deployed, and [spec-v3.md](./spec-v3.md) controls wherever the two differ. It answers what a reader of one contract asks about the others: who may call it, what it calls, and what each side relies on. Its headings follow the cross-module list of the review the spec cites under "From the July fresh-eyes review", less the entries the cut removed.

The set is seven contracts: the core, `OspexBetting`; three modules, `OspexMarkets`, `OspexPositions` and `OspexMatching`; and three market contracts, `OspexMoneylineScorer`, `OspexSpreadScorer` and `OspexTotalScorer`, which share `OspexScorer`. It reads one other set, the games set (`src/games/`), and holds one coin.

### Who may call whom

Every call one contract of the set makes to another, or out of the set, with the deployer's two calls first:

| Caller | Call | What the callee checks |
|--------|------|------------------------|
| The deployer | `OspexBetting.bootstrapModules`, `finalize` | The caller is the deployer, and finalize has not run |
| `OspexBetting`, in `bootstrapModules` | `getModuleType()` of each address it is asked to register | Nothing: each module's is a pure read. The core refuses an address whose answer is not the type it is registered under |
| `OspexBetting`, in `bootstrapModules` | `i_games()` of the markets module and of each market contract | Nothing: a public read of an immutable. The core refuses a module whose answer is not the core's own games set |
| `OspexBetting`, in `bootstrapModules` | `i_token()` of the positions module | Nothing: a public read of an immutable. The core refuses a module whose answer is not the core's own coin |
| `OspexBetting`, in `bootstrapModules` | `i_ospexCore()` of the markets, the positions and the matching module | Nothing: a public read of an immutable. The core refuses a module whose answer is not the core's own address. A market contract is not asked: it holds no core |
| `OspexMarkets` and the market contracts, in their constructors | `OspexBetting.i_games` | Nothing: a public read, copied once |
| `OspexPositions`, in its constructor | `OspexBetting.i_token` | Nothing: a public read, copied once |
| `OspexMatching`, in its constructor | `OspexBetting.i_games`, then that games set's `i_timelock` | Nothing: two public reads of immutables, copied once. The matching module refuses a games address with no code or with a wallet's delegation, and a zero timelock |
| The Polygon timelock | `OspexMatching.liftTakingStakeCap` | The caller is the timelock the matching module read at its deploy; the cap has not been lifted; no Cross is in progress |
| `OspexPositions` | `OspexMarkets.createMarket` | The caller is the address registered as the positions module |
| `OspexPositions`, at a fill | `OspexMarkets.getMarketId` | Nothing: a public read |
| `OspexPositions`, at a fill | `OspexMarkets.requireBetsOpen`, the close gate | Nothing about the caller: a public read. It refuses an id that is not a market, a settled market, a game that has ended, and a game at or after its start + n |
| `OspexPositions`, at a claim | `OspexMarkets.getMarket` | Nothing: a public read, which refuses an id that is not a market |
| `OspexMatching`, in `cross` | `OspexPositions.recordFill`, once for each leg it attempts | The caller is the address registered as the matching module. `cross` is the one function that makes this call |
| `OspexMarkets`, `OspexPositions`, `OspexMatching` | `OspexBetting.getModule` | Nothing: a public read of the registry |
| `OspexMarkets` | `OspexBetting.isApprovedScorer` | Nothing: a public read of the registry |
| `OspexMarkets`, `OspexPositions`, `OspexMatching` | `OspexBetting.emitCoreEvent` | The caller is a registered module |
| `OspexMarkets` | A market contract's `outcomeOf` | Nothing: a public read |
| `OspexMarkets` | The games set's `getGameStatus` | Nothing: a public read, which refuses an id that is not a game |
| `OspexMarkets`, at the close gate | The games set's `getGameStart` and `getGameWindow` | Nothing: public reads. `getGameStart` refuses a game whose start is not written, so the gate reads it only for a verified or a disputed game |
| The market contracts | The games set's `getGameScores` | Nothing: a public read, which refuses a game that is not scored |
| `OspexPositions`, at a fill | The coin's `transferFrom`, once from each of the two accounts, the maker's first; and its `balanceOf` for itself, before the two and after | The coin's own, among them the account's allowance to `OspexPositions` |
| `OspexPositions`, at a claim | The coin's `transfer`, to the account that claims | The coin's own. An ERC-20 `transfer` reads no allowance: the account approves nothing to be paid |

From outside the set: anyone settles a market (`settleMarket`) and reads; an account claims its own position (`claimPosition`), cancels its own order (`cancelOrder`), raises its own floor (`raiseMinNonce`), and registers and drops its own couriers (`registerCourier`, `unregisterCourier`); and a courier sends a Cross (`cross`). The games set calls nothing in the betting set, and the betting set writes nothing to the games set.

**An account's couriers are the account's to write.** A courier is an address an account names to send the fills of its orders. `registerCourier` and `unregisterCourier` take the courier and nothing else: the account is the caller, `msg.sender`, never `tx.origin`, so a contract an account calls writes its own couriers and not the account's. They are the only two functions that write a courier, and each writes the caller's own: no module, courier or other account writes an account's couriers for it, the contract has no owner, and an account that registered none has none, so there is no default. An account may hold several, its own address among them. `isCourier` is the read. `cross` checks its sender, the immediate caller, against the same record: the taking order's account must have registered it, or the call reverts, and a resting order whose account has not is skipped. An account that sends its own Cross has registered itself, like any other sender.

**The registry is wired once, then locked.** Each check above that names a registered module is a lookup in the core's registry at the time of the call, `msg.sender == core.getModule(type)`. The registry writes a type's address once, at its registration, and refuses a second registration of that type; `finalize` refuses any count of modules but six and any set but the required one, and after it nothing registers. So the lookups are not swap machinery: no call replaces a module, before finalize or after. Each contract declares the type hashes it looks up as constants of its own, and `bootstrapModules` checks each module's own answer to `getModuleType()` against the type it is registered under, and then its wiring, below. A type that is not registered resolves to the zero address, which `_getModule` refuses by name and which no caller is. `isApprovedScorer` refuses it too: it answers false for the zero address at every stage, before any market contract is registered, between their registrations and after finalize, so the empty slot of a market contract not yet registered approves nothing.

**The wiring is checked at registration.** Each of the three modules names its core (`i_ospexCore`); the markets module and the three market contracts each hold the games set they copied from their core at their own deploy (`i_games`), and the positions module the coin (`i_token`). `bootstrapModules` reads those getters after the type's and before the address is written: first the value the module's type holds, its games set or its coin, and last its core. No type is asked both a games set and a coin. It refuses by name a markets module or a market contract whose games set is not the core's (`ModuleGamesMismatch`), a positions module whose coin is not the core's (`ModuleTokenMismatch`), and a markets, positions or matching module that names another core (`ModuleCoreMismatch`). The core is asked last: a module of this repository copies its games set and its coin from its core, so one deployed with a core of another games set or another coin is told which value is wrong. A refusal reverts the whole call and writes nothing, so the type stays free for the right module, and `finalize`, which reads no module, locks only addresses that passed. A read that fails fails the whole call, with the read's own revert data: none, for an address that has no such function.

A market contract is checked on its games set alone. It holds no core address: it copies the games set at its deploy and never calls the core again, and the games set is what its settlements read. So a market contract deployed with another core that names the same games set is the same code holding the same value, and it registers. A type outside the six is asked its type and nothing else. It can still be registered, and a core that holds one cannot finalize: its count is not six, or one of the six types is missing.

What the check does not prove. It reads what a module answers and not its code, so a contract written to answer the core's values registers, whatever else it does, and it takes the core's own games set and coin as given. It stops a mistake at the deploy: a markets, positions or matching module deployed with the wrong core, or any module left from an earlier run on another games set or another coin. That each address holds this repository's build, and that the core itself was deployed with the right games set and the right coin, are the deploy's to prove before finalize.

### Where coin is accepted, and the one approval

The set pulls coin in one place: `OspexPositions._record`, reached only through `recordFill`, pulls the maker's stake and then the taker's with `transferFrom`. A pull the coin refuses, by reverting or by answering false, reverts the fill under its own name, one for each of the two accounts, carrying the account and the amount; no balance or allowance is read first. After the two pulls the fill reverts unless the contract's balance rose by at least the two stakes: coin that arrives beside the pulls cannot fail that, and a short receipt always does. Those stakes are the coin the set accounts for. Both accounts approve `OspexPositions` for the coin and nothing else: no fee is taken at a fill, so there is no second spender. The set sends coin in one place: `claimPosition` pays a position's payout to the account that claims it, with `transfer`. Coin can also be sent to a contract of the set by a plain transfer, outside any function of the set: that coin is counted by nothing, belongs to no position, and no function sends it back (see "The coin").

What a fill is checked against, and where:

- That the caller is the matching module: `OspexPositions.recordFill`.
- That both stakes are above zero: `OspexPositions._fill`.
- At the first fill on a game, a market contract and a line, when the market is drawn: `OspexMarkets._create` checks the line's bound, that the game is a game of the games set and has not ended, that the market contract is one of the three, and that it takes the line.
- At every fill: `OspexPositions._record` calls the close gate, `OspexMarkets.requireBetsOpen`, which refuses an id that is not a market, a settled market, a game that has ended, and a game whose start is written at or after its start + n, n being the game's own window. Bets close when the game scores or at start + n, whichever comes first. A game whose start is not written has no start + n and takes fills until it is verified or released. Nothing checks the start itself: at kickoff and after it, inside n, a fill lands.
- Everything about the signed orders: `OspexMatching.cross`, before it calls `recordFill`. See "The Cross" below.

A market stays `Open` after its game ends until someone settles it; the close gate, which reads the game, is what refuses its fills meanwhile.

### The Cross

`cross(taking, resting)` is the one path a fill arrives by. The sender, the immediate caller and never `tx.origin`, lists one taking order and the resting orders it is to fill against, in order, each with its signature. It chooses the orders and their order and nothing else.

Before anything moves, each of these reverts the whole call under its own name: a Cross already in progress; a sender the taking order's account has not registered; a taking order that is badly signed, at a price or for a stake that is not admissible, signed for more than the one-cent cap while the cap is in force (below), cancelled, expired, more than 30 seconds from its expiry, or full; and a resting order, anywhere in the list, that is badly signed, not admissible, on another game, market contract or line, on the taking order's side, or at a price that does not meet the taking order's. The order among these checks is not promised, but for this: an order's own price and stake are tested before its room is read and before its price is compared with another order's, since a zero stake has no room and a price out of range meets no price; and the cap on a taking stake is tested after the signature, the price and the lot. A call with two faults otherwise reverts under either name.

Then the walk, one leg for each resting order in list order. An order is filled or skipped, and a skipped order is recorded under the first reason that applies, in this order: its account has not registered the sender; it is cancelled, by its own cancel or under its account's floor; it has expired; it has no room left; nothing fits the lot; the coin refused the pull of its account's stake. A leg takes k lots of 100 units of resting stake, k being the smaller of the resting order's room over 100 and the taking stake left over p, p the resting price's ticks less 100: the resting account stakes 100 x k and the taking account k x p, which is the resting price to the unit, and a leg fills only if neither stake is under 100 units. One filled amount is kept for each order, by its hash, in its own stake, whichever role it plays and across Crosses. If no leg filled, the call reverts, and its refusal carries each listed order's reason: the skip records of a reverted call do not exist.

What each side of the seam decides. `OspexMatching` decides which orders may fill, and for how much; it holds no coin and is approved for none. `OspexPositions` decides whether the fill lands: the market, the close gate, the two pulls and the receipt. The matching module reads one failure of that call as a skip: the positions module's `OspexPositions__MakerPullRefused`, recognised only when the revert data is exactly that error for this leg, 68 bytes, the selector, then this leg's resting account and resting stake. It then writes both orders' filled amounts back as they were. Every other revert of the call reverts the Cross with its data unchanged: the taking account's refused pull, a short receipt, the close gate, a market that cannot be drawn.

One Cross at a time. While a Cross is in progress, the matching module refuses another Cross, a cancel, a raised floor, a registration, a drop and the cap's lift, each under one name. These six are its only functions that change state, so from a Cross's first check to its end nothing but that Cross changes a cancel mark, a floor, a courier, a filled amount or the cap's flag. The positions module keeps its own guard on `recordFill` and `claimPosition`. The reads are not held: one made from inside a Cross, by a contract the coin calls during a pull, shows the legs done so far and the leg in progress, which is taken back if that leg is skipped.

What this build is not. Each stake is pulled in full at each leg: netting, one rebalance for the taking account and pay-backs come with shared collateral. The account's own key signs, with a 65-byte signature: the approved agent and contract wallets come with the agent. A position is claimed by its owner.

The cap and its switch. Until the switch, a taking order's signed stake is at most `TAKING_STAKE_CAP`, one cent, 10,000 units of the coin, 100 lots: a taking order signed for more is refused under its own name before anything moves, whatever it has filled so far and on either side; the signed stake decides, not what is left to fill. Resting stakes are not capped: what the other side puts up follows from the odds, up to a dollar against one cent at the shortest price. The switch is `liftTakingStakeCap`, which the matching module takes from the Polygon timelock alone, once: a second call is refused by name, a call while a Cross is in progress is refused under the exclusion's name, and no function puts the cap back. The timelock's address is read once, from the games set the core names, when the matching module is deployed, and kept as `i_timelock`; the seams table above has the constructor's two reads and the timelock's call. `s_takingStakeCapLifted` is the read.

### One event, emitted twice

Each state change of the three modules emits a typed event from the module and, through `OspexBetting.emitCoreEvent`, a `CoreEventEmitted` from the core that carries the event's type, the module that emitted it and a payload, so an indexer can follow one address. There are twelve types, each the keccak256 of the string below, and each payload is the typed event's parameters in the typed event's order, ABI-encoded:

| Core event type | Typed event | Emitted by |
|-----------------|-------------|------------|
| `MARKET_CREATED` | `MarketCreated` | `OspexMarkets` |
| `MARKET_SETTLED` | `MarketSettled` | `OspexMarkets` |
| `POSITION_MATCHED_PAIR` | `PositionFilled` | `OspexPositions` |
| `POSITION_CLAIMED` | `PositionClaimed` | `OspexPositions` |
| `ORDER_CANCELLED` | `OrderCancelled` | `OspexMatching` |
| `MIN_NONCE_UPDATED` | `MinNonceUpdated` | `OspexMatching` |
| `COURIER_REGISTERED` | `CourierRegistered` | `OspexMatching` |
| `COURIER_UNREGISTERED` | `CourierUnregistered` | `OspexMatching` |
| `ORDER_MATCHED` | `OrderMatched` | `OspexMatching` |
| `ORDER_SKIPPED` | `OrderSkipped` | `OspexMatching` |
| `CROSSED` | `Crossed` | `OspexMatching` |
| `TAKING_STAKE_CAP_LIFTED` | `TakingStakeCapLifted` | `OspexMatching` |

The fill's two names differ: the typed event is `PositionFilled` and the core type is `POSITION_MATCHED_PAIR`. The core checks that the emitter is a registered module, and nothing about the type or the payload. The core's own four events (`GamesSet`, `TokenSet`, `ModulesBootstrapped`, `Finalized`) are emitted once, by the core. This table is the twelve as they stand; the schema the spec asks for, for an indexer, is written when the set's events are complete.

What a Cross emits, in order, each followed by its copy through the hub: for a filled leg, `MarketCreated` if the leg draws the market, then `PositionFilled`, then `OrderMatched`; for a skipped order, `OrderSkipped`; and once, last, `Crossed`. `PositionFilled`'s taker is the taking order's account, never the sender; `Crossed` names the sender, as its courier. `OrderMatched` carries the fields v2's per-order fill event carried, in their order and with the same three indexed, under v3's names. `OrderSkipped` carries the reason as a number, in the order the reasons are tested: 0 no courier, 1 cancelled, 2 expired, 3 no room, 4 nothing fits, 5 pull refused. It exists only for a Cross that filled at least one leg.

### The market contracts and the one outcome enum

`Outcome` holds every market contract's results in one enum, and which of its values a settlement writes depends on the market's contract: the moneyline and the spread return `Home`, `Away` or `Push`; the total returns `Over`, `Under` or `Push`; `OspexMarkets` writes `Void` itself, with no call to a market contract, when the game is voided or released; `None` is the value of a market that is not settled. A market's contract is the address in its `scorer` field, checked to be one of the three when the market is drawn; which of the three it is, is that contract's `getModuleType()`.

Which side an outcome pays is decided in one place, `OspexPositions._payout`: side A on `Home` or `Over`, side B on `Away` or `Under`, and each side its own stake on `Push` or `Void`. Side A is the home team on a moneyline or a spread, and over on a total.

The two scales are stated once, in `OspexBettingTypes.sol`: a line is in tenths of a point, a price in hundredths of decimal odds. A market contract's arithmetic assumes what a market can hold, scores of at most the games set's `MAX_SCORE` and a line within `MAX_LINE_TICKS`. Its pure read, `outcome`, takes any numbers and is correct within those bounds only.

### The games set

The betting set reads the games set through four calls. `OspexMarkets` reads `getGameStatus` when it draws a market, where the game must exist and must not have ended; at the close gate, at every fill; and when it settles a market, where the status alone decides: on a scored game the market contract names the outcome; on a voided or a released game the outcome is `Void`; anything else, a dispute record included, is refused. At the close gate it also reads `getGameStart` and `getGameWindow`, for a game whose start is written, and refuses the fill at or after their sum. A market contract reads `getGameScores`, the home team's score then the away team's, which the games set refuses unless the game is scored; the status is read first, so the scores are read only on a scored game.

A settlement reads no start and waits out no clock, and nothing here ends a game: the games set ends every game, and a market follows. A market on an ended game is settled by whoever calls `settleMarket`; nothing settles it on its own.

### The coin

The coin is fixed at the core's deploy and copied by the positions module at its own. With a coin that moves exactly the amount asked, as USDC does, what the module holds for a market is what the market's positions can claim. Coin sent to the module outside a pull belongs to no position, and nothing sends it back.

What the set holds with any coin, and what it does not. A fill is recorded only if the positions module's balance rose by at least the two stakes it writes into the two positions, and a call the coin makes during a pull can record no fill, pay no claim, cancel no order, raise no floor, change no courier and start no Cross: the positions module's guard and the matching module's exclusion refuse each. So whatever a coin does during a fill, no position is recorded that the contract's balance did not rise to cover. What a coin does outside a fill, a rebase or a fee on the transfer that pays a claim, is not checked: choosing the coin is the deploy's.

A coin that calls the debited account during a transfer hands that account a way to make a Cross fail. From inside its own pull it can end the game, where the game's release is open to anyone: the next leg then meets the close gate, the whole Cross reverts, and the release reverts with it. Or it can spend the gas passed to it, so that the Cross runs out of gas. Either way the account pays no coin and every fill of that Cross is lost. Nothing is built against this: no gas limit is put on a pull, which could one day fail real transfers, and no leg is skipped at the close gate. USDC makes no such call.

### What the cut removed from the list

Three entries of the review's list lived in the modules the cut dropped: the leaderboard's transfer locks, a position's provenance fields, and the order of settlement and a leaderboard's scoring. A fourth, the report envelope, is the games set's reporter's.
