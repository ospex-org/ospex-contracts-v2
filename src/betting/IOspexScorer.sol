// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Outcome} from "./OspexBettingTypes.sol";
import {IOspexModule} from "./IOspexModule.sol";

/**
 * @title IOspexScorer
 * @author ospex.org
 * @notice What a market contract answers. There are three, the moneyline, the spread and the total, fixed at the
 *         core's finalize: each turns a scored game's two scores and a market's line into the market's outcome.
 *         A signed order names a market's contract in its `scorer` field, which keeps that name.
 */
interface IOspexScorer is IOspexModule {
    /// @notice The outcome of a market on `gameId` with `lineTicks`, read from the games set's scores, the home
    ///         team's then the away team's. The games set refuses the read unless the game is scored.
    /// @dev The line is the caller's. The markets module passes a market's own, which is within MAX_LINE_TICKS;
    ///      on a line near the top of the integer's range the spread's arithmetic overflows, which reverts.
    /// @param gameId The game
    /// @param lineTicks The market's line, scaled by 10: the home team's handicap for a spread, the total for a
    ///        total, ignored by the moneyline
    function outcomeOf(uint256 gameId, int32 lineTicks) external view returns (Outcome);

    /// @notice The outcome for two scores and a line, with nothing read: the arithmetic alone, so that anyone can
    ///         check how a market would settle on a score.
    /// @dev Correct for what a market can hold: scores of at most the games set's MAX_SCORE and a line within
    ///      MAX_LINE_TICKS. Nothing bounds the arguments here, and the spread's and the total's arithmetic
    ///      casts them to a signed 32-bit integer on that assumption: beyond those bounds a call can revert on
    ///      overflow, or return a wrong outcome where a cast wraps. No market settles on such numbers: the
    ///      games set refuses a score above MAX_SCORE, and the markets module a line beyond MAX_LINE_TICKS.
    /// @param homeScore The home team's score
    /// @param awayScore The away team's score
    /// @param lineTicks The market's line, scaled by 10
    function outcome(uint32 homeScore, uint32 awayScore, int32 lineTicks) external pure returns (Outcome);
}
