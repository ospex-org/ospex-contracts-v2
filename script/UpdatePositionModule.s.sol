// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/PositionModule.sol";

/**
 * @title UpdatePositionModule
 * @notice Script to redeploy PositionModule and update the core registry
 * @dev This script allows updating a single module without redeploying everything
 */
contract UpdatePositionModule is Script {
    // Expected configuration - update these as needed
    struct ModuleConfig {
        address ospexCoreAddress;
        address tokenAddress;
    }

    function run() external {
        // Get deployer address from environment or use default
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        // Configuration - UPDATE THESE VALUES AS NEEDED
        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: vm.envOr("OSPEX_CORE_ADDRESS", 0x8A583cc9282CC6dC735389d2Ca7Ea7Df3A2D3f7b), // Your deployed core address
            tokenAddress: vm.envOr("TOKEN_ADDRESS", 0x0bEcAfa5dC817143C7D000d1C60db865301d2D83) // Your USDC token address
        });

        // Validate configuration
        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS must be set");
        require(config.tokenAddress != address(0), "TOKEN_ADDRESS must be set");
        
        console.log("=== UPDATE POSITION MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore Address:", config.ospexCoreAddress);
        console.log("Token Address:", config.tokenAddress);
        console.log("Current Balance:", deployer.balance);

        vm.startBroadcast(deployer);

        // Deploy new PositionModule
        address newPositionModule = deployNewPositionModule(config);
        
        // Update the registry
        updateCoreRegistry(config.ospexCoreAddress, newPositionModule);
        
        // Print summary
        printUpdateSummary(config.ospexCoreAddress, newPositionModule);

        vm.stopBroadcast();
    }

    function deployNewPositionModule(ModuleConfig memory config) internal returns (address) {
        console.log("\n=== Deploying New PositionModule ===");
        
        PositionModule newPositionModule = new PositionModule(
            config.ospexCoreAddress,
            config.tokenAddress
        );
        
        address moduleAddress = address(newPositionModule);
        console.log("New PositionModule deployed at:", moduleAddress);
        console.log("Using Token Address:", config.tokenAddress);
        
        return moduleAddress;
    }

    function updateCoreRegistry(address coreAddress, address newModuleAddress) internal {
        console.log("\n=== Updating Core Registry ===");
        
        OspexCore core = OspexCore(coreAddress);
        
        // Get the old module address for logging
        address oldModule = core.getModule(keccak256("POSITION_MODULE"));
        console.log("Old PositionModule:", oldModule);
        console.log("New PositionModule:", newModuleAddress);
        
        // Update the registry
        core.registerModule(keccak256("POSITION_MODULE"), newModuleAddress);
        console.log("Registry updated successfully");
        
        // Verify the update
        address confirmedModule = core.getModule(keccak256("POSITION_MODULE"));
        require(confirmedModule == newModuleAddress, "Registry update failed");
        console.log("Update verified");
    }

    function printUpdateSummary(address coreAddress, address newModuleAddress) internal view {
        console.log("\n=== UPDATE SUMMARY ===");
        console.log("Network: Polygon Amoy Testnet (or current network)");
        console.log("OspexCore:", coreAddress);
        console.log("New PositionModule:", newModuleAddress);
        
        console.log("\n=== FRONTEND CONFIGURATION UPDATE ===");
        console.log("Update your frontend configuration:");
        console.log("POSITION_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== MCP SERVER CONFIGURATION UPDATE ===");
        console.log("Update your MCP server configuration:");
        console.log("POSITION_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== IMPORTANT NOTES ===");
        console.log("*** WARNING: All existing position mappings will be reset ***");
        console.log("- Previous positions are no longer accessible on-chain");
        console.log("- Event history remains in your backend/Firebase");
        console.log("- Users will need to create new positions");
        console.log("- Test data loss is acceptable as mentioned");
        
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update frontend contract addresses");
        console.log("2. Update MCP server contract addresses");
        console.log("3. Test position creation with the new module");
        console.log("4. Test adjustUnmatchedPair with zero unmatched amount (new feature)");
        console.log("5. Test secondary market functionality");
        console.log("6. Verify position claiming works correctly");
        
        console.log("\n=== BUG FIX INCLUDED ===");
        console.log("The new PositionModule includes:");
        console.log("- FIXED: Users can now adjust positions after being fully matched");
        console.log("- FIXED: Removed restriction preventing 'restart' of positions");
        console.log("- All existing position functionality maintained");
        console.log("- Compatible with SecondaryMarketModule");
        console.log("- Proper event emission through Core contract");
    }

    /**
     * @notice Helper function to get deployment configuration from environment
     * @dev Can be used to customize deployment from command line
     */
    function getConfigFromEnv() internal view returns (ModuleConfig memory) {
        return ModuleConfig({
            ospexCoreAddress: vm.envAddress("OSPEX_CORE_ADDRESS"),
            tokenAddress: vm.envAddress("TOKEN_ADDRESS")
        });
    }
}