// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeType, Leaderboard} from "../../src/core/OspexTypes.sol";

// Simple mock for testing TreasuryModule leaderboard validation
contract MockLeaderboardModule {
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
    MockLeaderboardModule mockLeaderboardModule;
    address protocolReceiver = address(0xBEEF);
    address user = address(0x1234);
    address notCore = address(0xDEAD);
    address notAdmin = address(0xBAD);
    uint256 leaderboardId = 1;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();
        // Fund user
        token.transfer(user, 1_000_000_000);
        
        // Deploy and register MockLeaderboardModule
        mockLeaderboardModule = new MockLeaderboardModule();
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));
        
        // Deploy TreasuryModule with valid addresses
        treasuryModule = new TreasuryModule(
            address(core),
            address(token),
            protocolReceiver
        );
        // Register TreasuryModule in core
        core.registerModule(keccak256("FEE_MODULE"), address(treasuryModule));
        
        // Grant admin role to this test contract
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), address(this));
    }

    // --- Constructor ---
    function testConstructor_RevertsOnZeroAddresses() public {
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidReceiver.selector);
        new TreasuryModule(address(0), address(token), protocolReceiver);
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidReceiver.selector);
        new TreasuryModule(address(core), address(0), protocolReceiver);
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidReceiver.selector);
        new TreasuryModule(address(core), address(token), address(0));
    }

    function testConstructor_SetsImmutables() public view {
        assertEq(address(treasuryModule.i_ospexCore()), address(core));
        assertEq(address(treasuryModule.i_token()), address(token));
        assertEq(treasuryModule.s_protocolReceiver(), protocolReceiver);
    }

    // --- Access Control ---
    function testOnlyAdminCanSetFeeRates() public {
        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(TreasuryModule.TreasuryModule__NotAdmin.selector, notAdmin));
        treasuryModule.setFeeRates(FeeType.ContestCreation, 100);
        
        // Test contract has admin role
        treasuryModule.setFeeRates(FeeType.ContestCreation, 100);
        assertEq(treasuryModule.getFeeRate(FeeType.ContestCreation), 100);
    }

    function testOnlyAdminCanSetProtocolCut() public {
        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(TreasuryModule.TreasuryModule__NotAdmin.selector, notAdmin));
        treasuryModule.setProtocolCut(100);
        
        // Test contract has admin role
        treasuryModule.setProtocolCut(100);
        assertEq(treasuryModule.s_protocolCutBps(), 100);
    }

    function testSetProtocolCut_RevertsIfTooHigh() public {
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidAllocation.selector);
        treasuryModule.setProtocolCut(10_001);
    }

    function testOnlyAdminCanSetProtocolReceiver() public {
        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(TreasuryModule.TreasuryModule__NotAdmin.selector, notAdmin));
        treasuryModule.setProtocolReceiver(address(0x1));
        
        // Test contract has admin role
        treasuryModule.setProtocolReceiver(address(0x1));
        assertEq(treasuryModule.s_protocolReceiver(), address(0x1));
    }

    function testSetProtocolReceiver_RevertsIfZero() public {
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidReceiver.selector);
        treasuryModule.setProtocolReceiver(address(0));
    }

    // --- Fee Handling ---
    function testProcessFee_SplitsCorrectly() public {
        // Set fee rate and protocol cut
        treasuryModule.setFeeRates(FeeType.ContestCreation, 1_000_000); // 1 USDC
        treasuryModule.setProtocolCut(2_000); // 20%
        // Approve and fund user
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);
        uint256 protocolReceiverBefore = token.balanceOf(protocolReceiver);
        uint256 userBefore = token.balanceOf(user);
        uint256 feeAmount = 1_000_000;
        uint256 protocolCut = 200_000; // 20% of 1M
        uint256 remaining = 800_000; // 80% of 1M
        
        // Since no valid leaderboard is set up, all remaining funds go to protocol as fallback
        vm.prank(address(core));
        vm.expectEmit(true, true, true, true);
        emit TreasuryModule.FeeProcessed(
            user,
            FeeType.ContestCreation,
            feeAmount,
            protocolCut,
            leaderboardId,
            0, // leaderboardAllocation = 0 (invalid leaderboard)
            remaining, // protocolFallback = remaining amount goes to protocol
            false // leaderboardValid = false
        );
        treasuryModule.processFee(
            user,
            feeAmount,
            FeeType.ContestCreation,
            leaderboardId
        );
        // Check balances - all funds go to protocol (cut + fallback)
        assertEq(
            token.balanceOf(protocolReceiver),
            protocolReceiverBefore + feeAmount // All 1M goes to protocol
        );
        assertEq(token.balanceOf(user), userBefore - feeAmount);
        assertEq(treasuryModule.getPrizePool(leaderboardId), 0); // No valid leaderboard
    }
    
    function testProcessFee_WithValidLeaderboard_SplitsCorrectly() public {
        // Set fee rate and protocol cut
        treasuryModule.setFeeRates(FeeType.ContestCreation, 1_000_000); // 1 USDC
        treasuryModule.setProtocolCut(2_000); // 20%
        
        // Set up a valid leaderboard
        Leaderboard memory validLeaderboard = Leaderboard({
            prizePool: 0,
            entryFee: 0,
            yieldStrategy: address(0),
            startTime: uint32(block.timestamp + 1 hours),
            endTime: uint32(block.timestamp + 8 days),
            safetyPeriodDuration: 1 days,
            roiSubmissionWindow: 7 days,
            claimWindow: 30 days
        });
        mockLeaderboardModule.setLeaderboard(leaderboardId, validLeaderboard);
        
        // Approve and fund user
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);
        uint256 protocolReceiverBefore = token.balanceOf(protocolReceiver);
        uint256 userBefore = token.balanceOf(user);
        uint256 feeAmount = 1_000_000;
        uint256 protocolCut = 200_000; // 20% of 1M
        uint256 leaderboardAllocation = 800_000; // 80% of 1M
        
        // With valid leaderboard, remaining funds go to leaderboard prize pool
        vm.prank(address(core));
        vm.expectEmit(true, true, true, true);
        emit TreasuryModule.FeeProcessed(
            user,
            FeeType.ContestCreation,
            feeAmount,
            protocolCut,
            leaderboardId,
            leaderboardAllocation, // leaderboardAllocation = 800k (valid leaderboard)
            0, // protocolFallback = 0 (no fallback needed)
            true // leaderboardValid = true
        );
        treasuryModule.processFee(
            user,
            feeAmount,
            FeeType.ContestCreation,
            leaderboardId
        );
        // Check balances - only protocol cut goes to protocol, rest to leaderboard
        assertEq(
            token.balanceOf(protocolReceiver),
            protocolReceiverBefore + protocolCut // Only 200k to protocol
        );
        assertEq(token.balanceOf(user), userBefore - feeAmount);
        assertEq(treasuryModule.getPrizePool(leaderboardId), leaderboardAllocation); // 800k to leaderboard
    }

    function testProcessFee_FeeDisabled_NoTransfer() public {
        // Fee rate is 0 by default
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);
        uint256 userBefore = token.balanceOf(user);
        vm.prank(address(core));
        treasuryModule.processFee(
            user,
            1_000_000,
            FeeType.ContestCreation,
            leaderboardId
        );
        // No transfer should occur
        assertEq(token.balanceOf(user), userBefore);
        assertEq(treasuryModule.getPrizePool(leaderboardId), 0);
    }

    function testProcessFee_RevertsOnZeroAmount() public {
        treasuryModule.setFeeRates(FeeType.ContestCreation, 1_000_000);
        vm.prank(address(core));
        vm.expectRevert(TreasuryModule.TreasuryModule__InvalidAllocation.selector);
        treasuryModule.processFee(user, 0, FeeType.ContestCreation, leaderboardId);
    }

    function testProcessFee_OnlyCore() public {
        treasuryModule.setFeeRates(FeeType.ContestCreation, 1_000_000);
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);
        vm.prank(notCore);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.processFee(
            user,
            1_000_000,
            FeeType.ContestCreation,
            leaderboardId
        );
    }

    // --- Prize Pool Claim ---
    function testClaimPrizePool_OnlyCore() public {
        // Set up a valid leaderboard so funds go to prize pool
        Leaderboard memory validLeaderboard = Leaderboard({
            prizePool: 0,
            entryFee: 100_000,
            yieldStrategy: address(0),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 7 days),
            safetyPeriodDuration: uint32(1 days),
            roiSubmissionWindow: uint32(3 days),
            claimWindow: uint32(30 days)
        });
        mockLeaderboardModule.setLeaderboard(leaderboardId, validLeaderboard);
        
        // Fund prize pool
        treasuryModule.setFeeRates(FeeType.ContestCreation, 1_000_000);
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);

        vm.prank(address(core));
        treasuryModule.processFee(
            user,
            1_000_000,
            FeeType.ContestCreation,
            leaderboardId
        );
        address winner = address(0xB0B);
        uint256 winnerBefore = token.balanceOf(winner);
        vm.prank(notCore);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.claimPrizePool(leaderboardId, winner, 1_000_000);
        vm.prank(address(core));
        treasuryModule.claimPrizePool(leaderboardId, winner, 1_000_000);
        assertEq(token.balanceOf(winner), winnerBefore + 1_000_000);
        assertEq(treasuryModule.getPrizePool(leaderboardId), 0);
    }

    function testClaimPrizePool_RevertsIfEmpty() public {
        vm.prank(address(core));
        vm.expectRevert(TreasuryModule.TreasuryModule__InsufficientBalance.selector);
        treasuryModule.claimPrizePool(leaderboardId, user, 0);
    }

    // --- Getters ---
    function testGetFeeRateAndPrizePool() public {
        treasuryModule.setFeeRates(FeeType.LeaderboardEntry, 123);
        assertEq(treasuryModule.getFeeRate(FeeType.LeaderboardEntry), 123);
        
        // Set up a valid leaderboard so funds go to prize pool
        Leaderboard memory validLeaderboard = Leaderboard({
            prizePool: 0,
            entryFee: 100_000,
            yieldStrategy: address(0),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 7 days),
            safetyPeriodDuration: uint32(1 days),
            roiSubmissionWindow: uint32(3 days),
            claimWindow: uint32(30 days)
        });
        mockLeaderboardModule.setLeaderboard(leaderboardId, validLeaderboard);
        
        // Fund prize pool
        treasuryModule.setFeeRates(FeeType.ContestCreation, 1_000_000);
        vm.prank(user);
        token.approve(address(treasuryModule), 1_000_000);

        vm.prank(address(core));
        treasuryModule.processFee(
            user,
            1_000_000,
            FeeType.ContestCreation,
            leaderboardId
        );
        assertEq(treasuryModule.getPrizePool(leaderboardId), 1_000_000);
    }
}
