// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOspexModule} from "../../src/betting/IOspexModule.sol";
import {IOspexMarkets} from "../../src/betting/IOspexMarkets.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";

// The gross reference: the positions module as it stood before shared collateral, frozen here from the commit
// the change was built on, its interface and its contract in one file. It pulls each account's stake in full
// at each leg, pays nothing back before the score, and pays a winner risk and profit: the accounting every
// account's end balance under the netted module must match to the unit. It differs from that commit's source in
// two places and no others: finishFills, which the matching module now calls once after the walk, is added
// with an empty body, since the gross module has nothing to do at it; and the maker's refusal carries a third
// word, the amount asked, which for a gross pull is the stake, so that the matching module reads the refusal as
// it reads the netted module's. The names carry "GrossPositionsReference" so the two can be deployed side by
// side, and the import paths reach into src/. Nothing of the arithmetic is changed.

/**
 * @title IGrossPositionsReference
 * @author ospex.org
 * @notice The positions module: it holds the stakes between a fill and a claim, records each fill, and pays a
 *         settled position out. It has no owner and no setter: no function but a fill pulls coin in, and none
 *         but a claim sends coin out.
 */
interface IGrossPositionsReference is IOspexModule {
    /// @notice Thrown by a fill when the coin refuses the pull of the maker's stake: the transfer reverts or
    ///         answers false. It carries the maker and the stake asked of it. The matching module reads this
    ///         error, with these two values, as the one failure of a fill that skips a resting order.
    error OspexPositions__MakerPullRefused(address maker, uint256 makerRisk, uint256 pull);
    /// @notice Thrown by a fill when the coin refuses the pull of the taker's stake: the transfer reverts or
    ///         answers false. It carries the taker and the stake asked of it.
    error OspexPositions__TakerPullRefused(address taker, uint256 takerRisk);

    /// @notice Emitted when a fill is recorded. The maker's profit is the taker's risk and the taker's profit
    ///         the maker's risk, so the two risks say everything.
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
    /// @param payout What was paid: risk and profit for a winner, the risk alone on a push or a void
    event PositionClaimed(uint256 indexed marketId, address indexed user, Side side, uint256 payout);

    /// @notice Records a fill: draws the market if no fill has yet, passes the markets module's close gate,
    ///         writes both positions and pulls both stakes, the maker's first. Only the matching module calls
    ///         it. A pull the coin refuses reverts the fill by name, MakerPullRefused or TakerPullRefused, and
    ///         the fill reverts too unless this contract's coin balance rose by at least the two stakes.
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

    /// @notice The end of a Cross, as the matching module now sends it after the walk. The gross module has
    ///         nothing to do at it: the taker was pulled at each leg, and nothing is paid back before the score.
    function finishFills(uint256 marketId, address taker, address[] calldata makers) external;

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

/**
 * @title GrossPositionsReference
 * @author ospex.org
 * @notice The positions module of the betting set: it holds every stake between its fill and its claim. A fill,
 *         recorded only by the matching module, draws the market if no fill has yet, passes the markets
 *         module's close gate, writes a position for each of the two accounts and pulls each account's stake
 *         in the set's coin. A claim, once the market is settled, pays a position out once: risk and profit to
 *         a winner, the risk alone on a push or a void, nothing to a loser.
 *
 *         Both accounts approve this contract for the coin, and nothing else: no fee is taken at a fill, so
 *         there is no second allowance. A maker's profit is the taker's risk and the taker's profit the maker's
 *         risk, so with a coin that moves exactly the amount asked, as USDC does, what the contract holds for a
 *         market is what its positions can claim. Coin sent here outside a pull belongs to no position, and no
 *         function sends it back.
 *
 *         The two pulls and the receipt. The maker's stake is pulled first, then the taker's. A pull the coin
 *         refuses, by reverting or by answering false, reverts the fill under its own name, one for each of
 *         the two accounts, with the account and the amount: no balance or allowance is read first, since a
 *         coin can refuse a transfer those reads would allow. After both pulls the fill reverts unless this
 *         contract's balance rose by at least the two stakes. Coin that reaches the contract beside the two
 *         pulls cannot fail that check; a short receipt always does.
 *
 *         What that holds, and what it does not. Whatever the coin does during a fill, a fill is recorded only
 *         if this contract's balance rose by at least what the two positions record, and a call the coin makes
 *         during a pull can record no fill and pay no claim, which the reentrancy guard refuses. What a coin
 *         does outside a fill, a rebase or a fee on the transfer that pays a claim, is not checked: choosing
 *         the coin is the deploy's. And a coin that calls the debited account during a transfer hands that
 *         account a way to make the fill's whole transaction fail, by spending the gas passed to it or by
 *         ending the game, where its release is open, so that a later fill of the same transaction meets the
 *         close gate. No gas limit is put on the pulls and nothing is skipped at the close gate. USDC makes no
 *         such call.
 *
 *         Who calls it, and what it calls. Only the matching module records a fill, checked against the core's
 *         registry at each call: its Cross is the one path a fill arrives by. An account claims its own
 *         position, and anyone reads. It calls the markets module, for a market's id, its drawing at a first
 *         fill, its close gate at every fill and its record at every claim; the coin, to pull the two stakes
 *         and read its own balance at a fill, and to pay at a claim; and the core, for its registry reads and
 *         its event hub. A fill and a claim each hold the reentrancy guard.
 *
 *         It has no owner, no setter and no pause, and no way out for the coin but a claim.
 */
contract GrossPositionsReference is IGrossPositionsReference, ReentrancyGuardTransient {
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

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the core address is zero
    error OspexPositions__InvalidAddress();
    /// @notice Thrown when an address other than the matching module records a fill
    error OspexPositions__NotMatchingModule(address caller);
    /// @notice Thrown when a fill's risk is 0 on either side
    error OspexPositions__InvalidAmount();
    /// @notice Thrown when, after a fill's two pulls, this contract's coin balance is under what it held before
    ///         them plus the two stakes: owed is that sum, held the balance read
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

    /// @inheritdoc IGrossPositionsReference
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

    /// @dev Draws the market if no fill has yet, then records the two positions and pulls the two stakes.
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

    /// @dev The close gate, the write, the two pulls and the receipt. The markets module's gate refuses, by
    ///      name, a settled market, a game that has ended and a game at or after its start + n; it is called
    ///      at every fill, into a market just drawn as into an old one. Then each account's position grows by
    ///      its risk and the other's, the maker's stake is pulled and then the taker's, each refusal under its
    ///      own name, and the balance is read against what it was before the pulls: at least the two stakes
    ///      more, or the fill reverts.
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

        uint256 owed = i_token.balanceOf(address(this)) + makerRisk + takerRisk;
        if (!i_token.trySafeTransferFrom(maker, address(this), makerRisk)) {
            revert OspexPositions__MakerPullRefused(maker, makerRisk, makerRisk);
        }
        if (!i_token.trySafeTransferFrom(taker, address(this), takerRisk)) {
            revert OspexPositions__TakerPullRefused(taker, takerRisk);
        }
        uint256 held = i_token.balanceOf(address(this));
        if (held < owed) revert OspexPositions__ShortReceipt(owed, held);

        emit PositionFilled(marketId, maker, taker, makerSide, takerSide, makerRisk, takerRisk);
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_MATCHED_PAIR, abi.encode(marketId, maker, taker, makerSide, takerSide, makerRisk, takerRisk)
        );
    }

    /// @inheritdoc IGrossPositionsReference
    function finishFills(uint256, address, address[] calldata) external override {}

    // ──────────────────────────── Claims ───────────────────────────────

    /// @inheritdoc IGrossPositionsReference
    function claimPosition(uint256 marketId, Side side) external override nonReentrant {
        Market memory m = IOspexMarkets(_getModule(MARKET_MODULE)).getMarket(marketId);
        if (m.status != MarketStatus.Closed) revert OspexPositions__NotSettled(marketId);

        Position storage pos = s_positions[marketId][msg.sender][side];
        if (pos.claimed) revert OspexPositions__AlreadyClaimed();

        uint256 payout = _payout(m.outcome, pos);
        if (pos.risk == 0 || payout == 0) revert OspexPositions__NoPayout();

        pos.risk = 0;
        pos.profit = 0;
        pos.claimed = true;

        i_token.safeTransfer(msg.sender, payout);

        emit PositionClaimed(marketId, msg.sender, side, payout);
        i_ospexCore.emitCoreEvent(EVENT_POSITION_CLAIMED, abi.encode(marketId, msg.sender, side, payout));
    }

    // ──────────────────────────── Reads ───────────────────────────────

    /// @inheritdoc IGrossPositionsReference
    function getPosition(uint256 marketId, address user, Side side)
        external
        view
        override
        returns (Position memory position)
    {
        position = s_positions[marketId][user][side];
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev What a position is paid on an outcome: the risk back on a push or a void; risk and profit to a
    ///      winner, side A on Home or Over and side B on Away or Under; nothing to a loser.
    function _payout(Outcome outcome, Position memory position) internal pure returns (uint256) {
        if (outcome == Outcome.Push || outcome == Outcome.Void) return position.risk;
        bool wins = position.side == Side.A
            ? (outcome == Outcome.Home || outcome == Outcome.Over)
            : (outcome == Outcome.Away || outcome == Outcome.Under);
        return wins ? position.risk + position.profit : 0;
    }

    /// @dev Resolves a module address from the core, reverting if not set. The core writes a type's address
    ///      once, so for a registered type this answers the same address at every call: wired once, then
    ///      locked.
    function _getModule(bytes32 moduleType) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) revert OspexPositions__ModuleNotSet(moduleType);
    }
}
