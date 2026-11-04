// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title OspexBettingTypes
 * @author ospex.org
 * @notice The types the betting set's contracts share: a market, its status and its outcome; a position and
 *         its side. The numbers of each enum are part of the set's interface: the events carry them and the
 *         reads return them.
 */

/// @notice A market: what positions are taken on, named by its game, its market contract and its line. Its id
///         is drawn at its first fill, so a market with no position does not exist.
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

/// @notice Where a market stands.
enum MarketStatus {
    /// @dev 0: taking positions, not settled.
    Open,
    /// @dev 1: settled; its positions are claimable.
    Closed
}

/// @notice A market's outcome, read by its market contract from the game's scores once the game is scored, or
///         Void when the game is voided or released.
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

/// @notice One account's stake on one side of a market, matched against stakes on the other side.
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
