// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Speculation} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title ISpeculationModule
 * @notice Interface for the SpeculationModule in the Ospex protocol
 * @dev Handles creation, settlement, and management of speculations (betting markets) for contests.
 */
interface ISpeculationModule is IModule {
    /**
     * @notice Returns the minimum speculation amount (in token's smallest units)
     */
    function s_minSpeculationAmount() external view returns (uint256);

    /**
     * @notice Returns the maximum speculation amount (in token's smallest units)
     */
    function s_maxSpeculationAmount() external view returns (uint256);

    /**
     * @notice Returns the current void cooldown (in seconds)
     */
    function s_voidCooldown() external view returns (uint32);

    /**
     * @notice Returns the number of decimals for the token (e.g., 6 for USDC, 18 for ETH)
     */
    function i_tokenDecimals() external view returns (uint8);

    /**
     * @notice Creates a new speculation (betting market) for a contest
     * @param contestId The ID of the contest
     * @param scorer The address of the scorer contract for this speculation
     * @param theNumber The line/spread/total number for the speculation
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @return speculationId The ID of the newly created speculation
     */
    function createSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256 leaderboardId
    ) external returns (uint256 speculationId);

    /**
     * @notice Creates a speculation, called from Position Module when creating an unmatched pair
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The number of the speculation
     * @param speculationCreator The creator of the speculation
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @return speculationId The ID of the speculation
     */
    function createSpeculationWithUnmatchedPair(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        address speculationCreator,
        uint256 leaderboardId
    ) external returns (uint256 speculationId);

    /**
     * @notice Settles a speculation after scoring (closes the market and sets the winner)
     * @param speculationId The ID of the speculation to settle
     */
    function settleSpeculation(uint256 speculationId) external;

    /**
     * @notice Forfeits a speculation (sets status to Closed and winSide to Forfeit)
     * @param speculationId The ID of the speculation to forfeit
     */
    function forfeitSpeculation(uint256 speculationId) external;

    /**
     * @notice Gets the details of a speculation
     * @param speculationId The ID of the speculation
     * @return speculation The Speculation struct
     */
    function getSpeculation(
        uint256 speculationId
    ) external view returns (Speculation memory speculation);

    /**
     * @notice Gets a speculation ID by contest parameters
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The number of the speculation
     * @return speculationId The ID of the speculation (0 if doesn't exist)
     */
    function getSpeculationId(
        uint256 contestId,
        address scorer,
        int32 theNumber
    ) external view returns (uint256 speculationId);

    /**
     * @notice Sets the minimum speculation amount (in whole tokens, normalized to token decimals)
     * @param minAmount The new minimum speculation amount (whole tokens)
     */
    function setMinSpeculationAmount(uint256 minAmount) external;

    /**
     * @notice Sets the maximum speculation amount (in whole tokens, normalized to token decimals)
     * @param maxAmount The new maximum speculation amount (whole tokens)
     */
    function setMaxSpeculationAmount(uint256 maxAmount) external;

    /**
     * @notice Sets the void cooldown (minimum time after start before a speculation can be voided)
     * @param newVoidCooldown The new void cooldown (in seconds)
     */
    function setVoidCooldown(uint32 newVoidCooldown) external;
}
