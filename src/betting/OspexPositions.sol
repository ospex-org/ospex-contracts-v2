// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexModule} from "./IOspexModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOspexMarkets} from "./IOspexMarkets.sol";
import {IOspexPositions} from "./IOspexPositions.sol";
import {OspexBetting} from "./OspexBetting.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "./OspexBettingTypes.sol";

/**
 * @title OspexPositions
 * @author ospex.org
 * @notice The positions module of the betting set: it holds, for each account on each market, that account's
 *         worst loss on the market and no more, and pays a settled position out net of what came back early. A
 *         fill, recorded only by the matching module, draws the market if no fill has yet, passes the markets
 *         module's close gate, writes a position for each of the two accounts and pulls the resting account
 *         what lifts its held amount to its worst loss. The end of a Cross, sent by the matching module once
 *         after its legs, pulls the taking account the same way, once, and then pays every account of the Cross
 *         held above its worst loss the difference, to the account. A claim, once the market is settled, pays a
 *         position out once.
 *
 *         The worst loss. Over an account's two records on a market, `a` on side A and `b` on side B: the
 *         larger of b.risk - a.profit and a.risk - b.profit, each term taken as zero when it would be
 *         negative, and zero on a push or a void. Each term is compared before it is subtracted, so no negative
 *         number is formed. What is held, s_held, moves only where coin moves, by the amount that moved: up at
 *         a pull, down at a pay-back the coin accepted. s_heldTotal is the sum of a market's held amounts
 *         while the market is open and before its first claim, and what remains unpaid after; every pay-back
 *         and every claim is compared with it first and refused by name if it asks more, so one market's
 *         shortfall is never paid from another's coin. Once the market's last Cross has completed, s_held is
 *         frozen: no claim moves it, and the close gate lets no fill land after settlement.
 *
 *         The pulls and the receipts. A pull is the coin's transfer and no read before it of the account's
 *         balance or allowance, since a coin can refuse a transfer those reads would allow. A pull the coin
 *         refuses, by reverting or by answering false, reverts under its own name, with the account and the
 *         amount asked: a resting account's refusal carries its stake too, and the matching module reads it
 *         as the one failure of a fill that skips a resting order; the taking account's refusal reverts the
 *         whole Cross. After each pull this contract's balance must have risen by at least the amount pulled,
 *         or the call reverts. A leg whose resting account is the taking account writes both records and pulls
 *         nothing: that account is pulled once, at the end, over both its records.
 *
 *         The pay-backs. Each is made in a call this contract makes to itself, sendPayBack, which only this
 *         contract may call and which sends with the reverting transfer; finishFills makes that call inside a
 *         try and catches its failure. A coin that reverts fails the subcall; a coin that answers false makes
 *         the subcall revert too; and whatever the coin did inside the subcall is undone by that revert. The
 *         two held numbers are lowered before the call and put back if it fails, so a refused pay-back fails
 *         nothing, loses nothing, and stays held for the account: it goes out at the account's next pay-back on
 *         that market or in its claim. Nothing retries it on its own.
 *
 *         The claim. Any address may send one, and the payout goes to the position's owner. On a settled market
 *         an account's whole amount is what is held for it plus its net on the outcome, a.profit - b.risk when
 *         side A wins and b.profit - a.risk when side B wins, the net compared before it is subtracted, and
 *         nothing on a push or a void. On a win the winning side's record is paid the whole amount and the
 *         losing side's is refused; risk + profit is never formed. On a push or a void side A's record is paid
 *         the smaller of what is held and its own risk, and side B's record the rest. A claim marks its record
 *         and leaves its numbers; a marked record is refused. Nothing here divides, so nothing rounds.
 *
 *         What that holds, and what it does not. Whatever the coin does during a fill, a fill is recorded only
 *         if this contract's balance rose by at least what it pulled, and a call the coin makes during a pull
 *         or a pay-back can record no fill, end no Cross and pay no claim, which the reentrancy guard refuses;
 *         the markets module's settlement is held by neither guard, so a receiver that can release a game may
 *         settle its market from inside a pay-back, and the Cross then completes after it. What a coin does on
 *         the way out, a fee or a charge on a pay-back or a claim, is not checked: choosing the coin is the
 *         deploy's. A coin that calls the debited or the paid account during a transfer hands that account a
 *         way to make the whole transaction fail, by spending the gas passed to it. No gas limit is put on a
 *         pull or a pay-back. USDC makes no such call.
 *
 *         Who calls it, and what it calls. Only the matching module records a fill or ends a Cross, checked
 *         against the core's registry at each call: its Cross is the one path a fill arrives by. Anyone claims,
 *         for any account, and anyone reads. It calls the markets module, for a market's id, its drawing at a
 *         first fill, its close gate at every fill and its record at every claim; the coin, to pull, to pay and
 *         to read its own balance; itself, for each pay-back; and the core, for its registry reads and its
 *         event hub. A fill, the end of a Cross and both claims each hold the reentrancy guard; the pay-back
 *         entry does not, since the guard is held around it.
 *
 *         It has no owner, no setter and no pause, and no way out for the coin but a pay-back or a claim, each
 *         to the account whose money it is.
 */
contract OspexPositions is IOspexPositions, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant MARKET_MODULE = keccak256("MARKET_MODULE");

    // The core event types this module emits through the core's hub. Each payload is the typed event's
    // parameters in the typed event's order. The fill's core type is POSITION_MATCHED_PAIR; its typed event is
    // PositionFilled.
    bytes32 public constant EVENT_POSITION_MATCHED_PAIR = keccak256("POSITION_MATCHED_PAIR");
    bytes32 public constant EVENT_POSITION_CLAIMED = keccak256("POSITION_CLAIMED");
    bytes32 public constant EVENT_HELD_CHANGED = keccak256("HELD_CHANGED");
    bytes32 public constant EVENT_PAY_BACK_REFUSED = keccak256("PAY_BACK_REFUSED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the core address is zero
    error OspexPositions__InvalidAddress();
    /// @notice Thrown when an address other than the matching module records a fill or ends a Cross
    error OspexPositions__NotMatchingModule(address caller);
    /// @notice Thrown when a fill's risk is 0 on either side
    error OspexPositions__InvalidAmount();
    /// @notice Thrown when, after a pull, this contract's coin balance is under what it held before the pull
    ///         plus the amount pulled: owed is that sum, held the balance read
    error OspexPositions__ShortReceipt(uint256 owed, uint256 held);
    /// @notice Thrown when a position is claimed on a market that is not settled
    error OspexPositions__NotSettled(uint256 marketId);
    /// @notice Thrown when a position is claimed twice
    error OspexPositions__AlreadyClaimed();
    /// @notice Thrown when a position with nothing to pay is claimed: a loser's, or none
    error OspexPositions__NoPayout();
    /// @notice Thrown when a required module is not registered in the core
    error OspexPositions__ModuleNotSet(bytes32 moduleType);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The core
    OspexBetting public immutable i_ospexCore;
    /// @notice The coin the stakes are held in, as the core holds it. Fixed at deploy.
    IERC20 public immutable i_token;

    /// @notice Market id → account → side → position
    mapping(uint256 => mapping(address => mapping(Side => Position))) public s_positions;
    /// @inheritdoc IOspexPositions
    mapping(uint256 => mapping(address => uint256)) public override s_held;
    /// @inheritdoc IOspexPositions
    mapping(uint256 => uint256) public override s_heldTotal;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the positions module
    /// @param core The betting set's core, which holds the coin's address
    constructor(address core) {
        if (core == address(0)) revert OspexPositions__InvalidAddress();
        i_ospexCore = OspexBetting(core);
        i_token = OspexBetting(core).i_token();
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return POSITION_MODULE;
    }

    // ──────────────────────────── Fills ────────────────────────────────

    /// @inheritdoc IOspexPositions
    function recordFill(
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        Side makerSide,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) external override nonReentrant returns (uint256) {
        if (msg.sender != i_ospexCore.getModule(MATCHING_MODULE)) {
            revert OspexPositions__NotMatchingModule(msg.sender);
        }
        return _fill(gameId, scorer, lineTicks, makerSide, maker, makerRisk, taker, takerRisk);
    }

    /// @inheritdoc IOspexPositions
    /// @dev The guard is taken before the caller is checked. The taking account's pull comes first, over both
    ///      its records as the Cross left them; then the pay-backs, after every pull and every write of the
    ///      Cross. No close gate here: a market a receiver settled from inside a pay-back still takes the rest of
    ///      this Cross's pay-backs, and the Cross completes.
    function finishFills(uint256 marketId, address taker, address[] calldata makers) external override nonReentrant {
        if (msg.sender != i_ospexCore.getModule(MATCHING_MODULE)) revert OspexPositions__NotMatchingModule(msg.sender);
        (uint256 pull, bool pulled) = _pull(marketId, taker);
        if (!pulled) revert OspexPositions__TakerPullRefused(taker, pull);
        _payBack(marketId, taker);
        for (uint256 i; i < makers.length; ++i) {
            _payBack(marketId, makers[i]);
        }
    }

    /// @dev Draws the market if no fill has yet, then records the two positions and pulls the resting account.
    function _fill(
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        Side makerSide,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) internal returns (uint256 marketId) {
        if (makerRisk == 0 || takerRisk == 0) revert OspexPositions__InvalidAmount();

        IOspexMarkets markets = IOspexMarkets(_getModule(MARKET_MODULE));
        marketId = markets.getMarketId(gameId, scorer, lineTicks);
        if (marketId == 0) marketId = markets.createMarket(gameId, scorer, lineTicks, maker, taker);

        _record(markets, marketId, makerSide, maker, makerRisk, taker, takerRisk);
    }

    /// @dev The close gate, the two writes, the resting account's pull and its receipt. The markets module's
    ///      gate refuses, by name, a settled market, a game that has ended and a game at or after its start + n;
    ///      it is called at every fill, into a market just drawn as into an old one. Then each account's position
    ///      grows by its risk and the other's, and the resting account is pulled what lifts its held amount to
    ///      its worst loss as its records now stand, nothing when it is already there, each refusal under the
    ///      resting account's name with the stake and the amount asked. A leg whose resting account is the
    ///      taking account pulls nothing: both terms of that account's worst loss are unchanged by the leg, and
    ///      what it owes the Cross is pulled once, at finishFills. The taking account's coin is not touched here.
    function _record(
        IOspexMarkets markets,
        uint256 marketId,
        Side makerSide,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) private {
        markets.requireBetsOpen(marketId);

        Side takerSide = makerSide == Side.A ? Side.B : Side.A;

        Position storage makerPos = s_positions[marketId][maker][makerSide];
        makerPos.side = makerSide;
        makerPos.risk += makerRisk;
        makerPos.profit += takerRisk;

        Position storage takerPos = s_positions[marketId][taker][takerSide];
        takerPos.side = takerSide;
        takerPos.risk += takerRisk;
        takerPos.profit += makerRisk;

        if (maker != taker) {
            (uint256 pull, bool pulled) = _pull(marketId, maker);
            if (!pulled) revert OspexPositions__MakerPullRefused(maker, makerRisk, pull);
        }

        emit PositionFilled(marketId, maker, taker, makerSide, takerSide, makerRisk, takerRisk);
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_MATCHED_PAIR, abi.encode(marketId, maker, taker, makerSide, takerSide, makerRisk, takerRisk)
        );
    }

    /// @dev Lifts what is held for `account` on the market to its worst loss, pulling the difference: nothing
    ///      is pulled and nothing written when the held amount is already at or above it. Answers the amount
    ///      asked and whether the coin moved it; the caller names the refusal. The balance is read before and
    ///      after the pull, and the call reverts unless it rose by at least the amount: coin that reaches the
    ///      contract beside the pull cannot fail that check, and a short receipt always does.
    function _pull(uint256 marketId, address account) private returns (uint256 pull, bool pulled) {
        uint256 worst = _worstLoss(marketId, account);
        uint256 held = s_held[marketId][account];
        if (worst <= held) return (0, true);
        pull = worst - held;
        s_held[marketId][account] = worst;
        s_heldTotal[marketId] += pull;

        uint256 owed = i_token.balanceOf(address(this)) + pull;
        if (!i_token.trySafeTransferFrom(account, address(this), pull)) return (pull, false);
        uint256 balance = i_token.balanceOf(address(this));
        if (balance < owed) revert OspexPositions__ShortReceipt(owed, balance);

        emit HeldChanged(marketId, account, pull, 0, worst);
        i_ospexCore.emitCoreEvent(EVENT_HELD_CHANGED, abi.encode(marketId, account, pull, uint256(0), worst));
        return (pull, true);
    }

    /// @dev Pays `account` what it is held above its worst loss on the market, if anything: the amount is
    ///      compared with the market's total first, both numbers are lowered, and the amount is sent in a call
    ///      this contract makes to itself and catches. If the coin refuses, by reverting or by answering false,
    ///      the subcall's effects are undone with it, both numbers are put back, and the refusal is recorded;
    ///      the amount stays held for the account.
    function _payBack(uint256 marketId, address account) private {
        uint256 worst = _worstLoss(marketId, account);
        uint256 held = s_held[marketId][account];
        if (held <= worst) return;
        uint256 amount = held - worst;
        uint256 total = s_heldTotal[marketId];
        if (amount > total) revert OspexPositions__MarketShort(marketId, amount, total);
        s_held[marketId][account] = worst;
        s_heldTotal[marketId] = total - amount;

        try this.sendPayBack(account, amount) {
            emit HeldChanged(marketId, account, 0, amount, worst);
            i_ospexCore.emitCoreEvent(EVENT_HELD_CHANGED, abi.encode(marketId, account, uint256(0), amount, worst));
        } catch {
            s_held[marketId][account] = held;
            s_heldTotal[marketId] = total;
            emit PayBackRefused(marketId, account, amount, held);
            i_ospexCore.emitCoreEvent(EVENT_PAY_BACK_REFUSED, abi.encode(marketId, account, amount, held));
        }
    }

    /// @inheritdoc IOspexPositions
    /// @dev No reentrancy guard: finishFills holds it around this call, and a guard here would refuse every
    ///      pay-back. The self-only check is what keeps this entry from being a way out of the contract.
    function sendPayBack(address account, uint256 amount) external override {
        if (msg.sender != address(this)) revert OspexPositions__NotSelf(msg.sender);
        i_token.safeTransfer(account, amount);
    }

    // ──────────────────────────── Claims ───────────────────────────────

    /// @inheritdoc IOspexPositions
    function claimPosition(uint256 marketId, Side side) external override nonReentrant returns (uint256 payout) {
        return _claim(marketId, msg.sender, side);
    }

    /// @inheritdoc IOspexPositions
    function claimPositionFor(uint256 marketId, address account, Side side)
        external
        override
        nonReentrant
        returns (uint256 payout)
    {
        return _claim(marketId, account, side);
    }

    /// @dev The one body behind both claims. The market must be settled; the record unclaimed and with
    ///      something to pay; the amount within the market's total. The record is marked and keeps its numbers,
    ///      the total falls by the amount, and the coin goes to the account with the reverting transfer: a
    ///      refusal reverts the whole call, so the record stays claimable.
    function _claim(uint256 marketId, address account, Side side) private returns (uint256 payout) {
        Market memory m = IOspexMarkets(_getModule(MARKET_MODULE)).getMarket(marketId);
        if (m.status != MarketStatus.Closed) revert OspexPositions__NotSettled(marketId);

        Position storage pos = s_positions[marketId][account][side];
        if (pos.claimed) revert OspexPositions__AlreadyClaimed();

        payout = _share(marketId, account, side, m.outcome);
        if (pos.risk == 0 || payout == 0) revert OspexPositions__NoPayout();
        uint256 total = s_heldTotal[marketId];
        if (payout > total) revert OspexPositions__MarketShort(marketId, payout, total);

        pos.claimed = true;
        s_heldTotal[marketId] = total - payout;

        i_token.safeTransfer(account, payout);

        emit PositionClaimed(marketId, account, side, payout);
        i_ospexCore.emitCoreEvent(EVENT_POSITION_CLAIMED, abi.encode(marketId, account, side, payout));
    }

    // ──────────────────────────── Reads ───────────────────────────────

    /// @inheritdoc IOspexPositions
    function getPosition(uint256 marketId, address user, Side side)
        external
        view
        override
        returns (Position memory position)
    {
        position = s_positions[marketId][user][side];
    }

    /// @inheritdoc IOspexPositions
    function previewFill(uint256 marketId, address account, Side side, uint256 risk, uint256 profit)
        external
        view
        override
        returns (uint256 pull, uint256 payBack)
    {
        Position storage a = s_positions[marketId][account][Side.A];
        Position storage b = s_positions[marketId][account][Side.B];
        (uint256 riskA, uint256 profitA, uint256 riskB, uint256 profitB) = (a.risk, a.profit, b.risk, b.profit);
        if (side == Side.A) {
            riskA += risk;
            profitA += profit;
        } else {
            riskB += risk;
            profitB += profit;
        }
        uint256 worst = _worst(riskA, profitA, riskB, profitB);
        uint256 held = s_held[marketId][account];
        pull = worst > held ? worst - held : 0;
        payBack = held > worst ? held - worst : 0;
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev An account's worst loss on a market, over its two records as they stand.
    function _worstLoss(uint256 marketId, address account) private view returns (uint256) {
        Position storage a = s_positions[marketId][account][Side.A];
        Position storage b = s_positions[marketId][account][Side.B];
        return _worst(a.risk, a.profit, b.risk, b.profit);
    }

    /// @dev The worst loss over two records: if side A wins the account wins profitA and loses riskB; if side B
    ///      wins, the mirror; a push or a void loses nothing. Each term is compared before it is subtracted.
    function _worst(uint256 riskA, uint256 profitA, uint256 riskB, uint256 profitB) private pure returns (uint256) {
        uint256 ifAWins = riskB > profitA ? riskB - profitA : 0;
        uint256 ifBWins = riskA > profitB ? riskA - profitB : 0;
        return ifAWins > ifBWins ? ifAWins : ifBWins;
    }

    /// @dev An account's whole amount on a settled market: what is held for it plus its net on the outcome. When
    ///      side A wins the net is profitA - riskB, when side B wins profitB - riskA, each compared before it is
    ///      subtracted; the subtraction from the held amount cannot underflow, since what is held is at least
    ///      the worst loss. On a push or a void the whole is what is held.
    function _whole(uint256 marketId, address account, Outcome outcome) private view returns (uint256) {
        Position storage a = s_positions[marketId][account][Side.A];
        Position storage b = s_positions[marketId][account][Side.B];
        uint256 held = s_held[marketId][account];
        if (outcome == Outcome.Home || outcome == Outcome.Over) {
            return a.profit >= b.risk ? held + (a.profit - b.risk) : held - (b.risk - a.profit);
        }
        if (outcome == Outcome.Away || outcome == Outcome.Under) {
            return b.profit >= a.risk ? held + (b.profit - a.risk) : held - (a.risk - b.profit);
        }
        return held;
    }

    /// @dev What one record of an account is paid on an outcome: on a win the whole amount on the winning
    ///      side's record, side A on Home or Over and side B on Away or Under, and nothing on the other; on a
    ///      push or a void side A's record the smaller of the whole and its own risk, and side B's the rest.
    function _share(uint256 marketId, address account, Side side, Outcome outcome) private view returns (uint256) {
        uint256 whole = _whole(marketId, account, outcome);
        if (outcome == Outcome.Push || outcome == Outcome.Void) {
            uint256 riskA = s_positions[marketId][account][Side.A].risk;
            uint256 shareA = whole < riskA ? whole : riskA;
            return side == Side.A ? shareA : whole - shareA;
        }
        bool aWins = outcome == Outcome.Home || outcome == Outcome.Over;
        return (side == Side.A) == aWins ? whole : 0;
    }

    /// @dev Resolves a module address from the core, reverting if not set. The core writes a type's address
    ///      once, so for a registered type this answers the same address at every call: wired once, then
    ///      locked.
    function _getModule(bytes32 moduleType) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) revert OspexPositions__ModuleNotSet(moduleType);
    }
}
