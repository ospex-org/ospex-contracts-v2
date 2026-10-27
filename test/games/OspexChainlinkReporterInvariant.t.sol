// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexChainlinkReporter} from "../../src/games/OspexChainlinkReporter.sol";
import {IReceiver} from "../../src/interfaces/cre/IReceiver.sol";
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
import {GamesBase, Deploy, MockReporter, OspexGamesHarness} from "./GamesBase.sol";
import {MockForwarder} from "./ForwarderFixtures.sol";
import {RefusingCoin} from "./CoinFixtures.sol";

/// @dev Drives the Chainlink reporter at random: reports of every kind, to several games, under right and wrong
///      metadata, from the forwarder and from everyone else, with payouts the games set takes and payouts it
///      refuses. Its model is the reporter's gate alone, written from the spec and never read back: a report
///      reaches the games set only from the forwarder, only under the fixed owner and id, with a live report's
///      metadata; a report the reporter refuses changes nothing; a report the games set takes credits the fee
///      to the payout address in the report and to no one else, and the reporter is never credited and never
///      holds coin. Whether the games set takes a report is the games set's business, checked elsewhere.
contract RelayHandler is Test {
    uint64 internal constant DATE = 1_800_000_037;
    bytes10 internal constant NAME = bytes10("830f5085b7");

    OspexGamesHarness public immutable games;
    OspexChainlinkReporter public immutable chainlink;
    MockForwarder public immutable forwarder;
    MockForwarder public immutable otherForwarder;
    RefusingCoin public immutable token;
    address public immutable owner;
    bytes32 public immutable id;
    uint96 public immutable fee;

    /// @dev Every address a report may name as payout: ones the games set takes, and ones it refuses.
    address[] public payouts;
    /// @dev Senders other than the forwarder.
    address[] public actors;
    uint256[] public gameIds;
    /// @dev What each payout should have been credited: the fee for each ended report that named it.
    mapping(address => uint256) public ghostCredit;

    uint256 public relays;
    uint256 public taken;
    uint256 public refusedByReporter;
    uint256 public refusedByGames;
    uint256 public starts;
    uint256 public ends;
    /// @dev Calls where the reporter and the model disagreed. Must stay 0.
    uint256 public mismatches;

    constructor(
        OspexGamesHarness games_,
        OspexChainlinkReporter chainlink_,
        MockForwarder forwarder_,
        MockForwarder otherForwarder_,
        RefusingCoin token_,
        address owner_,
        bytes32 id_,
        address[] memory payouts_,
        address[] memory actors_,
        uint256[] memory gameIds_
    ) {
        games = games_;
        chainlink = chainlink_;
        forwarder = forwarder_;
        otherForwarder = otherForwarder_;
        token = token_;
        owner = owner_;
        id = id_;
        fee = games_.getTerms("").fee;
        payouts = payouts_;
        actors = actors_;
        gameIds = gameIds_;
    }

    function payoutCount() external view returns (uint256) {
        return payouts.length;
    }

    /// @dev Time moves forward, up to two days at a step.
    function warp(uint256 by) external {
        vm.warp(vm.getBlockTimestamp() + bound(by, 0, 2 days));
    }

    /// @dev One report, through the reporter or at it, as the seeds say. Time moves forward a little first, so
    ///      that starts, scores, voids and day-7 results all fall due over a run.
    function relay(
        uint256 gameSeed,
        uint8 kindSeed,
        uint256 payoutSeed,
        uint8 metaSeed,
        uint8 senderSeed,
        uint32 home,
        uint32 away,
        uint64 startSeed
    ) external {
        vm.warp(vm.getBlockTimestamp() + (uint256(startSeed) % 6 hours));
        Report memory r = _report(gameSeed, kindSeed, payoutSeed, home, away, startSeed);
        (bytes memory metadata, bytes memory metaErr) = _metadata(metaSeed);
        address sender = _sender(senderSeed);
        bytes memory data = abi.encode(r);

        bytes32 before = _state();
        uint256[] memory creditsBefore = _credits();
        bool ok;
        bytes memory err;
        bytes memory expected;
        if (sender == address(forwarder)) {
            address origin = actors[senderSeed % actors.length];
            vm.prank(origin, origin);
            (ok, err) = address(forwarder).call(abi.encodeCall(MockForwarder.report, (address(chainlink), metadata, data)));
            expected = metaErr;
        } else if (sender == address(otherForwarder)) {
            (ok, err) = address(otherForwarder).call(
                abi.encodeCall(MockForwarder.report, (address(chainlink), metadata, data))
            );
            expected = abi.encodeWithSelector(
                OspexChainlinkReporter.OspexChainlinkReporter__NotTheForwarder.selector, address(otherForwarder)
            );
        } else {
            vm.prank(sender, sender);
            (ok, err) = address(chainlink).call(abi.encodeCall(IReceiver.onReport, (metadata, data)));
            expected = abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheForwarder.selector, sender);
        }
        ++relays;

        if (expected.length != 0) {
            // The reporter's own refusal: by name, and nothing changed.
            if (ok || keccak256(err) != keccak256(expected) || _state() != before) ++mismatches;
            ++refusedByReporter;
            return;
        }
        if (!ok) {
            // The games set's refusal, through the reporter: nothing changed.
            if (_state() != before) ++mismatches;
            ++refusedByGames;
            return;
        }
        ++taken;
        bool end = r.kind == ReportKind.Score || r.kind == ReportKind.Void;
        if (r.kind == ReportKind.Start) ++starts;
        if (end) ++ends;
        // The fee went to the payout in the report, and to no one else.
        uint256[] memory afterCall = _credits();
        for (uint256 i; i < payouts.length; ++i) {
            uint256 want = creditsBefore[i] + ((end && payouts[i] == r.payout) ? fee : 0);
            if (afterCall[i] != want) ++mismatches;
        }
        if (end) ghostCredit[r.payout] += fee;
        if (games.getCredit(address(chainlink)) != 0 || token.balanceOf(address(chainlink)) != 0) ++mismatches;
    }

    // ──────────────────────────── Shapes ───────────────────────────────

    function _report(uint256 gameSeed, uint8 kindSeed, uint256 payoutSeed, uint32 home, uint32 away, uint64 startSeed)
        internal
        view
        returns (Report memory r)
    {
        r.gameId = gameIds[gameSeed % gameIds.length];
        uint8 k = kindSeed % 5;
        home = uint32(bound(home, 0, 300));
        away = uint32(bound(away, 0, 300));
        address payout = payouts[payoutSeed % payouts.length];
        if (k == 0) {
            r.kind = ReportKind.Start;
            r.start = DATE + uint64(bound(startSeed, 0, 20 hours));
            r.readings = _plainReadings(home, away);
            r.payout = payoutSeed % 7 == 0 ? payout : address(0);
        } else if (k == 1 || k == 4) {
            r.kind = ReportKind.Score;
            r.homeScore = home;
            r.awayScore = away;
            r.readings = _scoreReadings(home, away);
            r.payout = payout;
        } else if (k == 2) {
            r.kind = ReportKind.Void;
            r.readings = _voidReadings();
            r.payout = payout;
        } else {
            r.kind = ReportKind.Dispute;
            r.readings = _disputeReadings(home, away);
            r.payout = payoutSeed % 7 == 0 ? payout : address(0);
        }
    }

    function _plainReadings(uint32 home, uint32 away) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 1, awayScore: 2});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
    }

    function _scoreReadings(uint32 home, uint32 away) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
    }

    function _voidReadings() internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredNoFinal, homeScore: 51, awayScore: 49});
        readings[2] = Reading({seat: 3, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
        readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredNoFinal, homeScore: 0, awayScore: 0});
    }

    function _disputeReadings(uint32 home, uint32 away) internal pure returns (Reading[] memory readings) {
        readings = new Reading[](4);
        readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
        readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: home + 3, awayScore: away});
        readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 88, awayScore: 90});
        readings[3] = Reading({seat: 4, kind: ReadingKind.Silent, homeScore: 0, awayScore: 0});
    }

    /// @dev Metadata by seed: right most of the time; otherwise another owner, another id, too short, or longer.
    ///      Returns the reporter's refusal for it, or nothing if the reporter takes it.
    function _metadata(uint8 seed) internal view returns (bytes memory metadata, bytes memory err) {
        uint8 pick = seed % 10;
        if (pick < 6) return (abi.encodePacked(id, NAME, owner, bytes2(uint16(seed))), "");
        if (pick == 6) {
            address other = actors[seed % actors.length];
            return (
                abi.encodePacked(id, NAME, other, bytes2(0x0001)),
                abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowOwner.selector, other)
            );
        }
        if (pick == 7) {
            bytes32 otherId = bytes32(uint256(id) ^ (uint256(seed) + 1));
            return (
                abi.encodePacked(otherId, NAME, owner, bytes2(0x0001)),
                abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__NotTheWorkflowId.selector, otherId)
            );
        }
        if (pick == 8) {
            bytes memory whole = abi.encodePacked(id, NAME, owner, bytes2(0x0001));
            uint256 n = seed % 64;
            metadata = new bytes(n);
            for (uint256 i; i < n; ++i) {
                metadata[i] = whole[i];
            }
            return (metadata, abi.encodeWithSelector(OspexChainlinkReporter.OspexChainlinkReporter__MetadataTooShort.selector, n));
        }
        return (abi.encodePacked(id, NAME, owner, bytes2(0x0001), new bytes(seed % 50)), "");
    }

    /// @dev The forwarder seven times in ten; otherwise another forwarder or another actor.
    function _sender(uint8 seed) internal view returns (address) {
        uint8 pick = seed % 10;
        if (pick < 7) return address(forwarder);
        if (pick == 7) return address(otherForwarder);
        return actors[seed % actors.length];
    }

    // ──────────────────────────── What a reader sees ───────────────────

    function _credits() internal view returns (uint256[] memory out) {
        out = new uint256[](payouts.length);
        for (uint256 i; i < payouts.length; ++i) {
            out[i] = games.getCredit(payouts[i]);
        }
    }

    /// @dev Every game's status, start, scores and dispute time, every tracked credit, and the coin held.
    function _state() internal view returns (bytes32) {
        bytes memory out = abi.encode(token.balanceOf(address(games)), token.balanceOf(address(chainlink)));
        for (uint256 i; i < gameIds.length; ++i) {
            uint256 g = gameIds[i];
            (bool okStart, bytes memory start) = address(games).staticcall(abi.encodeCall(IOspexGames.getGameStart, (g)));
            (bool okScores, bytes memory scores) = address(games).staticcall(abi.encodeCall(IOspexGames.getGameScores, (g)));
            (bool okDisputed, bytes memory disputed) =
                address(games).staticcall(abi.encodeCall(IOspexGames.getGameDisputedAt, (g)));
            (uint96 held,) = games.getGameFee(g);
            out = abi.encodePacked(
                out, uint8(games.getGameStatus(g)), okStart, start, okScores, scores, okDisputed, disputed, held
            );
        }
        for (uint256 i; i < payouts.length; ++i) {
            out = abi.encodePacked(out, games.getCredit(payouts[i]));
        }
        return keccak256(out);
    }
}

/// @notice The stateful run for the Chainlink reporter: reports and money moving through it at random.
contract OspexChainlinkReporterInvariantTest is GamesBase {
    bytes32 internal constant WORKFLOW_ID = 0x00a7c1d3e5f709112233445566778899aabbccddeeff00112233445566778899;
    uint256 internal constant GAMES = 6;

    MockForwarder internal forwarder;
    MockForwarder internal otherForwarder;
    OspexChainlinkReporter internal chainlink;
    RelayHandler internal handler;
    address internal workflowOwner = makeAddr("workflow owner");

    function setUp() public override {
        vm.warp(DATE - 1 hours);
        timelock = new TimelockController(DELAY, _one(timelockKey), _one(address(0)), address(0));
        token = new RefusingCoin();
        forwarder = new MockForwarder();
        otherForwarder = new MockForwarder();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        vm.startPrank(deployer, deployer);
        chainlink = new OspexChainlinkReporter(address(forwarder), workflowOwner, WORKFLOW_ID, IOspexGames(predicted));
        later = new MockReporter(IOspexGames(predicted));
        address[] memory reporters = new address[](2);
        reporters[0] = address(chainlink);
        reporters[1] = address(later);
        ReporterKind[] memory kinds = new ReporterKind[](2);
        kinds[0] = ReporterKind.FirstN;
        kinds[1] = ReporterKind.AfterN;
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

        uint256[] memory ids = new uint256[](GAMES);
        for (uint256 i; i < GAMES; ++i) {
            ids[i] = _createAt(DATE + uint64(i) * 1 hours);
        }

        address[] memory payouts = new address[](10);
        payouts[0] = makeAddr("payout a");
        payouts[1] = makeAddr("payout b");
        payouts[2] = stranger;
        payouts[3] = address(forwarder);
        payouts[4] = workflowOwner;
        payouts[5] = address(chainlink); // refused: a reporter
        payouts[6] = address(later); // refused: a reporter
        payouts[7] = address(games); // refused
        payouts[8] = address(token); // refused
        payouts[9] = address(0); // refused
        address[] memory actors = new address[](6);
        actors[0] = stranger;
        actors[1] = workflowOwner;
        actors[2] = deployer;
        actors[3] = timelockKey;
        actors[4] = creator;
        actors[5] = address(games);

        handler = new RelayHandler(
            games, chainlink, forwarder, otherForwarder, token, workflowOwner, WORKFLOW_ID, payouts, actors, ids
        );
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theReporterRelaysExactlyWhatTheForwarderSendsAndNothingElse() public view {
        assertEq(handler.mismatches(), 0, "the reporter and the model disagreed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theFeeGoesWhereTheTakenReportSaidAndTheReporterIsNeverPaid() public view {
        for (uint256 i; i < handler.payoutCount(); ++i) {
            address a = handler.payouts(i);
            assertEq(games.getCredit(a), handler.ghostCredit(a), "a credit other than the taken reports named");
        }
        assertEq(games.getCredit(address(chainlink)), 0, "the reporter is credited");
        assertEq(token.balanceOf(address(chainlink)), 0, "the reporter holds coin");
        assertEq(address(chainlink).balance, 0, "the reporter holds the chain's coin");
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 20
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theFixedValuesNeverChange() public view {
        assertEq(chainlink.i_forwarder(), address(forwarder), "forwarder");
        assertEq(chainlink.i_workflowOwner(), workflowOwner, "owner");
        assertEq(chainlink.i_workflowId(), WORKFLOW_ID, "id");
        assertEq(address(chainlink.i_games()), address(games), "games");
        assertEq(chainlink.fixedValues(), abi.encode(address(forwarder), workflowOwner, WORKFLOW_ID), "fixed values");
    }

    /// @dev Totals across every run of this contract's invariants, kept in the process environment since each
    ///      run starts from setUp; the last run's log line holds the sums.
    function afterInvariant() public {
        uint256 relays = vm.envOr("REPORTER_RELAYS", uint256(0)) + handler.relays();
        uint256 taken = vm.envOr("REPORTER_TAKEN", uint256(0)) + handler.taken();
        uint256 byReporter = vm.envOr("REPORTER_REFUSED", uint256(0)) + handler.refusedByReporter();
        uint256 byGames = vm.envOr("REPORTER_GAMES_REFUSED", uint256(0)) + handler.refusedByGames();
        uint256 starts = vm.envOr("REPORTER_STARTS", uint256(0)) + handler.starts();
        uint256 ends = vm.envOr("REPORTER_ENDS", uint256(0)) + handler.ends();
        vm.setEnv("REPORTER_RELAYS", vm.toString(relays));
        vm.setEnv("REPORTER_TAKEN", vm.toString(taken));
        vm.setEnv("REPORTER_REFUSED", vm.toString(byReporter));
        vm.setEnv("REPORTER_GAMES_REFUSED", vm.toString(byGames));
        vm.setEnv("REPORTER_STARTS", vm.toString(starts));
        vm.setEnv("REPORTER_ENDS", vm.toString(ends));
        console2.log("totals so far: relays", relays, "taken", taken);
        console2.log("refused by the reporter", byReporter, "by the games set", byGames);
        console2.log("starts", starts, "ends", ends);
    }
}
