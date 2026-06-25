// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title IWorkflowRegistry
 * @notice Minimal interface for the Chainlink CRE WorkflowRegistry 2.0.0
 *         (Ethereum mainnet 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5).
 * @dev Only the functions the Ospex owner ({CreWorkflowOwner}) ever calls are declared: `linkOwner`
 *      (one-time ownership bootstrap), `upsertWorkflow` (register/update — always ACTIVE), and
 *      `deleteWorkflow` (retire a workflow to free one of the org's hard-capped slots). The PAUSE
 *      lifecycle functions — `pauseWorkflow`, `batchPauseWorkflows`, `updateWorkflowDONFamily` — are
 *      intentionally absent so the owner contract has no symbol through which to pause; pausing is
 *      structurally impossible. Deleting does NOT require the workflow to be paused first.
 *
 *      Registry semantics that matter here:
 *        - The workflow owner is `msg.sender` of `upsertWorkflow`; the record is keyed by
 *          keccak256(abi.encode(msg.sender, name, tag)). There is no EOA/tx.origin/code-size check,
 *          so a contract can be the owner.
 *        - Every lifecycle call requires `msg.sender` to be a linked owner (s_linkedOwners).
 *        - `linkOwner`'s `signature` must recover (EIP-191/ECDSA) to a Chainlink-allowlisted signer
 *          over the (arbitrary) owner address — the owner's own key is never used.
 *        - `upsertWorkflow` honors the `status` field on create, so forcing it to ACTIVE prevents a
 *          paused registration.
 */
interface IWorkflowRegistry {
    /// @notice Workflow status. Mirrors the registry enum exactly (ACTIVE = 0, PAUSED = 1).
    enum WorkflowStatus {
        ACTIVE,
        PAUSED
    }

    /// @notice Links `msg.sender` as a workflow owner, authorized by a Chainlink allowlisted-signer
    ///         signature over the owner address. One-time per owner; reverts if already linked.
    function linkOwner(uint256 validityTimestamp, bytes32 proof, bytes calldata signature) external;

    /// @notice Registers a new workflow (when none exists for owner∥name∥tag) or updates the existing
    ///         one. Owner = msg.sender; requires msg.sender to be a linked owner.
    function upsertWorkflow(
        string calldata workflowName,
        string calldata tag,
        bytes32 workflowId,
        WorkflowStatus status,
        string calldata donFamily,
        string calldata binaryUrl,
        string calldata configUrl,
        bytes calldata attributes,
        bool keepAlive
    ) external;

    /// @notice Deletes a workflow, freeing the owner's slot. Owner = msg.sender; requires msg.sender to
    ///         be a linked owner. Selector 0x695e1340. Does NOT require the workflow to be paused first.
    function deleteWorkflow(bytes32 workflowId) external;
}
