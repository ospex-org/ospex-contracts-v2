// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

    /// @dev Kept apart from the script's own constants. The frozen artifact: OpenZeppelin v5.5.0's
    ///      TimelockController with LF source text, built by solc 0.8.26 with this repo's foundry.toml and
    ///      remappings.txt, every byte hashed, the metadata included.
    bytes32 internal constant EXACT_INIT = 0x352e04ba86c69a442bc4b3d0d009723eb1677dd9a81e9731a48befbd1fa11b4a;
    bytes32 internal constant EXACT_CODE = 0x1f4a487e94bf4ae08bcad7a0fda749625eb1fb682e5edd89400ee412b93833e7;
    /// @dev The same two with the 32-byte source digest in the metadata zeroed: every executable byte.
    bytes32 internal constant PINNED_INIT = 0x06e4a76c9b1409ecf842a8bb6d4a1e17eb1d2514f0a08c3f090ab894ee4ff757;
    bytes32 internal constant PINNED_CODE = 0x2ded0b376fdbd407ed64919fa8ebf624dcd3ee6a65293a08bce7cee8cad2231a;
    uint256 internal constant INIT_LENGTH = 6753;
    uint256 internal constant CODE_LENGTH = 5448;

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
    /// then built, and only the read-back refuses it, with "a role is not as ruled".
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
        (TimelockController t, Write[] memory writes, bytes memory sent) = _deployRecorded(DAY0);
        bytes memory runtime = address(t).code;

        // What was sent: the pinned creation code, then the four ruled constructor arguments.
        bytes memory args = abi.encode(DAY0, _list(k), _list(address(0)), address(0));
        assertEq(sent.length, INIT_LENGTH + args.length, "init code length");
        assertEq(_masked(_slice(sent, 0, INIT_LENGTH), runtime), PINNED_INIT, "creation code is not the pinned build");
        assertEq(keccak256(_slice(sent, 0, INIT_LENGTH)), EXACT_INIT, "creation code is not the frozen artifact");
        assertEq(_slice(sent, INIT_LENGTH, args.length), args, "constructor arguments");

        // What is there: the pinned runtime code, the ruled roles, and nothing else written.
        assertEq(runtime.length, CODE_LENGTH, "code length");
        assertEq(_masked(runtime, runtime), PINNED_CODE, "code is not the pinned build");
        assertEq(keccak256(runtime), EXACT_CODE, "code is not the frozen artifact");
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
        assertEq(script.EXACT_INIT_HASH(), EXACT_INIT, "script's creation-code pin");
        assertEq(script.EXACT_CODE_HASH(), EXACT_CODE, "script's runtime-code pin");
        assertEq(script.STOCK_INIT_HASH(), PINNED_INIT, "script's executable creation-code pin");
        assertEq(script.STOCK_CODE_HASH(), PINNED_CODE, "script's executable runtime-code pin");
        (TimelockController t,) = _deploy(DAY0);
        bytes memory code = address(t).code;
        bytes memory init = type(TimelockController).creationCode;
        // This build is the frozen artifact, every byte, and so is what the deploy left on chain.
        assertEq(keccak256(init), EXACT_INIT, "the build's creation code is not the frozen artifact");
        assertEq(keccak256(code), EXACT_CODE, "the deployed code is not the frozen artifact");
        assertEq(script.stockHash(code), PINNED_CODE, "script's hash of the deployed code");
        assertEq(script.stockHash(init), PINNED_INIT, "script's hash of the creation code");

        // A changed byte outside the source digest is refused: in the code...
        bytes memory changed = bytes.concat(code);
        changed[100] = changed[100] ^ 0x01;
        assertTrue(script.stockHash(changed) != PINNED_CODE, "a changed opcode passes");
        vm.etch(address(t), changed);
        VmSafe.Log[] memory none;
        vm.expectRevert(bytes("not the pinned build"));
        script.verify(t, k, deployer, DAY0, none);
        // ...in the metadata's compiler version (its last byte sits 3 from the end)...
        bytes memory compiler = bytes.concat(code);
        compiler[compiler.length - 3] = compiler[compiler.length - 3] ^ 0x01;
        assertTrue(script.stockHash(compiler) != PINNED_CODE, "another compiler version passes");
        // ...and in the constructor.
        bytes memory constructorChanged = bytes.concat(init);
        constructorChanged[100] = constructorChanged[100] ^ 0x01;
        assertTrue(script.stockHash(constructorChanged) != PINNED_INIT, "a changed constructor passes");

        // Code with no metadata section, or with two, is refused.
        bytes memory bare = bytes.concat(code);
        bare[bare.length - 53] = 0x00;
        assertEq(script.stockHash(bare), bytes32(0), "code with no metadata section passes");
        assertEq(script.stockHash(bytes.concat(code, code)), bytes32(0), "code with two sections passes");

        // A changed source digest is refused too. The executable-code hash does not see it; the exact
        // hash does.
        bytes memory digest = bytes.concat(code);
        digest[digest.length - 20] = digest[digest.length - 20] ^ 0x01;
        assertEq(script.stockHash(digest), PINNED_CODE, "the executable-code hash sees the digest");
        vm.etch(address(t), digest);
        vm.expectRevert(bytes("the metadata is not the pinned build's"));
        script.verify(t, k, deployer, DAY0, none);
        // Control: with the deployed code put back, both code checks pass and the read-back reaches the
        // logs, of which none were given.
        vm.etch(address(t), code);
        vm.expectRevert(bytes("the timelock has other logs"));
        script.verify(t, k, deployer, DAY0, none);

        // The run refuses a changed build before it creates anything: a changed constructor byte, and a
        // changed source digest, in the creation code the script carries.
        _expectRunRefusesBeforeBuilding(100, "not the pinned build");
        _expectRunRefusesBeforeBuilding(_offsetOf(init, _digest(code)), "the metadata is not the pinned build's");
    }

    /// run() reads the deployed contract back before it returns; the verify() tests above show what the
    /// read-back refuses. (A wrong answer cannot be mocked in: forge puts code at a mocked address, and
    /// the deploy then collides with it.)
    function test_readBack_runReadsTheDeployedContract() public {
        address next = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.expectCall(next, abi.encodeCall(TimelockController.getMinDelay, ()), 1);
        vm.expectCall(next, abi.encodeCall(IAccessControl.hasRole, (PROPOSER, k)), 1);
        vm.expectCall(next, abi.encodeCall(IAccessControl.hasRole, (ADMIN, deployer)), 1);
        assertEq(address(script.run(k, 137, DAY0)), next, "deployed there");
    }

    /// The read-back compares every field of every log, in order. Built from this test contract, so
    /// the deployer is address(this).
    function test_readBack_everyLogFieldIsCompared() public {
        vm.recordLogs();
        TimelockController t = new TimelockController(DAY0, _list(k), _list(address(0)), address(0));
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        script.verify(t, k, address(this), DAY0, logs);

        // A deployer named wrongly holds no role either; only the logs' sender field shows it.
        vm.expectRevert(bytes("a role log is not as ruled"));
        script.verify(t, k, stranger, DAY0, logs);

        for (uint256 i; i < logs.length; ++i) {
            string memory reason = i < 4 ? "a role log is not as ruled" : "the delay log is not as ruled";
            VmSafe.Log[] memory bad = _copy(logs);
            bad[i].emitter = stranger;
            _expectRefused(t, bad, reason);

            for (uint256 j; j < logs[i].topics.length; ++j) {
                bad = _copy(logs);
                bad[i].topics[j] = bytes32(uint256(bad[i].topics[j]) ^ 1);
                _expectRefused(t, bad, reason);
            }

            bad = _copy(logs);
            bytes32[] memory fewer = new bytes32[](logs[i].topics.length - 1);
            for (uint256 j; j < fewer.length; ++j) {
                fewer[j] = logs[i].topics[j];
            }
            bad[i].topics = fewer;
            _expectRefused(t, bad, reason);

            bad = _copy(logs);
            bad[i].data = bytes.concat(bad[i].data, hex"00");
            _expectRefused(t, bad, reason);
        }

        VmSafe.Log[] memory swapped = _copy(logs);
        (swapped[1], swapped[2]) = (swapped[2], swapped[1]);
        _expectRefused(t, swapped, "a role log is not as ruled");

        VmSafe.Log[] memory otherDelay = _copy(logs);
        otherDelay[4].data = abi.encode(uint256(0), DAY0 + 1);
        _expectRefused(t, otherDelay, "the delay log is not as ruled");
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
        (t, writes,) = _deployRecorded(delay);
    }

    /// @dev Deploys through the script and returns what the state diff saw: every storage write to the
    ///      timelock, and the init code its creation was sent.
    function _deployRecorded(uint256 delay)
        internal
        returns (TimelockController t, Write[] memory writes, bytes memory sent)
    {
        vm.startStateDiffRecording();
        t = script.run(k, 137, delay);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        uint256 creates;
        for (uint256 i; i < diff.length; ++i) {
            if (diff[i].kind == VmSafe.AccountAccessKind.Create && diff[i].account == address(t)) {
                sent = diff[i].data;
                ++creates;
            }
        }
        assertEq(creates, 1, "one creation");

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

    /// @dev Written apart from the script's stockHash: the source digest is read by position from the
    ///      runtime's 53-byte metadata trailer (it fills the trailer's bytes 10 to 41), then its one copy in
    ///      `code` is zeroed.
    function _masked(bytes memory code, bytes memory runtime) internal pure returns (bytes32) {
        bytes32 digest = bytes32(_slice(runtime, runtime.length - 43, 32));
        bytes memory c = bytes.concat(code);
        uint256 copies;
        for (uint256 i; i + 32 <= c.length; ++i) {
            if (bytes32(_slice(c, i, 32)) == digest) {
                for (uint256 j; j < 32; ++j) {
                    c[i + j] = 0;
                }
                ++copies;
            }
        }
        assertEq(copies, 1, "copies of the source digest");
        return keccak256(c);
    }

    /// @dev The source digest, read by position from the runtime's 53-byte metadata trailer.
    function _digest(bytes memory runtime) internal pure returns (bytes32) {
        return bytes32(_slice(runtime, runtime.length - 43, 32));
    }

    /// @dev Where the one copy of `word` starts in `b`.
    function _offsetOf(bytes memory b, bytes32 word) internal pure returns (uint256 at) {
        uint256 copies;
        for (uint256 i; i + 32 <= b.length; ++i) {
            if (_word(b, i) == word) {
                at = i;
                ++copies;
            }
        }
        assertEq(copies, 1, "copies of the word");
    }

    function _word(bytes memory b, uint256 i) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(b, 0x20), i))
        }
    }

    /// @dev The script carries the timelock's creation code inside its own code. Flips byte `pos` of every
    ///      copy there, runs the changed script, and expects it refused for `reason` before any contract is
    ///      created (a creation the refusal later undoes is still recorded). Then puts the script back.
    function _expectRunRefusesBeforeBuilding(uint256 pos, string memory reason) internal {
        bytes memory init = type(TimelockController).creationCode;
        bytes memory original = address(script).code;
        bytes memory changed = bytes.concat(original);
        uint256 copies;
        for (uint256 i; i + init.length <= changed.length; ++i) {
            if (_word(changed, i) == _word(init, 0) && keccak256(_slice(changed, i, init.length)) == keccak256(init)) {
                changed[i + pos] = changed[i + pos] ^ 0x01;
                ++copies;
                i += init.length - 1;
            }
        }
        assertGt(copies, 0, "the script carries the creation code");

        vm.etch(address(script), changed);
        vm.startStateDiffRecording();
        vm.expectRevert(bytes(reason));
        script.run(k, 137, DAY0);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            assertTrue(diff[i].kind != VmSafe.AccountAccessKind.Create, "a contract was created");
        }
        vm.etch(address(script), original);
    }

    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = b[start + i];
        }
    }

    function _expectRefused(TimelockController t, VmSafe.Log[] memory logs, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.verify(t, k, address(this), DAY0, logs);
    }

    /// @dev A deep copy, so one change cannot reach the original's topics or data.
    function _copy(VmSafe.Log[] memory logs) internal pure returns (VmSafe.Log[] memory out) {
        out = new VmSafe.Log[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            bytes32[] memory topics = new bytes32[](logs[i].topics.length);
            for (uint256 j; j < topics.length; ++j) {
                topics[j] = logs[i].topics[j];
            }
            out[i] = VmSafe.Log(topics, bytes.concat(logs[i].data), logs[i].emitter);
        }
    }

    function _list(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
