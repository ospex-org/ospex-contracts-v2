// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] OddsPair system has been removed. Positions use riskAmount/profitAmount directly.

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionType, Contest, ContestStatus, Position, WinSide, LeagueId, Speculation, SpeculationStatus, FeeType, Leaderboard} from "../../src/core/OspexTypes.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockSpeculationModule} from "../mocks/MockSpeculationModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

contract MockLeaderboardModule {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

contract PositionModuleTest is Test {
    using stdStorage for StdStorage;

    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;

    address user = address(0xBEEF);
    address taker = address(0xCAFE);
    address protocolReceiver = address(0xFEED);

    MockContestModule mockContestModule;
    MockLeaderboardModule mockLeaderboardModule;

    // leaderboard Id and allocation set to 0 for testing
    uint256 leaderboardId = 0;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();
        // Fund user
        token.transfer(user, 1_000_000_000);
        // Fund taker
        token.transfer(taker, 500_000_000);

        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(
            address(core),
            address(token)
        );
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);

        // Register a mock contest module so SpeculationModule can call getContest
        mockContestModule = new MockContestModule();

        // Register a mock leaderboard module so TreasuryModule can call getLeaderboard
        mockLeaderboardModule = new MockLeaderboardModule();

        // Register modules for event emission and inter-module communication
        // Note: The test contract (address(this)) is automatically granted MODULE_ADMIN_ROLE and DEFAULT_ADMIN_ROLE
        // when it deploys the OspexCore contract, so it can register modules
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(positionModule)
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(speculationModule)
        );
        core.registerModule(
            keccak256("CONTRIBUTION_MODULE"),
            address(contributionModule)
        );
        core.registerModule(
            keccak256("TREASURY_MODULE"),
            address(treasuryModule)
        );
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(mockContestModule)
        );
        core.registerModule(
            keccak256("LEADERBOARD_MODULE"),
            address(mockLeaderboardModule)
        );

        // Register this test contract as MATCHING_MODULE so it can call recordFill
        core.registerModule(keccak256("MATCHING_MODULE"), address(this));

        // Register this test contract as ORACLE_MODULE (kept for other module interactions)
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));

        // Set up default verified contests for all tests
        Contest memory defaultContest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, // Set the contest as verified
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, defaultContest);
        mockContestModule.setContest(2, defaultContest); // Add contest ID 2 for multi-contest tests
        mockContestModule.setContest(3, defaultContest); // Add contest ID 3 for safety

        // DO NOT set min/max speculation amounts here. They are set in the SpeculationModule constructor.
    }

    // --- Helper Functions ---

    /// @notice Helper to record a fill (test contract has MATCHING_MODULE role)
    function _helperRecordFill(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address _taker,
        uint256 takerRisk
    ) internal returns (uint256 speculationId) {
        speculationId = positionModule.recordFill(
            contestId, scorer, lineTicks, leaderboardId,
            makerPositionType, maker, makerRisk,
            _taker, takerRisk, 0, 0
        );
    }

    /// @notice Helper to record a fill on a specific PositionModule instance
    function _helperRecordFillLocal(
        PositionModule localPM,
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address _taker,
        uint256 takerRisk
    ) internal returns (uint256 speculationId) {
        speculationId = localPM.recordFill(
            contestId, scorer, lineTicks, leaderboardId,
            makerPositionType, maker, makerRisk,
            _taker, takerRisk, 0, 0
        );
    }

    // --- CONSTRUCTOR TESTS ---

    function testConstructor_SetsAddresses() public view {
        assertEq(address(positionModule.i_ospexCore()), address(core));
        assertEq(address(positionModule.i_token()), address(token));
    }

    function testConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(PositionModule.PositionModule__InvalidAddress.selector);
        new PositionModule(
            address(0),
            address(token)
        );
    }

    function testGetModuleType() public view {
        assertEq(positionModule.getModuleType(), keccak256("POSITION_MODULE"));
    }

    // --- recordFill TESTS ---

    function testRecordFill_HappyPath() public {
        // Maker = address(this), 10 USDC risk, taker 8 USDC risk (equivalent to old 1.80 odds)
        // At 1.80 odds: maker risks 10, profit if win = 8. Taker risks 8, profit if win = 10.
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        // Approve tokens for both maker and taker
        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Verify speculation was created
        assertGt(specId, 0, "Speculation should have been created");

        // Verify maker position
        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        assertEq(makerPos.riskAmount, 10_000_000, "Maker riskAmount should be 10M");
        assertEq(makerPos.profitAmount, 8_000_000, "Maker profitAmount should be 8M");
        assertEq(uint(makerPos.positionType), uint(PositionType.Upper));
        assertFalse(makerPos.claimed);

        // Verify taker position
        Position memory takerPos = positionModule.getPosition(
            specId,
            taker,
            PositionType.Lower
        );
        assertEq(takerPos.riskAmount, 8_000_000, "Taker riskAmount should be 8M");
        assertEq(takerPos.profitAmount, 10_000_000, "Taker profitAmount should be 10M");
        assertEq(uint(takerPos.positionType), uint(PositionType.Lower));
        assertFalse(takerPos.claimed);
    }

    function testRecordFill_RevertsWithoutMatchingModule() public {
        // Use an address that is NOT the MATCHING_MODULE
        address unauthorized = address(0xDEAD);

        vm.expectRevert(
            PositionModule.PositionModule__NotMatchingModule.selector
        );
        vm.prank(unauthorized);
        positionModule.recordFill(
            1,
            address(0x1234),
            42,
            leaderboardId,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            8_000_000,
            0,
            0
        );
    }

    function testRecordFill_RevertsIfSpeculationNotOpen() public {
        uint32 startTime = uint32(block.timestamp + 1 hours);

        MockScorerModule mockScorer = new MockScorerModule();

        // First create a speculation via recordFill
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Settle the speculation
        vm.warp(startTime + 2 hours);
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        speculationModule.settleSpeculation(specId);

        // Try to record a fill after speculation is closed
        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        // recordFill will find the existing speculation (which is now Closed) and revert
        vm.expectRevert(
            PositionModule.PositionModule__SpeculationNotOpen.selector
        );
        positionModule.recordFill(
            1,
            address(mockScorer),
            42,
            leaderboardId,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk,
            0,
            0
        );
    }

    function testRecordFill_RevertsIfTakerRiskOutOfRange() public {
        token.approve(address(positionModule), 10_000_000);
        vm.prank(taker);
        token.approve(address(positionModule), 1);

        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.recordFill(
            1,
            address(0x1234),
            42,
            leaderboardId,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            1, // Below min speculation amount
            0,
            0
        );
    }

    // --- recordFill with auto-speculation creation TESTS ---

    function testRecordFill_CreatesSpeculationAutomatically() public {
        // Verify speculation doesn't exist yet
        uint256 existingSpecId = speculationModule.getSpeculationId(
            1, // contestId
            address(0x1234), // scorer
            42 // lineTicks
        );
        assertEq(existingSpecId, 0, "Speculation should not exist yet");

        // Set up maker and taker approvals
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        // Call recordFill — speculation should be created automatically
        uint256 specId = _helperRecordFill(
            1, // contestId
            address(0x1234), // scorer
            42, // lineTicks
            PositionType.Upper,
            address(this), // maker
            makerRisk,
            taker,
            takerRisk
        );

        // Verify speculation was created
        assertGt(specId, 0, "Speculation should have been created");

        Speculation memory spec = speculationModule.getSpeculation(specId);
        assertEq(spec.contestId, 1);
        assertEq(spec.speculationScorer, address(0x1234));
        assertEq(spec.lineTicks, 42);

        // Verify positions were created
        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        assertGt(makerPos.riskAmount, 0, "Maker should have risk amount");

        Position memory takerPos = positionModule.getPosition(
            specId,
            taker,
            PositionType.Lower
        );
        assertGt(takerPos.riskAmount, 0, "Taker should have risk amount");
    }

    // --- CLAIM POSITION TESTS ---

    function testClaimPosition_HappyPath() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        MockScorerModule mockScorer = new MockScorerModule();

        // Create matched pair: maker=this (Upper), taker=0xCAFE (Lower)
        // At 1.80 odds: makerRisk=10M, takerRisk=8M
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Settle speculation (Away wins = Upper wins)
        vm.warp(futureTime + 2 hours);
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        speculationModule.settleSpeculation(specId);

        // Claim: winner gets riskAmount + profitAmount = 10M + 8M = 18M
        uint256 balBefore = token.balanceOf(address(this));
        positionModule.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 18_000_000, "Winner payout should be 18M (10M + 8M)");

        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        assertTrue(pos.claimed);
        assertEq(pos.riskAmount, 0);
    }

    function testGetPosition_ReturnPositionWithClaimedTrue() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        MockScorerModule mockScorer = new MockScorerModule();

        // Create matched pair
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        vm.warp(futureTime + 2 hours);
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        speculationModule.settleSpeculation(specId);

        positionModule.claimPosition(specId, PositionType.Upper);
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        assertTrue(pos.claimed);
        assertEq(pos.riskAmount, 0);
    }

    // --- PAYOUT CALCULATION EDGE CASES ---

    function testClaimPosition_PushVoidForfeit() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);
        uint32 futureTime2 = uint32(block.timestamp + 2 hours);

        // Use MockSpeculationModule for this test
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPositionModule = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPositionModule)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        // Reset to a reasonable starting time
        vm.warp(1672531200); // Jan 1, 2023

        // --- Test Push scenario ---
        // At 1.80 odds: maker risks 10M, taker risks 8M
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(localPositionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(localPositionModule), takerRisk);

        uint256 specIdPush = _helperRecordFillLocal(
            localPositionModule,
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        vm.warp(futureTime + 2 hours);
        Contest memory contestPush = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contestPush);

        mockSpeculationModule.settleSpeculation(specIdPush);
        mockSpeculationModule.setSpeculationWinSide(specIdPush, WinSide.Push);

        // On Push: payout = riskAmount (original stake back)
        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specIdPush,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000_000, "Push should return riskAmount (10M)");

        // --- Test Void scenario ---
        vm.warp(1672531200 + 1 days); // Jan 2, 2023
        futureTime2 = uint32(block.timestamp + 1 hours);

        // Create matched pair for Void test
        token.approve(address(localPositionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(localPositionModule), takerRisk);

        uint256 specIdVoid = _helperRecordFillLocal(
            localPositionModule,
            2,
            address(mockScorer),
            43,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        vm.warp(futureTime2 + 2 hours);
        Contest memory contestVoid = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(2, contestVoid);

        mockSpeculationModule.settleSpeculation(specIdVoid);
        mockSpeculationModule.setSpeculationWinSide(specIdVoid, WinSide.Void);

        balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specIdVoid,
            PositionType.Upper
        );
        balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000_000, "Void should return riskAmount (10M)");
    }

    function testClaimPosition_WinLossScenarios() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPositionModule = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPositionModule)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 tokenUnit = 10_000_000; // 10 USDC

        // --- Create Upper position ---
        // At 1.10 odds: maker risks 10M, taker risks 1M (profit for maker = 1M)
        uint256 upperTakerRisk = 1_000_000;
        address upperTaker = address(0xCAFE);

        token.approve(address(localPositionModule), tokenUnit);
        token.transfer(upperTaker, upperTakerRisk);
        vm.prank(upperTaker);
        token.approve(address(localPositionModule), upperTakerRisk);

        uint256 specId1 = _helperRecordFillLocal(
            localPositionModule,
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            tokenUnit,
            upperTaker,
            upperTakerRisk
        );

        // --- Create Lower position (separate speculation) ---
        // At 1.80 odds Lower: maker risks 10M, taker risks 8M
        uint256 lowerTakerRisk = 8_000_000;
        address lowerTaker = address(0xCAFF);

        token.approve(address(localPositionModule), tokenUnit);
        token.transfer(lowerTaker, lowerTakerRisk);
        vm.prank(lowerTaker);
        token.approve(address(localPositionModule), lowerTakerRisk);

        uint256 specId2 = _helperRecordFillLocal(
            localPositionModule,
            1,
            address(mockScorer),
            43,
            PositionType.Lower,
            address(this),
            tokenUnit,
            lowerTaker,
            lowerTakerRisk
        );

        vm.warp(futureTime + 2 hours);
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        mockSpeculationModule.settleSpeculation(specId1);
        mockSpeculationModule.settleSpeculation(specId2);

        // Test win for Upper (Away)
        mockSpeculationModule.setSpeculationWinSide(specId1, WinSide.Away);
        Position memory posUpper = localPositionModule.getPosition(
            specId1,
            address(this),
            PositionType.Upper
        );
        emit log_named_uint("riskAmount (Upper win)", posUpper.riskAmount);
        emit log_named_uint("positionType (Upper win)", uint(posUpper.positionType));

        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId1,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Upper win)", balAfter - balBefore);
        // Winner gets riskAmount + profitAmount
        assertGt(balAfter - balBefore, tokenUnit);

        // Test win for Lower (Home)
        mockSpeculationModule.setSpeculationWinSide(specId2, WinSide.Home);
        Position memory posLower = localPositionModule.getPosition(
            specId2,
            address(this),
            PositionType.Lower
        );
        emit log_named_uint("riskAmount (Lower win)", posLower.riskAmount);
        emit log_named_uint("positionType (Lower win)", uint(posLower.positionType));

        balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId2,
            PositionType.Lower
        );
        balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Lower win)", balAfter - balBefore);
        assertGt(balAfter - balBefore, tokenUnit);
    }

    // --- TRANSFER POSITION TESTS ---

    function testTransferPosition_HappyPath() public {
        // Create matched pair
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 1_000_000; // At 1.10 odds

        token.approve(address(positionModule), makerRisk);
        token.transfer(taker, takerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );

        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);
        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            user,
            makerPos.riskAmount,
            makerPos.profitAmount
        );

        Position memory fromPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        Position memory toPos = positionModule.getPosition(
            specId,
            user,
            PositionType.Upper
        );
        assertEq(fromPos.riskAmount, 0);
        assertEq(toPos.riskAmount, makerPos.riskAmount);
        assertEq(toPos.profitAmount, makerPos.profitAmount);
        assertFalse(toPos.claimed);
    }

    function testTransferPosition_RevertsIfUnauthorized() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 1_000_000;

        token.approve(address(positionModule), makerRisk);
        token.transfer(taker, takerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );

        // MockMarket WITHOUT market role
        MockMarket market = new MockMarket(address(positionModule));
        vm.expectRevert(
            PositionModule.PositionModule__UnauthorizedMarket.selector
        );
        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            user,
            makerPos.riskAmount,
            makerPos.profitAmount
        );
    }

    function testTransferPosition_RevertsIfInvalidAmount() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 1_000_000;

        token.approve(address(positionModule), makerRisk);
        token.transfer(taker, takerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );

        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            user,
            makerPos.riskAmount + 1,
            makerPos.profitAmount
        );
    }

    // --- CLAIM POSITION EDGE CASE TESTS ---

    /**
     * @notice Test that claimPosition reverts with NoPayout when riskAmount=0
     * @dev This scenario occurs when a user transfers their entire position via secondary market
     */
    function testClaimPosition_RevertsWithNoPayout_WhenBothAmountsZero() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPositionModule = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPositionModule)
        );

        MockMarket mockMarket = new MockMarket(address(localPositionModule));
        core.setMarketRole(address(mockMarket), true);

        MockScorerModule mockScorer = new MockScorerModule();

        // Create matched pair: maker=this, taker=taker
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 10_000_000; // At 2.00 odds

        token.approve(address(localPositionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(localPositionModule), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            localPositionModule,
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Transfer entire position to another user via secondary market
        address buyer = address(0xBEEF);
        mockMarket.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            buyer,
            10_000_000,
            10_000_000
        );

        // Verify maker's position now has riskAmount=0
        Position memory makerPos = localPositionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        assertEq(makerPos.riskAmount, 0, "riskAmount should be 0 after full transfer");

        // Settle speculation
        vm.warp(block.timestamp + 2 hours);
        Contest memory contest = Contest({
            awayScore: 100,
            homeScore: 90,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        mockSpeculationModule.settleSpeculation(specId);

        // Attempt to claim should revert with NoPayout
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        localPositionModule.claimPosition(specId, PositionType.Upper);
    }

    /**
     * @notice Test that calling claimPosition twice reverts with AlreadyClaimed
     */
    function testClaimPosition_RevertsWithAlreadyClaimed_OnDoubleClaim() public {
        MockScorerModule mockScorer = new MockScorerModule();

        // Create matched pair
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Settle speculation
        vm.warp(block.timestamp + 2 hours);
        Contest memory contest = Contest({
            awayScore: 100,
            homeScore: 90,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        speculationModule.settleSpeculation(specId);

        // First claim succeeds
        positionModule.claimPosition(specId, PositionType.Upper);

        // Second claim should revert with AlreadyClaimed
        vm.expectRevert(PositionModule.PositionModule__AlreadyClaimed.selector);
        positionModule.claimPosition(specId, PositionType.Upper);
    }

    // --- TRANSFER POSITION ACCUMULATION TEST ---

    /**
     * @notice Test that transferPosition correctly accumulates riskAmount when recipient has existing position
     */
    function testTransferPosition_AccumulatesRiskAmount() public {
        // Step 1: Buyer (user) creates a position (5 USDC risk, 5 USDC taker risk at 2.00 odds)
        uint256 buyerRisk = 5_000_000;
        uint256 buyerTakerRisk = 5_000_000;

        vm.prank(user);
        token.approve(address(positionModule), buyerRisk);
        address taker1 = address(0xCAF1);
        token.transfer(taker1, buyerTakerRisk);
        vm.prank(taker1);
        token.approve(address(positionModule), buyerTakerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            user,
            buyerRisk,
            taker1,
            buyerTakerRisk
        );

        // Verify buyer's position
        Position memory buyerPosBefore = positionModule.getPosition(
            specId,
            user,
            PositionType.Upper
        );
        assertEq(buyerPosBefore.riskAmount, buyerRisk, "Buyer should have 5 USDC risk");

        // Step 2: Seller creates a position (10 USDC risk)
        address seller = address(0x5E11);
        uint256 sellerRisk = 10_000_000;
        uint256 sellerTakerRisk = 10_000_000;

        token.transfer(seller, sellerRisk);
        vm.prank(seller);
        token.approve(address(positionModule), sellerRisk);

        address taker2 = address(0xCAF2);
        token.transfer(taker2, sellerTakerRisk);
        vm.prank(taker2);
        token.approve(address(positionModule), sellerTakerRisk);

        // Use the same speculation by calling recordFill with the same contest/scorer/lineTicks
        positionModule.recordFill(
            1, address(0x1234), 42, leaderboardId,
            PositionType.Upper, seller, sellerRisk,
            taker2, sellerTakerRisk, 0, 0
        );

        // Step 3: Transfer seller's position to buyer
        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);
        market.transferPosition(
            specId,
            seller,
            PositionType.Upper,
            user,
            sellerRisk,
            sellerTakerRisk
        );

        // Step 4: Verify buyer's riskAmount is ACCUMULATED (5 + 10 = 15)
        Position memory buyerPosAfter = positionModule.getPosition(
            specId,
            user,
            PositionType.Upper
        );
        assertEq(
            buyerPosAfter.riskAmount,
            buyerRisk + sellerRisk,
            "Buyer's riskAmount should accumulate (5 + 10 = 15)"
        );
    }

    // =========================================================================
    // DIRECT RISK/PROFIT TESTS
    // Tests with various risk/profit ratios equivalent to different odds
    // =========================================================================

    /// @notice Helper: settle a speculation as Away-wins (Upper wins)
    function _settleAsAwayWins(uint256 specId, uint256 contestId) internal {
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 100, homeScore: 90, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(contestId, c);
        speculationModule.settleSpeculation(specId);
    }

    /// @notice Helper: settle a speculation as Home-wins (Lower wins)
    function _settleAsHomeWins(uint256 specId, uint256 contestId) internal {
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 90, homeScore: 100, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(contestId, c);
    }

    // --- Individual risk/profit ratio tests ---

    function testRecordFill_Odds193_Upper() public {
        // At 1.93 odds: maker risks 5_376_345, profit = 5_000_000 (taker risk)
        // Taker risks 5_000_000, profit = 5_376_345 (maker risk)
        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 makerBalBefore = token.balanceOf(address(this));
        uint256 takerBalBefore = token.balanceOf(taker);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 200,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        assertEq(token.balanceOf(address(this)), makerBalBefore - makerRisk, "maker balance wrong");
        assertEq(token.balanceOf(taker), takerBalBefore - takerRisk, "taker balance wrong");

        // Verify both positions
        Position memory mPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        Position memory tPos = positionModule.getPosition(specId, taker, PositionType.Lower);
        assertEq(mPos.riskAmount, makerRisk);
        assertEq(mPos.profitAmount, takerRisk);
        assertEq(tPos.riskAmount, takerRisk);
        assertEq(tPos.profitAmount, makerRisk);

        // Pool conservation: both sides reference the same total pool
        assertEq(mPos.riskAmount + mPos.profitAmount, makerRisk + takerRisk);
        assertEq(tPos.riskAmount + tPos.profitAmount, makerRisk + takerRisk);
    }

    function testRecordFill_Odds187_Upper() public {
        // At 1.87 odds: maker risks 5_747_127, profit = 5_000_000
        uint256 makerRisk = 5_747_127;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 201,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        Position memory mPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(mPos.riskAmount, makerRisk);
        assertEq(mPos.profitAmount, takerRisk);
    }

    function testRecordFill_Odds208_Upper() public {
        // At 2.08 odds: maker risks 4_629_630, profit = 5_000_000
        uint256 makerRisk = 4_629_630;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 202,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        Position memory mPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(mPos.riskAmount, makerRisk);
        assertEq(mPos.profitAmount, takerRisk);
    }

    function testRecordFill_Odds215_Upper() public {
        // At 2.15 odds: maker risks 4_347_827, profit = 5_000_000
        uint256 makerRisk = 4_347_827;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 203,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        Position memory mPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(mPos.riskAmount, makerRisk);
        assertEq(mPos.profitAmount, takerRisk);
    }

    /// @notice Lower-side maker at 1.93 odds
    function testRecordFill_Odds193_Lower() public {
        // At 1.93 odds Lower: maker risks 5_376_345, taker risks 5_000_000
        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 204,
            PositionType.Lower, address(this), makerRisk, taker, takerRisk
        );

        // Verify taker gets Upper position (opposite of maker)
        Position memory tPos = positionModule.getPosition(specId, taker, PositionType.Upper);
        assertEq(tPos.riskAmount, takerRisk);
        assertEq(tPos.profitAmount, makerRisk);
    }

    // --- Multiple fills on same speculation ---

    /// @notice Two fills on the same speculation accumulate positions
    function testRecordFill_MultipleFillers_SameSpeculation() public {
        uint256 makerRisk1 = 10_000_000;
        uint256 takerRisk1 = 9_300_000; // at ~1.93 odds

        token.approve(address(positionModule), makerRisk1);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk1);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 250,
            PositionType.Upper, address(this), makerRisk1, taker, takerRisk1
        );

        // Second fill with a different taker
        uint256 makerRisk2 = 5_000_000;
        uint256 takerRisk2 = 4_650_000;
        address taker2 = address(0xCAF2);
        token.transfer(taker2, takerRisk2);

        token.approve(address(positionModule), makerRisk2);
        vm.prank(taker2);
        token.approve(address(positionModule), takerRisk2);

        // recordFill with same contest/scorer/lineTicks reuses existing speculation
        positionModule.recordFill(
            1, address(0x1234), 250, leaderboardId,
            PositionType.Upper, address(this), makerRisk2,
            taker2, takerRisk2, 0, 0
        );

        // Verify maker's accumulated position
        Position memory mPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(mPos.riskAmount, makerRisk1 + makerRisk2, "maker riskAmount = total of both fills");

        // Verify both takers have positions
        Position memory t1Pos = positionModule.getPosition(specId, taker, PositionType.Lower);
        Position memory t2Pos = positionModule.getPosition(specId, taker2, PositionType.Lower);
        assertGt(t1Pos.riskAmount, 0, "taker1 has position");
        assertGt(t2Pos.riskAmount, 0, "taker2 has position");
    }

    // --- Exact allowance tests ---

    /// @notice Maker approves exactly the risk amount needed
    function testRecordFill_ExactAllowance() public {
        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        // Approve EXACTLY the amount that will be consumed
        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 220,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        Position memory mPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(mPos.riskAmount, makerRisk, "exact allowance should succeed");
    }

    /// @notice Maker approves 1 less than needed — should revert
    function testRecordFill_InsufficientAllowanceReverts() public {
        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        // Approve 1 less than needed
        token.approve(address(positionModule), makerRisk - 1);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        // SafeERC20 reverts with "Not allowed" from MockERC20
        vm.expectRevert("Not allowed");
        positionModule.recordFill(
            1, address(0x1234), 221, leaderboardId,
            PositionType.Upper, address(this), makerRisk,
            taker, takerRisk, 0, 0
        );
    }

    // --- Claim payouts at various risk/profit ratios ---

    /// @notice Maker (Upper) wins — verify payout = riskAmount + profitAmount
    function testClaimPosition_MakerWins() public {
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(mockScorer), 230,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        _settleAsAwayWins(specId, 1); // Upper wins

        uint256 balBefore = token.balanceOf(address(this));
        positionModule.claimPosition(specId, PositionType.Upper);
        uint256 payout = token.balanceOf(address(this)) - balBefore;

        // Winner gets their stake + opponent's stake
        assertEq(payout, makerRisk + takerRisk, "maker payout = makerRisk + takerRisk");
    }

    /// @notice Taker (Lower) wins — taker payout should equal total pool
    function testClaimPosition_TakerWins() public {
        MockScorerModule mockScorer = new MockScorerModule();
        mockScorer.setDefaultWinSide(WinSide.Home); // Home = Lower wins

        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(mockScorer), 231,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        _settleAsHomeWins(specId, 1);
        speculationModule.settleSpeculation(specId);

        uint256 balBefore = token.balanceOf(taker);
        vm.prank(taker);
        positionModule.claimPosition(specId, PositionType.Lower);
        uint256 payout = token.balanceOf(taker) - balBefore;

        // Taker payout = taker stake + maker stake = same total pool
        assertEq(payout, takerRisk + makerRisk, "taker payout = takerRisk + makerRisk");
    }

    /// @notice Claim test across multiple risk/profit ratios — winner takes pool
    function testClaimPosition_MultipleRatios_WinnerTakesPool() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(address(core), 6);
        core.registerModule(keccak256("SPECULATION_MODULE"), address(mockSpeculationModule));
        PositionModule localPM = new PositionModule(address(core), address(token));
        core.registerModule(keccak256("POSITION_MODULE"), address(localPM));

        MockScorerModule mockScorer = new MockScorerModule();

        // Risk/profit ratios corresponding to various odds
        uint256[4] memory makerRisks = [uint256(10_000_000), uint256(10_000_000), uint256(10_000_000), uint256(10_000_000)];
        uint256[4] memory takerRisks = [uint256(9_300_000), uint256(8_700_000), uint256(10_800_000), uint256(11_500_000)];

        for (uint256 i = 0; i < makerRisks.length; i++) {
            int32 lineTicks = int32(int256(240 + i));

            address _taker = address(uint160(0xCA00 + i));
            token.transfer(_taker, takerRisks[i]);
            token.approve(address(localPM), makerRisks[i]);
            vm.prank(_taker);
            token.approve(address(localPM), takerRisks[i]);

            uint256 specId = _helperRecordFillLocal(
                localPM, 1, address(mockScorer), lineTicks,
                PositionType.Upper, address(this), makerRisks[i],
                _taker, takerRisks[i]
            );

            // Settle as Away wins (Upper wins)
            vm.warp(block.timestamp + 2 hours);
            Contest memory c = Contest({
                awayScore: 100, homeScore: 90, leagueId: LeagueId.NBA,
                contestStatus: ContestStatus.Scored, contestCreator: address(this),
                scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
            });
            mockContestModule.setContest(1, c);
            mockSpeculationModule.settleSpeculation(specId);

            uint256 balBefore = token.balanceOf(address(this));
            localPM.claimPosition(specId, PositionType.Upper);
            uint256 payout = token.balanceOf(address(this)) - balBefore;

            // Winner gets the entire pool
            assertEq(payout, makerRisks[i] + takerRisks[i], string.concat("payout mismatch at index ", vm.toString(i)));

            // Loser gets nothing
            vm.prank(_taker);
            vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
            localPM.claimPosition(specId, PositionType.Lower);
        }
    }

    // --- Self-transfer revert ---

    function testTransferPosition_RevertsOnSelfTransfer() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(0x1234), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);

        vm.expectRevert(PositionModule.PositionModule__NoSelfTransfer.selector);
        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            address(this), // self-transfer
            makerRisk,
            takerRisk
        );
    }

    // =========================================================================
    // TASK 4: EVENT EMISSION TESTS
    // =========================================================================

    /// @notice Verify PositionFilled event is emitted with all correct fields from recordFill
    function testRecordFill_EmitsPositionFilledEvent() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        // We expect PositionFilled with all indexed + non-indexed fields.
        // Note: the event is emitted from the internal _recordFill. The speculation ID is
        // determined at runtime, so we check indexed topics for maker/taker and check data fields.
        // checkTopic1=false (speculationId unknown at compile time), checkTopic2=true, checkTopic3=true, checkData=true
        vm.expectEmit(false, true, true, true, address(positionModule));
        emit PositionModule.PositionFilled(
            0, // speculationId placeholder (topic1 unchecked)
            address(this), // maker
            taker, // taker
            PositionType.Upper, // makerPositionType
            PositionType.Lower, // takerPositionType
            makerRisk, // makerRisk
            takerRisk // takerRisk
        );

        _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );
    }

    /// @notice Verify PositionClaimed event is emitted with correct fields
    function testClaimPosition_EmitsPositionClaimedEvent() public {
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        _settleAsAwayWins(specId, 1); // Upper wins

        // Winner payout = riskAmount + profitAmount = 10M + 8M = 18M
        vm.expectEmit(true, true, false, true, address(positionModule));
        emit PositionModule.PositionClaimed(
            specId,
            address(this),
            PositionType.Upper,
            makerRisk + takerRisk // payout = 18M
        );

        positionModule.claimPosition(specId, PositionType.Upper);
    }

    /// @notice Verify PositionTransferred event is emitted with correct fields
    function testTransferPosition_EmitsPositionTransferredEvent() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );

        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);

        vm.expectEmit(true, true, true, true, address(positionModule));
        emit PositionModule.PositionTransferred(
            specId,
            address(this), // from
            PositionType.Upper,
            user, // to
            makerPos.riskAmount,
            makerPos.profitAmount
        );

        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            user,
            makerPos.riskAmount,
            makerPos.profitAmount
        );
    }

    // =========================================================================
    // TASK 5: FIX testClaimPosition_WinLossScenarios — exact payout + loser revert
    // (Original test replaced above with assertGt; new version uses exact assertEq
    //  and adds loser claim revert path. Added as a separate test to preserve original.)
    // =========================================================================

    /// @notice Win/loss scenarios with exact payout assertions and loser revert
    function testClaimPosition_WinLossScenarios_ExactPayout() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPositionModule = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPositionModule)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        // --- Upper maker wins scenario ---
        uint256 upperMakerRisk = 10_000_000;
        uint256 upperTakerRisk = 1_000_000;
        address upperTaker = address(0xCAFE);

        token.approve(address(localPositionModule), upperMakerRisk);
        token.transfer(upperTaker, upperTakerRisk);
        vm.prank(upperTaker);
        token.approve(address(localPositionModule), upperTakerRisk);

        uint256 specId1 = _helperRecordFillLocal(
            localPositionModule,
            1,
            address(mockScorer),
            42,
            PositionType.Upper,
            address(this),
            upperMakerRisk,
            upperTaker,
            upperTakerRisk
        );

        // --- Lower maker wins scenario (separate speculation) ---
        uint256 lowerMakerRisk = 10_000_000;
        uint256 lowerTakerRisk = 8_000_000;
        address lowerTaker = address(0xCAFF);

        token.approve(address(localPositionModule), lowerMakerRisk);
        token.transfer(lowerTaker, lowerTakerRisk);
        vm.prank(lowerTaker);
        token.approve(address(localPositionModule), lowerTakerRisk);

        uint256 specId2 = _helperRecordFillLocal(
            localPositionModule,
            1,
            address(mockScorer),
            43,
            PositionType.Lower,
            address(this),
            lowerMakerRisk,
            lowerTaker,
            lowerTakerRisk
        );

        // Settle both
        vm.warp(block.timestamp + 2 hours);
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        mockSpeculationModule.settleSpeculation(specId1);
        mockSpeculationModule.settleSpeculation(specId2);

        // Upper wins for specId1
        mockSpeculationModule.setSpeculationWinSide(specId1, WinSide.Away);

        // Get maker positions for exact payout calculation
        Position memory posUpper = localPositionModule.getPosition(
            specId1,
            address(this),
            PositionType.Upper
        );

        // Winner gets exactly riskAmount + profitAmount
        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(specId1, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(
            balAfter - balBefore,
            posUpper.riskAmount + posUpper.profitAmount,
            "Upper winner payout should be riskAmount + profitAmount"
        );

        // Loser (taker) tries to claim — should revert with NoPayout
        vm.prank(upperTaker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        localPositionModule.claimPosition(specId1, PositionType.Lower);

        // Home wins for specId2 (Lower maker wins)
        mockSpeculationModule.setSpeculationWinSide(specId2, WinSide.Home);
        Position memory posLower = localPositionModule.getPosition(
            specId2,
            address(this),
            PositionType.Lower
        );

        balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(specId2, PositionType.Lower);
        balAfter = token.balanceOf(address(this));
        assertEq(
            balAfter - balBefore,
            posLower.riskAmount + posLower.profitAmount,
            "Lower winner payout should be riskAmount + profitAmount"
        );

        // Loser (taker) tries to claim — should revert with NoPayout
        vm.prank(lowerTaker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        localPositionModule.claimPosition(specId2, PositionType.Upper);
    }

    // =========================================================================
    // TASK 6: MISSING REVERT TESTS
    // =========================================================================

    /// @notice claimPosition reverts with NotSettled when speculation is still Open
    function testClaimPosition_RevertsIfNotSettled() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(0x1234),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Speculation is still Open — claim should revert
        vm.expectRevert(PositionModule.PositionModule__NotSettled.selector);
        positionModule.claimPosition(specId, PositionType.Upper);
    }

    // Note: Double claim prevention test already exists as
    // testClaimPosition_RevertsWithAlreadyClaimed_OnDoubleClaim — skipping duplicate.

    // =========================================================================
    // TASK 7: FORFEIT PAYOUT PATH + PUSH/VOID/FORFEIT FOR BOTH MAKER AND TAKER
    // =========================================================================

    /// @notice Push: both maker AND taker get exactly riskAmount back
    function testClaimPosition_Push_BothMakerAndTaker() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPM = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPM)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(localPM), makerRisk);
        vm.prank(taker);
        token.approve(address(localPM), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            localPM, 1, address(mockScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, c);
        mockSpeculationModule.settleSpeculation(specId);
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Push);

        // Maker claims — gets exactly riskAmount back
        uint256 balBefore = token.balanceOf(address(this));
        localPM.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, makerRisk, "Push: maker gets riskAmount back");

        // Taker claims — gets exactly riskAmount back
        balBefore = token.balanceOf(taker);
        vm.prank(taker);
        localPM.claimPosition(specId, PositionType.Lower);
        balAfter = token.balanceOf(taker);
        assertEq(balAfter - balBefore, takerRisk, "Push: taker gets riskAmount back");
    }

    /// @notice Void: both maker AND taker get exactly riskAmount back
    function testClaimPosition_Void_BothMakerAndTaker() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPM = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPM)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(localPM), makerRisk);
        vm.prank(taker);
        token.approve(address(localPM), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            localPM, 1, address(mockScorer), 50,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, c);
        mockSpeculationModule.settleSpeculation(specId);
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Void);

        // Maker claims
        uint256 balBefore = token.balanceOf(address(this));
        localPM.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, makerRisk, "Void: maker gets riskAmount back");

        // Taker claims
        balBefore = token.balanceOf(taker);
        vm.prank(taker);
        localPM.claimPosition(specId, PositionType.Lower);
        balAfter = token.balanceOf(taker);
        assertEq(balAfter - balBefore, takerRisk, "Void: taker gets riskAmount back");
    }

    /// @notice Forfeit: both maker AND taker get exactly riskAmount back
    function testClaimPosition_Forfeit_BothMakerAndTaker() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPM = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPM)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(localPM), makerRisk);
        vm.prank(taker);
        token.approve(address(localPM), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            localPM, 1, address(mockScorer), 51,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, c);
        mockSpeculationModule.settleSpeculation(specId);
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Forfeit);

        // Maker claims — gets exactly riskAmount back
        uint256 balBefore = token.balanceOf(address(this));
        localPM.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, makerRisk, "Forfeit: maker gets riskAmount back");

        // Taker claims — gets exactly riskAmount back
        balBefore = token.balanceOf(taker);
        vm.prank(taker);
        localPM.claimPosition(specId, PositionType.Lower);
        balAfter = token.balanceOf(taker);
        assertEq(balAfter - balBefore, takerRisk, "Forfeit: taker gets riskAmount back");
    }

    // =========================================================================
    // TASK 9: EXERCISE CONTRIBUTION PATH
    // =========================================================================

    /// @notice recordFill with nonzero contributions transfers contribution token to receiver
    function testRecordFill_WithContributions() public {
        // Deploy a separate contribution token (different from the position token)
        MockERC20 contributionToken = new MockERC20();
        address contributionReceiver = address(0xFACE);

        // Set up contribution module with token and receiver
        contributionModule.setContributionToken(address(contributionToken));
        contributionModule.setContributionReceiver(contributionReceiver);

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;
        uint256 makerContribution = 500_000; // 0.5 USDC contribution
        uint256 takerContribution = 400_000; // 0.4 USDC contribution

        // Approve position token for both maker and taker
        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        // Fund and approve contribution token for maker and taker
        contributionToken.transfer(address(this), makerContribution);
        contributionToken.approve(address(contributionModule), makerContribution);

        contributionToken.transfer(taker, takerContribution);
        vm.prank(taker);
        contributionToken.approve(address(contributionModule), takerContribution);

        // Record balances before
        uint256 receiverBalBefore = contributionToken.balanceOf(contributionReceiver);

        // Call recordFill with contributions
        uint256 specId = positionModule.recordFill(
            1, address(0x1234), 42, leaderboardId,
            PositionType.Upper, address(this), makerRisk,
            taker, takerRisk,
            makerContribution, takerContribution
        );

        // Verify positions are correct (contributions don't affect risk/profit)
        Position memory makerPos = positionModule.getPosition(
            specId, address(this), PositionType.Upper
        );
        assertEq(makerPos.riskAmount, makerRisk, "Maker riskAmount unaffected by contribution");
        assertEq(makerPos.profitAmount, takerRisk, "Maker profitAmount unaffected by contribution");

        Position memory takerPos = positionModule.getPosition(
            specId, taker, PositionType.Lower
        );
        assertEq(takerPos.riskAmount, takerRisk, "Taker riskAmount unaffected by contribution");
        assertEq(takerPos.profitAmount, makerRisk, "Taker profitAmount unaffected by contribution");

        // Verify contribution token was transferred to receiver
        uint256 receiverBalAfter = contributionToken.balanceOf(contributionReceiver);
        assertEq(
            receiverBalAfter - receiverBalBefore,
            makerContribution + takerContribution,
            "Receiver should have received both contributions"
        );
    }

    // =========================================================================
    // TASK 11: PARTIAL TRANSFER TEST
    // =========================================================================

    /// @notice Partial transfer: transfer half, settle, both sender and receiver claim correctly
    function testTransferPosition_PartialTransfer_BothClaim() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPM = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPM)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 makerRisk = 100_000_000; // 100 USDC (100e6)
        uint256 takerRisk = 80_000_000;  // 80 USDC (80e6)

        token.approve(address(localPM), makerRisk);
        vm.prank(taker);
        token.approve(address(localPM), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            localPM, 1, address(mockScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        // Verify initial position: risk=100e6, profit=80e6
        Position memory origPos = localPM.getPosition(specId, address(this), PositionType.Upper);
        assertEq(origPos.riskAmount, 100_000_000);
        assertEq(origPos.profitAmount, 80_000_000);

        // Transfer half to another address
        address receiver = address(0xAAAA);
        MockMarket market = new MockMarket(address(localPM));
        core.setMarketRole(address(market), true);

        market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            receiver,
            50_000_000, // half risk
            40_000_000  // half profit
        );

        // Verify sender has remainder: risk=50e6, profit=40e6
        Position memory senderPos = localPM.getPosition(specId, address(this), PositionType.Upper);
        assertEq(senderPos.riskAmount, 50_000_000, "Sender risk should be 50e6");
        assertEq(senderPos.profitAmount, 40_000_000, "Sender profit should be 40e6");

        // Verify receiver has: risk=50e6, profit=40e6
        Position memory receiverPos = localPM.getPosition(specId, receiver, PositionType.Upper);
        assertEq(receiverPos.riskAmount, 50_000_000, "Receiver risk should be 50e6");
        assertEq(receiverPos.profitAmount, 40_000_000, "Receiver profit should be 40e6");

        // Settle as Upper wins (Away)
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 100, homeScore: 90, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, c);
        mockSpeculationModule.settleSpeculation(specId);
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Away);

        // Sender claims: payout = 50e6 + 40e6 = 90e6
        uint256 balBefore = token.balanceOf(address(this));
        localPM.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 90_000_000, "Sender payout should be 50e6 + 40e6 = 90e6");

        // Receiver claims: payout = 50e6 + 40e6 = 90e6
        balBefore = token.balanceOf(receiver);
        vm.prank(receiver);
        localPM.claimPosition(specId, PositionType.Upper);
        balAfter = token.balanceOf(receiver);
        assertEq(balAfter - balBefore, 90_000_000, "Receiver payout should be 50e6 + 40e6 = 90e6");
    }

    // =========================================================================
    // TASK 19: POSITION AGGREGATION TEST
    // =========================================================================

    /// @notice Same user, same speculation, same side, three fills — positions aggregate
    function testRecordFill_PositionAggregation_ThreeFills() public {
        MockSpeculationModule mockSpeculationModule = new MockSpeculationModule(
            address(core),
            6
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(mockSpeculationModule)
        );
        PositionModule localPM = new PositionModule(
            address(core),
            address(token)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(localPM)
        );

        MockScorerModule mockScorer = new MockScorerModule();

        // Three fills with different risk/profit amounts
        uint256 makerRisk1 = 10_000_000;
        uint256 takerRisk1 = 8_000_000;
        uint256 makerRisk2 = 5_000_000;
        uint256 takerRisk2 = 4_000_000;
        uint256 makerRisk3 = 7_000_000;
        uint256 takerRisk3 = 6_000_000;

        address taker1 = address(0xCA01);
        address taker2 = address(0xCA02);
        address taker3 = address(0xCA03);

        // Fund takers
        token.transfer(taker1, takerRisk1);
        token.transfer(taker2, takerRisk2);
        token.transfer(taker3, takerRisk3);

        // Fill 1
        token.approve(address(localPM), makerRisk1);
        vm.prank(taker1);
        token.approve(address(localPM), takerRisk1);

        uint256 specId = _helperRecordFillLocal(
            localPM, 1, address(mockScorer), 42,
            PositionType.Upper, address(this), makerRisk1, taker1, takerRisk1
        );

        // Fill 2 — same speculation (same contest/scorer/lineTicks)
        token.approve(address(localPM), makerRisk2);
        vm.prank(taker2);
        token.approve(address(localPM), takerRisk2);

        localPM.recordFill(
            1, address(mockScorer), 42, leaderboardId,
            PositionType.Upper, address(this), makerRisk2,
            taker2, takerRisk2, 0, 0
        );

        // Fill 3 — same speculation
        token.approve(address(localPM), makerRisk3);
        vm.prank(taker3);
        token.approve(address(localPM), takerRisk3);

        localPM.recordFill(
            1, address(mockScorer), 42, leaderboardId,
            PositionType.Upper, address(this), makerRisk3,
            taker3, takerRisk3, 0, 0
        );

        // Verify aggregated position
        uint256 totalMakerRisk = makerRisk1 + makerRisk2 + makerRisk3; // 22M
        uint256 totalMakerProfit = takerRisk1 + takerRisk2 + takerRisk3; // 18M

        Position memory makerPos = localPM.getPosition(specId, address(this), PositionType.Upper);
        assertEq(makerPos.riskAmount, totalMakerRisk, "riskAmount == sum of all fills' risk");
        assertEq(makerPos.profitAmount, totalMakerProfit, "profitAmount == sum of all fills' profit");

        // Settle and claim — payout should be totalRisk + totalProfit
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = Contest({
            awayScore: 100, homeScore: 90, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, c);
        mockSpeculationModule.settleSpeculation(specId);
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Away);

        uint256 balBefore = token.balanceOf(address(this));
        localPM.claimPosition(specId, PositionType.Upper);
        uint256 payout = token.balanceOf(address(this)) - balBefore;
        assertEq(
            payout,
            totalMakerRisk + totalMakerProfit,
            "Claim payout == totalRiskAmount + totalProfitAmount"
        );
    }
}
