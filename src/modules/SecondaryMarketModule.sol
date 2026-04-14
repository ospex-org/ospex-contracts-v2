// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OspexCore} from "../core/OspexCore.sol";
import {
    SaleListing,
    Position,
    PositionType,
    Speculation,
    SpeculationStatus
} from "../core/OspexTypes.sol";
import {ISecondaryMarketModule} from "../interfaces/ISecondaryMarketModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SecondaryMarketModule
 * @notice Handles secondary market trading of matched positions in the Ospex protocol.
 * @dev Sellers list positions at a price. Buyers purchase proportionally (partial buys
 *      preserve the listing ratio). Payment flows through this contract — sellers claim
 *      proceeds separately via claimSaleProceeds(). Position ownership is transferred
 *      atomically via PositionModule.transferPosition().
 */
contract SecondaryMarketModule is ISecondaryMarketModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant SECONDARY_MARKET_MODULE =
        keccak256("SECONDARY_MARKET_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");

    bytes32 public constant EVENT_POSITION_LISTED =
        keccak256("POSITION_LISTED");
    bytes32 public constant EVENT_LISTING_UPDATED =
        keccak256("LISTING_UPDATED");
    bytes32 public constant EVENT_POSITION_SOLD = keccak256("POSITION_SOLD");
    bytes32 public constant EVENT_LISTING_CANCELLED =
        keccak256("LISTING_CANCELLED");
    bytes32 public constant EVENT_SALE_PROCEEDS_CLAIMED =
        keccak256("SALE_PROCEEDS_CLAIMED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when attempting to interact with a non-active listing
    error SecondaryMarketModule__ListingNotActive();
    /// @notice Thrown when a buyer attempts to buy their own listing
    error SecondaryMarketModule__CannotBuyOwnPosition();
    /// @notice Thrown when a seller has no pending proceeds to claim
    error SecondaryMarketModule__NoProceedsAvailable();
    /// @notice Thrown when a requested amount exceeds the position or listing
    error SecondaryMarketModule__AmountAboveMaximum(uint256 amount);
    /// @notice Thrown when the speculation is not in Open status
    error SecondaryMarketModule__SpeculationNotActive();
    /// @notice Thrown when an address parameter is zero
    error SecondaryMarketModule__InvalidAddress();
    /// @notice Thrown when a required amount is zero
    error SecondaryMarketModule__InvalidAmount();
    /// @notice Thrown when the position has already been claimed
    error SecondaryMarketModule__PositionAlreadyClaimed();
    /// @notice Thrown when a required module is not registered in OspexCore
    error SecondaryMarketModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when proportional price calculation rounds to zero
    error SecondaryMarketModule__PurchasePriceZero();

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a position is listed for sale
    event PositionListed(
        uint256 indexed speculationId,
        address indexed seller,
        PositionType positionType,
        uint256 price,
        uint256 riskAmount,
        uint256 profitAmount,
        uint32 timestamp
    );

    /// @notice Emitted when a listing is updated
    event ListingUpdated(
        uint256 indexed speculationId,
        address indexed seller,
        PositionType positionType,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 oldRiskAmount,
        uint256 newRiskAmount,
        uint256 oldProfitAmount,
        uint256 newProfitAmount
    );

    /// @notice Emitted when a position is sold (fully or partially)
    event PositionSold(
        uint256 indexed speculationId,
        address indexed seller,
        PositionType positionType,
        address indexed buyer,
        uint256 riskAmount,
        uint256 profitAmount,
        uint256 purchasePrice
    );

    /// @notice Emitted when a listing is cancelled
    event ListingCancelled(
        uint256 indexed speculationId,
        address indexed seller,
        PositionType positionType
    );

    /// @notice Emitted when sale proceeds are claimed
    event SaleProceedsClaimed(address indexed seller, uint256 amount);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The USDC token contract
    IERC20 public immutable i_token;

    /// @notice Speculation ID → seller → position type → SaleListing
    mapping(uint256 => mapping(address => mapping(PositionType => SaleListing)))
        public s_saleListings;
    /// @notice Seller → pending proceeds from sold positions
    mapping(address => uint256) public s_pendingSaleProceeds;

    // ──────────────────────────── Constructor ──────────────────────────

    /**
     * @notice Deploys the SecondaryMarketModule with immutable configuration
     * @param ospexCore_ The OspexCore contract address
     * @param token_ The USDC token address
     */
    constructor(address ospexCore_, address token_) {
        if (ospexCore_ == address(0) || token_ == address(0))
            revert SecondaryMarketModule__InvalidAddress();
        i_ospexCore = OspexCore(ospexCore_);
        i_token = IERC20(token_);
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return SECONDARY_MARKET_MODULE;
    }

    // ──────────────────────────── Listing ──────────────────────────────

    /// @inheritdoc ISecondaryMarketModule
    function listPositionForSale(
        uint256 speculationId,
        PositionType positionType,
        uint256 price,
        uint256 riskAmount,
        uint256 profitAmount
    ) external override nonReentrant {
        if (price == 0 || riskAmount == 0 || profitAmount == 0)
            revert SecondaryMarketModule__InvalidAmount();

        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);

        if (spec.speculationStatus != SpeculationStatus.Open)
            revert SecondaryMarketModule__SpeculationNotActive();

        Position memory position = IPositionModule(_getModule(POSITION_MODULE))
            .getPosition(speculationId, msg.sender, positionType);

        if (position.claimed)
            revert SecondaryMarketModule__PositionAlreadyClaimed();

        if (riskAmount > position.riskAmount)
            revert SecondaryMarketModule__AmountAboveMaximum(riskAmount);
        if (profitAmount > position.profitAmount)
            revert SecondaryMarketModule__AmountAboveMaximum(profitAmount);

        s_saleListings[speculationId][msg.sender][positionType] = SaleListing({
            price: price,
            riskAmount: riskAmount,
            profitAmount: profitAmount
        });

        emit PositionListed(
            speculationId,
            msg.sender,
            positionType,
            price,
            riskAmount,
            profitAmount,
            uint32(block.timestamp)
        );
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_LISTED,
            abi.encode(
                speculationId,
                msg.sender,
                positionType,
                price,
                riskAmount,
                profitAmount,
                uint32(block.timestamp)
            )
        );
    }

    // ──────────────────────────── Buying ───────────────────────────────

    /**
     * @notice Buys a portion (or all) of a listed position
     * @dev Buyer specifies only riskAmount. profitAmount and purchasePrice are derived
     *      proportionally from the listing, preserving the ratio on partial buys.
     * @param speculationId The speculation ID
     * @param seller The seller address
     * @param positionType The position type
     * @param riskAmount The risk amount the buyer wants to purchase
     */
    function buyPosition(
        uint256 speculationId,
        address seller,
        PositionType positionType,
        uint256 riskAmount
    ) external override nonReentrant {
        if (msg.sender == seller)
            revert SecondaryMarketModule__CannotBuyOwnPosition();

        if (riskAmount == 0) revert SecondaryMarketModule__InvalidAmount();

        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);

        if (spec.speculationStatus != SpeculationStatus.Open)
            revert SecondaryMarketModule__SpeculationNotActive();

        SaleListing storage listing = s_saleListings[speculationId][seller][
            positionType
        ];

        if (listing.riskAmount == 0)
            revert SecondaryMarketModule__ListingNotActive();
        if (riskAmount > listing.riskAmount)
            revert SecondaryMarketModule__AmountAboveMaximum(riskAmount);

        address posModule = _getModule(POSITION_MODULE);

        Position memory pos = IPositionModule(posModule).getPosition(
            speculationId,
            seller,
            positionType
        );
        if (pos.claimed) revert SecondaryMarketModule__PositionAlreadyClaimed();

        uint256 profitAmount = (listing.profitAmount * riskAmount) /
            listing.riskAmount;
        uint256 purchasePrice = (listing.price * riskAmount) /
            listing.riskAmount;

        if (purchasePrice == 0)
            revert SecondaryMarketModule__PurchasePriceZero();

        i_token.safeTransferFrom(msg.sender, address(this), purchasePrice);
        s_pendingSaleProceeds[seller] += purchasePrice;

        IPositionModule(posModule).transferPosition(
            speculationId,
            seller,
            positionType,
            msg.sender,
            riskAmount,
            profitAmount
        );

        if (riskAmount == listing.riskAmount) {
            delete s_saleListings[speculationId][seller][positionType];
        } else {
            listing.riskAmount -= riskAmount;
            listing.profitAmount -= profitAmount;
            listing.price -= purchasePrice;
        }

        emit PositionSold(
            speculationId,
            seller,
            positionType,
            msg.sender,
            riskAmount,
            profitAmount,
            purchasePrice
        );
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_SOLD,
            abi.encode(
                speculationId,
                seller,
                positionType,
                msg.sender,
                riskAmount,
                profitAmount,
                purchasePrice
            )
        );
    }

    // ──────────────────────────── Proceeds ─────────────────────────────

    /// @inheritdoc ISecondaryMarketModule
    function claimSaleProceeds() external override nonReentrant {
        uint256 amount = s_pendingSaleProceeds[msg.sender];
        if (amount == 0) revert SecondaryMarketModule__NoProceedsAvailable();
        s_pendingSaleProceeds[msg.sender] = 0;
        i_token.safeTransfer(msg.sender, amount);
        emit SaleProceedsClaimed(msg.sender, amount);
        i_ospexCore.emitCoreEvent(
            EVENT_SALE_PROCEEDS_CLAIMED,
            abi.encode(msg.sender, amount)
        );
    }

    // ──────────────────────────── Listing Management ──────────────────

    /// @inheritdoc ISecondaryMarketModule
    function cancelListing(
        uint256 speculationId,
        PositionType positionType
    ) external override nonReentrant {
        SaleListing storage listing = s_saleListings[speculationId][msg.sender][
            positionType
        ];

        if (listing.riskAmount == 0)
            revert SecondaryMarketModule__ListingNotActive();

        Position memory position = IPositionModule(_getModule(POSITION_MODULE))
            .getPosition(speculationId, msg.sender, positionType);
        if (position.claimed)
            revert SecondaryMarketModule__PositionAlreadyClaimed();

        delete s_saleListings[speculationId][msg.sender][positionType];

        emit ListingCancelled(speculationId, msg.sender, positionType);
        i_ospexCore.emitCoreEvent(
            EVENT_LISTING_CANCELLED,
            abi.encode(speculationId, msg.sender, positionType)
        );
    }

    /// @inheritdoc ISecondaryMarketModule
    function updateListing(
        uint256 speculationId,
        PositionType positionType,
        uint256 newPrice,
        uint256 newRiskAmount,
        uint256 newProfitAmount
    ) external override nonReentrant {
        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);

        if (spec.speculationStatus != SpeculationStatus.Open)
            revert SecondaryMarketModule__SpeculationNotActive();

        SaleListing storage listing = s_saleListings[speculationId][msg.sender][
            positionType
        ];

        if (listing.riskAmount == 0)
            revert SecondaryMarketModule__ListingNotActive();

        Position memory position = IPositionModule(_getModule(POSITION_MODULE))
            .getPosition(speculationId, msg.sender, positionType);
        if (position.claimed)
            revert SecondaryMarketModule__PositionAlreadyClaimed();

        uint256 oldPrice = listing.price;
        uint256 oldRiskAmount = listing.riskAmount;
        uint256 oldProfitAmount = listing.profitAmount;

        if (newPrice > 0) {
            listing.price = newPrice;
        }
        if (newRiskAmount > 0) {
            if (newRiskAmount > position.riskAmount)
                revert SecondaryMarketModule__AmountAboveMaximum(newRiskAmount);
            listing.riskAmount = newRiskAmount;
        }
        if (newProfitAmount > 0) {
            if (newProfitAmount > position.profitAmount)
                revert SecondaryMarketModule__AmountAboveMaximum(
                    newProfitAmount
                );
            listing.profitAmount = newProfitAmount;
        }

        emit ListingUpdated(
            speculationId,
            msg.sender,
            positionType,
            oldPrice,
            listing.price,
            oldRiskAmount,
            listing.riskAmount,
            oldProfitAmount,
            listing.profitAmount
        );
        i_ospexCore.emitCoreEvent(
            EVENT_LISTING_UPDATED,
            abi.encode(
                speculationId,
                msg.sender,
                positionType,
                oldPrice,
                listing.price,
                oldRiskAmount,
                listing.riskAmount,
                oldProfitAmount,
                listing.profitAmount
            )
        );
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc ISecondaryMarketModule
    function getSaleListing(
        uint256 speculationId,
        address seller,
        PositionType positionType
    ) external view override returns (SaleListing memory listing) {
        return s_saleListings[speculationId][seller][positionType];
    }

    /// @inheritdoc ISecondaryMarketModule
    function getPendingSaleProceeds(
        address seller
    ) external view override returns (uint256 amount) {
        return s_pendingSaleProceeds[seller];
    }

    // ──────────────────────────── Module Lookup ───────────────────────

    /**
     * @notice Resolves a module address from OspexCore, reverting if not set
     * @param moduleType The module type identifier
     * @return module The module contract address
     */
    function _getModule(
        bytes32 moduleType
    ) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) {
            revert SecondaryMarketModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
