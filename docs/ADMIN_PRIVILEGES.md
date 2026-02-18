# Admin Privileges & Trust Model

> **Last updated**: 2026-02-18
> **Chain**: Polygon mainnet (chain ID 137)
> **OspexCore**: `0x8016b2C5f161e84940E25Bb99479aAca19D982aD`
> **Deployer wallet**: `0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886`

---

## TL;DR

| Question | Answer |
|----------|--------|
| Can the deployer pause the contract? | **No** — no pause mechanism exists in any contract |
| Is there an upgrade/proxy mechanism? | **No** — but modules can be swapped via the core registry (see [Module Swap Risk](#module-swap-risk)) |
| Can the deployer withdraw user position funds? | **No** — PositionModule has zero admin functions |
| Can the deployer change fees? | **Yes** — fee rates, protocol cut %, and fee receiver address |
| What's the worst the deployer can do? | Module swap (disrupts new activity + locks unclaimed positions until re-registered), redirect protocol fees, sweep unclaimed leaderboard prizes after claim window |

---

## Per-Contract Admin Functions

### OspexCore (`0x8016b2C5f161e84940E25Bb99479aAca19D982aD`)

The minimal core contract. Manages module registry and access control.

- **Admin**: `0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886`
- **Pausable**: No
- **Upgradeable**: No (module registry pattern — see [Module Swap Risk](#module-swap-risk))
- **Admin can withdraw user funds**: No
- **Admin-only functions**:
  - `registerModule(bytes32, address)` — swaps a module address in the registry. Requires `MODULE_ADMIN_ROLE`.
  - `proposeAdmin(address)` — initiates two-step admin transfer. Requires `DEFAULT_ADMIN_ROLE`.
  - `setMarketRole(address, bool)` — grants/revokes secondary market access. Requires `DEFAULT_ADMIN_ROLE`.
- **Inherited from AccessControl**: `grantRole`, `revokeRole`, `renounceRole`

---

### PositionModule (`0xF717aa8fe4BEDcA345B027D065DA0E1a31465B1A`)

User fund escrow. All USDC for positions sits here.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions**: **None** — zero `onlyAdmin` or role-gated functions
- **Key trust property**: The deployer cannot withdraw, redirect, or freeze escrowed USDC. Funds leave only via `claimPosition()` (user claims winnings) or `adjustUnmatchedPair()` (user withdraws their own unmatched amount).
- **Note**: `claimPosition()` calls `emitCoreEvent()` on OspexCore. If PositionModule is unregistered via a module swap, this call reverts, temporarily blocking claims. See [Module Swap Risk](#module-swap-risk).

---

### SpeculationModule (`0x599FFd7A5A00525DD54BD247f136f99aF6108513`)

Market creation and settlement.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `setMinSpeculationAmount(uint256)` — sets minimum position size
  - `setMaxSpeculationAmount(uint256)` — sets maximum position size
  - `setVoidCooldown(uint32)` — sets void timeout (minimum 1 day)
- **Role-gated functions**:
  - `forfeitSpeculation(uint256)` — forfeits a speculation after void cooldown. Requires `SPECULATION_MANAGER_ROLE`. Currently **not granted to anyone**.

---

### ContestModule (`0x9E56311029F8CC5e2708C4951011697b9Bb40A09`)

Oracle-scored sports events.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `setCreateContestSourceHash(bytes32)` — updates the hash of the Chainlink Functions JS source for contest creation
  - `setUpdateContestMarketsSourceHash(bytes32)` — updates the hash for market data update source
- **Role-gated functions**:
  - `scoreContestManually(uint256, uint32, uint32)` — manually scores a contest. Requires `SCORE_MANAGER_ROLE`. Only callable after a 2-day wait period (`MANUAL_SCORE_WAIT_PERIOD`). Currently **not granted to anyone**.
- **Oracle-gated functions**: `createContest`, `setContestLeagueIdAndStartTime`, `setScores`, `updateContestMarkets` — only callable by OracleModule.

---

### TreasuryModule (`0x48Fe67B7b866Ce87eA4B6f45BF7Bcc3cf868ccD0`)

Fee routing and prize pool management. Holds fee revenue and leaderboard prize pools.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No (cannot access PositionModule escrow)
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `setFeeRates(FeeType, uint256)` — sets fee rate for a given fee type
  - `setProtocolCut(uint256)` — sets protocol cut in basis points (max 10000 = 100%)
  - `setProtocolReceiver(address)` — **redirects protocol fee revenue to arbitrary address**
- **Module-gated functions**: `processFee` (only OspexCore), `processLeaderboardEntryFee` (only OspexCore), `claimPrizePool` (only LeaderboardModule)

---

### LeaderboardModule (`0xEA6FF671Bc70e1926af9915aEF9D38AD2548066b`)

Competitions, ROI tracking, and prizes.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No (cannot access PositionModule escrow)
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `createLeaderboard(...)` — creates a new competition
  - `addLeaderboardSpeculation(uint256, uint256)` — registers a speculation as eligible for a leaderboard
  - `adminSweep(uint256, address)` — **sends unclaimed leaderboard prizes to arbitrary address**. Only callable after the claim window has ended. Cannot touch escrowed position funds.

---

### RulesModule (`0xEfDf69ef9f3657d6571bb9c979D2Ce3D7Afb6891`)

Leaderboard eligibility rules. All rule setters are **time-locked**: they revert if the leaderboard has already started.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`, time-locked to before leaderboard start):
  - `setMinBankroll(uint256, uint256)`
  - `setMaxBankroll(uint256, uint256)`
  - `setMinBetPercentage(uint256, uint16)`
  - `setMaxBetPercentage(uint256, uint16)`
  - `setMinBets(uint256, uint16)`
  - `setOddsEnforcementBps(uint256, uint16)`
  - `setAllowLiveBetting(uint256, bool)`
  - `setDeviationRule(uint256, LeagueId, address, PositionType, int32)`

---

### OracleModule (`0x5105b835365dB92e493B430635e374E16f3C8249`)

Chainlink Functions integration for contest creation, market updates, and scoring.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `setLinkDenominator(uint256)` — adjusts LINK payment per oracle request
- **Permissionless functions**: `createContestFromOracle`, `updateContestMarketsFromOracle`, `scoreContestFromOracle` — callable by anyone (they pay LINK for the Chainlink request). Source code hashes are validated against ContestModule's stored hashes.

---

### SecondaryMarketModule (`0x85E25F3BC29fAD936824ED44624f1A6200F3816E`)

Position trading/selling.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `setMinSaleAmount(uint256)` — sets minimum listing size
  - `setMaxSaleAmount(uint256)` — sets maximum listing size
- **Note**: The `buyPosition` function calls `transferPosition` on PositionModule, which requires `MARKET_ROLE`. Currently **MARKET_ROLE is not granted** to SecondaryMarketModule, meaning secondary market trading is not yet active.

---

### ContributionModule (`0x384e356422E530c1AAF934CA48c178B19CA5C4F8`)

Voluntary user contributions (charity/donation feature). **Dormant** — deployed but contribution token and receiver are not set.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions** (require `DEFAULT_ADMIN_ROLE`):
  - `setContributionToken(address)` — sets which token is used for contributions
  - `setContributionReceiver(address)` — **redirects voluntary contributions to arbitrary address** (or disables by setting to zero address)

---

### Scorer Modules (MoneylineScorerModule, SpreadScorerModule, TotalScorerModule)

| Contract | Address |
|----------|---------|
| MoneylineScorerModule | `0x82c93AAf547fC809646A7bEd5D8A9D4B72Db3045` |
| SpreadScorerModule | `0x4377A09760b3587dAf1717F094bf7bd455daD4af` |
| TotalScorerModule | `0xD7b35DE1bbFD03625a17F38472d3FBa7b77cBeCf` |

Pure scoring logic. Determine `WinSide` from contest scores and speculation parameters.

- **Pausable**: No
- **Upgradeable**: No
- **Admin can withdraw user funds**: No
- **Admin-only functions**: **None** — zero admin functions in all three contracts

---

## Roles Table

| Role | What It Can Do | Who Holds It | Admin Role (can grant/revoke) |
|------|---------------|-------------|-------------------------------|
| `DEFAULT_ADMIN_ROLE` | All admin functions across modules, grant/revoke all roles | `0xfd6C...5886` (deployer) | `DEFAULT_ADMIN_ROLE` (self-administering) |
| `MODULE_ADMIN_ROLE` | Register/swap module addresses via `registerModule()` | `0xfd6C...5886` (deployer) | `DEFAULT_ADMIN_ROLE` |
| `MARKET_ROLE` | Transfer matched positions in PositionModule (secondary market) | **Nobody** — not yet granted | `DEFAULT_ADMIN_ROLE` |
| `SCORE_MANAGER_ROLE` | Manually score contests after 2-day wait period | **Nobody** — not yet granted | `DEFAULT_ADMIN_ROLE` |
| `SPECULATION_MANAGER_ROLE` | Forfeit speculations after void cooldown | **Nobody** — not yet granted | `DEFAULT_ADMIN_ROLE` |

---

## Fund Flow

```
User deposits USDC
       │
       ▼
┌─────────────────┐
│ PositionModule   │ ← USDC escrowed here (zero admin functions)
│ (0xF717...5B1A)  │
└────┬──────┬──────┘
     │      │
     │      ▼
     │   Fees deducted ──► TreasuryModule (0x48Fe...ccD0)
     │                         │
     │                    ┌────┴─────┐
     │                    │          │
     │                    ▼          ▼
     │              Protocol      Leaderboard
     │              Receiver      Prize Pool
     │            (0xdaC6...)    (in TreasuryModule)
     │
     ▼
  User claims via claimPosition()
  USDC returned directly from PositionModule to user
```

**Key**: Fees flow through TreasuryModule. Position funds never leave PositionModule except back to the user (claim/adjust) or to the taker on match. The deployer cannot redirect position funds — only fee revenue.

---

## Module Swap Risk

This is the protocol's most significant trust dependency.

### How it works

The deployer (holding `MODULE_ADMIN_ROLE`) can call `OspexCore.registerModule(bytes32, address)` to point any module type at a new address. When a module is swapped:

1. The old module address is marked `s_isModuleRegistered[oldAddress] = false`
2. The new address is marked `s_isModuleRegistered[newAddress] = true`
3. Any call from the old module to `emitCoreEvent()` will revert with `OspexCore__NotRegisteredModule`

### Impact on existing funds

- **The deployer CANNOT extract funds** from the old PositionModule. There is no admin withdrawal function — it simply doesn't exist in the contract.
- **Claims are blocked**: `claimPosition()` calls `emitCoreEvent()` at the end. If PositionModule is unregistered, this call reverts, preventing users from claiming. Funds remain locked in the contract.
- **The deployer CAN re-register** the old module to restore claiming at any time.
- **A malicious replacement module** could steal NEW deposits but not existing ones (existing USDC sits in the old contract's storage).

### Impact on new activity

- A new module with different logic could allow unfair position creation, altered odds calculation, or fee manipulation for new positions.
- Users interacting with the protocol after a swap would be using the new module's logic.

### Why this capability exists

The protocol has not been professionally audited. The deployer retains the ability to swap modules in case a bug is discovered post-deployment. This is a pragmatic tradeoff: revoking `MODULE_ADMIN_ROLE` would make the protocol's module addresses immutable but would require a complete redeployment to fix any contract bug.

The deployer intends to revoke this role after sufficient confidence in contract correctness (e.g., professional audit, extended production runtime without issues).

---

## Fund-Redirecting Functions

Three admin functions can redirect money to arbitrary addresses. **None of them can touch escrowed position funds in PositionModule.**

| Function | Contract | What It Redirects | Current State |
|----------|----------|-------------------|---------------|
| `setProtocolReceiver(address)` | TreasuryModule | Protocol fee revenue (% of all fees) | Receiver: `0xdaC630aE52b868FF0A180458eFb9ac88e7425114` |
| `adminSweep(uint256, address)` | LeaderboardModule | Unclaimed leaderboard prizes | Only after claim window expires |
| `setContributionReceiver(address)` | ContributionModule | Voluntary user contributions | **Dormant** — receiver not set, module not active |

---

## Renouncement Recommendations

### Can be renounced now (via `AccessControl.renounceRole`)

- **`MODULE_ADMIN_ROLE`** — eliminates module swap risk entirely. This is the single biggest trust improvement available. After renouncement, all module addresses become permanent.

### Should NOT be renounced yet

- **`DEFAULT_ADMIN_ROLE`** — needed for:
  - Fee adjustments (`setFeeRates`, `setProtocolCut`)
  - Leaderboard management (`createLeaderboard`, `addLeaderboardSpeculation`)
  - Oracle configuration (`setLinkDenominator`, source hash updates)
  - Granting `SCORE_MANAGER_ROLE` / `SPECULATION_MANAGER_ROLE` when needed
  - Enabling secondary market (`setMarketRole`)

### Worth considering

- Call `setProtocolReceiver` once to the desired permanent address, then renounce `MODULE_ADMIN_ROLE` (which locks TreasuryModule in place, making receiver immutable since it requires a registered module to call `emitCoreEvent`)
- Create a timelock contract to hold `DEFAULT_ADMIN_ROLE` — adds a delay before admin actions take effect, giving users time to exit

---

## Verification Notes

This document was generated by:
1. Reading all 12 contract source files in `ospex-foundry-matched-pairs/src/`
2. Querying on-chain role holders via `scripts/queryRoleHolders.js` against OspexCore at `0x8016b2C5f161e84940E25Bb99479aAca19D982aD` on Polygon mainnet
3. Cross-referencing every admin function claim against its `onlyAdmin` / `onlyRole` modifier in source

Every `onlyAdmin` modifier in every module checks `i_ospexCore.hasRole(DEFAULT_ADMIN_ROLE(), msg.sender)`. There are no separate owner patterns or multi-sig requirements — all admin power flows through the single deployer wallet holding `DEFAULT_ADMIN_ROLE`.
