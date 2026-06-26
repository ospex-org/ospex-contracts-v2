// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IWorkflowRegistry} from "../interfaces/cre/IWorkflowRegistry.sol";

/**
 * @title CreWorkflowOwner
 * @author ospex.org
 * @notice The constrained governance owner of the Ospex CRE oracle workflow in the Chainlink
 *         WorkflowRegistry. This contract — NOT an EOA, and NOT the timelock itself — is the address
 *         registered as the workflow owner (it is the `msg.sender` that calls `upsertWorkflow`). It
 *         exists to make PAUSING the workflow STRUCTURALLY IMPOSSIBLE while allowing audited,
 *         time-delayed UPDATE and DELETE. Delete is allowed because the org has a hard cap on workflow
 *         slots — retiring a workflow to free a slot must be possible — but only through the timelock.
 *
 * @dev Governance architecture (the established "timelock owns a narrowly-scoped privileged contract"
 *      pattern — OZ Governor / Compound lineage):
 *
 *        GRID wallet ──proposer──▶ OZ TimelockController ──onlyTimelock──▶ CreWorkflowOwner ──▶ WorkflowRegistry
 *                                  (audited delay+access)   (THIS: update+delete)  (linked owner)
 *
 *      Why this and not a raw timelock-as-owner: a vanilla {TimelockController} set directly as the
 *      registry owner could schedule ANY registry call, including `pauseWorkflow` (arbitrary-calldata
 *      execution). The hard requirement is that PAUSE be UNREACHABLE. So we keep the audited
 *      TimelockController for the delay + proposer access control, but isolate the registry-facing
 *      authority in THIS minimal adapter, which:
 *        1. is the sole linked owner of the workflow (so only THIS contract can drive registry
 *           lifecycle calls — a `pauseWorkflow` scheduled through the timelock would execute with
 *           msg.sender = the timelock, which is NOT a linked owner, and the registry reverts); and
 *        2. exposes exactly TWO lifecycle actions — {updateWorkflow} (which calls `upsertWorkflow` with
 *           `status` HARDCODED to ACTIVE) and {deleteWorkflow} (frees a slot). There is deliberately NO
 *           pause / DON-move / admin function anywhere in this contract, so pausing has no code path;
 *           delete is permitted but, like update, only via the timelock.
 *
 *      Pinned workflow identity: the workflow NAME (and TAG, which it reuses as the name) is fixed at
 *      construction, NOT a per-call parameter. {updateWorkflow} can only ever rotate the per-build
 *      artifacts (workflow id, binary/config URLs). This makes two failure modes structurally
 *      impossible: (i) the registered name can never drift away from the receiver's immutable
 *      `i_workflowName` pin (which would make {CreOracleReceiver} silently reject every report); and
 *      (ii) because the registry keys a record by (owner, name, tag), a fixed name+tag guarantees every
 *      update lands on the SAME record — never spawning a new one that would consume one of the org's
 *      hard-capped workflow slots.
 *
 *      Immutability: the trusted timelock and the registry are immutable (set at construction). There
 *      is no Ownable, no setter, no upgrade — matching the Ospex zero-admin trust model. Rotating the
 *      timelock means deploying a fresh owner adapter and re-linking (which itself needs a Chainlink
 *      authorization), not a privileged in-place swap.
 *
 *      The receiver ({CreOracleReceiver}) binds its `i_workflowOwner` to THIS contract's address (the
 *      DON reports the registered owner — this adapter — in the report metadata) and its
 *      `i_workflowName` to (the bytes10 encoding of) this adapter's pinned {s_workflowName}.
 */
contract CreWorkflowOwner {
    /// @notice The Chainlink CRE WorkflowRegistry this contract owns a workflow in.
    IWorkflowRegistry public immutable i_registry;

    /// @notice The only address allowed to drive this contract: the OZ TimelockController in front of it.
    address public immutable i_timelock;

    /// @notice The pinned workflow identity (plaintext registry name). Set once at construction and
    ///         reused as BOTH the registry `workflowName` and `tag` on every {updateWorkflow}, so the
    ///         identity can never drift: it always maps to the receiver's pinned name, and every update
    ///         lands on the SAME registry record (never spawning a new one that would burn one of the
    ///         org's hard-capped workflow slots). CRE hashes this name (SHA256, first 10 hex chars) into
    ///         the report's bytes10 metadata field, so any non-empty length is fine. Not
    ///         language-`immutable` only because Solidity immutables cannot hold strings; there is no
    ///         setter, so it is effectively immutable.
    string public s_workflowName;

    error CreWorkflowOwner__ZeroAddress();
    error CreWorkflowOwner__EmptyWorkflowName();
    error CreWorkflowOwner__NotTimelock(address caller);

    /// @notice Emitted when the one-time ownership link is forwarded to the registry.
    event OwnerLinkForwarded(bytes32 proof);
    /// @notice Emitted when an ACTIVE register/update is forwarded to the registry.
    event WorkflowUpdateForwarded(bytes32 indexed workflowId, string workflowName);
    /// @notice Emitted when a workflow delete is forwarded to the registry (frees a slot).
    event WorkflowDeleteForwarded(bytes32 indexed workflowId);

    modifier onlyTimelock() {
        if (msg.sender != i_timelock) revert CreWorkflowOwner__NotTimelock(msg.sender);
        _;
    }

    /**
     * @param registry_ The CRE WorkflowRegistry address.
     * @param timelock_ The OZ TimelockController that governs this adapter (the sole caller).
     * @param workflowName_ The workflow's registry name (plaintext, any non-empty length). Pinned here
     *        and reused as both the `workflowName` and `tag` on every update. CRE encodes the name into
     *        the report's `bytes10` metadata field as the first 10 hex chars of SHA256(name) — a hash,
     *        NOT a string truncation — so there is deliberately no <=10-byte cap; the receiver's
     *        `i_workflowName` pin MUST be set to that same SHA256-derived bytes10 (NOT the plaintext)
     *        so DON reports are never rejected for a name mismatch.
     */
    constructor(address registry_, address timelock_, string memory workflowName_) {
        if (registry_ == address(0) || timelock_ == address(0)) {
            revert CreWorkflowOwner__ZeroAddress();
        }
        if (bytes(workflowName_).length == 0) revert CreWorkflowOwner__EmptyWorkflowName();
        i_registry = IWorkflowRegistry(registry_);
        i_timelock = timelock_;
        s_workflowName = workflowName_;
    }

    /**
     * @notice One-time bootstrap: links THIS contract as a workflow owner in the registry. The
     *         `signature` is a Chainlink allowlisted-signer authorization over this contract's address
     *         (obtained off-chain via the cre-cli owner-linking flow). Link-only — the registry's
     *         `linkOwner` cannot pause or delete anything, and it reverts if already linked.
     * @dev Routed through the timelock like every other action, so even the bootstrap is delayed.
     */
    function linkSelfAsOwner(
        uint256 validityTimestamp,
        bytes32 proof,
        bytes calldata signature
    ) external onlyTimelock {
        i_registry.linkOwner(validityTimestamp, proof, signature);
        emit OwnerLinkForwarded(proof);
    }

    /**
     * @notice Registers (first call) or updates the workflow, with `status` HARDCODED to ACTIVE,
     *         `keepAlive` HARDCODED to true, and name+tag HARDCODED to the pinned {s_workflowName}.
     *         Together with {deleteWorkflow} these are the only two registry-lifecycle actions this
     *         contract exposes; pausing is unreachable because no function here can emit anything but an
     *         ACTIVE upsert on the pinned identity.
     * @dev Callable only by the timelock, so every update is subject to the timelock's delay. Only the
     *      per-build artifacts (workflow id, binary/config URLs) vary per call. Three registry fields are
     *      forced: `status` = ACTIVE; `keepAlive` = true (the registry's `keepAlive=false` create-path
     *      can pause same-owner/same-name active records — that pause-capable flag is never exposed); and
     *      `workflowName`/`tag` = {s_workflowName}. So identity can never drift from the receiver's pin
     *      and every update is in-place (slot-safe).
     * @param workflowId The compiled-binary workflow id (CRE rotates it on every build; not pinned).
     * @param donFamily The DON family the workflow runs on (the receiver does not check it).
     * @param binaryUrl The uploaded WASM artifact URL produced by the cre-cli build/upload.
     * @param configUrl The uploaded config artifact URL.
     * @param attributes Registry attributes blob (usually empty).
     */
    function updateWorkflow(
        bytes32 workflowId,
        string calldata donFamily,
        string calldata binaryUrl,
        string calldata configUrl,
        bytes calldata attributes
    ) external onlyTimelock {
        string memory name = s_workflowName;
        i_registry.upsertWorkflow(
            name, // pinned at construction — identity cannot drift from the receiver's pin
            name, // tag == name: every update is in-place on the same record (slot-preserving)
            workflowId,
            IWorkflowRegistry.WorkflowStatus.ACTIVE, // hardcoded — pause is structurally impossible
            donFamily,
            binaryUrl,
            configUrl,
            attributes,
            true // keepAlive hardcoded true — never expose the registry's pause-capable create-path flag
        );
        emit WorkflowUpdateForwarded(workflowId, name);
    }

    /**
     * @notice Deletes the workflow in the registry, freeing the org's slot. The org has a hard cap on
     *         workflow slots, so retiring a workflow to free one must be possible — but, like
     *         {updateWorkflow}, only through the timelock (subject to its delay). The registry does NOT
     *         require the workflow to be paused first.
     * @dev The only other lifecycle action besides {updateWorkflow}. Pausing remains unreachable — this
     *      contract exposes no pause symbol.
     * @param workflowId The id of the workflow to delete.
     */
    function deleteWorkflow(bytes32 workflowId) external onlyTimelock {
        i_registry.deleteWorkflow(workflowId);
        emit WorkflowDeleteForwarded(workflowId);
    }
}
