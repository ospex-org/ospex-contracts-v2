// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {LeagueId, PositionType} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

interface IRulesModule is IModule {
    // --- Rule Setters ---
    function setMinBankroll(uint256 leaderboardId, uint256 value) external;
    function setMaxBankroll(uint256 leaderboardId, uint256 value) external;
    function setMinBetPercentage(uint256 leaderboardId, uint16 value) external;
    function setMaxBetPercentage(uint256 leaderboardId, uint16 value) external;
    function setMinBets(uint256 leaderboardId, uint16 value) external;
    function setOddsEnforcementBps(uint256 leaderboardId, uint16 value) external;
    function setAllowLiveBetting(uint256 leaderboardId, bool value) external;
    function setDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 maxDeviation
    ) external;

    // --- Validation Functions ---
    function isBankrollValid(uint256 leaderboardId, uint256 bankroll) external view returns (bool);
    function isBetValid(uint256 leaderboardId, uint256 bankroll, uint256 betAmount) external view returns (bool);
    function isMinPositionsMet(uint256 leaderboardId, uint256 userPositions) external view returns (bool);
    function isOddsValid(uint256 leaderboardId, uint64 userOdds, uint64 marketOdds) external view returns (bool);
    function isNumberValid(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType,
        int32 userNumber,
        int32 marketNumber
    ) external view returns (bool);
    function validateLeaderboardPosition(
        uint256 leaderboardId,
        uint256 speculationId,
        uint256 amount,
        uint256 declaredBankroll,
        int32 userNumber,
        uint64 userOdds,
        PositionType positionType
    ) external view returns (bool);

    // --- Getter Functions ---
    function getDeviationRule(
        uint256 leaderboardId,
        LeagueId leagueId,
        address scorer,
        PositionType positionType
    ) external view returns (int32 maxDeviation, bool isSet);
    
    function getAllRules(
        uint256 leaderboardId
    ) external view returns (
        uint256 minBankroll,
        uint256 maxBankroll,
        uint16 minBetPercentage,
        uint16 maxBetPercentage,
        uint16 minBets,
        uint16 oddsEnforcementBps,
        bool allowLiveBetting
    );
    function getMaxBetAmount(uint256 leaderboardId, uint256 bankroll) external view returns (uint256 maxBetAmount);
    function getMinBetAmount(uint256 leaderboardId, uint256 bankroll) external view returns (uint256 minBetAmount);
}
