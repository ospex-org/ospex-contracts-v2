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
    
    // Events from TreasuryModule
    event LeaderboardEntryFeeProcessed(
        address indexed payer,
        uint256 totalAmount,
        uint256 protocolCut,
        uint256 indexed leaderboardId,
        uint256 leaderboardAllocation
    );
    address notAdmin = address(0xBAD);
    address admin = address(this); // This test contract has admin role
    uint256 leaderboardId = 1;
    uint256 protocolCutBps = 500; // 5% protocol cut for testing
    uint256 constant MAX_BPS = 10_000;

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
        
        // Set protocol cut for testing
        treasuryModule.setProtocolCut(protocolCutBps);
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
        
        // Calculate expected prize pool amount (total - protocol cut)
        uint256 totalFee = 1_000_000;
        uint256 expectedProtocolCut = (totalFee * protocolCutBps) / MAX_BPS;
        uint256 expectedPrizePool = totalFee - expectedProtocolCut; // 950,000 with 5% cut
        
        vm.prank(notCore);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.claimPrizePool(leaderboardId, winner, expectedPrizePool);
        
        vm.prank(address(core));
        treasuryModule.claimPrizePool(leaderboardId, winner, expectedPrizePool);
        assertEq(token.balanceOf(winner), winnerBefore + expectedPrizePool);
        assertEq(treasuryModule.getPrizePool(leaderboardId), 0);
    }

    function testClaimPrizePool_RevertsIfEmpty() public {
        vm.prank(address(core));
        vm.expectRevert(TreasuryModule.TreasuryModule__InsufficientBalance.selector);
        treasuryModule.claimPrizePool(leaderboardId, user, 0);
    }

    // --- Getters ---
    function testGetFeeRateAndPrizePool() public {
        treasuryModule.setFeeRates(FeeType.ContestCreation, 123);
        assertEq(treasuryModule.getFeeRate(FeeType.ContestCreation), 123);
        
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
        // After 5% protocol cut, prize pool should be 950,000
        uint256 expectedPrizePool = 1_000_000 - ((1_000_000 * protocolCutBps) / MAX_BPS);
        assertEq(treasuryModule.getPrizePool(leaderboardId), expectedPrizePool);
    }

    // --- Leaderboard Entry Fee Tests ---
    function testProcessLeaderboardEntryFee() public {
        uint256 entryFee = 10_000_000; // 10 USDC
        uint256 expectedProtocolCut = (entryFee * protocolCutBps) / MAX_BPS;
        uint256 expectedLeaderboardAmount = entryFee - expectedProtocolCut;

        // Fund user and approve
        vm.prank(user);
        token.approve(address(treasuryModule), entryFee);

        // Get initial balances
        uint256 initialProtocolBalance = token.balanceOf(protocolReceiver);
        uint256 initialPrizePool = treasuryModule.getPrizePool(leaderboardId);

        // Process leaderboard entry fee
        vm.prank(address(core));
        treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);

        // Verify protocol receiver got their cut
        assertEq(
            token.balanceOf(protocolReceiver),
            initialProtocolBalance + expectedProtocolCut,
            "Protocol receiver should receive protocol cut"
        );

        // Verify prize pool increased
        assertEq(
            treasuryModule.getPrizePool(leaderboardId),
            initialPrizePool + expectedLeaderboardAmount,
            "Prize pool should increase by remaining amount"
        );

        // Verify treasury holds the prize pool amount (not transferred out until claimed)
        assertEq(token.balanceOf(address(treasuryModule)), expectedLeaderboardAmount, "Treasury should hold prize pool funds");
    }

    function testProcessLeaderboardEntryFeeZeroProtocolCut() public {
        // Set protocol cut to 0
        vm.prank(admin);
        treasuryModule.setProtocolCut(0);

        uint256 entryFee = 5_000_000; // 5 USDC

        // Fund user and approve
        vm.prank(user);
        token.approve(address(treasuryModule), entryFee);

        // Get initial balances
        uint256 initialProtocolBalance = token.balanceOf(protocolReceiver);
        uint256 initialPrizePool = treasuryModule.getPrizePool(leaderboardId);

        // Process leaderboard entry fee
        vm.prank(address(core));
        treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);

        // Verify protocol receiver got nothing
        assertEq(
            token.balanceOf(protocolReceiver),
            initialProtocolBalance,
            "Protocol receiver should receive nothing when cut is 0"
        );

        // Verify all funds went to prize pool
        assertEq(
            treasuryModule.getPrizePool(leaderboardId),
            initialPrizePool + entryFee,
            "All funds should go to prize pool when protocol cut is 0"
        );
    }

    function testProcessLeaderboardEntryFeeMultipleEntries() public {
        uint256 entryFee = 10_000_000; // 10 USDC
        uint256 numEntries = 3;
        uint256 totalFees = entryFee * numEntries;
        uint256 expectedProtocolCut = (totalFees * protocolCutBps) / MAX_BPS;
        uint256 expectedLeaderboardAmount = totalFees - expectedProtocolCut;

        // Fund user and approve total
        vm.prank(user);
        token.approve(address(treasuryModule), totalFees);

        // Get initial prize pool
        uint256 initialPrizePool = treasuryModule.getPrizePool(leaderboardId);

        // Process multiple entries
        for (uint256 i = 0; i < numEntries; i++) {
            vm.prank(address(core));
            treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);
        }

        // Verify final prize pool
        assertEq(
            treasuryModule.getPrizePool(leaderboardId),
            initialPrizePool + expectedLeaderboardAmount,
            "Prize pool should accumulate from multiple entries"
        );
    }

    function testProcessLeaderboardEntryFeeOnlyCore() public {
        uint256 entryFee = 1_000_000; // 1 USDC

        // Fund user and approve
        vm.prank(user);
        token.approve(address(treasuryModule), entryFee);

        // Try to call from non-core address
        vm.prank(user);
        vm.expectRevert(TreasuryModule.TreasuryModule__NotCore.selector);
        treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);
    }

    function testProcessLeaderboardEntryFeeInsufficientBalance() public {
        uint256 entryFee = 1_000_000; // 1 USDC

        // Don't fund user - should fail on transfer
        vm.prank(address(core));
        vm.expectRevert(); // ERC20 transfer will revert
        treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);
    }

    function testProcessLeaderboardEntryFeeInsufficientApproval() public {
        uint256 entryFee = 1_000_000; // 1 USDC

        // Fund user but don't approve enough
        vm.prank(user);
        token.approve(address(treasuryModule), entryFee - 1);

        vm.prank(address(core));
        vm.expectRevert(); // ERC20 transfer will revert
        treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);
    }

    function testProcessLeaderboardEntryFeeEmitsEvent() public {
        uint256 entryFee = 2_000_000; // 2 USDC
        uint256 expectedProtocolCut = (entryFee * protocolCutBps) / MAX_BPS;
        uint256 expectedLeaderboardAmount = entryFee - expectedProtocolCut;

        // Fund user and approve
        vm.prank(user);
        token.approve(address(treasuryModule), entryFee);

        // Expect the event
        vm.expectEmit(true, true, true, true);
        emit LeaderboardEntryFeeProcessed(
            user,
            entryFee,
            expectedProtocolCut,
            leaderboardId,
            expectedLeaderboardAmount
        );

        // Process leaderboard entry fee
        vm.prank(address(core));
        treasuryModule.processLeaderboardEntryFee(user, entryFee, leaderboardId);
    }
}
