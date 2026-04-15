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
import "../src/modules/LeaderboardModule.sol";
import "../src/modules/RulesModule.sol";
import "../src/modules/MoneylineScorerModule.sol";
import "../src/modules/SpreadScorerModule.sol";
import "../src/modules/TotalScorerModule.sol";
import "../src/modules/MatchingModule.sol";

// Mock contracts for local testing
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockLinkToken.sol";
import "../test/mocks/MockFunctionsRouter.sol";

/**
 * @title DeployLocal
 * @notice Deployment script for Ospex protocol on local anvil chain
 * @dev Deploys all contracts using bootstrap+finalize pattern (zero-admin)
 */
contract DeployLocal is Script {
    // Deployment configuration
    struct DeploymentConfig {
        uint8 tokenDecimals;
        uint32 voidCooldown;
        uint256 minSpeculationAmount;
        uint256 contestCreationFee;
        uint256 speculationCreationFee;
        uint256 leaderboardCreationFee;
        bytes32 donId;
        uint256 linkDenominator;
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
        address leaderboardModule;
        address rulesModule;
        address moneylineScorerModule;
        address spreadScorerModule;
        address totalScorerModule;
        address matchingModule;
    }

    function run() external {
        // WARNING: ONLY FOR LOCAL ANVIL DEPLOYMENT!
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying with address:", deployer);
        console.log("Balance:", deployer.balance);

        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6,
            voidCooldown: 3 days,
            minSpeculationAmount: 1 * 10**6, // 1 USDC
            contestCreationFee: 1_000_000, // 1.00 USDC
            speculationCreationFee: 500_000, // 0.50 USDC (split between maker and taker)
            leaderboardCreationFee: 250_000, // 0.25 USDC
            donId: bytes32("test_don_id"),
            linkDenominator: 10**18,
            protocolReceiver: deployer
        });

        vm.startBroadcast(deployerPrivateKey);

        DeployedContracts memory contracts = deployContracts(config);

        bootstrapAndFinalize(contracts);

        printDeploymentInfo(contracts);

        vm.stopBroadcast();
    }

    function deployContracts(
        DeploymentConfig memory config
    ) internal returns (DeployedContracts memory contracts) {
        console.log("\n=== Deploying Mock Tokens ===");

        contracts.mockToken = address(new MockERC20());
        console.log("MockERC20 deployed at:", contracts.mockToken);

        contracts.mockLinkToken = address(new MockLinkToken());
        console.log("MockLinkToken deployed at:", contracts.mockLinkToken);

        contracts.mockFunctionsRouter = address(new MockFunctionsRouter(contracts.mockLinkToken));
        console.log("MockFunctionsRouter deployed at:", contracts.mockFunctionsRouter);

        console.log("\n=== Deploying Core Contract ===");

        contracts.ospexCore = address(new OspexCore());
        console.log("OspexCore deployed at:", contracts.ospexCore);

        console.log("\n=== Deploying Modules ===");

        // Modules with only OspexCore dependency
        contracts.contestModule = address(new ContestModule(contracts.ospexCore));
        console.log("ContestModule deployed at:", contracts.contestModule);

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

        contracts.matchingModule = address(new MatchingModule(contracts.ospexCore));
        console.log("MatchingModule deployed at:", contracts.matchingModule);

        // Modules with additional dependencies
        contracts.treasuryModule = address(new TreasuryModule(
            contracts.ospexCore,
            contracts.mockToken,
            config.protocolReceiver,
            config.contestCreationFee,
            config.speculationCreationFee,
            config.leaderboardCreationFee
        ));
        console.log("TreasuryModule deployed at:", contracts.treasuryModule);

        contracts.speculationModule = address(new SpeculationModule(
            contracts.ospexCore,
            config.tokenDecimals,
            config.voidCooldown,
            config.minSpeculationAmount
        ));
        console.log("SpeculationModule deployed at:", contracts.speculationModule);

        contracts.positionModule = address(new PositionModule(
            contracts.ospexCore,
            contracts.mockToken
        ));
        console.log("PositionModule deployed at:", contracts.positionModule);

        contracts.secondaryMarketModule = address(new SecondaryMarketModule(
            contracts.ospexCore,
            contracts.mockToken
        ));
        console.log("SecondaryMarketModule deployed at:", contracts.secondaryMarketModule);

        // TODO: Replace address(0x1) with the real approved signer address before production deploy
        contracts.oracleModule = address(new OracleModule(
            contracts.ospexCore,
            contracts.mockFunctionsRouter,
            contracts.mockLinkToken,
            config.donId,
            config.linkDenominator,
            address(0x1)
        ));
        console.log("OracleModule deployed at:", contracts.oracleModule);

        return contracts;
    }

    function bootstrapAndFinalize(DeployedContracts memory contracts) internal {
        console.log("\n=== Bootstrap + Finalize ===");

        OspexCore core = OspexCore(contracts.ospexCore);

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);

        types[0] = core.CONTEST_MODULE();           addrs[0] = contracts.contestModule;
        types[1] = core.SPECULATION_MODULE();        addrs[1] = contracts.speculationModule;
        types[2] = core.POSITION_MODULE();           addrs[2] = contracts.positionModule;
        types[3] = core.MATCHING_MODULE();           addrs[3] = contracts.matchingModule;
        types[4] = core.ORACLE_MODULE();             addrs[4] = contracts.oracleModule;
        types[5] = core.TREASURY_MODULE();           addrs[5] = contracts.treasuryModule;
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = contracts.leaderboardModule;
        types[7] = core.RULES_MODULE();              addrs[7] = contracts.rulesModule;
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = contracts.secondaryMarketModule;
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = contracts.moneylineScorerModule;
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = contracts.spreadScorerModule;
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = contracts.totalScorerModule;

        core.bootstrapModules(types, addrs);
        console.log("All 12 modules bootstrapped.");

        core.finalize();
        console.log("Protocol finalized. No admin key remains.");
    }

    function printDeploymentInfo(DeployedContracts memory contracts) internal pure {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Core Contract:");
        console.log("  OspexCore:", contracts.ospexCore);

        console.log("\nMock Tokens:");
        console.log("  MockERC20:", contracts.mockToken);
        console.log("  MockLinkToken:", contracts.mockLinkToken);
        console.log("  MockFunctionsRouter:", contracts.mockFunctionsRouter);

        console.log("\nModules (12):");
        console.log("  ContestModule:", contracts.contestModule);
        console.log("  SpeculationModule:", contracts.speculationModule);
        console.log("  PositionModule:", contracts.positionModule);
        console.log("  MatchingModule:", contracts.matchingModule);
        console.log("  OracleModule:", contracts.oracleModule);
        console.log("  TreasuryModule:", contracts.treasuryModule);
        console.log("  LeaderboardModule:", contracts.leaderboardModule);
        console.log("  RulesModule:", contracts.rulesModule);
        console.log("  SecondaryMarketModule:", contracts.secondaryMarketModule);
        console.log("  MoneylineScorerModule:", contracts.moneylineScorerModule);
        console.log("  SpreadScorerModule:", contracts.spreadScorerModule);
        console.log("  TotalScorerModule:", contracts.totalScorerModule);
    }
}
