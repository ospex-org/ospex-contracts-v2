// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexBetting} from "../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../src/betting/OspexPositions.sol";
import {OspexMatching} from "../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../src/betting/OspexTotalScorer.sol";
import {OspexCourierRelay} from "../src/betting/OspexCourierRelay.sol";
import {OspexSignpost} from "../src/signpost/OspexSignpost.sol";
import {DeployGames} from "./DeployGames.s.sol";

/// @dev The two reads the script makes of the games set: the timelock it answers to and the coin it holds.
interface IBettingGamesRead {
    function i_timelock() external view returns (address);
    function i_token() external view returns (address);
}

/// @dev The reads the script makes of the set's public values, each answered by the contract's own getter.
interface IBettingCoreRead {
    function i_games() external view returns (address);
    function i_token() external view returns (address);
    function i_deployer() external view returns (address);
    function s_finalized() external view returns (bool);
    function s_moduleCount() external view returns (uint256);
}

interface IBettingMatchingRead {
    function i_timelock() external view returns (address);
    function s_takingStakeCapLifted() external view returns (bool);
    function TAKING_STAKE_CAP() external view returns (uint256);
}

interface IBettingRelayRead {
    function i_matching() external view returns (address);
    function i_timelock() external view returns (address);
    function s_sender() external view returns (address);
}

/// @dev The coin's decimals.
interface IBettingCoinRead {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title DeployBetting
 * @notice Deploy day for the betting set: the core, its six modules and the courier relay, then the registry
 *         bootstrapped and finalized. Ten sends from one deployer, at its nonces k to k + 9, from one plan. Every run
 *         goes through script/deploy-betting.sh, which checks the commit, the tree, forge and the node first.
 *
 *         Phases, each its own `--sig`:
 *         1. `predict(bytes20 commit)`, no broadcast. Reads the deployer's nonce k, predicts the eight addresses,
 *            writes the plan to deployments/betting-set/<chain id>/prediction.json, and prints the plan's digest.
 *         2. `create(bytes32 digest, bytes16 go, uint256 maxFee)`, `--broadcast --slow`. The creations the
 *            chain has not yet proven, at k to k + 7.
 *         3. `bootstrap(...)`, `--broadcast`. The bootstrap of the six, at k + 8, after every identity, build and
 *            wiring check at the finalized block.
 *         4. `finalize(...)`, `--broadcast`. The lock, at k + 9.
 *         5. `check(address core, uint256 creationBlock, uint8 stage)`, read only: the set against the plan at
 *            the stage named, 1 created, 2 bootstrapped, 3 finalized.
 *         6. `signpostCall(uint64 deployBlock)`, read only: the entry the key schedules on the timelock.
 *
 *         Why three sending runs. Forge runs the whole script, then broadcasts the transactions it collected. No
 *         code of the script runs after a receipt within one run: a read between two of its sends sees the
 *         simulation, and a read of the node sees the chain before any of that run's sends. A check that must
 *         read a real receipt needs a new run, so the ten sends are three: the creations; the bootstrap, the one
 *         call that exposes the set; and the lock.
 *
 *         What each sending run reads first, from the node, at two anchors it reads once and uses by number:
 *         the finalized block, and the block before the run's own (the latest). It reads both again before it
 *         sends, and a changed block holds. The prefix: the plan's steps, from k, proven by their effect at the
 *         finalized block. The deployer's latest and pending nonces must both be k plus the prefix. A run sends
 *         only what the prefix has not proven, and a phase already done sends nothing and reads back. A nonce
 *         above the prefix, a send not yet final or a nonce used for something else, holds: nothing is sent
 *         again on a guess.
 *
 *         The go value is a non-zero acknowledgement that a value was given. It does not authenticate an
 *         approval: on deploy day the operator reads the comment it names against the plan before the first
 *         send. The fork's runs carry FORK_GO, a fixture value; the wrapper refuses it in live mode.
 *
 *         From the bootstrap's receipt the set takes bets under the cap, whether or not finalize has run and
 *         whether or not the signpost lists it. The set is never abandoned merely because it is used: identity,
 *         receipt and governance discrepancies hold further sends; use and balance are recorded.
 */
contract DeployBetting is Script {
    // ──────────────────────────── The ruled values ─────────────────────

    /// @notice The deployer: the operator's working wallet, the address that created the games set.
    address public constant DEPLOYER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @notice The relay's first sender: the Polygon timelock's own address, until the courier is live.
    address public constant FIRST_SENDER = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;

    /// @notice The go value the wrapper passes on its own fork: the first sixteen bytes of keccak256("fork").
    ///         A fixture value, not an approval, and refused by the wrapper in live mode.
    bytes16 public constant FORK_GO = bytes16(keccak256("fork"));

    /// @notice The deploy-day order's bounds: the highest maximum fee per gas a run may carry, and the most the
    ///         remaining steps may cost at that fee. A run's balance must hold twice that cost.
    uint256 public constant MAX_FEE_CEILING = 600 gwei;
    uint256 public constant SPEND_BOUND = 10 ether;

    /// @notice The cap on each signed taking order's stake that the matching module is born with.
    uint256 public constant TAKING_STAKE_CAP = 10_000;

    /// @notice The stages `check` holds a set to.
    uint8 public constant CREATED = 1;
    uint8 public constant BOOTSTRAPPED = 2;
    uint8 public constant FINALIZED = 3;

    uint256 public constant CREATIONS = 8;
    uint256 public constant STEPS = 10;

    /// @dev The widest block range one log read asks the node for. A longer range is read in windows.
    uint256 public constant LOG_WINDOW = 10_000;
    /// @dev How far above and below the run's own block the finalized block is looked for.
    uint256 public constant ANCHOR_AHEAD = 16;
    uint256 public constant ANCHOR_BEHIND = 250;

    /// @dev The timelock's log of a scheduled call: one per call, a batch's calls each with its index.
    bytes32 internal constant CALL_SCHEDULED =
        keccak256("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)");
    /// @dev An address that executes the entry in signpostCall's own simulation. Nobody holds its key.
    address internal constant PROOF_EXECUTOR = address(uint160(uint256(keccak256("ospex betting proof executor"))));

    // ──────────────────────────── The pinned build ─────────────────────

    /// @dev keccak256 of each contract's creation code, every byte, the metadata included: the build at this
    ///      commit with solc 0.8.26, via IR, the optimizer at 200 runs, Cancun, this repository's foundry.toml and
    ///      remappings.txt. And the same with the metadata's source digest zeroed: every executable byte.
    bytes32 public constant CORE_INIT_HASH = 0x10bc3a005731246f516a196da544d7ea664d3e441b65ae7be3f55a2f390a08ee;
    bytes32 public constant CORE_STOCK_HASH = 0x9b7af64601a8b54cef54eb7efbb04756f08952125678f6be706b44c4e34b5e8f;
    bytes32 public constant MARKETS_INIT_HASH = 0x17d91f1cdacfc44527ec35c18ffddd87aadc5ea25df521e0a1b24f0ee7a79fe9;
    bytes32 public constant MARKETS_STOCK_HASH = 0xc5e8178da4da4390e5ec36bcdd78b71ad03b2dea00d8dc766b8eb39d567980c9;
    bytes32 public constant POSITIONS_INIT_HASH = 0xfbbe1f5b92ad4761486c465fd5010975f7fe3112b783a37c6d7da6227533a2e5;
    bytes32 public constant POSITIONS_STOCK_HASH = 0x9ed7723da2e200130d6d2d7e5a1a4af4684a6b69f0dd32ae9c8b35528ce06e14;
    bytes32 public constant MATCHING_INIT_HASH = 0xc34ef2c77552b2a6156965a97194cd4f27cb3c219001703cd60da8bbe85717b3;
    bytes32 public constant MATCHING_STOCK_HASH = 0xf4b29d43de601b73361c2783774095acd2b048db14bebe8697618c6540c59f43;
    bytes32 public constant MONEYLINE_INIT_HASH = 0x2eeea8cf79eff7ca49f90382a8af06ee7012a4630ad29c0f0bc82794fa9c9347;
    bytes32 public constant MONEYLINE_STOCK_HASH = 0x0180652822e922a1e63e51d7b6200a77a3b2c2bf8f2529cbe9b488c27a5b056d;
    bytes32 public constant SPREAD_INIT_HASH = 0x765b02f86e5804884fd43299b643df251d1eec30e3f695d179900ada7e55e5bc;
    bytes32 public constant SPREAD_STOCK_HASH = 0x9f771f24e5e4dd84d5d2278bea1b5d241b0578650cfe6515a27a639837d8c3d9;
    bytes32 public constant TOTAL_INIT_HASH = 0x5025d12be6d1f17e3147d1bfc24804a716cd110871119c760091bd48116f5d4f;
    bytes32 public constant TOTAL_STOCK_HASH = 0x4ebccbc6f8e63d30530c103d4af7ea4fdea36f0fbe868210a136f96310c5ae07;
    bytes32 public constant RELAY_INIT_HASH = 0x87fdbef3eb67b931a21c2b3e7142e7675fd4833532081524676fbc29a21992c4;
    bytes32 public constant RELAY_STOCK_HASH = 0x758d0fd72284e3e1c0e64fbbebac7bad8e52c8b2a1414e874b646eebec418827;

    /// @dev The games set's deploy script: its check of the Polygon timelock, reused as it is.
    DeployGames public immutable gamesDeploy;

    // ──────────────────────────── The table, per chain ─────────────────

    /// @notice The fixed addresses and the ruled values. Each address is checked against the chain before
    ///         anything is sent.
    struct Inputs {
        uint256 chainId;
        /// @dev The games contract: the first contract of the signpost's games entry.
        address games;
        address coin;
        address timelock;
        /// @dev The key: the timelock's one proposer and canceller.
        address k;
        uint256 timelockCreationBlock;
        address signpost;
        bytes32 signpostCodeHash;
        /// @dev The signpost entry that lists the games set.
        uint256 gamesEntry;
        address deployer;
        address firstSender;
    }

    function inputs(uint256 chainId) public pure returns (Inputs memory in_) {
        if (chainId == 137) {
            in_ = Inputs({
                chainId: 137,
                // The games contract, entry 1's first contract, created by script/DeployGames.s.sol.
                games: 0x1b424d0dDB5C4aa4551845898093ae8D58052fD3,
                // Native USDC.
                coin: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
                // OpenZeppelin's TimelockController v5.5.0, created in block 95761553 by
                // script/DeployPolygonTimelock.s.sol, with K its one proposer and canceller.
                timelock: 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C,
                k: 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E,
                timelockCreationBlock: 95761553,
                // The signpost, created by script/DeploySignpost.s.sol, owned by the timelock.
                signpost: 0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A,
                signpostCodeHash: 0x8e9825eee784d86186f78673b1cec491425dd517e4663e73dd7c72bea19cf9e8,
                gamesEntry: 1,
                deployer: DEPLOYER,
                firstSender: FIRST_SENDER
            });
        } else {
            revert("no inputs for this chain");
        }
    }

    // ──────────────────────────── The plan ─────────────────────────────

    /// @notice One send of the plan: its nonce, the account it acts on (the address a creation makes, or the
    ///         core a call goes to), its value, and keccak256 of its exact input.
    struct Step {
        uint64 nonce;
        address target;
        uint256 value;
        bytes32 inputHash;
    }

    /// @notice What predict writes and every other phase reads back.
    struct Plan {
        uint256 chainId;
        address deployer;
        /// @dev k: the deployer's nonce at the prediction.
        uint64 nonce;
        uint256 blockNumber;
        bytes32 blockHash;
        address firstSender;
        bytes20 commit;
        /// @dev The eight, in deploy order: core, markets, positions, matching, moneyline, spread, total, relay.
        address[] contracts;
        /// @dev keccak256 of each one's creation code, as the script held it.
        bytes32[] initHashes;
        Step[] steps;
    }

    /// @notice The two blocks a run reads at, each by number, with its hash and the digest of the node's whole
    ///         answer for it, read once and read again before anything is sent.
    struct Anchors {
        uint256 finalized;
        bytes32 finalizedHash;
        bytes32 finalizedAnswer;
        uint256 latest;
        bytes32 latestHash;
        bytes32 latestAnswer;
    }

    enum Phase {
        Create,
        Bootstrap,
        Finalize
    }

    constructor() {
        gamesDeploy = new DeployGames();
    }

    // ──────────────────────────── The phases ───────────────────────────

    /// @notice Phase 1. `--sig "predict(bytes20)" <commit>`, no broadcast.
    function predict(bytes20 commit) external returns (Plan memory) {
        return _predict(inputs(block.chainid), commit, _dir(block.chainid));
    }

    /// @notice Phase 2. `--sig "create(bytes32,bytes16,uint256)" <digest> <go> <maxFee> --broadcast --slow`.
    function create(bytes32 digest, bytes16 go, uint256 maxFee) external {
        _fromWrapper(Phase.Create, digest, go, maxFee);
    }

    /// @notice Phase 3. `--sig "bootstrap(bytes32,bytes16,uint256)" <digest> <go> <maxFee> --broadcast`.
    function bootstrap(bytes32 digest, bytes16 go, uint256 maxFee) external {
        _fromWrapper(Phase.Bootstrap, digest, go, maxFee);
    }

    /// @notice Phase 4. `--sig "finalize(bytes32,bytes16,uint256)" <digest> <go> <maxFee> --broadcast`.
    function finalize(bytes32 digest, bytes16 go, uint256 maxFee) external {
        _fromWrapper(Phase.Finalize, digest, go, maxFee);
    }

    /// @notice Phase 5. `--sig "check(address,uint256,uint8)" <core> <creation block> <stage>`, read only.
    function check(address core, uint256 creationBlock, uint8 stage) external {
        Inputs memory in_ = inputs(block.chainid);
        Plan memory p = readPlan(_dir(block.chainid));
        _check(in_, p, core, creationBlock, stage);
    }

    /// @notice Phase 6. `--sig "signpostCall(uint64)" <deploy block>`, read only.
    function signpostCall(uint64 deployBlock) external returns (bytes memory scheduleCall, bytes32 operationId) {
        string memory dir = _dir(block.chainid);
        return _signpostCall(inputs(block.chainid), readPlan(dir), deployBlock, dir);
    }

    function _fromWrapper(Phase which, bytes32 digest, bytes16 go, uint256 maxFee) internal {
        (, address sender,) = vm.readCallers();
        Inputs memory in_ = inputs(block.chainid);
        _phase(in_, readPlan(_dir(block.chainid)), sender, digest, go, maxFee, which);
    }

    // ──────────────────────────── Phase 1 ──────────────────────────────

    function _predict(Inputs memory in_, bytes20 commit, string memory dir) internal returns (Plan memory p) {
        require(block.chainid == in_.chainId, "the node is not on the table's chain");
        require(in_.firstSender != address(0), "the first sender is not ruled");
        require(commit != bytes20(0), "the commit is missing");
        _requireRoles(in_);
        _requireBuild();
        requireChain(in_);
        require(!vm.exists(_planPath(dir)), "a plan exists: no new prediction while it stands");

        uint256 at = block.number - 1;
        uint64 k = vm.getNonce(in_.deployer);
        require(_nonceAt(in_.deployer, at) == k, "the deployer's nonce moved under the run: predict again");
        require(_pendingNonce(in_.deployer) == k, "the deployer has a pending transaction: no plan on a moving nonce");
        p = _buildPlan(in_, k, commit, at, _blockHash(at));
        for (uint256 i; i < CREATIONS; ++i) {
            require(p.contracts[i].code.length == 0, "a predicted address already has code");
        }
        _writePlan(dir, p);

        console.log("deployer", in_.deployer, "at nonce", uint256(k));
        console.log("the plan's block", p.blockNumber, vm.toString(p.blockHash));
        _printPlan(in_, p);
        _printMetadata();
        console.log("written:", _planPath(dir));
    }

    /// @dev For the manifest: keccak256 of each of the eight artifacts' metadata as solc wrote it. It holds the
    ///      compiler, every setting and the keccak256 of every source, so two equal lines are one build's input.
    function _printMetadata() internal view {
        string[8] memory files = [
            "OspexBetting",
            "OspexMarkets",
            "OspexPositions",
            "OspexMatching",
            "OspexMoneylineScorer",
            "OspexSpreadScorer",
            "OspexTotalScorer",
            "OspexCourierRelay"
        ];
        for (uint256 i; i < CREATIONS; ++i) {
            string memory path = string.concat(vm.projectRoot(), "/out/", files[i], ".sol/", files[i], ".json");
            string memory raw = vm.parseJsonString(vm.readFile(path), ".rawMetadata");
            console.log(string.concat("manifest.mustEqual.metadata.", files[i], ": ", vm.toString(keccak256(bytes(raw)))));
        }
    }

    /// @notice The plan for deployer nonce `k`: the eight addresses by nonce, the eight creation codes' hashes,
    ///         and the ten steps with the hash of each exact input.
    function _buildPlan(Inputs memory in_, uint64 k, bytes20 commit, uint256 blockNumber, bytes32 blockHash)
        internal
        pure
        returns (Plan memory p)
    {
        p.chainId = in_.chainId;
        p.deployer = in_.deployer;
        p.nonce = k;
        p.blockNumber = blockNumber;
        p.blockHash = blockHash;
        p.firstSender = in_.firstSender;
        p.commit = commit;
        p.contracts = new address[](CREATIONS);
        p.initHashes = new bytes32[](CREATIONS);
        p.steps = new Step[](STEPS);
        for (uint256 i; i < CREATIONS; ++i) {
            p.contracts[i] = vm.computeCreateAddress(in_.deployer, uint256(k) + i);
        }
        for (uint256 i; i < CREATIONS; ++i) {
            bytes memory code = _creationCode(i);
            p.initHashes[i] = keccak256(code);
            p.steps[i] = Step({
                // casting to 'uint64' is safe because i is below eight
                // forge-lint: disable-next-line(unsafe-typecast)
                nonce: k + uint64(i),
                target: p.contracts[i],
                value: 0,
                inputHash: keccak256(bytes.concat(code, _constructorArgs(i, in_, p)))
            });
        }
        p.steps[8] = Step({
            nonce: k + 8,
            target: p.contracts[0],
            value: 0,
            inputHash: keccak256(_bootstrapCall(p))
        });
        p.steps[9] = Step({nonce: k + 9, target: p.contracts[0], value: 0, inputHash: keccak256(_finalizeCall())});
    }

    /// @notice The plan's digest: keccak256 of the chain id, the table's addresses with the deployer and the first
    ///         sender, k, the commit, the eight creation codes' hashes and the ten steps' hashes.
    function planDigest(Inputs memory in_, Plan memory p) public pure returns (bytes32) {
        bytes32[] memory stepHashes = new bytes32[](p.steps.length);
        for (uint256 i; i < p.steps.length; ++i) {
            Step memory s = p.steps[i];
            stepHashes[i] = keccak256(abi.encode(s.nonce, s.target, s.value, s.inputHash));
        }
        bytes32 table = keccak256(
            abi.encode(in_.games, in_.coin, in_.timelock, in_.k, in_.signpost, in_.deployer, in_.firstSender)
        );
        return keccak256(abi.encode(p.chainId, table, p.nonce, p.commit, p.initHashes, stepHashes));
    }

    /// @notice Fails unless the plan read from the file is the plan this script builds from its own constants,
    ///         the file's k and its commit: a plan file edited after the digest was posted refuses the run.
    function requirePlanIsThisScripts(Inputs memory in_, Plan memory p) public pure {
        require(p.chainId == in_.chainId, "the plan is for another chain");
        require(p.deployer == in_.deployer, "the plan's deployer is not the table's");
        require(p.firstSender == in_.firstSender, "the plan's first sender is not the table's");
        Plan memory want = _buildPlan(in_, p.nonce, p.commit, p.blockNumber, p.blockHash);
        require(
            keccak256(abi.encode(p.contracts)) == keccak256(abi.encode(want.contracts)),
            "the plan's addresses are not this script's"
        );
        require(
            keccak256(abi.encode(p.initHashes)) == keccak256(abi.encode(want.initHashes)),
            "the plan's creation codes are not this script's"
        );
        require(keccak256(abi.encode(p.steps)) == keccak256(abi.encode(want.steps)), "the plan's steps are not this script's");
    }

    // ──────────────────────────── Phases 2 to 4 ────────────────────────

    /// @dev The checks every sending phase makes before it sends anything, the prefix, and the sends the
    ///      prefix leaves. Every failed check reverts the simulation, so nothing is sent.
    function _phase(
        Inputs memory in_,
        Plan memory p,
        address sender,
        bytes32 digest,
        bytes16 go,
        uint256 maxFee,
        Phase which
    ) internal returns (uint256 proven, uint256 sent) {
        // The anchors first, before the long reads, so the finalized block is near the run's own.
        Anchors memory a = _anchors();
        require(block.chainid == in_.chainId && p.chainId == in_.chainId, "the node is not on the plan's chain");
        require(sender == in_.deployer && sender == p.deployer, "the sender is not the deployer");
        _requireRoles(in_);
        requirePlanIsThisScripts(in_, p);
        require(planDigest(in_, p) == digest, "the digest is not this plan's");
        require(go != bytes16(0), "the go value is zero");
        require(maxFee != 0 && maxFee <= MAX_FEE_CEILING, "the maximum fee is not within the ceiling");
        _requireBuild();
        requireChain(in_);

        bytes32[] memory runtimes = plannedRuntimes(in_, p);
        proven = _prefix(in_, p, a, runtimes);
        _requireNonces(in_, p, a, proven);
        console.log("the prefix: steps proven at the finalized block", proven);

        uint256 from;
        uint256 to;
        if (which == Phase.Create) {
            (from, to) = (proven, CREATIONS);
        } else if (which == Phase.Bootstrap) {
            require(proven >= CREATIONS, "the eight creations are not all proven at the finalized block: nothing sent");
            (from, to) = (proven, 9);
        } else {
            require(proven >= 9, "the bootstrap is not proven at the finalized block: nothing sent");
            (from, to) = (proven, STEPS);
        }
        if (from >= to) {
            console.log("this phase's steps are proven: nothing sent; the read-back follows");
            _requireStage(in_, p, proven >= STEPS ? FINALIZED : (proven >= 9 ? BOOTSTRAPPED : CREATED), a, runtimes, p.blockNumber);
            _requireAnchorsStill(a);
            return (proven, 0);
        }

        // Before the one call that exposes the set: every identity, build and wiring check, at the finalized
        // block, the scan of the timelock among them. Before the lock: the bootstrap, as stage 2.
        if (which == Phase.Bootstrap) _requireStage(in_, p, CREATED, a, runtimes, p.blockNumber);
        if (which == Phase.Finalize) _requireStage(in_, p, BOOTSTRAPPED, a, runtimes, p.blockNumber);
        // The run's own state agrees: no code at a creation it will send.
        for (uint256 i = from; i < to && i < CREATIONS; ++i) {
            require(p.contracts[i].code.length == 0, "the run's own state has code at a creation to send: run again");
        }

        _gasRule(in_, p, sender, proven, maxFee);
        _requireAnchorsStill(a);

        _sendsStart();
        vm.startBroadcast(sender);
        for (uint256 i = from; i < to; ++i) {
            require(vm.getNonce(sender) == p.steps[i].nonce, "the nonce is not the step's: nothing more sent");
            _send(i, in_, p);
        }
        vm.stopBroadcast();
        _sendsEnd();
        sent = to - from;
        for (uint256 i = from; i < to; ++i) {
            console.log("sent: step", i, "at nonce", uint256(p.steps[i].nonce));
        }
        console.log("next: wait for the receipts to be final, then the read-back at the finalized block");
    }

    /// @dev Around the sends, and only them: empty here. A test records the logs of the sends alone through
    ///      them, apart from the simulations undone before.
    function _sendsStart() internal virtual {}

    function _sendsEnd() internal virtual {}

    /// @dev One step of the plan, inside the broadcast. A creation lands at its planned address or nothing
    ///      more is sent.
    function _send(uint256 i, Inputs memory in_, Plan memory p) internal {
        if (i < CREATIONS) {
            address made = _create(i, in_, p);
            require(made == p.contracts[i], "a creation is not at its planned address");
        } else if (i == 8) {
            (bytes32[] memory types, address[] memory modules) = _bootstrapArgs(p);
            OspexBetting(p.contracts[0]).bootstrapModules(types, modules);
        } else {
            OspexBetting(p.contracts[0]).finalize();
        }
    }

    /// @notice The prefix: how many of the plan's steps, from k, are proven by their effect at the finalized
    ///         block. A creation by code at its address that is exactly this plan's; the bootstrap by the exact
    ///         six registered with its one log; the lock by s_finalized with its one log. Holds on code that is
    ///         not the plan's, and on a later planned address with code after one without.
    function _prefix(Inputs memory in_, Plan memory p, Anchors memory a, bytes32[] memory runtimes)
        internal
        returns (uint256 proven)
    {
        while (proven < CREATIONS) {
            bytes memory code = _codeAt(p.contracts[proven], a.finalized);
            if (code.length == 0) break;
            require(keccak256(code) == runtimes[proven], "a planned address holds code that is not this plan's: held");
            ++proven;
        }
        for (uint256 i = proven; i < CREATIONS; ++i) {
            require(_codeAt(p.contracts[i], a.finalized).length == 0, "a planned address has code after one without: held");
        }
        if (proven < CREATIONS) return proven;

        address core = p.contracts[0];
        uint256 count = _uintAt(core, abi.encodeCall(IBettingCoreRead.s_moduleCount, ()), a.finalized);
        if (count == 0) {
            _requireRegistryEmpty(core, a.finalized);
            return proven;
        }
        _requireRegistryIsThePlans(in_, p, a.finalized);
        require(
            _countLogs(core, p.blockNumber, a.finalized, OspexBetting.ModulesBootstrapped.selector) == 1,
            "the bootstrap's log is not one at the finalized block: held"
        );
        proven = 9;
        if (!_boolAt(core, abi.encodeCall(IBettingCoreRead.s_finalized, ()), a.finalized)) return proven;
        require(
            _countLogs(core, p.blockNumber, a.finalized, OspexBetting.Finalized.selector) == 1,
            "the lock's log is not one at the finalized block: held"
        );
        proven = STEPS;
    }

    /// @dev The deployer's latest nonce, at the latest anchor, and its pending nonce must both be k plus the
    ///      prefix, and so must the run's own. A nonce above it is a send not yet final, or a nonce used for
    ///      something else: held either way.
    function _requireNonces(Inputs memory in_, Plan memory p, Anchors memory a, uint256 proven) internal {
        uint256 want = uint256(p.nonce) + proven;
        uint256 latest = _nonceAt(in_.deployer, a.latest);
        uint256 pending = _pendingNonce(in_.deployer);
        require(latest == pending, "the deployer has a pending transaction: held");
        require(
            latest == want,
            "the deployer's nonce is not k plus the proven prefix: a send not yet final, or a nonce used otherwise: held"
        );
        require(vm.getNonce(in_.deployer) == want, "the run's own nonce is not k plus the prefix: run again");
    }

    /// @dev The gas rule. The maximum fee within the ceiling; the remaining steps' gas, measured in a
    ///      simulation of them from the run's own state, times the maximum fee, within the spend bound; the
    ///      deployer's balance at least twice that.
    function _gasRule(Inputs memory in_, Plan memory p, address sender, uint256 proven, uint256 maxFee) internal {
        uint256[] memory gas = remainingGas(in_, p, sender, proven);
        uint256 total;
        for (uint256 i; i < gas.length; ++i) {
            total += gas[i];
            console.log("gas, simulated with its intrinsic cost: step", proven + i, gas[i]);
        }
        uint256 cost = total * maxFee;
        console.log("the remaining steps' gas", total, "at the maximum fee, wei", cost);
        require(cost <= SPEND_BOUND, "the remaining steps cost more than the spend bound at this fee");
        require(sender.balance >= 2 * cost, "the deployer holds less than twice the remaining steps' cost");
    }

    // ──────────────────────────── Phase 5: the read-back ───────────────

    function _check(Inputs memory in_, Plan memory p, address core, uint256 creationBlock, uint8 stage) internal {
        Anchors memory a = _anchors();
        require(block.chainid == in_.chainId, "the node is not on the plan's chain");
        requirePlanIsThisScripts(in_, p);
        require(core == p.contracts[0], "the core is not the plan's");
        require(stage >= CREATED && stage <= FINALIZED, "the stage is not 1, 2 or 3");
        _requireBuild();
        requireChain(in_);
        bytes32[] memory runtimes = plannedRuntimes(in_, p);
        _requireStage(in_, p, stage, a, runtimes, creationBlock);
        _requireAnchorsStill(a);
        console.log("read back at stage", uint256(stage), "at the finalized block", a.finalized);
    }

    /// @notice The set against the plan at a stage, at the finalized anchor, with the mutable guard reads also at
    ///         the latest anchor, the logs from `fromBlock` to the latest anchor, and the observations recorded.
    ///         A chain at another stage than the one named fails.
    function _requireStage(
        Inputs memory in_,
        Plan memory p,
        uint8 stage,
        Anchors memory a,
        bytes32[] memory runtimes,
        uint256 fromBlock
    ) internal {
        // Identity: the eight's code, exactly this plan's, at the finalized block and the same at the latest.
        for (uint256 i; i < CREATIONS; ++i) {
            bytes32 atFinal = keccak256(_codeAt(p.contracts[i], a.finalized));
            require(atFinal == runtimes[i], "a contract's code at the finalized block is not this plan's");
            require(keccak256(_codeAt(p.contracts[i], a.latest)) == atFinal, "a contract's code moved after the finalized block");
        }
        _requireWiring(in_, p, a.finalized);
        // The mutable guard reads, at both anchors: the relay's sender, and the cap.
        _requireGuards(in_, p, a.finalized);
        _requireGuards(in_, p, a.latest);
        scan(in_, p.contracts[3], p.contracts[7], a);

        address core = p.contracts[0];
        bool locked = _boolAt(core, abi.encodeCall(IBettingCoreRead.s_finalized, ()), a.finalized);
        if (stage == CREATED) {
            _requireRegistryEmpty(core, a.finalized);
            require(!locked, "the core is finalized: not stage 1");
        } else {
            _requireRegistryIsThePlans(in_, p, a.finalized);
            require(locked == (stage == FINALIZED), "the core's lock is not the stage's");
        }
        _requireLogs(in_, p, stage, fromBlock, a);
        if (stage == FINALIZED) _requireDeployerHasNoRegistryRight(in_, p);
        _observe(in_, p, a);
    }

    /// @dev Every module's wiring read at block `n`: the core's three values, each module's type and values,
    ///      the scorers asked their type and games set only, the matching module's timelock and domain, the
    ///      relay's two.
    function _requireWiring(Inputs memory in_, Plan memory p, uint256 n) internal {
        address core = p.contracts[0];
        require(_addressAt(core, abi.encodeCall(IBettingCoreRead.i_games, ()), n) == in_.games, "the core's games set");
        require(_addressAt(core, abi.encodeCall(IBettingCoreRead.i_token, ()), n) == in_.coin, "the core's coin");
        require(_addressAt(core, abi.encodeCall(IBettingCoreRead.i_deployer, ()), n) == in_.deployer, "the core's deployer");

        bytes32[6] memory types = moduleTypes();
        for (uint256 j; j < 6; ++j) {
            address m = p.contracts[1 + j];
            require(_bytes32At(m, abi.encodeWithSignature("getModuleType()"), n) == types[j], "a module's type");
        }
        address markets = p.contracts[1];
        require(_addressAt(markets, abi.encodeWithSignature("i_ospexCore()"), n) == core, "the markets module's core");
        require(_addressAt(markets, abi.encodeWithSignature("i_games()"), n) == in_.games, "the markets module's games set");
        address positions = p.contracts[2];
        require(_addressAt(positions, abi.encodeWithSignature("i_ospexCore()"), n) == core, "the positions module's core");
        require(_addressAt(positions, abi.encodeWithSignature("i_token()"), n) == in_.coin, "the positions module's coin");
        address matching = p.contracts[3];
        require(_addressAt(matching, abi.encodeWithSignature("i_ospexCore()"), n) == core, "the matching module's core");
        require(_addressAt(matching, abi.encodeCall(IBettingMatchingRead.i_timelock, ()), n) == in_.timelock, "the matching module's timelock");
        require(
            _bytes32At(matching, abi.encodeCall(OspexMatching.getDomainSeparator, ()), n) == domainSeparator(matching),
            "the matching module's domain"
        );
        for (uint256 j = 4; j < 7; ++j) {
            require(_addressAt(p.contracts[j], abi.encodeWithSignature("i_games()"), n) == in_.games, "a scorer's games set");
        }
        address relay = p.contracts[7];
        require(_addressAt(relay, abi.encodeCall(IBettingRelayRead.i_matching, ()), n) == matching, "the relay's matching module");
        require(_addressAt(relay, abi.encodeCall(IBettingRelayRead.i_timelock, ()), n) == in_.timelock, "the relay's timelock");
    }

    /// @dev The mutable reads that guard the set at block `n`: the relay's sender is the first sender, the cap is
    ///      not lifted, and the constant is the cap.
    function _requireGuards(Inputs memory in_, Plan memory p, uint256 n) internal {
        require(
            _addressAt(p.contracts[7], abi.encodeCall(IBettingRelayRead.s_sender, ()), n) == in_.firstSender,
            "the relay's sender is not the first sender"
        );
        require(!_boolAt(p.contracts[3], abi.encodeCall(IBettingMatchingRead.s_takingStakeCapLifted, ()), n), "the cap is lifted");
        require(
            _uintAt(p.contracts[3], abi.encodeCall(IBettingMatchingRead.TAKING_STAKE_CAP, ()), n) == TAKING_STAKE_CAP,
            "the matching module's cap is not 10,000"
        );
    }

    function _requireRegistryEmpty(address core, uint256 n) internal {
        require(_uintAt(core, abi.encodeCall(IBettingCoreRead.s_moduleCount, ()), n) == 0, "the registry is not empty");
        bytes32[6] memory types = moduleTypes();
        for (uint256 j; j < 6; ++j) {
            require(_addressAt(core, abi.encodeCall(OspexBetting.getModule, (types[j])), n) == address(0), "the registry is not empty");
        }
    }

    function _requireRegistryIsThePlans(Inputs memory, Plan memory p, uint256 n) internal {
        address core = p.contracts[0];
        require(_uintAt(core, abi.encodeCall(IBettingCoreRead.s_moduleCount, ()), n) == 6, "the registry's count is not six: held");
        bytes32[6] memory types = moduleTypes();
        for (uint256 j; j < 6; ++j) {
            require(
                _addressAt(core, abi.encodeCall(OspexBetting.getModule, (types[j])), n) == p.contracts[1 + j],
                "the registry is not the plan's six: held"
            );
        }
    }

    /// @dev The logs from `fromBlock` to the latest anchor. The core's own, its hub copies of the modules' events
    ///      aside, exactly the stage's: GamesSet and TokenSet, then ModulesBootstrapped(6), then Finalized, the
    ///      last two at or below the finalized block. The relay's exactly SenderSet(0, first sender). No module
    ///      log before the bootstrap's block.
    function _requireLogs(Inputs memory in_, Plan memory p, uint8 stage, uint256 fromBlock, Anchors memory a) internal {
        address core = p.contracts[0];
        VmSafe.EthGetLogs[] memory logs = _logs(core, fromBlock, a.latest, new bytes32[](0));
        uint256 n;
        uint256 bootstrapBlock = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            VmSafe.EthGetLogs memory l = logs[i];
            if (l.topics.length > 0 && l.topics[0] == OspexBetting.CoreEventEmitted.selector) continue;
            if (n == 0) {
                require(l.topics.length == 2 && l.topics[0] == OspexBetting.GamesSet.selector && l.topics[1] == _topic(in_.games), "the core's first log is not GamesSet(games)");
            } else if (n == 1) {
                require(l.topics.length == 2 && l.topics[0] == OspexBetting.TokenSet.selector && l.topics[1] == _topic(in_.coin), "the core's second log is not TokenSet(coin)");
            } else if (n == 2) {
                require(
                    l.topics.length == 1 && l.topics[0] == OspexBetting.ModulesBootstrapped.selector
                        && keccak256(l.data) == keccak256(abi.encode(uint256(6))) && l.blockNumber <= a.finalized,
                    "the core's third log is not ModulesBootstrapped(6) at or below the finalized block"
                );
                bootstrapBlock = l.blockNumber;
            } else if (n == 3) {
                require(
                    l.topics.length == 1 && l.topics[0] == OspexBetting.Finalized.selector && l.data.length == 0
                        && l.blockNumber <= a.finalized,
                    "the core's fourth log is not Finalized() at or below the finalized block"
                );
            } else {
                revert("the core has a log of its own past the stage's");
            }
            ++n;
        }
        uint256 want = stage == CREATED ? 2 : (stage == BOOTSTRAPPED ? 3 : 4);
        require(n == want, "the core's own logs are not the stage's");

        VmSafe.EthGetLogs[] memory relayLogs = _logs(p.contracts[7], fromBlock, a.latest, new bytes32[](0));
        require(relayLogs.length == 1, "the relay's logs are not its one constructor log");
        require(
            relayLogs[0].topics.length == 3 && relayLogs[0].topics[0] == OspexCourierRelay.SenderSet.selector
                && relayLogs[0].topics[1] == bytes32(0) && relayLogs[0].topics[2] == _topic(in_.firstSender),
            "the relay's log is not SenderSet(0, first sender)"
        );

        uint256 until = stage == CREATED ? a.latest : bootstrapBlock - 1;
        for (uint256 j = 1; j < 7; ++j) {
            if (until < fromBlock) break;
            require(_logs(p.contracts[j], fromBlock, until, new bytes32[](0)).length == 0, "a module has a log before the bootstrap");
        }
    }

    /// @dev After the lock: the deployer's two registry calls are refused by name, and it is neither the relay's
    ///      nor the matching module's timelock. Static calls on the run's own state, which only moves forward.
    function _requireDeployerHasNoRegistryRight(Inputs memory in_, Plan memory p) internal {
        address core = p.contracts[0];
        bytes memory finalized = abi.encodeWithSelector(OspexBetting.OspexBetting__AlreadyFinalized.selector);
        bool ok;
        bytes memory err;
        vm.prank(in_.deployer);
        (ok, err) = core.call(abi.encodeCall(OspexBetting.bootstrapModules, (new bytes32[](0), new address[](0))));
        require(!ok && keccak256(err) == keccak256(finalized), "the deployer's bootstrap is not refused AlreadyFinalized");
        vm.prank(in_.deployer);
        (ok, err) = core.call(abi.encodeCall(OspexBetting.finalize, ()));
        require(!ok && keccak256(err) == keccak256(finalized), "the deployer's finalize is not refused AlreadyFinalized");
        vm.prank(in_.deployer);
        (ok, err) = p.contracts[7].call(abi.encodeCall(OspexCourierRelay.setSender, (in_.deployer)));
        require(
            !ok
                && keccak256(err)
                    == keccak256(abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheTimelock.selector, in_.deployer)),
            "the deployer's setSender is not refused NotTheTimelock"
        );
        vm.prank(in_.deployer);
        (ok, err) = p.contracts[3].call(abi.encodeCall(OspexMatching.liftTakingStakeCap, ()));
        require(
            !ok
                && keccak256(err)
                    == keccak256(abi.encodeWithSelector(OspexMatching.OspexMatching__NotTheTimelock.selector, in_.deployer)),
            "the deployer's cap lift is not refused NotTheTimelock"
        );
        console.log("the deployer keeps no registry right", in_.deployer);
    }

    /// @dev The observations, never pass or fail: the markets made, the positions module's coin, the liabilities
    ///      it records, and the difference, coin sent to it unasked. At the latest anchor.
    function _observe(Inputs memory in_, Plan memory p, Anchors memory a) internal {
        uint256 markets = _uintAt(p.contracts[1], abi.encodeWithSignature("marketCount()"), a.latest);
        uint256 held = _uintAt(in_.coin, abi.encodeCall(IBettingCoinRead.balanceOf, (p.contracts[2])), a.latest);
        uint256 liabilities;
        for (uint256 m = 1; m <= markets; ++m) {
            liabilities += _uintAt(p.contracts[2], abi.encodeWithSignature("s_heldTotal(uint256)", m), a.latest);
        }
        console.log("observed: markets", markets);
        console.log("observed: the positions module's coin", held);
        console.log("observed: the liabilities it records", liabilities);
        if (held >= liabilities) console.log("observed: coin beyond the liabilities, sent unasked", held - liabilities);
        else console.log("observed: the coin is SHORT of the liabilities by", liabilities - held);
    }

    // ──────────────────────────── The timelock scan ────────────────────

    /// @notice Fails unless no waiting or ready timelock operation names the matching module or the relay. Every
    ///         CallScheduled log from the timelock's creation to the latest anchor is read, the finalized part
    ///         and the tail above it, one log per call of a batch; for each that targets either contract, the
    ///         operation's state is read at the latest anchor, and at the finalized one for the record. It says
    ///         what was scheduled up to the latest anchor, not what is scheduled after it, so it is made again
    ///         at each boundary.
    function scan(Inputs memory in_, address matching, address relay, Anchors memory a) public returns (uint256 named) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = CALL_SCHEDULED;
        VmSafe.EthGetLogs[] memory logs = _logs(in_.timelock, in_.timelockCreationBlock, a.latest, topics);
        for (uint256 i; i < logs.length; ++i) {
            VmSafe.EthGetLogs memory l = logs[i];
            require(l.emitter == in_.timelock && l.topics.length == 3, "a scheduled-call log is not the timelock's");
            (address target,,,,) = abi.decode(l.data, (address, uint256, bytes, bytes32, uint256));
            if (target != matching && target != relay) continue;
            ++named;
            bytes32 id = l.topics[1];
            uint256 nowState = _uintAt(in_.timelock, abi.encodeCall(TimelockController.getOperationState, (id)), a.latest);
            uint256 thenState = _uintAt(in_.timelock, abi.encodeCall(TimelockController.getOperationState, (id)), a.finalized);
            console.log("a scheduled call names the set: block", uint256(l.blockNumber));
            console.log("  operation", vm.toString(id));
            console.log("  state at the latest and the finalized block", nowState, thenState);
            require(nowState != 1 && nowState != 2, "a waiting or ready timelock operation names the matching module or the relay: held");
        }
        console.log("the timelock scan: scheduled calls read", logs.length, "naming the set", named);
        console.log("  from block", in_.timelockCreationBlock, "to the latest anchor", a.latest);
    }

    // ──────────────────────────── Phase 6 ──────────────────────────────

    function _signpostCall(Inputs memory in_, Plan memory p, uint64 deployBlock, string memory dir)
        internal
        returns (bytes memory scheduleCall, bytes32 operationId)
    {
        Anchors memory a = _anchors();
        require(block.chainid == in_.chainId, "the node is not on the plan's chain");
        requirePlanIsThisScripts(in_, p);
        _requireBuild();
        requireChain(in_);
        bytes32[] memory runtimes = plannedRuntimes(in_, p);
        address core = p.contracts[0];
        require(deployBlock != 0 && deployBlock <= a.finalized, "the deploy block is not at or below the finalized block");
        require(_codeAt(core, deployBlock - 1).length == 0, "the core existed before the deploy block");
        require(keccak256(_codeAt(core, deployBlock)) == runtimes[0], "the core is not in the deploy block");
        _requireStage(in_, p, FINALIZED, a, runtimes, deployBlock);

        // The entry's contracts from the chain: the core, its six from the registry, the relay by the deployer's
        // nonce, on the registry's matching module.
        address[] memory set = new address[](CREATIONS);
        set[0] = core;
        bytes32[6] memory types = moduleTypes();
        for (uint256 j; j < 6; ++j) {
            set[1 + j] = _addressAt(core, abi.encodeCall(OspexBetting.getModule, (types[j])), a.finalized);
        }
        set[7] = vm.computeCreateAddress(in_.deployer, uint256(p.nonce) + 7);
        require(
            _addressAt(set[7], abi.encodeCall(IBettingRelayRead.i_matching, ()), a.finalized) == set[3],
            "the relay is not on the registry's matching module"
        );
        for (uint256 i; i < CREATIONS; ++i) {
            require(set[i] == p.contracts[i], "the chain's set is not the plan's");
        }

        bytes memory add =
            abi.encodeCall(OspexSignpost.addEntry, (OspexSignpost.Kind.Betting, in_.coin, set, p.commit, deployBlock));
        TimelockController t = TimelockController(payable(in_.timelock));
        bytes32 salt = keccak256(abi.encode("betting set", core));
        uint256 delay = t.getMinDelay();
        operationId = t.hashOperation(in_.signpost, 0, add, bytes32(0), salt);
        scheduleCall = abi.encodeCall(TimelockController.schedule, (in_.signpost, 0, add, bytes32(0), salt, delay));
        bytes memory run = abi.encodeCall(TimelockController.execute, (in_.signpost, 0, add, bytes32(0), salt));
        uint256 previewId = OspexSignpost(in_.signpost).entryCount();

        uint256 provedId = _proveEntry(in_, add, salt, delay, set, p.commit, deployBlock);
        _requireAnchorsStill(a);

        string memory key = "signpostCall";
        vm.serializeAddress(key, "timelock", in_.timelock);
        vm.serializeAddress(key, "signpost", in_.signpost);
        vm.serializeAddress(key, "contracts", set);
        vm.serializeBytes(key, "commit", abi.encodePacked(p.commit));
        vm.serializeUint(key, "deployBlock", deployBlock);
        vm.serializeUint(key, "delay", delay);
        vm.serializeBytes32(key, "salt", salt);
        vm.serializeBytes32(key, "operationId", operationId);
        vm.serializeBytes32(key, "scheduleHash", keccak256(scheduleCall));
        vm.serializeUint(key, "previewId", previewId);
        vm.serializeUint(key, "finalizedBlock", a.finalized);
        vm.serializeBytes32(key, "finalizedHash", a.finalizedHash);
        vm.serializeBytes(key, "addEntry", add);
        vm.serializeBytes(key, "schedule", scheduleCall);
        string memory json = vm.serializeBytes(key, "execute", run);
        vm.writeJson(json, string.concat(dir, "/signpost-call.json"));

        console.log("for K to send to the timelock", in_.timelock, "(schedule):");
        console.logBytes(scheduleCall);
        console.log("keccak256 of the schedule calldata", vm.toString(keccak256(scheduleCall)));
        console.log("for an executor, after the delay of", delay, "seconds (execute):");
        console.logBytes(run);
        console.log("operation id", vm.toString(operationId));
        console.log("previewId, a preview and never an argument:", previewId, "the simulation's id:", provedId);
        console.log("written:", string.concat(dir, "/signpost-call.json"));
    }

    /// @dev The entry proven in a simulation, undone after, as the day makes it: K calls schedule on the timelock,
    ///      the delay passes, an executor calls execute, and the timelock calls the signpost. The timelock is
    ///      never made to call schedule on itself. Returns the id the simulation's EntryAdded gave.
    function _proveEntry(
        Inputs memory in_,
        bytes memory add,
        bytes32 salt,
        uint256 delay,
        address[] memory set,
        bytes20 commit,
        uint64 deployBlock
    ) internal returns (uint256 id) {
        TimelockController t = TimelockController(payable(in_.timelock));
        OspexSignpost signpost = OspexSignpost(in_.signpost);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(in_.k);
        t.schedule(in_.signpost, 0, add, bytes32(0), salt, delay);
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(PROOF_EXECUTOR);
        t.execute(in_.signpost, 0, add, bytes32(0), salt);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == in_.signpost && logs[i].topics.length > 1
                    && logs[i].topics[0] == OspexSignpost.EntryAdded.selector
            ) {
                require(!found, "the simulation added two entries");
                id = uint256(logs[i].topics[1]);
                found = true;
            }
        }
        require(found, "the simulation added no entry");
        OspexSignpost.Entry memory e = signpost.getEntry(id);
        require(e.kind == OspexSignpost.Kind.Betting && e.coin == in_.coin, "the entry's kind or coin");
        require(keccak256(abi.encode(e.contracts)) == keccak256(abi.encode(set)), "the entry's contracts");
        for (uint256 i; i < set.length; ++i) {
            require(e.codeHashes[i] == set[i].codehash && e.codeHashes[i] != bytes32(0), "the entry's code hashes");
        }
        require(e.commit == commit && e.deployBlock == deployBlock, "the entry's commit or deploy block");
        require(e.status == OspexSignpost.Status.Building, "the entry is not building");
        vm.revertToState(snap);
    }

    // ──────────────────────────── The chain's fixed addresses ──────────

    /// @notice Fails unless the chain holds the table as pinned: the timelock's whole layout, replayed from its
    ///         logs by the games deploy's own check; the signpost's code and owner; the games entry standing and
    ///         naming the table's games contract with its recorded code; that contract answering to the table's
    ///         timelock and holding the table's coin; a coin with six decimals.
    function requireChain(Inputs memory in_) public {
        require(block.chainid == in_.chainId, "the node is not on the table's chain");
        _timelockCheck().requireTimelock(in_.timelock, in_.k, in_.timelockCreationBlock);
        require(in_.signpost.codehash == in_.signpostCodeHash, "the signpost is not the pinned code");
        require(OspexSignpost(in_.signpost).i_timelock() == in_.timelock, "the signpost is not the timelock's");
        OspexSignpost.Entry memory e = OspexSignpost(in_.signpost).getEntry(in_.gamesEntry);
        require(e.kind == OspexSignpost.Kind.Games, "the games entry is not a games set");
        require(e.status != OspexSignpost.Status.Retired, "the games entry is retired");
        require(
            e.contracts.length != 0 && e.contracts[0] == in_.games && in_.games.codehash == e.codeHashes[0],
            "the table's games contract is not the games entry's, with its recorded code"
        );
        require(IBettingGamesRead(in_.games).i_token() == in_.coin, "the coin is not the games set's own");
        require(IBettingGamesRead(in_.games).i_timelock() == in_.timelock, "the games set's timelock is not the table's");
        require(in_.coin.code.length != 0, "the coin has no code");
        require(IBettingCoinRead(in_.coin).decimals() == 6, "the coin does not have six decimals");
    }

    /// @dev The roles kept apart: the deployer is not the first sender, the timelock or the key.
    function _requireRoles(Inputs memory in_) internal pure {
        require(in_.deployer != in_.firstSender, "the deployer is the first sender");
        require(in_.deployer != in_.timelock, "the deployer is the timelock");
        require(in_.deployer != in_.k, "the deployer is the key");
    }

    /// @dev The build: each creation code's exact hash and stock hash are the pinned ones.
    function _requireBuild() internal pure {
        bytes32[2][8] memory pinned = pinnedHashes();
        for (uint256 i; i < CREATIONS; ++i) {
            bytes memory code = _creationCode(i);
            require(stockHash(code) == pinned[i][1], "a contract is not the pinned build");
            require(keccak256(code) == pinned[i][0], "a contract's metadata is not the pinned build's");
        }
    }

    function pinnedHashes() public pure returns (bytes32[2][8] memory h) {
        h[0] = [CORE_INIT_HASH, CORE_STOCK_HASH];
        h[1] = [MARKETS_INIT_HASH, MARKETS_STOCK_HASH];
        h[2] = [POSITIONS_INIT_HASH, POSITIONS_STOCK_HASH];
        h[3] = [MATCHING_INIT_HASH, MATCHING_STOCK_HASH];
        h[4] = [MONEYLINE_INIT_HASH, MONEYLINE_STOCK_HASH];
        h[5] = [SPREAD_INIT_HASH, SPREAD_STOCK_HASH];
        h[6] = [TOTAL_INIT_HASH, TOTAL_STOCK_HASH];
        h[7] = [RELAY_INIT_HASH, RELAY_STOCK_HASH];
    }

    /// @notice keccak256 of `code` with the 32-byte source digest in solc's metadata zeroed, so every other byte
    ///         is compared. Zero unless `code` holds exactly one metadata section. DeploySignpost's method.
    function stockHash(bytes memory code) public pure returns (bytes32) {
        bytes memory c = bytes.concat(code);
        uint256 sections;
        for (uint256 i; i + 42 <= c.length; ++i) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(c, 0x20), i))
            }
            // a2 64 "ipfs" 58 22 12 20: the metadata's first key, then the 32-byte digest's header.
            if (word >> 176 == 0xa2646970667358221220) {
                assembly ("memory-safe") {
                    mstore(add(add(c, 0x2a), i), 0)
                }
                ++sections;
            }
        }
        return sections == 1 ? keccak256(c) : bytes32(0);
    }

    // ──────────────────────────── The set's code ───────────────────────

    /// @notice The six module types, in the registry's order: markets, positions, matching, and the three scorers.
    function moduleTypes() public pure returns (bytes32[6] memory) {
        return [
            keccak256("MARKET_MODULE"),
            keccak256("POSITION_MODULE"),
            keccak256("MATCHING_MODULE"),
            keccak256("MONEYLINE_SCORER_MODULE"),
            keccak256("SPREAD_SCORER_MODULE"),
            keccak256("TOTAL_SCORER_MODULE")
        ];
    }

    /// @notice The matching module's EIP-712 domain: ("Ospex", "3", the chain, its address).
    function domainSeparator(address matching) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Ospex"),
                keccak256("3"),
                block.chainid,
                matching
            )
        );
    }

    function _creationCode(uint256 i) internal pure returns (bytes memory) {
        if (i == 0) return type(OspexBetting).creationCode;
        if (i == 1) return type(OspexMarkets).creationCode;
        if (i == 2) return type(OspexPositions).creationCode;
        if (i == 3) return type(OspexMatching).creationCode;
        if (i == 4) return type(OspexMoneylineScorer).creationCode;
        if (i == 5) return type(OspexSpreadScorer).creationCode;
        if (i == 6) return type(OspexTotalScorer).creationCode;
        return type(OspexCourierRelay).creationCode;
    }

    /// @notice The ABI-encoded constructor arguments of creation `i`: the tail of its creation input, and what the
    ///         explorer's verification is given.
    function _constructorArgs(uint256 i, Inputs memory in_, Plan memory p) internal pure returns (bytes memory) {
        if (i == 0) return abi.encode(in_.games, in_.coin);
        if (i < 7) return abi.encode(p.contracts[0]);
        return abi.encode(p.contracts[3], p.firstSender);
    }

    function _bootstrapArgs(Plan memory p) internal pure returns (bytes32[] memory types, address[] memory modules) {
        bytes32[6] memory t = moduleTypes();
        types = new bytes32[](6);
        modules = new address[](6);
        for (uint256 j; j < 6; ++j) {
            types[j] = t[j];
            modules[j] = p.contracts[1 + j];
        }
    }

    function _bootstrapCall(Plan memory p) internal pure returns (bytes memory) {
        (bytes32[] memory types, address[] memory modules) = _bootstrapArgs(p);
        return abi.encodeCall(OspexBetting.bootstrapModules, (types, modules));
    }

    function _finalizeCall() internal pure returns (bytes memory) {
        return abi.encodeCall(OspexBetting.finalize, ());
    }

    /// @dev Creation `i`, from the caller in force (the broadcast's sender, or a prank in a simulation).
    function _create(uint256 i, Inputs memory in_, Plan memory p) internal returns (address) {
        if (i == 0) return address(new OspexBetting(in_.games, in_.coin));
        if (i == 1) return address(new OspexMarkets(p.contracts[0]));
        if (i == 2) return address(new OspexPositions(p.contracts[0]));
        if (i == 3) return address(new OspexMatching(p.contracts[0]));
        if (i == 4) return address(new OspexMoneylineScorer(p.contracts[0]));
        if (i == 5) return address(new OspexSpreadScorer(p.contracts[0]));
        if (i == 6) return address(new OspexTotalScorer(p.contracts[0]));
        return address(new OspexCourierRelay(p.contracts[3], p.firstSender));
    }

    /// @notice The runtime code hash each of the eight has once created with this plan's values, from the
    ///         plan's creations simulated from the deployer at k, on a slate cleared of the planned addresses'
    ///         code, and undone. The matching module's code holds its own address and the core's its deployer,
    ///         so only a creation at the planned address by the deployer gives the code to compare.
    function plannedRuntimes(Inputs memory in_, Plan memory p) public returns (bytes32[] memory h) {
        h = new bytes32[](CREATIONS);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < CREATIONS; ++i) {
            if (p.contracts[i].code.length != 0) {
                vm.etch(p.contracts[i], "");
                vm.resetNonce(p.contracts[i]);
            }
        }
        vm.setNonceUnsafe(in_.deployer, p.nonce);
        for (uint256 i; i < CREATIONS; ++i) {
            vm.prank(in_.deployer);
            address made = _create(i, in_, p);
            require(made == p.contracts[i], "a simulated creation is not at its planned address");
            h[i] = made.codehash;
        }
        vm.revertToState(snap);
    }

    /// @notice The gas of each remaining step, from step `proven` on, simulated from the run's own state as the
    ///         deployer and undone: the simulation's gas with the transaction's intrinsic cost added (21,000 and
    ///         the calldata). An estimate to bound the spend, not a receipt.
    function remainingGas(Inputs memory in_, Plan memory p, address sender, uint256 proven)
        public
        returns (uint256[] memory gas)
    {
        gas = new uint256[](STEPS - proven);
        uint256 snap = vm.snapshotState();
        for (uint256 i = proven; i < STEPS; ++i) {
            bytes memory input = i < CREATIONS
                ? bytes.concat(_creationCode(i), _constructorArgs(i, in_, p))
                : (i == 8 ? _bootstrapCall(p) : _finalizeCall());
            uint256 before = gasleft();
            vm.prank(sender);
            if (i < CREATIONS) {
                require(_create(i, in_, p) == p.contracts[i], "a simulated creation is not at its planned address");
            } else if (i == 8) {
                (bytes32[] memory types, address[] memory modules) = _bootstrapArgs(p);
                OspexBetting(p.contracts[0]).bootstrapModules(types, modules);
            } else {
                OspexBetting(p.contracts[0]).finalize();
            }
            gas[i - proven] = before - gasleft() + 21_000 + _calldataGas(input);
        }
        vm.revertToState(snap);
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    // ──────────────────────────── The records ──────────────────────────

    function readPlan(string memory dir) public view returns (Plan memory p) {
        string memory path = _planPath(dir);
        require(vm.exists(path), "no plan: run predict first");
        string memory json = vm.readFile(path);
        p.chainId = vm.parseJsonUint(json, ".chainId");
        p.deployer = vm.parseJsonAddress(json, ".deployer");
        uint256 k = vm.parseJsonUint(json, ".nonce");
        require(k <= type(uint64).max, "the plan's nonce is not a nonce");
        // casting to 'uint64' is safe because the line above refuses anything wider
        // forge-lint: disable-next-line(unsafe-typecast)
        p.nonce = uint64(k);
        p.blockNumber = vm.parseJsonUint(json, ".blockNumber");
        p.blockHash = vm.parseJsonBytes32(json, ".blockHash");
        p.firstSender = vm.parseJsonAddress(json, ".firstSender");
        bytes memory commit = vm.parseJsonBytes(json, ".commit");
        require(commit.length == 20, "the plan's commit is not twenty bytes");
        // casting to 'bytes20' is safe because the line above requires twenty bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        p.commit = bytes20(commit);
        p.contracts = vm.parseJsonAddressArray(json, ".contracts");
        p.initHashes = vm.parseJsonBytes32Array(json, ".initHashes");
        uint256[] memory nonces = vm.parseJsonUintArray(json, ".stepNonces");
        address[] memory targets = vm.parseJsonAddressArray(json, ".stepTargets");
        uint256[] memory values = vm.parseJsonUintArray(json, ".stepValues");
        bytes32[] memory inputs_ = vm.parseJsonBytes32Array(json, ".stepInputHashes");
        require(
            p.contracts.length == CREATIONS && p.initHashes.length == CREATIONS && nonces.length == STEPS
                && targets.length == STEPS && values.length == STEPS && inputs_.length == STEPS,
            "the plan's lists are not eight and ten long"
        );
        p.steps = new Step[](STEPS);
        for (uint256 i; i < STEPS; ++i) {
            require(nonces[i] <= type(uint64).max, "a step's nonce is not a nonce");
            // casting to 'uint64' is safe because the line above refuses anything wider
            // forge-lint: disable-next-line(unsafe-typecast)
            p.steps[i] = Step({nonce: uint64(nonces[i]), target: targets[i], value: values[i], inputHash: inputs_[i]});
        }
    }

    function _writePlan(string memory dir, Plan memory p) internal {
        uint256[] memory nonces = new uint256[](STEPS);
        address[] memory targets = new address[](STEPS);
        uint256[] memory values = new uint256[](STEPS);
        bytes32[] memory inputs_ = new bytes32[](STEPS);
        for (uint256 i; i < STEPS; ++i) {
            nonces[i] = p.steps[i].nonce;
            targets[i] = p.steps[i].target;
            values[i] = p.steps[i].value;
            inputs_[i] = p.steps[i].inputHash;
        }
        string memory key = "plan";
        vm.serializeUint(key, "chainId", p.chainId);
        vm.serializeAddress(key, "deployer", p.deployer);
        vm.serializeUint(key, "nonce", p.nonce);
        vm.serializeUint(key, "blockNumber", p.blockNumber);
        vm.serializeBytes32(key, "blockHash", p.blockHash);
        vm.serializeAddress(key, "firstSender", p.firstSender);
        vm.serializeBytes(key, "commit", abi.encodePacked(p.commit));
        vm.serializeAddress(key, "contracts", p.contracts);
        vm.serializeBytes32(key, "initHashes", p.initHashes);
        vm.serializeUint(key, "stepNonces", nonces);
        vm.serializeAddress(key, "stepTargets", targets);
        vm.serializeUint(key, "stepValues", values);
        string memory json = vm.serializeBytes32(key, "stepInputHashes", inputs_);
        vm.createDir(dir, true);
        vm.writeJson(json, _planPath(dir));
    }

    /// @dev The plan as printed: the digest, the table, the eight, the ten steps, and the manifest's lines, which
    ///      the wrapper collects.
    function _printPlan(Inputs memory in_, Plan memory p) internal pure {
        bytes32 digest = planDigest(in_, p);
        console.log("the plan's digest", vm.toString(digest));
        string[8] memory names =
            ["core", "markets", "positions", "matching", "moneyline", "spread", "total", "relay"];
        for (uint256 i; i < CREATIONS; ++i) {
            console.log(string.concat("  ", names[i]), p.contracts[i], "creation code", vm.toString(p.initHashes[i]));
        }
        for (uint256 i; i < STEPS; ++i) {
            console.log("  step", i, "nonce", uint256(p.steps[i].nonce));
            console.log("    target", p.steps[i].target, "input", vm.toString(p.steps[i].inputHash));
        }
        console.log(string.concat("manifest.mustEqual.digest: ", vm.toString(digest)));
        console.log(string.concat("manifest.mustEqual.k: ", vm.toString(uint256(p.nonce))));
        console.log(string.concat("manifest.mustEqual.commit: ", vm.toString(abi.encodePacked(p.commit))));
        console.log(string.concat("manifest.mustEqual.deployer: ", vm.toString(in_.deployer)));
        console.log(string.concat("manifest.mustEqual.firstSender: ", vm.toString(in_.firstSender)));
        console.log(
            string.concat(
                "manifest.mustEqual.table: ",
                vm.toString(
                    keccak256(abi.encode(in_.games, in_.coin, in_.timelock, in_.k, in_.signpost, in_.deployer, in_.firstSender))
                )
            )
        );
        for (uint256 i; i < CREATIONS; ++i) {
            console.log(string.concat("manifest.mustEqual.creationCode.", names[i], ": ", vm.toString(p.initHashes[i])));
        }
        for (uint256 i; i < STEPS; ++i) {
            Step memory s = p.steps[i];
            console.log(
                string.concat(
                    "manifest.mustEqual.step.",
                    vm.toString(i),
                    ": ",
                    vm.toString(uint256(s.nonce)),
                    " ",
                    vm.toString(s.target),
                    " ",
                    vm.toString(s.value),
                    " ",
                    vm.toString(s.inputHash)
                )
            );
        }
        console.log(string.concat("manifest.declared.planBlock: ", vm.toString(p.blockNumber), " ", vm.toString(p.blockHash)));
    }

    function _planPath(string memory dir) internal pure returns (string memory) {
        return string.concat(dir, "/prediction.json");
    }

    function _dir(uint256 chainId) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/betting-set/", vm.toString(chainId));
    }

    // ──────────────────────────── Reads of the node ────────────────────

    /// @notice The two anchors, read once. The finalized block: the node's answer for "finalized", matched whole
    ///         against its answers for the numbers near the run's own block, so that no field of a block object
    ///         is decoded; its hash from the run's own chain. The latest: the block before the run's own.
    function _anchors() internal returns (Anchors memory a) {
        bytes32 finalizedAnswer = _finalizedAnswer();
        uint256 top = block.number + ANCHOR_AHEAD;
        uint256 bottom = block.number > ANCHOR_BEHIND ? block.number - ANCHOR_BEHIND : 1;
        bool found;
        for (uint256 m = top; m >= bottom; --m) {
            if (_blockAnswerAt(m) == finalizedAnswer) {
                a.finalized = m;
                found = true;
                break;
            }
        }
        require(found, "the node's finalized block is not near the run's own: held");
        require(a.finalized < block.number, "the finalized block is not below the run's own: run again");
        a.finalizedHash = _blockHash(a.finalized);
        a.finalizedAnswer = finalizedAnswer;
        a.latest = block.number - 1;
        a.latestHash = _blockHash(a.latest);
        a.latestAnswer = _blockAnswerAt(a.latest);
        require(a.finalizedHash != bytes32(0) && a.latestHash != bytes32(0), "an anchor has no hash");
        require(a.latestAnswer != bytes32(0), "the node gave no latest block");
        console.log("the finalized anchor", a.finalized, vm.toString(a.finalizedHash));
        console.log("the latest anchor", a.latest, vm.toString(a.latestHash));
    }

    /// @dev Both anchors read again: a changed block holds.
    function _requireAnchorsStill(Anchors memory a) internal {
        require(_blockAnswerAt(a.finalized) == a.finalizedAnswer, "the finalized anchor's block changed during the run: held");
        require(_blockAnswerAt(a.latest) == a.latestAnswer, "the latest anchor's block changed during the run: held");
    }

    /// @dev The digest of the node's whole answer for "finalized". Overridable: a test on a fork stands in for a
    ///      node that cannot see the test's own blocks.
    function _finalizedAnswer() internal virtual returns (bytes32 h) {
        h = _rawBlock('"finalized"');
        require(h != bytes32(0), "the node gave no finalized block");
    }

    /// @dev The digest of the node's whole answer for block `m`; zero for a block it does not have.
    function _blockAnswerAt(uint256 m) internal virtual returns (bytes32) {
        return _rawBlock(string.concat('"', _hex(m), '"'));
    }

    /// @dev The node's block object, kept whole: forge hands an object back as a tuple of its fields, which this
    ///      script compares and never decodes. A null answer comes back as one zero word.
    function _rawBlock(string memory param) internal returns (bytes32) {
        (bool ok, bytes memory raw) = address(vm).call(
            abi.encodeWithSignature("rpc(string,string)", "eth_getBlockByNumber", string.concat("[", param, ",false]"))
        );
        require(ok, "the node refused a block read");
        return raw.length <= 96 ? bytes32(0) : keccak256(raw);
    }

    /// @dev A block's hash from the run's own chain. Overridable, as the anchors are.
    function _blockHash(uint256 n) internal view virtual returns (bytes32) {
        return blockhash(n);
    }

    /// @dev The code at `account` in block `n`, from the node. Overridable.
    function _codeAt(address account, uint256 n) internal virtual returns (bytes memory) {
        return vm.rpc("eth_getCode", string.concat('["', vm.toString(account), '","', _hex(n), '"]'));
    }

    /// @dev A call's answer in block `n`, from the node. Overridable.
    function _callAt(address target, bytes memory data, uint256 n) internal virtual returns (bytes memory) {
        return vm.rpc(
            "eth_call",
            string.concat('[{"to":"', vm.toString(target), '","data":"', vm.toString(data), '"},"', _hex(n), '"]')
        );
    }

    /// @dev The account's nonce in block `n`, from the node. Overridable.
    function _nonceAt(address account, uint256 n) internal virtual returns (uint256) {
        return _quantity(vm.rpc("eth_getTransactionCount", string.concat('["', vm.toString(account), '","', _hex(n), '"]')));
    }

    /// @dev The account's pending nonce, from the node. Overridable.
    function _pendingNonce(address account) internal virtual returns (uint256) {
        return _quantity(vm.rpc("eth_getTransactionCount", string.concat('["', vm.toString(account), '","pending"]')));
    }

    /// @dev The logs of `emitter` under `topics` from `fromBlock` to `toBlock`, in windows. Overridable.
    function _logs(address emitter, uint256 fromBlock, uint256 toBlock, bytes32[] memory topics)
        internal
        virtual
        returns (VmSafe.EthGetLogs[] memory logs)
    {
        if (fromBlock > toBlock) return new VmSafe.EthGetLogs[](0);
        uint256 windows = (toBlock - fromBlock) / LOG_WINDOW + 1;
        VmSafe.EthGetLogs[][] memory raw = new VmSafe.EthGetLogs[][](windows);
        uint256 count;
        for (uint256 w; w < windows; ++w) {
            uint256 from = fromBlock + w * LOG_WINDOW;
            uint256 to = from + LOG_WINDOW - 1;
            if (to > toBlock) to = toBlock;
            raw[w] = vm.eth_getLogs(from, to, emitter, topics);
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

    /// @dev The games deploy, whose timelock check this script calls. Overridable, so a test can hand it a log
    ///      reader of its own.
    function _timelockCheck() internal virtual returns (DeployGames) {
        return gamesDeploy;
    }

    function _countLogs(address emitter, uint256 fromBlock, uint256 toBlock, bytes32 topic0) internal returns (uint256) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic0;
        return _logs(emitter, fromBlock, toBlock, topics).length;
    }

    function _wordAt(address target, bytes memory data, uint256 n) internal returns (bytes32) {
        bytes memory r = _callAt(target, data, n);
        require(r.length == 32, "a read at an anchor did not answer one word");
        // casting to 'bytes32' is safe because the line above requires one word
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32(r);
    }

    function _addressAt(address target, bytes memory data, uint256 n) internal returns (address) {
        uint256 w = uint256(_wordAt(target, data, n));
        require(w >> 160 == 0, "a read at an anchor did not answer an address");
        // casting to 'uint160' is safe because the line above requires the high bits zero
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(w));
    }

    function _uintAt(address target, bytes memory data, uint256 n) internal returns (uint256) {
        return uint256(_wordAt(target, data, n));
    }

    function _bytes32At(address target, bytes memory data, uint256 n) internal returns (bytes32) {
        return _wordAt(target, data, n);
    }

    function _boolAt(address target, bytes memory data, uint256 n) internal returns (bool) {
        uint256 w = uint256(_wordAt(target, data, n));
        require(w <= 1, "a read at an anchor did not answer a bool");
        return w == 1;
    }

    /// @dev A quantity as the node answers it: its bytes, high byte first.
    function _quantity(bytes memory b) internal pure returns (uint256) {
        require(b.length != 0 && b.length <= 32, "the node gave no quantity");
        // casting to 'bytes32' is safe because the line above requires at most one word
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(bytes32(b) >> (8 * (32 - b.length)));
    }

    function _topic(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev A number as the node takes a block: 0x, then its hex digits with no leading zero.
    function _hex(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0x0";
        bytes memory digits = "0123456789abcdef";
        bytes memory out = new bytes(64);
        uint256 i = 64;
        while (n != 0) {
            out[--i] = digits[n & 15];
            n >>= 4;
        }
        bytes memory trimmed = new bytes(64 - i);
        for (uint256 j; j < trimmed.length; ++j) {
            trimmed[j] = out[i + j];
        }
        return string.concat("0x", string(trimmed));
    }
}
