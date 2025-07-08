// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/modules/ContributionModule.sol";
import "../../src/core/OspexCore.sol";
import "../../src/core/OspexTypes.sol";
import "../mocks/MockERC20.sol";

contract ContributionModuleTest is Test {
    // Contracts
    OspexCore core;
    ContributionModule contributionModule;
    MockERC20 token;

    // Test accounts
    address admin = address(0x1234);
    address user = address(0xBEEF);
    address contributor = address(0xCAFE);
    address receiver = address(0xDEAD);
    address authorizedModule = address(0xABCD);

    function setUp() public {
        // Deploy core contract
        core = new OspexCore();
        
        // Deploy contribution module with core address
        contributionModule = new ContributionModule(address(core));
        
        // Deploy mock token
        token = new MockERC20();
        
        // Register the module with the core
        core.registerModule(
            keccak256("CONTRIBUTION_MODULE"),
            address(contributionModule)
        );
        
        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);
        
        // Register an authorized module for testing handleContribution
        core.registerModule(keccak256("TEST_MODULE"), authorizedModule);
        
        // Fund accounts
        token.transfer(contributor, 1_000_000);
        
        // Give user some ETH
        vm.deal(user, 10 ether);
        vm.deal(contributor, 10 ether);
        vm.deal(admin, 10 ether);
    }

    // --- Constructor Tests ---
    function testConstructor_SetsCore() public view {
        assertEq(address(contributionModule.i_ospexCore()), address(core));
    }

    function testConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(ContributionModule.ContributionModule__InvalidAddress.selector);
        new ContributionModule(address(0));
    }

    // --- Module Type Tests ---
    function testGetModuleType() public view {
        assertEq(contributionModule.getModuleType(), keccak256("CONTRIBUTION_MODULE"));
    }

    // --- Set Contribution Token Tests ---
    function testSetContributionToken_AdminCanCall() public {
        // Admin can call
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));

        // Verify token was set
        assertEq(address(contributionModule.s_contributionToken()), address(token));
    }

    function testSetContributionToken_NonAdminCannotCall() public {
        // Try to call as a regular user
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ContributionModule.ContributionModule__NotAdmin.selector, user));
        contributionModule.setContributionToken(address(token));
    }
    
    function testSetContributionToken_ZeroAddressIsAllowed() public {
        // Admin should be able to set a zero address (to disable contributions)
        vm.prank(admin);
        contributionModule.setContributionToken(address(0));
        
        // Verify token was set to zero
        assertEq(address(contributionModule.s_contributionToken()), address(0));
    }

    // --- Set Contribution Receiver Tests ---
    function testSetContributionReceiver_AdminCanCall() public {
        // Admin can call
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);

        // Verify receiver was set
        assertEq(contributionModule.s_contributionReceiver(), receiver);
    }

    function testSetContributionReceiver_NonAdminCannotCall() public {
        // Try to call as a regular user
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ContributionModule.ContributionModule__NotAdmin.selector, user));
        contributionModule.setContributionReceiver(receiver);
    }
    
    function testSetContributionReceiver_ZeroAddressIsAllowed() public {
        // Admin should be able to set a zero address (to disable contributions)
        vm.prank(admin);
        contributionModule.setContributionReceiver(address(0));
        
        // Verify receiver was set to zero
        assertEq(contributionModule.s_contributionReceiver(), address(0));
    }

    // --- Handle Contribution Tests ---
    function testHandleContribution_Success() public {
        // Setup for a successful contribution
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);

        // Approve tokens to be spent by contribution module
        vm.prank(contributor);
        token.approve(address(contributionModule), 100_000);
        
        // Initial balances
        uint256 contributorBalanceBefore = token.balanceOf(contributor);
        uint256 receiverBalanceBefore = token.balanceOf(receiver);
        
        // Expected event emission
        vm.expectEmit(true, true, true, true);
        emit ContributionModule.ContributionMade(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
        
        // Make the contribution as an authorized module
        vm.prank(authorizedModule);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
        
        // Check balances changed correctly
        assertEq(token.balanceOf(contributor), contributorBalanceBefore - 50_000);
        assertEq(token.balanceOf(receiver), receiverBalanceBefore + 50_000);
    }

    function testHandleContribution_UnauthorizedCannotCall() public {
        // Setup contribution token and receiver
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);

        // Try to call as unauthorized user
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ContributionModule.ContributionModule__NotAuthorized.selector, user));
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
    }
    
    function testHandleContribution_RevertsIfTokenNotSet() public {
        // Setup: Set receiver but not token
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);
        
        // Try to make a contribution as authorized module
        vm.prank(authorizedModule);
        vm.expectRevert(ContributionModule.ContributionModule__InvalidAddress.selector);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
    }
    
    function testHandleContribution_RevertsIfReceiverNotSet() public {
        // Setup: Set token but not receiver
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        
        // Try to make a contribution as authorized module
        vm.prank(authorizedModule);
        vm.expectRevert(ContributionModule.ContributionModule__InvalidAddress.selector);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
    }
    
    function testHandleContribution_ZeroAmountNoop() public {
        // Even with token and receiver not set, zero amount should do nothing
        vm.prank(authorizedModule);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            0 // amount = 0
        );
        // No token transfers should happen
    }
    
    function testHandleContribution_EventEmissionAndCoreEvent() public {
        // Setup for a successful contribution
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);

        vm.prank(contributor);
        token.approve(address(contributionModule), 100_000);
        
        // Expect ContributionMade event
        vm.expectEmit(true, true, true, true);
        emit ContributionModule.ContributionMade(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
        
        // Also expect emitCoreEvent to be called
        vm.expectCall(
            address(core),
            abi.encodeWithSelector(
                OspexCore.emitCoreEvent.selector,
                keccak256("CONTRIBUTION_MADE"),
                abi.encode(
                    1, // speculationId
                    contributor,
                    123, // oddsPairId
                    PositionType.Upper,
                    50_000 // amount
                )
            )
        );
        
        // Make the contribution as authorized module
        vm.prank(authorizedModule);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount
        );
    }

    function testHandleContribution_InsufficientAllowance() public {
        // Setup for a contribution but with insufficient allowance
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);

        vm.prank(contributor);
        token.approve(address(contributionModule), 10_000); // Only approve 10k
        
        // Expect revert on insufficient allowance
        vm.expectRevert(); // SafeERC20 will revert but not with a custom error
        vm.prank(authorizedModule);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount > allowance
        );
    }
    
    function testHandleContribution_InsufficientBalance() public {
        // Setup with a contributor who has less balance than the contribution amount
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        
        vm.prank(admin);
        contributionModule.setContributionReceiver(receiver);

        // Directly manipulate the contributor's balance to be 10,000
        // First transfer all funds away from contributor to test contract
        vm.startPrank(contributor);
        token.transfer(address(this), token.balanceOf(contributor));
        vm.stopPrank();
        
        // Then transfer back exactly 10,000 tokens
        token.transfer(contributor, 10_000);
        
        // Verify the balance is correct
        assertEq(token.balanceOf(contributor), 10_000);
        
        vm.prank(contributor);
        token.approve(address(contributionModule), 50_000);
        
        // Expect revert on insufficient balance
        vm.expectRevert(); // SafeERC20 will revert but not with a custom error
        vm.prank(authorizedModule);
        contributionModule.handleContribution(
            1, // speculationId
            contributor,
            123, // oddsPairId
            PositionType.Upper,
            50_000 // amount > balance
        );
    }
}
