// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/core/OspexCore.sol";

// Deploys the OspexCore contract on anvil
// # 1. Deploy OspexCore
// forge script script/DeployCore.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast --via-ir --optimize

contract DeployCore is Script {
    function run() external {
        vm.startBroadcast();
        
        OspexCore core = new OspexCore();
        console.log("OspexCore deployed at:", address(core));
        
        vm.stopBroadcast();
    }
}
