// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UnauthenticatedPlainReporter, SwappedRelay} from "./ReporterFixtures.sol";
import {RefusingCoin} from "./CoinFixtures.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
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
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";

/// @dev A reading as the spec's text orders it, declared here and not taken from the repository's types.
struct SpecReading {
    uint8 seat;
    uint8 kind;
    uint32 homeScore;
    uint32 awayScore;
}

/// @dev A report as the spec's text orders it: the game; what it is; the start; the home team's and the away
///      team's scores; the readings; the payout address.
struct SpecReport {
    uint256 gameId;
    uint8 kind;
    uint64 start;
    uint32 homeScore;
    uint32 awayScore;
    SpecReading[] readings;
    address payout;
}

/// @dev GameCreated's data, field for field, decoded as one struct behind one offset.
struct CreatedEvent {
    string league;
    string homeTeam;
    string awayTeam;
    uint64 date;
    Hint[] hints;
    Terms terms;
    address[] reporters;
    uint8[] kinds;
}

/// @dev A contract with code and nothing else.
contract Plain {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice One test per line of the spec's "Must never happen" that this contract carries. Above each test,
///         "Break:" names the one-line change to src/games/OspexGames.sol that turns it red.
contract OspexGamesNeverLinesTest is GamesBase {
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An address not among a game's recorded reporters writes a start, a score, a void, a dispute record or
    //  a day-7 result to that game." Here, for a start and a score.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in report(), delete `if (kind == ReporterKind.None) revert OspexGames__NotAReporter(r.gameId,
    /// msg.sender);`. Every outsider's score is then taken. (An outsider's start is still refused, by the
    /// first-n check, under another name; the starts' names are checked last so the red shows the score.)
    function test_neverLine_onlyRecordedReportersWrite() public {
        uint256 game = _create();

        // Two reporters join the list after the game is made, through the timelock.
        MockReporter lateFirst = new MockReporter(games);
        MockReporter lateAfter = new MockReporter(games);
        _approve(address(lateAfter), ReporterKind.AfterN);
        _approve(address(lateFirst), ReporterKind.FirstN);
        uint256 laterGame = _create();

        address[] memory outsiders = new address[](11);
        outsiders[0] = makeAddr("stranger");
        outsiders[1] = address(new MockReporter(games)); // a reporter contract never approved
        outsiders[2] = address(lateFirst); // approved after the game was made, first-n
        outsiders[3] = address(lateAfter); // approved after the game was made, after-n
        outsiders[4] = deployer;
        outsiders[5] = creator;
        outsiders[6] = timelockKey;
        outsiders[7] = address(this);
        outsiders[8] = address(games);
        outsiders[9] = payout;
        outsiders[10] = address(timelock);

        // Starts: every outsider refused, nothing changes. The refusals' names are checked at the end.
        bytes[] memory startErrors = new bytes[](outsiders.length);
        for (uint256 i; i < outsiders.length; ++i) {
            bytes32 before = _viewAll();
            (bool ok, bytes memory err) = _send(outsiders[i], _startReport(game, START));
            assertFalse(ok, string.concat("start taken from outsider ", vm.toString(i)));
            assertEq(_viewAll(), before, "a refused start changed state");
            startErrors[i] = err;
        }

        // A recorded reporter writes the start; past start + n every kind of recorded reporter could score.
        _startBy(first, game, START);
        vm.warp(START + WINDOW + 1);

        // Scores: every outsider refused, nothing changes.
        for (uint256 i; i < outsiders.length; ++i) {
            bytes32 before = _viewAll();
            (bool ok, bytes memory err) = _send(outsiders[i], _scoreReport(game, HOME, AWAY));
            assertFalse(ok, string.concat("score taken from outsider ", vm.toString(i)));
            assertEq(_viewAll(), before, "a refused score changed state");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, outsiders[i]));
        }
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "still unscored");
        for (uint256 i; i < outsiders.length; ++i) {
            assertEq(
                startErrors[i],
                abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, outsiders[i]),
                "an outsider's start was refused for another reason"
            );
        }

        // Controls: the game's own after-n reporter scores it; the late reporters write to the game made after.
        _scoreBy(later, game, HOME, AWAY);
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored), "recorded reporter scored");
        vm.warp(DATE - 1 hours);
        _startBy(lateFirst, laterGame, START);
        vm.warp(START + WINDOW);
        _scoreBy(lateAfter, laterGame, 3, 5);
        (uint32 h, uint32 a) = games.getGameScores(laterGame);
        assertEq(h, 3, "later game's home score");
        assertEq(a, 5, "later game's away score");
        // And a reporter recorded on the first game, but not on the list a later game copied, cannot write
        // that later game.
        _retire(address(second));
        uint256 newest = _create();
        (bool okDropped, bytes memory errDropped) = _send(address(second), _startReport(newest, START));
        assertFalse(okDropped, "a reporter not on the newest list wrote a game made after");
        assertEq(
            errDropped, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, newest, address(second))
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A game's reporters, or their kinds, change after its creation, by anyone, the timelock key included."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The list moves through the timelock's own calls: an approval, then a retirement and an approval, then
    /// three retirements, with a change of terms each time. Every game keeps its copy, and every other call
    /// from every other caller, the timelock key's included, changes no game's copy either.
    /// Break: in getGameReporters(), change `Reporter[] storage list = s_gameReporters[gameId];` to
    /// `Reporter[] storage list = s_approved;`. The first game's read then follows the list as it changes.
    function test_neverLine_reportersNeverChangeAfterCreation() public {
        vm.recordLogs();
        uint256 g1 = _create();
        (address[] memory created, uint8[] memory createdKinds) = _createdReporters(vm.getRecordedLogs());
        (address[] memory r1, uint8[] memory k1) = games.getGameReporters(g1);
        _assertList(r1, k1, _setupList(), _setupKinds(), "g1 as created");
        _assertList(created, createdKinds, r1, k1, "creation event = read");

        MockReporter extra = new MockReporter(games);
        MockReporter extra2 = new MockReporter(games);
        address[][] memory lists = new address[][](3);
        uint8[][] memory kindLists = new uint8[][](3);
        lists[0] = new address[](4);
        (lists[0][0], lists[0][1], lists[0][2], lists[0][3]) =
            (address(first), address(later), address(second), address(extra));
        kindLists[0] = new uint8[](4);
        (kindLists[0][0], kindLists[0][1], kindLists[0][2], kindLists[0][3]) = (1, 2, 1, 2);
        lists[1] = new address[](4);
        (lists[1][0], lists[1][1], lists[1][2], lists[1][3]) =
            (address(first), address(second), address(extra), address(extra2));
        kindLists[1] = new uint8[](4);
        (kindLists[1][0], kindLists[1][1], kindLists[1][2], kindLists[1][3]) = (1, 1, 2, 1);
        lists[2] = _one(address(extra2));
        kindLists[2] = new uint8[](1);
        kindLists[2][0] = 1;

        uint256[] memory made = new uint256[](4);
        made[0] = g1;
        for (uint256 step; step < 3; ++step) {
            // Every game made so far, those made by _everyCallFromEveryone included, word for word: the
            // newest game is not always one this test made.
            bytes32 everyGame = _gameStates();
            if (step == 0) {
                _approve(address(extra), ReporterKind.AfterN);
            } else if (step == 1) {
                _retire(address(later));
                _approve(address(extra2), ReporterKind.FirstN);
            } else {
                _retire(address(first));
                _retire(address(second));
                _retire(address(extra));
            }
            _setTerms("nba", _terms(uint64(1 hours * (step + 2))));
            assertEq(_gameStates(), everyGame, "a change of the list or the terms wrote a game");
            (address[] memory approved, uint8[] memory approvedKinds) = games.getApprovedReporters();
            _assertList(approved, approvedKinds, lists[step], kindLists[step], "the approved list");
            made[step + 1] = _create();
            _everyCallFromEveryone(made);

            (address[] memory now1, uint8[] memory nowK1) = games.getGameReporters(g1);
            _assertList(now1, nowK1, r1, k1, "g1 moved after a list change");
            _assertTerms(games.getGameTerms(g1), _launchTerms(), "g1's terms moved");
            for (uint256 j; j <= step; ++j) {
                (address[] memory rj, uint8[] memory kj) = games.getGameReporters(made[j + 1]);
                _assertList(rj, kj, lists[j], kindLists[j], "a later game moved");
                assertEq(games.getGameWindow(made[j + 1]), uint64(1 hours * (j + 2)), "a later game's n moved");
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A start or a score is written twice, or changed after it is written."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in _writeStart(), delete `if (status != GameStatus.Unverified) _refuseStart(r.gameId, status);`.
    /// A second start then overwrites the first.
    function test_neverLine_startWrittenOnce() public {
        uint256 game = _create();
        _startBy(first, game, START);

        uint64[3] memory others = [START, START + 1, DATE - 5];
        MockReporter[2] memory firstNs = [first, second];
        for (uint256 i; i < firstNs.length; ++i) {
            for (uint256 j; j < others.length; ++j) {
                bytes32 before = _viewAll();
                (bool ok, bytes memory err) = _send(address(firstNs[i]), _startReport(game, others[j]));
                assertFalse(ok, "a second start was taken");
                assertEq(games.getGameStart(game), START, "start changed");
                assertEq(_viewAll(), before, "a refused start changed state");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartAlreadyWritten.selector, game));
            }
        }

        // After the score, a start report is refused as the game has ended, and the start stays.
        vm.warp(START);
        _scoreBy(second, game, HOME, AWAY);
        (bool okAfter, bytes memory errAfter) = _send(address(second), _startReport(game, START + 7));
        assertFalse(okAfter, "a start after the score was taken");
        assertEq(games.getGameStart(game), START, "start changed after the score");
        assertEq(
            errAfter,
            abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, GameStatus.Scored)
        );
    }

    /// Break: in _writeScore(), delete `if (status != GameStatus.Verified && status != GameStatus.Disputed)
    /// _refuseResult(r.gameId, status);`. The second score then runs on to `_end`, which refuses it by the same
    /// name, but the after-n reporter's second score inside n is refused for the hour instead: the red.
    function test_neverLine_scoreWrittenOnce() public {
        uint256 game = _create();
        _startBy(first, game, START);
        vm.warp(START + 1);
        _scoreBy(first, game, HOME, AWAY);

        // Every recorded reporter, each kind, inside n and after n, the same score and a different one.
        address[3] memory reporters = [address(first), address(second), address(later)];
        uint64[2] memory times = [START + 2, START + WINDOW + 9];
        uint32[2][3] memory scores = [[HOME, AWAY], [AWAY, HOME], [uint32(0), uint32(0)]];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 i; i < reporters.length; ++i) {
                for (uint256 s; s < scores.length; ++s) {
                    bytes32 before = _viewAll();
                    (bool ok, bytes memory err) =
                        _send(reporters[i], _scoreReport(game, scores[s][0], scores[s][1]));
                    assertFalse(ok, "a second score was taken");
                    assertEq(_viewAll(), before, "a refused score changed state");
                    assertEq(
                        err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, GameStatus.Scored)
                    );
                }
            }
        }
        (uint32 h, uint32 a) = games.getGameScores(game);
        assertEq(h, HOME, "home score changed");
        assertEq(a, AWAY, "away score changed");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A score is written before the game's start."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in _checkHour(), delete `if (block.timestamp < start) revert OspexGames__BeforeStart(gameId,
    /// g.start);`. A first-n reporter then scores before the start. (Only a first-n reporter discriminates
    /// here: an after-n reporter is also held back by start + n.)
    function test_neverLine_noScoreBeforeTheStartTime() public {
        uint256 game = _create();
        vm.warp(DATE - 2 hours);
        _startBy(first, game, START);

        uint64[4] memory early = [uint64(DATE - 2 hours), START - 3600, START - 2, START - 1];
        for (uint256 i; i < early.length; ++i) {
            vm.warp(early[i]);
            bytes32 before = _viewAll();
            (bool ok, bytes memory err) = _send(address(first), _scoreReport(game, HOME, AWAY));
            assertFalse(ok, "a score before the start was taken");
            assertEq(_viewAll(), before, "a refused score changed state");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, game, START));
        }

        // Control: at the start itself, a first-n reporter's score is taken.
        vm.warp(START);
        _scoreBy(first, game, HOME, AWAY);
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored), "score at the start");
    }

    /// Break: in _writeScore(), delete `if (status != GameStatus.Verified && status != GameStatus.Disputed)
    /// _refuseResult(r.gameId, status);`. A game with no start written then takes a score: its start is 0, so
    /// no time is before it.
    function test_neverLine_noScoreBeforeTheStartIsWritten() public {
        uint256 game = _create();
        uint64[4] memory times = [uint64(DATE - 1 days), DATE, START + WINDOW, DATE + 40 days];
        address[3] memory reporters = [address(first), address(second), address(later)];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 i; i < reporters.length; ++i) {
                bytes32 before = _viewAll();
                (bool ok, bytes memory err) = _send(reporters[i], _scoreReport(game, HOME, AWAY));
                assertFalse(ok, "a score with no start was taken");
                assertEq(_viewAll(), before, "a refused score changed state");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game));
            }
        }
        assertEq(uint8(_status(game)), uint8(GameStatus.Unverified), "still unverified");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A void is stored as a scored 0-0." Here, the status values and the score read: no game reads as
    // scored, at 0-0 or at any score, unless a score was written.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in getGameScores(), delete `if (g.status != GameStatus.Scored) revert OspexGames__NotScored(gameId,
    /// g.status);`. A voided game then reads as a 0-0 score.
    function test_neverLine_noGameReadsAsScoredUnlessScoreWritten() public {
        // Every status but Scored, each reached through its own path, with the score fields at 0-0 and then
        // planted at a real-looking score.
        GameStatus[5] memory unscored = [
            GameStatus.Unverified, GameStatus.Verified, GameStatus.Disputed, GameStatus.Voided, GameStatus.Released
        ];
        uint32[2][2] memory fields = [[uint32(0), uint32(0)], [HOME, AWAY]];
        for (uint256 s; s < unscored.length; ++s) {
            for (uint256 f; f < fields.length; ++f) {
                vm.warp(DATE - 1 hours);
                uint256 game = _inStatus(unscored[s]);
                games.harnessSetScoreFields(game, fields[f][0], fields[f][1]);
                assertEq(uint8(_status(game)), uint8(unscored[s]), "status read");
                vm.expectRevert(
                    abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, unscored[s])
                );
                games.getGameScores(game);
            }
        }

        // Controls: a written 0-0 reads as scored 0-0, and a written score reads home then away.
        vm.warp(DATE - 1 hours);
        uint256 nil = _create();
        _startBy(first, nil, START);
        vm.warp(START + 1);
        _scoreBy(first, nil, 0, 0);
        (uint32 h0, uint32 a0) = games.getGameScores(nil);
        assertEq(uint256(h0) + uint256(a0), 0, "a written 0-0 reads 0-0");
        vm.warp(DATE - 1 hours);
        uint256 real = _create();
        _startBy(second, real, START);
        vm.warp(START + 1);
        _scoreBy(second, real, HOME, AWAY);
        (uint32 h, uint32 a) = games.getGameScores(real);
        assertEq(h, HOME, "home");
        assertEq(a, AWAY, "away");
    }

    /// The status values, the kinds' numbers and the report kinds are part of a read that never changes.
    /// Break: in IOspexGames.sol, swap the lines `Scored,` and `Voided,` in GameStatus.
    function test_neverLine_statusAndKindNumbersAreFixed() public pure {
        assertEq(uint8(GameStatus.None), 0);
        assertEq(uint8(GameStatus.Unverified), 1);
        assertEq(uint8(GameStatus.Verified), 2);
        assertEq(uint8(GameStatus.Disputed), 3);
        assertEq(uint8(GameStatus.Scored), 4);
        assertEq(uint8(GameStatus.Voided), 5);
        assertEq(uint8(GameStatus.Released), 6);
        assertEq(uint8(type(GameStatus).max), 6, "no status after Released");
        assertEq(uint8(ReporterKind.None), 0);
        assertEq(uint8(ReporterKind.FirstN), 1);
        assertEq(uint8(ReporterKind.AfterN), 2);
        assertEq(uint8(type(ReporterKind).max), 2, "no kind after AfterN");
        assertEq(uint8(ReportKind.None), 0);
        assertEq(uint8(ReportKind.Start), 1);
        assertEq(uint8(ReportKind.Score), 2);
        assertEq(uint8(ReportKind.Void), 3);
        assertEq(uint8(ReportKind.Dispute), 4);
        assertEq(uint8(type(ReportKind).max), 4, "no report kind after Dispute");
        assertEq(uint8(ReadingKind.Silent), 0);
        assertEq(uint8(ReadingKind.AnsweredNoFinal), 1);
        assertEq(uint8(ReadingKind.AnsweredFinal), 2);
        assertEq(uint8(type(ReadingKind).max), 2, "no reading kind after AnsweredFinal");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A rejected report changes any game's state or moves any money; a second creation of the same real
    //  game shares a reporter list, a state or money with the first."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Every refusal the report call makes, each against games in each state the call can see, and every
    /// refusal the release makes. A refused report or release reverts, changes no read of any game, emits
    /// nothing, and moves no money: the coin the games set holds, every credit, every account's coin and every
    /// game's held fee read as before.
    /// Break: in report(), replace `revert OspexGames__ReportKindNotTaken(r.kind);` with nothing. A report with
    /// no kind is then "taken" without a revert, and an event announcing it is emitted for a game it did not
    /// change.
    function test_neverLine_rejectedReportChangesNothing() public {
        uint256 open = _create(); // Unverified
        uint256 verified = _create();
        uint256 scored = _create();
        uint256 tight = _create(); // for the after-n window
        uint256 ahead = _create(); // for a report before the start
        uint256 disputed = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, verified, START);
        _startBy(first, scored, START);
        _startBy(first, tight, START);
        _startBy(first, ahead, START);
        _startBy(first, disputed, START);
        vm.warp(START + 10);
        _scoreBy(first, scored, HOME, AWAY);
        _disputeBy(first, disputed);
        uint256 unknown = games.gameCount() + 1;
        uint64 late = START + 10;
        uint64 day7 = START + 10 + DAY7;
        uint64 closed = DATE + DAY30;

        Refusal[] memory cases = new Refusal[](71);
        uint256 n;
        // The start's refusals.
        cases[n++] = _refusal(_startReport(0, START), address(first), _err1(OspexGames.OspexGames__UnknownGame.selector, 0), late);
        cases[n++] = _refusal(_startReport(unknown, START), address(first), _err1(OspexGames.OspexGames__UnknownGame.selector, unknown), late);
        cases[n++] = _refusal(_startReport(open, START), makeAddr("x"), abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, open, makeAddr("x")), late);
        Report memory r = _startReport(open, START);
        r.kind = ReportKind.None;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__ReportKindNotTaken.selector, ReportKind.None), late);
        r = _startReport(open, START);
        r.homeScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Start), late);
        cases[n++] = _refusal(_startReport(scored, START), address(second), abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored), late);
        cases[n++] = _refusal(_startReport(verified, START + 1), address(second), _err1(OspexGames.OspexGames__StartAlreadyWritten.selector, verified), late);
        cases[n++] = _refusal(_startReport(disputed, START + 1), address(second), _err1(OspexGames.OspexGames__StartAlreadyWritten.selector, disputed), late);
        cases[n++] = _refusal(_startReport(open, START), address(later), abi.encodeWithSelector(OspexGames.OspexGames__NotFirstN.selector, open, address(later)), late);
        cases[n++] = _refusal(_startReport(open, DATE + DAY + 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, open, DATE + DAY + 1), late);
        cases[n++] = _refusal(_startReport(open, DATE - DAY - 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, open, DATE - DAY - 1), late);
        r = _startReport(open, START);
        r.payout = payout;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Start), late);
        r = _startReport(open, START);
        r.readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 1, awayScore: 0});
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__SilentReadingNotEmpty.selector, 3), late);
        // The score's refusals.
        r = _scoreReport(verified, HOME, AWAY);
        r.start = START;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Score), late);
        cases[n++] = _refusal(_scoreReport(scored, 1, 2), address(first), abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored), late);
        cases[n++] = _refusal(_scoreReport(open, HOME, AWAY), address(first), _err1(OspexGames.OspexGames__StartNotWritten.selector, open), late);
        cases[n++] = _refusal(_scoreReport(tight, HOME, AWAY), address(later), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, tight, uint256(START) + WINDOW), START + WINDOW - 1);
        cases[n++] = _refusal(_scoreReport(disputed, HOME, AWAY), address(later), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, disputed, uint256(START) + WINDOW), START + WINDOW - 1);
        cases[n++] = _refusal(_scoreReport(verified, games.MAX_SCORE() + 1, AWAY), address(first), abi.encodeWithSelector(OspexGames.OspexGames__ScoreOutOfRange.selector, games.MAX_SCORE() + 1, AWAY), late);
        cases[n++] = _refusal(_scoreReport(verified, HOME, games.MAX_SCORE() + 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__ScoreOutOfRange.selector, HOME, games.MAX_SCORE() + 1), late);
        cases[n++] = _refusal(_scoreReport(ahead, HOME, AWAY), address(first), abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, ahead, START), DATE - 1 hours);
        cases[n++] = _refusal(_scoreReportTo(verified, address(games)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Score), late);
        cases[n++] = _refusal(_scoreReportTo(verified, address(first)), address(first), _isAReporter(address(first)), late);
        cases[n++] = _refusal(_scoreReportTo(verified, address(second)), address(first), _isAReporter(address(second)), late);
        cases[n++] = _refusal(_scoreReportTo(verified, address(token)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheCoin.selector, ReportKind.Score), late);
        // The void's refusals: the status, the fields, the payout, the hour and the day-7 clock.
        cases[n++] = _refusal(_voidReport(open), address(first), _err1(OspexGames.OspexGames__StartNotWritten.selector, open), late);
        cases[n++] = _refusal(_voidReport(scored), address(first), abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored), START + WINDOW);
        r = _voidReport(verified);
        r.homeScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Void), START + WINDOW);
        r = _voidReport(verified);
        r.start = START;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Void), START + WINDOW);
        r = _voidReport(verified);
        r.awayScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Void), START + WINDOW);
        // Inside n a disputed game's void names n, not the day-7 clock.
        cases[n++] = _refusal(_voidReport(disputed), address(first), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, disputed, uint256(START) + WINDOW), late);
        cases[n++] = _refusal(_voidReportTo(verified, address(0)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__NoPayout.selector, ReportKind.Void), START + WINDOW);
        cases[n++] = _refusal(_voidReportTo(verified, address(0x1010)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsReserved.selector, ReportKind.Void, address(0x1010)), START + WINDOW);
        cases[n++] = _refusal(_voidReportTo(verified, address(games)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Void), START + WINDOW);
        cases[n++] = _refusal(_voidReportTo(verified, address(token)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheCoin.selector, ReportKind.Void), START + WINDOW);
        cases[n++] = _refusal(_voidReportTo(verified, address(later)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Void, address(later)), START + WINDOW);
        cases[n++] = _refusal(_voidReport(tight), address(first), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, tight, uint256(START) + WINDOW), START + WINDOW - 1);
        cases[n++] = _refusal(_voidReport(tight), address(later), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, tight, uint256(START) + WINDOW), START + WINDOW - 1);
        cases[n++] = _refusal(_voidReport(disputed), address(first), abi.encodeWithSelector(OspexGames.OspexGames__InsideDay7Clock.selector, disputed, uint256(day7)), day7 - 1);
        cases[n++] = _refusal(_voidReport(disputed), address(later), abi.encodeWithSelector(OspexGames.OspexGames__InsideDay7Clock.selector, disputed, uint256(day7)), day7 - 1);
        // The dispute record's refusals: the status, the fields and the hour.
        cases[n++] = _refusal(_disputeReport(open), address(first), _err1(OspexGames.OspexGames__StartNotWritten.selector, open), late);
        cases[n++] = _refusal(_disputeReport(scored), address(first), abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored), late);
        r = _disputeReport(verified);
        r.payout = payout;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        r = _disputeReport(verified);
        r.awayScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        r = _disputeReport(verified);
        r.homeScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        r = _disputeReport(verified);
        r.start = START;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        cases[n++] = _refusal(_disputeReport(ahead), address(first), abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, ahead, START), DATE - 1 hours);
        cases[n++] = _refusal(_disputeReport(tight), address(later), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, tight, uint256(START) + WINDOW), START + WINDOW - 1);
        // The fields on a disputed game: a score's start, an update's start and scores, a day-7 void's start and
        // away score, each refused where the game has a dispute record too.
        r = _scoreReport(disputed, HOME, AWAY);
        r.start = START;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Score), late);
        r = _disputeReport(disputed);
        r.start = START;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        r = _disputeReport(disputed);
        r.homeScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        r = _disputeReport(disputed);
        r.awayScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute), late);
        r = _voidReport(disputed);
        r.start = START;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Void), day7);
        r = _voidReport(disputed);
        r.awayScore = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Void), day7);
        // A silent reading carrying a score, in a void and in a dispute record.
        r = _voidReport(verified);
        r.readings[2] = Reading({seat: 3, kind: ReadingKind.Silent, homeScore: 0, awayScore: 1});
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__SilentReadingNotEmpty.selector, 2), START + WINDOW);
        r = _disputeReport(verified);
        r.readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 1, awayScore: 0});
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__SilentReadingNotEmpty.selector, 3), late);
        // The readings against the result: two readings for one seat; a score no final reads, on a game with no
        // record and on a disputed one; a game with no record's score on two finals inside n (two of three) and
        // on one final from start + n (one of two); a score beside a dissenting final; a disputed game's score on
        // two finals (two of three) and on three finals beside a dissent before the day-7 clock; an hour-24 void
        // over three finals that agree, and over two.
        r = _startReport(open, START);
        r.readings[2].seat = 1;
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__ReadingSeatRepeated.selector, 2), late);
        r = _scoreReport(verified, 1, 0);
        r.readings = _scoreReadings(HOME, AWAY);
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 0, 3), late);
        r = _scoreReport(verified, HOME, AWAY);
        r.readings = _finals(2);
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 2, 3), late);
        r = _scoreReport(verified, HOME, AWAY);
        r.readings = _finals(1);
        cases[n++] = _refusal(r, address(later), abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 1, 2), START + WINDOW);
        r = _scoreReport(disputed, 1, 0);
        r.readings = _scoreReadings(HOME, AWAY);
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 0, 3), late);
        r = _scoreReport(verified, HOME, AWAY);
        r.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FinalDissents.selector, 3), late);
        r = _scoreReport(disputed, HOME, AWAY);
        r.readings[2] = Reading({seat: 3, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 2, 3), late);
        r = _scoreReport(disputed, HOME, AWAY);
        r.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FinalDissents.selector, 3), day7 - 1);
        r = _voidReport(verified);
        r.readings = _scoreReadings(HOME, AWAY);
        cases[n++] = _refusal(r, address(later), abi.encodeWithSelector(OspexGames.OspexGames__FinalsAgree.selector, HOME, AWAY), START + WINDOW);
        r = _voidReport(verified);
        r.readings = _finals(2);
        cases[n++] = _refusal(r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FinalsAgree.selector, HOME, AWAY), START + WINDOW);
        // The day-30 clock: a start, a score, a void, a dispute record and an update at the clock.
        cases[n++] = _refusal(_startReport(open, START), address(first), _pastDay30(open), closed);
        cases[n++] = _refusal(_scoreReport(verified, HOME, AWAY), address(first), _pastDay30(verified), closed);
        cases[n++] = _refusal(_voidReport(verified), address(later), _pastDay30(verified), closed);
        cases[n++] = _refusal(_disputeReport(verified), address(first), _pastDay30(verified), closed);
        cases[n++] = _refusal(_disputeReport(disputed), address(later), _pastDay30(disputed), closed);
        assertEq(n, cases.length, "every case filled");

        address[] memory accounts = new address[](8);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (address(first), address(later), address(second), creator);
        (accounts[4], accounts[5], accounts[6], accounts[7]) = (payout, address(games), address(this), address(0));
        assertEq(token.balanceOf(address(games)), 6 * uint256(FEE), "six games' fees, one of them credited");
        for (uint256 i; i < n; ++i) {
            _assertRefused(cases[i], accounts, i);
        }

        // The release's refusals: not a game, ended, and not yet open, from a stranger and from the creator.
        _assertReleaseRefused(0, late, _err1(OspexGames.OspexGames__UnknownGame.selector, 0), accounts);
        _assertReleaseRefused(unknown, late, _err1(OspexGames.OspexGames__UnknownGame.selector, unknown), accounts);
        _assertReleaseRefused(
            scored,
            START + DAY30,
            abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored),
            accounts
        );
        _assertReleaseRefused(
            open,
            DATE + DAY30 - 1,
            abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, open, uint256(DATE) + DAY30),
            accounts
        );
        _assertReleaseRefused(
            verified,
            DATE + DAY30 - 1,
            abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, verified, uint256(DATE) + DAY30),
            accounts
        );
        _assertReleaseRefused(
            disputed,
            DATE + DAY30 - 1,
            abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, disputed, uint256(DATE) + DAY30),
            accounts
        );
    }

    /// Break: in createGame(), change `gameId = ++s_gameCount;` to `gameId = s_gameCount + 1;`. Every creation
    /// then lands on game 1: the second creation of the same real game appends to the first one's reporters
    /// and resets its state.
    function test_neverLine_secondCreationOfTheSameGameSharesNothing() public {
        uint256 a = _create();
        uint256 b = _create(); // the same real game: same creator, league, teams, date and hints
        assertTrue(a != b, "the same real game shares an id");
        assertEq(b, a + 1, "ids count up");

        vm.warp(DATE - 1 hours);
        _startBy(first, a, START);
        assertEq(uint8(_status(b)), uint8(GameStatus.Unverified), "b moved with a's start");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, b));
        games.getGameStart(b);

        vm.warp(START + 1);
        _scoreBy(first, a, HOME, AWAY);
        assertEq(uint8(_status(b)), uint8(GameStatus.Unverified), "b moved with a's score");

        vm.warp(DATE - 1 hours);
        _startBy(second, b, START + 50);
        vm.warp(START + 60);
        _scoreBy(second, b, AWAY, HOME);
        assertEq(games.getGameStart(a), START, "a moved with b's start");
        (uint32 ha, uint32 aa) = games.getGameScores(a);
        assertEq(ha, HOME, "a's home moved with b");
        assertEq(aa, AWAY, "a's away moved with b");

        // A third creation of the same game after the list changed holds the new list; the first two keep theirs.
        _retire(address(first));
        _retire(address(later));
        uint256 c = _create();
        (address[] memory rc,) = games.getGameReporters(c);
        assertEq(rc.length, 1, "c holds the list of its own creation");
        (address[] memory ra,) = games.getGameReporters(a);
        (address[] memory rb,) = games.getGameReporters(b);
        assertEq(ra.length, 3, "a's list moved");
        assertEq(rb.length, 3, "b's list moved");
        assertEq(games.getGameWindow(a), WINDOW, "a's window");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "The games set deploys without the hooks; a reporter's report shape differs by reporter."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A first-n reporter and an after-n reporter write through the same call in the same shape, and the
    /// after-n path, the hook the open path's reporter needs, takes a score from start + n.
    /// Break: in _checkHour(), change `if (kind == ReporterKind.AfterN && block.timestamp < opensAt)` to
    /// `if (kind == ReporterKind.AfterN)`. The after-n reporter can then never score.
    function test_neverLine_oneShapeForEveryReporter() public {
        uint256 game = _create();
        vm.warp(DATE - 1 hours);

        vm.recordLogs();
        _startBy(first, game, START);
        vm.warp(START + WINDOW);
        _scoreBy(later, game, HOME, AWAY);
        Vm.Log[] memory all = vm.getRecordedLogs();

        // The score's end credits its fee before its report's event; the two reports' events are compared here.
        assertEq(all.length, 3, "two reports, two events, and the score's credit");
        assertEq(all[1].topics[0], IOspexGames.FeeCredited.selector, "the score's credit");
        Vm.Log[] memory logs = new Vm.Log[](2);
        (logs[0], logs[1]) = (all[0], all[2]);
        assertEq(logs.length, 2, "two reports, two events");
        assertEq(logs[0].topics[0], logs[1].topics[0], "one event for every reporter");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(first)))), "the start names its reporter");
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(address(later)))), "the score names its reporter");
        (uint32 h, uint32 a) = games.getGameScores(game);
        assertEq(h, HOME, "after-n score, home");
        assertEq(a, AWAY, "after-n score, away");

        // The same first-n reporter scores another game inside n, through the same call.
        vm.warp(DATE - 1 hours);
        uint256 other = _create();
        _startBy(first, other, START);
        vm.warp(START + 1);
        _scoreBy(first, other, AWAY, HOME);
        assertEq(uint8(_status(other)), uint8(GameStatus.Scored), "first-n scored inside n");
    }

    /// The one call's selector is the canonical signature of the one shape, and every field of it is pinned by
    /// position, name and type from the compiled artifact: the game, the kind, the start, the home score, the
    /// away score, the readings (seat, kind, home score, away score) and the payout. The signature alone
    /// cannot see two fields of one type swapped; the names can.
    /// Break: in IOspexGames.sol, swap the lines `uint32 homeScore;` and `uint32 awayScore;` in Reading.
    function test_neverLine_theReportShapeIsPinned() public view {
        bytes4 expected =
            bytes4(keccak256("report((uint256,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address))"));
        assertEq(IOspexGames.report.selector, expected, "the report call's signature moved");

        // The interface and the contract that deploys, since a reader may decode by either.
        string[2] memory artifacts = [_artifact("IOspexGames"), _artifact("OspexGames")];
        string memory shape = "$.abi[?(@.name == 'report')].inputs[0].components";
        for (uint256 i; i < artifacts.length; ++i) {
            _assertParams(
                artifacts[i],
                shape,
                "gameId;kind;start;homeScore;awayScore;readings;payout",
                "uint256;uint8;uint64;uint32;uint32;tuple[];address"
            );
            _assertParams(
                artifacts[i],
                string.concat(shape, "[5].components"),
                "seat;kind;homeScore;awayScore",
                "uint8;uint8;uint32;uint32"
            );
            assertEq(vm.parseJsonString(artifacts[i], string.concat(shape, "[1].internalType")), "enum ReportKind");
            assertEq(
                vm.parseJsonString(artifacts[i], string.concat(shape, "[5].components[1].internalType")),
                "enum ReadingKind"
            );
        }
    }

    /// A reporter built from the spec's text, not from this repository's types, sends a start and a score as
    /// raw calldata in the spec's order, the score over three finals, the count inside n. The contract reads the
    /// home score as the home score, and takes a seat above the reading kinds' range where the seat goes. (A seat
    /// of 4 in the kind's place would not decode.)
    /// Break: in IOspexGames.sol, swap the lines `uint32 homeScore;` and `uint32 awayScore;` in Report.
    function test_neverLine_aReportInTheSpecsOrderReadsBack() public {
        uint256 game = _create();
        bytes4 call =
            bytes4(keccak256("report((uint256,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address))"));
        SpecReading[] memory readings = new SpecReading[](4);
        readings[0] = SpecReading({seat: 4, kind: 2, homeScore: 104, awayScore: 97});
        readings[1] = SpecReading({seat: 3, kind: 0, homeScore: 0, awayScore: 0});
        readings[2] = SpecReading({seat: 2, kind: 2, homeScore: 104, awayScore: 97});
        readings[3] = SpecReading({seat: 1, kind: 2, homeScore: 104, awayScore: 97});

        bytes memory start = abi.encodeWithSelector(
            call,
            SpecReport({
                gameId: game, kind: 1, start: START, homeScore: 0, awayScore: 0, readings: readings, payout: address(0)
            })
        );
        vm.prank(address(first), address(first));
        (bool ok, bytes memory err) = address(games).call(start);
        assertTrue(ok, string.concat("the spec-order start was refused: ", vm.toString(err)));
        assertEq(games.getGameStart(game), START);

        vm.warp(START + 1);
        bytes memory score = abi.encodeWithSelector(
            call,
            SpecReport({
                gameId: game, kind: 2, start: 0, homeScore: 104, awayScore: 97, readings: readings, payout: payout
            })
        );
        vm.recordLogs();
        vm.prank(address(first), address(first));
        (ok, err) = address(games).call(score);
        assertTrue(ok, string.concat("the spec-order score was refused: ", vm.toString(err)));
        (uint32 home, uint32 away) = games.getGameScores(game);
        assertEq(home, 104, "the home score read back as another field");
        assertEq(away, 97, "the away score read back as another field");

        // The score's credit, then the report's event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the report");
        assertEq(logs[1].topics[0], IOspexGames.GameReported.selector, "the report's event");
        (uint64 s, uint32 h, uint32 a, SpecReading[] memory got, address pay) =
            abi.decode(logs[1].data, (uint64, uint32, uint32, SpecReading[], address));
        assertEq(s, 0);
        assertEq(h, 104);
        assertEq(a, 97);
        assertEq(pay, payout);
        assertEq(got.length, 4);
        assertEq(got[0].seat, 4);
        assertEq(got[0].kind, 2);
        assertEq(got[1].seat, 3);
        assertEq(got[2].seat, 2);
        assertEq(got[3].seat, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A games entry moves to live when its games contract does not record each game's reporters at
    //  creation, or v2's entry moves to live." The games set's half: getGameReporters returns the
    //  creation-time copy, and a later change to the list does not move it.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The real signpost, owned by a stock timelock, moves an entry whose first contract is this games
    /// contract to live, for a game made before the list changed; the read it took is the creation copy.
    /// Break: in getGameReporters(), change `Reporter[] storage list = s_gameReporters[gameId];` to
    /// `Reporter[] storage list = s_approved;`.
    function test_neverLine_signpostReadsTheCreationCopy() public {
        address k = makeAddr("K");
        TimelockController timelock = new TimelockController(60, _one(k), _one(address(0)), address(0));
        address coin = address(new Plain());
        address[] memory v2 = new address[](2);
        v2[0] = address(new Plain());
        v2[1] = address(new Plain());
        vm.roll(1_000);
        vm.prank(deployer, deployer);
        OspexSignpost signpost =
            new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, v2, bytes20(keccak256("v2")), 900);

        uint256 game = _create();
        _retire(address(first));
        _approve(address(new MockReporter(games)), ReporterKind.FirstN);
        _create();

        address[] memory set = new address[](2);
        set[0] = address(games);
        set[1] = address(first);
        bytes memory add =
            abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Games, address(0), set, bytes20(keccak256("v3")), 990));
        bytes memory live = abi.encodeCall(OspexSignpost.moveForward, (1, OspexSignpost.Status.Live, game, ""));
        vm.startPrank(k);
        timelock.schedule(address(signpost), 0, add, bytes32(0), bytes32(0), 60);
        timelock.schedule(address(signpost), 0, live, bytes32(0), bytes32(uint256(1)), 60);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 60);
        timelock.execute(address(signpost), 0, add, bytes32(0), bytes32(0));
        timelock.execute(address(signpost), 0, live, bytes32(0), bytes32(uint256(1)));
        assertEq(uint8(signpost.getEntry(1).status), uint8(OspexSignpost.Status.Live), "entry moved to live");

        (address[] memory r, uint8[] memory kinds) = games.getGameReporters(game);
        _assertList(r, kinds, _setupList(), _setupKinds(), "the read the signpost took is the creation copy");

        // Control: the signpost refuses a move naming an id that is not a game.
        bytes memory add2 =
            abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Games, address(0), set, bytes20(keccak256("v3b")), 990));
        uint256 missing = games.gameCount() + 1;
        bytes memory live2 = abi.encodeCall(OspexSignpost.moveForward, (2, OspexSignpost.Status.Live, missing, ""));
        vm.startPrank(k);
        timelock.schedule(address(signpost), 0, add2, bytes32(0), bytes32(uint256(2)), 60);
        timelock.schedule(address(signpost), 0, live2, bytes32(0), bytes32(uint256(3)), 60);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 60);
        timelock.execute(address(signpost), 0, add2, bytes32(0), bytes32(uint256(2)));
        vm.expectRevert(
            abi.encodeWithSelector(OspexSignpost.OspexSignpost__ReportersNotRecorded.selector, address(games), missing)
        );
        timelock.execute(address(signpost), 0, live2, bytes32(0), bytes32(uint256(3)));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An after-n reporter writes to a game before its start + n." With the list and the terms changing
    // through the timelock: the clock is the game's own n, whatever its league's terms or the defaults become.
    // An after-n reporter scores from start + n, that second included. The start and score cases with the
    // defaults fixed are in OspexGames.t.sol: test_start_onlyFirstN, test_score_afterNOpensAtStartPlusN,
    // test_score_afterNClockIsTheGamesOwnN.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// An after-n reporter approved through the timelock writes no start, and scores only from start + n of
    /// the game's own n: not when the defaults shrink to a second, not when its league gets terms of its own.
    /// Break: in _checkHour(), change `uint256 opensAt = start + g.terms.window;` to
    /// `uint256 opensAt = start + s_defaultTerms.window;`. The game then opens at the defaults' new n.
    function test_neverLine_afterNWritesNothingBeforeItsGamesStartPlusN() public {
        MockReporter lateAfter = new MockReporter(games);
        _approve(address(lateAfter), ReporterKind.AfterN);
        uint256 game = _create(); // n = WINDOW, from the defaults
        (bool okStart, bytes memory errStart) = _send(address(lateAfter), _startReport(game, START));
        assertFalse(okStart, "an after-n reporter wrote a start");
        assertEq(errStart, abi.encodeWithSelector(OspexGames.OspexGames__NotFirstN.selector, game, address(lateAfter)));
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);

        _setTerms("", _terms(1));
        _setTerms("nba", _terms(2));
        uint256 opensAt = uint256(START) + WINDOW;
        uint64[4] memory early = [START, START + 1, START + 2, uint64(opensAt - 1)];
        address[2] memory afterNs = [address(later), address(lateAfter)];
        for (uint256 i; i < early.length; ++i) {
            vm.warp(early[i]);
            for (uint256 a; a < afterNs.length; ++a) {
                bytes32 before = _viewAll();
                (bool ok, bytes memory err) = _send(afterNs[a], _scoreReport(game, HOME, AWAY));
                assertFalse(ok, "an after-n reporter scored before the game's start + n");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, game, opensAt));
                assertEq(_viewAll(), before, "a refused score changed state");
            }
        }
        // Control: at the game's own start + n, the after-n reporter approved through the timelock before the
        // game was made scores it.
        vm.warp(opensAt);
        _scoreBy(lateAfter, game, HOME, AWAY);
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A retirement scores, voids or settles anything; it only opens the release." Here, the first half: a
    // retirement writes no game and moves no money. The second half, that it opens the release and nothing
    // else does so early, is test_neverLine_aRetirementOnlyOpensTheRelease.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Games in every status, each reached through its own path, each reporter retired in turn, the last
    /// leaving every game with every reporter retired: after each retirement every game's status, start,
    /// scores, reporters and terms read as before, its storage is unchanged word for word, the date included,
    /// no money moves, and the only event is the retirement. What moves is the one thing a retirement opens:
    /// whether every reporter of a game is retired.
    /// Break: in retireReporter(), add `s_games[s_gameCount].status = GameStatus.Released;` before the emit.
    /// The newest game is then released by the retirement itself.
    function test_neverLine_aRetirementWritesNoGame() public {
        GameStatus[6] memory statuses = [
            GameStatus.Unverified,
            GameStatus.Verified,
            GameStatus.Disputed,
            GameStatus.Scored,
            GameStatus.Voided,
            GameStatus.Released
        ];
        for (uint256 i; i < statuses.length; ++i) {
            vm.warp(DATE - 1 hours);
            _inStatus(statuses[i]);
        }
        vm.warp(DATE - 1 hours);
        uint256 last = _create(); // the newest game: Unverified, so a release of it shows
        assertEq(last, 7);
        address[] memory accounts = new address[](5);
        (accounts[0], accounts[1], accounts[2], accounts[3], accounts[4]) =
            (creator, payout, stranger, address(first), address(games));
        bytes32 money = _money(accounts);

        address[3] memory retiring = [address(later), address(second), address(first)];
        for (uint256 r; r < retiring.length; ++r) {
            bytes32 before = _gameStates();
            vm.recordLogs();
            _retire(retiring[r]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_gameStates(), before, "a retirement changed a game");
            assertEq(_money(accounts), money, "a retirement moved money");
            uint256 fromGames;
            for (uint256 l; l < logs.length; ++l) {
                if (logs[l].emitter != address(games)) continue;
                ++fromGames;
                assertEq(logs[l].topics[0], IOspexGames.ReporterRetired.selector, "a retirement emitted more");
            }
            assertEq(fromGames, 1, "one event from the games set");
            for (uint256 id = 1; id <= last; ++id) {
                assertEq(games.isEveryReporterRetired(id), r == 2, "every reporter retired, read at once");
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A term change or an approval reaches a game already made."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Reporters approved after a game is made, of both kinds, write nothing to it at any hour, though they
    /// write to the game made after; the earlier game's list never gains them, and the approvals leave its
    /// storage unchanged word for word, the date included.
    /// Break: in _recordedKind(), change `Reporter[] storage list = s_gameReporters[gameId];` to
    /// `Reporter[] storage list = s_approved;`. The reporter approved later then writes the earlier game.
    function test_neverLine_noApprovalReachesAGameAlreadyMade() public {
        uint256 game = _create();
        MockReporter lateFirst = new MockReporter(games);
        MockReporter lateAfter = new MockReporter(games);
        bytes32 games0 = _gameStates();
        _approve(address(lateFirst), ReporterKind.FirstN);
        _approve(address(lateAfter), ReporterKind.AfterN);
        assertEq(_gameStates(), games0, "an approval wrote a game already made");
        uint256 made = _create();

        vm.warp(DATE - 1 hours);
        bytes32 before = _viewAll();
        (bool ok, bytes memory err) = _send(address(lateFirst), _startReport(game, START));
        assertFalse(ok, "a reporter approved later wrote the start of a game made before");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, address(lateFirst)));
        assertEq(_viewAll(), before);
        _startBy(first, game, START);
        uint64[3] memory times = [START, START + WINDOW, START + 40 days];
        MockReporter[2] memory late = [lateFirst, lateAfter];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 l; l < late.length; ++l) {
                before = _viewAll();
                (ok, err) = _send(address(late[l]), _scoreReport(game, HOME, AWAY));
                assertFalse(ok, "a reporter approved later scored a game made before");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, address(late[l])));
                assertEq(_viewAll(), before);
            }
        }
        (address[] memory r,) = games.getGameReporters(game);
        assertEq(r, _setupList(), "the earlier game's list moved");
        // Control: they write to the game made after them.
        vm.warp(DATE - 1 hours);
        _startBy(lateFirst, made, START);
        vm.warp(START + WINDOW);
        _scoreBy(lateAfter, made, HOME, AWAY);
        assertEq(uint8(_status(made)), uint8(GameStatus.Scored));
    }

    /// A game keeps the four terms it copied: a change to its league's terms, and to the defaults, reaches only
    /// games made after, in each of the four, and leaves the storage of every game already made unchanged word
    /// for word, the date included.
    /// Break: in getGameWindow(), change `return _game(gameId).terms.window;` to `return s_defaultTerms.window;`.
    function test_neverLine_noTermChangeReachesAGameAlreadyMade() public {
        uint256 game = _create(); // nba, on the defaults
        Terms memory own = Terms({window: 2 hours, day7Clock: 2 days, day30Clock: 10 days, fee: 7});
        Terms memory defaults2 = Terms({window: 3 hours, day7Clock: 3 days, day30Clock: 11 days, fee: 0});
        bytes32 before = _gameStates();
        _setTerms("", defaults2);
        assertEq(_gameStates(), before, "a change to the defaults wrote a game already made");
        uint256 onNewDefaults = _create();
        before = _gameStates();
        _setTerms("nba", own);
        assertEq(_gameStates(), before, "a change to a league's terms wrote a game already made");
        uint256 onOwn = _create();

        assertEq(games.getGameWindow(game), WINDOW, "n moved");
        _assertTerms(games.getGameTerms(game), _launchTerms(), "the first game's terms moved");
        assertEq(games.getGameWindow(onNewDefaults), 3 hours);
        _assertTerms(games.getGameTerms(onNewDefaults), defaults2, "the second game's terms moved");
        assertEq(games.getGameWindow(onOwn), 2 hours);
        _assertTerms(games.getGameTerms(onOwn), own, "the third game's terms");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An approval takes effect before the timelock's delay, or approves code other than what the queued
    //  call announced."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The key queues an approval. Until the delay is up nothing about the reporter changes: it is not on the
    /// list, a game made while the call waits does not copy it, it writes nothing, and the call cannot run. The
    /// key cannot make the call directly either. Once the delay is up it runs, and only games made after copy it.
    /// Break: in approveReporter(), delete the `onlyTimelock` modifier. The key's direct call then lands at once.
    function test_neverLine_anApprovalWaitsTheDelay() public {
        MockReporter r = new MockReporter(games);
        address a = address(r);
        bytes memory call = abi.encodeCall(IOspexGames.approveReporter, (a, ReporterKind.FirstN, a.codehash));
        vm.prank(timelockKey, timelockKey);
        (bool direct, bytes memory err) = address(games).call(call);
        assertFalse(direct, "the key approved without the timelock");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotTheTimelock.selector, timelockKey));

        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32("q"), DELAY);
        uint256 queuedAt = vm.getBlockTimestamp();
        vm.warp(queuedAt + DELAY - 1);
        uint256 duringWait = _create();
        vm.prank(stranger);
        vm.expectRevert(_notReady(call, bytes32("q")));
        timelock.execute(address(games), 0, call, bytes32(0), bytes32("q"));
        (ReporterKind k,,) = games.getReporter(a);
        assertEq(uint8(k), 0, "approved before the delay");
        (bool ok, bytes memory why) = _send(a, _startReport(duringWait, START));
        assertFalse(ok, "the queued reporter wrote before the delay was up");
        assertEq(why, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, duringWait, a));

        vm.warp(queuedAt + DELAY);
        vm.prank(stranger);
        timelock.execute(address(games), 0, call, bytes32(0), bytes32("q"));
        uint256 afterIt = _create();
        (ok, why) = _send(a, _startReport(duringWait, START));
        assertFalse(ok, "the approval reached a game made while it waited");
        assertEq(why, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, duringWait, a));
        _take(a, _startReport(afterIt, START));
    }

    /// The queued call names an address and a code hash. If the code at the address when the call runs hashes
    /// otherwise, whatever is there, the approval is refused and nothing changes; if it hashes as announced, it
    /// runs. Here the address has no code when the call is queued, as a reporter deployed later would not.
    /// Break: in _admit(), delete `if (found != codeHash) revert OspexGames__CodeHashMismatch(reporter,
    /// codeHash, found);`. The other code is then approved.
    function test_neverLine_anApprovalApprovesOnlyTheCodeAnnounced() public {
        MockReporter announcedCode = new MockReporter(games);
        UnauthenticatedPlainReporter otherCode =
            new UnauthenticatedPlainReporter(games, address(1), address(2), bytes32("other"));
        bytes32 announced = address(announcedCode).codehash;
        address at = makeAddr("where the reporter will be deployed");
        bytes memory call = abi.encodeCall(IOspexGames.approveReporter, (at, ReporterKind.FirstN, announced));

        // Other code arrives at the address before the call runs: refused.
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32("1"), DELAY);
        vm.etch(at, address(otherCode).code);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        bytes32 list = _viewList();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OspexGames.OspexGames__CodeHashMismatch.selector, at, announced, at.codehash)
        );
        timelock.execute(address(games), 0, call, bytes32(0), bytes32("1"));
        assertEq(_viewList(), list, "other code was approved");
        (ReporterKind k,,) = games.getReporter(at);
        assertEq(uint8(k), 0);

        // A call that names a zero hash announces no code, so it approves none: refused, though the code at the
        // address is a fit reporter. A zero hash must not read as "any code".
        address atZero = makeAddr("named with a zero hash");
        bytes memory zeroCall = abi.encodeCall(IOspexGames.approveReporter, (atZero, ReporterKind.FirstN, bytes32(0)));
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, zeroCall, bytes32(0), bytes32("0"), DELAY);
        vm.etch(atZero, address(announcedCode).code);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OspexGames.OspexGames__CodeHashMismatch.selector, atZero, bytes32(0), announced)
        );
        timelock.execute(address(games), 0, zeroCall, bytes32(0), bytes32("0"));
        assertEq(_viewList(), list, "a zero hash approved the code that was there");

        // The announced code arrives instead: the same call, queued again, runs.
        vm.etch(at, address(announcedCode).code);
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32("2"), DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        timelock.execute(address(games), 0, call, bytes32(0), bytes32("2"));
        (k,,) = games.getReporter(at);
        assertEq(uint8(k), uint8(ReporterKind.FirstN), "the announced code was refused");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A deployer keeps any power after deploy; an entry or a reporter is written after deploy by anything but
    //  a timelock call that waited the timelock's delay."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The deploy writes exactly its first state, the list, each reporter's admission with its code hash and the
    /// default terms, and nothing else; the owner is the timelock given; and the deployer, as its own
    /// transaction, makes none of the timelock's three calls afterwards.
    /// Break: in the constructor, change `i_timelock = timelock;` to `i_timelock = msg.sender;`. The deployer
    /// then answers for the timelock and writes at once.
    function test_neverLine_theDeployerKeepsNothing() public {
        address[] memory list = _setupList();
        ReporterKind[] memory kinds = new ReporterKind[](3);
        (kinds[0], kinds[1], kinds[2]) = (ReporterKind.FirstN, ReporterKind.AfterN, ReporterKind.FirstN);
        vm.startStateDiffRecording();
        vm.prank(deployer, deployer);
        OspexGames g = new OspexGames(address(timelock), token, _launchTerms(), list, kinds, _hashes(list));
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        assertEq(g.i_timelock(), address(timelock), "the owner is the timelock given");
        // Slots: 1 the list's length, keccak(1) + i its entries, keccak(account . 2) each admission's kind and
        // retired flag and the slot after it its code hash, 4 and 5 the default terms. Read from `forge inspect
        // OspexGames storageLayout`.
        bytes32[] memory want = new bytes32[](12);
        want[0] = bytes32(uint256(1));
        for (uint256 i; i < 3; ++i) {
            want[1 + i] = bytes32(uint256(keccak256(abi.encode(uint256(1)))) + i);
            want[4 + i] = keccak256(abi.encode(list[i], uint256(2)));
            want[7 + i] = bytes32(uint256(keccak256(abi.encode(list[i], uint256(2)))) + 1);
        }
        want[10] = bytes32(uint256(4));
        want[11] = bytes32(uint256(5));
        _assertWritesExactly(diff, address(g), want);
        for (uint256 i; i < 3; ++i) {
            bytes32 hashSlot = bytes32(uint256(keccak256(abi.encode(list[i], uint256(2)))) + 1);
            assertEq(vm.load(address(g), hashSlot), list[i].codehash, "each admission's code hash, where it lies");
        }

        address[3] memory callers = [deployer, timelockKey, creator];
        for (uint256 i; i < callers.length; ++i) {
            bytes[3] memory calls = [
                abi.encodeCall(IOspexGames.approveReporter, (address(first), ReporterKind.FirstN, bytes32(0))),
                abi.encodeCall(IOspexGames.retireReporter, (address(first))),
                abi.encodeCall(IOspexGames.setTerms, ("nba", _terms(1)))
            ];
            for (uint256 c; c < calls.length; ++c) {
                vm.prank(callers[i], callers[i]);
                (bool ok, bytes memory err) = address(g).call(calls[c]);
                assertFalse(ok, "a write after deploy by something other than the timelock");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotTheTimelock.selector, callers[i]));
            }
        }
    }

    /// The same three calls from any address but the timelock's: each refused, nothing changed.
    /// Break: in setTerms(), delete the `onlyTimelock` modifier.
    function testFuzz_neverLine_nothingButTheTimelockChangesTheListOrTheTerms(address caller) public {
        vm.assume(caller != address(timelock));
        MockReporter fresh = new MockReporter(games);
        bytes[3] memory calls = [
            abi.encodeCall(IOspexGames.approveReporter, (address(fresh), ReporterKind.FirstN, address(fresh).codehash)),
            abi.encodeCall(IOspexGames.retireReporter, (address(first))),
            abi.encodeCall(IOspexGames.setTerms, ("", _terms(1)))
        ];
        bytes32 list = _viewList();
        for (uint256 c; c < calls.length; ++c) {
            vm.prank(caller, caller);
            (bool ok, bytes memory err) = address(games).call(calls[c]);
            assertFalse(ok, "a caller other than the timelock changed the list or the terms");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotTheTimelock.selector, caller));
        }
        assertEq(_viewList(), list);
        (, bool retired,) = games.getReporter(address(first));
        assertFalse(retired);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A contract other than the timelock carries its own wait on a change."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// With the timelock's delay at a minute, an hour and seven days, each of the three calls lands the moment
    /// the timelock runs it, after exactly its delay: a game made in the same second copies the change. The
    /// games set adds no wait of its own, and keeps no queue or pending change to read.
    /// Break: in approveReporter(), add `if (block.timestamp < 1_900_000_000) revert
    /// OspexGames__NotTheTimelock(msg.sender);`, a wait of its own until a fixed time.
    function test_neverLine_noWaitButTheTimelocks() public {
        uint256[3] memory delays = [DELAY, 1 hours, 7 days];
        for (uint256 i; i < delays.length; ++i) {
            uint256 d = delays[i];
            TimelockController t = new TimelockController(d, _one(timelockKey), _one(address(0)), address(0));
            MockReporter r1 = new MockReporter(IOspexGames(address(0)));
            address[] memory list = _one(address(r1));
            OspexGames g = new OspexGames(address(t), token, _launchTerms(), list, _kinds1(ReporterKind.FirstN), _hashes(list));
            MockReporter r2 = new MockReporter(IOspexGames(address(g)));
            Terms memory changed = _terms(5 hours);
            bytes[3] memory calls = [
                abi.encodeCall(IOspexGames.approveReporter, (address(r2), ReporterKind.FirstN, address(r2).codehash)),
                abi.encodeCall(IOspexGames.retireReporter, (address(r1))),
                abi.encodeCall(IOspexGames.setTerms, ("nba", changed))
            ];
            vm.startPrank(timelockKey);
            for (uint256 c; c < 3; ++c) {
                t.schedule(address(g), 0, calls[c], bytes32(0), bytes32(c), d);
            }
            vm.stopPrank();
            vm.warp(vm.getBlockTimestamp() + d);
            for (uint256 c; c < 3; ++c) {
                t.execute(address(g), 0, calls[c], bytes32(0), bytes32(c));
            }
            // The same second: a game made now has the new list and the new terms.
            vm.prank(creator);
            token.approve(address(g), FEE);
            vm.prank(creator, creator);
            uint256 game = g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
            (address[] memory r,) = g.getGameReporters(game);
            assertEq(r.length, 1, "the changed list");
            assertEq(r[0], address(r2), "the approved reporter");
            assertEq(g.getGameWindow(game), 5 hours, "the changed terms");
            (, bool retired,) = g.getReporter(address(r1));
            assertTrue(retired, "the retirement");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A retired reporter writes nothing more to any game." (The spec's chosen line under "Retiring a
    //  reporter".)
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A retired reporter is refused by name on every game that recorded it, for every report kind it could
    /// send, at every hour; games made after its retirement never record it. The retirement is checked before
    /// the report's kind or readings are read, so a void, a dispute record, a report with no kind and a report
    /// with a malformed reading are refused as from a retired reporter too.
    /// Break: in report(), delete `if (a.retired) revert OspexGames__ReporterRetired(msg.sender);`.
    function test_neverLine_aRetiredReporterWritesNothingMore() public {
        uint256 unstarted = _create();
        uint256 started = _create();
        vm.warp(DATE - 1 hours);
        _startBy(second, started, START);
        _retire(address(first));
        _retire(address(later));
        uint256 made = _create();

        uint64[3] memory times = [DATE - 1 hours, START + 1, START + WINDOW + 1];
        address[2] memory retiredOnes = [address(first), address(later)];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 w; w < retiredOnes.length; ++w) {
                Report[] memory reports = _everyKind(unstarted, started);
                for (uint256 x; x < reports.length; ++x) {
                    bytes32 before = _viewAll();
                    (bool ok, bytes memory err) = _send(retiredOnes[w], reports[x]);
                    assertFalse(ok, "a retired reporter wrote");
                    assertEq(
                        err, abi.encodeWithSelector(OspexGames.OspexGames__ReporterRetired.selector, retiredOnes[w])
                    );
                    assertEq(_viewAll(), before, "a refused report changed state");
                }
                (bool okMade, bytes memory errMade) = _send(retiredOnes[w], _startReport(made, START));
                assertFalse(okMade, "a retired reporter wrote a game made after its retirement");
                assertEq(
                    errMade,
                    abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, made, retiredOnes[w])
                );
            }
        }
        // Control: the reporter not retired writes on.
        vm.warp(START + 1);
        _scoreBy(second, started, HOME, AWAY);
        _startBy(second, unstarted, START);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A report from a reporter whose live code differs from the hash recorded at its approval is never
    //  accepted."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// After its approval a reporter's code is swapped, for other code that relays reports and for no code at
    /// all. Every report it sends is refused by name, for every report kind, at every hour, on every game that
    /// recorded it, and nothing changes; the hash it was approved with stays stored. With the approved code put
    /// back it writes again, since the check is the live code against the stored hash. It covers a first
    /// reporter the constructor admitted (first-n) and one the timelock approved (after-n). On a chain, code at
    /// an address changes only by a self-destruct and a redeploy at the same address; vm.etch stands for where
    /// that ends.
    /// Break: in report(), delete `if (found != a.codeHash) revert OspexGames__CodeChanged(msg.sender,
    /// a.codeHash, found);`. The swapped code then writes the start.
    function test_neverLine_aReporterWhoseCodeChangedWritesNothing() public {
        // Code of its own, unlike `first`'s, so that a check against another reporter's stored hash is seen.
        UnauthenticatedPlainReporter lateAfter =
            new UnauthenticatedPlainReporter(games, address(1), address(2), bytes32("approved later"));
        assertTrue(address(lateAfter).codehash != address(first).codehash, "two reporters, two codes");
        _approve(address(lateAfter), ReporterKind.AfterN);
        uint256 unstarted = _create();
        uint256 started = _create();
        vm.warp(DATE - 1 hours);
        _startBy(second, started, START);

        address other = address(new SwappedRelay(games));
        address[2] memory reporters = [address(first), address(lateAfter)];
        for (uint256 w; w < reporters.length; ++w) {
            address who = reporters[w];
            bytes memory approvedCode = who.code;
            bytes32 approved = who.codehash;
            (,, bytes32 stored) = games.getReporter(who);
            assertEq(stored, approved, "the hash stored at approval");

            // Other code, and no code.
            bytes[2] memory swaps = [other.code, bytes("")];
            for (uint256 s; s < swaps.length; ++s) {
                vm.etch(who, swaps[s]);
                bytes32 found = who.codehash;
                if (s == 0) assertEq(found, other.codehash, "the other code is there");
                else assertTrue(found == bytes32(0) || found == keccak256(""), "no code is there");
                assertTrue(found != approved);
                _assertCodeChangedRefused(who, approved, found, unstarted, started);
                (,, stored) = games.getReporter(who);
                assertEq(stored, approved, "a swap moved the stored hash");
            }
            vm.etch(who, approvedCode);
            assertEq(who.codehash, approved, "the approved code is back");
        }
        // Control: with the approved code back, each writes again.
        vm.warp(DATE - 1 hours);
        _startBy(first, unstarted, START);
        vm.warp(START + WINDOW);
        _take(address(lateAfter), _scoreReport(started, HOME, AWAY));
        assertEq(uint8(_status(started)), uint8(GameStatus.Scored));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The creation fee. "The creation fee goes to the transaction sender."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A courier sends the transaction, the reporter calls the games set, and the payout address rides inside
    /// the report. A score credits that payout address: not the courier, who is the transaction's sender and
    /// origin, not the reporter, and not the creator. Both kinds of reporter, each at an hour it may write. A
    /// payout address that happens to be the transaction's sender, as on the open path when a runner sends its
    /// own report, is credited as named (the open path's test below sends that way): what never happens is the
    /// sender taking the payout address's place.
    /// Break: in _writeScore(), change `_end(g, r.gameId, GameStatus.Scored, r.payout);` to
    /// `_end(g, r.gameId, GameStatus.Scored, tx.origin);`. The courier is credited instead.
    function test_neverLine_theSenderNeverTakesThePayoutAddressesPlace() public {
        address courier = makeAddr("courier");
        address to = makeAddr("the payout address in the report");
        uint256 a = _create();
        uint256 b = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, a, START);
        _startBy(first, b, START);

        vm.warp(START + 10); // inside n: a first-n reporter
        (bool ok, bytes memory err) = _sendAs(courier, first, _scoreReportTo(a, to));
        assertTrue(ok, vm.toString(err));
        vm.warp(START + WINDOW); // from start + n: an after-n reporter
        (ok, err) = _sendAs(courier, later, _scoreReportTo(b, to));
        assertTrue(ok, vm.toString(err));

        assertEq(games.getCredit(to), 2 * uint256(FEE), "the payout address in the report");
        address[5] memory never = [courier, address(first), address(later), creator, address(this)];
        for (uint256 i; i < never.length; ++i) {
            assertEq(games.getCredit(never[i]), 0, "credited an address the report did not name");
        }
        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NothingToWithdraw.selector, courier));
        games.withdraw();
        vm.prank(to);
        assertEq(games.withdraw(), 2 * uint256(FEE), "withdrawn");
        assertEq(token.balanceOf(to), 2 * uint256(FEE), "paid to the payout address");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "The creation fee goes to an address where it literally can't be withdrawn." The chain refuses those it
    //  can name: 0 and the rest of the reserved range up to 0xffff, the games set, the coin, and every address
    //  ever approved as a reporter. That any other payout address can call withdraw is for review.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A score naming address 0 as its payout is refused by name, and the game keeps its fee: nothing is
    /// credited, no coin moves, the game does not end. Control: the same report naming another address is
    /// taken, credits it, and that address withdraws.
    /// Break: in _checkPayout(), delete `if (payout == address(0)) revert OspexGames__NoPayout(kind);`. The
    /// score is then taken and the fee credited to address 0, which nothing can withdraw.
    function test_neverLine_aPayoutOfZeroIsRefused() public {
        _assertPayoutRefused(
            first, address(0), abi.encodeWithSelector(OspexGames.OspexGames__NoPayout.selector, ReportKind.Score)
        );
    }

    /// The same, naming an address from 1 to MAX_RESERVED_ADDRESS, the range set aside for precompiles and a
    /// chain's own contracts: the first precompile, the last one Ethereum has today (0x11), Polygon's P-256
    /// check (0x100), Polygon's native coin's contract (0x1010) and the range's last address. Each is refused
    /// by name, with the address. Control, beside the helper's own: 0x10000, the first address past the range,
    /// is credited and withdraws.
    /// Break: in _checkPayout(), delete `if (uint160(payout) <= uint160(MAX_RESERVED_ADDRESS)) revert
    /// OspexGames__PayoutIsReserved(kind, payout);`. The score is then taken and the fee credited to a
    /// precompile, which never calls withdraw.
    function test_neverLine_aPayoutOfAReservedAddressIsRefused() public {
        assertEq(games.MAX_RESERVED_ADDRESS(), address(0xffff), "the range's last address");
        address[5] memory reserved = [address(1), address(0x11), address(0x100), address(0x1010), address(0xffff)];
        for (uint256 i; i < reserved.length; ++i) {
            _assertPayoutRefused(
                first,
                reserved[i],
                abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsReserved.selector, ReportKind.Score, reserved[i])
            );
        }
        address past = address(0x10000);
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(game, past));
        assertEq(games.getCredit(past), FEE, "control: the first address past the range is credited");
        vm.prank(past);
        assertEq(games.withdraw(), FEE, "control: and withdraws");
        assertEq(token.balanceOf(past), FEE);
    }

    /// The same, naming the games set's own address.
    /// Break: in _checkPayout(), delete `if (payout == address(this)) revert
    /// OspexGames__PayoutIsTheGamesSet(kind);`. The score is then taken and the fee credited to the games set,
    /// which never calls its own withdraw.
    function test_neverLine_aPayoutOfTheGamesSetIsRefused() public {
        _assertPayoutRefused(
            first,
            address(games),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Score)
        );
    }

    /// The same, naming the coin's own address.
    /// Break: in _checkPayout(), delete `if (payout == address(i_token)) revert OspexGames__PayoutIsTheCoin(kind);`.
    /// The score is then taken and the fee credited to the coin, which never calls withdraw.
    function test_neverLine_aPayoutOfTheCoinIsRefused() public {
        _assertPayoutRefused(
            first, address(token), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheCoin.selector, ReportKind.Score)
        );
    }

    /// The same, naming the reporter that sends the report: a first-n reporter inside n, and an after-n reporter
    /// from start + n.
    /// Break: in _checkPayout(), delete `if (s_admissions[payout].kind != ReporterKind.None) revert
    /// OspexGames__PayoutIsAReporter(kind, payout);`. The score is then taken and the fee credited to the
    /// reporter, a contract with no call to withdraw.
    function test_neverLine_aPayoutOfTheSendingReporterIsRefused() public {
        _assertPayoutRefused(first, address(first), _isAReporter(address(first)));
        _assertPayoutRefused(later, address(later), _isAReporter(address(later)));
    }

    /// The same, naming a reporter other than the sender: another of the game's reporters, of each kind, and a
    /// reporter approved after the game was made, which is not on the game's copy.
    /// Break: in _checkPayout(), change `if (s_admissions[payout].kind != ReporterKind.None)` to
    /// `if (payout == msg.sender)`. Only the sender is then refused, and the score credits the other reporter.
    function test_neverLine_aPayoutOfAnyReporterIsRefused() public {
        _assertPayoutRefused(first, address(second), _isAReporter(address(second)));
        _assertPayoutRefused(first, address(later), _isAReporter(address(later)));

        uint256 game = _create();
        MockReporter newer = new MockReporter(games);
        _approve(address(newer), ReporterKind.FirstN);
        (address[] memory copied,) = games.getGameReporters(game);
        for (uint256 i; i < copied.length; ++i) {
            assertTrue(copied[i] != address(newer), "the newer reporter is on the game's copy");
        }
        _assertPayoutRefusedOn(game, first, address(newer), _isAReporter(address(newer)));
    }

    /// The same, naming a retired reporter: one of the game's own reporters, retired after the game was made,
    /// and one retired before the game was made, so never on its copy. A retired reporter keeps its admission,
    /// and the refusal with it.
    /// Break: in _checkPayout(), change `s_admissions[payout].kind != ReporterKind.None` to
    /// `s_admissions[payout].kind != ReporterKind.None && !s_admissions[payout].retired`. The score then credits
    /// the retired reporter.
    function test_neverLine_aPayoutOfARetiredReporterIsRefused() public {
        MockReporter gone = new MockReporter(games);
        _approve(address(gone), ReporterKind.AfterN);
        _retire(address(gone));
        uint256 game = _create();
        _retire(address(second));
        (, bool goneRetired,) = games.getReporter(address(gone));
        (, bool secondRetired,) = games.getReporter(address(second));
        assertTrue(goneRetired && secondRetired, "both retired");

        _assertPayoutRefusedOn(game, first, address(second), _isAReporter(address(second)));
        _assertPayoutRefused(first, address(gone), _isAReporter(address(gone)));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "On the open path, the creation fee goes anywhere but the runner named inside the sealed machine's
    //  statement." The games set's half: it credits the payout address inside the report, and no other. The
    //  statement's half is the open path's reporter's.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// An after-n reporter, the open path's kind, scores from start + n naming any address the chain does not
    /// refuse, under any fee. The runner sends its own report, through the reporter, so the address named is
    /// also the transaction's sender and origin. That address is credited the game's fee, once, and no other
    /// address's credit moves.
    /// Break: in _end(), change `s_credits[account] += fee;` to `s_credits[msg.sender] += fee;`. The reporter
    /// that sent the report is credited instead of the address it named. And a payout check that refused the
    /// transaction's origin, `if (payout == address(i_token) || payout == tx.origin) revert ...`, would refuse
    /// the runner's own report here.
    function testFuzz_neverLine_theFeeGoesToThePayoutInsideTheReport(address runner, uint96 fee) public {
        // Not an address the chain refuses as payout: the reserved range from 0, the games set, the coin, or a
        // reporter. Nor the cheatcode address, which cannot send.
        vm.assume(uint160(runner) > 0xffff && runner != address(games) && runner != address(token));
        vm.assume(runner != address(first) && runner != address(later) && runner != address(second));
        vm.assume(runner != address(vm));
        fee = uint96(bound(fee, 1, PURSE));
        _setTerms("", _feeTerms(fee));
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + WINDOW);

        address[7] memory others =
            [address(later), address(first), address(second), creator, address(this), stranger, payout];
        uint256[7] memory before;
        for (uint256 i; i < others.length; ++i) {
            before[i] = games.getCredit(others[i]);
        }
        uint256 runnerBefore = games.getCredit(runner);
        vm.recordLogs();
        (bool ok, bytes memory err) = _sendAs(runner, later, _scoreReportTo(game, runner));
        assertTrue(ok, string.concat("the runner's own report, naming itself, was refused: ", vm.toString(err)));
        _assertOneCredit(vm.getRecordedLogs(), game, runner, fee);

        assertEq(games.getCredit(runner), runnerBefore + fee, "the runner named in the report");
        for (uint256 i; i < others.length; ++i) {
            if (others[i] != runner) assertEq(games.getCredit(others[i]), before[i], "another address was credited");
        }
        assertEq(token.balanceOf(address(games)), fee, "the games set holds the fee, now credited");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A release pays anyone anything but their own stake, and the creator their own creation fee." The fee's
    //  half; the stakes are the betting set's.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Two creators and two fees: a game made at 1 USDC before the fee rose to 3, one made at 3 by another
    /// creator, one made at 3 whose start was written, and one at 3 with a dispute record. Once the day-30
    /// clock has run, a stranger releases three of them and their creator the fourth. Each creator is credited
    /// its own games' fees and the stranger nothing; no other credit moves; each creator withdraws exactly what
    /// it paid.
    /// Break: in _release(), change `_end(g, gameId, GameStatus.Released, g.creator);` to
    /// `_end(g, gameId, GameStatus.Released, msg.sender);`. Whoever releases the game is credited.
    function test_neverLine_aReleaseCreditsTheCreatorItsOwnFee() public {
        address other = makeAddr("another creator");
        _fund(other, address(games));
        uint256 g1 = _create();
        _setTerms("", _feeTerms(3 * FEE));
        vm.prank(other, other);
        uint256 g2 = games.createGame("nba", "Denver Nuggets", "Utah Jazz", DATE, _hints(), ANY_FEE);
        uint256 g3 = _create();
        uint256 g4 = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, g3, START);
        _startBy(first, g4, START);
        vm.warp(START + 1);
        _disputeBy(first, g4);
        assertEq(token.balanceOf(address(games)), 10 * uint256(FEE), "held: 1 + 3 + 3 + 3");

        vm.warp(START + DAY30);
        vm.recordLogs();
        _releaseBy(stranger, g1);
        _assertOneCredit(vm.getRecordedLogs(), g1, creator, FEE);
        vm.recordLogs();
        _releaseBy(stranger, g2);
        _assertOneCredit(vm.getRecordedLogs(), g2, other, 3 * FEE);
        _releaseBy(creator, g3);
        _releaseBy(stranger, g4);

        uint256[4] memory ids = [g1, g2, g3, g4];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(uint8(_status(ids[i])), uint8(GameStatus.Released), "released");
            assertEq(_held(ids[i]), 0, "a released game still holds its fee");
        }
        assertEq(games.getCredit(creator), 7 * uint256(FEE), "the creator: 1 + 3 + 3");
        assertEq(games.getCredit(other), 3 * uint256(FEE), "the other creator: 3");
        address[4] memory nobody = [stranger, payout, address(first), address(this)];
        for (uint256 i; i < nobody.length; ++i) {
            assertEq(games.getCredit(nobody[i]), 0, "a release credited someone else");
        }
        vm.prank(creator);
        games.withdraw();
        vm.prank(other);
        games.withdraw();
        assertEq(token.balanceOf(creator), PURSE, "the creator has back what it paid");
        assertEq(token.balanceOf(other), PURSE, "the other creator has back what it paid");
        assertEq(token.balanceOf(address(games)), 0, "the games set holds nothing");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A rejected report changes any game's state or moves any money; a second creation of the same real
    //  game shares a reporter list, a state or money with the first." Here, the money.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Two creations of the same real game each take and hold their own fee. The first ends by a score. Two
    /// reports are refused and neither credits anything or moves coin: a second score to the first, and a
    /// score to the second creation, whose start is not written. The second creation still holds its own fee,
    /// and only its own end pays it, to its own creator. (Every other refusal is in
    /// test_neverLine_rejectedReportChangesNothing, which checks the money too.) The second score is refused
    /// twice over, by the score's status check and by `_end`; the score to an unstarted game only by the first,
    /// which is what the break below reaches.
    /// Break: in _writeScore(), delete `if (status != GameStatus.Verified && status != GameStatus.Disputed)
    /// _refuseResult(r.gameId, status);`. The score to the unstarted second creation is then taken and credits
    /// its fee to that report's payout address.
    function test_neverLine_aRefusedReportMovesNoFeeAndTheSameRealGameHoldsItsOwn() public {
        address first2 = makeAddr("a second payout address");
        uint256 a = _create();
        uint256 b = _create(); // the same real game: same creator, league, teams, date and hints
        assertEq(token.balanceOf(address(games)), 2 * uint256(FEE), "each creation took its own fee");
        assertEq(_held(a), FEE, "a holds its fee");
        assertEq(_held(b), FEE, "b holds its fee");

        vm.warp(DATE - 1 hours);
        _startBy(first, a, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(a, payout));
        assertEq(_held(b), FEE, "b's fee moved with a's score");

        address[] memory accounts = new address[](4);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (payout, first2, creator, address(first));
        bytes32 money = _money(accounts);
        vm.recordLogs();
        (bool ok, bytes memory err) = _send(address(first), _scoreReportTo(a, first2));
        assertFalse(ok, "a second score was taken");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, a, GameStatus.Scored));
        assertEq(vm.getRecordedLogs().length, 0, "a refused report emitted");
        assertEq(_money(accounts), money, "a refused report moved money");

        vm.recordLogs();
        (ok, err) = _send(address(first), _scoreReportTo(b, first2));
        assertFalse(ok, "a score to a game with no start was taken");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, b));
        assertEq(vm.getRecordedLogs().length, 0, "a refused report emitted");
        assertEq(_money(accounts), money, "a refused report moved money");
        assertEq(_held(b), FEE, "b holds its fee");

        vm.warp(DATE + DAY30);
        _releaseBy(stranger, b);
        assertEq(games.getCredit(creator), FEE, "b's end credits b's own creator");
        vm.prank(payout);
        assertEq(games.withdraw(), FEE, "a's payout address");
        vm.prank(creator);
        assertEq(games.withdraw(), FEE, "b's creator");
        assertEq(token.balanceOf(address(games)), 0, "the games set holds nothing");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A term change or an approval reaches a game already made." For the fee: a game is credited what it
    //  holds, whatever its league's fee is today.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Games made at 1 USDC (the default), at 5 and at 0 as the default changes, and at 2 under its league's
    /// own terms; then the default goes to 7. Each game's end credits the fee it copied at its creation: up,
    /// down, to 0 and from 0, by the default terms and by a league's own. The coin the games set holds is what
    /// the games paid, all along.
    /// Break: in _end(), change `uint96 fee = g.terms.fee;` to `uint96 fee = s_defaultTerms.fee;`. Every end
    /// then credits today's default fee.
    function test_neverLine_aFeeChangeReachesNoGameAlreadyMade() public {
        uint256 g1 = _create(); // nba takes the default: 1
        _setTerms("", _feeTerms(5 * FEE));
        uint256 g2 = _create(); // 5
        _setTerms("", _feeTerms(0));
        uint256 g3 = _create(); // 0
        _setTerms("nba", _feeTerms(2 * FEE));
        uint256 g4 = _create(); // nba's own: 2
        _setTerms("", _feeTerms(7 * FEE));
        assertEq(token.balanceOf(address(games)), 8 * uint256(FEE), "held: 1 + 5 + 0 + 2");
        assertEq(games.getTerms("").fee, 7 * FEE, "the default today");

        vm.warp(DATE - 1 hours);
        _startBy(first, g1, START);
        _startBy(first, g3, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(g1, payout));
        assertEq(games.getCredit(payout), FEE, "g1 credits the 1 it holds");
        vm.recordLogs();
        _take(address(first), _scoreReportTo(g3, payout));
        assertEq(games.getCredit(payout), FEE, "g3, made at 0, credits nothing");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IOspexGames.FeeCredited.selector, "a fee of 0 was credited");
        }
        vm.warp(DATE + DAY30);
        _releaseBy(stranger, g2);
        assertEq(games.getCredit(creator), 5 * uint256(FEE), "g2 credits the 5 it holds");
        _releaseBy(stranger, g4);
        assertEq(games.getCredit(creator), 7 * uint256(FEE), "g4 credits the 2 it holds");
        assertEq(token.balanceOf(address(games)), 8 * uint256(FEE), "the coin held is what was paid");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A refused USDC transfer stops a game from ending, or a release from happening."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The coin refuses every transfer (paused): a score and a release each go through and credit, and only
    /// the withdrawals fail, until the coin takes transfers again. The coin blocks the payout address: the
    /// score goes through, and only that address's withdrawal fails. The coin blocks the games set itself:
    /// the release goes through, and only the withdrawal fails.
    /// Break: in _end(), change `s_credits[account] += fee;` to `i_token.safeTransfer(account, fee);`. The fee
    /// is then paid inside the end, and the paused coin refuses the score.
    function test_neverLine_aRefusedTransferStopsNoEnd() public {
        uint256 a = _create();
        uint256 b = _create();
        uint256 c = _create();
        uint256 d = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, a, START);
        _startBy(first, c, START);
        vm.warp(START + 10);

        // Paused.
        token.setPaused(true);
        _take(address(first), _scoreReportTo(a, payout));
        assertEq(uint8(_status(a)), uint8(GameStatus.Scored), "the score was written");
        vm.warp(DATE + DAY30); // the release's clock, from the date: b never starts
        _releaseBy(stranger, b);
        assertEq(uint8(_status(b)), uint8(GameStatus.Released), "the release was written");
        assertEq(games.getCredit(payout), FEE, "the score credited");
        assertEq(games.getCredit(creator), FEE, "the release credited");
        vm.prank(payout);
        vm.expectRevert(RefusingCoin.Paused.selector);
        games.withdraw();
        vm.prank(creator);
        vm.expectRevert(RefusingCoin.Paused.selector);
        games.withdraw();
        assertEq(games.getCredit(payout), FEE, "a refused withdrawal kept the credit");
        token.setPaused(false);
        vm.prank(payout);
        games.withdraw();
        vm.prank(creator);
        games.withdraw();
        assertEq(token.balanceOf(payout), FEE, "paid once the coin took transfers");

        // The payout address blocked.
        vm.warp(START + 10); // back inside c's clocks
        address blocked = makeAddr("a payout address the coin blocks");
        token.setBlocked(blocked, true);
        _take(address(first), _scoreReportTo(c, blocked));
        assertEq(uint8(_status(c)), uint8(GameStatus.Scored), "the score was written");
        vm.prank(blocked);
        vm.expectRevert(abi.encodeWithSelector(RefusingCoin.Blocked.selector, blocked));
        games.withdraw();
        token.setBlocked(blocked, false);
        vm.prank(blocked);
        assertEq(games.withdraw(), FEE, "paid once unblocked");

        // The games set blocked.
        vm.warp(DATE + DAY30); // d never starts: the release's clock, from the date
        token.setBlocked(address(games), true);
        _releaseBy(stranger, d);
        assertEq(uint8(_status(d)), uint8(GameStatus.Released), "the release was written");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(RefusingCoin.Blocked.selector, address(games)));
        games.withdraw();
        token.setBlocked(address(games), false);
        vm.prank(creator);
        assertEq(games.withdraw(), FEE, "paid once the games set was unblocked");
        assertEq(token.balanceOf(address(games)), 0, "the games set holds nothing");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A creation pulls more than the fee its caller named." Not in the spec's text: a line for this piece.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A creator reads the fee, 1 USDC, and allows the games set far more than that, as a standing allowance
    /// does. A raise to 100 USDC is queued in the timelock. While it waits, a creation naming the 1 it read
    /// takes 1. Then the raise runs first, and the same creation, naming the same 1, is refused by name before
    /// the coin is called: the call reaches no coin address, no game is made, and no coin moves. The creator
    /// read 100 and named it: the creation takes 100.
    /// Break: in createGame(), delete `if (terms.fee > maxFee) revert OspexGames__FeeAboveMax(terms.fee,
    /// maxFee);`. The same creation then takes the 100.
    function test_neverLine_aCreationPullsNoMoreThanTheFeeItsCallerNamed() public {
        address who = makeAddr("a creator with a standing allowance");
        token.mint(who, 1_000 * uint256(FEE));
        vm.prank(who);
        token.approve(address(games), type(uint256).max);
        uint256 named = games.getTerms("nba").fee;
        assertEq(named, FEE, "the fee the creator read");

        bytes memory raise = abi.encodeCall(IOspexGames.setTerms, ("", _feeTerms(100 * FEE)));
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, raise, bytes32(0), bytes32("raise"), DELAY);
        vm.prank(who, who);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), named);
        assertEq(token.balanceOf(who), 999 * uint256(FEE), "while the raise waits, the fee read");

        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        timelock.execute(address(games), 0, raise, bytes32(0), bytes32("raise"));
        assertEq(games.getTerms("nba").fee, 100 * FEE, "the raise ran first");
        uint256 count = games.gameCount();
        uint256 held = token.balanceOf(address(games));
        vm.startStateDiffRecording();
        vm.prank(who, who);
        (bool ok, bytes memory err) = address(games).call(
            abi.encodeCall(IOspexGames.createGame, ("nba", "Home", "Away", DATE, new Hint[](0), named))
        );
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertFalse(ok, "a creation took more than its caller named");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FeeAboveMax.selector, 100 * uint256(FEE), named));
        for (uint256 i; i < accesses.length; ++i) {
            assertTrue(accesses[i].account != address(token), "the coin was called");
        }
        assertEq(games.gameCount(), count, "a game was made");
        assertEq(token.balanceOf(who), 999 * uint256(FEE), "the creator's coin moved");
        assertEq(token.balanceOf(address(games)), held, "the games set's coin moved");

        vm.prank(who, who);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), 100 * uint256(FEE));
        assertEq(token.balanceOf(who), 899 * uint256(FEE), "control: named the new fee, it is taken");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An address not among a game's recorded reporters writes a start, a score, a void, a dispute record or
    //  a day-7 result to that game." Here, for a void, a dispute record and a day-7 result.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Outsiders of every kind: a stranger, the creator, the timelock, its key, a contract that was never
    /// approved, and a reporter approved after the games were made. Each sends a void and a dispute record to a
    /// started game, and a day-7 score, a day-7 void and an update to a disputed game, at start + n and past the
    /// day-7 clock: each is refused by name, emits nothing and changes nothing. Controls: the games' own
    /// reporters, of both kinds, are taken for each kind of report.
    /// Break: in report(), change `if (kind == ReporterKind.None) revert OspexGames__NotAReporter(r.gameId,
    /// msg.sender);` to `if (kind == ReporterKind.None && r.kind != ReportKind.Void) revert
    /// OspexGames__NotAReporter(r.gameId, msg.sender);`. An outsider's void is then taken.
    function test_neverLine_onlyRecordedReportersWriteAnEnd() public {
        address[] memory accounts = new address[](4);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (creator, payout, stranger, address(games));
        uint256 started = _create();
        uint256 disputed = _create();
        uint256 third = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, started, START);
        _startBy(first, disputed, START);
        _startBy(first, third, START);
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        MockReporter lateComer = new MockReporter(games);
        _approve(address(lateComer), ReporterKind.AfterN);

        address[6] memory outsiders =
            [stranger, creator, address(timelock), timelockKey, address(new Plain()), address(lateComer)];
        uint64[2] memory times = [START + WINDOW, START + 1 + DAY7];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 o; o < outsiders.length; ++o) {
                Report[5] memory reports = [
                    _voidReport(started),
                    _disputeReport(started),
                    _scoreReport(disputed, HOME, AWAY),
                    _voidReport(disputed),
                    _disputeReport(disputed)
                ];
                for (uint256 k; k < reports.length; ++k) {
                    _assertReportRefused(
                        outsiders[o],
                        reports[k],
                        abi.encodeWithSelector(
                            OspexGames.OspexGames__NotAReporter.selector, reports[k].gameId, outsiders[o]
                        ),
                        accounts
                    );
                }
            }
        }
        // Controls, at the later hour: the day-7 score by an after-n reporter; the void by a first-n one; a
        // dispute record by an after-n reporter and an update by a first-n one, then that game's day-7 void.
        _take(address(later), _scoreReportTo(disputed, payout));
        _take(address(first), _voidReportTo(started, payout));
        _take(address(later), _disputeReport(third));
        Report memory thirdUpdate = _disputeReport(third);
        thirdUpdate.readings[1].homeScore = HOME + 9; // a vote changed since the record: not a repeat
        _take(address(first), thirdUpdate);
        vm.warp(START + 1 + DAY7 + DAY7);
        _take(address(second), _voidReportTo(third, payout));
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Scored), "the day-7 score");
        assertEq(uint8(_status(started)), uint8(GameStatus.Voided), "the void");
        assertEq(uint8(_status(third)), uint8(GameStatus.Voided), "the day-7 void");
        assertEq(games.getCredit(payout), 3 * uint256(FEE), "each end credited the payout address once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An after-n reporter writes to a game before its start + n." Here, for a dispute record.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// An after-n reporter's dispute record is refused inside n by name, at the start, inside n and at
    /// start + n - 1, on a game with the default n and on one whose league gave it another; at start + n it is
    /// taken and the day-7 clock counts from then. A first-n reporter's record is taken from the start, and an
    /// after-n reporter's update inside n is refused the same way; its update from start + n is taken and moves
    /// nothing.
    /// Break: in _writeDispute(), change `_checkHour(g, r.gameId, kind);` to
    /// `_checkHour(g, r.gameId, ReporterKind.FirstN);`. The after-n reporter's dispute record inside n is then
    /// taken.
    function test_neverLine_afterNWritesNoDisputeRecordBeforeStartPlusN() public {
        _setTerms("nhl", _terms(3 hours));
        uint256 game = _create(); // nba: n is a day
        vm.prank(creator, creator);
        uint256 short_ = games.createGame("nhl", "Home", "Away", DATE, _hints(), ANY_FEE); // n is 3 hours
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        _startBy(first, short_, START);

        uint256[2] memory ids = [game, short_];
        uint64[2] memory windows = [WINDOW, 3 hours];
        for (uint256 i; i < ids.length; ++i) {
            uint64[3] memory inside = [START, START + windows[i] / 2, START + windows[i] - 1];
            for (uint256 t; t < inside.length; ++t) {
                vm.warp(inside[t]);
                bytes32 before = _viewAll();
                (bool ok, bytes memory err) = _send(address(later), _disputeReport(ids[i]));
                assertFalse(ok, "an after-n reporter's dispute record inside n was taken");
                assertEq(
                    err,
                    abi.encodeWithSelector(
                        OspexGames.OspexGames__InsideWindow.selector, ids[i], uint256(START) + windows[i]
                    )
                );
                assertEq(_viewAll(), before, "a refused report changed state");
            }
            vm.warp(START + windows[i]);
            _take(address(later), _disputeReport(ids[i]));
            assertEq(uint8(_status(ids[i])), uint8(GameStatus.Disputed), "taken at start + n");
            assertEq(games.getGameDisputedAt(ids[i]), START + windows[i], "the day-7 clock counts from the record");
        }

        vm.warp(DATE - 1 hours);
        uint256 early = _create();
        _startBy(first, early, START);
        vm.warp(START);
        _take(address(first), _disputeReport(early));
        (bool okUpdate, bytes memory errUpdate) = _send(address(later), _disputeReport(early));
        assertFalse(okUpdate, "an after-n reporter's update inside n was taken");
        assertEq(
            errUpdate,
            abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, early, uint256(START) + WINDOW)
        );
        vm.warp(START + WINDOW);
        Report memory lateUpdate = _disputeReport(early);
        lateUpdate.readings[1].homeScore = HOME + 9; // a vote changed since the record: not a repeat
        _take(address(later), lateUpdate);
        assertEq(games.getGameDisputedAt(early), START, "the update moved the clock");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A retirement scores, voids or settles anything; it only opens the release." Here, the second half.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Games in every open status (unverified, started, disputed), long before their day-30 clock, beside a
    /// scored game and a voided one, and a game made after a fourth, first-n reporter was approved. Retiring one
    /// of the three, then another, writes no game, moves no money and leaves each open game's release refused by
    /// name; retiring the last opens the release of each game that recorded only those three, at once, and still
    /// writes and credits nothing. The game that also recorded the fourth, still live and able to write its
    /// start, stays closed, though the approved list is not empty either way. Then anyone releases each open
    /// game, and the creator alone is credited. The ended games' release is refused as ended throughout.
    /// Break: in _everyReporterRetired(), change `if (!s_admissions[r.account].retired) return false;` to
    /// `if (s_admissions[r.account].retired) return true;`. One retirement then opens every release.
    function test_neverLine_aRetirementOnlyOpensTheRelease() public {
        vm.warp(DATE - 1 hours);
        uint256 unverified = _inStatus(GameStatus.Unverified);
        uint256 verified = _inStatus(GameStatus.Verified);
        uint256 disputed = _inStatus(GameStatus.Disputed);
        uint256 scored = _inStatus(GameStatus.Scored);
        vm.warp(DATE - 1 hours);
        uint256 voided = _inStatus(GameStatus.Voided);
        vm.warp(START + 2 days); // long before the day-30 clock
        MockReporter fourth = new MockReporter(games);
        _approve(address(fourth), ReporterKind.FirstN);
        uint256 withFourth = _create(); // records the three and the fourth
        uint256[3] memory open = [unverified, verified, disputed];
        uint256[2] memory ended = [scored, voided];
        GameStatus[2] memory endedStatuses = [GameStatus.Scored, GameStatus.Voided];
        address[] memory accounts = new address[](5);
        (accounts[0], accounts[1], accounts[2], accounts[3], accounts[4]) =
            (creator, payout, stranger, address(games), address(first));

        address[3] memory retiring = [address(later), address(second), address(first)];
        for (uint256 r; r < retiring.length; ++r) {
            bytes32 money = _money(accounts);
            bytes32 states = _gameStates();
            _retire(retiring[r]);
            assertEq(_money(accounts), money, "a retirement moved money");
            assertEq(_gameStates(), states, "a retirement wrote a game");
            bool last = r == retiring.length - 1;
            for (uint256 i; i < open.length; ++i) {
                assertEq(games.isEveryReporterRetired(open[i]), last, "every reporter retired");
                if (last) continue;
                (bool ok, bytes memory err) = _tryRelease(stranger, open[i]);
                assertFalse(ok, "a release opened before every reporter was retired");
                uint256 opensAt = uint256(DATE) + DAY30;
                assertEq(
                    err, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, open[i], opensAt)
                );
            }
            for (uint256 i; i < ended.length; ++i) {
                (bool ok, bytes memory err) = _tryRelease(stranger, ended[i]);
                assertFalse(ok, "an ended game was released");
                assertEq(
                    err,
                    abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, ended[i], endedStatuses[i])
                );
            }
        }
        for (uint256 i; i < open.length; ++i) {
            assertLt(uint8(_status(open[i])), uint8(GameStatus.Scored), "a retirement ended a game");
            assertEq(_held(open[i]), FEE, "a retirement credited a fee");
        }
        assertEq(games.getCredit(creator), 0, "a retirement credited the creator");
        // The game that recorded the fourth reporter, still live, is not one whose every reporter is retired:
        // its release waits for its clock, though every other game's is open and the list holds a reporter.
        (address[] memory listed,) = games.getApprovedReporters();
        assertEq(listed.length, 1, "the approved list holds the fourth reporter");
        assertFalse(games.isEveryReporterRetired(withFourth), "the fourth reporter is live");
        (bool okFourth, bytes memory errFourth) = _tryRelease(stranger, withFourth);
        assertFalse(okFourth, "a game with a live reporter was released early");
        assertEq(
            errFourth,
            abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, withFourth, uint256(DATE) + DAY30)
        );

        vm.recordLogs();
        _releaseBy(stranger, unverified);
        _assertOneCredit(vm.getRecordedLogs(), unverified, creator, FEE);
        _releaseBy(creator, verified);
        _releaseBy(makeAddr("anyone"), disputed);
        for (uint256 i; i < open.length; ++i) {
            assertEq(uint8(_status(open[i])), uint8(GameStatus.Released), "released at once");
            assertEq(_held(open[i]), 0, "a released game holds nothing");
        }
        assertEq(games.getCredit(creator), 3 * uint256(FEE), "the creator, each game's fee");
        assertEq(games.getCredit(stranger), 0, "a releaser was credited");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A release touches a game that has a score or a void; a score or a void is accepted after a release."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A released game, with a start and without, takes no start, score, void or dispute record from any
    /// reporter of either kind at any hour, and no second release, each refused by name, nothing emitted,
    /// nothing changed. A scored game and a voided game: a release of each is refused by name before the day-30
    /// clock, at it and long past it, by a stranger and by the creator, with every reporter live and then with
    /// every reporter retired; nothing changes and no second credit is made.
    /// Break: in release(), delete `if (status >= GameStatus.Scored) revert OspexGames__GameEnded(gameId,
    /// status);`. A release of a scored game before its clock is then refused as not open instead of as ended
    /// (and past its clock only by `_end`). A second break, the dispute record's: in _writeDispute(), delete
    /// `if (status != GameStatus.Verified && status != GameStatus.Disputed) _refuseResult(r.gameId, status);`.
    /// An update to a released game is then taken.
    function test_neverLine_noReleaseOfAnEndedGameAndNoEndAfterARelease() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, stranger);

        // Released games take nothing more.
        vm.warp(DATE - 1 hours);
        uint256 withStart = _create();
        uint256 noStart = _create();
        _startBy(first, withStart, START);
        vm.warp(START + DAY30);
        _releaseBy(stranger, withStart);
        _releaseBy(stranger, noStart);
        uint256[2] memory released = [withStart, noStart];
        MockReporter[3] memory reporters = [first, later, second];
        uint64[3] memory hours_ = [START + DAY30, START + DAY30 + DAY7, START + DAY30 + 365 days];
        for (uint256 t; t < hours_.length; ++t) {
            vm.warp(hours_[t]);
            for (uint256 g; g < released.length; ++g) {
                bytes memory want =
                    abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, released[g], GameStatus.Released);
                for (uint256 w; w < reporters.length; ++w) {
                    Report[4] memory reports = [
                        _startReport(released[g], START),
                        _scoreReport(released[g], HOME, AWAY),
                        _voidReport(released[g]),
                        _disputeReport(released[g])
                    ];
                    for (uint256 k; k < reports.length; ++k) {
                        _assertReportRefused(address(reporters[w]), reports[k], want, accounts);
                    }
                }
                (bool okAgain, bytes memory errAgain) = _tryRelease(creator, released[g]);
                assertFalse(okAgain, "a released game was released again");
                assertEq(errAgain, want, "the second release's refusal");
            }
        }
        assertEq(games.getCredit(creator), 2 * uint256(FEE), "each release credited the creator once");

        // Ended games are not released.
        vm.warp(DATE - 1 hours);
        uint256 scored = _inStatus(GameStatus.Scored);
        vm.warp(DATE - 1 hours);
        uint256 voided = _inStatus(GameStatus.Voided);
        uint256[2] memory ended = [scored, voided];
        GameStatus[2] memory endedStatuses = [GameStatus.Scored, GameStatus.Voided];
        address[2] memory callers = [stranger, creator];
        uint64[3] memory times = [START + WINDOW + 1, START + DAY30, START + DAY30 + 365 days];
        for (uint256 pass; pass < 2; ++pass) {
            if (pass == 1) {
                vm.warp(START + WINDOW + 1);
                _retire(address(first));
                _retire(address(later));
                _retire(address(second));
                assertTrue(games.isEveryReporterRetired(scored), "every reporter retired");
            }
            for (uint256 t; t < times.length; ++t) {
                for (uint256 i; i < ended.length; ++i) {
                    for (uint256 c; c < callers.length; ++c) {
                        vm.warp(times[t]);
                        bytes32 money = _money(accounts);
                        bytes32 state = _viewAll();
                        vm.recordLogs();
                        (bool ok, bytes memory err) = _tryRelease(callers[c], ended[i]);
                        assertFalse(ok, "an ended game was released");
                        assertEq(
                            err,
                            abi.encodeWithSelector(
                                OspexGames.OspexGames__GameEnded.selector, ended[i], endedStatuses[i]
                            ),
                            "the refusal"
                        );
                        assertEq(vm.getRecordedLogs().length, 0, "a refused release emitted");
                        assertEq(_money(accounts), money, "a refused release moved money");
                        assertEq(_viewAll(), state, "a refused release changed a game");
                    }
                }
            }
        }
        assertEq(games.getCredit(payout), 2 * uint256(FEE), "the score and the void each credited once");
        assertEq(games.getCredit(creator), 2 * uint256(FEE), "no release of an ended game credited");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A game ends twice, or a release discards a score that landed first." Before the day-30 clock the first
    //  end to land is the game's; from the clock the release is the only door.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// In the day-30 clock's last second, with nothing released: a score is taken, pays on its result, and the
    /// release after it, at the clock, is refused as ended; a void the same, on a second game. In the other
    /// order, a release lands at the clock on a third game, and the score, the void and a second release after
    /// it are refused as ended, by the status's name before the clock's. Each game credits once, to the end that
    /// landed.
    /// Break: in _end(), change `g.status = end;` to `if (end != GameStatus.Released) g.status = end;`. A
    /// release then credits the creator and leaves the game open, so the game ends again.
    function test_neverLine_aGameEndsOnceAndTheFirstEndWins() public {
        vm.warp(DATE - 1 hours);
        uint256 lateScore = _create();
        uint256 lateVoid = _create();
        uint256 releasedFirst = _create();
        _startBy(first, lateScore, START);
        _startBy(first, lateVoid, START);
        _startBy(first, releasedFirst, START);
        vm.warp(DATE + DAY30 - 1); // the clock's last second, nothing released

        vm.recordLogs();
        _take(address(later), _scoreReportTo(lateScore, payout));
        _assertOneCredit(vm.getRecordedLogs(), lateScore, payout, FEE);
        (uint32 h, uint32 a) = games.getGameScores(lateScore);
        assertEq(h, HOME, "the late score pays on its result");
        assertEq(a, AWAY, "the late score pays on its result");
        vm.recordLogs();
        _take(address(first), _voidReportTo(lateVoid, payout));
        _assertOneCredit(vm.getRecordedLogs(), lateVoid, payout, FEE);

        vm.warp(DATE + DAY30);
        (bool ok, bytes memory err) = _tryRelease(stranger, lateScore);
        assertFalse(ok, "a release discarded a score that landed first");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, lateScore, GameStatus.Scored));
        (ok, err) = _tryRelease(creator, lateVoid);
        assertFalse(ok, "a release discarded a void that landed first");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, lateVoid, GameStatus.Voided));

        vm.recordLogs();
        _releaseBy(stranger, releasedFirst);
        _assertOneCredit(vm.getRecordedLogs(), releasedFirst, creator, FEE);
        assertEq(uint8(_status(releasedFirst)), uint8(GameStatus.Released), "released");
        bytes memory releasedErr =
            abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, releasedFirst, GameStatus.Released);
        (ok, err) = _send(address(later), _scoreReportTo(releasedFirst, payout));
        assertFalse(ok, "a score after a release was taken");
        assertEq(err, releasedErr, "named as ended, not as past the clock");
        (ok, err) = _send(address(first), _voidReportTo(releasedFirst, payout));
        assertFalse(ok, "a void after a release was taken");
        assertEq(err, releasedErr, "named as ended, not as past the clock");
        (ok, err) = _tryRelease(creator, releasedFirst);
        assertFalse(ok, "a released game was released again");
        assertEq(err, releasedErr);

        assertEq(games.getCredit(payout), 2 * uint256(FEE), "the two late ends paid their payout address");
        assertEq(games.getCredit(creator), FEE, "the release paid the creator");
        assertEq(_held(lateScore) + _held(lateVoid) + _held(releasedFirst), 0, "every game ended");
        assertEq(token.balanceOf(address(games)), 3 * uint256(FEE), "three fees, all credited");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "From the day-30 clock the release is the only door." Not in the spec's text; ruled as a correction to it:
    //  a start, a score, a void, a dispute record or an update at or after the game's date plus the day-30 clock
    //  is refused, and a game still open then ends as a release.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A game with no start, a started game and a disputed game, at the day-30 clock, a week after it and a year
    /// after it: every report the game could otherwise take is refused by the clock's name, from a reporter of
    /// either kind, with nothing written, nothing emitted and no money moved: a start on the first, a score, a
    /// void and a dispute record on the second, a score, a void and an update on the third. A second before the
    /// clock the same reports are taken on three other games. In the clock's first second a start and then a
    /// void are refused on a fourth game with no start, and its release lands. Then anyone releases each open
    /// game, and the creator alone is credited: no payout address was paid past the clock.
    /// Break: in _writeScore(), delete `_checkDay30(g, r.gameId);`. A score at the day-30 clock is then taken.
    function test_neverLine_afterDay30TheOnlyDoorIsTheRelease() public {
        address[] memory accounts = new address[](4);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (creator, payout, stranger, address(games));
        vm.warp(DATE - 1 hours);
        uint256 open = _create();
        uint256 started = _create();
        uint256 disputed = _create();
        uint256 open2 = _create();
        uint256 started2 = _create();
        uint256 disputed2 = _create();
        uint256 raced = _create();
        _startBy(first, started, START);
        _startBy(first, disputed, START);
        _startBy(first, started2, START);
        _startBy(first, disputed2, START);
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        _disputeBy(first, disputed2);

        // A second before the clock: taken.
        vm.warp(DATE + DAY30 - 1);
        _startBy(first, open2, DATE + DAY);
        _take(address(later), _scoreReportTo(started2, payout));
        Report memory update2 = _disputeReport(disputed2); // an update: a vote changed, not a repeat
        update2.readings[1].homeScore = HOME + 9;
        _take(address(first), update2);
        _take(address(later), _voidReportTo(disputed2, payout)); // the day-7 void, long open
        assertEq(games.getCredit(payout), 2 * uint256(FEE), "the two ends before the clock paid their payout");

        // At the clock, a week after it and a year after it: refused by the clock's name.
        uint64[3] memory hours_ = [DATE + DAY30, DATE + DAY30 + DAY7, DATE + DAY30 + 365 days];
        MockReporter[2] memory kinds = [first, later];
        for (uint256 t; t < hours_.length; ++t) {
            vm.warp(hours_[t]);
            _assertReportRefused(address(first), _startReport(open, START), _pastDay30(open), accounts);
            for (uint256 w; w < kinds.length; ++w) {
                Report[6] memory reports = [
                    _scoreReport(started, HOME, AWAY),
                    _voidReport(started),
                    _disputeReport(started),
                    _scoreReport(disputed, HOME, AWAY),
                    _voidReport(disputed),
                    _disputeReport(disputed)
                ];
                for (uint256 k; k < reports.length; ++k) {
                    _assertReportRefused(address(kinds[w]), reports[k], _pastDay30(reports[k].gameId), accounts);
                }
            }
        }
        // The race in the clock's first second: a start, then a void, both refused; the release lands.
        vm.warp(DATE + DAY30);
        (bool ok, bytes memory err) = _send(address(first), _startReport(raced, DATE + DAY));
        assertFalse(ok, "a start at the clock was taken");
        assertEq(err, _pastDay30(raced));
        (ok, err) = _send(address(later), _voidReportTo(raced, payout));
        assertFalse(ok, "a void at the clock was taken");
        assertEq(err, _err1(OspexGames.OspexGames__StartNotWritten.selector, raced));
        vm.recordLogs();
        _releaseBy(creator, raced);
        _assertOneCredit(vm.getRecordedLogs(), raced, creator, FEE);

        // Then anyone releases each open game, and the creator alone is credited.
        vm.warp(DATE + DAY30 + 365 days);
        vm.recordLogs();
        _releaseBy(stranger, open);
        _assertOneCredit(vm.getRecordedLogs(), open, creator, FEE);
        _releaseBy(stranger, started);
        _releaseBy(makeAddr("anyone"), disputed);
        _releaseBy(stranger, open2);
        uint256[5] memory released = [open, started, disputed, open2, raced];
        for (uint256 i; i < released.length; ++i) {
            assertEq(uint8(_status(released[i])), uint8(GameStatus.Released), "released");
            assertEq(_held(released[i]), 0, "a released game holds its fee");
        }
        assertEq(games.getCredit(creator), 5 * uint256(FEE), "the creator, each released game's fee");
        assertEq(games.getCredit(payout), 2 * uint256(FEE), "a report past the clock paid its payout");
        assertEq(games.getCredit(stranger), 0, "a releaser was credited");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "No write after creation moves a clock." The day-30 clock counts from the date given at creation: a start
    //  written late or early, a dispute record and an update move it neither way.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The two directions. Late: with no start written, the release is refused a second before the date's clock;
    /// a start at the far end of its bound after the date, written in that second, leaves the release open at the
    /// clock, where the score and the void that follow are refused and the release lands: the creator, not the
    /// payout address, is credited. Early: at the date plus 29 days, with no start, a release is refused; a start
    /// at the far end of its bound before the date is written, and the release stays refused until the date's
    /// clock, with the same second named; a score in the clock's last second is taken and pays its payout. A
    /// dispute record and an update move the clock neither way.
    /// Break: in _day30(), change `return uint256(g.date) + g.terms.day30Clock;` to
    /// `return uint256(g.start != 0 ? g.start : g.date) + g.terms.day30Clock;`. A late start then moves the
    /// release a day out, and an early one a day in.
    function test_neverLine_noWriteMovesTheDay30Clock() public {
        vm.warp(DATE - 1 hours);
        uint256 lateGame = _create();
        uint256 earlyGame = _create();
        uint256 disputedGame = _create();
        _startBy(first, disputedGame, START);
        vm.warp(START + 1);
        _disputeBy(first, disputedGame);
        uint256 opensAt = uint256(DATE) + DAY30;

        // Late.
        vm.warp(DATE + DAY30 - 1);
        (bool ok, bytes memory err) = _tryRelease(creator, lateGame);
        assertFalse(ok, "the release opened before the date's clock");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, lateGame, opensAt));
        _startBy(first, lateGame, DATE + DAY);
        Report memory sameSecond = _disputeReport(disputedGame); // an update, in the same second: a vote changed
        sameSecond.readings[1].homeScore = HOME + 9;
        _take(address(first), sameSecond);
        vm.warp(DATE + DAY30);
        (ok, err) = _send(address(first), _scoreReportTo(lateGame, payout));
        assertFalse(ok, "a late start moved the clock: a score landed at it");
        assertEq(err, _pastDay30(lateGame));
        (ok, err) = _send(address(later), _voidReportTo(lateGame, payout));
        assertFalse(ok, "a late start moved the clock: a void landed at it");
        assertEq(err, _pastDay30(lateGame));
        vm.recordLogs();
        _releaseBy(creator, lateGame);
        _assertOneCredit(vm.getRecordedLogs(), lateGame, creator, FEE);
        assertEq(games.getCredit(payout), 0, "a result past the clock took the fee");
        _releaseBy(stranger, disputedGame); // the record and the update moved nothing: open at the date's clock
        assertEq(uint8(_status(disputedGame)), uint8(GameStatus.Released), "released at the date's clock");

        // Early.
        vm.warp(DATE + 29 days);
        bytes memory notOpen =
            abi.encodeWithSelector(OspexGames.OspexGames__ReleaseNotOpen.selector, earlyGame, opensAt);
        (ok, err) = _tryRelease(creator, earlyGame);
        assertFalse(ok);
        assertEq(err, notOpen);
        _startBy(first, earlyGame, DATE - DAY);
        (ok, err) = _tryRelease(creator, earlyGame);
        assertFalse(ok, "an early start opened the release a day early");
        assertEq(err, notOpen, "the same second named");
        vm.warp(DATE + DAY30 - 1);
        (ok, err) = _tryRelease(creator, earlyGame);
        assertFalse(ok, "the release opened before the date's clock");
        assertEq(err, notOpen);
        vm.recordLogs();
        _take(address(later), _scoreReportTo(earlyGame, payout));
        _assertOneCredit(vm.getRecordedLogs(), earlyGame, payout, FEE);
        (ok, err) = _tryRelease(creator, earlyGame);
        assertFalse(ok, "a release discarded a score that landed first");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, earlyGame, GameStatus.Scored));
        assertEq(games.getCredit(creator), 2 * uint256(FEE), "the two releases");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A dispute still open at the day-30 clock ends as a release, like any other game."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A dispute record a second before the day-30 clock: its day-7 clock would run a week past it. At the
    /// day-30 clock the void is refused by that clock's name, not the day-7 clock's, and so are an update and a
    /// score; anyone releases the game and the creator is credited; the record's time still reads. Control: a
    /// record written a week and a second before the clock gets its day-7 void in the clock's last second.
    /// Break: in release(), add `if (g.disputedAt != 0 && block.timestamp < uint256(g.disputedAt) +
    /// g.terms.day7Clock) revert OspexGames__InsideDay7Clock(gameId, uint256(g.disputedAt) + g.terms.day7Clock);`
    /// before `_release(g, gameId);`. The release then waits out a late dispute's day-7 clock.
    function test_neverLine_aDisputeOpenAtDay30ReleasesLikeAnyOther() public {
        vm.warp(DATE - 1 hours);
        uint256 lateRecord = _create();
        uint256 inTime = _create();
        _startBy(first, lateRecord, START);
        _startBy(first, inTime, START);
        vm.warp(DATE + DAY30 - DAY7 - 1);
        _disputeBy(later, inTime);
        vm.warp(DATE + DAY30 - 1);
        _disputeBy(first, lateRecord);
        assertEq(games.getGameDisputedAt(lateRecord), DATE + DAY30 - 1, "the record's time");
        vm.recordLogs();
        _take(address(later), _voidReportTo(inTime, payout)); // the day-7 void, in the clock's last second
        _assertOneCredit(vm.getRecordedLogs(), inTime, payout, FEE);

        vm.warp(DATE + DAY30);
        bytes memory closed = _pastDay30(lateRecord);
        (bool ok, bytes memory err) = _send(address(later), _voidReport(lateRecord));
        assertFalse(ok, "a void landed at the clock");
        assertEq(err, closed, "the void was refused by the day-7 clock, not the day-30 clock");
        (ok, err) = _send(address(first), _disputeReport(lateRecord));
        assertFalse(ok, "an update landed at the clock");
        assertEq(err, closed);
        (ok, err) = _send(address(first), _scoreReportTo(lateRecord, payout));
        assertFalse(ok, "a score landed at the clock");
        assertEq(err, closed);
        vm.recordLogs();
        _releaseBy(stranger, lateRecord);
        _assertOneCredit(vm.getRecordedLogs(), lateRecord, creator, FEE);
        assertEq(uint8(_status(lateRecord)), uint8(GameStatus.Released), "a dispute open at the clock released");
        assertEq(games.getGameDisputedAt(lateRecord), DATE + DAY30 - 1, "the record reads as history");
        assertEq(games.getCredit(stranger), 0, "the releaser was credited");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "Two readings in one report name the same seat." Ruled: the games set refuses a report its own readings
    //  contradict; a seat read twice is the first such shape.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A report of every kind, a start, a score, a dispute record, an update and a void, carrying two readings
    /// for one seat is refused by name with the second one's index, wherever the pair sits, for a seat at either
    /// end of the range; nothing is written, nothing credited. Controls: the same reports with seats 0 and 255
    /// beside the usual ones are taken.
    /// Break: in _checkReadings(), delete `seats |= seat;`. A repeated seat is then never seen.
    function test_neverLine_noTwoReadingsShareASeat() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        uint8[3][3] memory pairs = [[0, 1, 1], [0, 3, 0], [1, 2, 255]]; // (first index, second index, the seat)
        for (uint256 k; k < 5; ++k) {
            for (uint256 p; p < pairs.length; ++p) {
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
                        r = _disputeReport(game);
                    } else {
                        vm.warp(START + WINDOW);
                        r = _voidReport(game);
                    }
                }
                r.readings[pairs[p][0]].seat = pairs[p][2];
                r.readings[pairs[p][1]].seat = pairs[p][2];
                _assertReportRefused(
                    address(first),
                    r,
                    abi.encodeWithSelector(OspexGames.OspexGames__ReadingSeatRepeated.selector, uint256(pairs[p][1])),
                    accounts
                );
            }
        }
        // Controls: the two ends of the seat range beside the usual seats.
        vm.warp(DATE - 1 hours);
        uint256 game2 = _create();
        Report memory s = _startReport(game2, START);
        s.readings[0].seat = 0;
        s.readings[3].seat = 255;
        _take(address(first), s);
        vm.warp(START + 1);
        Report memory sc = _scoreReport(game2, HOME, AWAY);
        sc.readings[0].seat = 255;
        sc.readings[3].seat = 0;
        _take(address(first), sc);
        assertEq(uint8(_status(game2)), uint8(GameStatus.Scored), "control: taken");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A score is written that no final among its readings reads." Ruled: the games set refuses a report its own
    //  readings contradict.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A score whose numbers no reading reads as a final is refused by name, with the count the game needs at
    /// that clock (three inside n, two from start + n on a game with no record, three on a disputed game), inside
    /// n from a first-n reporter and after n from an after-n one: a 1-0 over three finals of 104-97; a score over
    /// readings with no final at all; a score whose numbers appear only in a reading answered without a final;
    /// the home and away swapped; one score of the two off by one, either way. Nothing is written, nothing
    /// credited. Control: the same score with two readings finals at its numbers, the count from start + n, is
    /// taken on the game with no record.
    /// Break: in _agreement(), change `return AGREE_AFTER_N;` to `return 0;`. A score no final reads is then taken
    /// on a game with no dispute record from start + n.
    function test_neverLine_aScoreNoFinalReadsIsRefused() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        vm.warp(DATE - 1 hours);
        uint256 plain = _create();
        uint256 disputed = _create();
        _startBy(first, plain, START);
        _startBy(first, disputed, START);
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        uint256[2] memory ids = [plain, disputed];
        uint256[2][2] memory needed = [[uint256(3), 2], [uint256(3), 3]]; // by game, then by hour
        uint64[2] memory hours_ = [START + 2, START + WINDOW];
        MockReporter[2] memory kinds = [first, later];
        Reading[] memory noFinals = _voidReadings();
        Reading[] memory onlyNoFinal = _voidReadings();
        onlyNoFinal[1] = Reading({seat: 2, kind: ReadingKind.AnsweredNoFinal, homeScore: 88, awayScore: 90});
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 t; t < hours_.length; ++t) {
                vm.warp(hours_[t]);
                Report[6] memory reports = [
                    _scoreReport(ids[i], 1, 0),
                    _scoreReport(ids[i], HOME, AWAY),
                    _scoreReport(ids[i], 88, 90),
                    _scoreReport(ids[i], AWAY, HOME),
                    _scoreReport(ids[i], HOME, AWAY + 1),
                    _scoreReport(ids[i], HOME + 1, AWAY)
                ];
                reports[0].readings = _scoreReadings(HOME, AWAY);
                reports[1].readings = noFinals;
                reports[2].readings = onlyNoFinal;
                reports[3].readings = _scoreReadings(HOME, AWAY);
                reports[4].readings = _scoreReadings(HOME, AWAY);
                reports[5].readings = _scoreReadings(HOME, AWAY);
                for (uint256 k; k < reports.length; ++k) {
                    _assertReportRefused(
                        address(kinds[t]),
                        reports[k],
                        abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 0, needed[i][t]),
                        accounts
                    );
                }
            }
        }
        // Control: two finals at the score's numbers, the count from start + n, on the game with no record.
        Report memory two = _scoreReportTo(plain, payout);
        two.readings = _voidReadings();
        two.readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        two.readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        vm.recordLogs();
        _take(address(later), two);
        _assertOneCredit(vm.getRecordedLogs(), plain, payout, FEE);
        (uint32 h, uint32 a) = games.getGameScores(plain);
        assertEq(h, HOME);
        assertEq(a, AWAY);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An undisputed score is written with fewer finals reading it than the program needs at that clock." The
    //  games set's half of "a score is written on fewer than two agreeing finals, or fewer than three inside the
    //  window": on a game with no dispute record a score needs three finals reading it inside n and two from
    //  start + n, the program's own counts, at the game's own n.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// On a game with no dispute record, a score on fewer finals than the program's count at that clock is
    /// refused by name with both counts: inside n, from a first-n reporter, one final (one of three) and two
    /// (two of three), at the start and a second before start + n; from start + n, that second included, from
    /// either kind, one final (one of two), at start + n and a week on. Under a league's own n of two hours,
    /// copied into the game, two finals are refused a second before the game's start + n and taken at it, while
    /// the default's game at that same second still needs three. Nothing is written, nothing credited. Controls:
    /// three finals inside n, and two from start + n from either kind, are taken.
    /// Break: in _agreement(), change `if (disputed || block.timestamp < uint256(g.start) + g.terms.window)
    /// return AGREE;` to `if (disputed) return AGREE;`. Two finals then settle a game with no record inside n.
    function test_neverLine_aScoreShortOfTheProgramsCountIsRefused() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        vm.warp(DATE - 1 hours);
        uint256 plain = _create();
        uint256 inside = _create();
        uint256 afterFirst = _create();
        uint256 afterLater = _create();
        _setTerms("nba", _terms(2 hours));
        uint256 narrow = _create(); // n = 2 hours, copied at creation
        _startBy(first, plain, START);
        _startBy(first, inside, START);
        _startBy(first, afterFirst, START);
        _startBy(first, afterLater, START);
        _startBy(first, narrow, START);
        bytes memory oneOfThree = abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 1, 3);
        bytes memory twoOfThree = abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 2, 3);
        bytes memory oneOfTwo = abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 1, 2);

        // Inside n, from a first-n reporter: one final and two, at the start and a second before start + n.
        uint64[2] memory insideHours = [START, START + WINDOW - 1];
        for (uint256 t; t < insideHours.length; ++t) {
            vm.warp(insideHours[t]);
            Report memory one = _scoreReportTo(plain, payout);
            one.readings = _finals(1);
            _assertReportRefused(address(first), one, oneOfThree, accounts);
            Report memory two = _scoreReportTo(plain, payout);
            two.readings = _finals(2);
            _assertReportRefused(address(first), two, twoOfThree, accounts);
        }
        // From start + n, from either kind: one final, at start + n and a week on.
        uint64[2] memory afterHours = [START + WINDOW, START + WINDOW + 7 days];
        MockReporter[2] memory kinds = [first, later];
        for (uint256 t; t < afterHours.length; ++t) {
            vm.warp(afterHours[t]);
            for (uint256 w; w < kinds.length; ++w) {
                Report memory one = _scoreReportTo(plain, payout);
                one.readings = _finals(1);
                _assertReportRefused(address(kinds[w]), one, oneOfTwo, accounts);
            }
        }
        // The game's own n: two finals a second before the narrow game's start + n, and at it, where the
        // default's game is still inside its n.
        vm.warp(uint256(START) + 2 hours - 1);
        Report memory early = _scoreReportTo(narrow, payout);
        early.readings = _finals(2);
        _assertReportRefused(address(first), early, twoOfThree, accounts);
        vm.warp(uint256(START) + 2 hours);
        Report memory wide = _scoreReportTo(plain, payout);
        wide.readings = _finals(2);
        _assertReportRefused(address(first), wide, twoOfThree, accounts);
        Report memory atN = _scoreReportTo(narrow, payout);
        atN.readings = _finals(2);
        _take(address(first), atN);
        assertEq(uint8(_status(plain)), uint8(GameStatus.Verified), "still open");
        // Controls: three finals inside n; two from start + n, from either kind.
        vm.warp(START + 2);
        Report memory three = _scoreReportTo(inside, payout);
        three.readings = _finals(3);
        vm.recordLogs();
        _take(address(first), three);
        _assertOneCredit(vm.getRecordedLogs(), inside, payout, FEE);
        vm.warp(START + WINDOW);
        Report memory twoFirst = _scoreReportTo(afterFirst, payout);
        twoFirst.readings = _finals(2);
        _take(address(first), twoFirst);
        Report memory twoLater = _scoreReportTo(afterLater, payout);
        twoLater.readings = _finals(2);
        _take(address(later), twoLater);
        assertEq(uint8(_status(narrow)), uint8(GameStatus.Scored), "the narrow game scored at its own n");
        assertEq(uint8(_status(inside)), uint8(GameStatus.Scored), "control: three finals inside n");
        assertEq(uint8(_status(afterFirst)), uint8(GameStatus.Scored), "control: two finals from start + n, first-n");
        assertEq(uint8(_status(afterLater)), uint8(GameStatus.Scored), "control: two finals from start + n, after-n");
        assertEq(games.getCredit(payout), 4 * uint256(FEE), "each score credited once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A void is written over finals that read the same in the count the program would have scored on." The
    //  games set's half of "the hour-24 void posts while any answering feed shows a final": a void over finals
    //  that agree in the program's count at the clock, two at hour 24 on a game with no record and three at day
    //  7 on a disputed game, is refused, since that is a score's agreement and the program scores on it; the
    //  readings a void does carry ride in its event as given.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A void whose readings hold as many finals that agree as a score needs at that clock is refused by name
    /// with the agreed numbers, from a reporter of either kind. At hour 24, on a game with no record, where two
    /// agree: two 104-97s beside two silents; two beside a 97-104 and a silent; three beside a silent; four;
    /// three among finals that differ. At day 7, on a disputed game, where three agree: three 104-97s beside a
    /// silent fourth; four; three among finals that differ. Nothing is written, nothing credited. Controls at
    /// hour 24: a void over one 104-97 beside three silents, one over a 104-97 beside a 97-104 and two silents,
    /// and one over a 104-97 beside a 104-90 (the same home score is not the same final) are taken; at day 7: a
    /// void over two 104-97s beside a 97-104 and a silent fourth, the program's own day-7 shape, and one over
    /// the 2-2 split are taken.
    /// Break: in _writeVoid(), delete `_checkVoidReadings(r.readings, _agreement(g, status ==
    /// GameStatus.Disputed));`. Every void above is then taken, at both clocks.
    function test_neverLine_aVoidOverAgreeingFinalsIsRefused() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        vm.warp(DATE - 1 hours);
        uint256 game = _create();
        uint256 oneFinal = _create();
        uint256 split = _create();
        uint256 sameHome = _create();
        uint256 day7 = _create();
        uint256 day7Program = _create();
        uint256 day7Split = _create();
        _startBy(first, game, START);
        _startBy(first, oneFinal, START);
        _startBy(first, split, START);
        _startBy(first, sameHome, START);
        _startBy(first, day7, START);
        _startBy(first, day7Program, START);
        _startBy(first, day7Split, START);
        vm.warp(START + 1);
        _disputeBy(first, day7);
        _disputeBy(first, day7Program);
        _disputeBy(first, day7Split);
        Reading[] memory four = new Reading[](4);
        Reading[] memory among = new Reading[](5);
        Reading[] memory twoTwo = new Reading[](4);
        for (uint256 i; i < 4; ++i) {
            four[i] = Reading({seat: uint8(i + 1), kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
            twoTwo[i] = Reading({seat: uint8(i + 1), kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        }
        twoTwo[0] = four[0];
        twoTwo[1] = four[1];
        among[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: 50, awayScore: 40});
        among[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        among[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        among[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: 60, awayScore: 61});
        among[4] = Reading({seat: 5, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        Reading[] memory twoAndOne = _finals(2); // two 104-97s beside a 97-104 and a silent
        twoAndOne[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        bytes memory want = abi.encodeWithSelector(OspexGames.OspexGames__FinalsAgree.selector, HOME, AWAY);
        MockReporter[2] memory kinds = [first, later];

        // Hour 24, on the game with no record, where two agree: the five shapes, from either kind.
        vm.warp(START + WINDOW);
        for (uint256 w; w < kinds.length; ++w) {
            Report memory r = _voidReportTo(game, payout);
            r.readings = _finals(2);
            _assertReportRefused(address(kinds[w]), r, want, accounts);
            r.readings = twoAndOne;
            _assertReportRefused(address(kinds[w]), r, want, accounts);
            r.readings = _scoreReadings(HOME, AWAY);
            _assertReportRefused(address(kinds[w]), r, want, accounts);
            r.readings = four;
            _assertReportRefused(address(kinds[w]), r, want, accounts);
            r.readings = among;
            _assertReportRefused(address(kinds[w]), r, want, accounts);
        }
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "still open");
        // Controls at hour 24: one final beside silents; a 1-1 split; one 104-97 beside one 104-90.
        Report memory o = _voidReportTo(oneFinal, payout);
        o.readings = _finals(1);
        _take(address(first), o);
        Report memory s = _voidReportTo(split, payout);
        s.readings = _finals(1);
        s.readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        _take(address(later), s);
        Report memory h = _voidReportTo(sameHome, payout);
        h.readings = _finals(1);
        h.readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: 90});
        _take(address(later), h);

        // Day 7, on the disputed game, where three agree: the three shapes, refused by the same name, from
        // either kind; two that agree are not refused there (the controls below).
        vm.warp(START + 1 + DAY7);
        for (uint256 w; w < kinds.length; ++w) {
            Report memory d = _voidReportTo(day7, payout);
            d.readings = _scoreReadings(HOME, AWAY);
            _assertReportRefused(address(kinds[w]), d, want, accounts);
            d.readings = four;
            _assertReportRefused(address(kinds[w]), d, want, accounts);
            d.readings = among;
            _assertReportRefused(address(kinds[w]), d, want, accounts);
        }
        assertEq(uint8(_status(day7)), uint8(GameStatus.Disputed), "still disputed");
        // Controls at day 7: the program's own shape, two that agree beside a third that differs and a silent
        // fourth; and the 2-2 split.
        Report memory p = _voidReportTo(day7Program, payout);
        p.readings = twoAndOne;
        _take(address(later), p);
        Report memory ds = _voidReportTo(day7Split, payout);
        ds.readings = twoTwo;
        _take(address(first), ds);
        assertEq(uint8(_status(oneFinal)), uint8(GameStatus.Voided), "control: one final voids at hour 24");
        assertEq(uint8(_status(split)), uint8(GameStatus.Voided), "control: the 1-1 split voids at hour 24");
        assertEq(uint8(_status(sameHome)), uint8(GameStatus.Voided), "control: the same home score is not the same final");
        assertEq(uint8(_status(day7Program)), uint8(GameStatus.Voided), "control: the program's day-7 void");
        assertEq(uint8(_status(day7Split)), uint8(GameStatus.Voided), "control: the 2-2 split voids at day 7");
        assertEq(games.getCredit(payout), 5 * uint256(FEE), "each void credited once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A disputed game settles on fewer than three agreeing recorded sources." The games set's half, with the
    //  readings: a disputed game's score needs AGREE finals reading it, and before its day-7 clock no final
    //  reading otherwise; the reporter gate is test_neverLine_aDisputedGameScoresOnlyThroughTheReporterGate's.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// On a disputed game, inside n from a first-n reporter and after n from an after-n one, before the day-7
    /// clock: a score on two agreeing finals beside two silents is refused by name (two of three), as is one on
    /// two finals beside a reading answered without a final, and one on three agreeing finals beside a dissenting
    /// fourth is refused by the dissent's name; a score beside a dissenting final is refused on a game with no
    /// record too. Nothing is written, nothing credited. Controls: three agreeing finals beside a silent spare
    /// settle the disputed game at either hour, and at the day-7 clock the dissenting shape settles it.
    /// Break: in _writeScore(), change `disputed ? AGREE : 1` to `disputed ? 2 : 1`. A disputed game then
    /// settles on two finals.
    function test_neverLine_aDisputedGameSettlesOnlyOnAgreement() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        vm.warp(DATE - 1 hours);
        uint256 disputed = _create();
        uint256 plain = _create();
        uint256 settled = _create();
        uint256 atDay7 = _create();
        _startBy(first, disputed, START);
        _startBy(first, plain, START);
        _startBy(first, settled, START);
        _startBy(first, atDay7, START);
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        _disputeBy(first, settled);
        _disputeBy(first, atDay7);
        bytes memory twoOfThree = abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 2, 3);
        bytes memory dissents = abi.encodeWithSelector(OspexGames.OspexGames__FinalDissents.selector, 3);

        uint64[2] memory hours_ = [START + 2, START + WINDOW];
        MockReporter[2] memory kinds = [first, later];
        for (uint256 t; t < hours_.length; ++t) {
            vm.warp(hours_[t]);
            Report memory two = _scoreReportTo(disputed, payout);
            two.readings[2] = Reading({seat: 3, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
            _assertReportRefused(address(kinds[t]), two, twoOfThree, accounts);
            two.readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 88, awayScore: 90});
            _assertReportRefused(address(kinds[t]), two, twoOfThree, accounts);
            Report memory dissent = _scoreReportTo(disputed, payout);
            dissent.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
            _assertReportRefused(address(kinds[t]), dissent, dissents, accounts);
            Report memory plainDissent = _scoreReportTo(plain, payout);
            plainDissent.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: 1, awayScore: 1});
            _assertReportRefused(address(kinds[t]), plainDissent, dissents, accounts);
        }
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Disputed), "still disputed");
        // Controls.
        vm.warp(START + 2);
        vm.recordLogs();
        _take(address(second), _scoreReportTo(settled, payout)); // three agree, the spare silent, inside n
        _assertOneCredit(vm.getRecordedLogs(), settled, payout, FEE);
        vm.warp(START + WINDOW);
        _take(address(later), _scoreReportTo(disputed, payout)); // the same after n
        vm.warp(START + 1 + DAY7);
        Report memory day7 = _scoreReportTo(atDay7, payout);
        day7.readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        _take(address(first), day7); // three of four, one dissenting: the day-7 settlement
        assertEq(uint8(_status(settled)), uint8(GameStatus.Scored), "control: agreement inside n");
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Scored), "control: agreement after n");
        assertEq(uint8(_status(atDay7)), uint8(GameStatus.Scored), "control: the day-7 settlement");
        assertEq(games.getCredit(payout), 3 * uint256(FEE), "each score credited once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A disputed game's checks change." The counts a game with no record is held to move with its clock; a
    //  disputed game's do not: its score needs three finals reading it at every clock, and its day-7 void is
    //  refused over three that agree and not over two.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// On a disputed game the count is three at every clock: a score on two agreeing finals beside two silents
    /// is refused by name (two of three) inside n from a first-n reporter, at start + n and a week on from either
    /// kind, and at the day-7 clock, where a game with no record needs two; a day-7 void over three agreeing
    /// finals is refused by name, and one over two that agree beside a third that differs and a silent fourth is
    /// taken. Nothing is written by a refusal, nothing credited. Controls: three agreeing finals settle a
    /// disputed game at each of those clocks.
    /// Break: in _writeScore(), change `_agreement(g, disputed)` to `_agreement(g, false)`. A disputed game then
    /// settles on two finals from start + n.
    function test_neverLine_aDisputedGamesChecksKeepTheirCount() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        vm.warp(DATE - 1 hours);
        uint256 disputed = _create();
        uint256 voided = _create();
        uint256[4] memory settled = [_create(), _create(), _create(), _create()];
        _startBy(first, disputed, START);
        _startBy(first, voided, START);
        for (uint256 i; i < settled.length; ++i) {
            _startBy(first, settled[i], START);
        }
        vm.warp(START + 1);
        _disputeBy(first, disputed);
        _disputeBy(first, voided);
        for (uint256 i; i < settled.length; ++i) {
            _disputeBy(first, settled[i]);
        }
        bytes memory twoOfThree = abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 2, 3);
        bytes memory agree = abi.encodeWithSelector(OspexGames.OspexGames__FinalsAgree.selector, HOME, AWAY);
        uint64[4] memory clocks = [START + 2, START + WINDOW, START + WINDOW + 7 days, START + 1 + DAY7];
        MockReporter[2] memory kinds = [first, later];
        for (uint256 t; t < clocks.length; ++t) {
            vm.warp(clocks[t]);
            for (uint256 w; w < kinds.length; ++w) {
                if (t == 0 && w == 1) continue; // an after-n reporter writes from start + n
                Report memory two = _scoreReportTo(disputed, payout);
                two.readings = _finals(2);
                _assertReportRefused(address(kinds[w]), two, twoOfThree, accounts);
            }
            // Control: three agreeing finals settle a disputed game at this clock.
            Report memory three = _scoreReportTo(settled[t], payout);
            three.readings = _finals(3);
            _take(address(kinds[t == 0 ? 0 : 1]), three);
            assertEq(uint8(_status(settled[t])), uint8(GameStatus.Scored), "control: three finals settle it");
        }
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Disputed), "still disputed");
        // The day-7 void: refused over three that agree, taken over two beside a third that differs.
        vm.warp(START + 1 + DAY7);
        Report memory v = _voidReportTo(voided, payout);
        v.readings = _finals(3);
        _assertReportRefused(address(later), v, agree, accounts);
        v.readings = _finals(2);
        v.readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        _take(address(later), v);
        assertEq(uint8(_status(voided)), uint8(GameStatus.Voided), "the program's day-7 void");
        assertEq(games.getCredit(payout), 5 * uint256(FEE), "each end credited once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A disputed game settles on fewer than three agreeing recorded sources." The games set's other half: a
    //  disputed game's score comes through the reporter gate like any other.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// On a disputed game, inside n and after it, before the day-7 clock and after: a score from a stranger, a
    /// retired reporter, a reporter whose code changed, a reporter approved after the game was made, and an
    /// after-n reporter inside n is refused by name and changes nothing; a score from a permitted reporter is
    /// taken at any of those hours, credits the payout address once, and nothing more is written.
    /// Break: in report(), change `if (kind == ReporterKind.None) revert OspexGames__NotAReporter(r.gameId,
    /// msg.sender);` to `if (kind == ReporterKind.None && g.status != GameStatus.Disputed) revert
    /// OspexGames__NotAReporter(r.gameId, msg.sender);`. A stranger then scores the disputed game.
    function test_neverLine_aDisputedGameScoresOnlyThroughTheReporterGate() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, stranger);
        MockReporter swapped = new MockReporter(games);
        _approve(address(swapped), ReporterKind.FirstN);
        MockReporter retiredOne = new MockReporter(games);
        _approve(address(retiredOne), ReporterKind.FirstN);
        vm.warp(DATE - 1 hours);
        uint256 game = _create(); // copies first, later, second, swapped and retiredOne
        _startBy(first, game, START);
        vm.warp(START + 1);
        _disputeBy(first, game);
        _retire(address(retiredOne));
        bytes32 approvedHash = address(swapped).codehash;
        vm.etch(address(swapped), address(new SwappedRelay(games)).code);
        bytes32 foundHash = address(swapped).codehash;
        MockReporter lateComer = new MockReporter(games);
        _approve(address(lateComer), ReporterKind.FirstN);

        uint64[4] memory times = [START + 2, START + WINDOW - 1, START + WINDOW, START + 1 + DAY7 + 1];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            address[5] memory senders =
                [stranger, address(retiredOne), address(swapped), address(lateComer), address(later)];
            bytes[5] memory why = [
                abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, stranger),
                abi.encodeWithSelector(OspexGames.OspexGames__ReporterRetired.selector, address(retiredOne)),
                abi.encodeWithSelector(
                    OspexGames.OspexGames__CodeChanged.selector, address(swapped), approvedHash, foundHash
                ),
                abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, address(lateComer)),
                abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, game, uint256(START) + WINDOW)
            ];
            uint256 count = t < 2 ? 5 : 4; // from start + n the after-n reporter is permitted
            for (uint256 s; s < count; ++s) {
                _assertReportRefused(senders[s], _scoreReportTo(game, payout), why[s], accounts);
            }
        }
        // Permitted: a first-n reporter, inside n and before the day-7 clock.
        vm.warp(START + 2);
        vm.recordLogs();
        _take(address(second), _scoreReportTo(game, payout));
        _assertOneCredit(vm.getRecordedLogs(), game, payout, FEE);
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored), "scored");
        bytes32 afterEnd = _viewAll();
        (bool okMore, bytes memory errMore) = _send(address(first), _disputeReport(game));
        assertFalse(okMore, "an update after the score was taken");
        assertEq(errMore, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, GameStatus.Scored));
        assertEq(_viewAll(), afterEnd, "something was written after the end");
        // Permitted too: an after-n reporter from start + n, and a first-n reporter past the day-7 clock.
        vm.warp(DATE - 1 hours);
        uint256 atN = _create();
        uint256 pastDay7 = _create();
        _startBy(first, atN, START);
        _startBy(first, pastDay7, START);
        vm.warp(START + 1);
        _disputeBy(first, atN);
        _disputeBy(first, pastDay7);
        vm.warp(START + WINDOW);
        _take(address(later), _scoreReportTo(atN, payout));
        vm.warp(START + 1 + DAY7 + 1);
        _take(address(first), _scoreReportTo(pastDay7, payout));
        assertEq(games.getCredit(payout), 3 * uint256(FEE), "each score credited once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "The hour-24 void posts while any answering feed shows a final." The readings a void carries ride in its
    //  event exactly as given, so the record can show them; the agreement rule behind them is the scoring
    //  program's, and the games set's own check of them is test_neverLine_aVoidOverAgreeingFinalsIsRefused.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A void whose readings show two finals that differ, beside an answer without a final and a silent, which is
    /// agreement in no count, is taken, and its event carries those readings exactly, feed by feed; the game
    /// reads Voided, no score, and its storage holds no reading.
    /// Break: in report(), change the emit's `r.readings` to `new Reading[](0)`. The void's readings are then
    /// lost.
    function test_neverLine_aVoidsReadingsRideInItsEventAsGiven() public {
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + WINDOW);
        Report memory r = _voidReport(game);
        r.readings = _readings(); // two feeds show a final, and here they differ
        r.readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: AWAY, awayScore: HOME});
        bytes memory raw = _rawGame(game);
        vm.recordLogs();
        _take(address(first), r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the credit and the report");
        assertEq(logs[1].topics[0], IOspexGames.GameReported.selector);
        assertEq(uint256(logs[1].topics[1]), game);
        assertEq(uint256(logs[1].topics[3]), uint256(ReportKind.Void));
        (uint64 start, uint32 h, uint32 a, Reading[] memory readings, address pay) =
            abi.decode(logs[1].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(uint256(start) + h + a, 0, "a void carries no start and no score");
        assertEq(pay, payout);
        assertEq(abi.encode(readings), abi.encode(r.readings), "the readings, as given");
        assertEq(uint8(_status(game)), uint8(GameStatus.Voided));
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, GameStatus.Voided));
        games.getGameScores(game);
        // The void wrote the status byte, took the game off the open list (its place is the first four bytes of
        // its fourth word, 0 from its end) and nothing else of the game: no reading is stored in the game's own
        // words.
        bytes memory rawAfter = _rawGame(game);
        assertEq(rawAfter.length, raw.length, "the game's storage grew");
        assertEq(uint8(rawAfter[31]), uint8(GameStatus.Voided), "the status byte");
        rawAfter[31] = raw[31];
        assertTrue(uint32(bytes4(abi.encodePacked(raw[96], raw[97], raw[98], raw[99]))) != 0, "the place before the void");
        assertEq(uint32(bytes4(abi.encodePacked(rawAfter[96], rawAfter[97], rawAfter[98], rawAfter[99]))), 0, "the place after the void");
        for (uint256 b = 96; b < 100; ++b) {
            rawAfter[b] = raw[b];
        }
        assertEq(rawAfter, raw, "a void wrote more than the status and the place");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A void is taken before start + n."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A void is refused by name with no start written, at any hour; and before the start, at the start, inside
    /// n and at start + n - 1, from a first-n reporter and from an after-n one, on a game with the default n and
    /// on one whose league gave it another. At start + n each kind's void is taken, credits the payout address
    /// and ends the game. A start written late, at start + n, opens the void at once.
    /// Break: in _writeVoid(), delete `if (block.timestamp < voidOpensAt) revert OspexGames__InsideWindow(
    /// r.gameId, voidOpensAt);`. A first-n reporter then voids at the start.
    function test_neverLine_noVoidBeforeStartPlusN() public {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, address(games));
        _setTerms("nhl", _terms(3 hours));
        vm.warp(DATE - 1 hours);
        uint256 unstarted = _create();
        uint256 game = _create();
        vm.prank(creator, creator);
        uint256 short_ = games.createGame("nhl", "Home", "Away", DATE, _hints(), ANY_FEE);
        _startBy(first, game, START);
        _startBy(first, short_, START);
        MockReporter[2] memory kinds = [first, later];

        uint64[3] memory anyHour = [DATE - 1 hours, START + WINDOW, START + DAY30];
        for (uint256 t; t < anyHour.length; ++t) {
            vm.warp(anyHour[t]);
            for (uint256 w; w < kinds.length; ++w) {
                (bool ok, bytes memory err) = _send(address(kinds[w]), _voidReport(unstarted));
                assertFalse(ok, "a game with no start was voided");
                assertEq(err, _err1(OspexGames.OspexGames__StartNotWritten.selector, unstarted));
            }
        }
        uint256[2] memory ids = [game, short_];
        uint64[2] memory windows = [WINDOW, 3 hours];
        for (uint256 i; i < ids.length; ++i) {
            uint64[4] memory early = [DATE - 1 hours, START, START + windows[i] / 2, START + windows[i] - 1];
            for (uint256 t; t < early.length; ++t) {
                vm.warp(early[t]);
                for (uint256 w; w < kinds.length; ++w) {
                    _assertReportRefused(
                        address(kinds[w]),
                        _voidReport(ids[i]),
                        abi.encodeWithSelector(
                            OspexGames.OspexGames__InsideWindow.selector, ids[i], uint256(START) + windows[i]
                        ),
                        accounts
                    );
                }
            }
            vm.warp(START + windows[i]);
            vm.recordLogs();
            _take(address(kinds[i]), _voidReportTo(ids[i], payout));
            _assertOneCredit(vm.getRecordedLogs(), ids[i], payout, FEE);
            assertEq(uint8(_status(ids[i])), uint8(GameStatus.Voided), "voided at start + n");
        }
        vm.warp(DATE - 1 hours);
        uint256 lateStart = _create();
        vm.warp(START + WINDOW);
        _startBy(first, lateStart, START);
        _take(address(later), _voidReport(lateStart));
        assertEq(uint8(_status(lateStart)), uint8(GameStatus.Voided), "a late start opens the void at once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A void is stored as a scored 0-0." Here, the void itself.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A void carrying a score is refused by name. A real void reads Voided, its score read refuses by name,
    /// and its storage holds no score; beside it a real 0-0 score reads Scored and 0-0, and a release reads
    /// Released: the three ends read apart by status, which is all the betting set reads.
    /// Break: in _writeVoid(), change `_end(g, r.gameId, GameStatus.Voided, r.payout);` to
    /// `_end(g, r.gameId, GameStatus.Scored, r.payout);`. The void is then stored as a scored 0-0.
    function test_neverLine_aVoidIsAStatusNotAScore() public {
        vm.warp(DATE - 1 hours);
        uint256 voided = _create();
        uint256 nil = _create();
        uint256 released = _create();
        _startBy(first, voided, START);
        _startBy(first, nil, START);
        _startBy(first, released, START);
        vm.warp(START + WINDOW);
        uint32[2][3] memory scores = [[HOME, AWAY], [uint32(0), uint32(1)], [uint32(1), uint32(0)]];
        for (uint256 i; i < scores.length; ++i) {
            Report memory r = _voidReport(voided);
            r.homeScore = scores[i][0];
            r.awayScore = scores[i][1];
            (bool ok, bytes memory err) = _send(address(first), r);
            assertFalse(ok, "a void carrying a score was taken");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Void));
        }
        _voidBy(first, voided);
        _scoreBy(first, nil, 0, 0);
        vm.warp(START + DAY30);
        _releaseBy(stranger, released);

        assertEq(uint8(_status(voided)), uint8(GameStatus.Voided), "a void is a status");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, voided, GameStatus.Voided));
        games.getGameScores(voided);
        bytes memory raw = _rawGame(voided);
        uint256 word0;
        assembly ("memory-safe") {
            word0 := mload(add(raw, 0x20))
        }
        assertEq((word0 >> 136) & 0xffffffff, 0, "a void stored a home score");
        assertEq((word0 >> 168) & 0xffffffff, 0, "a void stored an away score");
        assertEq(uint8(word0), uint8(GameStatus.Voided), "the status byte");

        assertEq(uint8(_status(nil)), uint8(GameStatus.Scored), "a written 0-0 is a score");
        (uint32 h, uint32 a) = games.getGameScores(nil);
        assertEq(uint256(h) + a, 0, "a written 0-0 reads 0-0");
        assertEq(uint8(_status(released)), uint8(GameStatus.Released), "a release is a status of its own");
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, released, GameStatus.Released));
        games.getGameScores(released);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "An update credits anything, or moves the day-7 clock."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A disputed game takes updates from its reporters of both kinds, inside n (the first-n kind), at
    /// start + n and a second before the day-7 clock runs: each is taken and emitted with its readings, credits
    /// nothing (no credit event, no credit moves, the fee stays held), writes nothing (the status, the record's
    /// time and the storage word for word are unchanged), and an update naming a payout is refused by name. The
    /// day-7 void opens at the first record plus the clock, not at the last update plus the clock: refused a
    /// second before, taken at it. On a second game an update past the day-7 clock is taken too, and the void
    /// after it.
    /// Break: in _writeDispute(), change `if (status == GameStatus.Verified) {` to
    /// `if (status <= GameStatus.Disputed) {`. Every update then moves the day-7 clock.
    function test_neverLine_anUpdateCreditsNothingAndMovesNoClock() public {
        vm.warp(DATE - 1 hours);
        uint256 game = _create();
        uint256 other = _create();
        _startBy(first, game, START);
        _startBy(first, other, START);
        vm.warp(START + 1);
        _disputeBy(first, game);
        _disputeBy(second, other);
        uint64 recordedAt = START + 1;
        assertEq(games.getGameDisputedAt(game), recordedAt, "the record's time");
        address[] memory accounts = new address[](7);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (creator, payout, stranger, address(first));
        (accounts[4], accounts[5], accounts[6]) = (address(later), address(second), address(games));
        bytes memory raw = _rawGame(game);

        uint64[3] memory times = [START + 2, START + WINDOW, recordedAt + DAY7 - 1];
        MockReporter[3] memory reporters = [first, later, second];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            for (uint256 w; w < reporters.length; ++w) {
                if (reporters[w] == later && times[t] < START + WINDOW) continue; // held by the hour, not here
                Report memory u = _disputeReport(game);
                // A reading changed since the record, and since every update before: a repeat is refused.
                u.readings[1].homeScore = HOME + 10 + uint32(t * 3 + w);
                _assertUpdateTaken(address(reporters[w]), u, accounts, raw, recordedAt);
            }
        }
        Report memory paid = _disputeReport(game);
        paid.payout = payout;
        (bool okPaid, bytes memory errPaid) = _send(address(first), paid);
        assertFalse(okPaid, "an update naming a payout was taken");
        assertEq(errPaid, abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Dispute));

        // The void opens at the first record plus the clock, whatever the updates since.
        vm.warp(recordedAt + DAY7 - 1);
        (bool okEarly, bytes memory errEarly) = _send(address(later), _voidReport(game));
        assertFalse(okEarly, "the day-7 void opened early");
        assertEq(
            errEarly,
            abi.encodeWithSelector(
                OspexGames.OspexGames__InsideDay7Clock.selector, game, uint256(recordedAt) + DAY7
            )
        );
        vm.warp(recordedAt + DAY7);
        vm.recordLogs();
        _take(address(later), _voidReportTo(game, payout));
        _assertOneCredit(vm.getRecordedLogs(), game, payout, FEE);
        assertEq(uint8(_status(game)), uint8(GameStatus.Voided), "the day-7 void");

        // Past the day-7 clock a disputed game still takes an update, and then its void.
        vm.warp(recordedAt + DAY7 + 3 days);
        Report memory lateUpdate = _disputeReport(other);
        lateUpdate.readings[1].homeScore = HOME + 9; // a reading changed since the record
        _take(address(first), lateUpdate);
        assertEq(games.getGameDisputedAt(other), recordedAt, "a late update moved the clock");
        assertEq(_held(other), FEE, "a late update credited the fee");
        _take(address(second), _voidReportTo(other, payout));
        assertEq(games.getCredit(payout), 2 * uint256(FEE), "each void credited once");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A game's stored identity differs from its creation event; a stored reading or vote differs from the
    //  reading it was emitted with; a game ends and stays on the open list, or is created and never joins it;
    //  a reader needs the events to know what a game is."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Every field the creation event carries is a read: the identity (getGameIdentity), the creator
    /// (getGameFee), the terms (getGameTerms) and the reporters (getGameReporters). Three creations at the
    /// limits (a league of one and of sixteen characters, teams of one character and of sixty-four with spaces
    /// inside, no hint and eight with ids of sixty-four characters, a date a year ahead) read back as their
    /// events say, field for field, and still do after the list and the terms change and more games are made.
    /// Break: in createGame(), change `identity.homeTeam = homeTeam;` to `identity.homeTeam = awayTeam;`.
    function test_neverLine_aGameIsReadableFromTheGame() public {
        string memory long = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01"; // 64
        Hint[] memory eight = new Hint[](8);
        for (uint256 j; j < 8; ++j) {
            eight[j] = Hint({seat: uint8(j * 31), id: string.concat(long, "")});
            eight[j].id = string.concat("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", vm.toString(j));
        }
        string[3] memory leagues = ["a", "abcdefghij123456", "nba"];
        string[3] memory homes = ["H", long, "Saint Mary's  (CA)"];
        string[3] memory aways = ["A", "Gonzaga Bulldogs 2026", " x "];
        uint64[3] memory dates = [uint64(1), uint64(vm.getBlockTimestamp() + 365 days), DATE];
        address[3] memory creators = [creator, address(this), stranger];
        _fund(stranger, address(games));
        uint256[3] memory made;
        CreatedEvent[3] memory events;
        for (uint256 i; i < 3; ++i) {
            Hint[] memory hints = i == 0 ? new Hint[](0) : i == 1 ? eight : _hints();
            vm.recordLogs();
            vm.prank(creators[i], creators[i]);
            made[i] = games.createGame(leagues[i], homes[i], aways[i], dates[i], hints, ANY_FEE);
            events[i] = _created(vm.getRecordedLogs(), made[i], creators[i]);
        }
        for (uint256 round; round < 2; ++round) {
            for (uint256 i; i < 3; ++i) {
                _assertReadsAsTheEvent(made[i], events[i], creators[i]);
            }
            // Then the list and the terms change and more games are made, none of which moves a game made.
            if (round == 0) {
                _retire(address(later));
                _approve(address(new MockReporter(games)), ReporterKind.AfterN);
                _setTerms("nba", _terms(2 hours));
                _setTerms("a", _terms(3 hours));
                _create();
                vm.prank(creator, creator);
                games.createGame("a", "H", "A", 1, new Hint[](0), ANY_FEE); // the same real game as the first
            }
        }
    }

    /// @dev Every read of the game against the creation event: the identity field for field, the hints seat and
    ///      id, the creator, the terms and the reporters with their kinds.
    function _assertReadsAsTheEvent(uint256 game, CreatedEvent memory e, address madeBy) internal view {
        (string memory league, string memory home, string memory away, uint64 date, Hint[] memory hints) =
            games.getGameIdentity(game);
        assertEq(league, e.league, "league");
        assertEq(home, e.homeTeam, "home");
        assertEq(away, e.awayTeam, "away");
        assertEq(date, e.date, "date");
        assertEq(hints.length, e.hints.length, "hint count");
        for (uint256 h; h < hints.length; ++h) {
            assertEq(hints[h].seat, e.hints[h].seat, "hint seat");
            assertEq(hints[h].id, e.hints[h].id, "hint id");
        }
        (, address creatorRead) = games.getGameFee(game);
        assertEq(creatorRead, madeBy, "creator");
        _assertTerms(games.getGameTerms(game), e.terms, "terms");
        (address[] memory r, uint8[] memory k) = games.getGameReporters(game);
        _assertList(r, k, e.reporters, e.kinds, "reporters");
    }

    /// @dev The game's creation event, decoded field for field, from the logs of its creation.
    function _created(Vm.Log[] memory logs, uint256 game, address madeBy) internal view returns (CreatedEvent memory e) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(games) || logs[i].topics[0] != IOspexGames.GameCreated.selector) continue;
            assertEq(uint256(logs[i].topics[1]), game, "the event's game");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(madeBy))), "the event's creator");
            return abi.decode(bytes.concat(abi.encode(uint256(32)), logs[i].data), (CreatedEvent));
        }
        revert("no GameCreated log");
    }

    /// The start's readings read back as the start's event carried them, a seat past the table included; each
    /// seat's last vote reads back as the program folds the dispute events: a record; an update that changes seat
    /// 2 and leaves seat 4 silent; an update from an after-n reporter at hour 24 in which seat 1 is silent (its
    /// vote stands), seat 3 answers without a final (its final taken back) and seat 4 votes for the first time;
    /// and an update before day 7 in which every seat is silent, which changes no vote. Each is compared with the
    /// readings decoded from the event the same report emitted, folded here by the program's rule, and the
    /// record's time reads beside them and never moves. After the day-7 void the readings still read.
    /// Break: in _writeVotes(), delete `if (reading.kind == ReadingKind.Silent) continue;`. A silent reading
    /// then overwrites a seat's vote.
    function test_neverLine_aStoredReadingIsTheReadingEmitted() public {
        vm.warp(DATE - 1 hours);
        uint256 game = _create();
        Report memory start = _startReport(game, START);
        start.readings[2] = Reading({seat: 200, kind: ReadingKind.AnsweredNoFinal, homeScore: 3, awayScore: 1});
        vm.recordLogs();
        _take(address(first), start);
        Reading[] memory startEmitted = _emittedReadings(vm.getRecordedLogs(), game);
        _assertSameReadings(startEmitted, start.readings, "the start event's readings are the start's");
        (Reading[] memory s0, Reading[] memory v0, uint64 at0) = games.getGameReadings(game);
        _assertSameReadings(s0, startEmitted, "the start's readings as emitted");
        assertEq(v0.length, 0, "no vote before a record");
        assertEq(at0, 0, "no record yet");

        Reading[][] memory emitted = new Reading[][](4);
        Report[4] memory reports;
        reports[0] = _disputeReport(game); // seats 1 and 2 finals that differ, 3 without a final, 4 silent
        reports[1] = _disputeReport(game);
        reports[1].readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        reports[2] = _disputeReport(game);
        reports[2].readings[0] = Reading({seat: 1, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        reports[2].readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY}); // its vote on record
        reports[2].readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 90, awayScore: 91});
        reports[2].readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});
        reports[3] = _disputeReport(game);
        for (uint256 i; i < 4; ++i) {
            reports[3].readings[i] = Reading({seat: uint8(i + 1), kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        }
        uint64[4] memory whens = [START + 1, START + 2, START + WINDOW, START + 1 + DAY7 - 1];
        MockReporter[4] memory whos = [first, second, later, first];
        for (uint256 i; i < 4; ++i) {
            vm.warp(whens[i]);
            vm.recordLogs();
            _take(address(whos[i]), reports[i]);
            emitted[i] = _emittedReadings(vm.getRecordedLogs(), game);
            _assertSameReadings(emitted[i], reports[i].readings, "the dispute event's readings are the report's");
            Reading[][] memory soFar = new Reading[][](i + 1);
            for (uint256 j; j <= i; ++j) {
                soFar[j] = emitted[j];
            }
            (Reading[] memory s, Reading[] memory v, uint64 at) = games.getGameReadings(game);
            _assertSameReadings(s, startEmitted, "the start's readings after a dispute report");
            _assertSameReadings(v, _foldVotes(soFar), "the votes after a dispute report");
            assertEq(at, START + 1, "the record's time");
        }
        // The fold, written out: seat 1 the record's final, seat 2 the first update's final, seat 3 the second
        // update's answer without a final, seat 4 the second update's final, in the order the seats first voted.
        (, Reading[] memory votes,) = games.getGameReadings(game);
        assertEq(votes.length, 4, "four seats voted");
        assertEq(votes[0].seat, 1);
        assertEq(uint8(votes[0].kind), uint8(ReadingKind.AnsweredFinal));
        assertEq(votes[0].homeScore, HOME);
        assertEq(votes[1].seat, 2);
        assertEq(votes[1].homeScore, HOME, "seat 2's changed vote");
        assertEq(votes[2].seat, 3);
        assertEq(uint8(votes[2].kind), uint8(ReadingKind.AnsweredNoFinal), "seat 3's final taken back");
        assertEq(votes[2].homeScore, 90);
        assertEq(votes[3].seat, 4);
        assertEq(uint8(votes[3].kind), uint8(ReadingKind.AnsweredFinal), "seat 4's first vote");

        vm.warp(START + 1 + DAY7);
        _take(address(later), _voidReportTo(game, payout));
        (Reading[] memory s4, Reading[] memory v4, uint64 at4) = games.getGameReadings(game);
        _assertSameReadings(s4, startEmitted, "the start's readings after the end");
        _assertSameReadings(v4, votes, "the votes after the end");
        assertEq(at4, START + 1, "the record's time after the end");
    }

    /// @dev The readings of the game's one GameReported log among `logs`.
    function _emittedReadings(Vm.Log[] memory logs, uint256 game) internal view returns (Reading[] memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(games) || logs[i].topics[0] != IOspexGames.GameReported.selector) continue;
            assertEq(uint256(logs[i].topics[1]), game, "the event's game");
            (,,, Reading[] memory readings,) = abi.decode(logs[i].data, (uint64, uint32, uint32, Reading[], address));
            return readings;
        }
        revert("no GameReported log");
    }

    /// Six games join the list at creation, in order. A refused report and a refused release leave it as it is.
    /// Each end takes exactly its game off: a score, the hour-24 void, the day-7 void, a release on every reporter
    /// retired, a release from the day-30 clock; the last game on the list moves into the ended one's place and
    /// nothing else moves; a second end is refused and moves nothing. At every step the list is exactly the games
    /// whose status is before Scored, each once, and every page agrees with the whole.
    /// Break: in _end(), delete `_leaveOpen(g);`. An ended game then stays on the list.
    function test_neverLine_aGameJoinsTheOpenListAtCreationAndLeavesAtItsEnd() public {
        vm.warp(DATE - 1 hours);
        uint256[] memory made = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            made[i] = _create();
            _assertOpenList(_prefix(made, i + 1), "after a creation");
        }
        for (uint256 i; i < 5; ++i) {
            _startBy(first, made[i], START);
        }
        _assertOpenList(made, "after the starts");
        // Refused: a stranger's score, a release before the clock, a start on a started game.
        (bool ok,) = _send(stranger, _scoreReport(made[0], HOME, AWAY));
        assertFalse(ok, "a stranger scored");
        (ok,) = _tryRelease(stranger, made[0]);
        assertFalse(ok, "a release before the clock");
        (ok,) = _send(address(first), _startReport(made[0], START));
        assertFalse(ok, "a second start");
        _assertOpenList(made, "after refusals");

        vm.warp(START + 1);
        _disputeBy(first, made[2]);
        _assertOpenList(made, "a dispute record ends nothing");
        _scoreBy(first, made[1], HOME, AWAY); // the last game, made[5], moves into made[1]'s place
        uint256[] memory want = new uint256[](5);
        (want[0], want[1], want[2], want[3], want[4]) = (made[0], made[5], made[2], made[3], made[4]);
        _assertOpenList(want, "after a score");
        (ok,) = _send(address(first), _scoreReport(made[1], HOME, AWAY));
        assertFalse(ok, "a second score");
        _assertOpenList(want, "a second end moves nothing");

        vm.warp(START + WINDOW);
        _voidBy(later, made[3]); // the hour-24 void: made[4] moves into its place
        want = new uint256[](4);
        (want[0], want[1], want[2], want[3]) = (made[0], made[5], made[2], made[4]);
        _assertOpenList(want, "after the hour-24 void");

        vm.warp(START + 1 + DAY7);
        _voidBy(first, made[2]); // the day-7 void: made[4] moves into its place
        want = new uint256[](3);
        (want[0], want[1], want[2]) = (made[0], made[5], made[4]);
        _assertOpenList(want, "after the day-7 void");

        _retire(address(first));
        _retire(address(later));
        _retire(address(second));
        _assertOpenList(want, "a retirement ends nothing");
        _releaseBy(stranger, made[4]); // every reporter retired: the last leaves, nothing moves
        want = new uint256[](2);
        (want[0], want[1]) = (made[0], made[5]);
        _assertOpenList(want, "after a release on every reporter retired");
        _releaseBy(stranger, made[5]); // a game with no start, its first-n reporters retired
        want = new uint256[](1);
        want[0] = made[0];
        _assertOpenList(want, "after the second such release");

        vm.warp(DATE + DAY30);
        _releaseBy(stranger, made[0]);
        _assertOpenList(new uint256[](0), "after the day-30 release");
        (ok,) = _tryRelease(stranger, made[0]);
        assertFalse(ok, "a second release");
        _assertOpenList(new uint256[](0), "a second release moves nothing");
    }

    /// @dev The open list is exactly `want`, in that order; each row of it, whole or paged, is the game's own
    ///      words; every page of it agrees with the whole; and every game made is on it exactly when its status
    ///      is before Scored, each once.
    function _assertOpenList(uint256[] memory want, string memory when) internal view {
        (OpenGame[] memory rows, uint256 total) = games.getOpenGames(0, type(uint256).max);
        uint256[] memory got = _idsOf(rows);
        assertEq(got, want, string.concat(when, ": the list"));
        assertEq(total, want.length, string.concat(when, ": the total"));
        for (uint256 i; i < rows.length; ++i) {
            _assertRowIsTheGame(rows[i], string.concat(when, ": a row"));
        }
        for (uint256 offset; offset <= want.length; ++offset) {
            (OpenGame[] memory page, uint256 t) = games.getOpenGames(offset, 2);
            assertEq(t, want.length, string.concat(when, ": a page's total"));
            uint256 n = offset >= want.length ? 0 : want.length - offset < 2 ? want.length - offset : 2;
            assertEq(page.length, n, string.concat(when, ": a page's length"));
            for (uint256 i; i < n; ++i) {
                assertEq(page[i].gameId, want[offset + i], string.concat(when, ": a page's entry"));
                _assertRowIsTheGame(page[i], string.concat(when, ": a page's row"));
            }
        }
        uint256 count = games.gameCount();
        for (uint256 id = 1; id <= count; ++id) {
            uint256 seen;
            for (uint256 i; i < got.length; ++i) {
                if (got[i] == id) ++seen;
            }
            bool open = _status(id) < GameStatus.Scored;
            assertEq(seen, open ? 1 : 0, string.concat(when, ": a game on the list other than once per open game"));
        }
    }

    function _prefix(uint256[] memory list, uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = list[i];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A dispute report that repeats the game's latest one, in the same order, is taken; or one that does not
    //  is refused as a repeat."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// The latest dispute report again is refused by name and writes nothing: no event, the votes, the record's
    /// time, the game's words and the open list as they were. The record again, from each of the game's
    /// reporters at its hour, inside n, at hour 24 and at day 7. Any other dispute report is taken, a return to
    /// an earlier one included: after an update that changes seat 2's vote, the update again is refused, the
    /// record's readings again are taken as an update and move seat 2's vote back, and then the update's
    /// readings, no longer the latest's, are taken again, while whichever was just taken is refused. The
    /// scoring program decides at day 7 from the votes on record, every seat closed by then, so a seat's genuine
    /// return to an earlier reading has to move its vote: the program's own sequences are settled in
    /// OspexGamesEnds.t.sol (test_readings_aReturnToEarlierReadings*). Controls: the latest's readings in
    /// another order are another report, taken, since a decision signed again is the same bytes; the same
    /// readings on another game are that game's own first record, taken; and at the day-30 clock the repeat is
    /// refused as every report is then, by the clock's name.
    /// Break: in _writeDispute(), delete `if (readings == s_lastDisputeReport[r.gameId]) revert
    /// OspexGames__DisputeReportRepeated(r.gameId);`. The latest again is then taken, and emits.
    function test_neverLine_onlyTheLatestDisputeReportAgainIsRefused() public {
        vm.warp(DATE - 1 hours);
        uint256 game = _create();
        uint256 other = _create();
        _startBy(first, game, START);
        _startBy(first, other, START);
        bytes memory refusal = abi.encodeWithSelector(OspexGames.OspexGames__DisputeReportRepeated.selector, game);
        Report memory record = _disputeReport(game);
        Report memory update = _disputeReport(game);
        update.readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: HOME, awayScore: AWAY});

        vm.warp(START + 1);
        _take(address(first), record);
        MockReporter[3] memory whos = [first, second, later];
        uint64[3] memory whens = [START + 2, START + WINDOW, START + 1 + DAY7];
        for (uint256 i; i < whens.length; ++i) {
            vm.warp(whens[i]);
            for (uint256 w; w < whos.length; ++w) {
                if (whos[w] == later && whens[i] < START + WINDOW) continue;
                _assertRepeatRefused(address(whos[w]), record, refusal);
            }
        }

        // At day 7, inside the day-30 clock: the update is taken and is the latest; the record, no longer the
        // latest, is taken again as a return; then the update again, no longer the latest, is taken too.
        _take(address(second), update);
        _assertVote(game, 2, HOME, "the update's vote");
        _assertRepeatRefused(address(first), update, refusal);
        _assertRepeatRefused(address(later), update, refusal);
        vm.recordLogs();
        _take(address(later), record);
        _assertSameReadings(_emittedReadings(vm.getRecordedLogs(), game), record.readings, "the return, emitted as given");
        _assertVote(game, 2, HOME + 3, "the vote moved back to the record's");
        assertEq(games.getGameDisputedAt(game), START + 1, "the record's time stands");
        assertEq(uint8(_status(game)), uint8(GameStatus.Disputed), "a return is an update");
        _assertRepeatRefused(address(first), record, refusal);
        _assertRepeatRefused(address(second), record, refusal);
        _take(address(first), update);
        _assertVote(game, 2, HOME, "the vote moved forward again");
        _assertRepeatRefused(address(later), update, refusal);

        // Controls.
        Report memory reordered = _disputeReport(game);
        reordered.readings[1] = update.readings[1];
        (reordered.readings[0], reordered.readings[1]) = (reordered.readings[1], reordered.readings[0]);
        _take(address(first), reordered); // the latest's readings in another order: another report
        Report memory onOther = _disputeReport(other);
        onOther.readings = reordered.readings;
        _take(address(second), onOther); // the same readings on the other game: its own first record
        assertEq(games.getGameDisputedAt(other), START + 1 + DAY7, "the other game's own record");
        _assertRepeatRefused(address(first), reordered, refusal); // the latest on its game

        vm.warp(DATE + DAY30);
        (bool ok, bytes memory err) = _send(address(first), reordered);
        assertFalse(ok, "a repeat at the day-30 clock was taken");
        assertEq(err, _pastDay30(game), "the clock names first");
    }

    /// @dev The repeat is refused by name, and nothing is written: no log, the game's words, its reads and the
    ///      open list as they were.
    function _assertRepeatRefused(address who, Report memory r, bytes memory refusal) internal {
        bytes memory raw = _rawGame(r.gameId);
        bytes32 everything = _gameStates();
        vm.recordLogs();
        (bool ok, bytes memory err) = _send(who, r);
        assertFalse(ok, "the latest dispute report again was taken");
        assertEq(err, refusal, "the refusal");
        assertEq(vm.getRecordedLogs().length, 0, "a refused repeat emitted");
        assertEq(_rawGame(r.gameId), raw, "a refused repeat wrote the game");
        assertEq(_gameStates(), everything, "a refused repeat changed what a reader sees");
    }

    /// @dev The vote on record for `seat` carries `home` as its home score.
    function _assertVote(uint256 game, uint8 seat, uint32 home, string memory what) internal view {
        (, Reading[] memory votes,) = games.getGameReadings(game);
        for (uint256 i; i < votes.length; ++i) {
            if (votes[i].seat == seat) {
                assertEq(votes[i].homeScore, home, what);
                return;
            }
        }
        revert(string.concat(what, ": no vote on record for the seat"));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "The creation fee goes to an address where it literally can't be withdrawn." Here, for a void: the same
    //  refusals as a score's.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A void naming as its payout address 0, a reserved address, the games set, the coin, the sending
    /// reporter, another of the game's reporters or a retired reporter is refused by name, with the void's kind
    /// in the refusal; nothing is emitted, no money moves and the game keeps its fee. The hour-24 void and the
    /// day-7 void alike. Control: the same void naming the payout address is taken, credits it, and it withdraws.
    /// Break: in _writeVoid(), delete `_checkPayout(ReportKind.Void, r.payout);`. A void naming address 0 is then
    /// taken and the fee credited to 0, which nothing can withdraw.
    function test_neverLine_aVoidRefusesThePayoutsAScoreRefuses() public {
        _assertVoidPayoutsRefused(false);
        _assertVoidPayoutsRefused(true);
    }

    /// @dev The seven refusals, for the hour-24 void (`disputed` false) or the day-7 void (`disputed` true).
    function _assertVoidPayoutsRefused(bool disputed) internal {
        MockReporter retiredOne = new MockReporter(games);
        _approve(address(retiredOne), ReporterKind.AfterN);
        _retire(address(retiredOne));
        address[7] memory bad = [
            address(0), address(0x1010), address(games), address(token), address(first), address(second), address(retiredOne)
        ];
        bytes[7] memory why = [
            abi.encodeWithSelector(OspexGames.OspexGames__NoPayout.selector, ReportKind.Void),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsReserved.selector, ReportKind.Void, address(0x1010)),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Void),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheCoin.selector, ReportKind.Void),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Void, address(first)),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Void, address(second)),
            abi.encodeWithSelector(
                OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Void, address(retiredOne)
            )
        ];
        address[] memory accounts = new address[](5);
        (accounts[0], accounts[1], accounts[2], accounts[3], accounts[4]) =
            (creator, payout, address(first), address(games), address(0));
        uint256 paid;
        for (uint256 i; i < bad.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 game = _create();
            _startBy(first, game, START);
            if (disputed) {
                vm.warp(START + 1);
                _disputeBy(first, game);
                vm.warp(START + 1 + DAY7);
            } else {
                vm.warp(START + WINDOW);
            }
            bytes32 money = _money(accounts);
            bytes32 state = _viewAll();
            vm.recordLogs();
            (bool ok, bytes memory err) = _send(address(first), _voidReportTo(game, bad[i]));
            assertFalse(ok, "a payout address that can never withdraw was taken for a void");
            assertEq(err, why[i], "the refusal");
            assertEq(vm.getRecordedLogs().length, 0, "a refused void emitted");
            assertEq(_money(accounts), money, "a refused void moved money");
            assertEq(_viewAll(), state, "a refused void changed a game");
            assertEq(_held(game), FEE, "the game keeps its fee");
            _take(address(first), _voidReportTo(game, payout));
            assertEq(uint8(_status(game)), uint8(GameStatus.Voided), "control: voided");
            vm.prank(payout);
            paid += games.withdraw();
        }
        assertEq(paid, bad.length * uint256(FEE), "control: each void credited the payout address, and it withdrew");
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    /// @dev One refused report: who sends what, at what hour, and the refusal it must get.
    struct Refusal {
        Report report;
        address from;
        bytes why;
        uint64 when;
    }

    function _refusal(Report memory report, address from, bytes memory why, uint64 when)
        internal
        pure
        returns (Refusal memory c)
    {
        c.report = report;
        c.from = from;
        c.why = why;
        c.when = when;
    }

    /// @dev The case is refused by name at its hour, emits nothing, changes no read and moves no money.
    function _assertRefused(Refusal memory c, address[] memory accounts, uint256 i) internal {
        vm.warp(c.when);
        bytes32 before = _viewAll();
        bytes32 money = _money(accounts);
        vm.recordLogs();
        (bool ok, bytes memory err) = _send(c.from, c.report);
        assertFalse(ok, string.concat("a rejected report was taken, case ", vm.toString(i)));
        assertEq(err, c.why, string.concat("refusal reason, case ", vm.toString(i)));
        assertEq(vm.getRecordedLogs().length, 0, string.concat("a rejected report emitted, case ", vm.toString(i)));
        assertEq(_viewAll(), before, string.concat("a rejected report changed state, case ", vm.toString(i)));
        assertEq(_money(accounts), money, string.concat("a rejected report moved money, case ", vm.toString(i)));
    }

    /// @dev `who`'s report is refused with `want`, emits nothing, changes no read and moves no money.
    function _assertReportRefused(address who, Report memory r, bytes memory want, address[] memory accounts)
        internal
    {
        bytes32 before = _viewAll();
        bytes32 money = _money(accounts);
        vm.recordLogs();
        (bool ok, bytes memory err) = _send(who, r);
        assertFalse(ok, "a report that must be refused was taken");
        assertEq(err, want, "the refusal");
        assertEq(vm.getRecordedLogs().length, 0, "a refused report emitted");
        assertEq(_viewAll(), before, "a refused report changed state");
        assertEq(_money(accounts), money, "a refused report moved money");
    }

    /// @dev `who`'s update `u` to the disputed `game` is taken and emitted with its readings and no payout, and
    ///      credits nothing, writes nothing and moves no clock: the money, the storage word for word, the
    ///      record's time, the status and the fee held read as before.
    function _assertUpdateTaken(
        address who,
        Report memory u,
        address[] memory accounts,
        bytes memory raw,
        uint64 recordedAt
    ) internal {
        uint256 game = u.gameId;
        bytes32 money = _money(accounts);
        vm.recordLogs();
        _take(who, u);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "an update emitted more than its report");
        assertEq(logs[0].topics[0], IOspexGames.GameReported.selector, "the report's event");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(who))), "the reporter");
        assertEq(uint256(logs[0].topics[3]), uint256(ReportKind.Dispute), "an update is a dispute report");
        (,,, Reading[] memory readings, address pay) =
            abi.decode(logs[0].data, (uint64, uint32, uint32, Reading[], address));
        assertEq(abi.encode(readings), abi.encode(u.readings), "the update's readings, as given");
        assertEq(pay, address(0), "an update names no payout");
        assertEq(_money(accounts), money, "an update moved money");
        assertEq(_rawGame(game), raw, "an update wrote the game");
        assertEq(games.getGameDisputedAt(game), recordedAt, "an update moved the day-7 clock");
        assertEq(uint8(_status(game)), uint8(GameStatus.Disputed), "an update moved the status");
        assertEq(_held(game), FEE, "an update credited the fee");
    }

    /// @dev A release of `game` at `when`, by a stranger and by the creator, is refused with `why`, emits
    ///      nothing, changes no read and moves no money.
    function _assertReleaseRefused(uint256 game, uint64 when, bytes memory why, address[] memory accounts) internal {
        address[2] memory callers = [stranger, creator];
        for (uint256 c; c < callers.length; ++c) {
            vm.warp(when);
            bytes32 before = _viewAll();
            bytes32 money = _money(accounts);
            vm.recordLogs();
            (bool ok, bytes memory err) = _tryRelease(callers[c], game);
            assertFalse(ok, "a rejected release was taken");
            assertEq(err, why, "refusal reason, release");
            assertEq(vm.getRecordedLogs().length, 0, "a rejected release emitted");
            assertEq(_viewAll(), before, "a rejected release changed state");
            assertEq(_money(accounts), money, "a rejected release moved money");
        }
    }

    /// @dev `by` scores a new game naming `bad` as the payout address: see _assertPayoutRefusedOn.
    function _assertPayoutRefused(MockReporter by, address bad, bytes memory why) internal {
        _assertPayoutRefusedOn(_create(), by, bad, why);
    }

    /// @dev `by` scores `game`, once started, naming `bad` as the payout address, at an hour it may write:
    ///      refused with `why`, nothing emitted, no game read and no money moved, and the game keeps its fee.
    ///      Then the same report naming `payout` is taken and credits it, and `payout` withdraws it.
    function _assertPayoutRefusedOn(uint256 game, MockReporter by, address bad, bytes memory why) internal {
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(by == later ? START + WINDOW : START + 10);

        address[] memory accounts = new address[](5);
        (accounts[0], accounts[1], accounts[2], accounts[3], accounts[4]) =
            (bad, address(by), creator, payout, address(games));
        bytes32 money = _money(accounts);
        bytes32 state = _viewAll();
        vm.recordLogs();
        (bool ok, bytes memory err) = _send(address(by), _scoreReportTo(game, bad));
        assertFalse(ok, "a payout address that can never withdraw was taken");
        assertEq(err, why, "the refusal");
        assertEq(vm.getRecordedLogs().length, 0, "a refused score emitted");
        assertEq(_money(accounts), money, "a refused score moved money");
        assertEq(_viewAll(), state, "a refused score changed a game");
        assertEq(_held(game), FEE, "the game keeps its fee");

        uint256 paid = token.balanceOf(payout);
        _take(address(by), _scoreReportTo(game, payout));
        assertEq(games.getCredit(payout), FEE, "control: the payout address is credited");
        vm.prank(payout);
        games.withdraw();
        assertEq(token.balanceOf(payout) - paid, FEE, "control: the payout address withdraws");
    }

    /// @dev The refusal of a score naming `reporter`, an address ever approved as a reporter, as its payout.
    function _isAReporter(address reporter) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Score, reporter);
    }

    /// @dev The logs hold exactly one FeeCredited, from the games set, for this game, account and amount.
    function _assertOneCredit(Vm.Log[] memory logs, uint256 gameId, address account, uint256 amount) internal view {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(games) || logs[i].topics[0] != IOspexGames.FeeCredited.selector) continue;
            ++found;
            assertEq(uint256(logs[i].topics[1]), gameId, "credited for another game");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), account, "credited another address");
            assertEq(abi.decode(logs[i].data, (uint256)), amount, "credited another amount");
        }
        assertEq(found, 1, "not one credit");
    }

    /// @dev Every report kind a reporter could send to two games, one unstarted and one started: a start, a
    ///      score, a void, a dispute record, a report with no kind, and a start with a malformed reading.
    function _everyKind(uint256 unstarted, uint256 started) internal view returns (Report[] memory out) {
        out = new Report[](6);
        out[0] = _startReport(unstarted, START);
        out[1] = _scoreReport(started, HOME, AWAY);
        out[2] = _voidReport(started);
        out[3] = _disputeReport(started);
        out[4] = _scoreReport(started, HOME, AWAY);
        out[4].kind = ReportKind.None;
        out[5] = _startReport(unstarted, START);
        out[5].readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 1, awayScore: 0});
    }

    /// @dev `who`, whose code hashes `found` where `approved` was recorded, sends every kind of report at every
    ///      hour: each is refused by name, emits nothing and changes nothing.
    function _assertCodeChangedRefused(address who, bytes32 approved, bytes32 found, uint256 unstarted, uint256 started)
        internal
    {
        uint64[3] memory times = [DATE - 1 hours, START + 1, START + WINDOW + 1];
        bytes memory want = abi.encodeWithSelector(OspexGames.OspexGames__CodeChanged.selector, who, approved, found);
        for (uint256 t; t < times.length; ++t) {
            vm.warp(times[t]);
            Report[] memory reports = _everyKind(unstarted, started);
            for (uint256 x; x < reports.length; ++x) {
                bytes32 before = _viewAll();
                vm.recordLogs();
                (bool ok, bytes memory err) = _send(who, reports[x]);
                assertFalse(ok, "a reporter whose code changed wrote");
                assertEq(err, want, "the refusal");
                assertEq(vm.getRecordedLogs().length, 0, "a refused report emitted");
                assertEq(_viewAll(), before, "a refused report changed state");
            }
        }
    }

    /// @dev Every game's status, start, scores, reporters and terms, each read as (taken, answer), and its
    ///      storage word for word, which holds the date no read returns: what a game is, without the one read a
    ///      retirement is meant to move.
    function _gameStates() internal view returns (bytes32) {
        uint256 count = games.gameCount();
        bytes memory out = abi.encode(count);
        for (uint256 id = 1; id <= count; ++id) {
            out = abi.encodePacked(out, keccak256(_rawGame(id)));
            bytes[7] memory calls = [
                abi.encodeCall(IOspexGames.getGameStatus, (id)),
                abi.encodeCall(IOspexGames.getGameStart, (id)),
                abi.encodeCall(games.getGameReporters, (id)),
                abi.encodeCall(IOspexGames.getGameScores, (id)),
                abi.encodeCall(IOspexGames.getGameTerms, (id)),
                abi.encodeCall(IOspexGames.getGameIdentity, (id)),
                abi.encodeCall(IOspexGames.getGameReadings, (id))
            ];
            for (uint256 c; c < calls.length; ++c) {
                (bool ok, bytes32 answer) = _hashCall(calls[c]);
                out = abi.encodePacked(out, ok, answer);
            }
        }
        out = abi.encodePacked(out, abi.encode(_openRows()));
        return keccak256(out);
    }

    /// @dev The stock timelock's refusal of a call to the games set that is not ready yet.
    function _notReady(bytes memory call, bytes32 callSalt) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector,
            timelock.hashOperation(address(games), 0, call, bytes32(0), callSalt),
            bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
        );
    }

    /// @dev The storage slots `account` wrote, each once, are exactly `want`.
    function _assertWritesExactly(VmSafe.AccountAccess[] memory diff, address account, bytes32[] memory want)
        internal
        pure
    {
        bytes32[] memory seen = new bytes32[](64);
        uint256 n;
        for (uint256 i; i < diff.length; ++i) {
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory s = diff[i].storageAccesses[j];
                if (s.account != account || !s.isWrite) continue;
                bool dup;
                for (uint256 k; k < n; ++k) {
                    if (seen[k] == s.slot) dup = true;
                }
                if (!dup) seen[n++] = s.slot;
            }
        }
        assertEq(n, want.length, "the deploy wrote another number of slots");
        for (uint256 i; i < want.length; ++i) {
            bool found;
            for (uint256 k; k < n; ++k) {
                if (seen[k] == want[i]) found = true;
            }
            assertTrue(found, "a slot of the first state was not written");
        }
    }

    /// @dev Every external call the contract has, from every kind of caller, the timelock key's address
    ///      included, against every game made so far. Refusals are expected; nothing may touch a game's list.
    ///      The timelock's three calls, made directly by any of these callers, are each refused.
    function _everyCallFromEveryone(uint256[] memory made) internal {
        address[6] memory callers =
            [timelockKey, deployer, creator, address(first), address(later), address(second)];
        address candidate = address(new MockReporter(games));
        for (uint256 c; c < callers.length; ++c) {
            bytes[3] memory timelockCalls = [
                abi.encodeCall(IOspexGames.approveReporter, (candidate, ReporterKind.FirstN, candidate.codehash)),
                abi.encodeCall(IOspexGames.retireReporter, (address(first))),
                abi.encodeCall(IOspexGames.setTerms, ("nba", _terms(1)))
            ];
            for (uint256 t; t < timelockCalls.length; ++t) {
                vm.prank(callers[c], callers[c]);
                (bool ok, bytes memory err) = address(games).call(timelockCalls[t]);
                assertFalse(ok, "a timelock call was taken from another caller");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotTheTimelock.selector, callers[c]));
            }
            for (uint256 m; m < made.length; ++m) {
                if (made[m] == 0) continue;
                for (uint8 kind; kind <= uint8(type(ReportKind).max); ++kind) {
                    Report memory r = _startReport(made[m], START);
                    r.kind = ReportKind(kind);
                    if (r.kind == ReportKind.Score) {
                        r.start = 0;
                        r.homeScore = HOME;
                    }
                    _send(callers[c], r);
                }
            }
            // Anyone may create a game, a reporter or the key included, and pays the fee to.
            if (token.allowance(callers[c], address(games)) == 0) _fund(callers[c], address(games));
            vm.prank(callers[c], callers[c]);
            games.createGame("nhl", "A", "B", DATE, _hints(), ANY_FEE);
            // And anyone may withdraw what it has been credited, which touches no game.
            vm.prank(callers[c], callers[c]);
            (bool paid,) = address(games).call(abi.encodeCall(IOspexGames.withdraw, ()));
            paid;
        }
    }

    function _createdReporters(Vm.Log[] memory logs)
        internal
        view
        returns (address[] memory reporters, uint8[] memory kinds)
    {
        bytes32 sig = IOspexGames.GameCreated.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(games) && logs[i].topics[0] == sig) {
                (,,,,,, reporters, kinds) = abi.decode(
                    logs[i].data, (string, string, string, uint64, Hint[], Terms, address[], uint8[])
                );
                return (reporters, kinds);
            }
        }
        revert("no GameCreated log");
    }

    function _setupList() internal view returns (address[] memory) {
        return _three(address(first), address(later), address(second));
    }

    function _setupKinds() internal pure returns (uint8[] memory) {
        return _kinds3(1, 2, 1);
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (a, b, c);
    }

    function _kinds3(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory list) {
        list = new uint8[](3);
        (list[0], list[1], list[2]) = (a, b, c);
    }

    function _assertList(
        address[] memory got,
        uint8[] memory gotKinds,
        address[] memory want,
        uint8[] memory wantKinds,
        string memory what
    ) internal pure {
        assertEq(got.length, want.length, what);
        assertEq(gotKinds.length, wantKinds.length, what);
        for (uint256 i; i < want.length; ++i) {
            assertEq(got[i], want[i], what);
            assertEq(gotKinds[i], wantKinds[i], what);
        }
    }

    function _err1(bytes4 selector, uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, id);
    }
}
