// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {OspexScorer} from "../../src/betting/OspexScorer.sol";
import {BettingBase} from "./BettingBase.sol";

/// @notice The core: its two deploy values, the bootstrap and its checks, the registry's reads and the hub.
contract OspexBettingTest is BettingBase {
    // ──────────────────────────── The deploy values ────────────────────

    function test_constructor_fixesTheGamesSetAndTheCoin() public {
        vm.expectEmit(true, true, true, true);
        emit OspexBetting.GamesSet(address(games));
        vm.expectEmit(true, true, true, true);
        emit OspexBetting.TokenSet(address(token));
        vm.prank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        assertEq(address(c.i_games()), address(games));
        assertEq(address(c.i_token()), address(token));
        assertEq(c.i_deployer(), deployer);
        assertFalse(c.s_finalized());
        assertEq(c.s_moduleCount(), 0);
        assertEq(c.MODULE_COUNT(), 6);
    }

    function test_constructor_refusesAnAddressWithNoCode() public {
        address[2] memory bare = [address(0), stranger];
        for (uint256 i; i < bare.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__GamesNotAContract.selector, bare[i]));
            new OspexBetting(bare[i], address(token));
            vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__TokenNotAContract.selector, bare[i]));
            new OspexBetting(address(games), bare[i]);
        }
    }

    function test_modules_readTheDeployValuesFromTheCore() public {
        // Each module copies what the core holds at its own deploy, so a set has one games set and one coin.
        assertEq(address(markets.i_games()), address(games));
        assertEq(address(positions.i_token()), address(token));
        assertEq(address(moneyline.i_games()), address(games));
        assertEq(address(spread.i_games()), address(games));
        assertEq(address(total.i_games()), address(games));
        // A zero core is refused by every module.
        vm.expectRevert(OspexMarkets.OspexMarkets__InvalidAddress.selector);
        new OspexMarkets(address(0));
        vm.expectRevert(OspexPositions.OspexPositions__InvalidAddress.selector);
        new OspexPositions(address(0));
        vm.expectRevert(OspexMatching.OspexMatching__InvalidAddress.selector);
        new OspexMatching(address(0));
        vm.expectRevert(OspexScorer.OspexScorer__InvalidCore.selector);
        new OspexMoneylineScorer(address(0));
        vm.expectRevert(OspexScorer.OspexScorer__InvalidCore.selector);
        new OspexSpreadScorer(address(0));
        vm.expectRevert(OspexScorer.OspexScorer__InvalidCore.selector);
        new OspexTotalScorer(address(0));
    }

    // ──────────────────────────── Bootstrap ────────────────────────────

    function test_bootstrap_registersEachModuleUnderItsType() public view {
        bytes32[] memory types = _types();
        address[] memory addrs = _modules();
        for (uint256 i; i < types.length; ++i) {
            assertEq(core.getModule(types[i]), addrs[i]);
            assertEq(core.s_moduleRegistry(types[i]), addrs[i]);
            assertTrue(core.isRegisteredModule(addrs[i]));
        }
        assertEq(core.s_moduleCount(), 6);
        assertTrue(core.s_finalized());
        assertEq(core.getModule(keccak256("EXTRA_MODULE")), address(0), "an unregistered type");
        assertFalse(core.isRegisteredModule(stranger));
        assertFalse(core.isRegisteredModule(address(core)));
    }

    function test_bootstrap_inTwoCallsCountsBoth() public {
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](6);
        address[] memory addrs = new address[](6);
        types[0] = c.MARKET_MODULE();
        addrs[0] = address(new OspexMarkets(address(c)));
        types[1] = c.POSITION_MODULE();
        addrs[1] = address(new OspexPositions(address(c)));
        types[2] = c.MATCHING_MODULE();
        addrs[2] = address(new OspexMatching(address(c)));
        types[3] = c.MONEYLINE_SCORER_MODULE();
        addrs[3] = address(new OspexMoneylineScorer(address(c)));
        types[4] = c.SPREAD_SCORER_MODULE();
        addrs[4] = address(new OspexSpreadScorer(address(c)));
        types[5] = c.TOTAL_SCORER_MODULE();
        addrs[5] = address(new OspexTotalScorer(address(c)));

        bytes32[] memory firstTypes = new bytes32[](2);
        address[] memory firstAddrs = new address[](2);
        bytes32[] memory restTypes = new bytes32[](4);
        address[] memory restAddrs = new address[](4);
        for (uint256 i; i < 6; ++i) {
            if (i < 2) {
                firstTypes[i] = types[i];
                firstAddrs[i] = addrs[i];
            } else {
                restTypes[i - 2] = types[i];
                restAddrs[i - 2] = addrs[i];
            }
        }
        vm.expectEmit(true, true, true, true, address(c));
        emit OspexBetting.ModulesBootstrapped(2);
        c.bootstrapModules(firstTypes, firstAddrs);
        assertEq(c.s_moduleCount(), 2);
        vm.expectEmit(true, true, true, true, address(c));
        emit OspexBetting.ModulesBootstrapped(4);
        c.bootstrapModules(restTypes, restAddrs);
        assertEq(c.s_moduleCount(), 6);
        vm.expectEmit(true, true, true, true, address(c));
        emit OspexBetting.Finalized();
        c.finalize();
        vm.stopPrank();
    }

    function test_bootstrap_refusesLengthsThatDiffer() public {
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](2);
        address[] memory addrs = new address[](1);
        vm.expectRevert(OspexBetting.OspexBetting__ArrayLengthMismatch.selector);
        c.bootstrapModules(types, addrs);
        vm.stopPrank();
    }

    function test_bootstrap_refusesTheZeroAddress() public {
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](1);
        address[] memory addrs = new address[](1);
        types[0] = c.MARKET_MODULE();
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__InvalidModuleAddress.selector, address(0)));
        c.bootstrapModules(types, addrs);
        vm.stopPrank();
    }

    function test_bootstrap_refusesATypeTwice() public {
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](2);
        address[] memory addrs = new address[](2);
        types[0] = c.MARKET_MODULE();
        types[1] = c.MARKET_MODULE();
        addrs[0] = address(new OspexMarkets(address(c)));
        addrs[1] = address(new OspexMarkets(address(c)));
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__DuplicateModuleType.selector, types[0]));
        c.bootstrapModules(types, addrs);
        vm.stopPrank();
    }

    function test_bootstrap_refusesAModuleOfAnotherType() public {
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](1);
        address[] memory addrs = new address[](1);
        // The positions module under the markets type: refused by the module's own answer.
        types[0] = c.MARKET_MODULE();
        addrs[0] = address(new OspexPositions(address(c)));
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexBetting.OspexBetting__ModuleTypeMismatch.selector, addrs[0], c.MARKET_MODULE(), c.POSITION_MODULE()
            )
        );
        c.bootstrapModules(types, addrs);
        // A wallet under any type: it answers nothing, so it is refused.
        addrs[0] = stranger;
        vm.expectRevert();
        c.bootstrapModules(types, addrs);
        // A contract that is not a module: the same.
        addrs[0] = address(token);
        vm.expectRevert();
        c.bootstrapModules(types, addrs);
        vm.stopPrank();
    }

    // ──────────────────────────── The hub ──────────────────────────────

    function test_hub_takesAnEventFromAModuleAlone() public {
        bytes memory payload = abi.encode(uint256(7), stranger);
        address[] memory outsiders = new address[](4);
        outsiders[0] = stranger;
        outsiders[1] = deployer;
        outsiders[2] = address(games);
        outsiders[3] = address(this);
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i], outsiders[i]);
            vm.expectRevert(
                abi.encodeWithSelector(OspexBetting.OspexBetting__NotRegisteredModule.selector, outsiders[i])
            );
            core.emitCoreEvent(keccak256("ANYTHING"), payload);
        }
        address[] memory modules = _modules();
        for (uint256 i; i < modules.length; ++i) {
            vm.prank(modules[i], modules[i]);
            vm.expectEmit(true, true, true, true, address(core));
            emit OspexBetting.CoreEventEmitted(keccak256("ANYTHING"), modules[i], payload);
            core.emitCoreEvent(keccak256("ANYTHING"), payload);
        }
    }

    function test_constants_areTheHashesOfTheirNames() public view {
        assertEq(core.MARKET_MODULE(), keccak256("MARKET_MODULE"));
        assertEq(core.POSITION_MODULE(), keccak256("POSITION_MODULE"));
        assertEq(core.MATCHING_MODULE(), keccak256("MATCHING_MODULE"));
        assertEq(core.MONEYLINE_SCORER_MODULE(), keccak256("MONEYLINE_SCORER_MODULE"));
        assertEq(core.SPREAD_SCORER_MODULE(), keccak256("SPREAD_SCORER_MODULE"));
        assertEq(core.TOTAL_SCORER_MODULE(), keccak256("TOTAL_SCORER_MODULE"));
        assertEq(markets.EVENT_MARKET_CREATED(), keccak256("MARKET_CREATED"));
        assertEq(markets.EVENT_MARKET_SETTLED(), keccak256("MARKET_SETTLED"));
        assertEq(positions.EVENT_POSITION_MATCHED_PAIR(), keccak256("POSITION_MATCHED_PAIR"));
        assertEq(positions.EVENT_POSITION_CLAIMED(), keccak256("POSITION_CLAIMED"));
        assertEq(matching.EVENT_COMMITMENT_CANCELLED(), keccak256("COMMITMENT_CANCELLED"));
        assertEq(matching.EVENT_MIN_NONCE_UPDATED(), keccak256("MIN_NONCE_UPDATED"));
    }
}
