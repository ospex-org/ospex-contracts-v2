// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
import {IContributionModule} from "../interfaces/IContributionModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SecondaryMarketModule
 * @notice Handles secondary market trading of matched positions in Ospex protocol
 * @dev Implements the minimal core + plug-in modules pattern. Uses hybrid event emission.
 */
contract SecondaryMarketModule is ISecondaryMarketModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    /// @notice Error for not admin
    error SecondaryMarketModule__NotAdmin(address admin);
    /// @notice Error for sale amount below minimum
    error SecondaryMarketModule__SaleAmountBelowMinimum(uint256 amount);
    /// @notice Error for sale amount above maximum
    error SecondaryMarketModule__SaleAmountAboveMaximum(uint256 amount);
    /// @notice Error for listing not active
    error SecondaryMarketModule__ListingNotActive();
    /// @notice Error for cannot buy own position
    error SecondaryMarketModule__CannotBuyOwnPosition();
    /// @notice Error for position does not exist
    error SecondaryMarketModule__PositionDoesNotExist();
    /// @notice Error for no matched amount
    error SecondaryMarketModule__NoMatchedAmount();
    /// @notice Error for no proceeds available
    error SecondaryMarketModule__NoProceedsAvailable();
    /// @notice Error for amount above maximum
    error SecondaryMarketModule__AmountAboveMaximum(uint256 amount);
    /// @notice Error for speculation not active
    error SecondaryMarketModule__SpeculationNotActive();
    /// @notice Error for invalid min sale amount
    error SecondaryMarketModule__InvalidMinSaleAmount();
    /// @notice Error for invalid max sale amount
    error SecondaryMarketModule__InvalidMaxSaleAmount();
    /// @notice Error for invalid address
    error SecondaryMarketModule__InvalidAddress();
    /// @notice Error for invalid price
    error SecondaryMarketModule__InvalidPrice();
    /// @notice Error for position already claimed
    error SecondaryMarketModule__PositionAlreadyClaimed();
    /// @notice Error for module not set
    error SecondaryMarketModule__ModuleNotSet(bytes32 moduleType);

    // --- Storage ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The ERC20 token
    IERC20 public immutable i_token;
    /// @notice The minimum sale amount
    uint256 public s_minSaleAmount;
    /// @notice The maximum sale amount
    uint256 public s_maxSaleAmount;

    // speculationId => seller => oddsPairId => positionType => SaleListing
    mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => SaleListing))))
        public s_saleListings;
    // seller => amount
    mapping(address => uint256) public s_pendingSaleProceeds;

    // --- Events (module-local) ---
    /**
     * @notice Emitted when a matched position is listed for sale
     * @param speculationId The ID of the speculation
     * @param seller The address of the seller
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param amount The amount of the position
     * @param price The price of the position
     * @param timestamp The timestamp of the listing
     */
    event PositionListed(
        uint256 indexed speculationId,
        address indexed seller,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 amount,
        uint256 price,
        uint32 timestamp
    );
    /**
     * @notice Emitted when a listing is updated
     * @param speculationId The ID of the speculation
     * @param seller The address of the seller
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param oldPrice The old price of the position
     * @param newPrice The new price of the position
     * @param oldAmount The old amount of the position
     * @param newAmount The new amount of the position
     */
    event ListingUpdated(
        uint256 indexed speculationId,
        address indexed seller,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 oldAmount,
        uint256 newAmount
    );
    /**
     * @notice Emitted when a position is sold
     * @param speculationId The ID of the speculation
     * @param seller The address of the seller
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param buyer The address of the buyer
     * @param amount The amount of the position
     */
    event PositionSold(
        uint256 indexed speculationId,
        address indexed seller,
        uint128 oddsPairId,
        PositionType positionType,
        address indexed buyer,
        uint256 amount
    );
    /**
     * @notice Emitted when a listing is cancelled
     * @param speculationId The ID of the speculation
     * @param seller The address of the seller
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     */
    event ListingCancelled(
        uint256 indexed speculationId,
        address indexed seller,
        uint128 oddsPairId,
        PositionType positionType
    );
    /**
     * @notice Emitted when sale proceeds are claimed
     * @param seller The address of the seller
     * @param amount The amount of the sale proceeds
     */
    event SaleProceedsClaimed(address indexed seller, uint256 amount);
    /**
     * @notice Emitted when the minimum sale amount is set
     * @param newMinSaleAmount The new minimum sale amount
     */
    event MinSaleAmountSet(uint256 newMinSaleAmount);
    /**
     * @notice Emitted when the maximum sale amount is set
     * @param newMaxSaleAmount The new maximum sale amount
     */
    event MaxSaleAmountSet(uint256 newMaxSaleAmount);

    // --- Modifiers ---
    /**
     * @notice Modifier to restrict function to only the OspexCore contract
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert SecondaryMarketModule__NotAdmin(msg.sender);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor for the SecondaryMarketModule
     * @param ospexCore The address of the OspexCore contract
     * @param token The address of the ERC20 token
     * @param minSaleAmount The minimum sale amount
     * @param maxSaleAmount The maximum sale amount
     */
    constructor(
        address ospexCore,
        address token,
        uint256 minSaleAmount,
        uint256 maxSaleAmount
    ) {
        if (ospexCore == address(0) || token == address(0))
            revert SecondaryMarketModule__InvalidAddress();
        if (minSaleAmount == 0)
            revert SecondaryMarketModule__InvalidMinSaleAmount();
        if (maxSaleAmount == 0)
            revert SecondaryMarketModule__InvalidMaxSaleAmount();
        i_ospexCore = OspexCore(ospexCore);
        i_token = IERC20(token);
        s_minSaleAmount = minSaleAmount;
        s_maxSaleAmount = maxSaleAmount;
    }

    // --- IModule ---
    /**
     * @notice Returns the module type
     * @return moduleType The module type
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("SECONDARY_MARKET_MODULE");
    }

    // --- ISecondaryMarketModule ---
    /**
     * @notice Lists a position for sale
     * @param speculationId The ID of the speculation
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param price The price of the position
     * @param amount The amount of the position
     * @param contributionAmount The amount of contribution
     */
    function listPositionForSale(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 price,
        uint256 amount,
        uint256 contributionAmount
    ) external override nonReentrant {
        if (price == 0) revert SecondaryMarketModule__InvalidPrice();
        Speculation memory spec = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);
        if (spec.speculationStatus != SpeculationStatus.Open)
            revert SecondaryMarketModule__SpeculationNotActive();
        Position memory position = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        ).getPosition(speculationId, msg.sender, oddsPairId, positionType);
        if (position.matchedAmount == 0)
            revert SecondaryMarketModule__NoMatchedAmount();
        // If amount is 0, set sale amount to matched amount
        uint256 saleAmount = amount == 0 ? position.matchedAmount : amount;

        if (saleAmount < s_minSaleAmount)
            revert SecondaryMarketModule__SaleAmountBelowMinimum(saleAmount);
        if (saleAmount > s_maxSaleAmount)
            revert SecondaryMarketModule__SaleAmountAboveMaximum(saleAmount);
        if (saleAmount > position.matchedAmount)
            revert SecondaryMarketModule__AmountAboveMaximum(saleAmount);

        if (contributionAmount > 0) {
            IContributionModule(_getModule(keccak256("CONTRIBUTION_MODULE")))
                .handleContribution(
                    speculationId,
                    msg.sender,
                    oddsPairId,
                    positionType,
                    contributionAmount
                );
        }

        s_saleListings[speculationId][msg.sender][oddsPairId][
            positionType
        ] = SaleListing({price: price, amount: saleAmount});

        emit PositionListed(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType,
            saleAmount,
            price,
            uint32(block.timestamp)
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_LISTED"),
            abi.encode(
                speculationId,
                msg.sender,
                oddsPairId,
                positionType,
                saleAmount,
                price,
                uint32(block.timestamp)
            )
        );
    }

    /**
     * @notice Buys a position from a seller
     * @param speculationId The ID of the speculation
     * @param seller The address of the seller
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param amount The amount of the position
     */
    function buyPosition(
        uint256 speculationId,
        address seller,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 amount
    ) external override nonReentrant {
        if (msg.sender == seller)
            revert SecondaryMarketModule__CannotBuyOwnPosition();

        if (amount == 0)
            revert SecondaryMarketModule__SaleAmountBelowMinimum(amount);

        Speculation memory spec = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);

        if (spec.speculationStatus != SpeculationStatus.Open)
            revert SecondaryMarketModule__SpeculationNotActive();

        SaleListing storage listing = s_saleListings[speculationId][seller][
            oddsPairId
        ][positionType];

        if (listing.amount < s_minSaleAmount)
            revert SecondaryMarketModule__ListingNotActive();

        if (amount > listing.amount)
            revert SecondaryMarketModule__AmountAboveMaximum(amount);

        uint256 purchasePrice = (listing.price * amount) / listing.amount;
        i_token.safeTransferFrom(msg.sender, address(this), purchasePrice);
        s_pendingSaleProceeds[seller] += purchasePrice;

        IPositionModule(_getModule(keccak256("POSITION_MODULE")))
            .transferPosition(
                speculationId,
                seller,
                oddsPairId,
                positionType,
                msg.sender,
                amount
            );

        if (amount == listing.amount) {
            delete s_saleListings[speculationId][seller][oddsPairId][
                positionType
            ];
        } else {
            listing.amount -= amount;
            listing.price -= purchasePrice;
        }

        emit PositionSold(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            msg.sender,
            amount
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_SOLD"),
            abi.encode(
                speculationId,
                seller,
                oddsPairId,
                positionType,
                msg.sender,
                amount
            )
        );
    }

    /**
     * @notice Claims sale proceeds
     */
    function claimSaleProceeds() external override nonReentrant {
        uint256 amount = s_pendingSaleProceeds[msg.sender];
        if (amount == 0) revert SecondaryMarketModule__NoProceedsAvailable();
        s_pendingSaleProceeds[msg.sender] = 0;
        i_token.safeTransfer(msg.sender, amount);
        emit SaleProceedsClaimed(msg.sender, amount);
        i_ospexCore.emitCoreEvent(
            keccak256("SALE_PROCEEDS_CLAIMED"),
            abi.encode(msg.sender, amount)
        );
    }

    /**
     * @notice Cancels a listing
     * @param speculationId The ID of the speculation
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     */
    function cancelListing(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType
    ) external override nonReentrant {
        SaleListing storage listing = s_saleListings[speculationId][msg.sender][
            oddsPairId
        ][positionType];

        if (listing.amount < s_minSaleAmount)
            revert SecondaryMarketModule__ListingNotActive();

        Position memory position = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        ).getPosition(speculationId, msg.sender, oddsPairId, positionType);
        if (position.poolId == 0)
            revert SecondaryMarketModule__PositionDoesNotExist();
        if (position.claimed)
            revert SecondaryMarketModule__PositionAlreadyClaimed();

        delete s_saleListings[speculationId][msg.sender][oddsPairId][
            positionType
        ];

        emit ListingCancelled(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType
        );
        i_ospexCore.emitCoreEvent(
            keccak256("LISTING_CANCELLED"),
            abi.encode(speculationId, msg.sender, oddsPairId, positionType)
        );
    }

    /**
     * @notice Updates a listing
     * @param speculationId The ID of the speculation
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param newPrice The new price of the position
     * @param newAmount The new amount of the position
     */
    function updateListing(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 newPrice,
        uint256 newAmount
    ) external override nonReentrant {
        Speculation memory spec = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);

        if (spec.speculationStatus != SpeculationStatus.Open)
            revert SecondaryMarketModule__SpeculationNotActive();

        SaleListing storage listing = s_saleListings[speculationId][msg.sender][
            oddsPairId
        ][positionType];

        if (listing.amount < s_minSaleAmount)
            revert SecondaryMarketModule__ListingNotActive();

        Position memory position = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        ).getPosition(speculationId, msg.sender, oddsPairId, positionType);
        if (position.poolId == 0)
            revert SecondaryMarketModule__PositionDoesNotExist();
        if (position.claimed)
            revert SecondaryMarketModule__PositionAlreadyClaimed();

        uint256 oldPrice = listing.price;
        uint256 oldAmount = listing.amount;

        if (newPrice > 0) {
            listing.price = newPrice;
        }

        if (newAmount > 0) {
            if (newAmount > position.matchedAmount)
                revert SecondaryMarketModule__AmountAboveMaximum(newAmount);
            if (newAmount < s_minSaleAmount)
                revert SecondaryMarketModule__SaleAmountBelowMinimum(newAmount);
            if (newAmount > s_maxSaleAmount)
                revert SecondaryMarketModule__SaleAmountAboveMaximum(newAmount);
            listing.amount = newAmount;
        }

        emit ListingUpdated(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType,
            oldPrice,
            listing.price,
            oldAmount,
            listing.amount
        );
        i_ospexCore.emitCoreEvent(
            keccak256("LISTING_UPDATED"),
            abi.encode(
                speculationId,
                msg.sender,
                oddsPairId,
                positionType,
                oldPrice,
                listing.price,
                oldAmount,
                listing.amount
            )
        );
    }

    /**
     * @notice Sets the minimum sale amount
     * @param newMinSaleAmount The new minimum sale amount
     */
    function setMinSaleAmount(
        uint256 newMinSaleAmount
    ) external override onlyAdmin {
        if (newMinSaleAmount == 0)
            revert SecondaryMarketModule__InvalidMinSaleAmount();
        s_minSaleAmount = newMinSaleAmount;
        emit MinSaleAmountSet(newMinSaleAmount);
        i_ospexCore.emitCoreEvent(
            keccak256("MIN_SALE_AMOUNT_SET"),
            abi.encode(newMinSaleAmount)
        );
    }

    /**
     * @notice Sets the maximum sale amount
     * @param newMaxSaleAmount The new maximum sale amount
     */
    function setMaxSaleAmount(
        uint256 newMaxSaleAmount
    ) external override onlyAdmin {
        if (newMaxSaleAmount == 0)
            revert SecondaryMarketModule__InvalidMaxSaleAmount();
        s_maxSaleAmount = newMaxSaleAmount;
        emit MaxSaleAmountSet(newMaxSaleAmount);
        i_ospexCore.emitCoreEvent(
            keccak256("MAX_SALE_AMOUNT_SET"),
            abi.encode(newMaxSaleAmount)
        );
    }

    // --- View Functions ---
    /**
     * @notice Gets a sale listing
     * @param speculationId The ID of the speculation
     * @param seller The address of the seller
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     */
    function getSaleListing(
        uint256 speculationId,
        address seller,
        uint128 oddsPairId,
        PositionType positionType
    ) external view override returns (SaleListing memory listing) {
        return s_saleListings[speculationId][seller][oddsPairId][positionType];
    }

    /**
     * @notice Gets the pending sale proceeds
     * @param seller The address of the seller
     */
    function getPendingSaleProceeds(
        address seller
    ) external view override returns (uint256 amount) {
        return s_pendingSaleProceeds[seller];
    }

    // --- Helper Function for Module Lookups ---
    /**
     * @notice Gets the module address
     * @param moduleType The type of module
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
