// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployBetting} from "../../script/DeployBetting.s.sol";
import {DeployGames} from "../../script/DeployGames.s.sol";
import {IOspexGames, GameStatus, Hint, ReporterKind} from "../../src/games/IOspexGames.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {TestCoin} from "../games/CoinFixtures.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {LiveGamesForkBase} from "./OspexCrossFork.t.sol";

/// @dev A TEST ADAPTER's store: the chain's logs below the fork block, which do not change, kept on disk under
///      deployments/betting-set/test/chain-logs/ by the hash of what was asked, with a checksum. A file that is
///      missing, short or fails its checksum (another test writing it at the same moment) is read from the
///      chain again. It saves the two hundred windows of the timelock's history in every test.
library ChainLogCache {
    VmSafe internal constant VM = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _path(bytes32 key) private view returns (string memory) {
        return string.concat(VM.projectRoot(), "/deployments/betting-set/test/chain-logs/", VM.toString(key), ".bin");
    }

    function read(bytes32 key) internal view returns (bytes memory) {
        string memory path = _path(key);
        if (!VM.isFile(path)) return "";
        bytes memory file = VM.readFileBinary(path);
        if (file.length < 32) return "";
        bytes memory body = new bytes(file.length - 32);
        for (uint256 i; i < body.length; ++i) {
            body[i] = file[i];
        }
        bytes32 sum;
        assembly ("memory-safe") {
            sum := mload(add(add(file, 0x20), sub(mload(file), 32)))
        }
        return sum == keccak256(body) ? body : bytes("");
    }

    function write(bytes32 key, bytes memory body) internal {
        VM.createDir(string.concat(VM.projectRoot(), "/deployments/betting-set/test/chain-logs"), true);
        VM.writeFileBinary(_path(key), bytes.concat(body, keccak256(body)));
    }
}

/// @dev The games deploy, with its read of the timelock's logs kept once per test: the read is two hundred
///      windows of the chain, and a test makes it at every phase. A test adapter: it reads the chain's logs up to
///      the fork block with the script's own read, and stands a timelock of the test's own in with its own logs.
contract TimelockLogsOnce is DeployGames {
    uint256 internal upTo;
    mapping(address => bytes) internal kept;
    mapping(address => bool) internal isKept;

    function setUpTo(uint256 blockNumber) external {
        upTo = blockNumber;
    }

    /// @dev A timelock the test built, with the logs it emitted.
    function setLogsOf(address timelock, VmSafe.Log[] memory logs) external {
        kept[timelock] = abi.encode(logs);
        isKept[timelock] = true;
    }

    function _timelockLogs(address timelock, uint256 creationBlock) internal override returns (VmSafe.Log[] memory) {
        if (!isKept[timelock]) {
            uint256 to = upTo == 0 ? block.number : upTo;
            bytes32 key = keccak256(abi.encode("the timelock's whole history", timelock, creationBlock, to));
            bytes memory found = ChainLogCache.read(key);
            if (found.length == 0) {
                VmSafe.EthGetLogs[] memory raw = _windows(timelock, creationBlock, to);
                VmSafe.Log[] memory logs = new VmSafe.Log[](raw.length);
                for (uint256 i; i < raw.length; ++i) {
                    logs[i] = VmSafe.Log(raw[i].topics, raw[i].data, raw[i].emitter);
                }
                found = abi.encode(logs);
                ChainLogCache.write(key, found);
            }
            kept[timelock] = found;
            isKept[timelock] = true;
        }
        bytes memory encoded = kept[timelock];
        return abi.decode(encoded, (VmSafe.Log[]));
    }

    function _windows(address emitter, uint256 fromBlock, uint256 toBlock)
        internal
        returns (VmSafe.EthGetLogs[] memory logs)
    {
        uint256 windows = (toBlock - fromBlock) / LOG_WINDOW + 1;
        VmSafe.EthGetLogs[][] memory raw = new VmSafe.EthGetLogs[][](windows);
        uint256 count;
        for (uint256 w; w < windows; ++w) {
            uint256 from = fromBlock + w * LOG_WINDOW;
            uint256 to = from + LOG_WINDOW - 1;
            if (to > toBlock) to = toBlock;
            raw[w] = vm.eth_getLogs(from, to, emitter, new bytes32[](0));
            count += raw[w].length;
        }
        logs = new VmSafe.EthGetLogs[](count);
        uint256 n;
        for (uint256 w; w < windows; ++w) {
            for (uint256 i; i < raw[w].length; ++i) {
                logs[n++] = raw[w][i];
            }
        }
    }
}

/// @dev Lets a test run each phase with inputs, a plan and a directory of its own, as the deployer, and stands in
///      for the reads a fork inside a test cannot serve. Each override below is a TEST ADAPTER: it does not prove
///      what a real node answers. The anvil rehearsal by hand does.
///      - The finalized and the latest block: a node behind a fork cannot see the test's own blocks. Here every
///        block the test reaches is final once a later one exists: the finalized block is the one before the
///        test's own, unless a test names another.
///      - Code, calls and nonces at a block: from `localFrom` on, the test's own state as it stands now; below
///        it, the chain's, through the script's own reads.
///      - The pending nonce: the nonce now, plus what a test says is pending.
///      - Logs: below `localFrom`, the chain's through the script's own read, kept once; from it on, the logs the
///        test recorded, its own actions' and the sends' alone (through the script's two hooks), each with the
///        block it happened in.
///      - The games deploy's timelock check reads its logs once per test (TimelockLogsOnce).
///      No plan value and no check is overridden.
contract DeployBettingHarness is DeployBetting {
    uint256 public localFrom;
    uint256 internal finalizedNamed;
    bool internal finalizedIsNamed;
    uint256 public pendingExtra;
    TimelockLogsOnce public immutable logsOnce;

    struct LocalLog {
        address emitter;
        bytes32[] topics;
        bytes data;
        uint64 blockNumber;
    }

    LocalLog[] internal localLogs;
    mapping(bytes32 => bytes) internal chainLogs;
    mapping(bytes32 => bool) internal chainLogsKept;

    constructor() {
        logsOnce = new TimelockLogsOnce();
    }

    // ── The test's controls ──

    function setLocalFrom(uint256 blockNumber) external {
        localFrom = blockNumber;
        logsOnce.setUpTo(blockNumber - 1);
    }

    function nameFinalized(uint256 blockNumber) external {
        finalizedNamed = blockNumber;
        finalizedIsNamed = true;
    }

    function setPendingExtra(uint256 n) external {
        pendingExtra = n;
    }

    /// @dev Logs the test recorded, from its own actions, in the block they happened in.
    function addLocalLogs(Vm.Log[] memory logs, uint256 blockNumber) public {
        for (uint256 i; i < logs.length; ++i) {
            localLogs.push(LocalLog(logs[i].emitter, logs[i].topics, logs[i].data, uint64(blockNumber)));
        }
    }

    function localLogCount() external view returns (uint256) {
        return localLogs.length;
    }

    // ── The phases, with the table, the plan, the sender and the directory a test chooses ──

    function predictFor(Inputs memory in_, bytes20 commit, string memory dir) external returns (Plan memory) {
        return _predict(in_, commit, dir);
    }

    function phaseFrom(
        Inputs memory in_,
        Plan memory p,
        address sender,
        bytes32 digest,
        bytes16 go,
        uint256 maxFee,
        Phase which
    ) external returns (uint256 proven, uint256 sent) {
        return _phase(in_, p, sender, digest, go, maxFee, which);
    }

    function checkFor(Inputs memory in_, Plan memory p, address core, uint256 creationBlock, uint8 stage) external {
        _check(in_, p, core, creationBlock, stage);
    }

    function signpostCallFor(Inputs memory in_, Plan memory p, uint64 deployBlock, string memory dir)
        external
        returns (bytes memory, bytes32)
    {
        return _signpostCall(in_, p, deployBlock, dir);
    }

    function writePlanFor(string memory dir, Plan memory p) external {
        _writePlan(dir, p);
    }

    function buildPlanFor(Inputs memory in_, uint64 k, bytes20 commit, uint256 blockNumber, bytes32 blockHash)
        external
        pure
        returns (Plan memory)
    {
        return _buildPlan(in_, k, commit, blockNumber, blockHash);
    }

    function anchorsNow() external returns (Anchors memory) {
        return _anchors();
    }

    function recordDir(string memory name) external view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/betting-set/test/", name);
    }

    // ── TEST ADAPTERS ──

    function _finalizedAnswer() internal view override returns (bytes32) {
        uint256 f = finalizedIsNamed ? finalizedNamed : block.number - 1;
        return keccak256(abi.encode("a test block", f));
    }

    function _blockAnswerAt(uint256 m) internal view override returns (bytes32) {
        return m <= block.number ? keccak256(abi.encode("a test block", m)) : bytes32(0);
    }

    function _blockHash(uint256 n) internal pure override returns (bytes32) {
        return keccak256(abi.encode("a test block's hash", n));
    }

    function _codeAt(address account, uint256 n) internal override returns (bytes memory) {
        if (n >= localFrom) return account.code;
        return super._codeAt(account, n);
    }

    function _callAt(address target, bytes memory data, uint256 n) internal override returns (bytes memory) {
        if (n >= localFrom) {
            (bool ok, bytes memory answer) = target.staticcall(data);
            require(ok, "a read at an anchor was refused");
            return answer;
        }
        return super._callAt(target, data, n);
    }

    function _nonceAt(address account, uint256 n) internal override returns (uint256) {
        if (n >= localFrom) return vm.getNonce(account);
        return super._nonceAt(account, n);
    }

    function _pendingNonce(address account) internal view override returns (uint256) {
        return vm.getNonce(account) + pendingExtra;
    }

    function _logs(address emitter, uint256 fromBlock, uint256 toBlock, bytes32[] memory topics)
        internal
        override
        returns (VmSafe.EthGetLogs[] memory logs)
    {
        VmSafe.EthGetLogs[] memory chain;
        if (fromBlock < localFrom) {
            uint256 chainTo = toBlock < localFrom ? toBlock : localFrom - 1;
            bytes32 key = keccak256(abi.encode(emitter, fromBlock, chainTo, topics));
            if (!chainLogsKept[key]) {
                bytes memory found = ChainLogCache.read(key);
                if (found.length == 0) {
                    found = abi.encode(super._logs(emitter, fromBlock, chainTo, topics));
                    ChainLogCache.write(key, found);
                }
                chainLogs[key] = found;
                chainLogsKept[key] = true;
            }
            bytes memory encoded = chainLogs[key];
            chain = abi.decode(encoded, (VmSafe.EthGetLogs[]));
        }
        uint256 n;
        for (uint256 i; i < localLogs.length; ++i) {
            if (_localMatches(localLogs[i], emitter, fromBlock, toBlock, topics)) ++n;
        }
        logs = new VmSafe.EthGetLogs[](chain.length + n);
        for (uint256 i; i < chain.length; ++i) {
            logs[i] = chain[i];
        }
        uint256 j = chain.length;
        for (uint256 i; i < localLogs.length; ++i) {
            LocalLog storage l = localLogs[i];
            if (!_localMatches(l, emitter, fromBlock, toBlock, topics)) continue;
            logs[j].emitter = l.emitter;
            logs[j].topics = l.topics;
            logs[j].data = l.data;
            logs[j].blockNumber = l.blockNumber;
            ++j;
        }
    }

    function _localMatches(
        LocalLog storage l,
        address emitter,
        uint256 fromBlock,
        uint256 toBlock,
        bytes32[] memory topics
    ) internal view returns (bool) {
        if (l.emitter != emitter || l.blockNumber < fromBlock || l.blockNumber > toBlock) return false;
        if (l.blockNumber < localFrom) return false;
        for (uint256 t; t < topics.length; ++t) {
            if (topics[t] == bytes32(0)) continue;
            if (l.topics.length <= t || l.topics[t] != topics[t]) return false;
        }
        return true;
    }

    function _timelockCheck() internal view override returns (DeployGames) {
        return logsOnce;
    }

    /// @dev What the last sending run sent, each as the account it acted on and the hash of its input: the
    ///      deployer's own creations and calls, from the sends alone.
    struct Sent {
        address account;
        bytes32 inputHash;
        bool creation;
    }

    Sent[] internal lastSent;

    function lastSentCount() external view returns (uint256) {
        return lastSent.length;
    }

    function lastSentAt(uint256 i) external view returns (Sent memory) {
        return lastSent[i];
    }

    /// @dev The sends' own logs and accesses, apart from the simulations undone before them.
    function _sendsStart() internal override {
        delete lastSent;
        vm.recordLogs();
        vm.startStateDiffRecording();
    }

    function _sendsEnd() internal override {
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            VmSafe.AccountAccess memory d = diff[i];
            if (d.accessor != DEPLOYER || d.reverted) continue;
            if (d.kind == VmSafe.AccountAccessKind.Create) {
                lastSent.push(Sent(d.account, keccak256(d.data), true));
            } else if (d.kind == VmSafe.AccountAccessKind.Call) {
                lastSent.push(Sent(d.account, keccak256(d.data), false));
            }
        }
        addLocalLogs(vm.getRecordedLogs(), block.number);
    }

    /// @dev TEST ADAPTER: steps `from` to `to` of the plan sent by the deployer alone, with no check, to stand for
    ///      a run that stopped after them.
    function sendSteps(Inputs memory in_, Plan memory p, uint256 from, uint256 to) external {
        vm.recordLogs();
        vm.startBroadcast(in_.deployer);
        for (uint256 i = from; i < to; ++i) {
            _send(i, in_, p);
        }
        vm.stopBroadcast();
        addLocalLogs(vm.getRecordedLogs(), block.number);
    }
}

/// @notice The betting set deployed by script/DeployBetting.s.sol on a fork of Polygon mainnet at FORK_BLOCK, from
///         the deployer at its own nonce, against the games set the signpost lists, the live timelock and USDC.
///         Each phase in order, the read-back at each stage, the entry scheduled by K and run by a stranger, and the
///         users' side end to end through the relay. Skipped without POLYGON_RPC_URL, and a skip is not a pass.
contract DeployBettingForkTest is LiveGamesForkBase {
    /// @dev A block of 11/23 near the head, after the games set's entry: the signpost holds two entries, the
    ///      timelock's delay is a minute, and the deployer's nonce is 4,356. Asserted by its hash.
    uint256 internal constant FORK_BLOCK = 97_827_000;
    bytes32 internal constant FORK_BLOCK_HASH = 0x58f7423543405f9dc747919e367c36b9a76750af4b31eabe73923f4159424d9b;
    uint64 internal constant K_AT_FORK = 4356;

    address internal constant DEPLOYER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant TIMELOCK = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;
    address internal constant K = 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E;
    address internal constant SIGNPOST = 0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A;
    address internal constant GAMES = 0x1b424d0dDB5C4aa4551845898093ae8D58052fD3;
    /// @dev An address that holds USDC at the fork block: the accounts are funded from it.
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @dev What each account is funded with: 5 USDC. The holder has 34 at the fork block, and no test needs more
    ///      than twelve.
    uint256 internal constant FUNDED = 5_000_000;
    /// @dev The run's maximum fee per gas: within the ceiling, and its cost within the bound.
    uint256 internal constant MAX_FEE = 300 gwei;
    bytes20 internal constant COMMIT = bytes20(hex"baa1fc566cf13552d968fb738ccb8ca3d859666f");
    bytes16 internal constant FORK_GO = bytes16(keccak256("fork"));

    DeployBettingHarness internal script;
    DeployBetting.Inputs internal polygon;
    IERC20 internal usdc = IERC20(USDC);
    OspexCourierRelay internal relay;

    function setUp() public override {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        liftAtDeploy = false;
        super.setUp();
        liveGames = IOspexGames(GAMES);
        script = new DeployBettingHarness();
        script.setLocalFrom(FORK_BLOCK + 1);
        polygon = script.inputs(137);
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _dir(string memory name) internal returns (string memory dir) {
        dir = script.recordDir(name);
        if (vm.exists(string.concat(dir, "/prediction.json"))) vm.removeFile(string.concat(dir, "/prediction.json"));
        if (vm.exists(string.concat(dir, "/signpost-call.json"))) vm.removeFile(string.concat(dir, "/signpost-call.json"));
    }

    /// @dev The next block: the test's own actions and the script's sends each happen in a block of their own.
    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    /// @dev Records the logs of what the test does next, to hand them to the harness with `_kept()`.
    function _recording() internal {
        vm.recordLogs();
    }

    function _kept() internal {
        script.addLocalLogs(vm.getRecordedLogs(), vm.getBlockNumber());
    }

    function _phase(DeployBetting.Plan memory p, DeployBetting.Phase which) internal returns (uint256, uint256) {
        return script.phaseFrom(polygon, p, DEPLOYER, script.planDigest(polygon, p), FORK_GO, MAX_FEE, which);
    }

    /// @dev The helpers of the test bases act on the set the script deployed.
    function _bind(DeployBetting.Plan memory p) internal {
        core = OspexBetting(p.contracts[0]);
        markets = OspexMarkets(p.contracts[1]);
        positions = OspexPositions(p.contracts[2]);
        matching = OspexMatching(p.contracts[3]);
        moneyline = OspexMoneylineScorer(p.contracts[4]);
        spread = OspexSpreadScorer(p.contracts[5]);
        total = OspexTotalScorer(p.contracts[6]);
        relay = OspexCourierRelay(p.contracts[7]);
    }

    /// @dev The whole deploy through the script: predict, create, the read-back at stage 1, bootstrap, stage 2,
    ///      finalize, stage 3. Each sending phase in a block of its own, read back in the next.
    function _deployTheSet(string memory name) internal returns (DeployBetting.Plan memory p, string memory dir) {
        dir = _dir(name);
        _nextBlock();
        p = script.predictFor(polygon, COMMIT, dir);
        (uint256 proven, uint256 sent) = _phase(p, DeployBetting.Phase.Create);
        assertEq(proven, 0, "the prefix before create");
        assertEq(sent, 8, "create sends the eight");
        _nextBlock();
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 1);
        (proven, sent) = _phase(p, DeployBetting.Phase.Bootstrap);
        assertEq(proven, 8, "the prefix before the bootstrap");
        assertEq(sent, 1, "bootstrap sends one");
        _bind(p);
        _nextBlock();
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 2);
        (proven, sent) = _phase(p, DeployBetting.Phase.Finalize);
        assertEq(proven, 9, "the prefix before finalize");
        assertEq(sent, 1, "finalize sends one");
        _nextBlock();
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 3);
    }

    function _fundWithUsdc(address who) internal {
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(who, FUNDED), "the funding transfer");
        vm.prank(who);
        assertTrue(usdc.approve(address(positions), type(uint256).max), "the approval");
    }

    /// @dev K schedules a call on the live timelock at its delay, the delay passes, a stranger runs it. The
    ///      timelock calls the target; it is never made to call schedule on itself.
    function _throughTheTimelock(address target, bytes memory call, bytes32 salt) internal {
        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        vm.prank(K);
        t.schedule(target, 0, call, bytes32(0), salt, delay);
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(stranger);
        t.execute(target, 0, call, bytes32(0), salt);
    }

    function _entryAddedId(Vm.Log[] memory logs) internal pure returns (uint256 id, bool found) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == SIGNPOST && logs[i].topics.length > 1 && logs[i].topics[0] == OspexSignpost.EntryAdded.selector
            ) {
                return (uint256(logs[i].topics[1]), true);
            }
        }
    }

    // ──────────────────────────── The fork ─────────────────────────────

    /// The fork is Polygon at the pinned block: chain 137, the block's hash the pinned one, and the deployer's
    /// nonce there 4,356.
    function test_fork_isPolygonAtThePinnedBlock() public {
        assertEq(block.chainid, 137, "the chain");
        assertEq(vm.getBlockNumber(), FORK_BLOCK, "the fork block");
        assertEq(vm.getNonce(DEPLOYER), K_AT_FORK, "the deployer's nonce at the fork block");
        assertEq(OspexSignpost(SIGNPOST).entryCount(), 2, "the signpost's entries at the fork block");
        assertEq(TimelockController(payable(TIMELOCK)).getMinDelay(), 60, "the delay at the fork block");
        // The fork block's hash, read from the chain once the fork is past it.
        vm.roll(FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "the fork block's hash is not the pinned one");
    }

    // ──────────────────────────── The rehearsal ────────────────────────

    /// predict names the eight addresses by the deployer's nonce, writes the plan, prints its digest, and sends
    /// nothing: no contract is created and no nonce moves.
    function test_predict_namesTheEightAndSendsNothing() public {
        string memory dir = _dir("predict");
        _nextBlock();
        vm.startStateDiffRecording();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            if (diff[i].kind == VmSafe.AccountAccessKind.Create && !diff[i].reverted) {
                // The simulation of the plan's creations is undone: nothing it made stands.
                assertEq(diff[i].account.code.length, 0, "a creation of predict stands");
            }
        }
        assertEq(vm.getNonce(DEPLOYER), K_AT_FORK, "the deployer's nonce moved");
        assertEq(p.nonce, K_AT_FORK, "k");
        for (uint256 i; i < 8; ++i) {
            assertEq(p.contracts[i], vm.computeCreateAddress(DEPLOYER, K_AT_FORK + i), "an address by nonce");
            assertEq(p.steps[i].nonce, K_AT_FORK + i, "a creation's nonce");
            assertEq(p.steps[i].target, p.contracts[i], "a creation's target");
        }
        assertEq(p.steps[8].target, p.contracts[0], "the bootstrap's target");
        assertEq(p.steps[9].target, p.contracts[0], "the lock's target");
        assertEq(p.firstSender, TIMELOCK, "the first sender is the timelock's own address");
        DeployBetting.Plan memory read = script.readPlan(dir);
        assertEq(script.planDigest(polygon, read), script.planDigest(polygon, p), "the plan as read back");
        vm.expectRevert(bytes("a plan exists: no new prediction while it stands"));
        script.predictFor(polygon, COMMIT, dir);
    }

    /// The deploy through the script in its three sending runs, each read back at its stage; a second key's bet
    /// after the bootstrap's receipt and before the lock, so the read-back passes on a used book; then the entry:
    /// signpostCall, K's schedule on the timelock, a stranger's execute, the id read from the receipt's log and the
    /// entry read back at it.
    function test_rehearsal_thePhasesInOrderOnAUsedBook() public {
        string memory dir = _dir("rehearsal");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        (uint256 proven, uint256 sent) = _phase(p, DeployBetting.Phase.Create);
        assertEq(proven, 0, "the prefix before create");
        assertEq(sent, 8, "create sends the eight");
        for (uint256 i; i < 8; ++i) {
            assertGt(p.contracts[i].code.length, 0, "a planned address holds no code after create");
        }
        assertEq(vm.getNonce(DEPLOYER), K_AT_FORK + 8, "the nonce after create");

        _nextBlock();
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 1);
        (proven, sent) = _phase(p, DeployBetting.Phase.Bootstrap);
        assertEq((proven * 10) + sent, 81, "bootstrap: the prefix eight, one send");
        _bind(p);
        assertEq(core.s_moduleCount(), 6, "the registry after the bootstrap");
        assertFalse(core.s_finalized(), "the core is not finalized after the bootstrap");

        // The second key's bet, after the bootstrap's receipt and before the lock: a used book.
        _nextBlock();
        _recording();
        _secondKeysBet();
        _kept();

        _nextBlock();
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 2);
        assertEq(markets.marketCount(), 1, "the used book's market");
        (proven, sent) = _phase(p, DeployBetting.Phase.Finalize);
        assertEq((proven * 10) + sent, 91, "finalize: the prefix nine, one send");
        assertTrue(core.s_finalized(), "the core is finalized");

        _nextBlock();
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 3);
        _nextBlock();
        (bytes memory scheduleCall, bytes32 operationId) =
            script.signpostCallFor(polygon, p, uint64(FORK_BLOCK + 1), dir);

        // K sends the schedule as written; the delay passes; a stranger runs the execute as written.
        string memory json = vm.readFile(string.concat(dir, "/signpost-call.json"));
        bytes memory run = vm.parseJsonBytes(json, ".execute");
        assertEq(vm.parseJsonBytes32(json, ".operationId"), operationId, "the operation id as written");
        uint256 preview = vm.parseJsonUint(json, ".previewId");
        vm.prank(K);
        (bool ok,) = TIMELOCK.call(scheduleCall);
        assertTrue(ok, "K's schedule");
        TimelockController t = TimelockController(payable(TIMELOCK));
        vm.warp(vm.getBlockTimestamp() + t.getMinDelay());
        vm.recordLogs();
        vm.prank(stranger);
        (ok,) = TIMELOCK.call(run);
        assertTrue(ok, "the stranger's execute");
        (uint256 id, bool found) = _entryAddedId(vm.getRecordedLogs());
        assertTrue(found, "no EntryAdded in the execute's logs");
        assertEq(id, preview, "the id, with nothing listed in between, is the preview");
        OspexSignpost.Entry memory e = OspexSignpost(SIGNPOST).getEntry(id);
        assertEq(uint8(e.kind), uint8(OspexSignpost.Kind.Betting), "the entry's kind");
        assertEq(e.coin, USDC, "the entry's coin");
        assertEq(e.contracts.length, 8, "the entry's contracts");
        for (uint256 i; i < 8; ++i) {
            assertEq(e.contracts[i], p.contracts[i], "an entry's contract");
            assertEq(e.codeHashes[i], p.contracts[i].codehash, "an entry's code hash");
        }
        assertEq(e.commit, COMMIT, "the entry's commit");
        assertEq(e.deployBlock, FORK_BLOCK + 1, "the entry's deploy block");
        assertEq(uint8(e.status), uint8(OspexSignpost.Status.Building), "the entry is building");
    }

    // ──────────────────────────── The users' side ───────────────────────

    /// @dev The game, the two accounts and their registration of the relay, on the deployed set.
    function _usersOnTheRelay() internal returns (Signer memory makerKey, Signer memory bettor, uint256 game) {
        (makerKey.a, makerKey.key) = makeAddrAndKey("the maker behind the relay");
        (bettor.a, bettor.key) = makeAddrAndKey("the bettor behind the relay");
        _fundWithUsdc(makerKey.a);
        _fundWithUsdc(bettor.a);
        uint256 fee = liveGames.getTerms("nba").fee;
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(creator, fee), "the creator's fee");
        game = _liveVerifiedGame(creator, usdc, fee);
        _register(makerKey.a, address(relay));
        _register(bettor.a, address(relay));
    }

    /// The users' side, end to end, on the set the script deployed, through the relay whose first sender is the
    /// timelock: K schedules the relay's Cross, the delay passes, a stranger runs it, and the timelock sends it,
    /// its taking order alive in the thirty seconds after the operation is ready; then the hand-over, a scheduled
    /// setSender, and a Cross of fresh orders from the new sender; the game scored 121 to 99 by the live set's
    /// first-n reporter's address; the market settled by a stranger; the maker paid both stakes of both Crosses,
    /// to the unit, by a stranger's claim for it; the bettor's claim refused NoPayout.
    function test_users_theTimelockSendsACrossThenHandsTheRelayToAKey() public {
        _deployTheSet("users");
        assertEq(relay.s_sender(), TIMELOCK, "the relay's first sender");
        (Signer memory makerKey, Signer memory bettor, uint256 game) = _usersOnTheRelay();
        uint256 makerHad = usdc.balanceOf(makerKey.a);
        uint256 bettorHad = usdc.balanceOf(bettor.a);

        // The Cross the timelock sends: signed before the schedule, its taking order alive for twenty seconds
        // past the moment the operation is ready.
        uint256 delay = TimelockController(payable(TIMELOCK)).getMinDelay();
        OspexMatching.SignedOrder memory resting = _rest(makerKey, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory taking =
            _takeUntil(bettor, game, Side.B, 190, 10_000, vm.getBlockTimestamp() + delay + 20);
        _throughTheTimelock(
            address(relay),
            abi.encodeCall(OspexMatching.cross, (taking, _list(resting))),
            keccak256("the first Cross, sent by the timelock")
        );
        assertEq(_filled(resting), 9_000, "the timelock's Cross: the maker's stake");
        assertEq(_filled(taking), 9_900, "the timelock's Cross: the bettor's stake");

        // The hand-over to a key, then a Cross of fresh orders from it.
        address courierKey = makeAddr("the courier's key");
        _throughTheTimelock(
            address(relay), abi.encodeCall(OspexCourierRelay.setSender, (courierKey)), keccak256("the hand-over")
        );
        assertEq(relay.s_sender(), courierKey, "the relay's sender after the hand-over");
        resting = _rest(makerKey, game, Side.A, 210, 10_000);
        taking = _take(bettor, game, Side.B, 190, 10_000);
        vm.prank(courierKey, courierKey);
        (bool ok, bytes memory err) = address(relay).call(abi.encodeCall(OspexMatching.cross, (taking, _list(resting))));
        assertTrue(ok, string.concat("the key's Cross was refused: ", vm.toString(err)));
        assertEq(_filled(taking), 9_900, "the key's Cross: the bettor's stake");

        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(usdc.balanceOf(address(positions)), 2 * 18_900, "the positions module after the two Crosses");

        // The score, the settlement, the claims.
        vm.warp(liveGames.getGameStart(game) + 2 hours);
        vm.prank(_liveFirstN());
        liveGames.report(_scoreReport(game, 121, 99));
        vm.prank(stranger);
        markets.settleMarket(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home), "the outcome");
        vm.prank(stranger);
        uint256 paid = positions.claimPositionFor(market, makerKey.a, Side.A);
        assertEq(paid, 2 * 18_900, "the maker's payout");
        assertEq(usdc.balanceOf(stranger), 0, "the stranger was paid");
        assertEq(usdc.balanceOf(makerKey.a), makerHad + 2 * 9_900, "the maker: what it had, and the bettor's stakes");
        (ok, err) = _tryClaim(bettor.a, market, Side.B);
        assertFalse(ok, "the losing side was paid");
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector), "the losing side's refusal");
        assertEq(usdc.balanceOf(bettor.a), bettorHad - 2 * 9_900, "the bettor: what it had, less its stakes");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module at the end");
        assertEq(positions.s_heldTotal(market), 0, "the liabilities at the end");
    }

    /// The cap, shown on the deployed set: a resting order at tick 101 with room for 2,000,000 units is filled
    /// by two takes of 10,000, each time the maker staking 1,000,000 units, one USDC, against one cent; a third
    /// take finds no room and fills nothing.
    function test_cap_atTick101AMakerStakesOneUsdcAgainstACent() public {
        _deployTheSet("tick101");
        (Signer memory makerKey, Signer memory bettor, uint256 game) = _usersOnTheRelay();
        address courierKey = makeAddr("a courier at tick 101");
        _register(makerKey.a, courierKey);
        _register(bettor.a, courierKey);
        OspexMatching.SignedOrder memory resting = _rest(makerKey, game, Side.A, 101, 2_000_000);
        for (uint256 i; i < 2; ++i) {
            OspexMatching.SignedOrder memory taking = _take(bettor, game, Side.B, 10_100, 10_000);
            _cross(courierKey, taking, _list(resting));
            assertEq(_filled(taking), 10_000, "a take of one cent, filled");
        }
        assertEq(_filled(resting), 2_000_000, "the maker's two stakes of one USDC");
        OspexMatching.SignedOrder memory third = _take(bettor, game, Side.B, 10_100, 10_000);
        (bool ok, bytes memory err) = _tryCross(courierKey, third, _list(resting));
        assertFalse(ok, "the third take filled");
        assertEq(err, _nothingFilled(_reasons(NO_ROOM)), "the third take's refusal: no room");
        assertEq(_filled(third), 0, "the third take's filled amount");
    }

    /// The refusals on the deployed set, each fixture meeting every other gate so that it can only be the
    /// refusal it names, each by its exact error, with nothing moved: a game not verified; a taking order of
    /// 10,100 units, then the lift through the live timelock and a fresh 10,100 filled on a fresh game; and a
    /// sender that is not the relay's, at the relay and at the matching module.
    function test_refusals_theGateTheCapAndASenderNotTheRelays() public {
        _deployTheSet("refusals");
        (Signer memory makerKey, Signer memory bettor, uint256 game) = _usersOnTheRelay();
        address courierKey = makeAddr("a courier for the refusals");
        _register(makerKey.a, courierKey);
        _register(bettor.a, courierKey);

        // The gate: a game with no start written.
        uint256 fee = liveGames.getTerms("nba").fee;
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(creator, fee), "the creator's fee");
        vm.startPrank(creator);
        assertTrue(usdc.approve(address(liveGames), fee), "the fee's approval");
        uint256 unverified = liveGames.createGame(
            "nba", "Home Team", "Away Team", uint64(vm.getBlockTimestamp() + 1 days), new Hint[](0), fee
        );
        vm.stopPrank();
        uint256 inPositions = usdc.balanceOf(address(positions));
        OspexMatching.SignedOrder memory restOn = _rest(makerKey, unverified, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory takeOn = _take(bettor, unverified, Side.B, 190, 10_000);
        (bool ok, bytes memory err) = _tryCross(courierKey, takeOn, _list(restOn));
        assertFalse(ok, "a Cross on a game not verified");
        assertEq(
            err,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameNotVerified.selector, unverified, GameStatus.Unverified),
            "the gate's refusal"
        );
        assertEq(usdc.balanceOf(address(positions)), inPositions, "the gate's refusal moved coin");

        // The cap: 10,100 refused; the lift through the live timelock; 10,100 filled on a fresh game.
        OspexMatching.SignedOrder memory above = _take(bettor, game, Side.B, 200, 10_100);
        (ok, err) = _tryCross(courierKey, above, _list(_rest(makerKey, game, Side.A, 200, 10_100)));
        assertFalse(ok, "10,100 before the lift");
        assertEq(err, _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, above), "the cap's refusal");
        _throughTheTimelock(address(matching), abi.encodeCall(OspexMatching.liftTakingStakeCap, ()), keccak256("the lift"));
        assertTrue(matching.s_takingStakeCapLifted(), "the lift");
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(creator, fee), "the creator's second fee");
        uint256 fresh = _liveVerifiedGame(creator, usdc, fee);
        above = _take(bettor, fresh, Side.B, 200, 10_100);
        _cross(courierKey, above, _list(_rest(makerKey, fresh, Side.A, 200, 10_100)));
        assertEq(_filled(above), 10_100, "10,100 after the lift");

        // A sender that is not the relay's: at the relay, and straight at the matching module.
        OspexMatching.SignedOrder memory resting = _rest(makerKey, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory taking = _take(bettor, game, Side.B, 190, 10_000);
        vm.prank(stranger, stranger);
        (ok, err) = address(relay).call(abi.encodeCall(OspexMatching.cross, (taking, _list(resting))));
        assertFalse(ok, "a stranger at the relay");
        assertEq(
            err, abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheSender.selector, stranger), "the relay's refusal"
        );
        (ok, err) = _tryCross(stranger, taking, _list(resting));
        assertFalse(ok, "a stranger at the matching module");
        assertEq(
            err,
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, bettor.a, stranger),
            "the matching module's refusal"
        );
    }

    // ──────────────────────────── The never-lines ───────────────────────
    //
    // Each test below is the witness of the scenarios section 5 of the build order names for it. A break changes
    // the production decision its words name, and the witness asserts the exact refusal, so its record says
    // whether another guard would still have stopped the run (red by message) or nothing would have (red by
    // outcome).

    /// @dev A games set built on the fork for the identity tests: the live timelock or another, Polygon's USDC,
    ///      the launch terms, the test base's first reporter.
    function _gamesFixture(address answersTo) internal returns (address) {
        address[] memory reporters = new address[](1);
        reporters[0] = address(first);
        ReporterKind[] memory kinds = new ReporterKind[](1);
        kinds[0] = ReporterKind.FirstN;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = address(first).codehash;
        DeployGames g = new DeployGames();
        return address(new OspexGames(answersTo, usdc, g.launchTerms(), reporters, kinds, hashes));
    }

    /// D1, the games entry (D1/1). The table's games contract must be the signpost's games entry's, with the code
    /// the entry recorded: a games set built on the fork, coherent in everything else (the live timelock, USDC),
    /// is refused by that check alone. The positive control: the table as pinned passes.
    function test_neverLine_theGamesSetIsTheEntrysWithItsRecordedCode() public {
        script.requireChain(polygon);
        DeployBetting.Inputs memory in_ = polygon;
        in_.games = _gamesFixture(TIMELOCK);
        vm.expectRevert(bytes("the table's games contract is not the games entry's, with its recorded code"));
        script.requireChain(in_);
    }

    /// D1, the coin (D1/2). The coin must be the games set's own: a coin of six decimals that is not it is refused by
    /// that check alone.
    function test_neverLine_theCoinIsTheGamesSetsOwn() public {
        DeployBetting.Inputs memory in_ = polygon;
        in_.coin = address(new TestCoin());
        vm.expectRevert(bytes("the coin is not the games set's own"));
        script.requireChain(in_);
    }

    /// D1, the timelock (D1/3). The games set must answer to the table's timelock: a games set that answers to
    /// another, listed on the signpost through the live timelock as a games entry and holding Polygon's USDC, is
    /// refused by that check alone; the table's timelock, the signpost's owner, stands.
    function test_neverLine_theGamesSetAnswersToTheTablesTimelock() public {
        address other = address(new TimelockController(60, _oneAddress(K), _oneAddress(address(0)), address(0)));
        address fixture = _gamesFixture(other);
        uint256 entry = OspexSignpost(SIGNPOST).entryCount();
        address[] memory set = _oneAddress(fixture);
        _throughTheTimelock(
            SIGNPOST,
            abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Games, address(0), set, COMMIT, uint64(block.number))),
            keccak256("a games set that answers to another timelock")
        );
        DeployBetting.Inputs memory in_ = polygon;
        in_.games = fixture;
        in_.gamesEntry = entry;
        vm.expectRevert(bytes("the games set's timelock is not the table's"));
        script.requireChain(in_);
    }

    /// D2, the relay's identity (D2/1). After the deploy, a relay built against another matching module is put at the
    /// relay's address: signpostCall refuses, and writes no call.
    function test_neverLine_noEntryIsWrittenForARelayWhoseIdentityWasNotRead() public {
        (DeployBetting.Plan memory p, string memory dir) = _deployTheSet("relay-identity");
        // A matching module on a core of the test base's games set, which answers to the test base's timelock.
        address otherMatching = address(new OspexMatching(_otherCore()));
        address foreign = address(new OspexCourierRelay(otherMatching, TIMELOCK));
        vm.etch(p.contracts[7], foreign.code);
        _nextBlock();
        vm.expectRevert(bytes("a contract's code at the finalized block is not this plan's"));
        script.signpostCallFor(polygon, p, uint64(FORK_BLOCK + 1), dir);
        assertFalse(vm.exists(string.concat(dir, "/signpost-call.json")), "a call was written");
    }

    /// D3 (D3/1). After the lock, the deployer keeps no registry right: s_finalized, and its bootstrap and finalize
    /// refused AlreadyFinalized, by name.
    function test_neverLine_theDeployerKeepsNoRegistryRight() public {
        (DeployBetting.Plan memory p,) = _deployTheSet("no-registry-right");
        OspexBetting c = OspexBetting(p.contracts[0]);
        assertTrue(c.s_finalized(), "the core is not finalized");
        vm.prank(DEPLOYER);
        vm.expectRevert(OspexBetting.OspexBetting__AlreadyFinalized.selector);
        c.bootstrapModules(new bytes32[](0), new address[](0));
        vm.prank(DEPLOYER);
        vm.expectRevert(OspexBetting.OspexBetting__AlreadyFinalized.selector);
        c.finalize();
    }

    /// D3, the roles (D3/2). A deployer that is the first sender, the timelock or the key is refused before the plan.
    function test_neverLine_theDeployerIsNotTheFirstSenderTheTimelockOrTheKey() public {
        string memory dir = _dir("roles");
        _nextBlock();
        DeployBetting.Inputs memory in_ = polygon;
        in_.firstSender = DEPLOYER;
        vm.expectRevert(bytes("the deployer is the first sender"));
        script.predictFor(in_, COMMIT, dir);
        in_ = polygon;
        in_.deployer = TIMELOCK;
        in_.firstSender = stranger;
        vm.expectRevert(bytes("the deployer is the timelock"));
        script.predictFor(in_, COMMIT, dir);
        in_ = polygon;
        in_.deployer = K;
        vm.expectRevert(bytes("the deployer is the key"));
        script.predictFor(in_, COMMIT, dir);
    }

    /// @dev The plan, its creations sent and read back at stage 1: the set up to the bootstrap.
    function _created(string memory name) internal returns (DeployBetting.Plan memory p, string memory dir) {
        dir = _dir(name);
        _nextBlock();
        p = script.predictFor(polygon, COMMIT, dir);
        _phase(p, DeployBetting.Phase.Create);
        _bind(p);
        _nextBlock();
    }

    /// D4, the cap's state (D4/1). Before the bootstrap the cap cannot be lifted at all: the lift emits through the
    /// core, which refuses a module not yet registered, so the lift itself reverts. After the bootstrap it can be,
    /// through the live timelock: the next guard read, finalize's, refuses by the cap's read, and nothing is sent.
    function test_neverLine_aLiftedCapHoldsTheNextSend() public {
        (DeployBetting.Plan memory p,) = _created("cap-lifted");
        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        bytes memory lift = abi.encodeCall(OspexMatching.liftTakingStakeCap, ());
        bytes32 salt = keccak256("a lift before the bootstrap");
        _recording();
        vm.prank(K);
        t.schedule(p.contracts[3], 0, lift, bytes32(0), salt, delay);
        _kept();
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OspexBetting.OspexBetting__NotRegisteredModule.selector, p.contracts[3])
        );
        t.execute(p.contracts[3], 0, lift, bytes32(0), salt);
        // forge's recorder keeps a log emitted inside a call that then reverted; a chain's log query never
        // returns one. The reverted lift's logs are dropped here, as the chain drops them.
        vm.getRecordedLogs();
        // The failed lift stays ready, and the scan would hold on it: K cancels it, as it would live.
        bytes32 failedLift = t.hashOperation(p.contracts[3], 0, lift, bytes32(0), salt);
        vm.prank(K);
        t.cancel(failedLift);
        _kept();
        _nextBlock();

        _phase(p, DeployBetting.Phase.Bootstrap);
        _nextBlock();
        _recording();
        _throughTheTimelock(p.contracts[3], lift, keccak256("a lift after the bootstrap"));
        _kept();
        _nextBlock();
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("the cap is lifted"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Finalize);
        assertFalse(OspexBetting(p.contracts[0]).s_finalized(), "the lock was sent");
    }

    /// @dev K schedules the lift on the new matching module and nobody runs it: a waiting operation that names it.
    function _waitingLift(address matchingModule) internal {
        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        _recording();
        vm.prank(K);
        t.schedule(
            matchingModule,
            0,
            abi.encodeCall(OspexMatching.liftTakingStakeCap, ()),
            bytes32(0),
            keccak256("a lift that waits"),
            delay
        );
        _kept();
    }

    /// D4, the scan (D4/2), a waiting lift at or below the finalized block: the bootstrap holds.
    function test_neverLine_aWaitingLiftAtTheFinalizedBlockHolds() public {
        (DeployBetting.Plan memory p,) = _created("waiting-lift-final");
        _waitingLift(p.contracts[3]);
        _nextBlock();
        _nextBlock();
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("a waiting or ready timelock operation names the matching module or the relay: held"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Bootstrap);
    }

    /// D4, the scan (D4/2), a waiting lift mined above the finalized block: the scan reads the tail to the latest
    /// block, and the bootstrap holds (R1).
    function test_neverLine_aWaitingLiftAboveTheFinalizedBlockHolds() public {
        (DeployBetting.Plan memory p,) = _created("waiting-lift-tail");
        uint256 creations = FORK_BLOCK + 1;
        _waitingLift(p.contracts[3]);
        uint256 lifted = vm.getBlockNumber();
        _nextBlock();
        script.nameFinalized(creations);
        assertGt(lifted, creations, "the lift is not above the finalized block");
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("a waiting or ready timelock operation names the matching module or the relay: held"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Bootstrap);
    }

    /// D5, a moved nonce (D5/1). A transaction of the deployer's after the plan moves its nonce: create refuses by
    /// the nonce, before any send.
    function test_neverLine_aMovedNonceStopsTheRunBeforeAnySend() public {
        string memory dir = _dir("moved-nonce");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        vm.setNonce(DEPLOYER, K_AT_FORK + 1);
        _nextBlock();
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(
            bytes("the deployer's nonce is not k plus the proven prefix: a send not yet final, or a nonce used otherwise: held")
        );
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Create);
        for (uint256 i; i < 8; ++i) {
            assertEq(p.contracts[i].code.length, 0, "a creation was sent");
        }
    }

    /// D5 and D9, a pending send (D5/2, D9/1). The deployer has a transaction sent and not mined: the run holds.
    /// A TEST ADAPTER stands for the pending nonce here; the anvil rehearsal by hand shows it with mining off.
    function test_neverLine_aPendingSendHoldsTheRun() public {
        string memory dir = _dir("pending");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        script.setPendingExtra(1);
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("the deployer has a pending transaction: held"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Create);
        assertEq(p.contracts[0].code.length, 0, "a creation was sent");
    }

    /// D5, foreign code (D5/3). The deployer's nonce k used for something else, whose code sits at the core's address:
    /// create holds on code that is not the plan's.
    function test_neverLine_foreignCodeAtAPlannedAddressHolds() public {
        string memory dir = _dir("foreign-code");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        vm.etch(p.contracts[0], _otherCore().code);
        vm.setNonce(DEPLOYER, K_AT_FORK + 1);
        _nextBlock();
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("a planned address holds code that is not this plan's: held"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Create);
        assertEq(p.contracts[1].code.length, 0, "a creation was sent after the foreign code");
    }

    /// D5, the frozen list (D5/4). Each sending run sends exactly its plan steps and nothing else, read from the
    /// sends' own accesses: the account each acts on and the hash of its exact input.
    function test_neverLine_eachRunSendsItsStepsAndNothingElse() public {
        string memory dir = _dir("frozen-list");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        _phase(p, DeployBetting.Phase.Create);
        _assertSent(p, 0, 8);
        _nextBlock();
        _phase(p, DeployBetting.Phase.Bootstrap);
        _assertSent(p, 8, 9);
        _nextBlock();
        _phase(p, DeployBetting.Phase.Finalize);
        _assertSent(p, 9, 10);
    }

    function _assertSent(DeployBetting.Plan memory p, uint256 from, uint256 to) internal view {
        assertEq(script.lastSentCount(), to - from, "the run's sends are not its steps");
        for (uint256 i = from; i < to; ++i) {
            DeployBettingHarness.Sent memory s = script.lastSentAt(i - from);
            assertEq(s.account, p.steps[i].target, "a send's account is not its step's");
            assertEq(s.inputHash, p.steps[i].inputHash, "a send's input is not its step's");
            assertEq(s.creation, i < 8, "a send's kind is not its step's");
        }
    }

    /// D5, the successful prefix. A run that stopped after three creations: create sends the five missing, at
    /// k + 3 to k + 7, and nothing else; a phase whose steps are proven sends nothing and reads back.
    function test_prefix_aStoppedRunIsFinishedFromItsProvenPrefix() public {
        string memory dir = _dir("prefix");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        script.sendSteps(polygon, p, 0, 3);
        _nextBlock();
        (uint256 proven, uint256 sent) = _phase(p, DeployBetting.Phase.Create);
        assertEq(proven, 3, "the proven prefix");
        assertEq(sent, 5, "the missing five");
        _assertSent(p, 3, 8);
        _nextBlock();
        (proven, sent) = _phase(p, DeployBetting.Phase.Create);
        assertEq(proven, 8, "the eight, proven");
        assertEq(sent, 0, "a completed phase sent");
        (proven, sent) = _phase(p, DeployBetting.Phase.Bootstrap);
        assertEq(sent, 1, "the bootstrap");
        _nextBlock();
        (proven, sent) = _phase(p, DeployBetting.Phase.Bootstrap);
        assertEq(proven, 9, "the bootstrap, proven");
        assertEq(sent, 0, "a completed bootstrap sent");
    }

    /// D5, the prefix at ten. Once the lock is final, a run of any of the three phases proves all ten steps, sends
    /// nothing and reads the set back at the stage it is at, the third: a finalized set still proves its bootstrap,
    /// and a completed phase never asks for its own earlier state.
    function test_prefix_aFinishedSetSendsNothingFromAnyPhase() public {
        (DeployBetting.Plan memory p,) = _created("finished");
        _phase(p, DeployBetting.Phase.Bootstrap);
        _nextBlock();
        _phase(p, DeployBetting.Phase.Finalize);
        _nextBlock();
        DeployBetting.Phase[3] memory phases =
            [DeployBetting.Phase.Create, DeployBetting.Phase.Bootstrap, DeployBetting.Phase.Finalize];
        for (uint256 i; i < 3; ++i) {
            (uint256 proven, uint256 sent) = _phase(p, phases[i]);
            assertEq(proven, 10, "a finished set's prefix");
            assertEq(sent, 0, "a completed phase sent");
        }
        script.checkFor(polygon, p, p.contracts[0], FORK_BLOCK + 1, 3);
    }

    /// D7, the commit in the digest (D7/1). Two plans that differ in their commit alone have different digests; the
    /// same plan has the same digest (the positive control).
    function test_neverLine_theDigestBindsTheCommit() public view {
        DeployBetting.Plan memory a = script.buildPlanFor(polygon, K_AT_FORK, COMMIT, 1, bytes32(uint256(1)));
        DeployBetting.Plan memory b = script.buildPlanFor(polygon, K_AT_FORK, bytes20(uint160(1)), 1, bytes32(uint256(1)));
        DeployBetting.Plan memory c = script.buildPlanFor(polygon, K_AT_FORK, COMMIT, 1, bytes32(uint256(1)));
        assertTrue(script.planDigest(polygon, a) != script.planDigest(polygon, b), "the digest does not bind the commit");
        assertEq(script.planDigest(polygon, a), script.planDigest(polygon, c), "one plan, two digests");
    }

    /// D8, a zero first sender (D8/1): predict refuses while the first sender is zero.
    function test_neverLine_predictRefusesAZeroFirstSender() public {
        string memory dir = _dir("zero-sender");
        _nextBlock();
        DeployBetting.Inputs memory in_ = polygon;
        in_.firstSender = address(0);
        vm.expectRevert(bytes("the first sender is not ruled"));
        script.predictFor(in_, COMMIT, dir);
        assertFalse(vm.exists(string.concat(dir, "/prediction.json")), "a plan was written");
    }

    /// D8, the sender as deployed (D8/2): the bootstrap reads the relay's sender, the first sender as ruled, before
    /// any registry write. Its witness is the bootstrap of the rehearsal; this reads the relay as created.
    function test_neverLine_theRelaysSenderIsTheRuledFirstSender() public {
        (DeployBetting.Plan memory p,) = _created("sender");
        assertEq(OspexCourierRelay(p.contracts[7]).s_sender(), TIMELOCK, "the relay's sender as created");
        (uint256 proven, uint256 sent) = _phase(p, DeployBetting.Phase.Bootstrap);
        assertEq(proven * 10 + sent, 81, "the bootstrap after the sender's read");
    }

    /// D8, the relay's current sender. The relay as created, its code and every immutable the plan's, then only its
    /// sender moved, in the fork's storage, to another nonzero address: the bootstrap refuses by the sender's read,
    /// and the registry is untouched. The test above is its positive control.
    function test_neverLine_aRelayWhoseSenderMovedHoldsTheBootstrap() public {
        (DeployBetting.Plan memory p,) = _created("sender-moved");
        address other = makeAddr("another sender");
        // The relay's one storage slot, slot 0, holds its sender.
        vm.store(p.contracts[7], bytes32(0), bytes32(uint256(uint160(other))));
        assertEq(OspexCourierRelay(p.contracts[7]).s_sender(), other, "the fixture's sender");
        _nextBlock();
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("the relay's sender is not the first sender"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Bootstrap);
        assertEq(OspexBetting(p.contracts[0]).s_moduleCount(), 0, "the registry moved");
    }

    /// D4, the scan, a batch. Each call of a scheduled batch is its own scheduled-call log: a waiting batch whose
    /// second call names the relay holds the bootstrap as a single call would.
    function test_neverLine_aWaitingBatchThatNamesTheRelayHolds() public {
        (DeployBetting.Plan memory p,) = _created("waiting-batch");
        TimelockController t = TimelockController(payable(TIMELOCK));
        uint256 delay = t.getMinDelay();
        address[] memory targets = new address[](2);
        targets[0] = SIGNPOST;
        targets[1] = p.contracts[7];
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(OspexSignpost.entryCount, ());
        payloads[1] = abi.encodeCall(OspexCourierRelay.setSender, (makeAddr("a key")));
        _recording();
        vm.prank(K);
        t.scheduleBatch(targets, values, payloads, bytes32(0), keccak256("a batch that waits"), delay);
        _kept();
        _nextBlock();
        _nextBlock();
        bytes32 digest = script.planDigest(polygon, p);
        vm.expectRevert(bytes("a waiting or ready timelock operation names the matching module or the relay: held"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, DeployBetting.Phase.Bootstrap);
    }

    /// D10, the stage signpostCall asks for (D10/1): on a core bootstrapped and not finalized, signpostCall refuses,
    /// and writes no call.
    function test_neverLine_noEntryIsWrittenForASetNotFinalized() public {
        (DeployBetting.Plan memory p, string memory dir) = _created("not-finalized");
        _phase(p, DeployBetting.Phase.Bootstrap);
        _nextBlock();
        vm.expectRevert(bytes("the core's lock is not the stage's"));
        script.signpostCallFor(polygon, p, uint64(FORK_BLOCK + 1), dir);
        assertFalse(vm.exists(string.concat(dir, "/signpost-call.json")), "a call was written");
    }

    // ──────────────────────────── The sending runs' other refusals ──────

    /// A sending run refuses, before anything is sent: a sender that is not the deployer; a digest that is not the
    /// plan's; a plan file edited after its digest; a go value of zero; a maximum fee above the ceiling; a deployer
    /// holding less than twice the remaining steps' cost.
    function test_runs_refuseWhatIsNotThePlansOrTheOrders() public {
        string memory dir = _dir("refuse");
        _nextBlock();
        DeployBetting.Plan memory p = script.predictFor(polygon, COMMIT, dir);
        bytes32 digest = script.planDigest(polygon, p);
        DeployBetting.Phase create = DeployBetting.Phase.Create;

        vm.expectRevert(bytes("the sender is not the deployer"));
        script.phaseFrom(polygon, p, stranger, digest, FORK_GO, MAX_FEE, create);
        vm.expectRevert(bytes("the digest is not this plan's"));
        script.phaseFrom(polygon, p, DEPLOYER, bytes32(uint256(digest) ^ 1), FORK_GO, MAX_FEE, create);
        DeployBetting.Plan memory edited = script.readPlan(dir);
        edited.steps[3].inputHash = bytes32(uint256(1));
        vm.expectRevert(bytes("the plan's steps are not this script's"));
        script.phaseFrom(polygon, edited, DEPLOYER, digest, FORK_GO, MAX_FEE, create);
        vm.expectRevert(bytes("the go value is zero"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, bytes16(0), MAX_FEE, create);
        vm.expectRevert(bytes("the maximum fee is not within the ceiling"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, 600 gwei + 1, create);
        vm.deal(DEPLOYER, 1 ether);
        vm.expectRevert(bytes("the deployer holds less than twice the remaining steps' cost"));
        script.phaseFrom(polygon, p, DEPLOYER, digest, FORK_GO, MAX_FEE, create);
        assertEq(p.contracts[0].code.length, 0, "a creation was sent");
    }

    /// @dev A core of this repository on the test base's games set and coin: code that is not the plan's.
    function _otherCore() internal returns (address) {
        return address(new OspexBetting(address(games), address(token)));
    }

    function _oneAddress(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// @dev The live games set's first-n reporter, as approved at the fork block.
    function _liveFirstN() internal view returns (address firstN) {
        (address[] memory reporters, uint8[] memory kinds) = liveGames.getApprovedReporters();
        for (uint256 i; i < reporters.length; ++i) {
            if (kinds[i] == uint8(ReporterKind.FirstN)) return reporters[i];
        }
        revert("the live games set has no first-n reporter");
    }

    /// @dev The second key's bet: a fixture maker rests an order on a game verified on the fork and registers the
    ///      second key as its courier; the second key registers itself for its own account and sends a Cross of its
    ///      own taking order, 10,000 units, straight to the matching module.
    function _secondKeysBet() internal {
        Signer memory makerKey;
        Signer memory secondKey;
        (makerKey.a, makerKey.key) = makeAddrAndKey("the fixture maker");
        (secondKey.a, secondKey.key) = makeAddrAndKey("the second key");
        _fundWithUsdc(makerKey.a);
        _fundWithUsdc(secondKey.a);
        uint256 fee = liveGames.getTerms("nba").fee;
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(creator, fee), "the creator's fee");
        uint256 game = _liveVerifiedGame(creator, usdc, fee);
        _register(makerKey.a, secondKey.a);
        _register(secondKey.a, secondKey.a);
        OspexMatching.SignedOrder memory resting = _rest(makerKey, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory taking = _take(secondKey, game, Side.B, 190, 10_000);
        _cross(secondKey.a, taking, _list(resting));
        assertEq(_filled(taking), 9_900, "the second key's bet, filled");
    }
}
