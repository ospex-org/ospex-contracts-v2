// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames, GameStatus, ReporterKind, ReportKind, Report, Hint, Terms} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter} from "./GamesBase.sol";
import {
    UnauthenticatedPlainReporter,
    OwnedReporter,
    ProxyReporter,
    ReporterLogicA,
    ReporterLogicB,
    NoReadReporter,
    RevertingReadReporter,
    SilentReporter,
    EmptyValuesReporter,
    ChameleonReporter,
    WritingReadReporter,
    ReenteringReporter
} from "./ReporterFixtures.sol";

/// @notice The approved list, retirement, the terms and the timelock's three calls, beyond the never-lines:
///         what an approval admits and refuses and why, what a retirement does in each part of a game's life,
///         what each league's terms are, and the stock timelock's roles and delay around the three calls.
contract OspexGamesListTest is GamesBase {
    bytes32 internal constant PROPOSER = keccak256("PROPOSER_ROLE");
    bytes32 internal constant CANCELLER = keccak256("CANCELLER_ROLE");

    // ──────────────────────────── The constructor's first state ────────

    /// The deploy emits the timelock once, then the default terms and each first reporter's approval, in
    /// order, with each reporter's own fixed values, exactly as a timelock approval does. Each first reporter's
    /// code hash is stored, as an approval stores one.
    function test_constructor_emitsTheFirstStateAsAnApprovalWould() public {
        UnauthenticatedPlainReporter a =
            new UnauthenticatedPlainReporter(IOspexGames(address(0)), address(1), address(2), bytes32("w1"));
        MockReporter b = new MockReporter(IOspexGames(address(0)));
        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(a), address(b));
        ReporterKind[] memory kinds = new ReporterKind[](2);
        (kinds[0], kinds[1]) = (ReporterKind.FirstN, ReporterKind.AfterN);

        vm.recordLogs();
        vm.prank(deployer, deployer);
        OspexGames g = new OspexGames(address(timelock), _launchTerms(), list, kinds, _hashes(list));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 4, "the timelock, the terms and two approvals");
        assertEq(logs[0].emitter, address(g));
        assertEq(logs[0].topics[0], IOspexGames.TimelockSet.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(timelock)))), "the timelock given");
        assertEq(logs[0].data.length, 0);
        assertEq(logs[1].topics[0], IOspexGames.TermsSet.selector);
        (string memory league, Terms memory t) = abi.decode(logs[1].data, (string, Terms));
        assertEq(league, "", "the default terms");
        _assertTerms(t, _launchTerms(), "the default terms emitted");
        for (uint256 i; i < 2; ++i) {
            Vm.Log memory l = logs[i + 2];
            assertEq(l.emitter, address(g));
            assertEq(l.topics[0], IOspexGames.ReporterApproved.selector);
            assertEq(l.topics[1], bytes32(uint256(uint160(list[i]))), "the reporter, in order");
            (uint8 kind, bytes32 hash, bytes memory values) = abi.decode(l.data, (uint8, bytes32, bytes));
            assertEq(kind, uint8(kinds[i]));
            assertEq(hash, list[i].codehash);
            (bool ok, bytes memory read) = list[i].staticcall(abi.encodeWithSignature("fixedValues()"));
            assertTrue(ok);
            assertEq(values, abi.decode(read, (bytes)), "the reporter's own values");
            (,, bytes32 stored) = g.getReporter(list[i]);
            assertEq(stored, list[i].codehash, "the code hash stored at deploy");
        }
        assertTrue(address(a).codehash != address(b).codehash, "two reporters, two hashes");
        (,, bytes memory plainValues) = abi.decode(logs[2].data, (uint8, bytes32, bytes));
        assertEq(
            plainValues,
            abi.encode(address(1), address(2), bytes32("w1")),
            "the plain reporter's forwarder, workflow owner and workflow id"
        );
    }

    /// The constructor admits its first reporters by the same rule as an approval: no wallet, no delegated
    /// wallet, no reporter whose code hashes otherwise than named (a zero hash included), and none without the
    /// fixed-values read.
    function test_constructor_admitsEachFirstReporterAsAnApprovalDoes() public {
        address good = address(new MockReporter(IOspexGames(address(0))));
        address wallet = makeAddr("wallet");
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", good));
        address noRead = address(new NoReadReporter(IOspexGames(address(0))));
        bytes32 wrong = keccak256("other code");

        address[5] memory who = [wallet, delegated, good, noRead, good];
        bytes32[5] memory named = [wallet.codehash, delegated.codehash, wrong, noRead.codehash, bytes32(0)];
        bytes[5] memory why = [
            abi.encodeWithSelector(OspexGames.OspexGames__NoCode.selector, wallet),
            abi.encodeWithSelector(OspexGames.OspexGames__Delegated.selector, delegated),
            abi.encodeWithSelector(OspexGames.OspexGames__CodeHashMismatch.selector, good, wrong, good.codehash),
            abi.encodeWithSelector(OspexGames.OspexGames__NoFixedValues.selector, noRead),
            abi.encodeWithSelector(OspexGames.OspexGames__CodeHashMismatch.selector, good, bytes32(0), good.codehash)
        ];
        for (uint256 i; i < who.length; ++i) {
            // Second on the list, behind a good first-n reporter, so only its own admission can refuse it.
            address[] memory list = new address[](2);
            (list[0], list[1]) = (good, who[i]);
            if (who[i] == good) list[0] = address(new MockReporter(IOspexGames(address(7))));
            ReporterKind[] memory kinds = new ReporterKind[](2);
            (kinds[0], kinds[1]) = (ReporterKind.FirstN, ReporterKind.AfterN);
            bytes32[] memory hashes = new bytes32[](2);
            (hashes[0], hashes[1]) = (list[0].codehash, named[i]);
            vm.expectRevert(why[i]);
            new OspexGames(address(timelock), _launchTerms(), list, kinds, hashes);
        }
    }

    /// The constructor's checks on its timelock address, all of them: a contract, not a wallet or a delegated
    /// one, and not the deployer. They are the checks the chain can make, and any contract passes them, one that
    /// is no timelock at all included (the control below). That the address is the stock timelock, with its
    /// roles and its delay, is for the deploy to check, against its code and its role events.
    function test_constructor_theTimelockIsAContractAndNotTheDeployer() public {
        address wallet = makeAddr("a wallet");
        address delegated = makeAddr("a delegated wallet");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(timelock)));
        address[] memory list = _one(address(first));
        address[3] memory bad = [wallet, delegated, address(0)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(deployer, deployer);
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__TimelockNotAContract.selector, bad[i]));
            new OspexGames(bad[i], _launchTerms(), list, _kinds1(ReporterKind.FirstN), _hashes(list));
        }
        // A contract that deploys it cannot name itself.
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__TimelockIsTheDeployer.selector, address(this)));
        new OspexGames(address(this), _launchTerms(), list, _kinds1(ReporterKind.FirstN), _hashes(list));
        // Control: 23 bytes of code that is not a delegation is a contract, and is taken, though it is no timelock.
        address short = makeAddr("short");
        vm.etch(short, abi.encodePacked(hex"ef0000", address(1)));
        OspexGames g = new OspexGames(short, _launchTerms(), list, _kinds1(ReporterKind.FirstN), _hashes(list));
        assertEq(g.i_timelock(), short);
    }

    /// The constructor holds its first state to the same limits as the timelock's calls: at most eight
    /// reporters, and default clocks that run in order, the day-30 clock at most a year (365 days, 31,536,000
    /// seconds). Each edge deploys; one past it is refused.
    function test_constructor_holdsTheSameLimits() public {
        for (uint256 n = 8; n <= 9; ++n) {
            address[] memory list = new address[](n);
            ReporterKind[] memory kinds = new ReporterKind[](n);
            for (uint256 i; i < n; ++i) {
                list[i] = address(new MockReporter(IOspexGames(address(uint160(i + 1)))));
                kinds[i] = ReporterKind.FirstN;
            }
            if (n == 9) vm.expectRevert(OspexGames.OspexGames__ListFull.selector);
            OspexGames g = new OspexGames(address(timelock), _launchTerms(), list, kinds, _hashes(list));
            if (n == 8) {
                (address[] memory got,) = g.getApprovedReporters();
                assertEq(got, list, "eight deploy");
            }
        }

        // The longest legal defaults: the day-30 clock at a year, n and the day-7 clock as long as the order
        // allows (n + day-7 = 31,535,999). Each refusal below breaks one rule of the order and no other.
        address a = address(new MockReporter(IOspexGames(address(0))));
        Terms memory edge =
            Terms({window: 15_767_999, day7Clock: 15_768_000, day30Clock: 31_536_000, fee: type(uint96).max});
        for (uint256 i; i < 4; ++i) {
            // A copy of the values: `past = edge` would alias the one struct in memory.
            Terms memory past = Terms(edge.window, edge.day7Clock, edge.day30Clock, edge.fee);
            if (i == 0) past.day30Clock = 31_536_001; // past a year
            if (i == 1) (past.window, past.day7Clock) = (1000, 1000); // a day-7 clock no longer than n
            if (i == 2) past.day7Clock = 15_768_001; // n and the day-7 clock reach the day-30 clock
            if (i == 3) past.window = 0;
            vm.expectRevert(OspexGames.OspexGames__TermsNotValid.selector);
            new OspexGames(address(timelock), past, _one(a), _kinds1(ReporterKind.FirstN), _hashes(_one(a)));
        }
        OspexGames atEdge =
            new OspexGames(address(timelock), edge, _one(a), _kinds1(ReporterKind.FirstN), _hashes(_one(a)));
        _assertTerms(atEdge.getTerms(""), edge, "the defaults at the edge");
    }

    // ──────────────────────────── Approvals ────────────────────────────

    /// An approval puts the reporter at the end of the list with its kind and emits the address, the kind, the
    /// code hash and what the reporter's own read returns. Two reporters, two different sets of values: each
    /// event carries its own reporter's, none the approver's. Games made after it copy it; games before never.
    function test_approve_addsTheReporterAndEmitsItsOwnValues() public {
        uint256 before = _create();
        UnauthenticatedPlainReporter p1 =
            new UnauthenticatedPlainReporter(games, makeAddr("forwarder 1"), makeAddr("owner 1"), bytes32("id 1"));
        UnauthenticatedPlainReporter p2 =
            new UnauthenticatedPlainReporter(games, makeAddr("forwarder 2"), makeAddr("owner 2"), bytes32("id 2"));
        UnauthenticatedPlainReporter[2] memory ps = [p1, p2];
        ReporterKind[2] memory kinds = [ReporterKind.AfterN, ReporterKind.FirstN];
        for (uint256 i; i < 2; ++i) {
            vm.recordLogs();
            _approve(address(ps[i]), kinds[i]);
            Vm.Log[] memory logs = _from(vm.getRecordedLogs(), address(games));
            assertEq(logs.length, 1, "one event");
            assertEq(logs[0].topics[0], IOspexGames.ReporterApproved.selector);
            assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(ps[i])))));
            (uint8 kind, bytes32 hash, bytes memory values) = abi.decode(logs[0].data, (uint8, bytes32, bytes));
            assertEq(kind, uint8(kinds[i]));
            assertEq(hash, address(ps[i]).codehash);
            assertEq(values, abi.encode(ps[i].i_forwarder(), ps[i].i_workflowOwner(), ps[i].i_workflowId()));
            (ReporterKind k, bool retired, bytes32 stored) = games.getReporter(address(ps[i]));
            assertEq(uint8(k), uint8(kinds[i]));
            assertFalse(retired);
            assertEq(stored, address(ps[i]).codehash, "the code hash stored with the reporter");
        }
        // The two differ only in their immutables, which are part of their code: two hashes.
        assertTrue(address(p1).codehash != address(p2).codehash, "immutables are part of the hash");
        (address[] memory list, uint8[] memory listKinds) = games.getApprovedReporters();
        assertEq(list.length, 5);
        assertEq(list[3], address(p1));
        assertEq(list[4], address(p2));
        assertEq(listKinds[3], 2);
        assertEq(listKinds[4], 1);

        uint256 afterIt = _create();
        (address[] memory r,) = games.getGameReporters(afterIt);
        assertEq(r, list, "a game made after copies the list with both");
        (r,) = games.getGameReporters(before);
        assertEq(r.length, 3, "a game made before never gains them");
    }

    /// Every way an approval is refused, each named, and none changes the list, a game or a reporter's
    /// standing, or emits anything.
    function test_approve_refusals() public {
        address wallet = makeAddr("a wallet");
        address delegated = makeAddr("a delegated wallet");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(first)));
        address noRead = address(new NoReadReporter(games));
        address reverting = address(new RevertingReadReporter());
        MockReporter fresh = new MockReporter(games);
        address f = address(fresh);
        bytes32 wrong = keccak256("not the code");
        _create();

        _refused(_approval(f, ReporterKind.None, f.codehash), _err(OspexGames.OspexGames__NoKind.selector, f));
        _refused(_approval(address(0), ReporterKind.FirstN, bytes32(0)), _err(OspexGames.OspexGames__NoCode.selector, address(0)));
        _refused(_approval(wallet, ReporterKind.FirstN, wallet.codehash), _err(OspexGames.OspexGames__NoCode.selector, wallet));
        _refused(
            _approval(delegated, ReporterKind.FirstN, delegated.codehash),
            _err(OspexGames.OspexGames__Delegated.selector, delegated)
        );
        _refused(
            _approval(f, ReporterKind.FirstN, wrong),
            abi.encodeWithSelector(OspexGames.OspexGames__CodeHashMismatch.selector, f, wrong, f.codehash)
        );
        // A zero hash names no code: refused, not read as "any code".
        _refused(
            _approval(f, ReporterKind.FirstN, bytes32(0)),
            abi.encodeWithSelector(OspexGames.OspexGames__CodeHashMismatch.selector, f, bytes32(0), f.codehash)
        );
        _refused(
            _approval(noRead, ReporterKind.AfterN, noRead.codehash),
            _err(OspexGames.OspexGames__NoFixedValues.selector, noRead)
        );
        _refused(
            _approval(reverting, ReporterKind.AfterN, reverting.codehash),
            _err(OspexGames.OspexGames__NoFixedValues.selector, reverting)
        );
        // A read that answers with no values, well formed but empty, has nothing to emit: refused by name.
        address empty = address(new EmptyValuesReporter());
        _refused(_approval(empty, ReporterKind.AfterN, empty.codehash), _err(OspexGames.OspexGames__NoFixedValues.selector, empty));
        // Approved already: the same kind, or the other kind, which would change its kind.
        _refused(
            _approval(address(first), ReporterKind.FirstN, address(first).codehash),
            _err(OspexGames.OspexGames__AlreadyApproved.selector, address(first))
        );
        _refused(
            _approval(address(later), ReporterKind.FirstN, address(later).codehash),
            _err(OspexGames.OspexGames__AlreadyApproved.selector, address(later))
        );
        // A contract that answers every call with nothing has no values to emit: refused, and changes nothing.
        // The call itself succeeds, so the refusal is the decoder's, which carries no reason: empty revert data,
        // not NoFixedValues.
        address silent = address(new SilentReporter());
        _refused(_approval(silent, ReporterKind.FirstN, silent.codehash), "");

        // Control for the delegation check: 23 bytes that do not start 0xef0100 are not a delegation, pass that
        // check, and are refused at the read instead. (Code that starts 0xef0100 is always 23 bytes: the EVM
        // takes no other, and forge will not build one, so the check's length test decides nothing alone.)
        address notDelegation = makeAddr("23 bytes, not 0xef0100");
        vm.etch(notDelegation, abi.encodePacked(hex"ef0000", address(first)));
        _refused(
            _approval(notDelegation, ReporterKind.FirstN, notDelegation.codehash),
            _err(OspexGames.OspexGames__NoFixedValues.selector, notDelegation)
        );
        // And the reporter refused for a wrong hash is approved with its own.
        _approve(f, ReporterKind.AfterN);
        (ReporterKind k,,) = games.getReporter(f);
        assertEq(uint8(k), uint8(ReporterKind.AfterN));
    }

    /// The fixed-values read is made as a read (STATICCALL), so a reporter's read can change nothing. A reporter
    /// whose read writes is refused. A read that tries to run another ready timelock call, here the approval of
    /// another reporter, runs nothing: were the read a CALL, that approval would land inside this one's read.
    function test_approve_theReadIsOnlyARead() public {
        WritingReadReporter writing = new WritingReadReporter();
        _refused(
            _approval(address(writing), ReporterKind.AfterN, address(writing).codehash),
            _err(OspexGames.OspexGames__NoFixedValues.selector, address(writing))
        );
        assertEq(writing.reads(), 0, "the read wrote");

        ReenteringReporter r = new ReenteringReporter();
        address a = address(r);
        address other = address(new MockReporter(games));
        bytes memory approveR = _approval(a, ReporterKind.FirstN, a.codehash);
        bytes memory approveOther = _approval(other, ReporterKind.AfterN, other.codehash);
        vm.startPrank(timelockKey);
        timelock.schedule(address(games), 0, approveR, bytes32(0), bytes32("r"), DELAY);
        timelock.schedule(address(games), 0, approveOther, bytes32(0), bytes32("other"), DELAY);
        vm.stopPrank();
        r.arm(timelock, address(games), approveOther, bytes32("other"));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        bytes32 list = _viewList();
        bytes32 otherId = timelock.hashOperation(address(games), 0, approveOther, bytes32(0), bytes32("other"));
        vm.prank(stranger);
        vm.expectRevert(_err(OspexGames.OspexGames__NoFixedValues.selector, a));
        timelock.execute(address(games), 0, approveR, bytes32(0), bytes32("r"));
        assertEq(_viewList(), list, "a read that ran another call changed the list");
        assertTrue(timelock.isOperationReady(otherId), "the other approval ran inside the read");

        // Control: disarmed, the read only reads (its code, and so its hash, is the same). The reporter is
        // approved once, as first-n, and the other approval then runs on its own.
        r.disarm();
        vm.prank(stranger);
        timelock.execute(address(games), 0, approveR, bytes32(0), bytes32("r"));
        vm.prank(stranger);
        timelock.execute(address(games), 0, approveOther, bytes32(0), bytes32("other"));
        (address[] memory approved, uint8[] memory kinds) = games.getApprovedReporters();
        assertEq(approved.length, 5);
        assertEq(approved[3], a);
        assertEq(kinds[3], uint8(ReporterKind.FirstN));
        assertEq(approved[4], other);
        assertEq(kinds[4], uint8(ReporterKind.AfterN));
    }

    /// An approval writes the reporter's entry before it makes the fixed-values read, so the read sees the
    /// reporter as it will stand. A reporter whose answer turns on its own standing then emits, at approval,
    /// the values it gives afterwards. (One whose answer turns on anything else still can differ: that the
    /// values are fixed is for review.)
    /// Break: in _admit(), move `bytes memory values = _fixedValues(reporter);` and the empty check above
    /// `a.kind = kind;`. The event then carries the values it gave while not yet approved.
    function test_approve_theEntryIsWrittenBeforeTheRead() public {
        ChameleonReporter c = new ChameleonReporter(games);
        vm.recordLogs();
        _approve(address(c), ReporterKind.FirstN);
        Vm.Log[] memory logs = _from(vm.getRecordedLogs(), address(games));
        assertEq(logs.length, 1);
        (,, bytes memory emitted) = abi.decode(logs[0].data, (uint8, bytes32, bytes));
        assertEq(emitted, c.fixedValues(), "the values emitted at approval are not the ones it gives after");
        assertEq(emitted, abi.encode(bytes32("values once approved")));
    }

    /// The list holds at most eight. A retirement frees a place.
    function test_approve_theListHoldsEight() public {
        MockReporter[] memory extra = new MockReporter[](6);
        for (uint256 i; i < 5; ++i) {
            extra[i] = new MockReporter(games);
            _approve(address(extra[i]), ReporterKind.AfterN);
        }
        (address[] memory list,) = games.getApprovedReporters();
        assertEq(list.length, 8);
        extra[5] = new MockReporter(games);
        address ninth = address(extra[5]);
        _refused(_approval(ninth, ReporterKind.FirstN, ninth.codehash), abi.encodeWithSelector(OspexGames.OspexGames__ListFull.selector));
        // A game made with the list full copies all eight.
        uint256 game = _create();
        (address[] memory r,) = games.getGameReporters(game);
        assertEq(r.length, 8);
        // Retire one; the ninth now fits.
        _retire(address(extra[0]));
        _approve(ninth, ReporterKind.FirstN);
        (list,) = games.getApprovedReporters();
        assertEq(list.length, 8);
        assertEq(list[7], ninth);
    }

    // ──────────────────────────── Retirement ───────────────────────────

    /// Retirement is for good: the reporter leaves the list, is marked retired, cannot be retired or approved
    /// again with either kind, and so its kind can never change. A reporter never approved cannot be retired.
    function test_retire_isForGood() public {
        vm.recordLogs();
        _retire(address(later));
        Vm.Log[] memory logs = _from(vm.getRecordedLogs(), address(games));
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IOspexGames.ReporterRetired.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(later)))));
        assertEq(logs[0].data.length, 0);

        (ReporterKind k, bool retired, bytes32 hash) = games.getReporter(address(later));
        assertEq(uint8(k), uint8(ReporterKind.AfterN), "a retired reporter keeps its kind");
        assertTrue(retired);
        assertEq(hash, address(later).codehash, "a retired reporter keeps its code hash");
        (address[] memory list,) = games.getApprovedReporters();
        assertEq(list.length, 2);

        address l = address(later);
        _refused(abi.encodeCall(IOspexGames.retireReporter, (l)), _err(OspexGames.OspexGames__ReporterRetired.selector, l));
        _refused(_approval(l, ReporterKind.AfterN, l.codehash), _err(OspexGames.OspexGames__ReporterRetired.selector, l));
        _refused(_approval(l, ReporterKind.FirstN, l.codehash), _err(OspexGames.OspexGames__ReporterRetired.selector, l));
        _refused(
            abi.encodeCall(IOspexGames.retireReporter, (stranger)), _err(OspexGames.OspexGames__NotApproved.selector, stranger)
        );
        address fresh = address(new MockReporter(games));
        _refused(abi.encodeCall(IOspexGames.retireReporter, (fresh)), _err(OspexGames.OspexGames__NotApproved.selector, fresh));
        (ReporterKind none, bool notRetired, bytes32 noHash) = games.getReporter(stranger);
        assertEq(uint8(none), 0, "never approved");
        assertFalse(notRetired);
        assertEq(noHash, bytes32(0), "never approved, no hash");
    }

    /// A retirement closes the gap: the others keep their order, wherever the retired one stood.
    function test_retire_keepsTheOthersInOrder() public {
        MockReporter x = new MockReporter(games);
        MockReporter y = new MockReporter(games);
        _approve(address(x), ReporterKind.AfterN);
        _approve(address(y), ReporterKind.FirstN);
        // [first, later, second, x, y]: retire from the middle, the end and the front.
        _retire(address(later));
        _assertApproved(_four(address(first), address(second), address(x), address(y)), "1;1;2;1");
        _retire(address(y));
        _assertApproved(_three(address(first), address(second), address(x)), "1;1;2");
        _retire(address(first));
        address[] memory two = new address[](2);
        (two[0], two[1]) = (address(second), address(x));
        _assertApproved(two, "1;2");
    }

    /// A retired reporter writes nothing more to any game, from any game's start to its end, while the game's
    /// other reporters write on. The cases the spec carries: before the start, in play, and unscored past
    /// start + n. A game whose every reporter is retired reads so at once, and nothing can write to it; it
    /// keeps its status, since the release is the ends' to write.
    function test_retire_beforeTheStartInPlayAndUnscored() public {
        uint256 unstarted = _create();
        uint256 inPlay = _create();
        uint256 unscored = _create();
        uint256 stranded = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, inPlay, START);
        _startBy(first, unscored, START);
        _startBy(first, stranded, START);

        _retire(address(first));
        // Before the start: the retired reporter's start is refused; the other first-n reporter writes it.
        _refusedReport(address(first), _startReport(unstarted, START), address(first));
        _startBy(second, unstarted, START);
        // In play: its score is refused; the other first-n reporter scores.
        vm.warp(START + 5);
        _refusedReport(address(first), _scoreReport(inPlay, HOME, AWAY), address(first));
        _scoreBy(second, inPlay, HOME, AWAY);
        // Unscored past start + n: retire the second first-n reporter too; the after-n reporter scores.
        _retire(address(second));
        vm.warp(START + WINDOW);
        _refusedReport(address(second), _scoreReport(unscored, HOME, AWAY), address(second));
        _scoreBy(later, unscored, AWAY, HOME);
        assertFalse(games.isEveryReporterRetired(stranded), "the after-n reporter is not retired");

        // Every reporter retired: the stranded game reads so at once; nothing writes to it; it stays Verified.
        _retire(address(later));
        assertTrue(games.isEveryReporterRetired(stranded), "every reporter of the stranded game is retired");
        MockReporter[3] memory all = [first, later, second];
        for (uint256 i; i < all.length; ++i) {
            _refusedReport(address(all[i]), _scoreReport(stranded, HOME, AWAY), address(all[i]));
        }
        assertEq(uint8(_status(stranded)), uint8(GameStatus.Verified), "a retirement wrote no end");
        // The ended games keep their ends.
        assertEq(uint8(_status(inPlay)), uint8(GameStatus.Scored));
        assertEq(uint8(_status(unscored)), uint8(GameStatus.Scored));
    }

    /// A game is made only while the list holds a first-n reporter: without one, nothing could write its
    /// start, and it could only be released. An approval of a first-n reporter opens creation again.
    function test_create_refusedWhileNoFirstNIsApproved() public {
        _retire(address(first));
        _create(); // `second` is still first-n
        _retire(address(second));
        vm.prank(creator, creator);
        vm.expectRevert(OspexGames.OspexGames__NoFirstNReporter.selector);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        // An after-n approval does not open it.
        MockReporter a = new MockReporter(games);
        _approve(address(a), ReporterKind.AfterN);
        vm.prank(creator, creator);
        vm.expectRevert(OspexGames.OspexGames__NoFirstNReporter.selector);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        // A first-n approval does.
        MockReporter f = new MockReporter(games);
        _approve(address(f), ReporterKind.FirstN);
        uint256 game = _create();
        (address[] memory r, uint8[] memory k) = games.getGameReporters(game);
        assertEq(r.length, 3, "later, a and f");
        assertEq(r[2], address(f));
        assertEq(k[2], 1);
        // Wherever the first-n reporter stands: with an after-n reporter approved after it, last on the list,
        // creation stays open.
        MockReporter b = new MockReporter(games);
        _approve(address(b), ReporterKind.AfterN);
        (r, k) = games.getGameReporters(_create());
        assertEq(r.length, 4, "later, a, f and b");
        assertEq(k[3], 2, "an after-n reporter last");
        // And when every reporter is retired, the list is empty and creation is refused.
        _retire(address(later));
        _retire(address(a));
        _retire(address(f));
        _retire(address(b));
        (address[] memory list,) = games.getApprovedReporters();
        assertEq(list.length, 0);
        vm.prank(creator, creator);
        vm.expectRevert(OspexGames.OspexGames__NoFirstNReporter.selector);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
    }

    // ──────────────────────────── The terms ────────────────────────────

    /// A league with its own terms gives them to its games; every other league takes the default terms, and a
    /// change to the defaults reaches every league without its own, never one with.
    function test_terms_perLeagueWithTheDefaultsForTheRest() public {
        Terms memory nhl = Terms({window: 3 hours, day7Clock: 5 days, day30Clock: 21 days, fee: 2_500_000});
        Terms memory defaults2 = Terms({window: 30 hours, day7Clock: 8 days, day30Clock: 31 days, fee: 0});
        vm.recordLogs();
        _setTerms("nhl", nhl);
        Vm.Log[] memory logs = _from(vm.getRecordedLogs(), address(games));
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IOspexGames.TermsSet.selector);
        (string memory league, Terms memory t) = abi.decode(logs[0].data, (string, Terms));
        assertEq(league, "nhl");
        _assertTerms(t, nhl, "the event");

        _assertTerms(games.getTerms("nhl"), nhl, "nhl reads its own");
        _assertTerms(games.getTerms("nba"), _launchTerms(), "nba reads the defaults");
        _assertTerms(_gameIn("nhl"), nhl, "an nhl game copies nhl's");
        _assertTerms(_gameIn("nba"), _launchTerms(), "an nba game copies the defaults");

        _setTerms("", defaults2);
        _assertTerms(games.getTerms(""), defaults2, "the defaults read back");
        _assertTerms(games.getTerms("nba"), defaults2, "nba follows the defaults");
        _assertTerms(games.getTerms("mlb"), defaults2, "mlb follows the defaults");
        _assertTerms(games.getTerms("nhl"), nhl, "nhl keeps its own");
        _assertTerms(_gameIn("nba"), defaults2, "a new nba game copies the new defaults");
        _assertTerms(_gameIn("nhl"), nhl, "a new nhl game copies nhl's");
        assertEq(games.getGameWindow(games.gameCount()), 3 hours, "the window read is the game's n");
    }

    /// The clocks run in order: n at least a second, the day-7 clock longer than n, the day-30 clock longer
    /// than n and the day-7 clock together, and at most MAX_CLOCK. Each refused set below breaks one of those
    /// four and no other, for a league and for the defaults; each edge just inside is taken. The fee takes any
    /// value, 0 and the largest included.
    /// Break: in _checkTerms(), change `uint256(terms.window) + terms.day7Clock >= terms.day30Clock` to
    /// `terms.day7Clock >= terms.day30Clock`. The chain n < day-7 < day-30 then admits the set marked below.
    function test_terms_theClocksRunInOrder() public {
        uint64 max = 31_536_000;
        uint64 big = uint64(1) << 63;
        Terms[9] memory refused = [
            Terms({window: 0, day7Clock: 2, day30Clock: 4, fee: 0}), // n is 0
            Terms({window: 5, day7Clock: 5, day30Clock: 100, fee: 0}), // the day-7 clock equals n
            Terms({window: 6, day7Clock: 5, day30Clock: 100, fee: 0}), // the day-7 clock shorter than n
            Terms({window: 1, day7Clock: 0, day30Clock: 4, fee: 0}), // the day-7 clock is 0
            Terms({window: 1, day7Clock: 2, day30Clock: 3, fee: 0}), // n + day-7 reaches the day-30 clock
            // n < day-7 < day-30 holds, but a dispute recorded 12 hours after the start would see the release
            // open before its day-7 result: the set the chain alone would admit.
            Terms({window: 1 days, day7Clock: 20 days, day30Clock: 20 days + 1, fee: 0}),
            Terms({window: 1, day7Clock: 2, day30Clock: 0, fee: 0}), // the day-30 clock is 0
            Terms({window: 1, day7Clock: 2, day30Clock: max + 1, fee: 0}), // the day-30 clock past a year
            // Clocks far past a year, whose sum passes 64 bits: refused by name, not by an overflow.
            Terms({window: big, day7Clock: big + 1, day30Clock: max, fee: 0})
        ];
        for (uint256 i; i < refused.length; ++i) {
            _refused(abi.encodeCall(IOspexGames.setTerms, ("nba", refused[i])), _sel(OspexGames.OspexGames__TermsNotValid.selector));
            _refused(abi.encodeCall(IOspexGames.setTerms, ("", refused[i])), _sel(OspexGames.OspexGames__TermsNotValid.selector));
        }
        Terms[5] memory taken = [
            Terms({window: 1, day7Clock: 2, day30Clock: 4, fee: 0}), // the lowest
            Terms({window: 5, day7Clock: 6, day30Clock: 100, fee: 7}),
            Terms({window: 1 days, day7Clock: 20 days, day30Clock: 21 days + 1, fee: 1}),
            Terms({window: 15_767_999, day7Clock: 15_768_000, day30Clock: max, fee: type(uint96).max}), // the highest
            _launchTerms()
        ];
        for (uint256 i; i < taken.length; ++i) {
            _setTerms("nba", taken[i]);
            _assertTerms(_gameIn("nba"), taken[i], "terms in order");
            _setTerms("", taken[i]);
            _assertTerms(games.getTerms(""), taken[i], "defaults in order");
        }
    }

    /// A league id must be one a creation would take, for setTerms and for getTerms.
    function test_terms_leagueIds() public {
        Terms memory low = Terms({window: 1, day7Clock: 2, day30Clock: 4, fee: 0});
        string[6] memory badLeagues = ["NBA", "n-b", "n b", "abcdefghijklmnopq", "nba\x00", string(hex"6e62c3a9")];
        for (uint256 i; i < badLeagues.length; ++i) {
            _refused(
                abi.encodeCall(IOspexGames.setTerms, (badLeagues[i], _launchTerms())),
                _sel(OspexGames.OspexGames__LeagueNotValid.selector)
            );
            vm.expectRevert(OspexGames.OspexGames__LeagueNotValid.selector);
            games.getTerms(badLeagues[i]);
        }
        // Control: the longest league id is taken.
        _setTerms("abcdefghijklmnop", low);
        _assertTerms(games.getTerms("abcdefghijklmnop"), low, "the longest league id");
    }

    // ──────────────────────────── The stock timelock around the calls ──

    /// Only the key schedules; anyone runs a call once its delay is up, and not before.
    function test_timelock_onlyTheKeySchedulesAndAnyoneRunsAReadyCall() public {
        MockReporter fresh = new MockReporter(games);
        bytes memory call = _approval(address(fresh), ReporterKind.AfterN, address(fresh).codehash);
        address[5] memory notKey = [stranger, deployer, creator, address(games), address(first)];
        for (uint256 i; i < notKey.length; ++i) {
            vm.prank(notKey[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notKey[i], PROPOSER)
            );
            timelock.schedule(address(games), 0, call, bytes32(0), bytes32(0), DELAY);
        }
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32(0), DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY - 1);
        vm.prank(creator);
        vm.expectRevert();
        timelock.execute(address(games), 0, call, bytes32(0), bytes32(0));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(creator);
        timelock.execute(address(games), 0, call, bytes32(0), bytes32(0));
        (ReporterKind k,,) = games.getReporter(address(fresh));
        assertEq(uint8(k), uint8(ReporterKind.AfterN), "anyone ran the ready call");
    }

    /// The key cancels a call while it waits; nobody else can; a cancelled call never runs.
    function test_timelock_theKeyCancels() public {
        bytes memory call = abi.encodeCall(IOspexGames.retireReporter, (address(second)));
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32(0), DELAY);
        bytes32 id = timelock.hashOperation(address(games), 0, call, bytes32(0), bytes32(0));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CANCELLER)
        );
        timelock.cancel(id);
        vm.prank(timelockKey);
        timelock.cancel(id);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectRevert();
        timelock.execute(address(games), 0, call, bytes32(0), bytes32(0));
        (, bool retired,) = games.getReporter(address(second));
        assertFalse(retired, "a cancelled retirement ran");
    }

    /// The delay is the timelock's setting: nobody changes it directly, the key included; it changes only
    /// through the timelock and its own delay. The games set's calls then wait the new delay, with no change
    /// to the games set, and shortening it again waits the longer delay.
    function test_timelock_theDelayChangesOnlyThroughItself() public {
        address[3] memory callers = [timelockKey, stranger, address(games)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, callers[i]));
            timelock.updateDelay(1);
        }
        assertEq(timelock.getMinDelay(), DELAY);

        // Raised to seven days through the timelock.
        bytes memory raise = abi.encodeCall(TimelockController.updateDelay, (7 days));
        vm.prank(timelockKey);
        timelock.schedule(address(timelock), 0, raise, bytes32(0), bytes32(0), DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        timelock.execute(address(timelock), 0, raise, bytes32(0), bytes32(0));
        assertEq(timelock.getMinDelay(), 7 days);

        // An approval now waits seven days.
        MockReporter fresh = new MockReporter(games);
        bytes memory call = _approval(address(fresh), ReporterKind.FirstN, address(fresh).codehash);
        vm.prank(timelockKey);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, DELAY, 7 days));
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32(0), DELAY);
        vm.prank(timelockKey);
        timelock.schedule(address(games), 0, call, bytes32(0), bytes32(0), 7 days);
        uint256 at = vm.getBlockTimestamp();
        vm.warp(at + 7 days - 1);
        vm.expectRevert();
        timelock.execute(address(games), 0, call, bytes32(0), bytes32(0));
        vm.warp(at + 7 days);
        timelock.execute(address(games), 0, call, bytes32(0), bytes32(0));
        (ReporterKind k,,) = games.getReporter(address(fresh));
        assertEq(uint8(k), uint8(ReporterKind.FirstN));

        // Shortening it back waits the seven days.
        bytes memory lower = abi.encodeCall(TimelockController.updateDelay, (DELAY));
        vm.prank(timelockKey);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, DELAY, 7 days));
        timelock.schedule(address(timelock), 0, lower, bytes32(0), bytes32(0), DELAY);
        vm.prank(timelockKey);
        timelock.schedule(address(timelock), 0, lower, bytes32(0), bytes32(0), 7 days);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        timelock.execute(address(timelock), 0, lower, bytes32(0), bytes32(0));
        assertEq(timelock.getMinDelay(), DELAY);
    }

    // ──────────────────────────── Review fixtures ──────────────────────

    /// A plain reporter: everything fixed at deploy. Approved, and what its read returns never moves.
    function test_fixture_aPlainReporterIsApprovedAndItsValuesHold() public {
        UnauthenticatedPlainReporter p =
            new UnauthenticatedPlainReporter(games, makeAddr("forwarder"), makeAddr("owner"), bytes32("id"));
        bytes memory before = p.fixedValues();
        _approve(address(p), ReporterKind.FirstN);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(p.fixedValues(), before, "a plain reporter's values moved");
        uint256 game = _create();
        _take(address(p), _startReport(game, START));
        assertEq(games.getGameStart(game), START);
    }

    /// A reporter with an owner and a setter passes every check the chain can make: it has code, it is not a
    /// delegation, and it hashes as named. After approval its owner moves its forwarder, and the code hash
    /// cannot see it: the values the approval event recorded no longer hold. This is why "no owner and no
    /// setters" is for review, before the call is queued.
    function test_fixture_anOwnerOrASetterIsForReview() public {
        OwnedReporter o = new OwnedReporter(games, makeAddr("forwarder"));
        bytes32 hash = address(o).codehash;
        bytes memory approvedValues = o.fixedValues();
        _approve(address(o), ReporterKind.FirstN);
        o.setForwarder(makeAddr("another forwarder"));
        assertEq(address(o).codehash, hash, "the code hash cannot see the setter");
        assertTrue(keccak256(o.fixedValues()) != keccak256(approvedValues), "the setter moved what was approved");
    }

    /// A proxy passes every on-chain check too: its code hash is the proxy's, and stays the same when its admin
    /// swaps the logic behind it. This is why "never a proxy" is for review.
    function test_fixture_aProxyIsForReview() public {
        ReporterLogicA a = new ReporterLogicA();
        ReporterLogicB b = new ReporterLogicB();
        ProxyReporter proxy = new ProxyReporter(address(a));
        bytes32 hash = address(proxy).codehash;
        _approve(address(proxy), ReporterKind.AfterN);
        (bool ok, bytes memory read) = address(proxy).staticcall(abi.encodeWithSignature("fixedValues()"));
        assertTrue(ok);
        assertEq(abi.decode(read, (bytes)), abi.encode(bytes32("logic A")));
        proxy.upgradeTo(address(b));
        assertEq(address(proxy).codehash, hash, "the code hash cannot see the upgrade");
        (ok, read) = address(proxy).staticcall(abi.encodeWithSignature("fixedValues()"));
        assertEq(abi.decode(read, (bytes)), abi.encode(bytes32("logic B")), "the logic moved behind the hash");
    }

    /// A wallet that has delegated code counts as a wallet: the chain refuses it, as it refuses a wallet.
    function test_fixture_aDelegatedWalletIsRefused() public {
        UnauthenticatedPlainReporter target =
            new UnauthenticatedPlainReporter(games, address(1), address(2), bytes32("id"));
        address wallet = makeAddr("a wallet that delegated to a reporter");
        _refused(_approval(wallet, ReporterKind.FirstN, wallet.codehash), _err(OspexGames.OspexGames__NoCode.selector, wallet));
        vm.etch(wallet, abi.encodePacked(hex"ef0100", address(target)));
        assertEq(wallet.code.length, 23);
        _refused(_approval(wallet, ReporterKind.FirstN, wallet.codehash), _err(OspexGames.OspexGames__Delegated.selector, wallet));
        // The reporter it delegated to is approved on its own.
        _approve(address(target), ReporterKind.FirstN);
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _approval(address reporter, ReporterKind kind, bytes32 hash) internal pure returns (bytes memory) {
        return abi.encodeCall(IOspexGames.approveReporter, (reporter, kind, hash));
    }

    /// @dev The timelock makes `call`; it is refused with `want`, emits nothing, and changes neither the list,
    ///      the default terms nor any game.
    function _refused(bytes memory call, bytes memory want) internal {
        bytes32 list = _viewList();
        bytes32 all = _viewAll();
        vm.recordLogs();
        (bool ok, bytes memory err) = _asTimelock(call);
        assertFalse(ok, "a refused call was taken");
        assertEq(err, want, "the refusal");
        assertEq(vm.getRecordedLogs().length, 0, "a refused call emitted");
        assertEq(_viewList(), list, "a refused call changed the list");
        assertEq(_viewAll(), all, "a refused call changed a game");
    }

    /// @dev `who` sends `r`; it is refused as from a retired reporter, and changes nothing.
    function _refusedReport(address who, Report memory r, address retiredOne) internal {
        bytes32 all = _viewAll();
        (bool ok, bytes memory err) = _send(who, r);
        assertFalse(ok, "a retired reporter wrote");
        assertEq(err, _err(OspexGames.OspexGames__ReporterRetired.selector, retiredOne));
        assertEq(_viewAll(), all, "a refused report changed a game");
    }

    function _gameIn(string memory league) internal returns (Terms memory) {
        vm.prank(creator, creator);
        uint256 game = games.createGame(league, "Home", "Away", DATE, new Hint[](0));
        return games.getGameTerms(game);
    }

    function _assertApproved(address[] memory want, string memory kinds) internal view {
        (address[] memory list, uint8[] memory k) = games.getApprovedReporters();
        assertEq(list, want, "the approved list");
        string[] memory w = vm.split(kinds, ";");
        assertEq(k.length, w.length);
        for (uint256 i; i < w.length; ++i) {
            assertEq(k[i], vm.parseUint(w[i]), "a kind");
        }
    }

    function _from(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++n;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) out[n++] = logs[i];
        }
    }

    function _err(bytes4 selector, address a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, a);
    }

    function _sel(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    function _four(address a, address b, address c, address d) internal pure returns (address[] memory l) {
        l = new address[](4);
        (l[0], l[1], l[2], l[3]) = (a, b, c, d);
    }
}
