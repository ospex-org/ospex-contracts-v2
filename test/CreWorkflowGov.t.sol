// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CreWorkflowOwner} from "../src/governance/CreWorkflowOwner.sol";
import {IWorkflowRegistry} from "../src/interfaces/cre/IWorkflowRegistry.sol";

/// @notice Minimal stand-in for the CRE WorkflowRegistry 2.0.0. Mirrors the only semantics the
///         governance design depends on: every lifecycle call requires msg.sender to be a linked
///         owner, owner = msg.sender, and upsert records the status. `deleteWorkflow` IS reachable —
///         but only via the adapter (the linked owner), driven by the timelock. `pauseWorkflow` is
///         present here (the real registry has it) ONLY to prove the timelock cannot reach it — it is
///         deliberately NOT on {IWorkflowRegistry} or {CreWorkflowOwner}, so pausing stays impossible.
contract MockWorkflowRegistry is IWorkflowRegistry {
    mapping(address => bool) public linked;
    address public lastOwner;
    uint8 public lastStatus = 255; // sentinel (real values are 0 = ACTIVE, 1 = PAUSED)
    bytes32 public lastWorkflowId;
    string public lastName;
    string public lastTag;
    bool public lastKeepAlive;
    uint256 public upsertCount;
    bool public paused;
    bool public deleted;

    error NotLinked(address who);
    error AlreadyLinked(address who);

    function linkOwner(uint256, bytes32, bytes calldata) external override {
        if (linked[msg.sender]) revert AlreadyLinked(msg.sender);
        linked[msg.sender] = true;
    }

    function upsertWorkflow(
        string calldata workflowName,
        string calldata tag,
        bytes32 workflowId,
        WorkflowStatus status,
        string calldata,
        string calldata,
        string calldata,
        bytes calldata,
        bool keepAlive
    ) external override {
        if (!linked[msg.sender]) revert NotLinked(msg.sender);
        lastOwner = msg.sender;
        lastStatus = uint8(status);
        lastWorkflowId = workflowId;
        lastName = workflowName;
        lastTag = tag;
        lastKeepAlive = keepAlive;
        upsertCount++;
    }

    // pauseWorkflow: NOT on {IWorkflowRegistry}/{CreWorkflowOwner} — present only to prove the timelock
    // cannot reach it (pausing must be structurally impossible).
    function pauseWorkflow(bytes32) external {
        if (!linked[msg.sender]) revert NotLinked(msg.sender);
        paused = true;
    }

    // deleteWorkflow: IS on {IWorkflowRegistry} — reachable, but only by a linked owner (the adapter).
    function deleteWorkflow(bytes32) external override {
        if (!linked[msg.sender]) revert NotLinked(msg.sender);
        deleted = true;
    }
}

/**
 * @title CreWorkflowGovTest
 * @notice Tests the governance layer: OZ {TimelockController} (delay + proposer access) fronting the
 *         {CreWorkflowOwner} adapter (the linked registry owner). Verifies propose→wait→execute for
 *         updates AND deletes; execute-before-delay reverts; only the proposer can propose; and — the
 *         hard requirement — PAUSE is UNREACHABLE while DELETE is allowed only via the timelocked adapter.
 */
contract CreWorkflowGovTest is Test {
    MockWorkflowRegistry internal registry;
    TimelockController internal timelock;
    CreWorkflowOwner internal ownerAdapter;

    address internal proposer = makeAddr("proposer"); // the GRID wallet
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant DELAY = 2 days;
    string internal constant WORKFLOW_NAME = "osverify";

    function setUp() public {
        registry = new MockWorkflowRegistry();

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        // admin = address(0): self-administered, no standing admin. Proposer also gets CANCELLER_ROLE.
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        ownerAdapter = new CreWorkflowOwner(address(registry), address(timelock), WORKFLOW_NAME);
    }

    // ──────────────────────────── helpers ─────────────────────────────

    function _scheduleAndExecute(address target, bytes memory data) internal {
        vm.prank(proposer);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function _linkData() internal view returns (bytes memory) {
        return abi.encodeCall(
            CreWorkflowOwner.linkSelfAsOwner,
            (block.timestamp + 1000, bytes32("proof"), bytes(""))
        );
    }

    function _updateData(bytes32 wfId) internal pure returns (bytes memory) {
        return abi.encodeCall(
            CreWorkflowOwner.updateWorkflow,
            (wfId, "zone-a", "https://bin", "https://cfg", bytes(""))
        );
    }

    function _linkAdapter() internal {
        _scheduleAndExecute(address(ownerAdapter), _linkData());
    }

    // ──────────────────────────── happy path ──────────────────────────

    function test_link_thenUpdate_registersActiveUnderAdapter() public {
        _linkAdapter();
        assertTrue(registry.linked(address(ownerAdapter)));

        _scheduleAndExecute(address(ownerAdapter), _updateData(bytes32(uint256(0x1234))));

        assertEq(registry.lastOwner(), address(ownerAdapter)); // owner = adapter, NOT the timelock
        assertEq(registry.lastStatus(), uint8(0)); // ACTIVE — hardcoded
        assertEq(registry.lastWorkflowId(), bytes32(uint256(0x1234)));
        // name + tag are both forced to the pinned identity — the caller can't supply them
        assertEq(registry.lastName(), WORKFLOW_NAME);
        assertEq(registry.lastTag(), WORKFLOW_NAME);
        assertTrue(registry.lastKeepAlive()); // keepAlive hardcoded true — no pause-capable flag exposed
        assertEq(registry.upsertCount(), 1);
    }

    /// @dev The pinned name is reused across updates, so the workflow id can rotate (CRE rebuilds it)
    ///      while the registry record identity (name+tag) stays fixed → in-place, slot-preserving.
    function test_update_rotatesIdButKeepsPinnedIdentity() public {
        _linkAdapter();
        _scheduleAndExecute(address(ownerAdapter), _updateData(bytes32(uint256(0xAAAA))));
        _scheduleAndExecute(address(ownerAdapter), _updateData(bytes32(uint256(0xBBBB))));
        assertEq(registry.lastWorkflowId(), bytes32(uint256(0xBBBB))); // id rotated
        assertEq(registry.lastName(), WORKFLOW_NAME); // identity unchanged
        assertEq(registry.lastTag(), WORKFLOW_NAME);
        assertEq(registry.upsertCount(), 2);
    }

    /// @dev The adapter CAN delete the workflow (to free a slot), but only through the timelock.
    function test_link_thenDelete_viaTimelock() public {
        _linkAdapter();
        bytes memory data = abi.encodeCall(CreWorkflowOwner.deleteWorkflow, (bytes32(uint256(0x1234))));
        _scheduleAndExecute(address(ownerAdapter), data);
        assertTrue(registry.deleted());
    }

    // ──────────────────────────── delay + access ──────────────────────

    function test_executeBeforeDelayReverts() public {
        bytes memory data = _updateData(bytes32(uint256(1)));
        vm.prank(proposer);
        timelock.schedule(address(ownerAdapter), 0, data, bytes32(0), bytes32(0), DELAY);
        // no warp — not ready yet
        vm.prank(executor);
        vm.expectRevert(); // TimelockUnexpectedOperationState
        timelock.execute(address(ownerAdapter), 0, data, bytes32(0), bytes32(0));
    }

    function test_onlyProposerCanSchedule() public {
        bytes memory data = _updateData(bytes32(uint256(1)));
        vm.prank(stranger);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        timelock.schedule(address(ownerAdapter), 0, data, bytes32(0), bytes32(0), DELAY);
    }

    function test_updateWorkflow_onlyTimelock() public {
        _linkAdapter();
        vm.expectRevert(
            abi.encodeWithSelector(CreWorkflowOwner.CreWorkflowOwner__NotTimelock.selector, address(this))
        );
        ownerAdapter.updateWorkflow(bytes32(uint256(1)), "zone-a", "b", "c", bytes(""));
    }

    function test_deleteWorkflow_onlyTimelock() public {
        _linkAdapter();
        vm.expectRevert(
            abi.encodeWithSelector(CreWorkflowOwner.CreWorkflowOwner__NotTimelock.selector, address(this))
        );
        ownerAdapter.deleteWorkflow(bytes32(uint256(1)));
    }

    function test_linkSelfAsOwner_onlyTimelock() public {
        vm.expectRevert(
            abi.encodeWithSelector(CreWorkflowOwner.CreWorkflowOwner__NotTimelock.selector, address(this))
        );
        ownerAdapter.linkSelfAsOwner(block.timestamp + 1, bytes32("p"), bytes(""));
    }

    // ──────────── PAUSE unreachable; registry reachable only via the adapter ──────────

    /// @dev Even though the timelock CAN schedule a direct registry.pauseWorkflow call, it executes
    ///      with msg.sender = the timelock, which is NOT the linked owner (the adapter is) → reverts.
    function test_timelockCannotPauseWorkflow() public {
        _linkAdapter();
        bytes memory data = abi.encodeWithSignature("pauseWorkflow(bytes32)", bytes32(uint256(0x1234)));
        vm.prank(proposer);
        timelock.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        vm.expectRevert(); // inner MockWorkflowRegistry.NotLinked(timelock) bubbles up
        timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));
        assertFalse(registry.paused());
    }

    /// @dev The timelock cannot drive the registry DIRECTLY (bypassing the adapter): a registry call
    ///      scheduled through the timelock executes with msg.sender = the timelock, which is NOT the
    ///      linked owner → reverts. Shown with deleteWorkflow; the only legitimate delete path is the
    ///      adapter (test_link_thenDelete_viaTimelock).
    function test_timelockCannotCallRegistryDirectly() public {
        _linkAdapter();
        bytes memory data = abi.encodeWithSignature("deleteWorkflow(bytes32)", bytes32(uint256(0x1234)));
        vm.prank(proposer);
        timelock.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        vm.expectRevert(); // inner NotLinked(timelock) bubbles up — only the adapter is linked
        timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));
        assertFalse(registry.deleted());
    }

    /// @dev The adapter exposes NO pause symbol at all — a low-level call to the pause selector hits no
    ///      function (no fallback) and reverts, so pausing is structurally impossible. (Delete IS a real
    ///      adapter function, but onlyTimelock — see test_deleteWorkflow_onlyTimelock.)
    function test_adapterHasNoPauseSelector() public {
        _linkAdapter();
        (bool okPause, ) = address(ownerAdapter).call(
            abi.encodeWithSignature("pauseWorkflow(bytes32)", bytes32(uint256(1)))
        );
        assertFalse(okPause);
        assertFalse(registry.paused());
    }

    // ──────────────────────────── constructor guards ──────────────────

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(CreWorkflowOwner.CreWorkflowOwner__ZeroAddress.selector);
        new CreWorkflowOwner(address(0), address(timelock), WORKFLOW_NAME);
        vm.expectRevert(CreWorkflowOwner.CreWorkflowOwner__ZeroAddress.selector);
        new CreWorkflowOwner(address(registry), address(0), WORKFLOW_NAME);
    }

    function test_constructor_emptyNameReverts() public {
        vm.expectRevert(CreWorkflowOwner.CreWorkflowOwner__EmptyWorkflowName.selector);
        new CreWorkflowOwner(address(registry), address(timelock), "");
    }

    function test_pinnedNameIsReadable() public view {
        assertEq(ownerAdapter.s_workflowName(), WORKFLOW_NAME);
    }

    /// @dev A workflow name longer than 10 bytes is intentionally ALLOWED: CRE hashes the name
    ///      (SHA256, first 10 hex chars) into the bytes10 metadata field, so length is irrelevant — a
    ///      <=10-byte cap would wrongly reject valid CRE names (e.g. CRE's own "my_workflow", 11 bytes).
    function test_constructor_acceptsNameLongerThan10Bytes() public {
        string memory longName = "my_workflow_long"; // 16 bytes
        CreWorkflowOwner a = new CreWorkflowOwner(address(registry), address(timelock), longName);
        assertEq(a.s_workflowName(), longName);
    }
}
