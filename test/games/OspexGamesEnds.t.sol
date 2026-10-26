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
import {GamesBase, MockReporter} from "./GamesBase.sol";

/// @dev A contract with code and nothing else, to release from.
contract Anyone {
    function release(IOspexGames games, uint256 gameId) external {
        games.release(gameId);
    }
}

/// @notice How a game ends: the void, the dispute record and its updates, and the release, each at the edges of
///         its clock, by both kinds of reporter, with its events and reads; and the readings the games set takes
///         behind a score and a void. The never-lines are in OspexGamesNeverLines.t.sol; this file sweeps the
///         edges and the shapes.
contract OspexGamesEndsTest is GamesBase {
    // ──────────────────────────── The void ─────────────────────────────

    /// A void's two events: the credit to the payout address, then the report, naming the reporter that wrote it,
    /// the void's kind, no start, no score, its readings and its payout. The game reads Voided, holds nothing,
    /// and the payout address withdraws the fee.
    function test_void_emitsTheCreditThenTheReport() public {
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + WINDOW);
        Report memory r = _voidReportTo(game, address(0xBEE00));
        vm.recordLogs();
        _take(address(later), r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the report");
        assertEq(logs[0].topics[0], IOspexGames.FeeCredited.selector);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(0xBEE00)))), "the payout address credited");
        assertEq(abi.decode(logs[0].data, (uint256)), FEE);
        assertEq(logs[1].topics[0], IOspexGames.GameReported.selector);
        assertEq(uint256(logs[1].topics[1]), game);
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(address(later)))), "the reporter that wrote");
        assertEq(uint256(logs[1].topics[3]), uint256(ReportKind.Void));
        (uint64 start, uint32 h, uint32 a, Reading[] memory readings, address pay) =
            abi.decode(logs[1].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(uint256(start) + h + a, 0, "a void carries no start and no score");
        assertEq(abi.encode(readings), abi.encode(_voidReadings()), "the readings as given");
        assertEq(pay, address(0xBEE00));
        assertEq(uint8(_status(game)), uint8(GameStatus.Voided));
        assertEq(_held(game), 0, "a voided game holds nothing");
        vm.prank(address(0xBEE00));
        assertEq(games.withdraw(), FEE, "the payout address withdraws");
    }

    /// A void's refusals name its first fault in one order: the game's status, a start or score field set, the
    /// payout address, its readings, then the clocks (the day-30 clock first, then n, then the day-7 clock). A
    /// void naming the games set as its payout is refused for the payout inside n, on a game with a dispute
    /// record and on one without, inside the day-7 clock, and at the day-30 clock. A void over three finals that
    /// agree, with a good payout, is refused for its readings inside n, before n's name. The same void naming a
    /// good payout over a void's readings is refused by the clock: inside n by n's name on both games, past n on
    /// the disputed game by the day-7 clock's, and at the day-30 clock by that clock's.
    function test_void_namesAPayoutFaultBeforeTheClocks() public {
        vm.warp(DATE - 1 hours);
        uint256 plain = _create();
        uint256 disputed = _create();
        uint256 late = _create();
        _startBy(first, plain, START);
        _startBy(first, disputed, START);
        _startBy(first, late, START);
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        bytes memory payoutFault =
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Void);
        bytes memory insideN = abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, plain, uint256(START) + WINDOW);
        bytes memory insideNDisputed =
            abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, disputed, uint256(START) + WINDOW);
        bytes memory insideDay7 =
            abi.encodeWithSelector(OspexGames.OspexGames__InsideDay7Clock.selector, disputed, uint256(START) + 1 + DAY7);
        bytes memory agree = abi.encodeWithSelector(OspexGames.OspexGames__FinalsAgree.selector, HOME, AWAY);

        vm.warp(START + 2);
        (bool ok, bytes memory err) = _send(address(first), _voidReportTo(plain, address(games)));
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before n");
        (ok, err) = _send(address(first), _voidReportTo(disputed, address(games)));
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before n, disputed game");
        Report memory overFinals = _voidReportTo(plain, address(games));
        overFinals.readings = _scoreReadings(HOME, AWAY);
        (ok, err) = _send(address(first), overFinals);
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before the readings");
        overFinals.payout = payout;
        (ok, err) = _send(address(first), overFinals);
        assertFalse(ok);
        assertEq(err, agree, "the readings fault is named before n");
        (ok, err) = _send(address(first), _voidReport(plain));
        assertFalse(ok);
        assertEq(err, insideN, "control: a good payout, inside n");
        (ok, err) = _send(address(first), _voidReport(disputed));
        assertFalse(ok);
        assertEq(err, insideNDisputed, "control: inside n a disputed game names n, not the day-7 clock");

        vm.warp(START + WINDOW);
        (ok, err) = _send(address(later), _voidReportTo(disputed, address(games)));
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before the day-7 clock");
        (ok, err) = _send(address(later), _voidReport(disputed));
        assertFalse(ok);
        assertEq(err, insideDay7, "control: a good payout, inside the day-7 clock");
        _take(address(later), _voidReport(plain));

        vm.warp(DATE + DAY30);
        (ok, err) = _send(address(later), _voidReportTo(late, address(games)));
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before the day-30 clock");
        (ok, err) = _send(address(later), _voidReport(late));
        assertFalse(ok);
        assertEq(err, _pastDay30(late), "control: a good payout, at the day-30 clock");
    }

    /// On a disputed game the void opens at the record plus the game's own day-7 clock: a league's own clock
    /// (two days) and the default (seven), each refused a second before and taken at it, by either kind; a change
    /// to the league's clock after the game was made does not move it.
    function test_void_onADisputedGameOpensAtTheRecordPlusTheGamesOwnClock() public {
        _setTerms("nhl", _clockTerms(2 days, 20 days));
        vm.warp(DATE - 1 hours);
        uint256 nba = _create(); // the default clocks
        vm.startPrank(creator, creator);
        uint256 nhl = games.createGame("nhl", "Home", "Away", DATE, _hints(), ANY_FEE);
        uint256 nhl2 = games.createGame("nhl", "Home", "Away", DATE, _hints(), ANY_FEE);
        vm.stopPrank();
        _startBy(first, nba, START);
        _startBy(first, nhl, START);
        _startBy(first, nhl2, START);
        vm.warp(START + 5);
        _disputeBy(first, nba);
        _disputeBy(first, nhl);
        _disputeBy(first, nhl2);
        _setTerms("nhl", _clockTerms(10 days, 20 days)); // after the games were made: reaches none of them

        uint256[3] memory ids = [nba, nhl, nhl2];
        uint64[3] memory clocks = [DAY7, 2 days, 2 days];
        MockReporter[3] memory voiders = [first, later, second];
        for (uint256 i; i < ids.length; ++i) {
            uint256 opensAt = uint256(START) + 5 + clocks[i];
            assertEq(games.getGameTerms(ids[i]).day7Clock, clocks[i], "the game's own clock");
            vm.warp(opensAt - 1);
            (bool ok, bytes memory err) = _send(address(voiders[i]), _voidReport(ids[i]));
            assertFalse(ok, "the day-7 void opened a second early");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__InsideDay7Clock.selector, ids[i], opensAt));
            vm.warp(opensAt);
            _take(address(voiders[i]), _voidReport(ids[i]));
            assertEq(uint8(_status(ids[i])), uint8(GameStatus.Voided), "the day-7 void");
        }
    }

    // ──────────────────────────── The dispute record ───────────────────

    /// The record's one event names the reporter, the kind, no start, no score, its readings and no payout. The
    /// game reads Disputed and the record's time; before the record that read is refused by name; after the
    /// game ends the record's time still reads. The record is written once: an update changes nothing.
    function test_dispute_recordWritesDisputedAndItsTimeOnce() public {
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotDisputed.selector, game));
        games.getGameDisputedAt(game);
        vm.warp(START + 90 minutes);
        vm.recordLogs();
        _take(address(second), _disputeReport(game));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the report alone: nothing credited");
        assertEq(logs[0].topics[0], IOspexGames.GameReported.selector);
        assertEq(uint256(logs[0].topics[1]), game);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(second)))), "the reporter that wrote");
        assertEq(uint256(logs[0].topics[3]), uint256(ReportKind.Dispute));
        (uint64 start, uint32 h, uint32 a, Reading[] memory readings, address pay) =
            abi.decode(logs[0].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(uint256(start) + h + a, 0, "a dispute record carries no start and no score");
        assertEq(abi.encode(readings), abi.encode(_disputeReadings()), "the readings as given");
        assertEq(pay, address(0), "a dispute record names no payout");
        assertEq(uint8(_status(game)), uint8(GameStatus.Disputed));
        assertEq(games.getGameDisputedAt(game), START + 90 minutes, "the record's time");
        assertEq(_held(game), FEE, "a disputed game holds its fee");

        vm.warp(START + 3 hours);
        _take(address(first), _disputeReport(game));
        assertEq(games.getGameDisputedAt(game), START + 90 minutes, "an update moved the record's time");
        vm.warp(START + 4 hours);
        _take(address(first), _scoreReportTo(game, payout));
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored));
        assertEq(games.getGameDisputedAt(game), START + 90 minutes, "the record is history after the end");
    }

    /// A first-n reporter's record is taken from the start, that second included, and refused before it; an
    /// after-n reporter's from start + n. A game with no start takes none.
    function test_dispute_byEitherKindAtItsHour() public {
        vm.warp(DATE - 1 hours);
        uint256 unstarted = _create();
        uint256 game = _create();
        uint256 other = _create();
        _startBy(first, game, START);
        _startBy(first, other, START);
        MockReporter[2] memory kinds = [first, later];
        for (uint256 w; w < kinds.length; ++w) {
            (bool ok, bytes memory err) = _send(address(kinds[w]), _disputeReport(unstarted));
            assertFalse(ok, "a game with no start took a dispute record");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, unstarted));
            vm.warp(START - 1);
            (ok, err) = _send(address(kinds[w]), _disputeReport(game));
            assertFalse(ok, "a dispute record before the start was taken");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, game, START));
        }
        vm.warp(START);
        _take(address(first), _disputeReport(game));
        assertEq(games.getGameDisputedAt(game), START, "a first-n reporter's record at the start");
        (bool okLater, bytes memory errLater) = _send(address(later), _disputeReport(other));
        assertFalse(okLater, "an after-n reporter's record at the start was taken");
        assertEq(
            errLater, abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, other, uint256(START) + WINDOW)
        );
        vm.warp(START + WINDOW);
        _take(address(later), _disputeReport(other));
        assertEq(games.getGameDisputedAt(other), START + WINDOW, "an after-n reporter's record at start + n");
    }

    // ──────────────────────────── The release ──────────────────────────

    /// The day-30 clock counts from the date given at creation, for a game with no start, one whose start was
    /// written after its date and one whose start was written a day before it alike: a second before, refused by
    /// name with the second it opens at; at it, taken. The clock is the game's own copied term: a league's own
    /// day-30 clock holds for its game, and a change after the game was made moves nothing. A start written in
    /// the last second before the clock moves it no more than an early one: the release opens at the date's
    /// clock. A start at the clock is refused, and the release is the door.
    function test_release_opensAtTheDay30ClockFromTheDate() public {
        _setTerms("nhl", _clockTerms(3 days, 10 days));
        vm.warp(DATE - 2 days);
        uint256 noStart = _create();
        uint256 lateStart = _create();
        uint256 earlyStart = _create();
        vm.prank(creator, creator);
        uint256 nhl = games.createGame("nhl", "Home", "Away", DATE, _hints(), ANY_FEE);
        _startBy(first, lateStart, DATE + DAY); // the far end of the start bound, after the date
        _startBy(first, earlyStart, DATE - DAY); // the far end before it
        _setTerms("nhl", _clockTerms(3 days, 300 days)); // after the game was made: reaches none

        uint256[4] memory ids = [noStart, lateStart, earlyStart, nhl];
        uint256[4] memory opensAt =
            [uint256(DATE) + DAY30, uint256(DATE) + DAY30, uint256(DATE) + DAY30, uint256(DATE) + 10 days];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(_day30(ids[i]), opensAt[i], "the game's own clock, from its date");
            vm.warp(opensAt[i] - 1);
            (bool ok, bytes memory err) = _tryRelease(stranger, ids[i]);
            assertFalse(ok, "the release opened a second early");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, ids[i], opensAt[i]));
            vm.warp(opensAt[i]);
            _releaseBy(stranger, ids[i]);
            assertEq(uint8(_status(ids[i])), uint8(GameStatus.Released), "released at its clock");
        }
        assertEq(games.getCredit(creator), 4 * uint256(FEE), "each release credited the creator");

        // A start written a second before the clock, at the far end of its bound, moves the release nowhere.
        vm.warp(DATE - 1 hours);
        uint256 lateWritten = _create();
        uint256 atTheClock = _create();
        vm.warp(DATE + DAY30 - 1);
        _startBy(first, lateWritten, DATE + DAY);
        (bool okEarly, bytes memory errEarly) = _tryRelease(stranger, lateWritten);
        assertFalse(okEarly, "the release opened before the date's clock");
        assertEq(
            errEarly, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, lateWritten, uint256(DATE) + DAY30)
        );
        vm.warp(DATE + DAY30);
        _releaseBy(stranger, lateWritten);
        assertEq(uint8(_status(lateWritten)), uint8(GameStatus.Released), "released at the date's clock");
        // At the clock a start is refused by name, and the release is taken.
        (bool okStart, bytes memory errStart) = _send(address(first), _startReport(atTheClock, START));
        assertFalse(okStart, "a start at the day-30 clock was taken");
        assertEq(errStart, _pastDay30(atTheClock));
        _releaseBy(creator, atTheClock);
        assertEq(uint8(_status(atTheClock)), uint8(GameStatus.Released), "the release is the only door");
        assertEq(games.getCredit(creator), 6 * uint256(FEE), "each release credited the creator");
    }

    /// A release's two events: the credit to the creator, then the release naming the game and the caller. At a
    /// fee of 0 the release alone. Anyone calls it: a stranger, the creator, a contract, the timelock's key.
    function test_release_emitsTheCreditThenTheReleaseAndIsAnyones() public {
        vm.warp(DATE - 1 hours);
        uint256 a = _create();
        uint256 b = _create();
        uint256 c = _create();
        _setTerms("", _feeTerms(0));
        uint256 free = _create();
        Anyone anyone = new Anyone();
        vm.warp(DATE + DAY30);

        vm.recordLogs();
        _releaseBy(stranger, a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the release");
        assertEq(logs[0].topics[0], IOspexGames.FeeCredited.selector);
        assertEq(uint256(logs[0].topics[1]), a);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(creator))), "the creator credited");
        assertEq(abi.decode(logs[0].data, (uint256)), FEE);
        assertEq(logs[1].topics[0], IOspexGames.GameReleased.selector);
        assertEq(uint256(logs[1].topics[1]), a);
        assertEq(abi.decode(logs[1].data, (address)), stranger, "the caller");

        anyone.release(games, b);
        assertEq(uint8(_status(b)), uint8(GameStatus.Released), "a contract released");
        _releaseBy(timelockKey, c);
        assertEq(uint8(_status(c)), uint8(GameStatus.Released), "the key released, as anyone");

        vm.recordLogs();
        _releaseBy(creator, free);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "at a fee of 0, the release alone");
        assertEq(logs[0].topics[0], IOspexGames.GameReleased.selector);
        assertEq(abi.decode(logs[0].data, (address)), creator);
        assertEq(games.getCredit(creator), 3 * uint256(FEE), "three fees, nothing for the free game");
        assertEq(games.getCredit(stranger) + games.getCredit(address(anyone)) + games.getCredit(timelockKey), 0);
    }

    /// The release before the clock opens when no reporter left could write to the game. A game whose start is
    /// not written: with one first-n reporter live it waits; with every first-n reporter retired and the after-n
    /// one live it reads as every reporter retired, since an after-n reporter writes no start, and anyone
    /// releases it at once. A game whose start is written, under the same retirements: the after-n reporter
    /// could still write it, so it waits for the date's clock, and opens when that reporter retires too.
    function test_release_opensWhenNoReporterLeftCouldWrite() public {
        vm.warp(DATE - 1 hours);
        uint256 unstarted = _create();
        uint256 started = _create();
        _startBy(first, started, START);
        _retire(address(first));
        assertFalse(games.isEveryReporterRetired(unstarted), "a first-n reporter is live");
        (bool okOne, bytes memory errOne) = _tryRelease(stranger, unstarted);
        assertFalse(okOne, "the release opened with a first-n reporter live");
        assertEq(errOne, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, unstarted, uint256(DATE) + DAY30));

        vm.warp(START + 2 days);
        _retire(address(second));
        (bool okStart, bytes memory errStart) = _send(address(later), _startReport(unstarted, START));
        assertFalse(okStart, "an after-n reporter wrote a start");
        assertEq(errStart, abi.encodeWithSelector(OspexGames.OspexGames__NotFirstN.selector, unstarted, address(later)));
        assertTrue(games.isEveryReporterRetired(unstarted), "no reporter left could write the unstarted game");
        assertFalse(games.isEveryReporterRetired(started), "the after-n reporter can still write the started game");
        (bool ok, bytes memory err) = _tryRelease(stranger, started);
        assertFalse(ok, "the started game's release opened while its after-n reporter was live");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, started, uint256(DATE) + DAY30));
        vm.recordLogs();
        _releaseBy(stranger, unstarted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the release");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(creator))), "the creator credited");
        assertEq(uint8(_status(unstarted)), uint8(GameStatus.Released), "released at once");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, unstarted));
        games.getGameStart(unstarted);

        _take(address(later), _scoreReportTo(started, payout)); // the live reporter still writes
        assertEq(uint8(_status(started)), uint8(GameStatus.Scored), "the after-n reporter scored");
    }

    // ──────────────────────────── The status machine ───────────────────

    /// From every status, every call a game can take (a start, a score, a void, a dispute record, a release),
    /// from a first-n reporter and from an after-n one, at an hour the day-7 clock has run and at the day-30
    /// clock: the status never moves back, a refused call leaves it, an ended game takes nothing, and a credit is
    /// emitted exactly when the call moves the game into an end from an open status. At the day-30 clock only
    /// the release lands. Which calls each status takes is test_report_refusalNamesByStatus's.
    function test_status_neverMovesBackAndACreditMeansAnEnd() public {
        GameStatus[6] memory statuses = [
            GameStatus.Unverified,
            GameStatus.Verified,
            GameStatus.Disputed,
            GameStatus.Scored,
            GameStatus.Voided,
            GameStatus.Released
        ];
        MockReporter[2] memory kinds = [first, later];
        uint64[2] memory hours_ = [START + 1 + DAY7, DATE + DAY30];
        for (uint256 h; h < hours_.length; ++h) {
            for (uint256 s; s < statuses.length; ++s) {
                for (uint256 w; w < kinds.length; ++w) {
                    for (uint256 action; action < 5; ++action) {
                        vm.warp(DATE - 1 hours);
                        uint256 game = _inStatus(statuses[s]);
                        vm.warp(hours_[h]);
                        GameStatus before = _status(game);
                        assertEq(uint8(before), uint8(statuses[s]), "the status reached");
                        vm.recordLogs();
                        bool ok;
                        if (action == 0) (ok,) = _send(address(kinds[w]), _startReport(game, START));
                        else if (action == 1) (ok,) = _send(address(kinds[w]), _scoreReport(game, HOME, AWAY));
                        else if (action == 2) (ok,) = _send(address(kinds[w]), _voidReport(game));
                        else if (action == 3) (ok,) = _send(address(kinds[w]), _disputeReport(game));
                        else (ok,) = _tryRelease(stranger, game);
                        Vm.Log[] memory logs = vm.getRecordedLogs();
                        GameStatus next = _status(game);
                        assertGe(uint8(next), uint8(before), "the status moved back");
                        bool ended = next >= GameStatus.Scored && before < GameStatus.Scored;
                        uint256 credits;
                        for (uint256 l; l < logs.length; ++l) {
                            if (logs[l].topics[0] == IOspexGames.FeeCredited.selector) ++credits;
                        }
                        assertEq(credits, ended ? 1 : 0, "a credit without an end, or an end without a credit");
                        if (!ok) assertEq(uint8(next), uint8(before), "a refused call moved the status");
                        if (before >= GameStatus.Scored) assertFalse(ok, "an ended game took a call");
                        if (h == 1 && action != 4) assertFalse(ok, "a report landed at the day-30 clock");
                        if (h == 1 && action == 4 && before < GameStatus.Scored) assertTrue(ok, "the release did not land");
                    }
                }
            }
        }
    }

    /// A disputed game takes a score at every hour a reporter may write: inside n from a first-n reporter, at
    /// start + n from an after-n one, before the day-7 clock has run and after, and in the last second before
    /// the day-30 clock. At that clock the score is refused by name, and the release is the door.
    function test_score_onADisputedGameAtEveryHour() public {
        uint64[4] memory times = [START + 2, START + WINDOW, START + 1 + DAY7, DATE + DAY30 - 1];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(DATE - 1 hours);
            uint256 game = _inStatus(GameStatus.Disputed);
            vm.warp(times[t]);
            MockReporter who = t == 0 ? first : later;
            vm.recordLogs();
            _take(address(who), _scoreReportTo(game, payout));
            assertEq(uint8(_status(game)), uint8(GameStatus.Scored), "a disputed game scored");
            (uint32 h, uint32 a) = games.getGameScores(game);
            assertEq(h, HOME);
            assertEq(a, AWAY);
            assertEq(games.getGameDisputedAt(game), START + 1, "the record stays as history");
        }
        assertEq(games.getCredit(payout), 4 * uint256(FEE), "each score credited once");
        vm.warp(DATE - 1 hours);
        uint256 late = _inStatus(GameStatus.Disputed);
        vm.warp(DATE + DAY30);
        (bool ok, bytes memory err) = _send(address(later), _scoreReportTo(late, payout));
        assertFalse(ok, "a score at the day-30 clock was taken");
        assertEq(err, _pastDay30(late));
        _releaseBy(stranger, late);
        assertEq(uint8(_status(late)), uint8(GameStatus.Released), "the release is the only door");
    }

    // ──────────────────────────── The readings ─────────────────────────

    /// The accepted shape the ruling names: an hour-24 void whose readings are one final and three silents is
    /// taken, since one feed alone is not agreement; two finals that agree beside two silents are not either.
    /// Its readings ride in the event as given.
    function test_readings_anHour24VoidOverOneFinalAndThreeSilentsIsTaken() public {
        vm.warp(DATE - 1 hours);
        uint256 oneFinal = _create();
        uint256 twoFinals = _create();
        _startBy(first, oneFinal, START);
        _startBy(first, twoFinals, START);
        vm.warp(START + WINDOW);
        Report memory r = _voidReportTo(oneFinal, payout);
        r.readings = _silents(4);
        r.readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        vm.recordLogs();
        _take(address(later), r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the report");
        (,,, Reading[] memory readings,) = abi.decode(logs[1].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(abi.encode(readings), abi.encode(r.readings), "the readings as given");
        assertEq(uint8(_status(oneFinal)), uint8(GameStatus.Voided), "voided over one final");

        Report memory two = _voidReportTo(twoFinals, payout);
        two.readings = _silents(4);
        two.readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        two.readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        _take(address(first), two);
        assertEq(uint8(_status(twoFinals)), uint8(GameStatus.Voided), "voided over two finals that agree");
        assertEq(games.getCredit(payout), 2 * uint256(FEE), "each void credited once");
    }

    /// The accepted shape the ruling names: a day-7 score carrying a dissent, three finals reading the score and
    /// one reading otherwise, is taken at the day-7 clock, the majority rule, and refused a second before it by
    /// the dissent's name, with the dissenting reading's index. The same score with every final agreeing is taken
    /// before the clock.
    function test_readings_aDay7ScoreCarryingADissentIsTaken() public {
        vm.warp(DATE - 1 hours);
        uint256 game = _create();
        uint256 agreed = _create();
        _startBy(first, game, START);
        _startBy(first, agreed, START);
        vm.warp(START + 1);
        _disputeBy(first, game);
        _disputeBy(first, agreed);
        Report memory r = _scoreReportTo(game, payout);
        r.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});

        vm.warp(START + 1 + DAY7 - 1);
        (bool ok, bytes memory err) = _send(address(later), r);
        assertFalse(ok, "a disputed game's score carrying a dissent was taken before the day-7 clock");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FinalDissents.selector, 3));
        _take(address(later), _scoreReportTo(agreed, payout)); // three finals agree, the spare silent: taken
        assertEq(uint8(_status(agreed)), uint8(GameStatus.Scored), "agreement settles before the clock");
        vm.warp(START + 1 + DAY7);
        vm.recordLogs();
        _take(address(later), r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the report");
        (,,, Reading[] memory readings,) = abi.decode(logs[1].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(abi.encode(readings), abi.encode(r.readings), "the readings as given, the dissent included");
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored), "the day-7 settlement");
        (uint32 h, uint32 a) = games.getGameScores(game);
        assertEq(h, HOME);
        assertEq(a, AWAY);
    }

    /// Four of the shapes the scoring program sends, named: inside n a score on three counting finals beside a
    /// spare that answered without a final; after n a score on two counting finals, the third silent, the spare
    /// without a final; an update whose finals all agree beside a silent fourth, since a dispute report's
    /// readings are read for shape alone; and a disputed game's score before day 7 on three agreeing finals
    /// beside a silent spare. The whole file of them runs in OspexGamesShapes.t.sol.
    function test_readings_theProgramsShapesAreTaken() public {
        vm.warp(DATE - 1 hours);
        uint256 inside = _create();
        uint256 afterN = _create();
        uint256 updated = _create();
        uint256 disputed = _create();
        _startBy(first, inside, START);
        _startBy(first, afterN, START);
        _startBy(first, updated, START);
        _startBy(first, disputed, START);

        vm.warp(START + 1);
        Report memory s = _scoreReportTo(inside, payout);
        s.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredNoFinal, homeScore: 50, awayScore: 40});
        _take(address(first), s);
        _disputeBy(first, updated); // the record: two finals that differ
        Report memory update = _disputeReport(updated);
        update.readings = _scoreReadings(HOME, AWAY); // every final agrees: an update, read for shape only
        _take(address(first), update);
        _disputeBy(first, disputed);
        Report memory settled = _scoreReportTo(disputed, payout);
        _take(address(second), settled); // three agreeing finals, the spare silent, inside n and before day 7

        vm.warp(START + WINDOW);
        Report memory two = _scoreReportTo(afterN, payout);
        two.readings[2] = Reading({seat: 3, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        two.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
        _take(address(later), two);

        assertEq(uint8(_status(inside)), uint8(GameStatus.Scored), "inside n");
        assertEq(uint8(_status(afterN)), uint8(GameStatus.Scored), "after n");
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Scored), "a disputed game on agreement");
        assertEq(uint8(_status(updated)), uint8(GameStatus.Disputed), "an update writes nothing");
        assertEq(games.getGameDisputedAt(updated), START + 1, "an update moves no clock");
        assertEq(games.getCredit(payout), 3 * uint256(FEE), "each end credited once");
    }

    /// @dev `count` silent readings at 0-0, seats 1 to `count`.
    function _silents(uint256 count) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](count);
        for (uint256 i; i < count; ++i) {
            readings[i] = Reading({seat: uint8(i + 1), kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        }
    }
}
