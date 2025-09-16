// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IModule} from "./IModule.sol";
import {PositionType, Leaderboard, LeaderboardPosition} from "../core/OspexTypes.sol";

interface ILeaderboardModule is IModule {
    function s_leaderboardSpeculationRegistered(
        uint256 leaderboardId,
        uint256 speculationId
    ) external view returns (bool);

    function s_registeredLeaderboardSpeculation(
        uint256 leaderboardId,
        address user,
        uint256 contestId,
        address scorer
    ) external view returns (uint256);

    function createLeaderboard(
        uint256 entryFee,
        address yieldStrategy,
        uint32 startTime,
        uint32 endTime,
        uint32 safetyPeriodDuration,
        uint32 roiSubmissionWindow,
        uint32 claimWindow
    ) external returns (uint256 leaderboardId);

    function addLeaderboardSpeculation(
        uint256 leaderboardId,
        uint256 speculationId
    ) external;

    function registerUser(
        uint256 leaderboardId,
        uint256 declaredBankroll
    ) external;

    function registerPositionForLeaderboards(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256[] calldata leaderboardIds
    ) external;

    function increaseLeaderboardPositionAmount(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256[] calldata leaderboardIds
    ) external;

    function submitLeaderboardROI(uint256 leaderboardId) external;

    function claimLeaderboardPrize(uint256 leaderboardId) external;

    function adminSweep(uint256 leaderboardId, address to) external;

    // --- Getters ---
    function getLeaderboard(
        uint256 leaderboardId
    ) external view returns (Leaderboard memory);

    function getLeaderboardPosition(
        uint256 leaderboardId,
        address user,
        uint256 speculationId
    ) external view returns (LeaderboardPosition memory);

    // Explicit getters for LeaderboardScoring fields (cannot return struct with mappings)
    function getUserROI(
        uint256 leaderboardId,
        address user
    ) external view returns (int256);
    function getWinners(
        uint256 leaderboardId
    ) external view returns (address[] memory);
    function getHighestROI(
        uint256 leaderboardId
    ) external view returns (int256);
    function hasClaimed(
        uint256 leaderboardId,
        address user
    ) external view returns (bool);
}
