// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Position, Side} from "./OspexBettingTypes.sol";
import {IOspexModule} from "./IOspexModule.sol";

/**
 * @title IOspexPositions
 * @author ospex.org
 * @notice The positions module: it holds, for each account on each market, that account's worst loss on the
 *         market and no more, records each fill, pays back what a fill leaves held above the worst loss, and
 *         pays a settled position out. It has no owner and no setter: no function but a fill pulls coin in,
 *         and none but a pay-back, made inside a fill, or a claim sends coin out.
 */
interface IOspexPositions is IOspexModule {
    /// @notice Thrown by a fill when the coin refuses the pull of the resting account's netted amount: the
    ///         transfer reverts or answers false. It carries the account, the stake it rests on this leg and
    ///         the amount asked of it, which is what lifts its held amount to its worst loss and is at most the
    ///         stake. The matching module reads this error, by its selector, the account and the stake, as the
    ///         one failure of a fill that skips a resting order; the third word is not compared.
    error OspexPositions__MakerPullRefused(address maker, uint256 makerRisk, uint256 pull);
    /// @notice Thrown by the end of a Cross when the coin refuses the taking account's one pull: the transfer
    ///         reverts or answers false. It carries the account and the amount asked, the netted pull over
    ///         every leg of the Cross.
    error OspexPositions__TakerPullRefused(address taker, uint256 pull);
    /// @notice Thrown by a pay-back or a claim that asks more than its market holds: asked is the amount, total
    ///         what the market holds. One market's shortfall is never paid from another market's coin.
    error OspexPositions__MarketShort(uint256 marketId, uint256 asked, uint256 total);
    /// @notice Thrown by the pay-back entry when its caller is any address but this contract's own
    error OspexPositions__NotSelf(address caller);

    /// @notice Emitted when a fill is recorded. The maker's profit is the taker's risk and the taker's profit
    ///         the maker's risk, so the two risks say everything. The amounts are the leg's two stakes, not
    ///         what was pulled.
    /// @param marketId The market
    /// @param maker The account whose resting order was taken
    /// @param taker The account that took it: the taking order's account, never the address that sent the fill
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
    /// @param payout What was paid: on a win the account's whole amount, what was held for it plus its net on
    ///               the outcome, on the winning side's record; on a push or a void side A's record up to its
    ///               risk and side B's the rest
    event PositionClaimed(uint256 indexed marketId, address indexed user, Side side, uint256 payout);

    /// @notice Emitted at every pull and every pay-back made: coin moved and the held amount with it, by that
    ///         amount. Not emitted for a rebalance that moved nothing, nor for a pay-back the coin refused.
    /// @param marketId The market
    /// @param account The account whose held amount changed
    /// @param pulled What was pulled from the account, or zero
    /// @param paidBack What was paid back to the account, or zero
    /// @param held What is held for the account on the market after the change
    event HeldChanged(
        uint256 indexed marketId, address indexed account, uint256 pulled, uint256 paidBack, uint256 held
    );

    /// @notice Emitted when the coin refuses a pay-back, by reverting or by answering false. The amount stays
    ///         held for the account and goes out at its next pay-back on the market or in its claim.
    /// @param marketId The market
    /// @param account The account the pay-back was addressed to
    /// @param amount What the coin refused
    /// @param held What stays held for the account, the amount included
    event PayBackRefused(uint256 indexed marketId, address indexed account, uint256 amount, uint256 held);

    /// @notice Records a fill: draws the market if no fill has yet, passes the markets module's close gate,
    ///         writes both positions and pulls the resting account what lifts its held amount to its worst
    ///         loss on the market, nothing when it is already there, and nothing when the resting account is
    ///         the taking account. The taking account is not pulled here: it is pulled once, at finishFills.
    ///         Only the matching module calls it. A pull the coin refuses reverts the fill by name,
    ///         MakerPullRefused, and the fill reverts too unless this contract's coin balance rose by at least
    ///         the amount pulled.
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

    /// @notice Ends a Cross's fills on a market: pulls the taking account once, what lifts its held amount to
    ///         its worst loss over both its records as the Cross left them, then pays every account of the
    ///         Cross held above its worst loss the difference, the taking account first and then each resting
    ///         account in list order, an account listed twice visited twice. Only the matching module calls
    ///         it. A taking pull the coin refuses reverts by name, TakerPullRefused, which reverts the whole
    ///         Cross. A pay-back the coin refuses reverts nothing: it is recorded, PayBackRefused, and the
    ///         amount stays held for the account.
    /// @param marketId The market the Cross's legs filled into
    /// @param taker The taking account
    /// @param makers The resting accounts of the filled legs, in list order
    function finishFills(uint256 marketId, address taker, address[] calldata makers) external;

    /// @notice Pays the caller's position on a settled market out, once. Refused while the market is not
    ///         settled, for an id that is not a market, for a position already claimed, and for one with
    ///         nothing to pay: a loser's, or none. The payout is net of what came back early: see
    ///         claimPositionFor.
    /// @param marketId The market
    /// @param side The position's side
    /// @return payout What was paid
    function claimPosition(uint256 marketId, Side side) external returns (uint256 payout);

    /// @notice Pays an account's position on a settled market out, once, to the account and never to the
    ///         caller. Any address may call it. On a win the winning side's record is paid the account's whole
    ///         amount, what is held for it plus its net on the outcome, and the losing side's record is refused;
    ///         on a push or a void side A's record is paid the smaller of what is held and its risk, and side
    ///         B's record the rest. A record is paid once and keeps its numbers. Refused as claimPosition is,
    ///         and for the zero account.
    /// @param marketId The market
    /// @param account The position's owner, which is paid
    /// @param side The position's side
    /// @return payout What was paid
    function claimPositionFor(uint256 marketId, address account, Side side) external returns (uint256 payout);

    /// @notice The pay-back entry: sends `amount` of the coin to `account` with the reverting transfer. Only
    ///         this contract calls it, from finishFills, inside a try whose catch records the refusal; any other
    ///         caller is refused, NotSelf. It carries no reentrancy guard of its own, since finishFills holds
    ///         the guard around it.
    /// @param account The account paid
    /// @param amount What is paid
    function sendPayBack(address account, uint256 amount) external;

    /// @notice What one fill would move for one account: the account's two records on the market, the record
    ///         on `side` grown by `risk` and `profit`, against what is held for it. Answers the pull that would
    ///         lift the held amount to the worst loss, or the pay-back that would lower it, one of them zero.
    ///         One account and one growth: a Cross of several legs, or an account in both roles, is forecast by
    ///         reading each account's two records and its held amount once and walking the legs in memory.
    /// @param marketId The market, which must be drawn
    /// @param account The account
    /// @param side The side the record grows on
    /// @param risk What the record's risk would grow by
    /// @param profit What its profit would grow by
    /// @return pull What would be pulled from the account
    /// @return payBack What would be paid back to it
    function previewFill(uint256 marketId, address account, Side side, uint256 risk, uint256 profit)
        external
        view
        returns (uint256 pull, uint256 payBack);

    /// @notice What the contract holds for an account on a market. It rises at a pull and falls at a pay-back
    ///         the coin accepted, by the amount that moved, and at nothing else: once the market's last Cross
    ///         has completed it is frozen, and a claim does not move it.
    function s_held(uint256 marketId, address account) external view returns (uint256);

    /// @notice The sum of a market's held amounts while the market is open and before its first claim; after
    ///         that, what remains unpaid. Every pay-back and every claim is compared with it first and refused
    ///         by name, MarketShort, if it asks more.
    function s_heldTotal(uint256 marketId) external view returns (uint256);

    /// @notice An account's position on one side of a market. Empty for an account with none: risk 0, profit 0
    ///         and side A, whichever side was asked for. After its claim a position keeps its numbers and reads
    ///         claimed.
    function getPosition(uint256 marketId, address user, Side side) external view returns (Position memory position);
}
