// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {IModule} from "../interfaces/IModule.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {
    Speculation,
    SpeculationStatus,
    WinSide,
    Contest,
    ContestStatus,
    FeeType
} from "../core/OspexTypes.sol";

/**
 * @title SpeculationModule
 * @notice Handles speculation creation, storage, and status management for Ospex protocol
 * @dev All business logic for speculations is implemented here.
 */

contract SpeculationModule is ISpeculationModule {
    // --- Custom Errors ---
    /// @notice Error for calling the module from non-authorized address
    error SpeculationModule__NotAuthorized(address caller);
    /// @notice Error for already settled speculation
    error SpeculationModule__AlreadySettled();
    /// @notice Error for speculation not started
    error SpeculationModule__SpeculationNotStarted();
    /// @notice Error for speculation already exists
    error SpeculationModule__SpeculationExists();
    /// @notice Error for void cooldown not met
    error SpeculationModule__VoidCooldownNotMet();
    /// @notice Error for void cooldown below minimum
    error SpeculationModule__VoidCooldownBelowMinimum(uint32 cooldown);
    /// @notice Error for speculation not open
    error SpeculationModule__SpeculationNotOpen();
    /// @notice Error for contest not finalized
    error SpeculationModule__ContestNotFinalized(uint256 contestId);
    /// @notice Error for contest not verified
    error SpeculationModule__ContestNotVerified();
    /// @notice Error for minimum above maximum
    error SpeculationModule__MinAboveMax(uint256 minAmount, uint256 maxAmount);
    /// @notice Error for maximum below minimum
    error SpeculationModule__MaxBelowMin(uint256 maxAmount, uint256 minAmount);
    /// @notice Error for not admin
    error SpeculationModule__NotAdmin(address admin);
    /// @notice Error for invalid address
    error SpeculationModule__InvalidAddress();
    /// @notice Error for module not set
    error SpeculationModule__ModuleNotSet(bytes32 moduleType);

    // --- Constants ---
    /// @notice The role of the Speculation Manager Role
    bytes32 public constant SPECULATION_MANAGER_ROLE =
        keccak256("SPECULATION_MANAGER_ROLE");

    // --- Storage ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The number of decimals for the token (e.g., 6 for USDC, 18 for ETH)
    uint8 public immutable i_tokenDecimals;
    /// @notice The speculation ID counter
    /// @dev If this module is replaced, initialize this counter in the new module
    ///      to the last used speculation ID to avoid ID collisions.
    uint256 public s_speculationIdCounter;
    /// @notice The void cooldown
    uint32 public s_voidCooldown = 3 days;
    /// @notice The minimum void cooldown
    uint32 public constant MIN_VOID_COOLDOWN = 1 days;
    /// @notice The maximum speculation amount
    uint256 public s_maxSpeculationAmount;
    /// @notice The minimum speculation amount
    uint256 public s_minSpeculationAmount;
    /// @notice The speculations
    mapping(uint256 => Speculation) public s_speculations;
    /// @notice Reverse lookup: contestId => scorer => theNumber => speculationId
    mapping(uint256 => mapping(address => mapping(int32 => uint256)))
        public s_speculationLookup;

    // --- Events ---
    /**
     * @notice Event for speculation creation
     * @param speculationId The ID of the speculation
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The number of the speculation
     * @param speculationCreator The creator of the speculation
     */
    event SpeculationCreated(
        uint256 indexed speculationId,
        uint256 indexed contestId,
        address scorer,
        int32 theNumber,
        address speculationCreator
    );

    /**
     * @notice Event for speculation settlement
     * @param speculationId The ID of the speculation
     * @param winner The winner of the speculation
     * @param scorer The scorer of the speculation
     */
    event SpeculationSettled(
        uint256 indexed speculationId,
        WinSide winner,
        address scorer
    );

    /**
     * @notice Event for speculation forfeiture
     * @param speculationId The ID of the speculation
     * @param forfeiter The forfeiter of the speculation
     */
    event SpeculationForfeited(
        uint256 indexed speculationId,
        address forfeiter
    );

    /**
     * @notice Event for void cooldown set
     * @param newVoidCooldown The new void cooldown
     */
    event VoidCooldownSet(uint32 newVoidCooldown);

    /**
     * @notice Event for maximum speculation amount set
     * @param newAmount The new maximum speculation amount
     */
    event MaxSpeculationAmountSet(uint256 newAmount);

    /**
     * @notice Event for minimum speculation amount set
     * @param newAmount The new minimum speculation amount
     */
    event MinSpeculationAmountSet(uint256 newAmount);

    // --- Modifiers ---
    /**
     * @notice Modifier for speculation open
     * @param speculationId The ID of the speculation
     */
    modifier speculationOpen(uint256 speculationId) {
        if (
            s_speculations[speculationId].speculationStatus !=
            SpeculationStatus.Open
        ) {
            revert SpeculationModule__SpeculationNotOpen();
        }
        _;
    }

    /**
     * @notice Modifier to restrict function to only the OspexCore contract
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert SpeculationModule__NotAdmin(msg.sender);
        }
        _;
    }

    /**
     * @notice Constructor for the speculation module
     * @param ospexCore The address of the OspexCore contract
     * @param tokenDecimals The number of decimals for the token
     */
    constructor(address ospexCore, uint8 tokenDecimals) {
        if (ospexCore == address(0)) {
            revert SpeculationModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(ospexCore);
        i_tokenDecimals = tokenDecimals;
        s_minSpeculationAmount = 1 * (10 ** tokenDecimals);
        s_maxSpeculationAmount = 100 * (10 ** tokenDecimals);
    }

    // --- IModule ---
    /**
     * @notice Returns the module type
     * @return moduleType The module type
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("SPECULATION_MODULE");
    }

    // --- ISpeculationModule ---
    /**
     * @notice Creates a speculation
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The number of the speculation
     * @param speculationCreator The address of the speculation creator
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @return speculationId The ID of the speculation
     */
    function createSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        address speculationCreator,
        uint256 leaderboardId
    ) external override returns (uint256) {
        if (msg.sender != _getModule(keccak256("POSITION_MODULE"))) {
            revert SpeculationModule__NotAuthorized(msg.sender);
        }
        return
            _createSpeculation(
                contestId,
                scorer,
                theNumber,
                speculationCreator,
                leaderboardId
            );
    }

    // --- ISpeculationModule ---
    /**
     * @notice Settles a speculation
     * @param speculationId The ID of the speculation
     */
    function settleSpeculation(uint256 speculationId) external override {
        Speculation storage s = s_speculations[speculationId];

        // Get contest start time for timing validation
        uint32 contestStartTime = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).s_contestStartTimes(s.contestId);

        if (uint32(block.timestamp) < contestStartTime) {
            revert SpeculationModule__SpeculationNotStarted();
        }
        if (s.speculationStatus == SpeculationStatus.Closed) {
            revert SpeculationModule__AlreadySettled();
        }
        // Auto-void if voidCooldown has passed
        if (uint32(block.timestamp) >= contestStartTime + s_voidCooldown) {
            s.speculationStatus = SpeculationStatus.Closed;
            s.winSide = WinSide.Void;
            emit SpeculationSettled(
                speculationId,
                WinSide.Void,
                s.speculationScorer
            );
            // Emit protocol-wide core event
            i_ospexCore.emitCoreEvent(
                keccak256("SPECULATION_SETTLED"),
                abi.encode(speculationId, WinSide.Void, s.speculationScorer)
            );
            return;
        }

        // Get contest status from ContestModule
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(s.contestId);
        if (
            !(contest.contestStatus == ContestStatus.Scored ||
                contest.contestStatus == ContestStatus.ScoredManually)
        ) {
            revert SpeculationModule__ContestNotFinalized(s.contestId);
        }

        // Call the scorer module
        IScorerModule scorer = IScorerModule(s.speculationScorer);
        s.winSide = scorer.determineWinSide(s.contestId, s.theNumber);
        s.speculationStatus = SpeculationStatus.Closed;

        emit SpeculationSettled(speculationId, s.winSide, s.speculationScorer);
        i_ospexCore.emitCoreEvent(
            keccak256("SPECULATION_SETTLED"),
            abi.encode(speculationId, s.winSide, s.speculationScorer)
        );
    }

    /**
     * @notice Forfeits a speculation
     * @param speculationId The ID of the speculation
     */
    function forfeitSpeculation(
        uint256 speculationId
    ) external override speculationOpen(speculationId) {
        if (!i_ospexCore.hasRole(SPECULATION_MANAGER_ROLE, msg.sender)) {
            revert SpeculationModule__NotAuthorized(msg.sender);
        }
        Speculation storage s = s_speculations[speculationId];

        // Get contest start time for timing validation
        uint32 contestStartTime = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).s_contestStartTimes(s.contestId);

        if (contestStartTime + s_voidCooldown > uint32(block.timestamp)) {
            revert SpeculationModule__VoidCooldownNotMet();
        }
        s.speculationStatus = SpeculationStatus.Closed;
        s.winSide = WinSide.Forfeit;
        emit SpeculationForfeited(speculationId, msg.sender);
        // Emit protocol-wide core event
        i_ospexCore.emitCoreEvent(
            keccak256("SPECULATION_FORFEITED"),
            abi.encode(speculationId, msg.sender)
        );
    }

    /**
     * @notice Internal function to create a speculation
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The number of the speculation
     * @param speculationCreator The creator of the speculation
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @return speculationId The ID of the speculation
     */
    function _createSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        address speculationCreator,
        uint256 leaderboardId
    ) internal returns (uint256) {
        if (s_speculationLookup[contestId][scorer][theNumber] != 0) {
            revert SpeculationModule__SpeculationExists();
        }

        // Validate contest exists and is verified
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);
        if (contest.contestStatus == ContestStatus.Unverified) {
            revert SpeculationModule__ContestNotVerified();
        }

        // Charge the speculation creation fee
        uint256 feeAmount = ITreasuryModule(
            _getModule(keccak256("TREASURY_MODULE"))
        ).getFeeRate(FeeType.SpeculationCreation);
        if (feeAmount > 0) {
            i_ospexCore.processFee(
                speculationCreator,
                feeAmount,
                FeeType.SpeculationCreation,
                leaderboardId
            );
        }

        s_speculationIdCounter++;
        uint256 speculationId = s_speculationIdCounter;
        s_speculations[speculationId] = Speculation({
            contestId: contestId,
            speculationScorer: scorer,
            theNumber: theNumber,
            speculationCreator: speculationCreator,
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        });

        // Populate reverse lookup
        s_speculationLookup[contestId][scorer][theNumber] = speculationId;

        emit SpeculationCreated(
            speculationId,
            contestId,
            scorer,
            theNumber,
            speculationCreator
        );
        // Emit protocol-wide core event
        i_ospexCore.emitCoreEvent(
            keccak256("SPECULATION_CREATED"),
            abi.encode(
                speculationId,
                contestId,
                scorer,
                theNumber,
                speculationCreator
            )
        );
        return speculationId;
    }

    /**
     * @notice Gets a speculation
     * @param speculationId The ID of the speculation
     * @return speculation The speculation
     */
    function getSpeculation(
        uint256 speculationId
    ) external view override returns (Speculation memory) {
        return s_speculations[speculationId];
    }

    /**
     * @notice Gets a speculation ID by contest parameters
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The number of the speculation
     * @return speculationId The ID of the speculation (0 if doesn't exist)
     */
    function getSpeculationId(
        uint256 contestId,
        address scorer,
        int32 theNumber
    ) external view override returns (uint256) {
        return s_speculationLookup[contestId][scorer][theNumber];
    }

    /**
     * @notice Sets the minimum speculation amount
     * @param minAmount The new minimum speculation amount
     */
    function setMinSpeculationAmount(
        uint256 minAmount
    ) external override onlyAdmin {
        uint256 minWithDecimals = minAmount * (10 ** i_tokenDecimals);
        if (minWithDecimals > s_maxSpeculationAmount) {
            revert SpeculationModule__MinAboveMax(
                minWithDecimals,
                s_maxSpeculationAmount
            );
        }
        s_minSpeculationAmount = minWithDecimals;
        emit MinSpeculationAmountSet(minWithDecimals);
        // Emit protocol-wide core event
        i_ospexCore.emitCoreEvent(
            keccak256("MIN_SPECULATION_AMOUNT_SET"),
            abi.encode(minWithDecimals)
        );
    }

    /**
     * @notice Sets the maximum speculation amount
     * @param maxAmount The new maximum speculation amount
     */
    function setMaxSpeculationAmount(
        uint256 maxAmount
    ) external override onlyAdmin {
        uint256 maxWithDecimals = maxAmount * (10 ** i_tokenDecimals);
        if (maxWithDecimals < s_minSpeculationAmount) {
            revert SpeculationModule__MaxBelowMin(
                maxWithDecimals,
                s_minSpeculationAmount
            );
        }
        s_maxSpeculationAmount = maxWithDecimals;
        emit MaxSpeculationAmountSet(maxWithDecimals);
        // Emit protocol-wide core event
        i_ospexCore.emitCoreEvent(
            keccak256("MAX_SPECULATION_AMOUNT_SET"),
            abi.encode(maxWithDecimals)
        );
    }

    /**
     * @notice Sets the void cooldown
     * @param newVoidCooldown The new void cooldown
     */
    function setVoidCooldown(
        uint32 newVoidCooldown
    ) external override onlyAdmin {
        if (newVoidCooldown < MIN_VOID_COOLDOWN) {
            revert SpeculationModule__VoidCooldownBelowMinimum(newVoidCooldown);
        }
        s_voidCooldown = newVoidCooldown;
        emit VoidCooldownSet(newVoidCooldown);
        // Emit protocol-wide core event
        i_ospexCore.emitCoreEvent(
            keccak256("VOID_COOLDOWN_SET"),
            abi.encode(newVoidCooldown)
        );
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
            revert SpeculationModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
