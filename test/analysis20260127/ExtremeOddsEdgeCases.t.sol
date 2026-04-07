// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] oddsTick uses integer ticks: 1.01 = 101, 101.00 = 10100
// [NOTE] Tests use planned deployment bounds: min=1 USDC, no maximum

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {
    PositionType,
    Contest,
    ContestStatus,
    Position,
    WinSide,
    LeagueId,
    Leaderboard
} from "../../src/core/OspexTypes.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

contract MockLeaderboardModuleExtreme {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

/// @title Extreme Odds Edge Case Tests
/// @notice Verifies riskAmountInRange modifier, fill math, and solvency at oddsTick boundaries
/// @dev Uses min=1 USDC (no maximum) to match planned deployment parameters
contract ExtremeOddsEdgeCases is Test {
    uint16 constant ODDS_SCALE = 100;
    uint16 constant MIN_ODDS = 101;
    uint16 constant MAX_ODDS = 10100;

    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;
    MockContestModule mockContestModule;
    MockLeaderboardModuleExtreme mockLeaderboardModule;
    MockScorerModule mockScorer;

    address maker = address(0xBEEF);
    address taker = address(0xCAFE);
    address protocolReceiver = address(0xFEED);

    int32 nextLineTicks = 1;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        // Fund with large amounts to cover extreme odds (maker can need 300+ USDC at 1.01)
        token.mint(maker, 1_000_000_000_000);
        token.mint(taker, 1_000_000_000_000);

        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(address(core), address(token));
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);
        mockContestModule = new MockContestModule();
        mockLeaderboardModule = new MockLeaderboardModuleExtreme();
        mockScorer = new MockScorerModule();

        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), address(contributionModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));

        // Register this test contract as MATCHING_MODULE so it can call recordFill
        core.registerModule(keccak256("MATCHING_MODULE"), address(this));

        // Register scorer modules so _getModule lookups don't revert
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), address(0xCC01));
        core.registerModule(keccak256("TOTAL_SCORER_MODULE"), address(0xCC02));

        core.setScorerRole(address(mockScorer), true);

        // Set up a verified contest
        _resetContest();

        vm.prank(maker);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(taker);
        token.approve(address(positionModule), type(uint256).max);
    }

    // ===================== HELPERS =====================

    /// @notice Replicate MatchingModule.matchCommitment fill math
    function _computeFill(uint16 oddsTick, uint256 takerDesiredRisk)
        internal pure returns (uint256 fillMakerRisk, uint256 takerRisk)
    {
        uint256 profitTicks = uint256(oddsTick) - ODDS_SCALE;
        uint256 rawFillMakerRisk = (takerDesiredRisk * uint256(ODDS_SCALE) + profitTicks - 1) / profitTicks;
        fillMakerRisk = rawFillMakerRisk - (rawFillMakerRisk % ODDS_SCALE);
        takerRisk = (fillMakerRisk * profitTicks) / ODDS_SCALE;
    }

    function _recordFill(uint256 makerRisk, uint256 takerRisk)
        internal returns (uint256 speculationId, int32 lineTicks)
    {
        lineTicks = nextLineTicks++;
        speculationId = positionModule.recordFill(
            1, address(mockScorer), lineTicks, 0,
            PositionType.Upper, maker, makerRisk, taker, takerRisk, 0, 0
        );
    }

    function _settleAndClaimWinner(uint256 speculationId, int32 lineTicks, uint256 expectedPayout) internal {
        Contest memory scored = Contest({
            awayScore: 10, homeScore: 5, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, scored);
        mockScorer.setWinSide(1, lineTicks, WinSide.Away);

        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);

        uint256 balBefore = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(speculationId, PositionType.Upper);
        assertEq(token.balanceOf(maker) - balBefore, expectedPayout, "Winner payout != total deposited");

        vm.prank(taker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        positionModule.claimPosition(speculationId, PositionType.Lower);

        _resetContest();
    }

    function _settleAndClaimPush(
        uint256 speculationId, int32 lineTicks, uint256 makerRisk, uint256 takerRisk
    ) internal {
        Contest memory scored = Contest({
            awayScore: 10, homeScore: 10, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, scored);
        mockScorer.setWinSide(1, lineTicks, WinSide.Push);

        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);

        uint256 makerBal = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(speculationId, PositionType.Upper);
        assertEq(token.balanceOf(maker) - makerBal, makerRisk, "Maker push refund wrong");

        uint256 takerBal = token.balanceOf(taker);
        vm.prank(taker);
        positionModule.claimPosition(speculationId, PositionType.Lower);
        assertEq(token.balanceOf(taker) - takerBal, takerRisk, "Taker push refund wrong");

        _resetContest();
    }

    function _resetContest() internal {
        Contest memory contest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
    }

    // =========================================================================
    // 1. EXTREME LOW ODDS (1.01) — Maker is heavy favorite
    //    Maker risks 100x taker. Taker gets a longshot payout.
    // =========================================================================

    /// @notice 1.01 odds, taker risks 1 USDC → maker risks 100 USDC. Winner gets 101 USDC.
    function test_Odds101_MinTakerRisk_Solvency() public {
        (uint256 makerRisk, uint256 takerRisk) = _computeFill(101, 1_000_000);

        assertEq(makerRisk, 100_000_000, "Maker should risk 100 USDC");
        assertEq(takerRisk, 1_000_000, "Taker should risk 1 USDC");

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);

        Position memory makerPos = positionModule.getPosition(specId, maker, PositionType.Upper);
        assertEq(makerPos.riskAmount, 100_000_000);
        assertEq(makerPos.profitAmount, 1_000_000, "Maker profit = taker risk");

        Position memory takerPos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(takerPos.riskAmount, 1_000_000);
        assertEq(takerPos.profitAmount, 100_000_000, "Taker profit = maker risk");

        _settleAndClaimWinner(specId, theNum, 101_000_000);
    }

    /// @notice 1.01 odds, taker risks 3 USDC → maker risks 300 USDC. Push returns both.
    function test_Odds101_MaxTakerRisk_PushSolvency() public {
        (uint256 makerRisk, uint256 takerRisk) = _computeFill(101, 3_000_000);

        assertEq(makerRisk, 300_000_000, "Maker should risk 300 USDC");
        assertEq(takerRisk, 3_000_000, "Taker should risk 3 USDC");

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);
        _settleAndClaimPush(specId, theNum, makerRisk, takerRisk);
    }

    // =========================================================================
    // 2. EXTREME HIGH ODDS (101.00) — Taker is heavy favorite
    //    Maker risks almost nothing. Taker's profit is tiny.
    // =========================================================================

    /// @notice 101.00 odds, taker risks 1 USDC → maker risks 0.01 USDC. Winner gets 1.01 USDC.
    function test_Odds10100_MinTakerRisk_Solvency() public {
        (uint256 makerRisk, uint256 takerRisk) = _computeFill(10100, 1_000_000);

        assertEq(makerRisk, 10_000, "Maker should risk 0.01 USDC");
        assertEq(takerRisk, 1_000_000, "Taker should risk 1 USDC");

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);

        Position memory makerPos = positionModule.getPosition(specId, maker, PositionType.Upper);
        assertEq(makerPos.riskAmount, 10_000);
        assertEq(makerPos.profitAmount, 1_000_000, "Maker profit = taker risk");

        Position memory takerPos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(takerPos.riskAmount, 1_000_000);
        assertEq(takerPos.profitAmount, 10_000, "Taker profit = maker risk");

        _settleAndClaimWinner(specId, theNum, 1_010_000);
    }

    /// @notice 101.00 odds, taker risks 3 USDC → maker risks 0.03 USDC. Push returns both.
    function test_Odds10100_MaxTakerRisk_PushSolvency() public {
        (uint256 makerRisk, uint256 takerRisk) = _computeFill(10100, 3_000_000);

        assertEq(makerRisk, 30_000, "Maker should risk 0.03 USDC");
        assertEq(takerRisk, 3_000_000, "Taker should risk 3 USDC");

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);
        _settleAndClaimPush(specId, theNum, makerRisk, takerRisk);
    }

    // =========================================================================
    // 3. MODIFIER ENFORCEMENT — riskAmountInRange reverts at boundaries
    // =========================================================================

    /// @notice takerRisk below min (1 USDC) reverts
    function test_TakerRiskBelowMin_Reverts() public {
        // 0.01 USDC taker risk — well below 1 USDC min
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1, address(mockScorer), nextLineTicks++, 0,
            PositionType.Upper, maker, 100, taker, 10_000, 0, 0
        );
    }

    /// @notice At 1.01 odds, tiny maker risk → takerRisk = 0.000001 USDC → reverts
    function test_Odds101_TinyMakerRisk_Reverts() public {
        // makerRisk=100 at 1.01 → takerRisk = 100 * 1 / 100 = 1 (0.000001 USDC)
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1, address(mockScorer), nextLineTicks++, 0,
            PositionType.Upper, maker, 100, taker, 1, 0, 0
        );
    }

    /// @notice takerRisk exactly at min boundary (1 USDC) succeeds
    function test_TakerRiskExactlyAtMin_Succeeds() public {
        (uint256 specId,) = _recordFill(1_000_000, 1_000_000);
        Position memory pos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(pos.riskAmount, 1_000_000);
    }

    /// @notice takerRisk 1 below min reverts
    function test_TakerRiskOneBelow_Min_Reverts() public {
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1, address(mockScorer), nextLineTicks++, 0,
            PositionType.Upper, maker, 999_999, taker, 999_999, 0, 0
        );
    }

    // =========================================================================
    // 4. ROUNDING GAP BOUNDARY
    //    At some oddsTick values, rounding fillMakerRisk to the nearest lot (100)
    //    causes actual takerRisk to fall below takerDesiredRisk.
    // =========================================================================

    /// @notice At oddsTick=9999, rounding pushes takerRisk below 1 USDC min → revert
    function test_RoundingGap_9999_FallsBelowMin() public {
        // profitTicks = 9899
        // rawFillMakerRisk = ceil(1_000_000 * 100 / 9899) = 10103
        // fillMakerRisk = 10103 - 3 = 10100
        // takerRisk = 10100 * 9899 / 100 = 999_799 (< 1 USDC)
        (uint256 fillMakerRisk, uint256 takerRisk) = _computeFill(9999, 1_000_000);

        assertEq(fillMakerRisk, 10_100, "fillMakerRisk after lot rounding");
        assertEq(takerRisk, 999_799, "takerRisk rounds below 1 USDC min");

        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1, address(mockScorer), nextLineTicks++, 0,
            PositionType.Upper, maker, fillMakerRisk, taker, takerRisk, 0, 0
        );
    }

    /// @notice The next valid lot at oddsTick=9999 produces takerRisk ~1.0097 USDC → succeeds
    function test_RoundingGap_9999_NextValidLot() public {
        // Stepping fillMakerRisk up to 10200
        uint256 fillMakerRisk = 10_200;
        uint256 takerRisk = (fillMakerRisk * 9899) / 100;

        assertEq(takerRisk, 1_009_698, "Next valid takerRisk ~1.0097 USDC");

        (uint256 specId,) = _recordFill(fillMakerRisk, takerRisk);
        Position memory pos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(pos.riskAmount, takerRisk);
    }

    /// @notice Enumerate odds near MAX_ODDS where lot rounding causes takerRisk to fall
    ///         below 1 USDC for takerDesiredRisk = exactly 1 USDC. Documents the scope of
    ///         the rounding gap — these are NOT bugs, just cases where the taker must
    ///         over-request by a fraction of a cent to land on a valid lot.
    function test_RoundingGap_HighOdds_DeadZoneCount() public pure {
        uint256 deadZoneCount = 0;

        for (uint16 oddsTick = 9000; oddsTick <= 10100; oddsTick++) {
            uint256 profitTicks = uint256(oddsTick) - 100;
            uint256 rawFillMakerRisk = (1_000_000 * 100 + profitTicks - 1) / profitTicks;
            uint256 fillMakerRisk = rawFillMakerRisk - (rawFillMakerRisk % 100);
            uint256 takerRisk = (fillMakerRisk * profitTicks) / 100;

            if (takerRisk < 1_000_000) deadZoneCount++;
        }

        // Most high-odds ticks have the gap at exactly 1 USDC desired risk.
        // The over-request needed is at most 0.01 USDC (1 lot step at MAX_ODDS).
        // This is expected behavior — the revert is clean, not a silent failure.
        assertEq(deadZoneCount, 1089, "Known dead zone count for ticks 9000-10100");
    }

    // =========================================================================
    // 5. GRANULARITY — takerRisk step size at extreme odds
    // =========================================================================

    /// @notice At MAX_ODDS (10100), takerRisk increments by 0.01 USDC per lot step
    function test_Granularity_MaxOdds() public {
        uint256 profitTicks = 10_000;

        uint256 makerRisk_A = 10_000;
        uint256 takerRisk_A = (makerRisk_A * profitTicks) / 100;

        uint256 makerRisk_B = 10_100;
        uint256 takerRisk_B = (makerRisk_B * profitTicks) / 100;

        assertEq(takerRisk_A, 1_000_000, "First valid step: 1.00 USDC");
        assertEq(takerRisk_B, 1_010_000, "Second step: 1.01 USDC");
        assertEq(takerRisk_B - takerRisk_A, 10_000, "Step = 0.01 USDC");

        // Both are valid fills
        (uint256 specA,) = _recordFill(makerRisk_A, takerRisk_A);
        (uint256 specB,) = _recordFill(makerRisk_B, takerRisk_B);
        assertGt(specA, 0);
        assertGt(specB, 0);
    }

    /// @notice At MIN_ODDS (101), takerRisk increments by 0.000001 USDC — near-continuous
    function test_Granularity_MinOdds() public pure {
        uint256 profitTicks = 1;

        uint256 takerRisk_A = (100_000_000 * profitTicks) / 100;
        uint256 takerRisk_B = (100_000_100 * profitTicks) / 100;

        assertEq(takerRisk_A, 1_000_000, "First step: 1.000000 USDC");
        assertEq(takerRisk_B, 1_000_001, "Second step: 1.000001 USDC");
        assertEq(takerRisk_B - takerRisk_A, 1, "Step = 1 base unit (0.000001 USDC)");
    }

    // =========================================================================
    // 6. FUZZ — solvency invariant across extreme bands
    // =========================================================================

    /// @notice Fuzz at low odds (1.01-1.10): maker risks 10-100x taker, solvency holds
    function testFuzz_Solvency_LowOdds(uint16 oddsTick) public {
        oddsTick = uint16(bound(oddsTick, 101, 110));
        uint256 profitTicks = uint256(oddsTick) - ODDS_SCALE;

        // Compute fill for 1 USDC taker risk
        uint256 rawMakerRisk = (1_000_000 * 100 + profitTicks - 1) / profitTicks;
        uint256 makerRisk = rawMakerRisk - (rawMakerRisk % 100);
        uint256 takerRisk = (makerRisk * profitTicks) / 100;

        if (takerRisk < 1_000_000) return;

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);
        _settleAndClaimWinner(specId, theNum, makerRisk + takerRisk);
    }

    /// @notice Fuzz at high odds (90.01-101.00): maker risks almost nothing, solvency holds
    function testFuzz_Solvency_HighOdds(uint16 oddsTick) public {
        oddsTick = uint16(bound(oddsTick, 9001, 10100));
        uint256 profitTicks = uint256(oddsTick) - ODDS_SCALE;

        uint256 rawMakerRisk = (1_000_000 * 100 + profitTicks - 1) / profitTicks;
        uint256 makerRisk = rawMakerRisk - (rawMakerRisk % 100);
        uint256 takerRisk = (makerRisk * profitTicks) / 100;

        if (takerRisk < 1_000_000) return;

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);
        _settleAndClaimWinner(specId, theNum, makerRisk + takerRisk);
    }

    /// @notice Fuzz push refunds at extreme odds: both sides get exact risk back
    function testFuzz_PushRefund_ExtremeOdds(uint16 oddsTick) public {
        oddsTick = uint16(bound(oddsTick, 101, 10100));
        uint256 profitTicks = uint256(oddsTick) - ODDS_SCALE;

        uint256 rawMakerRisk = (1_000_000 * 100 + profitTicks - 1) / profitTicks;
        uint256 makerRisk = rawMakerRisk - (rawMakerRisk % 100);
        uint256 takerRisk = (makerRisk * profitTicks) / 100;

        if (takerRisk < 1_000_000) return;

        (uint256 specId, int32 theNum) = _recordFill(makerRisk, takerRisk);
        _settleAndClaimPush(specId, theNum, makerRisk, takerRisk);
    }

    // =========================================================================
    // 7. NO-MAX — large fills succeed, admin can update min, unfillable at odds
    // =========================================================================

    /// @notice Very large taker risk (1M USDC) succeeds with no max cap
    function test_LargeTakerRisk_Succeeds() public {
        uint256 largeTakerRisk = 1_000_000_000_000; // 1M USDC
        uint256 largeMakerRisk = 1_000_000_000_000; // 1M USDC (even odds)
        // Mint enough for both sides
        token.mint(maker, largeMakerRisk);
        token.mint(taker, largeTakerRisk);
        (uint256 specId,) = _recordFill(largeMakerRisk, largeTakerRisk);
        Position memory pos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(pos.riskAmount, largeTakerRisk, "1M USDC fill succeeded");
    }

    /// @notice Admin updates minRisk and the new value is enforced
    function test_AdminUpdatesMin_NewValueEnforced() public {
        // Raise min to 5 USDC
        speculationModule.setMinSpeculationAmount(5_000_000);
        assertEq(speculationModule.s_minSpeculationAmount(), 5_000_000);

        // 4 USDC taker risk now reverts
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1, address(mockScorer), nextLineTicks++, 0,
            PositionType.Upper, maker, 4_000_000, taker, 4_000_000, 0, 0
        );

        // 5 USDC taker risk succeeds
        (uint256 specId,) = _recordFill(5_000_000, 5_000_000);
        Position memory pos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(pos.riskAmount, 5_000_000, "5 USDC fill after min raised");
    }

    /// @notice 1 USDC commitment at 1.50 odds: taker risk = 0.50 USDC, below 1 USDC min → reverts
    function test_UnfillableAtLowOdds_TakerRiskBelowMin() public {
        // Maker commits 1 USDC at oddsTick=150 (1.50 odds)
        // profitTicks = 50
        // If taker wants to fill the full 1 USDC maker risk:
        //   takerRisk = 1_000_000 * 50 / 100 = 500_000 (0.50 USDC)
        // 0.50 USDC < 1 USDC min → revert
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1, address(mockScorer), nextLineTicks++, 0,
            PositionType.Upper, maker, 1_000_000, taker, 500_000, 0, 0
        );
    }
}
