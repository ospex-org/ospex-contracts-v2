// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IModule} from "./IModule.sol";
import {Contest, LeagueId} from "../core/OspexTypes.sol";

/**
 * @title IContestModule
 * @notice Interface for the Ospex ContestModule
 */
interface IContestModule is IModule {
    /// @notice The contest ID counter
    function s_contestIdCounter() external view returns (uint256);

    /// @notice The hash of the create contest source
    function s_createContestSourceHash() external view returns (bytes32);

    /// @notice The contest start times
    function s_contestStartTimes(uint256 contestId) external view returns (uint32);

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

    /// @notice Sets the create contest source hash
    /// @param newCreateContestSourceHash The new create contest source hash
    function setCreateContestSourceHash(
        bytes32 newCreateContestSourceHash
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
}
