// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {GameStatus, IOspexGames, ReporterKind} from "../../src/games/IOspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {RefusingCoin} from "../games/CoinFixtures.sol";
import {Deploy, GamesBase, MockReporter, OspexGamesHarness} from "../games/GamesBase.sol";

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

/// @dev A stand-in for a module: it answers the core's four reads as it was told at its deploy, or as it was last
///      told to answer. It is no module of the repository. The core's checks are tested against it one answer at a
///      time; with every answer right it registers, which is the limit of a check that reads answers and not code.
contract StandInModule {
    bytes32 public getModuleType;
    address public i_ospexCore;
    address public i_games;
    address public i_token;

    constructor(bytes32 moduleType, address core, address games, address token) {
        getModuleType = moduleType;
        i_ospexCore = core;
        i_games = games;
        i_token = token;
    }

    /// @dev Changes the three answers, as a contract whose answers are not fixed can at any time.
    function answer(address core, address games, address token) external {
        i_ospexCore = core;
        i_games = games;
        i_token = token;
    }
}

/// @dev A contract that answers a type and none of the three wiring reads: it has no such functions.
contract TypeOnlyModule {
    bytes32 public immutable getModuleType;

    constructor(bytes32 moduleType) {
        getModuleType = moduleType;
    }
}

/// @dev A stand-in whose every answer is right, and which writes to its own storage inside one of them: the
///      read numbered `writesIn`, 0 for the type, 1 for the games set, 2 for the coin, 3 for the core, and 4 for
///      none. None of its four functions is declared a read.
contract WritingModule {
    bytes32 internal immutable i_type;
    address internal immutable i_coreAnswer;
    address internal immutable i_gamesAnswer;
    address internal immutable i_tokenAnswer;
    uint256 internal immutable i_writesIn;
    uint256 public s_writes;

    constructor(bytes32 moduleType, address core, address games, address token, uint256 writesIn) {
        i_type = moduleType;
        i_coreAnswer = core;
        i_gamesAnswer = games;
        i_tokenAnswer = token;
        i_writesIn = writesIn;
    }

    function getModuleType() external returns (bytes32) {
        if (i_writesIn == 0) ++s_writes;
        return i_type;
    }

    function i_games() external returns (address) {
        if (i_writesIn == 1) ++s_writes;
        return i_gamesAnswer;
    }

    function i_token() external returns (address) {
        if (i_writesIn == 2) ++s_writes;
        return i_tokenAnswer;
    }

    function i_ospexCore() external returns (address) {
        if (i_writesIn == 3) ++s_writes;
        return i_coreAnswer;
    }
}

/// @dev A stand-in whose every answer is right but one, which it does not give: the read numbered `silentIn`, 0
///      for the type, 1 for the games set, 2 for the coin, 3 for the core, and 4 for none, reverts with no data,
///      as a call to a function the contract does not have would.
contract SilentModule {
    bytes32 internal immutable i_type;
    address internal immutable i_coreAnswer;
    address internal immutable i_gamesAnswer;
    address internal immutable i_tokenAnswer;
    uint256 internal immutable i_silentIn;

    constructor(bytes32 moduleType, address core, address games, address token, uint256 silentIn) {
        i_type = moduleType;
        i_coreAnswer = core;
        i_gamesAnswer = games;
        i_tokenAnswer = token;
        i_silentIn = silentIn;
    }

    function getModuleType() external view returns (bytes32) {
        if (i_silentIn == 0) revert();
        return i_type;
    }

    function i_games() external view returns (address) {
        if (i_silentIn == 1) revert();
        return i_gamesAnswer;
    }

    function i_token() external view returns (address) {
        if (i_silentIn == 2) revert();
        return i_tokenAnswer;
    }

    function i_ospexCore() external view returns (address) {
        if (i_silentIn == 3) revert();
        return i_coreAnswer;
    }
}

/// @dev A stand-in that answers right only while the core holds nothing of it. Once the core's registry holds an
///      address under its type, or holds its address as a module, each of its three wiring answers is the zero
///      address: a core that wrote an address before it read it would be answered wrong, and would refuse it.
contract ObservingModule {
    bytes32 public immutable getModuleType;
    OspexBetting internal immutable i_core;
    address internal immutable i_gamesAnswer;
    address internal immutable i_tokenAnswer;

    constructor(bytes32 moduleType, OspexBetting core, address games, address token) {
        getModuleType = moduleType;
        i_core = core;
        i_gamesAnswer = games;
        i_tokenAnswer = token;
    }

    /// @dev Whether the core holds nothing of this contract: no address under its type, and not its address.
    function unwritten() public view returns (bool) {
        return i_core.getModule(getModuleType) == address(0) && !i_core.isRegisteredModule(address(this));
    }

    function i_ospexCore() external view returns (address) {
        return unwritten() ? address(i_core) : address(0);
    }

    function i_games() external view returns (address) {
        return unwritten() ? i_gamesAnswer : address(0);
    }

    function i_token() external view returns (address) {
        return unwritten() ? i_tokenAnswer : address(0);
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

    /// @dev A second games set with its own first-n reporter, and a second coin: what a module must not be
    ///      wired to. Deployed by _deployOtherCores, for the tests that need them, and not by setUp.
    OspexGamesHarness internal games2;
    MockReporter internal first2;
    RefusingCoin internal token2;
    /// @dev Three cores that are not `core`. The first names this core's games set and coin, and differs from
    ///      it in its address alone; the second names the second games set; the third the second coin.
    OspexBetting internal coreOfSameValues;
    OspexBetting internal coreOfGames2;
    OspexBetting internal coreOfToken2;

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

    // ──────────────────────────── Other sets ───────────────────────────

    /// @dev Six fresh modules on `c`, built from src/, with their types, in the core's order.
    function _freshSet(OspexBetting c) internal returns (bytes32[] memory types, address[] memory addrs) {
        types = new bytes32[](6);
        addrs = new address[](6);
        types[0] = c.MARKET_MODULE();
        addrs[0] = address(new OspexMarkets(address(c)));
        types[1] = c.POSITION_MODULE();
        addrs[1] = address(new OspexPositions(address(c)));
        types[2] = c.MATCHING_MODULE();
        addrs[2] = address(new OspexMatching(address(c)));
        types[3] = c.MONEYLINE_SCORER_MODULE();
        addrs[3] = address(new OspexMoneylineScorer(address(c)));
        types[4] = c.SPREAD_SCORER_MODULE();
        addrs[4] = address(new OspexSpreadScorer(address(c)));
        types[5] = c.TOTAL_SCORER_MODULE();
        addrs[5] = address(new OspexTotalScorer(address(c)));
    }

    /// @dev The second games set, the second coin and the three other cores. The second games set has the
    ///      first's timelock, fee coin and launch terms and one reporter of its own, and the creator can pay
    ///      its fee.
    function _deployOtherCores() internal {
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        vm.startPrank(deployer, deployer);
        first2 = new MockReporter(IOspexGames(predicted));
        address[] memory reporters = new address[](1);
        reporters[0] = address(first2);
        ReporterKind[] memory kinds = new ReporterKind[](1);
        kinds[0] = ReporterKind.FirstN;
        games2 = new OspexGamesHarness(
            Deploy({
                timelock: address(timelock),
                token: token,
                defaultTerms: _launchTerms(),
                reporters: reporters,
                kinds: kinds,
                codeHashes: _hashes(reporters)
            })
        );
        token2 = new RefusingCoin();
        coreOfSameValues = new OspexBetting(address(games), address(token));
        coreOfGames2 = new OspexBetting(address(games2), address(token));
        coreOfToken2 = new OspexBetting(address(games), address(token2));
        vm.stopPrank();
        assertEq(address(games2), predicted, "the second games set's address as predicted");
        assertTrue(address(games2) != address(games), "the second games set is the first");
        assertTrue(address(token2) != address(token), "the second coin is the first");
        _fund(creator, address(games2));
    }

    /// @dev A game on the second games set with its start written at START by that set's reporter. It takes
    ///      the next number there.
    function _verifiedGameOnGames2() internal returns (uint256 game) {
        uint256 fee = games2.getTerms("nba").fee;
        vm.prank(creator, creator);
        game = games2.createGame("nba", "Denver Nuggets", "Utah Jazz", DATE, _hints(), fee);
        first2.send(_startReport(game, START));
    }

    /// @dev Scores `game` on the second games set `home`-`away`, at the clock as it stands.
    function _scoreOnGames2(uint256 game, uint32 home, uint32 away) internal {
        first2.send(_scoreReport(game, home, away));
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
