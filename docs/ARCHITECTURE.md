# Ospex Protocol Architecture

Ospex is a decentralized peer-to-peer sports betting protocol. This document outlines the smart contract architecture.

## Design Pattern

**Minimal Core Registry + Modular Plug-ins**

OspexCore serves as the central registry and access control hub. All business logic lives in independent modules that register with the core.

```
OspexCore (Registry & Access Control)
    |
    +-- PositionModule      - User positions & matching
    +-- SpeculationModule   - Market lifecycle
    +-- ContestModule       - Sports events
    +-- LeaderboardModule   - Competitions & prizes
    +-- RulesModule         - Position eligibility
    +-- TreasuryModule      - Fee collection
    +-- OracleModule        - Chainlink Functions
    +-- SecondaryMarketModule - Position trading
    +-- ContributionModule  - Priority queue
    +-- Scorer Modules      - Outcome determination
```

---

## Core

### OspexCore.sol
Central registry and access control. Manages module registration, role assignments, and provides shared state access to all modules.

**Key Functions:**
- `registerModule()` - Register a module address
- `setTokenAddress()` - Configure the payment token (USDC)
- Role management via OpenZeppelin AccessControl

### OspexTypes.sol
Shared type definitions used across all modules:
- `Contest` - Sports event with teams, start time, scores
- `Speculation` - Market on a contest (moneyline, spread, total)
- `Position` - User stake with matched/unmatched amounts
- `OddsPair` - Upper/lower odds for a speculation
- `Leaderboard` - Competition with entry fees and prize pools
- `Listing` - Secondary market position listing

**Odds Precision:** 1e7 (e.g., 1.80 odds = 18,000,000)

---

## Modules

### PositionModule.sol
Handles all position lifecycle operations. This is where user funds enter and exit the protocol.

**Key Functions:**
- `createUnmatchedPair()` - Create position at desired odds
- `completeUnmatchedPair()` - Match against existing position
- `adjustUnmatchedPair()` - Modify unmatched amount or flags
- `claimPosition()` - Withdraw winnings after resolution

### SpeculationModule.sol
Manages speculation (market) lifecycle and status transitions.

**Key Functions:**
- `createSpeculation()` - Create market for a contest
- `setSpeculationStatus()` - Open, lock, resolve, or cancel
- `resolveSpeculation()` - Record winning side after oracle response

**Status Flow:** `Pending -> Open -> Locked -> Resolved/Cancelled`

### ContestModule.sol
Manages sports events. Contests must exist before speculations can be created.

**Key Functions:**
- `createContest()` - Create event with teams and start time
- `setScores()` - Record final scores from oracle
- `setContestStatus()` - Mark verified or cancelled

### OracleModule.sol
Chainlink Functions integration for fetching game results.

**Key Functions:**
- `sendRequest()` - Request scores from off-chain API
- `fulfillRequest()` - Callback with oracle response
- Handles score parsing and contest updates

### TreasuryModule.sol
Collects protocol fees and manages prize pools.

**Key Functions:**
- `collectFee()` - Take percentage from payouts
- `withdrawFees()` - Admin withdrawal of collected fees

**Fee:** Configurable, taken from winning payouts

### LeaderboardModule.sol
Manages ROI-based competitions with entry fees and prizes.

**Key Functions:**
- `createLeaderboard()` - Create competition with parameters
- `enterLeaderboard()` - User pays entry fee to join
- `recordPosition()` - Track position for ROI calculation
- `distributePrizes()` - Pay out winners

### RulesModule.sol
Validates position eligibility for leaderboard participation.

**Key Functions:**
- `validatePosition()` - Check if position meets leaderboard rules
- Rules include: min/max amount, allowed speculation types

### ContributionModule.sol
Priority queue ordering for unmatched positions.

**Key Functions:**
- `contribute()` - Pay to boost queue position
- Contributions go to protocol treasury

### SecondaryMarketModule.sol
Enables trading of matched positions before resolution.

**Key Functions:**
- `listPositionForSale()` - List position at asking price
- `updateSaleListing()` - Modify price or amount
- `cancelSaleListing()` - Remove listing
- `purchasePosition()` - Buy listed position

### Scorer Modules
Determine outcomes based on final scores:

| Module | Purpose |
|--------|---------|
| MoneylineScorerModule | Winner/loser (no spread) |
| SpreadScorerModule | Point spread outcomes |
| TotalScorerModule | Over/under total points |

Each implements `scoreSpeculation()` returning which side (upper/lower) won.

---

## Position Types

| Type | Value | Meaning |
|------|-------|---------|
| Upper | 0 | Away team or Over |
| Lower | 1 | Home team or Under |

---

## Protocol Flow

```
1. Contest created (sports event)
2. Speculation created (market on that event)
3. Users create/complete positions
4. Game starts -> speculation locked
5. Game ends -> oracle fetches scores
6. Scorer determines winner
7. Users claim winnings
```

---

## Security Model

- **ReentrancyGuard** on all fund-transferring functions
- **SafeERC20** for token transfers
- **AccessControl** for privileged operations
- Checks-Effects-Interactions pattern throughout

---

## Network Deployments

See [DEPLOYMENT.md](./DEPLOYMENT.md) for deployment instructions.

| Network | Status |
|---------|--------|
| Local (Anvil) | Development |
| Polygon Amoy | Testnet |
| Polygon | Mainnet |
