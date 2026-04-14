// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Position, PositionType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title IPositionModule
 * @notice Interface for the Ospex PositionModule. Handles position fill recording,
 *         claiming, and transfers via the SecondaryMarketModule.
 */
interface IPositionModule is IModule {
    /// @notice Records a fill. Only callable by MatchingModule.
    /// @dev Creates the speculation if it doesn't exist yet. Creation fee is split
    ///      between maker and taker. Bet-size enforcement applies to takerRisk only.
    /// @param contestId The contest ID
    /// @param scorer The scorer address
    /// @param lineTicks The line number (10x format, 0 for moneyline)
    /// @param makerPositionType The maker's position type (Upper or Lower)
    /// @param maker The maker address
    /// @param makerRisk Maker risk being consumed
    /// @param taker The taker address
    /// @param takerRisk The taker's risk amount
    /// @return speculationId The speculation ID for the fill
    function recordFill(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) external returns (uint256);

    /// @notice Transfers position ownership. Only callable by SecondaryMarketModule.
    /// @dev Transfers are blocked if the remaining position would fall below
    ///      leaderboard-locked amounts.
    /// @param speculationId The speculation ID
    /// @param from The sender address
    /// @param positionType The position type
    /// @param to The recipient address
    /// @param riskAmount The risk amount being transferred
    /// @param profitAmount The profit amount being transferred
    function transferPosition(
        uint256 speculationId,
        address from,
        PositionType positionType,
        address to,
        uint256 riskAmount,
        uint256 profitAmount
    ) external;

    /// @notice Claims winnings from a settled position. Permissionless for the position holder.
    /// @param speculationId The speculation ID
    /// @param positionType The position type
    function claimPosition(
        uint256 speculationId,
        PositionType positionType
    ) external;

    /// @notice Gets position details
    /// @param speculationId The speculation ID
    /// @param user The address to check
    /// @param positionType The position type
    /// @return position The Position struct
    function getPosition(
        uint256 speculationId,
        address user,
        PositionType positionType
    ) external view returns (Position memory position);
}
