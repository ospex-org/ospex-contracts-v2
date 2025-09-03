// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/ContestModule.sol";

/**
 * @title UpdateContestModule
 * @notice Script to redeploy ContestModule and update the core registry
 * @dev This script allows updating a single module without redeploying everything
 */
contract UpdateContestModule is Script {
    // Expected configuration - update these as needed
    struct ModuleConfig {
        address ospexCoreAddress;
        bytes32 createContestSourceHash;
        bytes32 updateContestMarketsSourceHash;
    }

    function run() external {
        // Get deployer address from environment or use default
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        // Configuration - UPDATE THESE VALUES AS NEEDED
        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: vm.envOr("OSPEX_CORE_ADDRESS", 0x8A583cc9282CC6dC735389d2Ca7Ea7Df3A2D3f7b), // Your deployed core address
            createContestSourceHash: 0x74533c92d0380a7aa2c8d597453cdcea7350344971be3df02623fe339002f9ab, // Update if needed
            updateContestMarketsSourceHash: 0x74533c92d0380a7aa2c8d597453cdcea7350344971be3df02623fe339002f9ab // TODO: update this
        });

        // Validate configuration
        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS must be set");
        
        console.log("=== UPDATE CONTEST MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore Address:", config.ospexCoreAddress);
        console.log("Current Balance:", deployer.balance);

        vm.startBroadcast(deployer);

        // Deploy new ContestModule
        address newContestModule = deployNewContestModule(config);
        
        // Update the registry
        updateCoreRegistry(config.ospexCoreAddress, newContestModule);
        
        // Print summary
        printUpdateSummary(config.ospexCoreAddress, newContestModule);

        vm.stopBroadcast();
    }

    function deployNewContestModule(ModuleConfig memory config) internal returns (address) {
        console.log("\n=== Deploying New ContestModule ===");
        
        ContestModule newContestModule = new ContestModule(
            config.ospexCoreAddress,
            config.createContestSourceHash,
            config.updateContestMarketsSourceHash
        );
        
        address moduleAddress = address(newContestModule);
        console.log("New ContestModule deployed at:", moduleAddress);
        console.log("Create Contest Source Hash:", vm.toString(config.createContestSourceHash));
        
        return moduleAddress;
    }

    function updateCoreRegistry(address coreAddress, address newModuleAddress) internal {
        console.log("\n=== Updating Core Registry ===");
        
        OspexCore core = OspexCore(coreAddress);
        
        // Get the old module address for logging
        address oldModule = core.getModule(keccak256("CONTEST_MODULE"));
        console.log("Old ContestModule:", oldModule);
        console.log("New ContestModule:", newModuleAddress);
        
        // Update the registry
        core.registerModule(keccak256("CONTEST_MODULE"), newModuleAddress);
        console.log("Registry updated successfully");
        
        // Verify the update
        address confirmedModule = core.getModule(keccak256("CONTEST_MODULE"));
        require(confirmedModule == newModuleAddress, "Registry update failed");
        console.log("Update verified");
    }

    function printUpdateSummary(address coreAddress, address newModuleAddress) internal pure {
        console.log("\n=== UPDATE SUMMARY ===");
        console.log("Network: Polygon Amoy Testnet (or current network)");
        console.log("OspexCore:", coreAddress);
        console.log("New ContestModule:", newModuleAddress);
        
        console.log("\n=== FRONTEND CONFIGURATION UPDATE ===");
        console.log("Update your frontend configuration:");
        console.log("CONTEST_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update frontend contract addresses");
        console.log("2. Test contest creation with the new module");
        console.log("3. Verify setCreateContestSourceHash function works");
        console.log("4. Test the complete contest creation flow");
        
        console.log("\n=== NEW FUNCTIONALITY ===");
        console.log("The new ContestModule includes:");
        console.log("- setCreateContestSourceHash() function");
        console.log("- All existing contest creation functionality");
        console.log("- Compatible with existing speculations and positions");
    }

    /**
     * @notice Helper function to get deployment configuration from environment
     * @dev Can be used to customize deployment from command line
     */
    function getConfigFromEnv() internal view returns (ModuleConfig memory) {
        return ModuleConfig({
            ospexCoreAddress: vm.envAddress("OSPEX_CORE_ADDRESS"),
            createContestSourceHash: vm.envBytes32("CREATE_CONTEST_SOURCE_HASH"),
            updateContestMarketsSourceHash: vm.envBytes32("UPDATE_CONTEST_MARKETS_SOURCE_HASH")
        });
    }
} 