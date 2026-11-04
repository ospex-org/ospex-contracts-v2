// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexModule} from "./IOspexModule.sol";
import {IOspexGames, GameStatus} from "../games/IOspexGames.sol";
import {IOspexMarkets} from "./IOspexMarkets.sol";
import {IOspexScorer} from "./IOspexScorer.sol";
import {OspexBetting} from "./OspexBetting.sol";
import {Market, MarketStatus, Outcome} from "./OspexBettingTypes.sol";

/**
 * @title OspexMarkets
 * @author ospex.org
 * @notice The markets module of the betting set. A market is what positions are taken on, named by its game, its
 *         market contract and its line; its id is drawn at its first fill, by the positions module, and it is
 *         settled by anyone once its game has ended.
 *
 *         A market settles only on its game's own status, read from the games set the core names. A scored game
 *         settles the market through its market contract, which reads the two scores, the home team's then the
 *         away team's, from the games set; a voided game voids the market, and so does a released game, which
 *         the betting set reads as a void. A game that has not ended, a dispute record included, settles
 *         nothing: the dispute record is a record, not an end. Nothing here reads a start, waits a cooldown or
 *         voids a game: the games set's clocks end every game, and this contract follows. Spec: "Two pieces",
 *         "How a game ends", "Must never happen" (a market settles on anything but its game's own status).
 *
 *         A market is drawn on a game that exists in the games set and has not ended, with one of the three
 *         market contracts and a line the contract takes: 0 for a moneyline, at least 0 for a total, any line
 *         inside MAX_LINE_TICKS for a spread, where the line is the home team's handicap. No fee is taken to
 *         draw one. A read of an id that is not a market is refused by name, and so is a fill into one.
 *
 *         It has no owner, no setter and no pause, and holds no coin.
 */
contract OspexMarkets is IOspexMarkets {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant MARKET_MODULE = keccak256("MARKET_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant MONEYLINE_SCORER_MODULE = keccak256("MONEYLINE_SCORER_MODULE");
    bytes32 public constant TOTAL_SCORER_MODULE = keccak256("TOTAL_SCORER_MODULE");

    bytes32 public constant EVENT_MARKET_CREATED = keccak256("MARKET_CREATED");
    bytes32 public constant EVENT_MARKET_SETTLED = keccak256("MARKET_SETTLED");

    /// @notice The bound on a line's magnitude, scaled by 10, for every market contract: 100,000.0 points. With
    ///         the games set's MAX_SCORE the line arithmetic fits a signed 32-bit integer.
    int32 public constant MAX_LINE_TICKS = 1_000_000;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when an address other than the positions module draws a market
    error OspexMarkets__NotAuthorized(address caller);
    /// @notice Thrown when a market that is already settled is settled again
    error OspexMarkets__AlreadySettled(uint256 marketId);
    /// @notice Thrown when an id that is not a market is read, settled or filled into
    error OspexMarkets__UnknownMarket(uint256 marketId);
    /// @notice Thrown when a market is drawn on a game, market contract and line that already have one
    error OspexMarkets__MarketExists(uint256 marketId);
    /// @notice Thrown when a market is drawn on a game that has ended: scored, voided or released
    error OspexMarkets__GameEnded(uint256 gameId, GameStatus status);
    /// @notice Thrown when a market is settled while its game has not ended, a dispute record or not
    error OspexMarkets__GameNotEnded(uint256 gameId, GameStatus status);
    /// @notice Thrown when the core address is zero
    error OspexMarkets__InvalidAddress();
    /// @notice Thrown when a required module is not registered in the core
    error OspexMarkets__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the market contract named is not one of the three
    error OspexMarkets__ScorerNotApproved(address scorer);
    /// @notice Thrown when the line is one the market contract does not take: other than 0 for a moneyline, or
    ///         below 0 for a total
    error OspexMarkets__InvalidLineTicks(address scorer, int32 lineTicks);
    /// @notice Thrown when a line's magnitude is above MAX_LINE_TICKS
    error OspexMarkets__LineTicksOutOfRange(int32 lineTicks);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The core
    OspexBetting public immutable i_ospexCore;
    /// @notice The games set, as the core holds it. Fixed at deploy.
    IOspexGames public immutable i_games;

    /// @notice How many markets have been drawn
    uint256 public s_marketCount;
    /// @notice Market id → market
    mapping(uint256 => Market) public s_markets;
    /// @notice Reverse lookup: game id → market contract → line → market id
    mapping(uint256 => mapping(address => mapping(int32 => uint256))) public s_marketLookup;

    /// @notice Deploys the markets module
    /// @param core The betting set's core, which holds the games set's address
    constructor(address core) {
        if (core == address(0)) revert OspexMarkets__InvalidAddress();
        i_ospexCore = OspexBetting(core);
        i_games = OspexBetting(core).i_games();
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return MARKET_MODULE;
    }

    // ──────────────────────────── Drawing a market ─────────────────────

    /// @inheritdoc IOspexMarkets
    function createMarket(uint256 gameId, address scorer, int32 lineTicks, address maker, address taker)
        external
        override
        returns (uint256)
    {
        if (msg.sender != _getModule(POSITION_MODULE)) revert OspexMarkets__NotAuthorized(msg.sender);
        return _create(gameId, scorer, lineTicks, maker, taker);
    }

    /// @dev Checks the line's magnitude, that no market exists on the three fields, that the game is a game of
    ///      the games set (its status read refuses an id that is not) and has not ended, that the market contract
    ///      is one of the three, and that it takes the line; then draws the market and emits it.
    function _create(uint256 gameId, address scorer, int32 lineTicks, address maker, address taker)
        internal
        returns (uint256)
    {
        if (lineTicks > MAX_LINE_TICKS || lineTicks < -MAX_LINE_TICKS) {
            revert OspexMarkets__LineTicksOutOfRange(lineTicks);
        }
        uint256 existing = s_marketLookup[gameId][scorer][lineTicks];
        if (existing != 0) revert OspexMarkets__MarketExists(existing);

        GameStatus status = i_games.getGameStatus(gameId);
        if (status >= GameStatus.Scored) revert OspexMarkets__GameEnded(gameId, status);

        if (!i_ospexCore.isApprovedScorer(scorer)) revert OspexMarkets__ScorerNotApproved(scorer);
        if (
            (scorer == _getModule(MONEYLINE_SCORER_MODULE) && lineTicks != 0)
                || (scorer == _getModule(TOTAL_SCORER_MODULE) && lineTicks < 0)
        ) {
            revert OspexMarkets__InvalidLineTicks(scorer, lineTicks);
        }

        uint256 marketId = ++s_marketCount;
        s_markets[marketId] = Market({
            gameId: gameId,
            scorer: scorer,
            lineTicks: lineTicks,
            status: MarketStatus.Open,
            outcome: Outcome.None
        });
        s_marketLookup[gameId][scorer][lineTicks] = marketId;

        emit MarketCreated(marketId, gameId, scorer, lineTicks, maker, taker);
        i_ospexCore.emitCoreEvent(EVENT_MARKET_CREATED, abi.encode(marketId, gameId, scorer, lineTicks, maker, taker));
        return marketId;
    }

    // ──────────────────────────── Settlement ──────────────────────────

    /// @inheritdoc IOspexMarkets
    /// @dev The status is read first: the scores read refuses a game that is not scored, so it is made only on
    ///      a scored game, through the market contract.
    function settleMarket(uint256 marketId) external override {
        Market storage m = _market(marketId);
        if (m.status == MarketStatus.Closed) revert OspexMarkets__AlreadySettled(marketId);

        GameStatus status = i_games.getGameStatus(m.gameId);
        Outcome outcome = Outcome.None;
        if (status == GameStatus.Scored) {
            outcome = IOspexScorer(m.scorer).outcomeOf(m.gameId, m.lineTicks);
        } else if (status == GameStatus.Voided || status == GameStatus.Released) {
            outcome = Outcome.Void;
        } else {
            revert OspexMarkets__GameNotEnded(m.gameId, status);
        }

        m.status = MarketStatus.Closed;
        m.outcome = outcome;

        emit MarketSettled(marketId, outcome, m.scorer);
        i_ospexCore.emitCoreEvent(EVENT_MARKET_SETTLED, abi.encode(marketId, outcome, m.scorer));
    }

    // ──────────────────────────── Reads ───────────────────────────────

    /// @inheritdoc IOspexMarkets
    function getMarket(uint256 marketId) external view override returns (Market memory) {
        return _market(marketId);
    }

    /// @inheritdoc IOspexMarkets
    function getMarketId(uint256 gameId, address scorer, int32 lineTicks) external view override returns (uint256) {
        return s_marketLookup[gameId][scorer][lineTicks];
    }

    /// @inheritdoc IOspexMarkets
    function marketCount() external view override returns (uint256) {
        return s_marketCount;
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev A market by id, refused by name for an id that is not one: ids run from 1 to the count.
    function _market(uint256 marketId) private view returns (Market storage m) {
        if (marketId == 0 || marketId > s_marketCount) revert OspexMarkets__UnknownMarket(marketId);
        m = s_markets[marketId];
    }

    /// @dev Resolves a module address from the core, reverting if not set
    function _getModule(bytes32 moduleType) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) revert OspexMarkets__ModuleNotSet(moduleType);
    }
}
