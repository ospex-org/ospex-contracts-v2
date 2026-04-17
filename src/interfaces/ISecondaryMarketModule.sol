// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {SaleListing, PositionType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title ISecondaryMarketModule
 * @notice Interface for the Ospex SecondaryMarketModule. Handles listing, buying,
 *         updating, and canceling sales of matched positions.
 */
interface ISecondaryMarketModule is IModule {
    /// @notice Lists a portion of a matched position for sale
    /// @param speculationId The speculation ID
    /// @param positionType The position type
    /// @param price The asking price in USDC
    /// @param riskAmount The risk amount being listed
    /// @param profitAmount The profit amount being listed
    function listPositionForSale(
        uint256 speculationId,
        PositionType positionType,
        uint256 price,
        uint256 riskAmount,
        uint256 profitAmount
    ) external;

    /// @notice Buys a portion (or all) of a listed position
    /// @dev profitAmount and purchasePrice are derived proportionally from the listing
    /// @dev expectedHash must match the current listing state
    /// @param speculationId The speculation ID
    /// @param seller The seller address
    /// @param positionType The position type
    /// @param riskAmount The risk amount to purchase
    /// @param expectedHash The expected listing state hash
    function buyPosition(
        uint256 speculationId,
        address seller,
        PositionType positionType,
        uint256 riskAmount,
        bytes32 expectedHash
    ) external;

    /// @notice Claims accumulated proceeds from sold positions
    function claimSaleProceeds() external;

    /// @notice Cancels an active sale listing
    /// @param speculationId The speculation ID
    /// @param positionType The position type
    function cancelListing(
        uint256 speculationId,
        PositionType positionType
    ) external;

    /// @notice Updates an existing sale listing with new price and/or amounts
    /// @dev Pass 0 for any field to keep the current value
    /// @param speculationId The speculation ID
    /// @param positionType The position type
    /// @param newPrice New price (0 to keep current)
    /// @param newRiskAmount New risk amount (0 to keep current)
    /// @param newProfitAmount New profit amount (0 to keep current)
    function updateListing(
        uint256 speculationId,
        PositionType positionType,
        uint256 newPrice,
        uint256 newRiskAmount,
        uint256 newProfitAmount
    ) external;

    /// @notice Returns the sale listing for a given position
    /// @param speculationId The speculation ID
    /// @param seller The seller address
    /// @param positionType The position type
    /// @return listing The SaleListing struct
    function getSaleListing(
        uint256 speculationId,
        address seller,
        PositionType positionType
    ) external view returns (SaleListing memory listing);

    /// @notice Returns pending sale proceeds for a seller
    /// @param seller The seller address
    /// @return amount Pending proceeds in USDC
    function getPendingSaleProceeds(
        address seller
    ) external view returns (uint256 amount);

    /// @notice Returns the current hash of a listing's state for use as expectedHash in buyPosition
    /// @param speculationId The speculation ID
    /// @param seller The seller address
    /// @param positionType The position type
    /// @return The keccak256 hash of the listing's current state
    function getListingHash(
        uint256 speculationId,
        address seller,
        PositionType positionType
    ) external view returns (bytes32);
}
