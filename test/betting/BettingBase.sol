// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {GameStatus} from "../../src/games/IOspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {GamesBase} from "../games/GamesBase.sol";

/// @dev The positions module with one test-only hook: a fill recorded without the matching module. The set has
///      no fill path until the Cross is built with the courier's check inside it, so the tests put positions
///      into a market through this hook, which calls the production fill from the matching module's gate
///      inward. It overrides nothing, so every other call runs the production code.
contract OspexPositionsHarness is OspexPositions {
    constructor(address core) OspexPositions(core) {}

    function harnessFill(
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        Side makerSide,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) external returns (uint256) {
        return _fill(gameId, scorer, lineTicks, makerSide, maker, makerRisk, taker, takerRisk);
    }
}

/// @dev Shared setup: the games test base, with its games contract, reporters, coin and timelock, and the
///      betting set deployed beside it, bootstrapped and finalized by the deployer; two funded accounts; and
///      helpers that score a game through the production report path and put positions into a market.
abstract contract BettingBase is GamesBase {
    /// @dev A stake in a test that is not about the amount: 10 USDC in six decimals.
    uint256 internal constant STAKE = 10_000_000;

    OspexBetting internal core;
    OspexMarkets internal markets;
    OspexPositionsHarness internal positions;
    OspexMatching internal matching;
    OspexMoneylineScorer internal moneyline;
    OspexSpreadScorer internal spread;
    OspexTotalScorer internal total;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    function setUp() public virtual override {
        super.setUp();
        _deploySet();
        _fund(maker, address(positions));
        _fund(taker, address(positions));
    }

    /// @dev The set as deploy day will make it: the core with the games set and the coin, the six modules on
    ///      the core, bootstrapped under their types, finalized.
    function _deploySet() internal {
        vm.startPrank(deployer, deployer);
        core = new OspexBetting(address(games), address(token));
        markets = new OspexMarkets(address(core));
        positions = new OspexPositionsHarness(address(core));
        matching = new OspexMatching(address(core));
        moneyline = new OspexMoneylineScorer(address(core));
        spread = new OspexSpreadScorer(address(core));
        total = new OspexTotalScorer(address(core));
        core.bootstrapModules(_types(), _modules());
        core.finalize();
        vm.stopPrank();
    }

    /// @dev The six module types, in the order the core's finalize names them.
    function _types() internal view returns (bytes32[] memory t) {
        t = new bytes32[](6);
        t[0] = core.MARKET_MODULE();
        t[1] = core.POSITION_MODULE();
        t[2] = core.MATCHING_MODULE();
        t[3] = core.MONEYLINE_SCORER_MODULE();
        t[4] = core.SPREAD_SCORER_MODULE();
        t[5] = core.TOTAL_SCORER_MODULE();
    }

    /// @dev The six modules, in the same order.
    function _modules() internal view returns (address[] memory a) {
        a = new address[](6);
        a[0] = address(markets);
        a[1] = address(positions);
        a[2] = address(matching);
        a[3] = address(moneyline);
        a[4] = address(spread);
        a[5] = address(total);
    }

    // ──────────────────────────── Games ────────────────────────────────

    /// @dev A game scored `home`-`away` through the production path: created, its start written at START by the
    ///      first-n reporter, and scored one second after the start by the same reporter over three agreeing
    ///      finals. The clock is left at START + 1.
    function _scoredGame(uint32 home, uint32 away) internal returns (uint256 game) {
        game = _create();
        _startBy(first, game, START);
        vm.warp(START + 1);
        _scoreBy(first, game, home, away);
    }

    /// @dev A game with its start written and nothing more: open to positions, not ended.
    function _verifiedGame() internal returns (uint256 game) {
        game = _create();
        _startBy(first, game, START);
    }

    /// @dev Scores `game` `home`-`away` through the production path, one second after START.
    function _score(uint256 game, uint32 home, uint32 away) internal {
        vm.warp(START + 1);
        _scoreBy(first, game, home, away);
    }

    // ──────────────────────────── Fills ────────────────────────────────

    /// @dev A fill through the hook: `maker` on `makerSide` risks `makerRisk`, `taker` on the other side risks
    ///      `takerRisk`. Draws the market at the first fill on its three fields.
    function _fill(uint256 game, address scorer, int32 line, Side makerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (uint256 marketId)
    {
        marketId = positions.harnessFill(game, scorer, line, makerSide, maker, makerRisk, taker, takerRisk);
    }

    /// @dev A market on `game`, `scorer` and `line`, with the maker on side A and the taker on side B, each
    ///      risking STAKE.
    function _market(uint256 game, address scorer, int32 line) internal returns (uint256 marketId) {
        marketId = _fill(game, scorer, line, Side.A, STAKE, STAKE);
    }

    /// @dev The same fill, with its result: for refusals whose name a test checks.
    function _tryFill(uint256 game, address scorer, int32 line, Side makerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (bool ok, bytes memory err)
    {
        (ok, err) = address(positions).call(
            abi.encodeCall(
                OspexPositionsHarness.harnessFill, (game, scorer, line, makerSide, maker, makerRisk, taker, takerRisk)
            )
        );
    }

    // ──────────────────────────── Settlement and claims ────────────────

    /// @dev Settles a market, with the result: for refusals whose name a test checks.
    function _trySettle(uint256 marketId) internal returns (bool ok, bytes memory err) {
        (ok, err) = address(markets).call(abi.encodeCall(OspexMarkets.settleMarket, (marketId)));
    }

    /// @dev Settles a market that must settle.
    function _settle(uint256 marketId) internal {
        (bool ok, bytes memory err) = _trySettle(marketId);
        assertTrue(ok, string.concat("settlement refused: ", vm.toString(err)));
    }

    /// @dev `who` claims its position on `side`, with the result.
    function _tryClaim(address who, uint256 marketId, Side side) internal returns (bool ok, bytes memory err) {
        vm.prank(who, who);
        (ok, err) = address(positions).call(abi.encodeCall(OspexPositions.claimPosition, (marketId, side)));
    }

    /// @dev `who` claims a position that must pay, and the coin it was paid.
    function _claim(address who, uint256 marketId, Side side) internal returns (uint256 paid) {
        uint256 before = token.balanceOf(who);
        (bool ok, bytes memory err) = _tryClaim(who, marketId, side);
        assertTrue(ok, string.concat("claim refused: ", vm.toString(err)));
        paid = token.balanceOf(who) - before;
    }

    /// @dev A market's outcome as its read gives it.
    function _outcome(uint256 marketId) internal view returns (Outcome) {
        return markets.getMarket(marketId).outcome;
    }

    function _position(uint256 marketId, address who, Side side) internal view returns (Position memory) {
        return positions.getPosition(marketId, who, side);
    }

    // ──────────────────────────── The compiled interface ────────────────

    /// @dev The two lists hold the same strings, each once.
    function _assertSameSet(string[] memory got, string[] memory want, string memory what) internal pure {
        assertEq(got.length, want.length, string.concat("the number of ", what, "s moved"));
        for (uint256 i; i < want.length; ++i) {
            uint256 seen;
            for (uint256 j; j < got.length; ++j) {
                if (keccak256(bytes(got[j])) == keccak256(bytes(want[i]))) ++seen;
            }
            assertEq(seen, 1, string.concat("not exactly once: ", want[i]));
        }
    }

    /// @dev Every entry of one ABI type in an artifact, as "Name(type name,type name)"; for an event, each
    ///      indexed parameter is marked "indexed type name".
    function _abiSignatures(string memory json, string memory abiType) internal view returns (string[] memory out) {
        string[] memory found = new string[](128);
        uint256 n;
        for (uint256 i; vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat("$.abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".type")))) != keccak256(bytes(abiType))) {
                continue;
            }
            string memory sig = string.concat(vm.parseJsonString(json, string.concat(entry, ".name")), "(");
            for (uint256 j; vm.keyExistsJson(json, string.concat(entry, ".inputs[", vm.toString(j), "]")); ++j) {
                string memory input = string.concat(entry, ".inputs[", vm.toString(j), "]");
                string memory t = vm.parseJsonString(json, string.concat(input, ".type"));
                if (vm.keyExistsJson(json, string.concat(input, ".indexed")) && vm.parseJsonBool(json, string.concat(input, ".indexed"))) {
                    t = string.concat("indexed ", t);
                }
                t = string.concat(t, " ", vm.parseJsonString(json, string.concat(input, ".name")));
                sig = string.concat(sig, j == 0 ? "" : ",", t);
            }
            found[n++] = string.concat(sig, ")");
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = found[i];
        }
    }
}
