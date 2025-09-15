// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/TreasuryModule.sol";

/**
 * @title UpdateTreasuryModule
 * @notice Script to redeploy TreasuryModule and update the core registry
 * @dev This script allows updating a single module without redeploying everything
 */
contract UpdateTreasuryModule is Script {
    // Expected configuration - update these as needed
    struct ModuleConfig {
        address ospexCoreAddress;
        address tokenAddress;        // USDC token address
        address protocolReceiver;    // Protocol fee receiver address
    }

    function run() external {
        // Get deployer address from environment or use default
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        // Configuration - UPDATE THESE VALUES AS NEEDED
        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: vm.envOr("OSPEX_CORE_ADDRESS", 0x829A2B2deaBd3b06f6E5938220eCfB450CE75e24),
            tokenAddress: vm.envOr("USDC_TOKEN_ADDRESS", 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8),
            protocolReceiver: vm.envOr("PROTOCOL_RECEIVER_ADDRESS", 0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3)
        });

        // Validate configuration
        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS must be set");
        require(config.tokenAddress != address(0), "USDC_TOKEN_ADDRESS must be set");
        require(config.protocolReceiver != address(0), "PROTOCOL_RECEIVER_ADDRESS must be set");
        
        console.log("=== UPDATE TREASURY MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore Address:", config.ospexCoreAddress);
        console.log("USDC Token Address:", config.tokenAddress);
        console.log("Protocol Receiver:", config.protocolReceiver);
        console.log("Current Balance:", deployer.balance);

        vm.startBroadcast(deployer);

        // Deploy new TreasuryModule
        address newTreasuryModule = deployNewTreasuryModule(config);
        
        // Update the registry
        updateCoreRegistry(config.ospexCoreAddress, newTreasuryModule);
        
        // Print summary
        printUpdateSummary(config.ospexCoreAddress, newTreasuryModule);

        vm.stopBroadcast();
    }

    function deployNewTreasuryModule(ModuleConfig memory config) internal returns (address) {
        console.log("\n=== Deploying New TreasuryModule ===");
        
        TreasuryModule newTreasuryModule = new TreasuryModule(
            config.ospexCoreAddress,
            config.tokenAddress,
            config.protocolReceiver
        );
        
        address moduleAddress = address(newTreasuryModule);
        console.log("New TreasuryModule deployed at:", moduleAddress);
        
        return moduleAddress;
    }

    function updateCoreRegistry(address coreAddress, address newModuleAddress) internal {
        console.log("\n=== Updating Core Registry ===");
        
        OspexCore core = OspexCore(coreAddress);
        
        // Get the old module address for logging
        address oldModule = core.getModule(keccak256("TREASURY_MODULE"));
        console.log("Old TreasuryModule:", oldModule);
        console.log("New TreasuryModule:", newModuleAddress);
        
        // Update the registry
        core.registerModule(keccak256("TREASURY_MODULE"), newModuleAddress);
        console.log("Registry updated successfully");
        
        // Verify the update
        address confirmedModule = core.getModule(keccak256("TREASURY_MODULE"));
        require(confirmedModule == newModuleAddress, "Registry update failed");
        console.log("Update verified");
    }

    function printUpdateSummary(address coreAddress, address newModuleAddress) internal pure {
        console.log("\n=== UPDATE SUMMARY ===");
        console.log("Network: Polygon Amoy Testnet (or current network)");
        console.log("OspexCore:", coreAddress);
        console.log("New TreasuryModule:", newModuleAddress);
        
        console.log("\n=== FRONTEND CONFIGURATION UPDATE ===");
        console.log("Update your frontend configuration:");
        console.log("TREASURY_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== FIREBASE CONFIGURATION UPDATE ===");
        console.log("Update your Firebase event handlers:");
        console.log("TREASURY_MODULE_ADDRESS=", newModuleAddress);
        
        console.log("\n=== IMPORTANT NOTES ===");
        console.log("*** WARNING: All existing prize pools will be reset ***");
        console.log("- Previous leaderboard prize pools are no longer accessible on-chain");
        console.log("- Event history remains in your backend/Firebase");
        console.log("- Protocol fee configuration will need to be reset");
        console.log("- Existing leaderboards will need fresh prize pool funding");
        
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update frontend contract addresses");
        console.log("2. Update Firebase event handler configuration");
        console.log("3. Reconfigure protocol fee rates if needed");
        console.log("4. Test fee collection and prize pool funding");
        console.log("5. Test leaderboard prize claiming with new access control");
        console.log("6. Verify Firebase event processing works correctly");
        
        console.log("\n=== NEW FEATURES INCLUDED ===");
        console.log("The new TreasuryModule includes:");
        console.log("- UPDATED: claimPrizePool() now uses onlyLeaderboardModule access control");
        console.log("- FIXED: LeaderboardModule can now call claimPrizePool() directly");
        console.log("- MAINTAINED: All fee collection functionality preserved");
        console.log("- MAINTAINED: Protocol cut and receiver configuration preserved");
        console.log("- MAINTAINED: Prize pool tracking and management preserved");
        console.log("- Compatible with existing Core contract fee routing");
        
        console.log("\n=== ACCESS CONTROL CHANGES ===");
        console.log("BEFORE: claimPrizePool() restricted to onlyCore");
        console.log("AFTER:  claimPrizePool() restricted to onlyLeaderboardModule");
        console.log("RESULT: LeaderboardModule can directly claim prizes for users");
        console.log("BENEFIT: Follows DeFi industry standards for user withdrawals");
        
        console.log("\n=== TESTING CHECKLIST ===");
        console.log("[] Verify LeaderboardModule can call claimPrizePool()");
        console.log("[] Verify non-LeaderboardModule addresses cannot call claimPrizePool()");
        console.log("[] Verify Core can still call processFee() and processLeaderboardEntryFee()");
        console.log("[] Test end-to-end leaderboard prize claiming flow");
        console.log("[] Verify Firebase handlers capture PRIZE_POOL_CLAIMED events");
        
        console.log("\n=== CONFIGURATION REQUIRED AFTER DEPLOYMENT ===");
        console.log("Run these commands on the new TreasuryModule:");
        console.log("1. treasuryModule.setFeeRates(FeeType.ContestCreation, RATE)");
        console.log("2. treasuryModule.setFeeRates(FeeType.SpeculationCreation, RATE)");
        console.log("3. treasuryModule.setProtocolCut(BPS) // if different from default");
        console.log("4. Verify protocolReceiver is set correctly");
    }

    /**
     * @notice Helper function to get deployment configuration from environment
     * @dev Can be used to customize deployment from command line
     */
    function getConfigFromEnv() internal view returns (ModuleConfig memory) {
        return ModuleConfig({
            ospexCoreAddress: vm.envAddress("OSPEX_CORE_ADDRESS"),
            tokenAddress: vm.envAddress("USDC_TOKEN_ADDRESS"),
            protocolReceiver: vm.envAddress("PROTOCOL_RECEIVER_ADDRESS")
        });
    }
}
