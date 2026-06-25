// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CreWorkflowOwner} from "../src/governance/CreWorkflowOwner.sol";

/**
 * @title DeployCreGovernance
 * @notice Deploys the on-chain governance for the Ospex CRE oracle workflow: an OZ
 *         {TimelockController} fronting a {CreWorkflowOwner} adapter that becomes the LINKED OWNER of
 *         the workflow in the Chainlink CRE WorkflowRegistry.
 *
 *         WHERE THIS RUNS — the chain the WorkflowRegistry lives on. The CRE *on-chain* registry is
 *         ETHEREUM MAINNET only (WorkflowRegistry 2.0.0 @ 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5);
 *         there is no testnet on-chain registry, so the real deploy is Ethereum mainnet (real ETH gas).
 *         The CreOracleReceiver this governance ultimately serves can be on Amoy (test) or Polygon
 *         mainnet (prod): the governance is deployed ONCE and reused across protocol redeploys — only
 *         the workflow's config (its binary/config, which encode the receiver address) changes, via a
 *         timelocked {CreWorkflowOwner.updateWorkflow}.
 *
 * @dev This script deploys the two contracts ONLY. The two follow-up steps are timelocked operations
 *      and are NOT done here:
 *        1. {CreWorkflowOwner.linkSelfAsOwner} — needs a Chainlink allowlisted-signer signature obtained
 *           off-chain via the cre-cli owner-linking flow; schedule + execute it through the timelock.
 *        2. {CreWorkflowOwner.updateWorkflow} — register / point the workflow under the adapter; timelocked.
 *      Before linking, free or raise the org's linked-owner quota (the single onchain-registry slot is
 *      held by the trial EOA today — do NOT unlink a live workflow owner).
 *
 *      Env inputs:
 *        DEPLOYER_ADDRESS    — the funded EOA that broadcasts (gas payer).
 *        WORKFLOW_REGISTRY   — the CRE WorkflowRegistry (default: Ethereum-mainnet 2.0.0 address).
 *        TIMELOCK_MIN_DELAY  — timelock delay in SECONDS (default 7 days). 604800 = 7d (recommended:
 *                              aligns with the void cooldown, reads as security-grade), 1209600 = 14d
 *                              (more conservative — covers the longest contest in-flight window). The
 *                              timelock controls ONLY workflow update/delete, never the protocol/funds.
 *                              A sub-1-day delay reverts unless ALLOW_SHORT_DELAY=true (test-deploy guard).
 *        ALLOW_SHORT_DELAY   — set true ONLY for a fast TEST governance deploy (short delay); omit for prod.
 *        TIMELOCK_PROPOSER   — address allowed to schedule (the governance wallet). MUST be set.
 *        TIMELOCK_EXECUTOR   — address allowed to execute (default = proposer).
 *        WORKFLOW_NAME       — the workflow's registry name (default "osverify"); pinned in the adapter.
 *                              MUST equal the name whose SHA256-derived bytes10 the receiver pins.
 */
contract DeployCreGovernance is Script {
    // CRE WorkflowRegistry 2.0.0 on Ethereum mainnet (the only on-chain registry).
    address constant CRE_WORKFLOW_REGISTRY_MAINNET = 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5;

    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "set DEPLOYER_ADDRESS");

        address registry = vm.envOr("WORKFLOW_REGISTRY", CRE_WORKFLOW_REGISTRY_MAINNET);
        // Catch a wrong chain / wrong address before broadcasting: the registry must be a real contract
        // on THIS chain. The mainnet WorkflowRegistry only exists on Ethereum mainnet, so this also
        // guards against accidentally running against a chain that has no registry deployed.
        require(registry.code.length > 0, "WORKFLOW_REGISTRY has no code on this chain");

        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(7 days)); // recommended; set explicitly at deploy
        // Fat-finger guards on the most dangerous parameter — the delay IS the protocol's protection window.
        // (1) Catch a units error: "7" meaning 7 days but read as 7 seconds. (2) Make a PROD deploy
        // safe-by-default: a sub-1-day delay (only ever wanted for a fast TEST deploy) reverts unless you
        // explicitly opt in, so a prod deploy that accidentally reuses the test delay fails loudly.
        require(minDelay >= 60, "TIMELOCK_MIN_DELAY < 60s -- seconds vs days? (7 days = 604800)");
        if (minDelay < 1 days) {
            require(
                vm.envOr("ALLOW_SHORT_DELAY", false),
                "TIMELOCK_MIN_DELAY < 1 day -- set ALLOW_SHORT_DELAY=true to confirm a TEST deploy"
            );
        }
        address proposer = vm.envOr("TIMELOCK_PROPOSER", address(0));
        require(proposer != address(0), "set TIMELOCK_PROPOSER");
        address executor = vm.envOr("TIMELOCK_EXECUTOR", proposer);
        string memory workflowName = vm.envOr("WORKFLOW_NAME", string("osverify"));

        console.log("=== Ospex CRE Governance Deployment ===");
        console.log("Chain id:", block.chainid);
        console.log("WorkflowRegistry:", registry);
        console.log("Timelock minDelay (seconds):", minDelay);
        console.log("Timelock minDelay (hours):", minDelay / 1 hours); // human-readable cross-check
        console.log("Timelock minDelay (days):", minDelay / 1 days); // 0 here => this is a TEST delay
        console.log("Proposer:", proposer);
        console.log("Executor:", executor);
        console.log("Workflow name (pinned in adapter):", workflowName);
        require(deployer.balance > 0, "Deployer has zero balance");

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        vm.startBroadcast(deployer);

        // admin = address(0): self-administered, no standing admin — only the timelock's own delayed
        // process can change roles/delay (matches the protocol's zero-admin trust model).
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, address(0));
        console.log("TimelockController:", address(timelock));

        // The adapter is the linked WorkflowRegistry owner; the timelock is its sole caller.
        CreWorkflowOwner adapter = new CreWorkflowOwner(registry, address(timelock), workflowName);
        console.log("CreWorkflowOwner (adapter / linked owner):", address(adapter));

        vm.stopBroadcast();

        console.log("\n=== NEXT STEPS (timelocked; NOT performed by this script) ===");
        console.log("1. Deploy/point the CreOracleReceiver with i_workflowOwner = the adapter address above.");
        console.log("2. Free or raise the org linked-owner quota, then schedule+execute adapter.linkSelfAsOwner");
        console.log("   using the Chainlink allowlisted-signer signature from the cre-cli owner-linking flow.");
        console.log("3. Schedule+execute adapter.updateWorkflow to register/point the workflow under the adapter.");
    }
}
