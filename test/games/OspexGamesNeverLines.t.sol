// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
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
    Hint
} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";

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
    /// msg.sender);`. Every outsider's score is then taken. (An outsider's start would still be refused, by
    /// the first-n check; the score case is the one this gate alone guards.)
    function test_neverLine_onlyRecordedReportersWrite() public {
        uint256 game = _create();

        // A later list, as approvals and retirements will make it: `first` stays, two reporters join.
        MockReporter lateFirst = new MockReporter(games);
        MockReporter lateAfter = new MockReporter(games);
        {
            address[] memory list = new address[](3);
            list[0] = address(lateAfter);
            list[1] = address(first);
            list[2] = address(lateFirst);
            ReporterKind[] memory kinds = new ReporterKind[](3);
            kinds[0] = ReporterKind.AfterN;
            kinds[1] = ReporterKind.FirstN;
            kinds[2] = ReporterKind.FirstN;
            games.harnessSetApproved(list, kinds);
        }
        uint256 laterGame = _create();

        address[] memory outsiders = new address[](10);
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

        // Starts: every outsider refused, nothing changes.
        for (uint256 i; i < outsiders.length; ++i) {
            bytes32 before = _viewAll();
            (bool ok, bytes memory err) = _send(outsiders[i], _startReport(game, START));
            assertFalse(ok, string.concat("start taken from outsider ", vm.toString(i)));
            assertEq(_viewAll(), before, "a refused start changed state");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotAReporter.selector, game, outsiders[i]));
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

    /// Break: in getGameReporters(), change `Reporter[] storage list = s_gameReporters[gameId];` to
    /// `Reporter[] storage list = s_approved;`. The first game's read then follows the list as it changes.
    function test_neverLine_reportersNeverChangeAfterCreation() public {
        vm.recordLogs();
        uint256 g1 = _create();
        (address[] memory created, uint8[] memory createdKinds) = _createdReporters(vm.getRecordedLogs());
        (address[] memory r1, uint8[] memory k1) = games.getGameReporters(g1);
        _assertList(r1, k1, _setupList(), _setupKinds(), "g1 as created");
        _assertList(created, createdKinds, r1, k1, "creation event = read");

        // Three later lists: an approval, a kind flipped on the same address, a removal and a reorder.
        MockReporter extra = new MockReporter(games);
        address[][] memory lists = new address[][](3);
        uint8[][] memory kindLists = new uint8[][](3);
        lists[0] = _three(address(first), address(later), address(extra));
        kindLists[0] = _kinds3(1, 2, 2);
        lists[1] = _three(address(later), address(first), address(extra));
        kindLists[1] = _kinds3(1, 2, 1); // `later` becomes first-n, `first` after-n
        lists[2] = new address[](1);
        lists[2][0] = address(extra);
        kindLists[2] = new uint8[](1);
        kindLists[2][0] = 1;

        uint256[] memory made = new uint256[](4);
        made[0] = g1;
        for (uint256 step; step < 3; ++step) {
            games.harnessSetApproved(lists[step], _toKinds(kindLists[step]));
            made[step + 1] = _create();
            _everyCallFromEveryone(made);

            (address[] memory now1, uint8[] memory nowK1) = games.getGameReporters(g1);
            _assertList(now1, nowK1, r1, k1, "g1 moved after a list change");
            for (uint256 j; j <= step; ++j) {
                (address[] memory rj, uint8[] memory kj) = games.getGameReporters(made[j + 1]);
                _assertList(rj, kj, lists[j], kindLists[j], "a later game moved");
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

        // A void is a status of its own, never the scored status.
        assertTrue(uint8(GameStatus.Voided) != uint8(GameStatus.Scored), "void is not scored");
        assertTrue(uint8(GameStatus.Released) != uint8(GameStatus.Scored), "release is not scored");

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
    /// report reverts, changes no read of any game, and emits nothing. This contract holds no money; the
    /// games set's dollar comes with the fee, and its half of this line with it.
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

        Report[] memory bad = new Report[](19);
        address[] memory from = new address[](19);
        bytes[] memory why = new bytes[](19);
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
        (bad[n], from[n], why[n]) = (_startReport(open, DATE + WINDOW + 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, open, DATE + WINDOW + 1));
        n++;
        (bad[n], from[n], why[n]) = (_startReport(open, DATE - WINDOW - 1), address(first), abi.encodeWithSelector(OspexGames.OspexGames__StartOutOfRange.selector, open, DATE - WINDOW - 1));
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
        assertEq(n, bad.length, "every case filled");

        for (uint256 i; i < n; ++i) {
            // The window case and the before-start case need their own clocks.
            if (i == 15) vm.warp(START + WINDOW - 1);
            else if (i == 18) vm.warp(DATE - 1 hours);
            else vm.warp(START + 10);
            bytes32 before = _viewAll();
            uint256 payoutBalance = payout.balance;
            vm.recordLogs();
            (bool ok, bytes memory err) = _send(from[i], bad[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertFalse(ok, string.concat("a rejected report was taken, case ", vm.toString(i)));
            assertEq(err, why[i], string.concat("refusal reason, case ", vm.toString(i)));
            assertEq(logs.length, 0, string.concat("a rejected report emitted, case ", vm.toString(i)));
            assertEq(_viewAll(), before, string.concat("a rejected report changed state, case ", vm.toString(i)));
            assertEq(address(games).balance, 0, "the games contract holds no money");
            assertEq(payout.balance, payoutBalance, "money moved");
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
        games.harnessSetApproved(_one(address(second)), _kinds1(ReporterKind.FirstN));
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
        Vm.Log[] memory logs = vm.getRecordedLogs();

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

    /// The one call's selector is the canonical signature of the one shape: the game, the kind, the start,
    /// the two scores, the readings (seat, kind, two scores) and the payout. A shape that differed by reporter
    /// would need a second call or a different tuple.
    /// Break: in IOspexGames.sol, swap the lines `uint64 start;` and `uint32 homeScore;` in Report.
    function test_neverLine_theReportShapeIsPinned() public pure {
        bytes4 expected =
            bytes4(keccak256("report((uint256,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address))"));
        assertEq(IOspexGames.report.selector, expected, "the report call's shape moved");
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
        games.harnessSetApproved(_one(address(later)), _kinds1(ReporterKind.FirstN));
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

    // ──────────────────────────── Helpers ──────────────────────────────

    /// @dev Every external call the contract has, from every kind of caller, the timelock key's address
    ///      included, against every game made so far. Refusals are expected; nothing may touch a game's list.
    function _everyCallFromEveryone(uint256[] memory made) internal {
        address[6] memory callers =
            [timelockKey, deployer, creator, address(first), address(later), address(second)];
        for (uint256 c; c < callers.length; ++c) {
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
            vm.prank(callers[c], callers[c]);
            games.createGame("nhl", "A", "B", DATE, _hints());
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
                    logs[i].data, (string, string, string, uint64, Hint[], uint64, address[], uint8[])
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

    function _toKinds(uint8[] memory k) internal pure returns (ReporterKind[] memory out) {
        out = new ReporterKind[](k.length);
        for (uint256 i; i < k.length; ++i) {
            out[i] = ReporterKind(k[i]);
        }
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
