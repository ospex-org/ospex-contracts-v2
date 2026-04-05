// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";

// Modules
import "../src/modules/TreasuryModule.sol";
import "../src/modules/OracleModule.sol";
import "../src/modules/SpeculationModule.sol";
import "../src/modules/PositionModule.sol";
import "../src/modules/SecondaryMarketModule.sol";
import "../src/modules/ContestModule.sol";
import "../src/modules/ContributionModule.sol";
import "../src/modules/LeaderboardModule.sol";
import "../src/modules/RulesModule.sol";
import "../src/modules/MoneylineScorerModule.sol";
import "../src/modules/SpreadScorerModule.sol";
import "../src/modules/TotalScorerModule.sol";
import "../src/modules/MatchingModule.sol";

/**
 * @title DeployPolygon
 * @notice Deployment script for Ospex protocol on Polygon Mainnet
 * @dev Deploys all contracts with Polygon mainnet configuration
 */
contract DeployPolygon is Script {
    // Polygon mainnet addresses
    address constant LINK_ADDRESS = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address constant FUNCTIONS_ROUTER = 0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10;
    address constant USDC_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    
    // Fee collection wallet (receives protocol fees)
    address constant FEE_RECEIVER = 0xdaC630aE52b868FF0A180458eFb9ac88e7425114;
    
    // Deployment configuration for Polygon mainnet
    struct DeploymentConfig {
        uint8 tokenDecimals;
        uint256 minSaleAmount;
        bytes32 createContestSourceHash;
        bytes32 updateContestMarketsSourceHash;
        bytes32 donId;
        address protocolReceiver;
    }

    // Deployed contract addresses
    struct DeployedContracts {
        // Core
        address ospexCore;
        // USDC token
        address usdc;
        // Modules
        address treasuryModule;
        address oracleModule;
        address speculationModule;
        address positionModule;
        address secondaryMarketModule;
        address contestModule;
        address contributionModule;
        address leaderboardModule;
        address rulesModule;
        address moneylineScorerModule;
        address spreadScorerModule;
        address totalScorerModule;
        address matchingModule;
    }

    function run() external {
        // Deployer address from environment variable - REQUIRED for mainnet
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        
        console.log("Deploying to Polygon Mainnet with address:", deployer);
        console.log("Balance:", deployer.balance);

        // Configuration for Polygon mainnet deployment
        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6, // USDC decimals
            minSaleAmount: 1 * 10**6, // 1 USDC
            createContestSourceHash: 0xa93ea3137b5c35f5932abee7e8d261c3d5e85d2cbc3918dfc2e75170867c8463,
            updateContestMarketsSourceHash: 0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4, // hash for JavaScript source code that refreshes odds/lines on existing contests
            donId: bytes32("fun-polygon-mainnet-1"),
            protocolReceiver: FEE_RECEIVER
        });

        vm.startBroadcast(deployer);

        DeployedContracts memory contracts = deployContracts(config, deployer);
        
        registerModules(contracts);
        
        printDeploymentInfo(contracts);

        vm.stopBroadcast();
    }

    function deployContracts(
        DeploymentConfig memory config,
        address /* deployer */
    ) internal returns (DeployedContracts memory contracts) {
        console.log("\n=== Using Polygon Mainnet USDC ===");
        
        // Use native USDC on Polygon mainnet
        contracts.usdc = USDC_ADDRESS;
        console.log("Using USDC at:", contracts.usdc);

        console.log("\n=== Deploying Core Contract ===");
        
        // Deploy core contract
        contracts.ospexCore = address(new OspexCore());
        console.log("OspexCore deployed at:", contracts.ospexCore);

        console.log("\n=== Deploying Modules ===");

        // Deploy modules that only depend on OspexCore
        contracts.contributionModule = address(new ContributionModule(contracts.ospexCore));
        console.log("ContributionModule:", contracts.contributionModule);
        
        contracts.leaderboardModule = address(new LeaderboardModule(contracts.ospexCore));
        console.log("LeaderboardModule:", contracts.leaderboardModule);
        
        contracts.rulesModule = address(new RulesModule(contracts.ospexCore));
        console.log("RulesModule:", contracts.rulesModule);
        
        contracts.moneylineScorerModule = address(new MoneylineScorerModule(contracts.ospexCore));
        console.log("MoneylineScorerModule:", contracts.moneylineScorerModule);
        
        contracts.spreadScorerModule = address(new SpreadScorerModule(contracts.ospexCore));
        console.log("SpreadScorerModule:", contracts.spreadScorerModule);
        
        contracts.totalScorerModule = address(new TotalScorerModule(contracts.ospexCore));
        console.log("TotalScorerModule:", contracts.totalScorerModule);

        contracts.matchingModule = address(new MatchingModule(contracts.ospexCore));
        console.log("MatchingModule:", contracts.matchingModule);

        // Deploy modules with additional dependencies
        contracts.treasuryModule = address(new TreasuryModule(
            contracts.ospexCore,
            contracts.usdc,
            config.protocolReceiver
        ));
        console.log("TreasuryModule:", contracts.treasuryModule);

        contracts.speculationModule = address(new SpeculationModule(
            contracts.ospexCore,
            config.tokenDecimals
        ));
        console.log("SpeculationModule:", contracts.speculationModule);

        contracts.positionModule = address(new PositionModule(
            contracts.ospexCore,
            contracts.usdc
        ));
        console.log("PositionModule:", contracts.positionModule);

        contracts.secondaryMarketModule = address(new SecondaryMarketModule(
            contracts.ospexCore,
            contracts.usdc,
            config.minSaleAmount
        ));
        console.log("SecondaryMarketModule:", contracts.secondaryMarketModule);

        contracts.contestModule = address(new ContestModule(
            contracts.ospexCore,
            config.createContestSourceHash,
            config.updateContestMarketsSourceHash
        ));
        console.log("ContestModule:", contracts.contestModule);

        contracts.oracleModule = address(new OracleModule(
            contracts.ospexCore,
            FUNCTIONS_ROUTER,
            LINK_ADDRESS,
            config.donId
        ));
        console.log("OracleModule:", contracts.oracleModule);
        
        console.log("All modules deployed successfully");

        return contracts;
    }

    function registerModules(DeployedContracts memory contracts) internal {
        console.log("\n=== Registering Modules ===");
        
        OspexCore core = OspexCore(contracts.ospexCore);
        
        // Register all modules
        core.registerModule(keccak256("TREASURY_MODULE"), contracts.treasuryModule);
        core.registerModule(keccak256("ORACLE_MODULE"), contracts.oracleModule);
        core.registerModule(keccak256("SPECULATION_MODULE"), contracts.speculationModule);
        core.registerModule(keccak256("POSITION_MODULE"), contracts.positionModule);
        core.registerModule(keccak256("SECONDARY_MARKET_MODULE"), contracts.secondaryMarketModule);
        core.registerModule(keccak256("CONTEST_MODULE"), contracts.contestModule);
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), contracts.contributionModule);
        core.registerModule(keccak256("LEADERBOARD_MODULE"), contracts.leaderboardModule);
        core.registerModule(keccak256("RULES_MODULE"), contracts.rulesModule);
        core.registerModule(keccak256("MONEYLINE_SCORER"), contracts.moneylineScorerModule);
        core.registerModule(keccak256("SPREAD_SCORER"), contracts.spreadScorerModule);
        core.registerModule(keccak256("TOTAL_SCORER"), contracts.totalScorerModule);
        core.registerModule(keccak256("MATCHING_MODULE"), contracts.matchingModule);

        // Grant scorer role to scorer modules
        core.setScorerRole(contracts.moneylineScorerModule, true);
        core.setScorerRole(contracts.spreadScorerModule, true);
        core.setScorerRole(contracts.totalScorerModule, true);

        console.log("All modules registered and scorer roles granted");
    }

    function printDeploymentInfo(DeployedContracts memory contracts) internal pure {
        console.log("\n=== DEPLOYMENT SUMMARY FOR POLYGON MAINNET ===");
        console.log("Network: Polygon Mainnet (Chain ID: 137)");
        console.log("Using LINK at:", LINK_ADDRESS);
        console.log("Using Chainlink Functions Router at:", FUNCTIONS_ROUTER);
        console.log("Fee Receiver:", FEE_RECEIVER);
        
        console.log("\nCore Contract:");
        console.log("  OspexCore:", contracts.ospexCore);
        
        console.log("\nUSDC Token:", contracts.usdc);
        
        console.log("\nCore & Key Modules:");
        console.log("  OspexCore:", contracts.ospexCore);
        console.log("  TreasuryModule:", contracts.treasuryModule);
        console.log("  OracleModule:", contracts.oracleModule);
        console.log("  LeaderboardModule:", contracts.leaderboardModule);
        
        console.log("\n=== CRITICAL NEXT STEPS ===");
        console.log("1. Add OracleModule as consumer to Chainlink subscription ID 191");
        console.log("2. Transfer admin role to hardware wallet (two-step process)");
        console.log("3. Update frontend with new contract addresses");
        console.log("4. Update agent server with new contract addresses");
        console.log("5. Test with small positions before going live");
        
        console.log("\n=== CHAINLINK FUNCTIONS SETUP ===");
        console.log("Add this address as consumer to subscription 191:");
        console.log("OracleModule:", contracts.oracleModule);
        console.log("DON ID: fun-polygon-mainnet-1");
        console.log("Functions Router:", FUNCTIONS_ROUTER);
        
        console.log("\n=== FRONTEND CONFIGURATION ===");
        console.log("Update your frontend configuration with these addresses:");
        console.log("OSPEX_CORE_ADDRESS=", contracts.ospexCore);
        console.log("USDC_ADDRESS=", contracts.usdc);
        console.log("TREASURY_MODULE_ADDRESS=", contracts.treasuryModule);
        console.log("SPECULATION_MODULE_ADDRESS=", contracts.speculationModule);
        console.log("POSITION_MODULE_ADDRESS=", contracts.positionModule);
        console.log("CONTEST_MODULE_ADDRESS=", contracts.contestModule);
    }
}
