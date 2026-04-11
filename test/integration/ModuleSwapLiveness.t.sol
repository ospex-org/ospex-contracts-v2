// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ModuleSwapLiveness
/// @notice Integration tests proving claim liveness across module swaps.
///
/// Context: OspexCore allows the admin to replace (swap) any module. When a module
/// is replaced, the old instance is marked as "retired" — it can still emit core
/// events but cannot process fees. The risk is that PositionModule.claimPosition()
/// uses a runtime lookup (_getModule) to fetch the CURRENT SpeculationModule. If
/// SpeculationModule is swapped independently, the new instance has empty storage
/// and claims break.
///
/// These tests validate:
///   1. Claim survives a PositionModule-only swap (safe path)
///   2. Solo SpeculationModule swap breaks claims (documents the risk)
///   3. Coordinated settle-before-swap-position is the correct upgrade path
///   4. Full lifecycle: position → score → swap position → settle → claim

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {
    PositionType, Contest, ContestStatus, Position, WinSide,
    LeagueId, Speculation, SpeculationStatus, Leaderboard
} from "../../src/core/OspexTypes.sol";

// Minimal mock for LeaderboardModule (same pattern as PositionModule.t.sol)
contract MockLeaderboardModule {
    mapping(uint256 => Leaderboard) private leaderboards;
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedRisk;
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedProfit;

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

contract ModuleSwapLivenessTest is Test {
    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;
    MockContestModule mockContestModule;
    MockLeaderboardModule mockLeaderboardModule;
    MockScorerModule mockScorer;

    address maker = address(0xBEEF);
    address taker = address(0xCAFE);
    address protocolReceiver = address(0xFEED);

    uint256 constant MAKER_RISK = 10_000_000; // 10 USDC
    uint256 constant TAKER_RISK = 8_000_000;  // 8 USDC (1.80 odds equivalent)

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        // Fund participants
        token.transfer(maker, 1_000_000_000);
        token.transfer(taker, 1_000_000_000);

        // Deploy modules
        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(address(core), address(token));
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);
        mockContestModule = new MockContestModule();
        mockLeaderboardModule = new MockLeaderboardModule();
        mockScorer = new MockScorerModule();

        // Register all modules
        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), address(contributionModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));
        core.registerModule(keccak256("MATCHING_MODULE"), address(this));
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), address(0xCC01));
        core.registerModule(keccak256("TOTAL_SCORER_MODULE"), address(0xCC02));

        // Grant scorer role
        core.setScorerRole(address(mockScorer), true);

        // Set up a verified contest
        mockContestModule.setContest(1, _verifiedContest());
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _verifiedContest() internal view returns (Contest memory) {
        return Contest({
            awayScore: 0, homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
    }

    function _scoredContest(uint32 away, uint32 home) internal view returns (Contest memory) {
        return Contest({
            awayScore: away, homeScore: home,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
    }

    /// @notice Create a matched position pair. Returns the speculation ID.
    function _createPosition() internal returns (uint256 specId) {
        vm.prank(maker);
        token.approve(address(positionModule), MAKER_RISK);
        vm.prank(taker);
        token.approve(address(positionModule), TAKER_RISK);

        specId = positionModule.recordFill(
            1,                      // contestId
            address(mockScorer),    // scorer
            0,                      // lineTicks (moneyline)
            0,                      // leaderboardId
            PositionType.Upper,     // maker is Upper (away)
            maker,
            MAKER_RISK,
            taker,
            TAKER_RISK,
            0, 0                    // contributions
        );
    }

    /// @notice Score the contest and settle the speculation.
    function _scoreAndSettle(uint256 specId) internal {
        // Warp past start time so settlement is allowed
        mockContestModule.setContestStartTime(1, uint32(block.timestamp));
        vm.warp(block.timestamp + 2 hours);

        // Score: Away wins → Upper (maker) wins
        mockContestModule.setContest(1, _scoredContest(100, 90));

        // Settle
        speculationModule.settleSpeculation(specId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1: Claim survives PositionModule swap
    //
    // Scenario: Admin deploys a new PositionModule and registers it.
    // The old PositionModule is retired but still holds user funds.
    // User calls claimPosition on the OLD module. This should succeed because:
    //   - Funds are in the old module's token balance
    //   - SpeculationModule is unchanged (still registered, still has data)
    //   - Retired modules can still call emitCoreEvent
    //   - getModule() is a view call with no access control
    // ═════════════════════════════════════════════════════════════════════════

    function testClaimSurvivesPositionModuleSwap() public {
        // 1. Create position on original PositionModule
        uint256 specId = _createPosition();

        // 2. Score and settle (speculation is Closed, winSide set)
        _scoreAndSettle(specId);

        // 3. Deploy and register a NEW PositionModule (retires the old one)
        PositionModule newPositionModule = new PositionModule(address(core), address(token));
        core.registerModule(keccak256("POSITION_MODULE"), address(newPositionModule));

        // Verify old module is retired
        assertTrue(core.s_isRetiredModule(address(positionModule)), "Old PM should be retired");
        assertFalse(core.isRegisteredModule(address(positionModule)), "Old PM should not be registered");

        // 4. Claim on the OLD PositionModule — should succeed
        uint256 balBefore = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(maker);

        // Winner gets risk + profit = 10M + 8M = 18M
        assertEq(balAfter - balBefore, 18_000_000, "Maker should receive full payout from old PM");

        // Verify position is marked claimed
        Position memory pos = positionModule.getPosition(specId, maker, PositionType.Upper);
        assertTrue(pos.claimed, "Position should be marked claimed");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2: Solo SpeculationModule swap breaks claims
    //
    // Scenario: Admin swaps ONLY SpeculationModule (without coordinating
    // with PositionModule). This is the dangerous independent swap case.
    // claimPosition() queries the NEW SpeculationModule for speculation data,
    // but the new module has empty storage. The claim should fail.
    //
    // This test DOCUMENTS THE RISK — it proves why the "no solo swap" policy
    // for SPECULATION_MODULE is necessary when positions have unclaimed funds.
    // ═════════════════════════════════════════════════════════════════════════

    function testClaimFailsAfterSoloSpeculationModuleSwap() public {
        // 1. Create position and settle
        uint256 specId = _createPosition();
        _scoreAndSettle(specId);

        // 2. Swap ONLY SpeculationModule (this is the dangerous operation)
        SpeculationModule newSpeculationModule = new SpeculationModule(address(core), 6);
        core.registerModule(keccak256("SPECULATION_MODULE"), address(newSpeculationModule));

        // 3. Attempt claim — should revert because new module has no speculation data.
        //    The new module returns a default Speculation with status = Open (not Closed),
        //    so PositionModule reverts with NotSettled.
        vm.prank(maker);
        vm.expectRevert(PositionModule.PositionModule__NotSettled.selector);
        positionModule.claimPosition(specId, PositionType.Upper);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3: Safe upgrade path — settle all, then swap PositionModule only
    //
    // Scenario: The admin follows the correct procedure:
    //   1. Ensure all speculations are settled
    //   2. Allow users to claim (or wait for claims)
    //   3. Only then swap PositionModule
    // This proves claims work at any point after settlement, even post-swap.
    // ═════════════════════════════════════════════════════════════════════════

    function testSafeUpgradePath_SettleAllThenSwapPosition() public {
        // 1. Create TWO positions (different speculations)
        uint256 specId1 = _createPosition();

        // Create a second position on a different line
        vm.prank(maker);
        token.approve(address(positionModule), MAKER_RISK);
        vm.prank(taker);
        token.approve(address(positionModule), TAKER_RISK);
        uint256 specId2 = positionModule.recordFill(
            1, address(mockScorer), 42, 0, // different lineTicks
            PositionType.Upper, maker, MAKER_RISK, taker, TAKER_RISK, 0, 0
        );

        // 2. Score and settle BOTH speculations
        _scoreAndSettle(specId1);
        speculationModule.settleSpeculation(specId2);

        // 3. Maker claims spec1 BEFORE swap
        vm.prank(maker);
        positionModule.claimPosition(specId1, PositionType.Upper);

        // 4. Swap PositionModule
        PositionModule newPM = new PositionModule(address(core), address(token));
        core.registerModule(keccak256("POSITION_MODULE"), address(newPM));

        // 5. Maker claims spec2 AFTER swap — still works on old module
        uint256 balBefore = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(specId2, PositionType.Upper);
        uint256 balAfter = token.balanceOf(maker);

        assertEq(balAfter - balBefore, 18_000_000, "Claim on old PM after swap should still pay out");

        // 6. Taker (loser) claims should revert with NoPayout on both
        vm.prank(taker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        positionModule.claimPosition(specId1, PositionType.Lower);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 4: Full lifecycle — position → score → swap PM → settle → claim
    //
    // This is the exact scenario OC requested:
    //   "create old position → swap module(s) → settle → claim still works"
    //
    // The key insight: swapping PositionModule BEFORE settlement is safe as
    // long as SpeculationModule remains registered. The old PositionModule
    // can still query the current SpeculationModule for settlement state.
    // ═════════════════════════════════════════════════════════════════════════

    function testFullLifecycle_CreateSwapSettleClaim() public {
        // 1. Create position on original PositionModule
        uint256 specId = _createPosition();

        // 2. Swap PositionModule BEFORE settlement
        PositionModule newPM = new PositionModule(address(core), address(token));
        core.registerModule(keccak256("POSITION_MODULE"), address(newPM));

        // Verify old is retired
        assertTrue(core.s_isRetiredModule(address(positionModule)));

        // 3. Score and settle AFTER swap
        //    Settlement is permissionless — anyone can call it on SpeculationModule
        //    SpeculationModule was NOT swapped, so it still has the speculation data
        _scoreAndSettle(specId);

        // 4. Verify speculation is settled
        Speculation memory spec = speculationModule.getSpeculation(specId);
        assertEq(uint(spec.speculationStatus), uint(SpeculationStatus.Closed));
        assertEq(uint(spec.winSide), uint(WinSide.Away)); // Upper wins

        // 5. Claim on OLD PositionModule — should succeed
        uint256 makerBalBefore = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(specId, PositionType.Upper);
        uint256 makerBalAfter = token.balanceOf(maker);

        assertEq(makerBalAfter - makerBalBefore, 18_000_000, "Winner should receive payout");

        // 6. Loser claim should revert
        vm.prank(taker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        positionModule.claimPosition(specId, PositionType.Lower);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 5: Retired PositionModule emitCoreEvent works
    //
    // Validates that claim events from a retired module are properly emitted,
    // ensuring off-chain indexers (Supabase) capture claims from old modules.
    // ═════════════════════════════════════════════════════════════════════════

    function testRetiredModuleEmitsCoreEventOnClaim() public {
        uint256 specId = _createPosition();
        _scoreAndSettle(specId);

        // Swap PositionModule
        PositionModule newPM = new PositionModule(address(core), address(token));
        core.registerModule(keccak256("POSITION_MODULE"), address(newPM));

        // Expect the CoreEventEmitted event from the RETIRED module
        // The emitter field should be the OLD PositionModule address
        vm.expectEmit(true, true, false, false, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("POSITION_CLAIMED"),
            address(positionModule), // old module as emitter
            ""  // don't check data
        );

        vm.prank(maker);
        positionModule.claimPosition(specId, PositionType.Upper);
    }
}
