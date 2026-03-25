// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] All odds in this file use 1e7 precision: 1.10 = 11_000_000, 1.80 = 18_000_000, etc. (MIN_ODDS = 10_100_000)

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionType, Contest, ContestStatus, Position, WinSide, OddsPair, LeagueId, Speculation, SpeculationStatus, FeeType, Leaderboard} from "../../src/core/OspexTypes.sol";
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

        // Register this test contract as ORACLE_MODULE so it can call createSpeculation
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));

        // Grant MARKET_ROLE to the test contract so it can call createMatchedPair
        core.setMarketRole(address(this), true);

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

    /// @notice Computes the oddsPairId deterministically (mirrors _getOrCreateOddsPairId logic).
    ///         The internal _getOrCreateOddsPairId is not publicly exposed, so tests compute the
    ///         expected oddsPairId using the same pure-math formula.
    function _computeOddsPairId(
        PositionModule pm,
        uint64 odds,
        PositionType positionType
    ) internal view returns (uint128 oddsPairId, uint64 upperOdds, uint64 lowerOdds) {
        uint64 normalizedOdds = pm.roundOddsToNearestIncrement(odds);
        uint64 inverseOdds = pm.calculateAndRoundInverseOdds(normalizedOdds);
        uint16 oddsIndex = uint16((normalizedOdds - pm.MIN_ODDS()) / pm.ODDS_INCREMENT());
        uint128 baseOddsPairId = uint128(oddsIndex);
        oddsPairId = (positionType == PositionType.Lower)
            ? baseOddsPairId + 10000
            : baseOddsPairId;
        upperOdds = (positionType == PositionType.Upper)
            ? normalizedOdds
            : inverseOdds;
        lowerOdds = (positionType == PositionType.Upper)
            ? inverseOdds
            : normalizedOdds;
    }

    /// @notice Helper to create a matched pair (test contract has MARKET_ROLE)
    function _helperCreateMatchedPair(
        PositionModule pm,
        uint256 specId,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address _taker,
        uint256 _takerAmount
    ) internal returns (uint256 makerAmountConsumed, uint128 _oddsPairId) {
        (_oddsPairId, , ) = _computeOddsPairId(pm, odds, makerPositionType);
        makerAmountConsumed = pm.createMatchedPair(
            specId, odds, makerPositionType, maker, makerAmountRemaining, _taker, _takerAmount, 0, 0
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

    // --- createMatchedPair TESTS ---

    function testCreateMatchedPair_HappyPath() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        // Maker = address(this), 10 USDC at 1.80 odds Upper
        // upperOdds = 18_000_000, lowerOdds = 22_500_000
        // matchableAmount = 10M * (18M - 10M) / 10M = 8_000_000
        // takerAmount = 8_000_000
        // makerAmountConsumed = 8M * (22.5M - 10M) / 10M = 10_000_000
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        // Approve tokens for both maker and taker
        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (uint256 makerAmountConsumed, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            makerAmountRemaining,
            taker,
            takerAmount
        );

        // Verify makerAmountConsumed
        assertEq(makerAmountConsumed, 10_000_000, "makerAmountConsumed should be 10M");

        // Verify maker position
        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertEq(makerPos.matchedAmount, 10_000_000, "Maker matchedAmount should be 10M");
        assertEq(makerPos.takerAmount, 8_000_000, "Maker takerAmount should be 8M");
        assertEq(uint(makerPos.positionType), uint(PositionType.Upper));
        assertFalse(makerPos.claimed);

        // Verify taker position
        Position memory takerPos = positionModule.getPosition(
            specId,
            taker,
            oddsPairId,
            PositionType.Lower
        );
        assertEq(takerPos.matchedAmount, 8_000_000, "Taker matchedAmount should be 8M");
        assertEq(takerPos.takerAmount, 10_000_000, "Taker takerAmount should be 10M");
        assertEq(uint(takerPos.positionType), uint(PositionType.Lower));
        assertFalse(takerPos.claimed);
    }

    function testCreateMatchedPair_RevertsWithoutMarketRole() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        // Use an address that does NOT have MARKET_ROLE
        address unauthorized = address(0xDEAD);

        vm.expectRevert(
            PositionModule.PositionModule__UnauthorizedMarket.selector
        );
        vm.prank(unauthorized);
        positionModule.createMatchedPair(
            specId,
            18_000_000,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            8_000_000,
            0,
            0
        );
    }

    function testCreateMatchedPair_RevertsIfSpeculationNotOpen() public {
        uint32 startTime = uint32(block.timestamp + 1 hours);

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
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

        // Try to create a matched pair after speculation is closed
        token.approve(address(positionModule), 10_000_000);
        vm.prank(taker);
        token.approve(address(positionModule), 8_000_000);

        vm.expectRevert(
            PositionModule.PositionModule__SpeculationNotOpen.selector
        );
        positionModule.createMatchedPair(
            specId,
            18_000_000,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            8_000_000,
            0,
            0
        );
    }

    function testCreateMatchedPair_RevertsIfOddsOutOfRange() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        token.approve(address(positionModule), 10_000_000);
        vm.prank(taker);
        token.approve(address(positionModule), 8_000_000);

        // Odds below MIN_ODDS
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionModule.PositionModule__OddsOutOfRange.selector,
                1_000_000
            )
        );
        positionModule.createMatchedPair(
            specId,
            1_000_000, // Below MIN_ODDS
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            8_000_000,
            0,
            0
        );
    }

    function testCreateMatchedPair_RevertsIfTakerAmountOutOfRange() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        token.approve(address(positionModule), 10_000_000);
        vm.prank(taker);
        token.approve(address(positionModule), 1);

        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.createMatchedPair(
            specId,
            18_000_000,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            1, // Below min speculation amount
            0,
            0
        );
    }

    function testCreateMatchedPair_RevertsIfInsufficientAmountRemaining() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        // At 1.80 odds Upper:
        // matchableAmount = 1M * (18M - 10M) / 10M = 800_000
        // But taker wants 1_000_000 which exceeds matchableAmount
        uint256 makerAmountRemaining = 1_000_000;
        uint256 takerAmount = 1_000_000; // Exceeds matchable 800_000

        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                PositionModule.PositionModule__InsufficientAmountRemaining.selector,
                makerAmountRemaining,
                800_000 // matchableAmount = 1M * 0.8
            )
        );
        positionModule.createMatchedPair(
            specId,
            18_000_000,
            PositionType.Upper,
            address(this),
            makerAmountRemaining,
            taker,
            takerAmount,
            0,
            0
        );
    }

    // --- createMatchedPairWithSpeculation TESTS ---

    function testCreateMatchedPairWithSpeculation_HappyPath() public {
        // Verify speculation doesn't exist yet
        uint256 existingSpecId = speculationModule.getSpeculationId(
            1, // contestId
            address(0x1234), // scorer
            42 // theNumber
        );
        assertEq(existingSpecId, 0, "Speculation should not exist yet");

        // Set up maker and taker approvals
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        // Call createMatchedPairWithSpeculation
        positionModule.createMatchedPairWithSpeculation(
            1, // contestId
            address(0x1234), // scorer
            42, // theNumber
            leaderboardId,
            odds,
            PositionType.Upper,
            address(this), // maker
            makerAmountRemaining,
            taker,
            takerAmount,
            0, // makerContributionAmount
            0  // takerContributionAmount
        );

        // Verify speculation was created
        uint256 newSpecId = speculationModule.getSpeculationId(
            1,
            address(0x1234),
            42
        );
        assertGt(newSpecId, 0, "Speculation should have been created");

        Speculation memory spec = speculationModule.getSpeculation(newSpecId);
        assertEq(spec.contestId, 1);
        assertEq(spec.speculationScorer, address(0x1234));
        assertEq(spec.theNumber, 42);

        // Verify positions were created
        (uint128 oddsPairId, , ) = _computeOddsPairId(
            positionModule,
            odds,
            PositionType.Upper
        );
        Position memory makerPos = positionModule.getPosition(
            newSpecId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertGt(makerPos.matchedAmount, 0, "Maker should have matched amount");

        Position memory takerPos = positionModule.getPosition(
            newSpecId,
            taker,
            oddsPairId,
            PositionType.Lower
        );
        assertGt(takerPos.matchedAmount, 0, "Taker should have matched amount");
    }

    function testCreateMatchedPairWithSpeculation_RevertsWithoutMarketRole() public {
        address unauthorized = address(0xDEAD);

        vm.expectRevert(
            PositionModule.PositionModule__UnauthorizedMarket.selector
        );
        vm.prank(unauthorized);
        positionModule.createMatchedPairWithSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId,
            18_000_000,
            PositionType.Upper,
            address(this),
            10_000_000,
            taker,
            8_000_000,
            0,
            0
        );
    }

    // --- CLAIM POSITION TESTS ---

    function testClaimPosition_HappyPath() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );

        // Create matched pair: maker=this (Upper), taker=0xCAFE (Lower)
        // At 1.80 odds: makerAmountConsumed=10M, takerAmount=8M
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            makerAmountRemaining,
            taker,
            takerAmount
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

        // Claim: winner gets matchedAmount + takerAmount = 10M + 8M = 18M
        uint256 balBefore = token.balanceOf(address(this));
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 18_000_000, "Winner payout should be 18M (10M + 8M)");

        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertTrue(pos.claimed);
        assertEq(pos.matchedAmount, 0);
    }

    function testGetPosition_ReturnPositionWithClaimedTrue() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );

        // Create matched pair
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (uint128 oddsPairId, , ) = _computeOddsPairId(
            positionModule,
            odds,
            PositionType.Upper
        );
        positionModule.createMatchedPair(
            specId, odds, PositionType.Upper, address(this), makerAmountRemaining, taker, takerAmount, 0, 0
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

        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertTrue(pos.claimed);
        assertEq(pos.matchedAmount, 0);
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
        uint256 specIdPush = mockSpeculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );

        // Create matched pair for Push test
        // At 1.80 odds: maker puts 10M, taker puts 8M
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        token.approve(address(localPositionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(localPositionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            localPositionModule,
            specIdPush,
            odds,
            PositionType.Upper,
            address(this),
            makerAmountRemaining,
            taker,
            takerAmount
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

        // On Push: payout = matchedAmount (original stake back)
        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specIdPush,
            oddsPairId,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000_000, "Push should return matchedAmount (10M)");

        // --- Test Void scenario ---
        vm.warp(1672531200 + 1 days); // Jan 2, 2023
        futureTime2 = uint32(block.timestamp + 1 hours);

        uint256 specIdVoid = mockSpeculationModule.createSpeculation(
            2,
            address(mockScorer),
            43,
            leaderboardId
        );

        // Create matched pair for Void test
        token.approve(address(localPositionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(localPositionModule), takerAmount);

        (uint128 oddsPairIdVoid, , ) = _computeOddsPairId(
            localPositionModule,
            odds,
            PositionType.Upper
        );
        localPositionModule.createMatchedPair(
            specIdVoid, odds, PositionType.Upper, address(this), makerAmountRemaining, taker, takerAmount, 0, 0
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
            oddsPairIdVoid,
            PositionType.Upper
        );
        balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000_000, "Void should return matchedAmount (10M)");
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

        uint256 specId = mockSpeculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );
        uint256 tokenUnit = 10_000_000; // 10 USDC

        // --- Create Upper position via createMatchedPair ---
        // At 1.10 odds Upper: upperOdds=11M, lowerOdds=inverse(~111M)
        // matchableAmount = 10M * (11M-10M)/10M = 1_000_000
        // takerAmount = 1_000_000, makerAmountConsumed = 1M * (lowerOdds-10M)/10M = 10_000_000
        uint64 upperOdds = 11_000_000;
        uint256 upperTakerAmount = (tokenUnit * (upperOdds - 10_000_000)) / 10_000_000; // 1_000_000
        address upperTaker = address(0xCAFE);

        token.approve(address(localPositionModule), tokenUnit);
        token.transfer(upperTaker, upperTakerAmount);
        vm.prank(upperTaker);
        token.approve(address(localPositionModule), upperTakerAmount);

        (, uint128 upperOddsPairId) = _helperCreateMatchedPair(
            localPositionModule,
            specId,
            upperOdds,
            PositionType.Upper,
            address(this),
            tokenUnit,
            upperTaker,
            upperTakerAmount
        );

        // --- Create Lower position via createMatchedPair ---
        // At 1.80 odds Lower: lowerOdds=18M, upperOdds=22.5M
        // relevantOdds for Lower maker = lowerOdds = 18M
        // matchableAmount = 10M * (18M-10M)/10M = 8_000_000
        // takerAmount = 8_000_000
        // oppositeOdds = upperOdds = 22.5M
        // makerAmountConsumed = 8M * (22.5M-10M)/10M = 10_000_000
        uint64 lowerOdds = 18_000_000;
        uint256 lowerTakerAmount = (tokenUnit * (lowerOdds - 10_000_000)) / 10_000_000; // 8_000_000
        address lowerTaker = address(0xCAFF);

        token.approve(address(localPositionModule), tokenUnit);
        token.transfer(lowerTaker, lowerTakerAmount);
        vm.prank(lowerTaker);
        token.approve(address(localPositionModule), lowerTakerAmount);

        (, uint128 lowerOddsPairId) = _helperCreateMatchedPair(
            localPositionModule,
            specId,
            lowerOdds,
            PositionType.Lower,
            address(this),
            tokenUnit,
            lowerTaker,
            lowerTakerAmount
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
        mockSpeculationModule.settleSpeculation(specId);

        // Test win for Upper (Away)
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Away);
        Position memory posUpper = localPositionModule.getPosition(
            specId,
            address(this),
            upperOddsPairId,
            PositionType.Upper
        );
        emit log_named_uint("matchedAmount (Upper win)", posUpper.matchedAmount);
        emit log_named_uint("positionType (Upper win)", uint(posUpper.positionType));

        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId,
            upperOddsPairId,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Upper win)", balAfter - balBefore);
        // Winner gets matchedAmount + takerAmount
        assertGt(balAfter - balBefore, tokenUnit);

        // Test win for Lower (Home)
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Home);
        Position memory posLower = localPositionModule.getPosition(
            specId,
            address(this),
            lowerOddsPairId,
            PositionType.Lower
        );
        emit log_named_uint("matchedAmount (Lower win)", posLower.matchedAmount);
        emit log_named_uint("positionType (Lower win)", uint(posLower.positionType));

        balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId,
            lowerOddsPairId,
            PositionType.Lower
        );
        balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Lower win)", balAfter - balBefore);
        assertGt(balAfter - balBefore, tokenUnit);
    }

    // --- TRANSFER POSITION TESTS ---

    function testTransferPosition_HappyPath() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        // Create matched pair
        uint64 odds = 11_000_000;
        uint256 tokenUnit = 10_000_000; // 10 USDC
        uint256 takerAmount = (tokenUnit * (odds - 10_000_000)) / 10_000_000; // 1_000_000

        token.approve(address(positionModule), tokenUnit);
        token.transfer(taker, takerAmount);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            tokenUnit,
            taker,
            takerAmount
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );

        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);
        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            user,
            makerPos.matchedAmount
        );

        Position memory fromPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        Position memory toPos = positionModule.getPosition(
            specId,
            user,
            oddsPairId,
            PositionType.Upper
        );
        assertEq(fromPos.matchedAmount, 0);
        assertEq(toPos.matchedAmount, makerPos.matchedAmount);
        assertEq(toPos.poolId, oddsPairId);
        assertFalse(toPos.claimed);
    }

    function testTransferPosition_RevertsIfUnauthorized() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        uint64 odds = 11_000_000;
        uint256 tokenUnit = 10_000_000;
        uint256 takerAmount = (tokenUnit * (odds - 10_000_000)) / 10_000_000;

        token.approve(address(positionModule), tokenUnit);
        token.transfer(taker, takerAmount);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            tokenUnit,
            taker,
            takerAmount
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
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
            oddsPairId,
            PositionType.Upper,
            user,
            makerPos.matchedAmount
        );
    }

    function testTransferPosition_RevertsIfInvalidAmount() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        uint64 odds = 11_000_000;
        uint256 tokenUnit = 10_000_000;
        uint256 takerAmount = (tokenUnit * (odds - 10_000_000)) / 10_000_000;

        token.approve(address(positionModule), tokenUnit);
        token.transfer(taker, takerAmount);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            tokenUnit,
            taker,
            takerAmount
        );

        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );

        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        vm.prank(address(market));
        market.transferPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            user,
            makerPos.matchedAmount + 1
        );
    }

    // --- ODDS LOGIC TESTS ---

    function testRoundOddsToNearestIncrement() public view {
        assertEq(
            positionModule.roundOddsToNearestIncrement(9_000_000),
            positionModule.MIN_ODDS()
        );
        assertEq(
            positionModule.roundOddsToNearestIncrement(2_000_000_000),
            positionModule.MAX_ODDS()
        );
        assertEq(
            positionModule.roundOddsToNearestIncrement(10_150_000),
            10_200_000
        );
        assertEq(
            positionModule.roundOddsToNearestIncrement(10_120_000),
            10_100_000
        );
    }

    function testCalculateAndRoundInverseOdds() public view {
        uint64 inv = positionModule.calculateAndRoundInverseOdds(11_000_000);
        assertGt(inv, 100_000_000);
        uint64 odds = 15_250_000;
        uint64 inv2 = positionModule.calculateAndRoundInverseOdds(odds);
        assertEq(inv2 % positionModule.ODDS_INCREMENT(), 0);
    }

    function testGetOddsPairAndOriginalInverseOdds() public {
        // Create a matched pair to force odds pair creation, then verify via getOddsPair
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );
        uint64 odds = 11_000_000;

        // Compute expected oddsPairId
        (uint128 oddsPairId, , ) = _computeOddsPairId(positionModule, odds, PositionType.Upper);

        // Create a matched pair to trigger odds pair creation in storage
        // At 1.10 odds: matchable = 10M * 0.1 = 1M, takerAmount = 1M
        token.approve(address(positionModule), 10_000_000);
        vm.prank(taker);
        token.approve(address(positionModule), 1_000_000);
        positionModule.createMatchedPair(
            specId, odds, PositionType.Upper, address(this), 10_000_000, taker, 1_000_000, 0, 0
        );

        OddsPair memory pair = positionModule.getOddsPair(oddsPairId);
        assertEq(pair.upperOdds, odds);
        assertEq(positionModule.getOriginalOdds(oddsPairId), odds);
        assertEq(positionModule.getInverseOdds(oddsPairId), pair.lowerOdds);
    }

    // --- ODDSPAIR ORIENTATION FIX TESTS ---

    /**
     * @notice Test 1: Verify no collisions when different maker odds map to complementary pairs
     * @dev This test ensures that 1.92x and 2.09x (which are inverses) create DIFFERENT oddsPairIds
     */
    function testGetOrCreateOddsPairId_UniqueIdsForDifferentMakerOdds() public view {
        // Test first odds (1.92x)
        (uint128 oddsPairId1, uint64 upper1, uint64 lower1) = _computeOddsPairId(
            positionModule,
            19_200_000,
            PositionType.Upper
        );
        assertEq(oddsPairId1, 91, "Incorrect oddsPairId for 1.92x Upper");
        assertEq(upper1, 19_200_000, "Upper should be maker's requested odds (1.92x)");
        assertEq(lower1, 20_900_000, "Lower should be inverse (2.09x)");

        // Test second odds (2.09x)
        (uint128 oddsPairId2, uint64 upper2, uint64 lower2) = _computeOddsPairId(
            positionModule,
            20_900_000,
            PositionType.Upper
        );
        assertEq(oddsPairId2, 108, "Incorrect oddsPairId for 2.09x Upper");
        assertEq(upper2, 20_900_000, "Upper should be maker's requested odds (2.09x)");
        assertEq(lower2, 19_200_000, "Lower should be inverse (1.92x)");

        // Verify no collision
        assertTrue(oddsPairId1 != oddsPairId2, "OddsPairIds must be unique - no collision allowed");

        // Verify formula
        uint128 expectedId1 = uint128((19_200_000 - positionModule.MIN_ODDS()) / positionModule.ODDS_INCREMENT());
        uint128 expectedId2 = uint128((20_900_000 - positionModule.MIN_ODDS()) / positionModule.ODDS_INCREMENT());
        assertEq(oddsPairId1, expectedId1, "Formula verification failed for 1.92x");
        assertEq(oddsPairId2, expectedId2, "Formula verification failed for 2.09x");
    }

    /**
     * @notice Test 2: Verify +10000 offset for Lower positions
     * @dev Upper and Lower positions at same odds should create different oddsPairIds with correct orientation
     */
    function testGetOrCreateOddsPairId_UpperLowerOffsetWorksCorrectly() public view {
        // Test Upper at 1.8x
        (uint128 upperOddsPairId, uint64 upperUpper, ) = _computeOddsPairId(
            positionModule,
            18_000_000,
            PositionType.Upper
        );
        assertEq(upperOddsPairId, 79, "Incorrect oddsPairId for 1.8x Upper");
        assertEq(upperUpper, 18_000_000, "Upper position should have 1.8x as upper odds");

        // Test Lower at 1.8x
        (uint128 lowerOddsPairId, , uint64 lowerLower) = _computeOddsPairId(
            positionModule,
            18_000_000,
            PositionType.Lower
        );
        assertEq(lowerOddsPairId, 10079, "Incorrect oddsPairId for 1.8x Lower (should be base + 10000)");
        assertEq(lowerLower, 18_000_000, "Lower position should have 1.8x as lower odds");

        // Verify offset is exactly 10000
        assertEq(lowerOddsPairId, upperOddsPairId + 10000, "Lower offset must be exactly +10000");
    }

    /**
     * @notice Test 3: Verify all four combinations create unique IDs with correct orientation
     * @dev Tests Upper/Lower at 1.8x and Upper/Lower at 2.25x (inverse pair)
     */
    function testGetOrCreateOddsPairId_ComplementaryOddsPairs() public view {
        // Test case 1: Upper at 1.8x
        (uint128 id1, uint64 upper1, uint64 lower1) = _computeOddsPairId(
            positionModule,
            18_000_000,
            PositionType.Upper
        );
        assertEq(id1, 79, "Upper at 1.8x should have oddsPairId=79");
        assertEq(upper1, 18_000_000, "Upper at 1.8x should store 18_000_000 as upperOdds");
        assertEq(lower1, 22_500_000, "Upper at 1.8x should store ~2.25x as lowerOdds");

        // Test case 2: Lower at 1.8x
        (uint128 id2, uint64 upper2, uint64 lower2) = _computeOddsPairId(
            positionModule,
            18_000_000,
            PositionType.Lower
        );
        assertEq(id2, 10079, "Lower at 1.8x should have oddsPairId=10079");
        assertEq(upper2, 22_500_000, "Lower at 1.8x should store ~2.25x as upperOdds");
        assertEq(lower2, 18_000_000, "Lower at 1.8x should store 18_000_000 as lowerOdds");

        // Test case 3: Upper at 2.25x
        (uint128 id3, uint64 upper3, uint64 lower3) = _computeOddsPairId(
            positionModule,
            22_500_000,
            PositionType.Upper
        );
        assertEq(id3, 124, "Upper at 2.25x should have oddsPairId=124");
        assertEq(upper3, 22_500_000, "Upper at 2.25x should store 22_500_000 as upperOdds");
        assertEq(lower3, 18_000_000, "Upper at 2.25x should store ~1.8x as lowerOdds");

        // Test case 4: Lower at 2.25x
        (uint128 id4, uint64 upper4, uint64 lower4) = _computeOddsPairId(
            positionModule,
            22_500_000,
            PositionType.Lower
        );
        assertEq(id4, 10124, "Lower at 2.25x should have oddsPairId=10124");
        assertEq(upper4, 18_000_000, "Lower at 2.25x should store ~1.8x as upperOdds");
        assertEq(lower4, 22_500_000, "Lower at 2.25x should store 22_500_000 as lowerOdds");

        // Critical assertion: all four IDs must be unique
        assertTrue(id1 != id2 && id1 != id3 && id1 != id4, "ID1 must be unique");
        assertTrue(id2 != id3 && id2 != id4, "ID2 must be unique");
        assertTrue(id3 != id4, "ID3 must be unique");

        // Verify inverse relationship
        assertEq(upper1, lower3, "Upper at 1.8x inverse should match Lower at 2.25x");
        assertEq(lower1, upper3, "Lower at 1.8x inverse should match Upper at 2.25x");
    }

    /**
     * @notice Test 4: Verify no race condition - order doesn't affect stored odds
     * @dev Verify that the deterministic formula produces identical results regardless of call order
     */
    function testGetOrCreateOddsPairId_OrderIndependence() public view {
        // Scenario A: Compute Upper first, then Lower
        (uint128 idA1, , ) = _computeOddsPairId(
            positionModule,
            19_200_000,
            PositionType.Upper
        );
        assertEq(idA1, 91, "Scenario A: Upper at 1.92x should be oddsPairId=91");

        (uint128 idA2, , ) = _computeOddsPairId(
            positionModule,
            19_200_000,
            PositionType.Lower
        );
        assertEq(idA2, 10091, "Scenario A: Lower at 1.92x should be oddsPairId=10091");

        // Scenario B: Compute Lower first, then Upper
        (uint128 idB1, , ) = _computeOddsPairId(
            positionModule,
            19_200_000,
            PositionType.Lower
        );
        assertEq(idB1, 10091, "Scenario B: Lower at 1.92x should be oddsPairId=10091");

        (uint128 idB2, , ) = _computeOddsPairId(
            positionModule,
            19_200_000,
            PositionType.Upper
        );
        assertEq(idB2, 91, "Scenario B: Upper at 1.92x should be oddsPairId=91");

        // Both scenarios should result in identical IDs
        assertEq(idA1, idB2, "Upper IDs must match regardless of computation order");
        assertEq(idA2, idB1, "Lower IDs must match regardless of computation order");
    }

    /**
     * @notice Test 5: Verify different maker odds that round to same inverse still create unique IDs
     * @dev Tests that 3.37x and 3.38x (both round to ~1.42x inverse) get different oddsPairIds
     */
    function testGetOrCreateOddsPairId_TakerReceivesCorrectInverseOdds() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        // Test Upper at 3.37x
        (uint128 id1, uint64 upper1, uint64 lower1) = _computeOddsPairId(
            positionModule,
            33_700_000,
            PositionType.Upper
        );
        uint128 expectedId1 = uint128((33_700_000 - positionModule.MIN_ODDS()) / positionModule.ODDS_INCREMENT());
        assertEq(id1, expectedId1, "3.37x Upper should have oddsPairId=236");
        assertEq(upper1, 33_700_000, "Upper at 3.37x should store 33_700_000");

        // Test Upper at 3.38x
        (uint128 id2, uint64 upper2, uint64 lower2) = _computeOddsPairId(
            positionModule,
            33_800_000,
            PositionType.Upper
        );
        uint128 expectedId2 = uint128((33_800_000 - positionModule.MIN_ODDS()) / positionModule.ODDS_INCREMENT());
        assertEq(id2, expectedId2, "3.38x Upper should have oddsPairId=237");
        assertEq(upper2, 33_800_000, "Upper at 3.38x should store 33_800_000");

        // Critical assertion: Different oddsPairIds despite similar inverse
        assertTrue(id1 != id2, "Different maker odds must create different oddsPairIds");
        assertEq(id2, id1 + 1, "Sequential odds should create sequential oddsPairIds");

        // Verify both round to similar inverse (around 1.42x)
        assertTrue(lower1 >= 14_100_000 && lower1 <= 14_300_000, "Inverse should be around 1.42x");
        assertTrue(lower2 >= 14_100_000 && lower2 <= 14_300_000, "Inverse should be around 1.42x");

        // Create matched pairs to verify takers receive correct positions
        address taker1 = address(0xCAFE);
        address taker2 = address(0xBEEF);
        uint256 makerAmount = 10_000_000;

        // Calculate taker amounts based on upper odds
        uint256 takerAmount1 = (makerAmount * (upper1 - 10_000_000)) / 10_000_000;
        uint256 takerAmount2 = (makerAmount * (upper2 - 10_000_000)) / 10_000_000;

        // Approve for both matched pairs
        token.approve(address(positionModule), 2 * makerAmount);
        token.transfer(taker1, takerAmount1);
        token.transfer(taker2, takerAmount2);
        vm.prank(taker1);
        token.approve(address(positionModule), takerAmount1);
        vm.prank(taker2);
        token.approve(address(positionModule), takerAmount2);

        // Create first matched pair (3.37x)
        positionModule.createMatchedPair(
            specId, 33_700_000, PositionType.Upper, address(this), makerAmount, taker1, takerAmount1, 0, 0
        );

        // Create second matched pair (3.38x)
        positionModule.createMatchedPair(
            specId, 33_800_000, PositionType.Upper, address(this), makerAmount, taker2, takerAmount2, 0, 0
        );

        // Verify takers received Lower positions with matched amounts
        Position memory takerPos1 = positionModule.getPosition(specId, taker1, id1, PositionType.Lower);
        Position memory takerPos2 = positionModule.getPosition(specId, taker2, id2, PositionType.Lower);

        assertGt(takerPos1.matchedAmount, 0, "Taker 1 should have matched amount");
        assertGt(takerPos2.matchedAmount, 0, "Taker 2 should have matched amount");
    }

    /**
     * @notice Test 6: Test boundary conditions
     * @dev Tests MIN_ODDS, MAX_ODDS, and odds near 2.0x
     */
    function testGetOrCreateOddsPairId_EdgeCases() public view {
        // Subtest 1: MIN_ODDS (1.01x)
        (uint128 minUpperId, uint64 minUpper, ) = _computeOddsPairId(
            positionModule,
            positionModule.MIN_ODDS(),
            PositionType.Upper
        );
        assertEq(minUpperId, 0, "MIN_ODDS Upper should have oddsPairId=0");
        assertEq(minUpper, positionModule.MIN_ODDS(), "Upper should be MIN_ODDS");

        (uint128 minLowerId, , uint64 minLowerL) = _computeOddsPairId(
            positionModule,
            positionModule.MIN_ODDS(),
            PositionType.Lower
        );
        assertEq(minLowerId, 10000, "MIN_ODDS Lower should have oddsPairId=10000");
        assertEq(minLowerL, positionModule.MIN_ODDS(), "Lower should be MIN_ODDS");

        // Subtest 2: MAX_ODDS (101.00x)
        (uint128 maxUpperId, uint64 maxUpper, ) = _computeOddsPairId(
            positionModule,
            positionModule.MAX_ODDS(),
            PositionType.Upper
        );
        uint128 expectedMaxId = uint128((positionModule.MAX_ODDS() - positionModule.MIN_ODDS()) / positionModule.ODDS_INCREMENT());
        assertEq(maxUpperId, expectedMaxId, "MAX_ODDS Upper should have correct oddsPairId");
        assertEq(maxUpper, positionModule.MAX_ODDS(), "Upper should be MAX_ODDS");

        (uint128 maxLowerId, , uint64 maxLowerL) = _computeOddsPairId(
            positionModule,
            positionModule.MAX_ODDS(),
            PositionType.Lower
        );
        assertEq(maxLowerId, expectedMaxId + 10000, "MAX_ODDS Lower should have oddsPairId with +10000 offset");
        assertEq(maxLowerL, positionModule.MAX_ODDS(), "Lower should be MAX_ODDS");

        // Subtest 3: Near 2.0x (where inverse ~ maker odds)
        (uint128 twoXId, uint64 twoXUpper, uint64 twoXLower) = _computeOddsPairId(
            positionModule,
            20_000_000,
            PositionType.Upper
        );
        uint128 expectedTwoXId = uint128((20_000_000 - positionModule.MIN_ODDS()) / positionModule.ODDS_INCREMENT());
        assertEq(twoXId, expectedTwoXId, "2.0x should have correct oddsPairId");
        assertEq(twoXUpper, 20_000_000, "Upper should be 2.0x");

        // At 2.0x, the inverse should also be very close to 2.0x
        assertTrue(twoXLower >= 19_900_000 && twoXLower <= 20_100_000, "Inverse of 2.0x should be close to 2.0x");

        // Verify the upper and lower odds are very close
        uint256 diff = twoXUpper > twoXLower ? twoXUpper - twoXLower : twoXLower - twoXUpper;
        assertTrue(diff < 200_000, "At 2.0x, upper and lower should be very close");
    }

    // --- CLAIM POSITION EDGE CASE TESTS ---

    /**
     * @notice Test that claimPosition reverts with NoPayout when matchedAmount=0
     * @dev This scenario occurs when a user transfers their entire matched position via secondary market
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

        uint256 specId = mockSpeculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );

        // Create matched pair: maker=this, taker=taker
        uint64 odds = 20_000_000; // 2.00 odds
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 10_000_000; // At 2.00 odds, taker = maker

        token.approve(address(localPositionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(localPositionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            localPositionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            makerAmountRemaining,
            taker,
            takerAmount
        );

        // Transfer entire matched position to another user via secondary market
        address buyer = address(0xBEEF);
        mockMarket.transferPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            buyer,
            10_000_000
        );

        // Verify maker's position now has matchedAmount=0
        Position memory makerPos = localPositionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertEq(makerPos.matchedAmount, 0, "matchedAmount should be 0 after full transfer");
        assertTrue(makerPos.poolId != 0, "poolId should still be set");

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
        localPositionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
    }

    /**
     * @notice Test that calling claimPosition twice reverts with AlreadyClaimed
     */
    function testClaimPosition_RevertsWithAlreadyClaimed_OnDoubleClaim() public {
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );

        // Create matched pair
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            address(this),
            makerAmountRemaining,
            taker,
            takerAmount
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
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);

        // Second claim should revert with AlreadyClaimed
        vm.expectRevert(PositionModule.PositionModule__AlreadyClaimed.selector);
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
    }

    /**
     * @notice Test that claimPosition with wrong oddsPairId reverts with PositionDoesNotExist
     */
    function testClaimPosition_RevertsWithPositionDoesNotExist_WrongOddsPairId() public {
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            leaderboardId
        );

        // Create matched pair at odds 1.80
        uint64 odds = 18_000_000;
        uint256 makerAmountRemaining = 10_000_000;
        uint256 takerAmount = 8_000_000;

        token.approve(address(positionModule), makerAmountRemaining);
        vm.prank(taker);
        token.approve(address(positionModule), takerAmount);

        (uint128 correctOddsPairId, , ) = _computeOddsPairId(
            positionModule,
            odds,
            PositionType.Upper
        );
        positionModule.createMatchedPair(
            specId, odds, PositionType.Upper, address(this), makerAmountRemaining, taker, takerAmount, 0, 0
        );

        // Get a different oddsPairId (for 2.00 odds)
        (uint128 wrongOddsPairId, , ) = _computeOddsPairId(
            positionModule,
            20_000_000,
            PositionType.Upper
        );
        assertTrue(correctOddsPairId != wrongOddsPairId, "OddsPairIds should be different");

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

        // Attempt to claim with wrong oddsPairId should revert
        vm.expectRevert(PositionModule.PositionModule__PositionDoesNotExist.selector);
        positionModule.claimPosition(specId, wrongOddsPairId, PositionType.Upper);
    }

    // --- TRANSFER POSITION ACCUMULATION TEST ---

    /**
     * @notice Test that transferPosition correctly accumulates matchedAmount when recipient has existing matched position
     */
    function testTransferPosition_AccumulatesMatchedAmount() public {
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            leaderboardId
        );

        uint64 odds = 20_000_000; // 2.00 odds
        uint256 buyerAmount = 5_000_000;
        uint256 buyerTakerAmount = 5_000_000; // At 2.00 odds, taker = maker

        // Step 1: Buyer (user) creates a matched position (5 USDC)
        vm.prank(user);
        token.approve(address(positionModule), buyerAmount);
        address taker1 = address(0xCAF1);
        token.transfer(taker1, buyerTakerAmount);
        vm.prank(taker1);
        token.approve(address(positionModule), buyerTakerAmount);

        (, uint128 oddsPairId) = _helperCreateMatchedPair(
            positionModule,
            specId,
            odds,
            PositionType.Upper,
            user,
            buyerAmount,
            taker1,
            buyerTakerAmount
        );

        // Verify buyer's matched position
        Position memory buyerPosBefore = positionModule.getPosition(
            specId,
            user,
            oddsPairId,
            PositionType.Upper
        );
        assertEq(buyerPosBefore.matchedAmount, buyerAmount, "Buyer should have 5 USDC matched");

        // Step 2: Seller creates a matched position (10 USDC)
        address seller = address(0x5E11);
        uint256 sellerAmount = 10_000_000;
        uint256 sellerTakerAmount = 10_000_000;

        token.transfer(seller, sellerAmount);
        vm.prank(seller);
        token.approve(address(positionModule), sellerAmount);

        address taker2 = address(0xCAF2);
        token.transfer(taker2, sellerTakerAmount);
        vm.prank(taker2);
        token.approve(address(positionModule), sellerTakerAmount);

        positionModule.createMatchedPair(
            specId, odds, PositionType.Upper, seller, sellerAmount, taker2, sellerTakerAmount, 0, 0
        );

        // Step 3: Transfer seller's position to buyer
        MockMarket market = new MockMarket(address(positionModule));
        core.setMarketRole(address(market), true);
        market.transferPosition(
            specId,
            seller,
            oddsPairId,
            PositionType.Upper,
            user,
            sellerAmount
        );

        // Step 4: Verify buyer's matchedAmount is ACCUMULATED (5 + 10 = 15)
        Position memory buyerPosAfter = positionModule.getPosition(
            specId,
            user,
            oddsPairId,
            PositionType.Upper
        );
        assertEq(
            buyerPosAfter.matchedAmount,
            buyerAmount + sellerAmount,
            "Buyer's matchedAmount should accumulate (5 + 10 = 15)"
        );
    }
}
