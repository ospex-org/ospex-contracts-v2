// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] All odds in this file use 1e7 precision: 1.10 = 11_000_000, 1.80 = 18_000_000, etc.

import "forge-std/Test.sol";
import {RulesModule} from "../../src/modules/RulesModule.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockSpeculationModule} from "../mocks/MockSpeculationModule.sol";
import {
    LeagueId,
    PositionType,
    Leaderboard,
    Contest,
    ContestMarket,
    ContestStatus,
    Speculation,
    SpeculationStatus,
    WinSide,
    LeaderboardPositionValidationResult
} from "../../src/core/OspexTypes.sol";

contract RulesModuleTest is Test {
    // --- Core Contracts ---
    OspexCore core;
    RulesModule rulesModule;
    LeaderboardModule leaderboardModule;
    TreasuryModule treasuryModule;
    PositionModule positionModule;
    MockERC20 token;
    MockContestModule mockContestModule;
    MockScorerModule mockScorerModule;
    MockSpeculationModule mockSpeculationModule;

    // --- Test Accounts ---
    address admin = address(0x1234);
    address nonAdmin = address(0xBAD);
    address user1 = address(0xBEEF);
    address mockScorer = address(0xFEED);
    address protocolReceiver = address(0xABC);

    // --- Test Constants ---
    uint256 constant TOKEN_AMOUNT = 1_000_000_000; // 1000 USDC
    uint256 constant MIN_BANKROLL = 50_000_000; // 50 USDC
    uint256 constant MAX_BANKROLL = 500_000_000; // 500 USDC
    uint256 constant DECLARED_BANKROLL = 100_000_000; // 100 USDC
    uint16 constant MIN_BET_PERCENTAGE = 100; // 1% of bankroll
    uint16 constant MAX_BET_PERCENTAGE = 1000; // 10% of bankroll
    uint16 constant MIN_BETS = 5; // minimum 5 positions
    uint16 constant ODDS_ENFORCEMENT_BPS = 2500; // 25% enforcement
    int32 constant MAX_DEVIATION = 150; // 1.5 point deviation
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

        // Deploy modules
        rulesModule = new RulesModule(address(core));
        leaderboardModule = new LeaderboardModule(address(core));
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);
        positionModule = new PositionModule(address(core), address(token));
        
        // Deploy mock modules
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();
        mockSpeculationModule = new MockSpeculationModule(address(core), 6);

        // Register modules
        core.registerModule(keccak256("RULES_MODULE"), address(rulesModule));
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(leaderboardModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(mockSpeculationModule));
        core.registerModule(keccak256("ORACLE_MODULE"), address(this)); // Test contract as oracle
        
        // Register scorer modules for directional position conflict testing
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), address(mockScorerModule));
        core.registerModule(keccak256("SPREAD_SCORER_MODULE"), address(mockScorerModule));

        // Grant admin role
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);

        // Set up a verified contest in the mock
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

        // Set up contest market data for validation tests
        ContestMarket memory market = ContestMarket({
            theNumber: 150,        // Market spread/total number
            upperOdds: 18_000_000, // 1.8 odds for Upper
            lowerOdds: 12_000_000, // 1.2 odds for Lower  
            lastUpdated: uint32(block.timestamp)
        });
        mockContestModule.setContestMarket(contestId, mockScorer, market);

        // Set up a basic speculation
        Speculation memory speculation = Speculation({
            contestId: contestId,
            speculationScorer: mockScorer,
            theNumber: 150, // +1.5 spread
            speculationCreator: admin,
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        });
        mockSpeculationModule.setTestSpeculation(speculationId, speculation);

        // Create a basic leaderboard for testing
        vm.prank(admin);
        leaderboardId = leaderboardModule.createLeaderboard(
            0, // no entry fee
            address(0), // no yield strategy
            uint32(block.timestamp + 1 hours), // starts in 1 hour
            uint32(block.timestamp + 8 days), // ends in 8 days
            SAFETY_PERIOD,
            ROI_WINDOW,
            CLAIM_WINDOW
        );

        // Add speculation to leaderboard for rules validation
        vm.prank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, speculationId);
    }

    // --- Constructor Tests ---
    function testConstructor_SetsOspexCore() public view {
        assertEq(address(rulesModule.i_ospexCore()), address(core));
    }

    function testConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(RulesModule.RulesModule__InvalidValue.selector);
        new RulesModule(address(0));
    }

    // --- Module Type Test ---
    function testGetModuleType_ReturnsCorrectValue() public view {
        assertEq(rulesModule.getModuleType(), keccak256("RULES_MODULE"));
    }

    // --- Rule Setter Tests ---
    function testSetMinBankroll_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "minBankroll", MIN_BANKROLL);
        
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
        
        assertEq(rulesModule.s_minBankroll(leaderboardId), MIN_BANKROLL);
    }

    function testSetMinBankroll_RevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotAdmin.selector, nonAdmin));
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
    }

    function testSetMinBankroll_RevertsIfLeaderboardStarted() public {
        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(admin);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
    }

    function testSetMinBankroll_RevertsIfInvalidLeaderboard() public {
        uint256 invalidLeaderboardId = 999;
        
        vm.prank(admin);
        vm.expectRevert(RulesModule.RulesModule__InvalidLeaderboard.selector);
        rulesModule.setMinBankroll(invalidLeaderboardId, MIN_BANKROLL);
    }

    function testSetMaxBankroll_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "maxBankroll", MAX_BANKROLL);
        
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
        
        assertEq(rulesModule.s_maxBankroll(leaderboardId), MAX_BANKROLL);
    }

    function testSetMinBetPercentage_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "minBetPercentage", MIN_BET_PERCENTAGE);
        
        rulesModule.setMinBetPercentage(leaderboardId, MIN_BET_PERCENTAGE);
        
        assertEq(rulesModule.s_minBetPercentage(leaderboardId), MIN_BET_PERCENTAGE);
    }

    function testSetMinBetPercentage_RevertsIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(RulesModule.RulesModule__InvalidBps.selector);
        rulesModule.setMinBetPercentage(leaderboardId, 10001); // > 100%
    }

    function testSetMaxBetPercentage_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "maxBetPercentage", MAX_BET_PERCENTAGE);
        
        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);
        
        assertEq(rulesModule.s_maxBetPercentage(leaderboardId), MAX_BET_PERCENTAGE);
    }

    function testSetMinBets_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "minBets", MIN_BETS);
        
        rulesModule.setMinBets(leaderboardId, MIN_BETS);
        
        assertEq(rulesModule.s_minBets(leaderboardId), MIN_BETS);
    }

    function testSetOddsEnforcementBps_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "oddsEnforcementBps", ODDS_ENFORCEMENT_BPS);
        
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS);
        
        assertEq(rulesModule.s_oddsEnforcementBps(leaderboardId), ODDS_ENFORCEMENT_BPS);
    }

    function testSetDeviationRule_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.DeviationRuleSet(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION
        );
        
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION
        );
        
        assertEq(
            rulesModule.s_deviationRules(leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper),
            MAX_DEVIATION
        );
        assertTrue(
            rulesModule.s_deviationRuleSet(leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper)
        );
    }

    function testSetAllowLiveBetting_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "allowLiveBetting", 1);
        
        rulesModule.setAllowLiveBetting(leaderboardId, true);
        
        assertTrue(rulesModule.s_allowLiveBetting(leaderboardId));
    }

    function testSetAllowLiveBetting_RevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotAdmin.selector, nonAdmin));
        rulesModule.setAllowLiveBetting(leaderboardId, true);
    }

    function testSetAllowLiveBetting_RevertsIfLeaderboardStarted() public {
        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(admin);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setAllowLiveBetting(leaderboardId, true);
    }

    function testSetAllowLiveBetting_DefaultsToFalse() public view {
        // Default value should be false
        assertFalse(rulesModule.s_allowLiveBetting(leaderboardId));
    }

    // --- Validation Function Tests ---
    function testIsBankrollValid_WithinRange() public {
        vm.startPrank(admin);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
        vm.stopPrank();

        // Valid bankroll
        assertTrue(rulesModule.isBankrollValid(leaderboardId, DECLARED_BANKROLL));
        
        // Edge cases
        assertTrue(rulesModule.isBankrollValid(leaderboardId, MIN_BANKROLL)); // exactly min
        assertTrue(rulesModule.isBankrollValid(leaderboardId, MAX_BANKROLL)); // exactly max
    }

    function testIsBankrollValid_OutOfRange() public {
        vm.startPrank(admin);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
        vm.stopPrank();

        // Below minimum
        assertFalse(rulesModule.isBankrollValid(leaderboardId, MIN_BANKROLL - 1));
        
        // Above maximum
        assertFalse(rulesModule.isBankrollValid(leaderboardId, MAX_BANKROLL + 1));
    }

    function testIsBankrollValid_NoLimitsSet() public view {
        // No limits set - should always return true
        assertTrue(rulesModule.isBankrollValid(leaderboardId, 1));
        assertTrue(rulesModule.isBankrollValid(leaderboardId, type(uint256).max));
    }


    function testIsMinPositionsMet_EnoughPositions() public {
        vm.prank(admin);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);

        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, MIN_BETS)); // exactly min
        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, MIN_BETS + 1)); // above min
    }

    function testIsMinPositionsMet_NotEnoughPositions() public {
        vm.prank(admin);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);

        assertFalse(rulesModule.isMinPositionsMet(leaderboardId, MIN_BETS - 1));
    }

    function testIsMinPositionsMet_NoMinimumSet() public view {
        // No minimum set - should always return true
        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, 0));
        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, 1));
    }

    function testIsOddsValid_NoEnforcement() public view {
        // No enforcement set - all odds should be valid
        uint64 marketOdds = 18_000_000; // 1.8
        uint64 userOdds = 30_000_000; // 3.0 (much better than market)
        
        assertTrue(rulesModule.validateOdds(leaderboardId, userOdds, marketOdds));
    }

    function testIsOddsValid_WorseOddsAlwaysAllowed() public {
        vm.prank(admin);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint64 marketOdds = 18_000_000; // 1.8
        uint64 worseOdds = 15_000_000; // 1.5 (worse than market)
        
        assertTrue(rulesModule.validateOdds(leaderboardId, worseOdds, marketOdds));
        assertTrue(rulesModule.validateOdds(leaderboardId, marketOdds, marketOdds)); // equal
    }

    function testIsOddsValid_WithinEnforcementLimit() public {
        vm.prank(admin);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint64 marketOdds = 20_000_000; // 2.0
        // Market profit = 2.0 - 1.0 = 1.0
        // 25% of market profit = 0.25
        // Max allowed = 2.0 + 0.25 = 2.25 = 22_500_000
        uint64 allowedOdds = 22_500_000;
        
        assertTrue(rulesModule.validateOdds(leaderboardId, allowedOdds, marketOdds));
    }

    function testIsOddsValid_ExceedsEnforcementLimit() public {
        vm.prank(admin);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint64 marketOdds = 20_000_000; // 2.0
        // Max allowed = 2.25 = 22_500_000 (calculated above)
        uint64 tooGoodOdds = 22_500_001; // Just over the limit
        
        assertFalse(rulesModule.validateOdds(leaderboardId, tooGoodOdds, marketOdds));
    }

    function testIsNumberValid_NoRuleSet() public view {
        // No deviation rule set - should allow all numbers
        assertTrue(rulesModule.validateNumber(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            500, // user number
            150  // market number
        ));
    }

    function testIsNumberValid_WithinDeviation() public {
        vm.prank(admin);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION // 150 (1.5 points)
        );

        int32 marketNumber = 150; // +1.5
        
        // Within deviation
        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            300, marketNumber // 300 - 150 = 150 (exactly at limit)
        ));
        
        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            0, marketNumber // 150 - 0 = 150 (exactly at limit)
        ));
        
        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            200, marketNumber // 200 - 150 = 50 (within limit)
        ));
    }

    function testIsNumberValid_ExceedsDeviation() public {
        vm.prank(admin);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION // 150 (1.5 points)
        );

        int32 marketNumber = 150; // +1.5
        
        // Exceeds deviation
        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            301, marketNumber // 301 - 150 = 151 (over limit)
        ));
        
        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            -1, marketNumber // 150 - (-1) = 151 (over limit)
        ));
    }

    function testIsNumberValid_ExactMatchRequired() public {
        vm.prank(admin);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            0 // exact match required
        );

        int32 marketNumber = 150;
        
        // Only exact match allowed
        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            150, marketNumber
        ));
        
        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            151, marketNumber
        ));
        
        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            149, marketNumber
        ));
    }

    // --- Comprehensive Validation Tests ---
    function testValidateLeaderboardPosition_Success() public {
        _setupCompleteRules();
        
        // Move to leaderboard active period
        vm.warp(block.timestamp + 2 hours);
        
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150, // exact market number
            18_000_000, // market odds
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.Valid));
    }

    function testValidateLeaderboardPosition_FailsInvalidLeaderboard() public view {
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            999, // invalid leaderboard
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.LeaderboardDoesNotExist));
    }

    function testValidateLeaderboardPosition_FailsOutsideTimeWindow() public {
        _setupCompleteRules();
        
        // Before leaderboard starts
        LeaderboardPositionValidationResult result1 = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result1), uint256(LeaderboardPositionValidationResult.LeaderboardHasNotStarted));
        
        // After leaderboard ends
        vm.warp(block.timestamp + 9 days);
        LeaderboardPositionValidationResult result2 = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result2), uint256(LeaderboardPositionValidationResult.LeaderboardHasEnded));
    }

    // NOTE: Bet amount validation moved to LeaderboardModule
    // This test is no longer applicable as RulesModule doesn't validate bet amounts

    function testValidateLeaderboardPosition_FailsSpeculationNotRegistered() public {
        _setupCompleteRules();
        // Don't setup leaderboard speculation - use unregistered speculation ID
        vm.warp(block.timestamp + 2 hours);
        
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId + 1, // Use speculation ID 2 which is not registered
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.SpeculationNotRegistered));
    }

    function testValidateLeaderboardPosition_FailsNumberDeviation() public {
        _setupCompleteRules();
        vm.warp(block.timestamp + 2 hours);
        
        // Number too far from market (market is 150, max deviation is 150)
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            350, // 350 - 150 = 200 > 150 max deviation
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.NumberDeviationTooLarge));
    }

    function testValidateLeaderboardPosition_FailsOddsEnforcement() public {
        _setupCompleteRules();
        vm.warp(block.timestamp + 2 hours);
        
        // Odds too good (market 1.8, max allowed ~2.25, user wants 3.0)
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            30_000_000, // 3.0 odds (too good)
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.OddsTooFavorable));
    }

    function testValidateLeaderboardPosition_FailsLiveBettingDisabled() public {
        _setupCompleteRules();
        
        // Move to leaderboard active period first
        vm.warp(block.timestamp + 2 hours);
        
        // Set contest start time to before current time (contest has started)
        uint32 contestStartTime = uint32(block.timestamp - 1 hours);
        mockContestModule.setContestStartTime(contestId, contestStartTime);
        
        // Live betting is disabled by default, so this should fail
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.LiveBettingNotAllowed));
    }

    function testValidateLeaderboardPosition_SucceedsLiveBettingEnabled() public {
        _setupCompleteRules();
        
        // Enable live betting
        vm.prank(admin);
        rulesModule.setAllowLiveBetting(leaderboardId, true);
        
        // Move to leaderboard active period first
        vm.warp(block.timestamp + 2 hours);
        
        // Set contest start time to before current time (contest has started)
        uint32 contestStartTime = uint32(block.timestamp - 1 hours);
        mockContestModule.setContestStartTime(contestId, contestStartTime);
        
        // Live betting is enabled, so this should succeed
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.Valid));
    }

    function testValidateLeaderboardPosition_SucceedsBeforeContestStarts() public {
        _setupCompleteRules();
        
        // Set contest start time to future (contest hasn't started yet)
        uint32 contestStartTime = uint32(block.timestamp + 4 hours);
        mockContestModule.setContestStartTime(contestId, contestStartTime);
        
        // Move to leaderboard active period (but before contest starts)
        vm.warp(block.timestamp + 2 hours);
        
        // Should succeed regardless of live betting setting since contest hasn't started
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.Valid));
    }

    function testGetAllRules_WithLiveBettingEnabled() public {
        _setupCompleteRules();
        
        // Enable live betting
        vm.prank(admin);
        rulesModule.setAllowLiveBetting(leaderboardId, true);
        
        (
            uint256 minBankroll,
            uint256 maxBankroll,
            uint16 minBetPercentage,
            uint16 maxBetPercentage,
            uint16 minBets,
            uint16 oddsEnforcementBps,
            bool allowLiveBetting
        ) = rulesModule.getAllRules(leaderboardId);
        
        assertEq(minBankroll, MIN_BANKROLL);
        assertEq(maxBankroll, MAX_BANKROLL);
        assertEq(minBetPercentage, MIN_BET_PERCENTAGE);
        assertEq(maxBetPercentage, MAX_BET_PERCENTAGE);
        assertEq(minBets, MIN_BETS);
        assertEq(oddsEnforcementBps, ODDS_ENFORCEMENT_BPS);
        assertTrue(allowLiveBetting); // Should be true after setting
    }

    // --- Getter Function Tests ---
    function testGetDeviationRule_Set() public {
        vm.prank(admin);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION
        );
        
        (int32 maxDeviation, bool isSet) = rulesModule.getDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper
        );
        
        assertEq(maxDeviation, MAX_DEVIATION);
        assertTrue(isSet);
    }

    function testGetDeviationRule_NotSet() public view {
        (int32 maxDeviation, bool isSet) = rulesModule.getDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper
        );
        
        assertEq(maxDeviation, 0); // default value
        assertFalse(isSet);
    }

    function testGetAllRules() public { 
        _setupCompleteRules();
        
        (
            uint256 minBankroll,
            uint256 maxBankroll,
            uint16 minBetPercentage,
            uint16 maxBetPercentage,
            uint16 minBets,
            uint16 oddsEnforcementBps,
            bool allowLiveBetting
        ) = rulesModule.getAllRules(leaderboardId);
        
        assertEq(minBankroll, MIN_BANKROLL);
        assertEq(maxBankroll, MAX_BANKROLL);
        assertEq(minBetPercentage, MIN_BET_PERCENTAGE);
        assertEq(maxBetPercentage, MAX_BET_PERCENTAGE);
        assertEq(minBets, MIN_BETS);
        assertEq(oddsEnforcementBps, ODDS_ENFORCEMENT_BPS);
        assertFalse(allowLiveBetting); // Default should be false
    }

    function testGetMaxBetAmount_WithLimit() public {
        vm.prank(admin);
        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);
        
        uint256 maxBet = rulesModule.getMaxBetAmount(leaderboardId, DECLARED_BANKROLL);
        uint256 expected = (DECLARED_BANKROLL * MAX_BET_PERCENTAGE) / 10000;
        
        assertEq(maxBet, expected);
    }

    function testGetMaxBetAmount_NoLimit() public view {
        uint256 maxBet = rulesModule.getMaxBetAmount(leaderboardId, DECLARED_BANKROLL);
        assertEq(maxBet, type(uint256).max);
    }

    function testGetMinBetAmount_WithMinimum() public {
        vm.prank(admin);
        rulesModule.setMinBetPercentage(leaderboardId, MIN_BET_PERCENTAGE);
        
        uint256 minBet = rulesModule.getMinBetAmount(leaderboardId, DECLARED_BANKROLL);
        uint256 expected = (DECLARED_BANKROLL * MIN_BET_PERCENTAGE) / 10000;
        
        assertEq(minBet, expected);
    }

    function testGetMinBetAmount_NoMinimum() public view {
        uint256 minBet = rulesModule.getMinBetAmount(leaderboardId, DECLARED_BANKROLL);
        assertEq(minBet, 0);
    }

    // --- Edge Case Tests ---
    function testRuleChanges_OnlyBeforeLeaderboardStarts() public {
        // Should work before start
        vm.prank(admin);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
        
        // Should fail after start
        vm.warp(block.timestamp + 2 hours);
        vm.prank(admin);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
    }

    function testValidation_HandlesZeroValues() public view {
        // Zero bankroll
        assertTrue(rulesModule.isBankrollValid(leaderboardId, 0));
    }

    function testValidation_HandlesMaxValues() public view {
        // Max uint256 values should not cause overflow
        assertTrue(rulesModule.isBankrollValid(leaderboardId, type(uint256).max));
    }

    function testModuleNotSet_Errors() public {
        // Create a new core without registered modules
        OspexCore newCore = new OspexCore();
        RulesModule newRulesModule = new RulesModule(address(newCore));
        
        vm.expectRevert(
            abi.encodeWithSelector(
                RulesModule.RulesModule__ModuleNotSet.selector,
                keccak256("LEADERBOARD_MODULE")
            )
        );
        newRulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1, // user address
            150,
            18_000_000,
            PositionType.Upper
        );
    }

    // --- Helper Functions ---
    function _setupCompleteRules() internal {
        vm.startPrank(admin);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
        rulesModule.setMinBetPercentage(leaderboardId, MIN_BET_PERCENTAGE);
        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION
        );
        vm.stopPrank();
        
        // Set contest start time to future by default (contest hasn't started)
        // This ensures existing tests continue to work as expected
        uint32 contestStartTime = uint32(block.timestamp + 6 hours);
        mockContestModule.setContestStartTime(contestId, contestStartTime);
    }

    function testValidateLeaderboardPosition_FailsDirectionalConflict_MoneylineToSpread() public {
        _setupCompleteRules();
        vm.warp(block.timestamp + 2 hours);
        
        // Create separate mock scorer addresses for moneyline and spread
        address mockMoneylineScorer = address(0x1111);
        address mockSpreadScorer = address(0x2222);
        
        // Register these as separate scorer modules (no prank needed - test contract has permissions)
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), mockMoneylineScorer);
        core.registerModule(keccak256("SPREAD_SCORER_MODULE"), mockSpreadScorer);
        
        // Set up contest markets for both scorer addresses
        mockContestModule.setContestMarket(contestId, mockMoneylineScorer, ContestMarket({
            theNumber: 150,
            upperOdds: 18_000_000,
            lowerOdds: 12_000_000,
            lastUpdated: 1
        }));
        mockContestModule.setContestMarket(contestId, mockSpreadScorer, ContestMarket({
            theNumber: 150,
            upperOdds: 18_000_000,
            lowerOdds: 12_000_000,
            lastUpdated: 1
        }));
        
        // Add the new speculations to the leaderboard
        vm.startPrank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, 10); // moneyline speculation
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, 11); // spread speculation  
        vm.stopPrank();
        
        // Create a speculation with moneyline scorer
        uint256 moneylineSpeculationId = 10;
        vm.mockCall(
            address(mockSpeculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", moneylineSpeculationId),
            abi.encode(Speculation({
                contestId: contestId,
                speculationScorer: mockMoneylineScorer,
                theNumber: 150,
                speculationCreator: address(0),
                speculationStatus: SpeculationStatus.Open,
                winSide: WinSide.TBD
            }))
        );
        
        // Create a speculation with spread scorer  
        uint256 spreadSpeculationId = 11;
        vm.mockCall(
            address(mockSpeculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", spreadSpeculationId),
            abi.encode(Speculation({
                contestId: contestId,
                speculationScorer: mockSpreadScorer,
                theNumber: 150,
                speculationCreator: address(0),
                speculationStatus: SpeculationStatus.Open,
                winSide: WinSide.TBD
            }))
        );
        
        // Mock that user already has a moneyline position registered for this contest
        vm.mockCall(
            address(leaderboardModule),
            abi.encodeWithSignature(
                "s_registeredLeaderboardSpeculation(uint256,address,uint256,address)",
                leaderboardId,
                user1,
                contestId,
                mockMoneylineScorer
            ),
            abi.encode(moneylineSpeculationId) // Non-zero = position exists
        );
        
        // Mock that user doesn't have a spread position yet
        vm.mockCall(
            address(leaderboardModule),
            abi.encodeWithSignature(
                "s_registeredLeaderboardSpeculation(uint256,address,uint256,address)",
                leaderboardId,
                user1,
                contestId,
                mockSpreadScorer
            ),
            abi.encode(0) // Zero = no position
        );
        
        // Try to register spread position - should fail with DirectionalPositionConflict
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            spreadSpeculationId,
            user1,
            150,
            18_000_000,
            PositionType.Upper
        );
        
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.DirectionalPositionConflict));
    }

    function testValidateLeaderboardPosition_FailsDirectionalConflict_SpreadToMoneyline() public {
        _setupCompleteRules();
        vm.warp(block.timestamp + 2 hours);
        
        // Create separate mock scorer addresses for moneyline and spread
        address mockMoneylineScorer = address(0x1111);
        address mockSpreadScorer = address(0x2222);
        
        // Register these as separate scorer modules (no prank needed - test contract has permissions)
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), mockMoneylineScorer);
        core.registerModule(keccak256("SPREAD_SCORER_MODULE"), mockSpreadScorer);
        
        // Set up contest markets for both scorer addresses
        mockContestModule.setContestMarket(contestId, mockMoneylineScorer, ContestMarket({
            theNumber: 150,
            upperOdds: 18_000_000,
            lowerOdds: 12_000_000,
            lastUpdated: 1
        }));
        mockContestModule.setContestMarket(contestId, mockSpreadScorer, ContestMarket({
            theNumber: 150,
            upperOdds: 18_000_000,
            lowerOdds: 12_000_000,
            lastUpdated: 1
        }));
        
        // Add the new speculations to the leaderboard
        vm.startPrank(admin);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, 12); // spread speculation
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, 13); // moneyline speculation  
        vm.stopPrank();
        
        // Create a speculation with spread scorer
        uint256 spreadSpeculationId = 12;
        vm.mockCall(
            address(mockSpeculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", spreadSpeculationId),
            abi.encode(Speculation({
                contestId: contestId,
                speculationScorer: mockSpreadScorer,
                theNumber: 150,
                speculationCreator: address(0),
                speculationStatus: SpeculationStatus.Open,
                winSide: WinSide.TBD
            }))
        );
        
        // Create a speculation with moneyline scorer
        uint256 moneylineSpeculationId = 13;
        vm.mockCall(
            address(mockSpeculationModule),
            abi.encodeWithSignature("getSpeculation(uint256)", moneylineSpeculationId),
            abi.encode(Speculation({
                contestId: contestId,
                speculationScorer: mockMoneylineScorer,
                theNumber: 150,
                speculationCreator: address(0),
                speculationStatus: SpeculationStatus.Open,
                winSide: WinSide.TBD
            }))
        );
        
        // Mock that user already has a spread position registered for this contest
        vm.mockCall(
            address(leaderboardModule),
            abi.encodeWithSignature(
                "s_registeredLeaderboardSpeculation(uint256,address,uint256,address)",
                leaderboardId,
                user1,
                contestId,
                mockSpreadScorer
            ),
            abi.encode(spreadSpeculationId) // Non-zero = position exists
        );
        
        // Mock that user doesn't have a moneyline position yet
        vm.mockCall(
            address(leaderboardModule),
            abi.encodeWithSignature(
                "s_registeredLeaderboardSpeculation(uint256,address,uint256,address)",
                leaderboardId,
                user1,
                contestId,
                mockMoneylineScorer
            ),
            abi.encode(0) // Zero = no position
        );
        
        // Try to register moneyline position - should fail with DirectionalPositionConflict
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            moneylineSpeculationId,
            user1,
            150,
            18_000_000,
            PositionType.Upper
        );
        
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.DirectionalPositionConflict));
    }
}
