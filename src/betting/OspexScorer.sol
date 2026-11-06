// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexGames} from "../games/IOspexGames.sol";
import {IOspexScorer} from "./IOspexScorer.sol";
import {OspexBetting} from "./OspexBetting.sol";

/**
 * @title OspexScorer
 * @author ospex.org
 * @notice What the three market contracts share: the games set, read from the core at deploy, and the one read
 *         of a game's scores from it, the home team's then the away team's. Each market contract supplies its
 *         own arithmetic and its two reads. A market contract reads the games set its core named when the
 *         contract was deployed, and no other. It has no storage and emits nothing: what it holds is the games
 *         set's address, i_games, an immutable fixed at its deploy. After its deploy the scores read is the
 *         one call it makes. The markets module calls its outcomeOf at a settlement, and anyone may read it.
 */
abstract contract OspexScorer is IOspexScorer {
    /// @notice The games set, as the core holds it. Fixed at deploy.
    IOspexGames public immutable i_games;

    /// @notice Thrown when the core address is zero
    error OspexScorer__InvalidCore();

    /// @param core The betting set's core, which holds the games set's address
    constructor(address core) {
        if (core == address(0)) revert OspexScorer__InvalidCore();
        i_games = OspexBetting(core).i_games();
    }

    /// @dev A game's scores from the games set, which returns the home team's first, then the away team's, and
    ///      refuses the read with NotScored unless the game is scored.
    function _scores(uint256 gameId) internal view returns (uint32 homeScore, uint32 awayScore) {
        (homeScore, awayScore) = i_games.getGameScores(gameId);
    }
}
