// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/SpeculationModule.sol";
import "../src/modules/PositionModule.sol";

/**
 * @title UpdateSpeculationAndPositionModules
 * @notice Script to redeploy SpeculationModule and PositionModule and update the core registry
 * @dev Updates both modules in a single transaction
 */
contract UpdateSpeculationAndPositionModules is Script {
    struct ModuleConfig {
        address ospexCoreAddress;
        address tokenAddress;
        uint8 tokenDecimals;
    }

    function run() external {
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: vm.envOr("OSPEX_CORE_ADDRESS", 0x829A2B2deaBd3b06f6E5938220eCfB450CE75e24),
            tokenAddress: vm.envOr("TOKEN_ADDRESS", 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8),
            tokenDecimals: 6
        });

        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS required");
        require(config.tokenAddress != address(0), "TOKEN_ADDRESS required");
        
        console.log("=== UPDATE MODULES ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore:", config.ospexCoreAddress);

        vm.startBroadcast(deployer);

        // Deploy new modules
        address newSpeculationModule = address(new SpeculationModule(
            config.ospexCoreAddress,
            config.tokenDecimals
        ));
        console.log("SpeculationModule deployed:", newSpeculationModule);
        
        address newPositionModule = address(new PositionModule(
            config.ospexCoreAddress,
            config.tokenAddress
        ));
        console.log("PositionModule deployed:", newPositionModule);
        
        // Update registry
        OspexCore core = OspexCore(config.ospexCoreAddress);
        
        core.registerModule(keccak256("SPECULATION_MODULE"), newSpeculationModule);
        console.log("SpeculationModule registered");
        
        core.registerModule(keccak256("POSITION_MODULE"), newPositionModule);
        console.log("PositionModule registered");

        // Summary
        console.log("\n=== UPDATE COMPLETE ===");
        console.log("SPECULATION_MODULE_ADDRESS=", newSpeculationModule);
        console.log("POSITION_MODULE_ADDRESS=", newPositionModule);
        console.log("\nUpdate frontend and MCP server configs with new addresses");

        vm.stopBroadcast();
    }
}

