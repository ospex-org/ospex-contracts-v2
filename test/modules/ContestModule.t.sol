// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {ContestModule} from "../../src/modules/ContestModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {Contest, ContestMarket, ContestStatus, FeeType, LeagueId, Leaderboard} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

// Simple mock for leaderboard validation in processFee
contract MockLeaderboardModule {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

contract ContestModuleTest is Test {
    ContestModule contestModule;
    TreasuryModule treasuryModule;
    OspexCore core;
    MockERC20 mockToken;
    MockLeaderboardModule mockLeaderboardModule;
    address oracleModule = address(0xBEEF);
    address scoreManager = address(0xCAFE);
    address notOracle = address(0xBAD);
    address contestCreator = address(0x123);
    address admin = address(0x1234);
    
    // Mock scorer addresses for updateContestMarkets tests
    address moneylineScorer = address(0xAAA1);
    address spreadScorer = address(0xAAA2);
    address totalScorer = address(0xAAA3);

    // Leaderboard Id and allocations set to 0 for testing
    uint256 leaderboardId = 0;

    function setUp() public {
        core = new OspexCore();
        // Register Oracle Module

        // Deploy mock token
        mockToken = new MockERC20();

        // Fund account for fee test
        mockToken.transfer(contestCreator, 10_000_000);

        vm.startPrank(address(this));
        core.registerModule(keccak256("ORACLE_MODULE"), oracleModule);
        // Deploy FeeModule with proper addresses (not zero)
        treasuryModule = new TreasuryModule(address(core), address(mockToken), address(0x2));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        // Deploy and register Contest Module
        contestModule = new ContestModule(address(core), bytes32("hash"), bytes32("markets_hash"));
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(contestModule)
        );

        // Deploy and register MockLeaderboardModule for processFee validation
        mockLeaderboardModule = new MockLeaderboardModule();
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));
        
        // Register mock scorer modules for updateContestMarkets tests
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), moneylineScorer);
        core.registerModule(keccak256("SPREAD_SCORER_MODULE"), spreadScorer);
        core.registerModule(keccak256("TOTAL_SCORER_MODULE"), totalScorer);
        
        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();
    }

    function testConstructor_RevertsOnZeroCore() public {
        vm.expectRevert(
            ContestModule.ContestModule__InvalidCoreAddress.selector
        );
        new ContestModule(address(0), bytes32("hash"), bytes32("markets_hash"));
    }

    function testGetModuleType() public view {
        assertEq(contestModule.getModuleType(), keccak256("CONTEST_MODULE"));
    }

    function testCreateContest_OnlyOracleModule() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.rundownId, "rd");
        assertEq(c.sportspageId, "sp");
        assertEq(c.jsonoddsId, "jo");
        assertEq(c.scoreContestSourceHash, bytes32("hash"));
        assertEq(c.contestCreator, contestCreator);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Unverified));
    }

    function testCreateContest_RevertsIfNotOracleModule() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
    }

    function testSetContestStatus_OnlyOracleModule() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        vm.prank(oracleModule);
        // Set start time to current block timestamp, may need to change this to some future time and warp ahead when/if appropriate
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));
        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Verified));
    }

    function testSetContestStatus_RevertsIfNotOracleModule() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        // Set start time to current block timestamp, may need to change this to some future time and warp ahead when/if appropriate
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));
    }

    function testSetScores_OracleModuleCanAlwaysSet() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        vm.prank(oracleModule);
        contestModule.setScores(contestId, 11, 22);
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.awayScore, 11);
        assertEq(c.homeScore, 22);
    }

    // This test assumes contestStartTimes[contestId] is set to block.timestamp at contest creation.
    // If not, this test should be commented out or marked as TODO until Oracle integration is complete.
    function testSetScores_ScoreManagerAfterWaitPeriod() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        // Verify the contest by setting start time
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        // Warp forward by 3 days to simulate wait period passing
        vm.warp(block.timestamp + 3 days);
        // Grant SCORE_MANAGER_ROLE to scoreManager
        bytes32 scoreManagerRole = keccak256("SCORE_MANAGER_ROLE");
        vm.prank(address(this));
        core.grantRole(scoreManagerRole, scoreManager);
        vm.prank(scoreManager);
        contestModule.scoreContestManually(contestId, 33, 44);
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.awayScore, 33);
        assertEq(c.homeScore, 44);
    }

    function testScoreContestManually_RevertsIfContestNotVerified() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        // Grant SCORE_MANAGER_ROLE to scoreManager
        bytes32 scoreManagerRole = keccak256("SCORE_MANAGER_ROLE");
        vm.prank(address(this));
        core.grantRole(scoreManagerRole, scoreManager);

        // Contest remains unverified, expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__ContestNotVerified.selector,
                contestId
            )
        );
        vm.prank(scoreManager);
        contestModule.scoreContestManually(contestId, 33, 44);
    }

    function testScoreContestManually_RevertsIfManualScoreWaitPeriodNotMet()
        public
    {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );

        // Verify the contest by setting start time
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        // Warp forward but less than required wait period (only 1 day)
        vm.warp(block.timestamp + 1 days);

        // Grant SCORE_MANAGER_ROLE to scoreManager
        bytes32 scoreManagerRole = keccak256("SCORE_MANAGER_ROLE");
        vm.prank(address(this));
        core.grantRole(scoreManagerRole, scoreManager);

        // Expect revert due to wait period not met
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule
                    .ContestModule__ManualScoreWaitPeriodNotMet
                    .selector,
                contestId,
                contestModule.MANUAL_SCORE_WAIT_PERIOD() - 1 days
            )
        );
        vm.prank(scoreManager);
        contestModule.scoreContestManually(contestId, 33, 44);
    }

    function testScoreContestManually_RevertsIfContestNotStarted() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );

        // Verify the contest but set start time in the future
        uint32 futureTime = uint32(block.timestamp + 1 days);
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, futureTime);

        // Grant SCORE_MANAGER_ROLE to scoreManager
        bytes32 scoreManagerRole = keccak256("SCORE_MANAGER_ROLE");
        vm.prank(address(this));
        core.grantRole(scoreManagerRole, scoreManager);

        // Expect revert due to contest not started
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__ContestNotStarted.selector,
                contestId,
                futureTime - block.timestamp
            )
        );
        vm.prank(scoreManager);
        contestModule.scoreContestManually(contestId, 33, 44);
    }

    function testSetScores_RevertsIfNotOracleOrScoreManager() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.setScores(contestId, 1, 2);
    }

    // This test covers the revert branch for manual score wait period.
    // For now, we just check that it reverts. Once Oracle integration is done and start time is set, update to check for the exact custom error.
    function testSetScores_ScoreManagerBeforeWaitPeriod_Reverts() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        // No warp, so still at creation time
        bytes32 scoreManagerRole = keccak256("SCORE_MANAGER_ROLE");
        vm.prank(address(this));
        core.grantRole(scoreManagerRole, scoreManager);
        // setScores uses the onlyOracleModule modifier, so scoreManager is rejected
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                scoreManager
            )
        );
        vm.prank(scoreManager);
        contestModule.setScores(contestId, 33, 44);
    }

    function testGetContest_ReturnsCorrectData() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.rundownId, "rd");
        assertEq(c.sportspageId, "sp");
        assertEq(c.jsonoddsId, "jo");
        assertEq(c.scoreContestSourceHash, bytes32("hash"));
        assertEq(c.contestCreator, contestCreator);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Unverified));
    }

    function testCreateContest_WithFee_ChargesFee() public {
        // Set a nonzero fee for ContestCreation using admin
        uint256 fee = 1_000_000; // 1 USDC (6 decimals)
        vm.prank(admin);
        treasuryModule.setFeeRates(FeeType.ContestCreation, fee);

        // Mint tokens to contestCreator and approve FeeModule
        vm.prank(contestCreator);
        mockToken.approve(address(treasuryModule), fee);

        // Use Foundry's expectCall to check that handleFee is called
        vm.expectCall(
            address(treasuryModule),
            abi.encodeWithSelector(
                treasuryModule.processFee.selector,
                contestCreator,
                fee,
                FeeType.ContestCreation,
                leaderboardId
            )
        );

        // Call createContest as OracleModule
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd",
            "sp",
            "jo",
            bytes32("hash"),
            contestCreator,
            leaderboardId
        );

        // Check that the contest was created as normal
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.rundownId, "rd");

        // Check that the contestCreator's balance decreased by the fee
        assertEq(mockToken.balanceOf(contestCreator), 10_000_000 - fee);
    }

    function testSetCreateContestSourceHash_OnlyAdmin() public {
        bytes32 newHash = bytes32("new_hash");
        // bytes32 oldHash = bytes32("hash"); // Original hash from constructor
        
        // Test successful update by admin
        vm.prank(admin);
        contestModule.setCreateContestSourceHash(newHash);
        
        // Verify the hash was updated
        assertEq(contestModule.s_createContestSourceHash(), newHash);
    }

    function testSetCreateContestSourceHash_RevertsIfNotAdmin() public {
        bytes32 newHash = bytes32("new_hash");
        
        // Expect revert when called by non-admin
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotAdmin.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.setCreateContestSourceHash(newHash);
    }

    function testSetCreateContestSourceHash_RevertsIfInvalidHash() public {
        bytes32 invalidHash = bytes32(0);
        
        // Expect revert when hash is zero
        vm.expectRevert(
            ContestModule.ContestModule__InvalidCreateContestSourceHash.selector
        );
        vm.prank(admin);
        contestModule.setCreateContestSourceHash(invalidHash);
    }

    // --- Update Contest Markets Tests ---
    function testUpdateContestMarkets_Success() public {
        uint256 contestId = 1;

        // Test values for all three markets (uint16 tick format)
        uint16 moneylineAwayOdds = 150; // 1.50
        uint16 moneylineHomeOdds = 250; // 2.50
        int32 spreadLineTicks = -35; // -3.5 point spread (10x)
        uint16 spreadAwayOdds = 180; // 1.80
        uint16 spreadHomeOdds = 220; // 2.20
        int32 totalLineTicks = 2250; // 225.0 total points (10x)
        uint16 overOdds = 190; // 1.90
        uint16 underOdds = 210; // 2.10

        // Expect the ContestMarketsUpdated event
        vm.expectEmit(true, true, true, true);
        emit ContestModule.ContestMarketsUpdated(
            contestId,
            uint32(block.timestamp),
            spreadLineTicks,
            totalLineTicks,
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadAwayOdds,
            spreadHomeOdds,
            overOdds,
            underOdds
        );

        // Call from oracle module
        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId,
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadLineTicks,
            spreadAwayOdds,
            spreadHomeOdds,
            totalLineTicks,
            overOdds,
            underOdds
        );

        // Verify all three markets were updated correctly
        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        assertEq(moneylineMarket.lineTicks, 0); // Moneyline always has lineTicks = 0
        assertEq(moneylineMarket.upperOdds, moneylineAwayOdds);
        assertEq(moneylineMarket.lowerOdds, moneylineHomeOdds);
        assertEq(moneylineMarket.lastUpdated, uint32(block.timestamp));

        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.lineTicks, spreadLineTicks);
        assertEq(spreadMarket.upperOdds, spreadAwayOdds);
        assertEq(spreadMarket.lowerOdds, spreadHomeOdds);
        assertEq(spreadMarket.lastUpdated, uint32(block.timestamp));

        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.lineTicks, totalLineTicks);
        assertEq(totalMarket.upperOdds, overOdds);
        assertEq(totalMarket.lowerOdds, underOdds);
        assertEq(totalMarket.lastUpdated, uint32(block.timestamp));
    }
    
    function testUpdateContestMarkets_RevertsIfNotOracleModule() public {
        // Expect revert when called by non-oracle module
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.updateContestMarkets(
            1,
            150,   // moneylineAwayOdds (tick)
            250,   // moneylineHomeOdds (tick)
            -35,   // spreadLineTicks (10x)
            180,   // spreadAwayOdds (tick)
            220,   // spreadHomeOdds (tick)
            2250,  // totalLineTicks (10x)
            190,   // overOdds (tick)
            210    // underOdds (tick)
        );
    }
    
    function testUpdateContestMarkets_HandlesEdgeCaseValues() public {
        uint256 contestId = 2;

        // Test with edge case values (uint16 tick format)
        uint16 veryLowOdds = 105; // 1.05 (very low)
        uint16 veryHighOdds = 500; // 5.00 (high)
        int32 negativeSpread = -150; // -15.0 points (10x)
        int32 highTotal = 5000; // 500.0 points (10x)

        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId,
            veryLowOdds,    // moneylineAwayOdds
            veryHighOdds,   // moneylineHomeOdds
            negativeSpread, // spreadLineTicks
            veryLowOdds,    // spreadAwayOdds
            veryHighOdds,   // spreadHomeOdds
            highTotal,      // totalLineTicks
            veryLowOdds,    // overOdds
            veryHighOdds    // underOdds
        );

        // Verify edge case values were stored correctly
        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.lineTicks, negativeSpread);
        assertEq(spreadMarket.upperOdds, veryLowOdds);
        assertEq(spreadMarket.lowerOdds, veryHighOdds);

        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.lineTicks, highTotal);
    }

    // --- Set Update Contest Markets Source Hash Tests ---
    function testSetUpdateContestMarketsSourceHash_OnlyAdmin() public {
        bytes32 newHash = bytes32("new_update_hash");
        bytes32 oldHash = contestModule.s_updateContestMarketsSourceHash();
        
        // Expect the UpdateContestMarketsSourceHashSet event
        vm.expectEmit(true, true, true, true);
        emit ContestModule.UpdateContestMarketsSourceHashSet(oldHash, newHash);
        
        // Test successful update by admin
        vm.prank(admin);
        contestModule.setUpdateContestMarketsSourceHash(newHash);
        
        // Verify the hash was updated
        assertEq(contestModule.s_updateContestMarketsSourceHash(), newHash);
    }

    function testSetUpdateContestMarketsSourceHash_RevertsIfNotAdmin() public {
        bytes32 newHash = bytes32("new_update_hash");
        
        // Expect revert when called by non-admin
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotAdmin.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.setUpdateContestMarketsSourceHash(newHash);
    }

    function testSetUpdateContestMarketsSourceHash_RevertsIfInvalidHash() public {
        bytes32 invalidHash = bytes32(0);
        
        // Expect revert when hash is zero
        vm.expectRevert(
            ContestModule.ContestModule__InvalidUpdateContestMarketsSourceHash.selector
        );
        vm.prank(admin);
        contestModule.setUpdateContestMarketsSourceHash(invalidHash);
    }

    // --- Get Contest Market Tests ---
    function testGetContestMarket_ReturnsCorrectData() public {
        uint256 contestId = 1;

        // First update markets with known values (uint16 tick format)
        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId,
            160,   // moneylineAwayOdds (tick)
            240,   // moneylineHomeOdds (tick)
            -25,   // spreadLineTicks (-2.5, 10x)
            170,   // spreadAwayOdds (tick)
            230,   // spreadHomeOdds (tick)
            2100,  // totalLineTicks (210.0, 10x)
            180,   // overOdds (tick)
            220    // underOdds (tick)
        );

        // Test all three market retrievals
        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        assertEq(moneylineMarket.lineTicks, 0); // Moneyline always 0
        assertEq(moneylineMarket.upperOdds, 160);
        assertEq(moneylineMarket.lowerOdds, 240);
        assertEq(moneylineMarket.lastUpdated, uint32(block.timestamp));

        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.lineTicks, -25);
        assertEq(spreadMarket.upperOdds, 170);
        assertEq(spreadMarket.lowerOdds, 230);
        assertEq(spreadMarket.lastUpdated, uint32(block.timestamp));

        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.lineTicks, 2100);
        assertEq(totalMarket.upperOdds, 180);
        assertEq(totalMarket.lowerOdds, 220);
        assertEq(totalMarket.lastUpdated, uint32(block.timestamp));
    }

    function testGetContestMarket_ReturnsEmptyForNonExistentMarket() public view {
        uint256 nonExistentContestId = 999;
        address unknownScorer = address(0x999);
        
        // Should return empty ContestMarket struct
        ContestMarket memory market = contestModule.getContestMarket(nonExistentContestId, unknownScorer);
        assertEq(market.lineTicks, 0);
        assertEq(market.upperOdds, 0);
        assertEq(market.lowerOdds, 0);
        assertEq(market.lastUpdated, 0);
    }

    function testGetContestMarket_ReturnsEmptyForUnsetMarket() public view {
        uint256 contestId = 1;

        // Get market before any updates (should be empty)
        ContestMarket memory market = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(market.lineTicks, 0);
        assertEq(market.upperOdds, 0);
        assertEq(market.lowerOdds, 0);
        assertEq(market.lastUpdated, 0);
    }

    // =====================================================================
    // Scoring Immutability Tests (C-7)
    // =====================================================================

    /// @notice Oracle scores a contest successfully, then a second oracle score reverts
    function testSetScores_OracleCannotRescore() public {
        // Create and verify a contest
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo", bytes32("hash"), contestCreator, leaderboardId
        );
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        // First oracle score succeeds
        vm.prank(oracleModule);
        contestModule.setScores(contestId, 100, 95);

        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Scored));
        assertEq(c.awayScore, 100);
        assertEq(c.homeScore, 95);

        // Second oracle score attempt reverts
        vm.prank(oracleModule);
        vm.expectRevert(
            abi.encodeWithSelector(ContestModule.ContestModule__AlreadyScored.selector, contestId)
        );
        contestModule.setScores(contestId, 110, 90);

        // Scores unchanged
        Contest memory c2 = contestModule.getContest(contestId);
        assertEq(c2.awayScore, 100);
        assertEq(c2.homeScore, 95);
    }

    /// @notice Manual score cannot overwrite an oracle-scored contest
    function testScoreContestManually_CannotOverwriteOracleScore() public {
        // Create and verify a contest
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo", bytes32("hash"), contestCreator, leaderboardId
        );
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        // Oracle scores the contest
        vm.prank(oracleModule);
        contestModule.setScores(contestId, 100, 95);

        // Grant SCORE_MANAGER_ROLE and warp past wait period
        core.grantRole(keccak256("SCORE_MANAGER_ROLE"), scoreManager);
        vm.warp(block.timestamp + 3 days);

        // Manual score attempt reverts — contest is Scored, not Verified
        vm.prank(scoreManager);
        vm.expectRevert(
            abi.encodeWithSelector(ContestModule.ContestModule__ContestNotVerified.selector, contestId)
        );
        contestModule.scoreContestManually(contestId, 110, 90);

        // Scores unchanged
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.awayScore, 100);
        assertEq(c.homeScore, 95);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Scored));
    }

    /// @notice Oracle cannot overwrite a manually-scored contest either
    function testSetScores_OracleCannotOverwriteManualScore() public {
        // Create and verify a contest
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo", bytes32("hash"), contestCreator, leaderboardId
        );
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        // Score manually
        core.grantRole(keccak256("SCORE_MANAGER_ROLE"), scoreManager);
        vm.warp(block.timestamp + 3 days);
        vm.prank(scoreManager);
        contestModule.scoreContestManually(contestId, 100, 95);

        assertEq(uint(contestModule.getContest(contestId).contestStatus), uint(ContestStatus.ScoredManually));

        // Oracle attempts to rescore — reverts
        vm.prank(oracleModule);
        vm.expectRevert(
            abi.encodeWithSelector(ContestModule.ContestModule__AlreadyScored.selector, contestId)
        );
        contestModule.setScores(contestId, 110, 90);
    }

    // --- setContestLeagueIdAndStartTime Validation Tests ---

    function testSetContestLeagueIdAndStartTime_RevertsIfUnknownLeague() public {
        // Create a contest first
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest("rd", "sp", "jo", bytes32("hash"), contestCreator, leaderboardId);

        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidValue.selector);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.Unknown, uint32(block.timestamp));
    }

    function testSetContestLeagueIdAndStartTime_RevertsIfStartTimeZero() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest("rd", "sp", "jo", bytes32("hash"), contestCreator, leaderboardId);

        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidValue.selector);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, 0);
    }

    // --- updateContestMarkets Validation Tests ---

    function testUpdateContestMarkets_RevertsIfAnyOddsZero() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidMarketData.selector);
        contestModule.updateContestMarkets(
            1,
            0,    // moneylineAwayOdds = 0
            250,
            -35,
            180,
            220,
            2250,
            190,
            210
        );
    }

    function testUpdateContestMarkets_RevertsIfUnderOddsZero() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidMarketData.selector);
        contestModule.updateContestMarkets(
            1,
            150,
            250,
            -35,
            180,
            220,
            2250,
            190,
            0     // underOdds = 0
        );
    }

    function testUpdateContestMarkets_RevertsIfNegativeTotalLineTicks() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidMarketData.selector);
        contestModule.updateContestMarkets(
            1,
            150,
            250,
            -35,
            180,
            220,
            -10,   // totalLineTicks < 0
            190,
            210
        );
    }

    // --- createContest All-Empty Source IDs Test ---

    function testCreateContest_RevertsIfAllSourceIdsEmpty() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidValue.selector);
        contestModule.createContest("", "", "", bytes32("hash"), contestCreator, leaderboardId);
    }

    function testCreateContest_SucceedsWithOneSourceId() public {
        // At least one non-empty source ID should succeed
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest("", "", "jo", bytes32("hash"), contestCreator, leaderboardId);
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.jsonoddsId, "jo");
    }
}
