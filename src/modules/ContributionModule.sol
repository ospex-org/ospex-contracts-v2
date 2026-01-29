// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IModule} from "../interfaces/IModule.sol";
import {IContributionModule} from "../interfaces/IContributionModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {PositionType} from "../core/OspexTypes.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ContributionModule
 * @notice Centralizes all contribution logic for the Ospex protocol
 * @dev Handles contribution token/receiver, transfers, and events. Called by other modules.
 */
contract ContributionModule is IContributionModule, IModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    /// @notice Error for invalid address
    error ContributionModule__InvalidAddress();
    /// @notice Error for not admin
    error ContributionModule__NotAdmin(address admin);
    /// @notice Error for not authorized
    error ContributionModule__NotAuthorized(address caller);
    /// @notice Error for invalid amount
    error ContributionModule__InvalidAmount();

    // --- Storage ---
    /// @notice The Ospex core contract
    OspexCore public immutable i_ospexCore;
    /// @notice The contribution token
    IERC20 public s_contributionToken;
    /// @notice The contribution receiver
    address public s_contributionReceiver;

    // --- Events ---
    /**
     * @notice Emitted when a contribution is made
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param contributionAmount The amount of the contribution
     */
    event ContributionMade(
        uint256 indexed speculationId,
        address indexed user,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 contributionAmount
    );
    /**
     * @notice Emitted when the contribution token is set
     * @param newToken The address of the new contribution token
     */
    event ContributionTokenSet(address newToken);
    /**
     * @notice Emitted when the contribution receiver is set
     * @param newReceiver The address of the new contribution receiver
     */
    event ContributionReceiverSet(address newReceiver);

    /**
     * @notice Modifier to ensure the caller is an admin
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert ContributionModule__NotAdmin(msg.sender);
        }
        _;
    }

    modifier onlyAuthorizedCaller() {
        if (
            !i_ospexCore.isRegisteredModule(msg.sender) &&
            !i_ospexCore.hasMarketRole(msg.sender)
        ) {
            revert ContributionModule__NotAuthorized(msg.sender);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor for the contribution module
     * @param ospexCore The address of the Ospex core contract
     */
    constructor(address ospexCore) {
        if (ospexCore == address(0))
            revert ContributionModule__InvalidAddress();
        i_ospexCore = OspexCore(ospexCore);
    }

    // --- IModule ---
    /**
     * @notice Gets the module type
     * @return moduleType The module type
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("CONTRIBUTION_MODULE");
    }

    // --- Admin Setters (only core can call) ---
    /**
     * @notice Sets the contribution token
     * @param newToken The address of the new contribution token
     */
    function setContributionToken(
        address newToken
    ) external override onlyAdmin {
        s_contributionToken = IERC20(newToken);
        emit ContributionTokenSet(newToken);
        i_ospexCore.emitCoreEvent(
            keccak256("CONTRIBUTION_TOKEN_SET"),
            abi.encode(newToken)
        );
    }
    /**
     * @notice Sets the contribution receiver
     * @param newReceiver The address of the new contribution receiver
     */
    function setContributionReceiver(
        address newReceiver
    ) external override onlyAdmin {
        s_contributionReceiver = newReceiver;
        emit ContributionReceiverSet(newReceiver);
        i_ospexCore.emitCoreEvent(
            keccak256("CONTRIBUTION_RECEIVER_SET"),
            abi.encode(newReceiver)
        );
    }

    // --- Contribution Handler ---
    /**
     * @notice Handles a contribution
     * @param speculationId The ID of the speculation
     * @param contributor The address of the contributor
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param contributionAmount The amount of the contribution
     */
    function handleContribution(
        uint256 speculationId,
        address contributor,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 contributionAmount
    ) external override onlyAuthorizedCaller nonReentrant {
        if (contributionAmount > 0) {
            if (
                address(s_contributionToken) == address(0) ||
                s_contributionReceiver == address(0)
            ) {
                revert ContributionModule__InvalidAddress();
            }
            s_contributionToken.safeTransferFrom(
                contributor,
                s_contributionReceiver,
                contributionAmount
            );
            emit ContributionMade(
                speculationId,
                contributor,
                oddsPairId,
                positionType,
                contributionAmount
            );
            // Emit protocol-wide core event
            i_ospexCore.emitCoreEvent(
                keccak256("CONTRIBUTION_MADE"),
                abi.encode(
                    speculationId,
                    contributor,
                    oddsPairId,
                    positionType,
                    contributionAmount
                )
            );
        }
    }
}
