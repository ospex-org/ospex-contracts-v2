// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/core/OspexCore.sol";
import {FeeType} from "../../src/core/OspexTypes.sol";

contract OspexCoreTest is Test {
    OspexCore core;
    address deployer = address(0xA11CE);
    address dummyModule1 = address(0x1001);
    address dummyModule2 = address(0x1002);

    // All 12 module addresses for bootstrap
    address contestModule = address(0x2001);
    address speculationModule = address(0x2002);
    address positionModule = address(0x2003);
    address matchingModule = address(0x2004);
    address oracleModule = address(0x2005);
    address treasuryModule = address(0x2006);
    address leaderboardModule = address(0x2007);
    address rulesModule = address(0x2008);
    address secondaryMarketModule = address(0x2009);
    address moneylineScorerModule = address(0x200A);
    address spreadScorerModule = address(0x200B);
    address totalScorerModule = address(0x200C);

    function setUp() public {
        vm.prank(deployer);
        core = new OspexCore();
    }

    // --- Constructor ---

    function testConstructor_SetsDeployer() public view {
        assertEq(core.i_deployer(), deployer);
    }

    function testConstructor_NotFinalized() public view {
        assertFalse(core.s_finalized());
    }

    // --- Bootstrap ---

    function testBootstrapModules_RegistersAllModules() public {
        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.prank(deployer);
        core.bootstrapModules(types, addrs);

        assertEq(core.s_moduleRegistry(core.CONTEST_MODULE()), contestModule);
        assertEq(core.s_moduleRegistry(core.TREASURY_MODULE()), treasuryModule);
        assertTrue(core.s_isModuleRegistered(contestModule));
        assertTrue(core.s_isModuleRegistered(treasuryModule));
    }

    function testBootstrapModules_EmitsEvent() public {
        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.prank(deployer);
        vm.expectEmit(false, false, false, true);
        emit OspexCore.ModulesBootstrapped(12);
        core.bootstrapModules(types, addrs);
    }

    function testBootstrapModules_RevertsIfNotDeployer() public {
        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__NotDeployer.selector, address(0xBAD))
        );
        core.bootstrapModules(types, addrs);
    }

    function testBootstrapModules_RevertsIfArrayLengthMismatch() public {
        bytes32[] memory types = new bytes32[](2);
        address[] memory addrs = new address[](1);
        types[0] = core.CONTEST_MODULE();
        types[1] = core.SPECULATION_MODULE();
        addrs[0] = contestModule;

        vm.prank(deployer);
        vm.expectRevert(OspexCore.OspexCore__ArrayLengthMismatch.selector);
        core.bootstrapModules(types, addrs);
    }

    function testBootstrapModules_RevertsIfZeroAddress() public {
        bytes32[] memory types = new bytes32[](1);
        address[] memory addrs = new address[](1);
        types[0] = core.CONTEST_MODULE();
        addrs[0] = address(0);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__InvalidModuleAddress.selector, address(0))
        );
        core.bootstrapModules(types, addrs);
    }

    function testBootstrapModules_RevertsOnDuplicateModuleType() public {
        // First register one module
        bytes32 contestKey = core.CONTEST_MODULE();
        bytes32[] memory types1 = new bytes32[](1);
        address[] memory addrs1 = new address[](1);
        types1[0] = contestKey;
        addrs1[0] = contestModule;
        vm.prank(deployer);
        core.bootstrapModules(types1, addrs1);

        // Try to register same type again
        bytes32[] memory types2 = new bytes32[](1);
        address[] memory addrs2 = new address[](1);
        types2[0] = contestKey; // duplicate
        addrs2[0] = address(0x9999);

        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__DuplicateModuleType.selector, contestKey)
        );
        vm.prank(deployer);
        core.bootstrapModules(types2, addrs2);
    }

    function testBootstrapModules_RevertsIfAlreadyFinalized() public {
        _bootstrapAndFinalize();

        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.prank(deployer);
        vm.expectRevert(OspexCore.OspexCore__AlreadyFinalized.selector);
        core.bootstrapModules(types, addrs);
    }

    function testBootstrapModules_CanBeCalledIncrementally() public {
        // Register first 6 modules
        bytes32[] memory types1 = new bytes32[](6);
        address[] memory addrs1 = new address[](6);
        types1[0] = core.CONTEST_MODULE();       addrs1[0] = contestModule;
        types1[1] = core.SPECULATION_MODULE();    addrs1[1] = speculationModule;
        types1[2] = core.POSITION_MODULE();       addrs1[2] = positionModule;
        types1[3] = core.MATCHING_MODULE();       addrs1[3] = matchingModule;
        types1[4] = core.ORACLE_MODULE();         addrs1[4] = oracleModule;
        types1[5] = core.TREASURY_MODULE();       addrs1[5] = treasuryModule;

        vm.prank(deployer);
        core.bootstrapModules(types1, addrs1);

        // Register remaining 6 modules
        bytes32[] memory types2 = new bytes32[](6);
        address[] memory addrs2 = new address[](6);
        types2[0] = core.LEADERBOARD_MODULE();         addrs2[0] = leaderboardModule;
        types2[1] = core.RULES_MODULE();                addrs2[1] = rulesModule;
        types2[2] = core.SECONDARY_MARKET_MODULE();     addrs2[2] = secondaryMarketModule;
        types2[3] = core.MONEYLINE_SCORER_MODULE();     addrs2[3] = moneylineScorerModule;
        types2[4] = core.SPREAD_SCORER_MODULE();        addrs2[4] = spreadScorerModule;
        types2[5] = core.TOTAL_SCORER_MODULE();         addrs2[5] = totalScorerModule;

        vm.prank(deployer);
        core.bootstrapModules(types2, addrs2);

        // All modules registered
        assertTrue(core.s_isModuleRegistered(contestModule));
        assertTrue(core.s_isModuleRegistered(totalScorerModule));
    }

    // --- Finalize ---

    function testFinalize_SetsFinalized() public {
        _bootstrapAndFinalize();
        assertTrue(core.s_finalized());
    }

    function testFinalize_EmitsEvent() public {
        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.startPrank(deployer);
        core.bootstrapModules(types, addrs);
        vm.expectEmit(false, false, false, true);
        emit OspexCore.Finalized();
        core.finalize();
        vm.stopPrank();
    }

    function testFinalize_RevertsIfNotDeployer() public {
        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.prank(deployer);
        core.bootstrapModules(types, addrs);

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__NotDeployer.selector, address(0xBAD))
        );
        core.finalize();
    }

    function testFinalize_RevertsIfAlreadyFinalized() public {
        _bootstrapAndFinalize();

        vm.prank(deployer);
        vm.expectRevert(OspexCore.OspexCore__AlreadyFinalized.selector);
        core.finalize();
    }

    function testFinalize_RevertsIfModuleNotRegistered() public {
        // Register only 11 of 12 modules (skip TOTAL_SCORER_MODULE)
        bytes32[] memory types = new bytes32[](11);
        address[] memory addrs = new address[](11);
        types[0] = core.CONTEST_MODULE();              addrs[0] = contestModule;
        types[1] = core.SPECULATION_MODULE();           addrs[1] = speculationModule;
        types[2] = core.POSITION_MODULE();              addrs[2] = positionModule;
        types[3] = core.MATCHING_MODULE();              addrs[3] = matchingModule;
        types[4] = core.ORACLE_MODULE();                addrs[4] = oracleModule;
        types[5] = core.TREASURY_MODULE();              addrs[5] = treasuryModule;
        types[6] = core.LEADERBOARD_MODULE();           addrs[6] = leaderboardModule;
        types[7] = core.RULES_MODULE();                 addrs[7] = rulesModule;
        types[8] = core.SECONDARY_MARKET_MODULE();      addrs[8] = secondaryMarketModule;
        types[9] = core.MONEYLINE_SCORER_MODULE();      addrs[9] = moneylineScorerModule;
        types[10] = core.SPREAD_SCORER_MODULE();        addrs[10] = spreadScorerModule;

        vm.startPrank(deployer);
        core.bootstrapModules(types, addrs);
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__ModuleNotRegistered.selector, core.TOTAL_SCORER_MODULE())
        );
        core.finalize();
        vm.stopPrank();
    }

    // --- Module Queries ---

    function testGetModule_ReturnsCorrectAddress() public {
        _bootstrapAndFinalize();
        assertEq(core.getModule(core.CONTEST_MODULE()), contestModule);
        assertEq(core.getModule(core.TREASURY_MODULE()), treasuryModule);
    }

    function testIsRegisteredModule_ReturnsCorrectValue() public {
        _bootstrapAndFinalize();
        assertTrue(core.isRegisteredModule(contestModule));
        assertFalse(core.isRegisteredModule(address(0xDEAD)));
    }

    function testIsSecondaryMarket_ReturnsCorrectValue() public {
        _bootstrapAndFinalize();
        assertTrue(core.isSecondaryMarket(secondaryMarketModule));
        assertFalse(core.isSecondaryMarket(contestModule));
        assertFalse(core.isSecondaryMarket(address(0xDEAD)));
    }

    function testIsApprovedScorer_ReturnsCorrectValues() public {
        _bootstrapAndFinalize();
        assertTrue(core.isApprovedScorer(moneylineScorerModule));
        assertTrue(core.isApprovedScorer(spreadScorerModule));
        assertTrue(core.isApprovedScorer(totalScorerModule));
        assertFalse(core.isApprovedScorer(contestModule));
        assertFalse(core.isApprovedScorer(address(0xDEAD)));
    }

    // --- Event Emission ---

    function testEmitCoreEvent_RegisteredModule_Succeeds() public {
        _bootstrapAndFinalize();

        bytes32 eventType = keccak256("TEST_EVENT");
        bytes memory eventData = abi.encodePacked(uint256(123));
        vm.prank(contestModule);
        vm.expectEmit(true, true, false, true);
        emit OspexCore.CoreEventEmitted(eventType, contestModule, eventData);
        core.emitCoreEvent(eventType, eventData);
    }

    function testEmitCoreEvent_UnregisteredModule_Reverts() public {
        _bootstrapAndFinalize();

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__NotRegisteredModule.selector, address(0xDEAD))
        );
        core.emitCoreEvent(keccak256("TEST"), "");
    }

    // --- Fee Processing Access Control ---

    function testProcessFee_UnregisteredModule_Reverts() public {
        _bootstrapAndFinalize();

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__NotRegisteredModule.selector, address(0xDEAD))
        );
        core.processFee(address(0xBEEF), FeeType.ContestCreation);
    }

    function testProcessSplitFee_UnregisteredModule_Reverts() public {
        _bootstrapAndFinalize();

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__NotRegisteredModule.selector, address(0xDEAD))
        );
        core.processSplitFee(address(0xBEEF), address(0xCAFE), FeeType.SpeculationCreation);
    }

    function testProcessLeaderboardEntryFee_UnregisteredModule_Reverts() public {
        _bootstrapAndFinalize();

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(OspexCore.OspexCore__NotRegisteredModule.selector, address(0xDEAD))
        );
        core.processLeaderboardEntryFee(address(0xBEEF), 100, 1);
    }

    // --- Constants ---

    function testConstants_ModuleKeysAreCorrect() public view {
        assertEq(core.CONTEST_MODULE(), keccak256("CONTEST_MODULE"));
        assertEq(core.SPECULATION_MODULE(), keccak256("SPECULATION_MODULE"));
        assertEq(core.POSITION_MODULE(), keccak256("POSITION_MODULE"));
        assertEq(core.MATCHING_MODULE(), keccak256("MATCHING_MODULE"));
        assertEq(core.ORACLE_MODULE(), keccak256("ORACLE_MODULE"));
        assertEq(core.TREASURY_MODULE(), keccak256("TREASURY_MODULE"));
        assertEq(core.LEADERBOARD_MODULE(), keccak256("LEADERBOARD_MODULE"));
        assertEq(core.RULES_MODULE(), keccak256("RULES_MODULE"));
        assertEq(core.SECONDARY_MARKET_MODULE(), keccak256("SECONDARY_MARKET_MODULE"));
        assertEq(core.MONEYLINE_SCORER_MODULE(), keccak256("MONEYLINE_SCORER_MODULE"));
        assertEq(core.SPREAD_SCORER_MODULE(), keccak256("SPREAD_SCORER_MODULE"));
        assertEq(core.TOTAL_SCORER_MODULE(), keccak256("TOTAL_SCORER_MODULE"));
    }

    // --- Helpers ---

    function _fullModuleArrays() internal view returns (bytes32[] memory types, address[] memory addrs) {
        types = new bytes32[](12);
        addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();              addrs[0] = contestModule;
        types[1] = core.SPECULATION_MODULE();           addrs[1] = speculationModule;
        types[2] = core.POSITION_MODULE();              addrs[2] = positionModule;
        types[3] = core.MATCHING_MODULE();              addrs[3] = matchingModule;
        types[4] = core.ORACLE_MODULE();                addrs[4] = oracleModule;
        types[5] = core.TREASURY_MODULE();              addrs[5] = treasuryModule;
        types[6] = core.LEADERBOARD_MODULE();           addrs[6] = leaderboardModule;
        types[7] = core.RULES_MODULE();                 addrs[7] = rulesModule;
        types[8] = core.SECONDARY_MARKET_MODULE();      addrs[8] = secondaryMarketModule;
        types[9] = core.MONEYLINE_SCORER_MODULE();      addrs[9] = moneylineScorerModule;
        types[10] = core.SPREAD_SCORER_MODULE();        addrs[10] = spreadScorerModule;
        types[11] = core.TOTAL_SCORER_MODULE();         addrs[11] = totalScorerModule;
    }

    function _bootstrapAndFinalize() internal {
        (bytes32[] memory types, address[] memory addrs) = _fullModuleArrays();
        vm.startPrank(deployer);
        core.bootstrapModules(types, addrs);
        core.finalize();
        vm.stopPrank();
    }
}
