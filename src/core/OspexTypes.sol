// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
    ScoredManually           // Manually scored by admin
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
    EPL
}

/// @notice Represents a speculation on a contest outcome
struct Speculation {
    uint256 contestId;                   // Associated contest ID
    uint32 startTimestamp;               // Time when speculation starts
    address speculationScorer;           // Scorer contract address
    int32 theNumber;                     // Line/spread/total number
    address speculationCreator;          // Creator address
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
    Forfeit,                 // Contest canceled
    Void                     // Unresolved and voided
}

/// @notice User's position in a speculation
struct Position {
    uint256 matchedAmount;
    uint256 unmatchedAmount;
    uint128 poolId;
    uint32 unmatchedExpiry;
    PositionType positionType;
    bool claimed;
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
    LeaderboardEntry      // Fee for entering a leaderboard
}

/// @notice Represents an odds pool for a contest
struct OddsPair {
    uint128 oddsPairId;       // Odds pair ID
    uint64 upperOdds;         // Upper odds
    uint64 lowerOdds;         // Lower odds
}

/// @notice Represents a sale listing for one side of a matched pair
struct SaleListing {
    uint256 price;            // Price of the sale listing
    uint256 amount;           // Amount of position to sell
}

/// @notice Represents a leaderboard and its configuration/state
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

/// @notice Stores current market odds/number and metadata for leaderboard enforcement
struct LeaderboardSpeculation {
    uint256 contestId;          // Associated contest ID (copied for convenience)
    uint256 speculationId;      // Associated speculation ID
    uint64 upperOdds;           // Current market odds for upper position (e.g., Away/Over)
    uint64 lowerOdds;           // Current market odds for lower position (e.g., Home/Under)
    int32 theNumber;            // Current market number (spread/total), if applicable
}

/// @notice Tracks a user's leaderboard-eligible position
struct LeaderboardPosition {
    uint256 contestId;            // Contest ID
    uint256 speculationId;        // Speculation ID
    uint256 amount;               // Amount eligible for leaderboard
    address user;                 // User address
    uint64 odds;                  // Odds at entry (for this position)
    PositionType positionType;    // Position type (Upper/Lower)
}

/// @notice Stores the scoring information for a leaderboard
struct LeaderboardScoring {
    int256 highestROI;
    address[] winners;
    mapping(address => int256) userROIs;
    mapping(address => bool) hasClaimed;
}

/// @notice Type of oracle request
enum OracleRequestType {
    ContestCreate,
    ContestScore,
    LeaderboardSpeculationCreate,
    LeaderboardSpeculationUpdate
}

/// @notice Context for oracle requests
struct OracleRequestContext {
    OracleRequestType requestType;
    uint256 contestId;             // Used for contest related requests
    uint256 speculationId;         // Used for speculation/leaderboard related requests
}