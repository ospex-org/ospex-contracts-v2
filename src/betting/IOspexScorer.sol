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
    /// @param gameId The game
    /// @param lineTicks The market's line, scaled by 10: the home team's handicap for a spread, the total for a
    ///        total, ignored by the moneyline
    function outcomeOf(uint256 gameId, int32 lineTicks) external view returns (Outcome);

    /// @notice The outcome for two scores and a line, with nothing read: the arithmetic alone, so that anyone can
    ///         check how a market would settle on a score.
    /// @param homeScore The home team's score
    /// @param awayScore The away team's score
    /// @param lineTicks The market's line, scaled by 10
    function outcome(uint32 homeScore, uint32 awayScore, int32 lineTicks) external pure returns (Outcome);
}
