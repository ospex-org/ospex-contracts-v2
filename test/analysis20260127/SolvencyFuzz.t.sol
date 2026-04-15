// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
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

contract MockLeaderboardModuleFuzz {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

contract SolvencyFuzz is Test {
    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;
    MockContestModule mockContestModule;
    MockLeaderboardModuleFuzz mockLeaderboardModule;
    MockScorerModule mockScorer;

    address maker = address(0xBEEF);
    address taker = address(0xCAFE);
    address protocolReceiver = address(0xFEED);

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        // Fund maker and taker with large amounts for fuzz tests
        token.mint(maker, 1_000_000_000_000); // 1M USDC
        token.mint(taker, 1_000_000_000_000); // 1M USDC

        speculationModule = new SpeculationModule(address(core), 6, 3600, 1_000_000);
        positionModule = new PositionModule(address(core), address(token));
        treasuryModule = new TreasuryModule(
            address(core), address(token), protocolReceiver,
            1_000_000, 500_000, 500_000
        );
        mockContestModule = new MockContestModule();
        mockLeaderboardModule = new MockLeaderboardModuleFuzz();
        mockScorer = new MockScorerModule();

        // Bootstrap all 12 modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();           addrs[0]  = address(mockContestModule);
        types[1]  = core.SPECULATION_MODULE();        addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();           addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();           addrs[3]  = address(this); // test contract acts as MATCHING_MODULE
        types[4]  = core.ORACLE_MODULE();             addrs[4]  = address(0xD004);
        types[5]  = core.TREASURY_MODULE();           addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();        addrs[6]  = address(mockLeaderboardModule);
        types[7]  = core.RULES_MODULE();              addrs[7]  = address(0xD007);
        types[8]  = core.SECONDARY_MARKET_MODULE();   addrs[8]  = address(0xD008);
        types[9]  = core.MONEYLINE_SCORER_MODULE();   addrs[9]  = address(0xCC01);
        types[10] = core.SPREAD_SCORER_MODULE();      addrs[10] = address(mockScorer);
        types[11] = core.TOTAL_SCORER_MODULE();       addrs[11] = address(0xCC02);
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Set up a verified contest
        Contest memory contest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            verifySourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        // Approve positionModule for both maker and taker
        vm.prank(maker);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(taker);
        token.approve(address(positionModule), type(uint256).max);

        // Approve TreasuryModule for speculation creation split fees
        vm.prank(maker);
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(taker);
        token.approve(address(treasuryModule), type(uint256).max);
    }

    /// @notice Fuzz test: for any valid oddsTick and makerRisk, total payouts == total deposited
    function testFuzz_SolvencyInvariant(uint16 oddsTick, uint256 makerRisk) public {
        // Bound inputs
        oddsTick = uint16(bound(oddsTick, 101, 10100));
        makerRisk = bound(makerRisk, 100, 100_000_000); // 0.0001 to 100 USDC
        // Ensure lot-aligned
        makerRisk = makerRisk - (makerRisk % 100);
        if (makerRisk == 0) makerRisk = 100;

        // Compute takerRisk = makerRisk * profitTicks / ODDS_SCALE
        uint256 profitTicks = uint256(oddsTick) - 100;
        uint256 takerRisk = (makerRisk * profitTicks) / 100;
        if (takerRisk == 0) return; // skip degenerate

        // takerRisk must be within speculation bounds (1e6 to 100e6)
        if (takerRisk < 1e6 || takerRisk > 100e6) return;

        uint256 totalDeposited = makerRisk + takerRisk;

        // Use a unique scorer address per fuzz run to avoid "SpeculationExists" revert
        // by using the lineTicks param to differentiate speculations
        int32 lineTicks = int32(int256(uint256(oddsTick)));

        // Create positions via recordFill
        uint256 speculationId = positionModule.recordFill(
            1,                    // contestId
            address(mockScorer),  // scorer
            lineTicks,
            PositionType.Upper,   // maker is Upper
            maker,
            makerRisk,
            taker,
            takerRisk
        );

        // Verify positions created correctly
        Position memory makerPos = positionModule.getPosition(speculationId, maker, PositionType.Upper);
        assertEq(makerPos.riskAmount, makerRisk, "Maker risk should match");
        assertEq(makerPos.profitAmount, takerRisk, "Maker profit should equal taker risk");

        Position memory takerPos = positionModule.getPosition(speculationId, taker, PositionType.Lower);
        assertEq(takerPos.riskAmount, takerRisk, "Taker risk should match");
        assertEq(takerPos.profitAmount, makerRisk, "Taker profit should equal maker risk");

        // --- Test Upper win scenario ---
        // Set contest as scored and scorer returns Away (Upper wins)
        Contest memory scoredContest = Contest({
            awayScore: 10,
            homeScore: 5,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            verifySourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, scoredContest);
        mockScorer.setWinSide(1, lineTicks, WinSide.Away);

        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);

        // Winner (maker/Upper) claims: gets riskAmount + profitAmount
        uint256 makerBalBefore = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(speculationId, PositionType.Upper);
        uint256 makerPayout = token.balanceOf(maker) - makerBalBefore;

        assertEq(makerPayout, totalDeposited, "Winner payout should equal total deposited");

        // Loser (taker/Lower) should get nothing
        vm.prank(taker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        positionModule.claimPosition(speculationId, PositionType.Lower);

        // --- Test Push scenario with a new speculation ---
        // Reset contest to verified for new speculation
        Contest memory verifiedContest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            verifySourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, verifiedContest);

        // Use a different lineTicks for the push speculation
        int32 pushLineTicks = lineTicks + 10000;

        uint256 pushSpecId = positionModule.recordFill(
            1,
            address(mockScorer),
            pushLineTicks,
            PositionType.Upper,
            maker,
            makerRisk,
            taker,
            takerRisk
        );

        // Score the contest and set Push
        mockContestModule.setContest(1, scoredContest);
        mockScorer.setWinSide(1, pushLineTicks, WinSide.Push);

        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(pushSpecId);

        // Both claim their risk back
        uint256 makerPushBefore = token.balanceOf(maker);
        vm.prank(maker);
        positionModule.claimPosition(pushSpecId, PositionType.Upper);
        uint256 makerRefund = token.balanceOf(maker) - makerPushBefore;

        uint256 takerPushBefore = token.balanceOf(taker);
        vm.prank(taker);
        positionModule.claimPosition(pushSpecId, PositionType.Lower);
        uint256 takerRefund = token.balanceOf(taker) - takerPushBefore;

        assertEq(makerRefund, makerRisk, "Maker should get risk back on push");
        assertEq(takerRefund, takerRisk, "Taker should get risk back on push");
        assertEq(makerRefund + takerRefund, totalDeposited, "Push refunds should equal total deposited");
    }
}

/// @notice Targeted invariant: exact division for fill math across odds range
contract SolvencyExactDivision is Test {
    /// @notice For oddsTick from 101 to 500, verify makerProfit computation has zero remainder
    function testTargeted_ExactDivision_OddsRange() public pure {
        uint256 fillMakerRisk = 100_000_000; // 100 USDC
        uint256 ODDS_SCALE = 100;

        for (uint16 oddsTick = 101; oddsTick <= 500; oddsTick++) {
            uint256 profitTicks = uint256(oddsTick) - ODDS_SCALE;
            uint256 makerProfit = (fillMakerRisk * profitTicks) / ODDS_SCALE;

            // Verify zero remainder: makerProfit * ODDS_SCALE == fillMakerRisk * profitTicks
            assertEq(
                makerProfit * ODDS_SCALE,
                fillMakerRisk * profitTicks,
                string.concat(
                    "Non-zero remainder at oddsTick=",
                    vm.toString(oddsTick)
                )
            );
        }
    }
}
