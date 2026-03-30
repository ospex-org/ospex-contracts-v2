// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Position, PositionType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title IPositionModule
 * @notice Interface for the PositionModule in the Ospex protocol
 * @dev Handles user positions: creation, matching, claiming, etc.
 */
interface IPositionModule is IModule {

    /**
     * @notice Records a fill
     * @param contestId The contest id
     * @param scorer The scorer address
     * @param lineTicks The line number if applicable
     * @param leaderboardId The leaderboard id for fees if applicable
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerRisk Maker risk being consumed
     * @param taker The address of the taker
     * @param takerRisk The risk the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return speculationId The speculation for the fill
     */
    function recordFill(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        uint256 leaderboardId,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external returns (uint256);

    /**
     * @notice Transfers position ownership
     * @param speculationId Speculation ID
     * @param from Address transferring from
     * @param positionType Position type
     * @param to Address transferring to
     * @param riskAmount The amount of risk being sold
     * @param profitAmount The amount of profit being sold
     */
    function transferPosition(
        uint256 speculationId,
        address from,
        PositionType positionType,
        address to,
        uint256 riskAmount,
        uint256 profitAmount
    ) external;

    /**
     * @notice Claims winnings from a position
     * @param speculationId Speculation ID
     * @param positionType Type of position
     */
    function claimPosition(
        uint256 speculationId,
        PositionType positionType
    ) external;

    /**
     * @notice Gets position details
     * @param speculationId Speculation ID
     * @param user Address to check
     * @param positionType Position type
     * @return position The Position struct
     */
    function getPosition(
        uint256 speculationId,
        address user,
        PositionType positionType
    ) external view returns (Position memory position);

}
