// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FeeType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title ITreasuryModule
 * @notice Interface for the TreasuryModule in the Ospex protocol
 * @dev Handles fee collection, routing, and allocation for contest creation, speculation creation, and leaderboard entry.
 */
interface ITreasuryModule is IModule {
    /**
     * @notice Handles a fee payment, splits between protocol and prize pools per config and user allocation.
     * @param payer The address paying the fee
     * @param amount The total fee amount
     * @param feeType The type of fee (see FeeType enum)
     * @param leaderboardId The leaderboard ID to allocate
     */
    function processFee(
        address payer,
        uint256 amount,
        FeeType feeType,
        uint256 leaderboardId
    ) external;

    /**
     * @notice Processes a leaderboard entry fee for a given payer and amount
     * @param payer The address of the payer
     * @param amount The amount of the fee
     * @param leaderboardId The ID of the leaderboard
     */
    function processLeaderboardEntryFee(
        address payer,
        uint256 amount,
        uint256 leaderboardId
    ) external;

    /**
     * @notice Admin: sets the fee rate for a given fee type
     * @param feeType The type of fee
     * @param rate The new fee rate (in token units or bps, per config)
     */
    function setFeeRates(FeeType feeType, uint256 rate) external;

    /**
     * @notice Admin: sets the protocol cut (in basis points)
     * @param cutBps The new protocol cut (e.g., 500 = 5%)
     */
    function setProtocolCut(uint256 cutBps) external;

    /**
     * @notice Admin: sets the protocol revenue receiver address
     * @param receiver The new protocol receiver address
     */
    function setProtocolReceiver(address receiver) external;

    /**
     * @notice Allows LeaderboardModule to transfer prize pool funds to winners
     * @param leaderboardId The leaderboard to claim from
     * @param to The address to send funds to
     * @param share The share of the prize pool to claim
     */
    function claimPrizePool(
        uint256 leaderboardId,
        address to,
        uint256 share
    ) external;

    /**
     * @notice Returns the current fee rate for a given type
     * @param feeType The type of fee
     * @return rate The current fee rate
     */
    function getFeeRate(FeeType feeType) external view returns (uint256 rate);

    /**
     * @notice Returns the current prize pool balance for a leaderboard
     * @param leaderboardId The leaderboard ID
     * @return balance The current prize pool balance
     */
    function getPrizePool(
        uint256 leaderboardId
    ) external view returns (uint256 balance);

}
