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

        // Deploy dependencies
        OspexCore core = new OspexCore();
        console.log("OspexCore deployed at:", address(core));

        MockERC20 token = new MockERC20();
        console.log("MockERC20 deployed at:", address(token));

        // Deploy SpeculationModule
        SpeculationModule speculationModule = new SpeculationModule(
            address(core),
            6 // USDC decimals
        );
        console.log("SpeculationModule deployed at:", address(speculationModule));

        // Deploy PositionModule
        PositionModule positionModule = new PositionModule(
            address(core),
            address(token)
        );
        console.log("PositionModule deployed at:", address(positionModule));

        // Register modules in OspexCore
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));

        // Deploy MatchingModule (looks up modules from OspexCore at runtime)
        MatchingModule matchingModule = new MatchingModule(address(core));
        console.log("MatchingModule deployed at:", address(matchingModule));
        console.log("All deployments successful!");

        vm.stopBroadcast();
    }
}
