// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {Speculation, SpeculationStatus, WinSide, Contest, ContestStatus, FeeType, LeagueId, Leaderboard} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
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

contract SpeculationModuleTest is Test {
    SpeculationModule speculationModule;
    OspexCore core;
    MockContestModule mockContestModule;
    TreasuryModule treasuryModule;
    MockERC20 mockToken;
    MockLeaderboardModule mockLeaderboardModule;
    uint8 constant TOKEN_DECIMALS = 6;
    uint256 constant MIN_AMOUNT = 1;
    uint256 constant MAX_AMOUNT = 100;
    address speculationCreator = address(0x123);
    address admin = address(0x1234);

    // leaderboard Id and allocations set to 0 for testing
    uint256 leaderboardId = 0;

    function setUp() public {
        core = new OspexCore();
        // Deploy mock token
        mockToken = new MockERC20();

        // Fund account for fee test
        mockToken.transfer(speculationCreator, 10_000_000);

        speculationModule = new SpeculationModule(
            address(core),
            TOKEN_DECIMALS
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(speculationModule)
        );

        treasuryModule = new TreasuryModule(address(core), address(mockToken), address(0x2));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));

        // Deploy and register mock contest module
        mockContestModule = new MockContestModule();
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(mockContestModule)
        );

        // Deploy and register MockLeaderboardModule for processFee validation
        mockLeaderboardModule = new MockLeaderboardModule();
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));

        // Register this test contract as POSITION_MODULE so it can call createSpeculation
        core.registerModule(keccak256("POSITION_MODULE"), address(this));

        // Grant SPECULATION_MANAGER_ROLE to this contract for forfeitSpeculation tests
        bytes32 SPECULATION_MANAGER_ROLE = keccak256(
            "SPECULATION_MANAGER_ROLE"
        );
        core.grantRole(SPECULATION_MANAGER_ROLE, address(this));
        
        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);

        // Set up a default verified contest for all tests
        Contest memory defaultContest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, // Set as verified so speculations can be created
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, defaultContest);
    }

    function testConstructor_SetsDecimalsAndAmounts() public view {
        assertEq(speculationModule.i_tokenDecimals(), TOKEN_DECIMALS);
        assertEq(
            speculationModule.s_minSpeculationAmount(),
            MIN_AMOUNT * (10 ** TOKEN_DECIMALS)
        );
        assertEq(
            speculationModule.s_maxSpeculationAmount(),
            MAX_AMOUNT * (10 ** TOKEN_DECIMALS)
        );
    }

    function testCreateSpeculation_Success() public {
        uint256 id = speculationModule.createSpeculation(
            1,
            address(0xBEEF),
            42,
            address(this),
            leaderboardId
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        // Note: startTimestamp field removed from Speculation struct
        assertEq(s.speculationScorer, address(0xBEEF));
        assertEq(s.theNumber, 42);
        assertEq(s.speculationCreator, address(this));
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
        assertEq(uint(s.winSide), uint(WinSide.TBD));
    }

    function testSettleSpeculation_Success() public {
        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

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

        vm.warp(block.timestamp + 1 hours);
        speculationModule.settleSpeculation(id);
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Closed));
    }

    function testSettleSpeculation_AutoVoidsAfterCooldown() public {
        uint32 nowTime = uint32(block.timestamp + 1);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

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

        vm.warp(nowTime + speculationModule.s_voidCooldown() + 1);
        speculationModule.settleSpeculation(id);
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.winSide), uint(WinSide.Void));
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Closed));
    }

    function testSettleSpeculation_RevertsIfNotStarted() public {
        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to be in Scored state
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

        // Set contest start time to future so settleSpeculation should revert
        uint32 futureStartTime = uint32(block.timestamp + 1 hours);
        mockContestModule.setContestStartTime(1, futureStartTime);

        vm.expectRevert(
            SpeculationModule.SpeculationModule__SpeculationNotStarted.selector
        );
        speculationModule.settleSpeculation(id);
    }

    function testSettleSpeculation_RevertsIfAlreadySettled() public {
        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to be in Scored state
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

        vm.warp(block.timestamp + 1 hours);
        speculationModule.settleSpeculation(id);
        vm.expectRevert(
            SpeculationModule.SpeculationModule__AlreadySettled.selector
        );
        speculationModule.settleSpeculation(id);
    }

    function testForfeitSpeculation_Success() public {
        uint32 nowTime = uint32(block.timestamp + 1);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to be in Scored state
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

        vm.warp(nowTime + speculationModule.s_voidCooldown() + 1);
        speculationModule.forfeitSpeculation(id);
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.winSide), uint(WinSide.Forfeit));
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Closed));
    }

    function testForfeitSpeculation_RevertsIfCooldownNotMet() public {

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to be in Scored state
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

        vm.expectRevert(
            SpeculationModule.SpeculationModule__VoidCooldownNotMet.selector
        );
        speculationModule.forfeitSpeculation(id);
    }

    function testForfeitSpeculation_RevertsIfNotAuthorized() public {
        uint32 nowTime = uint32(block.timestamp + 1);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to be in Scored state
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

        // Warp past cooldown period
        vm.warp(nowTime + speculationModule.s_voidCooldown() + 1);

        // Try to call forfeitSpeculation from an unauthorized address
        address unauthorizedCaller = address(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__NotAuthorized.selector,
                unauthorizedCaller
            )
        );
        vm.prank(unauthorizedCaller);
        speculationModule.forfeitSpeculation(id);
    }

    function testSpeculationOpen_RevertsIfNotOpen() public {
        // Create and settle a speculation
        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to be in Scored state
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

        vm.warp(block.timestamp + 1 hours);
        speculationModule.settleSpeculation(id);

        // Try to call a function with speculationOpen modifier (forfeitSpeculation)
        vm.expectRevert(
            SpeculationModule.SpeculationModule__SpeculationNotOpen.selector
        );
        speculationModule.forfeitSpeculation(id);
    }

    function testSetMinSpeculationAmount_Success() public {
        vm.prank(admin);
        speculationModule.setMinSpeculationAmount(2);
        assertEq(
            speculationModule.s_minSpeculationAmount(),
            2 * (10 ** TOKEN_DECIMALS)
        );
    }

    function testSettleSpeculation_RevertsIfContestNotFinalized() public {
        uint32 startTime = uint32(block.timestamp + 1); // speculation starts soon
        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        // Create speculation
        uint256 id = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(this),
            leaderboardId
        );

        // Set up the contest to NOT be scored (e.g., status = Verified)
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, // Not Scored or ScoredManually
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        // Warp to after speculation start
        vm.warp(startTime + 1);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule
                    .SpeculationModule__ContestNotFinalized
                    .selector,
                1 // contestId
            )
        );
        speculationModule.settleSpeculation(id);
    }

    function testSetMinSpeculationAmount_RevertsIfMinAboveMax() public {
        vm.prank(admin);
        speculationModule.setMaxSpeculationAmount(2);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__MinAboveMax.selector,
                3 * (10 ** TOKEN_DECIMALS),
                2 * (10 ** TOKEN_DECIMALS)
            )
        );
        speculationModule.setMinSpeculationAmount(3);
    }

    function testSetMaxSpeculationAmount_Success() public {
        vm.prank(admin);
        speculationModule.setMaxSpeculationAmount(200);
        assertEq(
            speculationModule.s_maxSpeculationAmount(),
            200 * (10 ** TOKEN_DECIMALS)
        );
    }

    function testSetMaxSpeculationAmount_RevertsIfMaxBelowMin() public {
        vm.prank(admin);
        speculationModule.setMinSpeculationAmount(10);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__MaxBelowMin.selector,
                5 * (10 ** TOKEN_DECIMALS),
                10 * (10 ** TOKEN_DECIMALS)
            )
        );
        speculationModule.setMaxSpeculationAmount(5);
    }

    function testSetVoidCooldown_Success() public {
        vm.prank(admin);
        speculationModule.setVoidCooldown(2 days);
        assertEq(speculationModule.s_voidCooldown(), 2 days);
    }

    function testSetVoidCooldown_RevertsIfBelowMinimum() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule
                    .SpeculationModule__VoidCooldownBelowMinimum
                    .selector,
                1
            )
        );
        speculationModule.setVoidCooldown(1);
    }

    function testGetSpeculation_ReturnsCorrectData() public {
        uint256 id = speculationModule.createSpeculation(
            1,
            address(0xBEEF),
            42,
            address(this),
            leaderboardId
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        // Note: startTimestamp field removed from Speculation struct
        assertEq(s.speculationScorer, address(0xBEEF));
        assertEq(s.theNumber, 42);
        assertEq(s.speculationCreator, address(this));
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
        assertEq(uint(s.winSide), uint(WinSide.TBD));
    }

    function testGetModuleType_ReturnsCorrectValue() public view {
        bytes32 expected = keccak256("SPECULATION_MODULE");
        assertEq(speculationModule.getModuleType(), expected);
    }

    function testCreateSpeculation_WithFee_ChargesFee() public {
        // Set the speculation creation fee using admin
        uint256 fee = 1_000_000; // 1 USDC (6 decimals)
        vm.prank(admin);
        treasuryModule.setFeeRates(FeeType.SpeculationCreation, fee);

        // Check initial balance of test contract (it gets all tokens from MockERC20 constructor)
        uint256 initialBalance = mockToken.balanceOf(address(this));

        // Approve the TreasuryModule to spend the test contract's tokens
        mockToken.approve(address(treasuryModule), fee);

        // Use expectCall to check that handleFee is called with the test contract as payer
        vm.expectCall(
            address(treasuryModule),
            abi.encodeWithSelector(
                treasuryModule.processFee.selector,
                address(this), // The test contract (POSITION_MODULE) pays the fee via speculationCreator
                fee,
                FeeType.SpeculationCreation,
                leaderboardId
            )
        );

        // Call createSpeculation as the POSITION_MODULE (test contract)
        uint256 speculationId = speculationModule.createSpeculation(
            1,
            address(0xBEEF),
            42,
            address(this),
            leaderboardId
        );

        // Check that the speculation was created as normal
        Speculation memory s = speculationModule.getSpeculation(
            speculationId
        );
        assertEq(s.contestId, 1);
        assertEq(s.speculationCreator, address(this)); // The test contract is the creator

        // Check that the test contract's balance decreased by the fee
        assertEq(mockToken.balanceOf(address(this)), initialBalance - fee); // Balance should decrease by fee amount
    }

    function testSpeculationModule_Revert_ModuleNotSet() public {
        // Create a new core and speculation module instance without registering required modules
        OspexCore newCore = new OspexCore();
        SpeculationModule newSpeculationModule = new SpeculationModule(
            address(newCore),
            TOKEN_DECIMALS
        );

        // Register the speculation module itself and POSITION_MODULE but NOT the treasury module
        newCore.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(newSpeculationModule)
        );
        newCore.registerModule(keccak256("POSITION_MODULE"), address(this));

        // Register a mock contest module so we can get past the contest validation
        // This allows us to test the TREASURY_MODULE check specifically
        MockContestModule mockContest = new MockContestModule();
        newCore.registerModule(keccak256("CONTEST_MODULE"), address(mockContest));

        // Set up a verified contest
        Contest memory testContest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContest.setContest(1, testContest);

        // Try to create a speculation - this will call _getModule for TREASURY_MODULE
        // which won't be registered, causing the revert
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__ModuleNotSet.selector,
                keccak256("TREASURY_MODULE")
            )
        );
        newSpeculationModule.createSpeculation(
            1, // contestId
            address(0xBEEF), // scorer
            42, // theNumber
            address(this), // speculationCreator
            leaderboardId // leaderboardId
        );
    }

    function testCreateSpeculation_RevertsWhenCalledByNonPositionModule() public {
        // Try to call createSpeculation from a different address (not the POSITION_MODULE)
        address nonPositionModule = address(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__NotAuthorized.selector,
                nonPositionModule
            )
        );
        vm.prank(nonPositionModule);
        speculationModule.createSpeculation(
            1, // contestId
            address(0xBEEF), // scorer
            42, // theNumber
            address(0x123), // speculationCreator
            leaderboardId
        );
    }

    function testCreateSpeculation_SuccessWhenCalledByPositionModule() public {
        address creator = address(0x456);

        // Approve fee payment from creator
        uint256 fee = treasuryModule.getFeeRate(FeeType.SpeculationCreation);
        if (fee > 0) {
            mockToken.transfer(creator, fee);
            vm.prank(creator);
            mockToken.approve(address(treasuryModule), fee);
        }

        // Call from POSITION_MODULE (this test contract)
        uint256 id = speculationModule.createSpeculation(
            1, // contestId
            address(0xBEEF), // scorer
            42, // theNumber
            creator, // speculationCreator
            leaderboardId
        );

        // Verify speculation was created with correct creator
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(s.speculationScorer, address(0xBEEF));
        assertEq(s.theNumber, 42);
        assertEq(s.speculationCreator, creator);
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
        assertEq(uint(s.winSide), uint(WinSide.TBD));
    }
}
