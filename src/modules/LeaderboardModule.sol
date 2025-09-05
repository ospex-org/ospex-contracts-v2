// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {IRulesModule} from "../interfaces/IRulesModule.sol";
import {PositionType, Leaderboard, LeaderboardPosition, Speculation, Position, OddsPair, LeaderboardScoring, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LeaderboardModule
 * @notice Handles leaderboard creation, storage, and status management for Ospex protocol
 * @dev All business logic for leaderboards is implemented here.
 */

contract LeaderboardModule is ILeaderboardModule, ReentrancyGuard {
    // --- Custom Errors ---
    /// @notice Error for calling the module from non-authorized address
    error LeaderboardModule__NotAdmin(address caller);
    /// @notice Error for invalid time range
    error LeaderboardModule__InvalidTimeRange();
    /// @notice Error for invalid time
    error LeaderboardModule__InvalidTime();
    /// @notice Error for bankroll out of range
    error LeaderboardModule__BankrollOutOfRange();
    /// @notice Error for no matched amount
    error LeaderboardModule__NoMatchedAmount();
    /// @notice Error for no additional matched amount
    error LeaderboardModule__NoAdditionalMatchedAmount();
    /// @notice Error for user already registered
    error LeaderboardModule__UserAlreadyRegistered();
    /// @notice Error for user not registered for leaderboard
    error LeaderboardModule__UserNotRegisteredForLeaderboard();
    /// @notice Error for invalid leaderboard count
    error LeaderboardModule__InvalidLeaderboardCount();
    /// @notice Error for invalid OspexCore
    error LeaderboardModule__InvalidOspexCore();
    /// @notice Error for position already exists for speculation
    error LeaderboardModule__PositionAlreadyExistsForSpeculation();
    /// @notice Error for leaderboard speculation not registered for leaderboard
    error LeaderboardModule__LeaderboardSpeculationNotRegisteredForLeaderboard();
    /// @notice Error for module not set
    error LeaderboardModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Error for not in ROI window
    error LeaderboardModule__NotInROIWindow();
    /// @notice Error for not in claim window
    error LeaderboardModule__NotInClaimWindow();
    /// @notice Error for not winner
    error LeaderboardModule__NotWinner();
    /// @notice Error for already claimed
    error LeaderboardModule__AlreadyClaimed();
    /// @notice Error for minimum positions not met
    error LeaderboardModule__MinimumPositionsNotMet();
    /// @notice Error for no unclaimed prizes
    error LeaderboardModule__NoUnclaimedPrizes();
    /// @notice Error for leaderboard speculation not found
    error LeaderboardModule__SpeculationAlreadyExists(uint256 speculationId);

    // --- State Variables ---
    // Stores all leaderboard core state, keyed by leaderboardId.
    // Each Leaderboard struct contains prize pool, timing, winner, etc.
    mapping(uint256 => Leaderboard) private s_leaderboards;

    // Stores the declared bankroll for each user in each leaderboard.
    // Used for eligibility checks and ROI normalization.
    // leaderboardId => user address => declared bankroll
    mapping(uint256 => mapping(address => uint256)) public s_userBankrolls;

    // Tracks each user's leaderboard-eligible position for a given speculation in a leaderboard.
    // leaderboardId => user address => speculationId => LeaderboardPosition
    mapping(uint256 => mapping(address => mapping(uint256 => LeaderboardPosition)))
        private s_leaderboardPositions;

    // Tracks all speculationIds a user has positions in for a given leaderboard.
    // Used for iterating over a user's leaderboard positions.
    // leaderboardId => user address => array of speculationIds
    mapping(uint256 => mapping(address => uint256[]))
        public s_userSpeculationIds;

    // Tracks if a speculation is registered for a leaderboard
    // leaderboardId => speculationId => bool
    mapping(uint256 => mapping(uint256 => bool))
        public s_leaderboardSpeculationRegistered;

    // Used to enforce one position (spread/moneyline) per leaderboard per user
    // leaderboardId => user => contestId => scorer => registeredSpeculationId
    mapping(uint256 => mapping(address => mapping(uint256 => mapping(address => uint256))))
        public s_registeredLeaderboardSpeculation;

    // Stores the scoring information for each leaderboard
    // leaderboardId => LeaderboardScoring
    mapping(uint256 => LeaderboardScoring) private s_leaderboardScoring;

    // Leaderboard counter
    uint256 public s_nextLeaderboardId;
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    // --- Constants ---
    /// @notice ROI precision for calculations
    uint256 public constant ROI_PRECISION = 1e18;

    // --- Events ---
    /**
     * @notice Event for leaderboard creation
     * @param leaderboardId The ID of the leaderboard
     * @param entryFee The entry fee for the leaderboard
     * @param yieldStrategy The yield strategy for the leaderboard
     * @param startTime The start time of the leaderboard
     * @param endTime The end time of the leaderboard
     * @param safetyPeriodDuration The safety period duration
     * @param roiSubmissionWindow The ROI submission window
     * @param claimWindow The claim window
     */
    event LeaderboardCreated(
        uint256 indexed leaderboardId,
        uint256 entryFee,
        address yieldStrategy,
        uint32 startTime,
        uint32 endTime,
        uint32 safetyPeriodDuration,
        uint32 roiSubmissionWindow,
        uint32 claimWindow
    );

    /**
     * @notice Event for adding a speculation to a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param speculationId The ID of the speculation
     */
    event LeaderboardSpeculationAdded(
        uint256 indexed leaderboardId,
        uint256 indexed speculationId
    );

    /**
     * @notice Event for user registration
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @param declaredBankroll The declared bankroll of the user
     */
    event UserRegistered(
        uint256 indexed leaderboardId,
        address indexed user,
        uint256 declaredBankroll
    );

    /**
     * @notice Event for adding a position to a leaderboard
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param amount The amount of the position
     * @param positionType The type of the position
     * @param leaderboardId The ID of the leaderboard
     */
    event LeaderboardPositionAdded(
        uint256 indexed speculationId,
        address indexed user,
        uint128 oddsPairId,
        uint256 amount,
        PositionType positionType,
        uint256 indexed leaderboardId
    );

    /**
     * @notice Event for updating a position in a leaderboard
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param amount The amount of the position
     * @param positionType The type of the position
     * @param leaderboardId The ID of the leaderboard
     */
    event LeaderboardPositionUpdated(
        uint256 indexed speculationId,
        address indexed user,
        uint128 oddsPairId,
        uint256 amount,
        PositionType positionType,
        uint256 indexed leaderboardId
    );

    /**
     * @notice Event for submitting ROI to a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @param roi The ROI of the user
     */
    event LeaderboardROISubmitted(
        uint256 indexed leaderboardId,
        address indexed user,
        int256 roi
    );

    /**
     * @notice Event for new highest ROI
     * @param leaderboardId The ID of the leaderboard
     * @param newHighestROI The new highest ROI
     * @param winner The winner of the leaderboard
     */
    event LeaderboardNewHighestROI(
        uint256 indexed leaderboardId,
        int256 newHighestROI,
        address winner
    );

    /**
     * @notice Event for prize claimed
     * @param leaderboardId The ID of the leaderboard
     * @param winner The winner of the leaderboard
     * @param amount The amount of the prize
     */
    event LeaderboardPrizeClaimed(
        uint256 indexed leaderboardId,
        address winner,
        uint256 amount
    );

    /**
     * @notice Event for prizes swept
     * @param leaderboardId The ID of the leaderboard
     * @param admin The address of the admin
     * @param amount The amount of the prizes
     */
    event LeaderboardPrizesSwept(
        uint256 indexed leaderboardId,
        address indexed admin,
        uint256 amount
    );

    // --- Modifiers ---

    /**
     * @notice Modifier to ensure the caller is the admin
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert LeaderboardModule__NotAdmin(msg.sender);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor for the leaderboard module
     * @param ospexCore_ The address of the OspexCore contract
     */
    constructor(address ospexCore_) {
        if (ospexCore_ == address(0)) {
            revert LeaderboardModule__InvalidOspexCore();
        }
        i_ospexCore = OspexCore(ospexCore_);
    }

    // --- IModule ---
    /**
     * @notice Gets the module type
     * @return moduleType The module type
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("LEADERBOARD_MODULE");
    }

    // --- Core Functions ---
    /**
     * @notice Creates a leaderboard
     * @param entryFee The entry fee for the leaderboard
     * @param yieldStrategy The yield strategy for the leaderboard
     * @param startTime The start time of the leaderboard
     * @param endTime The end time of the leaderboard
     * @param safetyPeriodDuration The safety period duration
     * @param roiSubmissionWindow The ROI submission window
     * @param claimWindow The claim window
     * @return leaderboardId The ID of the leaderboard
     */
    function createLeaderboard(
        uint256 entryFee,
        address yieldStrategy,
        uint32 startTime,
        uint32 endTime,
        uint32 safetyPeriodDuration,
        uint32 roiSubmissionWindow,
        uint32 claimWindow
    ) external override onlyAdmin returns (uint256 leaderboardId) {
        // Validate time range
        if (startTime >= endTime || startTime < block.timestamp) {
            revert LeaderboardModule__InvalidTimeRange();
        }
        leaderboardId = s_nextLeaderboardId++;
        s_leaderboards[leaderboardId] = Leaderboard({
            prizePool: 0,
            entryFee: entryFee,
            yieldStrategy: yieldStrategy,
            startTime: startTime,
            endTime: endTime,
            safetyPeriodDuration: safetyPeriodDuration,
            roiSubmissionWindow: roiSubmissionWindow,
            claimWindow: claimWindow
        });
        emit LeaderboardCreated(
            leaderboardId,
            entryFee,
            yieldStrategy,
            startTime,
            endTime,
            safetyPeriodDuration,
            roiSubmissionWindow,
            claimWindow
        );
        i_ospexCore.emitCoreEvent(
            keccak256("LEADERBOARD_CREATED"),
            abi.encode(
                leaderboardId,
                entryFee,
                yieldStrategy,
                startTime,
                endTime,
                safetyPeriodDuration,
                roiSubmissionWindow,
                claimWindow
            )
        );
    }

    /**
     * @notice Adds a speculation to a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param speculationId The ID of the speculation
     */
    function addLeaderboardSpeculation(
        uint256 leaderboardId,
        uint256 speculationId
    ) external override onlyAdmin {
        // Validate that the LeaderboardSpeculation doesn't already exist
        if (s_leaderboardSpeculationRegistered[leaderboardId][speculationId]) {
            revert LeaderboardModule__SpeculationAlreadyExists(speculationId);
        }
        s_leaderboardSpeculationRegistered[leaderboardId][speculationId] = true;
        emit LeaderboardSpeculationAdded(leaderboardId, speculationId);
        i_ospexCore.emitCoreEvent(
            keccak256("LEADERBOARD_SPECULATION_ADDED"),
            abi.encode(leaderboardId, speculationId)
        );
    }

    /**
     * @notice Registers a user for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param declaredBankroll The declared bankroll of the user
     */
    function registerUser(
        uint256 leaderboardId,
        uint256 declaredBankroll
    ) external override {
        Leaderboard storage leaderboard = s_leaderboards[leaderboardId];

        // Check if leaderboard exists and hasn't ended
        if (
            leaderboard.startTime == 0 || block.timestamp >= leaderboard.endTime
        ) {
            revert LeaderboardModule__InvalidTime();
        }

        // Check if user is already registered (bankroll > 0 means registered)
        if (s_userBankrolls[leaderboardId][msg.sender] > 0) {
            revert LeaderboardModule__UserAlreadyRegistered();
        }

        // If bankroll requirements exist, validate them
        if (
            !IRulesModule(_getModule(keccak256("RULES_MODULE")))
                .isBankrollValid(leaderboardId, declaredBankroll)
        ) {
            revert LeaderboardModule__BankrollOutOfRange();
        }

        // Charge the leaderboard entry fee
        uint256 feeAmount = leaderboard.entryFee;
        if (feeAmount > 0) {
            i_ospexCore.processLeaderboardEntryFee(
                msg.sender,
                feeAmount,
                leaderboardId
            );
        }

        // Store user's bankroll
        s_userBankrolls[leaderboardId][msg.sender] = declaredBankroll;

        emit UserRegistered(leaderboardId, msg.sender, declaredBankroll);
        i_ospexCore.emitCoreEvent(
            keccak256("USER_REGISTERED"),
            abi.encode(leaderboardId, msg.sender, declaredBankroll)
        );
    }

    /**
     * @notice Registers a position for one or more leaderboards (initial registration only)
     * @param speculationId The speculation ID
     * @param oddsPairId The odds pair ID
     * @param positionType The position type
     * @param leaderboardIds The list of leaderboard IDs (max 8)
     */
    function registerPositionForLeaderboards(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256[] calldata leaderboardIds
    ) external override {
        if (leaderboardIds.length > 8) {
            revert LeaderboardModule__InvalidLeaderboardCount();
        }
        address user = msg.sender;
        (
            uint256 matchedAmount,
            uint64 odds,
            int32 theNumber,
            uint256 contestId,
            address scorer
        ) = _getPositionAndLeaderboardData(
                speculationId,
                user,
                oddsPairId,
                positionType
            );

        for (uint256 i = 0; i < leaderboardIds.length; i++) {
            uint256 leaderboardId = leaderboardIds[i];
            (, uint256 declaredBankroll) = _getLeaderboardAndBankroll(
                leaderboardId,
                user
            );
            // Check if the speculation is already registered for this leaderboard
            uint256 registeredSpecId = s_registeredLeaderboardSpeculation[
                leaderboardId
            ][user][contestId][scorer];
            if (registeredSpecId != 0) {
                // Already registered, must use increase function
                revert LeaderboardModule__PositionAlreadyExistsForSpeculation();
            }

            IRulesModule rulesModule = IRulesModule(
                _getModule(keccak256("RULES_MODULE"))
            );

            // Cap at max allowed bet size
            uint256 maxBet = rulesModule.getMaxBetAmount(
                leaderboardId,
                declaredBankroll
            );
            uint256 cappedAmount = matchedAmount > maxBet
                ? maxBet
                : matchedAmount;

            // Validate position using comprehensive rules validation
            if (
                cappedAmount >=
                rulesModule.getMinBetAmount(leaderboardId, declaredBankroll) &&
                rulesModule.validateLeaderboardPosition(
                    leaderboardId,
                    speculationId,
                    cappedAmount,
                    declaredBankroll,
                    theNumber,
                    odds,
                    positionType
                )
            ) {
                // Register this speculationId as the slot owner
                s_registeredLeaderboardSpeculation[leaderboardId][user][
                    contestId
                ][scorer] = speculationId;
                // Store LeaderboardPosition
                s_leaderboardPositions[leaderboardId][user][
                    speculationId
                ] = LeaderboardPosition({
                    contestId: contestId,
                    speculationId: speculationId,
                    amount: cappedAmount,
                    user: user,
                    odds: odds,
                    positionType: positionType
                });
                // Track speculationId for user in this leaderboard
                s_userSpeculationIds[leaderboardId][user].push(speculationId);
                emit LeaderboardPositionAdded(
                    speculationId,
                    user,
                    oddsPairId,
                    cappedAmount,
                    positionType,
                    leaderboardId
                );
                i_ospexCore.emitCoreEvent(
                    keccak256("LEADERBOARD_POSITION_ADDED"),
                    abi.encode(
                        speculationId,
                        user,
                        oddsPairId,
                        cappedAmount,
                        positionType,
                        leaderboardId
                    )
                );
            }
        }
    }

    /**
     * @notice Increases the registered amount of a position for one or more leaderboards
     * @param speculationId The speculation ID
     * @param oddsPairId The odds pair ID
     * @param positionType The position type
     * @param leaderboardIds The list of leaderboard IDs (max 8)
     */
    function increaseLeaderboardPositionAmount(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint256[] calldata leaderboardIds
    ) external override {
        if (leaderboardIds.length > 8) {
            revert LeaderboardModule__InvalidLeaderboardCount();
        }
        address user = msg.sender;
        (
            uint256 matchedAmount,
            ,
            ,
            uint256 contestId,
            address scorer
        ) = _getPositionAndLeaderboardData(
                speculationId,
                user,
                oddsPairId,
                positionType
            );

        for (uint256 i = 0; i < leaderboardIds.length; i++) {
            uint256 leaderboardId = leaderboardIds[i];
            (, uint256 declaredBankroll) = _getLeaderboardAndBankroll(
                leaderboardId,
                user
            );
            // Check if the speculation is already registered for this leaderboard
            uint256 registeredSpecId = s_registeredLeaderboardSpeculation[
                leaderboardId
            ][user][contestId][scorer];
            if (registeredSpecId != speculationId) {
                // Not registered yet, must use register function
                revert LeaderboardModule__LeaderboardSpeculationNotRegisteredForLeaderboard();
            }
            LeaderboardPosition storage lbPos = s_leaderboardPositions[
                leaderboardId
            ][user][speculationId];
            if (matchedAmount <= lbPos.amount) {
                revert LeaderboardModule__NoAdditionalMatchedAmount();
            }

            // Cap at max allowed bet size
            uint256 maxBet = IRulesModule(_getModule(keccak256("RULES_MODULE")))
                .getMaxBetAmount(leaderboardId, declaredBankroll);
            uint256 cappedAmount = matchedAmount > maxBet
                ? maxBet
                : matchedAmount;
            if (cappedAmount > lbPos.amount) {
                lbPos.amount = cappedAmount;

                emit LeaderboardPositionUpdated(
                    speculationId,
                    user,
                    oddsPairId,
                    cappedAmount,
                    positionType,
                    leaderboardId
                );
                i_ospexCore.emitCoreEvent(
                    keccak256("LEADERBOARD_POSITION_UPDATED"),
                    abi.encode(
                        speculationId,
                        user,
                        oddsPairId,
                        cappedAmount,
                        positionType,
                        leaderboardId
                    )
                );
            }
        }
    }

    /**
     * @notice Submits a ROI to a leaderboard
     * @param leaderboardId The ID of the leaderboard
     */
    function submitLeaderboardROI(uint256 leaderboardId) external override {
        // --- Time checks ---
        Leaderboard storage leaderboard = s_leaderboards[leaderboardId];
        uint256 claimWindowStart = leaderboard.endTime +
            leaderboard.safetyPeriodDuration;
        uint256 claimWindowEnd = claimWindowStart + leaderboard.claimWindow;
        if (
            block.timestamp < claimWindowStart ||
            block.timestamp > claimWindowEnd
        ) {
            revert LeaderboardModule__NotInROIWindow();
        }

        // --- User registration check ---
        uint256 declaredBankroll = s_userBankrolls[leaderboardId][msg.sender];
        if (declaredBankroll == 0) {
            revert LeaderboardModule__UserNotRegisteredForLeaderboard();
        }

        // --- Minimum positions check (via RulesModule) ---
        if (
            !IRulesModule(_getModule(keccak256("RULES_MODULE")))
                .isMinPositionsMet(
                    leaderboardId,
                    s_userSpeculationIds[leaderboardId][msg.sender].length
                )
        ) {
            revert LeaderboardModule__MinimumPositionsNotMet();
        }

        // --- Calculate ROI ---
        int256 roi = _calculateROI(leaderboardId, msg.sender, declaredBankroll);

        // --- Store and compare ---
        LeaderboardScoring storage leaderboardScoring = s_leaderboardScoring[
            leaderboardId
        ];
        leaderboardScoring.userROIs[msg.sender] = roi;
        if (
            leaderboardScoring.winners.length == 0 ||
            roi > leaderboardScoring.highestROI
        ) {
            // --- New highest ROI: reset winners list ---
            leaderboardScoring.highestROI = roi;
            delete leaderboardScoring.winners;
            leaderboardScoring.winners.push(msg.sender);
            emit LeaderboardNewHighestROI(leaderboardId, roi, msg.sender);
            i_ospexCore.emitCoreEvent(
                keccak256("LEADERBOARD_NEW_HIGHEST_ROI"),
                abi.encode(leaderboardId, roi, msg.sender)
            );
        } else if (roi == leaderboardScoring.highestROI) {
            // --- Equal ROI (tie): add to winners list if not already present ---
            bool alreadyInWinners = false;
            for (uint256 i = 0; i < leaderboardScoring.winners.length; i++) {
                if (leaderboardScoring.winners[i] == msg.sender) {
                    alreadyInWinners = true;
                    break;
                }
            }
            if (!alreadyInWinners) {
                leaderboardScoring.winners.push(msg.sender);
                emit LeaderboardNewHighestROI(leaderboardId, roi, msg.sender);
                i_ospexCore.emitCoreEvent(
                    keccak256("LEADERBOARD_NEW_HIGHEST_ROI"),
                    abi.encode(leaderboardId, roi, msg.sender)
                );
            }
        }
        emit LeaderboardROISubmitted(leaderboardId, msg.sender, roi);
        i_ospexCore.emitCoreEvent(
            keccak256("LEADERBOARD_ROI_SUBMITTED"),
            abi.encode(leaderboardId, msg.sender, roi)
        );
    }

    /**
     * @notice Claims a prize from a leaderboard
     * @param leaderboardId The ID of the leaderboard
     */
    function claimLeaderboardPrize(
        uint256 leaderboardId
    ) external override nonReentrant {
        Leaderboard storage lb = s_leaderboards[leaderboardId];
        LeaderboardScoring storage scoring = s_leaderboardScoring[
            leaderboardId
        ];

        // Calculate time boundaries
        (
            ,
            ,
            uint256 claimWindowStart,
            uint256 claimWindowEnd
        ) = _calculateTimeBounds(lb);

        // Only allow during claim window
        if (
            block.timestamp < claimWindowStart ||
            block.timestamp > claimWindowEnd
        ) {
            revert LeaderboardModule__NotInClaimWindow();
        }

        // Only winner(s) can claim
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

        // Only one claim per winner
        if (scoring.hasClaimed[msg.sender]) {
            revert LeaderboardModule__AlreadyClaimed();
        }

        // Mark as claimed
        scoring.hasClaimed[msg.sender] = true;

        // Calculate share
        uint256 share = lb.prizePool / scoring.winners.length;

        // Transfer prize
        ITreasuryModule(_getModule(keccak256("TREASURY_MODULE")))
            .claimPrizePool(leaderboardId, msg.sender, share);

        // Emit events
        emit LeaderboardPrizeClaimed(leaderboardId, msg.sender, share);
        i_ospexCore.emitCoreEvent(
            keccak256("LEADERBOARD_PRIZE_CLAIMED"),
            abi.encode(leaderboardId, msg.sender, share)
        );
    }

    /**
     * @notice Sweeps prizes from a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param to The address to sweep the prizes to
     */
    function adminSweep(
        uint256 leaderboardId,
        address to
    ) external override nonReentrant onlyAdmin {
        Leaderboard storage lb = s_leaderboards[leaderboardId];
        LeaderboardScoring storage scoring = s_leaderboardScoring[
            leaderboardId
        ];

        // Calculate time boundaries
        (, , , uint256 claimWindowEnd) = _calculateTimeBounds(lb);

        // Only after claim window
        if (block.timestamp <= claimWindowEnd) {
            revert LeaderboardModule__NotInClaimWindow();
        }

        // Count unclaimed winners
        uint256 unclaimedCount = 0;
        for (uint256 i = 0; i < scoring.winners.length; i++) {
            if (!scoring.hasClaimed[scoring.winners[i]]) {
                unclaimedCount++;
            }
        }
        if (unclaimedCount == 0) {
            revert LeaderboardModule__NoUnclaimedPrizes();
        }

        // Calculate unclaimed amount
        uint256 share = lb.prizePool / scoring.winners.length;
        uint256 unclaimedAmount = share * unclaimedCount;

        // Mark all as claimed to prevent future claims
        for (uint256 i = 0; i < scoring.winners.length; i++) {
            scoring.hasClaimed[scoring.winners[i]] = true;
        }

        // Transfer unclaimed to protocol treasury
        ITreasuryModule(_getModule(keccak256("TREASURY_MODULE")))
            .claimPrizePool(leaderboardId, to, unclaimedAmount);

        // Emit event
        emit LeaderboardPrizesSwept(leaderboardId, to, unclaimedAmount);
        i_ospexCore.emitCoreEvent(
            keccak256("LEADERBOARD_PRIZES_SWEEP"),
            abi.encode(leaderboardId, to, unclaimedAmount)
        );
    }

    /**
     * @notice Internal helper to get leaderboard and user's declared bankroll, with validation
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @return leaderboard The leaderboard
     * @return declaredBankroll The declared bankroll of the user
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
     * @notice Internal helper to get the full Position struct for a user/speculation/oddsPair/positionType
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of the position
     */
    function _getPositionAndLeaderboardData(
        uint256 speculationId,
        address user,
        uint128 oddsPairId,
        PositionType positionType
    )
        internal
        view
        returns (
            uint256 matchedAmount,
            uint64 odds,
            int32 theNumber,
            uint256 contestId,
            address scorer
        )
    {
        IPositionModule posModule = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        );
        Position memory pos = posModule.getPosition(
            speculationId,
            user,
            oddsPairId,
            positionType
        );
        matchedAmount = pos.matchedAmount;
        if (matchedAmount == 0) {
            revert LeaderboardModule__NoMatchedAmount();
        }
        OddsPair memory oddsPair = posModule.getOddsPair(oddsPairId);
        odds = positionType == PositionType.Upper
            ? oddsPair.upperOdds
            : oddsPair.lowerOdds;
        Speculation memory spec = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);
        theNumber = spec.theNumber;
        contestId = spec.contestId;
        scorer = spec.speculationScorer;
        return (matchedAmount, odds, theNumber, contestId, scorer);
    }

    /**
     * @notice Internal helper to calculate ROI
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @param declaredBankroll The declared bankroll of the user
     * @return roi The ROI of the user
     */
    function _calculateROI(
        uint256 leaderboardId,
        address user,
        uint256 declaredBankroll
    ) internal view returns (int256 roi) {
        // --- Sum up net profit/loss for all leaderboard-eligible positions ---
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
        // --- ROI = net / declaredBankroll ---
        roi = (net * int256(ROI_PRECISION)) / int256(declaredBankroll);
        return roi;
    }

    /**
     * @notice Internal helper to calculate the net profit/loss for a position
     * @param lbPos The leaderboard position
     * @return net The net profit/loss for the position
     */
    function _calculatePositionNet(
        LeaderboardPosition storage lbPos
    ) internal view returns (int256 net) {
        // --- Fetch the speculation result ---
        Speculation memory spec = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(lbPos.speculationId);

        // --- Fetch the odds precision ---
        uint256 oddsPrecision = uint256(
            IPositionModule(_getModule(keccak256("POSITION_MODULE")))
                .ODDS_PRECISION()
        );

        // --- Retrieve outcome ---
        bool isWinner = _isLeaderboardPositionWinner(lbPos, spec);
        bool isPushOrVoid = (spec.winSide == WinSide.Push ||
            spec.winSide == WinSide.Void ||
            spec.winSide == WinSide.Forfeit);

        uint256 payout;
        if (isPushOrVoid) {
            payout = lbPos.amount;
        } else if (isWinner) {
            payout = (lbPos.amount * lbPos.odds) / oddsPrecision;
        } else {
            payout = 0;
        }

        // --- Net = payout - amount ---
        return int256(payout) - int256(lbPos.amount);
    }

    /**
     * @notice Internal helper to check if a leaderboard position is a winner
     * @param lbPos The leaderboard position
     * @param spec The speculation
     * @return isWinner True if the position is a winner, false otherwise
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
     * @return claimWindowStart The start of the claim window
     * @return claimWindowEnd The end of the claim window
     */
    function _calculateTimeBounds(
        Leaderboard storage lb
    )
        internal
        view
        returns (
            uint256 roiWindowStart,
            uint256 roiWindowEnd,
            uint256 claimWindowStart,
            uint256 claimWindowEnd
        )
    {
        roiWindowStart = lb.endTime + lb.safetyPeriodDuration;
        roiWindowEnd = roiWindowStart + lb.roiSubmissionWindow;
        claimWindowStart = roiWindowEnd;
        claimWindowEnd = claimWindowStart + lb.claimWindow;
        return (roiWindowStart, roiWindowEnd, claimWindowStart, claimWindowEnd);
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
            revert LeaderboardModule__ModuleNotSet(moduleType);
        }
        return module;
    }

    // --- Getters ---
    /**
     * @notice Gets a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @return leaderboard The leaderboard
     */
    function getLeaderboard(
        uint256 leaderboardId
    ) external view override returns (Leaderboard memory) {
        return s_leaderboards[leaderboardId];
    }

    /**
     * @notice Gets a leaderboard position
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @param speculationId The ID of the speculation
     * @return leaderboardPosition The leaderboard position
     */
    function getLeaderboardPosition(
        uint256 leaderboardId,
        address user,
        uint256 speculationId
    ) external view override returns (LeaderboardPosition memory) {
        return s_leaderboardPositions[leaderboardId][user][speculationId];
    }

    // --- Explicit getters for LeaderboardScoring fields ---
    /**
     * @notice Gets the ROI for a user
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @return roi The ROI of the user
     */
    function getUserROI(
        uint256 leaderboardId,
        address user
    ) external view override returns (int256) {
        return s_leaderboardScoring[leaderboardId].userROIs[user];
    }

    /**
     * @notice Gets the winners of a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @return winners The winners of the leaderboard
     */
    function getWinners(
        uint256 leaderboardId
    ) external view override returns (address[] memory) {
        return s_leaderboardScoring[leaderboardId].winners;
    }

    /**
     * @notice Gets the highest ROI for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @return highestROI The highest ROI for the leaderboard
     */
    function getHighestROI(
        uint256 leaderboardId
    ) external view override returns (int256) {
        return s_leaderboardScoring[leaderboardId].highestROI;
    }

    /**
     * @notice Checks if a user has claimed a prize
     * @param leaderboardId The ID of the leaderboard
     * @param user The address of the user
     * @return hasClaimed True if the user has claimed a prize, false otherwise
     */
    function hasClaimed(
        uint256 leaderboardId,
        address user
    ) external view override returns (bool) {
        return s_leaderboardScoring[leaderboardId].hasClaimed[user];
    }
}
