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
 * @title DeployAmoy
 * @notice Full deployment script for Ospex v2 on Polygon Amoy testnet
 * @dev Deploys OspexCore + all 13 modules, registers them, and grants roles.
 *
 *      To switch to mainnet: grep "MAINNET:" in this file and swap every annotated value.
 *      See the commented-out POLYGON MAINNET CONFIG block below.
 *
 *      EIP-712 note: MatchingModule inherits OpenZeppelin's EIP712("Ospex", "1"),
 *      which computes the domain separator using block.chainid at runtime.
 *      No hardcoded chain ID is needed — it will be 80002 on Amoy and 137 on mainnet automatically.
 */
contract DeployAmoy is Script {

    // =========================================================================
    // === AMOY TESTNET CONFIG (active) ========================================
    // =========================================================================

    // MAINNET: 0xb0897686c545045aFc77CF20eC7A532E3120E0F1
    address constant LINK_ADDRESS = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;

    // MAINNET: 0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10
    address constant FUNCTIONS_ROUTER = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De;

    // MAINNET: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 (native USDC, 6 decimals)
    address constant USDC_ADDRESS = 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8; // Mock USDC previously deployed on Amoy

    // MAINNET: 0xdaC630aE52b868FF0A180458eFb9ac88e7425114 (dedicated fee wallet)
    // On testnet we just send fees back to the deployer.
    // Set at runtime in run() so we can default to the deployer address.

    // MAINNET: bytes32("fun-polygon-mainnet-1")
    bytes32 constant DON_ID = bytes32("fun-polygon-amoy-1");

    // MAINNET: Chain ID 137. Amoy is 80002.
    // (Not used in the script — OZ EIP712 reads block.chainid at runtime.)

    // MAINNET: Subscription ID 191 (https://functions.chain.link/polygon/191)
    // Amoy subscription ID: 416 (https://functions.chain.link/polygon-amoy/416)
    // Subscription ID is NOT set in the contract — it's passed by callers of OracleModule.
    // After deploy, add OracleModule as a consumer on the subscription dashboard.

    // =========================================================================
    // === POLYGON MAINNET CONFIG (swap these in for production) ================
    // =========================================================================
    //
    // address constant LINK_ADDRESS       = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    // address constant FUNCTIONS_ROUTER   = 0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10;  // confirmed correct
    // address constant USDC_ADDRESS       = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    // bytes32 constant DON_ID             = bytes32("fun-polygon-mainnet-1");
    // address constant FEE_RECEIVER       = 0xdaC630aE52b868FF0A180458eFb9ac88e7425114;
    //
    // Source hashes — regenerate after any change to the Chainlink Functions JS source:
    // bytes32 constant CREATE_CONTEST_SOURCE_HASH          = <new hash>;
    // bytes32 constant UPDATE_CONTEST_MARKETS_SOURCE_HASH  = <new hash>;
    //
    // =========================================================================

    struct DeploymentConfig {
        uint8 tokenDecimals;
        uint256 minSaleAmount;
        bytes32 createContestSourceHash;
        bytes32 updateContestMarketsSourceHash;
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
        address contributionModule;
        address leaderboardModule;
        address rulesModule;
        address moneylineScorerModule;
        address spreadScorerModule;
        address totalScorerModule;
        address matchingModule;
    }

    function run() external {
        // Default to the known Amoy deployer; override with DEPLOYER_ADDRESS env var for other wallets.
        // MAINNET: set DEPLOYER_ADDRESS to the mainnet deployer wallet (hardware wallet recommended).
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));

        console.log("=== Ospex v2 Deployment ===");
        console.log("Network: Polygon Amoy Testnet (Chain ID 80002)"); // MAINNET: "Polygon Mainnet (Chain ID 137)"
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        require(deployer.balance > 0, "Deployer has zero balance - fund with POL before deploying");

        // MAINNET: update both source hashes after regenerating Chainlink Functions JS source.
        // These hashes are stored in ContestModule and validated by OracleModule when making
        // Chainlink Functions requests. If they don't match the uploaded source, oracle calls revert.
        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6,                   // USDC is always 6 decimals on both networks
            minSaleAmount: 1 * 10**6,           // 1 USDC — minimum listing on secondary market
            createContestSourceHash: 0x01c48e15068b68b7d5986d5013edd83a243ac31a761567e9db0e57b513c26c01,
            // MAINNET: 0xa93ea3137b5c35f5932abee7e8d261c3d5e85d2cbc3918dfc2e75170867c8463
            updateContestMarketsSourceHash: 0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4,
            // MAINNET: 0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4 (same hash if source unchanged)
            protocolReceiver: deployer           // MAINNET: 0xdaC630aE52b868FF0A180458eFb9ac88e7425114
        });

        vm.startBroadcast(deployer);

        // Step 1: Deploy all contracts
        DeployedContracts memory contracts = _deployContracts(config);

        // Step 2: Register every module with OspexCore and grant roles
        _registerModules(contracts);

        // Step 3: Verify the deployment is consistent
        _verifyDeployment(contracts);

        // Step 4: Print summary and next steps
        _printSummary(contracts, deployer);

        vm.stopBroadcast();
    }

    // =========================================================================
    // Deploy
    // =========================================================================

    function _deployContracts(
        DeploymentConfig memory config
    ) internal returns (DeployedContracts memory c) {
        console.log("\n--- Using existing USDC token ---");
        c.usdc = USDC_ADDRESS;
        console.log("USDC:", c.usdc);

        // ---- Core ----
        // OspexCore is the central registry and access-control hub.
        // The deployer gets DEFAULT_ADMIN_ROLE and MODULE_ADMIN_ROLE in the constructor.
        console.log("\n--- Deploying OspexCore ---");
        c.ospexCore = address(new OspexCore());
        console.log("OspexCore:", c.ospexCore);

        // ---- Modules that only need OspexCore ----
        console.log("\n--- Deploying simple modules ---");

        // ContributionModule: voluntary donation feature (currently dormant)
        c.contributionModule = address(new ContributionModule(c.ospexCore));
        console.log("ContributionModule:", c.contributionModule);

        // LeaderboardModule: competitions, ROI tracking, prize pools
        c.leaderboardModule = address(new LeaderboardModule(c.ospexCore));
        console.log("LeaderboardModule:", c.leaderboardModule);

        // RulesModule: eligibility rules for leaderboard competitions
        c.rulesModule = address(new RulesModule(c.ospexCore));
        console.log("RulesModule:", c.rulesModule);

        // Scorer modules: pure scoring logic — determine win side from scores + speculation params.
        // Each scorer handles a different bet type. All three get SCORER_ROLE after registration.
        c.moneylineScorerModule = address(new MoneylineScorerModule(c.ospexCore));
        console.log("MoneylineScorerModule:", c.moneylineScorerModule);

        c.spreadScorerModule = address(new SpreadScorerModule(c.ospexCore));
        console.log("SpreadScorerModule:", c.spreadScorerModule);

        c.totalScorerModule = address(new TotalScorerModule(c.ospexCore));
        console.log("TotalScorerModule:", c.totalScorerModule);

        // MatchingModule: off-chain signed-order matching via EIP-712.
        // OZ EIP712("Ospex", "1") computes domain separator from block.chainid — no config needed.
        c.matchingModule = address(new MatchingModule(c.ospexCore));
        console.log("MatchingModule:", c.matchingModule);

        // ---- Modules with additional constructor dependencies ----
        console.log("\n--- Deploying modules with dependencies ---");

        // TreasuryModule: collects protocol fees and holds leaderboard prize pools.
        // protocolReceiver gets the protocol's cut of all fees.
        c.treasuryModule = address(new TreasuryModule(
            c.ospexCore,
            c.usdc,
            config.protocolReceiver // MAINNET: dedicated fee wallet, not deployer
        ));
        console.log("TreasuryModule:", c.treasuryModule);

        // SpeculationModule: market lifecycle (create, lock, settle, void).
        c.speculationModule = address(new SpeculationModule(
            c.ospexCore,
            config.tokenDecimals
        ));
        console.log("SpeculationModule:", c.speculationModule);

        // PositionModule: escrows all USDC for user positions. Zero admin functions — funds
        // can only leave via user claims or user-initiated adjustments.
        c.positionModule = address(new PositionModule(
            c.ospexCore,
            c.usdc
        ));
        console.log("PositionModule:", c.positionModule);

        // SecondaryMarketModule: position trading. Requires MARKET_ROLE on OspexCore to
        // call transferPosition on PositionModule. Role is NOT granted here — enable manually
        // when ready to activate secondary market.
        c.secondaryMarketModule = address(new SecondaryMarketModule(
            c.ospexCore,
            c.usdc,
            config.minSaleAmount
        ));
        console.log("SecondaryMarketModule:", c.secondaryMarketModule);

        // ContestModule: sports event creation. Source hashes are validated by OracleModule
        // when making Chainlink Functions requests.
        c.contestModule = address(new ContestModule(
            c.ospexCore,
            config.createContestSourceHash,
            config.updateContestMarketsSourceHash
        ));
        console.log("ContestModule:", c.contestModule);

        // OracleModule: Chainlink Functions integration. Callers pass subscriptionId and pay LINK.
        // After deployment, add this address as a consumer on the Chainlink subscription dashboard.
        c.oracleModule = address(new OracleModule(
            c.ospexCore,
            FUNCTIONS_ROUTER,
            LINK_ADDRESS,
            DON_ID
        ));
        console.log("OracleModule:", c.oracleModule);

        console.log("\nAll 13 modules deployed.");
        return c;
    }

    // =========================================================================
    // Register + Roles
    // =========================================================================

    function _registerModules(DeployedContracts memory c) internal {
        console.log("\n--- Registering modules with OspexCore ---");

        OspexCore core = OspexCore(c.ospexCore);

        // Register every module. OspexCore stores module addresses by keccak256 key.
        // Other modules look up each other via core.getModule(keccak256("MODULE_NAME")).
        core.registerModule(keccak256("TREASURY_MODULE"), c.treasuryModule);
        core.registerModule(keccak256("ORACLE_MODULE"), c.oracleModule);
        core.registerModule(keccak256("SPECULATION_MODULE"), c.speculationModule);
        core.registerModule(keccak256("POSITION_MODULE"), c.positionModule);
        core.registerModule(keccak256("SECONDARY_MARKET_MODULE"), c.secondaryMarketModule);
        core.registerModule(keccak256("CONTEST_MODULE"), c.contestModule);
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), c.contributionModule);
        core.registerModule(keccak256("LEADERBOARD_MODULE"), c.leaderboardModule);
        core.registerModule(keccak256("RULES_MODULE"), c.rulesModule);
        core.registerModule(keccak256("MONEYLINE_SCORER_MODULE"), c.moneylineScorerModule);
        core.registerModule(keccak256("SPREAD_SCORER_MODULE"), c.spreadScorerModule);
        core.registerModule(keccak256("TOTAL_SCORER_MODULE"), c.totalScorerModule);
        core.registerModule(keccak256("MATCHING_MODULE"), c.matchingModule);

        console.log("All 13 modules registered.");

        // Grant SCORER_ROLE to each scorer module. PositionModule checks this role
        // when a scorer module calls scorePosition().
        console.log("\n--- Granting SCORER_ROLE to scorer modules ---");
        core.setScorerRole(c.moneylineScorerModule, true);
        core.setScorerRole(c.spreadScorerModule, true);
        core.setScorerRole(c.totalScorerModule, true);
        console.log("SCORER_ROLE granted to Moneyline, Spread, Total scorer modules.");

        // NOTE: MARKET_ROLE is intentionally NOT granted to SecondaryMarketModule here.
        // Enable secondary market manually: core.setMarketRole(secondaryMarketModule, true)
        // SCORE_MANAGER_ROLE and SPECULATION_MANAGER_ROLE are also not granted yet.
    }

    // =========================================================================
    // Verification
    // =========================================================================

    function _verifyDeployment(DeployedContracts memory c) internal view {
        console.log("\n--- Post-deploy verification ---");

        OspexCore core = OspexCore(c.ospexCore);

        // Verify each module is registered at the expected address
        _verifyModule(core, "TREASURY_MODULE", c.treasuryModule);
        _verifyModule(core, "ORACLE_MODULE", c.oracleModule);
        _verifyModule(core, "SPECULATION_MODULE", c.speculationModule);
        _verifyModule(core, "POSITION_MODULE", c.positionModule);
        _verifyModule(core, "SECONDARY_MARKET_MODULE", c.secondaryMarketModule);
        _verifyModule(core, "CONTEST_MODULE", c.contestModule);
        _verifyModule(core, "CONTRIBUTION_MODULE", c.contributionModule);
        _verifyModule(core, "LEADERBOARD_MODULE", c.leaderboardModule);
        _verifyModule(core, "RULES_MODULE", c.rulesModule);
        _verifyModule(core, "MONEYLINE_SCORER_MODULE", c.moneylineScorerModule);
        _verifyModule(core, "SPREAD_SCORER_MODULE", c.spreadScorerModule);
        _verifyModule(core, "TOTAL_SCORER_MODULE", c.totalScorerModule);
        _verifyModule(core, "MATCHING_MODULE", c.matchingModule);

        // Verify scorer roles
        require(core.hasScorerRole(c.moneylineScorerModule), "MoneylineScorerModule missing SCORER_ROLE");
        require(core.hasScorerRole(c.spreadScorerModule), "SpreadScorerModule missing SCORER_ROLE");
        require(core.hasScorerRole(c.totalScorerModule), "TotalScorerModule missing SCORER_ROLE");

        // Verify all modules report as registered
        require(core.isRegisteredModule(c.treasuryModule), "TreasuryModule not registered");
        require(core.isRegisteredModule(c.oracleModule), "OracleModule not registered");
        require(core.isRegisteredModule(c.positionModule), "PositionModule not registered");
        require(core.isRegisteredModule(c.matchingModule), "MatchingModule not registered");

        console.log("All 13 module registrations verified.");
        console.log("All 3 scorer role assignments verified.");
        console.log("Verification PASSED.");
    }

    function _verifyModule(OspexCore core, string memory name, address expected) internal view {
        address actual = core.getModule(keccak256(bytes(name)));
        require(
            actual == expected,
            string(abi.encodePacked(name, " registration mismatch"))
        );
    }

    // =========================================================================
    // Summary
    // =========================================================================

    function _printSummary(DeployedContracts memory c, address deployer) internal pure {
        console.log("\n============================================================");
        console.log("  DEPLOYMENT SUMMARY - Polygon Amoy Testnet (Chain ID 80002)");
        console.log("============================================================");
        // MAINNET: "Polygon Mainnet (Chain ID 137)"

        console.log("\nDeployer / Admin:", deployer);
        console.log("LINK:", LINK_ADDRESS);
        console.log("Functions Router:", FUNCTIONS_ROUTER);
        console.log("USDC:", c.usdc);

        console.log("\nCore:");
        console.log("  OspexCore:", c.ospexCore);

        console.log("\nModules:");
        console.log("  TreasuryModule:", c.treasuryModule);
        console.log("  OracleModule:", c.oracleModule);
        console.log("  SpeculationModule:", c.speculationModule);
        console.log("  PositionModule:", c.positionModule);
        console.log("  SecondaryMarketModule:", c.secondaryMarketModule);
        console.log("  ContestModule:", c.contestModule);
        console.log("  ContributionModule:", c.contributionModule);
        console.log("  LeaderboardModule:", c.leaderboardModule);
        console.log("  RulesModule:", c.rulesModule);
        console.log("  MoneylineScorerModule:", c.moneylineScorerModule);
        console.log("  SpreadScorerModule:", c.spreadScorerModule);
        console.log("  TotalScorerModule:", c.totalScorerModule);
        console.log("  MatchingModule:", c.matchingModule);

        console.log("\n============================================================");
        console.log("  CRITICAL NEXT STEPS");
        console.log("============================================================");
        console.log("1. Add OracleModule as consumer on Chainlink subscription 416");
        //           MAINNET: subscription 191
        console.log("   Dashboard: https://functions.chain.link/polygon-amoy/416");
        //           MAINNET: https://functions.chain.link/polygon/191
        console.log("2. Fund OracleModule with LINK for Chainlink Functions requests");
        console.log("3. Upload Chainlink Functions secrets (offchain-secrets) for Amoy");
        //           MAINNET: upload mainnet secrets
        console.log("4. Update ospex-fdb Firebase functions with new contract addresses");
        console.log("5. Update ospex-agent-server .env with new contract addresses");
        console.log("6. Update ospex-lovable frontend config with new contract addresses");
        console.log("7. Test contest creation -> speculation -> position -> scoring flow");

        console.log("\n============================================================");
        console.log("  FRONTEND / AGENT SERVER CONFIG");
        console.log("============================================================");
        console.log("OSPEX_CORE_ADDRESS=", c.ospexCore);
        console.log("USDC_ADDRESS=", c.usdc);
        console.log("TREASURY_MODULE_ADDRESS=", c.treasuryModule);
        console.log("ORACLE_MODULE_ADDRESS=", c.oracleModule);
        console.log("SPECULATION_MODULE_ADDRESS=", c.speculationModule);
        console.log("POSITION_MODULE_ADDRESS=", c.positionModule);
        console.log("SECONDARY_MARKET_MODULE_ADDRESS=", c.secondaryMarketModule);
        console.log("CONTEST_MODULE_ADDRESS=", c.contestModule);
        console.log("MATCHING_MODULE_ADDRESS=", c.matchingModule);
    }
}
