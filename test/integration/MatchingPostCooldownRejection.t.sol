// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] This test uses the real MatchingModule and real SpeculationModule to verify
//        the post-cooldown matching rejection. MockContestModule controls contest state.
//        A minimal mock PositionModule handles recordFill for successful matches.

import "forge-std/Test.sol";
import {MatchingModule} from "../../src/modules/MatchingModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {
    PositionType,
    Contest,
    ContestStatus,
    LeagueId,
    WinSide
} from "../../src/core/OspexTypes.sol";

/// @dev Minimal mock that implements recordFill for successful matches
contract MockPositionModuleForCooldown {
    uint256 public returnSpeculationId = 1;

    function recordFill(
        uint256, address, int32, PositionType,
        address, uint256, address, uint256
    ) external returns (uint256) {
        return returnSpeculationId;
    }

    function getModuleType() external pure returns (bytes32) {
        return keccak256("POSITION_MODULE");
    }
}

/**
 * @title MatchingPostCooldownRejectionTest
 * @notice Integration tests verifying that matchCommitment rejects fills when
 *         the contest has elapsed its void cooldown, even if settleSpeculation
 *         has not yet been called.
 *
 * Timeline:
 *   T+0:   Deploy. Contest starts at T+0. voidCooldown = 3 days.
 *   T+3d:  Cooldown boundary (exact). isContestPastCooldown returns true.
 *   T+3d+1: Past cooldown. Fills should be rejected.
 */
contract MatchingPostCooldownRejectionTest is Test {
    OspexCore core;
    MatchingModule matchingModule;
    SpeculationModule speculationModule;
    MockContestModule mockContestModule;
    MockScorerModule mockScorerModule;
    MockPositionModuleForCooldown mockPositionModule;

    uint256 constant MAKER_PK = 0xA11CE;
    address maker;
    address taker = address(0xBBBB);
    address defaultScorer = address(0xDDDD);

    uint256 constant CONTEST_ID = 1;
    uint256 constant RISK_AMOUNT = 100_000_000; // 100 USDC
    uint256 constant TAKER_DESIRED_RISK = 10_000_000; // 10 USDC
    uint16 constant ODDS_TICK = 191; // 1.91
    uint32 constant VOID_COOLDOWN = 3 days;

    uint32 contestStartTime;

    function setUp() public {
        maker = vm.addr(MAKER_PK);

        core = new OspexCore();
        matchingModule = new MatchingModule(address(core));
        speculationModule = new SpeculationModule(address(core), VOID_COOLDOWN);
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();
        mockPositionModule = new MockPositionModuleForCooldown();

        // Bootstrap all 12 modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();         addrs[0]  = address(mockContestModule);
        types[1]  = core.SPECULATION_MODULE();      addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();         addrs[2]  = address(mockPositionModule);
        types[3]  = core.MATCHING_MODULE();         addrs[3]  = address(matchingModule);
        types[4]  = core.ORACLE_MODULE();           addrs[4]  = address(0xFEED);
        types[5]  = core.TREASURY_MODULE();         addrs[5]  = address(0xFE05);
        types[6]  = core.LEADERBOARD_MODULE();      addrs[6]  = address(0x1B05);
        types[7]  = core.RULES_MODULE();            addrs[7]  = address(0xD007);
        types[8]  = core.SECONDARY_MARKET_MODULE(); addrs[8]  = address(0x5EC0);
        types[9]  = core.MONEYLINE_SCORER_MODULE(); addrs[9]  = address(mockScorerModule);
        types[10] = core.SPREAD_SCORER_MODULE();    addrs[10] = address(0x5901);
        types[11] = core.TOTAL_SCORER_MODULE();     addrs[11] = address(0x7701);
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Contest: Verified, starts now
        contestStartTime = uint32(block.timestamp);
        Contest memory contest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "test", sportspageId: "test", jsonoddsId: "test"
        });
        mockContestModule.setContest(CONTEST_ID, contest);
        mockContestModule.setContestStartTime(CONTEST_ID, contestStartTime);
    }

    // =========================================================================
    // Test 1: Match during normal window succeeds
    // =========================================================================

    function test_MatchDuringNormalWindowSucceeds() public {
        // We're at T+0, cooldown ends at T+3d. Normal window.
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedCommitment();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, TAKER_DESIRED_RISK);

        // Verify fill was recorded
        assertGt(matchingModule.s_filledRisk(matchingModule.getCommitmentHash(c)), 0, "Fill should be recorded");
    }

    // =========================================================================
    // Test 2: Match immediately after cooldown elapsed reverts
    // =========================================================================

    function test_MatchImmediatelyAfterCooldownElapsedReverts() public {
        // Warp past cooldown. Contest is still Verified (not terminal).
        vm.warp(uint256(contestStartTime) + uint256(VOID_COOLDOWN) + 1);

        // Verify precondition: contest is NOT terminal
        assertFalse(
            mockContestModule.isContestTerminal(CONTEST_ID),
            "Contest should NOT be terminal yet"
        );

        // Verify precondition: cooldown IS elapsed
        assertTrue(
            speculationModule.isContestPastCooldown(CONTEST_ID),
            "Contest should be past cooldown"
        );

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedCommitment();

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__ContestPastCooldown.selector);
        matchingModule.matchCommitment(c, sig, TAKER_DESIRED_RISK);
    }

    // =========================================================================
    // Test 3: Match after void settlement reverts with existing terminal error
    // =========================================================================

    function test_MatchAfterVoidSettlementReverts() public {
        // Set contest to Voided directly (simulates post-settlement state)
        Contest memory voided = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Voided, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "test", sportspageId: "test", jsonoddsId: "test"
        });
        mockContestModule.setContest(CONTEST_ID, voided);

        // Also warp past cooldown so both checks would fire — terminal should win
        vm.warp(uint256(contestStartTime) + uint256(VOID_COOLDOWN) + 1);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedCommitment();

        // Should revert with ContestAlreadyScored (the terminal check), NOT ContestPastCooldown
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__ContestAlreadyScored.selector);
        matchingModule.matchCommitment(c, sig, TAKER_DESIRED_RISK);
    }

    // =========================================================================
    // Test 4: Match at exact cooldown boundary reverts (>= boundary)
    // =========================================================================

    function test_MatchAtCooldownBoundary() public {
        // Warp to EXACTLY contestStartTime + voidCooldown
        vm.warp(uint256(contestStartTime) + uint256(VOID_COOLDOWN));

        // Contest is NOT terminal
        assertFalse(mockContestModule.isContestTerminal(CONTEST_ID));

        // But IS past cooldown (>= boundary)
        assertTrue(speculationModule.isContestPastCooldown(CONTEST_ID));

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedCommitment();

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__ContestPastCooldown.selector);
        matchingModule.matchCommitment(c, sig, TAKER_DESIRED_RISK);
    }

    // =========================================================================
    // Test 5: Match on scored contest reverts with existing terminal error
    // =========================================================================

    function test_MatchScoredContestReverts() public {
        // Score the contest (not void — properly scored)
        Contest memory scored = Contest({
            awayScore: 110, homeScore: 100, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "test", sportspageId: "test", jsonoddsId: "test"
        });
        mockContestModule.setContest(CONTEST_ID, scored);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedCommitment();

        // Should revert with ContestAlreadyScored (terminal check fires first)
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__ContestAlreadyScored.selector);
        matchingModule.matchCommitment(c, sig, TAKER_DESIRED_RISK);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _signedCommitment()
        internal
        view
        returns (MatchingModule.OspexCommitment memory c, bytes memory sig)
    {
        c = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: CONTEST_ID,
            scorer: defaultScorer,
            lineTicks: int32(0),
            positionType: PositionType.Upper,
            oddsTick: ODDS_TICK,
            riskAmount: RISK_AMOUNT,
            nonce: 1,
            expiry: block.timestamp + 30 days
        });
        bytes32 digest = matchingModule.getCommitmentHash(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
