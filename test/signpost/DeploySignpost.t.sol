// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
import {DeploySignpost, IV2Core} from "../../script/DeploySignpost.s.sol";

/// @dev Lets a test run the script's deploy with first-entry values of its own.
contract DeploySignpostHarness is DeploySignpost {
    function deployFirst(First memory f) external returns (OspexSignpost) {
        return _deploy(f);
    }
}

/**
 * @notice Tests for script/DeploySignpost.s.sol, on a fork of Polygon mainnet at FORK_BLOCK: after the Polygon
 *         timelock's creation, with v2 and its USDC there. They need POLYGON_RPC_URL; without it (CI has no
 *         RPC) every test here is skipped, which is how a run reports that no fork was used.
 *
 *         Tests named test_mustNever<line>_... are the signpost's lines under "Must never happen" in
 *         docs/spec-v3.md ("Keys, deploys and the signpost", numbered as in OspexSignpost.t.sol) as they
 *         reach the deploy, each with the one-line break that turns it red.
 */
contract DeploySignpostTest is Test {
    uint256 internal constant FORK_BLOCK = 95_785_000;
    uint256 internal constant TIMELOCK_CREATION_BLOCK = 95_761_553;

    /// @dev Kept apart from the script's own constants.
    address internal constant TIMELOCK = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;
    address internal constant K = 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E;
    /// @dev The address that sent the timelock's deploy.
    address internal constant TIMELOCK_DEPLOYER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    address internal constant V2_CORE = 0x40047BAFcdEd16C938058b7b67186299a2893561;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    bytes20 internal constant V2_COMMIT = hex"d2be2cb10f9cc0f54d7df807d6aa750b4c3dafdd";
    uint64 internal constant V2_DEPLOY_BLOCK = 89_322_650;

    DeploySignpostHarness internal script;
    /// @dev In a test, forge broadcasts from its default sender.
    address internal deployer = DEFAULT_SENDER;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        script = new DeploySignpostHarness();
    }

    // ---------------------------------------------------------------------------------------------------
    // v2's entry, read from the chain
    // ---------------------------------------------------------------------------------------------------

    /// The fork is Polygon at the pinned block, with the Polygon timelock as script/DeployPolygonTimelock.s.sol
    /// deployed it.
    function test_fork_isPolygonWithTheTimelock() public view {
        assertEq(block.chainid, 137, "chain id");
        assertEq(block.number, FORK_BLOCK, "fork block");
        assertEq(TIMELOCK.codehash, script.TIMELOCK_CODE_HASH(), "the timelock's code");
        assertEq(TimelockController(payable(TIMELOCK)).getMinDelay(), 60, "the day-0 delay");
        script.requireTimelock(TIMELOCK, K);
    }

    /// Each value of v2's entry against the chain: its contracts are the finalized core and the twelve
    /// modules it registered, in that order; each code hash is the chain's; the coin is what v2's
    /// PositionModule holds; and the core is the first of the thirteen to exist, created in the deploy block.
    function test_v2_theEntryIsWhatTheChainHolds() public {
        DeploySignpost.First memory f = script.v2();
        assertEq(f.timelock, TIMELOCK, "timelock");
        assertEq(f.k, K, "K");
        assertEq(uint8(f.kind), uint8(OspexSignpost.Kind.Both), "kind");
        assertEq(f.coin, USDC, "coin");
        assertEq(f.commit, V2_COMMIT, "commit");
        assertEq(f.deployBlock, V2_DEPLOY_BLOCK, "deploy block");
        assertEq(f.contracts.length, 13, "thirteen contracts");
        assertEq(f.contracts[0], V2_CORE, "the core first");

        IV2Core core = IV2Core(V2_CORE);
        assertTrue(core.s_finalized(), "finalized");
        string[12] memory names = [
            "CONTEST_MODULE",
            "SPECULATION_MODULE",
            "POSITION_MODULE",
            "MATCHING_MODULE",
            "CRE_ORACLE_RECEIVER",
            "TREASURY_MODULE",
            "LEADERBOARD_MODULE",
            "RULES_MODULE",
            "SECONDARY_MARKET_MODULE",
            "MONEYLINE_SCORER_MODULE",
            "SPREAD_SCORER_MODULE",
            "TOTAL_SCORER_MODULE"
        ];
        for (uint256 i; i < 12; ++i) {
            assertEq(core.getModule(keccak256(bytes(names[i]))), f.contracts[i + 1], names[i]);
        }
        for (uint256 i; i < 13; ++i) {
            assertEq(f.contracts[i].codehash, f.codeHashes[i], "code hash");
            for (uint256 j; j < i; ++j) {
                assertTrue(f.codeHashes[i] != f.codeHashes[j], "two contracts share a code hash");
            }
        }
        (bool ok, bytes memory token) = f.contracts[3].staticcall(abi.encodeWithSignature("i_token()"));
        assertTrue(ok, "PositionModule");
        assertEq(abi.decode(token, (address)), USDC, "PositionModule holds USDC");

        // The deploy block: no contract of the set had code the block before; the core had it after.
        assertEq(vm.parseUint("0x552f49a"), uint256(V2_DEPLOY_BLOCK), "hex of the deploy block");
        for (uint256 i; i < 13; ++i) {
            assertEq(_codeAt(f.contracts[i], "0x552f499").length, 0, "a contract existed before the deploy block");
        }
        assertEq(keccak256(_codeAt(V2_CORE, "0x552f49a")), f.codeHashes[0], "the core exists in the deploy block");
    }

    // ---------------------------------------------------------------------------------------------------
    // The deploy
    // ---------------------------------------------------------------------------------------------------

    /// run() deploys the pinned build with v2 as its one entry, marked building, and nothing else.
    function test_run_deploysThePinnedBuildWithV2AsItsFirstEntry() public {
        DeploySignpost.First memory f = script.v2();
        vm.startStateDiffRecording();
        OspexSignpost s = script.run();
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        // One creation, sent the pinned creation code and then the constructor's arguments.
        bytes memory init = type(OspexSignpost).creationCode;
        bytes memory args = script.constructorArgs(f);
        uint256 creates;
        uint256 writes;
        for (uint256 i; i < diff.length; ++i) {
            if (diff[i].kind == VmSafe.AccountAccessKind.Create) {
                ++creates;
                assertEq(diff[i].account, address(s), "the creation");
                assertEq(diff[i].accessor, deployer, "the sender");
                assertEq(diff[i].data, bytes.concat(init, args), "creation code and arguments");
            }
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory a = diff[i].storageAccesses[j];
                if (a.isWrite && !a.reverted) {
                    assertEq(a.account, address(s), "a write to another account");
                    ++writes;
                }
            }
        }
        assertEq(creates, 1, "one creation");
        // The list's length, four of the entry's five slots (the reason's stays empty), and its two lists of
        // thirteen. OspexSignpostTest's test_mustNever4_theDeployerKeepsNothing checks each slot and value.
        assertEq(writes, 1 + 4 + 2 * 13, "the deploy's writes");

        assertEq(keccak256(init), script.EXACT_INIT_HASH(), "creation code");
        assertEq(keccak256(address(s).code), script.EXACT_CODE_HASH(), "runtime code");
        assertEq(s.i_timelock(), TIMELOCK, "owned by the Polygon timelock");
        assertEq(s.entryCount(), 1, "one entry");
        OspexSignpost.Entry memory e = s.getEntry(0);
        assertEq(uint8(e.kind), uint8(OspexSignpost.Kind.Both), "kind");
        assertEq(e.coin, USDC, "coin");
        assertEq(e.contracts, f.contracts, "contracts");
        assertEq(e.codeHashes, f.codeHashes, "code hashes");
        assertEq(e.commit, V2_COMMIT, "commit");
        assertEq(e.deployBlock, V2_DEPLOY_BLOCK, "deploy block");
        assertEq(uint8(e.status), uint8(OspexSignpost.Status.Building), "building");
        assertEq(e.reason, "", "no reason");
    }

    /// Must never happen 4: a deployer keeps any power after deploy. The script refuses any owner but the
    /// Polygon timelock: an account with other code, a wallet, and a stock timelock with other roles.
    /// Break: in _deploy(), delete `requireTimelock(f.timelock, f.k);`. This goes red: each wrong owner is
    /// then refused later, by the constructor or the read-back, with another reason.
    function test_mustNever4_theScriptRefusesAnyOwnerButThePolygonTimelock() public {
        _expectDeployRefused(_withTimelock(V2_CORE), "the owner is not the Polygon timelock's code");
        _expectDeployRefused(_withTimelock(K), "the owner is not the Polygon timelock's code");
        _expectDeployRefused(_withTimelock(deployer), "the owner is not the Polygon timelock's code");
        TimelockController other = new TimelockController(60, _one(stranger), _one(address(0)), address(0));
        assertEq(address(other).codehash, script.TIMELOCK_CODE_HASH(), "the same stock code");
        _expectDeployRefused(_withTimelock(address(other)), "the timelock's roles are not as ruled");
        // The right timelock read against another key.
        DeploySignpost.First memory otherKey = script.v2();
        otherKey.k = stranger;
        _expectDeployRefused(otherKey, "the timelock's roles are not as ruled");
        // Control: the Polygon timelock passes.
        script.requireTimelock(TIMELOCK, K);
    }

    /// The script refuses a first entry the chain does not hold.
    function test_v2_theScriptRefusesValuesTheChainDoesNotHold() public {
        DeploySignpost.First memory f = script.v2();
        f.codeHashes[7] = bytes32(uint256(f.codeHashes[7]) ^ 1);
        _expectDeployRefused(f, "a contract's code is not the pinned code");

        f = script.v2();
        (f.contracts[1], f.contracts[2]) = (f.contracts[2], f.contracts[1]);
        (f.codeHashes[1], f.codeHashes[2]) = (f.codeHashes[2], f.codeHashes[1]);
        _expectDeployRefused(f, "a module is not the core's");

        f = script.v2();
        f.coin = address(0xc2132D05D31c914a87C6611C10748AEb04B58e8F); // Polygon's USDT
        _expectDeployRefused(f, "the coin is not v2's");

        f = script.v2();
        f.kind = OspexSignpost.Kind.Betting;
        _expectDeployRefused(f, "v2 is games and betting together");

        f = script.v2();
        address[] memory twelve = new address[](12);
        for (uint256 i; i < 12; ++i) {
            twelve[i] = f.contracts[i];
        }
        f.contracts = twelve;
        _expectDeployRefused(f, "v2 is its core and twelve modules");
    }

    /// The script carries the signpost's creation code. A changed executable byte, and a changed source
    /// digest, are each refused before any contract is created.
    function test_build_theScriptRefusesAnyBuildButThePinnedOne() public {
        bytes memory init = type(OspexSignpost).creationCode;
        assertEq(keccak256(init), script.EXACT_INIT_HASH(), "this build is the frozen artifact");
        assertEq(script.stockHash(init), script.STOCK_INIT_HASH(), "its executable bytes");
        _expectRunRefusesBeforeBuilding(100, "not the pinned build");
        _expectRunRefusesBeforeBuilding(_digestOffset(init), "the metadata is not the pinned build's");
    }

    /// The read-back compares the code, the owner, every field of the one entry, and its one log. run() reads
    /// forge's recorded logs for its own read-back, which leaves none for a test, so the signpost here is
    /// built by the test with v2's values: the same code, since the code holds only the owner's address.
    function test_readBack_verifyComparesEveryField() public {
        DeploySignpost.First memory f = script.v2();
        vm.recordLogs();
        OspexSignpost s = new OspexSignpost(f.timelock, f.kind, f.coin, f.contracts, f.commit, f.deployBlock);
        VmSafe.Log[] memory logs = _signpostLogs(vm.getRecordedLogs(), address(s));
        assertEq(logs.length, 1, "one log");
        assertEq(keccak256(address(s).code), script.EXACT_CODE_HASH(), "the pinned runtime code");
        script.verify(s, f, logs);

        // A signpost holding other values, each read against v2's.
        _expectVerifyRefused(_with(f, "commit"), "the first entry's commit");
        _expectVerifyRefused(_with(f, "deployBlock"), "the first entry's deploy block");
        _expectVerifyRefused(_with(f, "order"), "the first entry's contracts");
        _expectVerifyRefused(_with(f, "fewer"), "the first entry's contracts");

        // The right signpost, read against other values.
        DeploySignpost.First memory g = script.v2();
        g.commit = bytes20(uint160(g.commit) ^ 1);
        vm.expectRevert(bytes("the first entry's commit"));
        script.verify(s, g, logs);
        g = script.v2();
        g.codeHashes[0] = bytes32(uint256(g.codeHashes[0]) ^ 1);
        vm.expectRevert(bytes("the first entry's code hashes"));
        script.verify(s, g, logs);

        // The logs: none, two, or one with any field changed.
        vm.expectRevert(bytes("the signpost has other logs"));
        script.verify(s, f, new VmSafe.Log[](0));
        VmSafe.Log[] memory two = new VmSafe.Log[](2);
        (two[0], two[1]) = (logs[0], logs[0]);
        vm.expectRevert(bytes("the signpost has other logs"));
        script.verify(s, f, two);
        for (uint256 t; t < 3; ++t) {
            VmSafe.Log[] memory bad = _copy(logs);
            bad[0].topics[t] = bytes32(uint256(bad[0].topics[t]) ^ 1);
            vm.expectRevert(bytes("the first entry's log is not as ruled"));
            script.verify(s, f, bad);
        }
        VmSafe.Log[] memory moved = _copy(logs);
        moved[0].emitter = stranger;
        vm.expectRevert(bytes("the first entry's log is not as ruled"));
        script.verify(s, f, moved);
        VmSafe.Log[] memory longer = _copy(logs);
        longer[0].data = bytes.concat(longer[0].data, hex"00");
        vm.expectRevert(bytes("the first entry's log is not as ruled"));
        script.verify(s, f, longer);

        // After a move, or a second entry, the read-back refuses: it is for right after the deploy.
        bytes memory retire = abi.encodeCall(OspexSignpost.moveForward, (0, OspexSignpost.Status.Retired, 0, ""));
        _viaTheTimelock(address(s), retire, bytes32(uint256(1)));
        vm.expectRevert(bytes("the first entry is not building"));
        script.verify(s, f, logs);
    }

    function test_inputs_anyChainButPolygonIsRefused() public {
        vm.chainId(80002);
        vm.expectRevert(bytes("the RPC is not on chain 137"));
        script.run();
        vm.expectRevert(bytes("the RPC is not on chain 137"));
        script.check(OspexSignpost(address(1)), 0);
    }

    // ---------------------------------------------------------------------------------------------------
    // The signpost with v2's entry, through the Polygon timelock
    //
    // These build the signpost with v2's values directly rather than through run(). run() refuses any
    // build but the pinned one, so a changed OspexSignpost would be refused there before these tests could
    // reach what they check. test_run_deploysThePinnedBuildWithV2AsItsFirstEntry shows run() deploys this
    // same code with this same entry.
    // ---------------------------------------------------------------------------------------------------

    /// Must never happen 3: v2's entry moves to live. On Polygon, through the Polygon timelock after its
    /// delay: v2's entry is refused, and so is v2's core or its ContestModule listed again as a games entry,
    /// since neither answers the reporters read. Retiring v2 goes through.
    /// Break: in OspexSignpost.moveForward(), delete `if (id == 0) revert OspexSignpost__FirstEntryNeverLive();`.
    /// This goes red: v2's entry is then refused for its reporters read instead, with another error.
    function test_mustNever3_v2NeverMovesToLiveOnPolygon() public {
        OspexSignpost s = _v2Signpost();
        bytes memory live = abi.encodeCall(OspexSignpost.moveForward, (0, OspexSignpost.Status.Live, 1, ""));
        _expectTimelockCallRefused(
            address(s), live, bytes32(uint256(1)), abi.encodeWithSelector(OspexSignpost.OspexSignpost__FirstEntryNeverLive.selector)
        );

        address[2] memory v2Games = [V2_CORE, script.v2().contracts[1]];
        for (uint256 i; i < 2; ++i) {
            address[] memory set = _one(v2Games[i]);
            bytes memory add =
                abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Games, address(0), set, V2_COMMIT, V2_DEPLOY_BLOCK));
            _viaTheTimelock(address(s), add, bytes32(uint256(10 + i)));
            bytes memory relisted = abi.encodeCall(OspexSignpost.moveForward, (i + 1, OspexSignpost.Status.Live, 1, ""));
            _expectTimelockCallRefused(
                address(s),
                relisted,
                bytes32(uint256(20 + i)),
                abi.encodeWithSelector(OspexSignpost.OspexSignpost__ReportersNotRecorded.selector, v2Games[i], 1)
            );
        }
        assertEq(uint8(s.getEntry(0).status), uint8(OspexSignpost.Status.Building), "v2 is building");

        // Control: retiring v2 goes through the same path.
        bytes memory retire =
            abi.encodeCall(OspexSignpost.moveForward, (0, OspexSignpost.Status.Retired, 0, "v3 is live"));
        _viaTheTimelock(address(s), retire, bytes32(uint256(30)));
        assertEq(uint8(s.getEntry(0).status), uint8(OspexSignpost.Status.Retired), "v2 retired");
        assertEq(s.getEntry(0).reason, "v3 is live", "reason");
    }

    /// Must never happen 4: an entry is written after deploy by anything but a timelock call that waited the
    /// timelock's delay. On Polygon: K, the deployer and the timelock's own deployer cannot write; a call K
    /// schedules on the Polygon timelock runs only once its delay is up.
    /// Break: in OspexSignpost's onlyTimelock modifier, delete
    /// `if (msg.sender != i_timelock) revert OspexSignpost__NotTheTimelock(msg.sender);`. This goes red: the
    /// direct calls then land.
    function test_mustNever4_onlyThePolygonTimelockWritesAfterItsDelay() public {
        OspexSignpost s = _v2Signpost();
        address[] memory set = _one(USDC);
        address[4] memory callers = [K, deployer, TIMELOCK_DEPLOYER, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, callers[i]));
            s.addEntry(OspexSignpost.Kind.Betting, USDC, set, V2_COMMIT, V2_DEPLOY_BLOCK);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(OspexSignpost.OspexSignpost__NotTheTimelock.selector, callers[i]));
            s.moveForward(0, OspexSignpost.Status.Retired, 0, "");
        }

        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        bytes memory add =
            abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Betting, USDC, set, V2_COMMIT, V2_DEPLOY_BLOCK));
        vm.prank(K);
        t.schedule(address(s), 0, add, bytes32(0), bytes32(0), delay);
        vm.warp(block.timestamp + delay - 1);
        vm.prank(stranger);
        vm.expectRevert();
        t.execute(address(s), 0, add, bytes32(0), bytes32(0));
        assertEq(s.entryCount(), 1, "added before the delay");
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        t.execute(address(s), 0, add, bytes32(0), bytes32(0));
        assertEq(s.entryCount(), 2, "added after the delay");
        assertEq(s.getEntry(1).codeHashes[0], USDC.codehash, "read from the chain");
    }

    // ---------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------

    /// @dev The signpost with v2's entry, owned by the Polygon timelock, built by this test contract.
    function _v2Signpost() internal returns (OspexSignpost) {
        DeploySignpost.First memory f = script.v2();
        return new OspexSignpost(f.timelock, f.kind, f.coin, f.contracts, f.commit, f.deployBlock);
    }

    function _codeAt(address account, string memory blockHex) internal returns (bytes memory) {
        return vm.rpc("eth_getCode", string.concat('["', vm.toString(account), '","', blockHex, '"]'));
    }

    function _withTimelock(address timelock) internal view returns (DeploySignpost.First memory f) {
        f = script.v2();
        f.timelock = timelock;
    }

    function _expectDeployRefused(DeploySignpost.First memory f, string memory reason) internal {
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(bytes(reason));
        script.deployFirst(f);
        assertEq(vm.getNonce(deployer), nonce, "something was sent");
    }

    /// @dev A signpost on the Polygon timelock whose first entry differs from v2's in one way, read back
    ///      against v2's values.
    function _expectVerifyRefused(DeploySignpost.First memory changed, string memory reason) internal {
        vm.recordLogs();
        OspexSignpost s = new OspexSignpost(
            changed.timelock, changed.kind, changed.coin, changed.contracts, changed.commit, changed.deployBlock
        );
        VmSafe.Log[] memory logs = _signpostLogs(vm.getRecordedLogs(), address(s));
        DeploySignpost.First memory v2 = script.v2();
        vm.expectRevert(bytes(reason));
        script.verify(s, v2, logs);
    }

    function _with(DeploySignpost.First memory f, string memory what)
        internal
        view
        returns (DeploySignpost.First memory g)
    {
        g = script.v2();
        bytes32 w = keccak256(bytes(what));
        if (w == keccak256("commit")) g.commit = bytes20(uint160(f.commit) ^ 1);
        if (w == keccak256("deployBlock")) g.deployBlock = f.deployBlock + 1;
        if (w == keccak256("order")) (g.contracts[1], g.contracts[2]) = (g.contracts[2], g.contracts[1]);
        if (w == keccak256("fewer")) {
            address[] memory twelve = new address[](12);
            for (uint256 i; i < 12; ++i) {
                twelve[i] = f.contracts[i];
            }
            g.contracts = twelve;
        }
    }

    function _viaTheTimelock(address target, bytes memory call, bytes32 salt) internal {
        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        vm.prank(K);
        t.schedule(target, 0, call, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(stranger);
        t.execute(target, 0, call, bytes32(0), salt);
    }

    function _expectTimelockCallRefused(address target, bytes memory call, bytes32 salt, bytes memory reason)
        internal
    {
        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        vm.prank(K);
        t.schedule(target, 0, call, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(stranger);
        vm.expectRevert(reason);
        t.execute(target, 0, call, bytes32(0), salt);
    }

    function _signpostLogs(VmSafe.Log[] memory all, address s) internal pure returns (VmSafe.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == s) ++n;
        }
        out = new VmSafe.Log[](n);
        n = 0;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == s) out[n++] = all[i];
        }
    }

    /// @dev Where the creation code's one metadata source digest starts.
    function _digestOffset(bytes memory code) internal pure returns (uint256 at) {
        uint256 copies;
        for (uint256 i; i + 42 <= code.length; ++i) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 0x20), i))
            }
            if (word >> 176 == 0xa2646970667358221220) {
                at = i + 10;
                ++copies;
            }
        }
        assertEq(copies, 1, "one metadata section");
    }

    /// @dev Flips byte `pos` of every copy of the signpost's creation code inside the script's own code,
    ///      runs it, and expects it refused for `reason` before any contract is created. Then puts it back.
    function _expectRunRefusesBeforeBuilding(uint256 pos, string memory reason) internal {
        bytes memory init = type(OspexSignpost).creationCode;
        bytes memory original = address(script).code;
        bytes memory changed = bytes.concat(original);
        uint256 copies;
        bytes32 head = _word(init, 0);
        for (uint256 i; i + init.length <= changed.length; ++i) {
            if (_word(changed, i) == head && keccak256(_slice(changed, i, init.length)) == keccak256(init)) {
                changed[i + pos] = changed[i + pos] ^ 0x01;
                ++copies;
                i += init.length - 1;
            }
        }
        assertGt(copies, 0, "the script carries the creation code");

        vm.etch(address(script), changed);
        vm.startStateDiffRecording();
        vm.expectRevert(bytes(reason));
        script.run();
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            assertTrue(diff[i].kind != VmSafe.AccountAccessKind.Create, "a contract was created");
        }
        vm.etch(address(script), original);
    }

    function _word(bytes memory b, uint256 i) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(b, 0x20), i))
        }
    }

    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = b[start + i];
        }
    }

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

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
