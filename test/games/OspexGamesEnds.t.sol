// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
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
///         its clock, by both kinds of reporter, with its events and reads. The never-lines are in
///         OspexGamesNeverLines.t.sol; this file sweeps the edges and the shapes.
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
    /// payout address, then the clocks. A void naming the games set as its payout is refused for the payout
    /// inside n, on a game with a dispute record and on one without, and inside the day-7 clock. The same void
    /// naming a good payout is refused by the clock: inside n by n's name on both games, and past n on the
    /// disputed game by the day-7 clock's.
    function test_void_namesAPayoutFaultBeforeTheClocks() public {
        vm.warp(DATE - 1 hours);
        uint256 plain = _create();
        uint256 disputed = _create();
        _startBy(first, plain, START);
        _startBy(first, disputed, START);
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        bytes memory payoutFault =
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Void);
        bytes memory insideN = abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, plain, uint256(START) + WINDOW);
        bytes memory insideNDisputed =
            abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, disputed, uint256(START) + WINDOW);
        bytes memory insideDay7 =
            abi.encodeWithSelector(OspexGames.OspexGames__InsideDay7Clock.selector, disputed, uint256(START) + 1 + DAY7);

        vm.warp(START + 2);
        (bool ok, bytes memory err) = _send(address(first), _voidReportTo(plain, address(games)));
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before n");
        (ok, err) = _send(address(first), _voidReportTo(disputed, address(games)));
        assertFalse(ok);
        assertEq(err, payoutFault, "the payout fault is named before n, disputed game");
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

    /// The day-30 clock counts from the start as written or, with no start written, from the date given at
    /// creation: a second before, refused by name with the second it opens at; at it, taken. Writing the start
    /// moves the clock with it, earlier or later than the date. The clock is the game's own copied term: a
    /// league's own day-30 clock holds for its game, and a change after the game was made moves nothing.
    function test_release_opensAtTheDay30ClockFromTheStartOrTheDate() public {
        _setTerms("nhl", _clockTerms(3 days, 10 days));
        vm.warp(DATE - 2 days);
        uint256 noStart = _create();
        uint256 lateStart = _create();
        uint256 earlyStart = _create();
        vm.prank(creator, creator);
        uint256 nhl = games.createGame("nhl", "Home", "Away", DATE, _hints(), ANY_FEE);
        _startBy(first, lateStart, START); // 613 seconds after the date
        _startBy(first, earlyStart, DATE - 1 days + 1); // a day before it, less a second
        _setTerms("nhl", _clockTerms(3 days, 300 days)); // after the game was made: reaches none

        uint256[4] memory ids = [noStart, lateStart, earlyStart, nhl];
        uint256[4] memory opensAt = [
            uint256(DATE) + DAY30, uint256(START) + DAY30, uint256(DATE) - 1 days + 1 + DAY30, uint256(DATE) + 10 days
        ];
        for (uint256 i; i < ids.length; ++i) {
            vm.warp(opensAt[i] - 1);
            (bool ok, bytes memory err) = _tryRelease(stranger, ids[i]);
            assertFalse(ok, "the release opened a second early");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, ids[i], opensAt[i]));
            vm.warp(opensAt[i]);
            _releaseBy(stranger, ids[i]);
            assertEq(uint8(_status(ids[i])), uint8(GameStatus.Released), "released at its clock");
        }
        assertEq(games.getCredit(creator), 4 * uint256(FEE), "each release credited the creator");

        // A start written after the date's clock has run, while nothing has released the game, moves the release
        // to the start's clock, by at most the start bound: refused until then, then taken.
        vm.warp(DATE - 1 hours);
        uint256 lateWritten = _create();
        vm.warp(DATE + DAY30);
        _startBy(first, lateWritten, START);
        (bool okLate, bytes memory errLate) = _tryRelease(stranger, lateWritten);
        assertFalse(okLate, "a start written after the date's clock ran left the release open");
        assertEq(
            errLate,
            abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, lateWritten, uint256(START) + DAY30)
        );
        vm.warp(START + DAY30);
        _releaseBy(stranger, lateWritten);
        assertEq(uint8(_status(lateWritten)), uint8(GameStatus.Released), "released at the start's clock");
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

    /// Every first-n reporter of a game retired while an after-n one is not: the game is not one whose every
    /// reporter is retired, so its release waits for the day-30 clock, from the date for a game whose start
    /// was never written (nothing can write it now). Retiring the last reporter opens the release at once.
    function test_release_waitsWhileAnyReporterIsLiveAndOpensWhenTheLastRetires() public {
        vm.warp(DATE - 1 hours);
        uint256 game = _create();
        _retire(address(first));
        _retire(address(second));
        assertFalse(games.isEveryReporterRetired(game), "the after-n reporter is live");
        (bool okStart, bytes memory errStart) = _send(address(later), _startReport(game, START));
        assertFalse(okStart, "an after-n reporter wrote a start");
        assertEq(errStart, abi.encodeWithSelector(OspexGames.OspexGames__NotFirstN.selector, game, address(later)));

        vm.warp(DATE + DAY30 - 1); // the clock runs from the date: no start was written
        (bool ok, bytes memory err) = _tryRelease(stranger, game);
        assertFalse(ok, "the release opened while a reporter was live");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, game, uint256(DATE) + DAY30));
        vm.warp(DATE - 1 hours + 2 days);
        _retire(address(later));
        assertTrue(games.isEveryReporterRetired(game), "every reporter retired");
        _releaseBy(stranger, game);
        assertEq(uint8(_status(game)), uint8(GameStatus.Released), "released at once");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
        games.getGameStart(game);
    }

    // ──────────────────────────── The status machine ───────────────────

    /// From every status, every call a game can take (a start, a score, a void, a dispute record, a release),
    /// from a first-n reporter and from an after-n one, at an hour every clock has run: the status never moves
    /// back, a refused call leaves it, an ended game takes nothing, and a credit is emitted exactly when the
    /// call moves the game into an end from an open status. Which calls each status takes is
    /// test_report_refusalNamesByStatus's.
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
        for (uint256 s; s < statuses.length; ++s) {
            for (uint256 w; w < kinds.length; ++w) {
                for (uint256 action; action < 5; ++action) {
                    vm.warp(DATE - 1 hours);
                    uint256 game = _inStatus(statuses[s]);
                    vm.warp(START + DAY30 + DAY7); // every clock has run
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
                }
            }
        }
    }

    /// A disputed game takes a score at every hour a reporter may write: inside n from a first-n reporter, at
    /// start + n from an after-n one, before the day-7 clock has run and after, and past the day-30 clock.
    function test_score_onADisputedGameAtEveryHour() public {
        uint64[4] memory times = [START + 2, START + WINDOW, START + 1 + DAY7, START + DAY30 + 1];
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
    }
}
