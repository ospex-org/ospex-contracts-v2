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
    Terms
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

    /// Break: in _writeScore(), delete `if (status != GameStatus.Verified) _refuseScore(r.gameId, status);`.
    /// A second score then overwrites the first.
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

    /// Break: in _writeScore(), delete `if (block.timestamp < start) revert OspexGames__BeforeStart(r.gameId,
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

    /// Break: in _writeScore(), delete `if (status != GameStatus.Verified) _refuseScore(r.gameId, status);`.
    /// A game with no start written then takes a score: its start is 0, so no time is before it.
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
        // Every status but Scored, with the score fields at 0-0 and then planted at a real-looking score.
        GameStatus[5] memory unscored = [
            GameStatus.Unverified, GameStatus.Verified, GameStatus.Disputed, GameStatus.Voided, GameStatus.Released
        ];
        uint32[2][2] memory fields = [[uint32(0), uint32(0)], [HOME, AWAY]];
        for (uint256 s; s < unscored.length; ++s) {
            for (uint256 f; f < fields.length; ++f) {
                uint256 game = _create();
                games.harnessSetStatus(game, unscored[s]);
                games.harnessSetScoreFields(game, fields[f][0], fields[f][1]);
                assertEq(uint8(_status(game)), uint8(unscored[s]), "status read");
                vm.expectRevert(
                    abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, unscored[s])
                );
                games.getGameScores(game);
            }
        }

        // Controls: a written 0-0 reads as scored 0-0, and a written score reads home then away.
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

    /// Every refusal the report call makes, each against games in each state the call can see. A refused
    /// report reverts, changes no read of any game, emits nothing, and moves no money: the coin the games set
    /// holds, every credit, every account's coin and every game's held fee read as before.
    /// Break: in report(), replace `revert OspexGames__ReportKindNotTaken(r.kind);` with nothing. A void is
    /// then "taken" without a revert, and an event announcing a void is emitted for a game that was not voided.
    function test_neverLine_rejectedReportChangesNothing() public {
        uint256 open = _create(); // Unverified
        uint256 verified = _create();
        uint256 scored = _create();
        uint256 tight = _create(); // for the after-n window
        uint256 ahead = _create(); // for a score before the start
        vm.warp(DATE - 1 hours);
        _startBy(first, verified, START);
        _startBy(first, scored, START);
        _startBy(first, tight, START);
        _startBy(first, ahead, START);
        vm.warp(START + 10);
        _scoreBy(first, scored, HOME, AWAY);
        uint256 unknown = games.gameCount() + 1;

        Report[] memory bad = new Report[](23);
        address[] memory from = new address[](23);
        bytes[] memory why = new bytes[](23);
        uint256 n;
        (bad[n], from[n], why[n]) = (_startReport(0, START), address(first), _err1(OspexGames.OspexGames__UnknownGame.selector, 0));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(unknown, START), address(first), _err1(OspexGames.OspexGames__UnknownGame.selector, unknown));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(open, START), makeAddr("x"), abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, open, makeAddr("x")));
        n++;
        Report memory r = _startReport(open, START);
        r.kind = ReportKind.None;
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__ReportKindNotTaken.selector, ReportKind.None));
        n++;
        r = _startReport(verified, 0);
        r.kind = ReportKind.Void;
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__ReportKindNotTaken.selector, ReportKind.Void));
        n++;
        r = _startReport(verified, 0);
        r.kind = ReportKind.Dispute;
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__ReportKindNotTaken.selector, ReportKind.Dispute));
        n++;
        r = _startReport(open, START);
        r.homeScore = 1;
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Start));
        n++;
        r = _scoreReport(verified, HOME, AWAY);
        r.start = START;
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Score));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReport(scored, 1, 2), address(first), abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(scored, START), address(second), abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, scored, GameStatus.Scored));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(verified, START + 1), address(second), _err1(OspexGames.OspexGames__StartAlreadyWritten.selector, verified));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(open, START), address(later), abi.encodeWithSelector(OspexGames.OspexGames__NotFirstN.selector, open, address(later)));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(open, DATE + DAY + 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, open, DATE + DAY + 1));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(open, DATE - DAY - 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, open, DATE - DAY - 1));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReport(open, HOME, AWAY), address(first), _err1(OspexGames.OspexGames__StartNotWritten.selector, open));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReport(tight, HOME, AWAY), address(later), abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, tight, uint256(START) + WINDOW));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReport(verified, games.MAX_SCORE() + 1, AWAY), address(first), abi.encodeWithSelector(OspexGames.OspexGames__ScoreOutOfRange.selector, games.MAX_SCORE() + 1, AWAY));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReport(verified, HOME, games.MAX_SCORE() + 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__ScoreOutOfRange.selector, HOME, games.MAX_SCORE() + 1));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReport(ahead, HOME, AWAY), address(first), abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, ahead, START));
        n++;
        r = _startReport(open, START);
        r.payout = payout;
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Start));
        n++;
        r = _startReport(open, START);
        r.readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 1, awayScore: 0});
        (bad[n], from[n], why[n]) = (r, address(first), abi.encodeWithSelector(OspexGames.OspexGames__SilentReadingNotEmpty.selector, 3));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReportTo(verified, address(games)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Score));
        n++;
        (bad[n], from[n], why[n]) = (_scoreReportTo(verified, address(first)), address(first), abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheReporter.selector, ReportKind.Score, address(first)));
        n++;
        assertEq(n, bad.length, "every case filled");

        address[] memory accounts = new address[](8);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (address(first), address(later), address(second), creator);
        (accounts[4], accounts[5], accounts[6], accounts[7]) = (payout, address(games), address(this), address(0));
        assertEq(token.balanceOf(address(games)), 5 * uint256(FEE), "five games' fees, one of them credited");
        for (uint256 i; i < n; ++i) {
            // The window case and the before-start case need their own clocks.
            if (i == 15) vm.warp(START + WINDOW - 1);
            else if (i == 18) vm.warp(DATE - 1 hours);
            else vm.warp(START + 10);
            bytes32 before = _viewAll();
            bytes32 money = _money(accounts);
            vm.recordLogs();
            (bool ok, bytes memory err) = _send(from[i], bad[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertFalse(ok, string.concat("a rejected report was taken, case ", vm.toString(i)));
            assertEq(err, why[i], string.concat("refusal reason, case ", vm.toString(i)));
            assertEq(logs.length, 0, string.concat("a rejected report emitted, case ", vm.toString(i)));
            assertEq(_viewAll(), before, string.concat("a rejected report changed state, case ", vm.toString(i)));
            assertEq(_money(accounts), money, string.concat("a rejected report moved money, case ", vm.toString(i)));
        }
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
    /// Break: in _writeScore(), change `if (kind == ReporterKind.AfterN && block.timestamp < opensAt)` to
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
    /// raw calldata in the spec's order. The contract reads the home score as the home score, and takes a seat
    /// above the reading kinds' range where the seat goes. (A seat of 4 in the kind's place would not decode.)
    /// Break: in IOspexGames.sol, swap the lines `uint32 homeScore;` and `uint32 awayScore;` in Report.
    function test_neverLine_aReportInTheSpecsOrderReadsBack() public {
        uint256 game = _create();
        bytes4 call =
            bytes4(keccak256("report((uint256,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address))"));
        SpecReading[] memory readings = new SpecReading[](2);
        readings[0] = SpecReading({seat: 4, kind: 2, homeScore: 104, awayScore: 97});
        readings[1] = SpecReading({seat: 3, kind: 0, homeScore: 0, awayScore: 0});

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
        assertEq(got.length, 2);
        assertEq(got[0].seat, 4);
        assertEq(got[0].kind, 2);
        assertEq(got[1].seat, 3);
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
    /// Break: in _writeScore(), change `uint256 opensAt = start + g.terms.window;` to
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
    // retirement writes no game. The contract holds no money yet, so the money half comes with the fee, and
    // the release comes with the ends.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Games in every status, each reporter retired in turn, the last leaving every game with every reporter
    /// retired: after each retirement every game's status, start, scores, reporters and terms read as before,
    /// its storage is unchanged word for word, the date included, and the only event is the retirement. What
    /// moves is the one thing a retirement opens: whether every reporter of a game is retired.
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
            uint256 game = _create();
            if (statuses[i] == GameStatus.Unverified) continue;
            _startBy(first, game, START);
            if (statuses[i] == GameStatus.Scored) {
                vm.warp(START + 1);
                _scoreBy(first, game, HOME, AWAY);
            } else if (statuses[i] != GameStatus.Verified) {
                games.harnessSetStatus(game, statuses[i]);
            }
        }
        uint256 last = _create(); // the newest game: Unverified, so a release of it shows
        assertEq(last, 7);

        address[3] memory retiring = [address(later), address(second), address(first)];
        for (uint256 r; r < retiring.length; ++r) {
            bytes32 before = _gameStates();
            vm.recordLogs();
            _retire(retiring[r]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_gameStates(), before, "a retirement changed a game");
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
            uint256 game = g.createGame("nba", "Home", "Away", DATE, new Hint[](0));
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
    /// the report's kind or readings are read, so a kind this contract does not take yet, and a report with a
    /// malformed reading, are refused as from a retired reporter too: the kinds the ends add inherit the check.
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
    /// own report, is credited as named: what never happens is the sender taking the payout address's place.
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
    // "The creation fee goes to an address where it literally can't be withdrawn." The chain refuses the
    //  three it can name; that any other payout address can call withdraw is for review.
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

    /// The same, naming the reporter that sends the report: a first-n reporter inside n, and an after-n reporter
    /// from start + n.
    /// Break: in _checkPayout(), delete `if (payout == msg.sender) revert OspexGames__PayoutIsTheReporter(kind,
    /// payout);`. The score is then taken and the fee credited to the reporter, a contract with no call to
    /// withdraw.
    function test_neverLine_aPayoutOfTheSendingReporterIsRefused() public {
        _assertPayoutRefused(
            first,
            address(first),
            abi.encodeWithSelector(
                OspexGames.OspexGames__PayoutIsTheReporter.selector, ReportKind.Score, address(first)
            )
        );
        _assertPayoutRefused(
            later,
            address(later),
            abi.encodeWithSelector(
                OspexGames.OspexGames__PayoutIsTheReporter.selector, ReportKind.Score, address(later)
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "On the open path, the creation fee goes anywhere but the runner named inside the sealed machine's
    //  statement." The games set's half: it credits the payout address inside the report, and no other. The
    //  statement's half is the open path's reporter's.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// An after-n reporter, the open path's kind, scores from start + n naming any address the chain does not
    /// refuse, under any fee: that address is credited the game's fee, once, and no other address's credit
    /// moves.
    /// Break: in _end(), change `s_credits[account] += fee;` to `s_credits[msg.sender] += fee;`. The reporter
    /// that sent the report is credited instead of the address it named.
    function testFuzz_neverLine_theFeeGoesToThePayoutInsideTheReport(address runner, uint96 fee) public {
        vm.assume(runner != address(0) && runner != address(games) && runner != address(later));
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
        _take(address(later), _scoreReportTo(game, runner));
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
    /// creator, one made at 3 whose start was written, and one at 3 with a dispute record. A stranger releases
    /// three of them and their creator the fourth. Each creator is credited its own games' fees and the stranger
    /// nothing; no other credit moves; each creator withdraws exactly what it paid. The releases go through the
    /// test harness's hook, which calls the production code's release credit; who may release a game, and
    /// when, is the release call's, not built yet.
    /// Break: in _release(), change `_end(g, gameId, GameStatus.Released, g.creator);` to
    /// `_end(g, gameId, GameStatus.Released, msg.sender);`. Whoever releases the game is credited.
    function test_neverLine_aReleaseCreditsTheCreatorItsOwnFee() public {
        address other = makeAddr("another creator");
        _fund(other, address(games));
        uint256 g1 = _create();
        _setTerms("", _feeTerms(3 * FEE));
        vm.prank(other, other);
        uint256 g2 = games.createGame("nba", "Denver Nuggets", "Utah Jazz", DATE, _hints());
        uint256 g3 = _create();
        uint256 g4 = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, g3, START);
        games.harnessSetStatus(g4, GameStatus.Disputed); // a dispute record, as the ends will write it
        assertEq(token.balanceOf(address(games)), 10 * uint256(FEE), "held: 1 + 3 + 3 + 3");

        vm.recordLogs();
        vm.prank(stranger);
        games.harnessRelease(g1);
        _assertOneCredit(vm.getRecordedLogs(), g1, creator, FEE);
        vm.recordLogs();
        vm.prank(stranger);
        games.harnessRelease(g2);
        _assertOneCredit(vm.getRecordedLogs(), g2, other, 3 * FEE);
        vm.prank(creator);
        games.harnessRelease(g3);
        vm.prank(stranger);
        games.harnessRelease(g4);

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
    /// Break: in _writeScore(), delete `if (status != GameStatus.Verified) _refuseScore(r.gameId, status);`.
    /// The score to the unstarted second creation is then taken and credits its fee to that report's payout
    /// address.
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

        vm.prank(stranger);
        games.harnessRelease(b);
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
        vm.prank(stranger);
        games.harnessRelease(g2);
        assertEq(games.getCredit(creator), 5 * uint256(FEE), "g2 credits the 5 it holds");
        vm.prank(stranger);
        games.harnessRelease(g4);
        assertEq(games.getCredit(creator), 7 * uint256(FEE), "g4 credits the 2 it holds");
        assertEq(token.balanceOf(address(games)), 8 * uint256(FEE), "the coin held is what was paid");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A refused USDC transfer stops a game from ending, or a release from happening." (10/21, a correction to
    //  the frozen text, carried into the spec since.)
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
        vm.prank(stranger);
        games.harnessRelease(b);
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
        token.setBlocked(address(games), true);
        vm.prank(stranger);
        games.harnessRelease(d);
        assertEq(uint8(_status(d)), uint8(GameStatus.Released), "the release was written");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(RefusingCoin.Blocked.selector, address(games)));
        games.withdraw();
        token.setBlocked(address(games), false);
        vm.prank(creator);
        assertEq(games.withdraw(), FEE, "paid once the games set was unblocked");
        assertEq(token.balanceOf(address(games)), 0, "the games set holds nothing");
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    /// @dev `by` scores a started game naming `bad` as the payout address, at an hour it may write: refused
    ///      with `why`, nothing emitted, no game read and no money moved, and the game keeps its fee. Then the
    ///      same report naming `payout` is taken and credits it, and `payout` withdraws it.
    function _assertPayoutRefused(MockReporter by, address bad, bytes memory why) internal {
        uint256 game = _create();
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
    ///      score, a report of each kind this contract does not take yet, and a start with a malformed reading.
    function _everyKind(uint256 unstarted, uint256 started) internal view returns (Report[] memory out) {
        out = new Report[](6);
        out[0] = _startReport(unstarted, START);
        out[1] = _scoreReport(started, HOME, AWAY);
        ReportKind[3] memory others = [ReportKind.None, ReportKind.Void, ReportKind.Dispute];
        for (uint256 i; i < others.length; ++i) {
            out[2 + i] = _scoreReport(started, HOME, AWAY);
            out[2 + i].kind = others[i];
        }
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
            bytes[5] memory calls = [
                abi.encodeCall(IOspexGames.getGameStatus, (id)),
                abi.encodeCall(IOspexGames.getGameStart, (id)),
                abi.encodeCall(games.getGameReporters, (id)),
                abi.encodeCall(IOspexGames.getGameScores, (id)),
                abi.encodeCall(IOspexGames.getGameTerms, (id))
            ];
            for (uint256 c; c < calls.length; ++c) {
                (bool ok, bytes memory answer) = address(games).staticcall(calls[c]);
                out = abi.encodePacked(out, ok, keccak256(answer));
            }
        }
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
            games.createGame("nhl", "A", "B", DATE, _hints());
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
