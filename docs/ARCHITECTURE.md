# Ospex Protocol Architecture

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
    +-- OracleModule           - Chainlink Functions integration
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
- `Contest` — Sports event with scores, league, external IDs, source hashes
- `Speculation` — Market on a contest (moneyline, spread, total)
- `Position` — User stake with risk/profit amounts, fill timestamp, secondary market flag
- `SaleListing` — Secondary market position listing
- `Leaderboard` — Competition with entry fees, time windows, prize pools
- `ScriptApproval` — EIP-712 signed approval for oracle JavaScript sources

**Key Enums:**
- `SpeculationStatus`: `Open`, `Closed`
- `WinSide`: `TBD`, `Away`, `Home`, `Over`, `Under`, `Push`, `Void`
- `PositionType`: `Upper` (away/over), `Lower` (home/under)
- `FeeType`: `ContestCreation`, `SpeculationCreation`, `LeaderboardCreation`

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

**Key Functions:**
- `createContest()` — Creates event with external IDs and source hashes. Only callable by OracleModule.
- `setContestLeagueIdAndStartTime()` — Sets league and start time from oracle callback. Moves status to Verified.
- `setScores()` — Records final scores. Immutable once set — scores cannot be overwritten.
- `updateContestMarkets()` — Stores reference odds/lines from oracle. Only callable by OracleModule.
- `voidContest()` — Marks contest as Voided. Only callable by SpeculationModule (during auto-void).

**Contest Status Flow:** `Unverified → Verified → Scored` (or `Verified → Voided`)

### OracleModule.sol

Chainlink Functions integration. Permissionless — anyone can trigger oracle requests by paying LINK.

**Key Functions:**
- `createContestFromOracle()` — Creates contest, verifies three EIP-712 script approvals, sends Chainlink request for verification
- `updateContestMarketsFromOracle()` — Sends request to update market data (odds, lines). Source hash validated against per-contest stored hash.
- `scoreContestFromOracle()` — Sends request to score a contest. Source hash validated against per-contest stored hash.

**Script Approval System:** Contest creation requires three EIP-712-signed `ScriptApproval` structs (verify, market update, score) from the immutable `i_approvedSigner`. Each approval binds a script hash to a purpose, optional league scope, and optional expiry. Approvals are checked at creation time only — subsequent oracle calls validate by hash match.

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

---

## Security Model

- **ReentrancyGuard** on all fund-transferring functions (PositionModule, TreasuryModule, LeaderboardModule, SecondaryMarketModule, OracleModule, MatchingModule)
- **SafeERC20** for all token transfers
- **EIP-712** for commitment signatures (MatchingModule) and script approvals (OracleModule)
- **Checks-Effects-Interactions** pattern throughout
- **Zero admin functions** on PositionModule (user fund escrow)
- **Bootstrap-then-finalize** — no admin key after deployment
- **Hash-locked scripts** — oracle JS validated against per-contest stored hashes

---

## Network Deployments

See [DEPLOYMENT.md](./DEPLOYMENT.md) for addresses and deployment instructions.

| Network | Status |
|---------|--------|
| Local (Anvil) | Development |
| Polygon Amoy | Testnet |
| Polygon | Mainnet |
