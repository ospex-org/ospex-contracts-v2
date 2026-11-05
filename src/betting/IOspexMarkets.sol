// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Market, Outcome} from "./OspexBettingTypes.sol";
import {IOspexModule} from "./IOspexModule.sol";

/**
 * @title IOspexMarkets
 * @author ospex.org
 * @notice The markets module: each market's record, drawn at its first fill, and its settlement, which anyone
 *         may call once the market's game has ended. A market settles only on its game's own status, read from
 *         the games set: a scored game settles it through its market contract; a voided or a released game
 *         voids it.
 */
interface IOspexMarkets is IOspexModule {
    /// @notice Emitted when a market is drawn, at its first fill. The two accounts are in this event alone: the
    ///         market's record does not store them.
    /// @param marketId The new market's id
    /// @param gameId Its game
    /// @param scorer Its market contract
    /// @param lineTicks Its line, scaled by 10
    /// @param maker The account whose resting order the first fill took
    /// @param taker The account that took it
    event MarketCreated(
        uint256 indexed marketId, uint256 indexed gameId, address scorer, int32 lineTicks, address maker, address taker
    );

    /// @notice Emitted when a market is settled.
    /// @param marketId The market
    /// @param outcome Its outcome
    /// @param scorer Its market contract
    event MarketSettled(uint256 indexed marketId, Outcome outcome, address scorer);

    /// @notice Draws a market. Only the positions module calls it, at the market's first fill.
    /// @param gameId The game, which must be a game of the games set and must not have ended
    /// @param scorer One of the three market contracts
    /// @param lineTicks The line, scaled by 10: 0 for a moneyline, at least 0 for a total, the home team's
    ///        handicap for a spread, and within MAX_LINE_TICKS for all three
    /// @param maker The account whose resting order the first fill took, for the event
    /// @param taker The account that took it, for the event
    /// @return marketId The new market's id
    function createMarket(uint256 gameId, address scorer, int32 lineTicks, address maker, address taker)
        external
        returns (uint256 marketId);

    /// @notice Settles a market. Anyone calls it. The game's status, read from the games set, decides: scored, the
    ///         market contract reads the scores and names the outcome; voided or released, the outcome is Void;
    ///         anything else, refused. Refused too for an id that is not a market and for a market already
    ///         settled. Nothing settles a market on its own: it stays Open after its game ends until this call.
    /// @param marketId The market
    function settleMarket(uint256 marketId) external;

    /// @notice A market's record. Refused for an id that is not a market.
    function getMarket(uint256 marketId) external view returns (Market memory market);

    /// @notice The id of the market on `gameId`, `scorer` and `lineTicks`, or 0 while no fill has drawn it.
    function getMarketId(uint256 gameId, address scorer, int32 lineTicks) external view returns (uint256 marketId);

    /// @notice How many markets have been drawn. Ids run from 1 to this number.
    function marketCount() external view returns (uint256);
}
