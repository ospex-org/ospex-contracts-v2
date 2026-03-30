// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] All odds in this file use uint16 ticks: 1.80 = 180, 1.20 = 120, etc.
// [NOTE] lineTicks is in 10x format: 1.5 = 15, -3.5 = -35

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
    LeagueId,
    LeaderboardPositionValidationResult
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

        // Register scorer modules for directional position conflict testing
        core.registerModule(keccak256("MONEYLINE_SCORER"), address(mockScorerModule));
        core.registerModule(keccak256("SPREAD_SCORER"), address(mockScorerModule));

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

        // Set contest start time to future (after leaderboard starts) to avoid LiveBettingNotAllowed
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 4 hours));

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

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);

        // Approve entry fee before registration
        _approveEntryFee(user1);

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

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);

        // Approve entry fee before registration
        _approveEntryFee(user1);

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

        // Don't warp time - leaderboard hasn't started yet but registration should work

        // Approve entry fee before registration
        _approveEntryFee(user1);

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

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);

        // Approve entry fee before registration
        _approveEntryFee(user1);

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
    }

    function testGetLeaderboardPosition_ReturnsEmptyForNonExistent() public view {
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(leaderboardId, user1, speculationId);
        assertEq(lbPos.speculationId, 0);
        assertEq(lbPos.contestId, 0);
        assertEq(lbPos.riskAmount, 0);
        assertEq(lbPos.profitAmount, 0);
        assertEq(lbPos.user, address(0));
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

        // Mock the position module calls (riskAmount/profitAmount based)
        _mockPositionModuleCalls();

        // Mock rules module validation
        _mockRulesModuleValidation(true);

        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPositionAdded(
            contestId,
            speculationId,
            user1,
            50_000_000, // riskAmount: 50 USDC
            40_000_000, // profitAmount: 40 USDC
            PositionType.Upper,
            leaderboardId
        );

        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            PositionType.Upper,
            leaderboardIds
        );

        // Verify position was registered
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.riskAmount, 50_000_000);
        assertEq(lbPos.profitAmount, 40_000_000);
        assertEq(lbPos.user, user1);
        assertEq(uint256(lbPos.positionType), uint256(PositionType.Upper));
    }

    function testRegisterPositionForLeaderboards_RevertsInvalidLeaderboardCount() public {
        uint256[] memory leaderboardIds = new uint256[](9); // exceeds max of 8

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidLeaderboardCount.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            PositionType.Upper,
            leaderboardIds
        );
    }

    function testRegisterPositionForLeaderboards_RevertsNoRiskAmount() public {
        _setupUserRegistration();

        // Mock position module to return zero risk amount
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)"),
            abi.encode(0, 0, uint8(0), false) // riskAmount = 0
        );

        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NoRiskAmount.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
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
            PositionType.Upper,
            leaderboardIds
        );

        // Try to register again - should fail
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__PositionAlreadyExistsForSpeculation.selector);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
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

        // Approve entry fee before registration
        _approveEntryFee(user1);

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
        // Mock getPosition call - returns Position{riskAmount, profitAmount, positionType, claimed}
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)"),
            abi.encode(
                50_000_000,  // riskAmount: 50 USDC
                40_000_000,  // profitAmount: 40 USDC
                uint8(0),    // positionType = Upper
                false        // claimed
            )
        );

        // Mock getSpeculation call
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // lineTicks
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

        // Updated signature: validateLeaderboardPosition(uint256,uint256,address,int32,uint8,uint256,uint256)
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,address,int32,uint8,uint256,uint256)"),
            abi.encode(shouldPass ? 0 : 5) // 0 = Valid, 5 = LiveBettingNotAllowed
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
        // No longer needed - entry fees are handled directly via processLeaderboardEntryFee
    }

    function _approveEntryFee(address user) internal {
        // Approve Treasury to spend user's USDC for entry fee
        vm.prank(user);
        token.approve(address(treasuryModule), ENTRY_FEE);
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
                int32(0),           // lineTicks
                address(0),         // speculationCreator
                uint8(1),           // speculationStatus = Closed
                uint8(5)            // winSide = Push (for 0 ROI)
            )
        );
    }

    // --- Prize Claiming Tests ---
    function testClaimLeaderboardPrize_Success() public {
        // Setup complete scenario with winner
        _setupLeaderboardWithWinner();

        // Warp to claim window (ROI window ends at day 16, so day 17 is in claim window)
        vm.warp(block.timestamp + 7 days); // Past ROI window, in claim window

        // Mock treasury module for prize claiming
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("claimPrizePool(uint256,address,uint256)"),
            abi.encode()
        );

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPrizeClaimed(leaderboardId, user1, 1e7); // Full 10 USDC prize pool (single winner)

        leaderboardModule.claimLeaderboardPrize(leaderboardId);

        // Verify user has claimed
        bool claimed = leaderboardModule.hasClaimed(leaderboardId, user1);
        assertTrue(claimed);
    }

    function testClaimLeaderboardPrize_RevertsNotInClaimWindow() public {
        _setupLeaderboardWithWinner();

        // Still in ROI window, not claim window yet
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
        emit LeaderboardModule.LeaderboardPrizesSwept(leaderboardId, admin, 1e7); // 10 USDC entry fee

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
        // User2 wins: payout = risk(50M) + profit(40M) = 90M, net = 40M
        // ROI = 40M * 1e18 / 100M(bankroll) = 4e17 = 40%
        emit LeaderboardModule.LeaderboardNewHighestROI(leaderboardId, 400000000000000000, user2); // Higher ROI

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

        // Update contest start time to be in the future to avoid live betting validation
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 6 hours));

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

        // Add speculation to all newly created leaderboards
        for (uint256 i = 1; i < 8; i++) {
            leaderboardModule.addLeaderboardSpeculation(leaderboardIds[i], speculationId);
        }
        vm.stopPrank();

        // Warp to after all leaderboards start (but only once)
        vm.warp(currentTime + 2 hours);

        // Register user for all additional leaderboards
        for (uint256 i = 1; i < 8; i++) {
            // Approve entry fee for each leaderboard registration
            _approveEntryFee(user1);
            vm.prank(user1);
            leaderboardModule.registerUser(leaderboardIds[i], DECLARED_BANKROLL);
        }

        // Register position for all leaderboards
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
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
            assertEq(lbPos.riskAmount, 50_000_000);
            assertEq(lbPos.user, user1);
        }
    }

    function testRegisterPositionForLeaderboards_BetAmountCapping() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();

        // Mock position with very high risk amount
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)"),
            abi.encode(
                500_000_000, // riskAmount: 500 USDC - high amount
                400_000_000, // profitAmount: 400 USDC
                uint8(0),    // positionType = Upper
                false        // claimed
            )
        );

        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // lineTicks
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
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,address,int32,uint8,uint256,uint256)"),
            abi.encode(0) // LeaderboardPositionValidationResult.Valid
        );

        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;

        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            PositionType.Upper,
            leaderboardIds
        );

        // Verify amount was capped
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.riskAmount, 100_000_000); // Should be capped to max
        // profitAmount should be scaled proportionally: 400M * 100M / 500M = 80M
        assertEq(lbPos.profitAmount, 80_000_000);
    }

    function testRegisterPositionForLeaderboards_CanRetryAfterValidationFailure() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();

        uint256[] memory leaderboardIds = new uint256[](1);
        leaderboardIds[0] = leaderboardId;

        // ===== PHASE 1: Initial attempt with validation failure (should revert) =====

        // Mock rules validation to return FAILURE
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
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,address,int32,uint8,uint256,uint256)"),
            abi.encode(7) // LeaderboardPositionValidationResult.OddsTooFavorable
        );

        // First registration attempt should REVERT
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(
            LeaderboardModule.LeaderboardModule__ValidationFailed.selector,
            uint256(LeaderboardPositionValidationResult.OddsTooFavorable)
        ));
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            PositionType.Upper,
            leaderboardIds
        );

        // ===== PHASE 2: Retry should succeed =====

        // Mock rules validation to return TRUE
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("validateLeaderboardPosition(uint256,uint256,address,int32,uint8,uint256,uint256)"),
            abi.encode(0) // LeaderboardPositionValidationResult.Valid
        );

        // Second registration attempt should succeed
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboards(
            speculationId,
            PositionType.Upper,
            leaderboardIds
        );

        // Verify position is now registered
        uint256 registeredSpecId = leaderboardModule.s_registeredLeaderboardSpeculation(
            leaderboardId,
            user1,
            contestId,
            admin // scorer
        );
        assertEq(registeredSpecId, speculationId);

        // Verify the position details
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId,
            user1,
            speculationId
        );
        assertEq(lbPos.riskAmount, 50_000_000);
        assertEq(lbPos.profitAmount, 40_000_000);
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

        // Approve entry fee before registration
        _approveEntryFee(user2);

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
            PositionType.Upper,
            leaderboardIds
        );

        // For user2, use different speculation ID to avoid conflicts
        uint256 speculationId2 = 2;
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", speculationId2, user2, uint8(0)),
            abi.encode(50_000_000, 40_000_000, uint8(0), false)
        );

        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId2),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // lineTicks
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
            PositionType.Upper,
            leaderboardIds
        );

        // Mock rules module for minimum positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );
    }

    function _mockHigherROIForUser2() internal {
        // Mock user2's position as a larger winning bet to create higher ROI
        // Position{riskAmount, profitAmount, positionType, claimed}
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", 2, user2, uint8(0)),
            abi.encode(
                100_000_000, // riskAmount: 100 USDC (double user1's 50M)
                80_000_000,  // profitAmount: 80 USDC
                uint8(0),    // positionType = Upper
                false        // claimed
            )
        );

        // Mock the speculation as closed and winning for Upper positions
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", 2),
            abi.encode(
                contestId,          // contestId
                admin,              // speculationScorer
                int32(0),           // lineTicks
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
                int32(0),           // lineTicks
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
                int32(0),           // lineTicks
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

    // --- ROI Window Boundary Tests (C-1 fix verification) ---
    // These tests verify that submitLeaderboardROI uses roiSubmissionWindow (7 days)
    // NOT claimWindow (30 days) for its time bounds. The original bug used claimWindow,
    // which made the ROI submission window 30 days instead of 7.
    //
    // Timeline for the default leaderboard created in setUp:
    //   endTime = T+8d, safetyPeriod = 1d, roiSubmissionWindow = 7d, claimWindow = 30d
    //   ROI window:   T+9d  to T+16d  (endTime + safety to + roiSubmissionWindow)
    //   Claim window: T+16d to T+46d  (roiWindowEnd to + claimWindow)
    //
    // NOTE: These are stubbed -- the full test helpers (_setupCompleteLeaderboardScenario etc.)
    // need to be updated for the refactored Position/Speculation structs before these can run.

    function testSubmitLeaderboardROI_RevertsBeforeROIWindowOpens() public {
        // Setup complete leaderboard scenario (user registered, position added, mocks in place)
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        // roiWindowStart = endTime + safetyPeriodDuration
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);

        // Warp to 1 second before ROI window opens
        vm.warp(roiWindowStart - 1);

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    function testSubmitLeaderboardROI_SucceedsAtROIWindowStart() public {
        // Setup complete leaderboard scenario
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);

        // Warp to exactly the ROI window start
        vm.warp(roiWindowStart);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // Verify ROI was submitted successfully
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 0); // Push scenario = 0 ROI
    }

    function testSubmitLeaderboardROI_SucceedsAtROIWindowEnd() public {
        // Setup complete leaderboard scenario
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);

        // Warp to exactly the ROI window end (boundary, uses <=)
        vm.warp(roiWindowEnd);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // Verify ROI was submitted successfully
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 0); // Push scenario = 0 ROI
    }

    function testSubmitLeaderboardROI_RevertsAfterROIWindowCloses() public {
        // Setup complete leaderboard scenario
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);

        // Warp to 1 second after ROI window closes
        vm.warp(roiWindowEnd + 1);

        // CRITICAL: This timestamp IS inside the old buggy window (which used claimWindow = 30d,
        // so old window ended at T+39d). This test failing would have caught the C-1 bug.
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    function testSubmitLeaderboardROI_RevertsInsideClaimWindowButOutsideROIWindow() public {
        // Setup complete leaderboard scenario
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);
        // claimWindowStart = roiWindowEnd, claimWindowEnd = claimWindowStart + claimWindow
        // So T+20d is solidly inside claim window (T+16d to T+46d)
        // but outside ROI window (T+9d to T+16d)

        // Warp to midpoint of claim window (well past ROI window end)
        vm.warp(roiWindowEnd + 4 days);

        // This is the definitive test: the old buggy code would have ALLOWED this submission
        // because it used claimWindow (30d) instead of roiSubmissionWindow (7d).
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }
}
