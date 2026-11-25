// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BettingEventsSchema} from "../../script/BettingEventsSchema.s.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {IOspexMarkets} from "../../src/betting/IOspexMarkets.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";

/// docs/betting-events.json is the build's own: the file is what the generator writes from the artifacts now, its
/// hub table is the modules' own `EVENT_` constants, every one of them and nothing else, and each topic 0 it gives is
/// the compiler's selector for that event, named through the contract or interface that declares it.
contract BettingEventsSchemaTest is Test {
    BettingEventsSchema internal schema;
    string internal file;

    OspexMarkets internal markets;
    OspexPositions internal positions;
    OspexMatching internal matching;

    function setUp() public {
        schema = new BettingEventsSchema();
        file = vm.readFile(string.concat(vm.projectRoot(), "/", schema.PATH()));
        // Each module's compiled runtime code at an address of its own, to read its constants: a constant is
        // reachable only through an instance, and these getters read no immutable.
        markets = OspexMarkets(makeAddr("markets"));
        positions = OspexPositions(makeAddr("positions"));
        matching = OspexMatching(makeAddr("matching"));
        vm.etch(address(markets), vm.getDeployedCode("OspexMarkets.sol:OspexMarkets"));
        vm.etch(address(positions), vm.getDeployedCode("OspexPositions.sol:OspexPositions"));
        vm.etch(address(matching), vm.getDeployedCode("OspexMatching.sol:OspexMatching"));
    }

    /// The file is the generator's output from this build's artifacts, byte for byte.
    /// Break: in OspexMatching.sol, rename `FloorRaised`'s `floor` to `newFloor`: the file no longer matches.
    function test_theFileIsWhatTheArtifactsGive() public view {
        assertEq(file, schema.schema(), "docs/betting-events.json is not the artifacts': run the generator");
    }

    /// The table holds seventeen types, each named by its module's own constant, with that module as its emitter.
    /// Break: in the generator, give `HELD_CHANGED` the matching module as its emitter.
    function test_theTypesAreTheModulesOwnConstants() public view {
        bytes32[17] memory constants = [
            markets.EVENT_MARKET_CREATED(),
            markets.EVENT_MARKET_SETTLED(),
            positions.EVENT_POSITION_MATCHED_PAIR(),
            positions.EVENT_POSITION_CLAIMED(),
            positions.EVENT_HELD_CHANGED(),
            positions.EVENT_PAY_BACK_REFUSED(),
            matching.EVENT_ORDER_CANCELLED(),
            matching.EVENT_FLOOR_RAISED(),
            matching.EVENT_VERSION_CHANGED(),
            matching.EVENT_AGENT_GRANTED(),
            matching.EVENT_AGENT_REVOKED(),
            matching.EVENT_COURIER_REGISTERED(),
            matching.EVENT_COURIER_UNREGISTERED(),
            matching.EVENT_ORDER_MATCHED(),
            matching.EVENT_ORDER_SKIPPED(),
            matching.EVENT_CROSSED(),
            matching.EVENT_TAKING_STAKE_CAP_LIFTED()
        ];
        string[17] memory emitters = [
            "OspexMarkets",
            "OspexMarkets",
            "OspexPositions",
            "OspexPositions",
            "OspexPositions",
            "OspexPositions",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching",
            "OspexMatching"
        ];
        BettingEventsSchema.Hub[17] memory hubs = _hubTypes();
        for (uint256 i; i < 17; ++i) {
            assertEq(keccak256(bytes(hubs[i].kind)), constants[i], string.concat("the type's constant: ", hubs[i].kind));
            assertEq(hubs[i].emitter, emitters[i], string.concat("the type's emitter: ", hubs[i].kind));
        }
    }

    /// Every `EVENT_` constant of the three modules is in the table, and the table holds nothing else: the counts
    /// are the artifacts' and each constant's name is one of the table's types for that module.
    /// Break: in the generator, drop `PAY_BACK_REFUSED`'s row (and the array's length with it).
    function test_theTableHoldsEveryConstantAndNothingElse() public view {
        BettingEventsSchema.Hub[17] memory hubs = _hubTypes();
        string[3] memory modules = ["OspexMarkets", "OspexPositions", "OspexMatching"];
        uint256 total;
        for (uint256 m; m < 3; ++m) {
            string[] memory keys = vm.parseJsonKeys(
                vm.readFile(string.concat(vm.projectRoot(), "/out/", modules[m], ".sol/", modules[m], ".json")),
                ".methodIdentifiers"
            );
            for (uint256 k; k < keys.length; ++k) {
                bytes memory key = bytes(keys[k]);
                if (key.length < 6 || keccak256(_slice(key, 0, 6)) != keccak256("EVENT_")) continue;
                // "EVENT_<KIND>()": the kind is between the prefix and the parentheses.
                bytes memory kind = _slice(key, 6, key.length - 2);
                bool found;
                for (uint256 i; i < 17; ++i) {
                    if (
                        keccak256(bytes(hubs[i].kind)) == keccak256(kind)
                            && keccak256(bytes(hubs[i].emitter)) == keccak256(bytes(modules[m]))
                    ) found = true;
                }
                assertTrue(found, string.concat("a constant not in the table: ", modules[m], ".", keys[k]));
                ++total;
            }
        }
        assertEq(total, 17, "the three modules' EVENT_ constants");
    }

    /// Each topic 0 in the file is the compiler's selector for its event, and each type hash is the keccak256 of its
    /// name: the signatures were written out from the artifacts, and this reads them back against the code.
    /// Break: in the generator, write a tuple's type as `tuple[]` instead of its components.
    function test_eachTopicIsTheCompilersSelector() public view {
        bytes32[17] memory selectors = [
            IOspexMarkets.MarketCreated.selector,
            IOspexMarkets.MarketSettled.selector,
            IOspexPositions.PositionFilled.selector,
            IOspexPositions.PositionClaimed.selector,
            IOspexPositions.HeldChanged.selector,
            IOspexPositions.PayBackRefused.selector,
            OspexMatching.OrderCancelled.selector,
            OspexMatching.FloorRaised.selector,
            OspexMatching.VersionChanged.selector,
            OspexMatching.AgentGranted.selector,
            OspexMatching.AgentRevoked.selector,
            OspexMatching.CourierRegistered.selector,
            OspexMatching.CourierUnregistered.selector,
            OspexMatching.OrderMatched.selector,
            OspexMatching.OrderSkipped.selector,
            OspexMatching.Crossed.selector,
            OspexMatching.TakingStakeCapLifted.selector
        ];
        BettingEventsSchema.Hub[17] memory hubs = _hubTypes();
        for (uint256 i; i < 17; ++i) {
            string memory at = string.concat(".hubTypes[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(file, string.concat(at, ".type")), hubs[i].kind, "the row's type");
            assertEq(
                vm.parseJsonBytes32(file, string.concat(at, ".typeHash")),
                keccak256(bytes(hubs[i].kind)),
                string.concat("the type hash: ", hubs[i].kind)
            );
            assertEq(
                vm.parseJsonBytes32(file, string.concat(at, ".event.topic0")),
                selectors[i],
                string.concat("the topic: ", hubs[i].eventName)
            );
        }
        assertFalse(vm.keyExistsJson(file, ".hubTypes[17]"), "a row past the seventeenth");

        assertEq(vm.parseJsonBytes32(file, ".hub.topic0"), OspexBetting.CoreEventEmitted.selector, "the hub's topic");
        bytes32[4] memory core = [
            OspexBetting.GamesSet.selector,
            OspexBetting.TokenSet.selector,
            OspexBetting.ModulesBootstrapped.selector,
            OspexBetting.Finalized.selector
        ];
        for (uint256 i; i < 4; ++i) {
            assertEq(
                vm.parseJsonBytes32(file, string.concat(".coreEvents[", vm.toString(i), "].topic0")),
                core[i],
                "a core event's topic"
            );
        }
        assertFalse(vm.keyExistsJson(file, ".coreEvents[4]"), "a core event past the fourth");
        assertEq(
            vm.parseJsonBytes32(file, ".relayEvents[0].topic0"), OspexCourierRelay.SenderSet.selector, "the relay's"
        );
        assertFalse(vm.keyExistsJson(file, ".relayEvents[1]"), "a relay event past the first");
    }

    function _hubTypes() internal view returns (BettingEventsSchema.Hub[17] memory) {
        return schema.hubTypes();
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = b[i];
        }
    }
}
