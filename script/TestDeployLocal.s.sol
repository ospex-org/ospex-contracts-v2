// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/modules/RulesModule.sol";
import "../src/core/OspexCore.sol";

contract TestDeploy is Script {
    // Add the struct from UpdateRulesModule
    struct ModuleConfig {
        address ospexCoreAddress;
    }

    function run() external {
        // Get deployer address like UpdateRulesModule
        address deployer = vm.envOr("DEPLOYER", address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266));
        
        // Use struct like UpdateRulesModule
        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: 0x5FbDB2315678afecb367f032d93F642f64180aa3
        });

        // Add validation like UpdateRulesModule
        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS must be set");
        
        // Add header logs like UpdateRulesModule
        console.log("=== UPDATE RULES MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore Address:", config.ospexCoreAddress);
        console.log("Current Balance:", deployer.balance);

        vm.startBroadcast(deployer);

        // Break into helper functions like UpdateRulesModule
        address newRulesModule = deployNewRulesModule(config);
        updateCoreRegistry(config.ospexCoreAddress, newRulesModule);
        
        // Print summary with minimal logging
        printUpdateSummary(config.ospexCoreAddress, newRulesModule);
        
        vm.stopBroadcast();
    }

    function deployNewRulesModule(ModuleConfig memory config) internal returns (address) {
        console.log("\n=== Deploying New RulesModule ===");
        
        RulesModule newRulesModule = new RulesModule(config.ospexCoreAddress);
        address moduleAddress = address(newRulesModule);
        console.log("New RulesModule deployed at:", moduleAddress);
        
        return moduleAddress;
    }

    function updateCoreRegistry(address coreAddress, address newModuleAddress) internal {
        console.log("\n=== Updating Core Registry ===");
        
        OspexCore core = OspexCore(coreAddress);
        
        // Get old module for logging
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
        // Only the essential info you need - the new contract address!
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
