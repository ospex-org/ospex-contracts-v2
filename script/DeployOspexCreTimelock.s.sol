// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {OspexCreTimelock} from "../src/governance/OspexCreTimelock.sol";

/**
 * @title DeployOspexCreTimelock
 * @notice Deploys the per-action {OspexCreTimelock} as the DIRECT linked owner of the Ospex CRE oracle
 *         workflow in the Chainlink WorkflowRegistry. SUPERSEDES the former DeployCreGovernance + a
 *         CreWorkflowOwner adapter (both removed) — the adapter is retired because a
 *         no-generic-executor owner cannot submit the `allowlistRequest` secret op; see
 *         `.claude/reviews/cre-governance-build-manifest.md`).
 *
 *         WHERE THIS RUNS — Ethereum mainnet (the only chain the CRE WorkflowRegistry 2.0.0 lives on,
 *         at 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5). The CreOracleReceiver it serves can be Amoy
 *         (test) or Polygon (prod); governance is deployed once and reused across receiver redeploys.
 *
 *         TWO PHASES (the CRE link/secrets/register bootstrap is off-chain and must happen INSTANTLY,
 *         so the timelock is deployed with global delay = 0, bootstrapped, THEN raised + locked down):
 *
 *           PHASE 1  `deploy()`               -> timelock in bootstrap state: global minDelay = 0,
 *                                                admin = deployer (temporary), the cold-wallet controller
 *                                                as proposer/executor/canceller.
 *           (off-chain) cre-cli + cast        -> link the timelock as owner, create secrets
 *                                                (allowlistRequest), register the workflow — ALL via
 *                                                schedule+execute with delay 0 (instant).
 *           PHASE 2  `configureAndLockdown()` -> set global delay = 7d + the registry `allowlistRequest`
 *                                                key lane = 1s, grant ADMIN to the timelock itself,
 *                                                deployer renounces ADMIN. From here: code ops take the
 *                                                full delay, key rotation is ~instant, and even changing
 *                                                these numbers is itself delayed (admin = self).
 *
 *         Env inputs:
 *           DEPLOYER_ADDRESS           — the funded EOA that broadcasts (gas payer; temp admin).
 *           OSPEX_TIMELOCK_CONTROLLER  — the cold-wallet controller (proposer/executor/canceller). Holds
 *                                        any address; the launch config is a single cold wallet, and the
 *                                        roles can later be migrated to a multisig via a 7-day governance
 *                                        op. MUST be set (phase 1).
 *           OSPEX_TIMELOCK             — the address deployed in phase 1 (phase 3 input). MUST be set (phase 3).
 *           WORKFLOW_REGISTRY          — CRE WorkflowRegistry (default: Ethereum-mainnet 2.0.0 address).
 *           OSPEX_TIMELOCK_FINAL_DELAY — production global delay in SECONDS (default 604800 = 7d). A
 *                                        sub-1-day delay reverts unless ALLOW_SHORT_DELAY=true (TEST guard).
 *           ALLOW_SHORT_DELAY          — true ONLY for a fast TEST deploy (short final delay); omit for prod.
 *           ALLOW_NON_MAINNET_REGISTRY — true ONLY for a mainnet-fork / local test (non-chainid-1) deploy.
 */
contract DeployOspexCreTimelock is Script {
    /// @dev CRE WorkflowRegistry 2.0.0 on Ethereum mainnet (the only on-chain registry).
    address internal constant CRE_WORKFLOW_REGISTRY_MAINNET = 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5;

    /// @dev The WorkflowRegistry `allowlistRequest` selector — the single on-chain op behind EVERY
    ///      `cre secrets` command (create/update/list/delete). Observed live on-chain (0x94ea0da6). This
    ///      is the ONE action given the fast (sub-global) delay lane, so a leaked API key can be rotated
    ///      without waiting the full code delay.
    bytes4 internal constant ALLOWLIST_REQUEST_SELECTOR = 0x94ea0da6;

    function _resolveRegistry() internal view returns (address registry) {
        registry = vm.envOr("WORKFLOW_REGISTRY", CRE_WORKFLOW_REGISTRY_MAINNET);
        require(registry.code.length > 0, "WORKFLOW_REGISTRY has no code on this chain");
        if (block.chainid != 1) {
            require(
                vm.envOr("ALLOW_NON_MAINNET_REGISTRY", false),
                "not Ethereum mainnet (set ALLOW_NON_MAINNET_REGISTRY=true for a fork/test deploy)"
            );
        }
    }

    /// @notice PHASE 1 — deploy the timelock in its BOOTSTRAP state (global delay = 0, admin = deployer,
    ///         the cold-wallet controller as proposer/executor/canceller). Nothing is locked yet.
    function deploy() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "set DEPLOYER_ADDRESS");
        require(deployer.balance > 0, "Deployer has zero balance");

        address registry = _resolveRegistry();
        address controller = vm.envOr("OSPEX_TIMELOCK_CONTROLLER", address(0));
        require(
            controller != address(0),
            "set OSPEX_TIMELOCK_CONTROLLER (the cold-wallet controller: proposer/executor/canceller)"
        );

        // Bootstrap runs with admin = the deployer ALONE — NO proposers/executors/cancellers yet — so
        // during the instant global=0 window only the deployer key can execute anything. The controller is
        // granted its operational roles in configureAndLockdown(), AFTER the delay is raised.
        address[] memory none = new address[](0);

        console.log("=== Deploy OspexCreTimelock (PHASE 1: bootstrap state, global delay = 0) ===");
        console.log("Chain id:", block.chainid);
        console.log("WorkflowRegistry:", registry);
        console.log("Controller (granted operational roles in phase 3):", controller);
        console.log("Temp admin (deployer ALONE; renounced in phase 3):", deployer);

        vm.startBroadcast(deployer);
        // minDelay = 0 -> bootstrap ops instant; admin = deployer (temporary); no proposers yet.
        OspexCreTimelock tl = new OspexCreTimelock(0, deployer, none, none, none);
        vm.stopBroadcast();

        console.log("OspexCreTimelock:", address(tl));
        console.log("\n=== NEXT (off-chain; all INSTANT while the global delay is 0) ===");
        console.log("1. Deploy/point CreOracleReceiver with i_workflowOwner = the timelock address above.");
        console.log("2. Free the org owner slot; cre account link-key --unsigned -> schedule+execute the");
        console.log("   timelock -> registry.linkOwner (delay 0).");
        console.log("3. cre secrets create --unsigned -> schedule+execute the allowlistRequest (delay 0),");
        console.log("   then cre secrets execute after ~13min Ethereum finality.");
        console.log("4. cre workflow deploy --unsigned -> schedule+execute upsertWorkflow to register (delay 0).");
        console.log("5. THEN run configureAndLockdown() to raise the delay + hand off admin.");
    }

    /// @notice PHASE 3 — after the off-chain bootstrap, set the two production delay numbers and lock the
    ///         timelock down: ADMIN_ROLE -> the timelock itself (self-administered), deployer renounces.
    ///         All calls here are direct admin calls (instant) by the deployer, who relinquishes admin last.
    function configureAndLockdown() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "set DEPLOYER_ADDRESS");

        address registry = _resolveRegistry();
        address tlAddr = vm.envOr("OSPEX_TIMELOCK", address(0));
        require(tlAddr != address(0), "set OSPEX_TIMELOCK (the address deployed in phase 1)");
        OspexCreTimelock tl = OspexCreTimelock(payable(tlAddr));

        address controller = vm.envOr("OSPEX_TIMELOCK_CONTROLLER", address(0));
        require(controller != address(0), "set OSPEX_TIMELOCK_CONTROLLER (granted proposer/executor/canceller here)");

        uint256 finalDelay = vm.envOr("OSPEX_TIMELOCK_FINAL_DELAY", uint256(7 days));
        // Fat-finger guards on the delay (the protocol's protection window):
        // (1) units check (7 days = 604800, not 7); (2) prod-safe-by-default — a sub-1-day delay reverts
        // unless explicitly opted in, so a prod deploy can't silently reuse a test delay.
        require(finalDelay >= 60, "FINAL_DELAY < 60s -- seconds vs days? (7 days = 604800)");
        if (finalDelay < 1 days) {
            require(
                vm.envOr("ALLOW_SHORT_DELAY", false),
                "FINAL_DELAY < 1 day -- set ALLOW_SHORT_DELAY=true to confirm a TEST deploy"
            );
        }
        require(tl.hasRole(tl.ADMIN_ROLE(), deployer), "deployer is not admin (already locked down?)");

        console.log("=== OspexCreTimelock configure + lockdown (PHASE 2) ===");
        console.log("Timelock:", tlAddr);
        console.log("Controller (granted proposer/executor/canceller):", controller);
        console.log("Final global delay (seconds):", finalDelay);
        console.log("Final global delay (days):", finalDelay / 1 days);
        console.log("Fast key lane: registry.allowlistRequest = 1s");

        OspexCreTimelock.UpdateDelayParams[] memory keyLane = new OspexCreTimelock.UpdateDelayParams[](1);
        keyLane[0] = OspexCreTimelock.UpdateDelayParams({
            target: registry,
            selector: ALLOWLIST_REQUEST_SELECTOR,
            newDelay: 1
        });

        vm.startBroadcast(deployer);
        // 1) set the two production delay numbers FIRST (so the controller never holds a role while global = 0)
        tl.updateDelay(finalDelay); // global default -> all code/lifecycle ops inherit this
        tl.updateDelay(keyLane); // the single fast carve-out -> key rotation
        // 2) NOW grant the controller its operational roles (after the delay is in force)
        tl.grantRole(tl.PROPOSER_ROLE(), controller);
        tl.grantRole(tl.EXECUTOR_ROLE(), controller);
        tl.grantRole(tl.CANCELLER_ROLE(), controller);
        // 3) hand ADMIN to the timelock itself, deployer renounces (MUST be last)
        tl.grantRole(tl.ADMIN_ROLE(), tlAddr); // self-administered: rule changes are themselves delayed
        tl.renounceRole(tl.ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        // Read-back gate — the 7-day guarantee is real ONLY if ADMIN is held SOLELY by the timelock.
        require(tl.getMinDelay() == finalDelay, "global delay not set");
        require(tl.getMinDelay(registry, ALLOWLIST_REQUEST_SELECTOR) == 1, "key lane not set");
        require(tl.getRoleMemberCount(tl.ADMIN_ROLE()) == 1, "ADMIN set must be exactly {timelock}");
        require(tl.getRoleMember(tl.ADMIN_ROLE(), 0) == tlAddr, "sole ADMIN must be the timelock");
        require(!tl.hasRole(tl.ADMIN_ROLE(), deployer), "deployer still ADMIN -- lockdown failed");
        require(
            tl.hasRole(tl.PROPOSER_ROLE(), controller) && tl.hasRole(tl.EXECUTOR_ROLE(), controller)
                && tl.hasRole(tl.CANCELLER_ROLE(), controller),
            "controller operational roles not granted"
        );
        console.log("Lockdown verified: sole ADMIN = timelock, deployer out, controller = proposer/exec/canceller.");
    }
}
