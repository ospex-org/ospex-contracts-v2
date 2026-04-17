// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] OddsPair system has been removed. Positions use riskAmount/profitAmount directly.

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionType, Contest, ContestStatus, Position, WinSide, LeagueId, Speculation, SpeculationStatus, FeeType, Leaderboard} from "../../src/core/OspexTypes.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockSpeculationModule} from "../mocks/MockSpeculationModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

contract MockLeaderboardModule {
    mapping(uint256 => Leaderboard) private leaderboards;
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedRisk;
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedProfit;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }

    function setLockedAmounts(
        uint256 speculationId, address user, PositionType positionType,
        uint256 risk, uint256 profit
    ) external {
        s_lockedRisk[speculationId][user][positionType] = risk;
        s_lockedProfit[speculationId][user][positionType] = profit;
    }
}

/// @dev Bundles a fresh core + modules for per-test isolation.
///      Using a struct keeps 1 stack slot instead of 5 separate locals,
///      which avoids Yul stack-too-deep under --ir-minimum.
struct LocalEnv {
    OspexCore core;
    MockSpeculationModule specMod;
    PositionModule posMod;
    MockMarket market;
    TreasuryModule treasury;
}

contract PositionModuleTest is Test {
    using stdStorage for StdStorage;

    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;

    address user = address(0xBEEF);
    address taker = address(0xCAFE);
    address protocolReceiver = address(0xFEED);

    MockContestModule mockContestModule;
    MockLeaderboardModule mockLeaderboardModule;
    MockScorerModule defaultScorer;

    // SpeculationModule constructor params
    uint32 constant VOID_COOLDOWN = 3 days;

    // TreasuryModule fee rates (real production fees)
    uint256 constant CONTEST_FEE = 1_000_000; // 1.00 USDC
    uint256 constant SPEC_FEE = 500_000;      // 0.50 USDC (split 250k maker / 250k taker)
    uint256 constant LB_FEE = 500_000;        // 0.50 USDC

    // MockMarket for transfer tests — registered as SECONDARY_MARKET_MODULE
    MockMarket defaultMarket;

    /// @notice Helper: bootstrap a fresh OspexCore with all 12 modules and finalize
    /// @dev The scorer registered as SPREAD_SCORER_MODULE is `scorer_`. The caller
    ///      must create its own SpeculationModule, PositionModule, and MockMarket
    ///      bound to the returned core.
    function _buildModuleArrays(
        address specMod,
        address posMod,
        address market,
        address scorer_,
        address treasury_
    ) internal view returns (bytes32[] memory types2, address[] memory addrs2) {
        types2 = new bytes32[](12);
        addrs2 = new address[](12);
        types2[0]  = keccak256("CONTEST_MODULE");           addrs2[0]  = address(mockContestModule);
        types2[1]  = keccak256("SPECULATION_MODULE");        addrs2[1]  = specMod;
        types2[2]  = keccak256("POSITION_MODULE");           addrs2[2]  = posMod;
        types2[3]  = keccak256("MATCHING_MODULE");           addrs2[3]  = address(this);
        types2[4]  = keccak256("ORACLE_MODULE");             addrs2[4]  = address(0xD001);
        types2[5]  = keccak256("TREASURY_MODULE");           addrs2[5]  = treasury_;
        types2[6]  = keccak256("LEADERBOARD_MODULE");        addrs2[6]  = address(mockLeaderboardModule);
        types2[7]  = keccak256("RULES_MODULE");              addrs2[7]  = address(0xD002);
        types2[8]  = keccak256("SECONDARY_MARKET_MODULE");   addrs2[8]  = market;
        types2[9]  = keccak256("MONEYLINE_SCORER_MODULE");   addrs2[9]  = address(0xCC01);
        types2[10] = keccak256("SPREAD_SCORER_MODULE");      addrs2[10] = scorer_;
        types2[11] = keccak256("TOTAL_SCORER_MODULE");       addrs2[11] = address(0xCC02);
    }

    function _bootstrapCore(
        OspexCore _core,
        address specMod,
        address posMod,
        address market,
        address scorer_,
        address treasury_
    ) internal {
        (bytes32[] memory types2, address[] memory addrs2) = _buildModuleArrays(specMod, posMod, market, scorer_, treasury_);
        _core.bootstrapModules(types2, addrs2);
        _core.finalize();
    }

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();
        // Fund user
        token.transfer(user, 1_000_000_000);
        // Fund taker
        token.transfer(taker, 500_000_000);

        speculationModule = new SpeculationModule(address(core), VOID_COOLDOWN);
        positionModule = new PositionModule(
            address(core),
            address(token)
        );
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver, CONTEST_FEE, SPEC_FEE, LB_FEE);

        // Register a mock contest module so SpeculationModule can call getContest
        mockContestModule = new MockContestModule();

        // Register a mock leaderboard module so TreasuryModule can call getLeaderboard
        mockLeaderboardModule = new MockLeaderboardModule();

        // Deploy a default scorer (a real contract so settleSpeculation can call determineWinSide)
        defaultScorer = new MockScorerModule();

        // MockMarket for secondary market transfer tests
        defaultMarket = new MockMarket(address(positionModule));

        // Bootstrap all 12 modules using the helper, then finalize
        _bootstrapCore(
            core,
            address(speculationModule),
            address(positionModule),
            address(defaultMarket),
            address(defaultScorer),
            address(treasuryModule)
        );

        // Set up default verified contests for all tests
        Contest memory defaultContest = Contest({
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
        mockContestModule.setContest(1, defaultContest);
        mockContestModule.setContest(2, defaultContest);
        mockContestModule.setContest(3, defaultContest);
        mockContestModule.setContestStartTime(1, uint32(block.timestamp));
        mockContestModule.setContestStartTime(2, uint32(block.timestamp));
        mockContestModule.setContestStartTime(3, uint32(block.timestamp));

        // Approve TreasuryModule for fee payments (speculation creation split fee)
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(user);
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(taker);
        token.approve(address(treasuryModule), type(uint256).max);
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
            contestId, scorer, lineTicks,
            makerPositionType, maker, makerRisk,
            _taker, takerRisk
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
            contestId, scorer, lineTicks,
            makerPositionType, maker, makerRisk,
            _taker, takerRisk
        );
    }

    /// @notice Approve a test-local TreasuryModule for all standard test addresses
    function _approveTreasury(TreasuryModule treasury) internal {
        token.approve(address(treasury), type(uint256).max);
        vm.prank(user);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(taker);
        token.approve(address(treasury), type(uint256).max);
    }

    /// @notice Creates a fresh core + MockSpeculationModule + PositionModule + MockMarket + TreasuryModule,
    ///         bootstraps all 12 modules, and approves TreasuryModule for standard test addresses.
    function _createLocalEnv() internal returns (LocalEnv memory env) {
        env.core = new OspexCore();
        env.specMod = new MockSpeculationModule(address(env.core), VOID_COOLDOWN);
        env.posMod = new PositionModule(address(env.core), address(token));
        env.market = new MockMarket(address(env.posMod));
        env.treasury = new TreasuryModule(address(env.core), address(token), protocolReceiver, CONTEST_FEE, SPEC_FEE, LB_FEE);
        _bootstrapCore(env.core, address(env.specMod), address(env.posMod), address(env.market), address(defaultScorer), address(env.treasury));
        _approveTreasury(env.treasury);
    }

    /// @notice Helper to create a scored Contest struct (reduces stack depth vs inline struct literal)
    function _scoredContest(uint32 awayScore, uint32 homeScore) internal view returns (Contest memory) {
        return Contest({
            awayScore: awayScore, homeScore: homeScore, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0), scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
    }

    /// @notice Helper to create a verified Contest struct
    function _verifiedContest() internal view returns (Contest memory) {
        return Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0), scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
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
            address(defaultScorer),
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
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            8_000_000
        );
    }

    function testRecordFill_RevertsIfSpeculationNotOpen() public {
        uint32 startTime = uint32(block.timestamp + 1 hours);

        // First create a speculation via recordFill using an approved scorer
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Settle the speculation
        vm.warp(startTime + 2 hours);
        Contest memory contest = _scoredContest(1, 0);
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
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );
    }


    // --- recordFill with auto-speculation creation TESTS ---

    function testRecordFill_CreatesSpeculationAutomatically() public {
        // Verify speculation doesn't exist yet
        uint256 existingSpecId = speculationModule.getSpeculationId(
            1, // contestId
            address(defaultScorer), // scorer
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
            address(defaultScorer), // scorer
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
        assertEq(spec.speculationScorer, address(defaultScorer));
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

        // Create matched pair: maker=this (Upper), taker=0xCAFE (Lower)
        // At 1.80 odds: makerRisk=10M, takerRisk=8M
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Settle speculation (Away wins = Upper wins)
        vm.warp(futureTime + 2 hours);
        Contest memory contest = _scoredContest(1, 0);
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

        // Create matched pair
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        vm.warp(futureTime + 2 hours);
        Contest memory contest = _scoredContest(1, 0);
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

    function testClaimPosition_PushAndVoid() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);
        uint32 futureTime2 = uint32(block.timestamp + 2 hours);

        // Use MockSpeculationModule for this test — need a fresh core since the first is finalized
        LocalEnv memory env = _createLocalEnv();

        // Reset to a reasonable starting time
        vm.warp(1672531200); // Jan 1, 2023

        // --- Test Push scenario ---
        // At 1.80 odds: maker risks 10M, taker risks 8M
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(env.posMod), makerRisk);
        vm.prank(taker);
        token.approve(address(env.posMod), takerRisk);

        uint256 specIdPush = _helperRecordFillLocal(
            env.posMod,
            1,
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        vm.warp(futureTime + 2 hours);
        Contest memory contestPush = _scoredContest(1, 0);
        mockContestModule.setContest(1, contestPush);

        env.specMod.settleSpeculation(specIdPush);
        env.specMod.setSpeculationWinSide(specIdPush, WinSide.Push);

        // On Push: payout = riskAmount (original stake back)
        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(
            specIdPush,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000_000, "Push should return riskAmount (10M)");

        // --- Test Void scenario ---
        vm.warp(1672531200 + 1 days); // Jan 2, 2023
        futureTime2 = uint32(block.timestamp + 1 hours);

        // Create matched pair for Void test
        token.approve(address(env.posMod), makerRisk);
        vm.prank(taker);
        token.approve(address(env.posMod), takerRisk);

        uint256 specIdVoid = _helperRecordFillLocal(
            env.posMod,
            2,
            address(defaultScorer),
            43,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        vm.warp(futureTime2 + 2 hours);
        Contest memory contestVoid = _scoredContest(1, 0);
        mockContestModule.setContest(2, contestVoid);

        env.specMod.settleSpeculation(specIdVoid);
        env.specMod.setSpeculationWinSide(specIdVoid, WinSide.Void);

        balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(
            specIdVoid,
            PositionType.Upper
        );
        balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000_000, "Void should return riskAmount (10M)");
    }

    function testClaimPosition_WinLossScenarios() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

        uint256 tokenUnit = 10_000_000; // 10 USDC

        // --- Create Upper position ---
        // At 1.10 odds: maker risks 10M, taker risks 1M (profit for maker = 1M)
        uint256 upperTakerRisk = 1_000_000;
        address upperTaker = address(0xCAFE);

        token.approve(address(env.posMod), tokenUnit);
        token.transfer(upperTaker, upperTakerRisk);
        vm.prank(upperTaker);
        token.approve(address(env.posMod), upperTakerRisk);

        uint256 specId1 = _helperRecordFillLocal(
            env.posMod,
            1,
            address(defaultScorer),
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

        token.approve(address(env.posMod), tokenUnit);
        token.transfer(lowerTaker, lowerTakerRisk + SPEC_FEE);
        vm.prank(lowerTaker);
        token.approve(address(env.posMod), lowerTakerRisk);
        vm.prank(lowerTaker);
        token.approve(address(env.treasury), type(uint256).max);

        uint256 specId2 = _helperRecordFillLocal(
            env.posMod,
            1,
            address(defaultScorer),
            43,
            PositionType.Lower,
            address(this),
            tokenUnit,
            lowerTaker,
            lowerTakerRisk
        );

        vm.warp(futureTime + 2 hours);
        Contest memory contest = _scoredContest(1, 0);
        mockContestModule.setContest(1, contest);
        env.specMod.settleSpeculation(specId1);
        env.specMod.settleSpeculation(specId2);

        // Test win for Upper (Away)
        env.specMod.setSpeculationWinSide(specId1, WinSide.Away);
        Position memory posUpper = env.posMod.getPosition(
            specId1,
            address(this),
            PositionType.Upper
        );
        emit log_named_uint("riskAmount (Upper win)", posUpper.riskAmount);
        emit log_named_uint("positionType (Upper win)", uint(posUpper.positionType));

        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(
            specId1,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Upper win)", balAfter - balBefore);
        // Winner gets riskAmount + profitAmount
        assertGt(balAfter - balBefore, tokenUnit);

        // Test win for Lower (Home)
        env.specMod.setSpeculationWinSide(specId2, WinSide.Home);
        Position memory posLower = env.posMod.getPosition(
            specId2,
            address(this),
            PositionType.Lower
        );
        emit log_named_uint("riskAmount (Lower win)", posLower.riskAmount);
        emit log_named_uint("positionType (Lower win)", uint(posLower.positionType));

        balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(
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
            address(defaultScorer),
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

        // Use the default market (already registered as SECONDARY_MARKET_MODULE)
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
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
            address(defaultScorer),
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

        // Create a MockMarket that is NOT registered as SECONDARY_MARKET_MODULE
        MockMarket unauthorizedMarket = new MockMarket(address(positionModule));
        vm.expectRevert(
            PositionModule.PositionModule__UnauthorizedMarket.selector
        );
        vm.prank(address(unauthorizedMarket));
        unauthorizedMarket.transferPosition(
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
            address(defaultScorer),
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

        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            user,
            makerPos.riskAmount + 1,
            makerPos.profitAmount
        );
    }

    // --- TRANSFER POSITION: CONTEST-SCORED CHECK ---

    function testTransferPosition_RevertsIfContestAlreadyScored() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        // Score the contest (but DON'T settle the speculation)
        Contest memory scoredContest = _scoredContest(1, 0);
        mockContestModule.setContest(1, scoredContest);

        // Transfer should revert because contest is scored (prevents front-running settlement)
        Position memory makerPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        vm.expectRevert(PositionModule.PositionModule__ContestAlreadyScored.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, address(this), PositionType.Upper, user,
            makerPos.riskAmount, makerPos.profitAmount
        );
    }

    function testTransferPosition_RevertsIfContestVoided() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        // Void the contest (but DON'T settle the speculation)
        Contest memory voidedContest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Voided, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0), scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, voidedContest);

        // Transfer should revert because contest is terminal (voided)
        Position memory makerPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        vm.expectRevert(PositionModule.PositionModule__ContestAlreadyScored.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, address(this), PositionType.Upper, user,
            makerPos.riskAmount, makerPos.profitAmount
        );
    }

    // --- CLAIM POSITION EDGE CASE TESTS ---

    /**
     * @notice Test that claimPosition reverts with NoPayout when riskAmount=0
     * @dev This scenario occurs when a user transfers their entire position via secondary market
     */
    function testClaimPosition_RevertsWithNoPayout_WhenBothAmountsZero() public {
        // Need fresh core for MockSpeculationModule + local market
        LocalEnv memory env = _createLocalEnv();

        // Create matched pair: maker=this, taker=taker
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 10_000_000; // At 2.00 odds

        token.approve(address(env.posMod), makerRisk);
        vm.prank(taker);
        token.approve(address(env.posMod), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            env.posMod,
            1,
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Transfer entire position to another user via secondary market
        address buyer = address(0xBEEF);
        env.market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            buyer,
            10_000_000,
            10_000_000
        );

        // Verify maker's position now has riskAmount=0
        Position memory makerPos = env.posMod.getPosition(
            specId,
            address(this),
            PositionType.Upper
        );
        assertEq(makerPos.riskAmount, 0, "riskAmount should be 0 after full transfer");

        // Settle speculation
        vm.warp(block.timestamp + 2 hours);
        Contest memory contest = _scoredContest(100, 90);
        mockContestModule.setContest(1, contest);
        env.specMod.settleSpeculation(specId);

        // Attempt to claim should revert with NoPayout
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        env.posMod.claimPosition(specId, PositionType.Upper);
    }

    /**
     * @notice Test that calling claimPosition twice reverts with AlreadyClaimed
     */
    function testClaimPosition_RevertsWithAlreadyClaimed_OnDoubleClaim() public {
        // Create matched pair
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Settle speculation
        vm.warp(block.timestamp + 2 hours);
        Contest memory contest = _scoredContest(100, 90);
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
        token.transfer(taker1, buyerTakerRisk + SPEC_FEE);
        vm.prank(taker1);
        token.approve(address(positionModule), buyerTakerRisk);
        vm.prank(taker1);
        token.approve(address(treasuryModule), type(uint256).max);

        uint256 specId = _helperRecordFill(
            1,
            address(defaultScorer),
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
            1, address(defaultScorer), 42,
            PositionType.Upper, seller, sellerRisk,
            taker2, sellerTakerRisk
        );

        // Step 3: Transfer seller's position to buyer
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
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
        Contest memory c = _scoredContest(100, 90);
        mockContestModule.setContest(contestId, c);
        speculationModule.settleSpeculation(specId);
    }

    /// @notice Helper: settle a speculation as Home-wins (Lower wins)
    function _settleAsHomeWins(uint256 /* specId */, uint256 contestId) internal {
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = _scoredContest(90, 100);
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
            1, address(defaultScorer), 200,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        uint256 halfFee = SPEC_FEE / 2;
        assertEq(token.balanceOf(address(this)), makerBalBefore - makerRisk - halfFee, "maker balance wrong");
        assertEq(token.balanceOf(taker), takerBalBefore - takerRisk - (SPEC_FEE - halfFee), "taker balance wrong");

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
            1, address(defaultScorer), 201,
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
            1, address(defaultScorer), 202,
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
            1, address(defaultScorer), 203,
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
            1, address(defaultScorer), 204,
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
            1, address(defaultScorer), 250,
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
            1, address(defaultScorer), 250,
            PositionType.Upper, address(this), makerRisk2,
            taker2, takerRisk2
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
            1, address(defaultScorer), 220,
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
            1, address(defaultScorer), 221,
            PositionType.Upper, address(this), makerRisk,
            taker, takerRisk
        );
    }

    // --- Claim payouts at various risk/profit ratios ---

    /// @notice Maker (Upper) wins — verify payout = riskAmount + profitAmount
    function testClaimPosition_MakerWins() public {
        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 230,
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

        // Need fresh core with mockScorer registered as scorer
        OspexCore core2 = new OspexCore();
        PositionModule posMod2;
        SpeculationModule specMod2;
        uint256 specId;
        uint256 makerRisk = 5_376_345;
        uint256 takerRisk = 5_000_000;
        {
            specMod2 = new SpeculationModule(address(core2), VOID_COOLDOWN);
            posMod2 = new PositionModule(address(core2), address(token));
            MockMarket localMarket = new MockMarket(address(posMod2));
            TreasuryModule treasury2 = new TreasuryModule(address(core2), address(token), protocolReceiver, CONTEST_FEE, SPEC_FEE, LB_FEE);
            _bootstrapCore(core2, address(specMod2), address(posMod2), address(localMarket), address(mockScorer), address(treasury2));
            _approveTreasury(treasury2);

            token.approve(address(posMod2), makerRisk);
            vm.prank(taker);
            token.approve(address(posMod2), takerRisk);

            specId = posMod2.recordFill(
                1, address(mockScorer), 231,
                PositionType.Upper, address(this), makerRisk, taker, takerRisk
            );
        }

        // Settle as home wins
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = _scoredContest(90, 100);
        mockContestModule.setContest(1, c);
        specMod2.settleSpeculation(specId);

        uint256 balBefore = token.balanceOf(taker);
        vm.prank(taker);
        posMod2.claimPosition(specId, PositionType.Lower);
        uint256 payout = token.balanceOf(taker) - balBefore;

        // Taker payout = taker stake + maker stake = same total pool
        assertEq(payout, takerRisk + makerRisk, "taker payout = takerRisk + makerRisk");
    }

    /// @notice Claim test across multiple risk/profit ratios — winner takes pool
    function testClaimPosition_MultipleRatios_WinnerTakesPool() public {
        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

        // Risk/profit ratios corresponding to various odds
        uint256[4] memory makerRisks = [uint256(10_000_000), uint256(10_000_000), uint256(10_000_000), uint256(10_000_000)];
        uint256[4] memory takerRisks = [uint256(9_300_000), uint256(8_700_000), uint256(10_800_000), uint256(11_500_000)];

        for (uint256 i = 0; i < makerRisks.length; i++) {
            int32 lineTicks = int32(int256(240 + i));

            address _taker = address(uint160(0xCA00 + i));
            token.transfer(_taker, takerRisks[i] + SPEC_FEE);
            token.approve(address(env.posMod), makerRisks[i]);
            vm.prank(_taker);
            token.approve(address(env.posMod), takerRisks[i]);
            vm.prank(_taker);
            token.approve(address(env.treasury), type(uint256).max);

            // Reset contest to Verified before each fill so speculation creation is allowed
            Contest memory verified = _verifiedContest();
            mockContestModule.setContest(1, verified);

            uint256 specId = _helperRecordFillLocal(
                env.posMod, 1, address(defaultScorer), lineTicks,
                PositionType.Upper, address(this), makerRisks[i],
                _taker, takerRisks[i]
            );

            // Score the contest, then settle as Away wins (Upper wins)
            Contest memory c = _scoredContest(100, 90);
            mockContestModule.setContest(1, c);
            vm.warp(block.timestamp + 2 hours);
            env.specMod.settleSpeculation(specId);

            uint256 balBefore = token.balanceOf(address(this));
            env.posMod.claimPosition(specId, PositionType.Upper);
            uint256 payout = token.balanceOf(address(this)) - balBefore;

            // Winner gets the entire pool
            assertEq(payout, makerRisks[i] + takerRisks[i], string.concat("payout mismatch at index ", vm.toString(i)));

            // Loser gets nothing
            vm.prank(_taker);
            vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
            env.posMod.claimPosition(specId, PositionType.Lower);
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
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.expectRevert(PositionModule.PositionModule__InvalidAddress.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            address(this), // self-transfer
            makerRisk,
            takerRisk
        );
    }

    function testTransferPosition_RevertsOnZeroAddress() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.expectRevert(PositionModule.PositionModule__InvalidAddress.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            address(0), // zero address
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
            address(defaultScorer),
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
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1,
            address(defaultScorer),
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
            address(defaultScorer),
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

        vm.expectEmit(true, true, true, true, address(positionModule));
        emit PositionModule.PositionTransferred(
            specId,
            address(this), // from
            PositionType.Upper,
            user, // to
            makerPos.riskAmount,
            makerPos.profitAmount
        );

        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            user,
            makerPos.riskAmount,
            makerPos.profitAmount
        );
    }

    // =========================================================================
    // TASK 5: FIX testClaimPosition_WinLossScenarios -- exact payout + loser revert
    // (Original test replaced above with assertGt; new version uses exact assertEq
    //  and adds loser claim revert path. Added as a separate test to preserve original.)
    // =========================================================================

    /// @notice Win/loss scenarios with exact payout assertions and loser revert
    function testClaimPosition_WinLossScenarios_ExactPayout() public {
        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

        // --- Upper maker wins scenario ---
        uint256 upperMakerRisk = 10_000_000;
        uint256 upperTakerRisk = 1_000_000;
        address upperTaker = address(0xCAFE);

        token.approve(address(env.posMod), upperMakerRisk);
        token.transfer(upperTaker, upperTakerRisk);
        vm.prank(upperTaker);
        token.approve(address(env.posMod), upperTakerRisk);

        uint256 specId1 = _helperRecordFillLocal(
            env.posMod,
            1,
            address(defaultScorer),
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

        token.approve(address(env.posMod), lowerMakerRisk);
        token.transfer(lowerTaker, lowerTakerRisk + SPEC_FEE);
        vm.prank(lowerTaker);
        token.approve(address(env.posMod), lowerTakerRisk);
        vm.prank(lowerTaker);
        token.approve(address(env.treasury), type(uint256).max);

        uint256 specId2 = _helperRecordFillLocal(
            env.posMod,
            1,
            address(defaultScorer),
            43,
            PositionType.Lower,
            address(this),
            lowerMakerRisk,
            lowerTaker,
            lowerTakerRisk
        );

        // Settle both
        vm.warp(block.timestamp + 2 hours);
        Contest memory contest = _scoredContest(1, 0);
        mockContestModule.setContest(1, contest);
        env.specMod.settleSpeculation(specId1);
        env.specMod.settleSpeculation(specId2);

        // Upper wins for specId1
        env.specMod.setSpeculationWinSide(specId1, WinSide.Away);

        // Get maker positions for exact payout calculation
        Position memory posUpper = env.posMod.getPosition(
            specId1,
            address(this),
            PositionType.Upper
        );

        // Winner gets exactly riskAmount + profitAmount
        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(specId1, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(
            balAfter - balBefore,
            posUpper.riskAmount + posUpper.profitAmount,
            "Upper winner payout should be riskAmount + profitAmount"
        );

        // Loser (taker) tries to claim -- should revert with NoPayout
        vm.prank(upperTaker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        env.posMod.claimPosition(specId1, PositionType.Lower);

        // Home wins for specId2 (Lower maker wins)
        env.specMod.setSpeculationWinSide(specId2, WinSide.Home);
        Position memory posLower = env.posMod.getPosition(
            specId2,
            address(this),
            PositionType.Lower
        );

        balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(specId2, PositionType.Lower);
        balAfter = token.balanceOf(address(this));
        assertEq(
            balAfter - balBefore,
            posLower.riskAmount + posLower.profitAmount,
            "Lower winner payout should be riskAmount + profitAmount"
        );

        // Loser (taker) tries to claim -- should revert with NoPayout
        vm.prank(lowerTaker);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        env.posMod.claimPosition(specId2, PositionType.Upper);
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
            address(defaultScorer),
            42,
            PositionType.Upper,
            address(this),
            makerRisk,
            taker,
            takerRisk
        );

        // Speculation is still Open -- claim should revert
        vm.expectRevert(PositionModule.PositionModule__NotSettled.selector);
        positionModule.claimPosition(specId, PositionType.Upper);
    }

    // Note: Double claim prevention test already exists as
    // testClaimPosition_RevertsWithAlreadyClaimed_OnDoubleClaim -- skipping duplicate.

    // =========================================================================
    // TASK 7: PUSH/VOID FOR BOTH MAKER AND TAKER
    // =========================================================================

    /// @notice Push: both maker AND taker get exactly riskAmount back
    function testClaimPosition_Push_BothMakerAndTaker() public {
        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(env.posMod), makerRisk);
        vm.prank(taker);
        token.approve(address(env.posMod), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            env.posMod, 1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.warp(block.timestamp + 2 hours);
        Contest memory c = _scoredContest(1, 0);
        mockContestModule.setContest(1, c);
        env.specMod.settleSpeculation(specId);
        env.specMod.setSpeculationWinSide(specId, WinSide.Push);

        // Maker claims -- gets exactly riskAmount back
        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, makerRisk, "Push: maker gets riskAmount back");

        // Taker claims -- gets exactly riskAmount back
        balBefore = token.balanceOf(taker);
        vm.prank(taker);
        env.posMod.claimPosition(specId, PositionType.Lower);
        balAfter = token.balanceOf(taker);
        assertEq(balAfter - balBefore, takerRisk, "Push: taker gets riskAmount back");
    }

    /// @notice Void: both maker AND taker get exactly riskAmount back
    function testClaimPosition_Void_BothMakerAndTaker() public {
        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(env.posMod), makerRisk);
        vm.prank(taker);
        token.approve(address(env.posMod), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            env.posMod, 1, address(defaultScorer), 50,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.warp(block.timestamp + 2 hours);
        Contest memory c = _scoredContest(1, 0);
        mockContestModule.setContest(1, c);
        env.specMod.settleSpeculation(specId);
        env.specMod.setSpeculationWinSide(specId, WinSide.Void);

        // Maker claims
        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, makerRisk, "Void: maker gets riskAmount back");

        // Taker claims
        balBefore = token.balanceOf(taker);
        vm.prank(taker);
        env.posMod.claimPosition(specId, PositionType.Lower);
        balAfter = token.balanceOf(taker);
        assertEq(balAfter - balBefore, takerRisk, "Void: taker gets riskAmount back");
    }

    // =========================================================================
    // TASK 11: PARTIAL TRANSFER TEST
    // =========================================================================

    /// @notice Partial transfer: transfer half, settle, both sender and receiver claim correctly
    function testTransferPosition_PartialTransfer_BothClaim() public {
        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

        uint256 makerRisk = 100_000_000; // 100 USDC (100e6)
        uint256 takerRisk = 80_000_000;  // 80 USDC (80e6)

        token.approve(address(env.posMod), makerRisk);
        vm.prank(taker);
        token.approve(address(env.posMod), takerRisk);

        uint256 specId = _helperRecordFillLocal(
            env.posMod, 1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        // Verify initial position: risk=100e6, profit=80e6
        Position memory origPos = env.posMod.getPosition(specId, address(this), PositionType.Upper);
        assertEq(origPos.riskAmount, 100_000_000);
        assertEq(origPos.profitAmount, 80_000_000);

        // Transfer half to another address
        address receiver = address(0xAAAA);
        env.market.transferPosition(
            specId,
            address(this),
            PositionType.Upper,
            receiver,
            50_000_000, // half risk
            40_000_000  // half profit
        );

        // Verify sender has remainder: risk=50e6, profit=40e6
        Position memory senderPos = env.posMod.getPosition(specId, address(this), PositionType.Upper);
        assertEq(senderPos.riskAmount, 50_000_000, "Sender risk should be 50e6");
        assertEq(senderPos.profitAmount, 40_000_000, "Sender profit should be 40e6");

        // Verify receiver has: risk=50e6, profit=40e6
        Position memory receiverPos = env.posMod.getPosition(specId, receiver, PositionType.Upper);
        assertEq(receiverPos.riskAmount, 50_000_000, "Receiver risk should be 50e6");
        assertEq(receiverPos.profitAmount, 40_000_000, "Receiver profit should be 40e6");

        // Settle as Upper wins (Away)
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = _scoredContest(100, 90);
        mockContestModule.setContest(1, c);
        env.specMod.settleSpeculation(specId);
        env.specMod.setSpeculationWinSide(specId, WinSide.Away);

        // Sender claims: payout = 50e6 + 40e6 = 90e6
        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(specId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 90_000_000, "Sender payout should be 50e6 + 40e6 = 90e6");

        // Receiver claims: payout = 50e6 + 40e6 = 90e6
        balBefore = token.balanceOf(receiver);
        vm.prank(receiver);
        env.posMod.claimPosition(specId, PositionType.Upper);
        balAfter = token.balanceOf(receiver);
        assertEq(balAfter - balBefore, 90_000_000, "Receiver payout should be 50e6 + 40e6 = 90e6");
    }

    // =========================================================================
    // TASK 19: POSITION AGGREGATION TEST
    // =========================================================================

    /// @notice Same user, same speculation, same side, three fills -- positions aggregate
    function testRecordFill_PositionAggregation_ThreeFills() public {
        // Need fresh core for MockSpeculationModule
        LocalEnv memory env = _createLocalEnv();

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

        // Fund takers (taker1 needs extra for speculation creation split fee)
        token.transfer(taker1, takerRisk1 + SPEC_FEE);
        token.transfer(taker2, takerRisk2);
        token.transfer(taker3, takerRisk3);

        // Fill 1 (creates speculation — triggers split fee for maker + taker1)
        token.approve(address(env.posMod), makerRisk1);
        vm.prank(taker1);
        token.approve(address(env.posMod), takerRisk1);
        vm.prank(taker1);
        token.approve(address(env.treasury), type(uint256).max);

        uint256 specId = _helperRecordFillLocal(
            env.posMod, 1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk1, taker1, takerRisk1
        );

        // Fill 2 -- same speculation (same contest/scorer/lineTicks)
        token.approve(address(env.posMod), makerRisk2);
        vm.prank(taker2);
        token.approve(address(env.posMod), takerRisk2);

        env.posMod.recordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk2,
            taker2, takerRisk2
        );

        // Fill 3 -- same speculation
        token.approve(address(env.posMod), makerRisk3);
        vm.prank(taker3);
        token.approve(address(env.posMod), takerRisk3);

        env.posMod.recordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk3,
            taker3, takerRisk3
        );

        // Verify aggregated position
        uint256 totalMakerRisk = makerRisk1 + makerRisk2 + makerRisk3; // 22M
        uint256 totalMakerProfit = takerRisk1 + takerRisk2 + takerRisk3; // 18M

        Position memory makerPos = env.posMod.getPosition(specId, address(this), PositionType.Upper);
        assertEq(makerPos.riskAmount, totalMakerRisk, "riskAmount == sum of all fills' risk");
        assertEq(makerPos.profitAmount, totalMakerProfit, "profitAmount == sum of all fills' profit");

        // Settle and claim -- payout should be totalRisk + totalProfit
        vm.warp(block.timestamp + 2 hours);
        Contest memory c = _scoredContest(100, 90);
        mockContestModule.setContest(1, c);
        env.specMod.settleSpeculation(specId);
        env.specMod.setSpeculationWinSide(specId, WinSide.Away);

        uint256 balBefore = token.balanceOf(address(this));
        env.posMod.claimPosition(specId, PositionType.Upper);
        uint256 payout = token.balanceOf(address(this)) - balBefore;
        assertEq(
            payout,
            totalMakerRisk + totalMakerProfit,
            "Claim payout == totalRiskAmount + totalProfitAmount"
        );
    }

    // =====================================================================
    // Transfer Lock Tests (C-6)
    // =====================================================================
    // Positions registered on a leaderboard lock the registered amounts.
    // Users can still transfer exposure ABOVE the locked amounts.
    // LeaderboardModule stores s_lockedRisk / s_lockedProfit per
    // (speculationId, user, positionType). PositionModule.transferPosition
    // ensures the remaining position after transfer >= locked amounts.
    // =====================================================================

    /// @notice Full transfer reverts when locked amounts would be violated
    function testTransferPosition_RevertsWhenLockedAmountsViolated() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        // Lock the full position amounts (simulates leaderboard registration)
        mockLeaderboardModule.setLockedAmounts(specId, address(this), PositionType.Upper, makerRisk, takerRisk);

        // Attempt full transfer -- should revert (remaining would be 0 < locked)
        vm.expectRevert(PositionModule.PositionModule__TransferLocked.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, address(this), PositionType.Upper, taker, makerRisk, takerRisk
        );
    }

    /// @notice Transfer succeeds when no amounts are locked (default)
    function testTransferPosition_SucceedsWhenNotLocked() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, address(this), PositionType.Upper, taker, makerRisk, takerRisk
        );

        Position memory fromPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(fromPos.riskAmount, 0, "sender should have 0 risk after full transfer");
    }

    /// @notice Lock only affects the locked user -- other users can still transfer
    function testTransferPosition_LockIsPerUser() public {
        uint256 makerRisk = 10_000_000;
        uint256 takerRisk = 8_000_000;

        token.approve(address(positionModule), makerRisk);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk, taker, takerRisk
        );

        // Lock maker's Upper position
        mockLeaderboardModule.setLockedAmounts(specId, address(this), PositionType.Upper, makerRisk, takerRisk);

        // Taker's Lower position is NOT locked -- transfer should succeed
        address recipient = address(0xDEAD);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, taker, PositionType.Lower, recipient, takerRisk, makerRisk
        );

        Position memory recipientPos = positionModule.getPosition(specId, recipient, PositionType.Lower);
        assertEq(recipientPos.riskAmount, takerRisk, "taker's unlocked position should transfer");
    }

    /// @notice Excess exposure above locked amount can be transferred
    function testTransferPosition_ExcessAboveLockedCanBeTransferred() public {
        // Initial fill: maker risks 10 USDC, taker risks 8 USDC
        uint256 makerRisk1 = 10_000_000;
        uint256 takerRisk1 = 8_000_000;

        token.approve(address(positionModule), makerRisk1);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk1);

        uint256 specId = _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk1, taker, takerRisk1
        );

        // Lock 10M risk / 8M profit (the registered leaderboard amounts)
        mockLeaderboardModule.setLockedAmounts(specId, address(this), PositionType.Upper, makerRisk1, takerRisk1);

        // Second fill adds more exposure: maker risks another 5 USDC, taker risks 4 USDC
        uint256 makerRisk2 = 5_000_000;
        uint256 takerRisk2 = 4_000_000;

        token.approve(address(positionModule), makerRisk2);
        vm.prank(taker);
        token.approve(address(positionModule), takerRisk2);

        _helperRecordFill(
            1, address(defaultScorer), 42,
            PositionType.Upper, address(this), makerRisk2, taker, takerRisk2
        );

        // Maker now has: risk = 15M, profit = 12M. Locked: risk = 10M, profit = 8M.
        // Transferable: risk = 5M, profit = 4M.
        Position memory pos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(pos.riskAmount, 15_000_000, "total risk should be 15M");
        assertEq(pos.profitAmount, 12_000_000, "total profit should be 12M");

        // Transfer the excess (5M risk, 4M profit) -- should succeed
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, address(this), PositionType.Upper, taker, makerRisk2, takerRisk2
        );

        // Remaining should equal the locked amounts exactly
        Position memory afterPos = positionModule.getPosition(specId, address(this), PositionType.Upper);
        assertEq(afterPos.riskAmount, makerRisk1, "remaining risk should equal locked amount");
        assertEq(afterPos.profitAmount, takerRisk1, "remaining profit should equal locked amount");

        // Trying to transfer even 1 more wei should revert
        vm.expectRevert(PositionModule.PositionModule__TransferLocked.selector);
        vm.prank(address(defaultMarket));
        defaultMarket.transferPosition(
            specId, address(this), PositionType.Upper, taker, 1, 0
        );
    }
}
