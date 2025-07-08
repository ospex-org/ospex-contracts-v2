# Approach: Minimal Core with Plug-in Modules

## Overview
This approach uses a minimal core contract that only manages access control, event emission, and registry of modules. All business logic is implemented in plug-in modules (Contest, Speculation, Position, Market, Scoring, Oracle), which are registered with the core. Each module is an independent contract, and the core only routes calls and manages permissions. This allows for maximum modularity and smallest possible contract sizes.

Benefits:
- Each module is as small as possible.
- Easy to add/replace modules (e.g., new scoring types).
- Core contract is extremely simple and secure.
- Byte size per contract is minimized.

## File Structure
```
src/
  core/
    OspexCore.sol
    OspexTypes.sol
  modules/
    ContestModule.sol
    SpeculationModule.sol
    PositionModule.sol
    ContributionModule.sol
    SecondaryMarketModule.sol
    MoneylineScorerModule.sol
    SpreadScorerModule.sol
    TotalScorerModule.sol
    OracleModule.sol
    FeeModule.sol
    LeaderboardModule.sol
  interfaces/
    IModule.sol
    IContestModule.sol
    ISpeculationModule.sol
    IPositionModule.sol
    IContributionModule.sol
    ISecondaryMarketModule.sol
    IScorerModule.sol
    IOracleModule.sol
    IFeeModule.sol
```

## Component Breakdown

### src/core/OspexCore.sol

#### Purpose
Central registry and access control for all modules.

#### Variables
- moduleRegistry: moduleType → address
- admin: protocol admin

#### Mappings
- moduleRegistry: bytes32 → address

#### Functions
- registerModule
- getModule
- setAdmin
- emitEvent (for off-chain indexing)

#### Interfaces
None

### src/core/OspexTypes.sol

#### Purpose
Holds all shared structs and enums.

#### Variables
None

#### Mappings
None

#### Functions
None

#### Interfaces
None

### src/modules/ContestModule.sol

#### Purpose
Handles contest logic.

#### Variables
- contests: contestId → Contest

#### Mappings
- contests

#### Functions
- createContest
- getContest
- setContestStatus
- setScores

#### Interfaces
- IContestModule, IModule

### src/modules/SpeculationModule.sol

#### Purpose
Handles speculation logic.

#### Variables
- speculations: speculationId → Speculation

#### Mappings
- speculations

#### Functions
- createSpeculation
- settleSpeculation
- forfeitSpeculation
- getSpeculation
- setMinSpeculationAmount, setMaxSpeculationAmount, setVoidCooldown

#### Interfaces
- ISpeculationModule, IModule

### src/modules/PositionModule.sol

#### Purpose
Handles position logic using the simple amount model.

#### Variables
- positions: speculationId → user → oddsPairId → positionType → Position

#### Mappings
- positions

#### Functions
- createUnmatchedPair
- adjustUnmatchedPair
- completeUnmatchedPair
- claimPosition
- transferPosition
- getPosition

#### Interfaces
- IPositionModule, IModule

### src/modules/SecondaryMarketModule.sol

#### Purpose
Handles secondary market logic.

#### Variables
- saleListings: speculationId → seller → oddsPairId → positionType → SaleListing
- pendingSaleProceeds: seller → amount

#### Mappings
- saleListings
- pendingSaleProceeds

#### Functions
- listPositionForSale
- buyPosition
- claimSaleProceeds
- cancelListing
- updateListing

#### Interfaces
- ISecondaryMarketModule, IModule

### src/modules/MoneylineScorerModule.sol

#### Purpose
Implements moneyline scoring logic.

#### Variables
- contestModule: address

#### Mappings
None

#### Functions
- determineWinSide

#### Interfaces
- IScorerModule, IModule

### src/modules/SpreadScorerModule.sol

#### Purpose
Implements spread scoring logic.

#### Variables
- contestModule: address

#### Mappings
None

#### Functions
- determineWinSide

#### Interfaces
- IScorerModule, IModule

### src/modules/TotalScorerModule.sol

#### Purpose
Implements total scoring logic.

#### Variables
- contestModule: address

#### Mappings
None

#### Functions
- determineWinSide

#### Interfaces
- IScorerModule, IModule

### src/modules/OracleModule.sol

#### Purpose
Handles Chainlink/oracle logic.

#### Variables
- linkToken, router, donId, etc.

#### Mappings
- requestMapping: requestId → contestId

#### Functions
- sendRequest
- fulfillRequest
- withdrawLink
- setRouter, setDonId, setSourceHash

#### Interfaces
- IOracleModule, IModule

### src/modules/ContributionModule.sol

#### Purpose
Centralizes all contribution logic for the protocol. Handles contribution token and receiver management, contribution transfers, and emits contribution events. This module is called by other modules (e.g., PositionModule, SecondaryMarketModule) whenever a contribution is required, ensuring a single source of truth and reducing code duplication.

#### Variables
- s_contributionToken: The ERC20 token used for contributions
- s_contributionReceiver: The address that receives contributions

#### Mappings
None

#### Functions
- handleContribution: Handles the transfer and event emission for a contribution
- setContributionToken: Sets the contribution token (admin only)
- setContributionReceiver: Sets the contribution receiver (admin only)
- getContributionToken: Returns the current contribution token address
- getContributionReceiver: Returns the current contribution receiver address

#### Events
- ContributionMade: Emitted when a contribution is made

#### Interfaces
- IContributionModule, IModule

#### Notes
- All modules that require contribution logic should call this module directly.
- The contribution token is expected to be the same across all modules, but this module can be extended to support multiple tokens if needed in the future.
- This module helps keep other modules (like PositionModule) under the EVM bytecode size limit by centralizing contribution logic. 

### src/modules/FeeModule.sol

#### Purpose
Centralizes all fee logic for the protocol. Handles fee collection, routing, and allocation for contest creation, speculation creation, and leaderboard entry. Supports configurable fee rates and protocol cut, user-directed allocation to prize pools, and transparent event emission. Ensures all fee logic is modular, auditable, and upgradable.

#### Variables
- s_feeRates: FeeType → uint256 (fee amount or rate per type)
- s_protocolCutBps: uint256 (basis points, e.g., 500 = 5%)
- s_protocolReceiver: address (where protocol revenue is sent)
- s_leaderboardPrizePools: leaderboardId → uint256 (prize pool balances)

#### Mappings
- s_feeRates
- s_leaderboardPrizePools

#### Functions
- handleFee(address payer, uint256 amount, FeeType feeType, uint256 leaderboardId): Accepts and routes fees, splits between protocol and prize pool for the specified leaderboard.
- setFeeRates(FeeType feeType, uint256 rate): Admin sets fee rates for each type.
- setProtocolCut(uint256 cutBps): Admin sets protocol cut in basis points.
- setProtocolReceiver(address receiver): Admin sets protocol revenue address.
- claimPrizePool(uint256 leaderboardId, address to): Allows LeaderboardModule to transfer prize pool funds to winners.
- getFeeRate(FeeType feeType): Returns current fee rate for a type.
- getPrizePool(uint256 leaderboardId): Returns current prize pool balance.

#### Events
- FeeHandled(address indexed payer, FeeType feeType, uint256 amount, uint256 protocolCut, uint256[] leaderboardIds, uint256[] allocations)
- ProtocolCutTransferred(address indexed receiver, uint256 amount)
- PrizePoolFunded(uint256 indexed leaderboardId, uint256 amount)

#### Interfaces
- IFeeModule, IModule

#### Notes
- All modules that require fee logic (ContestModule, SpeculationModule, LeaderboardModule) should call this module directly.
- All fee rates and protocol cut are configurable and can be set to zero.
- User-directed allocation to a single leaderboard per transaction is supported.
- Prize pool balances are tracked per leaderboard and can be claimed by the LeaderboardModule.
- Transparent event emission for all fee actions for off-chain analytics and trust.
- Fee logic is centralized for auditability and upgradability, following DeFi best practices.

### src/modules/LeaderboardModule.sol

#### Purpose
Handles all logic for Ospex leaderboards, including creation, user registration, position tracking, ROI calculation, winner selection, and prize claiming. Designed to be highly modular, secure, and resistant to gaming/exploits.

#### Key Features
- Multiple concurrent leaderboards (e.g., monthly, yearly, event-based), each with its own config.
- Explicit user opt-in: Users must register and declare a bankroll for each leaderboard.
- Strict position tracking: Leaderboard-eligible positions are tracked separately from protocol positions to prevent gaming (e.g., self-matching, unrealistic odds).
- Configurable bet size and bankroll limits: Each leaderboard can set min/max bankroll, min/max bet as % of bankroll, min number of bets, etc.
- **Configurable odds enforcement**: Each leaderboard can set a required odds proximity percentage (e.g., within 25% of opening odds). If set to zero, no odds limiting is enforced.
- Prize pool management: Prize pools are funded via the FeeModule and can optionally use a yield strategy.
- On-chain ROI calculation and winner selection: Deterministic, transparent, and scalable (with fallback for large leaderboards).
- Anti-exploit odds enforcement: Only positions within a certain % of API-provided odds are eligible; odds are stored at speculation creation for auditability.
- Safety period and claim window: Configurable time windows for prize claims and dispute resolution (can be set to zero for immediate claim, and fields can be present in the struct for future extensibility).

#### State Variables
- `mapping(uint256 => Leaderboard)` s_leaderboards: All leaderboard configs and state.
- `mapping(uint256 => address[])` s_leaderboardParticipants: Registered users per leaderboard.
- `mapping(uint256 => mapping(address => uint64))` s_userBankrolls: Declared bankrolls.
- `mapping(uint256 => mapping(address => mapping(uint256 => LeaderboardPosition)))` s_leaderboardPositions: Leaderboard-eligible positions.
- `mapping(uint256 => mapping(address => uint256[]))` s_userSpeculationIds: Speculation IDs per user per leaderboard.
- `mapping(uint256 => SpeculationOdds)` s_speculationOdds: API odds at speculation creation, for anti-exploit checks.

#### Key Functions
- **createLeaderboard**: Admin-only. Creates a new leaderboard with all config params (bankroll/bet limits, time window, min bets, odds enforcement %, yield strategy, safety period, claim window, etc.).
- **registerUser**: User registers for a leaderboard, declaring their bankroll (enforced by min/max).
- **addPositionToLeaderboards**: Called by PositionModule when a user wants a position to count for a leaderboard. Checks eligibility (time, bankroll, bet size, odds), stores position and odds snapshot.
- **scoreLeaderboard**: After leaderboard ends, calculates ROI for all participants and determines winner. If too many users for a single tx, fallback mechanism allows users to submit their own ROI claims.
- **claimLeaderboardPrize**: Winner claims prize after safety period. Prize pool is managed via FeeModule and/or YieldModule.
- **_calculateUserROI**: Internal. Calculates user's ROI based on leaderboard-eligible positions, using declared bankroll as denominator.
- **_calculateWinnings, _calculateMaxPayout, _oddsToMultiplier**: Internal helpers for payout/ROI math, using stored odds and leaderboard config.
- **_isInSafetyPeriod, _managePrizePool**: Internal helpers for yield/safety period logic.

#### Interactions with Other Modules
- **FeeModule**: All prize pool funding is routed through FeeModule. LeaderboardModule never handles raw fee logic.
- **PositionModule**: Notifies LeaderboardModule when a position is to be tracked for a leaderboard. LeaderboardModule enforces stricter rules than protocol positions.
- **YieldModule (optional)**: If a leaderboard uses a yield strategy, prize pool funds are managed via YieldModule.
- **Core**: For access control, event emission, and registry.

#### Anti-Exploit/Strictness Rationale
- Separate position tracking: Prevents users from gaming the leaderboard by transferring, splitting, or selling positions after creation.
- Odds enforcement: Only positions within X% of API odds at speculation creation are eligible. Prevents self-matching at unrealistic odds. This percentage is configurable per leaderboard and can be set to zero for no restriction.
- One position per direction per contest per leaderboard per user: No multi-betting or hedging to game ROI.
- No transfers/sales of leaderboard positions: Once a position is leaderboard-eligible, it's locked for the duration.
- All eligibility checks are on-chain and deterministic.

#### Edge Cases & Best Practices
- Gas limits: For large leaderboards, scoring may require a fallback mechanism (users submit their own ROI claims, contract tracks highest, challenge window, etc.).
- Unclaimed prizes: After claim window, admin can sweep unclaimed prizes to protocol.
- Yield strategy: If set, prize pool is deposited to yield during competition, then withdrawn for payout.
- Extensibility: Future support for multiple winners, more complex payout splits, sponsor seeding, etc.
- **Admin cannot pause/disable a leaderboard after creation** to avoid risk of admin compromise disabling competitions.
- **Dispute/challenge window**: Struct includes claim window and safety period fields for future extensibility, but these can be set to zero for immediate claims. No challenge/dispute logic is implemented by default.
- **Only time-based leaderboards are supported in this iteration**; event-based/custom leaderboards may be considered in the future.
- Be mindful of struct size to avoid EVM memory slot issues; only add fields as needed.

#### Example Leaderboard Struct
```solidity
struct Leaderboard {
    uint256 prizePool;            // Total prize pool
    uint256 entryFee;             // Entry fee (if any)
    address yieldStrategy;        // Optional yield strategy contract
    uint32 startTime;             // Leaderboard start timestamp
    uint32 endTime;               // Leaderboard end timestamp
    uint32 safetyPeriodDuration;  // Safety period after end (seconds)
    uint32 roiSubmissionWindow;   // ROI submission window after end (seconds)  
    uint32 claimWindow;           // Claim window after end (seconds)
}
```

#### Example LeaderboardPosition Struct
```solidity
struct LeaderboardPosition {
    uint256 contestId;            // Contest ID
    uint256 speculationId;        // Speculation ID
    uint256 amount;               // Amount eligible for leaderboard
    address user;                 // User address
    uint64 odds;                  // Odds at entry (for this position)
    PositionType positionType;    // Position type (Upper/Lower)
}
```

#### Summary Table (add to your existing table)
| Module              | Purpose                                      | Key Functions                | Notes/Strictness                         |
|---------------------|----------------------------------------------|------------------------------|------------------------------------------|
| LeaderboardModule   | Manages all leaderboard logic and state      | createLeaderboard, registerUser, addPositionToLeaderboards, scoreLeaderboard, claimLeaderboardPrize | Delegates all rule checks to RulesModule |

## Data Flow
1. **Contest Creation**:
   - User calls OspexCore.getModule("Contest") and then ContestModule.createContest.
2. **Speculation Creation**:
   - User calls OspexCore.getModule("Speculation") and then SpeculationModule.createSpeculation.
3. **Bet Placement**:
   - User calls OspexCore.getModule("Position") and then PositionModule.createUnmatchedPair.
4. **Matching**:
   - User calls OspexCore.getModule("Position") and then PositionModule.completeUnmatchedPair (batch actions can be handled off-chain or by looping in the PositionModule).
5. **Claiming**:
   - After contest is scored (via OracleModule and ScorerModule), user calls PositionModule.claimPosition.
6. **Secondary Market**:
   - Users list and buy positions via SecondaryMarketModule.
7. **Scoring**:
   - SpeculationModule calls the appropriate ScorerModule to determine the winner.

## Data Flow (Updated)

1. **Leaderboard Creation**: Admin calls LeaderboardModule.createLeaderboard.
2. **User Registration**: User calls LeaderboardModule.registerUser, declaring bankroll.
3. **Bet Placement**: User places a bet via PositionModule, specifying if it should count for a leaderboard. PositionModule calls LeaderboardModule.addPositionToLeaderboards.
4. **Fee Handling**: FeeModule handles all fee collection and prize pool funding, allocating to the correct leaderboard.
5. **Leaderboard Scoring**: After leaderboard ends, admin (or users, if fallback needed) calls LeaderboardModule.scoreLeaderboard to determine winner.
6. **Prize Claiming**: Winner claims prize via LeaderboardModule.claimLeaderboardPrize. Prize pool is paid out, possibly after a safety period.

---

## Minimal Core with Plug-in Modules: Deep Dive & Practical Guidance

### What is the Minimal Core with Plug-in Modules Pattern?
This pattern is a modular smart contract architecture where:
- **A single, minimal Core contract** manages access control, event emission, and a registry of module addresses.
- **All business logic is implemented in separate, focused Module contracts** (e.g., ContestModule, PositionModule, MarketModule, etc.).
- The Core contract does not contain business logic; it only routes calls and manages permissions.
- Each Module manages its own storage (mappings, variables) and exposes an interface for the Core and other modules to interact with.

#### Key Benefits
- **Byte size per contract is minimized** (each module is small and focused).
- **Maximum modularity**: easy to add, remove, or upgrade modules (by deploying a new module and updating the registry in the Core).
- **Separation of concerns**: each contract has a single responsibility.
- **Security**: the Core can enforce access control and permissions centrally.
- **Easier auditing**: smaller contracts are easier to review.

#### Project Variable Naming Conventions
- **Storage variables (including public):** Use the `s_` prefix (e.g., `s_minSpeculationAmount`).
- **Immutable variables:** Use the `i_` prefix (e.g., `i_core`).
- **Constants:** Use ALL_CAPS_WITH_UNDERSCORES (e.g., `MIN_VOID_COOLDOWN`).
- **Structs, enums, events:** Use CapWords (e.g., `SpeculationStatus`, `ContestCreated`).
- **Functions and modifiers:** Use mixedCase (e.g., `createSpeculation`, `onlyOwner`).

This convention is based on the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html#naming-conventions) and best practices from leading Solidity projects. All new code and refactors should follow this pattern.

---

### Token Decimals Normalization

All speculation amounts (min, max, user input) are normalized to the token's decimals, which is set via the immutable `i_tokenDecimals` in `SpeculationModule`. This enables compatibility with both 6-decimal (e.g., USDC) and 18-decimal (e.g., ETH, DAI) tokens. All min/max logic and user-facing amounts are adjusted by `10 ** i_tokenDecimals` to ensure correct behavior regardless of the token used.

When deploying a new SpeculationModule, the token decimals must be provided to the constructor. This pattern ensures future-proofing and cross-token compatibility for the protocol.

---

### Real-World Usage & Prevalence
- **This pattern is inspired by plugin/module architectures in DeFi and DAO protocols.**
- **Examples:**
  - **Gnosis Safe**: Uses a minimal core (the Safe) and plug-in modules for additional features (e.g., spending limits, guards, custom logic).
  - **Balancer V2**: Has a Vault (core) and plug-in Pool contracts (modules) for different pool types.
  - **Moloch/DAOhaus DAOs**: Use a core DAO contract and plug-in modules for voting, ragequit, extensions, etc.
  - **OpenZeppelin's Diamond Standard (EIP-2535)**: A more advanced version, but with upgradeability (which you don't want).
- **How common?**
  - Not as common as monolithic or simple modularization, but increasingly popular for complex protocols that want to maximize flexibility and minimize contract size.
  - Especially useful for protocols expecting to add new features or market types over time.

---

### Moving Functions Around: Is It Easy?
- **Yes!**
  - Each module is independent. If a module gets too large, you can split it into two (e.g., PositionModule → PositionModule + PositionSplitModule) and update the Core's registry.
  - The Core only needs to know the address of each module and the interface it exposes.
  - As long as you maintain interface compatibility, you can move, split, or replace modules with minimal disruption.
- **Best Practice:**
  - Keep interfaces stable and versioned.
  - Use the Core as the single source of truth for module addresses.

---

### Where is Storage Managed? (Mappings, Variables)
- **Each module manages its own storage.**
  - For example, `PositionModule` would have its own mappings for positions, etc.
  - `SpeculationModule` would have its own mappings for speculations.
  - This keeps each contract's storage focused and minimizes byte size.
- **Mental Model:**
  - Think of each module as a "microservice" with its own database (storage).
  - As long as you expose getter/setter functions, other modules (or the Core) can read/write as needed.
- **Does it matter where a mapping is stored?**
  - **No, as long as the contract that needs to access it knows where to find it (i.e., has the module address and interface).**
  - For example, if `PositionModule` needs to check a speculation's status, it calls `SpeculationModule.getSpeculationStatus(speculationId)`.
  - If you ever want to move a mapping to a new module, you can migrate the data and update the Core's registry.

---

### How Does Access Control Work?
- **Centralized in the Core:**
  - The Core contract manages roles (e.g., admin, market manager, scorer, etc.).
  - When a user calls a module, the module can check with the Core to see if the caller has the required role.
  - Alternatively, the Core can act as a gatekeeper, only forwarding calls to modules if the caller is authorized.
- **Patterns:**
  - **Direct Check:** Each module imports the Core's interface and checks `Core.hasRole(role, msg.sender)`.
  - **Forwarding:** The Core exposes functions like `callModule(bytes32 moduleType, bytes calldata data)` and only forwards if the caller is authorized.
- **Flexibility:**
  - You can add new roles or permissions in the Core without changing modules.
  - Modules can have their own internal access control for module-specific logic if needed.

---

### How to Think About Mappings & Storage in This Pattern
- **Mappings are just state variables scoped to a contract.**
- **The only thing that matters is that the contract which needs to read/write them has access to the contract address and interface.**
- **If you need to move a mapping, you can migrate the data and update the Core's registry.**
- **You can always add getter/setter functions to expose or update mappings as needed.**
- **This is similar to how microservices in web2 have their own databases, but expose APIs for other services to interact with their data.**

---

### Example: Your Position Mapping
Suppose you have this mapping in `PositionManager`:
```solidity
mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => Position)))) public s_positions;
```
- In the plug-in module pattern, this mapping would live in `PositionModule.sol`.
- If another module (e.g., SecondaryMarketModule) needs to read or update a position, it calls `PositionModule.getPosition(...)` or `PositionModule.transferPosition(...)`.
- If you ever want to move this mapping to a new module, you:
  1. Deploy the new module with the mapping.
  2. Migrate the data (if needed).
  3. Update the Core's registry to point to the new module.

---

### Summary Table
| Aspect                | Minimal Core + Plug-in Modules Pattern |
|-----------------------|----------------------------------------|
| Storage Location      | Each module manages its own storage    |
| Access Control        | Centralized in Core, checked by modules|
| Modularity            | Very high; easy to add/split/replace   |
| Byte Size per Contract| Minimal                                |
| Data Migration        | Possible by deploying new modules       |
| Real-World Usage      | Gnosis Safe, Balancer V2, DAOs         |
| Mapping Location      | Wherever is most logical (per module)  |
| Function Movement     | Easy, as long as interfaces are stable  |

---

### Final Thoughts
- **This pattern is ideal for complex, evolving protocols that want maximum flexibility and minimal contract size.**
- **It is not overkill for a sophisticated P2P orderbook; in fact, it is a best practice for such systems.**
- **You can always start with a few modules and split further as needed.**
- **The only real tradeoff is a bit more complexity in managing module addresses and interfaces, but this is outweighed by the benefits for large systems.**

## Summary Table

| Approach | Key Pattern | Storage | Modularity | Extensibility | Byte Size per Contract | Security | Gas Optimization |
|----------|-------------|---------|------------|---------------|-----------------------|----------|------------------|
| 1 | Domain-driven modularization | Per-contract | High | High | Low | High | Good |
| 2 | Service contracts + shared storage | Centralized | High | High | Very low | High | Good |
| 3 | Minimal core + plug-in modules | Per-module | Very high | Very high | Minimal | Very high | Good |

## Recommendation

- **Approach 1** is the most familiar and easiest to audit, and is likely the best fit for your requirements unless you want to experiment with more advanced patterns.
- **Approach 2** is best if you want to maximize code deduplication and are comfortable with a single storage contract.
- **Approach 3** is the most modular and future-proof, but may be overkill unless you plan to add many new modules or scoring types.

---

# User Architectural Clarifications & Preferences (for Future Reference)

**This section summarizes key decisions and preferences for the Minimal Core + Plug-in Modules pattern, based on user feedback. Reference this if context is lost in a new chat.**

## Interfaces
- Interfaces for each module (e.g., `IContestModule.sol`) should be created in the `/interfaces` folder.
- If an interface does not exist yet, it should be drafted alongside the module.
- A base `IModule.sol` interface should also be created for all modules to implement.

## Chainlink/Oracle Logic
- All Chainlink Functions/oracle logic should be moved to a dedicated Oracle module (e.g., `OracleModule.sol`).
- The user prefers to keep the function execution code for Chainlink Functions as close as possible to the current working implementation (from v2), to avoid breaking working DON interactions. However, how the output is stored and how these functions interact with the rest of the project can be refactored as needed.
- If a new architecture is required for oracle logic, it is acceptable, but minimal changes to the working Chainlink Functions code are preferred unless necessary.

## Access Control
- The access control logic and roles from v2 were solid, but can be moved or refactored as needed to fit the new architecture.
- New roles can be added, and obsolete roles can be removed as appropriate.
- Access control can be centralized in the core or distributed to modules, based on what makes the most sense for the new design.

## Event Emission
- The new pattern should be used for event emission: protocol-wide events should be emitted via the core (e.g., `OspexCore.emitCoreEvent(...)`) for off-chain indexing.
- Modules should not emit their own events directly unless there is a compelling reason.

## Other Modules
- As of this writing, only the core and types modules exist. ContestModule is the first business logic module being built.
- Interfaces for other modules should be created as needed, following the same pattern.

## Folder Structure
- Modules should be placed in the `/modules` folder.
- Interfaces should be placed in the `/interfaces` folder.
- Documentation and architectural clarifications should be added to `/ai/chat` as needed.

---

## Custom Errors
- Use custom errors (not revert strings) for all error handling, as per Solidity best practices.
- Define errors in the contract where they are used, unless they are truly protocol-wide and shared by multiple contracts.

---

## Event Emission Pattern: Hybrid Approach

In the Minimal Core + Plug-in Modules architecture, Ospex uses a hybrid event emission pattern:
- **Module-local events**: Each module emits its own detailed events for actions it handles (e.g., `PositionCreated`, `SpeculationSettled`). These are useful for debugging, analytics, and module-specific off-chain consumers.
- **Core events**: For protocol-wide actions (e.g., position created, contest settled), modules also call `OspexCore.emitCoreEvent` to emit a canonical event. This provides a single, protocol-wide event stream for off-chain indexers and analytics.

**Best Practices:**
- Always emit both event types for major user-facing actions.
- Use module-local events for detailed tracking and debugging.
- Use core events for canonical, protocol-wide analytics and off-chain indexing.
- Document which events are core vs. module-local in your code and docs.

**Rationale:**
- This pattern is used by leading protocols (e.g., Gnosis Safe, Balancer V2) and provides the best balance of granularity, indexability, and maintainability.
- Off-chain indexers can choose to listen to just the core, or to all modules for more detail.
- This approach is already used in Ospex's `ContestModule` and `SpeculationModule`.

**If you ever want to move to core-only events, you can, but you will lose some granularity and debugging ease. The hybrid pattern is recommended for most modular protocols.**

---

## [2024-06] Position Unmatched Expiry Timestamp (Proposed Change)

### Rationale
- Users may want unmatched positions to expire at a custom time (e.g., after game start, or after a set period), rather than only at contest end or by manual action.
- This replaces the old `autoCancelAtStart` boolean with a more flexible, user-driven mechanism.
- If set to 0, the unmatched amount remains open until filled, contest ends, or user acts.

### Struct Change
- Add a new field to the `Position` struct:
  ```solidity
  /// @notice User's position in a speculation
  struct Position {
      uint256 matchedAmount;
      uint256 unmatchedAmount;
      uint128 poolId;
      uint32 unmatchedExpiry; // Unix time when unmatched amount expires (0 = no expiry)
      PositionType positionType;
      bool claimed;
  }
  ```
- **Type:** `uint32` (good until 2106, saves storage vs. `uint256`).

### Function Impacts
- `createUnmatchedPair`: Accepts expiry value, validates (must be 0 or a future timestamp), sets it.
- `adjustUnmatchedPair`: Allows editing the expiry (with similar validation).
- `completeUnmatchedPair`: Checks that the expiry (if set) is not in the past before matching.
- `claimPosition`, `transferPosition`: No change needed unless restricting based on expiry (not typical).
- **Other functions:** Any function that interacts with unmatched positions may need to check expiry.

### Best Practices
- If `unmatchedExpiry == 0`, unmatched amount remains open until filled, contest ends, or user acts.
- If `unmatchedExpiry > 0` and block.timestamp >= unmatchedExpiry, unmatched amount is no longer available for matching (can be auto-cancelled or left for user to reclaim/adjust).
- UI should allow users to set (or not set) this value.
- Off-chain indexers may want to track expiry for unmatched positions.
- New test cases for expiry logic and edge cases.

### Migration
- For existing positions, set `unmatchedExpiry` to 0 by default.

### Module/Component Breakdown Updates
- **PositionModule**: Handles all logic for setting, editing, and enforcing `unmatchedExpiry`.
- **Structs**: Update all documentation and interfaces to include the new field.
- **Validation**: Ensure all relevant functions validate and respect the expiry logic.

### Example Usage
- User creates an unmatched position with `unmatchedExpiry = block.timestamp + 1 days`.
- If unmatched after 1 day, the unmatched amount is no longer available for matching.
- If user sets `unmatchedExpiry = 0`, unmatched amount remains open indefinitely (subject to contest end or manual action).

### [Design Note: Unmatched Expiry Flexibility]

- **Users can update the `unmatchedExpiry` of their position at any time, even after the previous expiry has passed.**
- This allows users to "re-activate" an unmatched order by setting a new expiry in the future, or to remove expiry entirely by setting it to zero.
- This design is intentional and provides maximum flexibility for users who may want to temporarily pause their unmatched order (e.g., during a meeting or halftime) and later make it available for matching again.
- Only the position owner can update the expiry, so there are no security or economic risks.
- Users can always withdraw their unmatched funds, regardless of expiry status, by reducing their unmatched amount via `adjustUnmatchedPair`.
- This approach matches real-world trading and orderbook behavior, where users can cancel, relist, or update orders as needed.
- If future requirements change, this behavior can be restricted, but the current design prioritizes user control and convenience.

---

### FeeType Enum (NEW)

The `FeeType` enum is used throughout the protocol to distinguish between different types of fees for routing, allocation, and analytics. It is defined in `OspexTypes.sol` and currently includes:
- `ContestCreation`: Fee for creating a contest
- `SpeculationCreation`: Fee for creating a speculation/market
- `LeaderboardEntry`: Fee for entering a leaderboard

This enum is used by the FeeModule and any module that needs to charge or allocate fees. It can be extended in the future if new fee types are added.

---

## Best Practices for Ospex Modules

- All state-changing functions (except getters, internal, and view/pure functions) should emit events where appropriate. This ensures transparency, off-chain analytics, and protocol consistency.
- Use custom errors (e.g., `error MyModule__SomeError();`) instead of require statements with revert strings for error handling. This is more gas-efficient and improves code clarity.

---

## LeaderboardSpeculation, Odds Enforcement, and Oracle Integration (2024-06 Update)

### Overview
To ensure leaderboard fairness and prevent manipulation, the protocol introduces a new `LeaderboardSpeculation` struct (fields TBD) for each speculation. This struct stores the current market odds (for moneyline) and/or the current market number (for spread/total), as well as relevant metadata (e.g., league, market type). The struct is stored on-chain and can be updated by anyone via an oracle call (with a fee).

### Storage and Enforcement
- A mapping from speculationId to `LeaderboardSpeculation` is maintained.
- All leaderboard eligibility checks (odds, spread, total) are enforced against the current value in this struct.
- Enforcement parameters (e.g., max allowed deviation) are configurable per league/market type and stored on-chain.

### Oracle Integration
- The OracleModule supports a new request type for updating leaderboard speculation odds/numbers.
- When a request is made, the context (request type, speculationId, etc.) is stored in a mapping keyed by requestId.
- In `fulfillRequest`, the context is used to route the response to the correct handler (e.g., update leaderboard speculation odds/number).

### Rationale
- This approach maximizes fairness, prevents manipulation (e.g., self-matching at unrealistic odds, outlier spreads/totals), and ensures all rules are on-chain and auditable.
- The exact fields of the `LeaderboardSpeculation` struct will be finalized during implementation, but the pattern is now established for robust, modular, and extensible odds enforcement.

## Structs Reference (Canonical, as of `OspexTypes.sol`)

### Leaderboard
```solidity
struct Leaderboard {
    uint256 prizePool;            // Total prize pool
    uint256 entryFee;             // Entry fee (if any)
    address yieldStrategy;        // Optional yield strategy contract
    uint32 startTime;             // Leaderboard start timestamp
    uint32 endTime;               // Leaderboard end timestamp
    uint32 safetyPeriodDuration;  // Safety period after end (seconds)
    uint32 roiSubmissionWindow;   // ROI submission window after end (seconds)  
    uint32 claimWindow;           // Claim window after end (seconds)
}
```

### LeaderboardRules
```solidity
struct LeaderboardRules {
    uint256 minBankroll;          // Minimum bankroll required to participate
    uint256 maxBankroll;          // Maximum bankroll allowed
    uint16 minBetPercentage;      // Minimum bet as % of bankroll (bps, e.g., 100 = 1%)
    uint16 maxBetPercentage;      // Maximum bet as % of bankroll (bps)
    uint16 minBets;               // Minimum number of bets required
    uint16 oddsEnforcementBps;    // Odds enforcement (bps, e.g., 2500 = 25%, 0 = no limit)
}
```

### LeaderboardPosition
```solidity
struct LeaderboardPosition {
    uint256 contestId;            // Contest ID
    uint256 speculationId;        // Speculation ID
    uint256 amount;               // Amount eligible for leaderboard
    address user;                 // User address
    uint64 odds;                  // Odds at entry (for this position)
    PositionType positionType;    // Position type (Upper/Lower)
}
```

---

## Key Design/Enforcement Updates

- The `prizePool` field on `Leaderboard` is a simple `uint256` and is managed via the FeeModule. There is **no longer a separate PrizePool struct**; all logic for funding, yield, and payout is handled via FeeModule and (optionally) a yield strategy contract.
- **Prize pool funding** comes from speculation creation fees, contest creation fees, and (optionally) entry fees, all routed through the FeeModule.
- **Entry fees** are enforced at registration (`registerUser`). If `entryFee > 0`, the user must pay the fee to join the leaderboard.
- When a user registers for a leaderboard, the contract checks if `entryFee > 0` and, if so, requires payment (handled via FeeModule). Entry fees are added to the leaderboard's prize pool and are not refundable.
- The `minBets` field is enforced at scoring time: only users who have at least `minBets` eligible positions are considered for prizes. This is not enforced at registration or opt-in, but is checked when determining the winner.
- `safetyPeriodDuration` and `claimWindow` are enforced at prize claim time: after the leaderboard ends, there is a delay before the winner can claim, to allow for disputes or challenges. After the safety period, the winner has a limited time to claim the prize. If unclaimed, the admin can sweep the prize to the protocol.
- Each speculation that is eligible for leaderboard tracking must have a corresponding `LeaderboardSpeculation` struct, populated via an admin or oracle-triggered function. This struct is used for all odds/number enforcement and anti-exploit logic.

---

## Additional Notes
- **All struct definitions in this document are now canonical and should match `OspexTypes.sol`.**
- **Prize pool logic is simplified and handled via FeeModule and a simple `uint256` field.**
- **Entry fee, minimum bets, and claim window logic are all enforced in the contract and should be reflected in the UI and off-chain analytics.**
- **LeaderboardSpeculation registration is required for all speculations that may be eligible for leaderboard tracking.**

---

## TODOs for Further Documentation
- Add a section on the exact process for registering/updating `LeaderboardSpeculation` (who, when, how).
- Add a section on the fallback scoring mechanism for large leaderboards (user-submitted ROI claims).
- Add a section on the admin sweep process for unclaimed prizes after the claim window.

## 2024-06 Update: Leaderboard Rules Modularization (Mapping-Based)

- The Leaderboard struct is now minimal, containing only core state fields.
- **All rule parameters (bankroll, bet %, minBets, odds enforcement, etc.) are now stored as individual mappings in the RulesModule, not as a struct.**
- The LeaderboardModule delegates all rule enforcement to the RulesModule for maximum modularity and storage efficiency.

---

## Structs Reference (Canonical, as of `OspexTypes.sol`)

### Leaderboard
```solidity
struct Leaderboard {
    uint256 prizePool;            // Total prize pool
    uint256 entryFee;             // Entry fee (if any)
    address yieldStrategy;        // Optional yield strategy contract
    uint32 startTime;             // Leaderboard start timestamp
    uint32 endTime;               // Leaderboard end timestamp
    uint32 safetyPeriodDuration;  // Safety period after end (seconds)
    uint32 roiSubmissionWindow;   // ROI submission window after end (seconds)  
    uint32 claimWindow;           // Claim window after end (seconds)
}
```

---

## RulesModule: Centralized Leaderboard Rule Management (Mapping-Based)

- All leaderboard rule parameters (min/max bankroll, min/max bet %, minBets, odds enforcement, etc.) are now stored as **individual mappings** in the RulesModule, keyed by leaderboardId.
- Example:
  - `mapping(uint256 => uint256) public s_minBankroll;`
  - `mapping(uint256 => uint256) public s_maxBankroll;`
  - `mapping(uint256 => uint16) public s_minBetPercentage;`
  - `mapping(uint256 => uint16) public s_maxBetPercentage;`
  - `mapping(uint256 => uint16) public s_minBets;`
  - `mapping(uint256 => uint16) public s_oddsEnforcementBps;`
- Only the values needed for a given leaderboard are set; unused rules remain at their default value (usually zero).
- The LeaderboardModule only stores essential state and delegates all rule checks to the RulesModule.
- This separation allows for more efficient storage, easier upgrades, and more flexible rule management.
- When a leaderboard is created, its rules are set in the RulesModule and referenced by leaderboardId.
- All validation (bankroll, bet size, odds, minBets, etc.) is performed by calling RulesModule functions, which read from these mappings.

---

## Key Design/Enforcement Updates

- The `prizePool` field on `Leaderboard` is a simple `uint256` and is managed via the FeeModule. There is **no longer a separate PrizePool struct**; all logic for funding, yield, and payout is handled via FeeModule and (optionally) a yield strategy contract.
- **All rule parameters are now stored as individual mappings in the RulesModule.**
- **Leaderboard struct is minimal; all rule parameters are stored in RulesModule mappings.**
- When a user registers for a leaderboard, the contract checks the relevant rules (minBankroll, maxBankroll, entryFee, etc.) by calling the RulesModule.
- All bet eligibility and enforcement (min/max bet %, odds enforcement, minBets, etc.) is handled by the RulesModule.

---

## Updated FAQ/Design Reference

- **Leaderboard struct:**  See above for the canonical definition.  Note: `prizePool` is a simple `uint256`, not a struct. All rule parameters are now stored as individual mappings in the RulesModule.
- **Rule parameters:**  Now stored as individual mappings in the RulesModule, not as a struct.

---

## Component Breakdown (Updated)

| Module              | Purpose                                      | Key Functions                | Notes/Strictness                         |
|---------------------|----------------------------------------------|------------------------------|------------------------------------------|
| LeaderboardModule   | Manages leaderboard state, registration, prize pool | createLeaderboard, registerUser, addPositionToLeaderboards, scoreLeaderboard, claimLeaderboardPrize | Delegates all rule checks to RulesModule |
| RulesModule         | Stores and enforces all leaderboard rules as mappings | setRule, getRule, isBankrollValid, isBetValid, isOddsValid, etc. | Called by LeaderboardModule for all rule checks |

---

## Storage Packing Note

- The Leaderboard struct is now optimally packed for Solidity storage efficiency. All small types are grouped together at the end of the struct, minimizing storage slot usage.
- Rule parameters are stored sparsely in mappings, so unused rules do not consume storage.
- See the codebase for the exact slot layout.

---

## Minimal Core with Plug-in Modules: Deep Dive & Practical Guidance (Relevant Excerpt)

### RulesModule: Why and How (Mapping-Based)
- The RulesModule centralizes all rule logic and storage for leaderboards using individual mappings for each rule parameter.
- This allows the LeaderboardModule to remain focused on state and user actions, while all eligibility and enforcement logic is handled in one place.
- The Leaderboard struct is now minimal, and all rule parameters are stored in the RulesModule's mappings.
- This pattern is highly modular, efficient, and future-proof.

---

## FAQ/Design Reference Updates

- All rule-related logic is now handled by the RulesModule using individual mappings.
- Leaderboard struct is minimal; all rule parameters are stored in RulesModule mappings.
- When a leaderboard is created, its rules are set in RulesModule and referenced by leaderboardId.
- All validation (bankroll, bet size, odds, minBets, etc.) is performed by calling RulesModule functions.

---

## Summary Table (Updated)

| Aspect                | Minimal Core + Plug-in Modules Pattern (with RulesModule) |
|-----------------------|----------------------------------------------------------|
| Storage Location      | Each module manages its own storage; rules in RulesModule mappings |
| Access Control        | Centralized in Core, checked by modules                  |
| Modularity            | Very high; easy to add/split/replace                     |
| Byte Size per Contract| Minimal                                                  |
| Data Migration        | Possible by deploying new modules                        |
| Real-World Usage      | Gnosis Safe, Balancer V2, DAOs                           |
| Mapping Location      | Wherever is most logical (per module)                    |
| Function Movement     | Easy, as long as interfaces are stable                   |
| Rule Logic            | Centralized in RulesModule (mapping-based)               |

---

# User Architectural Clarifications & Preferences (for Future Reference)

- All rule parameters for leaderboards are now managed by the RulesModule as individual mappings.
- The Leaderboard struct is minimal and only contains core state.
- All eligibility and enforcement logic is delegated to the RulesModule.

## Leaderboard Registration Process (2024-06 Update)

- **Explicit registration only:** Users must explicitly register each position they want to count for a leaderboard, and only after the position has a matched amount.
- **No opt-in/pending tracking:** The contract does not track or process opt-in or pending positions. Only explicitly registered, matched positions are eligible for leaderboard tracking.
- **Batch registration:** Users can register a position for up to 8 leaderboards in a single call. Validation is performed for each leaderboard.
- **UI responsibility:** The UI/front-end is responsible for surfacing eligible positions and facilitating registration. The contract only cares about explicit registration calls.
- **Rationale:** This approach is simpler, clearer, and matches industry standards in DeFi, prediction markets, and gaming protocols. It reduces storage, complexity, and edge cases, and makes user actions and eligibility transparent.

---

## FAQ/Design Reference Updates

- **How do users register positions for leaderboards?**
  - Users must explicitly register each position for the leaderboard(s) they wish to compete in, after the position is matched.
  - There is no automatic or pending opt-in; registration is always explicit and user-initiated.
  - Users can register a position for up to 8 leaderboards in a single call.
  - The contract validates each registration per leaderboard.

- **Why this approach?**
  - Simpler code, less storage, and fewer edge cases.
  - Clearer for users: only explicitly registered positions count.
  - Matches best practices in DeFi, prediction markets, and gaming protocols.
  - Any inconvenience for market makers (who may need to register multiple positions) can be handled in the UI (e.g., batch registration tools).

---

## Process Flow (Updated)

1. **User creates or matches a position.**
2. **User (via UI) selects eligible positions and initiates registration for up to 8 leaderboards.**
3. **Contract validates each registration and records the position for each leaderboard if valid.**
4. **Only explicitly registered positions are tracked for leaderboard ROI and prizes.**

---

## Summary Table (Updated)

| Step                | Old Model (Opt-in)         | New Model (Explicit Registration) |
|---------------------|----------------------------|-----------------------------------|
| Opt-in Tracking     | Yes                        | No                                |
| User Action         | Optional, can be pending   | Explicit, always required         |
| Eligible Positions  | Pending or matched         | Only matched                      |
| Storage/Complexity  | Higher                     | Lower                             |
| Industry Standard   | Rare                       | Yes                               |

---

## Additional Notes (Updated)

- **All registration is explicit and user-initiated.**
- **No opt-in or pending position tracking in the contract.**
- **UI/front-end should help users batch register eligible positions.**

## Changelog (Add entry)
- 2024-06: Registration process simplified. Users must explicitly register matched positions for leaderboards; opt-in/pending tracking removed for clarity and simplicity.

---

## 3. How do users participate? (Updated)

- **Explicit registration required:** Users must explicitly register each position they want to count for a leaderboard, after the position has a matched amount.
- **No opt-in/pending tracking:** There is no longer any concept of "opt-in" or pending positions. Only explicitly registered positions are eligible.
- **Batch registration:** Users can register a position for up to 8 leaderboards in a single call.
- **UI responsibility:** The UI/front-end is responsible for surfacing eligible positions and facilitating registration.

## 7. How is ROI calculated and how is the winner determined? (Updated)

- **Only explicitly registered positions are tracked for leaderboard ROI.**
- **No automatic or pending opt-in:** Users must register each position they want to count.

## Additional Notes (Updated)

- **All registration is explicit and user-initiated.**
- **No opt-in or pending position tracking in the contract.**
- **UI/front-end should help users batch register eligible positions.**