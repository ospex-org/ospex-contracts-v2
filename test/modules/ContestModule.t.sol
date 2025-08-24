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
        core.registerModule(keccak256("MONEYLINE_SCORER"), moneylineScorer);
        core.registerModule(keccak256("SPREAD_SCORER"), spreadScorer);
        core.registerModule(keccak256("TOTAL_SCORER"), totalScorer);
        
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
        vm.expectRevert(); // Just check for any revert for now
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
        
        // Test values for all three markets
        uint64 moneylineAwayOdds = 15_000_000; // 1.5
        uint64 moneylineHomeOdds = 25_000_000; // 2.5
        int32 spreadNumber = -350; // -3.5 point spread
        uint64 spreadAwayOdds = 18_000_000; // 1.8
        uint64 spreadHomeOdds = 22_000_000; // 2.2
        int32 totalNumber = 22500; // 225.0 total points
        uint64 overOdds = 19_000_000; // 1.9
        uint64 underOdds = 21_000_000; // 2.1
        
        // Expect the ContestMarketsUpdated event
        vm.expectEmit(true, true, true, true);
        emit ContestModule.ContestMarketsUpdated(
            contestId,
            uint32(block.timestamp),
            spreadNumber,
            totalNumber,
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
            spreadNumber,
            spreadAwayOdds,
            spreadHomeOdds,
            totalNumber,
            overOdds,
            underOdds
        );
        
        // Verify all three markets were updated correctly
        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        assertEq(moneylineMarket.theNumber, 0); // Moneyline always has theNumber = 0
        assertEq(moneylineMarket.upperOdds, moneylineAwayOdds);
        assertEq(moneylineMarket.lowerOdds, moneylineHomeOdds);
        assertEq(moneylineMarket.lastUpdated, uint32(block.timestamp));
        
        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.theNumber, spreadNumber);
        assertEq(spreadMarket.upperOdds, spreadAwayOdds);
        assertEq(spreadMarket.lowerOdds, spreadHomeOdds);
        assertEq(spreadMarket.lastUpdated, uint32(block.timestamp));
        
        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.theNumber, totalNumber);
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
            15_000_000, // moneylineAwayOdds
            25_000_000, // moneylineHomeOdds
            -350,       // spreadNumber
            18_000_000, // spreadAwayOdds
            22_000_000, // spreadHomeOdds
            22500,      // totalNumber
            19_000_000, // overOdds
            21_000_000  // underOdds
        );
    }
    
    function testUpdateContestMarkets_HandlesEdgeCaseValues() public {
        uint256 contestId = 2;
        
        // Test with edge case values
        uint64 veryLowOdds = 10_500_000; // 1.05 (very low)
        uint64 veryHighOdds = 50_000_000; // 5.0 (high)
        int32 negativeSpread = -1500; // -15.0 points
        int32 highTotal = 50000; // 500.0 points
        
        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId,
            veryLowOdds,    // moneylineAwayOdds
            veryHighOdds,   // moneylineHomeOdds
            negativeSpread, // spreadNumber
            veryLowOdds,    // spreadAwayOdds
            veryHighOdds,   // spreadHomeOdds
            highTotal,      // totalNumber
            veryLowOdds,    // overOdds
            veryHighOdds    // underOdds
        );
        
        // Verify edge case values were stored correctly
        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.theNumber, negativeSpread);
        assertEq(spreadMarket.upperOdds, veryLowOdds);
        assertEq(spreadMarket.lowerOdds, veryHighOdds);
        
        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.theNumber, highTotal);
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
        
        // First update markets with known values
        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId,
            16_000_000, // moneylineAwayOdds
            24_000_000, // moneylineHomeOdds
            -250,       // spreadNumber (-2.5)
            17_000_000, // spreadAwayOdds
            23_000_000, // spreadHomeOdds
            21000,      // totalNumber (210.0)
            18_000_000, // overOdds
            22_000_000  // underOdds
        );
        
        // Test all three market retrievals
        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        assertEq(moneylineMarket.theNumber, 0); // Moneyline always 0
        assertEq(moneylineMarket.upperOdds, 16_000_000);
        assertEq(moneylineMarket.lowerOdds, 24_000_000);
        assertEq(moneylineMarket.lastUpdated, uint32(block.timestamp));
        
        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.theNumber, -250);
        assertEq(spreadMarket.upperOdds, 17_000_000);
        assertEq(spreadMarket.lowerOdds, 23_000_000);
        assertEq(spreadMarket.lastUpdated, uint32(block.timestamp));
        
        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.theNumber, 21000);
        assertEq(totalMarket.upperOdds, 18_000_000);
        assertEq(totalMarket.lowerOdds, 22_000_000);
        assertEq(totalMarket.lastUpdated, uint32(block.timestamp));
    }

    function testGetContestMarket_ReturnsEmptyForNonExistentMarket() public {
        uint256 nonExistentContestId = 999;
        address unknownScorer = address(0x999);
        
        // Should return empty ContestMarket struct
        ContestMarket memory market = contestModule.getContestMarket(nonExistentContestId, unknownScorer);
        assertEq(market.theNumber, 0);
        assertEq(market.upperOdds, 0);
        assertEq(market.lowerOdds, 0);
        assertEq(market.lastUpdated, 0);
    }

    function testGetContestMarket_ReturnsEmptyForUnsetMarket() public {
        uint256 contestId = 1;
        
        // Get market before any updates (should be empty)
        ContestMarket memory market = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(market.theNumber, 0);
        assertEq(market.upperOdds, 0);
        assertEq(market.lowerOdds, 0);
        assertEq(market.lastUpdated, 0);
    }
}
