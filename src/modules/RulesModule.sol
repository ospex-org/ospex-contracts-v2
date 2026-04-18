// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IRulesModule} from "../interfaces/IRulesModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {
    LeagueId,
    Leaderboard,
    Contest,
    Speculation,
    PositionType,
    ContestMarket,
    LeaderboardPositionValidationResult
} from "../core/OspexTypes.sol";

/**
 * @title RulesModule
 * @notice Configurable rules engine for Ospex leaderboards. Controls bankroll limits,
 *         bet sizing, odds enforcement, number deviation, and position validation.
 * @dev All rule setters are restricted to the leaderboard creator and can only be
 *      called before the leaderboard starts. Rules are immutable once the leaderboard is active.
 */

contract RulesModule is IRulesModule {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant RULES_MODULE = keccak256("RULES_MODULE");
    bytes32 public constant LEADERBOARD_MODULE =
        keccak256("LEADERBOARD_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant MONEYLINE_SCORER_MODULE =
        keccak256("MONEYLINE_SCORER_MODULE");
    bytes32 public constant SPREAD_SCORER_MODULE =
        keccak256("SPREAD_SCORER_MODULE");

    bytes32 public constant EVENT_RULE_SET = keccak256("RULE_SET");
    bytes32 public constant EVENT_DEVIATION_RULE_SET =
        keccak256("DEVIATION_RULE_SET");

    /// @notice Maximum basis points (10000 = 100%)
    uint16 public constant MAX_BPS = 10000;
    /// @notice Odds scale factor (1.91 odds = 191 ticks)
    uint16 public constant ODDS_SCALE = 100;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when attempting to set rules after a leaderboard has started
    error RulesModule__LeaderboardStarted();
    /// @notice Thrown when a required module is not registered in OspexCore
    error RulesModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when a rule value creates an invalid cross-field conflict
    error RulesModule__InvalidValue();
    /// @notice Thrown when a BPS value exceeds MAX_BPS
    error RulesModule__InvalidBps();
    /// @notice Thrown when a leaderboard does not exist
    error RulesModule__InvalidLeaderboard();
    /// @notice Thrown when a deviation value is negative
    error RulesModule__InvalidDeviation();
    /// @notice Thrown when a non-creator calls a creator-only function
    error RulesModule__NotCreator(address caller);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a basic rule is set for a leaderboard
    /// @param leaderboardId The leaderboard ID
    /// @param ruleType The rule name (e.g. "minBankroll", "maxBetPercentage")
    /// @param value The rule value
    event RuleSet(
        uint256 indexed leaderboardId,
        string ruleType,
        uint256 value
    );

    /// @notice Emitted when a deviation rule is set for a leaderboard
    /// @param leaderboardId The leaderboard ID
    /// @param leagueId The league
    /// @param scorer The scorer contract address
    /// @param positionType The position type
    /// @param maxDeviation The maximum allowed deviation
    event DeviationRuleSet(
        uint256 indexed leaderboardId,
        LeagueId indexed leagueId,
        address indexed scorer,
        PositionType positionType,
        int32 maxDeviation
    );

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @notice Validates the caller is the leaderboard creator and the leaderboard has not started
    modifier onlyCreatorBeforeStart(uint256 leaderboardId) {
        Leaderboard memory lb = ILeaderboardModule(
            _getModule(LEADERBOARD_MODULE)
        ).getLeaderboard(leaderboardId);
        if (lb.startTime == 0) revert RulesModule__InvalidLeaderboard();
        if (msg.sender != lb.creator)
            revert RulesModule__NotCreator(msg.sender);
        if (block.timestamp >= lb.startTime)
            revert RulesModule__LeaderboardStarted();
        _;
    }

    /// @dev Ensures a BPS value does not exceed 100%
    modifier valueNotExceedingMaxBps(uint256 value) {
        if (value > MAX_BPS) revert RulesModule__InvalidBps();
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Leaderboard ID → minimum bankroll
    mapping(uint256 => uint256) public s_minBankroll;
    /// @notice Leaderboard ID → maximum bankroll
    mapping(uint256 => uint256) public s_maxBankroll;
    /// @notice Leaderboard ID → minimum bet percentage (BPS of bankroll)
    mapping(uint256 => uint16) public s_minBetPercentage;
    /// @notice Leaderboard ID → maximum bet percentage (BPS of bankroll)
    mapping(uint256 => uint16) public s_maxBetPercentage;
    /// @notice Leaderboard ID → minimum number of positions for ROI submission (min/default of 1)
    mapping(uint256 => uint16) public s_minBets;
    /// @notice Leaderboard ID → odds enforcement threshold (BPS above market)
    mapping(uint256 => uint16) public s_oddsEnforcementBps;
    /// @notice Leaderboard ID → whether live betting is allowed
    mapping(uint256 => bool) public s_allowLiveBetting;
    /// @notice Leaderboard ID → whether moneyline+spread on same contestId is allowed
    mapping(uint256 => bool) public s_allowMoneylineSpreadPairing;

    /// @notice Leaderboard ID → league → scorer → position type → max deviation
    mapping(uint256 => mapping(LeagueId => mapping(address => mapping(PositionType => int32))))
        public s_deviationRules;

    /// @notice Tracks which deviation rules have been explicitly set
    mapping(uint256 => mapping(LeagueId => mapping(address => mapping(PositionType => bool))))
        public s_deviationRuleSet;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the RulesModule
    /// @param ospexCore The OspexCore contract address
    constructor(address ospexCore) {
        if (ospexCore == address(0)) revert RulesModule__InvalidValue();
        i_ospexCore = OspexCore(ospexCore);
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return RULES_MODULE;
    }

    // ──────────────────────────── Rule Setters ─────────────────────────

    /// @inheritdoc IRulesModule
    function setMinBankroll(
        uint256 leaderboardId,
        uint256 value
    ) external override onlyCreatorBeforeStart(leaderboardId) {
        if (
            value > 0 &&
            s_maxBankroll[leaderboardId] > 0 &&
            value > s_maxBankroll[leaderboardId]
        ) revert RulesModule__InvalidValue();
        s_minBankroll[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBankroll", value);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "minBankroll", value)
        );
    }

    /// @inheritdoc IRulesModule
    function setMaxBankroll(
        uint256 leaderboardId,
        uint256 value
    ) external override onlyCreatorBeforeStart(leaderboardId) {
        if (
            value > 0 &&
            s_minBankroll[leaderboardId] > 0 &&
            value < s_minBankroll[leaderboardId]
        ) revert RulesModule__InvalidValue();
        s_maxBankroll[leaderboardId] = value;
        emit RuleSet(leaderboardId, "maxBankroll", value);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "maxBankroll", value)
        );
    }

    /// @inheritdoc IRulesModule
    function setMinBetPercentage(
        uint256 leaderboardId,
        uint16 value
    )
        external
        override
        onlyCreatorBeforeStart(leaderboardId)
        valueNotExceedingMaxBps(value)
    {
        if (
            value > 0 &&
            s_maxBetPercentage[leaderboardId] > 0 &&
            value > s_maxBetPercentage[leaderboardId]
        ) revert RulesModule__InvalidValue();
        s_minBetPercentage[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBetPercentage", value);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "minBetPercentage", value)
        );
    }

    /// @inheritdoc IRulesModule
    function setMaxBetPercentage(
        uint256 leaderboardId,
        uint16 value
    )
        external
        override
        onlyCreatorBeforeStart(leaderboardId)
        valueNotExceedingMaxBps(value)
    {
        if (
            value > 0 &&
            s_minBetPercentage[leaderboardId] > 0 &&
            value < s_minBetPercentage[leaderboardId]
        ) revert RulesModule__InvalidValue();
        s_maxBetPercentage[leaderboardId] = value;
        emit RuleSet(leaderboardId, "maxBetPercentage", value);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "maxBetPercentage", value)
        );
    }

    /// @inheritdoc IRulesModule
    function setMinBets(
        uint256 leaderboardId,
        uint16 value
    ) external override onlyCreatorBeforeStart(leaderboardId) {
        if (value == 0) revert RulesModule__InvalidValue();
        s_minBets[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBets", value);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "minBets", value)
        );
    }

    /// @inheritdoc IRulesModule
    function setOddsEnforcementBps(
        uint256 leaderboardId,
        uint16 value
    )
        external
        override
        onlyCreatorBeforeStart(leaderboardId)
        valueNotExceedingMaxBps(value)
    {
        s_oddsEnforcementBps[leaderboardId] = value;
        emit RuleSet(leaderboardId, "oddsEnforcementBps", value);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "oddsEnforcementBps", value)
        );
    }

    /// @inheritdoc IRulesModule
    function setAllowLiveBetting(
        uint256 leaderboardId,
        bool value
    ) external override onlyCreatorBeforeStart(leaderboardId) {
        s_allowLiveBetting[leaderboardId] = value;
        emit RuleSet(leaderboardId, "allowLiveBetting", value ? 1 : 0);
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(leaderboardId, "allowLiveBetting", value ? 1 : 0)
        );
    }

    /// @inheritdoc IRulesModule
    function setDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 maxDeviation
    ) external override onlyCreatorBeforeStart(leaderboardId) {
        if (maxDeviation < 0) revert RulesModule__InvalidDeviation();
        s_deviationRules[leaderboardId][leagueId][scorer][
            positionType
        ] = maxDeviation;
        s_deviationRuleSet[leaderboardId][leagueId][scorer][
            positionType
        ] = true;

        emit DeviationRuleSet(
            leaderboardId,
            leagueId,
            scorer,
            positionType,
            maxDeviation
        );
        i_ospexCore.emitCoreEvent(
            EVENT_DEVIATION_RULE_SET,
            abi.encode(
                leaderboardId,
                leagueId,
                scorer,
                positionType,
                maxDeviation
            )
        );
    }

    /// @inheritdoc IRulesModule
    function setAllowMoneylineSpreadPairing(
        uint256 leaderboardId,
        bool value
    ) external override onlyCreatorBeforeStart(leaderboardId) {
        s_allowMoneylineSpreadPairing[leaderboardId] = value;
        emit RuleSet(
            leaderboardId,
            "allowMoneylineSpreadPairing",
            value ? 1 : 0
        );
        i_ospexCore.emitCoreEvent(
            EVENT_RULE_SET,
            abi.encode(
                leaderboardId,
                "allowMoneylineSpreadPairing",
                value ? 1 : 0
            )
        );
    }

    // ──────────────────────────── Validation Functions ─────────────────

    /// @inheritdoc IRulesModule
    function isBankrollValid(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view override returns (bool) {
        if (
            s_minBankroll[leaderboardId] > 0 &&
            bankroll < s_minBankroll[leaderboardId]
        ) {
            return false;
        }
        if (
            s_maxBankroll[leaderboardId] > 0 &&
            bankroll > s_maxBankroll[leaderboardId]
        ) {
            return false;
        }
        return true;
    }

    /// @inheritdoc IRulesModule
    function isMinPositionsMet(
        uint256 leaderboardId,
        uint256 userPositions
    ) external view override returns (bool) {
        uint16 minBets = s_minBets[leaderboardId];
        uint16 effectiveMin = minBets > 0 ? minBets : 1;
        return userPositions >= effectiveMin;
    }

    /// @inheritdoc IRulesModule
    function validateOdds(
        uint256 leaderboardId,
        uint256 riskAmount,
        uint256 profitAmount,
        uint16 marketOddsTick
    ) public view override returns (bool) {
        uint16 enforcementBps = s_oddsEnforcementBps[leaderboardId];

        // If no enforcement set, all odds are valid
        if (enforcementBps == 0) return true;

        // If effective odds <= market odds, always allowed (worse or equal odds)
        // Exact check: (risk + profit) * ODDS_SCALE <= risk * marketOdds
        // No division, no rounding
        uint256 lhs = (riskAmount + profitAmount) * ODDS_SCALE;
        uint256 rhs = riskAmount * uint256(marketOddsTick);
        if (lhs <= rhs) return true;

        // Check if within enforcement threshold
        // effective odds <= marketOdds * (10000 + maxAboveBps) / 10000
        // Cross-multiplied to avoid division:
        // (risk + profit) * ODDS_SCALE * 10000 <= risk * marketOdds * (10000 + maxAboveBps)
        return lhs * MAX_BPS <= rhs * (MAX_BPS + uint256(enforcementBps));
    }

    /// @inheritdoc IRulesModule
    function validateNumber(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 userNumber,
        int32 marketNumber
    ) public view override returns (bool) {
        if (
            !s_deviationRuleSet[leaderboardId][leagueId][scorer][positionType]
        ) {
            return true; // No rule set, allow all numbers
        }

        int32 maxDeviation = s_deviationRules[leaderboardId][leagueId][scorer][
            positionType
        ];

        int32 difference = userNumber > marketNumber
            ? userNumber - marketNumber
            : marketNumber - userNumber;

        return difference <= maxDeviation;
    }

    /**
     * @notice Comprehensive validation for a leaderboard position entry
     * @dev Checks leaderboard existence, timing, speculation registration, live betting,
     *      number deviation, odds enforcement, and position conflicts.
     * @param leaderboardId The leaderboard ID
     * @param speculationId The speculation ID
     * @param user The user address
     * @param userNumber The user's spread/total number (10x format)
     * @param positionType The position type (Upper/Lower)
     * @param riskAmount The risk amount (may be capped by LeaderboardModule)
     * @param profitAmount The profit amount (may be scaled proportionally if risk was capped)
     * @return The validation result enum (Valid or a specific failure reason)
     */
    function validateLeaderboardPosition(
        uint256 leaderboardId,
        uint256 speculationId,
        address user,
        int32 userNumber,
        PositionType positionType,
        uint256 riskAmount,
        uint256 profitAmount
    ) external view override returns (LeaderboardPositionValidationResult) {
        ILeaderboardModule leaderboardModule = ILeaderboardModule(
            _getModule(LEADERBOARD_MODULE)
        );
        IContestModule contestModule = IContestModule(
            _getModule(CONTEST_MODULE)
        );
        Leaderboard memory leaderboard = leaderboardModule.getLeaderboard(
            leaderboardId
        );

        if (leaderboard.startTime == 0)
            return LeaderboardPositionValidationResult.LeaderboardDoesNotExist;

        if (block.timestamp < leaderboard.startTime)
            return LeaderboardPositionValidationResult.LeaderboardHasNotStarted;
        if (block.timestamp >= leaderboard.endTime)
            return LeaderboardPositionValidationResult.LeaderboardHasEnded;

        if (
            !leaderboardModule.s_leaderboardSpeculationRegistered(
                leaderboardId,
                speculationId
            )
        ) {
            return LeaderboardPositionValidationResult.SpeculationNotRegistered;
        }

        Speculation memory speculation = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);

        if (!s_allowLiveBetting[leaderboardId]) {
            if (
                block.timestamp >=
                contestModule.s_contestStartTimes(speculation.contestId)
            ) {
                return
                    LeaderboardPositionValidationResult.LiveBettingNotAllowed;
            }
        }

        Contest memory contest = contestModule.getContest(
            speculation.contestId
        );

        ContestMarket memory contestMarket = contestModule.getContestMarket(
            speculation.contestId,
            speculation.speculationScorer
        );

        if (
            !validateNumber(
                leaderboardId,
                contest.leagueId,
                speculation.speculationScorer,
                positionType,
                userNumber,
                contestMarket.lineTicks
            )
        ) {
            return LeaderboardPositionValidationResult.NumberDeviationTooLarge;
        }

        uint16 marketOddsTick = positionType == PositionType.Upper
            ? contestMarket.upperOdds
            : contestMarket.lowerOdds;

        if (
            !validateOdds(
                leaderboardId,
                riskAmount,
                profitAmount,
                marketOddsTick
            )
        ) {
            return LeaderboardPositionValidationResult.OddsTooFavorable;
        }

        if (!s_allowMoneylineSpreadPairing[leaderboardId]) {
            if (
                speculation.speculationScorer ==
                _getModule(MONEYLINE_SCORER_MODULE)
            ) {
                if (
                    leaderboardModule.s_registeredLeaderboardSpeculation(
                        leaderboardId,
                        user,
                        speculation.contestId,
                        _getModule(SPREAD_SCORER_MODULE)
                    ) != 0
                ) {
                    return
                        LeaderboardPositionValidationResult
                            .MoneylineSpreadPairingNotAllowed;
                }
            } else if (
                speculation.speculationScorer ==
                _getModule(SPREAD_SCORER_MODULE)
            ) {
                if (
                    leaderboardModule.s_registeredLeaderboardSpeculation(
                        leaderboardId,
                        user,
                        speculation.contestId,
                        _getModule(MONEYLINE_SCORER_MODULE)
                    ) != 0
                ) {
                    return
                        LeaderboardPositionValidationResult
                            .MoneylineSpreadPairingNotAllowed;
                }
            }
        }

        return LeaderboardPositionValidationResult.Valid;
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc IRulesModule
    function getDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType
    ) external view override returns (int32 maxDeviation, bool isSet) {
        maxDeviation = s_deviationRules[leaderboardId][leagueId][scorer][
            positionType
        ];
        isSet = s_deviationRuleSet[leaderboardId][leagueId][scorer][
            positionType
        ];
    }

    /// @inheritdoc IRulesModule
    function getAllRules(
        uint256 leaderboardId
    )
        external
        view
        override
        returns (
            uint256 minBankroll,
            uint256 maxBankroll,
            uint16 minBetPercentage,
            uint16 maxBetPercentage,
            uint16 minBets,
            uint16 oddsEnforcementBps,
            bool allowLiveBetting,
            bool allowMoneylineSpreadPairing
        )
    {
        return (
            s_minBankroll[leaderboardId],
            s_maxBankroll[leaderboardId],
            s_minBetPercentage[leaderboardId],
            s_maxBetPercentage[leaderboardId],
            s_minBets[leaderboardId],
            s_oddsEnforcementBps[leaderboardId],
            s_allowLiveBetting[leaderboardId],
            s_allowMoneylineSpreadPairing[leaderboardId]
        );
    }

    /// @inheritdoc IRulesModule
    function getMaxBetAmount(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view override returns (uint256 maxBetAmount) {
        if (s_maxBetPercentage[leaderboardId] > 0) {
            maxBetAmount =
                (bankroll * s_maxBetPercentage[leaderboardId]) /
                MAX_BPS;
        } else {
            maxBetAmount = type(uint256).max; // No limit
        }
        return maxBetAmount;
    }

    /// @inheritdoc IRulesModule
    function getMinBetAmount(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view override returns (uint256 minBetAmount) {
        if (s_minBetPercentage[leaderboardId] > 0) {
            minBetAmount =
                (bankroll * s_minBetPercentage[leaderboardId]) /
                MAX_BPS;
        } else {
            minBetAmount = 0; // No minimum
        }
        return minBetAmount;
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
            revert RulesModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
