// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FeeType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title ITreasuryModule
 * @notice Interface for the Ospex TreasuryModule. Handles protocol fee collection,
 *         leaderboard prize pool accounting, and prize disbursement.
 */
interface ITreasuryModule is IModule {
    /**
     * @notice Collects a protocol fee based on the stored rate for the given FeeType
     * @param payer The address paying the fee
     * @param feeType The category of fee being charged
     */
    function processFee(address payer, FeeType feeType) external;

    /**
     * @notice Collects a protocol fee split equally between two payers.
     *         First payer is charged floor(rate/2), second payer gets the remainder.
     * @param payer1 First payer (charged floor half)
     * @param payer2 Second payer (charged remainder)
     * @param feeType The category of fee being charged
     */
    function processSplitFee(
        address payer1,
        address payer2,
        FeeType feeType
    ) external;

    /**
     * @notice Permissionless funding of any leaderboard's prize pool
     * @param leaderboardId The leaderboard to fund
     * @param amount Amount of USDC to deposit
     */
    function fundLeaderboard(uint256 leaderboardId, uint256 amount) external;

    /**
     * @notice Collects a leaderboard entry fee and adds it to the prize pool
     * @param payer The address paying the entry fee
     * @param amount The entry fee amount in USDC
     * @param leaderboardId The leaderboard receiving the entry
     */
    function processLeaderboardEntryFee(
        address payer,
        uint256 amount,
        uint256 leaderboardId
    ) external;

    /**
     * @notice Transfers prize pool funds to a winner. Only callable by LeaderboardModule.
     * @param leaderboardId The leaderboard to claim from
     * @param to The recipient address
     * @param amount The amount to disburse in USDC
     */
    function claimPrizePool(
        uint256 leaderboardId,
        address to,
        uint256 amount
    ) external;

    /**
     * @notice Returns the fee rate for a given FeeType (USDC token units)
     * @param feeType The category of fee
     * @return rate The fee amount
     */
    function getFeeRate(FeeType feeType) external view returns (uint256 rate);

    /**
     * @notice Returns the current prize pool balance for a leaderboard
     * @param leaderboardId The leaderboard ID
     * @return balance The prize pool balance in USDC
     */
    function getPrizePool(
        uint256 leaderboardId
    ) external view returns (uint256 balance);
}
