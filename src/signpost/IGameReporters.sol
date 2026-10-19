// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IGameReporters
 * @author ospex.org
 * @notice The read a games contract answers with a game's reporters: the addresses that may write the
 *         game's start and how it ended, as the game recorded them when it was made, and each one's kind.
 * @dev OspexSignpost calls it, for a game the move names, before it moves an entry that holds games to
 *      live. The signpost's code never changes, so this selector and its return shape are fixed for every
 *      games contract that is to be listed as live.
 */
interface IGameReporters {
    /// @param gameId The game.
    /// @return reporters The game's reporters, as recorded at its creation.
    /// @return kinds Each reporter's kind, in the same order as `reporters`.
    function getGameReporters(uint256 gameId) external view returns (address[] memory reporters, uint8[] memory kinds);
}
