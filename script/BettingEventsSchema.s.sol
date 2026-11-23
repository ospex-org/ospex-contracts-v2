// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/**
 * @title BettingEventsSchema
 * @notice Writes docs/betting-events.json, the positional schema of the betting set's events, from the build's
 *         artifacts. For each type the core's hub carries: its name and the keccak256 of the name, which is the
 *         `eventType` of the core's CoreEventEmitted; the module that emits it; the typed event's signature and its
 *         topic 0; and the payload's fields in order, with their ABI types. Every module emits each typed event and,
 *         beside it, a CoreEventEmitted whose payload is every field of that event, indexed or not, in order,
 *         ABI-encoded. Then the core's own four events and the relay's one, which have no copy through the hub.
 *
 *         `forge script script/BettingEventsSchema.s.sol --skip test` writes the file.
 *         test/betting/BettingEventsSchema.t.sol builds it again and requires the file to be the same, and the table
 *         below to be the modules' own `EVENT_` constants, so the file cannot drift from the code.
 */
contract BettingEventsSchema is Script {
    string public constant PATH = "docs/betting-events.json";

    /// @notice One type the hub carries: its name, the module that emits it, and the typed event beside it.
    struct Hub {
        string kind;
        string emitter;
        string eventName;
    }

    /// @notice The hub's seventeen types, as docs/ARCHITECTURE.md lists them under "One event, emitted twice".
    function hubTypes() public pure returns (Hub[17] memory h) {
        h[0] = Hub("MARKET_CREATED", "OspexMarkets", "MarketCreated");
        h[1] = Hub("MARKET_SETTLED", "OspexMarkets", "MarketSettled");
        h[2] = Hub("POSITION_MATCHED_PAIR", "OspexPositions", "PositionFilled");
        h[3] = Hub("POSITION_CLAIMED", "OspexPositions", "PositionClaimed");
        h[4] = Hub("HELD_CHANGED", "OspexPositions", "HeldChanged");
        h[5] = Hub("PAY_BACK_REFUSED", "OspexPositions", "PayBackRefused");
        h[6] = Hub("ORDER_CANCELLED", "OspexMatching", "OrderCancelled");
        h[7] = Hub("FLOOR_RAISED", "OspexMatching", "FloorRaised");
        h[8] = Hub("VERSION_CHANGED", "OspexMatching", "VersionChanged");
        h[9] = Hub("AGENT_GRANTED", "OspexMatching", "AgentGranted");
        h[10] = Hub("AGENT_REVOKED", "OspexMatching", "AgentRevoked");
        h[11] = Hub("COURIER_REGISTERED", "OspexMatching", "CourierRegistered");
        h[12] = Hub("COURIER_UNREGISTERED", "OspexMatching", "CourierUnregistered");
        h[13] = Hub("ORDER_MATCHED", "OspexMatching", "OrderMatched");
        h[14] = Hub("ORDER_SKIPPED", "OspexMatching", "OrderSkipped");
        h[15] = Hub("CROSSED", "OspexMatching", "Crossed");
        h[16] = Hub("TAKING_STAKE_CAP_LIFTED", "OspexMatching", "TakingStakeCapLifted");
    }

    function run() external {
        vm.writeFile(string.concat(vm.projectRoot(), "/", PATH), schema());
    }

    /// @notice The schema, as the file holds it.
    function schema() public view returns (string memory json) {
        Hub[17] memory hubs = hubTypes();
        string memory core = _artifact("OspexBetting");
        json = string.concat(
            "{\n",
            '  "about": "The betting set\'s events, by position. Each hub type is carried by the core\'s CoreEventEmitted, whose eventType is the keccak256 of the type\'s name and whose payload is every field of the typed event, indexed or not, in order, ABI-encoded. A field\'s indexed flag is the typed event\'s own topic layout.",\n',
            '  "hub": ',
            _eventObject(core, "OspexBetting", "CoreEventEmitted", "  "),
            ",\n",
            '  "hubTypes": [\n'
        );
        for (uint256 i; i < hubs.length; ++i) {
            string memory abiJson = _artifact(hubs[i].emitter);
            json = string.concat(
                json,
                "    {\n",
                '      "type": "',
                hubs[i].kind,
                '",\n',
                '      "typeHash": "',
                vm.toString(keccak256(bytes(hubs[i].kind))),
                '",\n',
                '      "emitter": "',
                hubs[i].emitter,
                '",\n',
                '      "event": ',
                _eventObject(abiJson, hubs[i].emitter, hubs[i].eventName, "      "),
                "\n    }",
                i + 1 < hubs.length ? ",\n" : "\n"
            );
        }
        json = string.concat(json, "  ],\n", '  "coreEvents": [\n');
        string[4] memory own = ["GamesSet", "TokenSet", "ModulesBootstrapped", "Finalized"];
        for (uint256 i; i < own.length; ++i) {
            json = string.concat(
                json, "    ", _eventObject(core, "OspexBetting", own[i], "    "), i + 1 < own.length ? ",\n" : "\n"
            );
        }
        json = string.concat(
            json,
            "  ],\n",
            '  "relayEvents": [\n',
            "    ",
            _eventObject(_artifact("OspexCourierRelay"), "OspexCourierRelay", "SenderSet", "    "),
            "\n  ]\n}\n"
        );
    }

    /// @dev One event as an object: its contract, its signature, its topic 0, and its fields in order.
    function _eventObject(string memory abiJson, string memory emitter, string memory name, string memory indent)
        internal
        view
        returns (string memory out)
    {
        string memory at = _eventPath(abiJson, name);
        string memory types;
        string memory fields;
        for (uint256 j; vm.keyExistsJson(abiJson, string.concat(at, ".inputs[", vm.toString(j), "]")); ++j) {
            string memory input = string.concat(at, ".inputs[", vm.toString(j), "]");
            string memory t = _canonical(abiJson, input);
            types = j == 0 ? t : string.concat(types, ",", t);
            fields = string.concat(
                fields,
                j == 0 ? "" : ",\n",
                indent,
                '    {"name": "',
                vm.parseJsonString(abiJson, string.concat(input, ".name")),
                '", "type": "',
                t,
                '", "indexed": ',
                vm.parseJsonBool(abiJson, string.concat(input, ".indexed")) ? "true" : "false",
                "}"
            );
        }
        string memory signature = string.concat(name, "(", types, ")");
        out = string.concat(
            "{\n",
            indent,
            '  "contract": "',
            emitter,
            '",\n',
            indent,
            '  "signature": "',
            signature,
            '",\n',
            indent,
            '  "topic0": "',
            vm.toString(keccak256(bytes(signature))),
            '",\n',
            indent,
            '  "fields": [',
            bytes(fields).length == 0 ? "" : string.concat("\n", fields, "\n", indent, "  "),
            "]\n",
            indent,
            "}"
        );
    }

    /// @dev The path of the named event in an artifact's ABI. Fails if there is none, or more than one.
    function _eventPath(string memory abiJson, string memory name) internal view returns (string memory found) {
        uint256 count;
        for (uint256 i; vm.keyExistsJson(abiJson, string.concat(".abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            if (
                _equal(vm.parseJsonString(abiJson, string.concat(entry, ".type")), "event")
                    && _equal(vm.parseJsonString(abiJson, string.concat(entry, ".name")), name)
            ) {
                found = entry;
                ++count;
            }
        }
        require(count == 1, string.concat("the artifact has not exactly one event ", name));
    }

    /// @dev An ABI parameter's canonical type: a tuple written out as its components, in parentheses.
    function _canonical(string memory abiJson, string memory param) internal view returns (string memory) {
        string memory t = vm.parseJsonString(abiJson, string.concat(param, ".type"));
        bytes memory b = bytes(t);
        if (b.length < 5 || !_equal(_slice(t, 0, 5), "tuple")) return t;
        string memory inner = "(";
        for (uint256 j; vm.keyExistsJson(abiJson, string.concat(param, ".components[", vm.toString(j), "]")); ++j) {
            inner = string.concat(
                inner, j == 0 ? "" : ",", _canonical(abiJson, string.concat(param, ".components[", vm.toString(j), "]"))
            );
        }
        return string.concat(inner, ")", _slice(t, 5, b.length));
    }

    function _artifact(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/out/", name, ".sol/", name, ".json"));
    }

    function _equal(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _slice(string memory s, uint256 from, uint256 to) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = b[i];
        }
        return string(out);
    }
}
