// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Position, PositionType, OddsPair} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title IPositionModule
 * @notice Interface for the PositionModule in the Ospex protocol
 * @dev Handles user positions: creation, matching, claiming, etc.
 */
interface IPositionModule is IModule {

    /**
     * @notice Returns the odds precision
     * @return The odds precision
     */
    function ODDS_PRECISION() external view returns (uint64);

    /**
     * @notice Creates an unmatched pair at specified odds
     * @param speculationId The speculation to bet on
     * @param odds Desired odds (fixed-point, 1e7 precision)
     * @param unmatchedExpiry The expiry of the unmatched position
     * @param positionType Upper/Lower position
     * @param amount Amount to bet
     * @param contributionAmount Amount to contribute (for front-end queueing)
     */
    function createUnmatchedPair(
        uint256 speculationId,
        uint64 odds,
        uint32 unmatchedExpiry,
        PositionType positionType,
        uint256 amount,
        uint256 contributionAmount
    ) external;

    /**
     * @notice Adjusts the amount of an existing unmatched pair
     * @param speculationId Speculation ID
     * @param oddsPairId ID of the odds pair
     * @param newUnmatchedExpiry The new expiry of the unmatched position
     * @param positionType Position type
     * @param amount Amount to adjust (positive to add, negative to reduce)
     * @param contributionAmount Optional amount to contribute
     */
    function adjustUnmatchedPair(
        uint256 speculationId,
        uint128 oddsPairId,
        uint32 newUnmatchedExpiry,
        PositionType positionType,
        int256 amount,
        uint256 contributionAmount
    ) external;

    /**
     * @notice Completes an unmatched pair by matching with a specific position
     * @param speculationId Speculation to bet on
     * @param maker Address of the position creator
     * @param oddsPairId ID of the odds pair to match with
     * @param makerPositionType Upper/Lower position
     * @param amount Amount to bet
     */
    function completeUnmatchedPair(
        uint256 speculationId,
        address maker,
        uint128 oddsPairId,
        PositionType makerPositionType,
        uint256 amount
    ) external;

    /**
     * @notice Completes multiple unmatched pairs by matching with specific positions
     * @param speculationId Speculation to bet on
     * @param makers Array of position creators
     * @param oddsPairIds Array of odds pair IDs
     * @param makerPositionTypes Array of position types
     * @param amounts Array of amounts to bet
     */
    function completeUnmatchedPairBatch(
        uint256 speculationId,
        address[] calldata makers,
        uint128[] calldata oddsPairIds,
        PositionType[] calldata makerPositionTypes,
        uint256[] calldata amounts
    ) external;

    /**
     * @notice Transfers position ownership
     * @param speculationId Speculation ID
     * @param from Address transferring from
     * @param oddsPairId ID of the odds pair
     * @param positionType Position type
     * @param to Address transferring to
     * @param amount Amount to transfer
     */
    function transferPosition(
        uint256 speculationId,
        address from,
        uint128 oddsPairId,
        PositionType positionType,
        address to,
        uint256 amount
    ) external;

    /**
     * @notice Claims winnings and/or unmatched amounts for a position
     * @param speculationId Speculation ID
     * @param oddsPairId Odds pair ID
     * @param positionType Type of position
     */
    function claimPosition(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType
    ) external;

    /**
     * @notice Gets position details
     * @param speculationId Speculation ID
     * @param user Address to check
     * @param oddsPairId Odds pair ID
     * @param positionType Position type
     * @return position The Position struct
     */
    function getPosition(
        uint256 speculationId,
        address user,
        uint128 oddsPairId,
        PositionType positionType
    ) external view returns (Position memory position);

    /**
     * @notice Gets an odds pair
     * @param oddsPairId The ID of the odds pair
     * @return oddsPair The odds pair
     */
    function getOddsPair(
        uint128 oddsPairId
    ) external view returns (OddsPair memory oddsPair);
}
