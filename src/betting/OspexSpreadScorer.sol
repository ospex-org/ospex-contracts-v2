// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexModule} from "./IOspexModule.sol";
import {IOspexScorer} from "./IOspexScorer.sol";
import {OspexScorer} from "./OspexScorer.sol";
import {Outcome} from "./OspexBettingTypes.sol";

/**
 * @title OspexSpreadScorer
 * @author ospex.org
 * @notice The spread: the line is the home team's handicap, `homeLine`, scaled by 10 (-35 is -3.5 points). The
 *         home team covers when home + homeLine > away; the away team covers when home + homeLine < away; equal
 *         is a push. Side A is the home team, side B the away team. A book shows the same line per team, the
 *         home team at homeLine and the away team at its negation.
 */
contract OspexSpreadScorer is OspexScorer {
    bytes32 public constant SPREAD_SCORER_MODULE = keccak256("SPREAD_SCORER_MODULE");

    /// @param core The betting set's core
    constructor(address core) OspexScorer(core) {}

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return SPREAD_SCORER_MODULE;
    }

    /// @inheritdoc IOspexScorer
    /// @param gameId The game
    /// @param homeLine The home team's handicap, scaled by 10
    function outcomeOf(uint256 gameId, int32 homeLine) external view override returns (Outcome) {
        (uint32 homeScore, uint32 awayScore) = _scores(gameId);
        return _outcome(homeScore, awayScore, homeLine);
    }

    /// @inheritdoc IOspexScorer
    /// @param homeScore The home team's score
    /// @param awayScore The away team's score
    /// @param homeLine The home team's handicap, scaled by 10
    function outcome(uint32 homeScore, uint32 awayScore, int32 homeLine) external pure override returns (Outcome) {
        return _outcome(homeScore, awayScore, homeLine);
    }

    /// @dev Both scores are scaled by 10 to the line's scale. Home when home + homeLine > away, Away when
    ///      home + homeLine < away, Push when equal.
    function _outcome(uint32 homeScore, uint32 awayScore, int32 homeLine) private pure returns (Outcome) {
        // Safe casts: a score is at most the games set's MAX_SCORE, 1,000,000, so scaled by 10 it fits an int32
        // beside a line of at most MAX_LINE_TICKS. That holds for a market's settlement; the pure read takes
        // any numbers, and IOspexScorer.outcome says what it answers outside those bounds.
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 home = int32(homeScore) * 10 + homeLine;
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 away = int32(awayScore) * 10;
        if (home > away) return Outcome.Home;
        if (home < away) return Outcome.Away;
        return Outcome.Push;
    }
}
