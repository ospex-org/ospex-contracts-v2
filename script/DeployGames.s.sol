// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexGames} from "../src/games/OspexGames.sol";
import {IOspexGames, ReporterKind, Terms} from "../src/games/IOspexGames.sol";
import {OspexChainlinkReporter} from "../src/games/OspexChainlinkReporter.sol";
import {IReceiver} from "../src/interfaces/cre/IReceiver.sol";
import {OspexSignpost} from "../src/signpost/OspexSignpost.sol";

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
 *            and its roles, the signpost, the coin, the forwarder), sends nothing, and writes the prediction to
 *            deployments/games-set/<chain id>/prediction.json. It then prints the command that builds the
 *            workflow's config naming both predicted addresses and computes its id (the scoring program's
 *            reproducible build, in ospex-cre), whose JSON output is saved beside the prediction as
 *            workflow.json. The deploying address sends nothing else from here to the second deploy.
 *
 *            Then the owner registers that id at Chainlink. Not here: a reporter deployed first would show the
 *            id in its constructor arguments, and an id someone else registers first can never be ours.
 *
 *         2. `deploy()`, with `--broadcast` and ETHEREUM_RPC_URL in the environment. It reads the prediction and
 *            workflow.json, requires the workflow's config to name both predicted addresses and its owner to be
 *            the predicted one, reads the registry on its own chain and stops unless it holds the id under that
 *            owner, and refuses to run twice. Then, reading the nonce before each send: one fee through the coin,
 *            from the deployer to the key, both balances by exactly the fee or it stops; the reporter, with the
 *            forwarder, the owner, the id and the games contract's predicted address fixed; the games contract,
 *            with the timelock, the coin, the launch terms (the fee among them) and the reporter as its one
 *            first-n reporter, its code hash checked by the constructor. Each address is checked against its
 *            prediction, the deployed state is read back, and deploy.json is written. A failed check reverts the
 *            simulation, so nothing is sent.
 *
 *         3. `signpostCall(uint256 deployBlock, bytes20 commit)`, no `--broadcast`. It checks the deployed code
 *            and the deploy block on chain, proves on the fork that the signpost takes the entry from the
 *            timelock, and writes the call the key schedules: `addEntry` for the games set, marked building,
 *            listed after the timelock's delay.
 *
 *         `check(address games, address reporter, uint256 creationBlock)` reads a deployed set back from the
 *         chain, its state now and every log from its creation.
 *
 *         The deployer keeps nothing: the games contract answers to the timelock, the reporter to no one. The
 *         fixed addresses sit in one table per chain, each checked against the chain before anything is sent,
 *         so the same script runs on another chain once its row is filled.
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

    // ──────────────────────────── The fixed addresses, per chain ───────

    /// @notice What the deploy reads from the chain and never sends: the timelock and its key, the signpost,
    ///         the coin, the forwarder, and the registry on its own chain.
    struct Inputs {
        uint256 chainId;
        address timelock;
        address k;
        /// @dev keccak256 of the timelock's runtime code, as pinned by its own deploy script.
        bytes32 timelockCodeHash;
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
                // script/DeployPolygonTimelock.s.sol, with K its one proposer and canceller.
                timelock: 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C,
                k: 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E,
                timelockCodeHash: 0x1f4a487e94bf4ae08bcad7a0fda749625eb1fb682e5edd89400ee412b93833e7,
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

    /// @notice What `predict` writes and `deploy` reads back.
    struct Prediction {
        uint256 chainId;
        address deployer;
        /// @dev k: the deployer's nonce at the prediction. The coin check is sent at k.
        uint64 nonce;
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
        string configHash;
        string binaryHash;
    }

    /// @notice What `deploy` writes and `signpostCall` reads back.
    struct Deployed {
        uint256 chainId;
        address deployer;
        address reporter;
        bytes32 reporterCodeHash;
        address games;
        bytes32 gamesCodeHash;
        bytes32 workflowId;
        address workflowOwner;
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
        requireRegistered(in_, w.id, p.workflowOwner, vm.envString("ETHEREUM_RPC_URL"));
        return _deploy(in_, p, w, dir);
    }

    /// @notice Phase 3. `--sig "signpostCall(uint256,bytes20)" <deploy block> <commit>`, no broadcast.
    function signpostCall(uint256 deployBlock, bytes20 commit) external returns (bytes memory call, bytes32 id) {
        string memory dir = _dir(block.chainid);
        return _signpostCall(inputs(block.chainid), readDeployed(dir), deployBlock, commit, dir);
    }

    /// @notice Reads a deployed set back from the chain: its state now, and every log the games contract and
    ///         the reporter emitted from `creationBlock` to now. For right after the deploy, before any game.
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
    }

    // ──────────────────────────── Phase 1 ──────────────────────────────

    /// @dev Checks the chain, predicts by nonce, writes the record. Sends nothing.
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
            workflowOwner: workflowOwner,
            reporter: vm.computeCreateAddress(deployer, nonce + 1),
            games: vm.computeCreateAddress(deployer, nonce + 2)
        });
        require(p.reporter.code.length == 0 && p.games.code.length == 0, "a predicted address already has code");

        string memory key = "prediction";
        vm.serializeUint(key, "chainId", p.chainId);
        vm.serializeAddress(key, "deployer", p.deployer);
        vm.serializeUint(key, "nonce", p.nonce);
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
                "  bun build/fingerprint.ts <spec> --set <the reporter's field>=",
                vm.toString(p.reporter),
                " --set <the games contract's field>=",
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

    /// @dev The three sends, each after a read of the nonce, inside the broadcast; then the read-back.
    function _deploy(Inputs memory in_, Prediction memory p, Workflow memory w, string memory dir)
        internal
        returns (OspexChainlinkReporter reporter, OspexGames games)
    {
        require(block.chainid == in_.chainId && p.chainId == in_.chainId, "the RPC is not on the prediction's chain");
        require(!vm.exists(string.concat(dir, "/deploy.json")), "deployed already: this script runs once");
        requireChain(in_);
        IERC20 coin = IERC20(in_.coin);

        vm.recordLogs();
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(sender == p.deployer, "the sender is not the predicted deployer");

        // The coin check, at k. One fee from the deployer to the key: the sender's balance falls by exactly
        // the fee and the key's rises by exactly the fee, or nothing is deployed on this coin.
        require(vm.getNonce(sender) == p.nonce, "the nonce moved since the prediction: nothing sent");
        uint256 senderBefore = coin.balanceOf(sender);
        uint256 keyBefore = coin.balanceOf(in_.k);
        require(senderBefore >= LAUNCH_FEE, "the deployer holds less than one fee of the coin");
        require(coin.transfer(in_.k, LAUNCH_FEE), "the coin refused the fee");
        require(coin.balanceOf(sender) + LAUNCH_FEE == senderBefore, "the coin did not take exactly the fee");
        require(coin.balanceOf(in_.k) == keyBefore + LAUNCH_FEE, "the coin did not deliver exactly the fee");

        // The reporter, at k + 1, with the games contract's address fixed before it exists.
        require(vm.getNonce(sender) == p.nonce + 1, "the nonce is not the reporter's: nothing more sent");
        reporter = new OspexChainlinkReporter(in_.forwarder, p.workflowOwner, w.id, IOspexGames(p.games));
        require(address(reporter) == p.reporter, "the reporter is not at its predicted address");

        // The games contract, at k + 2: the launch terms and the reporter as its one first-n reporter.
        require(vm.getNonce(sender) == p.nonce + 2, "the nonce is not the games contract's: nothing more sent");
        games = new OspexGames(
            in_.timelock, coin, launchTerms(), _one(address(reporter)), _firstN(), _one32(address(reporter).codehash)
        );
        require(address(games) == p.games, "the games contract is not at its predicted address");
        vm.stopBroadcast();

        verify(games, reporter, in_, p, w.id, _from(vm.getRecordedLogs(), address(games), address(reporter)));
        _writeDeployed(in_, p, w, reporter, games, dir);

        console.log("reporter", address(reporter));
        console.log("games", address(games));
        console.log("workflow id", vm.toString(w.id));
        console.log("constructor arguments for the verification, the reporter's then the games contract's:");
        console.logBytes(abi.encode(in_.forwarder, p.workflowOwner, w.id, p.games));
        console.logBytes(gamesConstructorArgs(in_, address(reporter)));
        console.log("written:", string.concat(dir, "/deploy.json"));
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
    ) public view {
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

    /// @dev Checks the deployed code and the deploy block on chain, proves the entry on the fork, writes the call.
    function _signpostCall(Inputs memory in_, Deployed memory d, uint256 deployBlock, bytes20 commit, string memory dir)
        internal
        returns (bytes memory call, bytes32 operationId)
    {
        require(block.chainid == in_.chainId && d.chainId == in_.chainId, "the RPC is not on the deploy's chain");
        require(commit != bytes20(0), "the commit is missing");
        require(deployBlock != 0 && deployBlock < block.number, "the deploy block is not a past block");
        requireChain(in_);
        require(d.games.codehash == d.gamesCodeHash && d.reporter.codehash == d.reporterCodeHash, "the code is not the deployed code");
        require(_codeAt(d.games, deployBlock - 1).length == 0, "the games contract existed before the deploy block");
        require(keccak256(_codeAt(d.games, deployBlock)) == d.gamesCodeHash, "the games contract is not in the deploy block");

        address[] memory set = new address[](2);
        set[0] = d.games;
        set[1] = d.reporter;
        bytes memory add = abi.encodeCall(
            OspexSignpost.addEntry, (OspexSignpost.Kind.Games, address(0), set, commit, uint64(deployBlock))
        );

        // Proven on the fork: from the timelock, the signpost takes the entry and reads both code hashes.
        OspexSignpost signpost = OspexSignpost(in_.signpost);
        uint256 before = vm.snapshotState();
        vm.prank(in_.timelock);
        uint256 id = signpost.addEntry(OspexSignpost.Kind.Games, address(0), set, commit, uint64(deployBlock));
        OspexSignpost.Entry memory e = signpost.getEntry(id);
        require(e.codeHashes[0] == d.gamesCodeHash && e.codeHashes[1] == d.reporterCodeHash, "the entry's code hashes");
        require(e.status == OspexSignpost.Status.Building, "the entry is not building");
        vm.revertToState(before);

        TimelockController timelock = TimelockController(payable(in_.timelock));
        bytes32 salt = keccak256(abi.encode("games set", d.games));
        uint256 delay = timelock.getMinDelay();
        operationId = timelock.hashOperation(in_.signpost, 0, add, bytes32(0), salt);
        call = abi.encodeCall(TimelockController.schedule, (in_.signpost, 0, add, bytes32(0), salt, delay));
        bytes memory run = abi.encodeCall(TimelockController.execute, (in_.signpost, 0, add, bytes32(0), salt));

        string memory key = "signpostCall";
        vm.serializeAddress(key, "timelock", in_.timelock);
        vm.serializeAddress(key, "signpost", in_.signpost);
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

    /// @notice Fails unless the chain holds the inputs as pinned: the timelock's code and roles, the signpost's
    ///         code and owner, a coin with six decimals, a forwarder that names itself one.
    function requireChain(Inputs memory in_) public view {
        require(block.chainid == in_.chainId, "the RPC is not on the inputs' chain");
        requireTimelock(in_.timelock, in_.k, in_.timelockCodeHash);
        require(in_.signpost.codehash == in_.signpostCodeHash, "the signpost is not the pinned code");
        require(OspexSignpost(in_.signpost).i_timelock() == in_.timelock, "the signpost is not the timelock's");
        require(in_.coin.code.length != 0, "the coin has no code");
        require(IDecimals(in_.coin).decimals() == COIN_DECIMALS, "the coin does not have six decimals");
        require(in_.forwarder.code.length != 0, "the forwarder has no code");
        require(_startsWith(IForwarderRead(in_.forwarder).typeAndVersion(), "KeystoneForwarder"), "not a forwarder");
        require(IForwarderRead(in_.forwarder).isForwarder(in_.forwarder), "the forwarder does not name itself one");
        require(in_.registry != address(0) && in_.registryChainId != 0, "the registry is missing");
    }

    /// @notice Fails unless `timelock` holds the pinned code, K proposes and cancels, anyone may run a ready
    ///         call, and the timelock is its own admin. The delay is a setting and not checked.
    function requireTimelock(address timelock, address k, bytes32 codeHash) public view {
        require(timelock.codehash == codeHash, "the timelock is not the pinned code");
        IAccessControl t = IAccessControl(timelock);
        address[3] memory who = [k, address(0), timelock];
        bytes32[4] memory roles =
            [keccak256("PROPOSER_ROLE"), keccak256("CANCELLER_ROLE"), keccak256("EXECUTOR_ROLE"), bytes32(0)];
        // Rows: K, address(0), the timelock. Columns: proposer, canceller, executor, admin.
        bool[4][3] memory ruled =
            [[true, true, false, false], [false, false, true, false], [false, false, false, true]];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 4; ++j) {
                require(t.hasRole(roles[j], who[i]) == ruled[i][j], "the timelock's roles are not as ruled");
            }
        }
    }

    /// @notice Fails unless the registry, on its own chain, holds `id` under `owner`. It moves to a fork of
    ///         `registryRpc` for the read and comes back.
    function requireRegistered(Inputs memory in_, bytes32 id, address owner, string memory registryRpc)
        public
        returns (IWorkflowRegistryRead.WorkflowStatus status)
    {
        uint256 home = vm.activeFork();
        vm.createSelectFork(registryRpc);
        require(block.chainid == in_.registryChainId, "the registry RPC is not on the registry's chain");
        IWorkflowRegistryRead registry = IWorkflowRegistryRead(in_.registry);
        require(
            keccak256(bytes(registry.typeAndVersion())) == keccak256("WorkflowRegistry 2.0.0"),
            "the registry is not WorkflowRegistry 2.0.0"
        );
        require(registry.isOwnerLinked(owner), "the workflow owner is not linked at the registry");
        IWorkflowRegistryRead.WorkflowMetadataView memory w;
        try registry.getWorkflowById(id) returns (IWorkflowRegistryRead.WorkflowMetadataView memory got) {
            w = got;
        } catch {
            revert("the registry does not hold the id");
        }
        require(w.workflowId == id && w.owner != address(0), "the registry does not hold the id");
        require(w.owner == owner, "the registry holds the id under another owner");
        status = w.status;
        console.log("the registry holds the id under the owner:", w.workflowName, w.donFamily);
        console.log("status", uint256(status), "(0 active, 1 paused), registered at", w.createdAt);
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
        p.workflowOwner = vm.parseJsonAddress(json, ".workflowOwner");
        p.reporter = vm.parseJsonAddress(json, ".reporter");
        p.games = vm.parseJsonAddress(json, ".games");
    }

    /// @notice Reads the reproducible build's output, workflow.json beside the prediction, and requires its
    ///         owner to be the predicted one and its config to name both predicted addresses. The id is taken
    ///         from it and from nothing else.
    function readWorkflow(string memory dir, Prediction memory p) public view returns (Workflow memory w) {
        string memory path = string.concat(dir, "/workflow.json");
        require(vm.exists(path), "no workflow.json: the reproducible build's output, saved beside the prediction");
        string memory json = vm.readFile(path);
        w.id = vm.parseJsonBytes32(json, ".hashes.id");
        w.owner = vm.parseJsonAddress(json, ".owner");
        w.name = vm.parseJsonString(json, ".name");
        w.cre = vm.parseJsonString(json, ".tools.cre");
        w.configHash = vm.parseJsonString(json, ".hashes.config");
        w.binaryHash = vm.parseJsonString(json, ".hashes.binary");
        require(w.id != bytes32(0), "the workflow id is zero");
        require(w.id[0] == 0, "the workflow id's first byte is not zero: not an id the registry computes");
        require(w.owner == p.workflowOwner, "the build's owner is not the predicted workflow owner");

        string[] memory keys = vm.parseJsonKeys(json, ".config");
        bool namesReporter = false;
        bool namesGames = false;
        for (uint256 i; i < keys.length; ++i) {
            string memory value = vm.parseJsonString(json, string.concat(".config.", keys[i]));
            if (!_isAddressText(value)) continue;
            address a = vm.parseAddress(value);
            if (a == p.reporter) namesReporter = true;
            if (a == p.games) namesGames = true;
        }
        require(namesReporter, "the build's config does not name the predicted reporter");
        require(namesGames, "the build's config does not name the predicted games contract");
    }

    function readDeployed(string memory dir) public view returns (Deployed memory d) {
        string memory path = string.concat(dir, "/deploy.json");
        require(vm.exists(path), "no deploy.json: run deploy first");
        string memory json = vm.readFile(path);
        d.chainId = vm.parseJsonUint(json, ".chainId");
        d.deployer = vm.parseJsonAddress(json, ".deployer");
        d.reporter = vm.parseJsonAddress(json, ".reporter");
        d.reporterCodeHash = vm.parseJsonBytes32(json, ".reporterCodeHash");
        d.games = vm.parseJsonAddress(json, ".games");
        d.gamesCodeHash = vm.parseJsonBytes32(json, ".gamesCodeHash");
        d.workflowId = vm.parseJsonBytes32(json, ".workflowId");
        d.workflowOwner = vm.parseJsonAddress(json, ".workflowOwner");
    }

    function _writeDeployed(
        Inputs memory in_,
        Prediction memory p,
        Workflow memory w,
        OspexChainlinkReporter reporter,
        OspexGames games,
        string memory dir
    ) internal {
        string memory key = "deployed";
        vm.serializeUint(key, "chainId", in_.chainId);
        vm.serializeAddress(key, "deployer", p.deployer);
        vm.serializeUint(key, "nonce", p.nonce);
        vm.serializeAddress(key, "reporter", address(reporter));
        vm.serializeBytes32(key, "reporterCodeHash", address(reporter).codehash);
        vm.serializeAddress(key, "games", address(games));
        vm.serializeBytes32(key, "gamesCodeHash", address(games).codehash);
        vm.serializeBytes32(key, "workflowId", w.id);
        vm.serializeAddress(key, "workflowOwner", p.workflowOwner);
        vm.serializeString(key, "workflowName", w.name);
        vm.serializeString(key, "cre", w.cre);
        vm.serializeString(key, "configHash", w.configHash);
        vm.serializeString(key, "binaryHash", w.binaryHash);
        vm.serializeAddress(key, "forwarder", in_.forwarder);
        vm.serializeAddress(key, "timelock", in_.timelock);
        vm.serializeAddress(key, "signpost", in_.signpost);
        vm.serializeAddress(key, "coin", in_.coin);
        string memory json = vm.serializeUint(key, "simulatedBlock", block.number);
        vm.writeJson(json, string.concat(dir, "/deploy.json"));
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

    /// @dev Every log the two contracts emitted from `fromBlock` to now, read from the chain. Overridable, so a
    ///      test on a fork can stand in for an RPC that cannot see a local deploy.
    function _logsOf(address games, address reporter, uint256 fromBlock)
        internal
        virtual
        returns (VmSafe.Log[] memory)
    {
        VmSafe.EthGetLogs[] memory g = vm.eth_getLogs(fromBlock, block.number, games, new bytes32[](0));
        VmSafe.EthGetLogs[] memory r = vm.eth_getLogs(fromBlock, block.number, reporter, new bytes32[](0));
        VmSafe.Log[] memory logs = new VmSafe.Log[](g.length + r.length);
        for (uint256 i; i < g.length; ++i) {
            logs[i] = VmSafe.Log(g[i].topics, g[i].data, g[i].emitter);
        }
        for (uint256 i; i < r.length; ++i) {
            logs[g.length + i] = VmSafe.Log(r[i].topics, r[i].data, r[i].emitter);
        }
        return logs;
    }

    /// @dev The code at `account` in block `blockNumber`, from the RPC. Overridable, as _logsOf is.
    function _codeAt(address account, uint256 blockNumber) internal virtual returns (bytes memory) {
        return vm.rpc("eth_getCode", string.concat('["', vm.toString(account), '","', _hex(blockNumber), '"]'));
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

    /// @dev True for "0x" and forty hex digits.
    function _isAddressText(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length != 42 || b[0] != "0" || b[1] != "x") return false;
        for (uint256 i = 2; i < 42; ++i) {
            bytes1 c = b[i];
            bool digit = c >= 0x30 && c <= 0x39;
            bool lower = c >= 0x61 && c <= 0x66;
            bool upper = c >= 0x41 && c <= 0x46;
            if (!digit && !lower && !upper) return false;
        }
        return true;
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
