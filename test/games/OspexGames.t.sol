// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
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
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";

/// @dev A contract that creates a game, as a program acting for someone would.
contract Creator {
    IOspexGames internal immutable i_games;

    constructor(IOspexGames games) {
        i_games = games;
    }

    function create() external returns (uint256) {
        return i_games.createGame("nhl", "Home", "Away", 1_800_000_037, new Hint[](0));
    }
}

/// @notice The games contract's behaviour beyond the never-lines: what creation accepts, what each report
///         kind needs, how each refusal is named, and what the events carry.
contract OspexGamesTest is GamesBase {
    // ──────────────────────────── Constructor ──────────────────────────

    function test_constructor_writesTheListInOrder() public {
        uint256 game = _create();
        (address[] memory r, uint8[] memory k) = games.getGameReporters(game);
        assertEq(r.length, 3);
        assertEq(r[0], address(first));
        assertEq(r[1], address(later));
        assertEq(r[2], address(second));
        assertEq(k[0], uint8(ReporterKind.FirstN));
        assertEq(k[1], uint8(ReporterKind.AfterN));
        assertEq(k[2], uint8(ReporterKind.FirstN));
        assertEq(games.getGameWindow(game), WINDOW);
    }

    function test_constructor_oneFirstNReporterIsEnough() public {
        address only = address(new MockReporter(IOspexGames(address(0))));
        OspexGames g = new OspexGames(_one(only), _kinds1(ReporterKind.FirstN), 1);
        vm.prank(creator);
        uint256 game = g.createGame("mlb", "Home", "Away", DATE, new Hint[](0));
        (address[] memory r, uint8[] memory k) = g.getGameReporters(game);
        assertEq(r.length, 1);
        assertEq(r[0], only);
        assertEq(k[0], 1);
        assertEq(g.getGameWindow(game), 1, "a window of one second is legal");
    }

    function test_constructor_refusals() public {
        address a = address(new MockReporter(IOspexGames(address(0))));
        address b = address(new MockReporter(IOspexGames(address(0))));

        vm.expectRevert(OspexGames.OspexGames__NoReporters.selector);
        new OspexGames(new address[](0), new ReporterKind[](0), WINDOW);

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__KindsLengthMismatch.selector, 1, 2));
        new OspexGames(_one(a), new ReporterKind[](2), WINDOW);

        vm.expectRevert(OspexGames.OspexGames__WindowZero.selector);
        new OspexGames(_one(a), _kinds1(ReporterKind.FirstN), 0);

        vm.expectRevert(OspexGames.OspexGames__ZeroReporter.selector);
        new OspexGames(_one(address(0)), _kinds1(ReporterKind.FirstN), WINDOW);

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NoKind.selector, a));
        new OspexGames(_one(a), _kinds1(ReporterKind.None), WINDOW);

        // A duplicate that is not next to its twin, with different kinds.
        address[] memory dup = new address[](3);
        (dup[0], dup[1], dup[2]) = (a, b, a);
        ReporterKind[] memory dupKinds = new ReporterKind[](3);
        (dupKinds[0], dupKinds[1], dupKinds[2]) = (ReporterKind.FirstN, ReporterKind.FirstN, ReporterKind.AfterN);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DuplicateReporter.selector, a));
        new OspexGames(dup, dupKinds, WINDOW);

        // Only after-n reporters: no start could ever be written.
        address[] memory two = new address[](2);
        (two[0], two[1]) = (a, b);
        ReporterKind[] memory afterOnly = new ReporterKind[](2);
        (afterOnly[0], afterOnly[1]) = (ReporterKind.AfterN, ReporterKind.AfterN);
        vm.expectRevert(OspexGames.OspexGames__NoFirstNReporter.selector);
        new OspexGames(two, afterOnly, WINDOW);

        // A duplicate next to its twin, and one at the end.
        (dup[0], dup[1], dup[2]) = (a, a, b);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DuplicateReporter.selector, a));
        new OspexGames(dup, dupKinds, WINDOW);
        (dup[0], dup[1], dup[2]) = (a, b, b);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DuplicateReporter.selector, b));
        new OspexGames(dup, dupKinds, WINDOW);

        // Controls: a first-n reporter is found last in the list, and first in it, ahead of an after-n one.
        (afterOnly[0], afterOnly[1]) = (ReporterKind.AfterN, ReporterKind.FirstN);
        new OspexGames(two, afterOnly, WINDOW);
        (afterOnly[0], afterOnly[1]) = (ReporterKind.FirstN, ReporterKind.AfterN);
        new OspexGames(two, afterOnly, WINDOW);
    }

    /// A kind outside the enum is refused by the decoder, before the constructor's body runs.
    function test_constructor_kindOutOfRangeIsRefused() public {
        address a = address(new MockReporter(IOspexGames(address(0))));
        bytes memory args = abi.encode(_one(a), _uint8s1(3), uint64(WINDOW));
        bytes memory code = abi.encodePacked(type(OspexGames).creationCode, args);
        address made;
        assembly ("memory-safe") {
            made := create(0, add(code, 0x20), mload(code))
        }
        assertEq(made, address(0), "a kind of 3 was taken");
        // Control: the same bytes with kind 1 deploy.
        args = abi.encode(_one(a), _uint8s1(1), uint64(WINDOW));
        code = abi.encodePacked(type(OspexGames).creationCode, args);
        assembly ("memory-safe") {
            made := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(made != address(0), "a kind of 1 was refused");
    }

    // ──────────────────────────── Creation ─────────────────────────────

    function test_create_eventCarriesTheIdentityAndTheCopy() public {
        Hint[] memory hints = _hints();
        vm.recordLogs();
        vm.prank(creator, creator);
        uint256 game = games.createGame("ncaab", "Saint Mary's (CA)", "Gonzaga", DATE + 5, hints);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(games));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], IOspexGames.GameCreated.selector);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(creator))));
        (
            string memory league,
            string memory home,
            string memory away,
            uint64 date,
            Hint[] memory gotHints,
            uint64 window,
            address[] memory reporters,
            uint8[] memory kinds
        ) = abi.decode(logs[0].data, (string, string, string, uint64, Hint[], uint64, address[], uint8[]));
        assertEq(league, "ncaab");
        assertEq(home, "Saint Mary's (CA)");
        assertEq(away, "Gonzaga");
        assertEq(date, DATE + 5);
        assertEq(gotHints.length, 2);
        assertEq(gotHints[0].seat, 3);
        assertEq(gotHints[0].id, "g-77120");
        assertEq(gotHints[1].seat, 1);
        assertEq(gotHints[1].id, "18432");
        assertEq(window, WINDOW);
        (address[] memory r, uint8[] memory k) = games.getGameReporters(game);
        assertEq(reporters, r);
        assertEq(kinds.length, k.length);
        for (uint256 i; i < k.length; ++i) {
            assertEq(kinds[i], k[i]);
        }
        assertEq(uint8(_status(game)), uint8(GameStatus.Unverified));
    }

    /// The creator the event names is the sender, not the transaction's origin: a contract that creates a game
    /// on someone's behalf is the creator.
    function test_create_creatorIsTheSenderNotTheOrigin() public {
        Creator c = new Creator(games);
        vm.recordLogs();
        vm.prank(creator, creator);
        uint256 game = c.create();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(c)))), "the creator is the sender");
    }

    function test_create_idsCountUpFromOne() public {
        assertEq(games.gameCount(), 0);
        for (uint256 i = 1; i <= 5; ++i) {
            assertEq(_create(), i);
            assertEq(games.gameCount(), i);
        }
    }

    function test_create_leagueId() public {
        string[8] memory good = ["a", "nfl", "ncaab", "f1", "0", "z9", "abcdefghijklmnop", "0123456789abcdef"];
        for (uint256 i; i < good.length; ++i) {
            games.createGame(good[i], "H", "A", DATE, new Hint[](0));
        }
        // Empty, one past the limit, and each neighbour of a-z and 0-9 in ASCII, plus the separators.
        string[12] memory bad =
            ["", "abcdefghijklmnopq", "NFL", "nFl", "n-fl", "n fl", "n_fl", "`", "{", "/", ":", "nfl\x00"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(OspexGames.OspexGames__LeagueNotValid.selector);
            games.createGame(bad[i], "H", "A", DATE, new Hint[](0));
        }
        // A byte above 0x7f.
        vm.expectRevert(OspexGames.OspexGames__LeagueNotValid.selector);
        games.createGame(string(hex"6e66c3a9"), "H", "A", DATE, new Hint[](0));
    }

    function test_create_teams() public {
        string memory max = _repeat("x", 64);
        string memory over = _repeat("x", 65);
        // The printable edges: space and tilde.
        games.createGame("nba", " ", "~", DATE, new Hint[](0));
        games.createGame("nba", max, "y", DATE, new Hint[](0));
        games.createGame("nba", "y", max, DATE, new Hint[](0));

        // Empty, too long, and a control byte, DEL or a non-ASCII byte first, inside and last.
        string[11] memory bad = [
            "",
            over,
            "\x1fab",
            "a\x1fb",
            "ab\x1f",
            "\x7fab",
            "ab\x7f",
            string(hex"c3a96162"),
            string(hex"4dc3a9"),
            "\x00",
            "ab\x0a"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(OspexGames.OspexGames__TeamNotValid.selector);
            games.createGame("nba", bad[i], "Away", DATE, new Hint[](0));
            vm.expectRevert(OspexGames.OspexGames__TeamNotValid.selector);
            games.createGame("nba", "Home", bad[i], DATE, new Hint[](0));
        }

        vm.expectRevert(OspexGames.OspexGames__SameTeams.selector);
        games.createGame("nba", "Utah Jazz", "Utah Jazz", DATE, new Hint[](0));
        // Control: text that differs only in case is two teams to the contract.
        games.createGame("nba", "Utah Jazz", "utah jazz", DATE, new Hint[](0));
    }

    function test_create_date() public {
        vm.expectRevert(OspexGames.OspexGames__NoDate.selector);
        games.createGame("nba", "H", "A", 0, new Hint[](0));
        uint256 game = games.createGame("nba", "H", "A", 1, new Hint[](0));
        assertEq(game, 1);
        games.createGame("nba", "H", "A", type(uint64).max, new Hint[](0));
    }

    function test_create_hints() public {
        Hint[] memory eight = new Hint[](8);
        for (uint256 i; i < 8; ++i) {
            eight[i] = Hint({seat: uint8(i), id: _repeat("9", 64)});
        }
        games.createGame("nba", "H", "A", DATE, eight);

        Hint[] memory nine = new Hint[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = Hint({seat: 1, id: "1"});
        }
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__TooManyHints.selector, 9));
        games.createGame("nba", "H", "A", DATE, nine);

        string[6] memory bad = ["", _repeat("9", 65), "a\nb", "\x1fab", "ab\x7f", string(hex"c3a9")];
        uint256[3] memory at = [uint256(0), 3, 7];
        for (uint256 i; i < bad.length; ++i) {
            for (uint256 p; p < at.length; ++p) {
                Hint[] memory h = new Hint[](8);
                for (uint256 j; j < 8; ++j) {
                    h[j] = Hint({seat: 2, id: "ok"});
                }
                h[at[p]].id = bad[i];
                vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__HintNotValid.selector, at[p]));
                games.createGame("nba", "H", "A", DATE, h);
            }
        }
    }

    // ──────────────────────────── The start ────────────────────────────

    /// The start must be within the game's window of the date given at creation, at both edges.
    function test_start_range() public {
        uint64[2] memory good = [DATE - WINDOW, DATE + WINDOW];
        for (uint256 i; i < good.length; ++i) {
            uint256 game = _create();
            _startBy(first, game, good[i]);
            assertEq(games.getGameStart(game), good[i]);
        }
        uint64[2] memory bad = [DATE - WINDOW - 1, DATE + WINDOW + 1];
        for (uint256 i; i < bad.length; ++i) {
            uint256 game = _create();
            (bool ok, bytes memory err) = _send(address(first), _startReport(game, bad[i]));
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, game, bad[i]));
        }
    }

    /// A start of 0 is refused even where the date is so early that 0 is within the window of it, since a
    /// written start is never 0.
    function test_start_zeroIsRefused() public {
        uint256 game = _createAt(100);
        (bool ok, bytes memory err) = _send(address(first), _startReport(game, 0));
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, game, 0));
        // Control: 1 is within the window of 100 and is taken.
        _startBy(first, game, 1);
        assertEq(games.getGameStart(game), 1);
    }

    /// The window used for the range is the game's own, copied at creation.
    function test_start_rangeUsesTheGamesOwnWindow() public {
        uint256 game = _create();
        games.harnessSetWindow(10);
        uint256 narrow = _create();
        _startBy(first, game, DATE + WINDOW);
        (bool ok, bytes memory err) = _send(address(first), _startReport(narrow, DATE + 11));
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, narrow, DATE + 11));
        _startBy(first, narrow, DATE + 10);
        assertEq(games.getGameWindow(game), WINDOW);
        assertEq(games.getGameWindow(narrow), 10);
    }

    function test_start_scoreFieldsMustBeEmpty() public {
        uint32[2][2] memory fields = [[uint32(1), uint32(0)], [uint32(0), uint32(1)]];
        for (uint256 i; i < fields.length; ++i) {
            uint256 game = _create();
            Report memory r = _startReport(game, START);
            (r.homeScore, r.awayScore) = (fields[i][0], fields[i][1]);
            (bool ok, bytes memory err) = _send(address(first), r);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Start));
        }
    }

    function test_start_onlyFirstN() public {
        uint256 game = _create();
        (bool ok, bytes memory err) = _send(address(later), _startReport(game, START));
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotFirstN.selector, game, address(later)));
        // Either first-n reporter may write it; the second one on the list here.
        _startBy(second, game, START);
        assertEq(games.getGameStart(game), START);
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified));
    }

    function test_start_canBeWrittenAnyTimeBeforeAnEnd() public {
        uint64[3] memory times = [uint64(DATE - 30 days), START + 1, DATE + 60 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            uint256 game = _create();
            _startBy(first, game, START);
            assertEq(games.getGameStart(game), START);
        }
    }

    // ──────────────────────────── The score ────────────────────────────

    function test_score_bounds() public {
        uint32 max = games.MAX_SCORE();
        uint256 game = _verified();
        vm.warp(START);
        uint32[2][2] memory over = [[max + 1, uint32(0)], [uint32(0), max + 1]];
        for (uint256 i; i < over.length; ++i) {
            (bool ok, bytes memory err) = _send(address(first), _scoreReport(game, over[i][0], over[i][1]));
            assertFalse(ok);
            assertEq(
                err, abi.encodeWithSelector(OspexGames.OspexGames__ScoreOutOfRange.selector, over[i][0], over[i][1])
            );
        }
        _scoreBy(first, game, max, max);
        (uint32 h, uint32 a) = games.getGameScores(game);
        assertEq(h, max);
        assertEq(a, max);
        assertEq(max, 1_000_000);
        assertLt(uint256(max) * 10, uint256(uint32(type(int32).max)), "MAX_SCORE x 10 fits in int32");
    }

    function test_score_startFieldMustBeEmpty() public {
        uint256 game = _verified();
        vm.warp(START + 1);
        Report memory r = _scoreReport(game, HOME, AWAY);
        r.start = 1;
        (bool ok, bytes memory err) = _send(address(first), r);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Score));
    }

    /// An after-n reporter scores from start + n, not a second before. A first-n reporter scores from the start.
    function test_score_afterNOpensAtStartPlusN() public {
        uint256 game = _verified();
        uint256 opensAt = uint256(START) + WINDOW;
        uint64[3] memory early = [START, START + WINDOW / 2, uint64(opensAt - 1)];
        for (uint256 i; i < early.length; ++i) {
            vm.warp(early[i]);
            (bool ok, bytes memory err) = _send(address(later), _scoreReport(game, HOME, AWAY));
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, game, opensAt));
        }
        vm.warp(opensAt);
        _scoreBy(later, game, HOME, AWAY);
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored));

        // A first-n reporter scores inside n.
        vm.warp(DATE - 1 hours);
        uint256 other = _verified();
        vm.warp(START);
        _scoreBy(second, other, HOME, AWAY);
        assertEq(uint8(_status(other)), uint8(GameStatus.Scored));
    }

    /// The after-n clock is the game's own n, copied at creation: a later change to n for new games moves it
    /// neither way.
    function test_score_afterNClockIsTheGamesOwnN() public {
        uint256 wide = _verified(); // n = WINDOW
        games.harnessSetWindow(10 minutes);
        uint256 narrow = _create();
        uint64 narrowStart = DATE + 300; // within the narrow game's n of its date
        _startBy(first, narrow, narrowStart);
        games.harnessSetWindow(3 days);

        vm.warp(uint256(narrowStart) + 10 minutes - 1);
        (bool early,) = _send(address(later), _scoreReport(narrow, HOME, AWAY));
        assertFalse(early, "the narrow game took an after-n score inside its own n");
        vm.warp(uint256(narrowStart) + 10 minutes);
        _scoreBy(later, narrow, HOME, AWAY);
        (bool ok, bytes memory err) = _send(address(later), _scoreReport(wide, HOME, AWAY));
        assertFalse(ok, "the wide game took an after-n score at the narrow game's n");
        assertEq(
            err, abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, wide, uint256(START) + WINDOW)
        );
        vm.warp(uint256(START) + WINDOW);
        _scoreBy(later, wide, HOME, AWAY);
        assertEq(uint8(_status(wide)), uint8(GameStatus.Scored));
    }

    /// An after-n reporter before the start is refused by the start, the earlier rule.
    function test_score_afterNBeforeTheStart() public {
        uint256 game = _verified();
        vm.warp(START - 1);
        (bool ok, bytes memory err) = _send(address(later), _scoreReport(game, HOME, AWAY));
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, game, START));
    }

    // ──────────────────────────── Report kinds and refusal names ───────

    function test_report_kindsNotTakenHere() public {
        uint256 game = _verified();
        vm.warp(START + WINDOW + 1);
        ReportKind[3] memory kinds = [ReportKind.None, ReportKind.Void, ReportKind.Dispute];
        for (uint256 i; i < kinds.length; ++i) {
            Report memory r = _scoreReport(game, 0, 0);
            r.kind = kinds[i];
            (bool ok, bytes memory err) = _send(address(first), r);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReportKindNotTaken.selector, kinds[i]));
        }
    }

    /// A kind outside the enum is refused by the decoder.
    function test_report_kindOutOfRangeIsRefused() public {
        uint256 game = _create();
        bytes memory data = abi.encodeCall(IOspexGames.report, (_startReport(game, START)));
        // The kind is the second head word of the tuple: selector (4) + offset (32) + gameId (32).
        uint256 kindWord;
        assembly ("memory-safe") {
            kindWord := mload(add(data, add(0x20, 68)))
            mstore(add(data, add(0x20, 68)), 5)
        }
        assertEq(kindWord, uint256(ReportKind.Start), "found the kind's word");
        vm.prank(address(first));
        (bool ok,) = address(games).call(data);
        assertFalse(ok, "a report kind of 5 was taken");
        // Control: the same bytes with the kind put back are taken.
        assembly ("memory-safe") {
            mstore(add(data, add(0x20, 68)), 1)
        }
        vm.prank(address(first));
        (ok,) = address(games).call(data);
        assertTrue(ok, "the start was refused");
        assertEq(games.getGameStart(game), START);
    }

    /// The July list's split of the old "already scored" refusal: each status names its own reason, for a
    /// start and for a score, from a reporter otherwise permitted.
    function test_report_refusalNamesByStatus() public {
        GameStatus[6] memory statuses = [
            GameStatus.Unverified,
            GameStatus.Verified,
            GameStatus.Disputed,
            GameStatus.Scored,
            GameStatus.Voided,
            GameStatus.Released
        ];
        for (uint256 i; i < statuses.length; ++i) {
            GameStatus s = statuses[i];
            // A game with its start written, then put in the status, so only the status decides.
            vm.warp(DATE - 1 hours);
            uint256 game = _verified();
            games.harnessSetStatus(game, s);
            vm.warp(START + WINDOW + 1);

            bytes memory wantStart;
            if (s == GameStatus.Verified || s == GameStatus.Disputed) {
                wantStart = abi.encodeWithSelector(OspexGames.OspexGames__StartAlreadyWritten.selector, game);
            } else if (s != GameStatus.Unverified) {
                wantStart = abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, s);
            }
            (bool okStart, bytes memory errStart) = _send(address(first), _startReport(game, START + 1));
            if (s == GameStatus.Unverified) {
                assertTrue(okStart, "a start on an unverified game");
            } else {
                assertFalse(okStart, "start taken");
                assertEq(errStart, wantStart, "start refusal name");
            }

            games.harnessSetStatus(game, s);
            bytes memory wantScore;
            if (s == GameStatus.Unverified) {
                wantScore = abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game);
            } else if (s == GameStatus.Disputed) {
                wantScore = abi.encodeWithSelector(OspexGames.OspexGames__Disputed.selector, game);
            } else if (s != GameStatus.Verified) {
                wantScore = abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, s);
            }
            (bool okScore, bytes memory errScore) = _send(address(first), _scoreReport(game, HOME, AWAY));
            if (s == GameStatus.Verified) {
                assertTrue(okScore, "a score on a verified game");
            } else {
                assertFalse(okScore, "score taken");
                assertEq(errScore, wantScore, "score refusal name");
            }
        }
    }

    function test_report_eventCarriesTheWholeReport() public {
        uint256 game = _create();
        _create(); // so the reported game is not the newest one
        Report memory r = _startReport(game, START);
        vm.recordLogs();
        _take(address(first), r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IOspexGames.GameReported.selector);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(first)))));
        assertEq(uint256(logs[0].topics[3]), uint256(ReportKind.Start));
        (uint64 start, uint32 h, uint32 a, Reading[] memory readings, address pay) =
            abi.decode(logs[0].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(start, START);
        assertEq(uint256(h) + uint256(a), 0);
        assertEq(pay, payout);
        _assertReadings(readings, _readings());

        vm.warp(START + 1);
        Report memory s = _scoreReport(game, HOME, AWAY);
        s.payout = address(0xBEE);
        vm.recordLogs();
        _take(address(second), s);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(second)))), "the reporter that wrote");
        assertEq(uint256(logs[0].topics[3]), uint256(ReportKind.Score));
        (start, h, a, readings, pay) = abi.decode(logs[0].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(start, 0);
        assertEq(h, HOME);
        assertEq(a, AWAY);
        assertEq(pay, address(0xBEE));
        _assertReadings(readings, _readings());
    }

    /// A report with no readings is taken: the games set emits readings and checks none.
    function test_report_readingsAreNotChecked() public {
        uint256 game = _create();
        Report memory r = _startReport(game, START);
        r.readings = new Reading[](0);
        _take(address(first), r);
        assertEq(games.getGameStart(game), START);
    }

    // ──────────────────────────── Reads ────────────────────────────────

    function test_reads_refuseAnIdThatIsNotAGame() public {
        _create();
        uint256[2] memory ids = [uint256(0), 2];
        for (uint256 i; i < ids.length; ++i) {
            bytes memory err = abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, ids[i]);
            vm.expectRevert(err);
            games.getGameStatus(ids[i]);
            vm.expectRevert(err);
            games.getGameStart(ids[i]);
            vm.expectRevert(err);
            games.getGameReporters(ids[i]);
            vm.expectRevert(err);
            games.getGameScores(ids[i]);
            vm.expectRevert(err);
            games.getGameWindow(ids[i]);
        }
    }

    function test_reads_startRefusedUntilWritten() public {
        uint256 game = _create();
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
        games.getGameStart(game);
        _startBy(first, game, START);
        assertEq(games.getGameStart(game), START);
    }

    /// A later change to n for new games does not reach a game already made.
    function test_reads_windowIsTheCreationCopy() public {
        uint256 game = _create();
        games.harnessSetWindow(7 hours);
        uint256 later_ = _create();
        assertEq(games.getGameWindow(game), WINDOW);
        assertEq(games.getGameWindow(later_), 7 hours);
    }

    /// The reads are open to any address.
    function test_reads_openToAnyAddress() public {
        uint256 game = _verified();
        vm.warp(START);
        _scoreBy(first, game, HOME, AWAY);
        address[3] memory who = [makeAddr("anyone"), address(0), address(games)];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i], who[i]);
            assertEq(uint8(games.getGameStatus(game)), uint8(GameStatus.Scored));
            assertEq(games.getGameStart(game), START);
            (uint32 h,) = games.getGameScores(game);
            assertEq(h, HOME);
            assertEq(games.getGameWindow(game), WINDOW);
            (address[] memory r,) = games.getGameReporters(game);
            assertEq(r.length, 3);
            vm.stopPrank();
        }
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _verified() internal returns (uint256 game) {
        game = _create();
        _startBy(first, game, START);
    }

    function _repeat(string memory s, uint256 times) internal pure returns (string memory out) {
        for (uint256 i; i < times; ++i) {
            out = string.concat(out, s);
        }
    }

    function _uint8s1(uint8 v) internal pure returns (uint8[] memory list) {
        list = new uint8[](1);
        list[0] = v;
    }

    function _assertReadings(Reading[] memory got, Reading[] memory want) internal pure {
        assertEq(got.length, want.length, "readings length");
        for (uint256 i; i < want.length; ++i) {
            assertEq(got[i].seat, want[i].seat, "seat");
            assertEq(uint8(got[i].kind), uint8(want[i].kind), "reading kind");
            assertEq(got[i].homeScore, want[i].homeScore, "reading home");
            assertEq(got[i].awayScore, want[i].awayScore, "reading away");
        }
    }
}
