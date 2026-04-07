// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/core/OspexCore.sol";
import {FeeType} from "../../src/core/OspexTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract OspexCoreTest is Test {
    OspexCore core;
    address admin = address(0xA11CE);
    address moduleAdmin = address(0xBEEF);
    address dummyModule1 = address(0x1001);
    address dummyModule2 = address(0x1002);
    bytes32 constant MODULE_TYPE = keccak256("DUMMY_MODULE");
    bytes32 constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");

    function setUp() public {
        vm.prank(admin);
        core = new OspexCore();
    }

    function testInitialRoles() public view {
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(core.hasRole(core.MODULE_ADMIN_ROLE(), admin));
    }

    function testRegisterModule_AsModuleAdmin_Succeeds() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.ModuleRegistered(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule1);
        assertEq(core.s_moduleRegistry(MODULE_TYPE), dummyModule1);
        assertTrue(core.s_isModuleRegistered(dummyModule1));
    }

    function testRegisterModule_RevertsIfNotModuleAdmin() public {
        // Pre-compute role to avoid vm.prank being consumed by the view call
        bytes32 role = core.MODULE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(0xBAD),
            role
        ));
        vm.prank(address(0xBAD));
        core.registerModule(MODULE_TYPE, dummyModule1);
    }

    function testRegisterModule_RevertsIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__InvalidModuleAddress.selector,
                address(0)
            )
        );
        core.registerModule(MODULE_TYPE, address(0));
    }

    function testRegisterModule_UpdatesOldModule() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        assertTrue(core.s_isModuleRegistered(dummyModule1));
        core.registerModule(MODULE_TYPE, dummyModule2);
        assertFalse(core.s_isModuleRegistered(dummyModule1));
        assertTrue(core.s_isRetiredModule(dummyModule1));
        assertTrue(core.s_isModuleRegistered(dummyModule2));
        vm.stopPrank();
    }

    function testGetModule_ReturnsCorrectAddress() public {
        vm.prank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        assertEq(core.getModule(MODULE_TYPE), dummyModule1);
    }

    // --- TWO-STEP ADMIN TRANSFER TESTS (M-3 Fix) ---

    /**
     * @notice Test the full two-step admin transfer flow
     * @dev Verifies proposeAdmin + acceptAdmin works correctly
     */
    function testTwoStepAdminTransfer_HappyPath() public {
        address newAdmin = address(0xB0B);

        // Step 1: Current admin proposes new admin
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.AdminTransferProposed(admin, newAdmin);
        core.proposeAdmin(newAdmin);

        // Verify pending admin is set
        assertEq(core.s_pendingAdmin(), newAdmin);
        // Old admin still has role
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
        // New admin doesn't have role yet
        assertFalse(core.hasRole(core.DEFAULT_ADMIN_ROLE(), newAdmin));

        // Step 2: New admin accepts
        vm.prank(newAdmin);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.AdminChanged(admin, newAdmin);
        core.acceptAdmin();

        // Verify transfer completed
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(core.s_pendingAdmin(), address(0)); // Pending admin cleared
    }

    /**
     * @notice Test proposeAdmin reverts if caller is not admin
     */
    function testProposeAdmin_RevertsIfNotAdmin() public {
        address newAdmin = address(0xB0B);
        bytes32 role = core.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(0xBAD),
            role
        ));
        vm.prank(address(0xBAD));
        core.proposeAdmin(newAdmin);
    }

    /**
     * @notice Test proposeAdmin reverts if zero address
     */
    function testProposeAdmin_RevertsIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__InvalidAdminAddress.selector,
                address(0)
            )
        );
        core.proposeAdmin(address(0));
    }

    /**
     * @notice Test acceptAdmin reverts if caller is not the pending admin
     */
    function testAcceptAdmin_RevertsIfNotPendingAdmin() public {
        address newAdmin = address(0xB0B);
        address imposter = address(0xBAD);

        // Propose new admin
        vm.prank(admin);
        core.proposeAdmin(newAdmin);

        // Imposter tries to accept
        vm.prank(imposter);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotPendingAdmin.selector,
                imposter
            )
        );
        core.acceptAdmin();
    }

    /**
     * @notice Test acceptAdmin reverts if no pending admin is set
     */
    function testAcceptAdmin_RevertsIfNoPendingAdmin() public {
        // No proposeAdmin called, so s_pendingAdmin is address(0)
        vm.prank(address(0xB0B));
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotPendingAdmin.selector,
                address(0xB0B)
            )
        );
        core.acceptAdmin();
    }

    /**
     * @notice Test that pending admin can be changed before acceptance
     * @dev This is important - admin should be able to correct a mistake
     */
    function testProposeAdmin_CanChangePendingAdmin() public {
        address wrongAdmin = address(0xBAD);
        address correctAdmin = address(0xB0B);

        // First proposal (wrong address)
        vm.prank(admin);
        core.proposeAdmin(wrongAdmin);
        assertEq(core.s_pendingAdmin(), wrongAdmin);

        // Second proposal (correct address) - overwrites first
        vm.prank(admin);
        core.proposeAdmin(correctAdmin);
        assertEq(core.s_pendingAdmin(), correctAdmin);

        // Wrong admin cannot accept anymore
        vm.prank(wrongAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotPendingAdmin.selector,
                wrongAdmin
            )
        );
        core.acceptAdmin();

        // Correct admin can accept
        vm.prank(correctAdmin);
        core.acceptAdmin();
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), correctAdmin));
    }

    /**
     * @notice Test that s_admin storage variable is updated correctly
     */
    function testTwoStepAdminTransfer_UpdatesStorageVariable() public {
        address newAdmin = address(0xB0B);

        // Verify initial s_admin
        assertEq(core.s_admin(), admin);

        // Propose and accept
        vm.prank(admin);
        core.proposeAdmin(newAdmin);
        vm.prank(newAdmin);
        core.acceptAdmin();

        // Verify s_admin is updated (not just the role)
        assertEq(core.s_admin(), newAdmin);
    }

    /**
     * @notice Test that new admin can perform admin actions after transfer
     */
    function testTwoStepAdminTransfer_NewAdminCanActAsAdmin() public {
        address newAdmin = address(0xB0B);
        address anotherNewAdmin = address(0xC0C);

        // Complete transfer to newAdmin
        vm.prank(admin);
        core.proposeAdmin(newAdmin);
        vm.prank(newAdmin);
        core.acceptAdmin();

        // New admin can now propose another admin
        vm.prank(newAdmin);
        core.proposeAdmin(anotherNewAdmin);
        assertEq(core.s_pendingAdmin(), anotherNewAdmin);
    }

    /**
     * @notice Test that old admin cannot perform admin actions after transfer
     */
    function testTwoStepAdminTransfer_OldAdminCannotActAsAdmin() public {
        address newAdmin = address(0xB0B);

        // Complete transfer
        vm.prank(admin);
        core.proposeAdmin(newAdmin);
        vm.prank(newAdmin);
        core.acceptAdmin();

        // Old admin cannot propose anymore
        bytes32 role = core.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            admin,
            role
        ));
        vm.prank(admin);
        core.proposeAdmin(address(0xD0D));
    }

    function testEmitCoreEvent_EmitsEvent() public {
        // Register this contract as a module
        vm.prank(admin);
        core.registerModule(MODULE_TYPE, address(this));

        bytes32 eventType = keccak256("TEST_EVENT");
        bytes memory eventData = abi.encodePacked(uint256(123));
        vm.expectEmit(true, true, false, true);
        emit OspexCore.CoreEventEmitted(eventType, address(this), eventData);
        core.emitCoreEvent(eventType, eventData);
    }

    function testIsRegisteredModule_ReturnsCorrectValue() public {
        vm.prank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        assertTrue(core.isRegisteredModule(dummyModule1));
        assertFalse(core.isRegisteredModule(address(0xDEAD)));
    }

    function testEmitCoreEvent_RegisteredModule_Succeeds() public {
        // Register dummyModule1 as a module
        vm.prank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);

        // Prank as the registered module and emit event
        bytes32 eventType = keccak256("REGISTERED_EVENT");
        bytes memory eventData = abi.encodePacked(uint256(456));
        vm.prank(dummyModule1);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.CoreEventEmitted(eventType, dummyModule1, eventData);
        core.emitCoreEvent(eventType, eventData);
    }

    function testEmitCoreEvent_UnregisteredModule_Reverts() public {
        // Prank as an unregistered module address
        bytes32 eventType = keccak256("UNREGISTERED_EVENT");
        bytes memory eventData = abi.encodePacked(uint256(789));
        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotRegisteredModule.selector,
                address(0xDEAD)
            )
        );
        core.emitCoreEvent(eventType, eventData);
    }

    function testEmitCoreEvent_EOA_Reverts() public {
        // Prank as an EOA (not registered as a module)
        bytes32 eventType = keccak256("EOA_EVENT");
        bytes memory eventData = abi.encodePacked(uint256(101112));
        vm.prank(address(0xB0B0));
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotRegisteredModule.selector,
                address(0xB0B0)
            )
        );
        core.emitCoreEvent(eventType, eventData);
    }

    // Test onlyModule modifier (indirectly, since it's internal)
    // This would be tested in modules that use the modifier

    function testSetMarketRole_GrantsAndRevokes() public {
        address market = address(0xCAFE);
        // Only admin can call
        vm.prank(admin);
        core.setMarketRole(market, true);
        assertTrue(core.hasMarketRole(market));
        vm.prank(admin);
        core.setMarketRole(market, false);
        assertFalse(core.hasMarketRole(market));
    }

    function testSetMarketRole_RevertsIfNotAdmin() public {
        address market = address(0xCAFE);
        bytes32 role = core.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(0xBAD),
            role
        ));
        vm.prank(address(0xBAD));
        core.setMarketRole(market, true);
    }

    function testHasMarketRole_ReturnsCorrectValue() public {
        address market = address(0xCAFE);
        vm.prank(admin);
        core.setMarketRole(market, true);
        assertTrue(core.hasMarketRole(market));
        vm.prank(admin);
        core.setMarketRole(market, false);
        assertFalse(core.hasMarketRole(market));
    }

    // --- RETIRED MODULE TESTS ---

    /**
     * @notice Swapping a module retires the old one and emits ModuleRetired
     */
    function testRegisterModule_RetiresOldModule_EmitsEvent() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);

        vm.expectEmit(true, true, false, true);
        emit OspexCore.ModuleRetired(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule2);
        vm.stopPrank();

        // Old module is retired, not registered
        assertFalse(core.s_isModuleRegistered(dummyModule1));
        assertTrue(core.s_isRetiredModule(dummyModule1));
        // New module is registered, not retired
        assertTrue(core.s_isModuleRegistered(dummyModule2));
        assertFalse(core.s_isRetiredModule(dummyModule2));
    }

    /**
     * @notice Re-registering the same address for the same type does not retire it
     */
    function testRegisterModule_SameAddress_DoesNotRetire() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        // Register same address again — should be a no-op on retirement
        core.registerModule(MODULE_TYPE, dummyModule1);
        vm.stopPrank();

        assertTrue(core.s_isModuleRegistered(dummyModule1));
        assertFalse(core.s_isRetiredModule(dummyModule1));
    }

    /**
     * @notice A retired module can still call emitCoreEvent
     * @dev This is the core fix: claims from a replaced PositionModule must not revert
     */
    function testEmitCoreEvent_RetiredModule_Succeeds() public {
        // Register then replace dummyModule1
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule2);
        vm.stopPrank();

        // dummyModule1 is now retired — emitCoreEvent should still work
        bytes32 eventType = keccak256("POSITION_CLAIMED");
        bytes memory eventData = abi.encode(uint256(1), address(0xBEEF), uint256(100));
        vm.prank(dummyModule1);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.CoreEventEmitted(eventType, dummyModule1, eventData);
        core.emitCoreEvent(eventType, eventData);
    }

    /**
     * @notice The emitter field in CoreEventEmitted distinguishes retired vs active modules
     */
    function testEmitCoreEvent_EmitterField_DistinguishesModuleGenerations() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule2);
        vm.stopPrank();

        bytes32 eventType = keccak256("POSITION_CLAIMED");
        bytes memory eventData = abi.encode(uint256(42));

        // Retired module emits with its own address
        vm.prank(dummyModule1);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.CoreEventEmitted(eventType, dummyModule1, eventData);
        core.emitCoreEvent(eventType, eventData);

        // Active module emits with its own address
        vm.prank(dummyModule2);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.CoreEventEmitted(eventType, dummyModule2, eventData);
        core.emitCoreEvent(eventType, eventData);
    }

    /**
     * @notice A retired module cannot call processFee — retired permissions are narrow
     */
    function testProcessFee_RetiredModule_Reverts() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule2);
        vm.stopPrank();

        // dummyModule1 is retired — processFee should revert
        vm.prank(dummyModule1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotRegisteredModule.selector,
                dummyModule1
            )
        );
        core.processFee(address(0xBEEF), 100, FeeType.ContestCreation, 0);
    }

    /**
     * @notice A retired module cannot call processLeaderboardEntryFee
     */
    function testProcessLeaderboardEntryFee_RetiredModule_Reverts() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule2);
        vm.stopPrank();

        vm.prank(dummyModule1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotRegisteredModule.selector,
                dummyModule1
            )
        );
        core.processLeaderboardEntryFee(address(0xBEEF), 100, 0);
    }

    /**
     * @notice An address that was never registered or retired cannot call emitCoreEvent
     */
    function testEmitCoreEvent_NeverRegistered_Reverts() public {
        // dummyModule1 was never registered — should revert
        vm.prank(dummyModule1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__NotRegisteredModule.selector,
                dummyModule1
            )
        );
        core.emitCoreEvent(keccak256("TEST"), "");
    }

    /**
     * @notice isRegisteredModule returns false for retired modules
     * @dev Retired is a separate status — not "registered" in the active sense
     */
    function testIsRegisteredModule_RetiredModule_ReturnsFalse() public {
        vm.startPrank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        core.registerModule(MODULE_TYPE, dummyModule2);
        vm.stopPrank();

        assertFalse(core.isRegisteredModule(dummyModule1));
        assertTrue(core.s_isRetiredModule(dummyModule1));
    }
}
