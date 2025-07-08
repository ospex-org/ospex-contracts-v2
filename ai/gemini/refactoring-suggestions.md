# Ospex Refactoring Suggestions

This document outlines three distinct architectural approaches to refactor the Ospex Solidity contracts, aiming to reduce bytecode size, improve modularity, and enhance maintainability while preserving core functionality.

## Approach 1: Registry & Modules

### Overview
This approach emphasizes maximum modularity. A central `OspexRegistry` contract acts as a directory, holding addresses of various functional modules (Managers) and potentially global settings. Modules are independent contracts responsible for specific domains (contests, speculations, positions, market, oracle interactions, bulk operations). They interact with each other by querying the registry for necessary contract addresses and calling functions via interfaces. This pattern facilitates clear separation of concerns and potentially allows for easier future updates or replacements of individual modules without affecting the entire system (though complex upgrades are avoided as per requirements).

### Benefits
- **High Modularity**: Clear separation of concerns makes the codebase easier to understand, test, and maintain.
- **Reduced Contract Size**: Individual modules are significantly smaller than the original monolithic contracts.
- **Flexibility**: Easier to add or modify specific features by working on isolated modules.
- **Clear Interaction Paths**: Interactions occur through well-defined interfaces retrieved from the registry.

### File Structure
```
src/
├── core/
│   ├── OspexTypes.sol
│   ├── OspexRegistry.sol
│   ├── managers/
│   │   ├── ContestManager.sol
│   │   ├── SpeculationManager.sol
│   │   ├── PositionManager.sol
│   │   ├── BulkManager.sol
│   │   ├── OracleManager.sol
│   ├── interfaces/
│   │   ├── IOspexRegistry.sol
│   │   ├── IContestManager.sol
│   │   ├── ISpeculationManager.sol
│   │   ├── IPositionManager.sol
│   │   ├── IBulkManager.sol
│   │   ├── IOracleManager.sol
│   │   ├── IOspexScorer.sol
├── market/
│   ├── SecondaryMarketManager.sol
│   ├── interfaces/
│   │   ├── ISecondaryMarketManager.sol
├── scoring/
│   ├── OspexMoneyline.sol
│   ├── OspexSpread.sol
│   ├── OspexTotal.sol
└── interfaces/  (Potentially redundant if core/interfaces is used globally)
    ├── IOspexPositionManager.sol # (Example - Reuse existing or place in core/interfaces)
    ├── IOspexScorer.sol # (Example - Reuse existing or place in core/interfaces)
    ├── IOspexSpeculationManager.sol # (Example - Reuse existing or place in core/interfaces)

```

### Component Breakdown

---

## `src/core/OspexTypes.sol`

### Purpose
Defines shared data structures (structs) and enumerations used across the entire protocol. Consolidates type definitions to prevent redundancy.

### Variables
- None (Contains only type definitions)

### Mappings
- None

### Functions
- None

### Interfaces
- None

---

## `src/core/OspexRegistry.sol`

### Purpose
Acts as a central directory and owner of global settings. Stores addresses of all manager contracts and provides functions to retrieve them. Manages access control roles related to registry updates.

### Variables
- `owner`: Address of the contract owner/admin.
- `tokenAddress`: Address of the primary ERC20 token.
- `contributionToken`: Address of the contribution token.
- `contributionReceiver`: Address receiving contributions.
- `minSpeculationAmount`: Minimum bet amount.
- `maxSpeculationAmount`: Maximum bet amount.
- `minOdds`: Minimum allowed odds.
- `maxOdds`: Maximum allowed odds.
- `voidCooldown`: Time after start before a speculation can be voided.
- `minSaleAmount`: Minimum secondary market sale amount.
- `maxSaleAmount`: Maximum secondary market sale amount.
- `bulkOperationSize`: Max positions in a bulk operation.
- `linkAddress`: Address of LINK token (for OracleManager).
- `linkDenominator`: Denominator for LINK payment calculation (for OracleManager).
- `donId`: Chainlink DON ID (for OracleManager).
- `createContestSourceHash`: Chainlink Functions source hash (for OracleManager).

### Mappings
- `moduleAddresses`: mapping(bytes32 => address) - Maps module identifiers (e.g., keccak256("CONTEST_MANAGER")) to contract addresses.
- `scorers`: mapping(address => bool) - Tracks registered scorer contract addresses.

### Functions
- `registerModule`: (Admin) Registers or updates the address for a module.
- `unregisterModule`: (Admin) Removes a module address.
- `getModuleAddress`: Returns the address of a registered module.
- `registerScorer`: (Admin) Registers a scorer contract.
- `unregisterScorer`: (Admin) Unregisters a scorer contract.
- `isScorer`: Checks if an address is a registered scorer.
- `setTokenAddress`: (Admin) Sets the primary token address.
- `setContributionSettings`: (Admin) Sets contribution token and receiver.
- `setSpeculationLimits`: (Admin) Sets min/max speculation amounts.
- `setOddsLimits`: (Admin) Sets min/max odds.
- `setVoidCooldown`: (Admin) Sets the void cooldown period.
- `setSaleAmountLimits`: (Admin) Sets min/max secondary market sale amounts.
- `setBulkOperationSize`: (Admin) Sets the bulk operation size limit.
- `setOracleParams`: (Admin) Sets Chainlink/Oracle related parameters (LINK address, denominator, DON ID, source hash).
- `getTokenAddress`: Returns the primary token address.
- `getContributionToken`: Returns the contribution token address.
- `getContributionReceiver`: Returns the contribution receiver address.
- `getMinSpeculationAmount`: Returns the minimum speculation amount.
- `getMaxSpeculationAmount`: Returns the maximum speculation amount.
- `getMinOdds`: Returns the minimum odds.
- `getMaxOdds`: Returns the maximum odds.
- `getVoidCooldown`: Returns the void cooldown period.
- `getMinSaleAmount`: Returns the minimum sale amount.
- `getMaxSaleAmount`: Returns the maximum sale amount.
- `getBulkOperationSize`: Returns the bulk operation size.
- `getLinkAddress`: Returns the LINK token address.
- `getLinkDenominator`: Returns the LINK payment denominator.
- `getDonId`: Returns the Chainlink DON ID.
- `getCreateContestSourceHash`: Returns the Chainlink Functions source hash.

### Interfaces
- `IOspexRegistry`

---

## `src/core/managers/ContestManager.sol`

### Purpose
Manages contest lifecycle (creation, verification, scoring). Interacts with the `OracleManager` for Chainlink Functions requests and responses. Stores contest-specific data.

### Variables
- `registry`: Address of the `OspexRegistry`.
- `s_contestId`: Counter for contest IDs.
- `s_contestTimerInterval`: Timer interval for scoring attempts.
- `MANUAL_SCORE_WAIT_PERIOD`: Constant wait time for manual scoring.

### Mappings
- `s_contests`: mapping(uint256 => Contest) - Stores contest data.
- `s_contestTimers`: mapping(uint256 => uint256) - Tracks scoring attempt timers.
- `s_contestCreationTime`: mapping(uint256 => uint256) - Tracks contest creation times.
- `s_requestMapping`: mapping(bytes32 => uint256) - Maps Oracle request IDs to contest IDs.
- `s_contestStartTimes`: mapping(uint256 => uint256) - Stores contest start times derived from Oracle response.

### Functions
- `constructor`: Sets the `OspexRegistry` address.
- `createContest`: Initiates contest creation via `OracleManager`.
- `handleOracleResponse`: Callback function called by `OracleManager` to process contest verification or scoring results.
- `scoreContest`: Initiates contest scoring via `OracleManager`.
- `scoreContestManually`: (Score Manager Role) Manually scores a contest after the wait period.
- `setTimer`: (Score Manager Role) Sets the scoring attempt interval.
- `getContest`: Returns contest data.
- `getContestStatus`: Returns the status of a contest.
- `getContestStartTime`: Returns the start time of a contest.
- `_verifyContest`: Internal logic to handle verification response.
- `_processScoring`: Internal logic to handle scoring response.

### Interfaces
- `IContestManager`
- Implements callback interface expected by `IOracleManager`.

---

## `src/core/managers/OracleManager.sol`

### Purpose
Handles all interactions with Chainlink Functions. Sends requests for contest creation and scoring, receives responses, and forwards them to the appropriate manager (e.g., `ContestManager`). Manages LINK payments and subscriptions.

### Variables
- `registry`: Address of the `OspexRegistry`.
- `s_router`: Chainlink Functions Router address (potentially fetched from Registry or set).
- `s_lastRequestId`: Tracks the latest request ID.
- `s_lastResponse`: Stores the latest response data.
- `s_lastError`: Stores the latest error data.

### Mappings
- `s_requestOriginator`: mapping(bytes32 => address) - Maps request ID to the contract that initiated it (e.g., `ContestManager`).

### Functions
- `constructor`: Sets the `OspexRegistry` address, initializes `FunctionsClient`.
- `sendRequest`: (Internal/Called by other managers) Sends a request to Chainlink Functions DON. Requires source, secrets, args, subscriptionId, gasLimit. Records originator.
- `fulfillRequest`: (External, Called by Chainlink Router) Callback for Chainlink Functions responses. Verifies request ID, stores response/error, and calls back the originating manager.
- `withdrawLink`: (Subscription Manager Role) Withdraws LINK from the contract.
- `setRouter`: (Admin/Subscription Manager Role) Updates the Chainlink Router address (if not immutable or fetched from Registry).
- `getLastResponse`: Returns the last response data.
- `getLastError`: Returns the last error data.

### Interfaces
- `IOracleManager`
- Extends `FunctionsClient`, `ConfirmedOwner`.

---

## `src/core/managers/SpeculationManager.sol`

### Purpose
Manages speculation lifecycle (creation, settlement). Stores speculation data and odds pair information. Interacts with registered `Scorer` contracts.

### Variables
- `registry`: Address of the `OspexRegistry`.
- `s_speculationId`: Counter for speculation IDs.
- `ODDS_PRECISION`: Constant for odds calculation.
- `ODDS_INCREMENT`: Constant for odds rounding.

### Mappings
- `s_speculations`: mapping(uint256 => Speculation) - Stores speculation data.
- `s_speculationTimers`: mapping(uint256 => uint256) - Tracks settlement attempt timers (may be simplified if settlement is purely reactive).
- `s_oddsPairs`: mapping(uint128 => OddsPair) - Stores configured odds pairs (upper/lower mapped).
- `s_speculationOddsPairs`: mapping(uint256 => mapping(uint16 => uint128)) - Maps speculation ID and odds index to the configured `oddsPairId`.
- `s_originalRequestedOdds`: mapping(uint128 => uint64) - Stores the originally requested odds before normalization/pairing.
- `s_inverseCalculatedOdds`: mapping(uint128 => uint64) - Stores the calculated inverse odds.

### Functions
- `constructor`: Sets the `OspexRegistry` address.
- `createSpeculation`: Creates a new speculation associated with a contest.
- `settleSpeculation`: Settles a speculation by calling the appropriate `Scorer` contract via the registry. Handles auto-voiding based on `voidCooldown` from the registry.
- `forfeitSpeculation`: (Speculation Manager Role) Manually forfeits a speculation.
- `createOrUseExistingOddsPair`: Creates or retrieves an `oddsPairId` based on requested odds, storing original and inverse odds.
- `storeOddsPair`: (Called by `PositionManager`) Stores a fully configured `OddsPair` struct (with upper/lower assigned).
- `getSpeculation`: Returns speculation data.
- `getSpeculationStatus`: Returns speculation status.
- `getSpeculationWinner`: Returns speculation winner.
- `getSpeculationStartTimestamp`: Returns speculation start time.
- `getOddsPair`: Returns a configured `OddsPair` struct.
- `getOriginalOdds`: Returns the original odds for an `oddsPairId`.
- `getInverseOdds`: Returns the inverse odds for an `oddsPairId`.
- `roundOddsToNearestIncrement`: Pure function for odds rounding.
- `calculateAndRoundInverseOdds`: Internal pure function for inverse odds calculation.

### Interfaces
- `ISpeculationManager`

---

## `src/core/managers/PositionManager.sol`

### Purpose
Manages the lifecycle of individual positions (creation, adjustment, matching, splitting, claiming). Stores position data. Interacts with `SpeculationManager` for odds and status, and with the ERC20 token contract via the registry. Handles position transfers initiated by the `SecondaryMarketManager`.

### Variables
- `registry`: Address of the `OspexRegistry`.

### Mappings
- `s_positions`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => Position)))) - Primary position storage.
- `s_repeat`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => uint8)))) - Tracks the next repeat index for a user/speculation/odds/type combination.
- `s_positionRepeats`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => mapping(uint8 => Position))))) - Stores repeated positions.

### Functions
- `constructor`: Sets the `OspexRegistry` address.
- `createUnmatchedPair`: Creates a new unmatched position, interacts with `SpeculationManager` to get/create `oddsPairId`, stores original/inverse odds there, configures and stores the `OddsPair` struct in `SpeculationManager`, handles token transfer, handles contribution.
- `adjustUnmatchedPair`: Adjusts amount or flags of an unmatched position, handles token transfer/refund, handles contribution.
- `completeUnmatchedPair`: Matches an existing unmatched position, updates both maker and taker positions, handles token transfer.
- `transferPosition`: (Called by authorized Market Managers via Registry) Transfers ownership of a matched amount between users, creating a new position entry for the recipient.
- `splitPosition`: Splits a matched position into two.
- `claimPosition`: Claims payout for a settled position, calculates payout based on `SpeculationManager` status/winner and `OddsPair` from `SpeculationManager`, handles token transfer.
- `createOrUpdatePosition`: (Called by `BulkManager`) Creates or updates position state during bulk operations. Returns the repeat index.
- `getPosition`: Returns position data for a specific index.
- `calculatePayout`: View function to calculate potential payout.
- `_getPosition`: Internal helper to retrieve position storage reference safely.
- `_getNextRepeatIndex`: Internal helper to manage repeat indices.
- `_handleContribution`: Internal helper for contribution logic.
- `_handleAutoCancelWithdrawal`: Internal logic for auto-cancel.

### Interfaces
- `IPositionManager`

---

## `src/core/managers/BulkManager.sol`

### Purpose
Handles bulk operations: matching multiple unmatched pairs (`completeUnmatchedPairBulk`) and combining multiple matched positions (`combinePositions`). Interacts extensively with `PositionManager` to update position states and with the ERC20 token via the registry.

### Variables
- `registry`: Address of the `OspexRegistry`.

### Mappings
- None (State updates happen in `PositionManager`)

### Functions
- `constructor`: Sets the `OspexRegistry` address.
- `completeUnmatchedPairBulk`: Takes an array of `PositionIdentifier`, validates them, calculates total required amount, transfers tokens, calls `PositionManager.createOrUpdatePosition` multiple times (once for the taker, and once for each maker being matched).
- `combinePositions`: Takes specification and indices, validates them, calls `PositionManager.getPosition` to read states, calls `PositionManager.createOrUpdatePosition` to update/zero-out source positions and update the target position.
- `_validateAndExecuteBulkMatch`: Internal helper for `completeUnmatchedPairBulk`.
- `_getMatchableAmount`: Internal helper to calculate matchable amount based on odds fetched from `SpeculationManager`.
- `_getRequiredMatchAmount`: Internal helper based on odds.
- `_hasUniqueIndices`: Pure helper function.
- `_preventInvalidAmount`: Internal helper using limits from Registry.

### Interfaces
- `IBulkManager`

---

## `src/market/SecondaryMarketManager.sol`

### Purpose
Manages the listing, buying, cancelling, and updating of sale listings for *matched* positions on a secondary market. Interacts with `PositionManager` to transfer ownership upon sale and with the ERC20 token via the registry.

### Variables
- `registry`: Address of the `OspěxRegistry`.

### Mappings
- `s_saleListings`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => mapping(uint8 => SaleListing))))) - Stores active sale listings.
- `s_pendingSaleProceeds`: mapping(address => uint256) - Tracks funds held by the contract for sellers.

### Functions
- `constructor`: Sets the `OspexRegistry` address.
- `listPositionForSale`: Creates a sale listing, handles contribution.
- `buyPosition`: Executes a purchase, transfers payment to the contract (held in `s_pendingSaleProceeds`), calls `PositionManager.transferPosition`, updates/deletes listing.
- `claimSaleProceeds`: Allows sellers to withdraw funds held in `s_pendingSaleProceeds`.
- `cancelListing`: Removes an active sale listing.
- `updateListing`: Modifies the price or amount of an active listing.
- `setContributionSettings`: (Admin/Contribution Manager Role) Sets secondary market contribution token/receiver via Registry (or directly if needed).
- `setMinSaleAmount`: (Market Manager Role) Updates min sale amount via Registry.
- `setMaxSaleAmount`: (Market Manager Role) Updates max sale amount via Registry.
- `_getPosition`: Internal helper calling `PositionManager.getPosition` for validation.
- `_handleContribution`: Internal helper for contribution logic specific to secondary market.

### Interfaces
- `ISecondaryMarketManager`

---

## `src/scoring/OspexMoneyline.sol` / `OspexSpread.sol` / `OspexTotal.sol`

### Purpose
Implement specific scoring logic for different bet types (Moneyline, Spread, Total). They fetch contest results from the `ContestManager` (or potentially directly from `OracleManager` if results are stored there, but `ContestManager` seems more logical) and determine the `WinSide`.

### Variables
- `registry`: Address of the `OspexRegistry`.

### Mappings
- None

### Functions
- `constructor`: Sets the `OspexRegistry` address.
- `determineWinSide`: Fetches contest data from `ContestManager` using the registry, validates status, applies specific scoring logic (e.g., `scoreMoneyline`, `scoreSpread`, `scoreTotal`), returns `WinSide`.
- `scoreMoneyline` / `scoreSpread` / `scoreTotal`: Private pure functions containing the actual comparison logic.

### Interfaces
- `IOspexScorer`

---

## `src/core/interfaces/*.sol` & `src/market/interfaces/*.sol`

### Purpose
Define the function signatures for each manager contract, enabling interoperability and interaction via the registry.

### Variables
- None

### Mappings
- None

### Functions
- Mirror the external/public functions defined in the corresponding manager contracts.

### Interfaces
- None

---

### Data Flow Examples

1.  **Create Contest**:
    *   User calls `ContestManager.createContest(...)`.
    *   `ContestManager` prepares args, potentially fetches Oracle params (DON ID, source hash) from `OspexRegistry`.
    *   `ContestManager` calls `OracleManager.sendRequest(...)`, passing callback info.
    *   `OracleManager` validates, gets LINK params from `Registry`, handles LINK payment, calls Chainlink `_sendRequest`, stores request ID mapping to `ContestManager`.
2.  **Oracle Response (Contest Verified)**:
    *   Chainlink DON calls `OracleManager.fulfillRequest(...)`.
    *   `OracleManager` validates request ID, finds originator (`ContestManager`), calls `ContestManager.handleOracleResponse(...)` with response data.
    *   `ContestManager` processes the response, updates `s_contests` status to Verified, stores start time, emits `ContestCreated`.
3.  **Create Unmatched Pair**:
    *   User calls `PositionManager.createUnmatchedPair(...)`.
    *   `PositionManager` validates amount against limits from `OspexRegistry`.
    *   `PositionManager` calls `SpeculationManager.createOrUseExistingOddsPair(...)` to get/create `oddsPairId`.
    *   `SpeculationManager` calculates inverse, stores original/inverse odds, returns `oddsPairId`.
    *   `PositionManager` fetches `tokenAddress` from `Registry`, handles `safeTransferFrom`.
    *   `PositionManager` creates `OddsPair` struct with correct upper/lower based on `positionType` and original/inverse odds fetched from `SpeculationManager`.
    *   `PositionManager` calls `SpeculationManager.storeOddsPair(...)` to save the configured struct.
    *   `PositionManager` updates its own position mappings (`s_positions` or `s_positionRepeats`).
    *   `PositionManager` handles contribution via `Registry` settings.
    *   `PositionManager` emits `UnmatchedPairCreated`.
4.  **Complete Unmatched Pair (Manual)**:
    *   Taker calls `PositionManager.completeUnmatchedPair(...)`.
    *   `PositionManager` validates speculation status via `SpeculationManager` (fetched via `Registry`).
    *   `PositionManager` fetches maker's `Position` and the configured `OddsPair` from `SpeculationManager`.
    *   `PositionManager` calculates matchable amount, validates taker's `amount`.
    *   `PositionManager` fetches `tokenAddress` from `Registry`, handles `safeTransferFrom` for taker's payment.
    *   `PositionManager` updates maker's `Position` state (matched/unmatched amounts).
    *   `PositionManager` creates/updates taker's `Position` state.
    *   `PositionManager` emits `UnmatchedPairCompleted`.
5.  **Complete Unmatched Pair (Bulk)**:
    *   Taker calls `BulkManager.completeUnmatchedPairBulk(...)` with `PositionIdentifier` array.
    *   `BulkManager` validates array length against limit from `Registry`.
    *   `BulkManager._validateAndExecuteBulkMatch`:
        *   Loops through identifiers.
        *   For each, calls `PositionManager.getPosition` to get maker state.
        *   Calls `SpeculationManager.getSpeculationStartTimestamp` via `Registry`.
        *   Calls `SpeculationManager.getOddsPair` via `Registry`.
        *   Calculates matchable amount.
        *   Calls `PositionManager.createOrUpdatePosition` to update maker's matched/unmatched amounts.
    *   `BulkManager` calculates `totalRequiredAmount`.
    *   `BulkManager` fetches `tokenAddress` from `Registry`, handles `safeTransferFrom` for total amount.
    *   `BulkManager` calls `PositionManager.createOrUpdatePosition` to create the taker's position.
    *   `BulkManager` emits events.
6.  **Settle Speculation**:
    *   Anyone calls `SpeculationManager.settleSpeculation(...)`.
    *   `SpeculationManager` checks start timestamp and `voidCooldown` from `Registry`. Handles auto-void if applicable.
    *   `SpeculationManager` identifies the `speculationScorer` address from `s_speculations`.
    *   `SpeculationManager` looks up scorer interface/address via `OspexRegistry.isScorer` and `getModuleAddress` (or dedicated scorer registry).
    *   `SpeculationManager` calls `Scorer.determineWinSide(...)` on the specific scorer contract (`OspexMoneyline`, etc.).
    *   Scorer contract fetches contest results from `ContestManager` (via `Registry`).
    *   Scorer returns `WinSide`.
    *   `SpeculationManager` updates `s_speculations` status and `winSide`. Emits `SpeculationSettled`.
7.  **Claim Position**:
    *   User calls `PositionManager.claimPosition(...)`.
    *   `PositionManager` gets `Position` storage.
    *   `PositionManager` calls `SpeculationManager.getSpeculation` via `Registry` to get status and `winSide`.
    *   `PositionManager` calls `SpeculationManager.getOddsPair` via `Registry`.
    *   `PositionManager.calculatePayout` determines the payout amount based on win side and odds.
    *   `PositionManager` adds any `unmatchedAmount` to payout.
    *   `PositionManager` fetches `tokenAddress` from `Registry`, handles `safeTransfer` of payout.
    *   `PositionManager` updates `Position` state (zeroes amounts, sets claimed flag). Emits `PositionClaimed`.
8.  **List Position for Sale**:
    *   Seller calls `SecondaryMarketManager.listPositionForSale(...)`.
    *   `SecondaryMarketManager` checks speculation status via `SpeculationManager` (via `Registry`).
    *   `SecondaryMarketManager` calls `PositionManager.getPosition` (via `Registry`) to validate matched amount and existence.
    *   `SecondaryMarketManager` validates sale amount against limits from `Registry`.
    *   `SecondaryMarketManager` handles contribution via `Registry` settings.
    *   `SecondaryMarketManager` updates `s_saleListings`. Emits `PositionListed`.
9.  **Buy Listed Position**:
    *   Buyer calls `SecondaryMarketManager.buyPosition(...)`.
    *   `SecondaryMarketManager` checks speculation status via `SpeculationManager`.
    *   `SecondaryMarketManager` validates listing exists in `s_saleListings`.
    *   `SecondaryMarketManager` calls `PositionManager.getPosition` for seller to check auto-cancel/existence.
    *   `SecondaryMarketManager` fetches `tokenAddress` from `Registry`, handles `safeTransferFrom` for payment, updates `s_pendingSaleProceeds`.
    *   `SecondaryMarketManager` calls `PositionManager.transferPosition` (via `Registry`) to move ownership.
    *   `SecondaryMarketManager` updates/deletes listing from `s_saleListings`. Emits `PositionSold`/`PositionPartiallySold`.

---

## Approach 2: Hierarchical Managers with Logic Refinement

### Overview
This approach retains the concept of manager contracts (`ContestManager`, `SpeculationManager`, `PositionManager`) but focuses on breaking down the largest and most complex ones, particularly `OspexPositionManager`, into more granular components based on functionality. It might introduce helper or library contracts (used internally, not as external dependencies) for common logic like odds calculations or validation, if deemed necessary to reduce bytecode size further, but primarily relies on splitting manager responsibilities. Bulk operations and the secondary market remain separate modules. Oracle interactions could be embedded within the `ContestManager` or kept separate as in Approach 1.

### Benefits
- **Reduced Size**: Breaks down the largest contracts (`PositionManager`) significantly.
- **Improved Focus**: Each manager (or sub-manager) has a narrower set of responsibilities.
- **Familiar Structure**: Maintains a similar overall flow to the original design but with better organization.
- **Potential for Logic Reuse**: Common validation or calculation logic can potentially be isolated (e.g., in internal functions or very simple internal helper contracts if absolutely needed for size).

### File Structure
```
src/
├── core/
│   ├── OspexTypes.sol
│   ├── OspexConfig.sol # Optional: Central storage for shared settings if not embedded
│   ├── managers/
│   │   ├── ContestManager.sol # May include Oracle logic or call a separate OracleManager
│   │   ├── SpeculationManager.sol
│   │   ├── UnmatchedPositionManager.sol # Handles creation, adjustment of unmatched
│   │   ├── MatchedPositionManager.sol   # Handles splitting, claiming of matched, transfer target
│   │   ├── PositionMatcher.sol        # Handles completeUnmatchedPair logic, interacts with Unmatched/Matched Managers
│   │   ├── BulkManager.sol
│   │   ├── OracleManager.sol # Optional: If not embedded in ContestManager
│   ├── interfaces/
│   │   ├── IContestManager.sol
│   │   ├── ISpeculationManager.sol
│   │   ├── IUnmatchedPositionManager.sol
│   │   ├── IMatchedPositionManager.sol
│   │   ├── IPositionMatcher.sol
│   │   ├── IBulkManager.sol
│   │   ├── IOracleManager.sol # Optional
│   │   ├── IOspexScorer.sol
├── market/
│   ├── SecondaryMarketManager.sol
│   ├── interfaces/
│   │   ├── ISecondaryMarketManager.sol
├── scoring/
│   ├── OspexMoneyline.sol
│   ├── OspexSpread.sol
│   ├── OspexTotal.sol
├── lib/ # Optional: For internal helpers if needed
│   ├── OddsCalculator.sol
│   ├── ValidationUtils.sol
└── interfaces/ # Global interfaces if needed

```
*Note: Explicitly separating `Unmatched` and `Matched` position management, along with a dedicated `PositionMatcher`, is one way to break down `OspexPositionManager`. Other logical splits are possible.*

### Component Breakdown

---

## `src/core/OspexTypes.sol`

### Purpose
(Same as Approach 1) Defines shared data structures and enums.

### Variables/Mappings/Functions/Interfaces
(Same as Approach 1)

---

## `src/core/OspexConfig.sol` (Optional)

### Purpose
If used, centralizes configuration parameters (limits, addresses, cooldowns) similar to the `OspexRegistry` variables in Approach 1, but without the module address registry function. Managers would read from this contract. Alternatively, config can be embedded within relevant managers.

### Variables/Mappings/Functions/Interfaces
(Similar to variable/getter section of `OspexRegistry` in Approach 1, focused only on parameters)

---

## `src/core/managers/ContestManager.sol`

### Purpose
Manages contest lifecycle. *May directly incorporate Chainlink Functions logic or delegate to a separate `OracleManager`.* Stores contest data.

### Variables
- `oracleManagerAddress`: Address of `OracleManager` (if separate).
- `configAddress`: Address of `OspexConfig` (if used).
- `linkAddress`, `routerAddress`, `donId`, etc.: (If Oracle logic embedded).
- `s_contestId`, `s_contests`, `s_contestTimers`, etc.: (Similar to Approach 1).

### Mappings
- (Similar to Approach 1, potentially including request mappings if Oracle logic is embedded).

### Functions
- `constructor`: Sets dependencies (Config, OracleManager if separate). Initializes Chainlink client if embedded.
- `createContest`: Initiates contest creation (either directly via embedded Oracle logic or by calling `OracleManager`).
- `handleOracleResponse`: Callback (either internal if embedded, or external called by `OracleManager`).
- `scoreContest`: Initiates scoring (directly or via `OracleManager`).
- `scoreContestManually`: Manually scores contest.
- `setTimer`: Sets scoring interval.
- `getContest`, `getContestStatus`, etc.: Getters for contest data.
- `fulfillRequest`: (If Oracle logic embedded) Chainlink callback.
- `sendRequest`: (If Oracle logic embedded) Internal function to send Chainlink request.

### Interfaces
- `IContestManager`
- Implements Oracle callback if `OracleManager` is separate.
- Extends `FunctionsClient` etc. if Oracle logic is embedded.

---

## `src/core/managers/SpeculationManager.sol`

### Purpose
Manages speculation lifecycle (creation, settlement) and odds pair definition. Stores speculation state.

### Variables
- `configAddress`: Address of `OspexConfig` (if used).
- `moneylineScorer`, `spreadScorer`, `totalScorer`: Addresses of specific scorer contracts.
- `s_speculationId`, `ODDS_PRECISION`, `ODDS_INCREMENT`: (Similar to Approach 1).

### Mappings
- `s_speculations`: Stores speculation data.
- `s_oddsPairs`, `s_speculationOddsPairs`, `s_originalRequestedOdds`, `s_inverseCalculatedOdds`: Odds pair related mappings (Similar to Approach 1).

### Functions
- `constructor`: Sets dependencies (Config, Scorer addresses).
- `createSpeculation`: Creates a new speculation.
- `settleSpeculation`: Settles a speculation by calling the appropriate registered scorer. Handles auto-void.
- `forfeitSpeculation`: Manually forfeits.
- `createOrUseExistingOddsPair`: Creates/retrieves `oddsPairId`.
- `storeOddsPair`: Stores configured `OddsPair` (likely called by `UnmatchedPositionManager` or `PositionMatcher`).
- `getSpeculation`, `getSpeculationStatus`, etc.: Getters.
- `getOddsPair`, `getOriginalOdds`, `getInverseOdds`: Odds getters.
- `roundOddsToNearestIncrement`, `calculateAndRoundInverseOdds`: Helpers.
- `registerScorer`, `setVoidCooldown`, `setMinSpeculationAmount`, etc.: Admin functions (if Config contract not used).

### Interfaces
- `ISpeculationManager`

---

## `src/core/managers/UnmatchedPositionManager.sol`

### Purpose
Handles the creation and adjustment of *unmatched* positions. Stores unmatched position data or interacts with a shared Position Storage contract.

### Variables
- `configAddress`: Address of `OspexConfig` (if used).
- `tokenAddress`: ERC20 token address.
- `speculationManagerAddress`: Address of `SpeculationManager`.
- `contributionToken`, `contributionReceiver`: Contribution settings.

### Mappings
- `s_unmatchedPositions`: mapping(...) -> `Position` (Stores only unmatched amount, or full Position struct focused on unmatched state).
- `s_repeat_unmatched`: mapping(...) -> `uint8` (Tracks repeat index specifically for operations here, or uses a shared repeat tracker).

### Functions
- `constructor`: Sets dependencies.
- `createUnmatchedPair`: Validates, calls `SpeculationManager` for odds pair ID, transfers tokens, stores unmatched position data, handles contribution, stores configured `OddsPair` in `SpeculationManager`. Emits `UnmatchedPairCreated`.
- `adjustUnmatchedPair`: Modifies amount/flags of an existing unmatched position, handles token transfer/refund, handles contribution. Emits `UnmatchedPairAdjusted`.
- `getPositionData`: Returns data for an unmatched position.
- `updateUnmatchedAmount`: (Internal or callable by `PositionMatcher`) Updates the unmatched amount when a match occurs.
- `getUnmatchedAmount`: View function.
- `_handleContribution`: Contribution helper.
- `_getNextRepeatIndex`: Repeat index helper.

### Interfaces
- `IUnmatchedPositionManager`

---

## `src/core/managers/MatchedPositionManager.sol`

### Purpose
Handles operations on *matched* positions: splitting, claiming, and being the recipient of transfers. Stores matched position data.

### Variables
- `configAddress`: Address of `OspexConfig` (if used).
- `tokenAddress`: ERC20 token address.
- `speculationManagerAddress`: Address of `SpeculationManager`.

### Mappings
- `s_matchedPositions`: mapping(...) -> `Position` (Stores matched amount and related flags, or full Position struct focused on matched state).
- `s_repeat_matched`: mapping(...) -> `uint8` (Tracks repeat index specifically for operations here, or uses a shared repeat tracker).

### Functions
- `constructor`: Sets dependencies.
- `splitPosition`: Splits a matched position into two entries. Emits `PositionSplit`.
- `claimPosition`: Calculates payout using `SpeculationManager` data, transfers tokens, marks position as claimed. Emits `PositionClaimed`.
- `receiveTransfer`: (Called by `PositionMatcher` or `SecondaryMarketManager`) Creates/updates a matched position entry for the recipient of a transfer/match.
- `updateMatchedAmount`: (Called by `PositionMatcher` or `SecondaryMarketManager`) Reduces the matched amount of the source position during a transfer/split.
- `getPositionData`: Returns data for a matched position.
- `calculatePayout`: View function for payout calculation.
- `_getPosition`: Internal helper.
- `_getNextRepeatIndex`: Repeat index helper.

### Interfaces
- `IMatchedPositionManager`

---

## `src/core/managers/PositionMatcher.sol`

### Purpose
Orchestrates the matching process (`completeUnmatchedPair`). Interacts with `UnmatchedPositionManager` to find and update the maker's unmatched amount, and with `MatchedPositionManager` to create/update the taker's and maker's matched positions.

### Variables
- `configAddress`: Address of `OspexConfig` (if used).
- `tokenAddress`: ERC20 token address.
- `speculationManagerAddress`: Address of `SpeculationManager`.
- `unmatchedManagerAddress`: Address of `UnmatchedPositionManager`.
- `matchedManagerAddress`: Address of `MatchedPositionManager`.

### Mappings
- None (Orchestration role)

### Functions
- `constructor`: Sets dependencies.
- `completeUnmatchedPair`:
    - Validates speculation status via `SpeculationManager`.
    - Fetches maker's position data (unmatched amount) from `UnmatchedPositionManager`.
    - Fetches `OddsPair` from `SpeculationManager`.
    - Calculates matchable amount, validates taker `amount`.
    - Transfers taker's tokens.
    - Calculates `makerAmountConsumed`.
    - Calls `UnmatchedPositionManager.updateUnmatchedAmount` for the maker.
    - Calls `MatchedPositionManager.receiveTransfer` to credit the maker's matched portion.
    - Calls `MatchedPositionManager.receiveTransfer` to create the taker's matched position.
    - Emits `UnmatchedPairCompleted`.

### Interfaces
- `IPositionMatcher`

---

## `src/core/managers/BulkManager.sol`

### Purpose
Handles bulk operations, interacting with the refined position managers (`UnmatchedPositionManager`, `MatchedPositionManager`, `PositionMatcher`).

### Variables
- `configAddress`: Address of `OspexConfig` (if used).
- `tokenAddress`: ERC20 token address.
- `speculationManagerAddress`, `unmatchedManagerAddress`, `matchedManagerAddress`, `positionMatcherAddress`: Dependencies.

### Mappings
- None

### Functions
- `constructor`: Sets dependencies.
- `completeUnmatchedPairBulk`:
    - Validates inputs.
    - Loops through identifiers:
        - Gets maker data from `UnmatchedPositionManager`.
        - Gets odds from `SpeculationManager`.
        - Calculates amounts.
        - Calls `UnmatchedPositionManager.updateUnmatchedAmount` for maker.
        - Calls `MatchedPositionManager.receiveTransfer` for maker's matched part.
    - Transfers total taker tokens.
    - Calls `MatchedPositionManager.receiveTransfer` for taker's position.
    - Emits events.
- `combinePositions`:
    - Validates inputs.
    - Loops through source indices:
        - Gets position data from `MatchedPositionManager`.
        - Validates state (fully matched, not claimed).
        - Calls `MatchedPositionManager.updateMatchedAmount` to zero out source.
    - Calls `MatchedPositionManager.updateMatchedAmount` to add to target (or `receiveTransfer` if creating target entry).
    - Emits events.

### Interfaces
- `IBulkManager`

---

## `src/market/SecondaryMarketManager.sol`

### Purpose
(Largely similar to Approach 1) Manages secondary market listings and sales. Interacts with `MatchedPositionManager` for transfers.

### Variables
- `configAddress`: Address of `OspexConfig` (if used).
- `tokenAddress`: ERC20 token address.
- `matchedManagerAddress`: Address of `MatchedPositionManager`.
- `speculationManagerAddress`: Address of `SpeculationManager`.
- `contributionToken`, `contributionReceiver`: Contribution settings.

### Mappings
- `s_saleListings`, `s_pendingSaleProceeds`: (Same as Approach 1).

### Functions
- `constructor`: Sets dependencies.
- `listPositionForSale`: Validates against `MatchedPositionManager`, stores listing. Handles contribution.
- `buyPosition`: Validates, transfers payment, calls `MatchedPositionManager.updateMatchedAmount` (for seller) and `MatchedPositionManager.receiveTransfer` (for buyer), updates listing.
- `claimSaleProceeds`: Withdraws pending proceeds.
- `cancelListing`: Removes listing.
- `updateListing`: Updates listing details.
- `setContributionSettings`, `setMinSaleAmount`, `setMaxSaleAmount`: Admin functions (if Config not used or for overrides).

### Interfaces
- `ISecondaryMarketManager`

---

## `src/scoring/*.sol`

### Purpose
(Same as Approach 1) Implement specific scoring logic.

### Variables
- `contestManagerAddress`: Address of `ContestManager`.

### Mappings/Functions/Interfaces
(Similar to Approach 1, fetching contest data from `ContestManager`).

---

## `src/lib/*.sol` (Optional)

### Purpose
Contain pure/internal helper functions (e.g., for odds calculations, complex validation logic) if needed to deduplicate code *within* managers and reduce bytecode size. These are *not* meant to be deployed as standalone library contracts linked externally.

### Variables/Mappings/Functions/Interfaces
- Contain only `pure` or `internal` functions.

---

### Data Flow Examples

Flows are similar to Approach 1, but calls related to positions are routed to the more specific managers:

*   **Create Unmatched**: User -> `UnmatchedPositionManager`. `UnmatchedPositionManager` -> `SpeculationManager` (for odds).
*   **Complete Unmatched**: Taker -> `PositionMatcher`. `PositionMatcher` -> `UnmatchedPositionManager` (read/update maker), `MatchedPositionManager` (create taker, update maker matched).
*   **Split Position**: User -> `MatchedPositionManager`.
*   **Claim Position**: User -> `MatchedPositionManager`. `MatchedPositionManager` -> `SpeculationManager` (read status/winner).
*   **List Sale**: Seller -> `SecondaryMarketManager`. `SecondaryMarketManager` -> `MatchedPositionManager` (validate).
*   **Buy Sale**: Buyer -> `SecondaryMarketManager`. `SecondaryMarketManager` -> `MatchedPositionManager` (transfer).
*   **Bulk Match**: Taker -> `BulkManager`. `BulkManager` -> `UnmatchedPositionManager` (update makers), `MatchedPositionManager` (update makers matched, create taker).
*   **Bulk Combine**: User -> `BulkManager`. `BulkManager` -> `MatchedPositionManager` (read/update positions).

---

## Approach 3: Logic/Storage Separation

### Overview
This approach strictly separates contract state (variables, mappings) from the logic that operates on it. Dedicated `Storage` contracts (`ContestStorage`, `SpeculationStorage`, `PositionStorage`, `MarketStorage`) hold the data. Manager contracts (`ContestManager`, `SpeculationManager`, `PositionManager`, etc.) contain only the business logic and interact with their corresponding storage contracts (and potentially others) to read and write state. Access to storage contracts is tightly controlled, typically only allowing the designated manager contract to write data. This can significantly reduce the size of logic contracts, making them easier to audit and potentially replace (again, without proxies).

### Benefits
- **Clear State/Logic Separation**: Enhances clarity and makes logic contracts smaller and potentially stateless (easier reasoning).
- **Reduced Logic Contract Size**: Logic contracts contain minimal state, focusing solely on operations.
- **Targeted Audits**: Audits can focus separately on storage access patterns and business logic correctness.
- **Potential for Upgradability (Logic Only)**: While avoiding proxies, this pattern *could* allow replacing a logic contract while keeping the storage contract, if carefully managed (though this is low priority for the user).

### Drawbacks
- **Increased Inter-Contract Calls**: Every state read/write involves an external call to a storage contract, increasing gas costs.
- **Access Control Complexity**: Requires careful management of permissions between logic and storage contracts.
- **Deployment Complexity**: More contracts to deploy and link together.

### File Structure
```
src/
├── core/
│   ├── OspexTypes.sol
│   ├── storage/
│   │   ├── ContestStorage.sol
│   │   ├── SpeculationStorage.sol
│   │   ├── PositionStorage.sol
│   │   ├── GlobalConfigStorage.sol # For shared settings like limits, addresses
│   ├── logic/
│   │   ├── ContestManager.sol
│   │   ├── SpeculationManager.sol
│   │   ├── PositionManager.sol # Could still be split as in Approach 2 if needed
│   │   ├── BulkManager.sol
│   │   ├── OracleManager.sol # Likely needed, interacts w/ ContestManager/Storage
│   ├── interfaces/
│   │   ├── storage/
│   │   │   ├── IContestStorage.sol
│   │   │   ├── ISpeculationStorage.sol
│   │   │   ├── IPositionStorage.sol
│   │   │   ├── IGlobalConfigStorage.sol
│   │   ├── logic/
│   │   │   ├── IContestManager.sol
│   │   │   ├── ISpeculationManager.sol
│   │   │   ├── IPositionManager.sol
│   │   │   ├── IBulkManager.sol
│   │   │   ├── IOracleManager.sol
│   │   ├── IOspexScorer.sol
├── market/
│   ├── storage/
│   │   ├── MarketStorage.sol
│   ├── logic/
│   │   ├── SecondaryMarketManager.sol
│   ├── interfaces/
│   │   ├── storage/
│   │   │   ├── IMarketStorage.sol
│   │   ├── logic/
│   │   │   ├── ISecondaryMarketManager.sol
├── scoring/
│   ├── OspexMoneyline.sol # Logic contracts
│   ├── OspexSpread.sol
│   ├── OspexTotal.sol
└── interfaces/ # Global interfaces if needed
```

### Component Breakdown

---

## `src/core/OspexTypes.sol`

### Purpose
(Same as Approach 1 & 2) Defines shared data structures and enums.

---

## `src/core/storage/GlobalConfigStorage.sol`

### Purpose
Stores global configuration parameters accessible by various logic contracts. Write access restricted to admin/owner.

### Variables
- `owner`: Address of the admin.
- `tokenAddress`, `contributionToken`, `contributionReceiver`, `minSpeculationAmount`, `maxSpeculationAmount`, `minOdds`, `maxOdds`, `voidCooldown`, `minSaleAmount`, `maxSaleAmount`, `bulkOperationSize`, `linkAddress`, `linkDenominator`, `donId`, `createContestSourceHash`: Global settings.

### Mappings
- `moduleAddresses`: mapping(bytes32 => address) - Maps LOGIC contract identifiers to their addresses (needed for linking logic/storage and inter-logic calls).
- `scorers`: mapping(address => bool) - Registered scorer logic contract addresses.

### Functions
- `constructor`: Sets owner.
- `setX`: Various setter functions for each variable, restricted to owner/admin.
- `getX`: Various getter functions for each variable.
- `registerModule`, `unregisterModule`, `getModuleAddress`: Manage logic contract addresses.
- `registerScorer`, `unregisterScorer`, `isScorer`: Manage scorer addresses.

### Interfaces
- `IGlobalConfigStorage`

---

## `src/core/storage/ContestStorage.sol`

### Purpose
Stores all data related to contests. Write access restricted to `ContestManager`.

### Variables
- `owner`: Address of the admin (for setting manager address).
- `managerAddress`: Address of the authorized `ContestManager` logic contract.
- `s_contestId`: Contest ID counter.

### Mappings
- `s_contests`: mapping(uint256 => Contest)
- `s_contestTimers`: mapping(uint256 => uint256)
- `s_contestCreationTime`: mapping(uint256 => uint256)
- `s_requestMapping`: mapping(bytes32 => uint256)
- `s_contestStartTimes`: mapping(uint256 => uint256)

### Functions
- `constructor`: Sets owner.
- `setManager`: (Owner) Sets the `ContestManager` address.
- `incrementContestId`: (Manager Only) Increments and returns the next contest ID.
- `setContest`: (Manager Only) Stores/updates a `Contest` struct.
- `setTimer`, `setCreationTime`, `setStartTime`: (Manager Only) Setters for specific fields/mappings.
- `mapRequest`: (Manager Only) Maps request ID to contest ID.
- `getContest`, `getTimer`, `getCreationTime`, `getStartTime`, `getRequestContestId`: Getters callable by anyone (or restricted if needed).
- `getContestId`: Returns current contest counter value.

### Interfaces
- `IContestStorage`

---

## `src/core/storage/SpeculationStorage.sol`

### Purpose
Stores all data related to speculations and odds pairs. Write access restricted to `SpeculationManager`.

### Variables
- `owner`: Address of the admin.
- `managerAddress`: Address of the authorized `SpeculationManager` logic contract.
- `s_speculationId`: Speculation ID counter.

### Mappings
- `s_speculations`: mapping(uint256 => Speculation)
- `s_oddsPairs`: mapping(uint128 => OddsPair)
- `s_speculationOddsPairs`: mapping(uint256 => mapping(uint16 => uint128))
- `s_originalRequestedOdds`: mapping(uint128 => uint64)
- `s_inverseCalculatedOdds`: mapping(uint128 => uint64)

### Functions
- `constructor`: Sets owner.
- `setManager`: (Owner) Sets the `SpeculationManager` address.
- `incrementSpeculationId`: (Manager Only) Increments and returns the next speculation ID.
- `setSpeculation`: (Manager Only) Stores/updates a `Speculation` struct.
- `setOddsPair`: (Manager Only) Stores/updates an `OddsPair` struct.
- `setSpeculationOddsPairMapping`: (Manager Only) Updates the mapping.
- `setOriginalOdds`, `setInverseOdds`: (Manager Only) Setters for odds mappings.
- `getSpeculation`, `getOddsPair`, `getSpeculationOddsPairMapping`, `getOriginalOdds`, `getInverseOdds`: Getters.
- `getSpeculationId`: Returns current speculation counter value.

### Interfaces
- `ISpeculationStorage`

---

## `src/core/storage/PositionStorage.sol`

### Purpose
Stores all data related to user positions (matched, unmatched, repeats). Write access restricted to `PositionManager` (and potentially `BulkManager`).

### Variables
- `owner`: Address of the admin.
- `managerAddress`: Address of the authorized `PositionManager` logic contract.
- `bulkManagerAddress`: Address of the authorized `BulkManager` logic contract.

### Mappings
- `s_positions`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => Position))))
- `s_repeat`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => uint8))))
- `s_positionRepeats`: mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => mapping(uint8 => Position)))))

### Functions
- `constructor`: Sets owner.
- `setManager`: (Owner) Sets the `PositionManager` address.
- `setBulkManager`: (Owner) Sets the `BulkManager` address.
- `setPosition`: (Manager or BulkManager Only) Stores/updates a `Position` struct in `s_positions`.
- `setRepeatPosition`: (Manager or BulkManager Only) Stores/updates a `Position` struct in `s_positionRepeats`.
- `setRepeatIndex`: (Manager or BulkManager Only) Updates the `s_repeat` mapping.
- `getPosition`, `getRepeatPosition`, `getRepeatIndex`: Getters.

### Interfaces
- `IPositionStorage`

---

## `src/market/storage/MarketStorage.sol`

### Purpose
Stores data related to the secondary market (listings, pending proceeds). Write access restricted to `SecondaryMarketManager`.

### Variables
- `owner`: Address of the admin.
- `managerAddress`: Address of the authorized `SecondaryMarketManager` logic contract.

### Mappings
- `s_saleListings`: mapping(...) -> `SaleListing`
- `s_pendingSaleProceeds`: mapping(address => uint256)

### Functions
- `constructor`: Sets owner.
- `setManager`: (Owner) Sets the `SecondaryMarketManager` address.
- `setListing`: (Manager Only) Stores/updates a `SaleListing`.
- `deleteListing`: (Manager Only) Removes a listing.
- `setPendingProceeds`: (Manager Only) Updates pending proceeds for a seller.
- `getListing`, `getPendingProceeds`: Getters.

### Interfaces
- `IMarketStorage`

---

## `src/core/logic/ContestManager.sol`

### Purpose
Contains the business logic for contest management. Reads/writes state from `ContestStorage` and `GlobalConfigStorage`. Interacts with `OracleManager`.

### Variables
- `contestStorage`: Address of `ContestStorage`.
- `globalConfig`: Address of `GlobalConfigStorage`.
- `oracleManager`: Address of `OracleManager`.

### Mappings
- None (State is in Storage contracts)

### Functions
- `constructor`: Sets storage/dependency addresses.
- `createContest`: Reads config from `GlobalConfigStorage`, calls `OracleManager.sendRequest`, tells `ContestStorage` to `incrementContestId` and `mapRequest`.
- `handleOracleResponse`: Callback from `OracleManager`. Reads request mapping from `ContestStorage`, processes response, calls `ContestStorage.setContest`, `ContestStorage.setStartTime`, etc.
- `scoreContest`: Reads config, calls `OracleManager.sendRequest`, tells `ContestStorage` to update timer.
- `scoreContestManually`: Reads start time/status from `ContestStorage`, validates, calls `ContestStorage.setContest` to update score/status.
- `setTimer`: Calls `GlobalConfigStorage.setContestTimerInterval` (if config allows logic contracts to update specific fields).
- `getContest`: Reads from `ContestStorage`.

### Interfaces
- `IContestManager`

---

## `src/core/logic/SpeculationManager.sol`

### Purpose
Contains business logic for speculation management and odds. Reads/writes state from `SpeculationStorage` and `GlobalConfigStorage`. Interacts with `Scorer` contracts.

### Variables
- `speculationStorage`: Address of `SpeculationStorage`.
- `globalConfig`: Address of `GlobalConfigStorage`.

### Mappings
- None

### Functions
- `constructor`: Sets storage/dependency addresses.
- `createSpeculation`: Reads config, calls `SpeculationStorage.incrementSpeculationId`, calls `SpeculationStorage.setSpeculation`.
- `settleSpeculation`: Reads speculation data and config (cooldown) from storage contracts, calls scorer (address from `GlobalConfigStorage`), calls `SpeculationStorage.setSpeculation` to update status/winner.
- `forfeitSpeculation`: Reads config/speculation, validates, calls `SpeculationStorage.setSpeculation`.
- `createOrUseExistingOddsPair`: Reads from `SpeculationStorage`, performs logic, calls `SpeculationStorage` setters (`setOriginalOdds`, `setInverseOdds`, `setSpeculationOddsPairMapping`).
- `storeOddsPair`: Calls `SpeculationStorage.setOddsPair`.
- `getSpeculation`: Reads from `SpeculationStorage`.
- `getOddsPair`: Reads from `SpeculationStorage`.
- `roundOddsToNearestIncrement`, `calculateAndRoundInverseOdds`: Pure helpers.

### Interfaces
- `ISpeculationManager`

---

## `src/core/logic/PositionManager.sol`

### Purpose
Contains business logic for position management. Reads/writes state from `PositionStorage` and `GlobalConfigStorage`. Interacts with `SpeculationManager` logic contract and ERC20 token. *Could be split further (Unmatched/Matched/Matcher logic) if needed, each interacting with `PositionStorage`.*

### Variables
- `positionStorage`: Address of `PositionStorage`.
- `globalConfig`: Address of `GlobalConfigStorage`.
- `speculationManager`: Address of `SpeculationManager` logic contract.

### Mappings
- None

### Functions
- `constructor`: Sets storage/dependency addresses.
- `createUnmatchedPair`: Reads config, calls `SpeculationManager.createOrUseExistingOddsPair`, transfers tokens, calls `PositionStorage.setPosition` / `setRepeatPosition`, handles contribution.
- `adjustUnmatchedPair`: Reads position from `PositionStorage`, validates, transfers tokens/refunds, calls `PositionStorage.setPosition` / `setRepeatPosition`.
- `completeUnmatchedPair`: Reads positions/config, calls `SpeculationManager.getOddsPair`, transfers tokens, calls `PositionStorage.setPosition` / `setRepeatPosition` multiple times to update maker/taker states.
- `transferPosition`: (Called by Market Manager) Reads source position, validates, calls `PositionStorage` to update source amount and create/update target position.
- `splitPosition`: Reads position, validates, calls `PositionStorage` to update source amount and create new split position.
- `claimPosition`: Reads position/speculation status/winner, calculates payout, transfers tokens, calls `PositionStorage` to update claimed status/zero amounts.
- `createOrUpdatePosition`: (Called by `BulkManager`) Calls appropriate setters in `PositionStorage`.
- `getPosition`: Reads from `PositionStorage`.
- `calculatePayout`: Reads necessary data from storage contracts/SpeculationManager, performs calculation.

### Interfaces
- `IPositionManager`

---

## `src/core/logic/BulkManager.sol`

### Purpose
Contains business logic for bulk operations. Interacts with `PositionManager` logic contract (which then interacts with `PositionStorage`) and `GlobalConfigStorage`.

### Variables
- `globalConfig`: Address of `GlobalConfigStorage`.
- `positionManager`: Address of `PositionManager` logic contract.
- `speculationManager`: Address of `SpeculationManager` logic contract.

### Mappings
- None

### Functions
- `constructor`: Sets storage/dependency addresses.
- `completeUnmatchedPairBulk`: Reads config, loops through identifiers, calls `PositionManager.getPosition`, `SpeculationManager.getOddsPair`, calculates amounts, transfers tokens, calls `PositionManager.createOrUpdatePosition` multiple times.
- `combinePositions`: Reads config, loops, calls `PositionManager.getPosition`, validates, calls `PositionManager.createOrUpdatePosition` multiple times.

### Interfaces
- `IBulkManager`

---

## `src/core/logic/OracleManager.sol`

### Purpose
Contains business logic for Chainlink Functions interaction. Reads config from `GlobalConfigStorage`. Calls back to registered logic contracts (e.g., `ContestManager`).

### Variables
- `globalConfig`: Address of `GlobalConfigStorage`.

### Mappings
- `s_requestOriginator`: mapping(bytes32 => address) - Maps request ID to the LOGIC contract address that initiated it.

### Functions
- `constructor`: Sets storage address, initializes `FunctionsClient`.
- `sendRequest`: Reads LINK config from `GlobalConfigStorage`, handles payment, calls Chainlink `_sendRequest`, stores originator mapping.
- `fulfillRequest`: Validates request ID, identifies originator logic contract from mapping, calls callback function on originator (e.g., `ContestManager.handleOracleResponse`).
- `withdrawLink`: Reads LINK address, transfers LINK.
- `setRouter`, `setDonId`, etc.: Calls setters on `GlobalConfigStorage` (if permitted).

### Interfaces
- `IOracleManager`

---

## `src/market/logic/SecondaryMarketManager.sol`

### Purpose
Contains business logic for secondary market. Reads/writes state from `MarketStorage` and `GlobalConfigStorage`. Interacts with `PositionManager` logic contract.

### Variables
- `marketStorage`: Address of `MarketStorage`.
- `globalConfig`: Address of `GlobalConfigStorage`.
- `positionManager`: Address of `PositionManager` logic contract.
- `speculationManager`: Address of `SpeculationManager` logic contract.

### Mappings
- None

### Functions
- `constructor`: Sets storage/dependency addresses.
- `listPositionForSale`: Reads config/position state (via `PositionManager`), handles contribution, calls `MarketStorage.setListing`.
- `buyPosition`: Reads listing/config, transfers payment, calls `PositionManager.transferPosition`, calls `MarketStorage` setters (`setPendingProceeds`, `deleteListing`/`setListing`).
- `claimSaleProceeds`: Reads `pendingProceeds` from `MarketStorage`, transfers tokens, calls `MarketStorage.setPendingProceeds` to zero out.
- `cancelListing`: Reads listing, validates (via `PositionManager`), calls `MarketStorage.deleteListing`.
- `updateListing`: Reads listing/position, validates, calls `MarketStorage.setListing`.

### Interfaces
- `ISecondaryMarketManager`

---

## `src/scoring/*.sol` (Logic)

### Purpose
(Similar to Approach 1 & 2) Implement scoring logic. Read contest data via `ContestManager` logic contract.

### Variables
- `contestManager`: Address of `ContestManager` logic contract.

### Mappings/Functions/Interfaces
(Similar logic, interacting with `ContestManager` logic contract to get contest data).

---

### Data Flow Examples

Flows involve an extra hop to storage contracts for state reads/writes:

*   **Create Contest**: User -> `ContestManager` (Logic) -> `GlobalConfigStorage` (Read config) -> `OracleManager` (Logic) -> `ContestStorage` (Write request mapping, increment ID) -> Chainlink.
*   **Oracle Response**: Chainlink -> `OracleManager` (Logic) -> `ContestManager` (Logic via callback) -> `ContestStorage` (Write contest state).
*   **Create Unmatched**: User -> `PositionManager` (Logic) -> `GlobalConfigStorage` (Read limits) -> `SpeculationManager` (Logic for odds) -> `PositionStorage` (Write position) -> Token Transfer.
*   **Claim Position**: User -> `PositionManager` (Logic) -> `PositionStorage` (Read position) -> `SpeculationManager` (Logic for winner/status) -> `PositionStorage` (Write claimed state) -> Token Transfer.
*   **Buy Sale**: Buyer -> `SecondaryMarketManager` (Logic) -> `MarketStorage` (Read listing) -> `PositionManager` (Logic for transfer) -> `MarketStorage` (Write proceeds, update listing) -> Token Transfer.

This illustrates the pattern: Logic contracts coordinate actions, read parameters from global config storage, read/write domain-specific state via dedicated storage contracts, and interact with other logic contracts or external systems (like Chainlink via `OracleManager`, or ERC20 token).

</rewritten_file> 