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
 * @notice The positions module of the betting set: it holds every stake between its fill and its claim. A fill,
 *         recorded only by the matching module, draws the market if no fill has yet, writes a position for each
 *         of the two accounts and pulls each account's stake in the set's coin. A claim, once the market is
 *         settled, pays a position out once: risk and profit to a winner, the risk alone on a push or a void,
 *         nothing to a loser.
 *
 *         Both accounts approve this contract for the coin, and nothing else: no fee is taken at a fill, so
 *         there is no second allowance. A maker's profit is the taker's risk and the taker's profit the maker's
 *         risk, so what the contract holds for a market is exactly what its positions can claim.
 *
 *         It has no owner, no setter and no pause, and no way out for the coin but a claim.
 */
contract OspexPositions is IOspexPositions, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant MARKET_MODULE = keccak256("MARKET_MODULE");

    bytes32 public constant EVENT_POSITION_MATCHED_PAIR = keccak256("POSITION_MATCHED_PAIR");
    bytes32 public constant EVENT_POSITION_CLAIMED = keccak256("POSITION_CLAIMED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the core address is zero
    error OspexPositions__InvalidAddress();
    /// @notice Thrown when an address other than the matching module records a fill
    error OspexPositions__NotMatchingModule(address caller);
    /// @notice Thrown when a fill's risk is 0 on either side
    error OspexPositions__InvalidAmount();
    /// @notice Thrown when a fill is recorded into a market that is settled
    error OspexPositions__MarketNotOpen(uint256 marketId);
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
        if (msg.sender != i_ospexCore.getModule(MATCHING_MODULE)) revert OspexPositions__NotMatchingModule(msg.sender);
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

    /// @dev The openness gate and the write. The market read refuses an id that is not a market by name, and a
    ///      settled market is refused here by name; then each account's position grows by its risk and the
    ///      other's, and each stake is pulled.
    function _record(
        IOspexMarkets markets,
        uint256 marketId,
        Side makerSide,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) private {
        Market memory m = markets.getMarket(marketId);
        if (m.status != MarketStatus.Open) revert OspexPositions__MarketNotOpen(marketId);

        Side takerSide = makerSide == Side.A ? Side.B : Side.A;

        Position storage makerPos = s_positions[marketId][maker][makerSide];
        makerPos.side = makerSide;
        makerPos.risk += makerRisk;
        makerPos.profit += takerRisk;

        Position storage takerPos = s_positions[marketId][taker][takerSide];
        takerPos.side = takerSide;
        takerPos.risk += takerRisk;
        takerPos.profit += makerRisk;

        i_token.safeTransferFrom(maker, address(this), makerRisk);
        i_token.safeTransferFrom(taker, address(this), takerRisk);

        emit PositionFilled(marketId, maker, taker, makerSide, takerSide, makerRisk, takerRisk);
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_MATCHED_PAIR, abi.encode(marketId, maker, taker, makerSide, takerSide, makerRisk, takerRisk)
        );
    }

    // ──────────────────────────── Claims ───────────────────────────────

    /// @inheritdoc IOspexPositions
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

    /// @inheritdoc IOspexPositions
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

    /// @dev Resolves a module address from the core, reverting if not set
    function _getModule(bytes32 moduleType) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) revert OspexPositions__ModuleNotSet(moduleType);
    }
}
