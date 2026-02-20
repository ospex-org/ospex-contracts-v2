// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IRulesModule} from "../interfaces/IRulesModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {LeagueId, Leaderboard, Contest, Speculation, PositionType, ContestMarket, LeaderboardPositionValidationResult} from "../core/OspexTypes.sol";

/**
 * @title RulesModule
 * @notice Handles rules creation, storage, and status management for Ospex protocol
 * @dev All business logic for rules is implemented here.
 */

contract RulesModule is IRulesModule {
    // --- Custom Errors ---
    /// @notice Error thrown when the caller is not an admin
    error RulesModule__NotAdmin(address admin);
    /// @notice Error thrown when the leaderboard has started
    error RulesModule__LeaderboardStarted();
    /// @notice Error thrown when the module is not set
    error RulesModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Error thrown when the value is invalid
    error RulesModule__InvalidValue();
    /// @notice Error thrown when the BPS is invalid
    error RulesModule__InvalidBps();
    /// @notice Error thrown when the leaderboard is invalid
    error RulesModule__InvalidLeaderboard();

    // --- State Variables ---
    OspexCore public immutable i_ospexCore;

    // Basic rule mappings
    mapping(uint256 => uint256) public s_minBankroll;
    mapping(uint256 => uint256) public s_maxBankroll;
    mapping(uint256 => uint16) public s_minBetPercentage;
    mapping(uint256 => uint16) public s_maxBetPercentage;
    mapping(uint256 => uint16) public s_minBets;
    mapping(uint256 => uint16) public s_oddsEnforcementBps;
    mapping(uint256 => bool) public s_allowLiveBetting;

    // Deviation rules - nested mappings for readability
    // leaderboardId => leagueId => scorer => positionType => maxDeviation
    mapping(uint256 => mapping(LeagueId => mapping(address => mapping(PositionType => int32))))
        public s_deviationRules;

    // Track which deviation rules have been explicitly set
    // leaderboardId => leagueId => scorer => positionType => isSet
    mapping(uint256 => mapping(LeagueId => mapping(address => mapping(PositionType => bool))))
        public s_deviationRuleSet;

    // --- Constants ---
    uint16 public constant MAX_BPS = 10000; // 100%

    // --- Events ---
    /**
     * @notice Event for setting a rule
     * @param leaderboardId The ID of the leaderboard
     * @param ruleType The type of rule
     * @param value The value of the rule
     */
    event RuleSet(
        uint256 indexed leaderboardId,
        string ruleType,
        uint256 value
    );

    /**
     * @notice Event for setting a deviation rule
     * @param leaderboardId The ID of the leaderboard
     * @param leagueId The ID of the league
     * @param scorer The address of the scorer
     * @param positionType The position type
     * @param maxDeviation The maximum deviation
     */
    event DeviationRuleSet(
        uint256 indexed leaderboardId,
        LeagueId indexed leagueId,
        address indexed scorer,
        PositionType positionType,
        int32 maxDeviation
    );

    // --- Modifiers ---
    /**
     * @notice Modifier to ensure the caller is an admin
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert RulesModule__NotAdmin(msg.sender);
        }
        _;
    }

    /**
     * @notice Modifier to ensure the leaderboard has not started
     * @param leaderboardId The ID of the leaderboard
     */
    modifier leaderboardNotStarted(uint256 leaderboardId) {
        Leaderboard memory leaderboard = ILeaderboardModule(
            _getModule(keccak256("LEADERBOARD_MODULE"))
        ).getLeaderboard(leaderboardId);
        if (leaderboard.startTime == 0)
            revert RulesModule__InvalidLeaderboard();
        if (block.timestamp >= leaderboard.startTime) {
            revert RulesModule__LeaderboardStarted();
        }
        _;
    }

    /**
     * @notice Modifier to ensure the value is greater than the maximum BPS
     * @param value The value to check
     */
    modifier valueGreaterThanMaxBps(uint256 value) {
        if (value > MAX_BPS) revert RulesModule__InvalidBps();
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor for the rules module
     * @param ospexCore The address of the OspexCore contract
     */
    constructor(address ospexCore) {
        if (ospexCore == address(0)) revert RulesModule__InvalidValue();
        i_ospexCore = OspexCore(ospexCore);
    }

    // --- IModule ---
    /**
     * @notice Gets the module type
     * @return moduleType The module type
     */
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("RULES_MODULE");
    }

    // --- Rule Setters ---
    /**
     * @notice Sets the minimum bankroll for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The minimum bankroll
     */
    function setMinBankroll(
        uint256 leaderboardId,
        uint256 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_minBankroll[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBankroll", value);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "minBankroll", value)
        );
    }

    /**
     * @notice Sets the maximum bankroll for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The maximum bankroll
     */
    function setMaxBankroll(
        uint256 leaderboardId,
        uint256 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_maxBankroll[leaderboardId] = value;
        emit RuleSet(leaderboardId, "maxBankroll", value);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "maxBankroll", value)
        );
    }

    /**
     * @notice Sets the minimum bet percentage for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The minimum bet percentage
     */
    function setMinBetPercentage(
        uint256 leaderboardId,
        uint16 value
    )
        external
        override
        onlyAdmin
        leaderboardNotStarted(leaderboardId)
        valueGreaterThanMaxBps(value)
    {
        s_minBetPercentage[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBetPercentage", value);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "minBetPercentage", value)
        );
    }

    /**
     * @notice Sets the maximum bet percentage for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The maximum bet percentage
     */
    function setMaxBetPercentage(
        uint256 leaderboardId,
        uint16 value
    )
        external
        override
        onlyAdmin
        leaderboardNotStarted(leaderboardId)
        valueGreaterThanMaxBps(value)
    {
        s_maxBetPercentage[leaderboardId] = value;
        emit RuleSet(leaderboardId, "maxBetPercentage", value);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "maxBetPercentage", value)
        );
    }

    /**
     * @notice Sets the minimum bets for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The minimum bets
     */
    function setMinBets(
        uint256 leaderboardId,
        uint16 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_minBets[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBets", value);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "minBets", value)
        );
    }

    /**
     * @notice Sets the odds enforcement BPS for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The odds enforcement BPS
     */
    function setOddsEnforcementBps(
        uint256 leaderboardId,
        uint16 value
    )
        external
        override
        onlyAdmin
        leaderboardNotStarted(leaderboardId)
        valueGreaterThanMaxBps(value)
    {
        s_oddsEnforcementBps[leaderboardId] = value;
        emit RuleSet(leaderboardId, "oddsEnforcementBps", value);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "oddsEnforcementBps", value)
        );
    }

    /**
     * @notice Sets the allow live betting for a leaderboard
     * @param leaderboardId The ID of the leaderboard
     * @param value The allow live betting
     */
    function setAllowLiveBetting(
        uint256 leaderboardId,
        bool value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_allowLiveBetting[leaderboardId] = value;
        emit RuleSet(leaderboardId, "allowLiveBetting", value ? 1 : 0);
        i_ospexCore.emitCoreEvent(
            keccak256("RULE_SET"),
            abi.encode(leaderboardId, "allowLiveBetting", value ? 1 : 0)
        );
    }

    /**
     * @notice Sets deviation rule for a specific leaderboard, league, scorer, and position type
     * @param leaderboardId The leaderboard ID
     * @param leagueId The league ID (e.g., NHL, NFL)
     * @param scorer The scorer contract address (e.g., spread scorer, moneyline scorer)
     * @param positionType The position type (Upper/Lower)
     * @param maxDeviation Maximum allowed deviation from market number (can be negative for calculations)
     * @dev A maxDeviation of 0 means exact match required, positive values allow deviation
     */
    function setDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 maxDeviation
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
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
            keccak256("DEVIATION_RULE_SET"),
            abi.encode(
                leaderboardId,
                leagueId,
                scorer,
                positionType,
                maxDeviation
            )
        );
    }

    // --- Validation Functions ---
    /**
     * @notice Validates if the bankroll is within the allowed range
     * @param leaderboardId The ID of the leaderboard
     * @param bankroll The bankroll to validate
     * @return bool True if the bankroll is valid
     */
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

    /**
     * @notice Validates if the minimum number of positions is met
     * @param leaderboardId The ID of the leaderboard
     * @param userPositions The number of positions the user has
     * @return bool True if the minimum number of positions is met
     */
    function isMinPositionsMet(
        uint256 leaderboardId,
        uint256 userPositions
    ) external view override returns (bool) {
        if (
            s_minBets[leaderboardId] > 0 &&
            userPositions < s_minBets[leaderboardId]
        ) {
            return false;
        }
        return true;
    }

    /**
     * @notice Validates if odds are within enforcement limits
     * @param leaderboardId The leaderboard ID
     * @param userOdds The odds the user is getting
     * @param marketOdds The current market odds
     * @return bool True if odds are valid (within enforcement or worse than market)
     * @dev Worse odds than market are always allowed, better odds are limited by enforcement BPS
     */
    function validateOdds(
        uint256 leaderboardId,
        uint64 userOdds,
        uint64 marketOdds
    ) external view override returns (bool) {
        uint16 enforcementBps = s_oddsEnforcementBps[leaderboardId];

        // If no enforcement set, all odds are valid
        if (enforcementBps == 0) return true;

        // If user odds are worse than or equal to market, always allowed
        if (userOdds <= marketOdds) return true;

        // Calculate maximum allowed odds (market + enforcement percentage)
        // Example: market 2.25, enforcement 25% -> max = 2.25 + (2.25-1)*0.25 = 2.25 + 0.3125 = 2.5625
        uint256 oddsPrecision = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        ).ODDS_PRECISION();

        uint256 marketProfit = uint256(marketOdds) - oddsPrecision;
        uint256 maxAdditionalProfit = (marketProfit * enforcementBps) / MAX_BPS;
        uint256 maxAllowedOdds = uint256(marketOdds) + maxAdditionalProfit;

        return uint256(userOdds) <= maxAllowedOdds;
    }

    /**
     * @notice Validates if a position's "number" (spread/total) is within deviation limits
     * @param leaderboardId The leaderboard ID
     * @param leagueId The league ID
     * @param scorer The scorer contract address
     * @param positionType The position type
     * @param userNumber The number the user is betting on
     * @param marketNumber The current market number
     * @return bool True if number is within allowed deviation
     */
    function validateNumber(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 userNumber,
        int32 marketNumber
    ) external view override returns (bool) {
        // Check if deviation rule is set for this combination
        if (
            !s_deviationRuleSet[leaderboardId][leagueId][scorer][positionType]
        ) {
            return true; // No rule set, allow all numbers
        }

        int32 maxDeviation = s_deviationRules[leaderboardId][leagueId][scorer][
            positionType
        ];

        // Calculate absolute difference
        int32 difference = userNumber > marketNumber
            ? userNumber - marketNumber
            : marketNumber - userNumber;

        return difference <= maxDeviation;
    }

    /**
     * @notice Comprehensive validation for a leaderboard position
     * @param leaderboardId The leaderboard ID
     * @param speculationId The speculation ID
     * @param user The user address
     * @param userNumber The number the user is betting on (for spreads/totals)
     * @param userOdds The odds the user is getting
     * @param positionType The position type (Upper/Lower)
     * @return bool True if position passes all validation rules
     */
    function validateLeaderboardPosition(
        uint256 leaderboardId,
        uint256 speculationId,
        address user,
        int32 userNumber,
        uint64 userOdds,
        PositionType positionType
    ) external view override returns (LeaderboardPositionValidationResult) {
        // Get leaderboard to ensure it exists and is active
        ILeaderboardModule leaderboardModule = ILeaderboardModule(
            _getModule(keccak256("LEADERBOARD_MODULE"))
        );
        IContestModule contestModule = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        );
        Leaderboard memory leaderboard = leaderboardModule.getLeaderboard(
            leaderboardId
        );

        // Check if leaderboard exists
        if (leaderboard.startTime == 0)
            return LeaderboardPositionValidationResult.LeaderboardDoesNotExist;

        // Check if leaderboard has started or ended
        if (block.timestamp < leaderboard.startTime)
            return LeaderboardPositionValidationResult.LeaderboardHasNotStarted;
        if (block.timestamp >= leaderboard.endTime)
            return LeaderboardPositionValidationResult.LeaderboardHasEnded;

        // Check if speculation is registered for leaderboard
        if (
            !leaderboardModule.s_leaderboardSpeculationRegistered(
                leaderboardId,
                speculationId
            )
        ) {
            return LeaderboardPositionValidationResult.SpeculationNotRegistered; // Speculation not registered for leaderboard
        }

        // Get speculation data for market comparison
        Speculation memory speculation = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);

        // Check if live betting is allowed
        if (!s_allowLiveBetting[leaderboardId]) {
            if (
                block.timestamp >=
                contestModule.s_contestStartTimes(speculation.contestId)
            ) {
                return
                    LeaderboardPositionValidationResult.LiveBettingNotAllowed;
            }
        }

        // Get contest and speculation info for league/scorer validation
        Contest memory contest = contestModule.getContest(
            speculation.contestId
        );

        // Get current market data for validation
        ContestMarket memory contestMarket = contestModule.getContestMarket(
            speculation.contestId,
            speculation.speculationScorer
        );

        // Validate number deviation (for spreads/totals) - compare against current market number
        if (
            !this.validateNumber(
                leaderboardId,
                contest.leagueId,
                speculation.speculationScorer,
                positionType,
                userNumber,
                contestMarket.theNumber
            )
        ) {
            return LeaderboardPositionValidationResult.NumberDeviationTooLarge;
        }

        // Validate odds enforcement - compare against current market odds
        uint64 marketOdds = positionType == PositionType.Upper
            ? contestMarket.upperOdds
            : contestMarket.lowerOdds;

        if (!this.validateOdds(leaderboardId, userOdds, marketOdds)) {
            return LeaderboardPositionValidationResult.OddsTooFavorable;
        }

        // Validate directional position conflict
        address moneylineScorer = _getModule(
            keccak256("MONEYLINE_SCORER")
        );
        address spreadScorer = _getModule(keccak256("SPREAD_SCORER"));

        if (speculation.speculationScorer == moneylineScorer) {
            if (
                leaderboardModule.s_registeredLeaderboardSpeculation(
                    leaderboardId,
                    user,
                    speculation.contestId,
                    spreadScorer
                ) != 0
            ) {
                return
                    LeaderboardPositionValidationResult
                        .DirectionalPositionConflict;
            }
        }
        if (speculation.speculationScorer == spreadScorer) {
            if (
                leaderboardModule.s_registeredLeaderboardSpeculation(
                    leaderboardId,
                    user,
                    speculation.contestId,
                    moneylineScorer
                ) != 0
            ) {
                return
                    LeaderboardPositionValidationResult
                        .DirectionalPositionConflict;
            }
        }

        return LeaderboardPositionValidationResult.Valid;
    }

    // --- Getter Functions ---
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
            bool allowLiveBetting
        )
    {
        return (
            s_minBankroll[leaderboardId],
            s_maxBankroll[leaderboardId],
            s_minBetPercentage[leaderboardId],
            s_maxBetPercentage[leaderboardId],
            s_minBets[leaderboardId],
            s_oddsEnforcementBps[leaderboardId],
            s_allowLiveBetting[leaderboardId]
        );
    }

    /**
     * @notice Gets the maximum allowed bet amount for a leaderboard based on bankroll
     * @param leaderboardId The leaderboard ID
     * @param bankroll The user's declared bankroll
     * @return maxBetAmount The maximum allowed bet (0 if no limit set)
     */
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

    /**
     * @notice Gets the minimum required bet amount for a leaderboard based on bankroll
     * @param leaderboardId The leaderboard ID
     * @param bankroll The user's declared bankroll
     * @return minBetAmount The minimum required bet (0 if no minimum set)
     */
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

    // --- Helper Functions ---
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
