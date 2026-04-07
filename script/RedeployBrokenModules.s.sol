// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";

// Modules that need redeployment
import "../src/modules/OracleModule.sol";
import "../src/modules/PositionModule.sol";
import "../src/modules/LeaderboardModule.sol";
import "../src/modules/RulesModule.sol";
import "../src/modules/MatchingModule.sol";

// For setting max speculation amount
import "../src/modules/SpeculationModule.sol";

/**
 * @title RedeployBrokenModules
 * @notice Redeploys modules that were deployed with wrong OspexCore address
 * @dev Redeploys: OracleModule, PositionModule, LeaderboardModule, RulesModule
 */
contract RedeployBrokenModules is Script {
    // Polygon mainnet addresses
    address constant LINK_ADDRESS = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address constant FUNCTIONS_ROUTER = 0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10;
    address constant USDC_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    
    // CORRECT OspexCore address (already deployed)
    address constant OSPEX_CORE = 0x8016b2C5f161e84940E25Bb99479aAca19D982aD;
    
    // Existing SpeculationModule (correctly deployed, just needs max amount set)
    address constant SPECULATION_MODULE = 0x599FFd7A5A00525DD54BD247f136f99aF6108513;
    
    // DON ID for Chainlink Functions
    bytes32 constant DON_ID = bytes32("fun-polygon-mainnet-1");
    
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        
        console.log("=== REDEPLOYING BROKEN MODULES ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("Using OspexCore at:", OSPEX_CORE);

        vm.startBroadcast(deployer);

        // 1. Deploy new modules with CORRECT OspexCore address
        console.log("\n=== Deploying New Modules ===");
        
        address newOracleModule = address(new OracleModule(
            OSPEX_CORE,
            FUNCTIONS_ROUTER,
            LINK_ADDRESS,
            DON_ID
        ));
        console.log("New OracleModule:", newOracleModule);
        
        address newPositionModule = address(new PositionModule(
            OSPEX_CORE,
            USDC_ADDRESS
        ));
        console.log("New PositionModule:", newPositionModule);
        
        address newLeaderboardModule = address(new LeaderboardModule(OSPEX_CORE));
        console.log("New LeaderboardModule:", newLeaderboardModule);
        
        address newRulesModule = address(new RulesModule(OSPEX_CORE));
        console.log("New RulesModule:", newRulesModule);

        address newMatchingModule = address(new MatchingModule(OSPEX_CORE));
        console.log("New MatchingModule:", newMatchingModule);

        // 2. Re-register modules in OspexCore (overwrites old registrations)
        console.log("\n=== Re-registering Modules ===");
        
        OspexCore core = OspexCore(OSPEX_CORE);
        
        core.registerModule(keccak256("ORACLE_MODULE"), newOracleModule);
        console.log("Registered ORACLE_MODULE");
        
        core.registerModule(keccak256("POSITION_MODULE"), newPositionModule);
        console.log("Registered POSITION_MODULE");
        
        core.registerModule(keccak256("LEADERBOARD_MODULE"), newLeaderboardModule);
        console.log("Registered LEADERBOARD_MODULE");
        
        core.registerModule(keccak256("RULES_MODULE"), newRulesModule);
        console.log("Registered RULES_MODULE");

        core.registerModule(keccak256("MATCHING_MODULE"), newMatchingModule);
        console.log("Registered MATCHING_MODULE");

        // Grant scorer role to existing scorer modules
        address moneylineScorer = core.getModule(keccak256("MONEYLINE_SCORER_MODULE"));
        address spreadScorer = core.getModule(keccak256("SPREAD_SCORER_MODULE"));
        address totalScorer = core.getModule(keccak256("TOTAL_SCORER_MODULE"));

        core.setScorerRole(moneylineScorer, true);
        console.log("Granted SCORER_ROLE to MoneylineScorerModule:", moneylineScorer);

        core.setScorerRole(spreadScorer, true);
        console.log("Granted SCORER_ROLE to SpreadScorerModule:", spreadScorer);

        core.setScorerRole(totalScorer, true);
        console.log("Granted SCORER_ROLE to TotalScorerModule:", totalScorer);

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== REDEPLOYMENT SUMMARY ===");
        console.log("New OracleModule:", newOracleModule);
        console.log("New PositionModule:", newPositionModule);
        console.log("New LeaderboardModule:", newLeaderboardModule);
        console.log("New RulesModule:", newRulesModule);
        console.log("New MatchingModule:", newMatchingModule);

        console.log("\n=== CRITICAL NEXT STEPS ===");
        console.log("1. Add NEW OracleModule as consumer to Chainlink subscription 191:");
        console.log("   Address:", newOracleModule);
        console.log("2. Remove OLD OracleModule from Chainlink subscription:");
        console.log("   Old address: 0x6FA9812cECD93084d7E276dD88e0aCE9E18E9EB5");
        console.log("3. Update frontend/backend with new contract addresses");
        console.log("4. Update Alchemy webhook if filtering by contract address");
        
        console.log("\n=== ADDRESSES TO UPDATE ===");
        console.log("ORACLE_MODULE_ADDRESS=", newOracleModule);
        console.log("POSITION_MODULE_ADDRESS=", newPositionModule);
        console.log("LEADERBOARD_MODULE_ADDRESS=", newLeaderboardModule);
        console.log("RULES_MODULE_ADDRESS=", newRulesModule);
        console.log("MATCHING_MODULE_ADDRESS=", newMatchingModule);
    }
}
