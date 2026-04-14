// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {IRulesModule} from "../interfaces/IRulesModule.sol";
import {
    PositionType,
    Leaderboard,
    LeaderboardPosition,
    Speculation,
    Position,
    LeaderboardScoring,
    WinSide,
    LeaderboardPositionValidationResult,
    FeeType
} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LeaderboardModule
 * @notice Handles leaderboard creation, user registration, position tracking,
 *         ROI scoring, and prize distribution for the Ospex protocol.
 * @dev Permissionless: anyone can create a leaderboard (0.50 USDC fee). The creator
 *      controls which speculations are eligible. Entry fees go entirely to the prize pool.
 *      Winners are determined by highest ROI during the submission window.
 */

contract LeaderboardModule is ILeaderboardModule, ReentrancyGuard {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant LEADERBOARD_MODULE =
        keccak256("LEADERBOARD_MODULE");
    bytes32 public constant TREASURY_MODULE = keccak256("TREASURY_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant RULES_MODULE = keccak256("RULES_MODULE");

    bytes32 public constant EVENT_LEADERBOARD_CREATED =
        keccak256("LEADERBOARD_CREATED");
    bytes32 public constant EVENT_LEADERBOARD_SPECULATION_ADDED =
        keccak256("LEADERBOARD_SPECULATION_ADDED");
    bytes32 public constant EVENT_USER_REGISTERED =
        keccak256("USER_REGISTERED");
    bytes32 public constant EVENT_LEADERBOARD_POSITION_ADDED =
        keccak256("LEADERBOARD_POSITION_ADDED");
    bytes32 public constant EVENT_LEADERBOARD_ROI_SUBMITTED =
        keccak256("LEADERBOARD_ROI_SUBMITTED");
    bytes32 public constant EVENT_LEADERBOARD_NEW_HIGHEST_ROI =
        keccak256("LEADERBOARD_NEW_HIGHEST_ROI");
    bytes32 public constant EVENT_LEADERBOARD_PRIZE_CLAIMED =
        keccak256("LEADERBOARD_PRIZE_CLAIMED");

    /// @notice ROI precision for calculations (1e18)
    uint256 public constant ROI_PRECISION = 1e18;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when leaderboard time parameters are invalid
    error LeaderboardModule__InvalidTimeRange();
    /// @notice Thrown when an action is attempted outside the valid time window
    error LeaderboardModule__InvalidTime();
    /// @notice Thrown when a declared bankroll is zero or fails rules validation
    error LeaderboardModule__BankrollOutOfRange();
    /// @notice Thrown when a position has zero risk amount
    error LeaderboardModule__NoRiskAmount();
    /// @notice Thrown when a user attempts to register for a leaderboard twice
    error LeaderboardModule__UserAlreadyRegistered();
    /// @notice Thrown when an unregistered user attempts a leaderboard action
    error LeaderboardModule__UserNotRegisteredForLeaderboard();
    /// @notice Thrown when a user attempts to submit ROI more than once
    error LeaderboardModule__ROIAlreadySubmitted();
    /// @notice Thrown when the OspexCore address is zero
    error LeaderboardModule__InvalidOspexCore();
    /// @notice Thrown when a position's risk amount is below the minimum bet
    error LeaderboardModule__BetSizeBelowMinimum();
    /// @notice Thrown when position validation fails against leaderboard rules
    error LeaderboardModule__ValidationFailed(
        LeaderboardPositionValidationResult reason
    );
    /// @notice Thrown when a user already has a position for the same contest/scorer slot
    error LeaderboardModule__PositionAlreadyExistsForSpeculation();
    /// @notice Thrown when a required module is not registered in OspexCore
    error LeaderboardModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when ROI submission is attempted outside the submission window
    error LeaderboardModule__NotInROIWindow();
    /// @notice Thrown when a speculation's contest has already started
    error LeaderboardModule__ContestAlreadyStarted();
    /// @notice Thrown when prize claim is attempted prior to close of ROI submission window
    error LeaderboardModule__NotClaimableYet();
    /// @notice Thrown when a non-winner attempts to claim a prize
    error LeaderboardModule__NotWinner();
    /// @notice Thrown when a winner attempts to claim a prize twice
    error LeaderboardModule__AlreadyClaimed();
    /// @notice Thrown when a user has not met the minimum positions requirement
    error LeaderboardModule__MinimumPositionsNotMet();
    /// @notice Thrown when a speculation is already registered for a leaderboard
    error LeaderboardModule__SpeculationAlreadyExists(uint256 speculationId);
    /// @notice Thrown when a non-creator calls a creator-only function
    error LeaderboardModule__NotCreator(address caller);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a new leaderboard is created
    /// @param leaderboardId The ID of the leaderboard
    /// @param creator The address of the leaderboard creator
    /// @param entryFee The entry fee for the leaderboard
    /// @param startTime The start time of the leaderboard
    /// @param endTime The end time of the leaderboard
    /// @param safetyPeriodDuration The safety period duration
    /// @param roiSubmissionWindow The ROI submission window
    event LeaderboardCreated(
        uint256 indexed leaderboardId,
        address indexed creator,
        uint256 entryFee,
        uint32 startTime,
        uint32 endTime,
        uint32 safetyPeriodDuration,
        uint32 roiSubmissionWindow
    );

    /// @notice Emitted when a speculation is added to a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param speculationId The ID of the speculation
    event LeaderboardSpeculationAdded(
        uint256 indexed leaderboardId,
        uint256 indexed speculationId
    );

    /// @notice Emitted when a user registers for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param user The address of the user
    /// @param declaredBankroll The declared bankroll of the user
    event UserRegistered(
        uint256 indexed leaderboardId,
        address indexed user,
        uint256 declaredBankroll
    );

    /// @notice Emitted when a position is snapshotted into a leaderboard
    /// @param contestId The ID of the contest
    /// @param speculationId The ID of the speculation
    /// @param user The address of the user
    /// @param riskAmount The risk amount of the position
    /// @param profitAmount The profit amount of the position
    /// @param positionType The type of the position
    /// @param leaderboardId The ID of the leaderboard
    event LeaderboardPositionAdded(
        uint256 contestId,
        uint256 indexed speculationId,
        address indexed user,
        uint256 riskAmount,
        uint256 profitAmount,
        PositionType positionType,
        uint256 indexed leaderboardId
    );

    /// @notice Emitted when a user submits their ROI
    /// @param leaderboardId The ID of the leaderboard
    /// @param user The address of the user
    /// @param roi The ROI of the user
    event LeaderboardROISubmitted(
        uint256 indexed leaderboardId,
        address indexed user,
        int256 roi
    );

    /// @notice Emitted when a new highest ROI is recorded or tied
    /// @param leaderboardId The ID of the leaderboard
    /// @param newHighestROI The new highest ROI
    /// @param winner The winner of the leaderboard
    event LeaderboardNewHighestROI(
        uint256 indexed leaderboardId,
        int256 newHighestROI,
        address winner
    );

    /// @notice Emitted when a winner claims their prize
    /// @param leaderboardId The ID of the leaderboard
    /// @param winner The winner of the leaderboard
    /// @param amount The amount of the prize
    event LeaderboardPrizeClaimed(
        uint256 indexed leaderboardId,
        address winner,
        uint256 amount
    );

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Auto-incrementing leaderboard ID counter (starts at 1)
    uint256 public s_nextLeaderboardId = 1;

    /// @notice Leaderboard ID → Leaderboard struct
    mapping(uint256 => Leaderboard) private s_leaderboards;

    /// @notice Leaderboard ID → user → declared bankroll
    mapping(uint256 => mapping(address => uint256)) public s_userBankrolls;

    /// @notice Leaderboard ID → user → speculation ID → LeaderboardPosition
    mapping(uint256 => mapping(address => mapping(uint256 => LeaderboardPosition)))
        private s_leaderboardPositions;

    /// @notice Leaderboard ID → user → array of speculation IDs with registered positions
    mapping(uint256 => mapping(address => uint256[]))
        public s_userSpeculationIds;

    /// @notice Leaderboard ID → speculation ID → whether registered
    mapping(uint256 => mapping(uint256 => bool))
        public s_leaderboardSpeculationRegistered;

    /// @notice Leaderboard ID → user → contest ID → scorer → registered speculation ID
    /// @dev Enforces one position per contest/scorer slot per user per leaderboard
    mapping(uint256 => mapping(address => mapping(uint256 => mapping(address => uint256))))
        public s_registeredLeaderboardSpeculation;

    /// @notice Leaderboard ID → LeaderboardScoring (winners, ROIs, claims)
    mapping(uint256 => LeaderboardScoring) private s_leaderboardScoring;

    /// @notice Leaderboard ID → user → whether ROI has been submitted
    mapping(uint256 => mapping(address => bool)) public s_roiSubmitted;

    /// @notice Speculation ID → user → position type → minimum locked risk
    mapping(uint256 => mapping(address => mapping(PositionType => uint256)))
        public s_lockedRisk;

    /// @notice Speculation ID → user → position type → minimum locked profit
    mapping(uint256 => mapping(address => mapping(PositionType => uint256)))
        public s_lockedProfit;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the LeaderboardModule
    /// @param ospexCore_ The OspexCore contract address
    constructor(address ospexCore_) {
        if (ospexCore_ == address(0)) {
            revert LeaderboardModule__InvalidOspexCore();
        }
        i_ospexCore = OspexCore(ospexCore_);
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return LEADERBOARD_MODULE;
    }

    // ──────────────────────────── Leaderboard Creation ─────────────────

    /// @inheritdoc ILeaderboardModule
    function createLeaderboard(
        uint256 entryFee,
        uint32 startTime,
        uint32 endTime,
        uint32 safetyPeriodDuration,
        uint32 roiSubmissionWindow
    ) external override returns (uint256 leaderboardId) {
        if (
            startTime >= endTime ||
            startTime < block.timestamp ||
            safetyPeriodDuration == 0 ||
            roiSubmissionWindow == 0
        ) {
            revert LeaderboardModule__InvalidTimeRange();
        }

        i_ospexCore.processFee(msg.sender, FeeType.LeaderboardCreation);

        leaderboardId = s_nextLeaderboardId++;
        s_leaderboards[leaderboardId] = Leaderboard({
            entryFee: entryFee,
            creator: msg.sender,
            startTime: startTime,
            endTime: endTime,
            safetyPeriodDuration: safetyPeriodDuration,
            roiSubmissionWindow: roiSubmissionWindow
        });
        emit LeaderboardCreated(
            leaderboardId,
            msg.sender,
            entryFee,
            startTime,
            endTime,
            safetyPeriodDuration,
            roiSubmissionWindow
        );
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_CREATED,
            abi.encode(
                leaderboardId,
                msg.sender,
                entryFee,
                startTime,
                endTime,
                safetyPeriodDuration,
                roiSubmissionWindow
            )
        );
    }

    // ──────────────────────────── Speculation Management ───────────────

    /// @inheritdoc ILeaderboardModule
    function addLeaderboardSpeculation(
        uint256 leaderboardId,
        uint256 speculationId
    ) external override {
        Leaderboard storage lb = s_leaderboards[leaderboardId];
        if (msg.sender != lb.creator)
            revert LeaderboardModule__NotCreator(msg.sender);
        if (lb.startTime == 0 || block.timestamp >= lb.endTime)
            revert LeaderboardModule__InvalidTime();
        if (s_leaderboardSpeculationRegistered[leaderboardId][speculationId]) {
            revert LeaderboardModule__SpeculationAlreadyExists(speculationId);
        }
        uint256 contestId = ISpeculationModule(_getModule(SPECULATION_MODULE))
            .getSpeculation(speculationId)
            .contestId;
        uint32 contestStartTime = IContestModule(_getModule(CONTEST_MODULE))
            .s_contestStartTimes(contestId);
        if (contestStartTime == 0 || block.timestamp >= contestStartTime)
            revert LeaderboardModule__ContestAlreadyStarted();
        s_leaderboardSpeculationRegistered[leaderboardId][speculationId] = true;
        emit LeaderboardSpeculationAdded(leaderboardId, speculationId);
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_SPECULATION_ADDED,
            abi.encode(leaderboardId, speculationId)
        );
    }

    // ──────────────────────────── User Registration ───────────────────

    /// @inheritdoc ILeaderboardModule
    function registerUser(
        uint256 leaderboardId,
        uint256 declaredBankroll
    ) external override nonReentrant {
        Leaderboard storage leaderboard = s_leaderboards[leaderboardId];

        if (
            leaderboard.startTime == 0 || block.timestamp >= leaderboard.endTime
        ) {
            revert LeaderboardModule__InvalidTime();
        }

        if (declaredBankroll == 0) {
            revert LeaderboardModule__BankrollOutOfRange();
        }

        if (s_userBankrolls[leaderboardId][msg.sender] > 0) {
            revert LeaderboardModule__UserAlreadyRegistered();
        }

        if (
            !IRulesModule(_getModule(RULES_MODULE)).isBankrollValid(
                leaderboardId,
                declaredBankroll
            )
        ) {
            revert LeaderboardModule__BankrollOutOfRange();
        }

        uint256 feeAmount = leaderboard.entryFee;
        if (feeAmount > 0) {
            i_ospexCore.processLeaderboardEntryFee(
                msg.sender,
                feeAmount,
                leaderboardId
            );
        }

        s_userBankrolls[leaderboardId][msg.sender] = declaredBankroll;

        emit UserRegistered(leaderboardId, msg.sender, declaredBankroll);
        i_ospexCore.emitCoreEvent(
            EVENT_USER_REGISTERED,
            abi.encode(leaderboardId, msg.sender, declaredBankroll)
        );
    }

    // ──────────────────────────── Position Registration ────────────────

    /**
     * @notice Registers a position for one leaderboard (initial registration only)
     * @dev Leaderboard design principles:
     *      - A leaderboard entry is an immutable snapshot of position economics at registration time.
     *      - Registration is intentionally decoupled from fill time. Strategic timing is a feature.
     *      - Subsequent changes to the underlying position (additional fills, transfers, secondary
     *        market sales) do not modify or invalidate the leaderboard entry.
     *      - Positions acquired via SecondaryMarketModule are eligible for registration.
     *      - The odds of record are a public, updatable reference point. Anyone can update them.
     *        Validation occurs against the odds of record at registration time, not at fill time.
     * @param speculationId The speculation ID
     * @param positionType The position type
     * @param leaderboardId The leaderboard ID
     */
    function registerPositionForLeaderboard(
        uint256 speculationId,
        PositionType positionType,
        uint256 leaderboardId
    ) external override {
        address user = msg.sender;
        (
            uint256 riskAmount,
            uint256 profitAmount,
            int32 lineTicks,
            uint256 contestId,
            address scorer
        ) = _getPositionAndLeaderboardData(speculationId, user, positionType);

        (, uint256 declaredBankroll) = _getLeaderboardAndBankroll(
            leaderboardId,
            user
        );

        if (
            s_registeredLeaderboardSpeculation[leaderboardId][user][contestId][
                scorer
            ] != 0
        ) {
            revert LeaderboardModule__PositionAlreadyExistsForSpeculation();
        }

        IRulesModule rulesModule = IRulesModule(_getModule(RULES_MODULE));

        uint256 maxBet = rulesModule.getMaxBetAmount(
            leaderboardId,
            declaredBankroll
        );
        uint256 cappedRiskAmount = riskAmount > maxBet ? maxBet : riskAmount;
        if (cappedRiskAmount == 0)
            revert LeaderboardModule__BetSizeBelowMinimum();

        uint256 cappedProfitAmount = riskAmount > maxBet
            ? (profitAmount * maxBet) / riskAmount
            : profitAmount;

        if (
            cappedRiskAmount <
            rulesModule.getMinBetAmount(leaderboardId, declaredBankroll)
        ) {
            revert LeaderboardModule__BetSizeBelowMinimum();
        }

        LeaderboardPositionValidationResult validationResult = rulesModule
            .validateLeaderboardPosition(
                leaderboardId,
                speculationId,
                user,
                lineTicks,
                positionType,
                cappedRiskAmount,
                cappedProfitAmount
            );

        if (validationResult != LeaderboardPositionValidationResult.Valid) {
            revert LeaderboardModule__ValidationFailed(validationResult);
        }

        s_registeredLeaderboardSpeculation[leaderboardId][user][contestId][
            scorer
        ] = speculationId;

        s_leaderboardPositions[leaderboardId][user][
            speculationId
        ] = LeaderboardPosition({
            contestId: contestId,
            speculationId: speculationId,
            riskAmount: cappedRiskAmount,
            profitAmount: cappedProfitAmount,
            user: user,
            positionType: positionType
        });

        s_userSpeculationIds[leaderboardId][user].push(speculationId);

        if (
            cappedRiskAmount > s_lockedRisk[speculationId][user][positionType]
        ) {
            s_lockedRisk[speculationId][user][positionType] = cappedRiskAmount;
        }
        if (
            cappedProfitAmount >
            s_lockedProfit[speculationId][user][positionType]
        ) {
            s_lockedProfit[speculationId][user][
                positionType
            ] = cappedProfitAmount;
        }

        emit LeaderboardPositionAdded(
            contestId,
            speculationId,
            user,
            cappedRiskAmount,
            cappedProfitAmount,
            positionType,
            leaderboardId
        );
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_POSITION_ADDED,
            abi.encode(
                contestId,
                speculationId,
                user,
                cappedRiskAmount,
                cappedProfitAmount,
                positionType,
                leaderboardId
            )
        );
    }

    // ──────────────────────────── ROI Submission ──────────────────────

    /**
     * @notice Submits a ROI to a leaderboard
     * @dev ROI is calculated from the user's registered leaderboard positions and their declared bankroll.
     * If the submitted ROI equals the current highest ROI, the user is added to the winners list,
     * creating a tie. Multiple users can share the highest ROI. Prize distribution handles ties
     * by splitting the prize pool equally among all co-winners.
     * Leaderboard ROI is computed from resolved positions at submission time.
     * Positions whose associated speculations remain unresolved (WinSide.TBD)
     * contribute zero to ROI. ROI submission is final and cannot be resubmitted.
     * This is an explicit liveness tradeoff: blocking submission on unresolved
     * positions could prevent users from submitting any ROI during oracle or settlement delays.
     * Contest scoring and speculation settlement are permissionless under normal
     * protocol operation, so any participant may initiate resolution of unresolved positions.
     * Leaderboard creators are responsible for configuring safetyPeriodDuration
     * long enough that unresolved positions are expected to be rare by the time
     * the ROI submission window opens for the selected contests.
     * @param leaderboardId The ID of the leaderboard
     */
    function submitLeaderboardROI(uint256 leaderboardId) external override {
        Leaderboard storage leaderboard = s_leaderboards[leaderboardId];
        (uint256 roiWindowStart, uint256 roiWindowEnd) = _calculateTimeBounds(
            leaderboard
        );
        if (
            block.timestamp < roiWindowStart || block.timestamp >= roiWindowEnd
        ) {
            revert LeaderboardModule__NotInROIWindow();
        }

        uint256 declaredBankroll = s_userBankrolls[leaderboardId][msg.sender];
        if (declaredBankroll == 0) {
            revert LeaderboardModule__UserNotRegisteredForLeaderboard();
        }

        LeaderboardScoring storage leaderboardScoring = s_leaderboardScoring[
            leaderboardId
        ];
        if (
            leaderboardScoring.userROIs[msg.sender] != 0 ||
            s_roiSubmitted[leaderboardId][msg.sender]
        ) {
            revert LeaderboardModule__ROIAlreadySubmitted();
        }

        if (
            !IRulesModule(_getModule(RULES_MODULE)).isMinPositionsMet(
                leaderboardId,
                s_userSpeculationIds[leaderboardId][msg.sender].length
            )
        ) {
            revert LeaderboardModule__MinimumPositionsNotMet();
        }

        int256 roi = _calculateROI(leaderboardId, msg.sender, declaredBankroll);

        leaderboardScoring.userROIs[msg.sender] = roi;
        s_roiSubmitted[leaderboardId][msg.sender] = true;

        if (
            leaderboardScoring.winners.length == 0 ||
            roi > leaderboardScoring.highestROI
        ) {
            leaderboardScoring.highestROI = roi;
            delete leaderboardScoring.winners;
            leaderboardScoring.winners.push(msg.sender);
            emit LeaderboardNewHighestROI(leaderboardId, roi, msg.sender);
            i_ospexCore.emitCoreEvent(
                EVENT_LEADERBOARD_NEW_HIGHEST_ROI,
                abi.encode(leaderboardId, roi, msg.sender)
            );
        } else if (roi == leaderboardScoring.highestROI) {
            leaderboardScoring.winners.push(msg.sender);
            emit LeaderboardNewHighestROI(leaderboardId, roi, msg.sender);
            i_ospexCore.emitCoreEvent(
                EVENT_LEADERBOARD_NEW_HIGHEST_ROI,
                abi.encode(leaderboardId, roi, msg.sender)
            );
        }

        emit LeaderboardROISubmitted(leaderboardId, msg.sender, roi);
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_ROI_SUBMITTED,
            abi.encode(leaderboardId, msg.sender, roi)
        );
    }

    // ──────────────────────────── Prize Claims ────────────────────────

    /**
     * @notice Claims a prize from a leaderboard
     * @dev The prize pool is split equally among all winners (users who share the highest ROI).
     * Each winner receives prizePool / winners.length. Integer division may leave up to
     * (winners.length - 1) wei of dust unclaimed in the treasury. Each winner can only claim once.
     * @param leaderboardId The ID of the leaderboard
     */
    function claimLeaderboardPrize(
        uint256 leaderboardId
    ) external override nonReentrant {
        Leaderboard storage lb = s_leaderboards[leaderboardId];
        LeaderboardScoring storage scoring = s_leaderboardScoring[
            leaderboardId
        ];

        (, uint256 roiWindowEnd) = _calculateTimeBounds(lb);

        if (block.timestamp < roiWindowEnd) {
            revert LeaderboardModule__NotClaimableYet();
        }

        bool isWinner = false;
        for (uint256 i = 0; i < scoring.winners.length; i++) {
            if (scoring.winners[i] == msg.sender) {
                isWinner = true;
                break;
            }
        }
        if (!isWinner) {
            revert LeaderboardModule__NotWinner();
        }

        if (scoring.hasClaimed[msg.sender]) {
            revert LeaderboardModule__AlreadyClaimed();
        }

        ITreasuryModule treasuryModule = ITreasuryModule(
            _getModule(TREASURY_MODULE)
        );

        if (scoring.snapshotPrizePool == 0) {
            scoring.snapshotPrizePool = treasuryModule.getPrizePool(
                leaderboardId
            );
        }

        scoring.hasClaimed[msg.sender] = true;

        uint256 share = scoring.snapshotPrizePool / scoring.winners.length;

        if (share > 0) {
            treasuryModule.claimPrizePool(leaderboardId, msg.sender, share);
        }

        emit LeaderboardPrizeClaimed(leaderboardId, msg.sender, share);
        i_ospexCore.emitCoreEvent(
            EVENT_LEADERBOARD_PRIZE_CLAIMED,
            abi.encode(leaderboardId, msg.sender, share)
        );
    }

    // ──────────────────────────── Internal Helpers ─────────────────────

    /**
     * @notice Gets leaderboard and user's declared bankroll, with validation
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @return leaderboard The leaderboard storage reference
     * @return declaredBankroll The user's declared bankroll
     */
    function _getLeaderboardAndBankroll(
        uint256 leaderboardId,
        address user
    )
        internal
        view
        returns (Leaderboard storage leaderboard, uint256 declaredBankroll)
    {
        leaderboard = s_leaderboards[leaderboardId];
        declaredBankroll = s_userBankrolls[leaderboardId][user];
        if (declaredBankroll == 0) {
            revert LeaderboardModule__UserNotRegisteredForLeaderboard();
        }
        if (
            block.timestamp < leaderboard.startTime ||
            block.timestamp >= leaderboard.endTime
        ) {
            revert LeaderboardModule__InvalidTime();
        }
        return (leaderboard, declaredBankroll);
    }

    /**
     * @notice Gets the full Position data for a user/speculation/positionType
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param positionType The type of the position
     * @return riskAmount The position's risk amount
     * @return profitAmount The position's profit amount
     * @return lineTicks The speculation's line in ticks
     * @return contestId The speculation's contest ID
     * @return scorer The speculation's scorer address
     */
    function _getPositionAndLeaderboardData(
        uint256 speculationId,
        address user,
        PositionType positionType
    )
        internal
        view
        returns (
            uint256 riskAmount,
            uint256 profitAmount,
            int32 lineTicks,
            uint256 contestId,
            address scorer
        )
    {
        IPositionModule posModule = IPositionModule(
            _getModule(POSITION_MODULE)
        );
        Position memory pos = posModule.getPosition(
            speculationId,
            user,
            positionType
        );
        riskAmount = pos.riskAmount;
        profitAmount = pos.profitAmount;
        if (riskAmount == 0) {
            revert LeaderboardModule__NoRiskAmount();
        }
        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);
        lineTicks = spec.lineTicks;
        contestId = spec.contestId;
        scorer = spec.speculationScorer;
        return (riskAmount, profitAmount, lineTicks, contestId, scorer);
    }

    /**
     * @notice Calculates ROI for a user's leaderboard positions
     * @dev Positions whose speculation has winSide == TBD (unscored) are excluded
     * from the net P&L sum. Only resolved outcomes (win, loss, push, void)
     * contribute to ROI.
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @param declaredBankroll The declared bankroll of the user
     * @return roi The ROI scaled by ROI_PRECISION
     */
    function _calculateROI(
        uint256 leaderboardId,
        address user,
        uint256 declaredBankroll
    ) internal view returns (int256 roi) {
        uint256[] storage speculationIds = s_userSpeculationIds[leaderboardId][
            user
        ];
        int256 net = 0;
        for (uint256 i = 0; i < speculationIds.length; i++) {
            LeaderboardPosition storage lbPos = s_leaderboardPositions[
                leaderboardId
            ][user][speculationIds[i]];
            net += _calculatePositionNet(lbPos);
        }
        // Safe casts: ROI_PRECISION and declaredBankroll are USDC-scale values, well within int256 max
        // forge-lint: disable-next-line(unsafe-typecast)
        roi = (net * int256(ROI_PRECISION)) / int256(declaredBankroll);
        return roi;
    }

    /**
     * @notice Calculates the net profit/loss for a single leaderboard position
     * @dev Positions with winSide == TBD (unscored) return 0 and are excluded from ROI.
     * @param lbPos The leaderboard position
     * @return net The net profit/loss (positive = win, negative = loss)
     */
    function _calculatePositionNet(
        LeaderboardPosition storage lbPos
    ) internal view returns (int256 net) {
        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(lbPos.speculationId);

        if (spec.winSide == WinSide.TBD) {
            return 0;
        }

        bool isWinner = _isLeaderboardPositionWinner(lbPos, spec);
        bool isPushOrVoid = (spec.winSide == WinSide.Push ||
            spec.winSide == WinSide.Void);

        uint256 payout;
        if (isPushOrVoid) {
            payout = lbPos.riskAmount;
        } else if (isWinner) {
            payout = lbPos.riskAmount + lbPos.profitAmount;
        } else {
            payout = 0;
        }

        // Safe casts: payout and riskAmount are USDC amounts (6 decimals), well within int256 max
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(payout) - int256(lbPos.riskAmount);
    }

    /**
     * @notice Checks if a leaderboard position is on the winning side
     * @param lbPos The leaderboard position
     * @param spec The speculation with the resolved winSide
     * @return True if the position is a winner
     */
    function _isLeaderboardPositionWinner(
        LeaderboardPosition storage lbPos,
        Speculation memory spec
    ) internal view returns (bool) {
        if (lbPos.positionType == PositionType.Upper) {
            return (spec.winSide == WinSide.Away ||
                spec.winSide == WinSide.Over);
        } else {
            return (spec.winSide == WinSide.Home ||
                spec.winSide == WinSide.Under);
        }
    }

    /**
     * @notice Internal helper to calculate the time bounds
     * @param lb The leaderboard
     * @return roiWindowStart The start of the ROI window
     * @return roiWindowEnd The end of the ROI window
     */
    function _calculateTimeBounds(
        Leaderboard storage lb
    ) internal view returns (uint256 roiWindowStart, uint256 roiWindowEnd) {
        roiWindowStart = lb.endTime + lb.safetyPeriodDuration;
        roiWindowEnd = roiWindowStart + lb.roiSubmissionWindow;
        return (roiWindowStart, roiWindowEnd);
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
            revert LeaderboardModule__ModuleNotSet(moduleType);
        }
        return module;
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc ILeaderboardModule
    function getLeaderboard(
        uint256 leaderboardId
    ) external view override returns (Leaderboard memory) {
        return s_leaderboards[leaderboardId];
    }

    /// @inheritdoc ILeaderboardModule
    function getLeaderboardPosition(
        uint256 leaderboardId,
        address user,
        uint256 speculationId
    ) external view override returns (LeaderboardPosition memory) {
        return s_leaderboardPositions[leaderboardId][user][speculationId];
    }

    /// @inheritdoc ILeaderboardModule
    function getUserROI(
        uint256 leaderboardId,
        address user
    ) external view override returns (int256) {
        return s_leaderboardScoring[leaderboardId].userROIs[user];
    }

    /// @inheritdoc ILeaderboardModule
    function getWinners(
        uint256 leaderboardId
    ) external view override returns (address[] memory) {
        return s_leaderboardScoring[leaderboardId].winners;
    }

    /// @inheritdoc ILeaderboardModule
    function getHighestROI(
        uint256 leaderboardId
    ) external view override returns (int256) {
        return s_leaderboardScoring[leaderboardId].highestROI;
    }

    /// @inheritdoc ILeaderboardModule
    function hasClaimed(
        uint256 leaderboardId,
        address user
    ) external view override returns (bool) {
        return s_leaderboardScoring[leaderboardId].hasClaimed[user];
    }
}
