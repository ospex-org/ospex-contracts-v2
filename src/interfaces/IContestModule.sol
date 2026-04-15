// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IModule} from "./IModule.sol";
import {Contest, LeagueId, ContestMarket} from "../core/OspexTypes.sol";

/**
 * @title IContestModule
 * @notice Interface for the Ospex ContestModule. Handles contest creation, market data,
 *         verification, and scoring. All mutations are restricted to the OracleModule.
 */
interface IContestModule is IModule {
    /// @notice The auto-incrementing contest ID counter
    function s_contestIdCounter() external view returns (uint256);

    /// @notice Returns the start timestamp for a contest (set during verification)
    /// @param contestId The contest ID
    /// @return The contest start timestamp
    function s_contestStartTimes(
        uint256 contestId
    ) external view returns (uint32);

    /// @notice Creates a new contest. Only callable by OracleModule.
    /// @param rundownId Contest ID from Rundown API
    /// @param sportspageId Contest ID from Sportspage API
    /// @param jsonoddsId Contest ID from JSONOdds API
    /// @param verifySourceHash Hash of the verification JS used at creation
    /// @param marketUpdateSourceHash Hash of the market updating source code for this contest
    /// @param scoreContestSourceHash Hash of the scoring source code for this contest
    /// @param approvedLeagueId Approved league from script approvals (Unknown = wildcard). Sets contest.leagueId.
    /// @param contestCreator Address that initiated (and pays for) the contest
    /// @return contestId The unique contest identifier
    function createContest(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId,
        bytes32 verifySourceHash,
        bytes32 marketUpdateSourceHash,
        bytes32 scoreContestSourceHash,
        LeagueId approvedLeagueId,
        address contestCreator
    ) external returns (uint256 contestId);

    /// @notice Updates all market data for a contest. Only callable by OracleModule.
    /// @param contestId The contest identifier
    /// @param moneylineAway Odds tick for away team moneyline
    /// @param moneylineHome Odds tick for home team moneyline
    /// @param spreadLineTicks The point spread (10x format)
    /// @param spreadAwayLine Odds tick for away spread
    /// @param spreadHomeLine Odds tick for home spread
    /// @param totalLineTicks The total points (10x format)
    /// @param overLine Odds tick for over
    /// @param underLine Odds tick for under
    function updateContestMarkets(
        uint256 contestId,
        uint16 moneylineAway,
        uint16 moneylineHome,
        int32 spreadLineTicks,
        uint16 spreadAwayLine,
        uint16 spreadHomeLine,
        int32 totalLineTicks,
        uint16 overLine,
        uint16 underLine
    ) external;

    /// @notice Sets the league and start time for a contest. Only callable by OracleModule.
    /// @param contestId The contest identifier
    /// @param leagueId The league ID
    /// @param startTime The contest start timestamp
    function setContestLeagueIdAndStartTime(
        uint256 contestId,
        LeagueId leagueId,
        uint32 startTime
    ) external;

    /// @notice Sets the final scores for a contest. Only callable by OracleModule.
    /// @param contestId The contest identifier
    /// @param awayScore Final away team score
    /// @param homeScore Final home team score
    function setScores(
        uint256 contestId,
        uint32 awayScore,
        uint32 homeScore
    ) external;

    /// @notice Gets contest data
    /// @param contestId The ID of the contest
    /// @return contest The contest struct
    function getContest(
        uint256 contestId
    ) external view returns (Contest memory contest);

    /// @notice Checks if a contest has been scored
    /// @param contestId The ID of the contest
    /// @return True if the contest has been scored
    function isContestScored(uint256 contestId) external view returns (bool);

    /// @notice Gets market data for a contest/scorer pair
    /// @param contestId The ID of the contest
    /// @param scorer The scorer contract address
    /// @return contestMarket The contest market data
    function getContestMarket(
        uint256 contestId,
        address scorer
    ) external view returns (ContestMarket memory contestMarket);
}
