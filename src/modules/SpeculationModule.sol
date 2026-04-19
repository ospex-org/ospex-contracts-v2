// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {IScorerModule} from "../interfaces/IScorerModule.sol";
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
 * @notice Handles speculation (betting market) creation and settlement for the Ospex protocol.
 * @dev Speculations are created by the PositionModule during the first fill of a new market.
 *      Settlement is permissionless — anyone can call settleSpeculation after the contest is scored.
 *      Auto-voids after the immutable cooldown if the contest remains unscored.
 */
contract SpeculationModule is ISpeculationModule {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant MONEYLINE_SCORER_MODULE =
        keccak256("MONEYLINE_SCORER_MODULE");
    bytes32 public constant TOTAL_SCORER_MODULE =
        keccak256("TOTAL_SCORER_MODULE");

    bytes32 public constant EVENT_SPECULATION_CREATED =
        keccak256("SPECULATION_CREATED");
    bytes32 public constant EVENT_SPECULATION_SETTLED =
        keccak256("SPECULATION_SETTLED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a non-PositionModule address calls a position-only function
    error SpeculationModule__NotAuthorized(address caller);
    /// @notice Thrown when attempting to settle an already-settled speculation
    error SpeculationModule__AlreadySettled();
    /// @notice Thrown when the speculation id does not yet exist
    error SpeculationModule__InvalidSpeculationId();
    /// @notice Thrown when attempting to settle before the contest has started (or contest has no start time)
    error SpeculationModule__InvalidStartTime();
    /// @notice Thrown when a speculation already exists for the given contest/scorer/line
    error SpeculationModule__SpeculationExists();
    /// @notice Thrown when attempting to create a speculation on a contest that is not in Verified status
    error SpeculationModule__InvalidContestStatus();
    /// @notice Thrown when the OspexCore address is zero
    error SpeculationModule__InvalidAddress();
    /// @notice Thrown when a required module is not registered in OspexCore
    error SpeculationModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the scorer address is not an approved scorer module
    error SpeculationModule__ScorerNotApproved();
    /// @notice Thrown when line ticks are invalid for the scorer type
    error SpeculationModule__InvalidLineTicks();
    /// @notice Thrown when the contest is not yet scored and cooldown has not elapsed
    error SpeculationModule__ContestNotFinalized(uint256 contestId);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a new speculation is created
    /// @param speculationId The speculation ID
    /// @param contestId The contest this speculation is for
    /// @param scorer The scorer module address
    /// @param lineTicks The line number (10x format)
    /// @param maker The address that initiated the market
    /// @param taker The address that completed the market
    event SpeculationCreated(
        uint256 indexed speculationId,
        uint256 indexed contestId,
        address scorer,
        int32 lineTicks,
        address maker,
        address taker
    );

    /// @notice Emitted when a speculation is settled
    /// @param speculationId The speculation ID
    /// @param winner The winning side
    /// @param scorer The scorer module that determined the outcome
    event SpeculationSettled(
        uint256 indexed speculationId,
        WinSide winner,
        address scorer
    );

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice Seconds after contest start before unscored speculations auto-void
    uint32 public immutable i_voidCooldown;

    /// @notice Auto-incrementing speculation ID counter
    uint256 public s_speculationIdCounter;
    /// @notice Speculation ID → Speculation struct
    mapping(uint256 => Speculation) public s_speculations;
    /// @notice Reverse lookup: contest ID → scorer → lineTicks → speculation ID
    mapping(uint256 => mapping(address => mapping(int32 => uint256)))
        public s_speculationLookup;

    /**
     * @notice Deploys the SpeculationModule with immutable configuration
     * @param ospexCore The OspexCore contract address
     * @param voidCooldown Seconds after contest start before auto-void
     */
    constructor(address ospexCore, uint32 voidCooldown) {
        if (ospexCore == address(0)) {
            revert SpeculationModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(ospexCore);
        i_voidCooldown = voidCooldown;
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return SPECULATION_MODULE;
    }

    // ──────────────────────────── Speculation Creation ─────────────────

    /// @inheritdoc ISpeculationModule
    function createSpeculation(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        address maker,
        address taker
    ) external override returns (uint256) {
        if (msg.sender != _getModule(POSITION_MODULE)) {
            revert SpeculationModule__NotAuthorized(msg.sender);
        }
        return _createSpeculation(contestId, scorer, lineTicks, maker, taker);
    }

    /**
     * @notice Internal speculation creation logic
     * @dev Validates contest state, scorer approval, line ticks, charges split fee,
     *      and stores the speculation with reverse lookup.
     * @param contestId The contest ID
     * @param scorer The scorer module address
     * @param lineTicks The line number (10x format)
     * @param maker The address that initiated the market
     * @param taker The address that completed the market
     * @return speculationId The new speculation ID
     */
    function _createSpeculation(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        address maker,
        address taker
    ) internal returns (uint256) {
        if (s_speculationLookup[contestId][scorer][lineTicks] != 0) {
            revert SpeculationModule__SpeculationExists();
        }

        Contest memory contest = IContestModule(_getModule(CONTEST_MODULE))
            .getContest(contestId);
        if (contest.contestStatus != ContestStatus.Verified)
            revert SpeculationModule__InvalidContestStatus();
        if (!i_ospexCore.isApprovedScorer(scorer)) {
            revert SpeculationModule__ScorerNotApproved();
        }

        if (
            (scorer == _getModule(MONEYLINE_SCORER_MODULE) && lineTicks != 0) ||
            (scorer == _getModule(TOTAL_SCORER_MODULE) && lineTicks < 0)
        ) {
            revert SpeculationModule__InvalidLineTicks();
        }

        i_ospexCore.processSplitFee(maker, taker, FeeType.SpeculationCreation);

        s_speculationIdCounter++;
        uint256 speculationId = s_speculationIdCounter;
        s_speculations[speculationId] = Speculation({
            contestId: contestId,
            speculationScorer: scorer,
            lineTicks: lineTicks,
            speculationTaker: taker,
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        });

        s_speculationLookup[contestId][scorer][lineTicks] = speculationId;

        emit SpeculationCreated(
            speculationId,
            contestId,
            scorer,
            lineTicks,
            maker,
            taker
        );
        i_ospexCore.emitCoreEvent(
            EVENT_SPECULATION_CREATED,
            abi.encode(
                speculationId,
                contestId,
                scorer,
                lineTicks,
                maker,
                taker
            )
        );
        return speculationId;
    }

    // ──────────────────────────── Settlement ──────────────────────────

    /// @inheritdoc ISpeculationModule
    function settleSpeculation(uint256 speculationId) external override {
        if (speculationId == 0 || speculationId > s_speculationIdCounter)
            revert SpeculationModule__InvalidSpeculationId();
        IContestModule contestModule = IContestModule(
            _getModule(CONTEST_MODULE)
        );

        Speculation storage s = s_speculations[speculationId];

        uint32 contestStartTime = contestModule.s_contestStartTimes(
            s.contestId
        );

        if (
            block.timestamp < uint256(contestStartTime) || contestStartTime == 0
        ) {
            revert SpeculationModule__InvalidStartTime();
        }
        if (s.speculationStatus == SpeculationStatus.Closed) {
            revert SpeculationModule__AlreadySettled();
        }

        Contest memory contest = contestModule.getContest(s.contestId);

        if (contest.contestStatus == ContestStatus.Scored) {
            IScorerModule scorer = IScorerModule(s.speculationScorer);
            WinSide winSide = scorer.determineWinSide(s.contestId, s.lineTicks);
            s.winSide = winSide;
            s.speculationStatus = SpeculationStatus.Closed;

            emit SpeculationSettled(
                speculationId,
                s.winSide,
                s.speculationScorer
            );
            i_ospexCore.emitCoreEvent(
                EVENT_SPECULATION_SETTLED,
                abi.encode(speculationId, s.winSide, s.speculationScorer)
            );
            return;
        }

        if (
            block.timestamp >=
            uint256(contestStartTime) + uint256(i_voidCooldown)
        ) {
            if (contest.contestStatus == ContestStatus.Verified) {
                contestModule.voidContest(s.contestId);
            }
            s.speculationStatus = SpeculationStatus.Closed;
            s.winSide = WinSide.Void;
            emit SpeculationSettled(
                speculationId,
                WinSide.Void,
                s.speculationScorer
            );
            i_ospexCore.emitCoreEvent(
                EVENT_SPECULATION_SETTLED,
                abi.encode(speculationId, WinSide.Void, s.speculationScorer)
            );
            return;
        }

        revert SpeculationModule__ContestNotFinalized(s.contestId);
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc ISpeculationModule
    function getSpeculation(
        uint256 speculationId
    ) external view override returns (Speculation memory) {
        return s_speculations[speculationId];
    }

    /// @inheritdoc ISpeculationModule
    function getSpeculationId(
        uint256 contestId,
        address scorer,
        int32 lineTicks
    ) external view override returns (uint256) {
        return s_speculationLookup[contestId][scorer][lineTicks];
    }

    /// @inheritdoc ISpeculationModule
    function isContestPastCooldown(
        uint256 contestId
    ) external view override returns (bool) {
        uint32 contestStartTime = IContestModule(_getModule(CONTEST_MODULE))
            .s_contestStartTimes(contestId);
        if (contestStartTime == 0) return false;
        return
            block.timestamp >=
            uint256(contestStartTime) + uint256(i_voidCooldown);
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
            revert SpeculationModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
