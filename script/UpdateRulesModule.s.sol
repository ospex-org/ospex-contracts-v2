// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/RulesModule.sol";

/**
 * @title UpdateRulesModule
 * @notice Script to redeploy RulesModule and update the core registry
 * @dev This script allows updating a single module without redeploying everything
 */
contract UpdateRulesModule is Script {
    // Expected configuration - update these as needed
    struct ModuleConfig {
        address ospexCoreAddress;
    }

    function run() external {
        // Get deployer address from environment or use default
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        // Configuration - UPDATE THESE VALUES AS NEEDED
        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: vm.envOr("OSPEX_CORE_ADDRESS", 0x829A2B2deaBd3b06f6E5938220eCfB450CE75e24)
        });

        // Validate configuration
        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS must be set");
        
        console.log("=== UPDATE RULES MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore Address:", config.ospexCoreAddress);
        console.log("Current Balance:", deployer.balance);

        vm.startBroadcast(deployer);

        // Deploy new RulesModule
        address newRulesModule = deployNewRulesModule(config);
        
        // Update the registry
        updateCoreRegistry(config.ospexCoreAddress, newRulesModule);
        
        // Print summary
        printUpdateSummary(config.ospexCoreAddress, newRulesModule);

        vm.stopBroadcast();
    }

    function deployNewRulesModule(ModuleConfig memory config) internal returns (address) {
        console.log("\n=== Deploying New RulesModule ===");
        
        RulesModule newRulesModule = new RulesModule(
            config.ospexCoreAddress
        );
        
        address moduleAddress = address(newRulesModule);
        console.log("New RulesModule deployed at:", moduleAddress);
        
        return moduleAddress;
    }

    function updateCoreRegistry(address coreAddress, address newModuleAddress) internal {
        console.log("\n=== Updating Core Registry ===");
        
        OspexCore core = OspexCore(coreAddress);
        
        // Get the old module address for logging
        address oldModule = core.getModule(keccak256("RULES_MODULE"));
        console.log("Old RulesModule:", oldModule);
        console.log("New RulesModule:", newModuleAddress);
        
        // Update the registry
        core.registerModule(keccak256("RULES_MODULE"), newModuleAddress);
        console.log("Registry updated successfully");
        
        // Verify the update
        address confirmedModule = core.getModule(keccak256("RULES_MODULE"));
        require(confirmedModule == newModuleAddress, "Registry update failed");
        console.log("Update verified");
    }

    function printUpdateSummary(address , address newModuleAddress) internal pure {
        // Only the essential info - the new contract address!
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("New RulesModule Address:", newModuleAddress);
    }

    /**
     * @notice Helper function to get deployment configuration from environment
     * @dev Can be used to customize deployment from command line
     */
    function getConfigFromEnv() internal view returns (ModuleConfig memory) {
        return ModuleConfig({
            ospexCoreAddress: vm.envAddress("OSPEX_CORE_ADDRESS")
        });
    }
} 