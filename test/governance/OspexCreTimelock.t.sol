// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OspexCreTimelock} from "../../src/governance/OspexCreTimelock.sol";

/// @dev Stand-in for the CRE WorkflowRegistry. Two functions whose selectors model the two lanes:
///      `codeOp` = a workflow-code/lifecycle op (the SLOW lane — inherits the global default);
///      `keyOp`  = the registry's `allowlistRequest` key op (the FAST lane — explicit 1s carve-out).
contract MockRegistry {
    uint256 public lastCode;
    bytes32 public lastKey;

    function codeOp(uint256 v) external {
        lastCode = v;
    }

    function keyOp(bytes32 digest, uint256 /*expiry*/ ) external {
        lastKey = digest;
    }

    /// @dev A target call that reverts — to exercise the timelock's `_execute` failure branch.
    function boom() external pure {
        revert("boom");
    }
}

/// @notice Tests for the Ospex per-action timelock. Focus = the TWO-line `[OSPEX]` modification
///         (default-slow per-selector delays with a sub-global fast carve-out) and the security
///         guarantees that make the 7-day code delay real (ADMIN = the timelock itself, so the rules
///         can't be instantly stripped). Upstream schedule/execute/hashing mechanics are byte-for-byte
///         Chainlink (already audited) and are exercised end-to-end by the lane tests below.
contract OspexCreTimelockTest is Test {
    OspexCreTimelock internal tl;
    MockRegistry internal reg;

    address internal safe = makeAddr("safe"); // 2-of-3 Safe stand-in (proposer/executor/canceller)
    address internal stranger = makeAddr("stranger");

    uint256 internal constant CODE_DELAY = 7 days;
    bytes32 internal constant NO_PRED = bytes32(0);

    bytes4 internal codeSel = MockRegistry.codeOp.selector;
    bytes4 internal keySel = MockRegistry.keyOp.selector;
    bytes4 internal updateGlobalSel = bytes4(keccak256("updateDelay(uint256)"));

    function setUp() public {
        reg = new MockRegistry();
        tl = _deployProductionLike();
    }

    // Mirrors the mainnet deploy/bootstrap/lockdown sequence:
    //   deploy global=0 (so bootstrap is instant) -> set global=7d + keyOp=1s -> ADMIN to self,
    //   deployer renounces. After this the Safe holds only proposer/executor/canceller.
    function _deployProductionLike() internal returns (OspexCreTimelock t) {
        // PHASE 1 — bootstrap state: admin = the deployer (this) ONLY; NO proposers/executors/cancellers
        // yet, so during the global=0 window only the deployer key can act (tightest exposure).
        address[] memory none = new address[](0);
        t = new OspexCreTimelock(0, address(this), none, none, none);

        // the two config numbers (admin = this -> direct, instant)
        t.updateDelay(CODE_DELAY); // global default = 7 days (everything inherits this)
        OspexCreTimelock.UpdateDelayParams[] memory p = new OspexCreTimelock.UpdateDelayParams[](1);
        p[0] = OspexCreTimelock.UpdateDelayParams({target: address(reg), selector: keySel, newDelay: 1});
        t.updateDelay(p); // key op = ~instant (1s)

        // PHASE 3 lockdown — grant the Safe its operational roles (AFTER the delay is raised), hand ADMIN
        // to the timelock itself, deployer renounces ADMIN.
        t.grantRole(t.PROPOSER_ROLE(), safe);
        t.grantRole(t.EXECUTOR_ROLE(), safe);
        t.grantRole(t.CANCELLER_ROLE(), safe);
        t.grantRole(t.ADMIN_ROLE(), address(t));
        t.renounceRole(t.ADMIN_ROLE(), address(this));
    }

    function _calls(address target, bytes memory data)
        internal
        pure
        returns (OspexCreTimelock.Call[] memory c)
    {
        c = new OspexCreTimelock.Call[](1);
        c[0] = OspexCreTimelock.Call({target: target, value: 0, data: data});
    }

    // ----------------------- the [OSPEX] per-action delay logic -----------------------

    function test_unsetSelectorInheritsGlobalDefault() public view {
        // code op + an arbitrary selector both inherit the 7-day global (default-SLOW / fail-safe)
        assertEq(tl.getMinDelay(address(reg), codeSel), CODE_DELAY);
        assertEq(tl.getMinDelay(address(reg), bytes4(0xdeadbeef)), CODE_DELAY);
        assertEq(tl.getMinDelay(), CODE_DELAY);
    }

    function test_keySelectorIsSubGlobalFastCarveOut() public view {
        // the one explicit carve-out: below the global default (impossible under upstream's max())
        assertEq(tl.getMinDelay(address(reg), keySel), 1);
    }

    function test_setDelayRevertsOnZero() public {
        // 0 is reserved to mean "inherit the default", so the setter must reject it.
        OspexCreTimelock t = _freshAdminHeld();
        OspexCreTimelock.UpdateDelayParams[] memory p = new OspexCreTimelock.UpdateDelayParams[](1);
        p[0] = OspexCreTimelock.UpdateDelayParams({target: address(reg), selector: keySel, newDelay: 0});
        vm.expectRevert("Timelock: use >0 (0 means inherit default)");
        t.updateDelay(p);
    }

    // ----------------------- lane enforcement (end-to-end schedule/execute) -----------------------

    function test_keyLane_executesInOneSecond() public {
        OspexCreTimelock.Call[] memory c =
            _calls(address(reg), abi.encodeCall(MockRegistry.keyOp, (bytes32(uint256(7)), uint256(0))));
        bytes32 salt = keccak256("key");

        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, 1); // 1s delay permitted for the key selector
        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        tl.executeBatch(c, NO_PRED, salt);

        assertEq(reg.lastKey(), bytes32(uint256(7)));
    }

    function test_codeLane_requiresFullSevenDays() public {
        OspexCreTimelock.Call[] memory c =
            _calls(address(reg), abi.encodeCall(MockRegistry.codeOp, (uint256(42))));
        bytes32 salt = keccak256("code");

        // cannot schedule below the inherited 7-day delay
        vm.prank(safe);
        vm.expectRevert("Timelock: insufficient delay");
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY - 1);

        // schedule at exactly 7 days
        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);

        // not executable before the delay elapses
        vm.warp(block.timestamp + CODE_DELAY - 1);
        vm.prank(safe);
        vm.expectRevert("Timelock: operation is not ready");
        tl.executeBatch(c, NO_PRED, salt);

        // executes after 7 days
        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        tl.executeBatch(c, NO_PRED, salt);
        assertEq(reg.lastCode(), 42);
    }

    function test_nonProposerCannotSchedule() public {
        OspexCreTimelock.Call[] memory c =
            _calls(address(reg), abi.encodeCall(MockRegistry.keyOp, (bytes32(0), uint256(0))));
        vm.prank(stranger);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        tl.scheduleBatch(c, NO_PRED, keccak256("x"), 1);
    }

    function test_cancellerCanCancelPending() public {
        OspexCreTimelock.Call[] memory c =
            _calls(address(reg), abi.encodeCall(MockRegistry.codeOp, (uint256(1))));
        bytes32 salt = keccak256("cancel");

        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
        bytes32 id = tl.hashOperationBatch(c, NO_PRED, salt);
        assertTrue(tl.isOperationPending(id));

        vm.prank(safe);
        tl.cancel(id);
        assertFalse(tl.isOperation(id));
    }

    // ----------------------- ADMIN = self: the 7-day code delay is REAL -----------------------

    function test_safeIsNotAdmin_cannotChangeRulesDirectly() public {
        assertFalse(tl.hasRole(tl.ADMIN_ROLE(), safe));
        assertTrue(tl.hasRole(tl.ADMIN_ROLE(), address(tl))); // self-administered

        vm.prank(safe);
        vm.expectRevert(); // onlyRole(ADMIN_ROLE)
        tl.updateDelay(1); // a proposer cannot instantly shrink the global delay
    }

    function test_strippingTheCodeDelayItselfTakesSevenDays() public {
        // A compromised proposer can't fast-track code: even changing the delay is a self-call that
        // inherits the 7-day default, so it can't take effect instantly.
        assertEq(tl.getMinDelay(address(tl), updateGlobalSel), CODE_DELAY);

        OspexCreTimelock.Call[] memory c =
            _calls(address(tl), abi.encodeWithSignature("updateDelay(uint256)", uint256(1)));
        vm.prank(safe);
        vm.expectRevert("Timelock: insufficient delay");
        tl.scheduleBatch(c, NO_PRED, keccak256("strip"), CODE_DELAY - 1);
    }

    function test_selfAdmin_canChangeRulesAfterTheDelay() public {
        // The positive side: the timelock CAN change its own rules — just slowly + observably.
        OspexCreTimelock.Call[] memory c =
            _calls(address(tl), abi.encodeWithSignature("updateDelay(uint256)", uint256(3 days)));
        bytes32 salt = keccak256("lower");

        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
        vm.warp(block.timestamp + CODE_DELAY);
        vm.prank(safe);
        tl.executeBatch(c, NO_PRED, salt); // timelock calls itself -> updateDelay(3 days)

        assertEq(tl.getMinDelay(), 3 days);
    }

    // ----------------------- batch-mixing: a fast op never speeds up a slow op -----------------------

    function test_batchMix_keyOpDoesNotSpeedUpCodeOp() public {
        OspexCreTimelock.Call[] memory c = new OspexCreTimelock.Call[](2);
        c[0] = OspexCreTimelock.Call({
            target: address(reg),
            value: 0,
            data: abi.encodeCall(MockRegistry.keyOp, (bytes32(uint256(1)), uint256(0)))
        });
        c[1] = OspexCreTimelock.Call({
            target: address(reg),
            value: 0,
            data: abi.encodeCall(MockRegistry.codeOp, (uint256(9)))
        });
        bytes32 salt = keccak256("mix");

        // the batch delay is the LARGEST member: max(1s, 7d) = 7d
        assertEq(tl.getMinDelay(c), CODE_DELAY);

        vm.prank(safe);
        vm.expectRevert("Timelock: insufficient delay");
        tl.scheduleBatch(c, NO_PRED, salt, 1);

        vm.prank(safe);
        vm.expectRevert("Timelock: insufficient delay");
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY - 1);

        // only at the full 7 days does it schedule + (after the wait) execute
        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
        vm.warp(block.timestamp + CODE_DELAY);
        vm.prank(safe);
        tl.executeBatch(c, NO_PRED, salt);
        assertEq(reg.lastCode(), 9);
    }

    // ----------------------- lockdown invariant (the whole guarantee rests on this) -----------------------

    function test_lockdownInvariant_soleAdminIsTheTimelock() public view {
        bytes32 adminRole = tl.ADMIN_ROLE();
        assertEq(tl.getRoleMemberCount(adminRole), 1);
        assertEq(tl.getRoleMember(adminRole, 0), address(tl));
        assertFalse(tl.hasRole(adminRole, address(this))); // deployer renounced
        assertFalse(tl.hasRole(adminRole, safe));
        // the Safe holds EXACTLY the operational roles; the deployer holds none
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), safe));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), safe));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), safe));
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), address(this)));
        assertFalse(tl.hasRole(tl.EXECUTOR_ROLE(), address(this)));
        assertFalse(tl.hasRole(tl.CANCELLER_ROLE(), address(this)));
    }

    // ----------------------- scheduling / role-gating edges -----------------------

    function test_doubleScheduleReverts() public {
        OspexCreTimelock.Call[] memory c = _calls(address(reg), abi.encodeCall(MockRegistry.codeOp, (uint256(1))));
        bytes32 salt = keccak256("dup");
        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
        vm.prank(safe);
        vm.expectRevert("Timelock: operation already scheduled");
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
    }

    function test_nonExecutorCannotExecute() public {
        OspexCreTimelock.Call[] memory c =
            _calls(address(reg), abi.encodeCall(MockRegistry.keyOp, (bytes32(0), uint256(0))));
        bytes32 salt = keccak256("exec");
        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, 1);
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        vm.expectRevert(); // not EXECUTOR
        tl.executeBatch(c, NO_PRED, salt);
    }

    function test_nonCancellerCannotCancel() public {
        OspexCreTimelock.Call[] memory c = _calls(address(reg), abi.encodeCall(MockRegistry.codeOp, (uint256(1))));
        bytes32 salt = keccak256("can");
        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
        bytes32 id = tl.hashOperationBatch(c, NO_PRED, salt);
        vm.prank(stranger);
        vm.expectRevert(); // not CANCELLER
        tl.cancel(id);
    }

    function test_predecessorMustBeDoneFirst() public {
        OspexCreTimelock.Call[] memory cA =
            _calls(address(reg), abi.encodeCall(MockRegistry.keyOp, (bytes32(uint256(1)), uint256(0))));
        bytes32 saltA = keccak256("A");
        bytes32 idA = tl.hashOperationBatch(cA, NO_PRED, saltA);
        OspexCreTimelock.Call[] memory cB =
            _calls(address(reg), abi.encodeCall(MockRegistry.keyOp, (bytes32(uint256(2)), uint256(0))));
        bytes32 saltB = keccak256("B");

        vm.startPrank(safe);
        tl.scheduleBatch(cA, NO_PRED, saltA, 1);
        tl.scheduleBatch(cB, idA, saltB, 1); // B depends on A
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Timelock: missing dependency");
        tl.executeBatch(cB, idA, saltB); // A not done yet
        tl.executeBatch(cA, NO_PRED, saltA);
        tl.executeBatch(cB, idA, saltB);
        vm.stopPrank();
        assertEq(reg.lastKey(), bytes32(uint256(2)));
    }

    // ----------------------- rule changes via the timelock are themselves delayed -----------------------

    function test_selfAdmin_addProposerTakesSevenDays() public {
        address newProposer = makeAddr("newProposer");
        bytes memory data = abi.encodeWithSignature("grantRole(bytes32,address)", tl.PROPOSER_ROLE(), newProposer);
        OspexCreTimelock.Call[] memory c = _calls(address(tl), data);
        bytes32 salt = keccak256("addprop");

        // grantRole on the timelock is unset -> inherits the 7-day default
        assertEq(tl.getMinDelay(address(tl), bytes4(keccak256("grantRole(bytes32,address)"))), CODE_DELAY);

        vm.prank(safe);
        vm.expectRevert("Timelock: insufficient delay");
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY - 1);

        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY);
        vm.warp(block.timestamp + CODE_DELAY);
        vm.prank(safe);
        tl.executeBatch(c, NO_PRED, salt);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), newProposer));
    }

    function test_canReconfigureAlreadySetSelector() public {
        OspexCreTimelock t = _freshAdminHeld();
        OspexCreTimelock.UpdateDelayParams[] memory p = new OspexCreTimelock.UpdateDelayParams[](1);
        p[0] = OspexCreTimelock.UpdateDelayParams({target: address(reg), selector: keySel, newDelay: 1});
        t.updateDelay(p);
        assertEq(t.getMinDelay(address(reg), keySel), 1);
        p[0].newDelay = 3 days; // re-point to another positive value
        t.updateDelay(p);
        assertEq(t.getMinDelay(address(reg), keySel), 3 days);
    }

    // ----------------------- bootstrap window semantics (global = 0) -----------------------

    function test_bootstrapWindow_unsetIsInstantWhenGlobalZero() public {
        address[] memory none = new address[](0);
        OspexCreTimelock t = new OspexCreTimelock(0, address(this), none, none, none);
        // during bootstrap the global is 0, so unset selectors inherit 0 -> instant (intended +
        // documented; this is WHY the Safe gets no roles until the delay is raised).
        assertEq(t.getMinDelay(address(reg), codeSel), 0);
        assertEq(t.getMinDelay(), 0);
    }

    // ----------------------- coverage: reachable branches (execute revert, cancel/view edges) -----------------------

    function test_execute_revertsIfUnderlyingCallReverts() public {
        OspexCreTimelock.Call[] memory c = _calls(address(reg), abi.encodeCall(MockRegistry.boom, ()));
        bytes32 salt = keccak256("boom");
        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, CODE_DELAY); // boom selector unset -> inherits 7d
        vm.warp(block.timestamp + CODE_DELAY);
        vm.prank(safe);
        vm.expectRevert("Timelock: underlying transaction reverted");
        tl.executeBatch(c, NO_PRED, salt);
    }

    function test_cancel_revertsIfNotPending() public {
        OspexCreTimelock.Call[] memory c = _calls(address(reg), abi.encodeCall(MockRegistry.codeOp, (uint256(1))));
        bytes32 id = tl.hashOperationBatch(c, NO_PRED, keccak256("never-scheduled"));
        vm.prank(safe);
        vm.expectRevert("Timelock: operation cannot be cancelled");
        tl.cancel(id);
    }

    function test_getMinDelay_revertsOnUnder4ByteCalldata() public {
        OspexCreTimelock.Call[] memory c = _calls(address(reg), hex"001122"); // 3 bytes < 4-byte selector
        vm.expectRevert();
        tl.getMinDelay(c);
    }

    function test_adminBypass_adminCanScheduleWithoutProposerRole() public {
        // admin "automatically inhabits all other roles" via onlyRoleOrAdminRole -> the deployer/admin
        // can drive the bootstrap ops without holding PROPOSER. (global=0 here so it's instant.)
        address[] memory only = new address[](1);
        only[0] = safe;
        OspexCreTimelock t = new OspexCreTimelock(0, address(this), only, only, only);
        assertFalse(t.hasRole(t.PROPOSER_ROLE(), address(this)));

        // realistic timestamp so a delay-0 op (the bootstrap pattern) isn't confused with
        // _DONE_TIMESTAMP (=1) at forge's default block.timestamp of 1
        vm.warp(1_000_000);
        OspexCreTimelock.Call[] memory c = _calls(address(reg), abi.encodeCall(MockRegistry.codeOp, (uint256(5))));
        bytes32 salt = keccak256("adminbypass");
        t.scheduleBatch(c, NO_PRED, salt, 0); // this = admin, not proposer -> admin-bypass branch
        t.executeBatch(c, NO_PRED, salt);
        assertEq(reg.lastCode(), 5);
    }

    function test_updateDelayParams_revertsForNonAdmin() public {
        OspexCreTimelock.UpdateDelayParams[] memory p = new OspexCreTimelock.UpdateDelayParams[](1);
        p[0] = OspexCreTimelock.UpdateDelayParams({target: address(reg), selector: keySel, newDelay: 5});
        vm.prank(safe); // proposer, NOT admin
        vm.expectRevert();
        tl.updateDelay(p);
    }

    function test_operationLifecycleViewHelpers() public {
        OspexCreTimelock.Call[] memory c =
            _calls(address(reg), abi.encodeCall(MockRegistry.keyOp, (bytes32(uint256(3)), uint256(0))));
        bytes32 salt = keccak256("lifecycle");
        bytes32 id = tl.hashOperationBatch(c, NO_PRED, salt);

        assertFalse(tl.isOperation(id));
        assertEq(tl.getTimestamp(id), 0);

        vm.prank(safe);
        tl.scheduleBatch(c, NO_PRED, salt, 1);
        assertTrue(tl.isOperation(id));
        assertTrue(tl.isOperationPending(id));
        assertFalse(tl.isOperationReady(id));
        assertFalse(tl.isOperationDone(id));

        vm.warp(block.timestamp + 1);
        assertTrue(tl.isOperationReady(id));

        vm.prank(safe);
        tl.executeBatch(c, NO_PRED, salt);
        assertTrue(tl.isOperationDone(id));
        assertFalse(tl.isOperationPending(id));
        assertEq(tl.getTimestamp(id), 1); // _DONE_TIMESTAMP
    }

    function test_receive_acceptsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(tl).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(tl).balance, 1 ether);
    }

    // ----------------------- helper -----------------------

    /// @dev A timelock where THIS test contract keeps ADMIN (no lockdown) — for exercising
    ///      admin-only setters directly.
    function _freshAdminHeld() internal returns (OspexCreTimelock t) {
        address[] memory one = new address[](1);
        one[0] = safe;
        t = new OspexCreTimelock(CODE_DELAY, address(this), one, one, one);
    }
}
