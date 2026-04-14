// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {OspexCore} from "../src/core/OspexCore.sol";
import {PositionModule} from "../src/modules/PositionModule.sol";
import {SpeculationModule} from "../src/modules/SpeculationModule.sol";
import {MatchingModule} from "../src/modules/MatchingModule.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeployMatchingModuleAnvil is Script {
    function run() external {
        vm.startBroadcast();

        OspexCore core = new OspexCore();
        console.log("OspexCore deployed at:", address(core));

        MockERC20 token = new MockERC20();
        console.log("MockERC20 deployed at:", address(token));

        SpeculationModule speculationModule = new SpeculationModule(
            address(core), 6, 3 days, 1_000_000
        );
        console.log("SpeculationModule deployed at:", address(speculationModule));

        PositionModule positionModule = new PositionModule(address(core), address(token));
        console.log("PositionModule deployed at:", address(positionModule));

        MatchingModule matchingModule = new MatchingModule(address(core));
        console.log("MatchingModule deployed at:", address(matchingModule));

        // Bootstrap the modules we have (partial — for local testing only)
        bytes32[] memory types = new bytes32[](3);
        address[] memory addrs = new address[](3);
        types[0] = core.SPECULATION_MODULE();   addrs[0] = address(speculationModule);
        types[1] = core.POSITION_MODULE();      addrs[1] = address(positionModule);
        types[2] = core.MATCHING_MODULE();      addrs[2] = address(matchingModule);
        core.bootstrapModules(types, addrs);
        console.log("Modules bootstrapped (not finalized - partial deploy for testing).");

        vm.stopBroadcast();
    }
}
