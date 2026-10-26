// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {OspexChainlinkReporter} from "../../src/games/OspexChainlinkReporter.sol";
import {IReceiver} from "../../src/interfaces/cre/IReceiver.sol";
import {IERC165} from "../../src/interfaces/cre/IERC165.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    ReadingKind,
    Reading,
    Report,
    Terms
} from "../../src/games/IOspexGames.sol";
import {GamesBase, Deploy, MockReporter, OspexGamesHarness} from "./GamesBase.sol";
import {MockForwarder} from "./ForwarderFixtures.sol";
import {RefusingCoin} from "./CoinFixtures.sol";

/// @dev A reading as the spec's text orders it, declared here and not taken from the repository's types.
struct SpecReading {
    uint8 seat;
    uint8 kind;
    uint32 homeScore;
    uint32 awayScore;
}

/// @dev A report as the spec's text orders it: the game; what it is; the start; the home team's and the away
///      team's scores; the readings; the payout address. What the workflow encodes.
struct SpecReport {
    uint256 gameId;
    uint8 kind;
    uint64 start;
    uint32 homeScore;
    uint32 awayScore;
    SpecReading[] readings;
    address payout;
}

/// @dev A reading with a field too few: another shape, which the reporter must refuse.
struct ShortReading {
    uint8 seat;
    uint8 kind;
    uint32 homeScore;
}

struct ShortReport {
    uint256 gameId;
    uint8 kind;
    uint64 start;
    uint32 homeScore;
    uint32 awayScore;
    ShortReading[] readings;
    address payout;
}

/**
 * @notice The Chainlink reporter against a games set that lists it first-n, with a stand-in forwarder. Tests
 *         named test_neverLine_... are the spec's lines under "Must never happen" as they reach the reporter
 *         (docs/spec-v3.md, "Games and reporters" and "The creation fee"), each with the one-line break in
 *         src/games/OspexChainlinkReporter.sol that turns it red.
 */
contract OspexChainlinkReporterTest is GamesBase {
    /// @dev An id as the registry computes one: 32 bytes with the first set to 0.
    bytes32 internal constant WORKFLOW_ID = 0x00a7c1d3e5f709112233445566778899aabbccddeeff00112233445566778899;
    /// @dev The name as the forwarder carries it: ten ASCII characters of a hash. Not read by the reporter.
    bytes10 internal constant NAME = bytes10("830f5085b7");
    bytes2 internal constant REPORT_ID = 0x0002;

    MockForwarder internal forwarder;
    OspexChainlinkReporter internal chainlink;
    address internal workflowOwner = makeAddr("workflow owner");
    address internal named = makeAddr("named in the report");

    event ReportRelayed(uint256 indexed gameId, ReportKind indexed kind, bytes2 reportId, address payout);

    function setUp() public override {
        vm.warp(DATE - 3 days);
        timelock = new TimelockController(DELAY, _one(timelockKey), _one(address(0)), address(0));
        token = new RefusingCoin();
        forwarder = new MockForwarder();
        // The reporter needs the games address at its own deploy, and the games contract needs the reporter's:
        // predict the games address from the deployer's nonce, as the deploy script does.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        vm.startPrank(deployer, deployer);
        chainlink = new OspexChainlinkReporter(address(forwarder), workflowOwner, WORKFLOW_ID, IOspexGames(predicted));
        later = new MockReporter(IOspexGames(predicted));
        first = new MockReporter(IOspexGames(predicted));
        address[] memory reporters = new address[](3);
        reporters[0] = address(chainlink);
        reporters[1] = address(later);
        reporters[2] = address(first);
        ReporterKind[] memory kinds = new ReporterKind[](3);
        kinds[0] = ReporterKind.FirstN;
        kinds[1] = ReporterKind.AfterN;
        kinds[2] = ReporterKind.FirstN;
        games = new OspexGamesHarness(
            Deploy({
                timelock: address(timelock),
                token: token,
                defaultTerms: _launchTerms(),
                reporters: reporters,
                kinds: kinds,
                codeHashes: _hashes(reporters)
            })
        );
        vm.stopPrank();
        assertEq(address(games), predicted, "games address as predicted");
        _fund(creator, address(games));
        _fund(address(this), address(games));
    }

    // ---------------------------------------------------------------------------------------------------
    // What is fixed at deploy
    // ---------------------------------------------------------------------------------------------------

    /// The four values, the one read, and the length a live report's metadata has.
    function test_constructor_fixesTheFourValues() public view {
        assertEq(chainlink.i_forwarder(), address(forwarder), "forwarder");
        assertEq(chainlink.i_workflowOwner(), workflowOwner, "workflow owner");
        assertEq(chainlink.i_workflowId(), WORKFLOW_ID, "workflow id");
        assertEq(address(chainlink.i_games()), address(games), "games");
        assertEq(chainlink.fixedValues(), abi.encode(address(forwarder), workflowOwner, WORKFLOW_ID), "fixed values");
        assertEq(chainlink.METADATA_LENGTH(), 64, "a live report's metadata");
    }

    /// A forwarder without code, a zero owner, a zero id and a zero games address are refused. A games address
    /// with no code yet is taken: on deploy day the games contract does not exist when the reporter deploys.
    function test_constructor_refusesAMissingValue() public {
        vm.expectRevert(
            abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__ForwarderNotAContract.selector, stranger)
        );
        new OspexChainlinkReporter(stranger, workflowOwner, WORKFLOW_ID, games);
        vm.expectRevert(OspexChainlinkReporter.OspexChainlinkReporter__NoWorkflowOwner.selector);
        new OspexChainlinkReporter(address(forwarder), address(0), WORKFLOW_ID, games);
        vm.expectRevert(OspexChainlinkReporter.OspexChainlinkReporter__NoWorkflowId.selector);
        new OspexChainlinkReporter(address(forwarder), workflowOwner, bytes32(0), games);
        vm.expectRevert(OspexChainlinkReporter.OspexChainlinkReporter__NoGames.selector);
        new OspexChainlinkReporter(address(forwarder), workflowOwner, WORKFLOW_ID, IOspexGames(address(0)));

        address future = vm.computeCreateAddress(stranger, 7);
        assertEq(future.code.length, 0, "no code yet");
        OspexChainlinkReporter early =
            new OspexChainlinkReporter(address(forwarder), workflowOwner, WORKFLOW_ID, IOspexGames(future));
        assertEq(address(early.i_games()), future, "fixed before it exists");
    }

    /// The forwarder checks ERC-165 before it calls: the reporter answers for IReceiver and IERC165 and for
    /// nothing else. The forwarder double routes to it and refuses a contract without the read.
    function test_erc165_answersForIReceiverOnly() public {
        assertTrue(chainlink.supportsInterface(type(IReceiver).interfaceId), "IReceiver");
        assertTrue(chainlink.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(chainlink.supportsInterface(0xffffffff), "the sentinel");
        assertFalse(chainlink.supportsInterface(IOspexGames.report.selector), "another interface");
        assertEq(type(IReceiver).interfaceId, IReceiver.onReport.selector, "IReceiver is onReport alone");

        vm.expectRevert(abi.encodeWithSelector(MockForwarder.NotAReceiver.selector, address(first)));
        forwarder.report(address(first), _good(), abi.encode(_startReport(1, START)));
    }

    /// The games set's approval reads the reporter itself: the constructor's log for the Chainlink reporter
    /// carries its fixed values, and so does a later approval through the timelock.
    function test_approval_readsTheReporterItself() public {
        (ReporterKind kind, bool retired, bytes32 codeHash) = games.getReporter(address(chainlink));
        assertEq(uint8(kind), uint8(ReporterKind.FirstN), "first-n");
        assertFalse(retired, "not retired");
        assertEq(codeHash, address(chainlink).codehash, "code hash");

        OspexChainlinkReporter other =
            new OspexChainlinkReporter(address(forwarder), workflowOwner, bytes32(uint256(WORKFLOW_ID) + 1), games);
        vm.expectEmit(true, true, true, true, address(games));
        emit IOspexGames.ReporterApproved(
            address(other),
            ReporterKind.FirstN,
            address(other).codehash,
            abi.encode(address(forwarder), workflowOwner, bytes32(uint256(WORKFLOW_ID) + 1))
        );
        (bool ok,) = _asTimelock(
            abi.encodeCall(IOspexGames.approveReporter, (address(other), ReporterKind.FirstN, address(other).codehash))
        );
        assertTrue(ok, "approved");
    }

    // ---------------------------------------------------------------------------------------------------
    // What it passes on
    // ---------------------------------------------------------------------------------------------------

    /// Each kind, through the forwarder, lands in the games set as sent: the start, the score with its fee
    /// credited to the payout in the report, the void, the dispute record. The games set's event carries
    /// the report field for field, and the reporter's event follows it.
    function test_relay_eachKindLandsAsSent() public {
        uint256 game = _create();
        Report memory start = _startReport(game, START);
        _relayAndCheck(game, start);
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "started");
        assertEq(games.getGameStart(game), START, "the start as sent");

        vm.warp(START + 1);
        Report memory score = _scoreReport(game, HOME, AWAY);
        score.payout = named;
        _relayAndCheck(game, score);
        assertEq(uint8(_status(game)), uint8(GameStatus.Scored), "scored");
        (uint32 home, uint32 away) = games.getGameScores(game);
        assertEq(home, HOME, "home");
        assertEq(away, AWAY, "away");
        assertEq(games.getCredit(named), FEE, "the fee to the payout in the report");

        uint256 voided = _inStatus(GameStatus.Verified);
        vm.warp(START + WINDOW);
        Report memory v = _voidReport(voided);
        v.payout = named;
        _relayAndCheck(voided, v);
        assertEq(uint8(_status(voided)), uint8(GameStatus.Voided), "voided");
        assertEq(games.getCredit(named), 2 * FEE, "the second fee");

        uint256 disputed = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        _relayAndCheck(disputed, _disputeReport(disputed));
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Disputed), "disputed");
        assertEq(games.getGameDisputedAt(disputed), START + 1, "the record's time");
    }

    /// The report is the one shape the spec gives, in the spec's order, encoded by the workflow as a struct:
    /// decoded here and passed on field for field. Another shape is refused by the decoder, and so is a kind
    /// past the last.
    /// Break: in onReport(), decode `report` as another shape.
    function test_neverLine_theReportShapeIsTheOneShape() public {
        uint256 game = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        SpecReport memory spec;
        spec.gameId = game;
        spec.kind = 2;
        spec.homeScore = HOME;
        spec.awayScore = AWAY;
        spec.readings = new SpecReading[](4);
        spec.readings[0] = SpecReading(1, 2, HOME, AWAY);
        spec.readings[1] = SpecReading(2, 2, HOME, AWAY);
        spec.readings[2] = SpecReading(3, 2, HOME, AWAY);
        spec.readings[3] = SpecReading(4, 0, 0, 0);
        spec.payout = named;

        vm.recordLogs();
        vm.prank(stranger, stranger);
        forwarder.report(address(chainlink), _good(), abi.encode(spec));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory reported = _theLog(logs, address(games), IOspexGames.GameReported.selector);
        assertEq(reported.topics[1], bytes32(game), "game");
        assertEq(reported.topics[2], bytes32(uint256(uint160(address(chainlink)))), "the reporter wrote it");
        assertEq(reported.topics[3], bytes32(uint256(2)), "a score");
        assertEq(
            keccak256(reported.data),
            keccak256(abi.encode(uint64(0), HOME, AWAY, _scoreReadings(HOME, AWAY), named)),
            "the report, field for field"
        );
        assertEq(games.getCredit(named), FEE, "credited as named");

        // Another shape: a reading with three fields. The games set is never called.
        uint256 second = _inStatus(GameStatus.Verified);
        ShortReport memory other;
        other.gameId = second;
        other.kind = 2;
        other.homeScore = HOME;
        other.awayScore = AWAY;
        other.readings = new ShortReading[](1);
        other.readings[0] = ShortReading(1, 2, HOME);
        other.payout = named;
        _expectRefused(_good(), abi.encode(other), "");

        // A kind past the last: refused by the decoder.
        spec.gameId = second;
        spec.kind = 5;
        _expectRefused(_good(), abi.encode(spec), "");
        // Not a report at all.
        _expectRefused(_good(), hex"01", "");
        _expectRefused(_good(), "", "");
        assertEq(uint8(_status(second)), uint8(GameStatus.Verified), "untouched");
    }

    /// A refusal in the games set comes back through the reporter under the games set's own name, with
    /// nothing written: a score to a game with no start, a second start, a report from a retired reporter,
    /// and a report at the day-30 clock.
    function test_relay_bubblesTheGamesSetsRefusal() public {
        uint256 game = _create();
        _expectRefused(
            _good(),
            abi.encode(_scoreReport(game, HOME, AWAY)),
            abi.encodeWithSelector(OspexGames.OspexGames__StartNotWritten.selector, game)
        );
        _startBy(first, game, START);
        _expectRefused(
            _good(),
            abi.encode(_startReport(game, START)),
            abi.encodeWithSelector(OspexGames.OspexGames__StartAlreadyWritten.selector, game)
        );
        vm.warp(_day30(game));
        _expectRefused(_good(), abi.encode(_scoreReport(game, HOME, AWAY)), _pastDay30(game));

        uint256 fresh = _create();
        _retire(address(chainlink));
        _expectRefused(
            _good(),
            abi.encode(_startReport(fresh, START)),
            abi.encodeWithSelector(OspexGames.OspexGames__ReporterRetired.selector, address(chainlink))
        );
    }

    // ---------------------------------------------------------------------------------------------------
    // "The Chainlink reporter takes a report from any forwarder, workflow owner or workflow id but the three
    //  fixed at deploy, or has an owner or a setter, or is a proxy."
    // ---------------------------------------------------------------------------------------------------

    /// Every sender but the forwarder is refused by name, with the games set never called: a stranger, a
    /// second forwarder, the games set itself, the workflow owner, the deployer, the key and the reporter.
    /// Break: in onReport(), delete `if (msg.sender != i_forwarder) revert
    /// OspexChainlinkReporter__NotTheForwarder(msg.sender);`. The stranger's start is then taken.
    function test_neverLine_onlyTheForwarderIsHeard() public {
        uint256 game = _create();
        bytes memory data = abi.encode(_startReport(game, START));
        MockForwarder other = new MockForwarder();
        address[8] memory senders = [
            stranger,
            address(other),
            address(games),
            workflowOwner,
            deployer,
            timelockKey,
            address(chainlink),
            address(this)
        ];
        bytes32 before = _everything();
        // The games set hears one report in this test: the control's, at the end.
        vm.expectCall(address(games), abi.encodeWithSelector(IOspexGames.report.selector), 1);
        for (uint256 i; i < senders.length; ++i) {
            vm.prank(senders[i], senders[i] == address(games) ? stranger : senders[i]);
            vm.expectRevert(
                abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheForwarder.selector, senders[i])
            );
            chainlink.onReport(_good(), data);
            assertEq(_everything(), before, "something changed");
        }
        // The second forwarder, routing as the first would.
        vm.expectRevert(
            abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheForwarder.selector, address(other))
        );
        other.report(address(chainlink), _good(), data);
        assertEq(_everything(), before, "something changed");

        // Control: the forwarder's.
        _relay(stranger, _good(), _startReport(game, START));
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "the forwarder's report is taken");
    }

    /// Metadata naming another workflow owner is refused by name, the id right.
    /// Break: in onReport(), delete `if (workflowOwner != i_workflowOwner) revert
    /// OspexChainlinkReporter__NotTheWorkflowOwner(workflowOwner);`.
    function test_neverLine_onlyTheWorkflowOwnersReportIsTaken() public {
        uint256 game = _create();
        bytes memory data = abi.encode(_startReport(game, START));
        address[4] memory owners = [address(0), stranger, timelockKey, address(forwarder)];
        for (uint256 i; i < owners.length; ++i) {
            _expectRefused(
                _metadata(WORKFLOW_ID, owners[i]),
                data,
                abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowOwner.selector, owners[i])
            );
        }
        _relay(stranger, _good(), _startReport(game, START));
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "the owner's report is taken");
    }

    /// Metadata naming another workflow id is refused by name, the owner right: a changed program, a changed
    /// config or the same program under another owner is another id.
    /// Break: in onReport(), delete `if (workflowId != i_workflowId) revert
    /// OspexChainlinkReporter__NotTheWorkflowId(workflowId);`.
    function test_neverLine_onlyTheWorkflowIdsReportIsTaken() public {
        uint256 game = _create();
        bytes memory data = abi.encode(_startReport(game, START));
        bytes32[4] memory ids = [
            bytes32(0),
            bytes32(uint256(WORKFLOW_ID) ^ 1),
            bytes32(uint256(WORKFLOW_ID) | (uint256(1) << 255)),
            0x0097efdade80ff0a9557d927a1c07075a453bba9cd0fae7e22519c613ec47805
        ];
        for (uint256 i; i < ids.length; ++i) {
            _expectRefused(
                _metadata(ids[i], workflowOwner),
                data,
                abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowId.selector, ids[i])
            );
        }
        _relay(stranger, _good(), _startReport(game, START));
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "the id's report is taken");
    }

    /// Any other owner or id, together or apart, is refused with nothing written.
    function testFuzz_metadata_anyOtherOwnerOrIdIsRefused(address owner, bytes32 id) public {
        vm.assume(owner != workflowOwner || id != WORKFLOW_ID);
        uint256 game = _create();
        bytes memory expected = owner != workflowOwner
            ? abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowOwner.selector, owner)
            : abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowId.selector, id);
        _expectRefused(_metadata(id, owner), abi.encode(_startReport(game, START)), expected);
    }

    /// Metadata shorter than a live report's is refused by name; a live report's 64 bytes are read, and so
    /// are longer metadata, their tail ignored.
    /// Break: in onReport(), delete `if (metadata.length < METADATA_LENGTH) revert
    /// OspexChainlinkReporter__MetadataTooShort(metadata.length);`. Short metadata is then refused by the
    /// slice, under no name.
    function test_metadata_shorterThanALiveReportsIsRefusedAndLongerIsRead() public {
        uint256 game = _create();
        bytes memory data = abi.encode(_startReport(game, START));
        bytes memory good = _good();
        uint256[7] memory lengths = [uint256(0), 31, 32, 42, 61, 62, 63];
        for (uint256 i; i < lengths.length; ++i) {
            _expectRefused(
                _prefix(good, lengths[i]),
                data,
                abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__MetadataTooShort.selector, lengths[i])
            );
        }
        _relay(stranger, bytes.concat(good, hex"deadbeef"), _startReport(game, START));
        assertEq(uint8(_status(game)), uint8(GameStatus.Verified), "longer metadata is read");

        uint256 second = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        bytes memory long = bytes.concat(good, new bytes(45));
        assertEq(long.length, 109, "the whole raw report's length");
        _relay(stranger, long, _scoreReport(second, HOME, AWAY));
        assertEq(uint8(_status(second)), uint8(GameStatus.Scored), "a 109-byte metadata is read");
    }

    /// The reporter has no owner, no setter and is not a proxy: its runtime code holds no storage write, no
    /// storage read, no delegatecall, no callcode, no create and no selfdestruct; its functions are the eight
    /// here and no other; its errors are the eight here. (The games contract's code holds a storage write, so
    /// the scan sees one.)
    /// Break: add `uint256 public count;` and `++count;` to onReport(). Both the scan and the function set go red.
    function test_neverLine_noOwnerNoSetterNotAProxy() public view {
        bytes memory exe = _executable(address(chainlink).code);
        uint8[9] memory forbidden = [0x54, 0x55, 0x5c, 0x5d, 0xf0, 0xf2, 0xf4, 0xf5, 0xff];
        string[9] memory names =
            ["SLOAD", "SSTORE", "TLOAD", "TSTORE", "CREATE", "CALLCODE", "DELEGATECALL", "CREATE2", "SELFDESTRUCT"];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(_hasOpcode(exe, forbidden[i]), string.concat("the reporter's code holds ", names[i]));
        }
        assertTrue(_hasOpcode(exe, 0xf1), "the reporter's code calls out (CALL)");
        assertTrue(_hasOpcode(_executable(address(games).code), 0x55), "the scan sees the games contract's SSTORE");

        string memory json = _artifact("OspexChainlinkReporter");
        string[] memory functions = vm.parseJsonKeys(json, "$.methodIdentifiers");
        string[8] memory expected = [
            "METADATA_LENGTH()",
            "fixedValues()",
            "i_forwarder()",
            "i_games()",
            "i_workflowId()",
            "i_workflowOwner()",
            "onReport(bytes,bytes)",
            "supportsInterface(bytes4)"
        ];
        assertEq(functions.length, expected.length, "the function count");
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_has(functions, expected[i]), string.concat("missing ", expected[i]));
        }

        string[8] memory errors = [
            "OspexChainlinkReporter__ForwarderNotAContract",
            "OspexChainlinkReporter__NoWorkflowOwner",
            "OspexChainlinkReporter__NoWorkflowId",
            "OspexChainlinkReporter__NoGames",
            "OspexChainlinkReporter__NotTheForwarder",
            "OspexChainlinkReporter__MetadataTooShort",
            "OspexChainlinkReporter__NotTheWorkflowOwner",
            "OspexChainlinkReporter__NotTheWorkflowId"
        ];
        uint256 found;
        for (uint256 i; vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(i), "]")); ++i) {
            string memory at = string.concat("$.abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(at, ".type")))) != keccak256("error")) continue;
            string memory name = vm.parseJsonString(json, string.concat(at, ".name"));
            bool known = false;
            for (uint256 j; j < errors.length; ++j) {
                if (keccak256(bytes(name)) == keccak256(bytes(errors[j]))) known = true;
            }
            assertTrue(known, string.concat("an error not in the list: ", name));
            ++found;
        }
        assertEq(found, errors.length, "the error count");
    }

    // ---------------------------------------------------------------------------------------------------
    // "The creation fee goes to the transaction sender." The reporter's half: it passes on the payout address
    // in the report and never puts in its caller's or the transaction's sender.
    // ---------------------------------------------------------------------------------------------------

    /// A stranger sends the forwarder's report whose payout is an address in none of the call: the fee goes
    /// there, and nothing to the stranger, the forwarder, the reporter or the workflow owner. A report that
    /// names the stranger pays the stranger, since that is the report's.
    /// Break: in onReport(), after the decode, `r.payout = tx.origin;` (or `msg.sender`).
    function test_neverLine_thePayoutIsTheReportsAndNeverTheSenders() public {
        uint256 game = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        Report memory score = _scoreReport(game, HOME, AWAY);
        score.payout = named;
        assertTrue(
            named != stranger && named != address(forwarder) && named != address(chainlink) && named != workflowOwner
                && named != deployer,
            "named in none of the call"
        );
        _relay(stranger, _good(), score);
        assertEq(games.getCredit(named), FEE, "the fee to the address in the report");
        address[5] memory nobody = [stranger, address(forwarder), address(chainlink), workflowOwner, deployer];
        for (uint256 i; i < nobody.length; ++i) {
            assertEq(games.getCredit(nobody[i]), 0, "credited without being named");
        }

        // Named in the report, the stranger is paid: the report's word, not the sender's standing.
        uint256 second = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        Report memory own = _scoreReport(second, HOME, AWAY);
        own.payout = stranger;
        _relay(stranger, _good(), own);
        assertEq(games.getCredit(stranger), FEE, "named, so paid");
    }

    // ---------------------------------------------------------------------------------------------------
    // "The creation fee goes to an address where it literally can't be withdrawn." The reporter's half: it
    // holds no money and is never the payout address.
    // ---------------------------------------------------------------------------------------------------

    /// A report naming the reporter as payout is refused by the games set, through the reporter, with nothing
    /// written; the reporter takes no coin of the chain, is credited nothing across every relay, and holds
    /// no coin.
    /// Break: in onReport(), after the decode, `r.payout = address(this);`. The named report is then refused.
    function test_neverLine_theReporterHoldsNoMoneyAndIsNeverPaid() public {
        uint256 game = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        Report memory toItself = _scoreReport(game, HOME, AWAY);
        toItself.payout = address(chainlink);
        _expectRefused(
            _good(),
            abi.encode(toItself),
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Score, address(chainlink))
        );
        Report memory toForwarder = _scoreReport(game, HOME, AWAY);
        toForwarder.payout = address(forwarder);
        _relay(stranger, _good(), toForwarder);
        assertEq(games.getCredit(address(forwarder)), FEE, "the forwarder is an address like any other to the games set");

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool paid,) = address(chainlink).call{value: 1}("");
        assertFalse(paid, "the reporter takes the chain's coin");
        assertEq(address(chainlink).balance, 0, "no coin of the chain");
        assertEq(token.balanceOf(address(chainlink)), 0, "no coin");
        assertEq(games.getCredit(address(chainlink)), 0, "no credit");
    }

    // ---------------------------------------------------------------------------------------------------
    // "A rejected report changes any game's state or moves any money." The first half: a report the reporter
    // refuses reaches nothing.
    // ---------------------------------------------------------------------------------------------------

    /// Each refusal the reporter makes, and each the games set makes through it, leaves every read of every
    /// game and every balance and credit as they were, and the reporter never calls the games set for one
    /// it refuses itself.
    function test_neverLine_aRefusedReportReachesNothing() public {
        uint256 game = _inStatus(GameStatus.Verified);
        vm.warp(START + 1);
        bytes memory score = abi.encode(_scoreReport(game, HOME, AWAY));
        bytes32 before = _everything();

        // The games set hears two reports in this test: the one it refuses itself, and the control's. The
        // reporter's own refusals never reach it.
        vm.expectCall(address(games), abi.encodeWithSelector(IOspexGames.report.selector), 2);
        _expectRefused(
            _metadata(WORKFLOW_ID, stranger),
            score,
            abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowOwner.selector, stranger)
        );
        _expectRefused(
            _metadata(bytes32(0), workflowOwner),
            score,
            abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowId.selector, bytes32(0))
        );
        _expectRefused(
            _prefix(_good(), 63),
            score,
            abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__MetadataTooShort.selector, 63)
        );
        // The games set's refusal, through the reporter.
        Report memory noPayout = _scoreReport(game, HOME, AWAY);
        noPayout.payout = address(0);
        _expectRefused(
            _good(), abi.encode(noPayout), abi.encodeWithSelector(OspexGames.OspexGames__NoPayout.selector, ReportKind.Score)
        );
        assertEq(_everything(), before, "something changed");

        // Control: the same score, right, is taken.
        _relay(stranger, _good(), _scoreReport(game, HOME, AWAY));
        assertTrue(_everything() != before, "the control changed nothing");
    }

    // ---------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------

    /// @dev The forwarder's metadata: the id, the hashed name, the owner and the report id, 64 bytes.
    function _metadata(bytes32 id, address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(id, NAME, owner, REPORT_ID);
    }

    function _good() internal view returns (bytes memory) {
        return _metadata(WORKFLOW_ID, workflowOwner);
    }

    /// @dev Sends a report through the forwarder from `origin`, as sender and origin. Reverts as the reporter
    ///      or the games set did.
    function _relay(address origin, bytes memory metadata, Report memory r) internal {
        vm.prank(origin, origin);
        forwarder.report(address(chainlink), metadata, abi.encode(r));
    }

    /// @dev Relays `r` and checks the two events: the games set's, carrying the report field for field, then
    ///      the reporter's, carrying the report id and the payout.
    function _relayAndCheck(uint256 game, Report memory r) internal {
        vm.recordLogs();
        _relay(stranger, _good(), r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory reported = _theLog(logs, address(games), IOspexGames.GameReported.selector);
        assertEq(reported.topics[1], bytes32(game), "game");
        assertEq(reported.topics[2], bytes32(uint256(uint160(address(chainlink)))), "the reporter wrote it");
        assertEq(reported.topics[3], bytes32(uint256(uint8(r.kind))), "kind");
        assertEq(
            keccak256(reported.data),
            keccak256(abi.encode(r.start, r.homeScore, r.awayScore, r.readings, r.payout)),
            "the report, field for field"
        );
        Vm.Log memory relayed = _theLog(logs, address(chainlink), ReportRelayed.selector);
        assertEq(relayed.topics[1], bytes32(game), "relayed: game");
        assertEq(relayed.topics[2], bytes32(uint256(uint8(r.kind))), "relayed: kind");
        assertEq(keccak256(relayed.data), keccak256(abi.encode(REPORT_ID, r.payout)), "relayed: report id and payout");
        assertTrue(_indexOf(logs, address(games), IOspexGames.GameReported.selector) < _indexOf(logs, address(chainlink), ReportRelayed.selector), "the reporter's event follows the games set's");
    }

    /// @dev Expects the relay of `data` under `metadata` to be refused, with `err` if given, and nothing changed.
    function _expectRefused(bytes memory metadata, bytes memory data, bytes memory err) internal {
        bytes32 before = _everything();
        vm.prank(stranger, stranger);
        (bool ok, bytes memory got) =
            address(forwarder).call(abi.encodeCall(MockForwarder.report, (address(chainlink), metadata, data)));
        assertFalse(ok, "taken");
        if (err.length != 0) assertEq(got, err, "another reason");
        assertEq(_everything(), before, "something changed");
    }

    /// @dev Every read of every game and every balance and credit a reader can see.
    function _everything() internal view returns (bytes32) {
        address[] memory accounts = new address[](9);
        accounts[0] = creator;
        accounts[1] = payout;
        accounts[2] = named;
        accounts[3] = stranger;
        accounts[4] = address(forwarder);
        accounts[5] = address(chainlink);
        accounts[6] = workflowOwner;
        accounts[7] = deployer;
        accounts[8] = timelockKey;
        return keccak256(abi.encode(_viewAll(), _money(accounts), _viewList()));
    }

    function _prefix(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
    }

    function _theLog(Vm.Log[] memory logs, address emitter, bytes32 selector) internal pure returns (Vm.Log memory) {
        uint256 i = _indexOf(logs, emitter, selector);
        require(i < logs.length, "no such log");
        return logs[i];
    }

    function _indexOf(Vm.Log[] memory logs, address emitter, bytes32 selector) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == selector) return i;
        }
        return logs.length;
    }

    /// @dev The runtime code without solc's metadata, whose length its last two bytes give.
    function _executable(bytes memory code) internal pure returns (bytes memory out) {
        uint256 n = code.length;
        uint256 metadata = (uint256(uint8(code[n - 2])) << 8) | uint256(uint8(code[n - 1]));
        uint256 end = n - 2 - metadata;
        out = new bytes(end);
        for (uint256 i; i < end; ++i) {
            out[i] = code[i];
        }
    }

    /// @dev True when `op` appears as an instruction: a PUSH's immediate bytes are skipped.
    function _hasOpcode(bytes memory exe, uint8 op) internal pure returns (bool) {
        for (uint256 i; i < exe.length; ++i) {
            uint8 b = uint8(exe[i]);
            if (b == op) return true;
            if (b >= 0x60 && b <= 0x7f) i += b - 0x5f;
        }
        return false;
    }

    function _has(string[] memory list, string memory s) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == keccak256(bytes(s))) return true;
        }
        return false;
    }
}
