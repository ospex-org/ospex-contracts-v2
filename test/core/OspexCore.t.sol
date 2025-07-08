// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/core/OspexCore.sol";

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
        vm.prank(address(0xBAD));
        vm.expectRevert();
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
        assertTrue(core.s_isModuleRegistered(dummyModule2));
        vm.stopPrank();
    }

    function testGetModule_ReturnsCorrectAddress() public {
        vm.prank(admin);
        core.registerModule(MODULE_TYPE, dummyModule1);
        assertEq(core.getModule(MODULE_TYPE), dummyModule1);
    }

    function testSetAdmin_Succeeds() public {
        address newAdmin = address(0xB0B);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.AdminChanged(admin, newAdmin);
        core.setAdmin(newAdmin);
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testSetAdmin_RevertsIfNotAdmin() public {
        address newAdmin = address(0xB0B);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        core.setAdmin(newAdmin);
    }

    function testSetAdmin_RevertsIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexCore.OspexCore__InvalidAdminAddress.selector,
                address(0)
            )
        );
        core.setAdmin(address(0));
    }

    function testEmitCoreEvent_EmitsEvent() public {
        // Register this contract as a module
        vm.prank(admin);
        core.registerModule(MODULE_TYPE, address(this));

        bytes32 eventType = keccak256("TEST_EVENT");
        bytes memory eventData = abi.encodePacked(uint256(123));
        vm.expectEmit(true, false, false, true);
        emit OspexCore.CoreEventEmitted(eventType, eventData);
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
        vm.expectEmit(true, false, false, true);
        emit OspexCore.CoreEventEmitted(eventType, eventData);
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
        vm.prank(address(0xBAD));
        vm.expectRevert();
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
}
