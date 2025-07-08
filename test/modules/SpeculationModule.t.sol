// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {Speculation, SpeculationStatus, WinSide, Contest, ContestStatus, FeeType, LeagueId} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SpeculationModuleTest is Test {
    SpeculationModule speculationModule;
    OspexCore core;
    MockContestModule mockContestModule;
    TreasuryModule treasuryModule;
    MockERC20 mockToken;
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

        // Register this test contract as ORACLE_MODULE so it can call createSpeculation
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));

        // Grant SPECULATION_MANAGER_ROLE to this contract for forfeitSpeculation tests
        bytes32 SPECULATION_MANAGER_ROLE = keccak256(
            "SPECULATION_MANAGER_ROLE"
        );
        core.grantRole(SPECULATION_MANAGER_ROLE, address(this));
        
        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);
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
        uint32 futureTime = uint32(block.timestamp + 1 hours);
        uint256 id = speculationModule.createSpeculation(
            1,
            futureTime,
            address(0xBEEF),
            42,
            leaderboardId
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(s.startTimestamp, futureTime);
        assertEq(s.speculationScorer, address(0xBEEF));
        assertEq(s.theNumber, 42);
        assertEq(s.speculationCreator, address(this));
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
        assertEq(uint(s.winSide), uint(WinSide.TBD));
    }

    function testCreateSpeculation_RevertsOnPastTimestamp() public {
        vm.expectRevert(
            SpeculationModule.SpeculationModule__InvalidStartTimestamp.selector
        );
        speculationModule.createSpeculation(
            1,
            uint32(block.timestamp - 1),
            address(0xBEEF),
            42,
            leaderboardId
        );
    }

    function testSettleSpeculation_Success() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            futureTime,
            address(mockScorer),
            42,
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

        vm.warp(futureTime + 1);
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
            nowTime,
            address(mockScorer),
            42,
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
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            futureTime,
            address(mockScorer),
            42,
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
            SpeculationModule.SpeculationModule__SpeculationNotStarted.selector
        );
        speculationModule.settleSpeculation(id);
    }

    function testSettleSpeculation_RevertsIfAlreadySettled() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            futureTime,
            address(mockScorer),
            42,
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

        vm.warp(futureTime + 1);
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
            nowTime,
            address(mockScorer),
            42,
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
        uint32 nowTime = uint32(block.timestamp + 1);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            nowTime,
            address(mockScorer),
            42,
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

    function testSpeculationOpen_RevertsIfNotOpen() public {
        // Create and settle a speculation
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        // Use a MockScorerModule
        MockScorerModule mockScorer = new MockScorerModule();

        uint256 id = speculationModule.createSpeculation(
            1,
            futureTime,
            address(mockScorer),
            42,
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

        vm.warp(futureTime + 1);
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
            startTime,
            address(mockScorer),
            42,
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
        uint32 futureTime = uint32(block.timestamp + 1 hours);
        uint256 id = speculationModule.createSpeculation(
            1,
            futureTime,
            address(0xBEEF),
            42,
            leaderboardId
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(s.startTimestamp, futureTime);
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
                treasuryModule.handleFee.selector,
                address(this), // The test contract (ORACLE_MODULE) pays the fee
                fee,
                FeeType.SpeculationCreation,
                leaderboardId
            )
        );

        // Call createSpeculation as the ORACLE_MODULE (test contract)
        uint32 futureTime = uint32(block.timestamp + 1 hours);
        uint256 speculationId = speculationModule.createSpeculation(
            1,
            futureTime,
            address(0xBEEF),
            42,
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
        
        // Register the speculation module itself and oracle module but NOT the treasury module
        newCore.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(newSpeculationModule)
        );
        newCore.registerModule(keccak256("ORACLE_MODULE"), address(this));
        
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
            uint32(block.timestamp + 1 hours), // startTimestamp
            address(0xBEEF), // scorer
            42, // theNumber
            leaderboardId // leaderboardId
        );
    }
}
