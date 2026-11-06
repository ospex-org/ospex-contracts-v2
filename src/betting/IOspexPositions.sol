// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Position, Side} from "./OspexBettingTypes.sol";
import {IOspexModule} from "./IOspexModule.sol";

/**
 * @title IOspexPositions
 * @author ospex.org
 * @notice The positions module: it holds the stakes between a fill and a claim, records each fill, and pays a
 *         settled position out. It has no owner and no setter: no function but a fill pulls coin in, and none
 *         but a claim sends coin out.
 */
interface IOspexPositions is IOspexModule {
    /// @notice Emitted when a fill is recorded. The maker's profit is the taker's risk and the taker's profit
    ///         the maker's risk, so the two risks say everything.
    /// @param marketId The market
    /// @param maker The account whose resting order was taken
    /// @param taker The account that took it
    /// @param makerSide The maker's side
    /// @param takerSide The taker's side, the other one
    /// @param makerRisk What the maker risks, and the taker wins
    /// @param takerRisk What the taker risks, and the maker wins
    event PositionFilled(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        Side makerSide,
        Side takerSide,
        uint256 makerRisk,
        uint256 takerRisk
    );

    /// @notice Emitted when a settled position is paid out.
    /// @param marketId The market
    /// @param user The position's owner, which is paid
    /// @param side Its side
    /// @param payout What was paid: risk and profit for a winner, the risk alone on a push or a void
    event PositionClaimed(uint256 indexed marketId, address indexed user, Side side, uint256 payout);

    /// @notice Records a fill: draws the market if no fill has yet, writes both positions and pulls both stakes.
    ///         Only the matching module calls it.
    /// @param gameId The game
    /// @param scorer The market contract
    /// @param lineTicks The line, scaled by 10
    /// @param makerSide The maker's side; the taker takes the other
    /// @param maker The account whose resting order was taken
    /// @param makerRisk What the maker risks
    /// @param taker The account that took it
    /// @param takerRisk What the taker risks
    /// @return marketId The market the fill went into
    function recordFill(
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        Side makerSide,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) external returns (uint256 marketId);

    /// @notice Pays the caller's position on a settled market out, once. Refused while the market is not
    ///         settled, for an id that is not a market, for a position already claimed, and for one with
    ///         nothing to pay: a loser's, or none.
    /// @param marketId The market
    /// @param side The position's side
    function claimPosition(uint256 marketId, Side side) external;

    /// @notice An account's position on one side of a market. Empty for an account with none: risk 0, profit 0
    ///         and side A, whichever side was asked for. After its claim a position reads risk 0, profit 0 and
    ///         claimed.
    function getPosition(uint256 marketId, address user, Side side) external view returns (Position memory position);
}
