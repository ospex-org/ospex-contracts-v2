// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {ContestModule} from "../../src/modules/ContestModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {Contest, ContestStatus, FeeType, LeagueId} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ContestModuleTest is Test {
    ContestModule contestModule;
    TreasuryModule treasuryModule;
    OspexCore core;
    MockERC20 mockToken;
    address oracleModule = address(0xBEEF);
    address scoreManager = address(0xCAFE);
    address notOracle = address(0xBAD);
    address contestCreator = address(0x123);
    address admin = address(0x1234);

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
        contestModule = new ContestModule(address(core), bytes32("hash"));
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(contestModule)
        );
        
        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();
    }

    function testConstructor_RevertsOnZeroCore() public {
        vm.expectRevert(
            ContestModule.ContestModule__InvalidCoreAddress.selector
        );
        new ContestModule(address(0), bytes32("hash"));
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
                treasuryModule.handleFee.selector,
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
}
