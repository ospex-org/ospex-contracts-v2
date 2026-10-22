// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    ReadingKind,
    Reading,
    Report,
    Hint
} from "../../src/games/IOspexGames.sol";

/// @dev A reporter as the games set sees one: a contract that sends reports. It relays what it is given.
contract MockReporter {
    IOspexGames public immutable i_games;

    constructor(IOspexGames games) {
        i_games = games;
    }

    function send(Report calldata r) external {
        i_games.report(r);
    }
}

/// @dev The games contract with test-only hooks. It overrides nothing, so every inherited call runs the
///      production code. The hooks stand in for what later work adds: the timelock's changes to the approved
///      list and to n for new games, and the ends that write the statuses this contract cannot write yet.
contract OspexGamesHarness is OspexGames {
    constructor(address[] memory reporters, ReporterKind[] memory kinds, uint64 window)
        OspexGames(reporters, kinds, window)
    {}

    /// @dev Replaces the approved list, as approvals and retirements will.
    function harnessSetApproved(address[] memory reporters, ReporterKind[] memory kinds) external {
        delete s_approved;
        for (uint256 i; i < reporters.length; ++i) {
            s_approved.push(Reporter({account: reporters[i], kind: kinds[i]}));
        }
    }

    /// @dev Sets n for games created after this, as a term change will.
    function harnessSetWindow(uint64 window) external {
        s_window = window;
    }

    /// @dev Puts a game in a status, as the ends will.
    function harnessSetStatus(uint256 gameId, GameStatus status) external {
        s_games[gameId].status = status;
    }

    /// @dev Plants score fields without the status, to show the read does not trust them.
    function harnessSetScoreFields(uint256 gameId, uint32 homeScore, uint32 awayScore) external {
        s_games[gameId].homeScore = homeScore;
        s_games[gameId].awayScore = awayScore;
    }

    /// @dev The approved list as it stands.
    function harnessApproved() external view returns (address[] memory reporters, uint8[] memory kinds) {
        uint256 count = s_approved.length;
        reporters = new address[](count);
        kinds = new uint8[](count);
        for (uint256 i; i < count; ++i) {
            reporters[i] = s_approved[i].account;
            kinds[i] = uint8(s_approved[i].kind);
        }
    }
}

/// @dev Shared setup: three reporters of mixed kinds, a date, a window, and helpers.
abstract contract GamesBase is Test {
    uint64 internal constant WINDOW = 1 days;
    /// @dev A scheduled start that is not round, so a start equal to it cannot pass for a start written as given.
    uint64 internal constant DATE = 1_800_000_037;
    /// @dev The start written in most tests: inside the window of DATE, and not equal to it.
    uint64 internal constant START = DATE + 613;
    uint32 internal constant HOME = 104;
    uint32 internal constant AWAY = 97;

    OspexGamesHarness internal games;
    /// @dev First-n reporter, first on the list.
    MockReporter internal first;
    /// @dev After-n reporter, second on the list.
    MockReporter internal later;
    /// @dev A second first-n reporter, third on the list.
    MockReporter internal second;

    address internal deployer = makeAddr("deployer");
    address internal creator = makeAddr("creator");
    address internal timelockKey = makeAddr("timelock");
    address internal payout = makeAddr("payout");

    function setUp() public virtual {
        vm.warp(DATE - 3 days);
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
        games = new OspexGamesHarness(reporters, kinds, WINDOW);
        vm.stopPrank();
        assertEq(address(games), predicted, "games address as predicted");
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

    function _startReport(uint256 gameId, uint64 start) internal view returns (Report memory r) {
        r.gameId = gameId;
        r.kind = ReportKind.Start;
        r.start = start;
        r.readings = _readings();
        r.payout = payout;
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
        bytes[5] memory calls = [
            abi.encodeCall(IOspexGames.getGameStatus, (gameId)),
            abi.encodeCall(IOspexGames.getGameStart, (gameId)),
            abi.encodeCall(games.getGameReporters, (gameId)),
            abi.encodeCall(IOspexGames.getGameScores, (gameId)),
            abi.encodeCall(IOspexGames.getGameWindow, (gameId))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory answer) = address(games).staticcall(calls[i]);
            out = abi.encodePacked(out, ok, keccak256(answer));
        }
        return out;
    }

    /// @dev Every read of every game, ids 0 to count + 1, and the count: the whole readable state.
    function _viewAll() internal view returns (bytes32) {
        uint256 count = games.gameCount();
        bytes memory out = abi.encode(count);
        for (uint256 id; id <= count + 1; ++id) {
            out = abi.encodePacked(out, _view(id));
        }
        return keccak256(out);
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

    function _selector(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(err, 0x20))
        }
    }
}
