// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {GamesBase, MockReporter} from "./GamesBase.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {GameStatus, ReadingKind, Reading, Report, ReportKind} from "../../src/games/IOspexGames.sol";

/// Every report the scoring program can send, run through the games set's report door. The file is
/// test/games/shapes.json, the program's own export: each shape is a report the program built by its own
/// decisions, listed once, with the clock it was decided at, the status of the game it meets, the decision and
/// the program's reason; the file's header names the repository and commit it was copied from. Each shape is fed
/// to a game set up at that clock, from a first-n reporter as the program is, and must be taken: a refusal is a
/// mismatch between the program and this contract, and the test names the shape. The checks the games set makes
/// of a report's readings are the lines the program keeps, so the file is this contract's regression against a
/// program that changes: when it does, the file is copied in again and run.
contract OspexGamesShapesTest is GamesBase {
    string internal constant FILE = "test/games/shapes.json";
    /// @dev How many shapes the file holds. A re-export with another count changes this line, so the change is
    ///      seen rather than taken on trust.
    uint256 internal constant SHAPES = 1207;
    /// @dev The shapes decided from start + n: after the window, hour 24 and day 7. An after-n reporter writes
    ///      from there, so each of these must be taken from one too.
    uint256 internal constant FROM_START_PLUS_N = 824;

    /// @dev One shape as the file holds it, fields in key order, since the JSON cheatcode encodes an object's
    ///      fields alphabetically. readings: one row per seat, [seat, kind, home, away].
    struct Shape {
        uint256 away;
        string clock;
        string decision;
        string game;
        uint256 home;
        uint256 kind;
        uint256[][] readings;
        string why;
    }

    /// @dev How many shapes were fed, by the file's own count key: "clock, game, decision".
    mapping(bytes32 => uint256) internal fed;

    /// Every shape in the file is taken from a first-n reporter, at the clock the program decided it, and writes
    /// what its decision says: a start the start, a score the score, a void Voided, a dispute record Disputed and
    /// the record's time, an update nothing. The counts by clock, game and decision are the file's own, and each
    /// end credits the payout address once.
    function test_shapes_everyReportTheProgramSendsIsTaken() public {
        (string memory json, Shape[] memory shapes) = _load();
        uint256 ends;
        string memory refused;
        uint256 refusals;
        for (uint256 i; i < shapes.length; ++i) {
            Shape memory s = shapes[i];
            (bool ok, bytes memory err, uint256 game) = _feed(s, first);
            if (!ok) {
                ++refusals;
                if (refusals <= 12) refused = string.concat(refused, _name(i, s), " refused: ", vm.toString(err), "; ");
                continue;
            }
            ends += _assertWritten(s, game, i);
            ++fed[keccak256(bytes(_key(s)))];
        }
        assertEq(refusals, 0, refused);
        assertEq(games.getCredit(payout), ends * uint256(FEE), "each end credited once");

        // The file's own counts, key by key, and their sum.
        string[] memory keys = vm.parseJsonKeys(json, ".counts");
        uint256 sum;
        for (uint256 k; k < keys.length; ++k) {
            uint256 want = vm.parseJsonUint(json, string.concat(".counts[\"", keys[k], "\"]"));
            if (_is(keys[k], "total")) {
                assertEq(want, shapes.length, "the file's total");
                continue;
            }
            assertEq(fed[keccak256(bytes(keys[k]))], want, keys[k]);
            sum += want;
        }
        assertEq(sum, shapes.length, "every shape under one count");
        assertEq(shapes.length, SHAPES, "the file's count");
    }

    /// The shapes decided from start + n are taken from an after-n reporter too, since it writes from there: after
    /// the window, hour 24 and day 7. Verification's and the window's are a first-n reporter's alone.
    function test_shapes_fromStartPlusNAnAfterNReporterSendsThemToo() public {
        (, Shape[] memory shapes) = _load();
        uint256 sent;
        uint256 ends;
        for (uint256 i; i < shapes.length; ++i) {
            Shape memory s = shapes[i];
            if (_is(s.clock, "verification") || _is(s.clock, "inside the window")) continue;
            (bool ok, bytes memory err, uint256 game) = _feed(s, later);
            assertTrue(ok, string.concat(_name(i, s), " refused from an after-n reporter: ", vm.toString(err)));
            ends += _assertWritten(s, game, i);
            ++sent;
        }
        assertEq(sent, FROM_START_PLUS_N, "the shapes from start + n");
        assertEq(games.getCredit(payout), ends * uint256(FEE), "each end credited once");
    }

    /// The door is the real one: the same driver, handed a shape the program never sends, is refused by the
    /// games set's own names. A score shape with its points changed is a score no final reads; a day-7 void shape
    /// with its finals made three alike is a void over agreement; an after-window score sent inside the window
    /// from an after-n reporter is inside the window. Nothing is written to those games.
    function test_shapes_theDriverReachesTheDoor() public {
        (, Shape[] memory shapes) = _load();
        uint256 scoreAt = _first(shapes, "after the window", "verified", "score");
        uint256 voidAt = _first(shapes, "day 7", "disputed", "void");

        Shape memory score = shapes[scoreAt]; // a reference into the list, so the change below is undone after
        score.home ^= 1;
        (bool ok, bytes memory err, uint256 game) = _feed(score, first);
        assertFalse(ok, "a score no final reads was taken");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__TooFewFinalsAgree.selector, 0, 1));
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "nothing written");
        score.home ^= 1;

        Shape memory v = shapes[voidAt];
        for (uint256 i; i < 3; ++i) {
            v.readings[i][1] = uint256(ReadingKind.AnsweredFinal);
            v.readings[i][2] = 27;
            v.readings[i][3] = 20;
        }
        (ok, err, game) = _feed(v, later);
        assertFalse(ok, "a void over three agreeing finals was taken");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__FinalsAgree.selector, 27, 20));
        assertEq(uint8(_status(game)), uint8(GameStatus.Disputed), "nothing written");

        Shape memory early = shapes[scoreAt];
        early.clock = "inside the window";
        (ok, err, game) = _feed(early, later);
        assertFalse(ok, "an after-n reporter wrote inside the window");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, game, START + WINDOW));
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "nothing written");
    }

    // ──────────────────────────── The driver ───────────────────────────

    /// @dev Reads the file and decodes its shapes.
    function _load() internal view returns (string memory json, Shape[] memory shapes) {
        json = vm.readFile(FILE);
        shapes = abi.decode(vm.parseJson(json, ".shapes"), (Shape[]));
        assertEq(vm.parseJsonUint(json, ".counts.total"), shapes.length, "the header's total is the list's length");
    }

    /// @dev A fresh game set up as the shape meets it, at the shape's clock, then the shape sent from `who`: a
    ///      start on a game with no start; otherwise the start is written at START by `first`, and for a disputed
    ///      game the record at START + 1. The window is [START, START + n): inside it the shape is sent at
    ///      START + 2, after it and at hour 24 at START + n, that second, and at day 7 at the record plus the
    ///      clock, that second. A start carries START, a score its points, a score and a void the payout address.
    function _feed(Shape memory s, MockReporter who) internal returns (bool ok, bytes memory err, uint256 game) {
        vm.warp(DATE - 1 hours);
        game = _create();
        if (!_is(s.game, "unverified")) _startBy(first, game, START);
        if (_is(s.game, "disputed")) {
            vm.warp(START + 1);
            _disputeBy(first, game);
        }
        vm.warp(_at(s.clock));
        Report memory r;
        r.gameId = game;
        r.kind = ReportKind(s.kind);
        if (r.kind == ReportKind.Start) r.start = START;
        r.homeScore = uint32(s.home);
        r.awayScore = uint32(s.away);
        r.readings = _readings(s.readings);
        if (r.kind == ReportKind.Score || r.kind == ReportKind.Void) r.payout = payout;
        (ok, err) = _send(address(who), r);
    }

    /// @dev The second a clock names.
    function _at(string memory clock) internal pure returns (uint256) {
        if (_is(clock, "verification")) return DATE - 1 hours;
        if (_is(clock, "inside the window")) return START + 2;
        if (_is(clock, "after the window") || _is(clock, "hour 24")) return START + WINDOW;
        if (_is(clock, "day 7")) return START + 1 + DAY7;
        revert(string.concat("a clock the test does not know: ", clock));
    }

    /// @dev What a taken shape must have written, by its decision; returns 1 for an end, 0 otherwise.
    function _assertWritten(Shape memory s, uint256 game, uint256 i) internal view returns (uint256) {
        string memory name = _name(i, s);
        if (_is(s.decision, "start")) {
            assertEq(s.kind, uint256(ReportKind.Start), name);
            assertEq(uint8(_status(game)), uint8(GameStatus.Verified), name);
            assertEq(games.getGameStart(game), START, name);
            return 0;
        }
        if (_is(s.decision, "score")) {
            assertEq(s.kind, uint256(ReportKind.Score), name);
            assertEq(uint8(_status(game)), uint8(GameStatus.Scored), name);
            (uint32 h, uint32 a) = games.getGameScores(game);
            assertEq(h, s.home, name);
            assertEq(a, s.away, name);
            return 1;
        }
        if (_is(s.decision, "void")) {
            assertEq(s.kind, uint256(ReportKind.Void), name);
            assertEq(uint8(_status(game)), uint8(GameStatus.Voided), name);
            return 1;
        }
        assertEq(s.kind, uint256(ReportKind.Dispute), name);
        assertEq(uint8(_status(game)), uint8(GameStatus.Disputed), name);
        if (_is(s.decision, "dispute record")) {
            assertEq(games.getGameDisputedAt(game), block.timestamp, string.concat(name, ": the record's time"));
        } else {
            assertTrue(_is(s.decision, "update"), string.concat(name, ": a decision the test does not know"));
            assertEq(games.getGameDisputedAt(game), START + 1, string.concat(name, ": an update moved the clock"));
        }
        return 0;
    }

    /// @dev The readings as the file lists them: [seat, kind, home, away] per row.
    function _readings(uint256[][] memory rows) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](rows.length);
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].length, 4, "a reading is four numbers");
            readings[i] = Reading({
                seat: uint8(rows[i][0]),
                kind: ReadingKind(rows[i][1]),
                homeScore: uint32(rows[i][2]),
                awayScore: uint32(rows[i][3])
            });
        }
    }

    /// @dev The index of the first shape at a clock, game and decision.
    function _first(Shape[] memory shapes, string memory clock, string memory game, string memory decision)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < shapes.length; ++i) {
            if (_is(shapes[i].clock, clock) && _is(shapes[i].game, game) && _is(shapes[i].decision, decision)) {
                return i;
            }
        }
        revert(string.concat("no shape: ", clock, ", ", game, ", ", decision));
    }

    /// @dev The file's count key for a shape.
    function _key(Shape memory s) internal pure returns (string memory) {
        return string.concat(s.clock, ", ", s.game, ", ", s.decision);
    }

    /// @dev A shape named for a failure message: its index, key and the program's reason.
    function _name(uint256 i, Shape memory s) internal pure returns (string memory) {
        return string.concat("shape ", vm.toString(i), " (", _key(s), ": ", s.why, ")");
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
