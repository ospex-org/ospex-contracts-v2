// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title OspexTypes
 * @author ospex.org
 * @notice Shared types and data structures for the Ospex protocol
 * @dev Contains all common structs and enums used across the protocol
 */

/// @notice Represents a contest with its scores and metadata
struct Contest {
    uint32 awayScore;                // Final away team score
    uint32 homeScore;                // Final home team score
    LeagueId leagueId;               // League ID
    ContestStatus contestStatus;     // Current status of the contest
    address contestCreator;          // Address that created the contest
    bytes32 verifySourceHash;        // Hash of the verification source code
    bytes32 marketUpdateSourceHash;  // Hash of the odds update source code
    bytes32 scoreContestSourceHash;  // Hash of the scoring source code
    string rundownId;                // Contest ID from Rundown API
    string sportspageId;             // Contest ID from Sportspage API
    string jsonoddsId;               // Contest ID from JSONOdds API
}

/// @notice Possible states of a contest
enum ContestStatus {
    Unverified,              // Initial state
    Verified,                // Contest verified by oracle
    Scored,                  // Final scores recorded
    Voided                   // Locked to void from speculation
}

/// @notice Represents a market for a contest
struct ContestMarket {
    int32 lineTicks;                     // Line/spread/total number
    uint16 upperOdds;                    // Upper odds (reference only)
    uint16 lowerOdds;                    // Lower odds (reference only)
    uint32 lastUpdated;
}

/// @notice League Id
enum LeagueId {
    Unknown,
    NCAAF,
    NFL,
    MLB,
    NBA,
    NCAAB,
    NHL,
    MMA,
    WNBA,
    CFL,
    MLS,
    EPL,
    FRA1,
    GER1,
    ESP1,
    ITA1,
    UEFACHAMP,
    UEFAEURO,
    FIFA
}

/// @notice Represents a speculation on a contest outcome
struct Speculation {
    uint256 contestId;                   // Associated contest ID
    address speculationScorer;           // Scorer contract address
    int32 lineTicks;                     // Line/spread/total number
    address speculationTaker;            // Creator address
    SpeculationStatus speculationStatus; // Current status
    WinSide winSide;                     // Winning side
}

/// @notice Status of a speculation
enum SpeculationStatus {
    Open,      // Taking bets, trading allowed
    Closed     // Scored and claimable
}

/// @notice Possible winning sides of a speculation
enum WinSide {
    TBD,                     // To be determined
    Away,                    // Away team wins
    Home,                    // Home team wins
    Over,                    // Over the total
    Under,                   // Under the total
    Push,                    // Tie/Push
    Void                     // Unresolved and voided
}

/// @notice User's position in a speculation
struct Position {
    uint256 riskAmount;         // amount user loses if wrong
    uint256 profitAmount;       // net winnings if correct
    PositionType positionType;
    bool claimed;
    /// @notice Earliest moment at which this position held non-zero exposure.
    /// Set on first fill and preserved across aggregating fills.
    /// Inherited from source on transfer (min of source and destination if both exist).
    uint32 firstFillTimestamp;
}

/// @notice Type of position taken in a speculation
enum PositionType {
    Upper,                   // Away team or Over
    Lower                    // Home team or Under
}

/// @notice Type of fee charged in the protocol
/// @dev Used for fee routing and allocation in TreasuryModule
enum FeeType {
    ContestCreation,      // Fee for creating a contest
    SpeculationCreation,  // Fee for creating a speculation/market
    LeaderboardCreation   // Fee for creating a leaderboard
}

/// @notice Represents a sale listing for one side of a matched pair
struct SaleListing {
    uint256 price;            // Price of the sale listing
    uint256 riskAmount;       // Risk amount of position to sell
    uint256 profitAmount;     // Profit amount of position to sell
}

/// @notice Represents a leaderboard and its configuration/state
struct Leaderboard {
    uint256 entryFee;             // Entry fee (if any)
    address creator;              // Creator address
    uint32 startTime;             // Leaderboard start timestamp
    uint32 endTime;               // Leaderboard end timestamp
    uint32 safetyPeriodDuration;  // Safety period after end (seconds)
    uint32 roiSubmissionWindow;   // ROI submission window after end (seconds)
}

/// @notice Tracks a user's leaderboard-eligible position
struct LeaderboardPosition {
    uint256 contestId;            // Contest ID
    uint256 speculationId;        // Speculation ID
    uint256 riskAmount;
    uint256 profitAmount;
    address user;                 // User address
    PositionType positionType;    // Position type (Upper/Lower)
}

/// @notice Stores the scoring information for a leaderboard
struct LeaderboardScoring {
    int256 highestROI;
    address[] winners;
    uint256 snapshotPrizePool;
    mapping(address => int256) userROIs;
    mapping(address => bool) hasClaimed;
}

/// @notice Type of oracle request
enum OracleRequestType {
    ContestCreate,
    ContestMarketsUpdate,
    ContestScore
}

/// @notice Context for oracle requests
struct OracleRequestContext {
    OracleRequestType requestType;
    uint256 contestId;             // Used for contest related requests
}

/// @notice Result of leaderboard position validation
enum LeaderboardPositionValidationResult {
    Valid,
    LeaderboardDoesNotExist,
    LeaderboardHasNotStarted,
    LeaderboardHasEnded,
    SpeculationNotRegistered,
    LiveBettingNotAllowed,
    NumberDeviationTooLarge,
    OddsTooFavorable,
    MoneylineSpreadPairingNotAllowed
}

/// @notice Purpose of a script approval — prevents cross-purpose signature replay
enum ScriptPurpose {
    VERIFY,        // 0 — contest verification JS
    MARKET_UPDATE, // 1 — market data update JS
    SCORE          // 2 — contest scoring JS
}

/// @notice Signed approval for a script hash from the protocol's approved signer
/// @dev Verified via EIP-712 signature at contest creation only
struct ScriptApproval {
    bytes32 scriptHash;      // keccak256 of the JS source
    ScriptPurpose purpose;   // what this hash is approved for
    LeagueId leagueId;       // LeagueId.Unknown (0) = all leagues
    uint16 version;          // human-readable version for off-chain tracking
    uint64 validUntil;       // expiry timestamp, 0 = permanent
}
