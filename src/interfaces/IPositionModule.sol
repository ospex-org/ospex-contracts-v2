// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

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
     * @notice Creates a fully matched pair atomically — both sides in a single call
     * @param speculationId The ID of the speculation
     * @param odds The odds for the maker's position
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerAmountRemaining The amount the maker has remaining
     * @param taker The address of the taker
     * @param takerAmount The amount the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return makerAmountConsumed The amount that is consumed by the match
     */
    function createMatchedPair(
        uint256 speculationId,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external returns (uint256);

    /**
     * @notice Creates a fully matched pair atomically — both sides in a single call with a speculation
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The line/spread/total number
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @param odds The odds for the maker's position
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerAmountRemaining The amount the maker has remaining
     * @param taker The address of the taker
     * @param takerAmount The amount the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return makerAmountConsumed The amount that is consumed by the match
     */
    function createMatchedPairWithSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256 leaderboardId,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external returns (uint256);

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
     * @notice Claims winnings from a position
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
