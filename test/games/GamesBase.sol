// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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

/// @dev A reporter as the games set sees one: a contract that sends reports, with the fixed-values read every
///      reporter has. It relays what it is given. Its fixed values are its games address and a tag.
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

/// @dev The games contract with test-only hooks. It overrides nothing, so every inherited call runs the
///      production code. The hooks stand in for what later work adds: the ends that write the statuses this
///      contract cannot write yet.
contract OspexGamesHarness is OspexGames {
    constructor(
        address timelock,
        Terms memory defaultTerms,
        address[] memory reporters,
        ReporterKind[] memory kinds,
        bytes32[] memory codeHashes
    ) OspexGames(timelock, defaultTerms, reporters, kinds, codeHashes) {}

    /// @dev Puts a game in a status, as the ends will.
    function harnessSetStatus(uint256 gameId, GameStatus status) external {
        s_games[gameId].status = status;
    }

    /// @dev Plants score fields without the status, to show the read does not trust them.
    function harnessSetScoreFields(uint256 gameId, uint32 homeScore, uint32 awayScore) external {
        s_games[gameId].homeScore = homeScore;
        s_games[gameId].awayScore = awayScore;
    }
}

/// @dev Shared setup: a stock timelock, three reporters of mixed kinds, a date, the launch terms, and helpers.
abstract contract GamesBase is Test {
    /// @dev The day-0 delay of the Polygon timelock.
    uint256 internal constant DELAY = 60;
    uint64 internal constant WINDOW = 1 days;
    /// @dev A scheduled start that is not round, so a start equal to it cannot pass for a start written as given.
    uint64 internal constant DATE = 1_800_000_037;
    /// @dev The start written in most tests: inside the window of DATE, and not equal to it.
    uint64 internal constant START = DATE + 613;
    uint32 internal constant HOME = 104;
    uint32 internal constant AWAY = 97;
    /// @dev The start bound, written out rather than read from the contract, so a change to it is seen.
    uint64 internal constant DAY = 86_400;

    TimelockController internal timelock;
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
        games = new OspexGamesHarness(address(timelock), _launchTerms(), reporters, kinds, _hashes(reporters));
        vm.stopPrank();
        assertEq(address(games), predicted, "games address as predicted");
    }

    // ──────────────────────────── Terms ────────────────────────────────

    /// @dev The launch terms, written out: n 24 hours, the day-7 clock 7 days, the day-30 clock 30 days, 1 USDC.
    function _launchTerms() internal pure returns (Terms memory) {
        return Terms({window: WINDOW, day7Clock: 604_800, day30Clock: 2_592_000, fee: 1_000_000});
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

    function _createAt(uint64 date) internal returns (uint256 gameId) {
        vm.prank(creator, creator);
        gameId = games.createGame("nba", "Denver Nuggets", "Utah Jazz", date, _hints());
    }

    // ──────────────────────────── Reports ──────────────────────────────

    function _readings() internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 88, awayScore: 90});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
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
        r.readings = _readings();
        r.payout = payout;
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

    // ──────────────────────────── What any reader sees ─────────────────

    /// @dev Every read of one game, each as (taken, answer or refusal): what any contract or agent can see.
    function _view(uint256 gameId) internal view returns (bytes memory) {
        bytes memory out;
        bytes[7] memory calls = [
            abi.encodeCall(IOspexGames.getGameStatus, (gameId)),
            abi.encodeCall(IOspexGames.getGameStart, (gameId)),
            abi.encodeCall(games.getGameReporters, (gameId)),
            abi.encodeCall(IOspexGames.getGameScores, (gameId)),
            abi.encodeCall(IOspexGames.getGameWindow, (gameId)),
            abi.encodeCall(IOspexGames.getGameTerms, (gameId)),
            abi.encodeCall(IOspexGames.isEveryReporterRetired, (gameId))
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
