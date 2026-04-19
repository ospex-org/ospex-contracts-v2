// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] All amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] This test uses real modules for PositionModule, SecondaryMarketModule,
//        LeaderboardModule, RulesModule, SpeculationModule, and TreasuryModule.
//        The test contract acts as the MatchingModule so it can call recordFill directly.

import "forge-std/Test.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {RulesModule} from "../../src/modules/RulesModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {SecondaryMarketModule} from "../../src/modules/SecondaryMarketModule.sol";
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
 * @title LeaderboardSecondaryMarketIneligibilityTest
 * @notice Integration tests verifying that positions acquired via the secondary market
 *         are permanently ineligible for leaderboard registration.
 *
 * Timeline:
 *   T+0:   Deploy, create contest (starts T+24h), create leaderboard (starts T+1h, ends T+8d)
 *   T+2h:  Warp. Register users. Create positions via recordFill (firstFillTimestamp > lb.startTime).
 *           Add speculations to leaderboard. Register/test positions.
 */
contract LeaderboardSecondaryMarketIneligibilityTest is Test {
    OspexCore core;
    PositionModule positionModule;
    SpeculationModule speculationModule;
    SecondaryMarketModule market;
    LeaderboardModule leaderboardModule;
    RulesModule rulesModule;
    TreasuryModule treasuryModule;
    MockERC20 token;
    MockContestModule mockContestModule;
    MockScorerModule mockScorerModule;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);
    address honestUser = address(0x600D);
    address lbCreator = address(0xC8EA);

    uint256 constant TOKEN_AMOUNT = 10_000_000_000; // 10,000 USDC
    uint256 constant ENTRY_FEE = 10_000_000; // 10 USDC
    uint256 constant DECLARED_BANKROLL = 1_000_000_000; // 1000 USDC

    uint256 leaderboardId;
    uint256 contestId = 1;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        positionModule = new PositionModule(address(core), address(token));
        speculationModule = new SpeculationModule(address(core), 3 days);
        market = new SecondaryMarketModule(address(core), address(token));
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
        types[8]  = core.SECONDARY_MARKET_MODULE(); addrs[8]  = address(market);
        types[9]  = core.MONEYLINE_SCORER_MODULE(); addrs[9]  = address(mockScorerModule);
        types[10] = core.SPREAD_SCORER_MODULE();    addrs[10] = address(0x5901);
        types[11] = core.TOTAL_SCORER_MODULE();     addrs[11] = address(0x7701);
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Fund accounts
        token.mint(alice, TOKEN_AMOUNT);
        token.mint(bob, TOKEN_AMOUNT);
        token.mint(attacker, TOKEN_AMOUNT);
        token.mint(honestUser, TOKEN_AMOUNT);
        token.mint(lbCreator, TOKEN_AMOUNT);

        address[5] memory users = [alice, bob, attacker, honestUser, lbCreator];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(positionModule), type(uint256).max);
            token.approve(address(treasuryModule), type(uint256).max);
            token.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }

        // Contest starts far in the future (so positions can be added and speculation registered)
        Contest memory contest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "test", sportspageId: "test", jsonoddsId: "test"
        });
        mockContestModule.setContest(contestId, contest);
        mockContestModule.setContestStartTime(contestId, uint32(block.timestamp + 24 hours));

        // Create leaderboard (starts in 1 hour)
        vm.prank(lbCreator);
        leaderboardId = leaderboardModule.createLeaderboard(
            ENTRY_FEE,
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 8 days),
            1 days,
            7 days
        );

        // Warp to after leaderboard start but before contest start
        vm.warp(block.timestamp + 2 hours);
    }

    // =========================================================================
    // Test 1: Secondary-bought position cannot be registered
    // =========================================================================

    function test_SecondaryBoughtPositionCannotBeRegistered() public {
        // Create primary position (after lb.startTime)
        uint256 specId = _createPrimaryPosition(alice, bob, contestId);

        // Add speculation to leaderboard
        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId);

        // Alice sells to attacker for 1 USDC
        _sellPosition(specId, alice, attacker, 1_000_000, 100_000_000, 80_000_000);

        // Register attacker for leaderboard
        _registerUserForLeaderboard(attacker);

        // Attacker tries to register — should revert (secondary market position)
        vm.prank(attacker);
        vm.expectRevert(
            LeaderboardModule.LeaderboardModule__SecondaryMarketPositionIneligible.selector
        );
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );
    }

    // =========================================================================
    // Test 2: Position delisted without sale remains eligible
    // =========================================================================

    function test_PositionDelistedWithoutSaleRemainsEligible() public {
        uint256 specId = _createPrimaryPosition(alice, bob, contestId);

        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId);

        // Alice lists her position on secondary market
        vm.prank(alice);
        market.listPositionForSale(specId, PositionType.Upper, 50_000_000, 100_000_000, 80_000_000);

        // Alice cancels the listing (no sale occurred)
        vm.prank(alice);
        market.cancelListing(specId, PositionType.Upper);

        // Alice registers for leaderboard and registers position — should succeed
        _registerUserForLeaderboard(alice);

        vm.prank(alice);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );

        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, alice, specId
        );
        assertEq(lbPos.riskAmount, 100_000_000, "Risk should be full primary amount");
        assertEq(lbPos.user, alice, "Position should belong to alice");
    }

    // =========================================================================
    // Test 3: Primary-only positions are fully eligible
    // =========================================================================

    function test_PrimaryOnlyPositionsFullyEligible() public {
        uint256 specId = _createPrimaryPosition(alice, bob, contestId);

        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId);

        _registerUserForLeaderboard(alice);

        vm.prank(alice);
        leaderboardModule.registerPositionForLeaderboard(
            specId, PositionType.Upper, leaderboardId
        );

        LeaderboardPosition memory lbPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, alice, specId
        );
        assertEq(lbPos.riskAmount, 100_000_000, "Risk should match primary position");
        assertEq(lbPos.profitAmount, 80_000_000, "Profit should match primary position");
        assertEq(lbPos.user, alice);
    }

    // =========================================================================
    // Test 4: Honest primary user outranks secondary attacker (end-to-end)
    // =========================================================================

    function test_HonestPrimaryUserBeatsSecondaryAttacker() public {
        // Position 1: alice vs bob on contest 1
        uint256 specId1 = _createPrimaryPosition(alice, bob, contestId);

        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId1);

        // Position 2: honestUser vs bob on contest 2
        uint256 contestId2 = 2;
        Contest memory contest2 = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "test2", sportspageId: "test2", jsonoddsId: "test2"
        });
        mockContestModule.setContest(contestId2, contest2);
        mockContestModule.setContestStartTime(contestId2, uint32(block.timestamp + 22 hours));

        uint256 specId2 = _createPrimaryPosition(honestUser, bob, contestId2);

        vm.prank(lbCreator);
        leaderboardModule.addLeaderboardSpeculation(leaderboardId, specId2);

        // Attacker buys alice's position for 1 USDC
        _sellPosition(specId1, alice, attacker, 1_000_000, 100_000_000, 80_000_000);

        // Register both for leaderboard
        _registerUserForLeaderboard(honestUser);
        _registerUserForLeaderboard(attacker);

        // honestUser registers primary position — succeeds
        vm.prank(honestUser);
        leaderboardModule.registerPositionForLeaderboard(
            specId2, PositionType.Upper, leaderboardId
        );

        // Attacker tries to register secondary position — blocked
        vm.prank(attacker);
        vm.expectRevert(
            LeaderboardModule.LeaderboardModule__SecondaryMarketPositionIneligible.selector
        );
        leaderboardModule.registerPositionForLeaderboard(
            specId1, PositionType.Upper, leaderboardId
        );

        // Verify
        LeaderboardPosition memory honestPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, honestUser, specId2
        );
        assertEq(honestPos.riskAmount, 100_000_000, "Honest user's position should be registered");

        LeaderboardPosition memory attackerPos = leaderboardModule.getLeaderboardPosition(
            leaderboardId, attacker, specId1
        );
        assertEq(attackerPos.riskAmount, 0, "Attacker's position should NOT be registered");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createPrimaryPosition(
        address maker,
        address taker,
        uint256 cId
    ) internal returns (uint256 specId) {
        specId = positionModule.recordFill(
            cId, address(mockScorerModule), 0, PositionType.Upper,
            maker, 100_000_000, taker, 80_000_000
        );
    }

    function _sellPosition(
        uint256 specId,
        address seller,
        address buyer,
        uint256 price,
        uint256 riskAmt,
        uint256 profitAmt
    ) internal {
        vm.prank(seller);
        market.listPositionForSale(specId, PositionType.Upper, price, riskAmt, profitAmt);

        vm.startPrank(buyer);
        bytes32 hash = market.getListingHash(specId, seller, PositionType.Upper);
        market.buyPosition(specId, seller, PositionType.Upper, riskAmt, hash);
        vm.stopPrank();
    }

    function _registerUserForLeaderboard(address user) internal {
        vm.prank(user);
        leaderboardModule.registerUser(leaderboardId, DECLARED_BANKROLL);
    }
}
