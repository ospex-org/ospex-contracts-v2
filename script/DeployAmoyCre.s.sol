// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/core/OspexCore.sol";

import "../src/modules/TreasuryModule.sol";
import "../src/modules/CreOracleReceiver.sol";
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
 * @title DeployAmoyCre
 * @notice Full Ospex deployment for Polygon Amoy with the Chainlink CRE oracle receiver in the
 *         CRE_ORACLE_RECEIVER slot (replaces the Functions-based OracleModule). Bootstrap+finalize, so
 *         no admin key remains — the exact zero-admin shape that redeploys to immutable mainnet.
 * @dev The CRE receiver's constructor takes (ospexCore, forwarder, workflowOwner, workflowName) — no
 *      router / LINK / DON id / subscription / approved-signer / fee / sunset; the workflow id is
 *      deliberately NOT pinned (CRE rotates it). There is no oracle-request fee and no on-chain rate
 *      limiting — griefing of the permissionless requests is bounded off-chain by the CRE platform's
 *      per-workflow log-trigger rate limit + the workflow owner's funded CRE balance.
 *
 *      Env inputs (with defaults):
 *        DEPLOYER_ADDRESS       — the Amoy-funded EOA that broadcasts (gas payer).
 *        KEYSTONE_FORWARDER     — Amoy production KeystoneForwarder (default below, from the CRE
 *                                 forwarder directory + `cre workflow supported-chains`).
 *        WORKFLOW_OWNER         — the CRE workflow owner ADDRESS (the report-metadata owner onReport
 *                                 enforces): an EOA for trial/Amoy deploys, or the OspexCreTimelock
 *                                 per-action timelock for governed deploys. MUST be set to the real value.
 *        WORKFLOW_NAME          — the CRE-derived bytes10 the DON stamps into report metadata (a HASH
 *                                 of the name, NOT plaintext bytes10 — see the note at the env read
 *                                 below). 0 = not enforced (the Amoy trials run unenforced).
 */
contract DeployAmoyCre is Script {
    // Amoy production KeystoneForwarder — confirmed via the CRE forwarder directory and
    // `cre workflow supported-chains` (tenant-scoped) on 2026-06-22.
    address constant DEFAULT_KEYSTONE_FORWARDER = 0x76c9cf548b4179F8901cda1f8623568b58215E62;
    address constant USDC_ADDRESS = 0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8;

    struct DeploymentConfig {
        uint32 voidCooldown;
        uint256 contestCreationFee;
        uint256 speculationCreationFee;
        uint256 leaderboardCreationFee;
        address protocolReceiver;
        address forwarder;
        address workflowOwner;
        bytes10 workflowName;
    }

    struct DeployedContracts {
        address ospexCore;
        address usdc;
        address treasuryModule;
        address oracleModule; // CreOracleReceiver
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
        // Fail before any broadcast if pointed at the wrong network — this is a one-shot zero-admin
        // deployment that finalizes the protocol (Polygon Amoy = 80002; a mainnet CRE deploy script
        // for chain 137 is still to be authored).
        require(block.chainid == 80002, "wrong chain");

        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "set DEPLOYER_ADDRESS");

        address forwarder = vm.envOr("KEYSTONE_FORWARDER", DEFAULT_KEYSTONE_FORWARDER);
        require(forwarder != address(0), "set KEYSTONE_FORWARDER"); // preflight: receiver also reverts on zero
        address workflowOwner = vm.envOr("WORKFLOW_OWNER", address(0));
        require(workflowOwner != address(0), "set WORKFLOW_OWNER (CRE workflow owner address)");
        // WORKFLOW_NAME, when enforced, MUST be the bytes10 the CRE engine stamps into report metadata:
        // SHA256(name) -> first 10 hex chars -> those 10 ASCII chars as bytes. This is a HASH of the name,
        // NOT bytes10 of the plaintext (e.g. "my_workflow" -> 0x62373666336165316465). The receiver
        // compares i_workflowName against this metadata value verbatim, so passing plaintext bytes here
        // would make onReport reject every report. 0 (default) = name not enforced (owner check only).
        bytes10 workflowName = bytes10(vm.envOr("WORKFLOW_NAME", bytes32(0)));

        console.log("=== Ospex CRE Deployment (Zero-Admin) ===");
        console.log("Network: Polygon Amoy Testnet (Chain ID 80002)");
        console.log("Deployer:", deployer);
        console.log("KeystoneForwarder:", forwarder);
        console.log("Workflow owner:", workflowOwner);
        console.log("Workflow name (bytes10):", vm.toString(abi.encodePacked(workflowName)));
        console.log(
            "  name enforcement:",
            workflowName == bytes10(0) ? "OFF (owner-only binding)" : "ON (SHA256-derived bytes10, NOT plaintext)"
        );
        require(deployer.balance > 0, "Deployer has zero balance");

        DeploymentConfig memory config = DeploymentConfig({
            voidCooldown: 1 days, // Amoy 1 day (Anvil 3 days, Mainnet 7 days)
            contestCreationFee: 1_000_000, // 1.00 USDC
            speculationCreationFee: 500_000, // 0.50 USDC
            leaderboardCreationFee: 500_000, // 0.50 USDC
            protocolReceiver: deployer,
            forwarder: forwarder,
            workflowOwner: workflowOwner,
            workflowName: workflowName
        });

        vm.startBroadcast(deployer);

        DeployedContracts memory contracts = _deployContracts(config);
        _bootstrapAndFinalize(contracts);
        _verifyDeployment(contracts);
        _printSummary(contracts, deployer);

        vm.stopBroadcast();
    }

    function _deployContracts(DeploymentConfig memory config) internal returns (DeployedContracts memory c) {
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

        c.treasuryModule = address(
            new TreasuryModule(
                c.ospexCore,
                c.usdc,
                config.protocolReceiver,
                config.contestCreationFee,
                config.speculationCreationFee,
                config.leaderboardCreationFee
            )
        );
        console.log("TreasuryModule:", c.treasuryModule);

        c.speculationModule = address(new SpeculationModule(c.ospexCore, config.voidCooldown));
        console.log("SpeculationModule:", c.speculationModule);

        c.positionModule = address(new PositionModule(c.ospexCore, c.usdc));
        console.log("PositionModule:", c.positionModule);

        c.secondaryMarketModule = address(new SecondaryMarketModule(c.ospexCore, c.usdc));
        console.log("SecondaryMarketModule:", c.secondaryMarketModule);

        // === CRE oracle receiver (replaces the Functions OracleModule) ===
        c.oracleModule =
            address(new CreOracleReceiver(c.ospexCore, config.forwarder, config.workflowOwner, config.workflowName));
        console.log("CreOracleReceiver (CRE_ORACLE_RECEIVER):", c.oracleModule);

        console.log("\nAll 12 modules deployed.");
        return c;
    }

    function _bootstrapAndFinalize(DeployedContracts memory c) internal {
        console.log("\n--- Bootstrap + Finalize ---");
        OspexCore core = OspexCore(c.ospexCore);

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();
        addrs[0] = c.contestModule;
        types[1] = core.SPECULATION_MODULE();
        addrs[1] = c.speculationModule;
        types[2] = core.POSITION_MODULE();
        addrs[2] = c.positionModule;
        types[3] = core.MATCHING_MODULE();
        addrs[3] = c.matchingModule;
        types[4] = core.CRE_ORACLE_RECEIVER();
        addrs[4] = c.oracleModule;
        types[5] = core.TREASURY_MODULE();
        addrs[5] = c.treasuryModule;
        types[6] = core.LEADERBOARD_MODULE();
        addrs[6] = c.leaderboardModule;
        types[7] = core.RULES_MODULE();
        addrs[7] = c.rulesModule;
        types[8] = core.SECONDARY_MARKET_MODULE();
        addrs[8] = c.secondaryMarketModule;
        types[9] = core.MONEYLINE_SCORER_MODULE();
        addrs[9] = c.moneylineScorerModule;
        types[10] = core.SPREAD_SCORER_MODULE();
        addrs[10] = c.spreadScorerModule;
        types[11] = core.TOTAL_SCORER_MODULE();
        addrs[11] = c.totalScorerModule;

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
        require(core.getModule(core.CRE_ORACLE_RECEIVER()) == c.oracleModule, "CreOracleReceiver mismatch");
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
        console.log("  DEPLOYMENT SUMMARY - Polygon Amoy CRE (Zero-Admin)");
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
        console.log("  CreOracleReceiver:", c.oracleModule);
        console.log("  TreasuryModule:", c.treasuryModule);
        console.log("  LeaderboardModule:", c.leaderboardModule);
        console.log("  RulesModule:", c.rulesModule);
        console.log("  SecondaryMarketModule:", c.secondaryMarketModule);
        console.log("  MoneylineScorerModule:", c.moneylineScorerModule);
        console.log("  SpreadScorerModule:", c.spreadScorerModule);
        console.log("  TotalScorerModule:", c.totalScorerModule);
        console.log("\n============================================================");
        console.log("  CRITICAL NEXT STEPS (CRE)");
        console.log("============================================================");
        console.log("1. cp ospex-cre/oracle/config.staging.example.json config.staging.json, then set");
        console.log("   receiverAddress + eventAddress to this CreOracleReceiver; secretOwner = workflow owner.");
        console.log("2. cre secrets create RAPIDAPI_KEY / JSONODDS_KEY (Vault DON).");
        console.log("3. cre workflow deploy ./oracle --target staging-settings (private registry).");
        console.log("4. createContestAndRequestVerify(rundownId, sportspageId, jsonoddsId).");
        console.log("5. Watch the workflow resolve -> contest reaches Verified on-chain.");
    }
}
