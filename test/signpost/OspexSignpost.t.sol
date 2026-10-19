// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
import {IGameReporters} from "../../src/signpost/IGameReporters.sol";

/// @dev A contract with code and no reporters read.
contract Plain {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @dev A games contract whose reporters read answers as it is set to.
contract MockGames is IGameReporters {
    enum Mode {
        Recorded,
        Empty,
        Mismatched,
        Reverts,
        KnownGameOnly
    }

    error GameNotFound(uint256 gameId);

    Mode public s_mode;
    uint256 public s_knownGame;

    constructor(Mode mode, uint256 knownGame) {
        s_mode = mode;
        s_knownGame = knownGame;
    }

    function getGameReporters(uint256 gameId)
        external
        view
        returns (address[] memory reporters, uint8[] memory kinds)
    {
        if (s_mode == Mode.Reverts) revert("no read");
        if (s_mode == Mode.KnownGameOnly && gameId != s_knownGame) revert GameNotFound(gameId);
        if (s_mode == Mode.Empty) return (new address[](0), new uint8[](0));
        reporters = new address[](1);
        reporters[0] = address(0xBEEF);
        kinds = new uint8[](s_mode == Mode.Mismatched ? 2 : 1);
    }
}

/// @dev Answers every call with the same bytes, or reverts with them, whatever the selector.
contract Answers {
    bytes internal s_answer;
    bool internal s_reverts;

    constructor(bytes memory answer, bool reverts) {
        s_answer = answer;
        s_reverts = reverts;
    }

    fallback() external {
        bytes memory a = s_answer;
        bool r = s_reverts;
        assembly ("memory-safe") {
            if r { revert(add(a, 0x20), mload(a)) }
            return(add(a, 0x20), mload(a))
        }
    }
}

/// @dev A games contract whose reporters read first tries to run a ready timelock call, then answers.
contract Reenters {
    TimelockController internal s_timelock;
    address internal s_target;
    bytes internal s_data;
    bytes32 internal s_salt;

    function arm(TimelockController t, address target, bytes memory data, bytes32 salt) external {
        s_timelock = t;
        s_target = target;
        s_data = data;
        s_salt = salt;
    }

    function getGameReporters(uint256) external returns (address[] memory reporters, uint8[] memory kinds) {
        if (address(s_timelock) != address(0)) {
            try s_timelock.execute{gas: 3_000_000}(s_target, 0, s_data, bytes32(0), s_salt) {} catch {}
        }
        reporters = new address[](1);
        reporters[0] = address(0xBEEF);
        kinds = new uint8[](1);
    }
}

/**
 * @notice Tests for src/signpost/OspexSignpost.sol, on a local chain, with OpenZeppelin's TimelockController
 *         (the build the Polygon timelock runs) as the owner.
 *
 *         The signpost's lines under "Must never happen" in docs/spec-v3.md ("Keys, deploys and the
 *         signpost") are numbered here: 1, a set disappears or a status moves backward; 2, an entry is edited
 *         or deleted, the timelock key included; 3, a games entry moves to live when its games contract does
 *         not record each game's reporters at creation, or v2's entry moves to live; 4, a deployer keeps any
 *         power after deploy, or an entry is written after deploy by anything but a timelock call that
 *         waited the timelock's delay. Each has tests named test_mustNever<line>_..., and each names the
 *         one-line break that turns it red. Other tests may go red under the same break.
 *
 *         A direct call is pranked with the caller as both sender and origin, as a wallet's own
 *         transaction is, so a check that let a transaction's origin through would show.
 */
contract OspexSignpostTest is Test {
    uint256 internal constant DELAY = 60;
    uint64 internal constant FIRST_BLOCK = 900;
    bytes20 internal constant FIRST_COMMIT = bytes20(keccak256("first commit"));
    bytes20 internal constant COMMIT = bytes20(keccak256("commit"));

    address internal k = makeAddr("K");
    address internal stranger = makeAddr("stranger");
    address internal deployer = makeAddr("deployer");

    TimelockController internal timelock;
    OspexSignpost internal signpost;
    address internal coin;
    /// @dev The first entry's first contract answers the reporters read, so only the first-entry rule can
    ///      keep that entry from moving to live.
    MockGames internal firstGames;
    address[] internal firstContracts;
    uint256 internal salt;

    function setUp() public {
        vm.roll(1_000);
        timelock = new TimelockController(DELAY, _one(k), _one(address(0)), address(0));
        coin = address(new Plain());
        firstGames = new MockGames(MockGames.Mode.Recorded, 0);
        firstContracts.push(address(firstGames));
        firstContracts.push(address(new Plain()));
        firstContracts.push(address(new Plain()));
        vm.prank(deployer, deployer);
        signpost = new OspexSignpost(
            address(timelock), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK
        );
    }

    // ---------------------------------------------------------------------------------------------------
    // Must never happen 1: a set that ever held a position disappears, or a status moves backward
    // ---------------------------------------------------------------------------------------------------

    /// Break: in moveForward(), replace `e.status = to;` with
    /// `if (to == Status.Retired) delete s_entries[id]; else e.status = to;`. This goes red: the retired
    /// entries read back empty.
    function test_mustNever1_anEntryNeverDisappears() public {
        OspexSignpost.Entry memory first = signpost.getEntry(0);
        uint256 games = _addGames(_answering());
        uint256 betting = _addBetting();
        OspexSignpost.Entry memory gamesBefore = signpost.getEntry(games);
        OspexSignpost.Entry memory bettingBefore = signpost.getEntry(betting);

        _move(games, OspexSignpost.Status.Live, 1, "");
        _move(games, OspexSignpost.Status.Retired, 0, "replaced");
        _move(betting, OspexSignpost.Status.Retired, 0, "");
        _move(0, OspexSignpost.Status.Retired, 0, "v3 is live");
        _addBetting();

        assertEq(signpost.entryCount(), 4, "count");
        _assertSameRecord(signpost.getEntry(0), first, "first entry");
        _assertSameRecord(signpost.getEntry(games), gamesBefore, "games entry");
        _assertSameRecord(signpost.getEntry(betting), bettingBefore, "betting entry");
        assertEq(uint8(signpost.getEntry(0).status), uint8(OspexSignpost.Status.Retired), "first entry status");
        assertEq(signpost.getEntry(0).reason, "v3 is live", "first entry reason");
        assertEq(uint8(signpost.getEntry(games).status), uint8(OspexSignpost.Status.Retired), "games status");
        assertEq(signpost.getEntry(games).reason, "replaced", "games reason");
        assertEq(uint8(signpost.getEntry(betting).status), uint8(OspexSignpost.Status.Retired), "betting status");
    }

    /// Every (from, to) pair, for an entry of each kind, and for the first entry: a move that is not
    /// forward is refused and changes nothing; every forward move lands.
    /// Break: in moveForward(), delete
    /// `if (uint8(to) <= uint8(from)) revert OspexSignpost__NotForward(id, from, to);`. This goes red: every
    /// backward move then lands.
    function test_mustNever1_aStatusNeverMovesBackward() public {
        for (uint256 kind; kind < 3; ++kind) {
            for (uint8 from; from < 3; ++from) {
                for (uint8 to; to < 3; ++to) {
                    uint256 id = _entryOf(kind);
                    if (from != 0) _move(id, OspexSignpost.Status(from), 1, from == 2 ? "r" : "");
                    OspexSignpost.Entry memory before = signpost.getEntry(id);
                    string memory reason = to == 2 ? "again" : "";
                    vm.prank(address(timelock));
                    if (to <= from) {
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                OspexSignpost.OspexSignpost__NotForward.selector,
                                id,
                                OspexSignpost.Status(from),
                                OspexSignpost.Status(to)
                            )
                        );
                        signpost.moveForward(id, OspexSignpost.Status(to), 1, reason);
                        _assertSameEntry(signpost.getEntry(id), before, "refused move");
                    } else {
                        signpost.moveForward(id, OspexSignpost.Status(to), 1, reason);
                        assertEq(uint8(signpost.getEntry(id).status), to, "forward move");
                    }
                }
            }
        }

        // The first entry: building to building, then, once retired, every move.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexSignpost.OspexSignpost__NotForward.selector,
                0,
                OspexSignpost.Status.Building,
                OspexSignpost.Status.Building
            )
        );
        signpost.moveForward(0, OspexSignpost.Status.Building, 1, "");
        _move(0, OspexSignpost.Status.Retired, 0, "first");
        for (uint8 to; to < 3; ++to) {
            vm.prank(address(timelock));
            vm.expectRevert(
                abi.encodeWithSelector(
                    OspexSignpost.OspexSignpost__NotForward.selector,
                    0,
                    OspexSignpost.Status.Retired,
                    OspexSignpost.Status(to)
                )
            );
            signpost.moveForward(0, OspexSignpost.Status(to), 1, to == 2 ? "second" : "");
        }
        assertEq(uint8(signpost.getEntry(0).status), uint8(OspexSignpost.Status.Retired), "first entry status");
        assertEq(signpost.getEntry(0).reason, "first", "first entry reason");
    }

    // ---------------------------------------------------------------------------------------------------
    // Must never happen 2: an entry is edited or deleted by anyone, the timelock key included
    // ---------------------------------------------------------------------------------------------------

    /// A retired entry's reason is never written over, whatever its kind, whether it was live first, and
    /// whether it was retired with a reason or without one; the first entry's neither. The key cannot reach
    /// it directly either.
    /// Break: in moveForward(), change `uint8(to) <= uint8(from)` to `uint8(to) < uint8(from)`. This goes
    /// red: the second retirement lands and replaces the reason.
    function test_mustNever2_aRetiredReasonIsNeverRewritten() public {
        string[2] memory firstReasons = ["first reason", ""];
        for (uint256 kind; kind < 3; ++kind) {
            for (uint256 viaLive; viaLive < 2; ++viaLive) {
                for (uint256 r; r < 2; ++r) {
                    uint256 id = _entryOf(kind);
                    if (viaLive == 1) _move(id, OspexSignpost.Status.Live, 1, "");
                    _move(id, OspexSignpost.Status.Retired, 0, firstReasons[r]);
                    _expectRetiredAgainRefused(id, firstReasons[r]);
                }
            }
        }
        _move(0, OspexSignpost.Status.Retired, 0, "");
        _expectRetiredAgainRefused(0, "");

        vm.prank(k, k);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, k));
        signpost.moveForward(0, OspexSignpost.Status.Retired, 0, "from the key");
        assertEq(signpost.getEntry(0).reason, "", "after the key's call");
    }

    /// An earlier entry is never written over by a later add, and a move changes nothing but the status and,
    /// on retirement, the reason: not the code hashes either, though the code changed after the add.
    /// Break: in _add(), change `Entry storage e = s_entries.push();` to
    /// `Entry storage e = s_entries.length == 0 ? s_entries.push() : s_entries[0];`. This goes red: the
    /// later add writes over the first entry.
    function test_mustNever2_noWriteEditsAnEntry() public {
        OspexSignpost.Entry memory first = signpost.getEntry(0);
        uint256 betting = _addBetting();
        OspexSignpost.Entry memory bettingBefore = signpost.getEntry(betting);
        _assertSameEntry(signpost.getEntry(0), first, "first entry after an add");

        address shared = address(new Plain());
        uint256 games = _add(OspexSignpost.Kind.Games, address(0), _two(_answering(), shared), COMMIT, 950);
        OspexSignpost.Entry memory gamesBefore = signpost.getEntry(games);
        _assertSameEntry(signpost.getEntry(0), first, "first entry after a second add");
        _assertSameEntry(signpost.getEntry(betting), bettingBefore, "betting entry after an add");

        vm.etch(shared, hex"60016000526001601ff3");
        assertTrue(shared.codehash != gamesBefore.codeHashes[1], "the code changed");
        _move(games, OspexSignpost.Status.Live, 1, "");
        _assertSameRecord(signpost.getEntry(games), gamesBefore, "games entry after a move to live");
        assertEq(signpost.getEntry(games).reason, "", "a move to live writes no reason");
        _move(games, OspexSignpost.Status.Retired, 0, "why");
        _assertSameRecord(signpost.getEntry(games), gamesBefore, "games entry after retirement");
        _move(betting, OspexSignpost.Status.Live, 0, "");
        _assertSameRecord(signpost.getEntry(betting), bettingBefore, "betting entry after a move to live");
        _assertSameEntry(signpost.getEntry(0), first, "first entry after the moves");
    }

    /// The reporters read cannot write. A games contract that, during the read for a move to live, runs the
    /// timelock's other ready call (retiring the same entry) fails to: the read is a static call. Otherwise
    /// the retirement would land inside the read and the move would then write live over retired.
    /// Break: in _requireRecordedReporters(), change `games.staticcall(` to `games.call(`, and drop the
    /// function's `view` so it compiles (one line each). This goes red: the retirement runs inside the
    /// read and is written over.
    function test_mustNever2_theReporterReadCannotWrite() public {
        Reenters g = new Reenters();
        uint256 id = _addGames(address(g));
        bytes memory live = abi.encodeCall(OspexSignpost.moveForward, (id, OspexSignpost.Status.Live, 1, ""));
        bytes memory retire =
            abi.encodeCall(OspexSignpost.moveForward, (id, OspexSignpost.Status.Retired, 0, "withdrawn"));
        bytes32 saltLive = bytes32(uint256(1001));
        bytes32 saltRetire = bytes32(uint256(1002));
        g.arm(timelock, address(signpost), retire, saltRetire);
        vm.startPrank(k);
        timelock.schedule(address(signpost), 0, live, bytes32(0), saltLive, DELAY);
        timelock.schedule(address(signpost), 0, retire, bytes32(0), saltRetire, DELAY);
        vm.stopPrank();
        vm.warp(block.timestamp + DELAY);

        vm.prank(stranger);
        timelock.execute(address(signpost), 0, live, bytes32(0), saltLive);
        bytes32 retireId = timelock.hashOperation(address(signpost), 0, retire, bytes32(0), saltRetire);
        assertFalse(timelock.isOperationDone(retireId), "the read ran the retirement");
        assertEq(uint8(signpost.getEntry(id).status), uint8(OspexSignpost.Status.Live), "live");
        assertEq(signpost.getEntry(id).reason, "", "no reason");

        // Control: the retirement was ready, and runs on its own afterwards.
        vm.prank(stranger);
        timelock.execute(address(signpost), 0, retire, bytes32(0), saltRetire);
        assertEq(uint8(signpost.getEntry(id).status), uint8(OspexSignpost.Status.Retired), "retired");
        assertEq(signpost.getEntry(id).reason, "withdrawn", "reason");
    }

    // ---------------------------------------------------------------------------------------------------
    // Must never happen 3: a games entry moves to live when its games contract does not record each
    // game's reporters at creation, or v2's entry moves to live
    // ---------------------------------------------------------------------------------------------------

    /// v2's entry is the constructor's, entry 0. Its first contract here answers the reporters read, so the
    /// first-entry rule is the only thing refusing it. Refused alone on the list and once others exist,
    /// directly and through the timelock, for any game, and for a first entry of any kind.
    /// Break: in moveForward(), delete `if (id == 0) revert OspexSignpost__FirstEntryNeverLive();`. This
    /// goes red: entry 0 then moves to live.
    function test_mustNever3_theFirstEntryNeverMovesToLive() public {
        OspexSignpost.Entry memory first = signpost.getEntry(0);
        assertEq(uint8(first.kind), uint8(OspexSignpost.Kind.Both), "the first entry holds games");
        _expectFirstEntryRefusedLive(signpost);

        // Through the timelock, after its delay: refused, and the timelock bubbles the reason.
        bytes memory call = abi.encodeCall(OspexSignpost.moveForward, (0, OspexSignpost.Status.Live, 1, ""));
        bytes32 s = _scheduleAndWait(call);
        vm.prank(stranger);
        vm.expectRevert(OspexSignpost.OspexSignpost__FirstEntryNeverLive.selector);
        timelock.execute(address(signpost), 0, call, bytes32(0), s);

        // Once other entries exist, among them a later entry with the very same contracts.
        _addBetting();
        uint256 later = _add(OspexSignpost.Kind.Both, coin, firstContracts, COMMIT, 950);
        _expectFirstEntryRefusedLive(signpost);
        _assertSameEntry(signpost.getEntry(0), first, "first entry");

        // A first entry of each other kind.
        address[] memory bettingSet = _one(address(new Plain()));
        vm.prank(deployer, deployer);
        OspexSignpost b =
            new OspexSignpost(address(timelock), OspexSignpost.Kind.Betting, coin, bettingSet, FIRST_COMMIT, FIRST_BLOCK);
        _expectFirstEntryRefusedLive(b);
        address[] memory gamesSet = _one(_answering());
        vm.prank(deployer, deployer);
        OspexSignpost g = new OspexSignpost(
            address(timelock), OspexSignpost.Kind.Games, address(0), gamesSet, FIRST_COMMIT, FIRST_BLOCK
        );
        _expectFirstEntryRefusedLive(g);

        // Controls: the later entry with the same contracts moves to live; entry 0 can be retired.
        _move(later, OspexSignpost.Status.Live, 1, "");
        assertEq(uint8(signpost.getEntry(later).status), uint8(OspexSignpost.Status.Live), "later entry");
        _move(0, OspexSignpost.Status.Retired, 0, "");
        assertEq(uint8(signpost.getEntry(0).status), uint8(OspexSignpost.Status.Retired), "first entry retired");
    }

    /// The signpost asks the entry's first contract for the named game's reporters and refuses unless the
    /// read succeeds and answers at least one reporter, with a kind for each. That is a check of the
    /// answer's shape for one game; recording at creation is the games contract's own rule.
    /// Break: in moveForward(), delete
    /// `if (e.kind != Kind.Betting) _requireRecordedReporters(e.contracts[0], game);`. This goes red:
    /// every games entry then moves to live.
    function test_mustNever3_aGamesEntryMovesToLiveOnlyIfItsGamesAnswerTheReportersRead() public {
        address[11] memory refused = [
            address(new Plain()),
            address(new MockGames(MockGames.Mode.Reverts, 0)),
            address(new MockGames(MockGames.Mode.Empty, 0)),
            address(new MockGames(MockGames.Mode.Mismatched, 0)),
            address(new MockGames(MockGames.Mode.KnownGameOnly, 8)),
            address(new Answers(abi.encode(uint256(64), uint256(0)), false)),
            address(new Answers(_answer(2, 1), false)),
            address(new Answers(_answer(3, 0), false)),
            // A read that reverts is refused, whatever it reverts with: here, a good answer.
            address(new Answers(_answer(1, 1), true)),
            address(new Answers(_answer(3, 3), true)),
            address(new Answers("", true))
        ];
        // A games entry is asked about games 0, 7 and the largest id; a later both entry about 1, 9 and the
        // one below the largest, so each read is counted on its own.
        uint256[3][2] memory games = [[uint256(0), 7, type(uint256).max], [uint256(1), 9, type(uint256).max - 1]];
        for (uint256 i; i < refused.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                for (uint256 n; n < 3; ++n) {
                    uint256 game = games[j][n];
                    uint256 id = j == 0 ? _addGames(refused[i]) : _add(OspexSignpost.Kind.Both, coin, _one(refused[i]), COMMIT, 950);
                    vm.expectCall(refused[i], abi.encodeCall(IGameReporters.getGameReporters, (game)), 1);
                    vm.prank(address(timelock));
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            OspexSignpost.OspexSignpost__ReportersNotRecorded.selector, refused[i], game
                        )
                    );
                    signpost.moveForward(id, OspexSignpost.Status.Live, game, "");
                    assertEq(uint8(signpost.getEntry(id).status), uint8(OspexSignpost.Status.Building), "stays building");
                }
            }
        }

        // Answers that are not two well-formed lists of the read's types: the decoding reverts.
        uint256[] memory bigKind = new uint256[](1);
        bigKind[0] = 256;
        uint256[] memory dirtyReporter = new uint256[](1);
        dirtyReporter[0] = (uint256(1) << 160) | 0xBEEF;
        bytes[3] memory garbled = [
            abi.encode(uint256(0x1000), uint256(0x1000), uint256(0), uint256(0)),
            abi.encode(_one(address(0xBEEF)), bigKind),
            abi.encode(dirtyReporter, new uint8[](1))
        ];
        for (uint256 i; i < garbled.length; ++i) {
            uint256 id = _addGames(address(new Answers(garbled[i], false)));
            vm.prank(address(timelock));
            vm.expectRevert();
            signpost.moveForward(id, OspexSignpost.Status.Live, 7, "");
            assertEq(uint8(signpost.getEntry(id).status), uint8(OspexSignpost.Status.Building), "garbled");
        }

        // Controls. A games contract that answers moves to live, through the timelock too...
        address recorded = address(new MockGames(MockGames.Mode.Recorded, 0));
        uint256 ok = _addGames(recorded);
        vm.expectCall(recorded, abi.encodeCall(IGameReporters.getGameReporters, (7)), 1);
        _viaTimelock(abi.encodeCall(OspexSignpost.moveForward, (ok, OspexSignpost.Status.Live, 7, "")));
        assertEq(uint8(signpost.getEntry(ok).status), uint8(OspexSignpost.Status.Live), "recorded");
        // ...so does one with three reporters and three kinds...
        uint256 three = _addGames(address(new Answers(_answer(3, 3), false)));
        _move(three, OspexSignpost.Status.Live, 7, "");
        assertEq(uint8(signpost.getEntry(three).status), uint8(OspexSignpost.Status.Live), "three");
        // ...and one that refuses an unknown game moves to live on a game it knows.
        uint256 strict = _addGames(address(new MockGames(MockGames.Mode.KnownGameOnly, 7)));
        _move(strict, OspexSignpost.Status.Live, 7, "");
        assertEq(uint8(signpost.getEntry(strict).status), uint8(OspexSignpost.Status.Live), "known game");
        // A betting entry has no games contract: it moves to live with no read made.
        address noRead = address(new Plain());
        uint256 betting = _add(OspexSignpost.Kind.Betting, coin, _one(noRead), COMMIT, 950);
        vm.expectCall(noRead, abi.encodeCall(IGameReporters.getGameReporters, (7)), 0);
        _move(betting, OspexSignpost.Status.Live, 7, "");
        assertEq(uint8(signpost.getEntry(betting).status), uint8(OspexSignpost.Status.Live), "betting");
    }

    // ---------------------------------------------------------------------------------------------------
    // Must never happen 4: a deployer keeps any power after deploy, or an entry is written after deploy by
    // anything but a timelock call that waited the timelock's delay
    // ---------------------------------------------------------------------------------------------------

    /// Every address but the timelock is refused, for both writes: the key, the deployer, a stranger, the
    /// test contract and a listed contract, each as its own transaction.
    /// Break: in the onlyTimelock modifier, delete
    /// `if (msg.sender != i_timelock) revert OspexSignpost__NotTheTimelock(msg.sender);`. This goes red:
    /// anyone can then add and move entries.
    function test_mustNever4_onlyTheTimelockWrites() public {
        address[5] memory callers = [k, deployer, stranger, address(this), address(firstGames)];
        for (uint256 i; i < callers.length; ++i) {
            _expectNotTheTimelock(callers[i]);
        }
        assertEq(signpost.entryCount(), 1, "nothing was added");
        assertEq(uint8(signpost.getEntry(0).status), uint8(OspexSignpost.Status.Building), "nothing moved");
        // Control: the timelock can.
        _addBetting();
        assertEq(signpost.entryCount(), 2, "the timelock adds");
    }

    /// The same, for any caller.
    function testFuzz_mustNever4_noOtherCallerWrites(address caller) public {
        vm.assume(caller != address(timelock));
        _expectNotTheTimelock(caller);
        assertEq(signpost.entryCount(), 1, "nothing was added");
    }

    /// The key schedules each write through the timelock; it runs only once the delay is up, and the key
    /// cannot call directly.
    /// Break: the same as test_mustNever4_onlyTheTimelockWrites. This goes red: the key's direct call
    /// lands without a wait.
    function test_mustNever4_aWriteLandsOnlyAfterTheTimelocksDelay() public {
        uint256[3] memory delays = [DELAY, 1 hours, 7 days];
        for (uint256 i; i < delays.length; ++i) {
            uint256 d = delays[i];
            TimelockController t = new TimelockController(d, _one(k), _one(address(0)), address(0));
            OspexSignpost s = new OspexSignpost(
                address(t), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK
            );
            address[] memory set = _one(address(new Plain()));
            bytes memory add = abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Betting, coin, set, COMMIT, 950));
            bytes memory retire = abi.encodeCall(OspexSignpost.moveForward, (0, OspexSignpost.Status.Retired, 0, "r"));

            // The key cannot write directly.
            vm.prank(k, k);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, k));
            s.addEntry(OspexSignpost.Kind.Betting, coin, set, COMMIT, 950);
            vm.prank(k, k);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, k));
            s.moveForward(0, OspexSignpost.Status.Retired, 0, "r");

            // Nor schedule a shorter wait than the delay.
            vm.prank(k);
            vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, d - 1, d));
            t.schedule(address(s), 0, add, bytes32(0), bytes32(0), d - 1);

            vm.startPrank(k);
            t.schedule(address(s), 0, add, bytes32(0), bytes32(0), d);
            t.schedule(address(s), 0, retire, bytes32(0), bytes32(0), d);
            vm.stopPrank();
            uint256 scheduledAt = block.timestamp;

            // One second short of the delay, neither runs.
            vm.warp(scheduledAt + d - 1);
            vm.startPrank(stranger);
            vm.expectRevert();
            t.execute(address(s), 0, add, bytes32(0), bytes32(0));
            vm.expectRevert();
            t.execute(address(s), 0, retire, bytes32(0), bytes32(0));
            vm.stopPrank();
            assertEq(s.entryCount(), 1, "added early");
            assertEq(uint8(s.getEntry(0).status), uint8(OspexSignpost.Status.Building), "moved early");

            // Once it is up, anyone can run them.
            vm.warp(scheduledAt + d);
            vm.startPrank(stranger);
            t.execute(address(s), 0, add, bytes32(0), bytes32(0));
            t.execute(address(s), 0, retire, bytes32(0), bytes32(0));
            vm.stopPrank();
            assertEq(s.entryCount(), 2, "added once ready");
            assertEq(uint8(s.getEntry(0).status), uint8(OspexSignpost.Status.Retired), "moved once ready");
        }
    }

    /// The deploy's storage writes are exactly the first entry's, the owner is the timelock given, and the
    /// deployer, as its own transaction, can write nothing afterwards. The constructor refuses as the owner
    /// the deployer, an address with no code, and a wallet with a delegation.
    /// Break: in the constructor, change `i_timelock = timelock;` to `i_timelock = msg.sender;`. This goes
    /// red: the deployer is then the owner and writes at once.
    function test_mustNever4_theDeployerKeepsNothing() public {
        vm.startStateDiffRecording();
        vm.prank(deployer, deployer);
        OspexSignpost s = new OspexSignpost(
            address(timelock), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK
        );
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        assertEq(s.i_timelock(), address(timelock), "the owner is the timelock given");
        _assertFirstEntryWritesOnly(diff, address(s), firstContracts);

        // The deployer writes nothing afterwards, to this signpost or the one in setUp.
        address[] memory set = _one(address(new Plain()));
        vm.prank(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, deployer));
        s.addEntry(OspexSignpost.Kind.Betting, coin, set, COMMIT, 950);
        _expectNotTheTimelock(deployer);

        // Owners the constructor refuses: the deployer's own wallet, the key, a wallet with a delegation.
        address wallet = makeAddr("a wallet with a delegation");
        vm.etch(wallet, abi.encodePacked(hex"ef0100", address(new Plain())));
        assertEq(wallet.code.length, 23, "23 bytes");
        address[3] memory owners = [deployer, k, wallet];
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(deployer, deployer);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__TimelockNotAContract.selector, owners[i]));
            new OspexSignpost(owners[i], OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK);
        }
        // A contract that deploys it cannot name itself.
        vm.expectRevert(
            abi.encodeWithSelector(OspexSignpost.OspexSignpost__TimelockIsTheDeployer.selector, address(this))
        );
        new OspexSignpost(address(this), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK);
        // Control: 23 bytes of code that is not a delegation is a contract, and can own it.
        address short = makeAddr("short");
        vm.etch(short, abi.encodePacked(hex"ef0000", address(1)));
        vm.prank(deployer, deployer);
        OspexSignpost owned =
            new OspexSignpost(short, OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK);
        assertEq(owned.i_timelock(), short, "a 23-byte contract owner");
    }

    // ---------------------------------------------------------------------------------------------------
    // What an entry holds
    // ---------------------------------------------------------------------------------------------------

    function test_entry_theFirstEntryIsTheConstructorsArguments() public view {
        assertEq(signpost.entryCount(), 1, "count");
        OspexSignpost.Entry memory e = signpost.getEntry(0);
        assertEq(uint8(e.kind), uint8(OspexSignpost.Kind.Both), "kind");
        assertEq(e.coin, coin, "coin");
        assertEq(e.contracts, firstContracts, "contracts");
        assertEq(e.codeHashes.length, firstContracts.length, "one hash per contract");
        for (uint256 i; i < firstContracts.length; ++i) {
            assertEq(e.codeHashes[i], firstContracts[i].codehash, "code hash read from the chain");
        }
        assertEq(e.commit, FIRST_COMMIT, "commit");
        assertEq(e.deployBlock, FIRST_BLOCK, "deploy block");
        assertEq(uint8(e.status), uint8(OspexSignpost.Status.Building), "status");
        assertEq(e.reason, "", "reason");
    }

    /// The hashes are read from the chain when the entry is written, and kept: code that changes later does
    /// not move them.
    function test_entry_codeHashesAreReadWhenWritten() public {
        Plain a = new Plain();
        MockGames b = new MockGames(MockGames.Mode.Recorded, 0);
        address[] memory set = _two(address(a), address(b));
        bytes32 hashA = address(a).codehash;
        bytes32 hashB = address(b).codehash;
        assertTrue(hashA != hashB, "two different codes");

        vm.expectEmit(true, true, true, true, address(signpost));
        emit OspexSignpost.EntryAdded(1, OspexSignpost.Kind.Betting, coin, set, _two(hashA, hashB), COMMIT, 950);
        uint256 id = _add(OspexSignpost.Kind.Betting, coin, set, COMMIT, 950);
        assertEq(signpost.getEntry(id).codeHashes, _two(hashA, hashB), "hashes");

        vm.etch(address(a), hex"6001");
        assertTrue(address(a).codehash != hashA, "the code changed");
        assertEq(signpost.getEntry(id).codeHashes, _two(hashA, hashB), "the record keeps what was written");
    }

    function test_entry_eachFieldMustBeTrueOfADeployedSet() public {
        address[] memory set = _one(address(new Plain()));
        address[] memory none = new address[](0);

        _expectAddRefused(OspexSignpost.Kind.Betting, coin, none, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NoContracts.selector));

        // A listed address with no code, or with a wallet's delegation.
        address eoa = makeAddr("eoa");
        _expectAddRefused(OspexSignpost.Kind.Betting, coin, _one(eoa), COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, eoa));
        address wallet = makeAddr("wallet");
        vm.etch(wallet, abi.encodePacked(hex"ef0100", address(new Plain())));
        _expectAddRefused(OspexSignpost.Kind.Betting, coin, _two(set[0], wallet), COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, wallet));
        // Control: 23 bytes of code that is not a delegation is a contract.
        address short = makeAddr("short");
        vm.etch(short, abi.encodePacked(hex"ef0000", address(1)));
        assertEq(short.code.length, 23, "23 bytes");
        _add(OspexSignpost.Kind.Betting, coin, _one(short), COMMIT, 950);

        // The coin: given exactly when the set holds bets, and a contract, for a betting entry and a both entry.
        _expectAddRefused(OspexSignpost.Kind.Games, coin, set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongCoin.selector, OspexSignpost.Kind.Games, coin));
        _expectAddRefused(OspexSignpost.Kind.Betting, address(0), set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongCoin.selector, OspexSignpost.Kind.Betting, address(0)));
        _expectAddRefused(OspexSignpost.Kind.Both, address(0), set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongCoin.selector, OspexSignpost.Kind.Both, address(0)));
        for (uint256 kind = 1; kind < 3; ++kind) {
            _expectAddRefused(OspexSignpost.Kind(kind), eoa, set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, eoa));
            _expectAddRefused(OspexSignpost.Kind(kind), wallet, set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, wallet));
        }

        // The commit and the deploy block.
        _expectAddRefused(OspexSignpost.Kind.Betting, coin, set, bytes20(0), 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NoCommit.selector));
        _expectAddRefused(OspexSignpost.Kind.Betting, coin, set, COMMIT, 0, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongDeployBlock.selector, uint64(0)));
        uint64 next = uint64(block.number + 1);
        _expectAddRefused(OspexSignpost.Kind.Betting, coin, set, COMMIT, next, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongDeployBlock.selector, next));

        // Controls: each kind with its right coin, a deploy block of 1 and of the current block.
        assertEq(uint8(signpost.getEntry(_add(OspexSignpost.Kind.Games, address(0), set, COMMIT, 1)).kind), 0, "games");
        assertEq(uint8(signpost.getEntry(_add(OspexSignpost.Kind.Betting, coin, set, COMMIT, uint64(block.number))).kind), 1, "betting");
        assertEq(uint8(signpost.getEntry(_add(OspexSignpost.Kind.Both, coin, set, COMMIT, 950)).kind), 2, "both");

        // The constructor holds its entry to the same rules.
        address[2] memory badCoins = [eoa, wallet];
        for (uint256 i; i < 2; ++i) {
            vm.prank(deployer, deployer);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, badCoins[i]));
            new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, badCoins[i], set, FIRST_COMMIT, FIRST_BLOCK);
        }
        vm.prank(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, eoa));
        new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, _one(eoa), FIRST_COMMIT, FIRST_BLOCK);
        vm.prank(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NoCommit.selector));
        new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, set, bytes20(0), FIRST_BLOCK);
    }

    /// The constructor emits the first entry, so the list can be read from its logs alone.
    function test_entry_theConstructorEmitsTheFirstEntry() public {
        bytes32[] memory hashes = new bytes32[](firstContracts.length);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = firstContracts[i].codehash;
        }
        vm.recordLogs();
        vm.prank(deployer, deployer);
        OspexSignpost s = new OspexSignpost(
            address(timelock), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK
        );
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one log");
        assertEq(logs[0].emitter, address(s), "emitter");
        assertEq(logs[0].topics.length, 3, "topics");
        assertEq(logs[0].topics[0], OspexSignpost.EntryAdded.selector, "event");
        assertEq(logs[0].topics[1], bytes32(0), "id 0");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(coin))), "coin");
        assertEq(
            logs[0].data,
            abi.encode(OspexSignpost.Kind.Both, firstContracts, hashes, FIRST_COMMIT, FIRST_BLOCK),
            "data"
        );
    }

    // ---------------------------------------------------------------------------------------------------
    // Moves and reasons
    // ---------------------------------------------------------------------------------------------------

    /// A reason only on retirement, for every kind; on retirement, no line feed or carriage return anywhere
    /// in it, for every kind, from building and from live.
    function test_move_aReasonIsOneLineAndOnlyOnRetirement() public {
        for (uint256 kind; kind < 3; ++kind) {
            uint256 id = _entryOf(kind);
            vm.recordLogs();
            vm.prank(address(timelock));
            vm.expectRevert(OspexSignpost.OspexSignpost__ReasonOnlyOnRetirement.selector);
            signpost.moveForward(id, OspexSignpost.Status.Live, 1, "a reason");
            assertEq(vm.getRecordedLogs().length, 0, "no event");
            assertEq(uint8(signpost.getEntry(id).status), uint8(OspexSignpost.Status.Building), "unmoved");
        }

        string[3] memory broken = ["two\nlines", "carriage\rreturn", "\n"];
        for (uint256 kind; kind < 3; ++kind) {
            for (uint8 from; from < 2; ++from) {
                uint256 id = _entryOf(kind);
                if (from == 1) _move(id, OspexSignpost.Status.Live, 1, "");
                for (uint256 i; i < broken.length; ++i) {
                    vm.prank(address(timelock));
                    vm.expectRevert(OspexSignpost.OspexSignpost__ReasonNotOneLine.selector);
                    signpost.moveForward(id, OspexSignpost.Status.Retired, 0, broken[i]);
                }
                assertEq(uint8(signpost.getEntry(id).status), from, "unmoved");
            }
        }

        // A break anywhere in a long reason.
        uint256 longId = _addBetting();
        uint256[10] memory at = [uint256(0), 1, 30, 31, 32, 33, 63, 64, 65, 255];
        bytes1[2] memory breaks = [bytes1(0x0a), bytes1(0x0d)];
        for (uint256 b; b < 2; ++b) {
            for (uint256 i; i < at.length; ++i) {
                bytes memory r = _filled(256);
                r[at[i]] = breaks[b];
                vm.prank(address(timelock));
                vm.expectRevert(OspexSignpost.OspexSignpost__ReasonNotOneLine.selector);
                signpost.moveForward(longId, OspexSignpost.Status.Retired, 0, string(r));
            }
        }

        // Controls: 256 bytes with no break; tabs and other text; an empty reason.
        string memory long = string(_filled(256));
        _move(longId, OspexSignpost.Status.Retired, 0, long);
        assertEq(signpost.getEntry(longId).reason, long, "long reason kept");
        uint256 games = _addGames(_answering());
        string memory reason = unicode"retired:\tthe games set was replaced — see entry 5";
        vm.expectEmit(true, true, true, true, address(signpost));
        emit OspexSignpost.StatusMoved(games, OspexSignpost.Status.Building, OspexSignpost.Status.Retired, reason);
        _move(games, OspexSignpost.Status.Retired, 0, reason);
        assertEq(signpost.getEntry(games).reason, reason, "reason kept");
        uint256 betting = _addBetting();
        _move(betting, OspexSignpost.Status.Retired, 0, "");
        assertEq(signpost.getEntry(betting).reason, "", "empty reason");
    }

    function test_move_anUnknownEntryIsRefused() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__UnknownEntry.selector, 1));
        signpost.moveForward(1, OspexSignpost.Status.Retired, 0, "");
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__UnknownEntry.selector, 1));
        signpost.getEntry(1);
        // Control: once added, it is known.
        _addBetting();
        assertEq(signpost.getEntry(1).coin, coin, "entry 1");
    }

    function test_move_emitsEachMove() public {
        uint256 games = _addGames(_answering());
        vm.expectEmit(true, true, true, true, address(signpost));
        emit OspexSignpost.StatusMoved(games, OspexSignpost.Status.Building, OspexSignpost.Status.Live, "");
        _move(games, OspexSignpost.Status.Live, 3, "");
        vm.expectEmit(true, true, true, true, address(signpost));
        emit OspexSignpost.StatusMoved(games, OspexSignpost.Status.Live, OspexSignpost.Status.Retired, "done");
        _move(games, OspexSignpost.Status.Retired, 0, "done");
    }

    // ---------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------

    function _add(OspexSignpost.Kind kind, address c, address[] memory set, bytes20 commit, uint64 deployBlock)
        internal
        returns (uint256 id)
    {
        vm.prank(address(timelock));
        id = signpost.addEntry(kind, c, set, commit, deployBlock);
    }

    function _addGames(address games) internal returns (uint256) {
        return _add(OspexSignpost.Kind.Games, address(0), _two(games, address(new Plain())), COMMIT, 950);
    }

    function _addBetting() internal returns (uint256) {
        return _add(OspexSignpost.Kind.Betting, coin, _one(address(new Plain())), COMMIT, 950);
    }

    /// @dev A fresh entry of kind 0 (games), 1 (betting) or 2 (both), whose first contract answers the
    ///      reporters read.
    function _entryOf(uint256 kind) internal returns (uint256) {
        if (kind == 0) return _addGames(_answering());
        if (kind == 1) return _addBetting();
        return _add(OspexSignpost.Kind.Both, coin, _one(_answering()), COMMIT, 950);
    }

    /// @dev A games contract that answers the reporters read with one reporter and one kind.
    function _answering() internal returns (address) {
        return address(new Answers(_answer(1, 1), false));
    }

    /// @dev The reporters read's answer: `nReporters` reporters and `nKinds` kinds.
    function _answer(uint256 nReporters, uint256 nKinds) internal pure returns (bytes memory) {
        address[] memory r = new address[](nReporters);
        for (uint256 i; i < nReporters; ++i) {
            r[i] = address(uint160(0xBEEF + i));
        }
        return abi.encode(r, new uint8[](nKinds));
    }

    function _move(uint256 id, OspexSignpost.Status to, uint256 game, string memory reason) internal {
        vm.prank(address(timelock));
        signpost.moveForward(id, to, game, reason);
    }

    /// @dev Schedules `call` on the signpost through the timelock as K, and waits the delay.
    function _scheduleAndWait(bytes memory call) internal returns (bytes32 s) {
        s = bytes32(++salt);
        vm.prank(k);
        timelock.schedule(address(signpost), 0, call, bytes32(0), s, DELAY);
        vm.warp(block.timestamp + DELAY);
    }

    /// @dev The same, then a stranger runs it.
    function _viaTimelock(bytes memory call) internal {
        bytes32 s = _scheduleAndWait(call);
        vm.prank(stranger);
        timelock.execute(address(signpost), 0, call, bytes32(0), s);
    }

    function _expectNotTheTimelock(address caller) internal {
        address[] memory set = _one(address(firstGames));
        vm.prank(caller, caller);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, caller));
        signpost.addEntry(OspexSignpost.Kind.Betting, coin, set, COMMIT, 950);
        vm.prank(caller, caller);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, caller));
        signpost.moveForward(0, OspexSignpost.Status.Retired, 0, "");
    }

    /// @dev Entry 0 of `s` is refused a move to live for several games, and does not move.
    function _expectFirstEntryRefusedLive(OspexSignpost s) internal {
        for (uint256 game; game < 4; ++game) {
            vm.prank(address(timelock));
            vm.expectRevert(OspexSignpost.OspexSignpost__FirstEntryNeverLive.selector);
            s.moveForward(0, OspexSignpost.Status.Live, game, "");
        }
        assertEq(uint8(s.getEntry(0).status), uint8(OspexSignpost.Status.Building), "the first entry moved");
    }

    /// @dev A retired entry, retired again with another reason: refused, and nothing changes.
    function _expectRetiredAgainRefused(uint256 id, string memory reasonBefore) internal {
        OspexSignpost.Entry memory before = signpost.getEntry(id);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexSignpost.OspexSignpost__NotForward.selector,
                id,
                OspexSignpost.Status.Retired,
                OspexSignpost.Status.Retired
            )
        );
        signpost.moveForward(id, OspexSignpost.Status.Retired, 0, "a reason written later");
        _assertSameEntry(signpost.getEntry(id), before, "retired entry");
        assertEq(signpost.getEntry(id).reason, reasonBefore, "reason");
    }

    function _expectAddRefused(
        OspexSignpost.Kind kind,
        address c,
        address[] memory set,
        bytes20 commit,
        uint64 deployBlock,
        bytes memory reason
    ) internal {
        uint256 count = signpost.entryCount();
        vm.prank(address(timelock));
        vm.expectRevert(reason);
        signpost.addEntry(kind, c, set, commit, deployBlock);
        assertEq(signpost.entryCount(), count, "refused add wrote an entry");
    }

    /// @dev Every field but the status and the reason, which a move may change.
    function _assertSameRecord(OspexSignpost.Entry memory a, OspexSignpost.Entry memory b, string memory what)
        internal
        pure
    {
        assertEq(uint8(a.kind), uint8(b.kind), what);
        assertEq(a.coin, b.coin, what);
        assertEq(a.contracts, b.contracts, what);
        assertEq(a.codeHashes, b.codeHashes, what);
        assertEq(a.commit, b.commit, what);
        assertEq(a.deployBlock, b.deployBlock, what);
    }

    /// @dev Every field.
    function _assertSameEntry(OspexSignpost.Entry memory a, OspexSignpost.Entry memory b, string memory what)
        internal
        pure
    {
        _assertSameRecord(a, b, what);
        assertEq(uint8(a.status), uint8(b.status), what);
        assertEq(a.reason, b.reason, what);
    }

    /// @dev The deploy's storage writes, exactly: the list's length, then the first entry's five slots and
    ///      its two lists, with the values written. Entries start at keccak256(0), five slots each.
    function _assertFirstEntryWritesOnly(VmSafe.AccountAccess[] memory diff, address s, address[] memory set)
        internal
        view
    {
        uint256 base = uint256(keccak256(abi.encode(uint256(0))));
        uint256 n = set.length;
        bytes32[] memory slots = new bytes32[](5 + 2 * n);
        bytes32[] memory values = new bytes32[](5 + 2 * n);
        uint256 w;
        slots[w] = bytes32(0);
        values[w++] = bytes32(uint256(1));
        slots[w] = bytes32(base);
        values[w++] = bytes32(uint256(uint160(coin)) << 8 | uint256(uint8(OspexSignpost.Kind.Both)));
        slots[w] = bytes32(base + 1);
        values[w++] = bytes32(n);
        uint256 contractsAt = uint256(keccak256(abi.encode(base + 1)));
        for (uint256 i; i < n; ++i) {
            slots[w] = bytes32(contractsAt + i);
            values[w++] = bytes32(uint256(uint160(set[i])));
        }
        slots[w] = bytes32(base + 2);
        values[w++] = bytes32(n);
        uint256 hashesAt = uint256(keccak256(abi.encode(base + 2)));
        for (uint256 i; i < n; ++i) {
            slots[w] = bytes32(hashesAt + i);
            values[w++] = set[i].codehash;
        }
        slots[w] = bytes32(base + 3);
        values[w++] = bytes32(uint256(uint160(FIRST_COMMIT)) | uint256(FIRST_BLOCK) << 160);

        // The two lists' lengths may be written before or after their elements; compare as sets.
        uint256 seen;
        for (uint256 i; i < diff.length; ++i) {
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory a = diff[i].storageAccesses[j];
                if (!a.isWrite || a.reverted) continue;
                assertEq(a.account, s, "the deploy wrote another account's storage");
                bool known;
                for (uint256 x; x < slots.length; ++x) {
                    if (slots[x] == a.slot) {
                        assertEq(a.newValue, values[x], "a first-entry slot holds another value");
                        known = true;
                    }
                }
                assertTrue(known, "the deploy wrote a slot outside the first entry");
                assertTrue(a.newValue != bytes32(uint256(uint160(deployer))), "the deployer is in storage");
                ++seen;
            }
        }
        assertEq(seen, slots.length, "the deploy's writes");
    }

    function _filled(uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "a";
        }
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](2);
        list[0] = a;
        list[1] = b;
    }
}

/**
 * @notice A stateful fuzz over the signpost's whole ABI. forge calls every function the compiled contract
 *         has, with random arguments, from the timelock, the key, the deployer and a stranger.
 *
 *         Its three entries are all retired, so no legitimate write can change them: retired is the last
 *         status, and nothing edits an entry. After every call each of the three must be byte-identical to
 *         what setUp wrote, status and reason included, and the list must hold at least three entries. So a
 *         function added to the contract that edits, deletes or reopens an entry, or rewrites a reason,
 *         fails it, whoever may call that function. What it cannot see: a change confined to entries added
 *         later (the fuzzer rarely writes a valid one), and anything the deterministic tests above cover.
 */
contract OspexSignpostInvariantTest is Test {
    OspexSignpost internal signpost;
    TimelockController internal timelock;
    OspexSignpost.Entry[3] internal written;

    function setUp() public {
        vm.roll(1_000);
        address k = makeAddr("K");
        timelock = new TimelockController(60, _one(k), _one(address(0)), address(0));
        address coin = address(new Plain());
        address games = address(new Answers(abi.encode(_one(address(0xBEEF)), new uint8[](1)), false));
        address[] memory set = new address[](2);
        set[0] = games;
        set[1] = address(new Plain());
        vm.prank(makeAddr("deployer"), makeAddr("deployer"));
        signpost = new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, set, bytes20(keccak256("c0")), 900);

        vm.startPrank(address(timelock));
        signpost.moveForward(0, OspexSignpost.Status.Retired, 0, "r0");
        signpost.addEntry(OspexSignpost.Kind.Betting, coin, _one(address(new Plain())), bytes20(keccak256("c1")), 950);
        signpost.moveForward(1, OspexSignpost.Status.Live, 0, "");
        signpost.moveForward(1, OspexSignpost.Status.Retired, 0, "");
        signpost.addEntry(OspexSignpost.Kind.Games, address(0), set, bytes20(keccak256("c2")), 960);
        signpost.moveForward(2, OspexSignpost.Status.Live, 1, "");
        signpost.moveForward(2, OspexSignpost.Status.Retired, 0, "r2");
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            written[i] = signpost.getEntry(i);
            assertEq(uint8(written[i].status), uint8(OspexSignpost.Status.Retired), "set up retired");
        }

        targetContract(address(signpost));
        targetSender(address(timelock));
        targetSender(k);
        targetSender(makeAddr("deployer"));
        targetSender(makeAddr("stranger"));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    function invariant_theRetiredEntriesNeverChange() public view {
        assertGe(signpost.entryCount(), 3, "an entry disappeared");
        for (uint256 i; i < 3; ++i) {
            OspexSignpost.Entry memory e = signpost.getEntry(i);
            OspexSignpost.Entry memory w = written[i];
            assertEq(uint8(e.kind), uint8(w.kind), "kind");
            assertEq(e.coin, w.coin, "coin");
            assertEq(e.contracts, w.contracts, "contracts");
            assertEq(e.codeHashes, w.codeHashes, "code hashes");
            assertEq(e.commit, w.commit, "commit");
            assertEq(e.deployBlock, w.deployBlock, "deploy block");
            assertEq(uint8(e.status), uint8(w.status), "status");
            assertEq(e.reason, w.reason, "reason");
        }
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
