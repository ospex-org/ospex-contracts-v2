// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IModule} from "./IModule.sol";
import {Contest, LeagueId, ContestMarket} from "../core/OspexTypes.sol";

/**
 * @title IContestModule
 * @notice Interface for the Ospex ContestModule
 */
interface IContestModule is IModule {
    /// @notice The contest ID counter
    function s_contestIdCounter() external view returns (uint256);

    /// @notice The hash of the create contest source
    function s_createContestSourceHash() external view returns (bytes32);

    /// @notice The hash of the update contest markets source
    function s_updateContestMarketsSourceHash() external view returns (bytes32);

    /// @notice The contest start times
    function s_contestStartTimes(
        uint256 contestId
    ) external view returns (uint32);

    /// @notice Creates a new contest
    /// @param rundownId Contest ID from Rundown API
    /// @param sportspageId Contest ID from Sportspage API
    /// @param jsonoddsId Contest ID from JSONOdds API
    /// @param scoreContestSourceHash Hash of scoring rules
    /// @param contestCreator Address that created the contest
    /// @param leaderboardId The leaderboard ID (where the fee will be allocated)
    /// @return contestId The unique contest identifier
    function createContest(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId,
        bytes32 scoreContestSourceHash,
        address contestCreator,
        uint256 leaderboardId
    ) external returns (uint256 contestId);

    /// @notice Gets contest data
    /// @param contestId The ID of the contest to retrieve
    /// @return contest The contest struct
    function getContest(
        uint256 contestId
    ) external view returns (Contest memory contest);

    /// @notice Checks if a contest has been scored
    /// @param contestId The ID of the contest
    /// @return True if the contest has been Scored or ScoredManually
    function isContestScored(uint256 contestId) external view returns (bool);

    /// @notice Gets a contest market
    /// @param contestId The ID of the contest
    /// @param scorer The scorer contract address
    /// @return contestMarket The contest market
    function getContestMarket(
        uint256 contestId,
        address scorer
    ) external view returns (ContestMarket memory contestMarket);

    /// @notice Sets the create contest source hash
    /// @param newCreateContestSourceHash The new create contest source hash
    function setCreateContestSourceHash(
        bytes32 newCreateContestSourceHash
    ) external;

    /// @notice Sets the update contest markets source hash
    /// @param newUpdateContestMarketsSourceHash The new update contest markets source hash
    function setUpdateContestMarketsSourceHash(
        bytes32 newUpdateContestMarketsSourceHash
    ) external;

    /// @notice Sets the start time of a contest
    /// @param contestId The contest identifier
    /// @param leagueId The league ID
    /// @param startTime The start time of the contest
    function setContestLeagueIdAndStartTime(
        uint256 contestId,
        LeagueId leagueId,
        uint32 startTime
    ) external;

    /// @notice Sets the final scores for a contest
    /// @param contestId The contest identifier
    /// @param awayScore Final away team score
    /// @param homeScore Final home team score
    function setScores(
        uint256 contestId,
        uint32 awayScore,
        uint32 homeScore
    ) external;

    /// @notice Updates all market data for a contest from oracle response
    /// @param contestId The contest identifier
    /// @param moneylineAway Odds tick for away team moneyline
    /// @param moneylineHome Odds tick for home team moneyline
    /// @param spread The point spread
    /// @param spreadAwayLine Odds tick for away spread
    /// @param spreadHomeLine Odds tick for home spread
    /// @param total The total points
    /// @param overLine Odds tick for over
    /// @param underLine Odds tick for under
    function updateContestMarkets(
        uint256 contestId,
        uint16 moneylineAway,
        uint16 moneylineHome,
        int32 spread,
        uint16 spreadAwayLine,
        uint16 spreadHomeLine,
        int32 total,
        uint16 overLine,
        uint16 underLine
    ) external;
}
