// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";

// Modules
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
 * @title DeployPolygonCre
 * @notice R5 deployment script for the Ospex protocol on Polygon Mainnet with the Chainlink CRE
 *         oracle receiver in the CRE_ORACLE_RECEIVER slot (replaces the R4 Functions-based
 *         OracleModule). This is the proven R4 mainnet deploy with ONLY the oracle wiring swapped.
 * @dev ZERO-ADMIN ONE-SHOT DEPLOYMENT — re-running this deploys a fresh protocol;
 *      there is no upgrade path. Confirm all parameters before running.
 *      Uses bootstrap+finalize pattern — no admin key after deployment.
 *
 *      The CRE receiver's constructor takes (ospexCore, forwarder, workflowOwner, workflowName) — no
 *      router / LINK / DON id / subscription / approved-signer / fee / sunset; the workflow id is
 *      deliberately NOT pinned (CRE rotates it). There is no oracle-request fee and no on-chain rate
 *      limiting — griefing of the permissionless requests is bounded off-chain by the CRE platform's
 *      per-workflow log-trigger rate limit + the workflow owner's funded CRE balance.
 *
 *      Env inputs (with defaults where noted):
 *        DEPLOYER_ADDRESS       — the mainnet-funded EOA that broadcasts (gas payer). MUST equal
 *                                 APPROVED_DEPLOYER below (hard guard).
 *        KEYSTONE_FORWARDER     — the Polygon MAINNET production KeystoneForwarder. NO DEFAULT — the
 *                                 mainnet forwarder address is deliberately NOT hardcoded/guessed here;
 *                                 it MUST be set to the real value and human-confirmed before deploy.
 *        WORKFLOW_OWNER         — the CRE workflow owner ADDRESS the report-metadata owner onReport
 *                                 enforces: the {CreWorkflowOwner} governance adapter for a governed
 *                                 mainnet deploy (it deploys SEPARATELY on Ethereum mainnet via
 *                                 DeployCreGovernance, so it does not exist at the time this script is
 *                                 authored). MUST be set to the real value.
 *        WORKFLOW_NAME          — the CRE-derived bytes10 the DON stamps into report metadata (a HASH
 *                                 of the name, NOT plaintext bytes10 — see the note at the env read
 *                                 below). 0 = not enforced (owner check only).
 */
contract DeployPolygonCre is Script {
    // Polygon mainnet token — UNCHANGED from the proven R4 mainnet config.
    address constant USDC_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    // CONFIGURABLE: Protocol fee receiver (hardware wallet / multisig for mainnet) — UNCHANGED from R4.
    address constant FEE_RECEIVER = 0xdaC630aE52b868FF0A180458eFb9ac88e7425114;
    // CONFIGURABLE: The mainnet deployer EOA (the broadcaster). Hard guard: DEPLOYER_ADDRESS must equal this.
    address constant APPROVED_DEPLOYER = 0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886;

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
        address oracleModule; // CreOracleReceiver (CRE_ORACLE_RECEIVER slot)
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
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // CRE oracle wiring — parameterized via env exactly like DeployAmoyCre. The mainnet forwarder
        // has NO default (must never be guessed); the workflow owner has no default (governance adapter
        // deploys separately); the workflow name defaults to not-enforced.
        address forwarder = vm.envAddress("KEYSTONE_FORWARDER");
        require(forwarder != address(0), "set KEYSTONE_FORWARDER (Polygon mainnet)"); // receiver also reverts on zero
        address workflowOwner = vm.envOr("WORKFLOW_OWNER", address(0));
        require(workflowOwner != address(0), "set WORKFLOW_OWNER (CRE workflow owner address)");
        // WORKFLOW_NAME posture (IMMUTABLE -- choose consciously). RECOMMENDED for mainnet: ENFORCE the
        // name. When enforced it MUST be the bytes10 the CRE engine stamps into report metadata:
        // SHA256(name) -> first 10 hex chars -> those 10 ASCII chars as bytes. This is a HASH of the name,
        // NOT bytes10 of the plaintext (e.g. "my_workflow" -> 0x62373666336165316465). The receiver
        // compares i_workflowName against this metadata value verbatim, so passing the PLAINTEXT name here
        // would make onReport reject every report -- a permanent brick. It MUST equal SHA256 of the exact
        // name pinned in DeployCreGovernance (default "osverify"). 0 (default) = name NOT enforced
        // (owner-only binding); acceptable, but pinning the name is strictly safer for an immutable deploy.
        bytes10 workflowName = bytes10(vm.envOr("WORKFLOW_NAME", bytes32(0)));

        console.log("=== Ospex Polygon Mainnet CRE Deployment (Zero-Admin) ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("KeystoneForwarder:", forwarder);
        console.log("Workflow owner:", workflowOwner);
        console.log("Workflow name (bytes10):", vm.toString(abi.encodePacked(workflowName)));
        console.log(
            "  name enforcement:",
            workflowName == bytes10(0) ? "OFF (owner-only binding)" : "ON (SHA256-derived bytes10, NOT plaintext)"
        );
        console.log("Fee receiver:", FEE_RECEIVER);
        console.log("Balance:", deployer.balance);

        // Hard guards — fail before any broadcast if the environment is wrong.
        require(block.chainid == 137, "wrong chain");
        require(deployer == APPROVED_DEPLOYER, "wrong deployer");
        require(deployer.balance > 0, "Deployer has zero balance");

        // CONFIGURABLE: Protocol parameters — see docs/deployment/DEPLOYMENT_PARAMETERS.md
        // UNCHANGED from the proven R4 mainnet config.
        DeploymentConfig memory config = DeploymentConfig({
            voidCooldown: 7 days, // CONFIGURABLE: Mainnet 7 days, Amoy 1 day, Anvil 3 days
            contestCreationFee: 1_000_000, // CONFIGURABLE: 1.00 USDC
            speculationCreationFee: 500_000, // CONFIGURABLE: 0.50 USDC (split between maker and taker)
            leaderboardCreationFee: 500_000, // CONFIGURABLE: 0.50 USDC
            protocolReceiver: FEE_RECEIVER, // CONFIGURABLE: fee receiver address
            forwarder: forwarder, // CRE: Polygon mainnet KeystoneForwarder (env)
            workflowOwner: workflowOwner, // CRE: workflow owner / governance adapter (env)
            workflowName: workflowName // CRE: enforced bytes10 workflow name (env, 0 = off)
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

        c.ospexCore = address(new OspexCore());
        console.log("OspexCore:", c.ospexCore);

        c.contestModule = address(new ContestModule(c.ospexCore));
        c.leaderboardModule = address(new LeaderboardModule(c.ospexCore));
        c.rulesModule = address(new RulesModule(c.ospexCore));
        c.moneylineScorerModule = address(new MoneylineScorerModule(c.ospexCore));
        c.spreadScorerModule = address(new SpreadScorerModule(c.ospexCore));
        c.totalScorerModule = address(new TotalScorerModule(c.ospexCore));
        c.matchingModule = address(new MatchingModule(c.ospexCore));

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
        c.speculationModule = address(new SpeculationModule(c.ospexCore, config.voidCooldown));
        c.positionModule = address(new PositionModule(c.ospexCore, c.usdc));
        c.secondaryMarketModule = address(new SecondaryMarketModule(c.ospexCore, c.usdc));
        // === CRE oracle receiver (replaces the Functions OracleModule) ===
        c.oracleModule =
            address(new CreOracleReceiver(c.ospexCore, config.forwarder, config.workflowOwner, config.workflowName));
        console.log("CreOracleReceiver (CRE_ORACLE_RECEIVER):", c.oracleModule);

        console.log("All 12 modules deployed.");
        return c;
    }

    function _bootstrapAndFinalize(DeployedContracts memory c) internal {
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
        core.finalize();
        console.log("Protocol FINALIZED.");
    }

    function _verifyDeployment(DeployedContracts memory c) internal view {
        OspexCore core = OspexCore(c.ospexCore);
        require(core.s_finalized(), "Not finalized!");
        require(core.getModule(core.CRE_ORACLE_RECEIVER()) == c.oracleModule, "CreOracleReceiver mismatch");
        require(core.isApprovedScorer(c.moneylineScorerModule), "MoneylineScorer check failed");
        require(core.isApprovedScorer(c.spreadScorerModule), "SpreadScorer check failed");
        require(core.isApprovedScorer(c.totalScorerModule), "TotalScorer check failed");
        require(core.isSecondaryMarket(c.secondaryMarketModule), "SecondaryMarket check failed");
        console.log("Verification PASSED.");
    }

    function _printSummary(DeployedContracts memory c, address deployer) internal pure {
        console.log("\n============================================================");
        console.log("  POLYGON MAINNET CRE DEPLOYMENT (Zero-Admin, Immutable)");
        console.log("============================================================");
        console.log("Deployer:", deployer);
        console.log("USDC:", c.usdc);
        console.log("OspexCore:", c.ospexCore);
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
        console.log("\n=== NEXT STEPS (CRE) ===");
        console.log("1. Point the CRE workflow config (receiverAddress + eventAddress) at this CreOracleReceiver.");
        console.log("2. Ensure the workflow owner matches WORKFLOW_OWNER (governance adapter on Ethereum mainnet).");
        console.log("3. Update all dependent services with new addresses.");
        console.log("4. Test with small positions before going live.");
    }
}
