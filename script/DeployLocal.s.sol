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

// Mock contracts for local testing
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockLinkToken.sol";
import "../test/mocks/MockFunctionsRouter.sol";

/**
 * @title DeployLocal
 * @notice Deployment script for Ospex protocol on local anvil chain
 * @dev Deploys all contracts including mocks for testing
 */
contract DeployLocal is Script {
    // Deployment configuration
    struct DeploymentConfig {
        uint8 tokenDecimals;
        uint256 minSaleAmount;
        uint256 maxSaleAmount;
        bytes32 createContestSourceHash;
        bytes32 donId;
        address protocolReceiver;
    }

    // Deployed contract addresses
    struct DeployedContracts {
        // Core
        address ospexCore;
        // Mock tokens
        address mockToken;
        address mockLinkToken;
        address mockFunctionsRouter;
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
    }

    function run() external {
        // ⚠️  WARNING: ONLY FOR LOCAL ANVIL DEPLOYMENT! ⚠️
        // For testnet/mainnet deployment, use --private-key flag or --interactive instead
        // This is Anvil's default account #0 private key
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying with address:", deployer);
        console.log("Balance:", deployer.balance);

        // Configuration for local deployment
        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6, // USDC-like decimals
            minSaleAmount: 1 * 10**6, // 1 USDC
            maxSaleAmount: 100_000 * 10**6, // 100,000 USDC
            createContestSourceHash: keccak256("test_source_hash"),
            donId: bytes32("test_don_id"),
            protocolReceiver: deployer // Use deployer as protocol receiver for testing
        });

        vm.startBroadcast(deployerPrivateKey);

        DeployedContracts memory contracts = deployContracts(config, deployer);
        
        registerModules(contracts);
        
        printDeploymentInfo(contracts);
        
        calculateDeploymentCosts();

        vm.stopBroadcast();
    }

    function deployContracts(
        DeploymentConfig memory config,
        address deployer
    ) internal returns (DeployedContracts memory contracts) {
        console.log("\n=== Deploying Mock Tokens ===");
        
        // Deploy mock tokens first
        contracts.mockToken = address(new MockERC20());
        console.log("MockERC20 deployed at:", contracts.mockToken);

        contracts.mockLinkToken = address(new MockLinkToken());
        console.log("MockLinkToken deployed at:", contracts.mockLinkToken);

        contracts.mockFunctionsRouter = address(new MockFunctionsRouter(contracts.mockLinkToken));
        console.log("MockFunctionsRouter deployed at:", contracts.mockFunctionsRouter);

        console.log("\n=== Deploying Core Contract ===");
        
        // Deploy core contract
        contracts.ospexCore = address(new OspexCore());
        console.log("OspexCore deployed at:", contracts.ospexCore);

        console.log("\n=== Deploying Modules ===");

        // Deploy modules that only depend on OspexCore
        contracts.contributionModule = address(new ContributionModule(contracts.ospexCore));
        console.log("ContributionModule deployed at:", contracts.contributionModule);

        contracts.leaderboardModule = address(new LeaderboardModule(contracts.ospexCore));
        console.log("LeaderboardModule deployed at:", contracts.leaderboardModule);

        contracts.rulesModule = address(new RulesModule(contracts.ospexCore));
        console.log("RulesModule deployed at:", contracts.rulesModule);

        contracts.moneylineScorerModule = address(new MoneylineScorerModule(contracts.ospexCore));
        console.log("MoneylineScorerModule deployed at:", contracts.moneylineScorerModule);

        contracts.spreadScorerModule = address(new SpreadScorerModule(contracts.ospexCore));
        console.log("SpreadScorerModule deployed at:", contracts.spreadScorerModule);

        contracts.totalScorerModule = address(new TotalScorerModule(contracts.ospexCore));
        console.log("TotalScorerModule deployed at:", contracts.totalScorerModule);

        // Deploy modules with additional dependencies
        contracts.treasuryModule = address(new TreasuryModule(
            contracts.ospexCore,
            contracts.mockToken,
            config.protocolReceiver
        ));
        console.log("TreasuryModule deployed at:", contracts.treasuryModule);

        contracts.speculationModule = address(new SpeculationModule(
            contracts.ospexCore,
            config.tokenDecimals
        ));
        console.log("SpeculationModule deployed at:", contracts.speculationModule);

        contracts.positionModule = address(new PositionModule(
            contracts.ospexCore,
            contracts.mockToken
        ));
        console.log("PositionModule deployed at:", contracts.positionModule);

        contracts.secondaryMarketModule = address(new SecondaryMarketModule(
            contracts.ospexCore,
            contracts.mockToken,
            config.minSaleAmount,
            config.maxSaleAmount
        ));
        console.log("SecondaryMarketModule deployed at:", contracts.secondaryMarketModule);

        contracts.contestModule = address(new ContestModule(
            contracts.ospexCore,
            config.createContestSourceHash
        ));
        console.log("ContestModule deployed at:", contracts.contestModule);

        contracts.oracleModule = address(new OracleModule(
            contracts.ospexCore,
            contracts.mockFunctionsRouter,
            contracts.mockLinkToken,
            config.donId
        ));
        console.log("OracleModule deployed at:", contracts.oracleModule);

        return contracts;
    }

    function registerModules(DeployedContracts memory contracts) internal {
        console.log("\n=== Registering Modules ===");
        
        OspexCore core = OspexCore(contracts.ospexCore);
        
        // Register all modules
        core.registerModule(keccak256("TREASURY_MODULE"), contracts.treasuryModule);
        console.log("Registered TreasuryModule");

        core.registerModule(keccak256("ORACLE_MODULE"), contracts.oracleModule);
        console.log("Registered OracleModule");

        core.registerModule(keccak256("SPECULATION_MODULE"), contracts.speculationModule);
        console.log("Registered SpeculationModule");

        core.registerModule(keccak256("POSITION_MODULE"), contracts.positionModule);
        console.log("Registered PositionModule");

        core.registerModule(keccak256("SECONDARY_MARKET_MODULE"), contracts.secondaryMarketModule);
        console.log("Registered SecondaryMarketModule");

        core.registerModule(keccak256("CONTEST_MODULE"), contracts.contestModule);
        console.log("Registered ContestModule");

        core.registerModule(keccak256("CONTRIBUTION_MODULE"), contracts.contributionModule);
        console.log("Registered ContributionModule");

        core.registerModule(keccak256("LEADERBOARD_MODULE"), contracts.leaderboardModule);
        console.log("Registered LeaderboardModule");

        core.registerModule(keccak256("RULES_MODULE"), contracts.rulesModule);
        console.log("Registered RulesModule");

        core.registerModule(keccak256("MONEYLINE_SCORER"), contracts.moneylineScorerModule);
        console.log("Registered MoneylineScorerModule");

        core.registerModule(keccak256("SPREAD_SCORER"), contracts.spreadScorerModule);
        console.log("Registered SpreadScorerModule");

        core.registerModule(keccak256("TOTAL_SCORER"), contracts.totalScorerModule);
        console.log("Registered TotalScorerModule");
    }

    function printDeploymentInfo(DeployedContracts memory contracts) internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Core Contract:");
        console.log("  OspexCore:", contracts.ospexCore);
        
        console.log("\nMock Tokens:");
        console.log("  MockERC20:", contracts.mockToken);
        console.log("  MockLinkToken:", contracts.mockLinkToken);
        console.log("  MockFunctionsRouter:", contracts.mockFunctionsRouter);
        
        console.log("\nModules:");
        console.log("  TreasuryModule:", contracts.treasuryModule);
        console.log("  OracleModule:", contracts.oracleModule);
        console.log("  SpeculationModule:", contracts.speculationModule);
        console.log("  PositionModule:", contracts.positionModule);
        console.log("  SecondaryMarketModule:", contracts.secondaryMarketModule);
        console.log("  ContestModule:", contracts.contestModule);
        console.log("  ContributionModule:", contracts.contributionModule);
        console.log("  LeaderboardModule:", contracts.leaderboardModule);
        console.log("  RulesModule:", contracts.rulesModule);
        console.log("  MoneylineScorerModule:", contracts.moneylineScorerModule);
        console.log("  SpreadScorerModule:", contracts.spreadScorerModule);
        console.log("  TotalScorerModule:", contracts.totalScorerModule);
    }

    function calculateDeploymentCosts() internal view {
        console.log("\n=== DEPLOYMENT COST ANALYSIS ===");
        console.log("Gas used will be calculated after deployment completes.");
        console.log("Run with --gas-report flag to see detailed gas usage.");
        console.log("\nTo estimate costs on different networks:");
        console.log("- Polygon: Multiply gas used by ~30 gwei");
        console.log("- Arbitrum: Multiply gas used by ~0.1 gwei");
        console.log("- Optimism: Multiply gas used by ~0.001 gwei");
        console.log("- Ethereum: Multiply gas used by ~20 gwei");
    }
} 