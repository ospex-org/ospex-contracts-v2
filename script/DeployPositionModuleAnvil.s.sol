// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {OspexCore} from "../src/core/OspexCore.sol";
import {PositionModule} from "../src/modules/PositionModule.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeployPositionModuleAnvil is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy dependencies
        OspexCore core = new OspexCore();
        console.log("OspexCore deployed at:", address(core));

        MockERC20 token = new MockERC20();
        console.log("MockERC20 deployed at:", address(token));

        // Deploy PositionModule
        PositionModule positionModule = new PositionModule(
            address(core),
            address(token)
        );
        console.log("PositionModule deployed at:", address(positionModule));
        console.log("PositionModule deployment successful!");

        vm.stopBroadcast();
    }
}
