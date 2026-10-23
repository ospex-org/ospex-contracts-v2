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
    Hint,
    Terms
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
        (address[] memory approved, uint8[] memory approvedKinds) = games.getApprovedReporters();
        uint256 game = _create();
        (address[] memory r, uint8[] memory k) = games.getGameReporters(game);
        assertEq(r.length, 3);
        assertEq(r[0], address(first));
        assertEq(r[1], address(later));
        assertEq(r[2], address(second));
        assertEq(k[0], uint8(ReporterKind.FirstN));
        assertEq(k[1], uint8(ReporterKind.AfterN));
        assertEq(k[2], uint8(ReporterKind.FirstN));
        assertEq(approved, r, "the approved list read");
        for (uint256 i; i < 3; ++i) {
            assertEq(approvedKinds[i], k[i], "the approved list's kinds");
        }
        assertEq(games.getGameWindow(game), WINDOW);
        _assertTerms(games.getGameTerms(game), _launchTerms(), "the launch terms");
        _assertTerms(games.getTerms(""), _launchTerms(), "the default terms");
        assertEq(games.i_timelock(), address(timelock), "the timelock");
    }

    function test_constructor_oneFirstNReporterIsEnough() public {
        address only = address(new MockReporter(IOspexGames(address(0))));
        OspexGames g = new OspexGames(
            address(timelock), _terms(1), _one(only), _kinds1(ReporterKind.FirstN), _hashes(_one(only))
        );
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
        address b = address(new MockReporter(IOspexGames(address(1))));
        address t = address(timelock);
        Terms memory terms = _launchTerms();

        vm.expectRevert(OspexGames.OspexGames__NoReporters.selector);
        new OspexGames(t, terms, new address[](0), new ReporterKind[](0), new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__LengthsDiffer.selector, 1, 2, 1));
        new OspexGames(t, terms, _one(a), new ReporterKind[](2), _hashes(_one(a)));
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__LengthsDiffer.selector, 1, 1, 0));
        new OspexGames(t, terms, _one(a), _kinds1(ReporterKind.FirstN), new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NoCode.selector, address(0)));
        new OspexGames(t, terms, _one(address(0)), _kinds1(ReporterKind.FirstN), new bytes32[](1));

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NoKind.selector, a));
        new OspexGames(t, terms, _one(a), _kinds1(ReporterKind.None), _hashes(_one(a)));

        // A duplicate that is not next to its twin, with different kinds.
        address[] memory dup = new address[](3);
        (dup[0], dup[1], dup[2]) = (a, b, a);
        ReporterKind[] memory dupKinds = new ReporterKind[](3);
        (dupKinds[0], dupKinds[1], dupKinds[2]) = (ReporterKind.FirstN, ReporterKind.FirstN, ReporterKind.AfterN);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__AlreadyApproved.selector, a));
        new OspexGames(t, terms, dup, dupKinds, _hashes(dup));

        // Only after-n reporters: no start could ever be written.
        address[] memory two = new address[](2);
        (two[0], two[1]) = (a, b);
        ReporterKind[] memory afterOnly = new ReporterKind[](2);
        (afterOnly[0], afterOnly[1]) = (ReporterKind.AfterN, ReporterKind.AfterN);
        vm.expectRevert(OspexGames.OspexGames__NoFirstNReporter.selector);
        new OspexGames(t, terms, two, afterOnly, _hashes(two));

        // A duplicate next to its twin, and one at the end.
        (dup[0], dup[1], dup[2]) = (a, a, b);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__AlreadyApproved.selector, a));
        new OspexGames(t, terms, dup, dupKinds, _hashes(dup));
        (dup[0], dup[1], dup[2]) = (a, b, b);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__AlreadyApproved.selector, b));
        new OspexGames(t, terms, dup, dupKinds, _hashes(dup));

        // Each launch term at 0 is refused.
        for (uint256 i; i < 3; ++i) {
            Terms memory zero = _launchTerms();
            if (i == 0) zero.window = 0;
            if (i == 1) zero.day7Clock = 0;
            if (i == 2) zero.day30Clock = 0;
            vm.expectRevert(OspexGames.OspexGames__TermsNotValid.selector);
            new OspexGames(t, zero, _one(a), _kinds1(ReporterKind.FirstN), _hashes(_one(a)));
        }

        // Controls: a first-n reporter is found last in the list, and first in it, ahead of an after-n one.
        (afterOnly[0], afterOnly[1]) = (ReporterKind.AfterN, ReporterKind.FirstN);
        new OspexGames(t, terms, two, afterOnly, _hashes(two));
        (afterOnly[0], afterOnly[1]) = (ReporterKind.FirstN, ReporterKind.AfterN);
        new OspexGames(t, terms, two, afterOnly, _hashes(two));
    }

    /// A kind outside the enum is refused by the decoder, before the constructor's body runs.
    function test_constructor_kindOutOfRangeIsRefused() public {
        address a = address(new MockReporter(IOspexGames(address(0))));
        bytes memory args = abi.encode(address(timelock), _launchTerms(), _one(a), _uint8s1(3), _hashes(_one(a)));
        bytes memory code = abi.encodePacked(type(OspexGames).creationCode, args);
        address made;
        assembly ("memory-safe") {
            made := create(0, add(code, 0x20), mload(code))
        }
        assertEq(made, address(0), "a kind of 3 was taken");
        // Control: the same bytes with kind 1 deploy.
        args = abi.encode(address(timelock), _launchTerms(), _one(a), _uint8s1(1), _hashes(_one(a)));
        code = abi.encodePacked(type(OspexGames).creationCode, args);
        assembly ("memory-safe") {
            made := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(made != address(0), "a kind of 1 was refused");
    }

    // ──────────────────────────── Creation ─────────────────────────────

    /// The league has terms of its own, each of the four unlike the defaults, so an event carrying the defaults
    /// in their place is seen.
    function test_create_eventCarriesTheIdentityAndTheCopy() public {
        _setTerms("ncaab", _ownTerms());
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
            Terms memory terms,
            address[] memory reporters,
            uint8[] memory kinds
        ) = abi.decode(logs[0].data, (string, string, string, uint64, Hint[], Terms, address[], uint8[]));
        assertEq(league, "ncaab");
        assertEq(home, "Saint Mary's (CA)");
        assertEq(away, "Gonzaga");
        assertEq(date, DATE + 5);
        assertEq(gotHints.length, 2);
        assertEq(gotHints[0].seat, 3);
        assertEq(gotHints[0].id, "g-77120");
        assertEq(gotHints[1].seat, 1);
        assertEq(gotHints[1].id, "18432");
        _assertTerms(terms, _ownTerms(), "the event's terms");
        _assertTerms(terms, games.getGameTerms(game), "the event's terms against the read");
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
        // The printable edges, space and tilde: a space is taken first and last, beside one other character.
        games.createGame("nba", " !", "~ ", DATE, new Hint[](0));
        games.createGame("nba", "a b", "~", DATE, new Hint[](0));
        games.createGame("nba", max, "y", DATE, new Hint[](0));
        games.createGame("nba", "y", max, DATE, new Hint[](0));
        games.createGame("nba", string.concat(_repeat(" ", 63), "z"), "y", DATE, new Hint[](0));

        // Empty, too long, only spaces, and a control byte, DEL or a non-ASCII byte first, inside and last.
        string[14] memory bad = [
            "",
            over,
            " ",
            "  ",
            _repeat(" ", 64),
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

    /// A date is not 0 and is at most a year after the creation. A date long past is taken: a late creation
    /// is not refused here.
    function test_create_date() public {
        uint64 edge = uint64(vm.getBlockTimestamp() + 31_536_000); // 365 days, written out
        uint64[5] memory bad = [uint64(0), edge + 1, edge + 30 days, DATE * 1000, type(uint64).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DateNotValid.selector, bad[i]));
            games.createGame("nba", "H", "A", bad[i], new Hint[](0));
        }
        uint64[4] memory good = [uint64(1), DATE - 400 days, DATE, edge];
        for (uint256 i; i < good.length; ++i) {
            uint256 game = games.createGame("nba", "H", "A", good[i], new Hint[](0));
            assertEq(game, i + 1, "a good date was refused");
        }
        // The cap counts from the creation's own time: a day later, a date a day further on is taken.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        games.createGame("nba", "H", "A", edge + 1 days, new Hint[](0));
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DateNotValid.selector, edge + 1 days + 1));
        games.createGame("nba", "H", "A", edge + 1 days + 1, new Hint[](0));
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

        string[8] memory bad = ["", _repeat("9", 65), " ", _repeat(" ", 64), "a\nb", "\x1fab", "ab\x7f", string(hex"c3a9")];
        uint256[3] memory at = [uint256(0), 3, 7];
        for (uint256 i; i < bad.length; ++i) {
            for (uint256 p; p < at.length; ++p) {
                Hint[] memory h = _eightSeats();
                h[at[p]].id = bad[i];
                vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__HintNotValid.selector, at[p]));
                games.createGame("nba", "H", "A", DATE, h);
            }
        }
        // Control: an id with spaces and one other character is taken.
        Hint[] memory spaced = _eightSeats();
        spaced[7].id = string.concat(_repeat(" ", 63), "1");
        games.createGame("nba", "H", "A", DATE, spaced);
    }

    /// No seat is hinted twice: the second hint for a seat is refused wherever the two sit, at both ends of
    /// the seat range, whatever their ids.
    function test_create_hintSeatsAreUnique() public {
        // (first index, second index, seat)
        uint256[3][5] memory twice = [[uint256(0), 1, 0], [uint256(0), 7, 255], [uint256(3), 5, 7], [uint256(6), 7, 1], [uint256(2), 4, 128]];
        for (uint256 c; c < twice.length; ++c) {
            Hint[] memory h = _eightSeats();
            h[twice[c][0]].seat = uint8(twice[c][2]);
            h[twice[c][1]].seat = uint8(twice[c][2]);
            h[twice[c][1]].id = "another id";
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__HintSeatRepeated.selector, twice[c][1]));
            games.createGame("nba", "H", "A", DATE, h);
        }
        // Controls: neighbouring seats and the two ends of the range together are taken.
        uint8[2][3] memory pairs = [[uint8(0), uint8(255)], [uint8(254), uint8(255)], [uint8(0), uint8(1)]];
        for (uint256 c; c < pairs.length; ++c) {
            Hint[] memory h = new Hint[](2);
            h[0] = Hint({seat: pairs[c][0], id: "a"});
            h[1] = Hint({seat: pairs[c][1], id: "a"});
            games.createGame("nba", "H", "A", DATE, h);
        }
        // And the same id under two seats is two hints.
        Hint[] memory sameId = new Hint[](2);
        sameId[0] = Hint({seat: 1, id: "18432"});
        sameId[1] = Hint({seat: 2, id: "18432"});
        games.createGame("nba", "H", "A", DATE, sameId);
    }

    // ──────────────────────────── The start ────────────────────────────

    /// The start must be within a day of the date given at creation, either way, both edges taken, whatever
    /// the game's n: a short n, the launch n of a day, a day either side of it, and a long n. (Ruled 10/22:
    /// a fixed, inclusive 24 hours, replacing n.)
    function test_start_boundIsADayWhateverTheGamesN() public {
        uint64[7] memory ns = [uint64(1), 10 minutes, 6 hours, DAY - 1, DAY, DAY + 1, 3 days];
        for (uint256 w; w < ns.length; ++w) {
            _setTerms("nba", _terms(ns[w]));
            uint64[2] memory good = [DATE - DAY, DATE + DAY];
            for (uint256 i; i < good.length; ++i) {
                uint256 game = _create();
                assertEq(games.getGameWindow(game), ns[w], "the game's n");
                _startBy(first, game, good[i]);
                assertEq(games.getGameStart(game), good[i]);
            }
            uint64[2] memory bad = [DATE - DAY - 1, DATE + DAY + 1];
            for (uint256 i; i < bad.length; ++i) {
                uint256 game = _create();
                (bool ok, bytes memory err) = _send(address(first), _startReport(game, bad[i]));
                assertFalse(ok, "a start more than a day from the date was taken");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, game, bad[i]));
            }
        }
    }

    /// A start of 0 is refused even where the date is so early that 0 is within a day of it, since a written
    /// start is never 0.
    function test_start_zeroIsRefused() public {
        uint256 game = _createAt(100);
        (bool ok, bytes memory err) = _send(address(first), _startReport(game, 0));
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, game, 0));
        // Control: 1 is within a day of 100 and is taken.
        _startBy(first, game, 1);
        assertEq(games.getGameStart(game), 1);
    }

    /// A start uses no score and pays nothing: a home score, an away score or a payout on it is refused, each
    /// alone.
    function test_start_unusedFieldsMustBeEmpty() public {
        address[2] memory payouts = [address(1), address(type(uint160).max)];
        for (uint256 i; i < 4; ++i) {
            uint256 game = _create();
            Report memory r = _startReport(game, START);
            if (i == 0) r.homeScore = 1;
            if (i == 1) r.awayScore = 1;
            if (i >= 2) r.payout = payouts[i - 2];
            (bool ok, bytes memory err) = _send(address(first), r);
            assertFalse(ok, "a start with a field it does not use was taken");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Start));
        }
        // Control: the same start with every unused field empty is taken.
        uint256 clean = _create();
        _startBy(first, clean, START);
        assertEq(games.getGameStart(clean), START);
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

    /// A start written late is taken: no rule refuses a start written after date + n (not taken, 10/22). The
    /// bound above keeps it within a day of the date, so it moves the day-30 release by at most a day.
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

    /// The after-n clock is the game's own n, copied at creation: a later change to its league's terms moves
    /// it neither way.
    function test_score_afterNClockIsTheGamesOwnN() public {
        uint256 wide = _verified(); // n = WINDOW
        _setTerms("nba", _terms(10 minutes));
        uint256 narrow = _create();
        uint64 narrowStart = DATE + 300;
        _startBy(first, narrow, narrowStart);
        _setTerms("nba", _terms(3 days));

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
    /// start and for a score, from a first-n reporter and from an after-n reporter past start + n. The status
    /// is checked before the reporter's kind, so an after-n reporter's start on a game whose start is written
    /// is refused as written, not as the wrong kind.
    function test_report_refusalNamesByStatus() public {
        GameStatus[6] memory statuses = [
            GameStatus.Unverified,
            GameStatus.Verified,
            GameStatus.Disputed,
            GameStatus.Scored,
            GameStatus.Voided,
            GameStatus.Released
        ];
        // What each report gets, by status, in the order above: 0 is taken, anything else names the refusal.
        bytes4 taken = bytes4(0);
        bytes4 written = OspexGames.OspexGames__StartAlreadyWritten.selector;
        bytes4 ended = OspexGames.OspexGames__GameEnded.selector;
        bytes4[6] memory startByFirst = [taken, written, written, ended, ended, ended];
        bytes4[6] memory startByLater =
            [OspexGames.OspexGames__NotFirstN.selector, written, written, ended, ended, ended];
        bytes4[6] memory scoreByEither = [
            OspexGames.OspexGames__StartNotWritten.selector,
            taken,
            OspexGames.OspexGames__Disputed.selector,
            ended,
            ended,
            ended
        ];

        MockReporter[2] memory who = [first, later];
        for (uint256 w; w < who.length; ++w) {
            for (uint256 i; i < statuses.length; ++i) {
                // One game for the start and one for the score, each in the status: a fresh game for
                // Unverified, and for any other status a game whose start is written, then put in it.
                vm.warp(DATE - 1 hours);
                uint256 forStart = _inStatus(statuses[i]);
                uint256 forScore = _inStatus(statuses[i]);
                vm.warp(START + WINDOW + 1);

                (bool ok, bytes memory err) = _send(address(who[w]), _startReport(forStart, START + 1));
                _assertNamed(ok, err, w == 0 ? startByFirst[i] : startByLater[i], forStart, statuses[i], who[w]);
                (ok, err) = _send(address(who[w]), _scoreReport(forScore, HOME, AWAY));
                _assertNamed(ok, err, scoreByEither[i], forScore, statuses[i], who[w]);
            }
        }
    }

    /// A reading marked silent carries no score: a feed that did not answer gave none. Refused in a start and
    /// in a score, wherever the reading sits, with either score set, up to the largest the field holds.
    function test_report_aSilentReadingCarriesNoScore() public {
        uint32[2][3] memory dirt =
            [[uint32(1), uint32(0)], [uint32(0), uint32(1)], [type(uint32).max, type(uint32).max]];
        uint256[3] memory at = [uint256(0), 1, 3];
        for (uint256 k; k < 2; ++k) {
            for (uint256 d; d < dirt.length; ++d) {
                for (uint256 p; p < at.length; ++p) {
                    vm.warp(DATE - 1 hours);
                    uint256 game = _create();
                    Report memory r = _startReport(game, START);
                    if (k == 1) {
                        _startBy(first, game, START);
                        vm.warp(START + 1);
                        r = _scoreReport(game, HOME, AWAY);
                    }
                    r.readings[at[p]] =
                        Reading({seat: 9, kind: ReadingKind.Silent, homeScore: dirt[d][0], awayScore: dirt[d][1]});
                    bytes32 before = _viewAll();
                    (bool ok, bytes memory err) = _send(address(first), r);
                    assertFalse(ok, "a silent reading with a score was taken");
                    assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__SilentReadingNotEmpty.selector, at[p]));
                    assertEq(_viewAll(), before, "a refused report changed state");
                }
            }
        }
        // Controls, in a start and in a score: a silent reading at 0-0, a reading answered without a final at
        // 0-0 and with scores, and a final at 0-0.
        Reading[] memory fine = new Reading[](4);
        fine[0] = Reading({seat: 1, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        fine[1] = Reading({seat: 2, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
        fine[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: type(uint32).max, awayScore: 7});
        fine[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: 0, awayScore: 0});
        vm.warp(DATE - 1 hours);
        uint256 game2 = _create();
        Report memory start = _startReport(game2, START);
        start.readings = fine;
        _take(address(first), start);
        vm.warp(START + 1);
        Report memory score = _scoreReport(game2, HOME, AWAY);
        score.readings = fine;
        _take(address(first), score);
        assertEq(uint8(_status(game2)), uint8(GameStatus.Scored));
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
        assertEq(pay, address(0), "a start pays nothing");
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

    /// A start with no readings is taken: a report need not carry any. What the games set does check in a
    /// reading, that a silent one carries no score, is test_report_aSilentReadingCarriesNoScore.
    function test_report_aStartWithNoReadingsIsTaken() public {
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
            vm.expectRevert(err);
            games.getGameTerms(ids[i]);
            vm.expectRevert(err);
            games.isEveryReporterRetired(ids[i]);
        }
    }

    function test_reads_startRefusedUntilWritten() public {
        uint256 game = _create();
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
        games.getGameStart(game);
        _startBy(first, game, START);
        assertEq(games.getGameStart(game), START);
    }

    /// A game that ended without a start has none to read: the start read refuses by the start, never by the
    /// status. A release from the date reaches a game whose start was never written; the ends write that
    /// later, and the hook plants it here. Every written start reads back, whatever the status after it.
    function test_reads_startRefusedForAGameThatEndedWithoutOne() public {
        GameStatus[3] memory unstarted = [GameStatus.Unverified, GameStatus.Released, GameStatus.Voided];
        for (uint256 i; i < unstarted.length; ++i) {
            uint256 game = _create();
            games.harnessSetStatus(game, unstarted[i]);
            assertEq(uint8(_status(game)), uint8(unstarted[i]), "status");
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
            games.getGameStart(game);
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, unstarted[i]));
            games.getGameScores(game);
            if (unstarted[i] != GameStatus.Unverified) {
                // An ended game takes no start, so the read stays refused.
                (bool ok, bytes memory err) = _send(address(first), _startReport(game, START));
                assertFalse(ok, "an ended game took a start");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, unstarted[i]));
                vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
                games.getGameStart(game);
            }
        }
        // Controls: a written start reads back in every status a game with a start can reach.
        GameStatus[5] memory started =
            [GameStatus.Verified, GameStatus.Disputed, GameStatus.Scored, GameStatus.Voided, GameStatus.Released];
        for (uint256 i; i < started.length; ++i) {
            uint256 game = _create();
            _startBy(first, game, START);
            games.harnessSetStatus(game, started[i]);
            assertEq(games.getGameStart(game), START, "a written start did not read back");
        }
    }

    /// A later change to a league's terms does not reach a game already made, in any of the four.
    function test_reads_termsAreTheCreationCopy() public {
        uint256 game = _create();
        Terms memory changed = Terms({window: 7 hours, day7Clock: 3 days, day30Clock: 20 days, fee: 0});
        _setTerms("nba", changed);
        uint256 later_ = _create();
        assertEq(games.getGameWindow(game), WINDOW);
        assertEq(games.getGameWindow(later_), 7 hours);
        _assertTerms(games.getGameTerms(game), _launchTerms(), "the game made before");
        _assertTerms(games.getGameTerms(later_), changed, "the game made after");
    }

    /// Several never-line tests compare each game's storage word for word (GamesBase._rawGame), since no read
    /// returns a game's date. This pins where each field lies, with a value no other field holds, so a change
    /// of layout turns this red rather than leaving those comparisons reading empty slots.
    function test_storage_aGameLiesWhereTheSnapshotsReadIt() public {
        Terms memory own = _ownTerms();
        _setTerms("nba", own);
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + 1);
        _scoreBy(first, game, HOME, AWAY);

        // Word 0: status, date, start, home, away. Word 1: n and the two clocks. Word 2: the fee.
        bytes memory want = abi.encodePacked(
            uint256(uint8(GameStatus.Scored)) | (uint256(DATE) << 8) | (uint256(START) << 72)
                | (uint256(HOME) << 136) | (uint256(AWAY) << 168),
            uint256(own.window) | (uint256(own.day7Clock) << 64) | (uint256(own.day30Clock) << 128),
            uint256(own.fee)
        );
        // Then the reporters' copy: its length, and each entry as address and kind.
        uint256 firstKind = uint256(uint8(ReporterKind.FirstN)) << 160;
        want = abi.encodePacked(want, uint256(3), uint256(uint160(address(first))) | firstKind);
        want = abi.encodePacked(want, uint256(uint160(address(later))) | (uint256(uint8(ReporterKind.AfterN)) << 160));
        want = abi.encodePacked(want, uint256(uint160(address(second))) | firstKind);
        assertEq(_rawGame(game), want, "a game's storage");
        assertEq(_rawDate(game), DATE, "a game's date");
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

    /// @dev A league's own terms, each of the four unlike the launch terms.
    function _ownTerms() internal pure returns (Terms memory) {
        return Terms({window: 3 hours, day7Clock: 5 days, day30Clock: 20 days, fee: 2_500_000});
    }

    function _verified() internal returns (uint256 game) {
        game = _create();
        _startBy(first, game, START);
    }

    /// @dev A game in a status: a fresh game for Unverified; otherwise a game whose start is written, put in it.
    function _inStatus(GameStatus s) internal returns (uint256 game) {
        game = _create();
        if (s == GameStatus.Unverified) return game;
        _startBy(first, game, START);
        games.harnessSetStatus(game, s);
    }

    /// @dev Asserts a report was taken (want 0) or refused with the named error and its arguments.
    function _assertNamed(bool ok, bytes memory err, bytes4 want, uint256 game, GameStatus s, MockReporter who)
        internal
        pure
    {
        if (want == bytes4(0)) {
            assertTrue(ok, string.concat("refused: ", vm.toString(err)));
            return;
        }
        assertFalse(ok, "taken");
        bytes memory expected;
        if (want == OspexGames.OspexGames__GameEnded.selector) {
            expected = abi.encodeWithSelector(want, game, s);
        } else if (want == OspexGames.OspexGames__NotFirstN.selector) {
            expected = abi.encodeWithSelector(want, game, address(who));
        } else {
            expected = abi.encodeWithSelector(want, game);
        }
        assertEq(err, expected, "refusal name");
    }

    /// @dev Eight hints with eight different seats, none of them 1, 7, 128 or 255.
    function _eightSeats() internal pure returns (Hint[] memory h) {
        h = new Hint[](8);
        for (uint256 j; j < 8; ++j) {
            h[j] = Hint({seat: uint8(j * 31), id: "ok"});
        }
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
