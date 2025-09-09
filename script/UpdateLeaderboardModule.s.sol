// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/LeaderboardModule.sol";

/**
 * @title UpdateLeaderboardModule
 * @notice Script to redeploy LeaderboardModule and update the core registry
 * @dev This script allows updating a single module without redeploying everything
 */
contract UpdateLeaderboardModule is Script {
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
        
        console.log("=== UPDATE LEADERBOARD MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore Address:", config.ospexCoreAddress);
        console.log("Current Balance:", deployer.balance);

        vm.startBroadcast(deployer);

        // Deploy new LeaderboardModule
        address newLeaderboardModule = deployNewLeaderboardModule(config);
        
        // Update the registry
        updateCoreRegistry(config.ospexCoreAddress, newLeaderboardModule);
        
        // Print summary
        printUpdateSummary(config.ospexCoreAddress, newLeaderboardModule);

        vm.stopBroadcast();
    }

    function deployNewLeaderboardModule(ModuleConfig memory config) internal returns (address) {
        console.log("\n=== Deploying New LeaderboardModule ===");
        
        LeaderboardModule newLeaderboardModule = new LeaderboardModule(
            config.ospexCoreAddress
        );
        
        address moduleAddress = address(newLeaderboardModule);
        console.log("New LeaderboardModule deployed at:", moduleAddress);
        
        return moduleAddress;
    }

    function updateCoreRegistry(address coreAddress, address newModuleAddress) internal {
        console.log("\n=== Updating Core Registry ===");
        
        OspexCore core = OspexCore(coreAddress);
        
        // Get the old module address for logging
        address oldModule = core.getModule(keccak256("LEADERBOARD_MODULE"));
        console.log("Old LeaderboardModule:", oldModule);
        console.log("New LeaderboardModule:", newModuleAddress);
        
        // Update the registry
        core.registerModule(keccak256("LEADERBOARD_MODULE"), newModuleAddress);
        console.log("Registry updated successfully");
        
        // Verify the update
        address confirmedModule = core.getModule(keccak256("LEADERBOARD_MODULE"));
        require(confirmedModule == newModuleAddress, "Registry update failed");
        console.log("Update verified");
    }

    function printUpdateSummary(address coreAddress, address newModuleAddress) internal pure {
        console.log("\n=== UPDATE SUMMARY ===");
        console.log("Network: Polygon Amoy Testnet (or current network)");
        console.log("OspexCore:", coreAddress);
        console.log("New LeaderboardModule:", newModuleAddress);
        
        console.log("\n=== FRONTEND CONFIGURATION UPDATE ===");
        console.log("Update your frontend configuration:");
        console.log("LEADERBOARD_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== FIREBASE CONFIGURATION UPDATE ===");
        console.log("Update your Firebase event handlers:");
        console.log("LEADERBOARD_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== IMPORTANT NOTES ===");
        console.log("*** WARNING: All existing leaderboard registrations will be reset ***");
        console.log("- Previous leaderboard registrations are no longer accessible on-chain");
        console.log("- Event history remains in your backend/Firebase");
        console.log("- Users will need to re-register for leaderboards");
        console.log("- Test data loss is acceptable as mentioned");
        
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update frontend contract addresses");
        console.log("2. Update Firebase event handler configuration");
        console.log("3. Test leaderboard creation with the new module");
        console.log("4. Test position registration for leaderboards");
        console.log("5. Test leaderboard position amount increases");
        console.log("6. Verify Firebase event processing works correctly");
        
        console.log("\n=== NEW FEATURES INCLUDED ===");
        console.log("The new LeaderboardModule includes:");
        console.log("- UPDATED: oddsPairId now included in LEADERBOARD_POSITION_ADDED events");
        console.log("- UPDATED: oddsPairId now included in LEADERBOARD_POSITION_UPDATED events");
        console.log("- FIXED: Firebase event handlers can now properly update position documents");
        console.log("- All existing leaderboard functionality maintained");
        console.log("- Compatible with existing speculation and position modules");
        console.log("- Proper event emission through Core contract");
        
        console.log("\n=== FIREBASE EVENT HANDLER UPDATES REQUIRED ===");
        console.log("After deployment, update Firebase dataSchema to:");
        console.log("LEADERBOARD_POSITION_ADDED: [\"uint256\", \"address\", \"uint128\", \"uint256\", \"uint8\", \"uint256\"]");
        console.log("LEADERBOARD_POSITION_UPDATED: [\"uint256\", \"address\", \"uint128\", \"uint256\", \"uint8\", \"uint256\"]");
        console.log("(speculationId, user, oddsPairId, amount, positionType, leaderboardId)");
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
