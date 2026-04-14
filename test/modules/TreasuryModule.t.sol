// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeType, Leaderboard} from "../../src/core/OspexTypes.sol";

/// @dev Mock LeaderboardModule that returns configurable leaderboard data
contract MockLeaderboardModuleForTreasury {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

contract TreasuryModuleTest is Test {
    OspexCore core;
    MockERC20 token;
    TreasuryModule treasuryModule;
    MockLeaderboardModuleForTreasury mockLeaderboard;
    address protocolReceiver = address(0xBEEF);
    address user = address(0x1234);
    address notCore = address(0xDEAD);
    address leaderboardModule;

    // Fee rates for testing
    uint256 constant CONTEST_FEE = 1_000_000; // 1.00 USDC
    uint256 constant SPECULATION_FEE = 500_000;
    uint256 constant LEADERBOARD_FEE = 500_000;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();
        // Fund user
        token.transfer(user, 1_000_000_000);

        // Deploy TreasuryModule with fee rates set in constructor
        treasuryModule = new TreasuryModule(
            address(core),
            address(token),
            protocolReceiver,
            CONTEST_FEE,
            SPECULATION_FEE,
            LEADERBOARD_FEE
        );

        // Deploy mock leaderboard module
        mockLeaderboard = new MockLeaderboardModuleForTreasury();
        leaderboardModule = address(mockLeaderboard);

        // Set up a valid leaderboard for fundLeaderboard tests
        Leaderboard memory lb = Leaderboard({
            entryFee: 0,
            creator: address(this),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 7 days),
            safetyPeriodDuration: 1 days,
            roiSubmissionWindow: 3 days
        });
        mockLeaderboard.setLeaderboard(1, lb);

        // Bootstrap all modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = address(0xD001);
        types[1] = core.SPECULATION_MODULE();        addrs[1] = address(0xD002);
        types[2] = core.POSITION_MODULE();           addrs[2] = address(0xD003);
        types[3] = core.MATCHING_MODULE();           addrs[3] = address(0xD004);
        types[4] = core.ORACLE_MODULE();             addrs[4] = address(0xD005);
        types[5] = core.TREASURY_MODULE();           addrs[5] = address(treasuryModule);
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = leaderboardModule;
        types[7] = core.RULES_MODULE();              addrs[7] = address(0xD007);
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xD008);
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = address(0xD009);
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = address(0xD00A);
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = address(0xD00B);
        core.bootstrapModules(types, addrs);
        core.finalize();
    }

    // --- Constructor ---
    function testConstructor_RevertsOnZeroAddresses() public {
        vm.expectRevert();
        new TreasuryModule(address(0), address(token), protocolReceiver, CONTEST_FEE, SPECULATION_FEE, LEADERBOARD_FEE);
        vm.expectRevert();
        new TreasuryModule(address(core), address(0), protocolReceiver, CONTEST_FEE, SPECULATION_FEE, LEADERBOARD_FEE);
        vm.expectRevert();
        new TreasuryModule(address(core), address(token), address(0), CONTEST_FEE, SPECULATION_FEE, LEADERBOARD_FEE);
    }

    function testConstructor_SetsImmutables() public view {
        assertEq(address(treasuryModule.i_ospexCore()), address(core));
        assertEq(address(treasuryModule.i_token()), address(token));
        assertEq(treasuryModule.i_protocolReceiver(), protocolReceiver);
    }

    function testConstructor_SetsFeeRates() public view {
        assertEq(treasuryModule.getFeeRate(FeeType.ContestCreation), CONTEST_FEE);
        assertEq(treasuryModule.getFeeRate(FeeType.SpeculationCreation), SPECULATION_FEE);
        assertEq(treasuryModule.getFeeRate(FeeType.LeaderboardCreation), LEADERBOARD_FEE);
    }

    // --- processFee ---
    function testProcessFee_TransfersCorrectAmount() public {
        vm.prank(user);
        token.approve(address(treasuryModule), CONTEST_FEE);
        uint256 protocolBefore = token.balanceOf(protocolReceiver);
        uint256 userBefore = token.balanceOf(user);

        vm.prank(address(core));
        treasuryModule.processFee(user, FeeType.ContestCreation);

        assertEq(token.balanceOf(protocolReceiver), protocolBefore + CONTEST_FEE);
        assertEq(token.balanceOf(user), userBefore - CONTEST_FEE);
    }

    function testProcessFee_ZeroFeeRate_NoTransfer() public {
        // Deploy treasury with zero fee rate for contest creation
        TreasuryModule zeroFeeTreasury = new TreasuryModule(
            address(core), address(token), protocolReceiver, 0, SPECULATION_FEE, LEADERBOARD_FEE
        );

        uint256 userBefore = token.balanceOf(user);
        // Need to call from core — but zeroFeeTreasury is not registered in core.
        // For this test, deploy a fresh core with zeroFeeTreasury
        OspexCore freshCore = new OspexCore();
        zeroFeeTreasury = new TreasuryModule(
            address(freshCore), address(token), protocolReceiver, 0, 0, 0
        );
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = freshCore.CONTEST_MODULE();           addrs[0] = address(0xF001);
        types[1] = freshCore.SPECULATION_MODULE();        addrs[1] = address(0xF002);
        types[2] = freshCore.POSITION_MODULE();           addrs[2] = address(0xF003);
        types[3] = freshCore.MATCHING_MODULE();           addrs[3] = address(0xF004);
        types[4] = freshCore.ORACLE_MODULE();             addrs[4] = address(0xF005);
        types[5] = freshCore.TREASURY_MODULE();           addrs[5] = address(zeroFeeTreasury);
        types[6] = freshCore.LEADERBOARD_MODULE();        addrs[6] = address(0xF006);
        types[7] = freshCore.RULES_MODULE();              addrs[7] = address(0xF007);
        types[8] = freshCore.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xF008);
        types[9] = freshCore.MONEYLINE_SCORER_MODULE();   addrs[9] = address(0xF009);
        types[10] = freshCore.SPREAD_SCORER_MODULE();     addrs[10] = address(0xF00A);
        types[11] = freshCore.TOTAL_SCORER_MODULE();      addrs[11] = address(0xF00B);
        freshCore.bootstrapModules(types, addrs);
        freshCore.finalize();

        vm.prank(address(freshCore));
        zeroFeeTreasury.processFee(user, FeeType.ContestCreation);
        assertEq(token.balanceOf(user), userBefore); // No transfer
    }

    function testProcessFee_OnlyCore() public {
        vm.prank(user);
        token.approve(address(treasuryModule), CONTEST_FEE);
        vm.prank(notCore);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.processFee(user, FeeType.ContestCreation);
    }

    // --- processSplitFee ---
    function testProcessSplitFee_SplitsFee5050() public {
        address payer1 = address(0xAA01);
        address payer2 = address(0xAA02);
        token.transfer(payer1, 10_000_000);
        token.transfer(payer2, 10_000_000);

        uint256 halfFloor = SPECULATION_FEE / 2;
        uint256 halfCeil = SPECULATION_FEE - halfFloor;

        vm.prank(payer1);
        token.approve(address(treasuryModule), halfFloor);
        vm.prank(payer2);
        token.approve(address(treasuryModule), halfCeil);

        uint256 protocolBefore = token.balanceOf(protocolReceiver);
        uint256 p1Before = token.balanceOf(payer1);
        uint256 p2Before = token.balanceOf(payer2);

        vm.prank(address(core));
        treasuryModule.processSplitFee(payer1, payer2, FeeType.SpeculationCreation);

        assertEq(token.balanceOf(payer1), p1Before - halfFloor);
        assertEq(token.balanceOf(payer2), p2Before - halfCeil);
        assertEq(token.balanceOf(protocolReceiver), protocolBefore + SPECULATION_FEE);
    }

    function testProcessSplitFee_OnlyCore() public {
        vm.prank(notCore);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.processSplitFee(user, address(0xAA02), FeeType.SpeculationCreation);
    }

    // --- fundLeaderboard ---
    function testFundLeaderboard_Success() public {
        uint256 amount = 5_000_000; // 5 USDC
        vm.prank(user);
        token.approve(address(treasuryModule), amount);

        uint256 poolBefore = treasuryModule.getPrizePool(1);
        vm.prank(user);
        treasuryModule.fundLeaderboard(1, amount);

        assertEq(treasuryModule.getPrizePool(1), poolBefore + amount);
        assertEq(token.balanceOf(address(treasuryModule)), amount);
    }

    function testFundLeaderboard_MultipleFundings() public {
        uint256 amount1 = 5_000_000;
        uint256 amount2 = 3_000_000;
        vm.prank(user);
        token.approve(address(treasuryModule), amount1 + amount2);

        vm.prank(user);
        treasuryModule.fundLeaderboard(1, amount1);
        vm.prank(user);
        treasuryModule.fundLeaderboard(1, amount2);

        assertEq(treasuryModule.getPrizePool(1), amount1 + amount2);
    }

    function testFundLeaderboard_RevertsAfterEndTime() public {
        // Warp past the leaderboard endTime
        vm.warp(block.timestamp + 8 days);

        uint256 amount = 5_000_000;
        vm.prank(user);
        token.approve(address(treasuryModule), amount);

        vm.prank(user);
        vm.expectRevert(TreasuryModule.TreasuryModule__LeaderboardEnded.selector);
        treasuryModule.fundLeaderboard(1, amount);
    }

    function testFundLeaderboard_RevertsIfNoCreator() public {
        // Try to fund a leaderboard that doesn't exist (creator is address(0))
        uint256 amount = 5_000_000;
        vm.prank(user);
        token.approve(address(treasuryModule), amount);

        vm.prank(user);
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidLeaderboardCreator.selector);
        treasuryModule.fundLeaderboard(999, amount);
    }

    // --- processLeaderboardEntryFee ---
    function testProcessLeaderboardEntryFee_FullAmountToPrizePool() public {
        uint256 entryFee = 10_000_000; // 10 USDC

        vm.prank(user);
        token.approve(address(treasuryModule), entryFee);

        uint256 protocolBefore = token.balanceOf(protocolReceiver);

        vm.prank(address(core));
        treasuryModule.processLeaderboardEntryFee(user, entryFee, 1);

        // Full amount should go to prize pool (no protocol cut)
        assertEq(treasuryModule.getPrizePool(1), entryFee);
        // Protocol receiver should get nothing from entry fees
        assertEq(token.balanceOf(protocolReceiver), protocolBefore);
    }

    function testProcessLeaderboardEntryFee_OnlyCore() public {
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);
        vm.prank(user);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.processLeaderboardEntryFee(user, 1_000_000, 1);
    }

    function testProcessLeaderboardEntryFee_MultipleEntries() public {
        uint256 entryFee = 10_000_000;
        uint256 numEntries = 3;

        vm.prank(user);
        token.approve(address(treasuryModule), entryFee * numEntries);

        for (uint256 i = 0; i < numEntries; i++) {
            vm.prank(address(core));
            treasuryModule.processLeaderboardEntryFee(user, entryFee, 1);
        }

        assertEq(treasuryModule.getPrizePool(1), entryFee * numEntries);
    }

    // --- claimPrizePool ---
    function testClaimPrizePool_OnlyLeaderboardModule() public {
        // Fund prize pool first
        uint256 amount = 5_000_000;
        vm.prank(user);
        token.approve(address(treasuryModule), amount);
        vm.prank(address(core));
        treasuryModule.processLeaderboardEntryFee(user, amount, 1);

        address winner = address(0xB0B);

        // Non-leaderboard module fails
        vm.prank(notCore);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotLeaderboardModule.selector);
        treasuryModule.claimPrizePool(1, winner, amount);

        // Core fails
        vm.prank(address(core));
        vm.expectRevert(TreasuryModule.TreasuryModule__NotLeaderboardModule.selector);
        treasuryModule.claimPrizePool(1, winner, amount);

        // LeaderboardModule succeeds
        uint256 winnerBefore = token.balanceOf(winner);
        vm.prank(leaderboardModule);
        treasuryModule.claimPrizePool(1, winner, amount);
        assertEq(token.balanceOf(winner), winnerBefore + amount);
        assertEq(treasuryModule.getPrizePool(1), 0);
    }

    function testClaimPrizePool_RevertsIfEmpty() public {
        vm.prank(leaderboardModule);
        vm.expectRevert(TreasuryModule.TreasuryModule__InsufficientBalance.selector);
        treasuryModule.claimPrizePool(1, user, 0);
    }

    function testClaimPrizePool_RevertsIfZeroAddress() public {
        vm.prank(leaderboardModule);
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidReceiver.selector);
        treasuryModule.claimPrizePool(1, address(0), 100);
    }

    // --- Getters ---
    function testGetFeeRate_ReturnsCorrectValues() public view {
        assertEq(treasuryModule.getFeeRate(FeeType.ContestCreation), CONTEST_FEE);
        assertEq(treasuryModule.getFeeRate(FeeType.SpeculationCreation), SPECULATION_FEE);
        assertEq(treasuryModule.getFeeRate(FeeType.LeaderboardCreation), LEADERBOARD_FEE);
    }

    function testGetPrizePool_ReturnsCorrectValue() public {
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);
        vm.prank(address(core));
        treasuryModule.processLeaderboardEntryFee(user, 1_000_000, 1);
        assertEq(treasuryModule.getPrizePool(1), 1_000_000);
    }
}
