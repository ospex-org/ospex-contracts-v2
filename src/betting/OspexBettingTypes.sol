// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title OspexBettingTypes
 * @author ospex.org
 * @notice The types the betting set's contracts share: a market, its status and its outcome; a position and
 *         its side. The numbers of each enum are part of the set's interface: the events carry them and the
 *         reads return them.
 *
 *         The set's two scales are stated here, once; every other mention of a scale in the set is this one.
 *
 *         A line is in tenths of a point: a signed 32-bit integer, named lineTicks everywhere but on the
 *         spread contract, which names it homeLine. -35 is -3.5 points; 2205 is 220.5 points. Its magnitude
 *         is at most MAX_LINE_TICKS, 1,000,000 ticks or 100,000.0 points, which the markets module checks
 *         when a market is drawn. A score is in whole points, as the games set holds it, and at most the
 *         games set's MAX_SCORE, 1,000,000: a market contract multiplies a score by 10 before it meets a
 *         line.
 *
 *         A price is in hundredths of decimal odds: an unsigned 16-bit integer, named oddsTick. 191 is 1.91.
 *         The matching module holds the scale and its bounds: ODDS_SCALE, MIN_ODDS (1.01) and MAX_ODDS
 *         (101.00).
 *
 *         An amount of coin is in the coin's smallest unit and has no scale here.
 */

/// @notice A market: what positions are taken on, named by its game, its market contract and its line. Its id
///         is drawn at its first fill, so a market with no position does not exist. The two accounts of that
///         first fill are in the MarketCreated event and are not stored here.
/// @param gameId The game, in the games set this betting set is deployed beside
/// @param scorer The market contract that settles it: the moneyline, the spread or the total
/// @param lineTicks The line, scaled by 10: for a spread, the home team's handicap (-35 is -3.5 points);
///        for a total, the total (2205 is 220.5 points); 0 for a moneyline
/// @param status Open until it is settled, then Closed
/// @param outcome None until it is settled
struct Market {
    uint256 gameId;
    address scorer;
    int32 lineTicks;
    MarketStatus status;
    Outcome outcome;
}

/// @notice Where a market stands. An empty record reads as Open, since Open is 0: whether an id is a market is
///         answered by the markets module's getMarket, which refuses an id that is not one, never by this value.
enum MarketStatus {
    /// @dev 0: not settled. A fill is recorded only into an Open market.
    Open,
    /// @dev 1: settled, its outcome written. A position the outcome pays, and that has not claimed, may claim;
    ///      a losing position's claim is refused, and so is a second claim.
    Closed
}

/// @notice A market's outcome, read by its market contract from the game's scores once the game is scored, or
///         Void when the game is voided or released. One enum holds the three market contracts' results: the
///         moneyline and the spread answer Home, Away or Push; the total answers Over, Under or Push; the
///         markets module writes Void itself, with no market contract asked. Which side each outcome pays is
///         decided in one place, the positions module's payout.
enum Outcome {
    /// @dev 0: not settled.
    None,
    /// @dev 1: the away team wins, on a moneyline or a spread. Side B.
    Away,
    /// @dev 2: the home team wins, on a moneyline or a spread. Side A.
    Home,
    /// @dev 3: over the total. Side A.
    Over,
    /// @dev 4: under the total. Side B.
    Under,
    /// @dev 5: a tie on the line. Every stake goes back to its owner.
    Push,
    /// @dev 6: the game was voided or released. Every stake goes back to its owner.
    Void
}

/// @notice A market's two sides. Side A is the home team on a moneyline or a spread, and over on a total; side B
///         is the away team, or under.
enum Side {
    /// @dev 0: the home team, or over.
    A,
    /// @dev 1: the away team, or under.
    B
}

/// @notice One account's stake on one side of a market, matched against stakes on the other side. A claim
///         zeroes risk and profit and sets claimed. A losing position is never claimed: its claim is refused,
///         and it keeps its numbers. An empty position reads risk 0, profit 0 and side A, whichever side was
///         asked for.
/// @param risk What the account loses if its side loses
/// @param profit What it wins if its side wins
/// @param side The side it holds
/// @param claimed Whether its payout has been claimed
struct Position {
    uint256 risk;
    uint256 profit;
    Side side;
    bool claimed;
}
