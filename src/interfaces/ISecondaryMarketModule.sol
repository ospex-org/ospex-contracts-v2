// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SaleListing, PositionType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title ISecondaryMarketModule
 * @notice Interface for the SecondaryMarketModule in the Ospex protocol
 * @dev Handles listing, buying, updating, and canceling sales of matched positions
 */
interface ISecondaryMarketModule is IModule {
    /**
     * @notice Lists a portion of a matched position for sale
     * @param speculationId Speculation ID
     * @param oddsPairId ID of the odds pair
     * @param positionType Position type
     * @param price Price in token
     * @param amount Amount of position to sell (0 for full amount)
     * @param contributionAmount Amount to contribute for listing priority
     */
    function listPositionForSale(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 price,
        uint256 amount,
        uint256 contributionAmount
    ) external;

    /**
     * @notice Buys a listed position from another user
     * @param speculationId Speculation ID
     * @param seller Address of the position seller
     * @param oddsPairId ID of the odds pair
     * @param positionType Position type
     * @param amount Amount of position to buy
     */
    function buyPosition(
        uint256 speculationId,
        address seller,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 amount
    ) external;

    /**
     * @notice Claims proceeds from sold positions
     */
    function claimSaleProceeds() external;

    /**
     * @notice Cancels an active sale listing
     * @param speculationId Speculation ID
     * @param oddsPairId ID of the odds pair
     * @param positionType Position type
     */
    function cancelListing(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType
    ) external;

    /**
     * @notice Updates an existing sale listing
     * @param speculationId Speculation ID
     * @param oddsPairId Odds pair ID
     * @param positionType Position type
     * @param newPrice New price for the listing (0 to keep current)
     * @param newAmount New amount for sale (0 to keep current)
     */
    function updateListing(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 newPrice,
        uint256 newAmount
    ) external;

    /**
     * @notice Sets the minimum sale amount
     * @param newMinSaleAmount New minimum sale amount
     */ 
    function setMinSaleAmount(uint256 newMinSaleAmount) external;

    /**
     * @notice Sets the maximum sale amount
     * @param newMaxSaleAmount New maximum sale amount
     */
    function setMaxSaleAmount(uint256 newMaxSaleAmount) external;

    /**
     * @notice Returns the sale listing for a given position
     * @param speculationId Speculation ID
     * @param seller Seller address
     * @param oddsPairId Odds pair ID
     * @param positionType Position type
     * @return listing The SaleListing struct
     */
    function getSaleListing(
        uint256 speculationId,
        address seller,
        uint128 oddsPairId,
        PositionType positionType
    ) external view returns (SaleListing memory listing);

    /**
     * @notice Returns the pending sale proceeds for a seller
     * @param seller Seller address
     * @return amount Pending proceeds
     */
    function getPendingSaleProceeds(address seller) external view returns (uint256 amount);
} 