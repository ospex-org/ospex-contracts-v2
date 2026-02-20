// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {FeeType, Leaderboard} from "../core/OspexTypes.sol";

/**
 * @title TreasuryModule
 * @notice Centralizes all fee logic for the Ospex protocol
 * @dev Handles fee collection, routing, and allocation for contest creation, speculation creation, and leaderboard entry.
 */
contract TreasuryModule is ITreasuryModule {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    /// @notice TreasuryModule__NotCore is thrown when a non-core module attempts to call the TreasuryModule
    error TreasuryModule__NotCore();
    /// @notice TreasuryModule__NotLeaderboardModule is thrown when a non-leaderboard module attempts to call the TreasuryModule
    error TreasuryModule__NotLeaderboardModule();
    /// @notice TreasuryModule__NotAdmin is thrown when a non-admin module attempts to call the TreasuryModule
    error TreasuryModule__NotAdmin(address admin);
    /// @notice TreasuryModule__InvalidReceiver is thrown when an invalid receiver is set
    error TreasuryModule__InvalidReceiver();
    /// @notice TreasuryModule__InvalidAllocation is thrown when an invalid allocation is attempted
    error TreasuryModule__InvalidAllocation();
    /// @notice TreasuryModule__InsufficientBalance is thrown when an insufficient balance is attempted
    error TreasuryModule__InsufficientBalance();

    // --- Storage ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The token contract
    IERC20 public immutable i_token;
    /// @notice FeeType => rate (token units or bps, per config)
    mapping(FeeType => uint256) public s_feeRates;
    /// @notice Protocol cut in basis points (e.g., 500 = 5%)
    uint256 public s_protocolCutBps;
    /// @notice Protocol revenue receiver
    address public s_protocolReceiver;
    /// @notice LeaderboardId => prize pool balance
    mapping(uint256 => uint256) public s_leaderboardPrizePools;

    // --- Constants ---
    /// @notice The maximum basis points (10000 = 100%)
    uint256 public constant MAX_BPS = 10_000;

    // --- Events ---
    /**
     * @notice Comprehensive event emitted when any fee is processed
     * @param payer The address that paid the fee
     * @param feeType The type of fee
     * @param totalAmount The total fee amount
     * @param protocolCut The amount that went to protocol receiver
     * @param leaderboardId The intended leaderboard ID
     * @param leaderboardAllocation The amount allocated to leaderboard (0 if invalid)
     * @param protocolFallback The additional amount sent to protocol due to invalid leaderboard
     * @param leaderboardValid Whether the leaderboard was valid
     */
    event FeeProcessed(
        address indexed payer,
        FeeType indexed feeType,
        uint256 totalAmount,
        uint256 protocolCut,
        uint256 indexed leaderboardId,
        uint256 leaderboardAllocation,
        uint256 protocolFallback,
        bool leaderboardValid
    );

    event LeaderboardEntryFeeProcessed(
        address indexed payer,
        uint256 totalAmount,
        uint256 protocolCut,
        uint256 indexed leaderboardId,
        uint256 leaderboardAllocation
    );
    /**
     * @notice Emitted when a fee rate is set
     * @param feeType The type of fee
     * @param newRate The new fee rate
     */
    event FeeRateSet(FeeType feeType, uint256 newRate);
    /**
     * @notice Emitted when protocol cut is set
     * @param newCutBps The new protocol cut in basis points
     */
    event ProtocolCutSet(uint256 newCutBps);
    /**
     * @notice Emitted when protocol receiver is set
     * @param newReceiver The new protocol receiver address
     */
    event ProtocolReceiverSet(address newReceiver);
    /**
     * @notice Emitted when a prize pool is claimed
     * @param leaderboardId The leaderboard ID
     * @param to The address to which the prize pool is transferred
     * @param amount The amount of prize pool claimed
     */
    event PrizePoolClaimed(
        uint256 indexed leaderboardId,
        address indexed to,
        uint256 amount
    );

    // --- Modifiers ---
    /// @notice Modifier to ensure only the OspexCore contract can call the function
    /// @dev This is to prevent any module from calling the TreasuryModule directly
    modifier onlyCore() {
        if (msg.sender != address(i_ospexCore))
            revert TreasuryModule__NotCore();
        _;
    }

    /// @notice Modifier to ensure only the LeaderboardModule contract can call the function
    modifier onlyLeaderboardModule() {
        if (msg.sender != address(i_ospexCore.getModule(keccak256("LEADERBOARD_MODULE"))))
            revert TreasuryModule__NotLeaderboardModule();
        _;
    }

    /// @notice Modifier to ensure only the admin can call the function
    /// @dev This is to prevent any module from calling the TreasuryModule directly
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert TreasuryModule__NotAdmin(msg.sender);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor for the TreasuryModule
     * @param ospexCore_ The OspexCore contract address
     * @param token_ The token contract address
     * @param protocolReceiver_ The protocol revenue receiver address
     */
    constructor(address ospexCore_, address token_, address protocolReceiver_) {
        if (
            ospexCore_ == address(0) ||
            token_ == address(0) ||
            protocolReceiver_ == address(0)
        ) revert TreasuryModule__InvalidReceiver();
        i_ospexCore = OspexCore(ospexCore_);
        i_token = IERC20(token_);
        s_protocolReceiver = protocolReceiver_;
        s_protocolCutBps = 0; // Default to 0, settable by admin
    }

    /**
     * @notice Returns the module type identifier
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("TREASURY_MODULE");
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Handles the fee for a given fee type
     * @param payer The address that paid the fee
     * @param amount The amount of fee
     * @param feeType The type of fee
     * @param leaderboardId The leaderboard ID
     */
    function processFee(
        address payer,
        uint256 amount,
        FeeType feeType,
        uint256 leaderboardId
    ) external override onlyCore {
        uint256 feeRate = s_feeRates[feeType];

        // If fee rate is 0, fees are disabled for this type - just return
        if (feeRate == 0) {
            return;
        }

        if (amount == 0) revert TreasuryModule__InvalidAllocation();

        // Calculate protocol cut
        uint256 protocolCut = (amount * s_protocolCutBps) / MAX_BPS;
        uint256 remaining = amount - protocolCut;

        // Initialize tracking variables - default to protocol fallback
        uint256 leaderboardAllocation = 0;
        uint256 protocolFallback = remaining; // Default: send to protocol
        bool leaderboardValid = false;

        // Transfer fee from payer
        i_token.safeTransferFrom(payer, address(this), amount);

        // Transfer protocol cut
        if (protocolCut > 0) {
            i_token.safeTransfer(s_protocolReceiver, protocolCut);
        }

        // Check if leaderboard is valid and allocate accordingly
        Leaderboard memory leaderboard = ILeaderboardModule(
            i_ospexCore.getModule(keccak256("LEADERBOARD_MODULE"))
        ).getLeaderboard(leaderboardId);

        if (leaderboard.startTime > 0 && leaderboardId > 0) {
            // Valid leaderboard - override default fallback behavior
            leaderboardValid = true;
            leaderboardAllocation = remaining;
            protocolFallback = 0; // Reset since we're allocating to leaderboard
            s_leaderboardPrizePools[leaderboardId] += remaining;
        }
        // Invalid/missing leaderboard: keep default protocol fallback

        // Send remaining funds to protocol if not allocated to leaderboard
        if (protocolFallback > 0) {
            i_token.safeTransfer(s_protocolReceiver, protocolFallback);
        }

        emit FeeProcessed(
            payer,
            feeType,
            amount,
            protocolCut,
            leaderboardId,
            leaderboardAllocation,
            protocolFallback,
            leaderboardValid
        );
        i_ospexCore.emitCoreEvent(
            keccak256("FEE_PROCESSED"),
            abi.encode(
                payer,
                feeType,
                amount,
                protocolCut,
                leaderboardId,
                leaderboardAllocation,
                protocolFallback,
                leaderboardValid
            )
        );
    }

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
    ) external override onlyCore {
        // Calculate protocol cut
        uint256 protocolCut = (amount * s_protocolCutBps) / MAX_BPS;
        uint256 remaining = amount - protocolCut;

        // Transfer fee from payer
        i_token.safeTransferFrom(payer, address(this), amount);

        // Transfer protocol cut
        if (protocolCut > 0) {
            i_token.safeTransfer(s_protocolReceiver, protocolCut);
        }

        // Add remaining funds to leaderboard prize pool
        s_leaderboardPrizePools[leaderboardId] += remaining;

        emit LeaderboardEntryFeeProcessed(
            payer,
            amount,
            protocolCut,
            leaderboardId,
            remaining
        );
        i_ospexCore.emitCoreEvent(
            keccak256("LEADERBOARD_ENTRY_FEE_PROCESSED"),
            abi.encode(
                payer,
                amount,
                protocolCut,
                leaderboardId,
                remaining
            )
        );
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Sets the fee rate for a given fee type
     * @param feeType The type of fee
     * @param rate The fee rate
     */
    function setFeeRates(
        FeeType feeType,
        uint256 rate
    ) external override onlyAdmin {
        s_feeRates[feeType] = rate;
        emit FeeRateSet(feeType, rate);
        i_ospexCore.emitCoreEvent(
            keccak256("FEE_RATE_SET"),
            abi.encode(feeType, rate)
        );
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Sets the protocol cut
     * @param cutBps The protocol cut in basis points
     */
    function setProtocolCut(uint256 cutBps) external override onlyAdmin {
        if (cutBps > MAX_BPS) revert TreasuryModule__InvalidAllocation();
        s_protocolCutBps = cutBps;
        emit ProtocolCutSet(cutBps);
        i_ospexCore.emitCoreEvent(
            keccak256("PROTOCOL_CUT_SET"),
            abi.encode(cutBps)
        );
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Sets the protocol receiver
     * @param receiver The protocol receiver address
     */
    function setProtocolReceiver(address receiver) external override onlyAdmin {
        if (receiver == address(0)) revert TreasuryModule__InvalidReceiver();
        s_protocolReceiver = receiver;
        emit ProtocolReceiverSet(receiver);
        i_ospexCore.emitCoreEvent(
            keccak256("PROTOCOL_RECEIVER_SET"),
            abi.encode(receiver)
        );
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Claims the prize pool for a given leaderboard ID
     * @param leaderboardId The leaderboard ID
     * @param to The address to transfer the prize pool to
     */
    function claimPrizePool(
        uint256 leaderboardId,
        address to,
        uint256 share
    ) external override onlyLeaderboardModule {
        if (share == 0) revert TreasuryModule__InsufficientBalance();
        s_leaderboardPrizePools[leaderboardId] -= share;
        i_token.safeTransfer(to, share);
        emit PrizePoolClaimed(leaderboardId, to, share);
        i_ospexCore.emitCoreEvent(
            keccak256("PRIZE_POOL_CLAIMED"),
            abi.encode(leaderboardId, to, share)
        );
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Gets the fee rate for a given fee type
     * @param feeType The type of fee
     * @return rate The fee rate
     */
    function getFeeRate(
        FeeType feeType
    ) external view override returns (uint256 rate) {
        return s_feeRates[feeType];
    }

    /// @inheritdoc ITreasuryModule
    /**
     * @notice Gets the prize pool for a given leaderboard ID
     * @param leaderboardId The leaderboard ID
     * @return balance The prize pool balance
     */
    function getPrizePool(
        uint256 leaderboardId
    ) external view override returns (uint256 balance) {
        return s_leaderboardPrizePools[leaderboardId];
    }
}
