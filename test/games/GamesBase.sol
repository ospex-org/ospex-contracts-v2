// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    ReadingKind,
    Reading,
    Report,
    Hint,
    Terms
} from "../../src/games/IOspexGames.sol";
import {IOspexReporter} from "../../src/games/IOspexReporter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RefusingCoin} from "./CoinFixtures.sol";

/// @dev A reporter as the games set sees one: a contract that sends reports, with the fixed-values read every
///      reporter has. It relays what it is given, from anyone: an unauthenticated test double, not a model for
///      a reporter. Its fixed values are its games address and a tag.
contract MockReporter is IOspexReporter {
    IOspexGames public immutable i_games;

    constructor(IOspexGames games) {
        i_games = games;
    }

    function send(Report calldata r) external {
        i_games.report(r);
    }

    function fixedValues() external view returns (bytes memory) {
        return abi.encode(address(i_games), bytes32("mock reporter"));
    }
}

/// @dev The six arguments of the games contract's constructor as one value. The harness's constructor takes them
///      this way so that it holds one word for them where the contract's own holds six: compiled through the IR
///      pipeline, the harness's creation code, the base constructor's loop inlined into it, sat one stack slot
///      from the limit, and a one-line change anywhere in the contract could fail the harness's build while the
///      contract itself built. The contract's constructor is unchanged.
struct Deploy {
    address timelock;
    IERC20 token;
    Terms defaultTerms;
    address[] reporters;
    ReporterKind[] kinds;
    bytes32[] codeHashes;
}

/// @dev The games contract with test-only hooks. It overrides nothing, so every inherited call runs the
///      production code. No hook writes a status: every status a test needs is reached through the production
///      paths (a start, a score, a void, a dispute record, a release).
contract OspexGamesHarness is OspexGames {
    constructor(Deploy memory d)
        OspexGames(d.timelock, d.token, d.defaultTerms, d.reporters, d.kinds, d.codeHashes)
    {}

    /// @dev Reaches `_end`, the one place an end is written and the fee credited, with whatever status and
    ///      account a test names, and none of the checks its production callers make first: the gate under test
    ///      is `_end`'s own (not a game, already ended, not an end).
    function harnessEnd(uint256 gameId, GameStatus end, address account) external {
        _end(s_games[gameId], gameId, end, account);
    }

    /// @dev Plants score fields without the status, to show the read does not trust them.
    function harnessSetScoreFields(uint256 gameId, uint32 homeScore, uint32 awayScore) external {
        s_games[gameId].homeScore = homeScore;
        s_games[gameId].awayScore = awayScore;
    }
}

/// @dev A game's storage, word for word, as any test or handler reads it. Where OspexGames keeps its games and
///      their reporter copies, from `forge inspect OspexGames storageLayout`;
///      test_storage_aGameLiesWhereTheSnapshotsReadIt pins it, so a layout change turns that test red instead
///      of leaving these reads looking at empty slots.
library GameWords {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant GAMES_SLOT = 6;
    uint256 internal constant GAME_REPORTERS_SLOT = 7;

    /// @dev One game's storage: its four words (status, date, start and scores; then its terms, two words;
    ///      then its creator and the time of its dispute record) and its reporters' copy. The reads show what a
    ///      game says; this shows every field a write could touch, the date included, which no read returns.
    function raw(address games, uint256 gameId) internal view returns (bytes memory out) {
        uint256 base = uint256(keccak256(abi.encode(gameId, GAMES_SLOT)));
        for (uint256 i; i < 4; ++i) {
            out = abi.encodePacked(out, vm.load(games, bytes32(base + i)));
        }
        bytes32 lengthSlot = keccak256(abi.encode(gameId, GAME_REPORTERS_SLOT));
        uint256 length = uint256(vm.load(games, lengthSlot));
        out = abi.encodePacked(out, length);
        uint256 firstEntry = uint256(keccak256(abi.encode(lengthSlot)));
        for (uint256 i; i < length; ++i) {
            out = abi.encodePacked(out, vm.load(games, bytes32(firstEntry + i)));
        }
    }

    /// @dev A game's date as stored: the eight bytes after the status byte in its first word.
    function date(address games, uint256 gameId) internal view returns (uint64) {
        bytes32 word = vm.load(games, keccak256(abi.encode(gameId, GAMES_SLOT)));
        return uint64(uint256(word) >> 8);
    }
}

/// @dev Shared setup: a stock timelock, three reporters of mixed kinds, a date, the launch terms, and helpers.
abstract contract GamesBase is Test {
    /// @dev The day-0 delay of the Polygon timelock.
    uint256 internal constant DELAY = 60;
    uint64 internal constant WINDOW = 1 days;
    /// @dev The launch day-7 and day-30 clocks, written out rather than read from the contract.
    uint64 internal constant DAY7 = 7 days;
    uint64 internal constant DAY30 = 30 days;
    /// @dev A scheduled start that is not round, so a start equal to it cannot pass for a start written as given.
    uint64 internal constant DATE = 1_800_000_037;
    /// @dev The start written in most tests: inside the window of DATE, and not equal to it.
    uint64 internal constant START = DATE + 613;
    uint32 internal constant HOME = 104;
    uint32 internal constant AWAY = 97;
    /// @dev The start bound, written out rather than read from the contract, so a change to it is seen.
    uint64 internal constant DAY = 86_400;
    /// @dev The launch creation fee: 1 USDC, in six decimals.
    uint96 internal constant FEE = 1_000_000;
    /// @dev What each funded creator starts with.
    uint256 internal constant PURSE = 1_000_000_000_000;
    /// @dev A creation's maxFee in a test that is not about it: any fee. The helpers below name the fee they
    ///      read instead, as a careful caller does.
    uint256 internal constant ANY_FEE = type(uint256).max;

    TimelockController internal timelock;
    /// @dev The coin the creation fee is paid in. It takes transfers until a test pauses it or blocks an address.
    RefusingCoin internal token;
    OspexGamesHarness internal games;
    /// @dev First-n reporter, first on the list.
    MockReporter internal first;
    /// @dev After-n reporter, second on the list.
    MockReporter internal later;
    /// @dev A second first-n reporter, third on the list.
    MockReporter internal second;

    address internal deployer = makeAddr("deployer");
    address internal creator = makeAddr("creator");
    /// @dev K: the one key that holds the timelock. It schedules and cancels; anyone runs a call once ready.
    address internal timelockKey = makeAddr("K");
    address internal stranger = makeAddr("stranger");
    address internal payout = makeAddr("payout");
    uint256 internal salt;

    function setUp() public virtual {
        vm.warp(DATE - 3 days);
        timelock = new TimelockController(DELAY, _one(timelockKey), _one(address(0)), address(0));
        token = new RefusingCoin();
        // The reporters need the games address at their own deploy, and the games contract needs theirs:
        // predict the games address from the deployer's nonce, as the deploy script will.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        vm.startPrank(deployer, deployer);
        first = new MockReporter(IOspexGames(predicted));
        later = new MockReporter(IOspexGames(predicted));
        second = new MockReporter(IOspexGames(predicted));
        address[] memory reporters = new address[](3);
        reporters[0] = address(first);
        reporters[1] = address(later);
        reporters[2] = address(second);
        ReporterKind[] memory kinds = new ReporterKind[](3);
        kinds[0] = ReporterKind.FirstN;
        kinds[1] = ReporterKind.AfterN;
        kinds[2] = ReporterKind.FirstN;
        games = new OspexGamesHarness(
            Deploy({
                timelock: address(timelock),
                token: token,
                defaultTerms: _launchTerms(),
                reporters: reporters,
                kinds: kinds,
                codeHashes: _hashes(reporters)
            })
        );
        vm.stopPrank();
        assertEq(address(games), predicted, "games address as predicted");
        // The two addresses most tests create from can pay the fee.
        _fund(creator, address(games));
        _fund(address(this), address(games));
    }

    /// @dev Gives `who` a purse of the coin and lets `spender` take from it.
    function _fund(address who, address spender) internal {
        token.mint(who, PURSE);
        vm.prank(who);
        token.approve(spender, type(uint256).max);
    }

    // ──────────────────────────── Terms ────────────────────────────────

    /// @dev The launch terms, written out: n 24 hours, the day-7 clock 7 days, the day-30 clock 30 days, 1 USDC.
    function _launchTerms() internal pure returns (Terms memory) {
        return Terms({window: WINDOW, day7Clock: 604_800, day30Clock: 2_592_000, fee: 1_000_000});
    }

    /// @dev The launch terms with another day-7 clock and day-30 clock.
    function _clockTerms(uint64 day7Clock, uint64 day30Clock) internal pure returns (Terms memory t) {
        t = _launchTerms();
        t.day7Clock = day7Clock;
        t.day30Clock = day30Clock;
    }

    function _terms(uint64 window) internal pure returns (Terms memory t) {
        t = _launchTerms();
        t.window = window;
    }

    function _assertTerms(Terms memory got, Terms memory want, string memory what) internal pure {
        assertEq(got.window, want.window, string.concat(what, ": n"));
        assertEq(got.day7Clock, want.day7Clock, string.concat(what, ": day-7 clock"));
        assertEq(got.day30Clock, want.day30Clock, string.concat(what, ": day-30 clock"));
        assertEq(got.fee, want.fee, string.concat(what, ": fee"));
    }

    // ──────────────────────────── The timelock's calls ─────────────────

    /// @dev Runs `call` on the games contract the way it runs live: K schedules it through the timelock, the
    ///      delay passes, and a stranger runs it. Reverts with the call's own refusal if it is refused.
    function _throughTimelock(bytes memory call) internal {
        bytes32 s = bytes32(++salt);
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        timelock.execute(address(games), 0, call, bytes32(0), s);
    }

    /// @dev The same call, made by the timelock's address at once, with its result: for refusals whose name a
    ///      test checks, and for tests where the delay is not the subject.
    function _asTimelock(bytes memory call) internal returns (bool ok, bytes memory err) {
        vm.prank(address(timelock));
        (ok, err) = address(games).call(call);
    }

    function _approve(address reporter, ReporterKind kind) internal {
        _throughTimelock(abi.encodeCall(IOspexGames.approveReporter, (reporter, kind, reporter.codehash)));
    }

    function _retire(address reporter) internal {
        _throughTimelock(abi.encodeCall(IOspexGames.retireReporter, (reporter)));
    }

    function _setTerms(string memory league, Terms memory terms) internal {
        _throughTimelock(abi.encodeCall(IOspexGames.setTerms, (league, terms)));
    }

    function _hashes(address[] memory reporters) internal view returns (bytes32[] memory h) {
        h = new bytes32[](reporters.length);
        for (uint256 i; i < reporters.length; ++i) {
            h[i] = reporters[i].codehash;
        }
    }

    // ──────────────────────────── Creation ─────────────────────────────

    function _hints() internal pure returns (Hint[] memory hints) {
        hints = new Hint[](2);
        hints[0] = Hint({seat: 3, id: "g-77120"});
        hints[1] = Hint({seat: 1, id: "18432"});
    }

    function _create() internal returns (uint256) {
        return _createAt(DATE);
    }

    /// @dev Reads the league's fee and names exactly that as the most the creator pays, as a careful caller does.
    function _createAt(uint64 date) internal returns (uint256 gameId) {
        uint256 fee = games.getTerms("nba").fee;
        vm.prank(creator, creator);
        gameId = games.createGame("nba", "Denver Nuggets", "Utah Jazz", date, _hints(), fee);
    }

    // ──────────────────────────── Reports ──────────────────────────────

    /// @dev Readings a start rides on, and the shape of a game still in play after n: two feeds show the same
    ///      final, one answered without a final, one is silent.
    function _readings() internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 88, awayScore: 90});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
    }

    /// @dev Readings as a score rests on them: the three counting seats show the same final, the spare is
    ///      silent. Three agreeing finals settle a game at any status and any hour the reporter may write.
    function _scoreReadings(uint32 home, uint32 away) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
    }

    /// @dev `count` finals reading HOME-AWAY on the first seats and the rest of four silent: the shapes the
    ///      readings checks count. Three is the program's agreement inside n and on a disputed game, two its
    ///      agreement from start + n on a game with no record; one is agreement in no count.
    function _finals(uint256 count) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        for (uint256 i; i < 4; ++i) {
            readings[i] = i < count
                ? Reading({seat: uint8(i + 1), kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY})
                : Reading({seat: uint8(i + 1), kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        }
    }

    /// @dev A start pays nothing, so its payout is empty.
    function _startReport(uint256 gameId, uint64 start) internal pure returns (Report memory r) {
        r.gameId = gameId;
        r.kind = ReportKind.Start;
        r.start = start;
        r.readings = _readings();
    }

    function _scoreReport(uint256 gameId, uint32 home, uint32 away) internal view returns (Report memory r) {
        r.gameId = gameId;
        r.kind = ReportKind.Score;
        r.homeScore = home;
        r.awayScore = away;
        r.readings = _scoreReadings(home, away);
        r.payout = payout;
    }

    /// @dev Readings as the hour-24 void rests on them: the feeds that answer all show no final, and one is
    ///      silent. The games set reads a void's readings only for finals that agree in the program's count at the
    ///      clock, two at hour 24 and three at day 7 on a disputed game; the shape is what the program would send.
    function _voidReadings() internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredNoFinal, homeScore: 51, awayScore: 49});
        readings[2] = Reading({seat: 3, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
    }

    /// @dev Readings as a dispute record rests on them: two feeds show finals that disagree, one shows no final
    ///      and one is silent.
    function _disputeReadings() internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME + 3, awayScore: AWAY});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 88, awayScore: 90});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
    }

    /// @dev A void: no start, no scores, the void's readings, and the payout address the end credits.
    function _voidReport(uint256 gameId) internal view returns (Report memory r) {
        r.gameId = gameId;
        r.kind = ReportKind.Void;
        r.readings = _voidReadings();
        r.payout = payout;
    }

    /// @dev A void whose payout address is `to`.
    function _voidReportTo(uint256 gameId, address to) internal view returns (Report memory r) {
        r = _voidReport(gameId);
        r.payout = to;
    }

    /// @dev A dispute record, or an update to one: no start, no scores, the readings that disagree, and no
    ///      payout, since it credits nothing.
    function _disputeReport(uint256 gameId) internal pure returns (Report memory r) {
        r.gameId = gameId;
        r.kind = ReportKind.Dispute;
        r.readings = _disputeReadings();
    }

    /// @dev Sends a report from `who` and returns whether it was taken and the revert data. A MockReporter
    ///      relays it; any other address sends it directly, as both sender and origin.
    function _send(address who, Report memory r) internal returns (bool ok, bytes memory err) {
        if (_isMock(who)) {
            (ok, err) = who.call(abi.encodeCall(MockReporter.send, (r)));
        } else {
            vm.prank(who, who);
            (ok, err) = address(games).call(abi.encodeCall(IOspexGames.report, (r)));
        }
    }

    function _isMock(address who) internal view returns (bool) {
        if (who.code.length == 0) return false;
        (bool ok, bytes memory answer) = who.staticcall(abi.encodeWithSignature("i_games()"));
        return ok && answer.length == 32 && abi.decode(answer, (address)) == address(games);
    }

    /// @dev Sends a report that must be taken.
    function _take(address who, Report memory r) internal {
        (bool ok, bytes memory err) = _send(who, r);
        assertTrue(ok, string.concat("report refused: ", vm.toString(err)));
    }

    function _startBy(MockReporter who, uint256 gameId, uint64 start) internal {
        _take(address(who), _startReport(gameId, start));
    }

    function _scoreBy(MockReporter who, uint256 gameId, uint32 home, uint32 away) internal {
        _take(address(who), _scoreReport(gameId, home, away));
    }

    function _voidBy(MockReporter who, uint256 gameId) internal {
        _take(address(who), _voidReport(gameId));
    }

    function _disputeBy(MockReporter who, uint256 gameId) internal {
        _take(address(who), _disputeReport(gameId));
    }

    /// @dev `who` releases the game, as sender and origin. Reverts with the release's own refusal if refused.
    function _releaseBy(address who, uint256 gameId) internal {
        vm.prank(who, who);
        games.release(gameId);
    }

    /// @dev The same, with its result: for refusals whose name a test checks.
    function _tryRelease(address who, uint256 gameId) internal returns (bool ok, bytes memory err) {
        vm.prank(who, who);
        (ok, err) = address(games).call(abi.encodeCall(IOspexGames.release, (gameId)));
    }

    /// @dev A game in a status, reached through the production paths: a fresh game for Unverified; otherwise a
    ///      game whose start is written at START by `first`, then disputed or scored at START + 1, voided at
    ///      start + n, or released by a stranger once its day-30 clock has run from its date. The clock is left
    ///      where the path needed it; a caller that cares sets it after.
    function _inStatus(GameStatus s) internal returns (uint256 game) {
        game = _create();
        if (s == GameStatus.Unverified) return game;
        _startBy(first, game, START);
        if (s == GameStatus.Verified) return game;
        if (s == GameStatus.Disputed) {
            vm.warp(START + 1);
            _disputeBy(first, game);
        } else if (s == GameStatus.Scored) {
            vm.warp(START + 1);
            _scoreBy(first, game, HOME, AWAY);
        } else if (s == GameStatus.Voided) {
            vm.warp(START + WINDOW);
            _voidBy(first, game);
        } else {
            vm.warp(_day30(game));
            _releaseBy(stranger, game);
        }
    }

    /// @dev The second a game's day-30 clock runs: its date as stored plus its own copied clock. From it the
    ///      release is open and every report is refused.
    function _day30(uint256 gameId) internal view returns (uint256) {
        return uint256(_rawDate(gameId)) + games.getGameTerms(gameId).day30Clock;
    }

    /// @dev The refusal of any report to `gameId` at or after its day-30 clock.
    function _pastDay30(uint256 gameId) internal view returns (bytes memory) {
        return abi.encodeWithSelector(OspexGames.OspexGames__PastDay30Clock.selector, gameId, _day30(gameId));
    }

    // ──────────────────────────── The creation fee ─────────────────────

    /// @dev A score whose payout address is `to`.
    function _scoreReportTo(uint256 gameId, address to) internal view returns (Report memory r) {
        r = _scoreReport(gameId, HOME, AWAY);
        r.payout = to;
    }

    /// @dev The launch terms with another fee.
    function _feeTerms(uint96 fee) internal pure returns (Terms memory t) {
        t = _launchTerms();
        t.fee = fee;
    }

    /// @dev The amount the games set holds for a game, as its read says.
    function _held(uint256 gameId) internal view returns (uint96 held) {
        (held,) = games.getGameFee(gameId);
    }

    /// @dev A courier sends a report through a reporter: the courier is the transaction's sender and origin, the
    ///      reporter is what calls the games set.
    function _sendAs(address courier, MockReporter through, Report memory r) internal returns (bool ok, bytes memory err) {
        vm.prank(courier, courier);
        (ok, err) = address(through).call(abi.encodeCall(MockReporter.send, (r)));
    }

    /// @dev Everything about the money a reader can see: the coin the games set holds, each account's credit
    ///      and coin, and each game's held amount.
    function _money(address[] memory accounts) internal view returns (bytes32) {
        bytes memory out = abi.encode(token.balanceOf(address(games)));
        for (uint256 i; i < accounts.length; ++i) {
            out = abi.encodePacked(out, games.getCredit(accounts[i]), token.balanceOf(accounts[i]));
        }
        uint256 count = games.gameCount();
        for (uint256 id = 1; id <= count; ++id) {
            out = abi.encodePacked(out, _held(id));
        }
        return keccak256(out);
    }

    // ──────────────────────────── What any reader sees ─────────────────

    /// @dev Every read of one game, each as (taken, answer or refusal): what any contract or agent can see.
    function _view(uint256 gameId) internal view returns (bytes memory) {
        bytes memory out;
        bytes[9] memory calls = [
            abi.encodeCall(IOspexGames.getGameStatus, (gameId)),
            abi.encodeCall(IOspexGames.getGameStart, (gameId)),
            abi.encodeCall(games.getGameReporters, (gameId)),
            abi.encodeCall(IOspexGames.getGameScores, (gameId)),
            abi.encodeCall(IOspexGames.getGameWindow, (gameId)),
            abi.encodeCall(IOspexGames.getGameTerms, (gameId)),
            abi.encodeCall(IOspexGames.isEveryReporterRetired, (gameId)),
            abi.encodeCall(IOspexGames.getGameFee, (gameId)),
            abi.encodeCall(IOspexGames.getGameDisputedAt, (gameId))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory answer) = address(games).staticcall(calls[i]);
            out = abi.encodePacked(out, ok, keccak256(answer));
        }
        return out;
    }

    /// @dev Every read of every game, ids 0 to count + 1, and the count: the whole readable state of the games.
    function _viewAll() internal view returns (bytes32) {
        uint256 count = games.gameCount();
        bytes memory out = abi.encode(count);
        for (uint256 id; id <= count + 1; ++id) {
            out = abi.encodePacked(out, _view(id));
        }
        return keccak256(out);
    }

    // ──────────────────────────── What lies in storage ──────────────────

    /// @dev One game's storage, word for word, and its reporters' copy: see GameWords.
    function _rawGame(uint256 gameId) internal view returns (bytes memory) {
        return GameWords.raw(address(games), gameId);
    }

    /// @dev A game's date as stored, which no read returns.
    function _rawDate(uint256 gameId) internal view returns (uint64) {
        return GameWords.date(address(games), gameId);
    }

    /// @dev The approved list and the default terms as they read now.
    function _viewList() internal view returns (bytes32) {
        (address[] memory r, uint8[] memory k) = games.getApprovedReporters();
        return keccak256(abi.encode(r, k, games.getTerms("")));
    }

    function _status(uint256 gameId) internal view returns (GameStatus) {
        return games.getGameStatus(gameId);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _kinds1(ReporterKind k) internal pure returns (ReporterKind[] memory list) {
        list = new ReporterKind[](1);
        list[0] = k;
    }

    // ──────────────────────────── The compiled interface ────────────────

    /// @dev A contract's build artifact, as forge wrote it for this run.
    function _artifact(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/out/", name, ".sol/", name, ".json"));
    }

    /// @dev Asserts the ABI parameter list at `path` holds exactly these names and types, in this order, and
    ///      nothing after them. `names` and `types` are ";"-separated.
    function _assertParams(string memory json, string memory path, string memory names, string memory types)
        internal
        view
    {
        string[] memory n = vm.split(names, ";");
        string[] memory t = vm.split(types, ";");
        assertEq(n.length, t.length, "the expected lists differ in length");
        for (uint256 i; i < n.length; ++i) {
            string memory at = string.concat(path, "[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(at, ".name")), n[i], string.concat(at, " name"));
            assertEq(vm.parseJsonString(json, string.concat(at, ".type")), t[i], string.concat(at, " type"));
        }
        assertFalse(
            vm.keyExistsJson(json, string.concat(path, "[", vm.toString(n.length), "]")),
            string.concat(path, " has a parameter past the last")
        );
    }

    function _selector(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(err, 0x20))
        }
    }
}
