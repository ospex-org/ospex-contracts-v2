// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    LeagueId,
    PositionType,
    LeaderboardPositionValidationResult
} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title IRulesModule
 * @notice Interface for the RulesModule in the Ospex protocol
 * @dev Handles configurable rules for leaderboards including bankroll limits, bet sizing,
 *      odds enforcement, number deviation limits, and comprehensive position validation.
 *      All rule setters require admin access and can only be called before the leaderboard starts.
 */
interface IRulesModule is IModule {
    // --- Rule Setters ---

    /// @notice Sets the minimum bankroll required to register for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param value The minimum bankroll in token smallest units (0 to disable)
    function setMinBankroll(uint256 leaderboardId, uint256 value) external;

    /// @notice Sets the maximum bankroll allowed for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param value The maximum bankroll in token smallest units (0 to disable)
    function setMaxBankroll(uint256 leaderboardId, uint256 value) external;

    /// @notice Sets the minimum bet percentage of bankroll for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param value The minimum bet percentage in basis points (e.g., 100 = 1%)
    function setMinBetPercentage(uint256 leaderboardId, uint16 value) external;

    /// @notice Sets the maximum bet percentage of bankroll for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param value The maximum bet percentage in basis points (e.g., 1000 = 10%)
    function setMaxBetPercentage(uint256 leaderboardId, uint16 value) external;

    /// @notice Sets the minimum number of positions required to submit ROI
    /// @param leaderboardId The ID of the leaderboard
    /// @param value The minimum number of positions (0 to disable)
    function setMinBets(uint256 leaderboardId, uint16 value) external;

    /// @notice Sets the odds enforcement threshold for a leaderboard
    /// @dev Controls how much better than market odds a leaderboard position can have.
    ///      Uses cross-multiplication to avoid rounding: no division in the validation path.
    /// @param leaderboardId The ID of the leaderboard
    /// @param value The maximum allowed deviation above market odds in basis points (e.g., 2500 = 25%)
    function setOddsEnforcementBps(
        uint256 leaderboardId,
        uint16 value
    ) external;

    /// @notice Sets whether live betting is allowed for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param value True to allow positions after contest start, false to restrict to pre-game only
    function setAllowLiveBetting(uint256 leaderboardId, bool value) external;

    /// @notice Sets a number deviation rule for a specific league/scorer/position type combination
    /// @dev Controls how far a user's spread/total number can deviate from the current market number
    /// @param leaderboardId The ID of the leaderboard
    /// @param leagueId The league (e.g., NBA, NFL)
    /// @param scorer The scorer contract address (e.g., spread scorer, total scorer)
    /// @param positionType The position type (Upper or Lower)
    /// @param maxDeviation Maximum allowed deviation in 10x format (e.g., 15 = 1.5 points, 0 = exact match)
    function setDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 maxDeviation
    ) external;

    // --- Validation Functions ---

    /// @notice Validates if a bankroll is within the allowed range for a leaderboard
    /// @param leaderboardId The ID of the leaderboard
    /// @param bankroll The bankroll amount to validate
    /// @return True if the bankroll is within the configured min/max range (or no limits set)
    function isBankrollValid(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view returns (bool);

    /// @notice Validates if a user has met the minimum number of positions for ROI submission
    /// @param leaderboardId The ID of the leaderboard
    /// @param userPositions The number of positions the user has in the leaderboard
    /// @return True if the minimum is met (or no minimum set)
    function isMinPositionsMet(
        uint256 leaderboardId,
        uint256 userPositions
    ) external view returns (bool);

    /// @notice Validates if a position's effective odds are within enforcement limits
    /// @dev Uses cross-multiplication to avoid integer division rounding:
    ///      At-or-worse-than-market check: (risk + profit) * ODDS_SCALE <= risk * marketOddsTick
    ///      Within-threshold check: lhs * MAX_BPS <= rhs * (MAX_BPS + enforcementBps)
    /// @param leaderboardId The ID of the leaderboard
    /// @param riskAmount The risk amount from the position
    /// @param profitAmount The profit amount from the position
    /// @param marketOddsTick The current market odds tick (e.g., 191 = 1.91)
    /// @return True if odds are valid (at-or-worse than market, or within enforcement threshold)
    function validateOdds(
        uint256 leaderboardId,
        uint256 riskAmount,
        uint256 profitAmount,
        uint16 marketOddsTick
    ) external view returns (bool);

    /// @notice Validates if a position's number is within deviation limits
    /// @param leaderboardId The ID of the leaderboard
    /// @param leagueId The league ID
    /// @param scorer The scorer contract address
    /// @param positionType The position type (Upper or Lower)
    /// @param userNumber The user's spread/total number (10x format)
    /// @param marketNumber The current market number (10x format)
    /// @return True if the number is within allowed deviation (or no rule set)
    function validateNumber(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 userNumber,
        int32 marketNumber
    ) external view returns (bool);

    /// @notice Comprehensive validation for a leaderboard position entry
    /// @dev Checks leaderboard existence, timing, speculation registration, live betting,
    ///      number deviation, odds enforcement, and directional position conflicts.
    /// @param leaderboardId The ID of the leaderboard
    /// @param speculationId The ID of the speculation
    /// @param user The user address
    /// @param userNumber The user's spread/total number (10x format)
    /// @param positionType The position type (Upper or Lower)
    /// @param riskAmount The risk amount (may be capped by LeaderboardModule before calling)
    /// @param profitAmount The profit amount (may be scaled proportionally if risk was capped)
    /// @return The validation result enum (Valid or a specific failure reason)
    function validateLeaderboardPosition(
        uint256 leaderboardId,
        uint256 speculationId,
        address user,
        int32 userNumber,
        PositionType positionType,
        uint256 riskAmount,
        uint256 profitAmount
    ) external view returns (LeaderboardPositionValidationResult);

    // --- Getter Functions ---

    /// @notice Gets the deviation rule for a specific league/scorer/position type combination
    /// @param leaderboardId The ID of the leaderboard
    /// @param leagueId The league ID
    /// @param scorer The scorer contract address
    /// @param positionType The position type (Upper or Lower)
    /// @return maxDeviation The maximum allowed deviation (10x format)
    /// @return isSet Whether a rule has been explicitly configured
    function getDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType
    ) external view returns (int32 maxDeviation, bool isSet);

    /// @notice Gets all basic rules for a leaderboard in a single call
    /// @param leaderboardId The ID of the leaderboard
    /// @return minBankroll Minimum bankroll (0 if no limit)
    /// @return maxBankroll Maximum bankroll (0 if no limit)
    /// @return minBetPercentage Minimum bet as BPS of bankroll (0 if no limit)
    /// @return maxBetPercentage Maximum bet as BPS of bankroll (0 if no limit)
    /// @return minBets Minimum number of positions for ROI submission (0 if no limit)
    /// @return oddsEnforcementBps Odds enforcement threshold in BPS (0 if no enforcement)
    /// @return allowLiveBetting Whether live betting is allowed
    function getAllRules(
        uint256 leaderboardId
    )
        external
        view
        returns (
            uint256 minBankroll,
            uint256 maxBankroll,
            uint16 minBetPercentage,
            uint16 maxBetPercentage,
            uint16 minBets,
            uint16 oddsEnforcementBps,
            bool allowLiveBetting
        );

    /// @notice Calculates the maximum allowed bet amount based on bankroll and max bet percentage
    /// @param leaderboardId The ID of the leaderboard
    /// @param bankroll The user's declared bankroll
    /// @return maxBetAmount The maximum allowed bet (type(uint256).max if no limit set)
    function getMaxBetAmount(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view returns (uint256 maxBetAmount);

    /// @notice Calculates the minimum required bet amount based on bankroll and min bet percentage
    /// @param leaderboardId The ID of the leaderboard
    /// @param bankroll The user's declared bankroll
    /// @return minBetAmount The minimum required bet (0 if no minimum set)
    function getMinBetAmount(
        uint256 leaderboardId,
        uint256 bankroll
    ) external view returns (uint256 minBetAmount);
}
