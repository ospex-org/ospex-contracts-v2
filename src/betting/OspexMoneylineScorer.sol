// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexModule} from "./IOspexModule.sol";
import {IOspexScorer} from "./IOspexScorer.sol";
import {OspexScorer} from "./OspexScorer.sol";
import {Outcome} from "./OspexBettingTypes.sol";

/**
 * @title OspexMoneylineScorer
 * @author ospex.org
 * @notice The moneyline: the team with more points wins; equal scores are a push. The line is ignored, and a
 *         moneyline market is drawn with a line of 0. Side A is the home team, side B the away team.
 */
contract OspexMoneylineScorer is OspexScorer {
    bytes32 public constant MONEYLINE_SCORER_MODULE = keccak256("MONEYLINE_SCORER_MODULE");

    /// @param core The betting set's core
    constructor(address core) OspexScorer(core) {}

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return MONEYLINE_SCORER_MODULE;
    }

    /// @inheritdoc IOspexScorer
    function outcomeOf(uint256 gameId, int32 lineTicks) external view override returns (Outcome) {
        (uint32 homeScore, uint32 awayScore) = _scores(gameId);
        return _outcome(homeScore, awayScore, lineTicks);
    }

    /// @inheritdoc IOspexScorer
    function outcome(uint32 homeScore, uint32 awayScore, int32 lineTicks) external pure override returns (Outcome) {
        return _outcome(homeScore, awayScore, lineTicks);
    }

    /// @dev Home when the home team scored more, Away when the away team did, Push on equal scores.
    function _outcome(uint32 homeScore, uint32 awayScore, int32) private pure returns (Outcome) {
        if (homeScore > awayScore) return Outcome.Home;
        if (awayScore > homeScore) return Outcome.Away;
        return Outcome.Push;
    }
}
