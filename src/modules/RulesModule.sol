// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRulesModule} from "../interfaces/IRulesModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {LeagueId, Leaderboard, LeaderboardSpeculation, Contest, Speculation, PositionType} from "../core/OspexTypes.sol";

contract RulesModule is IRulesModule {
    // --- Custom Errors ---
    error RulesModule__NotAdmin(address admin);
    error RulesModule__LeaderboardStarted();
    error RulesModule__LeaderboardSpeculationDoesNotExist();
    error RulesModule__ModuleNotSet(bytes32 moduleType);
    error RulesModule__InvalidValue();
    error RulesModule__InvalidBps();
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
    event RuleSet(uint256 indexed leaderboardId, string ruleType, uint256 value);
    event DeviationRuleSet(
        uint256 indexed leaderboardId,
        LeagueId indexed leagueId,
        address indexed scorer,
        PositionType positionType,
        int32 maxDeviation
    );

    // --- Modifiers ---
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert RulesModule__NotAdmin(msg.sender);
        }
        _;
    }

    modifier leaderboardNotStarted(uint256 leaderboardId) {
        Leaderboard memory leaderboard = ILeaderboardModule(_getModule(keccak256("LEADERBOARD_MODULE")))
            .getLeaderboard(leaderboardId);
        if (leaderboard.startTime == 0) revert RulesModule__InvalidLeaderboard();
        if (block.timestamp >= leaderboard.startTime) {
            revert RulesModule__LeaderboardStarted();
        }
        _;
    }

    modifier valueGreaterThanMaxBps(uint256 value) {
        if (value > MAX_BPS) revert RulesModule__InvalidBps();
        _;
    }

    // --- Constructor ---
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
    function setMinBankroll(
        uint256 leaderboardId,
        uint256 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_minBankroll[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBankroll", value);
    }

    function setMaxBankroll(
        uint256 leaderboardId,
        uint256 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_maxBankroll[leaderboardId] = value;
        emit RuleSet(leaderboardId, "maxBankroll", value);
    }

    function setMinBetPercentage(
        uint256 leaderboardId,
        uint16 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) valueGreaterThanMaxBps(value) {
        s_minBetPercentage[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBetPercentage", value);
    }

    function setMaxBetPercentage(
        uint256 leaderboardId,
        uint16 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) valueGreaterThanMaxBps(value) {
        s_maxBetPercentage[leaderboardId] = value;
        emit RuleSet(leaderboardId, "maxBetPercentage", value);
    }

    function setMinBets(
        uint256 leaderboardId,
        uint16 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) {
        s_minBets[leaderboardId] = value;
        emit RuleSet(leaderboardId, "minBets", value);
    }

    function setOddsEnforcementBps(
        uint256 leaderboardId,
        uint16 value
    ) external override onlyAdmin leaderboardNotStarted(leaderboardId) valueGreaterThanMaxBps(value) {
        s_oddsEnforcementBps[leaderboardId] = value;
        emit RuleSet(leaderboardId, "oddsEnforcementBps", value);
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
        s_deviationRules[leaderboardId][leagueId][scorer][positionType] = maxDeviation;
        s_deviationRuleSet[leaderboardId][leagueId][scorer][positionType] = true;

        emit DeviationRuleSet(leaderboardId, leagueId, scorer, positionType, maxDeviation);
        i_ospexCore.emitCoreEvent(
            keccak256("DEVIATION_RULE_SET"),
            abi.encode(leaderboardId, leagueId, scorer, positionType, maxDeviation)
        );
    }

    // --- Validation Functions ---
    function isBankrollValid(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view override returns (bool) {
        if (s_minBankroll[leaderboardId] > 0 && bankroll < s_minBankroll[leaderboardId]) {
            return false;
        }
        if (s_maxBankroll[leaderboardId] > 0 && bankroll > s_maxBankroll[leaderboardId]) {
            return false;
        }
        return true;
    }

    function isBetValid(
        uint256 leaderboardId,
        uint256 bankroll,
        uint256 betAmount
    ) external view override returns (bool) {
        if (s_minBetPercentage[leaderboardId] > 0) {
            uint256 minBet = (bankroll * s_minBetPercentage[leaderboardId]) / MAX_BPS;
            if (betAmount < minBet) return false;
        }
        if (s_maxBetPercentage[leaderboardId] > 0) {
            uint256 maxBet = (bankroll * s_maxBetPercentage[leaderboardId]) / MAX_BPS;
            if (betAmount > maxBet) return false;
        }
        return true;
    }

    function isMinPositionsMet(
        uint256 leaderboardId,
        uint256 userPositions
    ) external view override returns (bool) {
        if (s_minBets[leaderboardId] > 0 && userPositions < s_minBets[leaderboardId]) {
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
    function isOddsValid(
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
        uint256 oddsPrecision = IPositionModule(_getModule(keccak256("POSITION_MODULE"))).ODDS_PRECISION();
        
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
    function isNumberValid(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 userNumber,
        int32 marketNumber
    ) external view override returns (bool) {
        // Check if deviation rule is set for this combination
        if (!s_deviationRuleSet[leaderboardId][leagueId][scorer][positionType]) {
            return true; // No rule set, allow all numbers
        }
        
        int32 maxDeviation = s_deviationRules[leaderboardId][leagueId][scorer][positionType];
        
        // Calculate absolute difference
        int32 difference = userNumber > marketNumber ? 
            userNumber - marketNumber : 
            marketNumber - userNumber;
        
        return difference <= maxDeviation;
    }

    /**
     * @notice Comprehensive validation for a leaderboard position
     * @param leaderboardId The leaderboard ID
     * @param speculationId The speculation ID
     * @param amount The bet amount
     * @param declaredBankroll The user's declared bankroll
     * @param userNumber The number the user is betting on (for spreads/totals)
     * @param userOdds The odds the user is getting
     * @param positionType The position type (Upper/Lower)
     * @return bool True if position passes all validation rules
     */
    function validateLeaderboardPosition(
        uint256 leaderboardId,
        uint256 speculationId,
        uint256 amount,
        uint256 declaredBankroll,
        int32 userNumber,
        uint64 userOdds,
        PositionType positionType
    ) external view override returns (bool) {
        // Get leaderboard to ensure it exists and is active
        ILeaderboardModule leaderboardModule = ILeaderboardModule(_getModule(keccak256("LEADERBOARD_MODULE")));
        Leaderboard memory leaderboard = leaderboardModule.getLeaderboard(leaderboardId);
        
        if (leaderboard.startTime == 0) return false; // Leaderboard doesn't exist
        if (block.timestamp < leaderboard.startTime || block.timestamp >= leaderboard.endTime) {
            return false; // Outside leaderboard time window
        }

        // Validate bet amount against bankroll rules
        if (!this.isBetValid(leaderboardId, declaredBankroll, amount)) {
            return false;
        }

        // Get leaderboard speculation data for market comparison
        LeaderboardSpeculation memory lbSpec = leaderboardModule.getLeaderboardSpeculation(speculationId);
        
        if (lbSpec.speculationId == 0) {
            return false; // Speculation not registered for leaderboard
        }

        // Get contest and speculation info for league/scorer validation
        Contest memory contest = IContestModule(_getModule(keccak256("CONTEST_MODULE")))
            .getContest(lbSpec.contestId);
        
        Speculation memory speculation = ISpeculationModule(_getModule(keccak256("SPECULATION_MODULE")))
            .getSpeculation(speculationId);

        // Validate number deviation (for spreads/totals)
        if (!this.isNumberValid(
            leaderboardId,
            contest.leagueId,
            speculation.speculationScorer,
            positionType,
            userNumber,
            lbSpec.theNumber
        )) {
            return false;
        }

        // Validate odds enforcement
        uint64 marketOdds = positionType == PositionType.Upper ? 
            lbSpec.upperOdds : 
            lbSpec.lowerOdds;
            
        if (!this.isOddsValid(leaderboardId, userOdds, marketOdds)) {
            return false;
        }

        return true;
    }

    // --- Getter Functions ---
    function getDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType
    ) external view override returns (int32 maxDeviation, bool isSet) {
        maxDeviation = s_deviationRules[leaderboardId][leagueId][scorer][positionType];
        isSet = s_deviationRuleSet[leaderboardId][leagueId][scorer][positionType];
    }

    function getAllRules(
        uint256 leaderboardId
    ) external view override returns (
        uint256 minBankroll,
        uint256 maxBankroll,
        uint16 minBetPercentage,
        uint16 maxBetPercentage,
        uint16 minBets,
        uint16 oddsEnforcementBps
    ) {
        return (
            s_minBankroll[leaderboardId],
            s_maxBankroll[leaderboardId],
            s_minBetPercentage[leaderboardId],
            s_maxBetPercentage[leaderboardId],
            s_minBets[leaderboardId],
            s_oddsEnforcementBps[leaderboardId]
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
            maxBetAmount = (bankroll * s_maxBetPercentage[leaderboardId]) / MAX_BPS;
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
            minBetAmount = (bankroll * s_minBetPercentage[leaderboardId]) / MAX_BPS;
        } else {
            minBetAmount = 0; // No minimum
        }
        return minBetAmount;
    }

    // --- Helper Functions ---
    function _getModule(bytes32 moduleType) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) {
            revert RulesModule__ModuleNotSet(moduleType);
        }
        return module;
    }

}
