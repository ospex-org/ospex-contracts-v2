// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All test amounts in this file use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] All odds in this file use uint16 ticks: 1.80 = 180, 1.20 = 120, etc.
// [NOTE] lineTicks is in 10x format: 1.5 = 15, -3.5 = -35, 220.5 = 2205

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
    address creator = address(0x1234);
    address nonCreator = address(0xBAD);
    address user1 = address(0xBEEF);
    address mockScorer = address(0xFEED);
    address protocolReceiver = address(0xABC);

    // --- Scorer addresses used in bootstrap (for directional conflict tests) ---
    address mockMoneylineScorer = address(0x1111);
    address mockSpreadScorer = address(0x2222);

    // --- Test Constants ---
    uint256 constant TOKEN_AMOUNT = 1_000_000_000; // 1000 USDC
    uint256 constant MIN_BANKROLL = 50_000_000; // 50 USDC
    uint256 constant MAX_BANKROLL = 500_000_000; // 500 USDC
    uint256 constant DECLARED_BANKROLL = 100_000_000; // 100 USDC
    uint16 constant MIN_BET_PERCENTAGE = 100; // 1% of bankroll
    uint16 constant MAX_BET_PERCENTAGE = 1000; // 10% of bankroll
    uint16 constant MIN_BETS = 5; // minimum 5 positions
    uint16 constant ODDS_ENFORCEMENT_BPS = 2500; // 25% enforcement
    int32 constant MAX_DEVIATION = 15; // 1.5 point deviation (10x format)
    uint32 constant SAFETY_PERIOD = 1 days;
    uint32 constant ROI_WINDOW = 7 days;

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
        treasuryModule = new TreasuryModule(
            address(core), address(token), protocolReceiver,
            1_000_000, // contestCreationFeeRate
            500_000,   // speculationCreationFeeRate
            500_000    // leaderboardCreationFeeRate
        );
        positionModule = new PositionModule(address(core), address(token));

        // Deploy mock modules
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();
        mockSpeculationModule = new MockSpeculationModule(address(core), 6, 7 days, 1_000_000);

        // Bootstrap all 12 modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = address(mockContestModule);
        types[1] = core.SPECULATION_MODULE();        addrs[1] = address(mockSpeculationModule);
        types[2] = core.POSITION_MODULE();           addrs[2] = address(positionModule);
        types[3] = core.MATCHING_MODULE();           addrs[3] = address(0xD004);
        types[4] = core.ORACLE_MODULE();             addrs[4] = address(this);
        types[5] = core.TREASURY_MODULE();           addrs[5] = address(treasuryModule);
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = address(leaderboardModule);
        types[7] = core.RULES_MODULE();              addrs[7] = address(rulesModule);
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xD008);
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = mockMoneylineScorer;
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = mockSpreadScorer;
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = address(0xD00B);
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Fund creator and approve treasury for leaderboard creation fee
        token.transfer(creator, TOKEN_AMOUNT);
        vm.prank(creator);
        token.approve(address(treasuryModule), type(uint256).max);

        // Set up a verified contest in the mock
        Contest memory contest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: creator,
            scoreContestSourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            rundownId: "test-rundown-id",
            sportspageId: "test-sportspage-id",
            jsonoddsId: "test-jsonodds-id"
        });
        mockContestModule.setContest(contestId, contest);

        // Set up contest market data for validation tests (uint16 ticks, 10x lineTicks)
        ContestMarket memory market = ContestMarket({
            lineTicks: 15,         // 1.5 spread (10x format)
            upperOdds: 180,        // 1.80 odds
            lowerOdds: 120,        // 1.20 odds
            lastUpdated: uint32(block.timestamp)
        });
        mockContestModule.setContestMarket(contestId, mockScorer, market);

        // Set up a basic speculation (10x lineTicks)
        Speculation memory speculation = Speculation({
            contestId: contestId,
            speculationScorer: mockScorer,
            lineTicks: 15, // +1.5 spread (10x format)
            speculationCreator: creator,
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        });
        mockSpeculationModule.setTestSpeculation(speculationId, speculation);

        // Set contest start time to future (required for addLeaderboardSpeculation)
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 6 hours));

        // Create a basic leaderboard for testing (creator becomes the leaderboard creator)
        vm.prank(creator);
        leaderboardId = leaderboardModule.createLeaderboard(
            0, // no entry fee
            uint32(block.timestamp + 1 hours), // starts in 1 hour
            uint32(block.timestamp + 8 days), // ends in 8 days
            SAFETY_PERIOD,
            ROI_WINDOW
        );

        // Add speculation to leaderboard for rules validation
        vm.prank(creator);
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
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "minBankroll", MIN_BANKROLL);

        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);

        assertEq(rulesModule.s_minBankroll(leaderboardId), MIN_BANKROLL);
    }

    function testSetMinBankroll_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
    }

    function testSetMinBankroll_RevertsIfLeaderboardStarted() public {
        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);
    }

    function testSetMinBankroll_RevertsIfInvalidLeaderboard() public {
        uint256 invalidLeaderboardId = 999;

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidLeaderboard.selector);
        rulesModule.setMinBankroll(invalidLeaderboardId, MIN_BANKROLL);
    }

    function testSetMaxBankroll_Success() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "maxBankroll", MAX_BANKROLL);

        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);

        assertEq(rulesModule.s_maxBankroll(leaderboardId), MAX_BANKROLL);
    }

    function testSetMinBetPercentage_Success() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "minBetPercentage", MIN_BET_PERCENTAGE);

        rulesModule.setMinBetPercentage(leaderboardId, MIN_BET_PERCENTAGE);

        assertEq(rulesModule.s_minBetPercentage(leaderboardId), MIN_BET_PERCENTAGE);
    }

    function testSetMinBetPercentage_RevertsIfTooHigh() public {
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidBps.selector);
        rulesModule.setMinBetPercentage(leaderboardId, 10001); // > 100%
    }

    function testSetMaxBetPercentage_Success() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "maxBetPercentage", MAX_BET_PERCENTAGE);

        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);

        assertEq(rulesModule.s_maxBetPercentage(leaderboardId), MAX_BET_PERCENTAGE);
    }

    function testSetMinBets_Success() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "minBets", MIN_BETS);

        rulesModule.setMinBets(leaderboardId, MIN_BETS);

        assertEq(rulesModule.s_minBets(leaderboardId), MIN_BETS);
    }

    function testSetOddsEnforcementBps_Success() public {
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "oddsEnforcementBps", ODDS_ENFORCEMENT_BPS);

        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS);

        assertEq(rulesModule.s_oddsEnforcementBps(leaderboardId), ODDS_ENFORCEMENT_BPS);
    }

    function testSetDeviationRule_Success() public {
        vm.prank(creator);
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
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit RulesModule.RuleSet(leaderboardId, "allowLiveBetting", 1);

        rulesModule.setAllowLiveBetting(leaderboardId, true);

        assertTrue(rulesModule.s_allowLiveBetting(leaderboardId));
    }

    function testSetAllowLiveBetting_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setAllowLiveBetting(leaderboardId, true);
    }

    function testSetAllowLiveBetting_RevertsIfLeaderboardStarted() public {
        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setAllowLiveBetting(leaderboardId, true);
    }

    function testSetAllowLiveBetting_DefaultsToFalse() public view {
        // Default value should be false
        assertFalse(rulesModule.s_allowLiveBetting(leaderboardId));
    }

    // --- Validation Function Tests ---
    function testIsBankrollValid_WithinRange() public {
        vm.startPrank(creator);
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
        vm.startPrank(creator);
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
        vm.prank(creator);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);

        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, MIN_BETS)); // exactly min
        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, MIN_BETS + 1)); // above min
    }

    function testIsMinPositionsMet_NotEnoughPositions() public {
        vm.prank(creator);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);

        assertFalse(rulesModule.isMinPositionsMet(leaderboardId, MIN_BETS - 1));
    }

    function testIsMinPositionsMet_NoMinimumSet() public view {
        // No minimum set - should always return true
        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, 0));
        assertTrue(rulesModule.isMinPositionsMet(leaderboardId, 1));
    }

    // --- validateOdds Tests (cross-multiplication: riskAmount, profitAmount, marketOddsTick) ---

    function testIsOddsValid_NoEnforcement() public view {
        // No enforcement set - all odds should be valid
        // risk=100, profit=200 => effective 3.0 (much better than market 1.80)
        uint256 riskAmount = 100;
        uint256 profitAmount = 200;
        uint16 marketOddsTick = 180; // 1.80

        assertTrue(rulesModule.validateOdds(leaderboardId, riskAmount, profitAmount, marketOddsTick));
    }

    function testIsOddsValid_WorseOddsAlwaysAllowed() public {
        vm.prank(creator);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint16 marketOddsTick = 180; // 1.80

        // Worse odds: risk=100, profit=50 => effective 1.50 (worse than market 1.80)
        // lhs = (100 + 50) * 100 = 15000, rhs = 100 * 180 = 18000, lhs <= rhs => valid
        assertTrue(rulesModule.validateOdds(leaderboardId, 100, 50, marketOddsTick));

        // Equal odds: risk=100, profit=80 => effective 1.80 (equal to market)
        // lhs = (100 + 80) * 100 = 18000, rhs = 100 * 180 = 18000, lhs <= rhs => valid
        assertTrue(rulesModule.validateOdds(leaderboardId, 100, 80, marketOddsTick));
    }

    function testIsOddsValid_WithinEnforcementLimit() public {
        vm.prank(creator);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint16 marketOddsTick = 200; // 2.00
        // Market 2.00, 25% above => max tick = 200 * 12500 / 10000 = 250 => effective odds 2.50
        // risk=100, profit=90 => effective 1.90 tick = 190. Better than 200 but within 25%.
        // lhs = (100 + 90) * 100 = 19000, rhs = 100 * 200 = 20000, lhs <= rhs => at-or-worse, valid
        // Actually 190 < 200, so that's worse. Let's pick something slightly better.
        // risk=100, profit=120 => effective 2.20 tick = 220. Better than 200.
        // lhs = (100 + 120) * 100 = 22000, rhs = 100 * 200 = 20000, lhs > rhs => check threshold
        // threshold: 22000 * 10000 <= 20000 * (10000 + 2500) => 220000000 <= 250000000 => valid
        assertTrue(rulesModule.validateOdds(leaderboardId, 100, 120, marketOddsTick));
    }

    function testIsOddsValid_ExceedsEnforcementLimit() public {
        vm.prank(creator);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint16 marketOddsTick = 200; // 2.00
        // Max allowed effective = 200 * 12500 / 10000 = 250 => 2.50
        // risk=100, profit=200 => effective 3.00 tick = 300. Over 250.
        // lhs = (100 + 200) * 100 = 30000, rhs = 100 * 200 = 20000
        // threshold: 30000 * 10000 <= 20000 * 12500 => 300000000 <= 250000000 => false
        assertFalse(rulesModule.validateOdds(leaderboardId, 100, 200, marketOddsTick));
    }

    function testIsOddsValid_ExactlyAtEnforcementBoundary() public {
        vm.prank(creator);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint16 marketOddsTick = 200; // 2.00
        // Max effective = 200 * 12500 / 10000 = 250 => 2.50
        // risk=100, profit=150 => effective 2.50 tick = 250. Exactly at boundary.
        // lhs = (100 + 150) * 100 = 25000, rhs = 100 * 200 = 20000
        // threshold: 25000 * 10000 <= 20000 * 12500 => 250000000 <= 250000000 => true (<=)
        assertTrue(rulesModule.validateOdds(leaderboardId, 100, 150, marketOddsTick));
    }

    function testIsOddsValid_JustOverEnforcementBoundary() public {
        vm.prank(creator);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS); // 25%

        uint16 marketOddsTick = 200; // 2.00
        // risk=100, profit=151 => effective 2.51 tick = 251. Just over boundary.
        // lhs = (100 + 151) * 100 = 25100, rhs = 100 * 200 = 20000
        // threshold: 25100 * 10000 <= 20000 * 12500 => 251000000 <= 250000000 => false
        assertFalse(rulesModule.validateOdds(leaderboardId, 100, 151, marketOddsTick));
    }

    // --- validateNumber Tests (10x format) ---

    function testIsNumberValid_NoRuleSet() public view {
        // No deviation rule set - should allow all numbers
        assertTrue(rulesModule.validateNumber(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            50, // user number (5.0 in 10x)
            15  // market number (1.5 in 10x)
        ));
    }

    function testIsNumberValid_WithinDeviation() public {
        vm.prank(creator);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION // 15 (1.5 points in 10x)
        );

        int32 marketNumber = 15; // +1.5 (10x)

        // Within deviation
        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            30, marketNumber // 30 - 15 = 15 (exactly at limit)
        ));

        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            0, marketNumber // 15 - 0 = 15 (exactly at limit)
        ));

        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            20, marketNumber // 20 - 15 = 5 (within limit)
        ));
    }

    function testIsNumberValid_ExceedsDeviation() public {
        vm.prank(creator);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION // 15 (1.5 points in 10x)
        );

        int32 marketNumber = 15; // +1.5 (10x)

        // Exceeds deviation
        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            31, marketNumber // 31 - 15 = 16 > 15 max deviation
        ));

        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            -1, marketNumber // 15 - (-1) = 16 > 15 max deviation
        ));
    }

    function testIsNumberValid_ExactMatchRequired() public {
        vm.prank(creator);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            0 // exact match required
        );

        int32 marketNumber = 15; // 1.5 (10x)

        // Only exact match allowed
        assertTrue(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            15, marketNumber
        ));

        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            16, marketNumber
        ));

        assertFalse(rulesModule.validateNumber(
            leaderboardId, LeagueId.NBA, mockScorer, PositionType.Upper,
            14, marketNumber
        ));
    }

    // --- Comprehensive Validation Tests ---
    function testValidateLeaderboardPosition_Success() public {
        _setupCompleteRules();

        // Move to leaderboard active period
        vm.warp(block.timestamp + 2 hours);

        // risk=100, profit=80 => effective 1.80 = market. Always valid.
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1,
            15, // exact market number (10x)
            PositionType.Upper,
            100, // riskAmount
            80   // profitAmount
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.Valid));
    }

    function testValidateLeaderboardPosition_FailsInvalidLeaderboard() public view {
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            999, // invalid leaderboard
            speculationId,
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.LeaderboardDoesNotExist));
    }

    function testValidateLeaderboardPosition_FailsOutsideTimeWindow() public {
        _setupCompleteRules();

        // Before leaderboard starts
        LeaderboardPositionValidationResult result1 = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result1), uint256(LeaderboardPositionValidationResult.LeaderboardHasNotStarted));

        // After leaderboard ends
        vm.warp(block.timestamp + 9 days);
        LeaderboardPositionValidationResult result2 = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result2), uint256(LeaderboardPositionValidationResult.LeaderboardHasEnded));
    }

    function testValidateLeaderboardPosition_FailsSpeculationNotRegistered() public {
        _setupCompleteRules();
        // Don't setup leaderboard speculation - use unregistered speculation ID
        vm.warp(block.timestamp + 2 hours);

        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId + 1, // Use speculation ID 2 which is not registered
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.SpeculationNotRegistered));
    }

    function testValidateLeaderboardPosition_FailsNumberDeviation() public {
        _setupCompleteRules();
        vm.warp(block.timestamp + 2 hours);

        // Number too far from market (market is 15, max deviation is 15)
        // User number 35: 35 - 15 = 20 > 15 max deviation
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1,
            35, // too far from market number 15 (10x format)
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.NumberDeviationTooLarge));
    }

    function testValidateLeaderboardPosition_FailsOddsEnforcement() public {
        _setupCompleteRules();
        vm.warp(block.timestamp + 2 hours);

        // Market odds for Upper = 180 (1.80). Max with 25% = 225 (2.25)
        // risk=100, profit=200 => effective 3.00 = 300 tick. Way over 225.
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            speculationId,
            user1,
            15, // exact market number
            PositionType.Upper,
            100,  // riskAmount
            200   // profitAmount => effective 3.00 (too good)
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
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.LiveBettingNotAllowed));
    }

    function testValidateLeaderboardPosition_SucceedsLiveBettingEnabled() public {
        _setupCompleteRules();

        // Enable live betting
        vm.prank(creator);
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
            user1,
            15,
            PositionType.Upper,
            100,
            80
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
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.Valid));
    }

    function testGetAllRules_WithLiveBettingEnabled() public {
        _setupCompleteRules();

        // Enable live betting
        vm.prank(creator);
        rulesModule.setAllowLiveBetting(leaderboardId, true);

        (
            uint256 minBankroll,
            uint256 maxBankroll,
            uint16 minBetPercentage,
            uint16 maxBetPercentage,
            uint16 minBets,
            uint16 oddsEnforcementBps,
            bool allowLiveBetting,
            bool allowMoneylineSpreadPairing
        ) = rulesModule.getAllRules(leaderboardId);

        assertEq(minBankroll, MIN_BANKROLL);
        assertEq(maxBankroll, MAX_BANKROLL);
        assertEq(minBetPercentage, MIN_BET_PERCENTAGE);
        assertEq(maxBetPercentage, MAX_BET_PERCENTAGE);
        assertEq(minBets, MIN_BETS);
        assertEq(oddsEnforcementBps, ODDS_ENFORCEMENT_BPS);
        assertTrue(allowLiveBetting); // Should be true after setting
        assertFalse(allowMoneylineSpreadPairing); // Default should be false
    }

    // --- Getter Function Tests ---
    function testGetDeviationRule_Set() public {
        vm.prank(creator);
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
            bool allowLiveBetting,
            bool allowMoneylineSpreadPairing
        ) = rulesModule.getAllRules(leaderboardId);

        assertEq(minBankroll, MIN_BANKROLL);
        assertEq(maxBankroll, MAX_BANKROLL);
        assertEq(minBetPercentage, MIN_BET_PERCENTAGE);
        assertEq(maxBetPercentage, MAX_BET_PERCENTAGE);
        assertEq(minBets, MIN_BETS);
        assertEq(oddsEnforcementBps, ODDS_ENFORCEMENT_BPS);
        assertFalse(allowLiveBetting); // Default should be false
        assertFalse(allowMoneylineSpreadPairing); // Default should be false
    }

    function testGetMaxBetAmount_WithLimit() public {
        vm.prank(creator);
        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);

        uint256 maxBet = rulesModule.getMaxBetAmount(leaderboardId, DECLARED_BANKROLL);
        // Independent calculation: 100_000_000 (100 USDC) * 1000 (10%) / 10000 = 10_000_000 (10 USDC)
        uint256 expected = 10_000_000;

        assertEq(maxBet, expected);
    }

    function testGetMaxBetAmount_NoLimit() public view {
        uint256 maxBet = rulesModule.getMaxBetAmount(leaderboardId, DECLARED_BANKROLL);
        assertEq(maxBet, type(uint256).max);
    }

    function testGetMinBetAmount_WithMinimum() public {
        vm.prank(creator);
        rulesModule.setMinBetPercentage(leaderboardId, MIN_BET_PERCENTAGE);

        uint256 minBet = rulesModule.getMinBetAmount(leaderboardId, DECLARED_BANKROLL);
        // Independent calculation: 100_000_000 (100 USDC) * 100 (1%) / 10000 = 1_000_000 (1 USDC)
        uint256 expected = 1_000_000;

        assertEq(minBet, expected);
    }

    function testGetMinBetAmount_NoMinimum() public view {
        uint256 minBet = rulesModule.getMinBetAmount(leaderboardId, DECLARED_BANKROLL);
        assertEq(minBet, 0);
    }

    // --- Edge Case Tests ---
    function testRuleChanges_OnlyBeforeLeaderboardStarts() public {
        // Should work before start
        vm.prank(creator);
        rulesModule.setMinBankroll(leaderboardId, MIN_BANKROLL);

        // Should fail after start
        vm.warp(block.timestamp + 2 hours);
        vm.prank(creator);
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
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );
    }

    // --- Helper Functions ---
    function _setupCompleteRules() internal {
        vm.startPrank(creator);
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

    function testValidateLeaderboardPosition_FailsMoneylineSpreadPairing_MoneylineToSpread() public {
        _setupCompleteRules();

        // Set up speculations in mock BEFORE adding to leaderboard (needed for contestId lookup)
        uint256 moneylineSpeculationId = 10;
        uint256 spreadSpeculationId = 11;
        mockSpeculationModule.setTestSpeculation(moneylineSpeculationId, Speculation({
            contestId: contestId,
            speculationScorer: mockMoneylineScorer,
            lineTicks: 15,
            speculationCreator: address(0),
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        }));
        mockSpeculationModule.setTestSpeculation(spreadSpeculationId, Speculation({
            contestId: contestId,
            speculationScorer: mockSpreadScorer,
            lineTicks: 15,
            speculationCreator: address(0),
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        }));

        // Set up contest markets for both scorer addresses (uint16 ticks, 10x lineTicks)
        mockContestModule.setContestMarket(contestId, mockMoneylineScorer, ContestMarket({
            lineTicks: 15,
            upperOdds: 180,
            lowerOdds: 120,
            lastUpdated: 1
        }));
        mockContestModule.setContestMarket(contestId, mockSpreadScorer, ContestMarket({
            lineTicks: 15,
            upperOdds: 180,
            lowerOdds: 120,
            lastUpdated: 1
        }));

        // Add the new speculations to the leaderboard
        vm.startPrank(creator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, moneylineSpeculationId);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, spreadSpeculationId);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

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

        // Try to register spread position - should fail with MoneylineSpreadPairingNotAllowed
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            spreadSpeculationId,
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );

        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.MoneylineSpreadPairingNotAllowed));
    }

    function testValidateLeaderboardPosition_FailsMoneylineSpreadPairing_SpreadToMoneyline() public {
        _setupCompleteRules();

        // Set up speculations in mock BEFORE adding to leaderboard (needed for contestId lookup)
        uint256 spreadSpeculationId = 12;
        uint256 moneylineSpeculationId = 13;
        mockSpeculationModule.setTestSpeculation(spreadSpeculationId, Speculation({
            contestId: contestId,
            speculationScorer: mockSpreadScorer,
            lineTicks: 15,
            speculationCreator: address(0),
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        }));
        mockSpeculationModule.setTestSpeculation(moneylineSpeculationId, Speculation({
            contestId: contestId,
            speculationScorer: mockMoneylineScorer,
            lineTicks: 15,
            speculationCreator: address(0),
            speculationStatus: SpeculationStatus.Open,
            winSide: WinSide.TBD
        }));

        // Set up contest markets for both scorer addresses (uint16 ticks, 10x lineTicks)
        mockContestModule.setContestMarket(contestId, mockMoneylineScorer, ContestMarket({
            lineTicks: 15,
            upperOdds: 180,
            lowerOdds: 120,
            lastUpdated: 1
        }));
        mockContestModule.setContestMarket(contestId, mockSpreadScorer, ContestMarket({
            lineTicks: 15,
            upperOdds: 180,
            lowerOdds: 120,
            lastUpdated: 1
        }));

        // Add the new speculations to the leaderboard
        vm.startPrank(creator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, spreadSpeculationId);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, moneylineSpeculationId);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

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

        // Try to register moneyline position - should fail with MoneylineSpreadPairingNotAllowed
        LeaderboardPositionValidationResult result = rulesModule.validateLeaderboardPosition(
            leaderboardId,
            moneylineSpeculationId,
            user1,
            15,
            PositionType.Upper,
            100,
            80
        );

        assertEq(uint256(result), uint256(LeaderboardPositionValidationResult.MoneylineSpreadPairingNotAllowed));
    }

    // --- Missing Negative Tests for Setters (#13) ---

    // setMaxBankroll
    function testSetMaxBankroll_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
    }

    function testSetMaxBankroll_RevertsIfLeaderboardStarted() public {
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setMaxBankroll(leaderboardId, MAX_BANKROLL);
    }

    // setMaxBetPercentage
    function testSetMaxBetPercentage_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);
    }

    function testSetMaxBetPercentage_RevertsIfLeaderboardStarted() public {
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setMaxBetPercentage(leaderboardId, MAX_BET_PERCENTAGE);
    }

    function testSetMaxBetPercentage_RevertsIfBpsTooHigh() public {
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidBps.selector);
        rulesModule.setMaxBetPercentage(leaderboardId, 10001); // > 100%
    }

    // setOddsEnforcementBps
    function testSetOddsEnforcementBps_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS);
    }

    function testSetOddsEnforcementBps_RevertsIfLeaderboardStarted() public {
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setOddsEnforcementBps(leaderboardId, ODDS_ENFORCEMENT_BPS);
    }

    function testSetOddsEnforcementBps_RevertsIfBpsTooHigh() public {
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidBps.selector);
        rulesModule.setOddsEnforcementBps(leaderboardId, 10001); // > 100%
    }

    // setDeviationRule
    function testSetDeviationRule_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION
        );
    }

    function testSetDeviationRule_RevertsIfLeaderboardStarted() public {
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setDeviationRule(
            leaderboardId,
            LeagueId.NBA,
            mockScorer,
            PositionType.Upper,
            MAX_DEVIATION
        );
    }

    // setMinBets
    function testSetMinBets_RevertsIfNotCreator() public {
        vm.prank(nonCreator);
        vm.expectRevert(abi.encodeWithSelector(RulesModule.RulesModule__NotCreator.selector, nonCreator));
        rulesModule.setMinBets(leaderboardId, MIN_BETS);
    }

    function testSetMinBets_RevertsIfLeaderboardStarted() public {
        vm.warp(block.timestamp + 2 hours);

        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__LeaderboardStarted.selector);
        rulesModule.setMinBets(leaderboardId, MIN_BETS);
    }

    // --- Cross-field Invariant Tests ---

    function testSetMinBankroll_RevertsIfExceedsMax() public {
        // Set max first
        vm.prank(creator);
        rulesModule.setMaxBankroll(leaderboardId, 100_000_000); // 100 USDC

        // Try to set min above max
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidValue.selector);
        rulesModule.setMinBankroll(leaderboardId, 200_000_000); // 200 USDC > max
    }

    function testSetMaxBankroll_RevertsIfBelowMin() public {
        // Set min first
        vm.prank(creator);
        rulesModule.setMinBankroll(leaderboardId, 100_000_000); // 100 USDC

        // Try to set max below min
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidValue.selector);
        rulesModule.setMaxBankroll(leaderboardId, 50_000_000); // 50 USDC < min
    }

    function testSetMinBetPercentage_RevertsIfExceedsMax() public {
        // Set max first
        vm.prank(creator);
        rulesModule.setMaxBetPercentage(leaderboardId, 500); // 5%

        // Try to set min above max
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidValue.selector);
        rulesModule.setMinBetPercentage(leaderboardId, 1000); // 10% > max
    }

    function testSetMaxBetPercentage_RevertsIfBelowMin() public {
        // Set min first
        vm.prank(creator);
        rulesModule.setMinBetPercentage(leaderboardId, 500); // 5%

        // Try to set max below min
        vm.prank(creator);
        vm.expectRevert(RulesModule.RulesModule__InvalidValue.selector);
        rulesModule.setMaxBetPercentage(leaderboardId, 100); // 1% < min
    }

    function testBankroll_EitherOrderWorks() public {
        // Set min first, then max — should work
        vm.prank(creator);
        rulesModule.setMinBankroll(leaderboardId, 50_000_000);
        vm.prank(creator);
        rulesModule.setMaxBankroll(leaderboardId, 200_000_000);

        assertEq(rulesModule.s_minBankroll(leaderboardId), 50_000_000);
        assertEq(rulesModule.s_maxBankroll(leaderboardId), 200_000_000);

        // Create a second leaderboard to test reverse order
        vm.prank(creator);
        uint256 lb2 = leaderboardModule.createLeaderboard(
            0,
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            SAFETY_PERIOD, ROI_WINDOW
        );

        // Set max first, then min — should also work
        vm.prank(creator);
        rulesModule.setMaxBankroll(lb2, 200_000_000);
        vm.prank(creator);
        rulesModule.setMinBankroll(lb2, 50_000_000);

        assertEq(rulesModule.s_minBankroll(lb2), 50_000_000);
        assertEq(rulesModule.s_maxBankroll(lb2), 200_000_000);
    }

    function testBetPercentage_EitherOrderWorks() public {
        // Set min first, then max
        vm.prank(creator);
        rulesModule.setMinBetPercentage(leaderboardId, 100); // 1%
        vm.prank(creator);
        rulesModule.setMaxBetPercentage(leaderboardId, 1000); // 10%

        assertEq(rulesModule.s_minBetPercentage(leaderboardId), 100);
        assertEq(rulesModule.s_maxBetPercentage(leaderboardId), 1000);

        // Create a second leaderboard to test reverse order
        vm.prank(creator);
        uint256 lb2 = leaderboardModule.createLeaderboard(
            0,
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            SAFETY_PERIOD, ROI_WINDOW
        );

        // Set max first, then min
        vm.prank(creator);
        rulesModule.setMaxBetPercentage(lb2, 1000);
        vm.prank(creator);
        rulesModule.setMinBetPercentage(lb2, 100);

        assertEq(rulesModule.s_minBetPercentage(lb2), 100);
        assertEq(rulesModule.s_maxBetPercentage(lb2), 1000);
    }

    function testBankroll_EqualMinMaxAllowed() public {
        // min == max is a valid config (fixed bankroll)
        vm.prank(creator);
        rulesModule.setMinBankroll(leaderboardId, 100_000_000);
        vm.prank(creator);
        rulesModule.setMaxBankroll(leaderboardId, 100_000_000);

        assertEq(rulesModule.s_minBankroll(leaderboardId), 100_000_000);
        assertEq(rulesModule.s_maxBankroll(leaderboardId), 100_000_000);
    }
}
