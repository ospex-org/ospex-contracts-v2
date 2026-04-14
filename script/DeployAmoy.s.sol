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

/**
 * @title DeployAmoy
 * @notice Full deployment script for Ospex on Polygon Amoy testnet
 * @dev Uses bootstrap+finalize pattern — no admin key after deployment.
 */
contract DeployAmoy is Script {

    // =========================================================================
    // === AMOY TESTNET CONFIG ================================================
    // =========================================================================

    address constant LINK_ADDRESS = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    address constant FUNCTIONS_ROUTER = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De;
    address constant USDC_ADDRESS = 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8;
    bytes32 constant DON_ID = bytes32("fun-polygon-amoy-1");
    uint256 constant LINK_DENOMINATOR = 10**18;

    struct DeploymentConfig {
        uint8 tokenDecimals;
        uint32 voidCooldown;
        uint256 minSpeculationAmount;
        uint256 contestCreationFee;
        uint256 speculationCreationFee;
        uint256 leaderboardCreationFee;
        address protocolReceiver;
    }

    struct DeployedContracts {
        address ospexCore;
        address usdc;
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
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));

        console.log("=== Ospex Deployment (Zero-Admin) ===");
        console.log("Network: Polygon Amoy Testnet (Chain ID 80002)");
        console.log("Deployer:", deployer);
        require(deployer.balance > 0, "Deployer has zero balance");

        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6,
            voidCooldown: 3 days,
            minSpeculationAmount: 1 * 10**6, // 1 USDC
            contestCreationFee: 1_000_000, // 1.00 USDC
            speculationCreationFee: 500_000, // 0.50 USDC (split between maker and taker)
            leaderboardCreationFee: 250_000, // 0.25 USDC
            protocolReceiver: deployer
        });

        vm.startBroadcast(deployer);

        DeployedContracts memory contracts = _deployContracts(config);
        _bootstrapAndFinalize(contracts);
        _verifyDeployment(contracts);
        _printSummary(contracts, deployer);

        vm.stopBroadcast();
    }

    function _deployContracts(
        DeploymentConfig memory config
    ) internal returns (DeployedContracts memory c) {
        c.usdc = USDC_ADDRESS;

        console.log("\n--- Deploying OspexCore ---");
        c.ospexCore = address(new OspexCore());
        console.log("OspexCore:", c.ospexCore);

        console.log("\n--- Deploying Modules ---");

        c.contestModule = address(new ContestModule(c.ospexCore));
        console.log("ContestModule:", c.contestModule);

        c.leaderboardModule = address(new LeaderboardModule(c.ospexCore));
        console.log("LeaderboardModule:", c.leaderboardModule);

        c.rulesModule = address(new RulesModule(c.ospexCore));
        console.log("RulesModule:", c.rulesModule);

        c.moneylineScorerModule = address(new MoneylineScorerModule(c.ospexCore));
        console.log("MoneylineScorerModule:", c.moneylineScorerModule);

        c.spreadScorerModule = address(new SpreadScorerModule(c.ospexCore));
        console.log("SpreadScorerModule:", c.spreadScorerModule);

        c.totalScorerModule = address(new TotalScorerModule(c.ospexCore));
        console.log("TotalScorerModule:", c.totalScorerModule);

        c.matchingModule = address(new MatchingModule(c.ospexCore));
        console.log("MatchingModule:", c.matchingModule);

        c.treasuryModule = address(new TreasuryModule(
            c.ospexCore, c.usdc, config.protocolReceiver,
            config.contestCreationFee, config.speculationCreationFee, config.leaderboardCreationFee
        ));
        console.log("TreasuryModule:", c.treasuryModule);

        c.speculationModule = address(new SpeculationModule(
            c.ospexCore, config.tokenDecimals, config.voidCooldown, config.minSpeculationAmount
        ));
        console.log("SpeculationModule:", c.speculationModule);

        c.positionModule = address(new PositionModule(c.ospexCore, c.usdc));
        console.log("PositionModule:", c.positionModule);

        c.secondaryMarketModule = address(new SecondaryMarketModule(c.ospexCore, c.usdc));
        console.log("SecondaryMarketModule:", c.secondaryMarketModule);

        c.oracleModule = address(new OracleModule(
            c.ospexCore, FUNCTIONS_ROUTER, LINK_ADDRESS, DON_ID, LINK_DENOMINATOR
        ));
        console.log("OracleModule:", c.oracleModule);

        console.log("\nAll 12 modules deployed.");
        return c;
    }

    function _bootstrapAndFinalize(DeployedContracts memory c) internal {
        console.log("\n--- Bootstrap + Finalize ---");
        OspexCore core = OspexCore(c.ospexCore);

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = c.contestModule;
        types[1] = core.SPECULATION_MODULE();        addrs[1] = c.speculationModule;
        types[2] = core.POSITION_MODULE();           addrs[2] = c.positionModule;
        types[3] = core.MATCHING_MODULE();           addrs[3] = c.matchingModule;
        types[4] = core.ORACLE_MODULE();             addrs[4] = c.oracleModule;
        types[5] = core.TREASURY_MODULE();           addrs[5] = c.treasuryModule;
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = c.leaderboardModule;
        types[7] = core.RULES_MODULE();              addrs[7] = c.rulesModule;
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = c.secondaryMarketModule;
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = c.moneylineScorerModule;
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = c.spreadScorerModule;
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = c.totalScorerModule;

        core.bootstrapModules(types, addrs);
        console.log("All 12 modules bootstrapped.");

        core.finalize();
        console.log("Protocol FINALIZED. No admin key remains.");
    }

    function _verifyDeployment(DeployedContracts memory c) internal view {
        console.log("\n--- Post-deploy verification ---");
        OspexCore core = OspexCore(c.ospexCore);

        require(core.s_finalized(), "Protocol not finalized!");
        require(core.getModule(core.CONTEST_MODULE()) == c.contestModule, "ContestModule mismatch");
        require(core.getModule(core.TREASURY_MODULE()) == c.treasuryModule, "TreasuryModule mismatch");
        require(core.getModule(core.ORACLE_MODULE()) == c.oracleModule, "OracleModule mismatch");
        require(core.isRegisteredModule(c.positionModule), "PositionModule not registered");
        require(core.isRegisteredModule(c.matchingModule), "MatchingModule not registered");
        require(core.isApprovedScorer(c.moneylineScorerModule), "MoneylineScorer not approved");
        require(core.isApprovedScorer(c.spreadScorerModule), "SpreadScorer not approved");
        require(core.isApprovedScorer(c.totalScorerModule), "TotalScorer not approved");
        require(core.isSecondaryMarket(c.secondaryMarketModule), "SecondaryMarket not recognized");

        console.log("Verification PASSED.");
    }

    function _printSummary(DeployedContracts memory c, address deployer) internal pure {
        console.log("\n============================================================");
        console.log("  DEPLOYMENT SUMMARY - Polygon Amoy (Zero-Admin)");
        console.log("============================================================");
        console.log("\nDeployer:", deployer);
        console.log("USDC:", c.usdc);
        console.log("\nCore:");
        console.log("  OspexCore:", c.ospexCore);
        console.log("\nModules (12):");
        console.log("  ContestModule:", c.contestModule);
        console.log("  SpeculationModule:", c.speculationModule);
        console.log("  PositionModule:", c.positionModule);
        console.log("  MatchingModule:", c.matchingModule);
        console.log("  OracleModule:", c.oracleModule);
        console.log("  TreasuryModule:", c.treasuryModule);
        console.log("  LeaderboardModule:", c.leaderboardModule);
        console.log("  RulesModule:", c.rulesModule);
        console.log("  SecondaryMarketModule:", c.secondaryMarketModule);
        console.log("  MoneylineScorerModule:", c.moneylineScorerModule);
        console.log("  SpreadScorerModule:", c.spreadScorerModule);
        console.log("  TotalScorerModule:", c.totalScorerModule);
        console.log("\n============================================================");
        console.log("  CRITICAL NEXT STEPS");
        console.log("============================================================");
        console.log("1. Add OracleModule as consumer on Chainlink subscription");
        console.log("2. Fund OracleModule with LINK");
        console.log("3. Upload Chainlink Functions secrets");
        console.log("4. Update ospex-fdb, ospex-agent-server, ospex-lovable configs");
        console.log("5. Test full flow: contest -> speculation -> position -> scoring");
    }
}
