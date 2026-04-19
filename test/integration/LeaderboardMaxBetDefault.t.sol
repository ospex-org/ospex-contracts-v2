// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] maxBetPercentage is in BPS: 10000 = 100%, 5000 = 50%
// [NOTE] This test uses real LeaderboardModule, RulesModule, PositionModule, SpeculationModule.

import "forge-std/Test.sol";
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
    Position,
    PositionType,
    Leaderboard,
    LeaderboardPosition,
    Contest,
    ContestStatus,
    LeagueId,
    WinSide,
    FeeType
} from "../../src/core/OspexTypes.sol";

/**
 * @title LeaderboardMaxBetDefaultTest
 * @notice Integration tests verifying that the default maxBetPercentage caps
 *         leaderboard-registered bets at 100% of declared bankroll, preventing
 *         ROI denominator gaming attacks.
 */
contract LeaderboardMaxBetDefaultTest is Test {
    OspexCore core;
    PositionModule positionModule;
    SpeculationModule speculationModule;
    LeaderboardModule leaderboardModule;
    RulesModule rulesModule;
    TreasuryModule treasuryModule;
    MockERC20 token;
    MockContestModule mockContestModule;
    MockScorerModule mockScorerModule;

    address user1 = address(0xBEEF);
    address counterparty = address(0xCAFE);
    address lbCreator = address(0xC8EA);

    uint256 constant TOKEN_AMOUNT = 100_000_000_000; // 100,000 USDC
    uint256 constant ENTRY_FEE = 0; // Free leaderboard for simplicity

    uint256 leaderboardId;
    uint256 contestId = 1;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        positionModule = new PositionModule(address(core), address(token));
        speculationModule = new SpeculationModule(address(core), 3 days);
        leaderboardModule = new LeaderboardModule(address(core));
        rulesModule = new RulesModule(address(core));
        treasuryModule = new TreasuryModule(
            address(core), address(token), address(0xFEED),
            1_000_000, 500_000, 500_000
        );
        mockContestModule = new MockContestModule();
        mockScorerModule = new MockScorerModule();

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();         addrs[0]  = address(mockContestModule);
        types[1]  = core.SPECULATION_MODULE();      addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();         addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();         addrs[3]  = address(this);
        types[4]  = core.ORACLE_MODULE();           addrs[4]  = address(0xFEED);
        types[5]  = core.TREASURY_MODULE();         addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();      addrs[6]  = address(leaderboardModule);
        types[7]  = core.RULES_MODULE();            addrs[7]  = address(rulesModule);
        types[8]  = core.SECONDARY_MARKET_MODULE(); addrs[8]  = address(0x5EC0);
        types[9]  = core.MONEYLINE_SCORER_MODULE(); addrs[9]  = address(mockScorerModule);
        types[10] = core.SPREAD_SCORER_MODULE();    addrs[10] = address(0x5901);
        types[11] = core.TOTAL_SCORER_MODULE();     addrs[11] = address(0x7701);
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Fund accounts
        token.mint(user1, TOKEN_AMOUNT);
        token.mint(counterparty, TOKEN_AMOUNT);
        token.mint(lbCreator, TOKEN_AMOUNT);

        address[3] memory users = [user1, counterparty, lbCreator];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(positionModule), type(uint256).max);
            token.approve(address(treasuryModule), type(uint256).max);
            vm.stopPrank();
        }

        // Contest starts far in the future
        Contest memory contest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "test", sportspageId: "test", jsonoddsId: "test"
        });
        mockContestModule.setContest(contestId, contest);
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 24 hours));

        // Create leaderboard (no explicit maxBetPercentage — uses default)
        vm.prank(lbCreator);
        leaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            1 days,
            7 days
        );

        // Warp to after leaderboard start
        vm.warp(block.timestamp + 2 hours);
    }

    // =========================================================================
    // Test 1: Default caps bet at bankroll
    // =========================================================================

    /// @notice Position larger than bankroll gets capped to bankroll amount
    function test_DefaultCapsBetAtBankroll() public {
        uint256 bankroll = 100_000_000; // 100 USDC
        uint256 positionRisk = 500_000_000; // 500 USDC — 5x bankroll

        _registerUserForLeaderboard(user1, bankroll);

        uint256 specId = _createPositionAndRegisterSpeculation(
            user1, positionRisk, 400_000_000
        );

        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );

        // Position should be CAPPED to bankroll (100 USDC), not full 500 USDC
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, user1, specId
        );
        assertEq(lbPos.riskAmount, bankroll, "Risk should be capped to bankroll");
        // Profit scaled proportionally: 400M * 100M / 500M = 80M
        assertEq(lbPos.profitAmount, 80_000_000, "Profit should be scaled proportionally");
    }

    // =========================================================================
    // Test 2: Default allows bet within bankroll
    // =========================================================================

    /// @notice Position within bankroll registers at full amount
    function test_DefaultAllowsBetWithinBankroll() public {
        uint256 bankroll = 100_000_000; // 100 USDC
        uint256 positionRisk = 50_000_000; // 50 USDC — within bankroll

        _registerUserForLeaderboard(user1, bankroll);

        uint256 specId = _createPositionAndRegisterSpeculation(
            user1, positionRisk, 40_000_000
        );

        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );

        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, user1, specId
        );
        assertEq(lbPos.riskAmount, positionRisk, "Risk should be full amount (within cap)");
        assertEq(lbPos.profitAmount, 40_000_000, "Profit should be full amount");
    }

    // =========================================================================
    // Test 3: Explicit 100% matches default behavior
    // =========================================================================

    /// @notice Explicitly setting maxBetPercentage to 10000 (100%) produces same result as default
    function test_Explicit100PercentMatchesDefault() public {
        // Create a second leaderboard with explicit 100%
        vm.prank(lbCreator);
        uint256 lb2 = leaderboardModule.createLeaderboard(
            0,
            uint32(block.timestamp + 1),
            uint32(block.timestamp + 8 days),
            1 days,
            7 days
        );
        vm.prank(lbCreator);
        rulesModule.setMaxBetPercentage(lb2, 10000); // 100%

        uint256 bankroll = 100_000_000; // 100 USDC

        // Check both produce the same max bet amount
        uint256 defaultMax = rulesModule.getMaxBetAmount(leaderboardId, bankroll);
        uint256 explicitMax = rulesModule.getMaxBetAmount(lb2, bankroll);

        assertEq(defaultMax, bankroll, "Default should cap at bankroll");
        assertEq(explicitMax, bankroll, "Explicit 100% should cap at bankroll");
        assertEq(defaultMax, explicitMax, "Both should match");
    }

    // =========================================================================
    // Test 4: Explicit tighter cap enforced
    // =========================================================================

    /// @notice 50% cap limits bets to half of bankroll
    function test_ExplicitTighterCapEnforced() public {
        uint32 lb50Start = uint32(block.timestamp + 1);
        vm.prank(lbCreator);
        uint256 lb50 = leaderboardModule.createLeaderboard(
            0,
            lb50Start,
            uint32(block.timestamp + 8 days),
            1 days,
            7 days
        );
        vm.prank(lbCreator);
        rulesModule.setMaxBetPercentage(lb50, 5000); // 50%

        // Warp to after lb50 starts
        vm.warp(uint256(lb50Start) + 1);

        // Create position and add speculation to lb50
        uint256 specId = _createPositionAndRegisterSpeculation(
            user1, 60_000_000, 48_000_000 // 60 USDC position
        );
        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(lb50, specId);

        uint256 bankroll = 100_000_000; // 100 USDC
        _registerUserForLeaderboard2(user1, bankroll, lb50);

        vm.prank(user1);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, lb50
        );

        // 60 USDC position should be capped to 50 USDC (50% of 100)
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            lb50, user1, specId
        );
        assertEq(lbPos.riskAmount, 50_000_000, "Risk should be capped to 50% of bankroll");
        // Profit scaled: 48M * 50M / 60M = 40M
        assertEq(lbPos.profitAmount, 40_000_000, "Profit should be scaled proportionally");
    }

    // =========================================================================
    // Test 5: Explicit 0 also produces 100% cap (not unlimited)
    // =========================================================================

    /// @notice Setting maxBetPercentage to 0 has no special effect — same as default
    function test_ExplicitZeroProduces100PercentCap() public {
        vm.prank(lbCreator);
        uint256 lbZero = leaderboardModule.createLeaderboard(
            0,
            uint32(block.timestamp + 1),
            uint32(block.timestamp + 8 days),
            1 days,
            7 days
        );
        // Explicitly set to 0
        vm.prank(lbCreator);
        rulesModule.setMaxBetPercentage(lbZero, 0);

        uint256 bankroll = 100_000_000;
        uint256 maxBet = rulesModule.getMaxBetAmount(lbZero, bankroll);

        // 0 is treated the same as unset — default to 100% of bankroll
        assertEq(maxBet, bankroll, "Explicit 0 should produce 100% cap, not unlimited");
    }

    // =========================================================================
    // Test 6: Denominator inflation attack blocked (end-to-end)
    // =========================================================================

    /// @notice Reproduces OC's attack: 1 USDC bankroll + 10,000 USDC position.
    ///         The position gets capped to 1 USDC in the leaderboard snapshot.
    function test_DenominatorInflationAttackBlocked() public {
        address attacker = address(0xBAD);
        token.mint(attacker, TOKEN_AMOUNT);
        vm.prank(attacker);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(attacker);
        token.approve(address(treasuryModule), type(uint256).max);

        uint256 attackerBankroll = 1_000_000; // 1 USDC — tiny bankroll
        uint256 attackerPosition = 10_000_000_000; // 10,000 USDC — massive position

        // Attacker registers with 1 USDC bankroll
        _registerUserForLeaderboard(attacker, attackerBankroll);

        // Attacker takes a 10,000 USDC position
        uint256 specId = _createPositionAndRegisterSpeculation(
            attacker, attackerPosition, 8_000_000_000 // 8,000 USDC profit
        );

        vm.prank(attacker);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );

        // The leaderboard snapshot should cap at 1 USDC (attacker's bankroll), not 10,000 USDC
        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, attacker, specId
        );
        assertEq(lbPos.riskAmount, attackerBankroll, "Attack position should be capped to bankroll");
        // Profit scaled: 8B * 1M / 10B = 800_000 (0.80 USDC)
        assertEq(lbPos.profitAmount, 800_000, "Profit should be scaled to capped risk");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createPositionAndRegisterSpeculation(
        address maker,
        uint256 riskAmount,
        uint256 takerRisk
    ) internal returns (uint256 specId) {
        specId = positionModule.recordFill(
            contestId, address(mockScorerModule), 0, PositionType.Upper,
            maker, riskAmount, counterparty, takerRisk
        );

        // Add to default leaderboard if not already registered
        if (!leaderboardModule.s_leaderboardSpeculationRegistered(leaderboardId, specId)) {
            vm.prank(lbCreator);
            leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId);
        }
    }

    function _registerUserForLeaderboard(address user, uint256 bankroll) internal {
        vm.prank(user);
        leaderboardModule.registerUser(leaderboardId, bankroll);
    }

    function _registerUserForLeaderboard2(address user, uint256 bankroll, uint256 lbId) internal {
        vm.prank(user);
        leaderboardModule.registerUser(lbId, bankroll);
    }
}
