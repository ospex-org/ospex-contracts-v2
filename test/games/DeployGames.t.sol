// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeployGames, IWorkflowRegistryRead} from "../../script/DeployGames.s.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {OspexChainlinkReporter} from "../../src/games/OspexChainlinkReporter.sol";
import {IOspexGames, ReporterKind, Terms, Hint} from "../../src/games/IOspexGames.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
import {MockReporter} from "./GamesBase.sol";
import {TestCoin, TrickCoin, FalseCoin} from "./CoinFixtures.sol";

/// @dev Lets a test run each phase with inputs, records and a directory of its own, and stands in for the two
///      reads of the RPC that cannot see a deploy made on a local fork: the code at a past block, and the logs.
contract DeployGamesHarness is DeployGames {
    uint256 internal localFrom;

    function predictFor(Inputs memory in_, address deployer, address workflowOwner, string memory dir)
        external
        returns (Prediction memory)
    {
        return _predict(in_, deployer, workflowOwner, dir);
    }

    function deployFrom(Inputs memory in_, Prediction memory p, Workflow memory w, string memory dir)
        external
        returns (OspexChainlinkReporter, OspexGames)
    {
        return _deploy(in_, p, w, dir);
    }

    function signpostCallFor(Inputs memory in_, Deployed memory d, uint256 deployBlock, bytes20 commit, string memory dir)
        external
        returns (bytes memory, bytes32)
    {
        return _signpostCall(in_, d, deployBlock, commit, dir);
    }

    /// @dev From this block on, the code at an address is the fork's own: a local creation the RPC never saw.
    function setLocalFrom(uint256 blockNumber) external {
        localFrom = blockNumber;
    }

    function _codeAt(address account, uint256 blockNumber) internal override returns (bytes memory) {
        if (localFrom != 0 && blockNumber >= localFrom) return account.code;
        return super._codeAt(account, blockNumber);
    }

    function recordDir(string memory name) external view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/games-set/test/", name);
    }
}

/**
 * @notice Tests for script/DeployGames.s.sol on a fork of Polygon mainnet at FORK_BLOCK, after the signpost's
 *         creation, with the Polygon timelock, the signpost, USDC and Chainlink's forwarder there, and a fork
 *         of Ethereum mainnet for the registry. They need POLYGON_RPC_URL and ETHEREUM_RPC_URL; without both
 *         (CI has no RPC) every test here is skipped, which is how a run reports that no fork was used.
 *
 *         The registry on Ethereum holds one workflow this repository can name, v2's, under its owner: the
 *         tests that need "an id the registry holds under the owner" use that pair, and the deploy they
 *         rehearse fixes v2's id in the reporter. The id's binding to a build with the predicted addresses in
 *         its config is the reproducible build's, rehearsed on the anvil forks; here the record is written as
 *         that build writes it.
 *
 *         Tests named test_neverLine_... are the spec's lines under "Must never happen" ("Keys, deploys and
 *         the signpost", and "Games and reporters") as they reach the deploy, each with the one-line break in
 *         the script that turns it red.
 */
contract DeployGamesTest is Test {
    uint256 internal constant FORK_BLOCK = 96_180_000;
    address internal constant TIMELOCK = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;
    address internal constant K = 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E;
    address internal constant SIGNPOST = 0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant FORWARDER = 0x76c9cf548b4179F8901cda1f8623568b58215E62;
    /// @dev An address that holds USDC at the fork block: the deployer and a creator are funded from it.
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @dev v2's workflow at the registry on Ethereum, and the owner it is held under.
    bytes32 internal constant V2_ID = 0x0097efdade80ff0a9557d927a1c07075a453bba9cd0fae7e22519c613ec47805;
    address internal constant V2_OWNER = 0x40047BAFcdEd16C938058b7b67186299a2893561;
    uint96 internal constant FEE = 1_000_000;

    DeployGamesHarness internal script;
    DeployGames.Inputs internal polygon;
    /// @dev In a test, forge broadcasts from its default sender.
    address internal deployer = DEFAULT_SENDER;
    address internal stranger = makeAddr("stranger");
    address internal creator = makeAddr("creator");
    string internal ethRpc;
    uint256 internal polygonFork;

    function setUp() public {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        ethRpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0 || bytes(ethRpc).length == 0) {
            vm.skip(true);
            return;
        }
        polygonFork = vm.createSelectFork(rpc, FORK_BLOCK);
        script = new DeployGamesHarness();
        script.setLocalFrom(FORK_BLOCK);
        polygon = script.inputs(137);
        // The deployer holds coin for the check.
        vm.prank(HOLDER);
        IERC20(USDC).transfer(deployer, 3 * FEE);
    }

    // ---------------------------------------------------------------------------------------------------
    // The chain's fixed addresses
    // ---------------------------------------------------------------------------------------------------

    /// The fork is Polygon at the pinned block, and it holds the inputs as pinned.
    function test_fork_isPolygonWithTheFixedAddresses() public view {
        assertEq(block.chainid, 137, "chain id");
        assertEq(block.number, FORK_BLOCK, "fork block");
        assertEq(polygon.timelock, TIMELOCK, "timelock");
        assertEq(polygon.k, K, "K");
        assertEq(polygon.signpost, SIGNPOST, "signpost");
        assertEq(polygon.coin, USDC, "coin");
        assertEq(polygon.forwarder, FORWARDER, "forwarder");
        script.requireChain(polygon);
        assertEq(TimelockController(payable(TIMELOCK)).getMinDelay(), 60, "the day-0 delay");
        assertEq(OspexSignpost(SIGNPOST).i_timelock(), TIMELOCK, "the signpost's owner");
        assertEq(OspexSignpost(SIGNPOST).entryCount(), 1, "the signpost lists v2 alone");
    }

    /// Each fixed address is checked against the chain: another timelock, another signpost, a coin with other
    /// decimals, a forwarder that is not one, each refused by name before anything is sent.
    function test_inputs_eachFixedAddressIsCheckedAgainstTheChain() public {
        DeployGames.Inputs memory in_;
        in_ = polygon;
        in_.timelock = SIGNPOST;
        vm.expectRevert(bytes("the timelock is not the pinned code"));
        script.requireChain(in_);
        in_ = polygon;
        in_.k = stranger;
        vm.expectRevert(bytes("the timelock's roles are not as ruled"));
        script.requireChain(in_);
        in_ = polygon;
        in_.signpost = TIMELOCK;
        vm.expectRevert(bytes("the signpost is not the pinned code"));
        script.requireChain(in_);
        in_ = polygon;
        in_.coin = TIMELOCK;
        vm.expectRevert();
        script.requireChain(in_);
        in_ = polygon;
        in_.coin = address(new EighteenDecimals());
        vm.expectRevert(bytes("the coin does not have six decimals"));
        script.requireChain(in_);
        in_ = polygon;
        in_.forwarder = stranger;
        vm.expectRevert(bytes("the forwarder has no code"));
        script.requireChain(in_);
        in_ = polygon;
        in_.forwarder = USDC;
        vm.expectRevert();
        script.requireChain(in_);
        in_ = polygon;
        in_.forwarder = address(new NotAForwarder());
        vm.expectRevert(bytes("the forwarder does not name itself one"));
        script.requireChain(in_);
        in_ = polygon;
        in_.registry = address(0);
        vm.expectRevert(bytes("the registry is missing"));
        script.requireChain(in_);
        vm.expectRevert(bytes("no inputs for this chain"));
        script.inputs(80002);
    }

    // ---------------------------------------------------------------------------------------------------
    // Phase 1: the prediction
    // ---------------------------------------------------------------------------------------------------

    /// predict reads the deployer's nonce k and names the coin check at k, the reporter at k + 1 and the games
    /// contract at k + 2, writes the record, and sends nothing.
    function test_predict_predictsByNonceAndSendsNothing() public {
        string memory dir = _fresh("predict");
        uint64 nonce = vm.getNonce(deployer);
        vm.startStateDiffRecording();
        DeployGames.Prediction memory p = script.predictFor(polygon, deployer, V2_OWNER, dir);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            assertTrue(diff[i].kind != VmSafe.AccountAccessKind.Create, "a contract was created");
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                assertFalse(diff[i].storageAccesses[j].isWrite, "something was written");
            }
        }
        assertEq(vm.getNonce(deployer), nonce, "something was sent");
        assertEq(p.chainId, 137, "chain");
        assertEq(p.deployer, deployer, "deployer");
        assertEq(p.nonce, nonce, "k");
        assertEq(p.workflowOwner, V2_OWNER, "owner");
        assertEq(p.reporter, vm.computeCreateAddress(deployer, nonce + 1), "the reporter at k + 1");
        assertEq(p.games, vm.computeCreateAddress(deployer, nonce + 2), "the games contract at k + 2");
        assertEq(p.reporter.code.length, 0, "no code yet at the reporter's address");
        assertEq(p.games.code.length, 0, "no code yet at the games address");

        DeployGames.Prediction memory back = script.readPrediction(dir);
        assertEq(keccak256(abi.encode(back)), keccak256(abi.encode(p)), "the record reads back as predicted");

        // A second prediction in the same place is refused: a new prediction means a new id.
        vm.expectRevert(bytes("a prediction exists: a new one means a new id"));
        script.predictFor(polygon, deployer, V2_OWNER, dir);
        _clean(dir);
    }

    /// predict refuses a missing owner, an owner that is the deployer, the key as deployer, and another chain.
    function test_predict_refusesWhatCannotBeDeployDay() public {
        string memory dir = _fresh("predict-refusals");
        vm.expectRevert(bytes("the workflow owner is missing"));
        script.predictFor(polygon, deployer, address(0), dir);
        vm.expectRevert(bytes("the workflow owner is the deployer"));
        script.predictFor(polygon, deployer, deployer, dir);
        vm.expectRevert(bytes("the deployer is the key"));
        script.predictFor(polygon, K, V2_OWNER, dir);
        assertFalse(vm.exists(string.concat(dir, "/prediction.json")), "a record was written");
        vm.chainId(80002);
        vm.expectRevert(bytes("the RPC is not on the inputs' chain"));
        script.predictFor(polygon, deployer, V2_OWNER, dir);
        vm.chainId(137);
        _clean(dir);
    }

    // ---------------------------------------------------------------------------------------------------
    // The build's output: the id comes from it and from nothing less
    // ---------------------------------------------------------------------------------------------------

    /// readWorkflow takes the id from the reproducible build's output and refuses an output whose owner is not
    /// the predicted one, whose config does not name both predicted addresses, or whose id is not one the
    /// registry computes.
    function test_workflow_theIdComesFromTheBuildAndFromNothingLess() public {
        string memory dir = _fresh("workflow");
        DeployGames.Prediction memory p = script.predictFor(polygon, deployer, V2_OWNER, dir);

        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        assertEq(w.id, V2_ID, "the id");
        assertEq(w.owner, V2_OWNER, "the owner");
        assertEq(w.name, "osgames", "the name");

        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, stranger);
        vm.expectRevert(bytes("the build's config does not name the predicted games contract"));
        script.readWorkflow(dir, p);
        _writeWorkflow(dir, V2_ID, V2_OWNER, stranger, p.games);
        vm.expectRevert(bytes("the build's config does not name the predicted reporter"));
        script.readWorkflow(dir, p);
        _writeWorkflow(dir, V2_ID, V2_OWNER, p.games, p.reporter);
        DeployGames.Workflow memory swapped = script.readWorkflow(dir, p);
        assertEq(swapped.id, V2_ID, "both named, in either field");
        _writeWorkflow(dir, V2_ID, K, p.reporter, p.games);
        vm.expectRevert(bytes("the build's owner is not the predicted workflow owner"));
        script.readWorkflow(dir, p);
        _writeWorkflow(dir, bytes32(0), V2_OWNER, p.reporter, p.games);
        vm.expectRevert(bytes("the workflow id is zero"));
        script.readWorkflow(dir, p);
        _writeWorkflow(dir, bytes32(uint256(V2_ID) | (uint256(1) << 255)), V2_OWNER, p.reporter, p.games);
        vm.expectRevert(bytes("the workflow id's first byte is not zero: not an id the registry computes"));
        script.readWorkflow(dir, p);
        vm.removeFile(string.concat(dir, "/workflow.json"));
        vm.expectRevert(bytes("no workflow.json: the reproducible build's output, saved beside the prediction"));
        script.readWorkflow(dir, p);
        _clean(dir);
    }

    // ---------------------------------------------------------------------------------------------------
    // The registry: the script stops before the reporter's deploy unless the registry holds the id
    // ---------------------------------------------------------------------------------------------------

    /// The registry on Ethereum, read from a fork of it: v2's id under v2's owner passes and the script is back
    /// on Polygon after; an unlinked owner, an id the registry does not hold, and a registry RPC on the wrong
    /// chain each stop it.
    /// Break: in deploy(), delete the `requireRegistered(...)` line. The deploy then goes ahead on an id the
    /// registry does not hold.
    function test_neverLine_theDeployWaitsForTheRegistryToHoldTheId() public {
        IWorkflowRegistryRead.WorkflowStatus status = script.requireRegistered(polygon, V2_ID, V2_OWNER, ethRpc);
        assertEq(uint8(status), uint8(IWorkflowRegistryRead.WorkflowStatus.ACTIVE), "v2's workflow is active");
        assertEq(block.chainid, 137, "back on Polygon");
        assertEq(block.number, FORK_BLOCK, "back at the fork block");

        // Another linked owner, read from the registry itself: v2's id is not held under it.
        vm.createSelectFork(ethRpc);
        address[] memory linked = IRegistryOwners(polygon.registry).getLinkedOwners(0, 4);
        vm.selectFork(polygonFork);
        address other = address(0);
        for (uint256 i; i < linked.length; ++i) {
            if (linked[i] != V2_OWNER) other = linked[i];
        }
        assertTrue(other != address(0), "the registry lists another linked owner");
        // A refusal ends a script run where it stands; a test goes on, so it steps back to the Polygon fork.
        vm.expectRevert(bytes("the registry holds the id under another owner"));
        script.requireRegistered(polygon, V2_ID, other, ethRpc);
        vm.selectFork(polygonFork);
        vm.expectRevert(bytes("the workflow owner is not linked at the registry"));
        script.requireRegistered(polygon, V2_ID, K, ethRpc);
        vm.selectFork(polygonFork);
        vm.expectRevert(bytes("the registry does not hold the id"));
        script.requireRegistered(polygon, bytes32(uint256(V2_ID) ^ 1), V2_OWNER, ethRpc);
        vm.selectFork(polygonFork);
        DeployGames.Inputs memory in_ = polygon;
        in_.registryChainId = 137;
        vm.expectRevert(bytes("the registry RPC is not on the registry's chain"));
        script.requireRegistered(in_, V2_ID, V2_OWNER, ethRpc);
        vm.selectFork(polygonFork);
        in_ = polygon;
        in_.registry = V2_OWNER; // a contract on Ethereum that is not the registry
        vm.expectRevert();
        script.requireRegistered(in_, V2_ID, V2_OWNER, ethRpc);
        vm.selectFork(polygonFork);
        assertEq(block.chainid, 137, "back on Polygon");

        // The whole deploy, with the registry's answer missing: stopped before anything is sent.
        string memory dir = _fresh("registry");
        DeployGames.Prediction memory p = script.predictFor(polygon, deployer, V2_OWNER, dir);
        bytes32 unregistered = bytes32(uint256(V2_ID) ^ 1);
        _writeWorkflow(dir, unregistered, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        vm.expectRevert(bytes("the registry does not hold the id"));
        script.requireRegistered(polygon, w.id, p.workflowOwner, ethRpc);
        vm.selectFork(polygonFork);
        assertEq(p.reporter.code.length, 0, "nothing deployed");
        _clean(dir);
    }

    // ---------------------------------------------------------------------------------------------------
    // Phase 2: the deploy
    // ---------------------------------------------------------------------------------------------------

    /// deploy sends three things and nothing else, each at its predicted nonce: one fee through the coin, the
    /// reporter, the games contract; both land at their predicted addresses; the games contract records the
    /// reporter as first-n with its code hash and the launch terms; the record is written.
    function test_deploy_deploysAtThePredictedAddresses() public {
        string memory dir = _fresh("deploy");
        DeployGames.Prediction memory p = script.predictFor(polygon, deployer, V2_OWNER, dir);
        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        script.requireRegistered(polygon, w.id, p.workflowOwner, ethRpc);

        uint256 deployerCoin = IERC20(USDC).balanceOf(deployer);
        uint256 keyCoin = IERC20(USDC).balanceOf(K);
        vm.startStateDiffRecording();
        (OspexChainlinkReporter reporter, OspexGames games) = script.deployFrom(polygon, p, w, dir);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        assertEq(address(reporter), p.reporter, "the reporter at its predicted address");
        assertEq(address(games), p.games, "the games contract at its predicted address");
        assertEq(vm.getNonce(deployer), p.nonce + 3, "three sends");
        uint256 creates;
        for (uint256 i; i < diff.length; ++i) {
            if (diff[i].kind == VmSafe.AccountAccessKind.Create) {
                ++creates;
                assertEq(diff[i].accessor, deployer, "created by the deployer");
                assertEq(diff[i].account, creates == 1 ? p.reporter : p.games, "the reporter first, then the games contract");
            }
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory a = diff[i].storageAccesses[j];
                if (!a.isWrite || a.reverted) continue;
                assertTrue(a.account == p.games || a.account == USDC, "a write outside the games contract and the coin");
            }
        }
        assertEq(creates, 2, "two creations");
        assertEq(IERC20(USDC).balanceOf(deployer), deployerCoin - FEE, "the deployer paid exactly one fee");
        assertEq(IERC20(USDC).balanceOf(K), keyCoin + FEE, "the key received exactly one fee");

        // The games contract, as the constructor wrote it.
        assertEq(games.i_timelock(), TIMELOCK, "the timelock");
        assertEq(address(games.i_token()), USDC, "the coin");
        Terms memory t = games.getTerms("");
        assertEq(t.window, 24 hours, "n");
        assertEq(t.day7Clock, 7 days, "the day-7 clock");
        assertEq(t.day30Clock, 30 days, "the day-30 clock");
        assertEq(t.fee, FEE, "the fee");
        (address[] memory listed, uint8[] memory kinds) = games.getApprovedReporters();
        assertEq(listed.length, 1, "one reporter");
        assertEq(listed[0], address(reporter), "the reporter");
        assertEq(kinds[0], uint8(ReporterKind.FirstN), "first-n");
        (ReporterKind kind, bool retired, bytes32 codeHash) = games.getReporter(address(reporter));
        assertEq(uint8(kind), uint8(ReporterKind.FirstN), "admitted first-n");
        assertFalse(retired, "not retired");
        assertEq(codeHash, address(reporter).codehash, "its code hash");
        // The reporter, as the deploy fixed it.
        assertEq(reporter.i_forwarder(), FORWARDER, "the forwarder");
        assertEq(reporter.i_workflowOwner(), V2_OWNER, "the owner");
        assertEq(reporter.i_workflowId(), V2_ID, "the id");
        assertEq(address(reporter.i_games()), address(games), "the games contract");

        DeployGames.Deployed memory d = script.readDeployed(dir);
        assertEq(d.reporter, address(reporter), "recorded reporter");
        assertEq(d.games, address(games), "recorded games");
        assertEq(d.workflowId, V2_ID, "recorded id");
        assertEq(d.reporterCodeHash, address(reporter).codehash, "recorded reporter code hash");
        assertEq(d.gamesCodeHash, address(games).codehash, "recorded games code hash");
        _clean(dir);
    }

    /// Must never happen: a deployer keeps any power after deploy; an entry or a reporter is written after
    /// deploy by anything but a timelock call that waited the timelock's delay. After the deploy the deployer,
    /// the key and a stranger write nothing to the games contract; a call the key schedules on the Polygon
    /// timelock lands only once its delay is up; the deployer holds no role and no credit.
    /// Break: in _deploy(), deploy the games contract with `p.deployer` in place of `in_.timelock`. The
    /// constructor refuses it (the timelock is the deployer), so the deploy stops: red by refusal.
    function test_neverLine_theDeployerKeepsNothing() public {
        (, OspexChainlinkReporter reporter, OspexGames games, string memory dir) = _deployed("keeps-nothing");
        assertEq(games.i_timelock(), TIMELOCK, "the games contract answers to the Polygon timelock");
        assertEq(games.getCredit(deployer), 0, "no credit");
        script.requireTimelock(TIMELOCK, K, polygon.timelockCodeHash);
        assertFalse(TimelockController(payable(TIMELOCK)).hasRole(keccak256("PROPOSER_ROLE"), deployer), "a role");

        MockReporter extra = new MockReporter(IOspexGames(address(games)));
        bytes memory approve = abi.encodeCall(
            IOspexGames.approveReporter, (address(extra), ReporterKind.AfterN, address(extra).codehash)
        );
        bytes memory terms = abi.encodeCall(IOspexGames.setTerms, ("nba", script.launchTerms()));
        bytes memory retire = abi.encodeCall(IOspexGames.retireReporter, (address(reporter)));
        address[3] memory callers = [deployer, K, stranger];
        for (uint256 i; i < callers.length; ++i) {
            bytes[3] memory calls = [approve, terms, retire];
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i], callers[i]);
                vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NotTheTimelock.selector, callers[i]));
                (bool ok,) = address(games).call(calls[j]);
                ok;
            }
        }
        (address[] memory listed,) = games.getApprovedReporters();
        assertEq(listed.length, 1, "the list is as deployed");

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        uint256 delay = timelock.getMinDelay();
        vm.prank(K);
        timelock.schedule(address(games), 0, approve, bytes32(0), bytes32(uint256(1)), delay);
        vm.warp(vm.getBlockTimestamp() + delay - 1);
        vm.prank(stranger);
        vm.expectRevert();
        timelock.execute(address(games), 0, approve, bytes32(0), bytes32(uint256(1)));
        (listed,) = games.getApprovedReporters();
        assertEq(listed.length, 1, "written before the delay");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        timelock.execute(address(games), 0, approve, bytes32(0), bytes32(uint256(1)));
        (listed,) = games.getApprovedReporters();
        assertEq(listed.length, 2, "written after the delay");
        assertEq(listed[1], address(extra), "the approved reporter");
        _clean(dir);
    }

    /// Must never happen: the games set deploys without the hooks; a reporter's report shape differs by
    /// reporter. The deployed games contract lists the reporter first-n and takes the one report shape from
    /// it through the forwarder, and from a reporter approved later the same way.
    /// Break: in _deploy(), deploy the games contract with `_afterN()` in place of `_firstN()` (and make the
    /// helper): the constructor refuses a list with no first-n reporter, so the deploy stops.
    function test_neverLine_theGamesSetDeploysWithTheHooks() public {
        (, OspexChainlinkReporter reporter, OspexGames games, string memory dir) = _deployed("hooks");
        (address[] memory listed, uint8[] memory kinds) = games.getApprovedReporters();
        assertEq(listed[0], address(reporter), "the reporter is on the list");
        assertEq(kinds[0], uint8(ReporterKind.FirstN), "first-n");

        // A game, and its start through the forwarder's report in the one shape.
        uint256 game = _createGame(games);
        (address[] memory recorded, uint8[] memory recordedKinds) = games.getGameReporters(game);
        assertEq(recorded.length, 1, "the game recorded its reporter");
        assertEq(recorded[0], address(reporter), "the reporter");
        assertEq(recordedKinds[0], uint8(ReporterKind.FirstN), "first-n");

        bytes memory metadata = abi.encodePacked(V2_ID, bytes10("830f5085b7"), V2_OWNER, bytes2(0x0001));
        vm.prank(FORWARDER, stranger);
        reporter.onReport(metadata, abi.encode(_startReport(game, uint64(vm.getBlockTimestamp() + 1 hours))));
        assertEq(uint8(games.getGameStatus(game)), 2, "started: the hook took the one shape");
        _clean(dir);
    }

    /// Done when: a nonce moved by one stops the script before it sends. The deployer sent one transaction
    /// since the prediction; deploy stops at its first read of the nonce, creating nothing and moving no coin.
    /// Break: in _deploy(), delete `require(vm.getNonce(sender) == p.nonce, ...)`. The deploy then runs, and
    /// the reporter lands at k + 2 instead of its predicted address (refused there, after the coin moved).
    function test_neverLine_aMovedNonceStopsTheDeployBeforeAnySend() public {
        string memory dir = _fresh("nonce");
        DeployGames.Prediction memory p = script.predictFor(polygon, deployer, V2_OWNER, dir);
        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        vm.setNonce(deployer, p.nonce + 1);
        _expectDeployStopped(polygon, p, w, dir, "the nonce moved since the prediction: nothing sent");
        assertEq(vm.getNonce(deployer), p.nonce + 1, "nothing sent");
        _clean(dir);
    }

    /// Done when: the coin check stops the script on a coin that doesn't move exactly the fee both ways. A
    /// coin that keeps a cut, one that charges the sender, one that refunds the sender, one that answers false,
    /// and a deployer short of one fee each stop the deploy before anything is created; the plain coin passes.
    /// Break: in _deploy(), delete `require(coin.balanceOf(in_.k) == keyBefore + LAUNCH_FEE, ...)`. The coin
    /// with a cut then gets a games set.
    function test_neverLine_theCoinCheckStopsADeployOnACoinThatMovesOtherThanTheFee() public {
        TrickCoin trick = new TrickCoin();
        trick.mint(deployer, 10 * FEE);
        DeployGames.Inputs memory other = polygon;
        other.coin = address(trick);
        string memory dir = _fresh("coin");
        DeployGames.Prediction memory p = script.predictFor(other, deployer, V2_OWNER, dir);
        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);

        trick.setCut(1);
        _expectDeployStopped(other, p, w, dir, "the coin did not deliver exactly the fee");
        trick.setCut(0);
        trick.setCharge(1);
        _expectDeployStopped(other, p, w, dir, "the coin did not take exactly the fee");
        trick.setCharge(0);
        trick.setRefund(1);
        _expectDeployStopped(other, p, w, dir, "the coin did not take exactly the fee");
        trick.setRefund(0);

        FalseCoin refusing = new FalseCoin();
        refusing.mint(deployer, 10 * FEE);
        refusing.setRefusing(true);
        other.coin = address(refusing);
        _expectDeployStopped(other, p, w, dir, "the coin refused the fee");

        TestCoin empty = new TestCoin();
        other.coin = address(empty);
        _expectDeployStopped(other, p, w, dir, "the deployer holds less than one fee of the coin");

        // Control: the trick coin, tricking nothing, passes the check and the set deploys.
        other.coin = address(trick);
        (OspexChainlinkReporter reporter, OspexGames games) = script.deployFrom(other, p, w, dir);
        assertEq(address(reporter), p.reporter, "deployed as predicted");
        assertEq(address(games.i_token()), address(trick), "on the coin that moved exactly the fee");
        assertEq(trick.balanceOf(K), FEE, "the key has the fee");
        _clean(dir);
    }

    /// deploy refuses to run twice: once a deploy record exists, and, that record gone, by the nonce.
    function test_deploy_refusesToRunTwice() public {
        (DeployGames.Prediction memory p,,, string memory dir) = _deployed("twice");
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(bytes("deployed already: this script runs once"));
        script.deployFrom(polygon, p, w, dir);
        vm.removeFile(string.concat(dir, "/deploy.json"));
        vm.expectRevert(bytes("the nonce moved since the prediction: nothing sent"));
        script.deployFrom(polygon, p, w, dir);
        assertEq(vm.getNonce(deployer), nonce, "something was sent");
        _clean(dir);
    }

    /// deploy refuses a sender other than the predicted deployer, and a prediction for another chain.
    function test_deploy_refusesAnotherSenderOrChain() public {
        string memory dir = _fresh("sender");
        // A prediction made for a stranger, deployed from the default sender.
        DeployGames.Prediction memory p = script.predictFor(polygon, stranger, V2_OWNER, dir);
        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        _expectDeployStopped(polygon, p, w, dir, "the sender is not the predicted deployer");
        p.chainId = 80002;
        _expectDeployStopped(polygon, p, w, dir, "the RPC is not on the prediction's chain");
        _clean(dir);
    }

    // ---------------------------------------------------------------------------------------------------
    // The read-back
    // ---------------------------------------------------------------------------------------------------

    /// verify compares every fixed value and the constructor's four logs; a set built otherwise is refused by
    /// the value that differs.
    function test_verify_readsEveryFixedValue() public {
        uint64 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        vm.recordLogs();
        OspexChainlinkReporter reporter = new OspexChainlinkReporter(FORWARDER, V2_OWNER, V2_ID, IOspexGames(predicted));
        OspexGames games = new OspexGames(
            TIMELOCK, IERC20(USDC), script.launchTerms(), _one(address(reporter)), _firstN(), _one32(address(reporter).codehash)
        );
        assertEq(address(games), predicted, "predicted");
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        DeployGames.Prediction memory p;
        p.chainId = 137;
        p.deployer = address(this);
        p.workflowOwner = V2_OWNER;
        p.reporter = address(reporter);
        p.games = address(games);
        script.verify(games, reporter, polygon, p, V2_ID, logs);

        // The values.
        vm.expectRevert(bytes("the reporter's workflow id"));
        script.verify(games, reporter, polygon, p, bytes32(uint256(V2_ID) ^ 1), logs);
        DeployGames.Prediction memory q = _copyOf(p);
        q.workflowOwner = K;
        vm.expectRevert(bytes("the reporter's workflow owner"));
        script.verify(games, reporter, polygon, q, V2_ID, logs);
        q = _copyOf(p);
        q.games = stranger;
        vm.expectRevert(bytes("not the predicted addresses"));
        script.verify(games, reporter, polygon, q, V2_ID, logs);
        DeployGames.Inputs memory in_ = polygon;
        in_.forwarder = USDC;
        vm.expectRevert();
        script.verify(games, reporter, in_, p, V2_ID, logs);

        // The logs: three, five, one changed.
        VmSafe.Log[] memory three = new VmSafe.Log[](3);
        for (uint256 i; i < 3; ++i) {
            three[i] = logs[i];
        }
        vm.expectRevert(bytes("the set has other logs"));
        script.verify(games, reporter, polygon, p, V2_ID, three);
        VmSafe.Log[] memory changed = _copy(logs);
        changed[0].topics[1] = bytes32(uint256(uint160(stranger)));
        vm.expectRevert(bytes("a constructor log is not as ruled"));
        script.verify(games, reporter, polygon, p, V2_ID, changed);
        changed = _copy(logs);
        changed[2].data = abi.encode("nba", script.launchTerms());
        vm.expectRevert(bytes("the terms log is not as ruled"));
        script.verify(games, reporter, polygon, p, V2_ID, changed);

        // A set built with other terms, with two reporters, or with the reporter after-n.
        Terms memory otherTerms = script.launchTerms();
        otherTerms.fee = 2 * FEE;
        _expectVerifyRefused(otherTerms, ReporterKind.FirstN, 0, "the default terms are not the launch terms");
        _expectVerifyRefused(script.launchTerms(), ReporterKind.FirstN, 1, "the approved list is not the reporter alone");
        _expectVerifyRefused(script.launchTerms(), ReporterKind.AfterN, 1, "the reporter is not first-n");
    }

    // ---------------------------------------------------------------------------------------------------
    // Phase 3: the signpost call, and the Polygon timelock running it
    // ---------------------------------------------------------------------------------------------------

    /// signpostCall checks the deployed code and the deploy block, proves the entry on the fork, and writes the
    /// call. The key schedules it on the Polygon timelock; it runs only after the delay; the signpost then lists
    /// the games set as building with both code hashes read from the chain; after a game is created, the move
    /// to live goes through, since the games contract records each game's reporters.
    function test_signpostCall_writesTheCallAndTheTimelockListsTheSet() public {
        (, OspexChainlinkReporter reporter, OspexGames games, string memory dir) = _deployed("signpost");
        // The block read through the cheatcode: under via-IR a `block.number` read beside a vm.roll can be
        // merged with the one after it, as a `block.timestamp` read beside a vm.warp can.
        uint256 deployBlock = vm.getBlockNumber();
        vm.roll(deployBlock + 1);
        assertEq(vm.getBlockNumber(), deployBlock + 1, "rolled one past the deploy block");
        DeployGames.Deployed memory d = script.readDeployed(dir);
        bytes20 commit = bytes20(hex"61f4dbb7358f31f3fe3778e67f98659b2709c9f7");

        vm.expectRevert(bytes("the commit is missing"));
        script.signpostCallFor(polygon, d, deployBlock, bytes20(0), dir);
        vm.expectRevert(bytes("the deploy block is not a past block"));
        script.signpostCallFor(polygon, d, deployBlock + 1, commit, dir);
        vm.expectRevert(bytes("the games contract is not in the deploy block"));
        script.signpostCallFor(polygon, d, deployBlock - 5, commit, dir);
        vm.roll(deployBlock + 2);
        vm.expectRevert(bytes("the games contract existed before the deploy block"));
        script.signpostCallFor(polygon, d, deployBlock + 1, commit, dir);
        vm.roll(deployBlock + 1);
        DeployGames.Deployed memory wrong = script.readDeployed(dir);
        wrong.reporterCodeHash = bytes32(uint256(d.reporterCodeHash) ^ 1);
        vm.expectRevert(bytes("the code is not the deployed code"));
        script.signpostCallFor(polygon, wrong, deployBlock, commit, dir);

        uint256 entries = OspexSignpost(SIGNPOST).entryCount();
        (bytes memory call, bytes32 operationId) = script.signpostCallFor(polygon, d, deployBlock, commit, dir);
        assertEq(OspexSignpost(SIGNPOST).entryCount(), entries, "the proof on the fork left no entry");
        string memory json = vm.readFile(string.concat(dir, "/signpost-call.json"));
        bytes memory add = vm.parseJsonBytes(json, ".addEntry");
        bytes32 salt = vm.parseJsonBytes32(json, ".salt");
        assertEq(vm.parseJsonBytes(json, ".schedule"), call, "the call as written");
        assertEq(vm.parseJsonBytes32(json, ".operationId"), operationId, "the operation id as written");

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        vm.prank(K);
        (bool ok,) = TIMELOCK.call(call);
        assertTrue(ok, "K schedules the call as written");
        assertTrue(timelock.isOperationPending(operationId), "pending");
        vm.warp(vm.getBlockTimestamp() + timelock.getMinDelay() - 1);
        vm.prank(stranger);
        vm.expectRevert();
        timelock.execute(SIGNPOST, 0, add, bytes32(0), salt);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        timelock.execute(SIGNPOST, 0, add, bytes32(0), salt);

        OspexSignpost signpost = OspexSignpost(SIGNPOST);
        assertEq(signpost.entryCount(), entries + 1, "listed");
        OspexSignpost.Entry memory e = signpost.getEntry(entries);
        assertEq(uint8(e.kind), uint8(OspexSignpost.Kind.Games), "a games entry");
        assertEq(e.coin, address(0), "no coin on a games entry");
        assertEq(e.contracts.length, 2, "the games contract and the reporter");
        assertEq(e.contracts[0], address(games), "the games contract first");
        assertEq(e.contracts[1], address(reporter), "the reporter second");
        assertEq(e.codeHashes[0], address(games).codehash, "the games contract's code hash, read from the chain");
        assertEq(e.codeHashes[1], address(reporter).codehash, "the reporter's code hash, read from the chain");
        assertEq(e.commit, commit, "the commit");
        assertEq(e.deployBlock, uint64(deployBlock), "the deploy block");
        assertEq(uint8(e.status), uint8(OspexSignpost.Status.Building), "building");

        // The move to live: a game exists and records its reporters, so the signpost's read answers.
        uint256 game = _createGame(games);
        bytes memory live = abi.encodeCall(OspexSignpost.moveForward, (entries, OspexSignpost.Status.Live, game, ""));
        uint256 delay = timelock.getMinDelay();
        vm.prank(K);
        timelock.schedule(SIGNPOST, 0, live, bytes32(0), bytes32(uint256(7)), delay);
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(stranger);
        timelock.execute(SIGNPOST, 0, live, bytes32(0), bytes32(uint256(7)));
        assertEq(uint8(signpost.getEntry(entries).status), uint8(OspexSignpost.Status.Live), "live");
        _clean(dir);
    }

    // ---------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------

    /// @dev A fresh record directory for one test.
    function _fresh(string memory name) internal returns (string memory dir) {
        dir = script.recordDir(name);
        _clean(dir);
    }

    function _clean(string memory dir) internal {
        if (vm.exists(dir)) vm.removeDir(dir, true);
    }

    /// @dev The whole happy path in `name`'s directory: predict, the build's record, the registry, the deploy.
    function _deployed(string memory name)
        internal
        returns (DeployGames.Prediction memory p, OspexChainlinkReporter reporter, OspexGames games, string memory dir)
    {
        dir = _fresh(name);
        p = script.predictFor(polygon, deployer, V2_OWNER, dir);
        _writeWorkflow(dir, V2_ID, V2_OWNER, p.reporter, p.games);
        DeployGames.Workflow memory w = script.readWorkflow(dir, p);
        script.requireRegistered(polygon, w.id, p.workflowOwner, ethRpc);
        (reporter, games) = script.deployFrom(polygon, p, w, dir);
    }

    /// @dev The build's output as its tool writes it, with the config naming the two addresses.
    function _writeWorkflow(string memory dir, bytes32 id, address owner, address reporter, address games) internal {
        string memory json = string.concat(
            '{"spec":"build/games.json","name":"osgames","owner":"',
            vm.toString(owner),
            '","config":{"receiverAddress":"',
            vm.toString(reporter),
            '","eventAddress":"',
            vm.toString(games),
            '","secretOwner":"',
            vm.toString(owner),
            '"},"tools":{"cre":"CRE CLI version v1.22.0","bun":"1.3.14"},"hashes":{"config":"',
            "9a7ab7e33948b572aa6dd0c9762f444573cadd564addb804f594536b57d4724b",
            '","binary":"5929b9c675ae03ec67e6a5b4adba8ff2be5164e41e7dcdbe7b670954638da755","id":"',
            vm.toString(id),
            '"},"matches":{"config":"no expectation","binary":"no expectation","id":"no expectation"},"notes":[]}'
        );
        vm.writeFile(string.concat(dir, "/workflow.json"), json);
    }

    /// @dev Expects the deploy to stop for `reason`, with nothing created, nothing sent and no coin moved.
    function _expectDeployStopped(
        DeployGames.Inputs memory in_,
        DeployGames.Prediction memory p,
        DeployGames.Workflow memory w,
        string memory dir,
        string memory reason
    ) internal {
        uint64 nonce = vm.getNonce(deployer);
        uint256 coin = IERC20(in_.coin).balanceOf(deployer);
        vm.startStateDiffRecording();
        vm.expectRevert(bytes(reason));
        script.deployFrom(in_, p, w, dir);
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            assertTrue(diff[i].kind != VmSafe.AccountAccessKind.Create || diff[i].reverted, "a contract was created");
        }
        assertEq(IERC20(in_.coin).balanceOf(deployer), coin, "coin moved");
        assertEq(p.reporter.code.length, 0, "the reporter was deployed");
        assertEq(p.games.code.length, 0, "the games contract was deployed");
        assertFalse(vm.exists(string.concat(dir, "/deploy.json")), "a deploy record was written");
        // In a test, forge counts a broadcast call against the sender's nonce even when the call then reverts,
        // and leaves the broadcast switched on; on chain a reverted simulation sends nothing and the nonce
        // stays. Put both back for the next attempt.
        vm.setNonceUnsafe(deployer, nonce);
        (VmSafe.CallerMode mode,,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.RecurrentBroadcast || mode == VmSafe.CallerMode.Broadcast) vm.stopBroadcast();
    }

    function _copyOf(DeployGames.Prediction memory p) internal pure returns (DeployGames.Prediction memory q) {
        q.chainId = p.chainId;
        q.deployer = p.deployer;
        q.nonce = p.nonce;
        q.workflowOwner = p.workflowOwner;
        q.reporter = p.reporter;
        q.games = p.games;
    }

    /// @dev A games set built otherwise, with a reporter of its own: other terms, the reporter's kind, and
    ///      `extra` first-n test reporters beside it. Read back against the launch values: refused for `reason`.
    function _expectVerifyRefused(Terms memory terms, ReporterKind kind, uint256 extra, string memory reason) internal {
        address[] memory reporters = new address[](1 + extra);
        ReporterKind[] memory kinds = new ReporterKind[](1 + extra);
        for (uint256 i; i < extra; ++i) {
            reporters[1 + i] = address(new MockReporter(IOspexGames(address(0))));
            kinds[1 + i] = ReporterKind.FirstN;
        }
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        OspexChainlinkReporter reporter = new OspexChainlinkReporter(FORWARDER, V2_OWNER, V2_ID, IOspexGames(predicted));
        reporters[0] = address(reporter);
        kinds[0] = kind;
        vm.recordLogs();
        OspexGames games = new OspexGames(TIMELOCK, IERC20(USDC), terms, reporters, kinds, _hashes(reporters));
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(address(games), predicted, "built where the reporter points");
        DeployGames.Prediction memory p;
        p.chainId = 137;
        p.deployer = address(this);
        p.workflowOwner = V2_OWNER;
        p.reporter = address(reporter);
        p.games = address(games);
        vm.expectRevert(bytes(reason));
        script.verify(games, reporter, polygon, p, V2_ID, logs);
    }

    /// @dev A game on the deployed games contract, its fee paid in USDC from the holder.
    function _createGame(OspexGames games) internal returns (uint256) {
        vm.prank(HOLDER);
        IERC20(USDC).transfer(creator, FEE);
        vm.prank(creator);
        IERC20(USDC).approve(address(games), FEE);
        vm.prank(creator, creator);
        return games.createGame(
            "nba", "Denver Nuggets", "Utah Jazz", uint64(vm.getBlockTimestamp() + 1 days), new Hint[](0), FEE
        );
    }

    function _startReport(uint256 game, uint64 start) internal pure returns (IOspexGamesReport memory r) {
        r.gameId = game;
        r.kind = 1;
        r.start = start;
        r.readings = new IOspexGamesReading[](1);
        r.readings[0] = IOspexGamesReading({seat: 1, kind: 2, homeScore: 1, awayScore: 2});
    }

    function _hashes(address[] memory reporters) internal view returns (bytes32[] memory h) {
        h = new bytes32[](reporters.length);
        for (uint256 i; i < reporters.length; ++i) {
            h[i] = reporters[i].codehash;
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

    function _one32(bytes32 h) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = h;
    }

    function _firstN() internal pure returns (ReporterKind[] memory list) {
        list = new ReporterKind[](1);
        list[0] = ReporterKind.FirstN;
    }
}

/// @dev The report shape as the workflow encodes it, declared here in the spec's order.
struct IOspexGamesReading {
    uint8 seat;
    uint8 kind;
    uint32 homeScore;
    uint32 awayScore;
}

struct IOspexGamesReport {
    uint256 gameId;
    uint8 kind;
    uint64 start;
    uint32 homeScore;
    uint32 awayScore;
    IOspexGamesReading[] readings;
    address payout;
}

/// @dev The registry's read of its linked owners.
interface IRegistryOwners {
    function getLinkedOwners(uint256 start, uint256 limit) external view returns (address[] memory);
}

/// @dev Shaped like a forwarder, down to its version string, but not one by its own account.
contract NotAForwarder {
    string public constant typeAndVersion = "KeystoneForwarder 1.0.0";

    function isForwarder(address) external pure returns (bool) {
        return false;
    }
}

/// @dev A coin with eighteen decimals: not the coin the launch fee is written in.
contract EighteenDecimals is ERC20 {
    constructor() ERC20("Eighteen", "E18") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
