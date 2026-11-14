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
import {
    BettingBase,
    ObservingModule,
    SilentModule,
    StandInModule,
    TypeOnlyModule,
    WritingModule
} from "./BettingBase.sol";

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
        // Each of the three modules names the core. A market contract holds none.
        assertEq(address(markets.i_ospexCore()), address(core));
        assertEq(address(positions.i_ospexCore()), address(core));
        assertEq(address(matching.i_ospexCore()), address(core));
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

    // ──────────────────────────── The wiring reads ─────────────────────

    /// Each read, alone. A stand-in under each of the six types and under two types outside them, with every
    /// answer right, then with one answer wrong at a time: the games set, the coin, the core. Each wrong answer
    /// is tried five ways: an address that is nothing here, the zero address, and the three of the core's own
    /// values that are not the right one, out of the core's address, its games set, its coin and its deployer.
    /// One row a type, the six in the core's order and then the two outside them; one letter an answer, in
    /// that order: G, T or C where the core refuses with that read's name, "-" where it does not ask a module
    /// of that type for that value, and registers the stand-in.
    ///
    ///   markets            G - C        the moneyline      G - -
    ///   positions          - T C        the spread         G - -
    ///   matching           - - C        the total          G - -
    ///                                   a type outside     - - -
    ///
    /// With every answer right the stand-in registers under each of the eight. It is no module: that is the
    /// limit of a check that reads answers and not code.
    function test_bootstrap_asksEachTypeForItsOwnValues() public {
        string[8] memory told = ["G-C", "-TC", "--C", "G--", "G--", "G--", "---", "---"];
        bytes32[8] memory types = _eightTypes();
        uint256 refused;
        vm.startPrank(deployer, deployer);
        for (uint256 i; i < 8; ++i) {
            assertFalse(_aStandInIsRefused(types[i], 3, 0, "-"), "refused with every answer right");
            for (uint256 read; read < 3; ++read) {
                for (uint256 way; way < 5; ++way) {
                    if (_aStandInIsRefused(types[i], read, way, bytes(told[i])[read])) ++refused;
                }
            }
        }
        vm.stopPrank();
        // What was seen, against the table: its eight letters, each met five ways.
        assertEq(refused, 40, "the refusals seen");
    }

    /// The type is asked first and the core last. A stand-in wrong in several answers is told about the first
    /// its type is asked. Between the type and the core a module is asked the value its type holds, a games
    /// set or a coin; no type is asked both, so those two have no order to test. And a type that is taken is
    /// refused before anything is read.
    function test_bootstrap_asksTheTypeFirstAndTheCoreLast() public {
        bytes32[8] memory types = _eightTypes();
        address g = makeAddr("another games set");
        address t = makeAddr("another coin");
        address x = makeAddr("another core");
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));

        // Wrong in all four, the type included: the type's refusal.
        address s = address(new StandInModule(types[1], x, g, t));
        _assertRefused(
            c,
            types[0],
            s,
            abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleTypeMismatch.selector, s, types[0], types[1])
        );
        // The markets type: the games set's before the core's, and the core's once the games set is right.
        s = address(new StandInModule(types[0], x, g, t));
        _assertRefused(c, types[0], s, _wiringRefusal("G", s, g));
        s = address(new StandInModule(types[0], x, address(games), t));
        _assertRefused(c, types[0], s, _wiringRefusal("C", s, x));
        // The positions type: the coin's before the core's, and the core's once the coin is right.
        s = address(new StandInModule(types[1], x, g, t));
        _assertRefused(c, types[1], s, _wiringRefusal("T", s, t));
        s = address(new StandInModule(types[1], x, g, address(token)));
        _assertRefused(c, types[1], s, _wiringRefusal("C", s, x));
        // The matching type is asked for its core alone.
        s = address(new StandInModule(types[2], x, g, t));
        _assertRefused(c, types[2], s, _wiringRefusal("C", s, x));
        // A market contract's type is asked for its games set alone: with that right, another coin and
        // another core are not read, and it registers.
        for (uint256 i = 3; i < 6; ++i) {
            s = address(new StandInModule(types[i], x, g, t));
            _assertRefused(c, types[i], s, _wiringRefusal("G", s, g));
            s = address(new StandInModule(types[i], x, address(games), t));
            _assertRegisters(c, types[i], s);
        }
        // A type outside the six is asked its type and nothing else.
        s = address(new StandInModule(types[6], x, g, t));
        _assertRegisters(c, types[6], s);
        // A type that is taken: a stand-in wrong in every value is told the type is taken, not what is wrong.
        s = address(new StandInModule(types[3], x, g, t));
        _assertRefused(
            c, types[3], s, abi.encodeWithSelector(OspexBetting.OspexBetting__DuplicateModuleType.selector, types[3])
        );
        vm.stopPrank();
    }

    /// The type's check, between contracts that pass the same wiring reads. The six modules built from src/
    /// and deployed with one core, each offered under each of the other five types: thirty pairs, each
    /// refused with the module's own answer to its type. For some pairs nothing else would refuse: a market
    /// contract under another market contract's type names the right games set, and is asked nothing more.
    function test_bootstrap_refusesEveryModuleUnderEveryOtherType() public {
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        (bytes32[] memory types, address[] memory addrs) = _freshSet(c);
        uint256 pairs;
        for (uint256 i; i < 6; ++i) {
            for (uint256 j; j < 6; ++j) {
                if (i != j) {
                    bytes memory refusal = abi.encodeWithSelector(
                        OspexBetting.OspexBetting__ModuleTypeMismatch.selector, addrs[i], types[j], types[i]
                    );
                    _assertRefused(c, types[j], addrs[i], refusal);
                    ++pairs;
                }
            }
        }
        assertEq(pairs, 30, "the pairs");
        // Each under its own type, they register.
        c.bootstrapModules(types, addrs);
        assertEq(c.s_moduleCount(), 6, "the six under their own types");
        vm.stopPrank();
    }

    /// An address that answers its type and has none of the three reads. Under each of the six types the call
    /// fails with no data, since each of the six is asked a value; under a type outside the six nothing more
    /// is asked, and it registers.
    function test_bootstrap_refusesAModuleThatDoesNotAnswerARead() public {
        bytes32[8] memory types = _eightTypes();
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        for (uint256 i; i < 6; ++i) {
            _assertRefused(c, types[i], address(new TypeOnlyModule(types[i])), "");
        }
        _assertRegisters(c, types[6], address(new TypeOnlyModule(types[6])));
        _assertRegisters(c, types[7], address(new TypeOnlyModule(types[7])));
        vm.stopPrank();
    }

    /// One read at a time. A stand-in whose every answer is right but one, which reverts with no data. Where
    /// the core makes that read of that type the call fails, with no data; where it does not, the read is
    /// never made and the stand-in registers. One row a type, as above; one digit a read, the type's, the
    /// games set's, the coin's and the core's: 1 where the core makes it.
    ///
    ///   markets            1 1 0 1      the moneyline      1 1 0 0
    ///   positions          1 0 1 1      the spread         1 1 0 0
    ///   matching           1 0 0 1      the total          1 1 0 0
    ///                                   a type outside     1 0 0 0
    function test_bootstrap_refusesAModuleThatFailsOneRead() public {
        string[8] memory made = ["1101", "1011", "1001", "1100", "1100", "1100", "1000", "1000"];
        bytes32[8] memory types = _eightTypes();
        uint256 failed;
        vm.startPrank(deployer, deployer);
        for (uint256 i; i < 8; ++i) {
            for (uint256 read; read < 5; ++read) {
                OspexBetting c = new OspexBetting(address(games), address(token));
                address s = address(new SilentModule(types[i], address(c), address(games), address(token), read));
                // The fifth, read 4, is silent in none of its answers, and registers under every type.
                if (_aFaultInOneRead(c, types[i], s, read < 4 && bytes(made[i])[read] == "1")) ++failed;
            }
        }
        vm.stopPrank();
        assertEq(failed, 16, "the reads the core was seen to make");
    }

    /// The reads cannot write. A stand-in whose every answer is right and which writes to its own storage
    /// inside one of them. Where the core makes that read of that type the write fails the read, and with it
    /// the call; where it does not, the read is never made and the stand-in registers. The table is the one
    /// above. Either way the stand-in has written nothing.
    function test_bootstrap_theReadsCannotWrite() public {
        string[8] memory made = ["1101", "1011", "1001", "1100", "1100", "1100", "1000", "1000"];
        bytes32[8] memory types = _eightTypes();
        uint256 failed;
        vm.startPrank(deployer, deployer);
        for (uint256 i; i < 8; ++i) {
            for (uint256 read; read < 5; ++read) {
                OspexBetting c = new OspexBetting(address(games), address(token));
                WritingModule s = new WritingModule(types[i], address(c), address(games), address(token), read);
                // The fifth, read 4, writes in none of its answers, and registers under every type.
                if (_aFaultInOneRead(c, types[i], address(s), read < 4 && bytes(made[i])[read] == "1")) ++failed;
                assertEq(s.s_writes(), 0, "the stand-in wrote");
            }
        }
        vm.stopPrank();
        assertEq(failed, 16, "the reads the core was seen to make");
    }

    /// Every address is read before it is written. Six stand-ins that answer right only while the core holds
    /// nothing of them register, in one call: each was read while the registry held neither its type nor its
    /// address. Once registered each answers the zero address, so a core that wrote first would have refused it.
    function test_bootstrap_readsAModuleBeforeItWritesIt() public {
        bytes32[8] memory eight = _eightTypes();
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](6);
        address[] memory addrs = new address[](6);
        for (uint256 i; i < 6; ++i) {
            types[i] = eight[i];
            addrs[i] = address(new ObservingModule(eight[i], c, address(games), address(token)));
            assertTrue(ObservingModule(addrs[i]).unwritten(), "the core holds something of a stand-in not yet offered");
        }
        c.bootstrapModules(types, addrs);
        vm.stopPrank();
        for (uint256 i; i < 6; ++i) {
            assertEq(c.getModule(types[i]), addrs[i], "a stand-in that answered right was not registered");
            assertFalse(ObservingModule(addrs[i]).unwritten(), "the stand-in does not see its registration");
            assertEq(ObservingModule(addrs[i]).i_ospexCore(), address(0), "it still answers right");
            assertEq(ObservingModule(addrs[i]).i_games(), address(0), "it still answers right");
            assertEq(ObservingModule(addrs[i]).i_token(), address(0), "it still answers right");
        }
    }

    /// All or nothing, at every place. A call of n stand-ins under the first n of the six types, for n from
    /// one to six, with the one at place k wrong in the value its type is asked first: the games set for the
    /// markets type and for a market contract's, the coin for the positions type, the core for the matching
    /// type. For every k the call is refused with that stand-in's refusal and registers none of its n. Each
    /// call is made of a core that holds nothing and of a core that already holds a module, under a type
    /// outside the six. Then the n that answer right register in one call.
    function test_bootstrap_refusesAWrongModuleAtEveryPlaceOfACall() public {
        uint256 calls;
        vm.startPrank(deployer, deployer);
        for (uint256 n = 1; n <= 6; ++n) {
            for (uint256 k; k < n; ++k) {
                _aCallWithAWrongModuleAtPlace(n, k, false);
                _aCallWithAWrongModuleAtPlace(n, k, true);
                calls += 2;
            }
        }
        vm.stopPrank();
        assertEq(calls, 42, "the places");
    }

    /// Checked once. finalize reads no module: six stand-ins register with every answer right, each then
    /// changes its three answers, and the set finalizes. It is also a limit of the check: a contract whose
    /// answers are not fixed can change them once it is registered. The repository's modules hold theirs in
    /// immutables.
    function test_finalize_readsNoModule() public {
        bytes32[8] memory eight = _eightTypes();
        address g = makeAddr("another games set");
        address t = makeAddr("another coin");
        address x = makeAddr("another core");
        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        bytes32[] memory types = new bytes32[](6);
        address[] memory addrs = new address[](6);
        for (uint256 i; i < 6; ++i) {
            types[i] = eight[i];
            addrs[i] = address(new StandInModule(eight[i], address(c), address(games), address(token)));
        }
        c.bootstrapModules(types, addrs);
        for (uint256 i; i < 6; ++i) {
            StandInModule(addrs[i]).answer(x, g, t);
        }
        vm.expectEmit(true, true, true, true, address(c));
        emit OspexBetting.Finalized();
        c.finalize();
        assertTrue(c.s_finalized(), "the set did not finalize");

        // The same answers at a registration are refused: the stand-in of the markets type, offered to a
        // core that holds nothing.
        OspexBetting d = new OspexBetting(address(games), address(token));
        _assertRefused(d, types[0], addrs[0], _wiringRefusal("G", addrs[0], g));
        vm.stopPrank();
    }

    /// @dev The six types in the core's order, and two outside them: one that is the hash of a name, as the
    ///      six are, and the zero type.
    function _eightTypes() internal pure returns (bytes32[8] memory) {
        return [
            keccak256("MARKET_MODULE"),
            keccak256("POSITION_MODULE"),
            keccak256("MATCHING_MODULE"),
            keccak256("MONEYLINE_SCORER_MODULE"),
            keccak256("SPREAD_SCORER_MODULE"),
            keccak256("TOTAL_SCORER_MODULE"),
            keccak256("EXTRA_MODULE"),
            bytes32(0)
        ];
    }

    /// @dev The refusal a letter names for `module`, with `found` as what the module answered: G the games
    ///      set's, T the coin's, C the core's.
    function _wiringRefusal(bytes1 letter, address module, address found) internal pure returns (bytes memory) {
        bytes4 selector = OspexBetting.OspexBetting__ModuleCoreMismatch.selector;
        if (letter == "G") {
            selector = OspexBetting.OspexBetting__ModuleGamesMismatch.selector;
        } else if (letter == "T") {
            selector = OspexBetting.OspexBetting__ModuleTokenMismatch.selector;
        } else {
            require(letter == "C", "a letter the table does not have");
        }
        return abi.encodeWithSelector(selector, module, found);
    }

    /// @dev A wrong answer to the read numbered `read`, 0 the games set, 1 the coin and 2 the core, the `way`th
    ///      of five: an address that is nothing here; the zero address; and the three of `c`'s own values, its
    ///      address, its games set, its coin and its deployer, that are not the right answer to that read.
    function _wrongAnswer(OspexBetting c, uint256 read, uint256 way) internal view returns (address) {
        if (way == 0) return address(uint160(uint256(keccak256(abi.encode("an address that is nothing here", read)))));
        if (way == 1) return address(0);
        address[4] memory own = [address(c), address(games), address(token), deployer];
        uint256 right = read == 0 ? 1 : read == 1 ? 2 : 0;
        uint256 pick = way - 2;
        return own[pick < right ? pick : pick + 1];
    }

    /// @dev On a fresh core, a stand-in under `moduleType` whose answers are right but for the read numbered
    ///      `read`, which gives its `way`th wrong answer; with `read` 3 every answer is right. By `letter` it
    ///      must be refused with that read's name, nothing written, or, for "-", registered. Returns whether
    ///      the call was seen to fail.
    function _aStandInIsRefused(bytes32 moduleType, uint256 read, uint256 way, bytes1 letter)
        internal
        returns (bool refused)
    {
        OspexBetting c = new OspexBetting(address(games), address(token));
        address wrong = read < 3 ? _wrongAnswer(c, read, way) : address(0);
        address s = address(
            new StandInModule(
                moduleType,
                read == 2 ? wrong : address(c),
                read == 0 ? wrong : address(games),
                read == 1 ? wrong : address(token)
            )
        );
        (bool ok, bytes memory err) = _register(c, moduleType, s);
        refused = !ok;
        if (letter == "-") {
            assertTrue(ok, "refused for a value the core does not ask a module of this type");
            assertEq(c.getModule(moduleType), s, "the type holds another address");
            assertEq(c.s_moduleCount(), 1, "the count");
        } else {
            assertFalse(ok, "registered with a wrong value");
            assertEq(err, _wiringRefusal(letter, s, wrong), "the refusal");
            assertEq(c.getModule(moduleType), address(0), "the type was taken");
            assertFalse(c.isRegisteredModule(s), "the address was registered");
            assertEq(c.s_moduleCount(), 0, "the count moved");
        }
    }

    /// @dev `s`, a stand-in whose every answer is right and which fails inside at most one of its reads, is
    ///      offered alone under `moduleType` to `c`, which holds nothing. If the core makes that read of that
    ///      type the call must fail with no data and write nothing; if not, the stand-in must register. The
    ///      call is given 30,000,000 gas. A write inside a static read spends all the gas the read was given,
    ///      all but a 64th of what was left; a 64th of this amount still finishes a registration, so a core
    ///      that went on after a failed read would be seen to register. Returns whether the call was seen to
    ///      fail.
    function _aFaultInOneRead(OspexBetting c, bytes32 moduleType, address s, bool readIsMade)
        internal
        returns (bool failed)
    {
        bytes32[] memory types = new bytes32[](1);
        address[] memory addrs = new address[](1);
        types[0] = moduleType;
        addrs[0] = s;
        bytes memory call = abi.encodeCall(OspexBetting.bootstrapModules, (types, addrs));
        (bool ok, bytes memory err) = address(c).call{gas: 30_000_000}(call);
        failed = !ok;
        assertEq(failed, readIsMade, "a read that fails: made where it should not be, or not where it should");
        assertEq(err.length, 0, "revert data where the read gave none");
        assertEq(c.isRegisteredModule(s), ok, "the registration");
        assertEq(c.s_moduleCount(), ok ? 1 : 0, "the count");
    }

    /// @dev On a fresh core, which holds nothing or, with `held`, one module under a type outside the six: a
    ///      call of `n` stand-ins under the first `n` types, the one at place `k` wrong in the value its type is
    ///      asked first. The call must be refused with that stand-in's refusal and register none of the `n`;
    ///      then the `n` that answer right must register in one call.
    function _aCallWithAWrongModuleAtPlace(uint256 n, uint256 k, bool held) internal {
        bytes32[8] memory eight = _eightTypes();
        OspexBetting c = new OspexBetting(address(games), address(token));
        if (held) _assertRegisters(c, eight[6], address(new TypeOnlyModule(eight[6])));
        bytes32[] memory types = new bytes32[](n);
        address[] memory right = new address[](n);
        address[] memory addrs = new address[](n);
        for (uint256 i; i < n; ++i) {
            types[i] = eight[i];
            right[i] = address(new StandInModule(eight[i], address(c), address(games), address(token)));
            addrs[i] = right[i];
        }
        address other = makeAddr("another value");
        addrs[k] = address(
            new StandInModule(
                eight[k],
                k == 2 ? other : address(c),
                k == 1 || k == 2 ? address(games) : other,
                k == 1 ? other : address(token)
            )
        );
        (bool ok, bytes memory err) = address(c).call(abi.encodeCall(OspexBetting.bootstrapModules, (types, addrs)));
        assertFalse(ok, "a call with a wrong module was taken");
        bytes1 letter = "G";
        if (k == 1) letter = "T";
        if (k == 2) letter = "C";
        assertEq(err, _wiringRefusal(letter, addrs[k], other));
        assertEq(c.s_moduleCount(), held ? 1 : 0, "the count moved");
        for (uint256 i; i < n; ++i) {
            assertEq(c.getModule(types[i]), address(0), "a type of a refused call was taken");
            assertFalse(c.isRegisteredModule(addrs[i]), "an address of a refused call was registered");
        }
        vm.expectEmit(true, true, true, true, address(c));
        emit OspexBetting.ModulesBootstrapped(n);
        c.bootstrapModules(types, right);
        assertEq(c.s_moduleCount(), n + (held ? 1 : 0), "the stand-ins that answer right");
    }

    /// @dev Offers `module` alone under `moduleType` to `c`, and returns the call's result.
    function _register(OspexBetting c, bytes32 moduleType, address module)
        internal
        returns (bool ok, bytes memory err)
    {
        bytes32[] memory types = new bytes32[](1);
        address[] memory addrs = new address[](1);
        types[0] = moduleType;
        addrs[0] = module;
        (ok, err) = address(c).call(abi.encodeCall(OspexBetting.bootstrapModules, (types, addrs)));
    }

    /// @dev `module`, alone under `moduleType`, is refused by `c` with exactly `refusal`, and nothing is written.
    function _assertRefused(OspexBetting c, bytes32 moduleType, address module, bytes memory refusal) internal {
        uint256 count = c.s_moduleCount();
        address held = c.getModule(moduleType);
        (bool ok, bytes memory err) = _register(c, moduleType, module);
        assertFalse(ok, "the module was registered");
        assertEq(err, refusal, "the refusal");
        assertEq(c.getModule(moduleType), held, "the type's address changed");
        assertFalse(c.isRegisteredModule(module), "the address was registered");
        assertEq(c.s_moduleCount(), count, "the count moved");
    }

    /// @dev `module`, alone under `moduleType`, is registered by `c`.
    function _assertRegisters(OspexBetting c, bytes32 moduleType, address module) internal {
        uint256 count = c.s_moduleCount();
        (bool ok, bytes memory err) = _register(c, moduleType, module);
        assertTrue(ok, string.concat("the module was refused: ", vm.toString(err)));
        assertEq(c.getModule(moduleType), module, "the type holds another address");
        assertTrue(c.isRegisteredModule(module), "the address was not registered");
        assertEq(c.s_moduleCount(), count + 1, "the count");
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
        assertEq(matching.EVENT_ORDER_CANCELLED(), keccak256("ORDER_CANCELLED"));
        assertEq(matching.EVENT_FLOOR_RAISED(), keccak256("FLOOR_RAISED"));
        assertEq(matching.EVENT_VERSION_CHANGED(), keccak256("VERSION_CHANGED"));
        assertEq(matching.EVENT_AGENT_GRANTED(), keccak256("AGENT_GRANTED"));
        assertEq(matching.EVENT_AGENT_REVOKED(), keccak256("AGENT_REVOKED"));
    }
}
