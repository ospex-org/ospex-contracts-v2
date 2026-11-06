// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexModule} from "./IOspexModule.sol";
import {IOspexScorer} from "./IOspexScorer.sol";
import {OspexScorer} from "./OspexScorer.sol";
import {Outcome} from "./OspexBettingTypes.sol";

/**
 * @title OspexTotalScorer
 * @author ospex.org
 * @notice The total: the two scores added, scaled by 10, against the line (2205 is 220.5 points). Over when the
 *         sum is above the line, Under when below, Push when equal. Side A is over, side B under. A total market
 *         is drawn with a line of at least 0.
 */
contract OspexTotalScorer is OspexScorer {
    bytes32 public constant TOTAL_SCORER_MODULE = keccak256("TOTAL_SCORER_MODULE");

    /// @param core The betting set's core
    constructor(address core) OspexScorer(core) {}

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return TOTAL_SCORER_MODULE;
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

    /// @dev The sum of the home team's score and the away team's, scaled by 10, against the line. The sum does
    ///      not depend on which score is which; the order of the two is the one the games set returns.
    function _outcome(uint32 homeScore, uint32 awayScore, int32 lineTicks) private pure returns (Outcome) {
        // Safe cast: two scores of at most the games set's MAX_SCORE each, scaled by 10, fit an int32. That
        // holds for a market's settlement; the pure read takes any numbers, and IOspexScorer.outcome says what
        // it answers outside those bounds.
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 total = int32(homeScore + awayScore) * 10;
        if (total > lineTicks) return Outcome.Over;
        if (total < lineTicks) return Outcome.Under;
        return Outcome.Push;
    }
}
