// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexGames} from "../src/games/OspexGames.sol";
import {IOspexGames, ReporterKind, Terms} from "../src/games/IOspexGames.sol";
import {OspexChainlinkReporter} from "../src/games/OspexChainlinkReporter.sol";
import {IReceiver} from "../src/interfaces/cre/IReceiver.sol";
import {OspexSignpost} from "../src/signpost/OspexSignpost.sol";
import {DeployPolygonTimelock} from "./DeployPolygonTimelock.s.sol";

/// @dev The reads the script makes of Chainlink's workflow registry, which lives on another chain.
interface IWorkflowRegistryRead {
    enum WorkflowStatus {
        ACTIVE,
        PAUSED
    }

    /// @dev The registry's view of one workflow, field for field as the deployed registry returns it. The DON
    ///      family is the last field; a decoder that leaves it out reads the rest and never knows.
    struct WorkflowMetadataView {
        bytes32 workflowId;
        address owner;
        uint64 createdAt;
        WorkflowStatus status;
        string workflowName;
        string binaryUrl;
        string configUrl;
        string tag;
        bytes attributes;
        string donFamily;
    }

    function typeAndVersion() external view returns (string memory);
    function isOwnerLinked(address owner) external view returns (bool);
    /// @dev Reverts (WorkflowDoesNotExist) for an id the registry does not hold.
    function getWorkflowById(bytes32 workflowId) external view returns (WorkflowMetadataView memory);
}

/// @dev The reads the script makes of Chainlink's forwarder.
interface IForwarderRead {
    function typeAndVersion() external view returns (string memory);
    function isForwarder(address forwarder) external view returns (bool);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/**
 * @title DeployGames
 * @notice Deploy day for the games set, in order: the Chainlink reporter, then the games contract, with every
 *         address known before anything depends on it. Three phases, each its own `--sig`, with the registration
 *         at Chainlink between the first two, which is not the script's to do.
 *
 *         1. `predict(address workflowOwner)`, with `--sender` the deploying address and no `--broadcast`. It
 *            reads the deployer's nonce k and predicts, by nonce alone, the coin check at k, the reporter at
 *            k + 1 and the games contract at k + 2. It checks the chain's fixed addresses (the Polygon timelock
 *            and its whole layout, the signpost, the coin, the forwarder), sends nothing, and writes the plan to
 *            deployments/games-set/<chain id>/prediction.json. It then prints the command that builds the
 *            workflow's config naming both predicted addresses and computes its id (the scoring program's
 *            reproducible build, in ospex-cre), whose JSON output is saved beside the plan as workflow.json. The
 *            deploying address sends nothing else from here to the second deploy.
 *
 *            Then the owner registers that id at Chainlink. Not here: a reporter deployed first would show the
 *            id in its constructor arguments, and an id someone else registers first can never be ours.
 *
 *         2. `deploy()`, with `--broadcast` and ETHEREUM_RPC_URL in the environment. It reads the plan and the
 *            build's record. The record is checked in full: the id whole (non-zero, first byte zero as the
 *            registry computes it), the owner the predicted one, the reporter under the key the program reads
 *            its receiver from and the games contract under the key it reads its event source from, the two
 *            hashes as recorded (a sha256 each), and all of it printed. The registry, read on its own chain,
 *            must hold that id under that owner, active, under that name, or the script stops. Then, in one
 *            broadcast, the chain decides what is left to send: the coin check is sent at nonce k, or skipped
 *            when the chain already shows the fee from the deployer to the key since the plan; the reporter is
 *            sent at k + 1, or skipped when its predicted address holds this deploy's reporter; the games
 *            contract is sent at k + 2, or the whole run is refused when both addresses hold code already.
 *            Re-running finishes what is missing and refuses what is done. The deployed set is read back
 *            before the script returns. No record is written here: the plan is prediction.json, and the
 *            receipts are forge's broadcast log (broadcast/DeployGames.s.sol/<chain id>/deploy-latest.json),
 *            written by forge from the receipts and only with `--broadcast`; a dry run writes no receipt and
 *            nothing this script reads. A failed check reverts the simulation, so nothing is sent.
 *
 *         3. `signpostCall(uint256 deployBlock, bytes20 commit)`, no `--broadcast`. It reads the plan and the
 *            chain: both predicted addresses hold code, the games contract did not exist the block before the
 *            deploy block and does in it, the two point at each other. It proves on the fork that the signpost
 *            takes the entry from the timelock, and writes the call the key schedules: `addEntry` for the games
 *            set, marked building, listed after the timelock's delay.
 *
 *         `check(address games, address reporter, uint256 creationBlock)` reads a deployed set back from the
 *         chain, its state now and every log from its creation, and prints the timelock's delay, the build's
 *         record in full if it sits beside the plan, and the registry's entry if ETHEREUM_RPC_URL is set.
 *
 *         The coin check. One fee moves from the deployer to the key through the coin at the pinned address,
 *         and both balances must move by exactly the fee. That proves the coin at the pinned address behaves:
 *         a transfer of the fee arrives as the fee. It proves nothing about a coin this script would never be
 *         pointed at: a coin that rounds a displayed balance, or charges only above some amount, passes one
 *         transfer and breaks the set later. The deploy-day line: a coin other than Polygon USDC gets its own
 *         review (exact transfer, no fee, no rebase, decimals) before this script is pointed at it, and that
 *         day, a redeploy on another stable, is this check's real customer.
 *
 *         The deployer is Flow A, the operator's working wallet, the address the box's lanes send from; it
 *         created the timelock. Its nonce moves on a timer, so the deploy-day checklist (README) stops whatever
 *         sends from it on the box before the plan is written and keeps it stopped until the three sends are
 *         mined. The deployer keeps nothing: the games contract answers to the timelock, the reporter to no
 *         one. The fixed addresses sit in one table per chain, each checked against the chain before anything
 *         is sent, so the same script runs on another chain once its row is filled.
 */
contract DeployGames is Script {
    // ──────────────────────────── The launch terms ─────────────────────

    /// @dev n: 24 hours, every league at launch.
    uint64 public constant LAUNCH_WINDOW = 24 hours;
    /// @dev The day-7 clock.
    uint64 public constant LAUNCH_DAY7_CLOCK = 7 days;
    /// @dev The day-30 clock.
    uint64 public constant LAUNCH_DAY30_CLOCK = 30 days;
    /// @dev The creation fee: 1 USDC, in six decimals. The coin check moves this amount, and the coin must
    ///      have six decimals for the amount to be one coin.
    uint96 public constant LAUNCH_FEE = 1_000_000;
    uint8 public constant COIN_DECIMALS = 6;

    /// @dev Forge's default sender. A prediction for it would be for an address nobody deploys from.
    address public constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    /// @dev The widest block range one log read asks the RPC for: the public endpoints' cap. A read over a
    ///      longer range goes in windows of this size.
    uint256 public constant LOG_WINDOW = 10_000;
    /// @dev How many blocks behind its head the registry's chain is read: at the head, a node behind a shared
    ///      endpoint may not have the block yet, and the registration this read waits for is older than that.
    uint256 public constant REGISTRY_LAG = 8;

    /// @dev The keys of the workflow's config under which the program reads its two addresses: the receiver it
    ///      writes to through the forwarder (the reporter), and the contract whose logs it watches (the games
    ///      contract). The build's record carries the config's values under these keys. A program that reads
    ///      other keys changes these two constants with it.
    string public constant RECEIVER_KEY = "receiverAddress";
    string public constant EVENT_KEY = "eventAddress";

    /// @dev The Polygon timelock's own deploy script: its verify is the whole layout, read from the code, the
    ///      delay, the roles and every log the timelock ever emitted.
    DeployPolygonTimelock public immutable timelockDeploy;

    // ──────────────────────────── The fixed addresses, per chain ───────

    /// @notice What the deploy reads from the chain and never sends: the timelock, its key, its creator and
    ///         creation block, the signpost, the coin, the forwarder, and the registry on its own chain.
    struct Inputs {
        uint256 chainId;
        address timelock;
        address k;
        /// @dev The address that created the timelock: it holds no role, and its name is in every grant log.
        address timelockDeployer;
        /// @dev The block the timelock was created in: its logs are read from there to now.
        uint256 timelockCreationBlock;
        address signpost;
        /// @dev keccak256 of the signpost's runtime code, as pinned by its own deploy script.
        bytes32 signpostCodeHash;
        address coin;
        address forwarder;
        address registry;
        uint256 registryChainId;
    }

    /// @notice The table. Polygon mainnet is filled; another chain is another row.
    function inputs(uint256 chainId) public pure returns (Inputs memory in_) {
        if (chainId == 137) {
            in_ = Inputs({
                chainId: 137,
                // OpenZeppelin's TimelockController v5.5.0, created in block 95761553 by
                // script/DeployPolygonTimelock.s.sol from Flow A, with K its one proposer and canceller.
                timelock: 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C,
                k: 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E,
                timelockDeployer: 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30,
                timelockCreationBlock: 95761553,
                // The signpost, created in block 95817955 by script/DeploySignpost.s.sol, owned by the timelock.
                signpost: 0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A,
                signpostCodeHash: 0x8e9825eee784d86186f78673b1cec491425dd517e4663e73dd7c72bea19cf9e8,
                // Native USDC.
                coin: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
                // Chainlink's KeystoneForwarder 1.0.0 on Polygon mainnet: the forwarder v2's receiver holds.
                forwarder: 0x76c9cf548b4179F8901cda1f8623568b58215E62,
                // Chainlink's WorkflowRegistry 2.0.0, on Ethereum mainnet.
                registry: 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5,
                registryChainId: 1
            });
        } else {
            revert("no inputs for this chain");
        }
    }

    // ──────────────────────────── The records ──────────────────────────

    /// @notice The plan: what `predict` writes and the other phases read back.
    struct Prediction {
        uint256 chainId;
        address deployer;
        /// @dev k: the deployer's nonce at the prediction. The coin check is sent at k.
        uint64 nonce;
        /// @dev The block at the prediction. The coin check is looked for on the chain from here.
        uint256 blockNumber;
        address workflowOwner;
        /// @dev The reporter, at k + 1.
        address reporter;
        /// @dev The games contract, at k + 2.
        address games;
    }

    /// @notice What the scoring program's reproducible build wrote, as the script reads it.
    struct Workflow {
        bytes32 id;
        address owner;
        string name;
        string cre;
        /// @dev sha256 of the config's bytes, as recorded.
        bytes32 configHash;
        /// @dev sha256 of the compiled program's bytes, as recorded.
        bytes32 binaryHash;
        /// @dev The config's value under RECEIVER_KEY: the reporter.
        address receiver;
        /// @dev The config's value under EVENT_KEY: the games contract.
        address watched;
    }

    constructor() {
        timelockDeploy = new DeployPolygonTimelock();
    }

    // ──────────────────────────── The phases ───────────────────────────

    /// @notice Phase 1. `--sig "predict(address)" <workflow owner> --sender <deployer>`, no broadcast.
    function predict(address workflowOwner) external returns (Prediction memory p) {
        (, address deployer,) = vm.readCallers();
        require(deployer != FORGE_DEFAULT_SENDER, "pass --sender, the deploying address");
        return _predict(inputs(block.chainid), deployer, workflowOwner, _dir(block.chainid));
    }

    /// @notice Phase 2. `--sig "deploy()" --account <deployer> --broadcast`, with ETHEREUM_RPC_URL set.
    function deploy() external returns (OspexChainlinkReporter reporter, OspexGames games) {
        Inputs memory in_ = inputs(block.chainid);
        string memory dir = _dir(block.chainid);
        Prediction memory p = readPrediction(dir);
        Workflow memory w = readWorkflow(dir, p);
        printWorkflow(w);
        requireRegistered(in_, w, vm.envString("ETHEREUM_RPC_URL"));
        return _deploy(in_, p, w);
    }

    /// @notice Phase 3. `--sig "signpostCall(uint256,bytes20)" <deploy block> <commit>`, no broadcast.
    function signpostCall(uint256 deployBlock, bytes20 commit) external returns (bytes memory call, bytes32 id) {
        string memory dir = _dir(block.chainid);
        return _signpostCall(inputs(block.chainid), readPrediction(dir), deployBlock, commit, dir);
    }

    /// @notice Reads a deployed set back from the chain: its state now, and every log the games contract and
    ///         the reporter emitted from `creationBlock` to now. For right after the deploy, before any game.
    ///         Prints the timelock's delay; the build's record in full, if workflow.json sits beside the plan;
    ///         the registry's entry, if ETHEREUM_RPC_URL is set.
    function check(address games, address reporter, uint256 creationBlock) external {
        Inputs memory in_ = inputs(block.chainid);
        OspexChainlinkReporter r = OspexChainlinkReporter(reporter);
        Prediction memory p;
        p.chainId = in_.chainId;
        p.workflowOwner = r.i_workflowOwner();
        p.reporter = reporter;
        p.games = games;
        VmSafe.Log[] memory logs = _logsOf(games, reporter, creationBlock);
        verify(OspexGames(games), r, in_, p, r.i_workflowId(), logs);
        console.log("read back as ruled", games, reporter);
        console.log("the timelock's delay, seconds:", TimelockController(payable(in_.timelock)).getMinDelay());

        string memory dir = _dir(block.chainid);
        if (vm.exists(string.concat(dir, "/workflow.json"))) {
            Prediction memory plan = readPrediction(dir);
            require(plan.reporter == reporter && plan.games == games, "the plan beside the record is another set's");
            Workflow memory w = readWorkflow(dir, plan);
            require(w.id == r.i_workflowId(), "the record's id is not the reporter's");
            printWorkflow(w);
            string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
            if (bytes(rpc).length != 0) requireRegistered(in_, w, rpc);
        } else {
            console.log("no workflow.json beside the plan: the build's record is not printed");
        }
    }

    // ──────────────────────────── Phase 1 ──────────────────────────────

    /// @dev Checks the chain, predicts by nonce, writes the plan. Sends nothing.
    function _predict(Inputs memory in_, address deployer, address workflowOwner, string memory dir)
        internal
        returns (Prediction memory p)
    {
        require(block.chainid == in_.chainId, "the RPC is not on the inputs' chain");
        require(workflowOwner != address(0), "the workflow owner is missing");
        require(workflowOwner != deployer, "the workflow owner is the deployer");
        require(deployer != in_.k, "the deployer is the key");
        requireChain(in_);
        require(!vm.exists(string.concat(dir, "/prediction.json")), "a prediction exists: a new one means a new id");

        uint64 nonce = vm.getNonce(deployer);
        p = Prediction({
            chainId: in_.chainId,
            deployer: deployer,
            nonce: nonce,
            blockNumber: block.number,
            workflowOwner: workflowOwner,
            reporter: vm.computeCreateAddress(deployer, nonce + 1),
            games: vm.computeCreateAddress(deployer, nonce + 2)
        });
        require(p.reporter.code.length == 0 && p.games.code.length == 0, "a predicted address already has code");

        string memory key = "prediction";
        vm.serializeUint(key, "chainId", p.chainId);
        vm.serializeAddress(key, "deployer", p.deployer);
        vm.serializeUint(key, "nonce", p.nonce);
        vm.serializeUint(key, "blockNumber", p.blockNumber);
        vm.serializeAddress(key, "workflowOwner", p.workflowOwner);
        vm.serializeAddress(key, "reporter", p.reporter);
        string memory json = vm.serializeAddress(key, "games", p.games);
        vm.createDir(dir, true);
        vm.writeJson(json, string.concat(dir, "/prediction.json"));

        console.log("deployer", deployer, "at nonce", nonce);
        console.log("the coin check at nonce", nonce);
        console.log("the reporter at nonce", nonce + 1, p.reporter);
        console.log("the games contract at nonce", nonce + 2, p.games);
        console.log("written:", string.concat(dir, "/prediction.json"));
        console.log("next, in ospex-cre, the config naming both addresses and its id, saved as workflow.json:");
        console.log(
            string.concat(
                "  bun build/fingerprint.ts <spec> --set ",
                RECEIVER_KEY,
                "=",
                vm.toString(p.reporter),
                " --set ",
                EVENT_KEY,
                "=",
                vm.toString(p.games),
                " --owner ",
                vm.toString(workflowOwner),
                " --json > ",
                dir,
                "/workflow.json"
            )
        );
        console.log("then the owner registers the id at Chainlink, and the deployer sends nothing until deploy()");
    }

    // ──────────────────────────── Phase 2 ──────────────────────────────

    /// @dev The sends the chain says are missing, each after a read of the nonce, inside the broadcast; then
    ///      the read-back. Writes no record.
    function _deploy(Inputs memory in_, Prediction memory p, Workflow memory w)
        internal
        returns (OspexChainlinkReporter reporter, OspexGames games)
    {
        require(block.chainid == in_.chainId && p.chainId == in_.chainId, "the RPC is not on the prediction's chain");
        requireChain(in_);
        IERC20 coin = IERC20(in_.coin);

        // What the chain holds already. Both addresses with code is the whole deploy, done.
        bool reporterUp = p.reporter.code.length != 0;
        bool gamesUp = p.games.code.length != 0;
        require(!(reporterUp && gamesUp), "deployed already: both predicted addresses hold code");
        require(reporterUp || !gamesUp, "the games contract has code and the reporter none: not this plan's deploy");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(sender == p.deployer, "the sender is not the predicted deployer");

        // The coin check, at k: sent when the nonce is k. When the nonce has moved, the chain must show the
        // fee from the deployer to the key since the plan, or nothing is sent: a stray transaction in the
        // check's slot is not the check.
        uint64 nonce = vm.getNonce(sender);
        bool coinChecked = nonce != p.nonce;
        if (coinChecked) {
            require(nonce > p.nonce, "the nonce is below the prediction's: not the prediction's chain");
            require(
                _feeSentToKey(in_, p), "the nonce moved since the prediction and the chain shows no coin check: nothing sent"
            );
        }
        vm.recordLogs();
        if (!coinChecked) {
            // One fee from the deployer to the key: the sender's balance falls by exactly the fee and the
            // key's rises by exactly the fee, or nothing is deployed on this coin.
            uint256 senderBefore = coin.balanceOf(sender);
            uint256 keyBefore = coin.balanceOf(in_.k);
            require(senderBefore >= LAUNCH_FEE, "the deployer holds less than one fee of the coin");
            require(coin.transfer(in_.k, LAUNCH_FEE), "the coin refused the fee");
            require(coin.balanceOf(sender) + LAUNCH_FEE == senderBefore, "the coin did not take exactly the fee");
            require(coin.balanceOf(in_.k) == keyBefore + LAUNCH_FEE, "the coin did not deliver exactly the fee");
        } else {
            console.log("the coin check is on the chain since the prediction: skipped");
        }

        // The reporter, at k + 1, with the games contract's address fixed before it exists; or, if its address
        // holds code, that code is this deploy's reporter and nothing is sent for it.
        if (!reporterUp) {
            require(vm.getNonce(sender) == p.nonce + 1, "the nonce is not the reporter's: nothing more sent");
            reporter = new OspexChainlinkReporter(in_.forwarder, p.workflowOwner, w.id, IOspexGames(p.games));
            require(address(reporter) == p.reporter, "the reporter is not at its predicted address");
        } else {
            reporter = OspexChainlinkReporter(p.reporter);
            require(
                reporter.i_forwarder() == in_.forwarder && reporter.i_workflowOwner() == p.workflowOwner
                    && reporter.i_workflowId() == w.id && address(reporter.i_games()) == p.games,
                "the code at the predicted reporter is not this deploy's reporter"
            );
            console.log("the reporter holds code as deployed: skipped");
        }

        // The games contract, at k + 2: the launch terms and the reporter as its one first-n reporter.
        require(vm.getNonce(sender) == p.nonce + 2, "the nonce is not the games contract's: nothing more sent");
        games = new OspexGames(
            in_.timelock, coin, launchTerms(), _one(address(reporter)), _firstN(), _one32(address(reporter).codehash)
        );
        require(address(games) == p.games, "the games contract is not at its predicted address");
        vm.stopBroadcast();

        verify(games, reporter, in_, p, w.id, _from(vm.getRecordedLogs(), address(games), address(reporter)));

        console.log("reporter", address(reporter));
        console.log("games", address(games));
        console.log("workflow id", vm.toString(w.id));
        console.log("the timelock's delay, seconds:", TimelockController(payable(in_.timelock)).getMinDelay());
        console.log("constructor arguments for the verification, the reporter's then the games contract's:");
        console.logBytes(abi.encode(in_.forwarder, p.workflowOwner, w.id, p.games));
        console.logBytes(gamesConstructorArgs(in_, address(reporter)));
        console.log("the receipts: broadcast/DeployGames.s.sol/<chain id>/deploy-latest.json, written by forge");
        console.log("next: signpostCall(<creation block of the games contract>, <commit>)");
    }

    /// @dev The read-back after the deploy, and `check`'s. Every value the deploy fixed, read from the
    ///      contracts, and the constructor's logs: the games contract's four and the reporter's none.
    function verify(
        OspexGames games,
        OspexChainlinkReporter reporter,
        Inputs memory in_,
        Prediction memory p,
        bytes32 workflowId,
        VmSafe.Log[] memory logs
    ) public {
        requireChain(in_);
        require(address(games) == p.games && address(reporter) == p.reporter, "not the predicted addresses");

        // The reporter: its four fixed values, its one read, the forwarder's interface check.
        require(reporter.i_forwarder() == in_.forwarder, "the reporter's forwarder");
        require(reporter.i_workflowOwner() == p.workflowOwner, "the reporter's workflow owner");
        require(reporter.i_workflowId() == workflowId, "the reporter's workflow id");
        require(address(reporter.i_games()) == address(games), "the reporter's games contract");
        bytes memory values = abi.encode(in_.forwarder, p.workflowOwner, workflowId);
        require(keccak256(reporter.fixedValues()) == keccak256(values), "the reporter's fixed values");
        require(reporter.supportsInterface(type(IReceiver).interfaceId), "the reporter does not answer for IReceiver");
        require(!reporter.supportsInterface(0xffffffff), "the reporter answers for every interface");

        // The games contract: the timelock, the coin, the launch terms, the one reporter.
        require(games.i_timelock() == in_.timelock, "the games contract's timelock");
        require(address(games.i_token()) == in_.coin, "the games contract's coin");
        _requireTerms(games.getTerms(""), launchTerms());
        (ReporterKind kind, bool retired, bytes32 codeHash) = games.getReporter(address(reporter));
        require(kind == ReporterKind.FirstN, "the reporter is not first-n");
        require(!retired, "the reporter is retired");
        require(codeHash == address(reporter).codehash && codeHash != bytes32(0), "the reporter's code hash");
        (address[] memory listed, uint8[] memory kinds) = games.getApprovedReporters();
        require(listed.length == 1 && listed[0] == address(reporter), "the approved list is not the reporter alone");
        require(kinds[0] == uint8(ReporterKind.FirstN), "the list's kind for the reporter");
        require(games.gameCount() == 0, "the games contract holds games");
        require(games.getCredit(p.deployer) == 0, "the deployer is credited");

        // The constructor's four logs, in order, from the games contract, and nothing from the reporter.
        require(logs.length == 4, "the set has other logs");
        _requireLog(logs[0], address(games), IOspexGames.TimelockSet.selector, _topic(in_.timelock), "");
        _requireLog(logs[1], address(games), IOspexGames.TokenSet.selector, _topic(in_.coin), "");
        require(
            logs[2].emitter == address(games) && logs[2].topics.length == 1
                && logs[2].topics[0] == IOspexGames.TermsSet.selector
                && keccak256(logs[2].data) == keccak256(abi.encode("", launchTerms())),
            "the terms log is not as ruled"
        );
        _requireLog(
            logs[3],
            address(games),
            IOspexGames.ReporterApproved.selector,
            _topic(address(reporter)),
            abi.encode(ReporterKind.FirstN, codeHash, values)
        );
    }

    // ──────────────────────────── Phase 3 ──────────────────────────────

    /// @dev Reads the plan and the chain, proves the entry on the fork, writes the call.
    function _signpostCall(Inputs memory in_, Prediction memory p, uint256 deployBlock, bytes20 commit, string memory dir)
        internal
        returns (bytes memory call, bytes32 operationId)
    {
        require(block.chainid == in_.chainId && p.chainId == in_.chainId, "the RPC is not on the prediction's chain");
        require(commit != bytes20(0), "the commit is missing");
        require(deployBlock != 0 && deployBlock < block.number, "the deploy block is not a past block");
        requireChain(in_);
        require(p.games.code.length != 0 && p.reporter.code.length != 0, "the predicted addresses do not both hold code");
        bytes32 gamesCodeHash = p.games.codehash;
        bytes32 reporterCodeHash = p.reporter.codehash;
        require(_codeAt(p.games, deployBlock - 1).length == 0, "the games contract existed before the deploy block");
        require(keccak256(_codeAt(p.games, deployBlock)) == gamesCodeHash, "the games contract is not in the deploy block");
        // The two point at each other: the reporter at the games contract, the games contract at the
        // reporter's code as it is.
        require(address(OspexChainlinkReporter(p.reporter).i_games()) == p.games, "the reporter is not this set's");
        (ReporterKind kind,, bytes32 recorded) = OspexGames(p.games).getReporter(p.reporter);
        require(kind == ReporterKind.FirstN && recorded == reporterCodeHash, "the games contract does not list the reporter as deployed");

        address[] memory set = new address[](2);
        set[0] = p.games;
        set[1] = p.reporter;
        bytes memory add = abi.encodeCall(
            OspexSignpost.addEntry, (OspexSignpost.Kind.Games, address(0), set, commit, uint64(deployBlock))
        );

        // Proven on the fork: from the timelock, the signpost takes the entry and reads both code hashes.
        OspexSignpost signpost = OspexSignpost(in_.signpost);
        uint256 before = vm.snapshotState();
        vm.prank(in_.timelock);
        uint256 id = signpost.addEntry(OspexSignpost.Kind.Games, address(0), set, commit, uint64(deployBlock));
        OspexSignpost.Entry memory e = signpost.getEntry(id);
        require(e.codeHashes[0] == gamesCodeHash && e.codeHashes[1] == reporterCodeHash, "the entry's code hashes");
        require(e.status == OspexSignpost.Status.Building, "the entry is not building");
        vm.revertToState(before);

        TimelockController timelock = TimelockController(payable(in_.timelock));
        bytes32 salt = keccak256(abi.encode("games set", p.games));
        uint256 delay = timelock.getMinDelay();
        operationId = timelock.hashOperation(in_.signpost, 0, add, bytes32(0), salt);
        call = abi.encodeCall(TimelockController.schedule, (in_.signpost, 0, add, bytes32(0), salt, delay));
        bytes memory run = abi.encodeCall(TimelockController.execute, (in_.signpost, 0, add, bytes32(0), salt));

        string memory key = "signpostCall";
        vm.serializeAddress(key, "timelock", in_.timelock);
        vm.serializeAddress(key, "signpost", in_.signpost);
        vm.serializeAddress(key, "games", p.games);
        vm.serializeAddress(key, "reporter", p.reporter);
        vm.serializeBytes32(key, "gamesCodeHash", gamesCodeHash);
        vm.serializeBytes32(key, "reporterCodeHash", reporterCodeHash);
        vm.serializeUint(key, "deployBlock", deployBlock);
        vm.serializeUint(key, "entryId", id);
        vm.serializeUint(key, "delay", delay);
        vm.serializeBytes32(key, "salt", salt);
        vm.serializeBytes32(key, "operationId", operationId);
        vm.serializeBytes(key, "addEntry", add);
        vm.serializeBytes(key, "schedule", call);
        string memory json = vm.serializeBytes(key, "execute", run);
        vm.writeJson(json, string.concat(dir, "/signpost-call.json"));

        console.log("for K to send to the timelock", in_.timelock, "(schedule):");
        console.logBytes(call);
        console.log("for anyone, after the delay of", delay, "seconds (execute):");
        console.logBytes(run);
        console.log("operation id", vm.toString(operationId), "entry", id);
        console.log("written:", string.concat(dir, "/signpost-call.json"));
    }

    // ──────────────────────────── The chain's fixed addresses ──────────

    /// @notice Fails unless the chain holds the inputs as pinned: the timelock's whole layout, the signpost's
    ///         code and owner, a coin with six decimals, a forwarder that names itself one.
    function requireChain(Inputs memory in_) public {
        require(block.chainid == in_.chainId, "the RPC is not on the inputs' chain");
        requireTimelock(in_.timelock, in_.k, in_.timelockDeployer, in_.timelockCreationBlock);
        require(in_.signpost.codehash == in_.signpostCodeHash, "the signpost is not the pinned code");
        require(OspexSignpost(in_.signpost).i_timelock() == in_.timelock, "the signpost is not the timelock's");
        require(in_.coin.code.length != 0, "the coin has no code");
        require(IDecimals(in_.coin).decimals() == COIN_DECIMALS, "the coin does not have six decimals");
        require(in_.forwarder.code.length != 0, "the forwarder has no code");
        require(_startsWith(IForwarderRead(in_.forwarder).typeAndVersion(), "KeystoneForwarder"), "not a forwarder");
        require(IForwarderRead(in_.forwarder).isForwarder(in_.forwarder), "the forwarder does not name itself one");
        require(in_.registry != address(0) && in_.registryChainId != 0, "the registry is missing");
    }

    /// @notice Fails unless `timelock` is the Polygon timelock's ruled layout, judged by its own deploy
    ///         script's verify: the pinned code, a delay above zero (read here, and the one the layout is
    ///         checked against), K its one proposer and canceller, anyone its executor, itself its admin, its
    ///         creator holding nothing, and the five constructor logs the only logs it ever emitted: no other
    ///         address was ever granted a role.
    function requireTimelock(address timelock, address k, address deployer, uint256 creationBlock) public {
        require(keccak256(timelock.code) == timelockDeploy.EXACT_CODE_HASH(), "the timelock is not the pinned code");
        uint256 delay = TimelockController(payable(timelock)).getMinDelay();
        require(delay != 0, "the timelock has no delay");
        timelockDeploy.verify(TimelockController(payable(timelock)), k, deployer, delay, _timelockLogs(timelock, creationBlock));
    }

    /// @notice Fails unless the registry, on its own chain, holds the build's id under the build's owner,
    ///         active, under the build's name. It moves to a fork of `registryRpc` for the read and comes back.
    function requireRegistered(Inputs memory in_, Workflow memory w, string memory registryRpc) public {
        uint256 home = vm.activeFork();
        uint256 head = _headOf(registryRpc);
        require(head > REGISTRY_LAG, "the registry RPC has no head");
        vm.createSelectFork(registryRpc, head - REGISTRY_LAG);
        require(block.chainid == in_.registryChainId, "the registry RPC is not on the registry's chain");
        IWorkflowRegistryRead registry = IWorkflowRegistryRead(in_.registry);
        require(
            keccak256(bytes(registry.typeAndVersion())) == keccak256("WorkflowRegistry 2.0.0"),
            "the registry is not WorkflowRegistry 2.0.0"
        );
        require(registry.isOwnerLinked(w.owner), "the workflow owner is not linked at the registry");
        IWorkflowRegistryRead.WorkflowMetadataView memory got;
        try registry.getWorkflowById(w.id) returns (IWorkflowRegistryRead.WorkflowMetadataView memory view_) {
            got = view_;
        } catch {
            revert("the registry does not hold the id");
        }
        require(got.workflowId == w.id && got.owner != address(0), "the registry does not hold the id");
        require(got.owner == w.owner, "the registry holds the id under another owner");
        require(got.status == IWorkflowRegistryRead.WorkflowStatus.ACTIVE, "the registry holds the id paused");
        require(keccak256(bytes(got.workflowName)) == keccak256(bytes(w.name)), "the registry's name for the id is not the build's");
        console.log("the registry holds the id under the owner, active:", got.workflowName, got.donFamily);
        console.log("registered at", got.createdAt, "tag", got.tag);
        vm.selectFork(home);
    }

    // ──────────────────────────── The records ──────────────────────────

    function readPrediction(string memory dir) public view returns (Prediction memory p) {
        string memory path = string.concat(dir, "/prediction.json");
        require(vm.exists(path), "no prediction: run predict first");
        string memory json = vm.readFile(path);
        p.chainId = vm.parseJsonUint(json, ".chainId");
        p.deployer = vm.parseJsonAddress(json, ".deployer");
        p.nonce = uint64(vm.parseJsonUint(json, ".nonce"));
        p.blockNumber = vm.parseJsonUint(json, ".blockNumber");
        p.workflowOwner = vm.parseJsonAddress(json, ".workflowOwner");
        p.reporter = vm.parseJsonAddress(json, ".reporter");
        p.games = vm.parseJsonAddress(json, ".games");
    }

    /// @notice Reads the reproducible build's output, workflow.json beside the plan, in full: the id whole, the
    ///         owner the predicted one, the reporter under RECEIVER_KEY and the games contract under EVENT_KEY,
    ///         the two hashes as recorded. The id is taken from it and from nothing else. What the script cannot
    ///         check is that the hashes are the reviewed program's: that is the build's, rebuilt from BUILD.md
    ///         in ospex-cre by whoever checks.
    function readWorkflow(string memory dir, Prediction memory p) public view returns (Workflow memory w) {
        string memory path = string.concat(dir, "/workflow.json");
        require(vm.exists(path), "no workflow.json: the reproducible build's output, saved beside the prediction");
        string memory json = vm.readFile(path);
        w.id = vm.parseJsonBytes32(json, ".hashes.id");
        w.owner = vm.parseJsonAddress(json, ".owner");
        w.name = vm.parseJsonString(json, ".name");
        w.cre = vm.parseJsonString(json, ".tools.cre");
        w.configHash = _sha256Text(vm.parseJsonString(json, ".hashes.config"), "the build's config hash is not a sha256");
        w.binaryHash = _sha256Text(vm.parseJsonString(json, ".hashes.binary"), "the build's binary hash is not a sha256");
        require(w.id != bytes32(0), "the workflow id is zero");
        require(w.id[0] == 0, "the workflow id's first byte is not zero: not an id the registry computes");
        require(bytes(w.name).length != 0, "the build's name is empty");
        require(w.owner == p.workflowOwner, "the build's owner is not the predicted workflow owner");

        string memory receiverKey = string.concat(".config.", RECEIVER_KEY);
        string memory eventKey = string.concat(".config.", EVENT_KEY);
        require(vm.keyExistsJson(json, receiverKey), "the build's config has no receiver key");
        require(vm.keyExistsJson(json, eventKey), "the build's config has no event key");
        w.receiver = vm.parseJsonAddress(json, receiverKey);
        w.watched = vm.parseJsonAddress(json, eventKey);
        require(w.receiver == p.reporter, "the build's receiver is not the predicted reporter");
        require(w.watched == p.games, "the build's event source is not the predicted games contract");
    }

    /// @notice The build's record, in full, as read.
    function printWorkflow(Workflow memory w) public pure {
        console.log("the build's record:");
        console.log("  workflow id", vm.toString(w.id));
        console.log("  owner", w.owner, "name", w.name);
        console.log(string.concat("  ", RECEIVER_KEY), w.receiver);
        console.log(string.concat("  ", EVENT_KEY), w.watched);
        console.log("  config sha256", vm.toString(w.configHash));
        console.log("  binary sha256", vm.toString(w.binaryHash));
        console.log("  built with", w.cre);
    }

    // ──────────────────────────── Values ───────────────────────────────

    /// @notice The launch terms: n 24 hours, the day-7 clock 7 days, the day-30 clock 30 days, 1 USDC.
    function launchTerms() public pure returns (Terms memory) {
        return Terms({window: LAUNCH_WINDOW, day7Clock: LAUNCH_DAY7_CLOCK, day30Clock: LAUNCH_DAY30_CLOCK, fee: LAUNCH_FEE});
    }

    /// @notice The games contract's constructor arguments, ABI-encoded: the tail of its creation input.
    function gamesConstructorArgs(Inputs memory in_, address reporter) public view returns (bytes memory) {
        return abi.encode(in_.timelock, in_.coin, launchTerms(), _one(reporter), _firstN(), _one32(reporter.codehash));
    }

    /// @notice Where this chain's records live.
    function _dir(uint256 chainId) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/games-set/", vm.toString(chainId));
    }

    // ──────────────────────────── Reads of the chain ───────────────────

    /// @dev True when the chain shows the fee going from the deployer to the key through the coin since the
    ///      plan's block: the coin check, on chain. Overridable, so a test on a fork can stand in for an RPC
    ///      that cannot see a transfer made locally.
    function _feeSentToKey(Inputs memory in_, Prediction memory p) internal virtual returns (bool) {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = IERC20.Transfer.selector;
        topics[1] = _topic(p.deployer);
        topics[2] = _topic(in_.k);
        VmSafe.Log[] memory logs = _logsIn(in_.coin, p.blockNumber, block.number, topics);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].data.length == 32 && abi.decode(logs[i].data, (uint256)) == LAUNCH_FEE) return true;
        }
        return false;
    }

    /// @dev Every log the timelock emitted from its creation to now, read from the chain. Overridable, so a test
    ///      can stand a timelock of its own, with its own logs, in the Polygon timelock's place.
    function _timelockLogs(address timelock, uint256 creationBlock) internal virtual returns (VmSafe.Log[] memory) {
        return _logsIn(timelock, creationBlock, block.number, new bytes32[](0));
    }

    /// @dev Every log the two contracts emitted from `fromBlock` to now, read from the chain. Overridable, so a
    ///      test on a fork can stand in for an RPC that cannot see a local deploy.
    function _logsOf(address games, address reporter, uint256 fromBlock)
        internal
        virtual
        returns (VmSafe.Log[] memory logs)
    {
        VmSafe.Log[] memory g = _logsIn(games, fromBlock, block.number, new bytes32[](0));
        VmSafe.Log[] memory r = _logsIn(reporter, fromBlock, block.number, new bytes32[](0));
        logs = new VmSafe.Log[](g.length + r.length);
        for (uint256 i; i < g.length; ++i) {
            logs[i] = g[i];
        }
        for (uint256 i; i < r.length; ++i) {
            logs[g.length + i] = r[i];
        }
    }

    /// @dev The logs of `emitter` under `topics` from `fromBlock` to `toBlock`, read from the RPC in windows of
    ///      LOG_WINDOW blocks, in order.
    function _logsIn(address emitter, uint256 fromBlock, uint256 toBlock, bytes32[] memory topics)
        internal
        returns (VmSafe.Log[] memory logs)
    {
        require(fromBlock <= toBlock, "the log range is empty");
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
        logs = new VmSafe.Log[](count);
        uint256 n;
        for (uint256 w; w < windows; ++w) {
            for (uint256 i; i < raw[w].length; ++i) {
                logs[n++] = VmSafe.Log(raw[w][i].topics, raw[w][i].data, raw[w][i].emitter);
            }
        }
    }

    /// @dev The code at `account` in block `blockNumber`, from the RPC. Overridable, as _logsOf is.
    function _codeAt(address account, uint256 blockNumber) internal virtual returns (bytes memory) {
        return vm.rpc("eth_getCode", string.concat('["', vm.toString(account), '","', _hex(blockNumber), '"]'));
    }

    /// @dev The head block of the chain behind `rpc`, asked before a fork of it is made, so the fork can be
    ///      pinned behind the head. The number comes back as its bytes, high byte first.
    function _headOf(string memory rpc) internal returns (uint256) {
        bytes memory n = vm.rpc(rpc, "eth_blockNumber", "[]");
        require(n.length != 0 && n.length <= 32, "the RPC gave no block number");
        return uint256(bytes32(n) >> (8 * (32 - n.length)));
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _requireTerms(Terms memory got, Terms memory want) private pure {
        require(
            got.window == want.window && got.day7Clock == want.day7Clock && got.day30Clock == want.day30Clock
                && got.fee == want.fee,
            "the default terms are not the launch terms"
        );
    }

    function _requireLog(VmSafe.Log memory l, address emitter, bytes32 selector, bytes32 topic1, bytes memory data)
        private
        pure
    {
        require(
            l.emitter == emitter && l.topics.length == 2 && l.topics[0] == selector && l.topics[1] == topic1
                && keccak256(l.data) == keccak256(data),
            "a constructor log is not as ruled"
        );
    }

    function _topic(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev The logs of the two contracts, in order, out of everything recorded.
    function _from(VmSafe.Log[] memory all, address games, address reporter)
        private
        pure
        returns (VmSafe.Log[] memory out)
    {
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == games || all[i].emitter == reporter) ++n;
        }
        out = new VmSafe.Log[](n);
        n = 0;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == games || all[i].emitter == reporter) out[n++] = all[i];
        }
    }

    /// @dev A number as the RPC takes a block: 0x, then its hex digits with no leading zero.
    function _hex(uint256 n) private pure returns (string memory) {
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

    /// @dev A sha256 as the build writes one: sixty-four hex digits, no 0x. Fails with `reason` otherwise.
    function _sha256Text(string memory s, string memory reason) private pure returns (bytes32) {
        bytes memory b = bytes(s);
        require(b.length == 64, reason);
        for (uint256 i; i < 64; ++i) {
            bytes1 c = b[i];
            bool digit = c >= 0x30 && c <= 0x39;
            bool lower = c >= 0x61 && c <= 0x66;
            bool upper = c >= 0x41 && c <= 0x46;
            require(digit || lower || upper, reason);
        }
        return vm.parseBytes32(string.concat("0x", s));
    }

    function _startsWith(string memory s, string memory prefix) private pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory p = bytes(prefix);
        if (a.length < p.length) return false;
        for (uint256 i; i < p.length; ++i) {
            if (a[i] != p[i]) return false;
        }
        return true;
    }

    function _one(address a) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _one32(bytes32 h) private pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = h;
    }

    function _firstN() private pure returns (ReporterKind[] memory list) {
        list = new ReporterKind[](1);
        list[0] = ReporterKind.FirstN;
    }
}
