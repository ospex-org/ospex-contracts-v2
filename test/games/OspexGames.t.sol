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
    Terms,
    OpenGame
} from "../../src/games/IOspexGames.sol";
import {GamesBase, GameWords, MockReporter, OspexGamesHarness} from "./GamesBase.sol";

/// @dev A contract that creates a game, as a program acting for someone would.
contract Creator {
    IOspexGames internal immutable i_games;

    constructor(IOspexGames games) {
        i_games = games;
    }

    function create() external returns (uint256) {
        return i_games.createGame("nhl", "Home", "Away", 1_800_000_037, new Hint[](0), type(uint256).max);
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
            address(timelock), token, _terms(1), _one(only), _kinds1(ReporterKind.FirstN), _hashes(_one(only))
        );
        vm.prank(creator);
        token.approve(address(g), FEE);
        vm.prank(creator);
        uint256 game = g.createGame("mlb", "Home", "Away", DATE, new Hint[](0), type(uint256).max);
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
        new OspexGames(t, token, terms, new address[](0), new ReporterKind[](0), new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__LengthsDiffer.selector, 1, 2, 1));
        new OspexGames(t, token, terms, _one(a), new ReporterKind[](2), _hashes(_one(a)));
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__LengthsDiffer.selector, 1, 1, 0));
        new OspexGames(t, token, terms, _one(a), _kinds1(ReporterKind.FirstN), new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NoCode.selector, address(0)));
        new OspexGames(t, token, terms, _one(address(0)), _kinds1(ReporterKind.FirstN), new bytes32[](1));

        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NoKind.selector, a));
        new OspexGames(t, token, terms, _one(a), _kinds1(ReporterKind.None), _hashes(_one(a)));

        // A duplicate that is not next to its twin, with different kinds.
        address[] memory dup = new address[](3);
        (dup[0], dup[1], dup[2]) = (a, b, a);
        ReporterKind[] memory dupKinds = new ReporterKind[](3);
        (dupKinds[0], dupKinds[1], dupKinds[2]) = (ReporterKind.FirstN, ReporterKind.FirstN, ReporterKind.AfterN);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__AlreadyApproved.selector, a));
        new OspexGames(t, token, terms, dup, dupKinds, _hashes(dup));

        // Only after-n reporters: no start could ever be written.
        address[] memory two = new address[](2);
        (two[0], two[1]) = (a, b);
        ReporterKind[] memory afterOnly = new ReporterKind[](2);
        (afterOnly[0], afterOnly[1]) = (ReporterKind.AfterN, ReporterKind.AfterN);
        vm.expectRevert(OspexGames.OspexGames__NoFirstNReporter.selector);
        new OspexGames(t, token, terms, two, afterOnly, _hashes(two));

        // A duplicate next to its twin, and one at the end.
        (dup[0], dup[1], dup[2]) = (a, a, b);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__AlreadyApproved.selector, a));
        new OspexGames(t, token, terms, dup, dupKinds, _hashes(dup));
        (dup[0], dup[1], dup[2]) = (a, b, b);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__AlreadyApproved.selector, b));
        new OspexGames(t, token, terms, dup, dupKinds, _hashes(dup));

        // Each launch term at 0 is refused.
        for (uint256 i; i < 3; ++i) {
            Terms memory zero = _launchTerms();
            if (i == 0) zero.window = 0;
            if (i == 1) zero.day7Clock = 0;
            if (i == 2) zero.day30Clock = 0;
            vm.expectRevert(OspexGames.OspexGames__TermsNotValid.selector);
            new OspexGames(t, token, zero, _one(a), _kinds1(ReporterKind.FirstN), _hashes(_one(a)));
        }

        // Controls: a first-n reporter is found last in the list, and first in it, ahead of an after-n one.
        (afterOnly[0], afterOnly[1]) = (ReporterKind.AfterN, ReporterKind.FirstN);
        new OspexGames(t, token, terms, two, afterOnly, _hashes(two));
        (afterOnly[0], afterOnly[1]) = (ReporterKind.FirstN, ReporterKind.AfterN);
        new OspexGames(t, token, terms, two, afterOnly, _hashes(two));
    }

    /// A kind outside the enum is refused by the decoder, before the constructor's body runs.
    function test_constructor_kindOutOfRangeIsRefused() public {
        address a = address(new MockReporter(IOspexGames(address(0))));
        bytes memory args = _ctorArgs(a, 3);
        bytes memory code = abi.encodePacked(type(OspexGames).creationCode, args);
        address made;
        assembly ("memory-safe") {
            made := create(0, add(code, 0x20), mload(code))
        }
        assertEq(made, address(0), "a kind of 3 was taken");
        // Control: the same bytes with kind 1 deploy.
        args = _ctorArgs(a, 1);
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
        uint256 game = games.createGame("ncaab", "Saint Mary's (CA)", "Gonzaga", DATE + 5, hints, ANY_FEE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The games set's one event, then the coin's: the creator pays the league's own fee to the games set.
        assertEq(logs.length, 2);
        _assertFeePaid(logs[1], creator, _ownTerms().fee);
        assertEq(logs[0].emitter, address(games));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], IOspexGames.GameCreated.selector);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(creator))));
        Created memory c = _decodeCreated(logs[0].data);
        assertEq(c.league, "ncaab");
        assertEq(c.home, "Saint Mary's (CA)");
        assertEq(c.away, "Gonzaga");
        assertEq(c.date, DATE + 5);
        assertEq(c.hints.length, 2);
        assertEq(c.hints[0].seat, 3);
        assertEq(c.hints[0].id, "g-77120");
        assertEq(c.hints[1].seat, 1);
        assertEq(c.hints[1].id, "18432");
        _assertTerms(c.terms, _ownTerms(), "the event's terms");
        _assertTerms(c.terms, games.getGameTerms(game), "the event's terms against the read");
        (address[] memory r, uint8[] memory k) = games.getGameReporters(game);
        assertEq(c.reporters, r);
        assertEq(c.kinds.length, k.length);
        for (uint256 i; i < k.length; ++i) {
            assertEq(c.kinds[i], k[i]);
        }
        assertEq(uint8(_status(game)), uint8(GameStatus.Unverified));
    }

    /// @dev GameCreated's data, field for field.
    struct Created {
        string league;
        string home;
        string away;
        uint64 date;
        Hint[] hints;
        Terms terms;
        address[] reporters;
        uint8[] kinds;
    }

    /// @dev Decodes GameCreated's data as one struct: the event's fields are the struct's, and a struct's
    ///      encoding is theirs behind one offset. One value back, where eight overran the stack.
    function _decodeCreated(bytes memory data) internal pure returns (Created memory) {
        return abi.decode(bytes.concat(abi.encode(uint256(32)), data), (Created));
    }

    /// The creator the event names is the sender, not the transaction's origin: a contract that creates a game
    /// on someone's behalf is the creator. It pays the fee, and a release would credit it.
    function test_create_creatorIsTheSenderNotTheOrigin() public {
        Creator c = new Creator(games);
        _fund(address(c), address(games));
        uint256 originCoin = token.balanceOf(creator);
        vm.recordLogs();
        vm.prank(creator, creator);
        uint256 game = c.create();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // The games set's one event, and the coin's transfer of the fee.
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(games));
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(c)))), "the creator is the sender");
        assertEq(token.balanceOf(address(c)), PURSE - FEE, "the sender paid the fee");
        assertEq(token.balanceOf(creator), originCoin, "the origin paid nothing");
        (, address recorded) = games.getGameFee(game);
        assertEq(recorded, address(c), "the creator a release credits");
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
            games.createGame(good[i], "H", "A", DATE, new Hint[](0), ANY_FEE);
        }
        // Empty, one past the limit, and each neighbour of a-z and 0-9 in ASCII, plus the separators.
        string[12] memory bad =
            ["", "abcdefghijklmnopq", "NFL", "nFl", "n-fl", "n fl", "n_fl", "`", "{", "/", ":", "nfl\x00"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(OspexGames.OspexGames__LeagueNotValid.selector);
            games.createGame(bad[i], "H", "A", DATE, new Hint[](0), ANY_FEE);
        }
        // A byte above 0x7f.
        vm.expectRevert(OspexGames.OspexGames__LeagueNotValid.selector);
        games.createGame(string(hex"6e66c3a9"), "H", "A", DATE, new Hint[](0), ANY_FEE);
    }

    function test_create_teams() public {
        string memory max = _repeat("x", 64);
        string memory over = _repeat("x", 65);
        // The printable edges, space and tilde: a space is taken first and last, beside one other character.
        games.createGame("nba", " !", "~ ", DATE, new Hint[](0), ANY_FEE);
        games.createGame("nba", "a b", "~", DATE, new Hint[](0), ANY_FEE);
        games.createGame("nba", max, "y", DATE, new Hint[](0), ANY_FEE);
        games.createGame("nba", "y", max, DATE, new Hint[](0), ANY_FEE);
        games.createGame("nba", string.concat(_repeat(" ", 63), "z"), "y", DATE, new Hint[](0), ANY_FEE);

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
            games.createGame("nba", bad[i], "Away", DATE, new Hint[](0), ANY_FEE);
            vm.expectRevert(OspexGames.OspexGames__TeamNotValid.selector);
            games.createGame("nba", "Home", bad[i], DATE, new Hint[](0), ANY_FEE);
        }

        vm.expectRevert(OspexGames.OspexGames__SameTeams.selector);
        games.createGame("nba", "Utah Jazz", "Utah Jazz", DATE, new Hint[](0), ANY_FEE);
        // Control: text that differs only in case is two teams to the contract.
        games.createGame("nba", "Utah Jazz", "utah jazz", DATE, new Hint[](0), ANY_FEE);
    }

    /// A date is not 0 and is at most a year after the creation. A date long past is taken: a late creation
    /// is not refused here.
    function test_create_date() public {
        uint64 edge = uint64(vm.getBlockTimestamp() + 31_536_000); // 365 days, written out
        uint64[5] memory bad = [uint64(0), edge + 1, edge + 30 days, DATE * 1000, type(uint64).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DateNotValid.selector, bad[i]));
            games.createGame("nba", "H", "A", bad[i], new Hint[](0), ANY_FEE);
        }
        uint64[4] memory good = [uint64(1), DATE - 400 days, DATE, edge];
        for (uint256 i; i < good.length; ++i) {
            uint256 game = games.createGame("nba", "H", "A", good[i], new Hint[](0), ANY_FEE);
            assertEq(game, i + 1, "a good date was refused");
        }
        // The cap counts from the creation's own time: a day later, a date a day further on is taken.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        games.createGame("nba", "H", "A", edge + 1 days, new Hint[](0), ANY_FEE);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__DateNotValid.selector, edge + 1 days + 1));
        games.createGame("nba", "H", "A", edge + 1 days + 1, new Hint[](0), ANY_FEE);
    }

    function test_create_hints() public {
        Hint[] memory eight = new Hint[](8);
        for (uint256 i; i < 8; ++i) {
            eight[i] = Hint({seat: uint8(i), id: _repeat("9", 64)});
        }
        games.createGame("nba", "H", "A", DATE, eight, ANY_FEE);

        Hint[] memory nine = new Hint[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = Hint({seat: 1, id: "1"});
        }
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__TooManyHints.selector, 9));
        games.createGame("nba", "H", "A", DATE, nine, ANY_FEE);

        string[8] memory bad = ["", _repeat("9", 65), " ", _repeat(" ", 64), "a\nb", "\x1fab", "ab\x7f", string(hex"c3a9")];
        uint256[3] memory at = [uint256(0), 3, 7];
        for (uint256 i; i < bad.length; ++i) {
            for (uint256 p; p < at.length; ++p) {
                Hint[] memory h = _eightSeats();
                h[at[p]].id = bad[i];
                vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__HintNotValid.selector, at[p]));
                games.createGame("nba", "H", "A", DATE, h, ANY_FEE);
            }
        }
        // Control: an id with spaces and one other character is taken.
        Hint[] memory spaced = _eightSeats();
        spaced[7].id = string.concat(_repeat(" ", 63), "1");
        games.createGame("nba", "H", "A", DATE, spaced, ANY_FEE);
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
            games.createGame("nba", "H", "A", DATE, h, ANY_FEE);
        }
        // Controls: neighbouring seats and the two ends of the range together are taken.
        uint8[2][3] memory pairs = [[uint8(0), uint8(255)], [uint8(254), uint8(255)], [uint8(0), uint8(1)]];
        for (uint256 c; c < pairs.length; ++c) {
            Hint[] memory h = new Hint[](2);
            h[0] = Hint({seat: pairs[c][0], id: "a"});
            h[1] = Hint({seat: pairs[c][1], id: "a"});
            games.createGame("nba", "H", "A", DATE, h, ANY_FEE);
        }
        // And the same id under two seats is two hints.
        Hint[] memory sameId = new Hint[](2);
        sameId[0] = Hint({seat: 1, id: "18432"});
        sameId[1] = Hint({seat: 2, id: "18432"});
        games.createGame("nba", "H", "A", DATE, sameId, ANY_FEE);
    }

    // ──────────────────────────── The start ────────────────────────────

    /// The start must be within a day of the date given at creation, either way, both edges taken, whatever
    /// the game's n: a short n, the launch n of a day, a day either side of it, and a long n. The bound is a
    /// fixed, inclusive 24 hours, and n plays no part in it.
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
    /// start is never 0. The clock sits before that date, so its day-30 clock has not run.
    function test_start_zeroIsRefused() public {
        vm.warp(50);
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

    /// A start written late is taken, up to the last second before the game's day-30 clock: no rule refuses a
    /// start written after date + n. The bound above keeps it within a day of the date, and writing it moves no
    /// clock. At the day-30 clock a start is refused like every other report: the release is the only door.
    function test_start_canBeWrittenAnyTimeBeforeTheDay30Clock() public {
        uint64[3] memory times = [uint64(DATE - 30 days), START + 1, DATE + DAY30 - 1];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            uint256 game = _create();
            _startBy(first, game, START);
            assertEq(games.getGameStart(game), START);
        }
        vm.warp(DATE - 1 hours);
        uint256 late = _create();
        vm.warp(DATE + DAY30);
        (bool ok, bytes memory err) = _send(address(first), _startReport(late, START));
        assertFalse(ok, "a start at the day-30 clock was taken");
        assertEq(err, _pastDay30(late));
        _releaseBy(stranger, late);
        assertEq(uint8(_status(late)), uint8(GameStatus.Released), "the release is the only door");
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

    /// A score names a payout address that is not 0: address 0 can never withdraw what a score credits it, and
    /// a scored game can never be scored again, so the refusal must come before the score is written. From
    /// either kind of reporter, inside n and after it. The games set's own address, the coin's and every
    /// reporter's are refused too, each by its own never-line test.
    /// Break: in _checkPayout(), delete `if (payout == address(0)) revert OspexGames__NoPayout(kind);`.
    function test_score_aZeroPayoutIsRefused() public {
        uint256 game = _verified();
        uint64[2] memory times = [START + 1, START + WINDOW];
        address[2] memory who = [address(first), address(later)];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 w; w < who.length; ++w) {
                Report memory r = _scoreReport(game, HOME, AWAY);
                r.payout = address(0);
                bytes32 before = _viewAll();
                vm.recordLogs();
                (bool ok, bytes memory err) = _send(who[w], r);
                assertFalse(ok, "a score with no payout address was taken");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NoPayout.selector, ReportKind.Score));
                assertEq(vm.getRecordedLogs().length, 0);
                assertEq(_viewAll(), before, "a refused score changed state");
            }
        }
        // Control: the same score with a payout address is taken.
        _take(address(first), _scoreReport(game, HOME, AWAY));
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored));
        assertEq(games.getCredit(payout), FEE, "the payout address named is credited");
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

    /// A report with no kind is refused by name, at an hour every other kind is taken.
    function test_report_aReportWithNoKindIsRefused() public {
        uint256 game = _verified();
        vm.warp(START + WINDOW + 1);
        Report memory r = _voidReport(game);
        r.kind = ReportKind.None;
        (bool ok, bytes memory err) = _send(address(first), r);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReportKindNotTaken.selector, ReportKind.None));
        // Control: the same report as a void is taken.
        r.kind = ReportKind.Void;
        _take(address(first), r);
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

    /// Each status names its own reason for refusing a report, rather than one "already scored" for all, for a
    /// start, a score, a void and a dispute record, from a first-n reporter and from an after-n reporter past
    /// start + n and inside the day-7 clock. The status is checked before the reporter's kind, so an after-n
    /// reporter's start on a game whose start is written is refused as written, not as the wrong kind. Every
    /// status is reached through the production paths.
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
        bytes4 noStart = OspexGames.OspexGames__StartNotWritten.selector;
        bytes4[6] memory startByFirst = [taken, written, written, ended, ended, ended];
        bytes4[6] memory startByLater =
            [OspexGames.OspexGames__NotFirstN.selector, written, written, ended, ended, ended];
        // A disputed game takes a score, and a dispute report as an update; its void waits for the day-7 clock.
        bytes4[6] memory scoreByEither = [noStart, taken, taken, ended, ended, ended];
        bytes4[6] memory voidByEither =
            [noStart, taken, OspexGames.OspexGames__InsideDay7Clock.selector, ended, ended, ended];
        bytes4[6] memory disputeByEither = [noStart, taken, taken, ended, ended, ended];

        MockReporter[2] memory who = [first, later];
        for (uint256 w; w < who.length; ++w) {
            for (uint256 i; i < statuses.length; ++i) {
                // One game per report kind, each in the status, each path begun before the date.
                vm.warp(DATE - 1 hours);
                uint256 forStart = _inStatus(statuses[i]);
                vm.warp(DATE - 1 hours);
                uint256 forScore = _inStatus(statuses[i]);
                vm.warp(DATE - 1 hours);
                uint256 forVoid = _inStatus(statuses[i]);
                vm.warp(DATE - 1 hours);
                uint256 forDispute = _inStatus(statuses[i]);
                vm.warp(START + WINDOW + 1);

                (bool ok, bytes memory err) = _send(address(who[w]), _startReport(forStart, START + 1));
                _assertNamed(ok, err, w == 0 ? startByFirst[i] : startByLater[i], forStart, statuses[i], who[w]);
                (ok, err) = _send(address(who[w]), _scoreReport(forScore, HOME, AWAY));
                _assertNamed(ok, err, scoreByEither[i], forScore, statuses[i], who[w]);
                (ok, err) = _send(address(who[w]), _voidReport(forVoid));
                _assertNamed(ok, err, voidByEither[i], forVoid, statuses[i], who[w]);
                // A vote changed since the record a disputed game was set up with, so the report is an update
                // and not a repeat of the record, which would be refused by that name.
                Report memory d = _disputeReport(forDispute);
                d.readings[1].homeScore = HOME + 1;
                (ok, err) = _send(address(who[w]), d);
                _assertNamed(ok, err, disputeByEither[i], forDispute, statuses[i], who[w]);
            }
        }
    }

    /// A reading marked silent carries no score: a feed that did not answer gave none. Refused in a report of
    /// every kind, a start, a score, a void, a dispute record and an update, wherever the reading sits, with
    /// either score set, up to the largest the field holds.
    function test_report_aSilentReadingCarriesNoScore() public {
        uint32[2][3] memory dirt =
            [[uint32(1), uint32(0)], [uint32(0), uint32(1)], [type(uint32).max, type(uint32).max]];
        uint256[3] memory at = [uint256(0), 1, 3];
        for (uint256 k; k < 5; ++k) {
            for (uint256 d; d < dirt.length; ++d) {
                for (uint256 p; p < at.length; ++p) {
                    vm.warp(DATE - 1 hours);
                    uint256 game = _create();
                    Report memory r = _startReport(game, START);
                    if (k != 0) {
                        _startBy(first, game, START);
                        vm.warp(START + 1);
                        if (k == 1) r = _scoreReport(game, HOME, AWAY);
                        else if (k == 2) r = _disputeReport(game);
                        else if (k == 3) {
                            _disputeBy(first, game);
                            r = _disputeReport(game); // an update
                        } else {
                            vm.warp(START + WINDOW);
                            r = _voidReport(game);
                        }
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
        // 0-0 and with scores, and three finals at 0-0, which is the score the control reports, inside n.
        Reading[] memory fine = new Reading[](6);
        fine[0] = Reading({seat: 1, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        fine[1] = Reading({seat: 2, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
        fine[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: type(uint32).max, awayScore: 7});
        fine[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: 0, awayScore: 0});
        fine[4] = Reading({seat: 5, kind: ReadingKind.AnsweredFinal, homeScore: 0, awayScore: 0});
        fine[5] = Reading({seat: 6, kind: ReadingKind.AnsweredFinal, homeScore: 0, awayScore: 0});
        vm.warp(DATE - 1 hours);
        uint256 game2 = _create();
        Report memory start = _startReport(game2, START);
        start.readings = fine;
        _take(address(first), start);
        vm.warp(START + 1);
        Report memory score = _scoreReport(game2, 0, 0);
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
        _assertScoreEvents(game);
    }

    /// @dev The second half of test_report_eventCarriesTheWholeReport: a score's two events, the fee's credit
    ///      first and then the report's.
    function _assertScoreEvents(uint256 game) internal {
        vm.warp(START + 1);
        Report memory s = _scoreReport(game, HOME, AWAY);
        s.payout = address(0xBEE00);
        vm.recordLogs();
        _take(address(second), s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], IOspexGames.FeeCredited.selector);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(0xBEE00)))), "the payout address credited");
        assertEq(abi.decode(logs[0].data, (uint256)), FEE);
        assertEq(logs[1].topics[0], IOspexGames.GameReported.selector);
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(address(second)))), "the reporter that wrote");
        assertEq(uint256(logs[1].topics[3]), uint256(ReportKind.Score));
        (uint64 start, uint32 h, uint32 a, Reading[] memory readings, address pay) =
            abi.decode(logs[1].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(start, 0);
        assertEq(h, HOME);
        assertEq(a, AWAY);
        assertEq(pay, address(0xBEE00));
        _assertReadings(readings, _scoreReadings(HOME, AWAY));
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
            vm.expectRevert(err);
            games.getGameFee(ids[i]);
            vm.expectRevert(err);
            games.getGameDisputedAt(ids[i]);
            vm.expectRevert(err);
            games.getGameIdentity(ids[i]);
            vm.expectRevert(err);
            games.getGameReadings(ids[i]);
            vm.expectRevert(err);
            games.release(ids[i]);
        }
    }

    /// The identity reads back word for word as the creator gave it, at every limit the creation takes: a league
    /// of one and of sixteen characters, teams of one character, of sixty-four and with spaces inside, no hint and
    /// eight hints with ids of sixty-four characters, the date as given; and a later creation or list change moves
    /// none of it.
    function test_reads_identityIsTheCreationsOwnWordForWord() public {
        string memory long = _repeat("abcdefgh", 8); // 64 characters
        Hint[] memory eight = _eightSeats();
        for (uint256 j; j < 8; ++j) {
            eight[j].id = string.concat(_repeat("x", 63), vm.toString(j));
        }
        string[3] memory leagues = ["a", "abcdefghij123456", "nba"];
        string[3] memory homes = ["H", long, "Saint Mary's  (CA)"];
        string[3] memory aways = ["A", "Gonzaga Bulldogs 2026", " x "];
        uint64[3] memory dates = [uint64(1), DATE, uint64(vm.getBlockTimestamp() + 365 days)];
        uint256[3] memory made;
        for (uint256 i; i < 3; ++i) {
            Hint[] memory hints = i == 0 ? new Hint[](0) : i == 1 ? eight : _hints();
            vm.prank(creator, creator);
            made[i] = games.createGame(leagues[i], homes[i], aways[i], dates[i], hints, ANY_FEE);
        }
        _retire(address(later));
        _setTerms("nba", _terms(2 hours));
        _create();
        for (uint256 i; i < 3; ++i) {
            (string memory league, string memory home, string memory away, uint64 date, Hint[] memory hints) =
                games.getGameIdentity(made[i]);
            assertEq(league, leagues[i], "league");
            assertEq(home, homes[i], "home");
            assertEq(away, aways[i], "away");
            assertEq(date, dates[i], "date");
            Hint[] memory want = i == 0 ? new Hint[](0) : i == 1 ? eight : _hints();
            assertEq(hints.length, want.length, "hint count");
            for (uint256 h; h < want.length; ++h) {
                assertEq(hints[h].seat, want[h].seat, "hint seat");
                assertEq(hints[h].id, want[h].id, "hint id");
            }
        }
    }

    /// The readings read empty until written, and then as the report gave them: the start's as given, each
    /// seat's last vote from the dispute reports, the record's time beside them; and they survive the game's end.
    function test_reads_readingsAreEmptyUntilWrittenAndThenAsGiven() public {
        uint256 game = _create();
        (Reading[] memory s0, Reading[] memory v0, uint64 at0) = games.getGameReadings(game);
        assertEq(s0.length, 0, "start readings before the start");
        assertEq(v0.length, 0, "votes before a record");
        assertEq(at0, 0, "the record's time before a record");

        Report memory start = _startReport(game, START);
        start.readings = _readings();
        start.readings[2] = Reading({seat: 9, kind: ReadingKind.AnsweredNoFinal, homeScore: 3, awayScore: 1});
        _take(address(first), start);
        (Reading[] memory s1, Reading[] memory v1, uint64 at1) = games.getGameReadings(game);
        _assertSameReadings(s1, start.readings, "the start's readings");
        assertEq(v1.length, 0, "votes before a record");
        assertEq(at1, 0, "the record's time before a record");

        vm.warp(START + 5);
        _disputeBy(first, game);
        (Reading[] memory s2, Reading[] memory v2, uint64 at2) = games.getGameReadings(game);
        _assertSameReadings(s2, start.readings, "the start's readings after the record");
        Reading[][] memory reports = new Reading[][](1);
        reports[0] = _disputeReadings();
        _assertSameReadings(v2, _foldVotes(reports), "the votes after the record");
        assertEq(at2, START + 5, "the record's time");

        vm.warp(START + 5 + DAY7);
        _voidBy(later, game);
        (Reading[] memory s3, Reading[] memory v3, uint64 at3) = games.getGameReadings(game);
        _assertSameReadings(s3, start.readings, "the start's readings after the end");
        _assertSameReadings(v3, v2, "the votes after the end");
        assertEq(at3, START + 5, "the record's time after the end");
    }

    /// The open list pages: the total beside every page, a page clipped at the end, an empty page past it, the
    /// whole list under the largest count, and the total alone under a count of 0.
    function test_reads_openGamesPagesClipAndCount() public {
        (OpenGame[] memory none, uint256 zero) = games.getOpenGames(0, type(uint256).max);
        assertEq(none.length, 0, "no games yet");
        assertEq(zero, 0, "no games yet: the total");
        uint256[] memory made = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            made[i] = _create();
        }
        (OpenGame[] memory all, uint256 total) = games.getOpenGames(0, type(uint256).max);
        assertEq(_idsOf(all), made, "the whole list, in creation order");
        assertEq(total, 5, "the total");
        (OpenGame[] memory page, uint256 t2) = games.getOpenGames(1, 2);
        assertEq(page.length, 2, "a page of two");
        assertEq(page[0].gameId, made[1], "the page's first");
        assertEq(page[1].gameId, made[2], "the page's second");
        assertEq(t2, 5, "the total beside a page");
        (OpenGame[] memory tail,) = games.getOpenGames(3, 10);
        assertEq(tail.length, 2, "a page clipped at the end");
        assertEq(tail[0].gameId, made[3], "the clipped page's first");
        assertEq(tail[1].gameId, made[4], "the clipped page's second");
        (OpenGame[] memory past, uint256 t3) = games.getOpenGames(5, 1);
        assertEq(past.length, 0, "a page past the end");
        assertEq(t3, 5, "the total past the end");
        (OpenGame[] memory far,) = games.getOpenGames(type(uint256).max, type(uint256).max);
        assertEq(far.length, 0, "a page far past the end");
        (OpenGame[] memory onlyTotal, uint256 t4) = games.getOpenGames(0, 0);
        assertEq(onlyTotal.length, 0, "a count of 0");
        assertEq(t4, 5, "the total under a count of 0");
        (OpenGame[] memory one,) = games.getOpenGames(4, 1);
        assertEq(one.length, 1, "the last alone");
        assertEq(one[0].gameId, made[4], "the last alone");
    }

    /// Each row of the open list is the game's own words: three games, one in a league with other terms and
    /// no hint, one started with the usual two hints, one disputed with eight hints of the longest ids (the
    /// hints stay in the identity read; a row has none). Each field against the read that answers it alone,
    /// then against the literal the test put there, so a row that swaps two of a game's words (the start for
    /// the date, the window for the day-7 clock, the record's time for the start) or leaves one out is caught.
    function test_reads_openGamesRowsAreTheGamesOwnWords() public {
        Terms memory other = _terms(WINDOW + 1 hours);
        other.day7Clock = DAY7 + 1 hours;
        _setTerms("abcdefghijklmnop", other);
        vm.warp(DATE - 1 hours);
        uint256 bare = _createIn("abcdefghijklmnop", new Hint[](0));
        uint256 plain = _create();
        uint256 full = _createIn("nba", _eightHints());
        _startBy(first, plain, START);
        _startBy(first, full, START);
        vm.warp(START + 1);
        _disputeBy(first, full);

        (OpenGame[] memory rows, uint256 total) = games.getOpenGames(0, type(uint256).max);
        assertEq(total, 3, "the total");
        assertEq(rows.length, 3, "three rows");
        for (uint256 i; i < 3; ++i) {
            _assertRowIsTheGame(rows[i], "a row");
        }
        assertEq(rows[0].gameId, bare, "the first row's game");
        assertEq(uint8(rows[0].status), uint8(GameStatus.Unverified), "an unstarted game's status");
        assertEq(rows[0].start, 0, "an unstarted game's start");
        assertEq(rows[0].window, WINDOW + 1 hours, "the other league's window");
        assertEq(rows[0].day7Clock, DAY7 + 1 hours, "the other league's day-7 clock");
        assertEq(rows[0].disputedAt, 0, "no record");
        assertEq(rows[0].league, "abcdefghijklmnop", "the other league");
        assertEq(rows[1].gameId, plain, "the second row's game");
        assertEq(uint8(rows[1].status), uint8(GameStatus.Verified), "a started game's status");
        assertEq(rows[1].start, START, "a started game's start, as written, not its date");
        assertEq(rows[1].window, WINDOW, "the launch window");
        assertEq(rows[1].day7Clock, DAY7, "the launch day-7 clock");
        assertEq(rows[1].disputedAt, 0, "no record yet");
        assertEq(rows[1].league, "nba", "the league");
        assertEq(rows[2].gameId, full, "the third row's game");
        assertEq(uint8(rows[2].status), uint8(GameStatus.Disputed), "a disputed game's status");
        assertEq(rows[2].start, START, "a disputed game's start");
        assertEq(rows[2].disputedAt, START + 1, "the record's time");
        assertEq(rows[2].league, "nba", "the league of the game with eight hints");
    }

    /// A row encodes to 320 bytes whatever the game, measured on the call's return data: its league is one to
    /// sixteen bytes, one word, and its hints stay in the identity read; the answer's own words are 96 bytes.
    /// So a reader that may take 25,000 bytes asks 77 rows a page (24,736 bytes); 78 rows are 25,056.
    function test_reads_openGamesPageBytesAreBoundedByTheRows() public {
        _setTerms("a", _terms(WINDOW));
        _setTerms("abcdefghijklmnop", _terms(WINDOW));
        vm.warp(DATE - 1 hours);
        _createIn("a", new Hint[](0));
        _createIn("abcdefghijklmnop", _eightHints());
        assertEq(_answerBytes(0, 1), 96 + 320, "a row with a league of one byte and no hint");
        assertEq(_answerBytes(1, 1), 96 + 320, "a row with a league of sixteen bytes and eight hints");
        for (uint256 i; i < 76; ++i) {
            _create();
        }
        assertEq(_answerBytes(0, 77), 96 + 77 * 320, "seventy-seven rows");
        assertEq(_answerBytes(0, 78), 96 + 78 * 320, "seventy-eight rows");
        assertEq(_answerBytes(78, 1), 96, "an empty page: the answer's own words");
    }

    /// @dev The length of the open list read's return data for a page.
    function _answerBytes(uint256 offset, uint256 count) internal view returns (uint256) {
        (bool ok, bytes memory answer) =
            address(games).staticcall(abi.encodeCall(IOspexGames.getOpenGames, (offset, count)));
        assertTrue(ok, "the read");
        return answer.length;
    }

    /// @dev A creation in `league` with `hints`, the usual teams and date, at the league's fee.
    function _createIn(string memory league, Hint[] memory hints) internal returns (uint256 gameId) {
        uint256 fee = games.getTerms(league).fee;
        vm.prank(creator, creator);
        gameId = games.createGame(league, "Denver Nuggets", "Utah Jazz", DATE, hints, fee);
    }

    /// @dev Eight hints, each with an id of 64 characters: the most a creation may give.
    function _eightHints() internal pure returns (Hint[] memory hints) {
        hints = new Hint[](8);
        for (uint256 i; i < 8; ++i) {
            hints[i] = Hint({
                seat: uint8(i + 1),
                id: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            });
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
    /// The one end a game with no start can reach is the release, once the day-30 clock has run from the date
    /// given at creation. Such a game reads Released, refuses its start and its scores by name, and takes nothing
    /// more: no report of any kind, and no second release. Its reads are the same before the release.
    /// Break: in getGameStart(), change `if (g.start == 0)` to `if (g.status == GameStatus.Unverified)`. The
    /// released game then reads a start of 0 as if one were written.
    function test_reads_startRefusedForAGameThatEndedWithoutOne() public {
        uint256 game = _create();
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
        games.getGameStart(game);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, GameStatus.Unverified));
        games.getGameScores(game);

        vm.warp(DATE + DAY30);
        _releaseBy(stranger, game);
        assertEq(uint8(_status(game)), uint8(GameStatus.Released), "status");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
        games.getGameStart(game);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, GameStatus.Released));
        games.getGameScores(game);
        // Nothing more is written: every report kind from every reporter, and a second release, are refused.
        bytes memory ended = abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, GameStatus.Released);
        MockReporter[3] memory reporters = [first, later, second];
        for (uint256 i; i < reporters.length; ++i) {
            Report[4] memory reports =
                [_startReport(game, START), _scoreReport(game, HOME, AWAY), _voidReport(game), _disputeReport(game)];
            for (uint256 k; k < reports.length; ++k) {
                (bool ok, bytes memory err) = _send(address(reporters[i]), reports[k]);
                assertFalse(ok, "a released game took a report");
                assertEq(err, ended, "the refusal");
            }
        }
        (bool okAgain, bytes memory errAgain) = _tryRelease(stranger, game);
        assertFalse(okAgain, "a released game was released again");
        assertEq(errAgain, ended, "the second release's refusal");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
        games.getGameStart(game);

        // Controls: a written start reads back in every status a game with a start can reach.
        GameStatus[5] memory started =
            [GameStatus.Verified, GameStatus.Disputed, GameStatus.Scored, GameStatus.Voided, GameStatus.Released];
        for (uint256 i; i < started.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 g = _inStatus(started[i]);
            assertEq(uint8(_status(g)), uint8(started[i]), "control status");
            assertEq(games.getGameStart(g), START, "a written start did not read back");
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
        uint256 other = _create(); // second on the open list, until the first game's end moves it first
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + 1);
        _disputeBy(first, game);
        // Word 3 while the game is open: the creator, the time of the dispute record, and its place on the open
        // list plus one.
        uint256 word3 = uint256(uint160(creator)) | (uint256(START + 1) << 160);
        assertEq(uint256(vm.load(address(games), bytes32(_slotOf(game) + 3))), word3 | (uint256(1) << 224), "word 3, open");
        assertEq(uint256(vm.load(address(games), bytes32(_slotOf(other) + 3))), uint256(uint160(creator)) | (uint256(2) << 224), "word 3 of the second game");
        vm.warp(START + 2);
        _scoreBy(first, game, HOME, AWAY);

        // Word 0: status, date, start, home, away. Word 1: n and the two clocks. Word 2: the fee. Word 3: the
        // creator, the time of the dispute record, and the place on the open list, 0 once ended.
        bytes memory want = abi.encodePacked(
            uint256(uint8(GameStatus.Scored)) | (uint256(DATE) << 8) | (uint256(START) << 72)
                | (uint256(HOME) << 136) | (uint256(AWAY) << 168),
            uint256(own.window) | (uint256(own.day7Clock) << 64) | (uint256(own.day30Clock) << 128),
            uint256(own.fee)
        );
        want = abi.encodePacked(want, word3);
        // Then the reporters' copy: its length, and each entry as address and kind.
        uint256 firstKind = uint256(uint8(ReporterKind.FirstN)) << 160;
        want = abi.encodePacked(want, uint256(3), uint256(uint160(address(first))) | firstKind);
        want = abi.encodePacked(want, uint256(uint160(address(later))) | (uint256(uint8(ReporterKind.AfterN)) << 160));
        want = abi.encodePacked(want, uint256(uint160(address(second))) | firstKind);
        assertEq(_rawGame(game), want, "a game's storage");
        assertEq(_rawDate(game), DATE, "a game's date");
        // The end moved the second game into the first's place, and the helper reads the place where it lies.
        assertEq(GameWords.openPlace(address(games), other), 1, "the second game's place after the first's end");
        assertEq(GameWords.openPlace(address(games), game), 0, "an ended game's place");
    }

    /// @dev The first word of a game's storage.
    function _slotOf(uint256 gameId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(gameId, GameWords.GAMES_SLOT)));
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
            (string memory league,,,,) = games.getGameIdentity(game);
            assertEq(league, "nba");
            (Reading[] memory startReadings,,) = games.getGameReadings(game);
            assertEq(startReadings.length, 4);
            (, uint256 total) = games.getOpenGames(0, 0);
            assertEq(total, 0);
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

    /// @dev Asserts a report was taken (want 0) or refused with the named error and its arguments.
    function _assertNamed(bool ok, bytes memory err, bytes4 want, uint256 game, GameStatus s, MockReporter who)
        internal
        view
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
        } else if (want == OspexGames.OspexGames__InsideDay7Clock.selector) {
            uint256 opensAt = uint256(games.getGameDisputedAt(game)) + games.getGameTerms(game).day7Clock;
            expected = abi.encodeWithSelector(want, game, opensAt);
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

    /// @dev The log is the coin's transfer of `amount` from `from` to the games set.
    function _assertFeePaid(Vm.Log memory l, address from, uint256 amount) internal view {
        assertEq(l.emitter, address(token));
        assertEq(l.topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(l.topics[1], bytes32(uint256(uint160(from))), "paid by the creator");
        assertEq(l.topics[2], bytes32(uint256(uint160(address(games)))), "paid to the games set");
        assertEq(abi.decode(l.data, (uint256)), amount, "the league's own fee");
    }

    /// @dev The constructor's arguments, ABI-encoded by hand, with one reporter of any kind number: for a kind
    ///      the enum cannot hold, which no typed call can pass.
    function _ctorArgs(address reporter, uint8 kind) internal view returns (bytes memory) {
        Terms memory terms = _launchTerms();
        address[] memory list = _one(reporter);
        uint8[] memory kinds = _uint8s1(kind);
        bytes32[] memory hashes = _hashes(list);
        return abi.encode(address(timelock), address(token), terms, list, kinds, hashes);
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
