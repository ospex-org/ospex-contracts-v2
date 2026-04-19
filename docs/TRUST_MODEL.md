# Ospex Protocol — Trust Model

> **Applies to**: v2.3 (zero-admin, post-hardening)
> **Pattern**: Bootstrap-then-finalize — no admin key after deployment

---

## TL;DR

| Question | Answer |
|----------|--------|
| Can the deployer pause the contract? | **No** — no pause mechanism exists |
| Can the deployer swap modules? | **No** — module registry is permanently locked after `finalize()` |
| Can the deployer change fees? | **No** — fee rates are set in the TreasuryModule constructor and are immutable |
| Can the deployer withdraw user funds? | **No** — PositionModule has zero admin functions |
| Can the deployer upgrade contracts? | **No** — no proxy pattern, no module swap, no upgrade path |
| What can the deployer do after deployment? | **Nothing** — the deployer address has no on-chain privileges after `finalize()` |
| What's the worst that can happen? | An undiscovered contract bug with no admin recourse (no pause, no upgrade — see [RISKS.md](./RISKS.md#1-no-professional-audit--critical)); oracle submits wrong scores (mitigated by triple-source verification); off-chain infrastructure goes down (positions remain safe on-chain) |

---

## Bootstrap-then-Finalize

OspexCore uses a one-shot deployment pattern:

1. **Constructor**: `i_deployer` is set to `msg.sender`. This is the only address with bootstrap authority.
2. **`bootstrapModules()`**: The deployer registers all 12 modules in a single call. Each module type can only be registered once — the call reverts on duplicates (`OspexCore__DuplicateModuleType`).
3. **`finalize()`**: The deployer calls this to permanently lock the registry. `finalize()` verifies all 12 required module types are registered, then sets `s_finalized = true`. After this point, `bootstrapModules()` reverts with `OspexCore__AlreadyFinalized`.

There is no `registerModule()`, no `replaceModule()`, no role-based access control. The deployer has exactly two functions available (`bootstrapModules` and `finalize`), both of which are gated by `notFinalized` and become permanently uncallable once finalize executes.

**The deployer wallet retains no on-chain power after finalize.** It is a regular address.

---

## What Cannot Change After Finalize

Every value below is set at construction time and is immutable for the life of the deployment:

| Value | Set By | Location |
|-------|--------|----------|
| Module addresses (all 12) | `bootstrapModules()` + `finalize()` | OspexCore |
| Protocol fee receiver | Constructor parameter | TreasuryModule `i_protocolReceiver` |
| Fee rates (contest, speculation, leaderboard creation) | Constructor parameters | TreasuryModule `s_feeRates` |
| Void cooldown | Constructor parameter | SpeculationModule `i_voidCooldown` |
| LINK denominator (payment per oracle call = 1e18 / denominator) | Constructor parameter | OracleModule `i_linkDenominator` |
| Approved script signer | Constructor parameter | OracleModule `i_approvedSigner` |
| USDC token address | Constructor parameter | PositionModule, TreasuryModule, SecondaryMarketModule |
| LINK token address | Constructor parameter | OracleModule |
| Chainlink DON ID | Constructor parameter | OracleModule `i_donId` |
| EIP-712 domain separators | Computed at construction | MatchingModule, OracleModule |

There is no admin function to modify any of these values. A mistake in any parameter requires redeploying the entire protocol.

---

## What Remains Mutable

These are protocol state changes that occur through normal operation, not admin action:

- **Contests**: Created and scored via OracleModule (permissionless, caller pays LINK)
- **Speculations**: Auto-created on first fill, settled permissionlessly after contest scoring
- **Positions**: Created via MatchingModule fills, claimed by users after settlement
- **Leaderboards**: Created permissionlessly (anyone, pays creation fee), rules set by creator before start
- **Sale listings**: Created, updated, and cancelled by position holders via SecondaryMarketModule
- **Prize pools**: Funded via entry fees and permissionless sponsorship, claimed by winners

All of these are user-initiated and follow the contract logic — no admin override exists for any of them.

---

## Remaining Trust Assumptions

The zero-admin model eliminates admin-key risk but does not eliminate all trust dependencies:

### Oracle Correctness

Contest scores are determined by Chainlink Functions executing JavaScript source code against three independent sports data APIs (The Rundown, Sportspage Feeds, JSONOdds). The script requires unanimous agreement across all three sources — if any source disagrees, the oracle request fails and no score is written.

**Trust assumption**: The approved signer (`i_approvedSigner`) has signed the script hashes that are stored per-contest at creation time. The signer vouches that the JS source is correct. Once a contest is created, only JS matching the stored hash can score it — but the signer's initial approval is a trust dependency.

**Mitigation**: Source code is public. Script hashes are verifiable. The approved signer is set immutably at deployment — it cannot be rotated to a compromised key.

### Off-Chain Infrastructure

The scorer service, agent server, and frontend are centralized services operated by the protocol developer. If they go down:
- No new contests are created (requires oracle request)
- No new market data updates are published
- Existing positions remain safe on-chain — users can still claim after settlement
- Anyone can call `scoreContestFromOracle()` directly if they have the JS source and LINK

### Approved Signer Discipline

Script approvals (EIP-712 signed by `i_approvedSigner`) are verified at contest creation time only. Once a contest exists, its script hashes are stored on-chain and the signer is no longer consulted. The risk is at the approval boundary: if the signer approves a malicious script hash, contests created with that hash would execute the malicious code.

**Mitigation**: Approvals can be scoped to specific leagues and given expiry timestamps. The signer address is immutable — compromise of a different key cannot affect the protocol. Planned: IPFS-pinned script preimages for public auditability.

---

## Fund Safety

### PositionModule — Zero Admin Functions

PositionModule holds all escrowed USDC. It has exactly three external functions:

- `recordFill()` — only callable by MatchingModule (verified by `i_ospexCore.getModule(MATCHING_MODULE)`)
- `claimPosition()` — only callable by the position holder, only after settlement
- `transferPosition()` — only callable by SecondaryMarketModule (verified by `i_ospexCore.isSecondaryMarket()`)

There is no admin withdrawal, no sweep, no emergency drain. USDC leaves PositionModule only through user claims (winners collect risk + profit, push/void returns risk) or secondary market transfers (position changes owner, USDC stays in PositionModule).

### No Freeze Mechanism

There is no pause function on any contract. The deployer cannot freeze the protocol or lock users out. This is a deliberate trade-off: the deployer also cannot halt an exploit in progress.

### Fee Flow

Protocol fees (contest creation, speculation creation, leaderboard creation) are flat amounts transferred directly to the immutable `i_protocolReceiver` address at the time of the fee-triggering action. Fees never pass through an intermediary or accumulate in a sweepable pool.

Leaderboard entry fees and sponsorship deposits are held by TreasuryModule and disbursed to winners via LeaderboardModule. There is no admin sweep — unclaimed funds remain in the TreasuryModule contract indefinitely.

---

## Trade-offs

The zero-admin model accepts these trade-offs:

| Benefit | Cost |
|---------|------|
| No admin key risk — deployer cannot rug | No emergency response — deployer cannot hotfix |
| No module swap attack vector | Cannot patch a buggy module without full redeployment |
| Immutable fees — users know the cost | Cannot adjust fees to market conditions |
| Immutable protocol receiver — fees go where promised | Cannot redirect fees to a new multisig or DAO |
| No pause — users cannot be locked out | No pause — an exploit cannot be halted |

The protocol is betting that the hardened, tested contract code is correct and complete. If a critical bug is discovered, the only recourse is deploying a new set of contracts and migrating users.

---

## Comparison to Previous Model

The pre-hardening contracts used OpenZeppelin AccessControl with role-based admin functions:

| Capability | Previous Model | Current Model |
|------------|---------------|---------------|
| Module swap | `registerModule()` with `MODULE_ADMIN_ROLE` | Impossible after `finalize()` |
| Fee changes | `setFeeRates()`, `setProtocolCut()`, `setProtocolReceiver()` | All immutable (constructor) |
| Score override | `scoreContestManually()` with `SCORE_MANAGER_ROLE` | Does not exist |
| Speculation forfeit | `forfeitSpeculation()` with `SPECULATION_MANAGER_ROLE` | Does not exist; auto-void after cooldown |
| Prize sweep | `adminSweep()` on LeaderboardModule | Does not exist |
| Admin transfer | `proposeAdmin()` / `acceptAdmin()` | Does not exist |
| Role grants | `grantRole()` / `revokeRole()` via AccessControl | No AccessControl imported |

The previous model retained admin powers as a pragmatic safety net for an unaudited protocol. The hardening cycle eliminated all admin powers and replaced discretionary fallbacks with permissionless, deterministic mechanisms (auto-void, permissionless scoring, immutable parameters).

---

## Verification

To verify the trust model on-chain:

```solidity
// Confirm finalization
assert(ospexCore.s_finalized() == true);

// Confirm no further module registration is possible
// bootstrapModules() will revert with OspexCore__AlreadyFinalized

// Confirm immutable fee receiver
assert(treasuryModule.i_protocolReceiver() == EXPECTED_RECEIVER);

// Confirm module addresses are permanent
assert(ospexCore.getModule(POSITION_MODULE) == EXPECTED_POSITION_MODULE);
```

There are no admin roles to query, no ownership to check, no timelocks to inspect. The absence of admin infrastructure is itself the trust property.

---

*See also: [DESIGN_DECISIONS.md](./DESIGN_DECISIONS.md) for intentional behaviors, [RISKS.md](./RISKS.md) for remaining risk factors.*
