// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {FeeType, Leaderboard} from "../core/OspexTypes.sol";

/**
 * @title TreasuryModule
 * @notice Centralizes all fee collection and prize-pool accounting for the Ospex protocol.
 * @dev All fee rates are set at deploy time. Protocol fees
 *      are transferred directly to the immutable receiver. Leaderboard entry fees
 *      and sponsorship deposits are held by this contract and disbursed by the
 *      LeaderboardModule via claimPrizePool().
 */
contract TreasuryModule is ITreasuryModule {
    using SafeERC20 for IERC20;
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant LEADERBOARD_MODULE =
        keccak256("LEADERBOARD_MODULE");
    bytes32 public constant TREASURY_MODULE = keccak256("TREASURY_MODULE");

    bytes32 public constant EVENT_FEE_PROCESSED = keccak256("FEE_PROCESSED");
    bytes32 public constant EVENT_SPLIT_FEE_PROCESSED =
        keccak256("SPLIT_FEE_PROCESSED");
    bytes32 public constant EVENT_LEADERBOARD_FUNDED =
        keccak256("LEADERBOARD_FUNDED");
    bytes32 public constant EVENT_LEADERBOARD_ENTRY_FEE_PROCESSED =
        keccak256("LEADERBOARD_ENTRY_FEE_PROCESSED");
    bytes32 public constant EVENT_PRIZE_POOL_CLAIMED =
        keccak256("PRIZE_POOL_CLAIMED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a non-Core address calls a Core-only function
    error TreasuryModule__NotCore();
    /// @notice Thrown when a non-LeaderboardModule address calls a leaderboard-only function
    error TreasuryModule__NotLeaderboardModule();
    /// @notice Thrown when an address parameter is the zero address
    error TreasuryModule__InvalidReceiver();
    /// @notice Thrown when a zero amount is passed where a positive value is required
    error TreasuryModule__InvalidAllocation();
    /// @notice Thrown when a leaderboard creator has a zero address
    error TreasuryModule__InvalidLeaderboardCreator();
    /// @notice Thrown when a prize pool claim exceeds the available balance
    error TreasuryModule__InsufficientBalance();
    /// @notice Thrown when attempting to fund a leaderboard that has already ended
    error TreasuryModule__LeaderboardEnded();

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a protocol fee is collected
    /// @param payer The address that paid the fee
    /// @param feeType The category of fee
    /// @param amount The fee amount in USDC
    event FeeProcessed(
        address indexed payer,
        FeeType indexed feeType,
        uint256 amount
    );

    /// @notice Emitted when anyone sponsors a leaderboard prize pool
    /// @param leaderboardId The leaderboard that received funding
    /// @param funder The address that deposited funds
    /// @param amount The amount deposited in USDC
    event LeaderboardFunded(
        uint256 indexed leaderboardId,
        address indexed funder,
        uint256 amount
    );

    /// @notice Emitted when a leaderboard entry fee is collected
    /// @param payer The address that paid the entry fee
    /// @param amount The entry fee amount in USDC
    /// @param leaderboardId The leaderboard receiving the entry
    event LeaderboardEntryFeeProcessed(
        address indexed payer,
        uint256 amount,
        uint256 indexed leaderboardId
    );

    /// @notice Emitted when prize pool funds are disbursed to a winner
    /// @param leaderboardId The leaderboard the prize was claimed from
    /// @param to The recipient address
    /// @param amount The amount disbursed in USDC
    event PrizePoolClaimed(
        uint256 indexed leaderboardId,
        address indexed to,
        uint256 amount
    );

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @notice Restricts access to the OspexCore contract
    modifier onlyCore() {
        if (msg.sender != address(i_ospexCore))
            revert TreasuryModule__NotCore();
        _;
    }

    /// @notice Restricts access to the registered LeaderboardModule
    modifier onlyLeaderboardModule() {
        if (msg.sender != i_ospexCore.getModule(LEADERBOARD_MODULE))
            revert TreasuryModule__NotLeaderboardModule();
        _;
    }

    /// @notice Validates that a leaderboard exists and has not ended
    /// @param leaderboardId The leaderboard to validate
    modifier validLeaderboard(uint256 leaderboardId) {
        Leaderboard memory lb = ILeaderboardModule(
            i_ospexCore.getModule(LEADERBOARD_MODULE)
        ).getLeaderboard(leaderboardId);
        if (lb.creator == address(0))
            revert TreasuryModule__InvalidLeaderboardCreator();
        if (block.timestamp >= lb.endTime)
            revert TreasuryModule__LeaderboardEnded();
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice The USDC token contract
    IERC20 public immutable i_token;

    /// @notice The address that receives all protocol fees
    address public immutable i_protocolReceiver;

    /// @notice Fee rate per FeeType, set at deploy time (USDC token units)
    mapping(FeeType => uint256) public s_feeRates;

    /// @notice Leaderboard ID → prize pool balance held by this contract
    mapping(uint256 => uint256) public s_leaderboardPrizePools;

    // ──────────────────────────── Constructor ──────────────────────────

    /**
     * @notice Deploys the TreasuryModule with immutable fee configuration
     * @param ospexCore_ The OspexCore contract address
     * @param token_ The USDC token contract address
     * @param protocolReceiver_ The address that receives protocol fees
     * @param contestCreationFeeRate Fee for creating a contest (USDC token units)
     * @param speculationCreationFeeRate Fee for creating a speculation (USDC token units)
     * @param leaderboardCreationFeeRate Fee for creating a leaderboard (USDC token units)
     */
    constructor(
        address ospexCore_,
        address token_,
        address protocolReceiver_,
        uint256 contestCreationFeeRate,
        uint256 speculationCreationFeeRate,
        uint256 leaderboardCreationFeeRate
    ) {
        if (
            ospexCore_ == address(0) ||
            token_ == address(0) ||
            protocolReceiver_ == address(0)
        ) revert TreasuryModule__InvalidReceiver();
        i_ospexCore = OspexCore(ospexCore_);
        i_token = IERC20(token_);
        i_protocolReceiver = protocolReceiver_;
        s_feeRates[FeeType.ContestCreation] = contestCreationFeeRate;
        s_feeRates[FeeType.SpeculationCreation] = speculationCreationFeeRate;
        s_feeRates[FeeType.LeaderboardCreation] = leaderboardCreationFeeRate;
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return TREASURY_MODULE;
    }

    // ──────────────────────────── Fee Processing ──────────────────────

    /// @inheritdoc ITreasuryModule
    function processFee(
        address payer,
        FeeType feeType
    ) external override onlyCore {
        uint256 amount = s_feeRates[feeType];
        if (amount == 0) return;

        i_token.safeTransferFrom(payer, i_protocolReceiver, amount);

        emit FeeProcessed(payer, feeType, amount);
        i_ospexCore.emitCoreEvent(
            EVENT_FEE_PROCESSED,
            abi.encode(payer, feeType, amount)
        );
    }

    /// @inheritdoc ITreasuryModule
    function processSplitFee(
        address payer1,
        address payer2,
        FeeType feeType
    ) external override onlyCore {
        uint256 totalAmount = s_feeRates[feeType];
        if (totalAmount == 0) return;
        uint256 firstHalf = totalAmount / 2;
        uint256 secondHalf = totalAmount - firstHalf;
        i_token.safeTransferFrom(payer1, i_protocolReceiver, firstHalf);
        i_token.safeTransferFrom(payer2, i_protocolReceiver, secondHalf);

        emit FeeProcessed(payer1, feeType, firstHalf);
        emit FeeProcessed(payer2, feeType, secondHalf);
        i_ospexCore.emitCoreEvent(
            EVENT_SPLIT_FEE_PROCESSED,
            abi.encode(payer1, payer2, feeType, firstHalf, secondHalf)
        );
    }

    // ──────────────────────────── Leaderboard Funding ─────────────────

    /// @inheritdoc ITreasuryModule
    function fundLeaderboard(
        uint256 leaderboardId,
        uint256 amount
    ) external validLeaderboard(leaderboardId) {
        if (amount == 0) revert TreasuryModule__InvalidAllocation();

        i_token.safeTransferFrom(msg.sender, address(this), amount);
        s_leaderboardPrizePools[leaderboardId] += amount;

        emit LeaderboardFunded(leaderboardId, msg.sender, amount);
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_FUNDED,
            abi.encode(leaderboardId, msg.sender, amount)
        );
    }

    /// @inheritdoc ITreasuryModule
    function processLeaderboardEntryFee(
        address payer,
        uint256 amount,
        uint256 leaderboardId
    ) external override onlyCore validLeaderboard(leaderboardId) {
        i_token.safeTransferFrom(payer, address(this), amount);
        s_leaderboardPrizePools[leaderboardId] += amount;

        emit LeaderboardEntryFeeProcessed(payer, amount, leaderboardId);
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_ENTRY_FEE_PROCESSED,
            abi.encode(payer, amount, leaderboardId)
        );
    }

    // ──────────────────────────── Prize Pool Disbursement ─────────────

    /// @inheritdoc ITreasuryModule
    function claimPrizePool(
        uint256 leaderboardId,
        address to,
        uint256 amount
    ) external override onlyLeaderboardModule {
        if (to == address(0)) revert TreasuryModule__InvalidReceiver();
        if (amount == 0 || amount > s_leaderboardPrizePools[leaderboardId])
            revert TreasuryModule__InsufficientBalance();
        s_leaderboardPrizePools[leaderboardId] -= amount;
        i_token.safeTransfer(to, amount);
        emit PrizePoolClaimed(leaderboardId, to, amount);
        i_ospexCore.emitCoreEvent(
            EVENT_PRIZE_POOL_CLAIMED,
            abi.encode(leaderboardId, to, amount)
        );
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc ITreasuryModule
    function getFeeRate(
        FeeType feeType
    ) external view override returns (uint256 rate) {
        return s_feeRates[feeType];
    }

    /// @inheritdoc ITreasuryModule
    function getPrizePool(
        uint256 leaderboardId
    ) external view override returns (uint256 balance) {
        return s_leaderboardPrizePools[leaderboardId];
    }
}
