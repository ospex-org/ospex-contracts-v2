// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IModule} from "./IModule.sol";
import {PositionType, Leaderboard, LeaderboardPosition} from "../core/OspexTypes.sol";

/**
 * @title ILeaderboardModule
 * @notice Interface for the LeaderboardModule in the Ospex protocol
 * @dev Handles leaderboard creation, user registration, position tracking, ROI scoring, and prize distribution.
 */
interface ILeaderboardModule is IModule {
    /// @notice Returns whether a speculation is registered for a given leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param speculationId The ID of the speculation
    /// @return True if the speculation is registered for the leaderboard
    function s_leaderboardSpeculationRegistered(
        uint256 leaderboardId,
        uint256 speculationId
    ) external view returns (bool);

    /// @notice Returns the registered speculation ID for a user's contest/scorer slot in a leaderboard
    /// @dev Used to enforce one position per contest/scorer per user per leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param user The address of the user
    /// @param contestId The ID of the contest
    /// @param scorer The address of the scorer contract
    /// @return The registered speculation ID (0 if no position registered)
    function s_registeredLeaderboardSpeculation(
        uint256 leaderboardId,
        address user,
        uint256 contestId,
        address scorer
    ) external view returns (uint256);

    /// @notice Creates a new leaderboard with the specified configuration
    /// @param entryFee The entry fee to join the leaderboard (in token smallest units, 0 for free)
    /// @param yieldStrategy The address of an optional yield strategy contract (address(0) for none)
    /// @param startTime The unix timestamp when the leaderboard becomes active
    /// @param endTime The unix timestamp when the leaderboard stops accepting positions
    /// @param safetyPeriodDuration Duration in seconds after endTime before ROI submission opens
    /// @param roiSubmissionWindow Duration in seconds of the ROI submission window
    /// @param claimWindow Duration in seconds of the prize claim window
    /// @return leaderboardId The ID of the newly created leaderboard
    function createLeaderboard(
        uint256 entryFee,
        address yieldStrategy,
        uint32 startTime,
        uint32 endTime,
        uint32 safetyPeriodDuration,
        uint32 roiSubmissionWindow,
        uint32 claimWindow
    ) external returns (uint256 leaderboardId);

    /// @notice Registers a speculation as eligible for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param speculationId The ID of the speculation to register
    function addLeaderboardSpeculation(
        uint256 leaderboardId,
        uint256 speculationId
    ) external;

    /// @notice Registers the caller for a leaderboard with a declared bankroll
    /// @param leaderboardId The ID of the leaderboard
    /// @param declaredBankroll The user's declared bankroll (used for ROI normalization)
    function registerUser(
        uint256 leaderboardId,
        uint256 declaredBankroll
    ) external;

    /// @notice Snapshots a user's position into one or more leaderboards
    /// @dev Creates immutable LeaderboardPosition entries. Risk/profit amounts may be capped
    ///      proportionally based on the leaderboard's max bet rules.
    /// @param speculationId The ID of the speculation the position is on
    /// @param positionType The position type (Upper or Lower)
    /// @param leaderboardIds Array of leaderboard IDs to register the position for (max 8)
    function registerPositionForLeaderboards(
        uint256 speculationId,
        PositionType positionType,
        uint256[] calldata leaderboardIds
    ) external;

    /// @notice Calculates and submits the caller's ROI for a leaderboard
    /// @dev Can only be called during the ROI submission window. Each user may submit exactly once.
    /// @param leaderboardId The ID of the leaderboard
    function submitLeaderboardROI(uint256 leaderboardId) external;

    /// @notice Claims the caller's share of the prize pool for a leaderboard
    /// @dev Can only be called during the claim window by a winner
    /// @param leaderboardId The ID of the leaderboard
    function claimLeaderboardPrize(uint256 leaderboardId) external;

    /// @notice Sweeps unclaimed prizes to a specified address after the claim window ends
    /// @param leaderboardId The ID of the leaderboard
    /// @param to The address to receive the unclaimed prizes
    function adminSweep(uint256 leaderboardId, address to) external;

    // --- Getters ---

    /// @notice Gets the configuration for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @return The Leaderboard struct
    function getLeaderboard(
        uint256 leaderboardId
    ) external view returns (Leaderboard memory);

    /// @notice Gets a user's leaderboard position for a specific speculation
    /// @param leaderboardId The ID of the leaderboard
    /// @param user The address of the user
    /// @param speculationId The ID of the speculation
    /// @return The LeaderboardPosition struct (immutable snapshot)
    function getLeaderboardPosition(
        uint256 leaderboardId,
        address user,
        uint256 speculationId
    ) external view returns (LeaderboardPosition memory);

    /// @notice Gets the submitted ROI for a user in a leaderboard
    /// @dev Returns 0 if not yet submitted — use hasClaimed or check s_roiSubmitted for disambiguation
    /// @param leaderboardId The ID of the leaderboard
    /// @param user The address of the user
    /// @return The user's ROI (scaled by ROI_PRECISION = 1e18)
    function getUserROI(
        uint256 leaderboardId,
        address user
    ) external view returns (int256);

    /// @notice Gets the current winner(s) of a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @return Array of winner addresses (may contain multiple in case of ties)
    function getWinners(
        uint256 leaderboardId
    ) external view returns (address[] memory);

    /// @notice Gets the highest submitted ROI for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @return The highest ROI value (scaled by ROI_PRECISION = 1e18)
    function getHighestROI(
        uint256 leaderboardId
    ) external view returns (int256);

    /// @notice Checks whether a user has claimed their prize for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param user The address of the user
    /// @return True if the user has already claimed
    function hasClaimed(
        uint256 leaderboardId,
        address user
    ) external view returns (bool);
}
