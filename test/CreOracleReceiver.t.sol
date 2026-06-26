// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OspexCore} from "../src/core/OspexCore.sol";
import {ContestModule} from "../src/modules/ContestModule.sol";
import {TreasuryModule} from "../src/modules/TreasuryModule.sol";
import {CreOracleReceiver} from "../src/modules/CreOracleReceiver.sol";
import {IReceiver} from "../src/interfaces/cre/IReceiver.sol";
import {IERC165} from "../src/interfaces/cre/IERC165.sol";
import {Contest, ContestMarket, ContestStatus, LeagueId} from "../src/core/OspexTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Minimal stand-in for the Chainlink KeystoneForwarder: routes a report to a
///         receiver so msg.sender on onReport is this contract (as in production).
contract MockKeystoneForwarder {
    function route(
        address receiver,
        bytes calldata metadata,
        bytes calldata report
    ) external {
        IReceiver(receiver).onReport(metadata, report);
    }
}

/**
 * @title CreOracleReceiverTest
 * @notice Unit + integration tests for the CRE receiver. Each scenario deploys a real OspexCore +
 *         ContestModule + TreasuryModule (zero fees) with CreOracleReceiver in the ORACLE_MODULE
 *         slot, plus a MockKeystoneForwarder. Exercises the trust model (forwarder / workflow owner /
 *         name; the workflow id is intentionally NOT pinned), domain separation (chain id / receiver),
 *         per-report idempotency, the fail-closed request/report binding (verify/score flags + market
 *         nonce), the pre-start score guard, and the verify/market/score apply paths.
 */
contract CreOracleReceiverTest is Test {
    OspexCore internal core;
    ContestModule internal contestModule;
    TreasuryModule internal treasuryModule;
    MockERC20 internal usdc;
    MockKeystoneForwarder internal forwarder;
    CreOracleReceiver internal receiver;

    address internal wfOwner;
    bytes10 internal constant WF_NAME = bytes10("osxverify1");
    /// @dev The workflow id is NOT pinned by the receiver (CRE rotates it on update); this value is
    ///      only used to fill the metadata layout, never validated.
    bytes32 internal constant WF_ID =
        0x0011223344556677889900aabbccddeeff00112233445566778899aabbccddee;

    address internal constant PROTOCOL_RECEIVER = address(0xFEE5);
    address internal user = address(0xCA11);

    // Mirrors of CreOracleReceiver events for expectEmit.
    event CreOracleRequested(
        uint256 indexed contestId,
        uint8 indexed requestType,
        uint64 requestNonce,
        string rundownId,
        string sportspageId,
        string jsonoddsId
    );
    event CreReportProcessed(
        bytes32 indexed reportKey,
        uint8 requestType,
        uint256 indexed contestId
    );

    function setUp() public {
        wfOwner = makeAddr("workflowOwner");
        (core, contestModule, forwarder, receiver) = _deploy();
    }

    // ──────────────────────────── Deploy a fresh protocol ──────────────

    function _deploy()
        internal
        returns (
            OspexCore core_,
            ContestModule contest_,
            MockKeystoneForwarder fwd_,
            CreOracleReceiver receiver_
        )
    {
        core_ = new OspexCore();
        usdc = new MockERC20();
        contest_ = new ContestModule(address(core_));
        treasuryModule = new TreasuryModule(
            address(core_),
            address(usdc),
            PROTOCOL_RECEIVER,
            0, // contestCreationFee — zero so no USDC moves
            0, // speculationCreationFee
            0 // leaderboardCreationFee
        );
        fwd_ = new MockKeystoneForwarder();
        receiver_ = new CreOracleReceiver(
            address(core_),
            address(fwd_),
            wfOwner,
            WF_NAME
        );

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core_.CONTEST_MODULE();
        addrs[0] = address(contest_);
        types[1] = core_.SPECULATION_MODULE();
        addrs[1] = address(0xA1);
        types[2] = core_.POSITION_MODULE();
        addrs[2] = address(0xA2);
        types[3] = core_.MATCHING_MODULE();
        addrs[3] = address(0xA3);
        types[4] = core_.ORACLE_MODULE();
        addrs[4] = address(receiver_);
        types[5] = core_.TREASURY_MODULE();
        addrs[5] = address(treasuryModule);
        types[6] = core_.LEADERBOARD_MODULE();
        addrs[6] = address(0xA6);
        types[7] = core_.RULES_MODULE();
        addrs[7] = address(0xA7);
        types[8] = core_.SECONDARY_MARKET_MODULE();
        addrs[8] = address(0xA8);
        types[9] = core_.MONEYLINE_SCORER_MODULE();
        addrs[9] = address(0xA9);
        types[10] = core_.SPREAD_SCORER_MODULE();
        addrs[10] = address(0xAA);
        types[11] = core_.TOTAL_SCORER_MODULE();
        addrs[11] = address(0xAB);
        core_.bootstrapModules(types, addrs);
        core_.finalize();
    }

    // ──────────────────────────── Encoding helpers ─────────────────────

    /// @dev Mirrors the KeystoneForwarder metadata: packed workflowId|workflowName|owner|reportId.
    function _metadata(
        bytes32 id,
        bytes10 name,
        address owner
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(id, name, owner, bytes2(0xABCD));
    }

    /// @dev Report envelope: abi.encode(uint8 requestType, uint256 chainId, address receiver,
    ///      uint64 requestNonce, bytes payload). Helpers bind block.chainid + the target receiver.
    function _verifyReport(
        address rcv,
        uint256 contestId,
        uint8 leagueId,
        uint32 startTime,
        uint16 version
    ) internal view returns (bytes memory) {
        bytes memory payload = abi.encode(contestId, leagueId, startTime, version);
        return abi.encode(uint8(0), block.chainid, rcv, uint64(0), payload);
    }

    function _marketReport(
        address rcv,
        uint256 contestId,
        uint64 nonce,
        uint16 mlAway,
        uint16 mlHome,
        int32 spreadTicks,
        uint16 spreadAway,
        uint16 spreadHome,
        int32 totalTicks,
        uint16 overOdds,
        uint16 underOdds,
        uint16 version
    ) internal view returns (bytes memory) {
        bytes memory payload = abi.encode(
            contestId,
            mlAway,
            mlHome,
            spreadTicks,
            spreadAway,
            spreadHome,
            totalTicks,
            overOdds,
            underOdds,
            version
        );
        return abi.encode(uint8(1), block.chainid, rcv, nonce, payload);
    }

    function _scoreReport(
        address rcv,
        uint256 contestId,
        uint32 awayScore,
        uint32 homeScore,
        uint16 version
    ) internal view returns (bytes memory) {
        bytes memory payload = abi.encode(contestId, awayScore, homeScore, version);
        return abi.encode(uint8(2), block.chainid, rcv, uint64(0), payload);
    }

    /// @dev create + verify a contest (start time = 1, i.e. already started) so market/score reports
    ///      and a permissionless score request have a Verified, started target.
    function _createAndVerify(
        CreOracleReceiver r,
        MockKeystoneForwarder fwd
    ) internal returns (uint256 contestId) {
        contestId = _create(r);
        fwd.route(
            address(r),
            _metadata(WF_ID, WF_NAME, wfOwner),
            _verifyReport(address(r), contestId, uint8(LeagueId.MLB), 1, 1)
        );
    }

    function _create(CreOracleReceiver r) internal returns (uint256 contestId) {
        vm.prank(user);
        contestId = r.createContestAndRequestVerify(
            "rundown-abc",
            "sportspage-def",
            "jsonodds-ghi"
        );
    }

    // ──────────────────────────── Request path ─────────────────────────

    function test_createContestAndRequestVerify_createsUnverifiedAndEmits() public {
        vm.expectEmit(true, true, false, true, address(receiver));
        emit CreOracleRequested(1, 0, 0, "rundown-abc", "sportspage-def", "jsonodds-ghi");
        uint256 contestId = _create(receiver);

        assertEq(contestId, 1);
        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint8(c.contestStatus), uint8(ContestStatus.Unverified));
        assertEq(c.rundownId, "rundown-abc");
        assertEq(c.contestCreator, user);
    }

    // ──────────────────────────── Happy path ───────────────────────────

    function test_onReport_validVerify_setsLeagueStartTimeAndVerifies() public {
        uint256 contestId = _create(receiver);
        uint8 nfl = uint8(LeagueId.NFL); // 2
        uint32 startTime = 1893456000;

        bytes memory metadata = _metadata(WF_ID, WF_NAME, wfOwner);
        bytes memory report = _verifyReport(address(receiver), contestId, nfl, startTime, 1);

        vm.expectEmit(true, true, false, true, address(receiver));
        emit CreReportProcessed(keccak256(report), 0, contestId);
        forwarder.route(address(receiver), metadata, report);

        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint8(c.contestStatus), uint8(ContestStatus.Verified));
        assertEq(uint8(c.leagueId), nfl);
        assertEq(contestModule.s_contestStartTimes(contestId), startTime);
        assertTrue(receiver.s_processedReport(keccak256(report)));
    }

    // ──────────────────────────── Trust model ──────────────────────────

    function test_onReport_revertsOnWrongForwarder() public {
        uint256 contestId = _create(receiver);
        bytes memory metadata = _metadata(WF_ID, WF_NAME, wfOwner);
        bytes memory report = _verifyReport(address(receiver), contestId, uint8(LeagueId.NFL), 1893456000, 1);

        // Direct call: msg.sender = address(this), not the forwarder.
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__InvalidSender.selector,
                address(this),
                address(forwarder)
            )
        );
        receiver.onReport(metadata, report);
    }

    function test_onReport_revertsOnWrongWorkflowOwner() public {
        uint256 contestId = _create(receiver);
        address badOwner = makeAddr("attacker");
        bytes memory metadata = _metadata(WF_ID, WF_NAME, badOwner);
        bytes memory report = _verifyReport(address(receiver), contestId, uint8(LeagueId.NFL), 1893456000, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__InvalidWorkflowOwner.selector,
                badOwner,
                wfOwner
            )
        );
        forwarder.route(address(receiver), metadata, report);
    }

    function test_onReport_revertsOnWrongWorkflowName() public {
        uint256 contestId = _create(receiver);
        bytes10 badName = bytes10("wrongname0");
        bytes memory metadata = _metadata(WF_ID, badName, wfOwner);
        bytes memory report = _verifyReport(address(receiver), contestId, uint8(LeagueId.NFL), 1893456000, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__InvalidWorkflowName.selector,
                badName,
                WF_NAME
            )
        );
        forwarder.route(address(receiver), metadata, report);
    }

    /// @dev The workflow id is NOT pinned — a report with ANY id in its metadata is accepted as long
    ///      as owner + name match. This is required because CRE rotates the id on every update.
    function test_onReport_workflowIdNotPinned_anyIdAccepted() public {
        uint256 contestId = _create(receiver);
        bytes32 anyId = keccak256("some-rotated-id");
        bytes memory metadata = _metadata(anyId, WF_NAME, wfOwner);
        bytes memory report = _verifyReport(address(receiver), contestId, uint8(LeagueId.MLB), 1893456000, 1);
        forwarder.route(address(receiver), metadata, report);

        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint8(c.contestStatus), uint8(ContestStatus.Verified));
        assertEq(uint8(c.leagueId), uint8(LeagueId.MLB));
    }

    // ──────────────────────────── Domain separation ───────────────────

    function test_onReport_revertsOnWrongChainId() public {
        uint256 contestId = _create(receiver);
        uint256 wrongChain = block.chainid + 1;
        bytes memory payload = abi.encode(contestId, uint8(LeagueId.NFL), uint32(1), uint16(1));
        bytes memory report = abi.encode(uint8(0), wrongChain, address(receiver), uint64(0), payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__WrongChainId.selector,
                wrongChain,
                block.chainid
            )
        );
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    function test_onReport_revertsOnWrongReceiver() public {
        uint256 contestId = _create(receiver);
        address wrongRcv = address(0xBEEF);
        bytes memory payload = abi.encode(contestId, uint8(LeagueId.NFL), uint32(1), uint16(1));
        bytes memory report = abi.encode(uint8(0), block.chainid, wrongRcv, uint64(0), payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__WrongReceiver.selector,
                wrongRcv,
                address(receiver)
            )
        );
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    // ──────────────────────────── Replay / dispatch / metadata ────────

    function test_onReport_revertsOnReplay() public {
        uint256 contestId = _create(receiver);
        bytes memory metadata = _metadata(WF_ID, WF_NAME, wfOwner);
        bytes memory report = _verifyReport(address(receiver), contestId, uint8(LeagueId.NFL), 1893456000, 1);

        forwarder.route(address(receiver), metadata, report); // first: ok
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__ReportAlreadyProcessed.selector,
                keccak256(report)
            )
        );
        forwarder.route(address(receiver), metadata, report); // replay: revert
    }

    function test_onReport_revertsOnUnknownRequestType() public {
        _create(receiver);
        bytes memory metadata = _metadata(WF_ID, WF_NAME, wfOwner);
        // requestType = 99 — not a valid OracleRequestType (0/1/2 are all wired now).
        bytes memory payload = abi.encode(uint256(1), uint8(0), uint32(1), uint16(1));
        bytes memory report = abi.encode(uint8(99), block.chainid, address(receiver), uint64(0), payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__InvalidRequestType.selector,
                uint8(99)
            )
        );
        forwarder.route(address(receiver), metadata, report);
    }

    function test_onReport_revertsOnShortMetadata() public {
        uint256 contestId = _create(receiver);
        bytes memory shortMeta = new bytes(40); // < 62
        bytes memory report = _verifyReport(address(receiver), contestId, uint8(LeagueId.NFL), 1893456000, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__InvalidMetadata.selector,
                uint256(40)
            )
        );
        forwarder.route(address(receiver), shortMeta, report);
    }

    /// @dev Defense-in-depth: a second valid verify for the same contest (fresh report key, so it
    ///      passes idempotency) is rejected by ContestModule's one-shot Unverified->Verified.
    function test_onReport_secondVerifyForSameContestReverts() public {
        uint256 contestId = _create(receiver);
        bytes memory metadata = _metadata(WF_ID, WF_NAME, wfOwner);
        forwarder.route(
            address(receiver),
            metadata,
            _verifyReport(address(receiver), contestId, uint8(LeagueId.NFL), 1893456000, 1)
        );
        vm.expectRevert(); // ContestModule__InvalidStatus
        forwarder.route(
            address(receiver),
            metadata,
            _verifyReport(address(receiver), contestId, uint8(LeagueId.NBA), 1893456000, 2)
        );
    }

    // ──────────────────────────── Market-update path ──────────────────

    function test_onReport_validMarket_writesMarketsAndStaysVerified() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        uint64 nonce = receiver.requestMarketUpdate(contestId); // nonce 1

        int32 spreadTicks = -15; // -1.5
        int32 totalTicks = 85; // 8.5
        bytes memory report = _marketReport(
            address(receiver), contestId, nonce, 250, 159, spreadTicks, 191, 191, totalTicks, 195, 187, 1
        );

        vm.expectEmit(true, true, false, true, address(receiver));
        emit CreReportProcessed(keccak256(report), 1, contestId);
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);

        ContestMarket memory ml = contestModule.getContestMarket(contestId, address(0xA9));
        ContestMarket memory sp = contestModule.getContestMarket(contestId, address(0xAA));
        ContestMarket memory tot = contestModule.getContestMarket(contestId, address(0xAB));
        assertEq(ml.lineTicks, int32(0));
        assertEq(ml.upperOdds, uint16(250));
        assertEq(ml.lowerOdds, uint16(159));
        assertEq(sp.lineTicks, spreadTicks);
        assertEq(sp.upperOdds, uint16(191));
        assertEq(tot.lineTicks, totalTicks);
        assertEq(tot.upperOdds, uint16(195));
        assertEq(tot.lowerOdds, uint16(187));

        // Market update does not change status.
        assertEq(uint8(contestModule.getContest(contestId).contestStatus), uint8(ContestStatus.Verified));
    }

    /// @dev The crux of the stale-overwrite guard under lastApplied semantics: once a newer report has
    ///      applied, an out-of-order OLDER report (nonce <= lastApplied) is rejected, so stale odds can
    ///      never overwrite fresh ones.
    function test_onReport_marketRejectsStaleNonce() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        receiver.requestMarketUpdate(contestId); // nonce 1
        uint64 latest = receiver.requestMarketUpdate(contestId); // nonce 2
        assertEq(latest, 2);

        // Apply the newer report (nonce 2) first → lastApplied = 2.
        bytes memory fresh = _marketReport(address(receiver), contestId, latest, 250, 159, -15, 191, 191, 85, 195, 187, 1);
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), fresh);
        assertEq(contestModule.getContestMarket(contestId, address(0xAA)).lineTicks, int32(-15));

        // Now an out-of-order older report (nonce 1 <= lastApplied 2) is rejected as stale and cannot
        // overwrite the fresher odds.
        bytes memory stale = _marketReport(address(receiver), contestId, 1, 100, 100, 20, 100, 100, 90, 100, 100, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__StaleMarketReport.selector,
                contestId,
                uint64(1),
                uint64(2)
            )
        );
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), stale);
        assertEq(contestModule.getContestMarket(contestId, address(0xAA)).lineTicks, int32(-15));
    }

    function test_onReport_marketRevertsOnZeroOdds() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        uint64 nonce = receiver.requestMarketUpdate(contestId);
        // overOdds = 0 — ContestModule rejects (defense-in-depth; the workflow also fails earlier).
        bytes memory report = _marketReport(address(receiver), contestId, nonce, 250, 159, -15, 191, 191, 85, 0, 187, 1);
        vm.expectRevert(); // ContestModule__InvalidMarketData
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    function test_onReport_marketRevertsOnUnverifiedContest() public {
        uint256 contestId = _create(receiver); // Unverified; market nonce stays 0
        bytes memory report = _marketReport(address(receiver), contestId, 0, 250, 159, -15, 191, 191, 85, 195, 187, 1);
        vm.expectRevert(); // ContestModule__ContestNotVerified
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    // ──────────────────────────── Score path ──────────────────────────

    function test_onReport_validScore_setsScoresAndScored() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        receiver.requestScore(contestId); // bind the score request (fee 0 in this deploy)
        bytes memory report = _scoreReport(address(receiver), contestId, 5, 3, 1);

        vm.expectEmit(true, true, false, true, address(receiver));
        emit CreReportProcessed(keccak256(report), 2, contestId);
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);

        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint8(c.contestStatus), uint8(ContestStatus.Scored));
        assertEq(c.awayScore, uint32(5));
        assertEq(c.homeScore, uint32(3));
    }

    function test_onReport_scoreRevertsOnUnverifiedContest() public {
        uint256 contestId = _create(receiver); // Unverified
        bytes memory report = _scoreReport(address(receiver), contestId, 5, 3, 1);
        vm.expectRevert(); // ContestModule__AlreadyScored (status != Verified)
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    function test_onReport_secondScoreReverts() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        receiver.requestScore(contestId);
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), _scoreReport(address(receiver), contestId, 5, 3, 1));
        vm.expectRevert(); // already Scored
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), _scoreReport(address(receiver), contestId, 9, 9, 2));
    }

    // ──────────────────────────── Request emitters (market/score) ─────

    function test_requestMarketUpdate_emitsAndBumpsNonce() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        vm.expectEmit(true, true, false, true, address(receiver));
        emit CreOracleRequested(contestId, 1, 1, "rundown-abc", "sportspage-def", "jsonodds-ghi");
        uint64 n = receiver.requestMarketUpdate(contestId);
        assertEq(n, 1);
        assertEq(receiver.s_marketNonce(contestId), 1);
    }

    function test_requestScore_emitsForStartedVerifiedContest() public {
        uint256 contestId = _createAndVerify(receiver, forwarder); // start time = 1 (already started)
        vm.expectEmit(true, true, false, true, address(receiver));
        emit CreOracleRequested(contestId, 2, 0, "rundown-abc", "sportspage-def", "jsonodds-ghi");
        receiver.requestScore(contestId);
    }

    function test_requestMarketUpdate_revertsOnUnverifiedContest() public {
        uint256 contestId = _create(receiver); // Unverified
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__ContestNotVerified.selector,
                contestId
            )
        );
        receiver.requestMarketUpdate(contestId);
    }

    function test_requestScore_revertsOnUnverifiedContest() public {
        uint256 contestId = _create(receiver); // Unverified
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__ContestNotVerified.selector,
                contestId
            )
        );
        receiver.requestScore(contestId);
    }

    /// @dev The pre-start guard: a score request for a game that has not started is rejected, so we
    ///      never emit a known-premature (workflow-owner-funded) score request.
    function test_requestScore_revertsWhenPremature() public {
        uint256 contestId = _create(receiver);
        uint32 future = uint32(block.timestamp + 1000);
        forwarder.route(
            address(receiver),
            _metadata(WF_ID, WF_NAME, wfOwner),
            _verifyReport(address(receiver), contestId, uint8(LeagueId.MLB), future, 1)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__PrematureScoreRequest.selector,
                contestId,
                future,
                block.timestamp
            )
        );
        receiver.requestScore(contestId);

        // After the start time, the request is allowed.
        vm.warp(future);
        receiver.requestScore(contestId);
    }

    // ──────────────────────────── Request/report binding (fail-closed) ─

    /// @dev A verify report for a contest that was never created/requested (an uncreated id, and
    ///      contest 0) is rejected — no ghost Verified contest can be minted.
    function test_onReport_verifyRevertsWhenNotRequested() public {
        bytes memory meta = _metadata(WF_ID, WF_NAME, wfOwner);

        uint256 uncreated = 999;
        vm.expectRevert(
            abi.encodeWithSelector(CreOracleReceiver.CreOracleReceiver__VerifyNotRequested.selector, uncreated)
        );
        forwarder.route(address(receiver), meta, _verifyReport(address(receiver), uncreated, uint8(LeagueId.MLB), 1, 1));

        vm.expectRevert(
            abi.encodeWithSelector(CreOracleReceiver.CreOracleReceiver__VerifyNotRequested.selector, uint256(0))
        );
        forwarder.route(address(receiver), meta, _verifyReport(address(receiver), 0, uint8(LeagueId.MLB), 1, 1));
    }

    /// @dev A score report with no prior {requestScore} is rejected even for a Verified, started contest.
    function test_onReport_scoreRevertsWhenNotRequested() public {
        uint256 contestId = _createAndVerify(receiver, forwarder); // Verified + started, but NO requestScore
        bytes memory meta = _metadata(WF_ID, WF_NAME, wfOwner);

        vm.expectRevert(
            abi.encodeWithSelector(CreOracleReceiver.CreOracleReceiver__ScoreNotRequested.selector, contestId)
        );
        forwarder.route(address(receiver), meta, _scoreReport(address(receiver), contestId, 5, 3, 1));

        // After a real request it applies.
        receiver.requestScore(contestId);
        forwarder.route(address(receiver), meta, _scoreReport(address(receiver), contestId, 5, 3, 1));
        assertEq(uint8(contestModule.getContest(contestId).contestStatus), uint8(ContestStatus.Scored));
    }

    /// @dev A market report carrying nonce 0 (no {requestMarketUpdate} ever made) is rejected — the
    ///      nonce-0 default can never be mistaken for a real request.
    function test_onReport_marketRevertsOnNonceZeroWhenUnrequested() public {
        uint256 contestId = _createAndVerify(receiver, forwarder); // s_marketNonce stays 0
        bytes memory report = _marketReport(address(receiver), contestId, 0, 250, 159, -15, 191, 191, 85, 195, 187, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__UnrequestedMarketReport.selector, contestId, uint64(0), uint64(0)
            )
        );
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    /// @dev A market report whose nonce exceeds the latest requested nonce is rejected (no such request).
    function test_onReport_marketRevertsOnNonceAboveRequested() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        receiver.requestMarketUpdate(contestId); // nonce 1 (latest requested = 1)
        bytes memory report = _marketReport(address(receiver), contestId, 2, 250, 159, -15, 191, 191, 85, 195, 187, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreOracleReceiver.CreOracleReceiver__UnrequestedMarketReport.selector, contestId, uint64(2), uint64(1)
            )
        );
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), report);
    }

    /// @dev The liveness fix: permissionless request spam (bumping the nonce) does NOT invalidate an
    ///      in-flight legitimate report. A report for an earlier-but-unapplied nonce still applies,
    ///      because the guard compares to the last APPLIED nonce, not the latest REQUESTED.
    function test_onReport_marketInFlightReportSurvivesRequestSpam() public {
        uint256 contestId = _createAndVerify(receiver, forwarder);
        receiver.requestMarketUpdate(contestId); // nonce 1 — the legit in-flight request
        receiver.requestMarketUpdate(contestId); // nonce 2 — spam
        receiver.requestMarketUpdate(contestId); // nonce 3 — spam (latest requested = 3, applied = 0)

        // The report answering the nonce-1 request STILL applies despite the spam up to 3.
        bytes memory r1 = _marketReport(address(receiver), contestId, 1, 250, 159, -15, 191, 191, 85, 195, 187, 1);
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), r1);
        assertEq(contestModule.getContestMarket(contestId, address(0xAA)).lineTicks, int32(-15));
        assertEq(receiver.s_lastAppliedMarketNonce(contestId), uint64(1));

        // A later nonce-3 report also applies (monotonic; freshest wins).
        bytes memory r3 = _marketReport(address(receiver), contestId, 3, 250, 159, -25, 191, 191, 95, 195, 187, 1);
        forwarder.route(address(receiver), _metadata(WF_ID, WF_NAME, wfOwner), r3);
        assertEq(contestModule.getContestMarket(contestId, address(0xAA)).lineTicks, int32(-25));
        assertEq(receiver.s_lastAppliedMarketNonce(contestId), uint64(3));
    }

    // ──────────────────────────── ERC165 ──────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertFalse(receiver.supportsInterface(0xffffffff));
    }
}
