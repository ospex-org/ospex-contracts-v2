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

/// @dev Answers every call with the same bytes, whatever the selector.
contract Answers {
    bytes internal s_answer;

    constructor(bytes memory answer) {
        s_answer = answer;
    }

    fallback() external {
        bytes memory a = s_answer;
        assembly ("memory-safe") {
            return(add(a, 0x20), mload(a))
        }
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
        vm.prank(deployer);
        signpost = new OspexSignpost(
            address(timelock), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK
        );
    }

    // ---------------------------------------------------------------------------------------------------
    // Must never happen
    // ---------------------------------------------------------------------------------------------------

    /// Must never happen 1: a set that ever held a position disappears from the signpost.
    /// Break: in moveForward(), replace `e.status = to;` with
    /// `if (to == Status.Retired) delete s_entries[id]; else e.status = to;`. This goes red: the retired
    /// entries read back empty.
    function test_mustNever1_anEntryNeverDisappears() public {
        OspexSignpost.Entry memory first = signpost.getEntry(0);
        uint256 games = _addGames(address(new MockGames(MockGames.Mode.Recorded, 0)));
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

    /// Must never happen 1: a status moves backward.
    /// Break: in moveForward(), delete
    /// `if (uint8(to) <= uint8(from)) revert OspexSignpost__NotForward(id, from, to);`. This goes red:
    /// every backward move then lands.
    function test_mustNever1_aStatusNeverMovesBackward() public {
        for (uint8 from; from < 3; ++from) {
            for (uint8 to; to < 3; ++to) {
                uint256 id = _bettingAt(OspexSignpost.Status(from));
                OspexSignpost.Entry memory before = signpost.getEntry(id);
                string memory reason = to == 2 ? "r" : "";
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
                    signpost.moveForward(id, OspexSignpost.Status(to), 0, reason);
                    _assertSameEntry(signpost.getEntry(id), before, "refused move");
                } else {
                    signpost.moveForward(id, OspexSignpost.Status(to), 0, reason);
                    assertEq(uint8(signpost.getEntry(id).status), to, "forward move");
                }
            }
        }
    }

    /// Must never happen 2: an entry is edited by anyone, the timelock key included. Here, a retired
    /// entry's reason written over by retiring it again.
    /// Break: in moveForward(), change `uint8(to) <= uint8(from)` to `uint8(to) < uint8(from)`. This goes
    /// red: the second retirement lands and replaces the reason.
    function test_mustNever2_aRetiredReasonIsNeverRewritten() public {
        uint256 id = _addBetting();
        _move(id, OspexSignpost.Status.Retired, 0, "first reason");
        OspexSignpost.Entry memory retired = signpost.getEntry(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                OspexSignpost.OspexSignpost__NotForward.selector,
                id,
                OspexSignpost.Status.Retired,
                OspexSignpost.Status.Retired
            )
        );
        _move(id, OspexSignpost.Status.Retired, 0, "second reason");
        _assertSameEntry(signpost.getEntry(id), retired, "retired entry");

        // The key itself cannot reach the entry either.
        vm.prank(k);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, k));
        signpost.moveForward(id, OspexSignpost.Status.Retired, 0, "second reason");
        _assertSameEntry(signpost.getEntry(id), retired, "after the key's call");
    }

    /// Must never happen 2: an entry is edited by anyone, the timelock key included. Here, an earlier entry
    /// written over by a later add, and any field but the status and the reason changed by a move.
    /// Break: in _add(), change `Entry storage e = s_entries.push();` to
    /// `Entry storage e = s_entries.length == 0 ? s_entries.push() : s_entries[0];`. This goes red: the
    /// later add writes over the first entry.
    function test_mustNever2_noWriteEditsAnEntry() public {
        OspexSignpost.Entry memory first = signpost.getEntry(0);
        uint256 betting = _addBetting();
        OspexSignpost.Entry memory bettingBefore = signpost.getEntry(betting);
        _assertSameEntry(signpost.getEntry(0), first, "first entry after an add");

        uint256 games = _addGames(address(new MockGames(MockGames.Mode.Recorded, 0)));
        OspexSignpost.Entry memory gamesBefore = signpost.getEntry(games);
        _assertSameEntry(signpost.getEntry(0), first, "first entry after a second add");
        _assertSameEntry(signpost.getEntry(betting), bettingBefore, "betting entry after an add");

        _move(games, OspexSignpost.Status.Live, 1, "");
        _assertSameRecord(signpost.getEntry(games), gamesBefore, "games entry after a move to live");
        assertEq(signpost.getEntry(games).reason, "", "a move to live writes no reason");
        _move(games, OspexSignpost.Status.Retired, 0, "why");
        _assertSameRecord(signpost.getEntry(games), gamesBefore, "games entry after retirement");
        _assertSameEntry(signpost.getEntry(0), first, "first entry after the moves");
        _assertSameEntry(signpost.getEntry(betting), bettingBefore, "betting entry after the moves");
    }

    /// Must never happen 3: v2's entry moves to live. v2's entry is the constructor's, entry 0. Its first
    /// contract here answers the reporters read, so the first-entry rule is the only thing refusing it.
    /// Break: in moveForward(), delete `if (id == 0) revert OspexSignpost__FirstEntryNeverLive();`. This
    /// goes red: entry 0 then moves to live.
    function test_mustNever3_theFirstEntryNeverMovesToLive() public {
        OspexSignpost.Entry memory first = signpost.getEntry(0);
        assertEq(uint8(first.kind), uint8(OspexSignpost.Kind.Both), "the first entry holds games");

        // Through the timelock, after its delay: refused, and the timelock bubbles the reason.
        bytes memory call = abi.encodeCall(OspexSignpost.moveForward, (0, OspexSignpost.Status.Live, 1, ""));
        bytes32 s = _scheduleAndWait(call);
        vm.prank(stranger);
        vm.expectRevert(OspexSignpost.OspexSignpost__FirstEntryNeverLive.selector);
        timelock.execute(address(signpost), 0, call, bytes32(0), s);
        // For every game, and with any game the read answers for.
        for (uint256 game; game < 4; ++game) {
            vm.prank(address(timelock));
            vm.expectRevert(OspexSignpost.OspexSignpost__FirstEntryNeverLive.selector);
            signpost.moveForward(0, OspexSignpost.Status.Live, game, "");
        }
        _assertSameEntry(signpost.getEntry(0), first, "first entry");

        // Control: the same games contract, in a later entry, moves to live; and entry 0 can be retired.
        uint256 later = _add(OspexSignpost.Kind.Both, coin, firstContracts, COMMIT, 950);
        _move(later, OspexSignpost.Status.Live, 1, "");
        assertEq(uint8(signpost.getEntry(later).status), uint8(OspexSignpost.Status.Live), "later entry");
        _move(0, OspexSignpost.Status.Retired, 0, "");
        assertEq(uint8(signpost.getEntry(0).status), uint8(OspexSignpost.Status.Retired), "first entry retired");
    }

    /// Must never happen 3: a games entry moves to live when its games contract does not record each game's
    /// reporters at creation. The signpost asks the entry's first contract for the named game's reporters
    /// and refuses unless it answers at least one, with a kind for each.
    /// Break: in moveForward(), delete
    /// `if (e.kind != Kind.Betting) _requireRecordedReporters(e.contracts[0], game);`. This goes red:
    /// every games entry then moves to live.
    function test_mustNever3_aGamesEntryMovesToLiveOnlyIfItsGamesRecordReporters() public {
        uint256 game = 7;
        address[6] memory refused = [
            address(new Plain()),
            address(new MockGames(MockGames.Mode.Reverts, 0)),
            address(new MockGames(MockGames.Mode.Empty, 0)),
            address(new MockGames(MockGames.Mode.Mismatched, 0)),
            address(new MockGames(MockGames.Mode.KnownGameOnly, 8)),
            address(new Answers(abi.encode(uint256(64), uint256(0))))
        ];
        for (uint256 i; i < refused.length; ++i) {
            // As a games entry, asked about game 7, and as a later both entry, asked about game 9.
            for (uint256 j; j < 2; ++j) {
                uint256 asked = j == 0 ? game : game + 2;
                uint256 id = j == 0 ? _addGames(refused[i]) : _addBoth(refused[i]);
                vm.expectCall(refused[i], abi.encodeCall(IGameReporters.getGameReporters, (asked)), 1);
                vm.prank(address(timelock));
                vm.expectRevert(
                    abi.encodeWithSelector(
                        OspexSignpost.OspexSignpost__ReportersNotRecorded.selector, refused[i], asked
                    )
                );
                signpost.moveForward(id, OspexSignpost.Status.Live, asked, "");
                assertEq(uint8(signpost.getEntry(id).status), uint8(OspexSignpost.Status.Building), "stays building");
            }
        }

        // Two lists, but not well formed: the decoding reverts.
        address garbled = address(new Answers(abi.encode(uint256(0x1000), uint256(0x1000), uint256(0), uint256(0))));
        uint256 garbledId = _addGames(garbled);
        vm.prank(address(timelock));
        vm.expectRevert();
        signpost.moveForward(garbledId, OspexSignpost.Status.Live, game, "");
        assertEq(uint8(signpost.getEntry(garbledId).status), uint8(OspexSignpost.Status.Building), "garbled");

        // Controls. A games contract that records reporters moves to live, through the timelock too...
        address recorded = address(new MockGames(MockGames.Mode.Recorded, 0));
        uint256 ok = _addGames(recorded);
        vm.expectCall(recorded, abi.encodeCall(IGameReporters.getGameReporters, (game)), 1);
        _viaTimelock(abi.encodeCall(OspexSignpost.moveForward, (ok, OspexSignpost.Status.Live, game, "")));
        assertEq(uint8(signpost.getEntry(ok).status), uint8(OspexSignpost.Status.Live), "recorded");
        // ...and one that refuses an unknown game moves to live on a game it knows.
        address strict = address(new MockGames(MockGames.Mode.KnownGameOnly, game));
        uint256 strictId = _addGames(strict);
        _move(strictId, OspexSignpost.Status.Live, game, "");
        assertEq(uint8(signpost.getEntry(strictId).status), uint8(OspexSignpost.Status.Live), "known game");
        // A betting entry has no games contract: it moves to live with no read made.
        address noRead = address(new Plain());
        address[] memory bettingSet = _one(noRead);
        uint256 betting = _add(OspexSignpost.Kind.Betting, coin, bettingSet, COMMIT, 950);
        vm.expectCall(noRead, abi.encodeCall(IGameReporters.getGameReporters, (game)), 0);
        _move(betting, OspexSignpost.Status.Live, game, "");
        assertEq(uint8(signpost.getEntry(betting).status), uint8(OspexSignpost.Status.Live), "betting");
    }

    /// Must never happen 4: an entry is written after deploy by anything but a timelock call. Every address
    /// but the timelock is refused, for both writes.
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

    /// Must never happen 4: a write lands without waiting the timelock's delay. The key schedules each
    /// write through the timelock; it runs only once the delay is up, and the key cannot call directly.
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
            vm.prank(k);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, k));
            s.addEntry(OspexSignpost.Kind.Betting, coin, set, COMMIT, 950);
            vm.prank(k);
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

    /// Must never happen 4: a deployer keeps any power after deploy, and the constructor's entry is the
    /// only write without a wait. The deploy's storage writes are exactly the first entry's, the owner is
    /// the timelock given, and the deployer can write nothing afterwards.
    /// Break: in the constructor, change `i_timelock = timelock;` to `i_timelock = msg.sender;`. This goes
    /// red: the deployer is then the owner and writes at once.
    function test_mustNever4_theDeployerKeepsNothing() public {
        vm.startStateDiffRecording();
        vm.prank(deployer);
        OspexSignpost s = new OspexSignpost(
            address(timelock), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK
        );
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        assertEq(s.i_timelock(), address(timelock), "the owner is the timelock given");
        _assertFirstEntryWritesOnly(diff, address(s), firstContracts);

        // The deployer writes nothing afterwards.
        _expectNotTheTimelock(deployer);

        // The constructor refuses an address with no code as the owner: the deployer's own wallet, or the key.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__TimelockNotAContract.selector, deployer));
        new OspexSignpost(deployer, OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__TimelockNotAContract.selector, k));
        new OspexSignpost(k, OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK);
        // A contract that deploys it cannot name itself.
        vm.expectRevert(
            abi.encodeWithSelector(OspexSignpost.OspexSignpost__TimelockIsTheDeployer.selector, address(this))
        );
        new OspexSignpost(address(this), OspexSignpost.Kind.Both, coin, firstContracts, FIRST_COMMIT, FIRST_BLOCK);
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
        address[] memory set = new address[](2);
        set[0] = address(a);
        set[1] = address(b);
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

        // The coin: given exactly when the set holds bets, and a contract.
        _expectAddRefused(OspexSignpost.Kind.Games, coin, set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongCoin.selector, OspexSignpost.Kind.Games, coin));
        _expectAddRefused(OspexSignpost.Kind.Betting, address(0), set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongCoin.selector, OspexSignpost.Kind.Betting, address(0)));
        _expectAddRefused(OspexSignpost.Kind.Both, address(0), set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__WrongCoin.selector, OspexSignpost.Kind.Both, address(0)));
        _expectAddRefused(OspexSignpost.Kind.Betting, eoa, set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, eoa));
        _expectAddRefused(OspexSignpost.Kind.Betting, wallet, set, COMMIT, 950, abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, wallet));

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
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotAContract.selector, eoa));
        new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, _one(eoa), FIRST_COMMIT, FIRST_BLOCK);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NoCommit.selector));
        new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, set, bytes20(0), FIRST_BLOCK);
    }

    // ---------------------------------------------------------------------------------------------------
    // Moves and reasons
    // ---------------------------------------------------------------------------------------------------

    function test_move_aReasonIsOneLineAndOnlyOnRetirement() public {
        uint256 games = _addGames(address(new MockGames(MockGames.Mode.Recorded, 0)));
        vm.prank(address(timelock));
        vm.expectRevert(OspexSignpost.OspexSignpost__ReasonOnlyOnRetirement.selector);
        signpost.moveForward(games, OspexSignpost.Status.Live, 1, "a reason");

        string[3] memory broken = ["two\nlines", "carriage\rreturn", "\n"];
        for (uint256 i; i < broken.length; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(OspexSignpost.OspexSignpost__ReasonNotOneLine.selector);
            signpost.moveForward(games, OspexSignpost.Status.Retired, 0, broken[i]);
        }
        assertEq(uint8(signpost.getEntry(games).status), uint8(OspexSignpost.Status.Building), "nothing moved");

        // Controls: tabs and other text are one line; an empty reason is allowed.
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
        uint256 games = _addGames(address(new MockGames(MockGames.Mode.Recorded, 0)));
        vm.expectEmit(true, true, true, true, address(signpost));
        emit OspexSignpost.StatusMoved(games, OspexSignpost.Status.Building, OspexSignpost.Status.Live, "");
        _move(games, OspexSignpost.Status.Live, 3, "");
        vm.expectEmit(true, true, true, true, address(signpost));
        emit OspexSignpost.StatusMoved(games, OspexSignpost.Status.Live, OspexSignpost.Status.Retired, "done");
        _move(games, OspexSignpost.Status.Retired, 0, "done");
    }

    /// The constructor emits the first entry, so the list can be read from its logs alone.
    function test_entry_theConstructorEmitsTheFirstEntry() public {
        bytes32[] memory hashes = new bytes32[](firstContracts.length);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = firstContracts[i].codehash;
        }
        vm.recordLogs();
        vm.prank(deployer);
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
        address[] memory set = new address[](2);
        set[0] = games;
        set[1] = address(new Plain());
        return _add(OspexSignpost.Kind.Games, address(0), set, COMMIT, 950);
    }

    function _addBoth(address games) internal returns (uint256) {
        return _add(OspexSignpost.Kind.Both, coin, _one(games), COMMIT, 950);
    }

    function _addBetting() internal returns (uint256) {
        return _add(OspexSignpost.Kind.Betting, coin, _one(address(new Plain())), COMMIT, 950);
    }

    /// @dev A fresh betting entry at `status`.
    function _bettingAt(OspexSignpost.Status status) internal returns (uint256 id) {
        id = _addBetting();
        if (status != OspexSignpost.Status.Building) _move(id, status, 0, status == OspexSignpost.Status.Retired ? "r" : "");
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
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, caller));
        signpost.addEntry(OspexSignpost.Kind.Betting, coin, set, COMMIT, 950);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, caller));
        signpost.moveForward(0, OspexSignpost.Status.Retired, 0, "");
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
 * @notice A stateful fuzz over the signpost's whole ABI: forge calls every function the compiled contract
 *         has, with random arguments, from the timelock, the key, the deployer and a stranger. After each
 *         call the three entries written in setUp must still be there, unchanged but for a forward move.
 *         A function added to the contract is fuzzed too, so an edit or delete path nobody wrote a test for
 *         still shows up here.
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
        address games = address(new MockGames(MockGames.Mode.Recorded, 0));
        address[] memory set = new address[](2);
        set[0] = games;
        set[1] = address(new Plain());
        vm.prank(makeAddr("deployer"));
        signpost = new OspexSignpost(address(timelock), OspexSignpost.Kind.Both, coin, set, bytes20(keccak256("c0")), 900);

        vm.startPrank(address(timelock));
        signpost.addEntry(OspexSignpost.Kind.Betting, coin, _one(address(new Plain())), bytes20(keccak256("c1")), 950);
        signpost.moveForward(1, OspexSignpost.Status.Live, 0, "");
        signpost.addEntry(OspexSignpost.Kind.Games, address(0), set, bytes20(keccak256("c2")), 960);
        signpost.moveForward(2, OspexSignpost.Status.Retired, 0, "r");
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            written[i] = signpost.getEntry(i);
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
    function invariant_entriesStayAndOnlyMoveForward() public view {
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
        }
        // Entry 0 never goes live; entry 1 was live and can only stay live or retire; entry 2 was retired
        // with a reason, and nothing changes it.
        assertTrue(signpost.getEntry(0).status != OspexSignpost.Status.Live, "the first entry went live");
        assertTrue(signpost.getEntry(1).status != OspexSignpost.Status.Building, "a live entry moved back");
        assertEq(uint8(signpost.getEntry(2).status), uint8(OspexSignpost.Status.Retired), "a retired entry moved");
        assertEq(signpost.getEntry(2).reason, "r", "a retired entry's reason changed");
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
