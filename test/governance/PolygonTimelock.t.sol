// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployPolygonTimelock} from "../../script/DeployPolygonTimelock.s.sol";

/// @dev Something for the timelock to call.
contract Target {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }
}

/**
 * @notice Tests for script/DeployPolygonTimelock.s.sol.
 *
 *         With POLYGON_RPC_URL set they run on a fork of Polygon mainnet at FORK_BLOCK. Without it (CI has
 *         no RPC) the same tests run on a local chain that carries Polygon's chain id.
 *
 *         The script uses forge's recorded logs for its own read-back, which leaves none for a test to
 *         re-read, so these tests take a second witness: every storage write the deploy made to the
 *         timelock. A role granted to anyone, even for a moment, is a write to that role's slot.
 *
 *         The three "must never happen" tests each name the one-line break that turns them red.
 */
contract PolygonTimelockTest is Test {
    uint256 internal constant FORK_BLOCK = 95_730_000;
    uint256 internal constant DAY0 = 60;
    uint256 internal constant SEVEN_DAYS = 604_800;

    /// @dev Kept apart from the script's own constant. OpenZeppelin v5.5.0's TimelockController built with
    ///      this repo's foundry.toml, minus solc's 53-byte metadata trailer: the same on a Windows build, a
    ///      Linux build and a standalone compile of the verification input.
    bytes32 internal constant PINNED = 0xc3bc13a3ed744700e803d10a97d2d3305b017bd75c917bdc407a7fd02c0b944c;
    uint256 internal constant PINNED_LENGTH = 5448;

    bytes32 internal constant ADMIN = 0x00;
    bytes32 internal constant PROPOSER = keccak256("PROPOSER_ROLE");
    bytes32 internal constant CANCELLER = keccak256("CANCELLER_ROLE");
    bytes32 internal constant EXECUTOR = keccak256("EXECUTOR_ROLE");

    DeployPolygonTimelock internal script;
    Target internal target;
    address internal k = makeAddr("K");
    address internal stranger = makeAddr("stranger");
    /// @dev In a test, forge broadcasts from its default sender.
    address internal deployer = DEFAULT_SENDER;

    struct Write {
        bytes32 slot;
        bytes32 value;
    }

    function setUp() public {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length > 0) {
            vm.createSelectFork(rpc, FORK_BLOCK);
        } else {
            vm.chainId(137);
        }
        script = new DeployPolygonTimelock();
        target = new Target();
    }

    // ---------------------------------------------------------------------------------------------------
    // Must never happen
    // ---------------------------------------------------------------------------------------------------

    /// Must never happen 1: the deploy is sent from the key's address.
    /// Break: delete `require(k != sender, "K is the sender");` in run(). This goes red: the timelock is
    /// then built, and only the read-back refuses it, with "the deployer is K".
    function test_mustNever1_theKeyCannotSendTheDeploy() public {
        uint64 nonce = vm.getNonce(deployer);
        address wouldBe = vm.computeCreateAddress(deployer, nonce);

        vm.expectRevert(bytes("K is the sender"));
        script.run(deployer, 137, DAY0);

        assertEq(vm.getNonce(deployer), nonce, "nothing was sent");
        assertEq(wouldBe.code.length, 0, "no timelock was built");
    }

    /// Must never happen 1: the deployer keeps any role after deploy.
    /// Break: in run(), change the constructor's last argument from `address(0)` to `sender`. This goes
    /// red: the deployer is then an admin, and the read-back refuses it with "a role is not as ruled".
    function test_mustNever1_theDeployerHoldsNoRole() public {
        (TimelockController t, Write[] memory writes) = _deploy(DAY0);

        assertFalse(t.hasRole(ADMIN, deployer), "deployer is admin");
        assertFalse(t.hasRole(PROPOSER, deployer), "deployer proposes");
        assertFalse(t.hasRole(CANCELLER, deployer), "deployer cancels");
        assertFalse(t.hasRole(EXECUTOR, deployer), "deployer executes");
        // The only writes are the ruled five, so no role slot of the deployer's was ever set.
        _assertRuledWrites(t, writes, DAY0);
    }

    /// Must never happen 2: a scheduled call runs before the timelock's delay is up.
    /// Break: in run(), change the constructor's first argument from `delay` to `0`. This goes red: the
    /// timelock then has no delay, and the read-back refuses it with "delay is not the input".
    function test_mustNever2_aCallRunsOnlyOnceTheDelayIsUp() public {
        uint256[3] memory delays = [DAY0, 1 hours, SEVEN_DAYS];
        for (uint256 i; i < delays.length; ++i) {
            uint256 d = delays[i];
            (TimelockController t,) = _deploy(d);
            bytes memory call = abi.encodeCall(Target.set, (d));
            bytes32 salt = bytes32(i);
            bytes32 id = t.hashOperation(address(target), 0, call, bytes32(0), salt);

            // A shorter wait than the delay cannot be scheduled.
            vm.expectRevert(
                abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, d - 1, d)
            );
            vm.prank(k);
            t.schedule(address(target), 0, call, bytes32(0), salt, d - 1);

            vm.prank(k);
            t.schedule(address(target), 0, call, bytes32(0), salt, d);
            uint256 scheduledAt = block.timestamp;

            // One second short of the delay, nobody can run it.
            vm.warp(scheduledAt + d - 1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    TimelockController.TimelockUnexpectedOperationState.selector,
                    id,
                    bytes32(1 << uint8(TimelockController.OperationState.Ready))
                )
            );
            vm.prank(stranger);
            t.execute(address(target), 0, call, bytes32(0), salt);
            assertTrue(target.value() != d, "ran early");

            // Once the delay is up, anyone can.
            vm.warp(scheduledAt + d);
            vm.prank(stranger);
            t.execute(address(target), 0, call, bytes32(0), salt);
            assertEq(target.value(), d, "did not run once ready");
        }
    }

    /// Must never happen 3: anything other than the stock contract, with the ruled roles, is deployed.
    /// Break: in lib/openzeppelin-contracts/contracts/governance/TimelockController.sol, delete the line
    /// `_grantRole(CANCELLER_ROLE, proposers[i]);` (and restore it afterwards). This goes red: the build is
    /// then not the pinned one, and the run refuses it with "not the pinned build".
    function test_mustNever3_onlyTheStockContractWithTheRuledRoles() public {
        (TimelockController t, Write[] memory writes) = _deploy(DAY0);

        assertEq(address(t).code.length, PINNED_LENGTH, "code length");
        assertEq(_withoutTrailer(address(t).code), PINNED, "code is not the pinned build");
        _assertRuledRoles(t);
        _assertRuledWrites(t, writes, DAY0);
    }

    // ---------------------------------------------------------------------------------------------------
    // The timelock deploy's five lines, under "Must never happen" in docs/spec-v3.md
    // ---------------------------------------------------------------------------------------------------

    /// 1. A modified timelock, an unresolved library revision, or bytes other than the reviewed stock
    ///    artifact is deployed. v5.6.1 and v5.7.0 build to the same code as v5.5.0, so the release is
    ///    read from the library's package.json: with any other release checked out, every deploy in this
    ///    file is refused with "OpenZeppelin is not v5.5.0".
    function test_line1_theArtifactIsThePinnedStockBuild() public {
        assertEq(script.OPENZEPPELIN(), "5.5.0", "script's release");
        assertEq(
            vm.parseJsonString(vm.readFile("lib/openzeppelin-contracts/package.json"), ".version"),
            "5.5.0",
            "the library's release"
        );
        (TimelockController t,) = _deploy(DAY0);
        bytes memory code = address(t).code;
        assertEq(script.STOCK_CODE_HASH(), PINNED, "script's pin");
        assertEq(_withoutTrailer(code), PINNED, "deployed code");
        assertEq(script.stockHash(code), PINNED, "script's hash of the deployed code");

        // One changed byte of executable code is refused...
        bytes memory changed = bytes.concat(code);
        changed[100] = changed[100] ^ 0x01;
        assertTrue(script.stockHash(changed) != PINNED, "a changed opcode passes");
        vm.etch(address(t), changed);
        VmSafe.Log[] memory none;
        vm.expectRevert(bytes("not the pinned build"));
        script.verify(t, k, deployer, DAY0, none);

        // ...and so is a trailer of another length. Only the trailer's 32-byte source digest is not
        // compared: it hashes the source text, which changes with line endings.
        bytes memory digest = bytes.concat(code);
        digest[digest.length - 20] = digest[digest.length - 20] ^ 0x01;
        assertEq(script.stockHash(digest), PINNED, "the digest is compared");
        bytes memory longer = bytes.concat(code, hex"00");
        assertEq(script.stockHash(longer), bytes32(0), "a trailer of another length passes");
    }

    /// 2. Proposer or canceller is anything but exactly {K}, K is zero or the deployer, or either role goes
    ///    to the timelock or another address.
    function test_line2_proposerAndCancellerAreExactlyK() public {
        (TimelockController t, Write[] memory writes) = _deploy(DAY0);
        _assertRuledRoles(t);
        _assertRuledWrites(t, writes, DAY0);

        vm.expectRevert(bytes("K is missing"));
        script.run(address(0), 137, DAY0);
        vm.expectRevert(bytes("K is the sender"));
        script.run(deployer, 137, DAY0);

        // A second proposer is visible only in the logs: hasRole has no list of holders.
        address[] memory two = new address[](2);
        two[0] = k;
        two[1] = stranger;
        _expectVerifyRefuses(two, _list(address(0)), address(0), DAY0, "the timelock has other logs");

        // The timelock as its own proposer and canceller.
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.recordLogs();
        TimelockController selfProposer = new TimelockController(DAY0, _list(self), _list(address(0)), address(0));
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(address(selfProposer), self, "address prediction");
        vm.expectRevert(bytes("a role is not as ruled"));
        script.verify(selfProposer, self, address(this), DAY0, logs);
    }

    /// 3. Executor is anything but exactly {address(0)}, including an empty list that leaves ready calls
    ///    unrunnable.
    function test_line3_executorIsExactlyAddressZero() public {
        (TimelockController t,) = _deploy(DAY0);
        assertTrue(t.hasRole(EXECUTOR, address(0)), "zero executes");
        assertFalse(t.hasRole(EXECUTOR, k), "K executes");

        // Anyone can run a ready call.
        bytes memory call = abi.encodeCall(Target.set, (7));
        vm.prank(k);
        t.schedule(address(target), 0, call, bytes32(0), bytes32(0), DAY0);
        vm.warp(block.timestamp + DAY0);
        vm.prank(stranger);
        t.execute(address(target), 0, call, bytes32(0), bytes32(0));
        assertEq(target.value(), 7, "a stranger could not run a ready call");

        address[] memory empty = new address[](0);
        _expectVerifyRefuses(_list(k), empty, address(0), DAY0, "a role is not as ruled");
        _expectVerifyRefuses(_list(k), _list(k), address(0), DAY0, "a role is not as ruled");
        _expectVerifyRefuses(_list(k), _list(stranger), address(0), DAY0, "a role is not as ruled");
    }

    /// 4. Admin is anything but the timelock itself, the deployer holds any role even for a moment, or the
    ///    timelock's own admin is given up.
    function test_line4_adminIsTheTimelockAloneAndTheDeployerNeverHeldARole() public {
        (TimelockController t, Write[] memory writes) = _deploy(DAY0);
        assertTrue(t.hasRole(ADMIN, address(t)), "the timelock is not its own admin");
        assertFalse(t.hasRole(ADMIN, k), "K is admin");
        _assertRuledWrites(t, writes, DAY0);

        // The deployer as admin.
        _expectVerifyRefuses(_list(k), _list(address(0)), address(this), DAY0, "a role is not as ruled");

        // The deployer as admin for a moment, then renounced: hasRole is clean, the logs are not.
        vm.recordLogs();
        TimelockController moment = new TimelockController(DAY0, _list(k), _list(address(0)), address(this));
        moment.renounceRole(ADMIN, address(this));
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(moment.hasRole(ADMIN, address(this)), "renounce");
        vm.expectRevert(bytes("the timelock has other logs"));
        script.verify(moment, k, address(this), DAY0, logs);

        // The timelock gives up its own admin.
        vm.recordLogs();
        TimelockController orphan = new TimelockController(DAY0, _list(k), _list(address(0)), address(0));
        vm.prank(address(orphan));
        orphan.renounceRole(ADMIN, address(orphan));
        logs = vm.getRecordedLogs();
        vm.expectRevert(bytes("a role is not as ruled"));
        script.verify(orphan, k, address(this), DAY0, logs);
    }

    /// 5. The delay at deploy is other than the day-0 value, or a setup call changes the constructor's
    ///    roles or delay before handover.
    function test_line5_theDelayIsTheInputAndNothingChangedItBeforeHandover() public {
        uint256[5] memory delays = [uint256(1), DAY0, 1 hours, SEVEN_DAYS, 30 days];
        for (uint256 i; i < delays.length; ++i) {
            (TimelockController t, Write[] memory writes) = _deploy(delays[i]);
            assertEq(t.getMinDelay(), delays[i], "delay");
            _assertRuledWrites(t, writes, delays[i]);
        }

        vm.expectRevert(bytes("delay is missing"));
        script.run(k, 137, 0);

        // The right timelock read against another delay.
        vm.recordLogs();
        TimelockController ok = new TimelockController(DAY0, _list(k), _list(address(0)), address(0));
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        script.verify(ok, k, address(this), DAY0, logs);
        vm.expectRevert(bytes("delay is not the input"));
        script.verify(ok, k, address(this), DAY0 + 1, logs);

        // A setup call before handover: the delay set again to the same value, through the timelock.
        vm.recordLogs();
        TimelockController reset = new TimelockController(DAY0, _list(k), _list(address(0)), address(0));
        vm.prank(address(reset));
        reset.updateDelay(DAY0);
        logs = vm.getRecordedLogs();
        assertEq(reset.getMinDelay(), DAY0, "same delay");
        vm.expectRevert(bytes("the timelock has other logs"));
        script.verify(reset, k, address(this), DAY0, logs);

        // A call scheduled before handover.
        vm.recordLogs();
        TimelockController queued = new TimelockController(DAY0, _list(k), _list(address(0)), address(0));
        vm.prank(k);
        queued.schedule(address(target), 0, "", bytes32(0), bytes32(0), DAY0);
        logs = vm.getRecordedLogs();
        vm.expectRevert(bytes("the timelock has other logs"));
        script.verify(queued, k, address(this), DAY0, logs);
    }

    // ---------------------------------------------------------------------------------------------------
    // Inputs, and the delay's own path
    // ---------------------------------------------------------------------------------------------------

    function test_inputs_eachMissingInputIsRefused() public {
        vm.expectRevert(bytes("K is missing"));
        script.run(address(0), 137, DAY0);
        vm.expectRevert(bytes("chain id is missing"));
        script.run(k, 0, DAY0);
        vm.expectRevert(bytes("delay is missing"));
        script.run(k, 137, 0);
        // All three present: it deploys.
        TimelockController t = script.run(k, 137, DAY0);
        assertEq(t.getMinDelay(), DAY0, "deployed");
    }

    function test_inputs_anyChainButPolygonIsRefused() public {
        vm.expectRevert(bytes("chain id is not 137"));
        script.run(k, 80002, DAY0);
        vm.expectRevert(bytes("chain id is not 137"));
        script.run(k, 1, DAY0);

        vm.chainId(80002);
        vm.expectRevert(bytes("the RPC is not on chain 137"));
        script.run(k, 137, DAY0);
        vm.expectRevert(bytes("the RPC is not on chain 137"));
        script.check(TimelockController(payable(address(1))), k, deployer, DAY0, 0);
    }

    /// The delay changes only through the timelock and its own delay: the launch-list step that raises
    /// the day-0 minute to seven days.
    function test_theDelayRisesOnlyThroughItself() public {
        (TimelockController t,) = _deploy(DAY0);

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, k));
        vm.prank(k);
        t.updateDelay(SEVEN_DAYS);

        bytes memory raise = abi.encodeCall(TimelockController.updateDelay, (SEVEN_DAYS));
        vm.prank(k);
        t.schedule(address(t), 0, raise, bytes32(0), bytes32(0), DAY0);
        vm.warp(block.timestamp + DAY0);
        vm.prank(stranger);
        t.execute(address(t), 0, raise, bytes32(0), bytes32(0));
        assertEq(t.getMinDelay(), SEVEN_DAYS, "raised");

        // From then on a call needs the seven days.
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, DAY0, SEVEN_DAYS)
        );
        vm.prank(k);
        t.schedule(address(target), 0, "", bytes32(0), bytes32(uint256(1)), DAY0);
    }

    /// With POLYGON_RPC_URL set, these tests run on Polygon itself: the pinned block, with Polygon's USDC
    /// there. Without it the test is skipped, which is how CI reports that no fork was used.
    function test_fork_isPolygonWhenAnRpcIsGiven() public {
        assertEq(block.chainid, 137, "chain id");
        if (bytes(vm.envOr("POLYGON_RPC_URL", string(""))).length == 0) vm.skip(true);
        assertEq(block.number, FORK_BLOCK, "fork block");
        assertGt(address(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359).code.length, 0, "Polygon's USDC");
    }

    // ---------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------

    function _deploy(uint256 delay) internal returns (TimelockController t, Write[] memory writes) {
        vm.startStateDiffRecording();
        t = script.run(k, 137, delay);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        uint256 n;
        for (uint256 i; i < diff.length; ++i) {
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory s = diff[i].storageAccesses[j];
                if (s.account == address(t) && s.isWrite && !s.reverted) ++n;
            }
        }
        writes = new Write[](n);
        n = 0;
        for (uint256 i; i < diff.length; ++i) {
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory s = diff[i].storageAccesses[j];
                if (s.account == address(t) && s.isWrite && !s.reverted) writes[n++] = Write(s.slot, s.newValue);
            }
        }
    }

    /// @dev AccessControl keeps `_roles` at slot 0; a role's holder flag sits at
    ///      keccak256(account . keccak256(role . 0)). TimelockController keeps `_minDelay` at slot 2.
    function _roleSlot(bytes32 role, address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, keccak256(abi.encode(role, uint256(0)))));
    }

    /// @dev The stock constructor's five writes for the ruled layout, in its order, and no others.
    function _assertRuledWrites(TimelockController t, Write[] memory w, uint256 delay) internal view {
        assertEq(w.length, 5, "the deploy wrote other storage");
        bytes32 one = bytes32(uint256(1));
        assertEq(w[0].slot, _roleSlot(ADMIN, address(t)), "write 0 slot");
        assertEq(w[0].value, one, "write 0 value");
        assertEq(w[1].slot, _roleSlot(PROPOSER, k), "write 1 slot");
        assertEq(w[1].value, one, "write 1 value");
        assertEq(w[2].slot, _roleSlot(CANCELLER, k), "write 2 slot");
        assertEq(w[2].value, one, "write 2 value");
        assertEq(w[3].slot, _roleSlot(EXECUTOR, address(0)), "write 3 slot");
        assertEq(w[3].value, one, "write 3 value");
        assertEq(w[4].slot, bytes32(uint256(2)), "write 4 slot");
        assertEq(w[4].value, bytes32(delay), "write 4 value");
    }

    /// @dev The ruled roles, read from the contract. Rows: K, address(0), the timelock, the deployer,
    ///      a stranger. Columns: proposer, canceller, executor, admin.
    function _assertRuledRoles(TimelockController t) internal view {
        address[5] memory who = [k, address(0), address(t), deployer, stranger];
        bytes32[4] memory roles = [PROPOSER, CANCELLER, EXECUTOR, ADMIN];
        bool[4][5] memory ruled = [
            [true, true, false, false],
            [false, false, true, false],
            [false, false, false, true],
            [false, false, false, false],
            [false, false, false, false]
        ];
        for (uint256 i; i < who.length; ++i) {
            for (uint256 j; j < roles.length; ++j) {
                assertEq(t.hasRole(roles[j], who[i]), ruled[i][j], "role");
            }
        }
    }

    /// @dev Builds a timelock from this test contract with the given arguments and expects the script's
    ///      read-back to refuse it for `reason`, reading it against K, this contract as deployer and DAY0.
    function _expectVerifyRefuses(
        address[] memory proposers,
        address[] memory executors,
        address admin,
        uint256 delay,
        string memory reason
    ) internal {
        vm.recordLogs();
        TimelockController t = new TimelockController(delay, proposers, executors, admin);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        vm.expectRevert(bytes(reason));
        script.verify(t, k, address(this), DAY0, logs);
    }

    /// @dev keccak256 of `code` without its last 53 bytes, written apart from the script's stockHash.
    function _withoutTrailer(bytes memory code) internal pure returns (bytes32 h) {
        bytes memory body = new bytes(code.length - 53);
        for (uint256 i; i < body.length; ++i) {
            body[i] = code[i];
        }
        h = keccak256(body);
    }

    function _list(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
