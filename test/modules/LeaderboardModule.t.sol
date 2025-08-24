// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] All odds in this file use 1e7 precision: 1.10 = 11_000_000, 1.80 = 18_000_000, etc.

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {RulesModule} from "../../src/modules/RulesModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {
    Leaderboard, 
    LeaderboardPosition, 
    PositionType, 
    FeeType,
    Contest,
    ContestStatus,
    Speculation,
    SpeculationStatus,
    WinSide,
    LeagueId
} from "../../src/core/OspexTypes.sol";

contract LeaderboardModuleTest is Test {
    // --- Core Contracts ---
    OspexCore core;
    LeaderboardModule leaderboardModule;
    RulesModule rulesModule;
    TreasuryModule treasuryModule;
    PositionModule positionModule;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    MockERC20 token;
    MockContestModule mockContestModule;
    MockScorerModule mockScorerModule;

    // --- Test Accounts ---
    address admin = address(0x1234);
    address user1 = address(0xBEEF);
    address user2 = address(0xCAFE);
    address user3 = address(0xDEAD);
    address oracleModule = address(0xFEED);
    address nonAdmin = address(0xBAD);
    address protocolReceiver = address(0xFEED);

    // --- Test Constants ---
    uint256 constant PRECISION = 1e18;
    uint256 constant TOKEN_AMOUNT = 1_000_000_000; // 1000 USDC
    uint256 constant ENTRY_FEE = 10_000_000; // 10 USDC
    uint256 constant DECLARED_BANKROLL = 100_000_000; // 100 USDC
    uint32 constant SAFETY_PERIOD = 1 days;
    uint32 constant ROI_WINDOW = 7 days;
    uint32 constant CLAIM_WINDOW = 30 days;

    // --- Test Variables ---
    uint256 leaderboardId;
    uint256 contestId = 1;
    uint256 speculationId = 1;

    function setUp() public {
        // Deploy core and token
        core = new OspexCore();
        token = new MockERC20();

        // Fund test accounts
        token.transfer(user1, TOKEN_AMOUNT);
        token.transfer(user2, TOKEN_AMOUNT);
        token.transfer(user3, TOKEN_AMOUNT);

        // Deploy modules
        leaderboardModule = new LeaderboardModule(address(core));
        rulesModule = new RulesModule(address(core));
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);
        positionModule = new PositionModule(address(core), address(token));
        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        
        // Deploy mock modules
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();

        // Register modules
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(leaderboardModule));
        core.registerModule(keccak256("RULES_MODULE"), address(rulesModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), address(contributionModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("ORACLE_MODULE"), oracleModule);

        // Grant admin role
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);

        // Set up a verified contest in the mock (required for leaderboard testing)
        Contest memory contest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: admin,
            scoreContestSourceHash: bytes32(0),
            rundownId: "test-rundown-id",
            sportspageId: "test-sportspage-id",
            jsonoddsId: "test-jsonodds-id"
        });
        mockContestModule.setContest(contestId, contest);

        // Create a basic leaderboard for most tests
        vm.prank(admin);
        leaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            address(0), // no yield strategy
            uint32(block.timestamp + 1 hours), // starts in 1 hour
            uint32(block.timestamp + 8 days), // ends in 8 days
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
    }

    // --- Constructor Tests ---
    function testConstructor_SetsOspexCore() public view {
        assertEq(address(leaderboardModule.i_ospexCore()), address(core));
    }

    function testConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidOspexCore.selector);
        new LeaderboardModule(address(0));
    }

    // --- Module Type Test ---
    function testGetModuleType_ReturnsCorrectValue() public view {
        assertEq(leaderboardModule.getModuleType(), keccak256("LEADERBOARD_MODULE"));
    }

    // --- Create Leaderboard Tests ---
    function testCreateLeaderboard_Success() public {
        uint32 startTime = uint32(block.timestamp + 1 hours);
        uint32 endTime = uint32(block.timestamp + 8 days);
        
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardCreated(
            1, // next leaderboard ID
            ENTRY_FEE,
            address(0),
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
        
        uint256 newLeaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            address(0),
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
        
        assertEq(newLeaderboardId, 1);
        
        Leaderboard memory lb = leaderboardModule.getLeaderboard(newLeaderboardId);
        assertEq(lb.entryFee, ENTRY_FEE);
        assertEq(lb.yieldStrategy, address(0));
        assertEq(lb.startTime, startTime);
        assertEq(lb.endTime, endTime);
        assertEq(lb.safetyPeriodDuration, SAFETY_PERIOD);
        assertEq(lb.roiSubmissionWindow, ROI_WINDOW);
        assertEq(lb.claimWindow, CLAIM_WINDOW);
        assertEq(lb.prizePool, 0);
    }

    function testCreateLeaderboard_RevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(LeaderboardModule.LeaderboardModule__NotAdmin.selector, nonAdmin));
        leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            address(0),
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
    }

    function testCreateLeaderboard_RevertsOnInvalidTimeRange() public {
        uint32 startTime = uint32(block.timestamp + 8 days);
        uint32 endTime = uint32(block.timestamp + 1 hours); // end before start
        
        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTimeRange.selector);
        leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            address(0),
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
    }

    function testCreateLeaderboard_RevertsOnPastStartTime() public {
        // Warp forward to have enough buffer for time manipulation
        vm.warp(block.timestamp + 10 days);
        
        uint32 startTime = uint32(block.timestamp - 1 hours); // in the past
        uint32 endTime = uint32(block.timestamp + 8 days);
        
        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTimeRange.selector);
        leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            address(0),
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
    }

    // --- Leaderboard Speculation Tests ---
    function testAddLeaderboardSpeculation_Success() public {
        vm.prank(admin);
        vm.expectEmit();
        emit LeaderboardModule.LeaderboardSpeculationAdded(
            leaderboardId,
            speculationId
        );
        
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId
        );
        
        // Verify the speculation is registered for the leaderboard
        bool isRegistered = leaderboardModule.s_leaderboardSpeculationRegistered(leaderboardId, speculationId);
        assertTrue(isRegistered);
    }

    function testAddLeaderboardSpeculation_RevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(LeaderboardModule.LeaderboardModule__NotAdmin.selector, nonAdmin));
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId
        );
    }

    function testAddLeaderboardSpeculation_RevertsIfAlreadyExists() public {
        // Add first
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId
        );
        
        // Try to add again
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LeaderboardModule.LeaderboardModule__SpeculationAlreadyExists.selector, speculationId));
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId
        );
    }



    // --- Register User Tests ---
    function testRegisterUser_Success() public {
        // Mock rules module to allow valid bankroll
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isBankrollValid(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock treasury module to return 0 fee
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("getFeeRate(uint8)"),
            abi.encode(0)
        );

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.UserRegistered(leaderboardId, user1, DECLARED_BANKROLL);
        
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
        
        // Verify user is registered
        assertEq(leaderboardModule.s_userBankrolls(leaderboardId, user1), DECLARED_BANKROLL);
    }

    function testRegisterUser_WithEntryFee() public {
        // Mock rules module to allow valid bankroll
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isBankrollValid(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock treasury module to return entry fee
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("getFeeRate(uint8)"),
            abi.encode(ENTRY_FEE)
        );

        // Mock core handleFee call
        vm.mockCall(
            address(core),
            abi.encodeWithSignature("handleFee(address,uint256,uint8,uint256)"),
            abi.encode()
        );

        // Warp to after leaderboard start  
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
        
        // Verify user is registered
        assertEq(leaderboardModule.s_userBankrolls(leaderboardId, user1), DECLARED_BANKROLL);
    }

    function testRegisterUser_SucceedsBeforeLeaderboardStarts() public {
        // Mock rules module to allow valid bankroll
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isBankrollValid(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock treasury module to return 0 fee
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("getFeeRate(uint8)"),
            abi.encode(0)
        );

        // Don't warp time - leaderboard hasn't started yet but registration should work
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.UserRegistered(leaderboardId, user1, DECLARED_BANKROLL);
        
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
        
        // Verify user is registered
        assertEq(leaderboardModule.s_userBankrolls(leaderboardId, user1), DECLARED_BANKROLL);
    }

    function testRegisterUser_RevertsIfLeaderboardEnded() public {
        // Warp to after leaderboard end (leaderboard ends at block.timestamp + 8 days)
        vm.warp(block.timestamp + 9 days);
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTime.selector);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
    }

    function testRegisterUser_RevertsIfLeaderboardNotExists() public {
        uint256 nonExistentLeaderboardId = 999;
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTime.selector);
        leaderboardModule.registerUser(nonExistentLeaderboardId, DECLARED_BANKROLL);
    }

    function testRegisterUser_RevertsIfAlreadyRegistered() public {
        // Mock rules module to allow valid bankroll
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isBankrollValid(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock treasury module to return 0 fee
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("getFeeRate(uint8)"),
            abi.encode(0)
        );

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
        
        // Register first time
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
        
        // Try to register again
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__UserAlreadyRegistered.selector);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
    }

    function testRegisterUser_RevertsIfInvalidBankroll() public {
        // Mock rules module to reject invalid bankroll
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isBankrollValid(uint256,uint256)"),
            abi.encode(false)
        );

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__BankrollOutOfRange.selector);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
    }

    // --- Getter Tests ---
    function testGetLeaderboard_ReturnsCorrectData() public view {
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        assertEq(lb.entryFee, ENTRY_FEE);
        assertEq(lb.yieldStrategy, address(0));
        assertEq(lb.safetyPeriodDuration, SAFETY_PERIOD);
        assertEq(lb.roiSubmissionWindow, ROI_WINDOW);
        assertEq(lb.claimWindow, CLAIM_WINDOW);
        assertEq(lb.prizePool, 0);
    }



    function testGetLeaderboardPosition_ReturnsEmptyForNonExistent() public view {
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(leaderboardId, user1, speculationId);
        assertEq(lbPos.speculationId, 0);
        assertEq(lbPos.contestId, 0);
        assertEq(lbPos.amount, 0);
        assertEq(lbPos.user, address(0));
        assertEq(lbPos.odds, 0);
        assertEq(uint256(lbPos.positionType), 0);
    }

    // --- Scoring Tests ---
    function testGetUserROI_ReturnsZeroForNonExistent() public view {
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 0);
    }

    function testGetWinners_ReturnsEmptyForNonExistent() public view {
        address[] memory winners = leaderboardModule.getWinners(leaderboardId);
        assertEq(winners.length, 0);
    }

    function testGetHighestROI_ReturnsZeroForNonExistent() public view {
        int256 highestROI = leaderboardModule.getHighestROI(leaderboardId);
        assertEq(highestROI, 0);
    }

    function testHasClaimed_ReturnsFalseForNonExistent() public view {
        bool claimed = leaderboardModule.hasClaimed(leaderboardId, user1);
        assertFalse(claimed);
    }

    // --- Module Not Set Tests ---
    function testLeaderboardModule_RevertsModuleNotSet() public {
        // Create a new core without registered modules
        OspexCore newCore = new OspexCore();
        LeaderboardModule newLeaderboardModule = new LeaderboardModule(address(newCore));
        
        // Grant admin role to create leaderboard
        newCore.grantRole(newCore.DEFAULT_ADMIN_ROLE(), admin);
        
        // Register only the leaderboard module (missing rules module)
        newCore.registerModule(keccak256("LEADERBOARD_MODULE"), address(newLeaderboardModule));
        
        // Create a leaderboard first (this should succeed)
        vm.prank(admin);
        uint256 newLeaderboardId = newLeaderboardModule.createLeaderboard(
            ENTRY_FEE,
            address(0),
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );
        
        // Warp to after leaderboard start time
        vm.warp(block.timestamp + 2 hours);
        
        // Now try to register user - should fail on missing RULES_MODULE
        vm.expectRevert(
            abi.encodeWithSelector(
                LeaderboardModule.LeaderboardModule__ModuleNotSet.selector,
                keccak256("RULES_MODULE")
            )
        );
        newLeaderboardModule.registerUser(newLeaderboardId, DECLARED_BANKROLL);
    }

    // --- ROI Precision Constant Test ---
    function testROIPrecision_IsCorrect() public view {
        assertEq(leaderboardModule.ROI_PRECISION(), PRECISION);
    }

    // --- Position Registration Tests ---
    function testRegisterPositionForLeaderboards_Success() public {
        // Setup user registration first
        _setupUserRegistration();
        
        // Setup position and leaderboard speculation
        _setupPositionAndSpeculation();
        
        // Mock the position module calls
        _mockPositionModuleCalls();
        
        // Mock rules module validation
        _mockRulesModuleValidation(true);
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPositionAdded(
            speculationId,
            user1,
            50_000_000, // 50 USDC
            PositionType.Upper,
            leaderboardId
        );
        
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1, // oddsPairId
            PositionType.Upper,
            leaderboardIds
        );
        
        // Verify position was registered
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.amount, 50_000_000);
        assertEq(lbPos.user, user1);
        assertEq(uint256(lbPos.positionType), uint256(PositionType.Upper));
    }

    function testRegisterPositionForLeaderboards_RevertsInvalidLeaderboardCount() public {
        uint256[] memory leaderboardIds = new uint256[](9); // exceeds max of 8
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidLeaderboardCount.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
    }

    function testRegisterPositionForLeaderboards_RevertsNoMatchedAmount() public {
        _setupUserRegistration();
        
        // Mock position module to return zero matched amount
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint128,uint8)"),
            abi.encode(0, 0, 0, 0, 0, 0, false) // matchedAmount = 0
        );
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NoMatchedAmount.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
    }

    function testRegisterPositionForLeaderboards_RevertsUserNotRegistered() public {
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1); // user1 not registered for leaderboard
        vm.expectRevert(LeaderboardModule.LeaderboardModule__UserNotRegisteredForLeaderboard.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
    }

    function testRegisterPositionForLeaderboards_RevertsPositionAlreadyExists() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        // Register position first time
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Try to register again - should fail
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__PositionAlreadyExistsForSpeculation.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
    }

    function testIncreaseLeaderboardPositionAmount_Success() public {
        // First register a position
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Now increase the amount
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint128,uint8)"),
            abi.encode(
                100_000_000, // increased matched amount
                0, 0, 0, 0, 0, false
            )
        );
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPositionUpdated(
            speculationId,
            user1,
            100_000_000,
            PositionType.Upper,
            leaderboardId
        );
        
        leaderboardModule.increaseLeaderboardPositionAmount(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Verify position was updated
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.amount, 100_000_000);
    }

    function testIncreaseLeaderboardPositionAmount_RevertsNotRegistered() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__LeaderboardSpeculationNotRegisteredForLeaderboard.selector);
        leaderboardModule.increaseLeaderboardPositionAmount(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
    }

    function testIncreaseLeaderboardPositionAmount_RevertsNoAdditionalAmount() public {
        // First register a position
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Try to increase but with same amount - should fail
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NoAdditionalMatchedAmount.selector);
        leaderboardModule.increaseLeaderboardPositionAmount(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
    }

    // --- Helper Functions ---
    function _setupUserRegistration() internal {
        _mockRulesModuleForRegistration();
        _mockTreasuryModuleForRegistration();
        
        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
    }

    function _setupPositionAndSpeculation() internal {
        // Add speculation to leaderboard
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId
        );
    }

    function _mockPositionModuleCalls() internal {
        // Mock getPosition call
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint128,uint8)"),
            abi.encode(
                50_000_000, // matchedAmount
                0, 0, 0, 0, 0, false
            )
        );
        
        // Mock getOddsPair call
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getOddsPair(uint128)"),
            abi.encode(
                18_000_000, // upperOdds
                12_000_000, // lowerOdds
                0, 0
            )
        );
        
        // Mock getSpeculation call
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(0),           // speculationStatus = Open
                uint8(0)            // winSide = TBD
            )
        );
    }

    function _mockRulesModuleValidation(bool shouldPass) internal {
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMaxBetAmount(uint256,uint256)"),
            abi.encode(100_000_000) // 100 USDC max
        );
        
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMinBetAmount(uint256,uint256)"),
            abi.encode(1_000_000) // 1 USDC min
        );
        
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,uint256,uint256,int32,uint64,uint8)"),
            abi.encode(shouldPass)
        );
    }

    function _mockRulesModuleForRegistration() internal {
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isBankrollValid(uint256,uint256)"),
            abi.encode(true)
        );
    }

    function _mockTreasuryModuleForRegistration() internal {
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("getFeeRate(uint8)"),
            abi.encode(0)
        );
    }

    // --- ROI Submission Tests ---
    function testSubmitLeaderboardROI_Success() public {
        // Setup a complete leaderboard scenario
        _setupCompleteLeaderboardScenario();
        
        // Warp to ROI submission window
        vm.warp(block.timestamp + 10 days); // past leaderboard end + safety period
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardROISubmitted(leaderboardId, user1, 0); // 0 ROI for simplicity
        
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        // Verify ROI was submitted
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 0);
    }

    function testSubmitLeaderboardROI_RevertsNotInROIWindow() public {
        _setupCompleteLeaderboardScenario();
        
        // Don't warp time - still in leaderboard period
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    function testSubmitLeaderboardROI_RevertsUserNotRegistered() public {
        // Create leaderboard but don't register user
        vm.warp(block.timestamp + 10 days);
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__UserNotRegisteredForLeaderboard.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    function _setupCompleteLeaderboardScenario() internal {
        // Register user
        _setupUserRegistration();
        
        // Setup and register position
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Mock rules module for minimum positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );
        
        // Mock speculation module for ROI calculation
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(1),           // speculationStatus = Closed
                uint8(5)            // winSide = Push (for 0 ROI)
            )
        );
        
        // Mock position module for odds precision
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("ODDS_PRECISION()"),
            abi.encode(1e7)
        );
    }

    // --- Prize Claiming Tests ---
    function testClaimLeaderboardPrize_Success() public {
        // Setup complete scenario with winner
        _setupLeaderboardWithWinner();
        
        // Warp to claim window (ROI window ends at day 16, so day 17 is in claim window)
        vm.warp(block.timestamp + 7 days); // Past ROI window, in claim window
        
        // Mock treasury module for prize claiming - need to mock it to accept calls from any address
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("claimPrizePool(uint256,address,uint256)"),
            abi.encode()
        );
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPrizeClaimed(leaderboardId, user1, 0); // 0 prize pool for simplicity
        
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
        
        // Verify user has claimed
        bool claimed = leaderboardModule.hasClaimed(leaderboardId, user1);
        assertTrue(claimed);
    }

    function testClaimLeaderboardPrize_RevertsNotInClaimWindow() public {
        _setupLeaderboardWithWinner();
        
        // Still in ROI window, not claim window yet
        // ROI window is from day 9 to day 16, so day 12 should be in ROI window
        vm.warp(block.timestamp + 2 days);
        
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInClaimWindow.selector);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
    }

    function testClaimLeaderboardPrize_RevertsNotWinner() public {
        _setupLeaderboardWithWinner();
        
        // Warp to claim window
        vm.warp(block.timestamp + 15 days);
        
        vm.prank(user2); // user2 is not the winner
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotWinner.selector);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
    }

    function testClaimLeaderboardPrize_RevertsAlreadyClaimed() public {
        _setupLeaderboardWithWinner();
        
        // Warp to claim window
        vm.warp(block.timestamp + 15 days);
        
        // Mock treasury module
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("claimPrizePool(uint256,address,uint256)"),
            abi.encode()
        );
        
        // Claim first time
        vm.prank(user1);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
        
        // Try to claim again
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__AlreadyClaimed.selector);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
    }

    // --- Admin Sweep Tests ---
    function testAdminSweep_Success() public {
        _setupLeaderboardWithWinner();
        
        // Warp past claim window
        vm.warp(block.timestamp + 50 days); // Past all windows
        
        // Mock treasury module
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("claimPrizePool(uint256,address,uint256)"),
            abi.encode()
        );
        
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPrizesSwept(leaderboardId, admin, 0);
        
        leaderboardModule.adminSweep(leaderboardId, admin);
        
        // Verify all winners are marked as claimed
        bool claimed = leaderboardModule.hasClaimed(leaderboardId, user1);
        assertTrue(claimed);
    }

    function testAdminSweep_RevertsNotAdmin() public {
        _setupLeaderboardWithWinner();
        
        vm.warp(block.timestamp + 50 days);
        
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(LeaderboardModule.LeaderboardModule__NotAdmin.selector, nonAdmin));
        leaderboardModule.adminSweep(leaderboardId, admin);
    }

    function testAdminSweep_RevertsNotInClaimWindow() public {
        _setupLeaderboardWithWinner();
        
        // Still in claim window
        vm.warp(block.timestamp + 15 days);
        
        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInClaimWindow.selector);
        leaderboardModule.adminSweep(leaderboardId, admin);
    }

    function testAdminSweep_RevertsNoUnclaimedPrizes() public {
        console.log("=== Starting testAdminSweep_RevertsNoUnclaimedPrizes ===");
        
        console.log("Setting up leaderboard with winner...");
        _setupLeaderboardWithWinner();
        console.log("Setup complete");
        
        // Warp to claim window and have user claim
        vm.warp(block.timestamp + 15 days);
        console.log("Warped to claim window");
        
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("claimPrizePool(uint256,address,uint256)"),
            abi.encode()
        );
        
        console.log("About to claim leaderboard prize...");
        vm.prank(user1);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
        console.log("Prize claimed successfully");
        
        // Now try admin sweep - should fail as no unclaimed prizes
        vm.warp(block.timestamp + 50 days);
        
        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NoUnclaimedPrizes.selector);
        leaderboardModule.adminSweep(leaderboardId, admin);
    }

    // --- Multiple Users and Tie Scenarios ---
    function testMultipleUsers_TiedROI() public {
        // Setup multiple users with identical ROI
        _setupMultipleUsersScenario();
        
        // Both users submit ROI
        vm.warp(block.timestamp + 12 days);
        
        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        vm.prank(user2);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        // Check that both are winners
        address[] memory winners = leaderboardModule.getWinners(leaderboardId);
        assertEq(winners.length, 2);
        
        // Check individual ROIs
        int256 roi1 = leaderboardModule.getUserROI(leaderboardId, user1);
        int256 roi2 = leaderboardModule.getUserROI(leaderboardId, user2);
        assertEq(roi1, roi2); // Should be tied
    }

    function testSubmitLeaderboardROI_NewHighestROI() public {
        _setupMultipleUsersScenario();
        
        vm.warp(block.timestamp + 12 days);
        
        // First user submits ROI
        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        // Mock a higher ROI for user2
        _mockHigherROIForUser2();
        
        vm.prank(user2);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardNewHighestROI(leaderboardId, 100000000000000000, user2); // Higher ROI
        
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        // Check that user2 is now the sole winner
        address[] memory winners = leaderboardModule.getWinners(leaderboardId);
        assertEq(winners.length, 1);
        assertEq(winners[0], user2);
    }

    // --- Edge Cases ---
    function testRegisterPositionForLeaderboards_MaxLeaderboards() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);
        
        // Create 8 different leaderboards (max allowed)
        uint256[] memory leaderboardIds = new uint256[](8);
        leaderboardIds[0] = leaderboardId; // Use the existing leaderboard from setUp
        
        // Get current time for consistent leaderboard creation
        uint256 currentTime = block.timestamp;
        
        // Create 7 additional leaderboards
        vm.startPrank(admin);
        for (uint256 i = 1; i < 8; i++) {
            uint256 newLeaderboardId = leaderboardModule.createLeaderboard(
                ENTRY_FEE,
                address(0),
                uint32(currentTime + 1 hours), // All start at same time
                uint32(currentTime + 8 days),  // All end at same time
                SAFETY_PERIOD,
                ROI_WINDOW,
                CLAIM_WINDOW
            );
            leaderboardIds[i] = newLeaderboardId;
        }
        vm.stopPrank();
        
        // Warp to after all leaderboards start (but only once)
        vm.warp(currentTime + 2 hours);
        
        // Register user for all additional leaderboards
        for (uint256 i = 1; i < 8; i++) {
            vm.prank(user1);
            leaderboardModule.registerUser(leaderboardIds[i], DECLARED_BANKROLL);
        }
        
        // Register position for all leaderboards
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Verify position was registered for all 8 leaderboards
        for (uint256 i = 0; i < 8; i++) {
            LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
                leaderboardIds[i],
                user1,
                speculationId
            );
            assertEq(lbPos.amount, 50_000_000);
            assertEq(lbPos.user, user1);
        }
    }

    function testRegisterPositionForLeaderboards_BetAmountCapping() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        
        // Mock position with very high amount
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint128,uint8)"),
            abi.encode(
                500_000_000, // 500 USDC - high amount
                0, 0, 0, 0, 0, false
            )
        );
        
        // Mock other calls
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getOddsPair(uint128)"),
            abi.encode(18_000_000, 12_000_000, 0, 0)
        );
        
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(0),           // speculationStatus = Open
                uint8(0)            // winSide = TBD
            )
        );
        
        // Mock rules module to cap at 100 USDC
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMaxBetAmount(uint256,uint256)"),
            abi.encode(100_000_000) // 100 USDC max
        );
        
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMinBetAmount(uint256,uint256)"),
            abi.encode(1_000_000)
        );
        
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,uint256,uint256,int32,uint64,uint8)"),
            abi.encode(true)
        );
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Verify amount was capped
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.amount, 100_000_000); // Should be capped to max
    }

    function testRegisterPositionForLeaderboards_CanRetryAfterZeroMarketOdds() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;

        // ===== PHASE 1: Initial attempt with zero market odds (should fail) =====
        
        // Mock rules validation to return FALSE (simulating zero market odds causing validation failure)
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMaxBetAmount(uint256,uint256)"),
            abi.encode(100_000_000) // 100 USDC max
        );
        
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMinBetAmount(uint256,uint256)"),
            abi.encode(1_000_000) // 1 USDC min
        );
        
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,uint256,uint256,int32,uint64,uint8)"),
            abi.encode(false) // FAILS due to zero market odds
        );

        // First registration attempt should fail silently (no revert, but nothing gets registered)
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );

        // Verify nothing was registered (should return 0 speculationId)
        uint256 registeredSpecId1 = leaderboardModule.s_registeredLeaderboardSpeculation(
            leaderboardId,
            user1, 
            contestId,
            admin // scorer from _setupPositionAndSpeculation
        );
        assertEq(registeredSpecId1, 0); // Nothing registered

        // ===== PHASE 2: Market odds become available, retry should succeed =====
        
        // Mock rules validation to return TRUE (simulating real market odds now available)
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,uint256,uint256,int32,uint64,uint8)"),
            abi.encode(true) // NOW PASSES with real market odds
        );

        // Second registration attempt should succeed
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPositionAdded(
            speculationId,
            user1,
            50_000_000, // 50 USDC from _mockPositionModuleCalls
            PositionType.Upper,
            leaderboardId
        );
        
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );

        // Verify position is now registered
        uint256 registeredSpecId2 = leaderboardModule.s_registeredLeaderboardSpeculation(
            leaderboardId,
            user1, 
            contestId,
            admin // scorer
        );
        assertEq(registeredSpecId2, speculationId); // Successfully registered

        // Verify the position details
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.amount, 50_000_000);
        assertEq(lbPos.contestId, contestId);
        assertEq(lbPos.speculationId, speculationId);
        assertEq(lbPos.user, user1);
        assertEq(uint256(lbPos.positionType), uint256(PositionType.Upper));
    }

    // --- Helper Functions for Complex Scenarios ---
    function _setupLeaderboardWithWinner() internal {
        console.log("Setting up complete leaderboard scenario...");
        _setupCompleteLeaderboardScenario();
        console.log("Complete leaderboard scenario setup done");
        
        // Submit ROI to make user1 the winner
        console.log("About to warp and submit ROI...");
        vm.warp(block.timestamp + 10 days);
        vm.prank(user1);
        console.log("Calling submitLeaderboardROI...");
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        console.log("ROI submission complete");
    }

    function _setupMultipleUsersScenario() internal {
        // Register multiple users
        _setupUserRegistration(); // user1
        
        // Register user2
        _mockRulesModuleForRegistration();
        _mockTreasuryModuleForRegistration();
        
        vm.prank(user2);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
        
        // Setup positions for both users
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);
        
        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;
        
        // Register positions for both users
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // For user2, use different speculation ID to avoid conflicts
        uint256 speculationId2 = 2;
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint128,uint8)", speculationId2, user2, 1, 0),
            abi.encode(50_000_000, 0, 0, 0, 0, 0, false)
        );
        
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId2),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(0),           // speculationStatus = Open
                uint8(0)            // winSide = TBD
            )
        );
        
        // Add leaderboard speculation for user2
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId2
        );
        
        vm.prank(user2);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId2,
            1,
            PositionType.Upper,
            leaderboardIds
        );
        
        // Mock rules module for minimum positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );
        
        // Mock position module for odds precision
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("ODDS_PRECISION()"),
            abi.encode(1e7)
        );
    }

    function _mockHigherROIForUser2() internal {
        // Mock user2's position as a larger winning bet to create higher ROI
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint128,uint8)", 2, user2, 1, 0),
            abi.encode(
                100_000_000, // 100M matched amount (double user1's 50M)
                0, // unmatchedAmount
                0, // poolId
                0, // unmatchedExpiry
                0, // positionType = Upper
                false // claimed
            )
        );
        
        // Mock the speculation as closed and winning for Upper positions
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", 2),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(1),           // speculationStatus = Closed
                uint8(1)            // winSide = Away (user2 wins since they have Upper position)
            )
        );
    }

    // --- Test for Multiple Users with Identical Negative ROI ---
    function testSubmitLeaderboardROI_MultipleUsersIdenticalNegativeROI() public {
        // This tests the critical edge case where multiple users end with the same negative ROI
        // They should all be tied for "first place" and split the pot
        
        _setupMultipleUsersScenario();
        
        // Mock both speculations as losing (both users lose their bets)
        // User1's speculation (speculationId = 1) - loses
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", 1),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(1),           // speculationStatus = Closed
                uint8(2)            // winSide = Home (user1 has Upper, so loses)
            )
        );
        
        // User2's speculation (speculationId = 2) - also loses
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", 2),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // theNumber
                address(0),         // speculationCreator
                uint8(1),           // speculationStatus = Closed
                uint8(2)            // winSide = Home (user2 has Upper, so loses)
            )
        );
        
        // Warp to ROI submission window
        vm.warp(block.timestamp + 10 days);
        
        // Both users submit their ROI
        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        vm.prank(user2);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        
        // Verify both users have the same negative ROI
        int256 user1ROI = leaderboardModule.getUserROI(leaderboardId, user1);
        int256 user2ROI = leaderboardModule.getUserROI(leaderboardId, user2);
        
        // Both should have -50% ROI (lost their entire bet)
        assertEq(user1ROI, -500000000000000000); // -50% in 18 decimal precision
        assertEq(user2ROI, -500000000000000000); // -50% in 18 decimal precision
        assertEq(user1ROI, user2ROI); // Identical ROI
        
        // Verify the highest ROI is still this negative value
        int256 highestROI = leaderboardModule.getHighestROI(leaderboardId);
        assertEq(highestROI, -500000000000000000);
        
        // Both users should be able to claim prizes (split pot)
        // This tests that the system correctly handles ties with negative ROI
        vm.warp(block.timestamp + 20 days); // Move to claim window
        
        // Both users should be winners (tied for first with negative ROI)
        address[] memory winners = leaderboardModule.getWinners(leaderboardId);
        assertEq(winners.length, 2); // Both users should be winners
        
        // Check that both users are in the winners array
        bool user1IsWinner = false;
        bool user2IsWinner = false;
        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i] == user1) user1IsWinner = true;
            if (winners[i] == user2) user2IsWinner = true;
        }
        assertTrue(user1IsWinner);
        assertTrue(user2IsWinner);
    }
}
