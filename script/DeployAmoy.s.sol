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

// Using existing USDC contract instead of deploying mock token

/**
 * @title DeployAmoy
 * @notice Deployment script for Ospex protocol on Polygon Amoy testnet
 * @dev Deploys all contracts with Amoy-specific configuration
 */
contract DeployAmoy is Script {
    // Amoy testnet-specific addresses
    address constant LINK_ADDRESS = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    address constant FUNCTIONS_ROUTER = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De;
    
    // Deployment configuration for Amoy
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
        // Existing USDC token for testnet
        address mockUSDC;
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
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        console.log("Deploying to Polygon Amoy testnet with address:", deployer);
        console.log("Balance:", deployer.balance);

        // Configuration for Amoy deployment
        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6, // USDC-like decimals
            minSaleAmount: 1 * 10**6, // 1 USDC
            createContestSourceHash: 0x74533c92d0380a7aa2c8d597453cdcea7350344971be3df02623fe339002f9ab,
            updateContestMarketsSourceHash: 0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4,
            donId: bytes32("fun-polygon-amoy-1"),
            protocolReceiver: deployer // Use deployer as protocol receiver for testing
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
        console.log("\n=== Using Existing USDC Token ===");
        
        // Use existing USDC contract instead of deploying new one
        contracts.mockUSDC = 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8;
        console.log("Using existing USDC at:", contracts.mockUSDC);

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
            contracts.mockUSDC,
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
            contracts.mockUSDC
        ));
        console.log("PositionModule:", contracts.positionModule);

        contracts.secondaryMarketModule = address(new SecondaryMarketModule(
            contracts.ospexCore,
            contracts.mockUSDC,
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
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), contracts.moneylineScorerModule);
        core.registerModule(keccak256("SPREAD_SCORER_MODULE"), contracts.spreadScorerModule);
        core.registerModule(keccak256("TOTAL_SCORER_MODULE"), contracts.totalScorerModule);
        core.registerModule(keccak256("MATCHING_MODULE"), contracts.matchingModule);

        // Grant scorer role to scorer modules
        core.setScorerRole(contracts.moneylineScorerModule, true);
        core.setScorerRole(contracts.spreadScorerModule, true);
        core.setScorerRole(contracts.totalScorerModule, true);

        console.log("All modules registered and scorer roles granted");
    }

    function printDeploymentInfo(DeployedContracts memory contracts) internal pure {
        console.log("\n=== DEPLOYMENT SUMMARY FOR POLYGON AMOY ===");
        console.log("Network: Polygon Amoy Testnet");
        console.log("Using LINK at:", LINK_ADDRESS);
        console.log("Using Chainlink Functions Router at:", FUNCTIONS_ROUTER);
        
        console.log("\nCore Contract:");
        console.log("  OspexCore:", contracts.ospexCore);
        
        console.log("\nExisting USDC Token:", contracts.mockUSDC);
        
        console.log("\nCore & Key Modules:");
        console.log("  OspexCore:", contracts.ospexCore);
        console.log("  TreasuryModule:", contracts.treasuryModule);
        console.log("  OracleModule:", contracts.oracleModule);
        console.log("  LeaderboardModule:", contracts.leaderboardModule);
        
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Fund the OracleModule with LINK tokens for Chainlink Functions");
        console.log("2. Test contest creation through the frontend");
        console.log("3. Test speculation creation and position management");
        console.log("4. Test scoring functionality with real contest data");
        console.log("5. Test secondary market functionality");
        
        console.log("\n=== CHAINLINK FUNCTIONS SETUP ===");
        console.log("Send LINK tokens to OracleModule:", contracts.oracleModule);
        console.log("DON ID:", string(abi.encodePacked(bytes32("fun-polygon-amoy-1"))));
        console.log("Functions Router:", FUNCTIONS_ROUTER);
        
        console.log("\n=== FRONTEND CONFIGURATION ===");
        console.log("Update your frontend configuration with these addresses:");
        console.log("OSPEX_CORE_ADDRESS=", contracts.ospexCore);
        console.log("MOCK_USDC_ADDRESS=", contracts.mockUSDC);
        console.log("TREASURY_MODULE_ADDRESS=", contracts.treasuryModule);
        console.log("SPECULATION_MODULE_ADDRESS=", contracts.speculationModule);
        console.log("POSITION_MODULE_ADDRESS=", contracts.positionModule);
        console.log("CONTEST_MODULE_ADDRESS=", contracts.contestModule);
    }
} 