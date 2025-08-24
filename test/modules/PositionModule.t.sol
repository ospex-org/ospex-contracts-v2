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
import {PositionType, Contest, ContestStatus, Position, WinSide, OddsPair, LeagueId} from "../../src/core/OspexTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockSpeculationModule} from "../mocks/MockSpeculationModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

contract PositionModuleTest is Test {
    using stdStorage for StdStorage;

    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;

    address user = address(0xBEEF);
    address protocolReceiver = address(0xFEED);

    MockContestModule mockContestModule;

    // leaderboard Id and allocation set to 0 for testing
    uint256 leaderboardId = 0;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();
        // Fund user
        token.transfer(user, 1_000_000_000);
        
        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(
            address(core),
            address(token)
        );
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);
        
        // Register a mock contest module so SpeculationModule can call getContest
        mockContestModule = new MockContestModule();
        
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
        
        // Register this test contract as ORACLE_MODULE so it can call createSpeculation
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

    function testCreateUnmatchedPair_HappyPath() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        vm.prank(address(this));
        positionModule.createUnmatchedPair(
            specId,
            11_000_000, // 1.10 odds
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            positionModule.getOrCreateOddsPairId(
                11_000_000,
                PositionType.Upper
            ),
            PositionType.Upper
        );
        assertEq(pos.unmatchedAmount, 1_000_000);
        assertEq(uint(pos.positionType), uint(PositionType.Upper));
        assertFalse(pos.claimed);
    }

    function testCreateUnmatchedPair_RevertsOnInvalidOdds() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionModule.PositionModule__OddsOutOfRange.selector,
                1_000_000
            )
        );
        positionModule.createUnmatchedPair(
            specId,
            1_000_000, // Below MIN_ODDS
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
    }

    function testCreateUnmatchedPair_RevertsIfPositionAlreadyExists() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 2_000_000); // Approve enough for two positions
        
        // Create the first position
        positionModule.createUnmatchedPair(
            specId,
            11_000_000, // 1.10 odds
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        
        // Try to create the exact same position again - should revert
        vm.expectRevert(PositionModule.PositionModule__PositionAlreadyExists.selector);
        positionModule.createUnmatchedPair(
            specId,
            11_000_000, // Same odds
            0, // Same unmatchedExpiry
            PositionType.Upper, // Same position type
            1_000_000, // Same amount
            0
        );
    }

    function testCreateUnmatchedPair_RevertsIfSpeculationNotOpen() public {
        // Create a speculation that starts soon
        uint32 startTime = uint32(block.timestamp + 1 hours);

        // Deploy mock scorer and register it
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Settle the speculation (simulate contest started and settled)
        vm.warp(startTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set to Scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        speculationModule.settleSpeculation(specId);

        // Try to create an unmatched pair after speculation is closed
        token.approve(address(positionModule), 1_000_000);
        vm.expectRevert(
            PositionModule.PositionModule__SpeculationNotOpen.selector
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
    }

    function testCreateUnmatchedPair_RevertsOnAmountOutOfRange() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1);
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1, // Below min
            0
        );
    }

    function testAdjustUnmatchedPair_HappyPath() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 2_000_000);
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        // Add 1 USDC to the position
        positionModule.adjustUnmatchedPair(
            specId,
            positionModule.getOrCreateOddsPairId(
                11_000_000,
                PositionType.Upper
            ),
            0, // newUnmatchedExpiry
            PositionType.Upper,
            int256(1_000_000),
            0
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            positionModule.getOrCreateOddsPairId(
                11_000_000,
                PositionType.Upper
            ),
            PositionType.Upper
        );
        assertEq(pos.unmatchedAmount, 2_000_000);
    }

    function testAdjustUnmatchedPair_RevertsIfReduceAmountTooHigh() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 2 * 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        emit log_named_uint("oddsPairId", oddsPairId);
        emit log_named_uint("unmatchedAmount", pos.unmatchedAmount);
        emit log_named_uint("min", speculationModule.s_minSpeculationAmount());
        emit log_named_uint("max", speculationModule.s_maxSpeculationAmount());
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        try
            positionModule.adjustUnmatchedPair(
                specId,
                oddsPairId,
                0, // unmatchedExpiry
                PositionType.Upper,
                -int256(2 * 1_000_000),
                0
            )
        {
            emit log("adjustUnmatchedPair did NOT revert as expected");
        } catch (bytes memory reason) {
            emit log_bytes(reason);
        }
    }

    function testAdjustUnmatchedPair_RevertsIfUnmatchedAmountZero() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 2 * 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        // Remove all unmatched amount
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            -int256(1_000_000),
            0
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        emit log_named_uint("oddsPairId", oddsPairId);
        emit log_named_uint("unmatchedAmount", pos.unmatchedAmount);
        emit log_named_uint("min", speculationModule.s_minSpeculationAmount());
        emit log_named_uint("max", speculationModule.s_maxSpeculationAmount());
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        try
            positionModule.adjustUnmatchedPair(
                specId,
                oddsPairId,
                0, // unmatchedExpiry
                PositionType.Upper,
                int256(1_000_000),
                0
            )
        {
            emit log("adjustUnmatchedPair did NOT revert as expected");
        } catch (bytes memory reason) {
            emit log_bytes(reason);
        }
    }

    function testAdjustUnmatchedPair_RevertsIfAmountExceedsMax() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 3 * 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        emit log_named_uint("oddsPairId", oddsPairId);
        emit log_named_uint("unmatchedAmount", pos.unmatchedAmount);
        emit log_named_uint("min", speculationModule.s_minSpeculationAmount());
        emit log_named_uint("max", speculationModule.s_maxSpeculationAmount());
        vm.expectRevert(PositionModule.PositionModule__InvalidAmount.selector);
        try
            positionModule.adjustUnmatchedPair(
                specId,
                oddsPairId,
                0, // unmatchedExpiry
                PositionType.Upper,
                int256(1_000_000),
                0
            )
        {
            emit log("adjustUnmatchedPair did NOT revert as expected");
        } catch (bytes memory reason) {
            emit log_bytes(reason);
        }
    }

    function testClaimPosition_HappyPath() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Deploy mock scorer and register it
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        vm.warp(futureTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set to Scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        speculationModule.settleSpeculation(specId);
        positionModule.claimPosition(
            specId,
            positionModule.getOrCreateOddsPairId(
                11_000_000,
                PositionType.Upper
            ),
            PositionType.Upper
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            positionModule.getOrCreateOddsPairId(
                11_000_000,
                PositionType.Upper
            ),
            PositionType.Upper
        );
        assertTrue(pos.claimed);
        assertEq(pos.unmatchedAmount, 0);
        assertEq(pos.matchedAmount, 0);
    }

    function testAdjustUnmatchedPair_HappyPathReduce() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 2 * 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            2 * 1_000_000,
            0
        );
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            -int256(1_000_000),
            0
        );
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertEq(pos.unmatchedAmount, 1_000_000);
    }

    function testAdjustUnmatchedPair_HappyPathAddReduceAdd() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 4 * 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            int256(1_000_000),
            0
        ); // add 1 (total 2)
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            -int256(1_000_000),
            0
        ); // reduce 1 (total 1)
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            int256(2 * 1_000_000),
            0
        ); // add 2 (total 3)
        Position memory pos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        assertEq(pos.unmatchedAmount, 3 * 1_000_000);
    }

    function testAdjustUnmatchedPair_RevertsIfPositionDoesNotExist() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        vm.expectRevert(
            PositionModule.PositionModule__PositionDoesNotExist.selector
        );
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            int256(1_000_000),
            0
        );
    }

    function testAdjustUnmatchedPair_RevertsIfAlreadyClaimed() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Deploy mock scorer and register it
        MockScorerModule mockScorer = new MockScorerModule();
        // Set the default win side to Away
        mockScorer.setDefaultWinSide(WinSide.Away);

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer), // Use our mock scorer instead of 0x1234
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        vm.warp(futureTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        // Optionally set specific win side for this contestId and theNumber
        // mockScorer.setWinSide(1, 42, WinSide.Away);

        speculationModule.settleSpeculation(specId);
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
        vm.expectRevert(
            PositionModule.PositionModule__SpeculationNotOpen.selector
        );
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            int256(1_000_000),
            0
        );
    }

    function testCompleteUnmatchedPair_HappyPath() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        address taker = address(0xCAFE);
        token.transfer(taker, 10_000_000); // 10 USDC
        uint64 upperOdds = 18_000_000;
        uint64 testOdds = upperOdds;
        token.approve(address(positionModule), 10_000_000); // 10 USDC
        positionModule.createUnmatchedPair(
            specId,
            testOdds,
            0, // unmatchedExpiry
            PositionType.Upper,
            10_000_000, // 10 USDC
            0
        );
        vm.startPrank(taker);
        token.approve(address(positionModule), 8_000_000); // 8 USDC
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            testOdds,
            PositionType.Upper
        );
        uint256 takerAmount = (10_000_000 * (upperOdds - 10_000_000)) /
            10_000_000; // 8_000_000
        emit log_named_uint(
            "Allowance for PositionModule",
            token.allowance(taker, address(positionModule))
        );
        positionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            takerAmount
        );
        vm.stopPrank();
        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
        Position memory takerPos = positionModule.getPosition(
            specId,
            taker,
            oddsPairId,
            PositionType.Lower
        );
        assertEq(makerPos.unmatchedAmount, 0);
        assertEq(makerPos.matchedAmount, 10_000_000);
        assertEq(takerPos.unmatchedAmount, 0);
        assertEq(takerPos.matchedAmount, takerAmount);
    }

    function testCompleteUnmatchedPair_RevertsIfPartialFillNotAccepted()
        public
    {
        // This test is no longer relevant as acceptPartialFill is removed.
    }

    function testTransferPosition_HappyPath() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        uint256 tokenUnit = 10_000_000; // 10 USDC
        token.approve(address(positionModule), tokenUnit);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            tokenUnit,
            0
        );
        address taker = address(0xCAFE);
        token.transfer(taker, tokenUnit);
        uint256 matchableAmount = (tokenUnit * (11_000_000 - 10_000_000)) /
            10_000_000;
        vm.startPrank(taker);
        token.approve(address(positionModule), tokenUnit);
        positionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            matchableAmount
        );
        vm.stopPrank();
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
            address(this),
            leaderboardId
        );
        uint256 tokenUnit = 10_000_000; // 10 USDC
        token.approve(address(positionModule), tokenUnit);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            tokenUnit,
            0
        );
        address taker = address(0xCAFE);
        token.transfer(taker, tokenUnit);
        uint256 matchableAmount = (tokenUnit * (11_000_000 - 10_000_000)) /
            10_000_000;
        vm.startPrank(taker);
        token.approve(address(positionModule), tokenUnit);
        positionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            matchableAmount
        );
        vm.stopPrank();
        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );
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
            address(this),
            leaderboardId
        );
        uint256 tokenUnit = 10_000_000; // 10 USDC
        token.approve(address(positionModule), tokenUnit);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            tokenUnit,
            0
        );
        address taker = address(0xCAFE);
        token.transfer(taker, tokenUnit);
        uint256 matchableAmount = (tokenUnit * (11_000_000 - 10_000_000)) /
            10_000_000;
        vm.startPrank(taker);
        token.approve(address(positionModule), tokenUnit);
        positionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            matchableAmount
        );
        vm.stopPrank();
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
        uint64 odds = 11_000_000;
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            odds,
            PositionType.Upper
        );
        OddsPair memory pair = positionModule.getOddsPair(oddsPairId);
        assertEq(pair.upperOdds, odds);
        assertEq(positionModule.getOriginalOdds(oddsPairId), odds);
        assertEq(positionModule.getInverseOdds(oddsPairId), pair.lowerOdds);
    }

    // --- _getPosition AlreadyClaimed ---
    function testGetPosition_ReturnPositionWithClaimedTrue() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Deploy mock scorer and register it
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        vm.warp(futureTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
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
        assertEq(pos.unmatchedAmount, 0);
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
        // Register the mock for this test
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

        // Create mock scorer
        MockScorerModule mockScorer = new MockScorerModule();

        // Reset to a reasonable starting time
        vm.warp(1672531200); // Jan 1, 2023
        emit log_named_uint("[Push] block.timestamp after warp", block.timestamp);

        // Test Push scenario

        emit log_named_uint("[Push] futureTime (startTimestamp)", futureTime);
        uint256 specIdPush = mockSpeculationModule.createSpeculation(
            1, // contestId 1
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(localPositionModule), 1_000_000);
        uint128 oddsPairId = localPositionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        localPositionModule.createUnmatchedPair(
            specIdPush,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        emit log_named_uint("[Push] block.timestamp before warp to end", block.timestamp);
        vm.warp(futureTime + 2 hours);
        emit log_named_uint("[Push] block.timestamp after warp to end", block.timestamp);

        // Set up the contest to be in Scored state before settling
        Contest memory contestPush = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contestPush);

        mockSpeculationModule.settleSpeculation(specIdPush);
        mockSpeculationModule.setSpeculationWinSide(specIdPush, WinSide.Push);
        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specIdPush,
            oddsPairId,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 1_000_000);

        // Reset time for Void scenario
        vm.warp(1672531200 + 1 days); // Jan 2, 2023
        emit log_named_uint("[Void] block.timestamp after warp", block.timestamp);
        futureTime2 = uint32(block.timestamp + 1 hours); // Calculate AFTER warp
        emit log_named_uint("[Void] futureTime2 (startTimestamp)", futureTime2);
        uint256 specIdVoid = mockSpeculationModule.createSpeculation(
            2, // contestId 2
            address(mockScorer),
            43,
            address(this),
            leaderboardId
        );
        token.approve(address(localPositionModule), 1_000_000);
        localPositionModule.createUnmatchedPair(
            specIdVoid,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        emit log_named_uint("[Void] block.timestamp before warp to end", block.timestamp);
        vm.warp(futureTime2 + 2 hours);
        emit log_named_uint("[Void] block.timestamp after warp to end", block.timestamp);

        // Set up the contest to be in Scored state before settling
        Contest memory contestVoid = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
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
            oddsPairId,
            PositionType.Upper
        );
        balAfter = token.balanceOf(address(this));
        assertEq(balAfter - balBefore, 1_000_000);
    }

    function testClaimPosition_WinLossScenarios() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);
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

        // Create mock scorer
        MockScorerModule mockScorer = new MockScorerModule();


        uint256 specId = mockSpeculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );
        uint256 tokenUnit = 10_000_000; // 10 USDC

        // Create Upper position
        token.approve(address(localPositionModule), tokenUnit);
        uint128 upperOddsPairId = localPositionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        localPositionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            tokenUnit,
            0
        );
        address upperTaker = address(0xCAFE);
        uint256 upperMatchableAmount = (tokenUnit * (11_000_000 - 10_000_000)) /
            10_000_000; // = 1_000_000
        token.transfer(upperTaker, upperMatchableAmount);
        vm.startPrank(upperTaker);
        token.approve(address(localPositionModule), upperMatchableAmount);
        localPositionModule.completeUnmatchedPair(
            specId,
            address(this),
            upperOddsPairId,
            PositionType.Upper,
            upperMatchableAmount
        );
        vm.stopPrank();

        // Create Lower position
        token.approve(address(localPositionModule), tokenUnit);
        uint128 lowerOddsPairId = localPositionModule.getOrCreateOddsPairId(
            18_000_000,
            PositionType.Lower
        );
        localPositionModule.createUnmatchedPair(
            specId,
            18_000_000,
            0, // unmatchedExpiry
            PositionType.Lower,
            tokenUnit,
            0
        );
        address lowerTaker = address(0xCAFF);
        uint256 lowerMatchableAmount = (tokenUnit * (18_000_000 - 10_000_000)) /
            10_000_000; // = 8_000_000
        token.transfer(lowerTaker, lowerMatchableAmount);
        vm.startPrank(lowerTaker);
        token.approve(address(localPositionModule), lowerMatchableAmount);
        localPositionModule.completeUnmatchedPair(
            specId,
            address(this),
            lowerOddsPairId,
            PositionType.Lower,
            lowerMatchableAmount
        );
        vm.stopPrank();

        vm.warp(futureTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
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
        emit log_named_uint(
            "matchedAmount (Upper win)",
            posUpper.matchedAmount
        );
        emit log_named_uint(
            "unmatchedAmount (Upper win)",
            posUpper.unmatchedAmount
        );
        emit log_named_uint(
            "positionType (Upper win)",
            uint(posUpper.positionType)
        );
        OddsPair memory pairUpper = localPositionModule.getOddsPair(
            upperOddsPairId
        );
        emit log_named_uint("upperOdds (Upper win)", pairUpper.upperOdds);
        emit log_named_uint("lowerOdds (Upper win)", pairUpper.lowerOdds);
        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId,
            upperOddsPairId,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Upper win)", balAfter - balBefore);
        emit log_named_uint("odds", 11_000_000);
        assertGt(balAfter - balBefore, tokenUnit);

        // Test win for Lower (Home)
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Home);
        Position memory posLower = localPositionModule.getPosition(
            specId,
            address(this),
            lowerOddsPairId,
            PositionType.Lower
        );
        emit log_named_uint(
            "matchedAmount (Lower win)",
            posLower.matchedAmount
        );
        emit log_named_uint(
            "unmatchedAmount (Lower win)",
            posLower.unmatchedAmount
        );
        emit log_named_uint(
            "positionType (Lower win)",
            uint(posLower.positionType)
        );
        OddsPair memory pairLower = localPositionModule.getOddsPair(
            lowerOddsPairId
        );
        emit log_named_uint("upperOdds (Lower win)", pairLower.upperOdds);
        emit log_named_uint("lowerOdds (Lower win)", pairLower.lowerOdds);
        balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId,
            lowerOddsPairId,
            PositionType.Lower
        );
        balAfter = token.balanceOf(address(this));
        emit log_named_uint("payout (Lower win)", balAfter - balBefore);
        emit log_named_uint("odds", 18_000_000);
        assertGt(balAfter - balBefore, tokenUnit);
    }

    function testClaimPosition_LoserWithUnmatchedAmount() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);
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

        // Create mock scorer
        MockScorerModule mockScorer = new MockScorerModule();


        uint256 specId = mockSpeculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );
        uint256 makerAmount = 10_000_000; // 10 USDC
        uint256 takerAmount = 1_000_000; // 1 USDC

        // Use higher odds (e.g., 2.00)
        uint64 odds = 20_000_000; // 2.00 odds
        token.approve(address(localPositionModule), makerAmount);
        uint128 oddsPairId = localPositionModule.getOrCreateOddsPairId(
            odds,
            PositionType.Upper
        );
        localPositionModule.createUnmatchedPair(
            specId,
            odds,
            0, // unmatchedExpiry
            PositionType.Upper,
            makerAmount,
            0
        );

        // Taker matches a small amount (1 USDC)
        address taker = address(0xCAFE);
        token.transfer(taker, takerAmount);
        vm.startPrank(taker);
        token.approve(address(localPositionModule), takerAmount);
        localPositionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            takerAmount
        );
        vm.stopPrank();

        // Settle speculation with Lower as winner (Upper loses)
        vm.warp(futureTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        mockSpeculationModule.settleSpeculation(specId);
        mockSpeculationModule.setSpeculationWinSide(specId, WinSide.Home);

        // Claim position: should only get back the unmatched amount (makerAmount - matched portion)
        // For odds 2.00, matched portion for 1 USDC taker is 1 USDC from maker
        // So unmatched = 10 - 1 = 9 USDC
        uint256 balBefore = token.balanceOf(address(this));
        localPositionModule.claimPosition(
            specId,
            oddsPairId,
            PositionType.Upper
        );
        uint256 balAfter = token.balanceOf(address(this));
        assertEq(
            balAfter - balBefore,
            9_000_000,
            "Should only receive unmatched amount back"
        );
    }

    function testCreateUnmatchedPair_RevertsIfExpiryInPast() public {
        // Warp to a reasonable timestamp first
        vm.warp(1672531200); // Jan 1, 2023

        // Create a speculation with future timestamp
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );

        // Set up an expiry in the past
        uint32 pastTime = uint32(block.timestamp - 1 hours);

        // Approve tokens
        token.approve(address(positionModule), 1_000_000);

        // Expect revert when trying to use past expiry
        vm.expectRevert(
            PositionModule.PositionModule__InvalidUnmatchedExpiry.selector
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            pastTime, // expiry in the past
            PositionType.Upper,
            1_000_000,
            0
        );
    }

    function testCompleteUnmatchedPair_RevertsIfExpired() public {
        uint32 expiry = uint32(block.timestamp + 1 hours);
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            expiry,
            PositionType.Upper,
            1_000_000,
            0
        );
        vm.warp(expiry + 1); // move past expiry
        address taker = address(0xCAFE);
        token.transfer(taker, 1_000_000);
        vm.startPrank(taker);
        token.approve(address(positionModule), 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        vm.expectRevert(
            PositionModule.PositionModule__UnmatchedExpired.selector
        );
        positionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            1_000_000
        );
        vm.stopPrank();
    }

    function testAdjustUnmatchedPair_RevertsIfNewExpiryInPast() public {
        // Warp to a reasonable timestamp first (e.g., Jan 1, 2023)
        vm.warp(1672531200);

        uint32 expiry = uint32(block.timestamp + 1 hours);
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            expiry,
            PositionType.Upper,
            1_000_000,
            0
        );

        // Now we can safely create a past timestamp
        uint32 pastTimestamp = uint32(block.timestamp - 1000);

        vm.expectRevert(
            PositionModule.PositionModule__InvalidUnmatchedExpiry.selector
        );
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            pastTimestamp, // timestamp in the past
            PositionType.Upper,
            int256(0),
            0
        );
    }

    function testCompleteUnmatchedPair_SucceedsIfNotExpired() public {
        // Start with a reasonable timestamp
        vm.warp(1672531200);

        uint32 expiry = uint32(block.timestamp + 1 hours);
        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );

        // Use odds of 2.0 to make the math clean
        uint64 odds = 20_000_000; // 2.0 odds
        uint256 makerAmount = 10_000_000; // 10 USDC

        token.approve(address(positionModule), makerAmount);
        positionModule.createUnmatchedPair(
            specId,
            odds,
            expiry, // Set expiry
            PositionType.Upper,
            makerAmount,
            0
        );

        // With 2.0 odds, taker needs the same amount as maker
        address taker = address(0xCAFE);
        uint256 takerAmount = 10_000_000; // 10 USDC (equal to maker with 2.0 odds)
        token.transfer(taker, takerAmount);

        vm.startPrank(taker);
        token.approve(address(positionModule), takerAmount);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            odds,
            PositionType.Upper
        );

        // Should succeed (no revert)
        positionModule.completeUnmatchedPair(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper,
            takerAmount
        );
        vm.stopPrank();

        // Verify positions were created correctly
        Position memory makerPos = positionModule.getPosition(
            specId,
            address(this),
            oddsPairId,
            PositionType.Upper
        );

        Position memory takerPos = positionModule.getPosition(
            specId,
            taker,
            oddsPairId,
            PositionType.Lower
        );

        // Maker should have all matched
        assertEq(
            makerPos.matchedAmount,
            10_000_000,
            "Incorrect maker matched amount"
        );
        assertEq(
            makerPos.unmatchedAmount,
            0,
            "Maker should have no unmatched amount"
        );

        // Taker should have all matched
        assertEq(
            takerPos.matchedAmount,
            10_000_000,
            "Incorrect taker matched amount"
        );
        assertEq(
            takerPos.unmatchedAmount,
            0,
            "Taker should have no unmatched amount"
        );
    }

    function testAdjustUnmatchedPair_RevertsIfSpeculationNotOpen() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Deploy mock scorer and register it
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );
        token.approve(address(positionModule), 1_000_000);
        uint128 oddsPairId = positionModule.getOrCreateOddsPairId(
            11_000_000,
            PositionType.Upper
        );
        positionModule.createUnmatchedPair(
            specId,
            11_000_000,
            0, // unmatchedExpiry
            PositionType.Upper,
            1_000_000,
            0
        );
        vm.warp(futureTime + 2 hours);

        // Set up the contest to be in Scored state before settling
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set the contest as scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        speculationModule.settleSpeculation(specId);
        vm.expectRevert(
            PositionModule.PositionModule__SpeculationNotOpen.selector
        );
        positionModule.adjustUnmatchedPair(
            specId,
            oddsPairId,
            0, // unmatchedExpiry
            PositionType.Upper,
            int256(1_000_000),
            0
        );
    }

    function testCompleteUnmatchedPairBatch_HappyPath() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        address taker = address(0xCAFE);
        address maker1 = address(this);
        address maker2 = address(0xBEEF);
        uint64 odds1 = 18_000_000; // 1.80
        uint64 odds2 = 15_000_000; // 1.50
        uint256 maker1Amount = 10_000_000; // 10 USDC
        uint256 maker2Amount = 6_000_000; // 6 USDC
        // Fund and approve makers
        token.transfer(maker2, maker2Amount);
        token.approve(address(positionModule), maker1Amount);
        vm.prank(maker2);
        token.approve(address(positionModule), maker2Amount);
        // Create unmatched pairs for both makers
        positionModule.createUnmatchedPair(
            specId,
            odds1,
            0,
            PositionType.Upper,
            maker1Amount,
            0
        );
        vm.prank(maker2);
        positionModule.createUnmatchedPair(
            specId,
            odds2,
            0,
            PositionType.Upper,
            maker2Amount,
            0
        );
        // Calculate taker amounts
        uint128 oddsPairId1 = positionModule.getOrCreateOddsPairId(
            odds1,
            PositionType.Upper
        );
        uint128 oddsPairId2 = positionModule.getOrCreateOddsPairId(
            odds2,
            PositionType.Upper
        );
        uint256 takerAmount1 = (maker1Amount * (odds1 - 10_000_000)) /
            10_000_000;
        uint256 takerAmount2 = (maker2Amount * (odds2 - 10_000_000)) /
            10_000_000;
        // Fund and approve taker
        token.transfer(taker, takerAmount1 + takerAmount2);
        vm.startPrank(taker);
        token.approve(address(positionModule), takerAmount1 + takerAmount2);
        // Call batch
        address[] memory makers = new address[](2);
        makers[0] = maker1;
        makers[1] = maker2;
        uint128[] memory oddsPairIds = new uint128[](2);
        oddsPairIds[0] = oddsPairId1;
        oddsPairIds[1] = oddsPairId2;
        PositionType[] memory makerPositionTypes = new PositionType[](2);
        makerPositionTypes[0] = PositionType.Upper;
        makerPositionTypes[1] = PositionType.Upper;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = takerAmount1;
        amounts[1] = takerAmount2;
        positionModule.completeUnmatchedPairBatch(
            specId,
            makers,
            oddsPairIds,
            makerPositionTypes,
            amounts
        );
        vm.stopPrank();
        // Check both positions are matched
        Position memory maker1Pos = positionModule.getPosition(
            specId,
            maker1,
            oddsPairId1,
            PositionType.Upper
        );
        Position memory taker1Pos = positionModule.getPosition(
            specId,
            taker,
            oddsPairId1,
            PositionType.Lower
        );
        assertEq(maker1Pos.unmatchedAmount, 0);
        assertEq(maker1Pos.matchedAmount, maker1Amount);
        assertEq(taker1Pos.matchedAmount, takerAmount1);
        Position memory maker2Pos = positionModule.getPosition(
            specId,
            maker2,
            oddsPairId2,
            PositionType.Upper
        );
        Position memory taker2Pos = positionModule.getPosition(
            specId,
            taker,
            oddsPairId2,
            PositionType.Lower
        );
        assertEq(maker2Pos.unmatchedAmount, 0);
        assertEq(maker2Pos.matchedAmount, maker2Amount);
        assertEq(taker2Pos.matchedAmount, takerAmount2);
    }

    function testCompleteUnmatchedPairBatch_RevertsOnArrayLengthMismatch()
        public
    {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        address[] memory makers = new address[](2);
        makers[0] = address(this);
        makers[1] = address(0xBEEF);
        uint128[] memory oddsPairIds = new uint128[](1);
        oddsPairIds[0] = positionModule.getOrCreateOddsPairId(
            18_000_000,
            PositionType.Upper
        );
        PositionType[] memory makerPositionTypes = new PositionType[](2);
        makerPositionTypes[0] = PositionType.Upper;
        makerPositionTypes[1] = PositionType.Upper;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000;
        amounts[1] = 1_000_000;
        vm.expectRevert(
            PositionModule.PositionModule__ArrayLengthMismatch.selector
        );
        positionModule.completeUnmatchedPairBatch(
            specId,
            makers,
            oddsPairIds,
            makerPositionTypes,
            amounts
        );
    }

    function testCompleteUnmatchedPairBatch_RevertsIfOneFails() public {

        uint256 specId = speculationModule.createSpeculation(
            1,
            address(0x1234),
            42,
            address(this),
            leaderboardId
        );
        address taker = address(0xCAFE);
        address maker1 = address(this);
        address maker2 = address(0xBEEF);
        uint64 odds1 = 18_000_000; // 1.80
        uint64 odds2 = 15_000_000; // 1.50
        uint256 maker1Amount = 10_000_000; // 10 USDC
        uint256 maker2Amount = 6_000_000; // 6 USDC
        // Fund and approve makers
        token.transfer(maker2, maker2Amount);
        token.approve(address(positionModule), maker1Amount);
        vm.prank(maker2);
        token.approve(address(positionModule), maker2Amount);
        // Create unmatched pairs for both makers
        positionModule.createUnmatchedPair(
            specId,
            odds1,
            0,
            PositionType.Upper,
            maker1Amount,
            0
        );
        vm.prank(maker2);
        positionModule.createUnmatchedPair(
            specId,
            odds2,
            0,
            PositionType.Upper,
            maker2Amount,
            0
        );
        // Calculate taker amounts, but make second one too large
        uint128 oddsPairId1 = positionModule.getOrCreateOddsPairId(
            odds1,
            PositionType.Upper
        );
        uint128 oddsPairId2 = positionModule.getOrCreateOddsPairId(
            odds2,
            PositionType.Upper
        );
        uint256 takerAmount1 = (maker1Amount * (odds1 - 10_000_000)) /
            10_000_000;
        uint256 takerAmount2 = ((maker2Amount * (odds2 - 10_000_000)) /
            10_000_000) + 1; // too much
        // Fund and approve taker
        token.transfer(taker, takerAmount1 + takerAmount2);
        vm.startPrank(taker);
        token.approve(address(positionModule), takerAmount1 + takerAmount2);
        address[] memory makers = new address[](2);
        makers[0] = maker1;
        makers[1] = maker2;
        uint128[] memory oddsPairIds = new uint128[](2);
        oddsPairIds[0] = oddsPairId1;
        oddsPairIds[1] = oddsPairId2;
        PositionType[] memory makerPositionTypes = new PositionType[](2);
        makerPositionTypes[0] = PositionType.Upper;
        makerPositionTypes[1] = PositionType.Upper;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = takerAmount1;
        amounts[1] = takerAmount2;
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionModule
                    .PositionModule__InsufficientUnmatchedAmount
                    .selector,
                takerAmount2,
                (maker2Amount * (odds2 - 10_000_000)) / 10_000_000
            )
        );
        positionModule.completeUnmatchedPairBatch(
            specId,
            makers,
            oddsPairIds,
            makerPositionTypes,
            amounts
        );
        vm.stopPrank();
    }
}
