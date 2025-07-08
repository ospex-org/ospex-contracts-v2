// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Contest, ContestStatus, FeeType, LeagueId} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";

/**
 * @title ContestModule
 * @notice Handles contest creation, storage, and status management for Ospex protocol
 * @dev All business logic for contests is implemented here. Oracle integration is handled in OracleModule.
 */
contract ContestModule is IContestModule {
    // --- Custom Errors ---
    /// @notice Error for calling the module from non-OracleModule
    error ContestModule__NotOracleModule(address caller);
    /// @notice Error for calling the module from non-admin
    error ContestModule__NotAdmin(address caller);
    /// @notice Error for calling the module from non-authorized address
    error ContestModule__NotAuthorized(address caller);
    /// @notice Error for invalid core address
    error ContestModule__InvalidCoreAddress();
    /// @notice Error for contest not verified
    error ContestModule__ContestNotVerified(uint256 contestId);
    /// @notice Error for contest not started
    error ContestModule__ContestNotStarted(
        uint256 contestId,
        uint256 timeRemaining
    );
    /// @notice Error for contest not unverified
    error ContestModule__ContestNotUnverified(uint256 contestId);
    /// @notice Error for manual score wait period not met
    error ContestModule__ManualScoreWaitPeriodNotMet(
        uint256 contestId,
        uint256 timeRemaining
    );
    /// @notice Error for invalid leaderboard ids
    error ContestModule__InvalidLeaderboardIds();
    /// @notice Error for module not set
    error ContestModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Error for invalid create contest source hash
    error ContestModule__InvalidCreateContestSourceHash();

    // --- Constants ---
    /// @notice The role of the ScoreManager, for manual score setting
    bytes32 public constant SCORE_MANAGER_ROLE =
        keccak256("SCORE_MANAGER_ROLE");
    /// @notice The manual score wait period, in the event that a contest is not scored by the OracleModule
    uint256 public constant MANUAL_SCORE_WAIT_PERIOD = 2 days;

    // --- Storage ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The contest ID counter
    /// @dev If this module is replaced, initialize this counter in the new module
    ///      to the last used contest ID to avoid ID collisions.
    uint256 public s_contestIdCounter;
    /// @notice The hash of the create contest source
    bytes32 public s_createContestSourceHash;
    /// @notice Mapping of contestId to Contest struct
    mapping(uint256 => Contest) private s_contests;
    /// @notice The contest start times
    mapping(uint256 => uint32) public s_contestStartTimes;

    // --- Events ---
    /**
     * @notice Emitted when a contest is created
     * @param contestId The ID of the contest
     * @param rundownId The ID of the rundown
     * @param sportspageId The ID of the sportspage
     * @param jsonoddsId The ID of the jsonodds
     * @param contestCreator The address of the contest creator
     * @param scoreContestSourceHash The hash of the contest source
     */
    event ContestCreated(
        uint256 indexed contestId,
        string rundownId,
        string sportspageId,
        string jsonoddsId,
        address indexed contestCreator,
        bytes32 scoreContestSourceHash
    );

    /**
     * @notice Emitted when a contest's status is verified
     * @param contestId The ID of the contest
     * @param startTime The start time of the contest
     */
    event ContestVerified(uint256 indexed contestId, uint256 startTime);

    /**
     * @notice Emitted when a contest's scores are set
     * @param contestId The ID of the contest
     * @param awayScore The away score
     * @param homeScore The home score
     */
    event ContestScoresSet(
        uint256 indexed contestId,
        uint32 awayScore,
        uint32 homeScore
    );

    /**
     * @notice Emitted when a contest's scores are set manually
     * @param contestId The ID of the contest
     * @param awayScore The away score
     * @param homeScore The home score
     */
    event ContestScoresSetManually(
        uint256 indexed contestId,
        uint32 awayScore,
        uint32 homeScore
    );

    /**
     * @notice Emitted when the create contest source hash is set
     * @param oldCreateContestSourceHash The old create contest source hash
     * @param newCreateContestSourceHash The new create contest source hash
     */
    event CreateContestSourceHashSet(
        bytes32 oldCreateContestSourceHash,
        bytes32 newCreateContestSourceHash
    );

    // --- Modifiers ---
    /**
     * @notice Modifier to ensure the caller is the OracleModule
     */
    modifier onlyOracleModule() {
        if (msg.sender != _getModule(keccak256("ORACLE_MODULE"))) {
            revert ContestModule__NotOracleModule(msg.sender);
        }
        _;
    }

    /**
     * @notice Modifier to ensure the caller is an admin
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert ContestModule__NotAdmin(msg.sender);
        }
        _;
    }

    /**
     * @notice Constructor sets the OspexCore address
     * @param _ospexCore The address of the OspexCore contract
     * @param _createContestSourceHash The hash of the create contest source
     */
    constructor(address _ospexCore, bytes32 _createContestSourceHash) {
        if (_ospexCore == address(0)) {
            revert ContestModule__InvalidCoreAddress();
        }
        i_ospexCore = OspexCore(_ospexCore);
        s_createContestSourceHash = _createContestSourceHash;
    }

    /**
     * @notice Returns the module type identifier
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("CONTEST_MODULE");
    }

    /**
     * @inheritdoc IContestModule
     * @dev Only callable by the OracleModule (enforced via core registry)
     */

    /**
     * @notice Creates a new contest
     * @param rundownId The ID of the rundown
     * @param sportspageId The ID of the sportspage
     * @param jsonoddsId The ID of the jsonodds
     * @param scoreContestSourceHash The hash of the contest source
     * @param contestCreator The address of the contest creator
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     */
    function createContest(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId,
        bytes32 scoreContestSourceHash,
        address contestCreator,
        uint256 leaderboardId
    ) external override onlyOracleModule returns (uint256 contestId) {
        // Charge the contest creation fee
        uint256 feeAmount = ITreasuryModule(
            _getModule(keccak256("TREASURY_MODULE"))
        ).getFeeRate(FeeType.ContestCreation);
        if (feeAmount > 0) {
            i_ospexCore.handleFee(
                contestCreator,
                feeAmount,
                FeeType.ContestCreation,
                leaderboardId
            );
        }

        s_contestIdCounter++;
        contestId = s_contestIdCounter;
        Contest storage c = s_contests[contestId];
        c.rundownId = rundownId;
        c.sportspageId = sportspageId;
        c.jsonoddsId = jsonoddsId;
        c.scoreContestSourceHash = scoreContestSourceHash;
        c.contestCreator = contestCreator;
        c.contestStatus = ContestStatus.Unverified;
        // Scores default to 0

        emit ContestCreated(
            contestId,
            rundownId,
            sportspageId,
            jsonoddsId,
            contestCreator,
            scoreContestSourceHash
        );
        i_ospexCore.emitCoreEvent(
            keccak256("CONTEST_CREATED"),
            abi.encode(
                contestId,
                rundownId,
                sportspageId,
                jsonoddsId,
                contestCreator,
                scoreContestSourceHash
            )
        );
    }

    /**
     * @inheritdoc IContestModule
     * @dev Only callable by the admin
     */

    /**
     * @notice Sets the create contest source hash
     * @param newCreateContestSourceHash The hash of the create contest source
     */
    function setCreateContestSourceHash(
        bytes32 newCreateContestSourceHash
    ) external onlyAdmin {
        if (newCreateContestSourceHash == bytes32(0)) {
            revert ContestModule__InvalidCreateContestSourceHash();
        }
        bytes32 oldCreateContestSourceHash = s_createContestSourceHash;
        s_createContestSourceHash = newCreateContestSourceHash;
        emit CreateContestSourceHashSet(
            oldCreateContestSourceHash,
            newCreateContestSourceHash
        );
        i_ospexCore.emitCoreEvent(
            keccak256("CREATE_CONTEST_SOURCE_HASH_SET"),
            abi.encode(oldCreateContestSourceHash, newCreateContestSourceHash)
        );
    }

    /**
     * @inheritdoc IContestModule
     * @dev Only callable by the OracleModule, except for manual override (see setScores)
     */

    /**
     * @notice Sets the status and start time of a contest
     * @param contestId The ID of the contest
     * @param startTime The start time of the contest
     */
    function setContestLeagueIdAndStartTime(
        uint256 contestId,
        LeagueId leagueId,
        uint32 startTime
    ) external override onlyOracleModule {
        s_contests[contestId].leagueId = leagueId;
        s_contestStartTimes[contestId] = startTime;
        s_contests[contestId].contestStatus = ContestStatus.Verified;
        emit ContestVerified(contestId, startTime);
        i_ospexCore.emitCoreEvent(
            keccak256("CONTEST_VERIFIED"),
            abi.encode(contestId, startTime)
        );
    }

    /**
     * @inheritdoc IContestModule
     * @dev Only callable by the OracleModule, except for manual override after MANUAL_SCORE_WAIT_PERIOD by SCORE_MANAGER_ROLE
     */

    /**
     * @notice Sets the scores of a contest
     * @param contestId The ID of the contest
     * @param awayScore The away score
     * @param homeScore The home score
     */
    function setScores(
        uint256 contestId,
        uint32 awayScore,
        uint32 homeScore
    ) external override onlyOracleModule {
        s_contests[contestId].awayScore = awayScore;
        s_contests[contestId].homeScore = homeScore;
        s_contests[contestId].contestStatus = ContestStatus.Scored;
        emit ContestScoresSet(contestId, awayScore, homeScore);
        i_ospexCore.emitCoreEvent(
            keccak256("CONTEST_SCORES_SET"),
            abi.encode(contestId, awayScore, homeScore)
        );
    }

    /**
     * @notice Sets the scores of a contest manually
     * @dev Only callable by the SCORE_MANAGER_ROLE
     * @dev Only allowed if manual wait period has passed (2 days)
     * @param contestId The ID of the contest
     * @param awayScore The away score
     * @param homeScore The home score
     */
    function scoreContestManually(
        uint256 contestId,
        uint32 awayScore,
        uint32 homeScore
    ) external {
        // Check if caller is authorized
        if (!i_ospexCore.hasRole(SCORE_MANAGER_ROLE, msg.sender)) {
            revert ContestModule__NotAuthorized(msg.sender);
        }
        // Check if contest is verified
        if (s_contests[contestId].contestStatus != ContestStatus.Verified) {
            revert ContestModule__ContestNotVerified(contestId);
        }
        // Check if contest has started
        if (block.timestamp < s_contestStartTimes[contestId]) {
            revert ContestModule__ContestNotStarted(
                contestId,
                s_contestStartTimes[contestId] - block.timestamp
            );
        }

        // Check wait period
        uint256 startTime = s_contestStartTimes[contestId];

        // Check if wait period has passed
        if (block.timestamp < startTime + MANUAL_SCORE_WAIT_PERIOD) {
            revert ContestModule__ManualScoreWaitPeriodNotMet(
                contestId,
                startTime + MANUAL_SCORE_WAIT_PERIOD - block.timestamp
            );
        }

        // Set scores
        s_contests[contestId].awayScore = awayScore;
        s_contests[contestId].homeScore = homeScore;
        s_contests[contestId].contestStatus = ContestStatus.ScoredManually;
        emit ContestScoresSetManually(contestId, awayScore, homeScore);
        i_ospexCore.emitCoreEvent(
            keccak256("CONTEST_SCORES_SET_MANUALLY"),
            abi.encode(contestId, awayScore, homeScore)
        );
    }

    /**
     * @inheritdoc IContestModule
     * @dev Public view, no restriction
     */

    /**
     * @notice Gets a contest
     * @param contestId The ID of the contest
     * @return contest The contest
     */
    function getContest(
        uint256 contestId
    ) external view override returns (Contest memory contest) {
        contest = s_contests[contestId];
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
            revert ContestModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
