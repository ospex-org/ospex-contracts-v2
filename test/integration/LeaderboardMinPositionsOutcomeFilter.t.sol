// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] This test uses real LeaderboardModule, RulesModule, TreasuryModule, PositionModule,
//        SpeculationModule. MockContestModule and MockScorerModule are used for contest/scoring.
//        The test contract acts as the MatchingModule.

import "forge-std/Test.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {RulesModule} from "../../src/modules/RulesModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {
    Position,
    PositionType,
    Leaderboard,
    LeaderboardPosition,
    Contest,
    ContestStatus,
    LeagueId,
    WinSide,
    FeeType
} from "../../src/core/OspexTypes.sol";

/**
 * @title LeaderboardMinPositionsOutcomeFilterTest
 * @notice Integration tests verifying that only Win, Loss, and Push positions count
 *         toward the min-positions requirement. Void and TBD do not count.
 *
 * Setup:
 *   - minBets = 3 for the leaderboard
 *   - Multiple contests/speculations created per test as needed
 *   - user1 is the primary test participant, counterparty is the taker
 */
contract LeaderboardMinPositionsOutcomeFilterTest is Test {
    OspexCore core;
    PositionModule positionModule;
    SpeculationModule speculationModule;
    LeaderboardModule leaderboardModule;
    RulesModule rulesModule;
    TreasuryModule treasuryModule;
    MockERC20 token;
    MockContestModule mockContestModule;
    MockScorerModule mockScorerModule;

    address user1 = address(0xBEEF);
    address counterparty = address(0xCAFE);
    address lbCreator = address(0xC8EA);

    uint256 constant TOKEN_AMOUNT = 10_000_000_000; // 10,000 USDC
    uint256 constant ENTRY_FEE = 10_000_000; // 10 USDC
    uint256 constant DECLARED_BANKROLL = 1_000_000_000; // 1000 USDC
    uint256 constant BET_AMOUNT = 50_000_000; // 50 USDC
    uint16 constant MIN_BETS = 3;

    uint256 leaderboardId;
    uint32 lbStartTime;
    uint32 lbEndTime;

    // Speculation IDs populated per-test
    uint256[] specIds;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        positionModule = new PositionModule(address(core), address(token));
        speculationModule = new SpeculationModule(address(core), 3 days);
        leaderboardModule = new LeaderboardModule(address(core));
        rulesModule = new RulesModule(address(core));
        treasuryModule = new TreasuryModule(
            address(core), address(token), address(0xFEED),
            1_000_000, 500_000, 500_000
        );
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();         addrs[0]  = address(mockContestModule);
        types[1]  = core.SPECULATION_MODULE();      addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();         addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();         addrs[3]  = address(this);
        types[4]  = core.ORACLE_MODULE();           addrs[4]  = address(0xFEED);
        types[5]  = core.TREASURY_MODULE();         addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();      addrs[6]  = address(leaderboardModule);
        types[7]  = core.RULES_MODULE();            addrs[7]  = address(rulesModule);
        types[8]  = core.SECONDARY_MARKET_MODULE(); addrs[8]  = address(0x5EC0);
        types[9]  = core.MONEYLINE_SCORER_MODULE(); addrs[9]  = address(mockScorerModule);
        types[10] = core.SPREAD_SCORER_MODULE();    addrs[10] = address(0x5901);
        types[11] = core.TOTAL_SCORER_MODULE();     addrs[11] = address(0x7701);
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Fund accounts
        token.mint(user1, TOKEN_AMOUNT);
        token.mint(counterparty, TOKEN_AMOUNT);
        token.mint(lbCreator, TOKEN_AMOUNT);

        address[3] memory users = [user1, counterparty, lbCreator];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(positionModule), type(uint256).max);
            token.approve(address(treasuryModule), type(uint256).max);
            vm.stopPrank();
        }

        // Create leaderboard
        lbStartTime = uint32(block.timestamp + 1 hours);
        lbEndTime = uint32(block.timestamp + 8 days);

        vm.prank(lbCreator);
        leaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE, lbStartTime, lbEndTime, 1 days, 7 days
        );

        // Set minBets = 3
        vm.prank(lbCreator);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);

        // Warp to after leaderboard start
        vm.warp(lbStartTime + 1);

        // Register user
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
    }

    // =========================================================================
    // Test 1: Void positions do NOT count toward min-positions
    // =========================================================================

    function test_VoidPositionsDoNotCountTowardMinPositions() public {
        // Create 3 positions, all resolve to Void
        for (uint256 i = 0; i < 3; i++) {
            _createAndRegisterPosition(i + 1);
        }

        // Settle all as Void (warp past voidCooldown without scoring)
        for (uint256 i = 0; i < specIds.length; i++) {
            _settleAsVoid(specIds[i], i + 1);
        }

        // Warp to ROI window
        _warpToROIWindow();

        // Submit should fail — 3 Void positions don't meet minBets=3
        vm.prank(user1);
        vm.expectRevert(
            LeaderboardModule.LeaderboardModule__MinimumPositionsNotMet.selector
        );
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    // =========================================================================
    // Test 2: TBD positions do NOT count toward min-positions
    // =========================================================================

    function test_TBDPositionsDoNotCountTowardMinPositions() public {
        // Create 3 positions, leave all as TBD (never settle)
        for (uint256 i = 0; i < 3; i++) {
            _createAndRegisterPosition(i + 1);
        }

        // Warp to ROI window (positions remain TBD)
        _warpToROIWindow();

        // Submit should fail — 3 TBD positions don't meet minBets=3
        vm.prank(user1);
        vm.expectRevert(
            LeaderboardModule.LeaderboardModule__MinimumPositionsNotMet.selector
        );
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    // =========================================================================
    // Test 3: Push positions DO count toward min-positions
    // =========================================================================

    function test_PushPositionsDOCountTowardMinPositions() public {
        // Create 3 positions, all resolve to Push
        for (uint256 i = 0; i < 3; i++) {
            _createAndRegisterPosition(i + 1);
        }

        // Settle all as Push
        for (uint256 i = 0; i < specIds.length; i++) {
            _settleAsScored(specIds[i], i + 1, WinSide.Push);
        }

        // Warp to ROI window
        _warpToROIWindow();

        // Submit should succeed — 3 Push positions meet minBets=3
        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // Verify ROI = 0 (Push = break even)
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 0, "Push positions should yield 0 ROI");
    }

    // =========================================================================
    // Test 4: Win/Loss positions count toward min-positions (control)
    // =========================================================================

    function test_WinLossPositionsCountTowardMinPositions() public {
        // Create 3 positions: 2 wins + 1 loss
        for (uint256 i = 0; i < 3; i++) {
            _createAndRegisterPosition(i + 1);
        }

        // Settle: spec1 = Away win (Upper wins), spec2 = Away win, spec3 = Home win (Upper loses)
        _settleAsScored(specIds[0], 1, WinSide.Away);
        _settleAsScored(specIds[1], 2, WinSide.Away);
        _settleAsScored(specIds[2], 3, WinSide.Home);

        // Warp to ROI window
        _warpToROIWindow();

        // Submit should succeed
        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // ROI = (2 * profit - 1 * risk) / bankroll
        // 2 wins: net = 2 * 40M = 80M. 1 loss: net = -50M. Total = 30M
        // ROI = 30M * 1e18 / 1000M = 3e16
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 30000000000000000, "ROI should reflect 2 wins and 1 loss");
    }

    // =========================================================================
    // Test 5: Mixed outcomes — only Win/Loss/Push count toward minimum
    // =========================================================================

    function test_MixedOutcomesCountOnlyWinLossPush() public {
        // Create 5 positions total
        // Qualifying count will be 2 (Win + Loss), minBets = 3. Should fail.
        for (uint256 i = 0; i < 5; i++) {
            _createAndRegisterPosition(i + 1);
        }

        // Settle: Win, Loss, Void, (TBD), Void
        _settleAsScored(specIds[0], 1, WinSide.Away);     // Win (Upper)
        _settleAsScored(specIds[1], 2, WinSide.Home);     // Loss (Upper)
        _settleAsVoid(specIds[2], 3);                      // Void
        // specIds[3] left as TBD (never settled)           // TBD
        _settleAsVoid(specIds[4], 5);                      // Void

        // Qualifying count = 2 (Win + Loss). minBets = 3. Should fail.
        _warpToROIWindow();

        vm.prank(user1);
        vm.expectRevert(
            LeaderboardModule.LeaderboardModule__MinimumPositionsNotMet.selector
        );
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    /// @notice Pre-creates 6 positions. With Win+Loss+Push = 3 qualifying, threshold is met.
    function test_MixedOutcomesThresholdBehavior() public {
        // Create 6 positions
        for (uint256 i = 0; i < 6; i++) {
            _createAndRegisterPosition(i + 1);
        }

        // Settle: Win, Loss, Void, TBD, Void, Push
        _settleAsScored(specIds[0], 1, WinSide.Away);     // Win
        _settleAsScored(specIds[1], 2, WinSide.Home);     // Loss
        _settleAsVoid(specIds[2], 3);                      // Void
        // specIds[3] left as TBD                           // TBD
        _settleAsVoid(specIds[4], 5);                      // Void
        _settleAsScored(specIds[5], 6, WinSide.Push);      // Push

        // Qualifying: Win + Loss + Push = 3. minBets = 3. Should succeed.
        _warpToROIWindow();

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // ROI = (Win profit - Loss risk + 0 for Push/Void/TBD) / bankroll
        // Win: +40M, Loss: -50M, Push: 0, Void: 0, TBD: 0, Void: 0 = -10M
        // ROI = -10M * 1e18 / 1000M = -1e16
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, -10000000000000000, "ROI should reflect Win + Loss + zeros");
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Creates a contest, speculation, position, and registers it for the leaderboard
    function _createAndRegisterPosition(uint256 contestId) internal {
        Contest memory contest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(contestId, contest);
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 10 hours));

        uint256 specId = positionModule.recordFill(
            contestId, address(mockScorerModule), 0, PositionType.Upper,
            user1, BET_AMOUNT, counterparty, 40_000_000
        );
        specIds.push(specId);

        // Add to leaderboard and register
        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId);

        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );
    }

    /// @dev Settles a speculation with a scored contest and specific outcome
    function _settleAsScored(uint256 specId, uint256 contestId, WinSide side) internal {
        // Warp past contest start so settlement is valid
        uint32 startTime = mockContestModule.s_contestStartTimes(contestId);
        if (block.timestamp < uint256(startTime)) {
            vm.warp(uint256(startTime) + 1);
        }

        Contest memory scored = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(contestId, scored);
        mockScorerModule.setWinSide(contestId, 0, side);
        speculationModule.settleSpeculation(specId);
    }

    /// @dev Settles a speculation as Void by warping past voidCooldown without scoring
    function _settleAsVoid(uint256 specId, uint256 contestId) internal {
        uint32 startTime = mockContestModule.s_contestStartTimes(contestId);
        uint256 voidTime = uint256(startTime) + 3 days + 1;
        if (block.timestamp < voidTime) {
            vm.warp(voidTime);
        }
        speculationModule.settleSpeculation(specId);
    }

    function _warpToROIWindow() internal {
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        if (block.timestamp < roiWindowStart) {
            vm.warp(roiWindowStart);
        }
    }
}
