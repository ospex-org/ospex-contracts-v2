// SPDX-License-Identifier: BUSL-1.1
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
     * @param positionType Position type
     * @param price Price in token
     * @param riskAmount Amount of risk of position for sale
     * @param profitAmount Amount of profit of position for sale
     * @param contributionAmount Amount to contribute for listing priority
     */
    function listPositionForSale(
        uint256 speculationId,
        PositionType positionType,
        uint256 price,
        uint256 riskAmount,
        uint256 profitAmount,
        uint256 contributionAmount
    ) external;

    /**
     * @notice Buys a listed position from another user
     * @param speculationId Speculation ID
     * @param seller Address of the position seller
     * @param positionType Position type
     * @param riskAmount Risk amount of position to buy
     */
    function buyPosition(
        uint256 speculationId,
        address seller,
        PositionType positionType,
        uint256 riskAmount
    ) external;

    /**
     * @notice Claims proceeds from sold positions
     */
    function claimSaleProceeds() external;

    /**
     * @notice Cancels an active sale listing
     * @param speculationId Speculation ID
     * @param positionType Position type
     */
    function cancelListing(
        uint256 speculationId,
        PositionType positionType
    ) external;

    /**
     * @notice Updates an existing sale listing
     * @param speculationId Speculation ID
     * @param positionType Position type
     * @param newPrice New price for the listing
     * @param newRiskAmount New risk amount for sale
     * @param newProfitAmount New profit amount for sale
     */
    function updateListing(
        uint256 speculationId,
        PositionType positionType,
        uint256 newPrice,
        uint256 newRiskAmount,
        uint256 newProfitAmount
    ) external;

    /**
     * @notice Sets the minimum sale amount
     * @param newMinSaleAmount New minimum sale amount
     */ 
    function setMinSaleAmount(uint256 newMinSaleAmount) external;

    /**
     * @notice Returns the sale listing for a given position
     * @param speculationId Speculation ID
     * @param seller Seller address
     * @param positionType Position type
     * @return listing The SaleListing struct
     */
    function getSaleListing(
        uint256 speculationId,
        address seller,
        PositionType positionType
    ) external view returns (SaleListing memory listing);

    /**
     * @notice Returns the pending sale proceeds for a seller
     * @param seller Seller address
     * @return amount Pending proceeds
     */
    function getPendingSaleProceeds(address seller) external view returns (uint256 amount);
} 