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

    // Fee rates for TreasuryModule (in USDC 6 decimals)
    uint256 constant CONTEST_FEE = 1_000_000; // 1.00 USDC
    uint256 constant SPEC_FEE = 500_000; // 0.50 USDC
    uint256 constant LB_FEE = 500_000; // 0.50 USDC

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
        // Fund admin for leaderboard creation fee
        token.transfer(admin, TOKEN_AMOUNT);

        // Deploy modules
        leaderboardModule = new LeaderboardModule(address(core));
        rulesModule = new RulesModule(address(core));
        treasuryModule = new TreasuryModule(
            address(core), address(token), protocolReceiver,
            CONTEST_FEE, SPEC_FEE, LB_FEE
        );
        positionModule = new PositionModule(address(core), address(token));
        speculationModule = new SpeculationModule(address(core), 6, 7 days, 1_000_000);

        // Deploy mock modules
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();

        // Bootstrap all 12 modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);

        types[0] = core.CONTEST_MODULE();
        addrs[0] = address(mockContestModule);

        types[1] = core.SPECULATION_MODULE();
        addrs[1] = address(speculationModule);

        types[2] = core.POSITION_MODULE();
        addrs[2] = address(positionModule);

        types[3] = core.MATCHING_MODULE();
        addrs[3] = address(this); // test contract acts as matching module

        types[4] = core.ORACLE_MODULE();
        addrs[4] = oracleModule;

        types[5] = core.TREASURY_MODULE();
        addrs[5] = address(treasuryModule);

        types[6] = core.LEADERBOARD_MODULE();
        addrs[6] = address(leaderboardModule);

        types[7] = core.RULES_MODULE();
        addrs[7] = address(rulesModule);

        types[8] = core.SECONDARY_MARKET_MODULE();
        addrs[8] = address(0x5EC0); // placeholder for secondary market

        types[9] = core.MONEYLINE_SCORER_MODULE();
        addrs[9] = address(mockScorerModule);

        types[10] = core.SPREAD_SCORER_MODULE();
        addrs[10] = address(0x5901); // placeholder scorer

        types[11] = core.TOTAL_SCORER_MODULE();
        addrs[11] = address(0x7701); // placeholder scorer

        core.bootstrapModules(types, addrs);
        core.finalize();

        // Set up a verified contest in the mock (required for leaderboard testing)
        Contest memory contest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: admin,
            scoreContestSourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            rundownId: "test-rundown-id",
            sportspageId: "test-sportspage-id",
            jsonoddsId: "test-jsonodds-id"
        });
        mockContestModule.setContest(contestId, contest);

        // Set contest start time to future (after leaderboard starts) to avoid LiveBettingNotAllowed
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 4 hours));

        // Approve TreasuryModule for admin (leaderboard creation fees)
        vm.prank(admin);
        token.approve(address(treasuryModule), type(uint256).max);

        // Create a basic leaderboard for most tests (permissionless, but admin creates)
        vm.prank(admin);
        leaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            uint32(block.timestamp + 1 hours), // starts in 1 hour
            uint32(block.timestamp + 8 days), // ends in 8 days
            SAFETY_PERIOD,
            ROI_WINDOW
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

        // Approve leaderboard creation fee
        vm.prank(admin);
        token.approve(address(treasuryModule), LB_FEE);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardCreated(
            2, // next leaderboard ID (setUp already created ID 1)
            admin, // creator
            ENTRY_FEE,
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW
        );

        uint256 newLeaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW
        );

        assertEq(newLeaderboardId, 2);

        Leaderboard memory lb = leaderboardModule.getLeaderboard(newLeaderboardId);
        assertEq(lb.entryFee, ENTRY_FEE);
        assertEq(lb.creator, admin);
        assertEq(lb.startTime, startTime);
        assertEq(lb.endTime, endTime);
        assertEq(lb.safetyPeriodDuration, SAFETY_PERIOD);
        assertEq(lb.roiSubmissionWindow, ROI_WINDOW);
    }

    function testCreateLeaderboard_Permissionless() public {
        // Anyone can create a leaderboard (not just admin)
        uint32 startTime = uint32(block.timestamp + 1 hours);
        uint32 endTime = uint32(block.timestamp + 8 days);

        // Approve leaderboard creation fee for nonAdmin
        vm.prank(nonAdmin);
        token.approve(address(treasuryModule), LB_FEE);

        // Fund nonAdmin so they can pay the fee
        token.transfer(nonAdmin, LB_FEE);

        vm.prank(nonAdmin);
        uint256 newId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW
        );

        Leaderboard memory lb = leaderboardModule.getLeaderboard(newId);
        assertEq(lb.creator, nonAdmin);
    }

    function testCreateLeaderboard_RevertsOnInvalidTimeRange() public {
        uint32 startTime = uint32(block.timestamp + 8 days);
        uint32 endTime = uint32(block.timestamp + 1 hours); // end before start

        vm.prank(admin);
        token.approve(address(treasuryModule), LB_FEE);

        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTimeRange.selector);
        leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW
        );
    }

    function testCreateLeaderboard_RevertsOnPastStartTime() public {
        // Warp forward to have enough buffer for time manipulation
        vm.warp(block.timestamp + 10 days);

        uint32 startTime = uint32(block.timestamp - 1 hours); // in the past
        uint32 endTime = uint32(block.timestamp + 8 days);

        vm.prank(admin);
        token.approve(address(treasuryModule), LB_FEE);

        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTimeRange.selector);
        leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            startTime,
            endTime,
            SAFETY_PERIOD,
            ROI_WINDOW
        );
    }

    // --- Leaderboard Speculation Tests ---
    function testAddLeaderboardSpeculation_Success() public {
        // Mock getSpeculation so addLeaderboardSpeculation can resolve contestId
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );

        // admin is the leaderboard creator
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

    function testAddLeaderboardSpeculation_RevertsIfNotCreator() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(LeaderboardModule.LeaderboardModule__NotCreator.selector, nonAdmin));
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId
        );
    }

    function testAddLeaderboardSpeculation_RevertsIfAlreadyExists() public {
        // Mock getSpeculation so addLeaderboardSpeculation can resolve contestId
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );

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

    function testRegisterUser_RevertsIfZeroBankroll() public {
        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__BankrollOutOfRange.selector);
        leaderboardModule.registerUser(leaderboardId, 0);
    }

    // --- Getter Tests ---
    function testGetLeaderboard_ReturnsCorrectData() public view {
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        assertEq(lb.entryFee, ENTRY_FEE);
        assertEq(lb.creator, admin);
        assertEq(lb.safetyPeriodDuration, SAFETY_PERIOD);
        assertEq(lb.roiSubmissionWindow, ROI_WINDOW);
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

        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
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

    function testRegisterPositionForLeaderboards_RevertsNoRiskAmount() public {
        _setupUserRegistration();

        // Mock position module to return zero risk amount
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)"),
            abi.encode(0, 0, uint8(0), false) // riskAmount = 0
        );


        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NoRiskAmount.selector);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
        );
    }

    function testRegisterPositionForLeaderboards_RevertsUserNotRegistered() public {
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();


        vm.prank(user1); // user1 not registered for leaderboard
        vm.expectRevert(LeaderboardModule.LeaderboardModule__UserNotRegisteredForLeaderboard.selector);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
        );
    }

    function testRegisterPositionForLeaderboards_RevertsPositionAlreadyExists() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();
        _mockRulesModuleValidation(true);


        // Register position first time
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
        );

        // Try to register again - should fail
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__PositionAlreadyExistsForSpeculation.selector);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
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
        // Mock getSpeculation so addLeaderboardSpeculation can resolve contestId
        // (the real SpeculationModule has no speculation created yet)
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(0),                        // speculationStatus = Open
                uint8(0)                         // winSide = TBD
            )
        );

        // Add speculation to leaderboard (only creator can do this)
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

        // Mock getSpeculation call — use mockScorerModule address as scorer (registered scorer)
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer (registered scorer)
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(0),                        // speculationStatus = Open
                uint8(0)                         // winSide = TBD
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


        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
        );

        // Mock rules module for minimum positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock speculation module for ROI calculation — use mockScorerModule address
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(1),                        // speculationStatus = Closed
                uint8(5)                         // winSide = Push (for 0 ROI)
            )
        );
    }

    // --- Prize Claiming Tests ---
    function testClaimLeaderboardPrize_Success() public {
        // Setup complete scenario with winner
        _setupLeaderboardWithWinner();

        // Warp past ROI window end (claims open forever after ROI window)
        vm.warp(block.timestamp + 7 days);

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

    function testClaimLeaderboardPrize_RevertsNotClaimableYet() public {
        _setupLeaderboardWithWinner();

        // Still in ROI window, not claimable yet
        vm.warp(block.timestamp + 2 days);

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotClaimableYet.selector);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
    }

    function testClaimLeaderboardPrize_RevertsNotWinner() public {
        _setupLeaderboardWithWinner();

        // Warp past ROI window
        vm.warp(block.timestamp + 15 days);

        vm.prank(user2); // user2 is not the winner
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotWinner.selector);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
    }

    function testClaimLeaderboardPrize_RevertsAlreadyClaimed() public {
        _setupLeaderboardWithWinner();

        // Warp past ROI window
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

    function testClaimLeaderboardPrize_SucceedsLongAfterROIWindow() public {
        // Claims are open forever after the ROI window ends
        _setupLeaderboardWithWinner();

        // Warp far into the future — should still work
        vm.warp(block.timestamp + 365 days);

        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("claimPrizePool(uint256,address,uint256)"),
            abi.encode()
        );

        vm.prank(user1);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);
        assertTrue(leaderboardModule.hasClaimed(leaderboardId, user1));
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
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(0),                        // speculationStatus = Open
                uint8(0)                         // winSide = TBD
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


        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
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

    function testRegisterPositionForLeaderboards_RevertsWhenCappedRiskRoundsToZero() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();

        // Mock position with a valid non-zero risk amount
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

        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(0),                        // speculationStatus = Open
                uint8(0)                         // winSide = TBD
            )
        );

        // Mock max bet to return 0 (simulates tiny bankroll where integer division rounds to 0)
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMaxBetAmount(uint256,uint256)"),
            abi.encode(0)
        );

        // Mock min bet to also return 0 (no minimum configured)
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("getMinBetAmount(uint256,uint256)"),
            abi.encode(0)
        );

        // Should revert because capped risk amount rounds to zero
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__BetSizeBelowMinimum.selector);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
        );
    }

    function testRegisterPositionForLeaderboards_CanRetryAfterValidationFailure() public {
        _setupUserRegistration();
        _setupPositionAndSpeculation();
        _mockPositionModuleCalls();


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
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
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
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
        );

        // Verify position is now registered
        uint256 registeredSpecId = leaderboardModule.s_registeredLeaderboardSpeculation(
            leaderboardId,
            user1,
            contestId,
            address(mockScorerModule) // scorer
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


        // Register positions for both users
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId,
            PositionType.Upper,
            leaderboardId
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
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(0),                        // speculationStatus = Open
                uint8(0)                         // winSide = TBD
            )
        );

        // Add leaderboard speculation for user2 (creator adds it)
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(
            leaderboardId,
            speculationId2
        );

        vm.prank(user2);
        leaderboardModule.registerPositionForLeaderboard(
            speculationId2,
            PositionType.Upper,
            leaderboardId
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
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(1),                        // speculationStatus = Closed
                uint8(1)                         // winSide = Away (user2 wins since they have Upper position)
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
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(1),                        // speculationStatus = Closed
                uint8(2)                         // winSide = Home (user1 has Upper, so loses)
            )
        );

        // User2's speculation (speculationId = 2) - also loses
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", 2),
            abi.encode(
                contestId,                      // contestId
                address(mockScorerModule),       // speculationScorer
                int32(0),                        // lineTicks
                address(0),                      // speculationCreator
                uint8(1),                        // speculationStatus = Closed
                uint8(2)                         // winSide = Home (user2 has Upper, so loses)
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
        vm.warp(block.timestamp + 20 days); // Move past ROI window

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
    // for its time bounds.
    //
    // Timeline for the default leaderboard created in setUp:
    //   endTime = T+8d, safetyPeriod = 1d, roiSubmissionWindow = 7d
    //   ROI window:   T+9d  to T+16d  (endTime + safety to + roiSubmissionWindow)
    //   Claims open:  T+16d onwards   (forever after ROI window)

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

    function testSubmitLeaderboardROI_RevertsAtROIWindowEnd() public {
        // Setup complete leaderboard scenario
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);

        // Warp to exactly the ROI window end — boundary is now exclusive
        vm.warp(roiWindowEnd);

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
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

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    function testSubmitLeaderboardROI_RevertsWellPastROIWindow() public {
        // Setup complete leaderboard scenario
        _setupCompleteLeaderboardScenario();

        // Get the leaderboard to compute exact boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);

        // Warp to midpoint well past ROI window end
        vm.warp(roiWindowEnd + 4 days);

        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    // =====================================================================
    // Prize Pool Snapshot Fix Tests (C-2)
    // =====================================================================
    // These tests verify the fix for the shrinking-pool bug where tied winners
    // received unequal shares because claimLeaderboardPrize computed shares
    // from the live (decremented) pool instead of a snapshot.
    //
    // The fix snapshots the prize pool on first claim. All winners split the
    // snapshot, not the live balance.
    // =====================================================================

    /// @notice Two tied winners both receive exactly half the prize pool
    function testTiedWinners_BothGetEqualShare() public {
        uint256 prizePool = _setupTwoTiedWinnersInClaimWindow();
        uint256 expectedShare = prizePool / 2; // 10 USDC each from 20 USDC pool

        uint256 user1BalBefore = token.balanceOf(user1);
        uint256 user2BalBefore = token.balanceOf(user2);

        // User1 claims first
        vm.prank(user1);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);

        // User2 claims second — must get the SAME share (not reduced by user1's claim)
        vm.prank(user2);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);

        // Both received equal shares
        assertEq(token.balanceOf(user1) - user1BalBefore, expectedShare, "user1 share incorrect");
        assertEq(token.balanceOf(user2) - user2BalBefore, expectedShare, "user2 share incorrect");

        // Treasury drained exactly
        assertEq(treasuryModule.getPrizePool(leaderboardId), 0, "pool should be empty");
    }

    /// @notice Claim order does not affect distribution — user2 claims first
    function testTiedWinners_ReverseClaimOrder() public {
        uint256 prizePool = _setupTwoTiedWinnersInClaimWindow();
        uint256 expectedShare = prizePool / 2;

        uint256 user1BalBefore = token.balanceOf(user1);
        uint256 user2BalBefore = token.balanceOf(user2);

        // User2 claims first this time
        vm.prank(user2);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);

        vm.prank(user1);
        leaderboardModule.claimLeaderboardPrize(leaderboardId);

        assertEq(token.balanceOf(user1) - user1BalBefore, expectedShare, "user1 share incorrect");
        assertEq(token.balanceOf(user2) - user2BalBefore, expectedShare, "user2 share incorrect");
    }

    // =====================================================================
    // TBD Exclusion Tests (C-3)
    // =====================================================================
    // Positions with winSide == TBD (unscored) are excluded from the ROI
    // calculation via early return in _calculatePositionNet. They contribute
    // zero to net P&L rather than being treated as a resolved outcome.
    // =====================================================================

    /// @notice A single TBD position yields 0 ROI, not a loss
    function testROI_TBDPosition_YieldsZeroROI() public {
        _setupCompleteLeaderboardScenario();

        // Speculation already mocked as Push (winSide=5) by _setupCompleteLeaderboardScenario.
        // Override to TBD (winSide=0) for this test.
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(0)) // TBD
        );

        // Warp to ROI window and submit
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        vm.warp(roiWindowStart);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // ROI should be 0 (TBD excluded), NOT -50% (loss)
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 0, "TBD position should yield 0 ROI");
    }

    /// @notice TBD position does not dilute a winning position's ROI
    function testROI_TBDPosition_DoesNotAffectWinningPosition() public {
        // Register user
        _mockRulesModuleForRegistration();
        vm.warp(block.timestamp + 2 hours);
        _approveEntryFee(user1);
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);

        // --- Position 1 (contest 1): will be scored as a win ---
        // Mock getSpeculation before addLeaderboardSpeculation so it can resolve contestId
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, speculationId);

        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", speculationId, user1, uint8(0)),
            abi.encode(50_000_000, 40_000_000, uint8(0), false)
        );
        _mockRulesModuleValidation(true);


        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(speculationId, PositionType.Upper, leaderboardId);

        // --- Position 2 (contest 2): will remain TBD (unscored) ---
        uint256 specId2 = 2;
        uint256 contestId2 = 2;
        // Set up contest 2 in the mock
        Contest memory contest2 = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: admin,
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "test2", sportspageId: "test2", jsonoddsId: "test2"
        });
        mockContestModule.setContest(contestId2, contest2);
        mockContestModule.setContestStartTime(contestId2, uint32(block.timestamp + 4 hours));

        // Mock getSpeculation before addLeaderboardSpeculation so it can resolve contestId
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", specId2),
            abi.encode(contestId2, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId2);

        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", specId2, user1, uint8(0)),
            abi.encode(50_000_000, 40_000_000, uint8(0), false)
        );
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(specId2, PositionType.Upper, leaderboardId);

        // Mock min positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );

        // --- Set scoring outcomes for ROI calculation ---
        // Speculation 1: Away win (Upper position wins) -> net = +40M
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(1)) // Away
        );
        // Speculation 2: TBD (unscored) -> excluded, net = 0
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", specId2),
            abi.encode(contestId2, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(0)) // TBD
        );

        // Submit ROI
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        vm.warp(roiWindowStart);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // ROI = +40M / 100M bankroll = 40% = 4e17
        // If TBD were a loss: ROI = (40M - 50M) / 100M = -10% = -1e17
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, 400000000000000000, "ROI should reflect only the winning position (40%)");
    }

    /// @notice TBD position does not dilute a losing position's ROI
    function testROI_TBDPosition_DoesNotAffectLosingPosition() public {
        // Register user
        _mockRulesModuleForRegistration();
        vm.warp(block.timestamp + 2 hours);
        _approveEntryFee(user1);
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);

        // --- Position 1 (contest 1): will be scored as a loss ---
        // Mock getSpeculation before addLeaderboardSpeculation so it can resolve contestId
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, speculationId);

        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", speculationId, user1, uint8(0)),
            abi.encode(50_000_000, 40_000_000, uint8(0), false)
        );
        _mockRulesModuleValidation(true);


        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(speculationId, PositionType.Upper, leaderboardId);

        // --- Position 2 (contest 2): will remain TBD ---
        uint256 specId2 = 2;
        uint256 contestId2 = 2;
        Contest memory contest2 = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: admin,
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "test2", sportspageId: "test2", jsonoddsId: "test2"
        });
        mockContestModule.setContest(contestId2, contest2);
        mockContestModule.setContestStartTime(contestId2, uint32(block.timestamp + 4 hours));

        // Mock getSpeculation before addLeaderboardSpeculation so it can resolve contestId
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", specId2),
            abi.encode(contestId2, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId2);

        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", specId2, user1, uint8(0)),
            abi.encode(50_000_000, 40_000_000, uint8(0), false)
        );
        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(specId2, PositionType.Upper, leaderboardId);

        // Mock min positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );

        // --- Set scoring outcomes ---
        // Speculation 1: Home win (Upper position loses) -> net = -50M
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", speculationId),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(2)) // Home
        );
        // Speculation 2: TBD -> excluded, net = 0
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", specId2),
            abi.encode(contestId2, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(0)) // TBD
        );

        // Submit ROI
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        vm.warp(roiWindowStart);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // ROI = -50M / 100M bankroll = -50% = -5e17
        // If TBD were also a loss: ROI = (-50M + -50M) / 100M = -100% = -1e18
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        assertEq(roi, -500000000000000000, "ROI should reflect only the losing position (-50%)");
    }

    // --- Helper: sets up two tied winners and warps to claim window ---
    function _setupTwoTiedWinnersInClaimWindow() internal returns (uint256 prizePool) {
        // Register user1
        _mockRulesModuleForRegistration();
        vm.warp(block.timestamp + 2 hours);
        _approveEntryFee(user1);
        vm.prank(user1);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);

        // Register user2
        _approveEntryFee(user2);
        vm.prank(user2);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);

        // Mock getSpeculation before addLeaderboardSpeculation so it can resolve contestId
        _mockPositionModuleCalls();

        // Add speculation and register position for user1
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, speculationId);
        _mockRulesModuleValidation(true);


        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(speculationId, PositionType.Upper, leaderboardId);

        // Setup user2's position on a second speculation
        uint256 specId2 = 2;
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", specId2, user2, uint8(0)),
            abi.encode(50_000_000, 40_000_000, uint8(0), false)
        );
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", specId2),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(0), uint8(0))
        );
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId2);
        vm.prank(user2);
        leaderboardModule.registerPositionForLeaderboard(specId2, PositionType.Upper, leaderboardId);

        // Mock min positions check
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock both speculations as Push (0 ROI) for scoring
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(5)) // Push
        );

        // Warp to ROI window and submit for both
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        vm.warp(roiWindowStart);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
        vm.prank(user2);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // Verify tie
        address[] memory winners = leaderboardModule.getWinners(leaderboardId);
        assertEq(winners.length, 2, "should have 2 tied winners");

        // Record prize pool and warp past ROI window (claims open forever after)
        prizePool = treasuryModule.getPrizePool(leaderboardId);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);
        vm.warp(roiWindowEnd);

        return prizePool;
    }

    // --- Helper: mirrors _calculateTimeBounds from LeaderboardModule for test use ---
    function _calculateTimeBoundsExternal(
        Leaderboard memory lb
    ) internal pure returns (uint256, uint256) {
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);
        return (roiWindowStart, roiWindowEnd);
    }

    // --- createLeaderboard Zero Windows Tests ---

    function testCreateLeaderboard_RevertsIfROIWindowZero() public {
        vm.prank(admin);
        token.approve(address(treasuryModule), LB_FEE);

        vm.prank(admin);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__InvalidTimeRange.selector);
        leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            SAFETY_PERIOD,
            0 // roiSubmissionWindow = 0
        );
    }

    // --- ROI/Claim Window Overlap Fix Tests ---

    function testSubmitROI_RevertsAtExactBoundary() public {
        // Setup a winner scenario
        _setupCompleteLeaderboardScenario();

        // Calculate the exact roiWindowEnd boundary
        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowEnd = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration) + uint256(lb.roiSubmissionWindow);

        // Warp to exact boundary
        vm.warp(roiWindowEnd);

        // ROI submission should be rejected at exact boundary (window is now exclusive on upper end)
        vm.prank(user1);
        vm.expectRevert(LeaderboardModule.LeaderboardModule__NotInROIWindow.selector);
        leaderboardModule.submitLeaderboardROI(leaderboardId);
    }

    function testSubmitROI_SucceedsOneSecondBeforeBoundary() public {
        _setupCompleteLeaderboardScenario();

        Leaderboard memory lb = leaderboardModule.getLeaderboard(leaderboardId);
        uint256 roiWindowEnd = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration) + uint256(lb.roiSubmissionWindow);

        // One second before boundary — should succeed
        vm.warp(roiWindowEnd - 1);

        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(leaderboardId);

        // Verify ROI was stored
        int256 roi = leaderboardModule.getUserROI(leaderboardId, user1);
        // ROI value depends on position mock (Push = 0 ROI), but no revert means success
        assertEq(roi, 0);
    }

    // --- Free Leaderboard (Zero Entry Fee) Tests ---

    function testFreeLeaderboard_WinnerCanClaim() public {
        // Approve leaderboard creation fee for user3 (anyone can create)
        vm.prank(user3);
        token.approve(address(treasuryModule), LB_FEE);

        // Create a free leaderboard (0 entry fee)
        vm.prank(user3);
        uint256 freeLbId = leaderboardModule.createLeaderboard(
            0, // entryFee = 0
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            SAFETY_PERIOD,
            ROI_WINDOW
        );

        // Register user (no entry fee needed)
        _mockRulesModuleForRegistration();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user1);
        leaderboardModule.registerUser(freeLbId, DECLARED_BANKROLL);

        // Setup position (user3 is the creator, so they add speculations)
        // Mock getSpeculation before addLeaderboardSpeculation so it can resolve contestId
        _mockPositionModuleCalls();
        vm.prank(user3);
        leaderboardModule.addLeaderboardSpeculation(freeLbId, speculationId);
        _mockRulesModuleValidation(true);

        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(speculationId, PositionType.Upper, freeLbId);

        // Mock min positions
        vm.mockCall(
            address(rulesModule),
            abi.encodeWithSignature("isMinPositionsMet(uint256,uint256)"),
            abi.encode(true)
        );

        // Mock speculation as Push for ROI calc
        vm.mockCall(
            address(speculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)"),
            abi.encode(contestId, address(mockScorerModule), int32(0), address(0), uint8(1), uint8(5))
        );

        // Submit ROI
        Leaderboard memory lb = leaderboardModule.getLeaderboard(freeLbId);
        uint256 roiWindowStart = uint256(lb.endTime) + uint256(lb.safetyPeriodDuration);
        vm.warp(roiWindowStart);
        vm.prank(user1);
        leaderboardModule.submitLeaderboardROI(freeLbId);

        // Warp past ROI window (claims open forever)
        uint256 roiWindowEnd = roiWindowStart + uint256(lb.roiSubmissionWindow);
        vm.warp(roiWindowEnd);

        // Mock treasury to return 0 prize pool
        vm.mockCall(
            address(treasuryModule),
            abi.encodeWithSignature("getPrizePool(uint256)"),
            abi.encode(0)
        );

        // Winner should be able to claim without reverting (share = 0, skips treasury call)
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LeaderboardModule.LeaderboardPrizeClaimed(freeLbId, user1, 0);
        leaderboardModule.claimLeaderboardPrize(freeLbId);

        // Verify user is marked as claimed
        assertTrue(leaderboardModule.hasClaimed(freeLbId, user1));
    }
}
