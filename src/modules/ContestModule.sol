// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    Contest,
    ContestStatus,
    ContestMarket,
    FeeType,
    LeagueId
} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";

/**
 * @title ContestModule
 * @notice Handles contest creation, scoring, and market data for the Ospex protocol.
 * @dev All mutations are restricted to the OracleModule. Scores are immutable once set —
 *      the protocol accepts oracle risk rather than allowing on-chain score overwrites.
 */
contract ContestModule is IContestModule {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant ORACLE_MODULE = keccak256("ORACLE_MODULE");
    bytes32 public constant TREASURY_MODULE = keccak256("TREASURY_MODULE");
    bytes32 public constant MONEYLINE_SCORER_MODULE =
        keccak256("MONEYLINE_SCORER_MODULE");
    bytes32 public constant SPREAD_SCORER_MODULE =
        keccak256("SPREAD_SCORER_MODULE");
    bytes32 public constant TOTAL_SCORER_MODULE =
        keccak256("TOTAL_SCORER_MODULE");

    bytes32 public constant EVENT_CONTEST_CREATED =
        keccak256("CONTEST_CREATED");
    bytes32 public constant EVENT_CONTEST_VERIFIED =
        keccak256("CONTEST_VERIFIED");
    bytes32 public constant EVENT_CONTEST_MARKETS_UPDATED =
        keccak256("CONTEST_MARKETS_UPDATED");
    bytes32 public constant EVENT_CONTEST_SCORES_SET =
        keccak256("CONTEST_SCORES_SET");
    bytes32 public constant EVENT_CONTEST_VOIDED = keccak256("CONTEST_VOIDED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a non-OracleModule address calls an oracle-only function
    error ContestModule__NotOracleModule(address caller);
    /// @notice Thrown when a non-SpeculationModule address calls a speculation-only function
    error ContestModule__NotSpeculationModule(address caller);
    /// @notice Thrown when the OspexCore address is zero
    error ContestModule__InvalidCoreAddress();
    /// @notice Thrown when a contest is missing all external IDs
    error ContestModule__InvalidValue();
    /// @notice Thrown when market data contains zero odds or negative total line
    error ContestModule__InvalidMarketData();
    /// @notice Thrown when a required module is not registered in OspexCore
    error ContestModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when attempting to score an already-scored contest
    error ContestModule__AlreadyScored(uint256 contestId);
    /// @notice Thrown when set contest league id and start time is attempted on a contest that is not unverified
    error ContestModule__InvalidStatus(uint256 contestId);
    /// @notice Thrown when the oracle callback leagueId conflicts with the league set from script approvals at creation
    error ContestModule__LeagueMismatch();
    /// @notice Thrown when attempting to void a contest that is not in Verified status
    error ContestModule__ContestNotVerified(uint256 contestId);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a new contest is created
    /// @param contestId The contest ID
    /// @param rundownId External ID from Rundown API
    /// @param sportspageId External ID from Sportspage API
    /// @param jsonoddsId External ID from JSONOdds API
    /// @param verifySourceHash Hash of the verification source code for this contest
    /// @param marketUpdateSourceHash Hash of the market update code for this contest
    /// @param scoreContestSourceHash Hash of the scoring source code for this contest
    /// @param approvedLeagueId The LeagueId for this contest
    /// @param contestCreator The address that created (and paid for) the contest
    event ContestCreated(
        uint256 indexed contestId,
        string rundownId,
        string sportspageId,
        string jsonoddsId,
        bytes32 verifySourceHash,
        bytes32 marketUpdateSourceHash,
        bytes32 scoreContestSourceHash,
        LeagueId approvedLeagueId,
        address indexed contestCreator
    );

    /// @notice Emitted when a contest is verified with league and start time
    /// @param contestId The contest ID
    /// @param leagueId The resolved league ID (may differ from creation if created as Unknown)
    /// @param startTime The contest start timestamp
    event ContestVerified(
        uint256 indexed contestId,
        LeagueId leagueId,
        uint256 startTime
    );

    /// @notice Emitted when market data is updated for a contest
    /// @param contestId The contest ID
    /// @param lastUpdated Timestamp of the update
    /// @param spreadLineTicks The spread line (10x format)
    /// @param totalLineTicks The total line (10x format)
    /// @param moneylineAwayOdds Away moneyline odds tick
    /// @param moneylineHomeOdds Home moneyline odds tick
    /// @param spreadAwayOdds Away spread odds tick
    /// @param spreadHomeOdds Home spread odds tick
    /// @param overOdds Over odds tick
    /// @param underOdds Under odds tick
    event ContestMarketsUpdated(
        uint256 indexed contestId,
        uint32 lastUpdated,
        int32 spreadLineTicks,
        int32 totalLineTicks,
        uint16 moneylineAwayOdds,
        uint16 moneylineHomeOdds,
        uint16 spreadAwayOdds,
        uint16 spreadHomeOdds,
        uint16 overOdds,
        uint16 underOdds
    );

    /// @notice Emitted when final scores are set for a contest
    /// @param contestId The contest ID
    /// @param awayScore Final away team score
    /// @param homeScore Final home team score
    event ContestScoresSet(
        uint256 indexed contestId,
        uint32 awayScore,
        uint32 homeScore
    );

    /// @notice Emitted when a contest is voided due to cooldown expiry without scoring
    /// @param contestId The contest ID
    event ContestVoided(uint256 indexed contestId);

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @dev Restricts access to the registered OracleModule
    modifier onlyOracleModule() {
        if (msg.sender != _getModule(ORACLE_MODULE)) {
            revert ContestModule__NotOracleModule(msg.sender);
        }
        _;
    }

    /// @dev Restricts access to the registered SpeculationModule
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(SPECULATION_MODULE)) {
            revert ContestModule__NotSpeculationModule(msg.sender);
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Auto-incrementing contest ID counter
    uint256 public s_contestIdCounter;

    /// @notice Contest ID → Contest struct
    mapping(uint256 => Contest) private s_contests;

    /// @notice Contest ID → start timestamp (set during verification)
    mapping(uint256 => uint32) public s_contestStartTimes;

    /// @notice Contest ID → scorer address → ContestMarket
    mapping(uint256 => mapping(address => ContestMarket))
        private s_contestMarket;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the ContestModule
    /// @param ospexCore_ The OspexCore contract address
    constructor(address ospexCore_) {
        if (ospexCore_ == address(0)) {
            revert ContestModule__InvalidCoreAddress();
        }
        i_ospexCore = OspexCore(ospexCore_);
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return CONTEST_MODULE;
    }

    // ──────────────────────────── Contest Creation ─────────────────────

    /// @inheritdoc IContestModule
    function createContest(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId,
        bytes32 verifySourceHash,
        bytes32 marketUpdateSourceHash,
        bytes32 scoreContestSourceHash,
        LeagueId approvedLeagueId,
        address contestCreator
    ) external override onlyOracleModule returns (uint256 contestId) {
        if (
            bytes(rundownId).length == 0 &&
            bytes(sportspageId).length == 0 &&
            bytes(jsonoddsId).length == 0
        ) {
            revert ContestModule__InvalidValue();
        }

        i_ospexCore.processFee(contestCreator, FeeType.ContestCreation);

        s_contestIdCounter++;
        contestId = s_contestIdCounter;
        Contest storage c = s_contests[contestId];
        c.rundownId = rundownId;
        c.sportspageId = sportspageId;
        c.jsonoddsId = jsonoddsId;
        c.verifySourceHash = verifySourceHash;
        c.marketUpdateSourceHash = marketUpdateSourceHash;
        c.scoreContestSourceHash = scoreContestSourceHash;
        c.leagueId = approvedLeagueId;
        c.contestCreator = contestCreator;
        c.contestStatus = ContestStatus.Unverified;

        emit ContestCreated(
            contestId,
            rundownId,
            sportspageId,
            jsonoddsId,
            verifySourceHash,
            marketUpdateSourceHash,
            scoreContestSourceHash,
            approvedLeagueId,
            contestCreator
        );
        i_ospexCore.emitCoreEvent(
            EVENT_CONTEST_CREATED,
            abi.encode(
                contestId,
                rundownId,
                sportspageId,
                jsonoddsId,
                verifySourceHash,
                marketUpdateSourceHash,
                scoreContestSourceHash,
                approvedLeagueId,
                contestCreator
            )
        );
    }

    // ──────────────────────────── Market Data ─────────────────────────

    /// @inheritdoc IContestModule
    function updateContestMarkets(
        uint256 contestId,
        uint16 moneylineAwayOdds,
        uint16 moneylineHomeOdds,
        int32 spreadLineTicks,
        uint16 spreadAwayOdds,
        uint16 spreadHomeOdds,
        int32 totalLineTicks,
        uint16 overOdds,
        uint16 underOdds
    ) external override onlyOracleModule {
        if (s_contests[contestId].contestStatus != ContestStatus.Verified)
            revert ContestModule__ContestNotVerified(contestId);
        if (
            moneylineAwayOdds == 0 ||
            moneylineHomeOdds == 0 ||
            spreadAwayOdds == 0 ||
            spreadHomeOdds == 0 ||
            overOdds == 0 ||
            underOdds == 0 ||
            totalLineTicks < 0
        ) {
            revert ContestModule__InvalidMarketData();
        }
        uint32 timestamp = uint32(block.timestamp);

        address moneylineScorer = _getModule(MONEYLINE_SCORER_MODULE);
        address spreadScorer = _getModule(SPREAD_SCORER_MODULE);
        address totalScorer = _getModule(TOTAL_SCORER_MODULE);

        s_contestMarket[contestId][moneylineScorer] = ContestMarket({
            lineTicks: 0,
            upperOdds: moneylineAwayOdds,
            lowerOdds: moneylineHomeOdds,
            lastUpdated: timestamp
        });

        s_contestMarket[contestId][spreadScorer] = ContestMarket({
            lineTicks: spreadLineTicks,
            upperOdds: spreadAwayOdds,
            lowerOdds: spreadHomeOdds,
            lastUpdated: timestamp
        });

        s_contestMarket[contestId][totalScorer] = ContestMarket({
            lineTicks: totalLineTicks,
            upperOdds: overOdds,
            lowerOdds: underOdds,
            lastUpdated: timestamp
        });

        emit ContestMarketsUpdated(
            contestId,
            timestamp,
            spreadLineTicks,
            totalLineTicks,
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadAwayOdds,
            spreadHomeOdds,
            overOdds,
            underOdds
        );

        i_ospexCore.emitCoreEvent(
            EVENT_CONTEST_MARKETS_UPDATED,
            abi.encode(
                contestId,
                timestamp,
                spreadLineTicks,
                totalLineTicks,
                moneylineAwayOdds,
                moneylineHomeOdds,
                spreadAwayOdds,
                spreadHomeOdds,
                overOdds,
                underOdds
            )
        );
    }

    // ──────────────────────────── Verification & Scoring ──────────────

    /// @inheritdoc IContestModule
    function setContestLeagueIdAndStartTime(
        uint256 contestId,
        LeagueId leagueId,
        uint32 startTime
    ) external override onlyOracleModule {
        if (leagueId == LeagueId.Unknown || startTime == 0) {
            revert ContestModule__InvalidValue();
        }
        if (s_contests[contestId].contestStatus != ContestStatus.Unverified)
            revert ContestModule__InvalidStatus(contestId);
        if (
            s_contests[contestId].leagueId != LeagueId.Unknown &&
            s_contests[contestId].leagueId != leagueId
        ) revert ContestModule__LeagueMismatch();
        s_contests[contestId].leagueId = leagueId;
        s_contestStartTimes[contestId] = startTime;
        s_contests[contestId].contestStatus = ContestStatus.Verified;
        emit ContestVerified(contestId, leagueId, startTime);
        i_ospexCore.emitCoreEvent(
            EVENT_CONTEST_VERIFIED,
            abi.encode(contestId, leagueId, startTime)
        );
    }

    /**
     * @notice Sets the final oracle score for a contest
     * @dev Oracle-set scores are immutable once written. This intentionally favors
     *      settlement finality over discretionary score correction. If upstream data sources
     *      disagree, scoring should fail before this function is reached. If a wrong but
     *      internally consistent result is submitted first, the protocol accepts that as
     *      oracle risk rather than allowing on-chain score overwrites.
     * @param contestId The ID of the contest
     * @param awayScore The away score
     * @param homeScore The home score
     */
    function setScores(
        uint256 contestId,
        uint32 awayScore,
        uint32 homeScore
    ) external override onlyOracleModule {
        if (s_contests[contestId].contestStatus != ContestStatus.Verified) {
            revert ContestModule__AlreadyScored(contestId);
        }
        s_contests[contestId].awayScore = awayScore;
        s_contests[contestId].homeScore = homeScore;
        s_contests[contestId].contestStatus = ContestStatus.Scored;
        emit ContestScoresSet(contestId, awayScore, homeScore);
        i_ospexCore.emitCoreEvent(
            EVENT_CONTEST_SCORES_SET,
            abi.encode(contestId, awayScore, homeScore)
        );
    }

    /// @inheritdoc IContestModule
    function voidContest(uint256 contestId) external onlySpeculationModule {
        if (s_contests[contestId].contestStatus != ContestStatus.Verified) {
            revert ContestModule__ContestNotVerified(contestId);
        }
        s_contests[contestId].contestStatus = ContestStatus.Voided;
        emit ContestVoided(contestId);
        i_ospexCore.emitCoreEvent(EVENT_CONTEST_VOIDED, abi.encode(contestId));
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc IContestModule
    function getContest(
        uint256 contestId
    ) external view override returns (Contest memory contest) {
        contest = s_contests[contestId];
    }

    /// @inheritdoc IContestModule
    function isContestTerminal(
        uint256 contestId
    ) external view override returns (bool) {
        return
            s_contests[contestId].contestStatus == ContestStatus.Scored ||
            s_contests[contestId].contestStatus == ContestStatus.Voided;
    }

    /// @inheritdoc IContestModule
    function getContestMarket(
        uint256 contestId,
        address scorer
    ) external view override returns (ContestMarket memory contestMarket) {
        contestMarket = s_contestMarket[contestId][scorer];
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
            revert ContestModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
