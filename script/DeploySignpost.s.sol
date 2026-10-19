// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OspexSignpost} from "../src/signpost/OspexSignpost.sol";

/// @dev The two v2 reads the script checks the first entry against.
interface IV2Core {
    function getModule(bytes32 moduleType) external view returns (address);
    function s_finalized() external view returns (bool);
}

interface IV2PositionModule {
    function i_token() external view returns (address);
}

/**
 * @title DeploySignpost
 * @notice Deploys OspexSignpost, owned by the Polygon timelock, with v2 as its first entry, marked building.
 *         Every value the deploy writes is a constant below, and each is checked against the chain first.
 *
 *         Deploy:    --sig "run()" --broadcast
 *         Read back: --sig "check(address,uint256)" <signpost> <creation block>
 *
 *         Both fail unless the signpost's code, its owner, its one entry and its logs are exactly as below.
 */
contract DeploySignpost is Script {
    uint256 public constant POLYGON = 137;

    /// @dev The frozen artifact: src/signpost/OspexSignpost.sol at this commit, built by solc 0.8.26 with
    ///      this repo's foundry.toml and remappings.txt. keccak256 of its creation code, and of its runtime
    ///      code with TIMELOCK in its one immutable, every byte, the metadata included.
    bytes32 public constant EXACT_INIT_HASH = 0xcc6cd0440eba938b071457bde20d6a9c2ac33ebd975bfdb5ef6a03a426845cdf;
    bytes32 public constant EXACT_CODE_HASH = 0x8e9825eee784d86186f78673b1cec491425dd517e4663e73dd7c72bea19cf9e8;
    /// @dev The same two with the metadata's source digest zeroed: every executable byte.
    bytes32 public constant STOCK_INIT_HASH = 0x71d7b33f3789695955023d8175e19dbf0b6a7dbc3012f250e35f26b57b2e1594;
    bytes32 public constant STOCK_CODE_HASH = 0xec38bf72ca9c2a4d2a63e837625b2d251bddb08eaa9e077f4521dca1b7aa320f;

    /// @dev The Polygon timelock: OpenZeppelin's TimelockController v5.5.0, created in block 95761553 by
    ///      script/DeployPolygonTimelock.s.sol, with K its one proposer and canceller.
    address public constant TIMELOCK = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;
    address public constant K = 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E;
    /// @dev Its runtime code's keccak256, as pinned in script/DeployPolygonTimelock.s.sol.
    bytes32 public constant TIMELOCK_CODE_HASH = 0x1f4a487e94bf4ae08bcad7a0fda749625eb1fb682e5edd89400ee412b93833e7;

    /// @dev v2: the set listed in docs/DEPLOYMENT.md. Its core created in block 89322650, the first of the
    ///      deploy's 13 creations, from this repo at d2be2cb.
    address public constant V2_CORE = 0x40047BAFcdEd16C938058b7b67186299a2893561;
    bytes20 public constant V2_COMMIT = hex"d2be2cb10f9cc0f54d7df807d6aa750b4c3dafdd";
    uint64 public constant V2_DEPLOY_BLOCK = 89_322_650;
    /// @dev Native USDC, the coin v2's PositionModule holds.
    address public constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    /// @notice The first entry's values, and what the script checks them against.
    struct First {
        address timelock;
        address k;
        OspexSignpost.Kind kind;
        address coin;
        address[] contracts;
        bytes32[] codeHashes;
        bytes20 commit;
        uint64 deployBlock;
    }

    function run() external returns (OspexSignpost signpost) {
        require(block.chainid == POLYGON, "the RPC is not on chain 137");
        signpost = _deploy(v2());
        console.log("signpost", address(signpost));
    }

    /// @notice Reads a deployed signpost back from the chain: its state now, and every log it emitted from
    ///         `creationBlock` to now.
    function check(OspexSignpost signpost, uint256 creationBlock) external {
        require(block.chainid == POLYGON, "the RPC is not on chain 137");
        First memory f = v2();
        requireTimelock(f.timelock, f.k);
        VmSafe.EthGetLogs[] memory raw =
            vm.eth_getLogs(creationBlock, block.number, address(signpost), new bytes32[](0));
        VmSafe.Log[] memory logs = new VmSafe.Log[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            logs[i] = VmSafe.Log(raw[i].topics, raw[i].data, raw[i].emitter);
        }
        verify(signpost, f, logs);
        console.log("read back as ruled", address(signpost));
    }

    /// @notice v2's entry: the core first, then its twelve modules in the order the core registered them.
    function v2() public pure returns (First memory f) {
        f.timelock = TIMELOCK;
        f.k = K;
        f.kind = OspexSignpost.Kind.Both;
        f.coin = USDC;
        f.commit = V2_COMMIT;
        f.deployBlock = V2_DEPLOY_BLOCK;
        f.contracts = new address[](13);
        f.codeHashes = new bytes32[](13);
        f.contracts[0] = V2_CORE;
        f.codeHashes[0] = 0x57bf38fe53df607eae0dd91e9c9506288afb652e92c8484218a4727c44eeebc7;
        f.contracts[1] = 0x0f838AF735E95625905c6acFB887a2E9f4DB9216; // ContestModule
        f.codeHashes[1] = 0x85b09e985fff212f8fb0d3d9a01491aa4840200af7d7ebc8783bb0315011bdb3;
        f.contracts[2] = 0xEA21b58E91eDcA41d0c42A8655234F8A64fa31bc; // SpeculationModule
        f.codeHashes[2] = 0x71505958e83a31e9c5f0c08066628eda7f87af4d2867328b5248b2d9fbebde6b;
        f.contracts[3] = 0x3C71fdB8ABF41487a512440e5ce6490158C26e56; // PositionModule
        f.codeHashes[3] = 0x556d0548905bcae94439192306f5271940212efb34d49c43feeb2ebb11ee307a;
        f.contracts[4] = 0x46Af20B6307Aa0Ec13de10EF58a02c5F1b5C9559; // MatchingModule
        f.codeHashes[4] = 0x7e2b73cf8ab1b645fafb60c268514de3eda06ba66aa276c4d73252f3bd8e3be7;
        f.contracts[5] = 0x06e3470012039797119Ae30e1236169304F9220C; // CreOracleReceiver
        f.codeHashes[5] = 0xd5cc884b986230b7e6c204666d3456de3be23856c8c5cb9bd961fdc3099b5389;
        f.contracts[6] = 0x07f357e67cc9B48D029b1E4C9B7F45569a2eB85C; // TreasuryModule
        f.codeHashes[6] = 0x504670ee70996f6e2241818a88c83a176ed7e3f59fce5c3ba9095e5ddb27ba14;
        f.contracts[7] = 0x02228F4bAB35d9631296C47C2103789474aD72ee; // LeaderboardModule
        f.codeHashes[7] = 0xd130766be9e64fb9822776351fb060324312e5e75ccdaa5b3050da31f9116f0a;
        f.contracts[8] = 0x5a5662C8246Ed3dC2422Cc8f773564fA41b34723; // RulesModule
        f.codeHashes[8] = 0x65612efcf9dd6408fedc8600f9aac578728f1256c3b73a4817c64857d6ba1034;
        f.contracts[9] = 0xf779d82E9a11234767921A73913dAd429F140aFB; // SecondaryMarketModule
        f.codeHashes[9] = 0x7dec7fe00c21c7122a0735a80cb7e46007b5b9c0683163724cae4e758f646518;
        f.contracts[10] = 0x59555106D4B5f1A797f3552f60ac418Eb6B6f6BD; // MoneylineScorerModule
        f.codeHashes[10] = 0x4d556f6b7ae8320ed20a588235d8cd7f55a602706b59de31d57f6e7986da011f;
        f.contracts[11] = 0x8f293da716164d5A32dc087A85e5164D929ae9D4; // SpreadScorerModule
        f.codeHashes[11] = 0xacbdb320ba710262051743f36a4dd1e34683c5f9c50b807a30aeed25ef5266e8;
        f.contracts[12] = 0xB4B1E2A2a75C34e9E4C5D3BB8A432aff973DaDa0; // TotalScorerModule
        f.codeHashes[12] = 0xf39aa8092a9b5990181c7a9e7c9925e3a2d91ab60bea785883334101876cba34;
    }

    /// @notice The module types v2's core registered, in its registration order: contracts[1] to [12].
    function v2ModuleTypes() public pure returns (bytes32[12] memory) {
        return [
            keccak256("CONTEST_MODULE"),
            keccak256("SPECULATION_MODULE"),
            keccak256("POSITION_MODULE"),
            keccak256("MATCHING_MODULE"),
            keccak256("CRE_ORACLE_RECEIVER"),
            keccak256("TREASURY_MODULE"),
            keccak256("LEADERBOARD_MODULE"),
            keccak256("RULES_MODULE"),
            keccak256("SECONDARY_MARKET_MODULE"),
            keccak256("MONEYLINE_SCORER_MODULE"),
            keccak256("SPREAD_SCORER_MODULE"),
            keccak256("TOTAL_SCORER_MODULE")
        ];
    }

    /// @notice Fails unless `timelock` holds the Polygon timelock's code, K proposes and cancels, anyone may
    ///         run a ready call, and the timelock is its own admin. The delay is a setting and not checked.
    function requireTimelock(address timelock, address k) public view {
        require(timelock.codehash == TIMELOCK_CODE_HASH, "the owner is not the Polygon timelock's code");
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

    /// @notice Fails unless the first entry's values are v2 as the chain holds it: each module is the one
    ///         the finalized core registered, each contract's code hash is the pinned one, and the coin is
    ///         the token v2's PositionModule holds.
    function requireV2(First memory f) public view {
        require(f.kind == OspexSignpost.Kind.Both, "v2 is games and betting together");
        require(f.contracts.length == 13 && f.codeHashes.length == 13, "v2 is its core and twelve modules");
        IV2Core core = IV2Core(f.contracts[0]);
        require(core.s_finalized(), "the core is not finalized");
        bytes32[12] memory types = v2ModuleTypes();
        for (uint256 i; i < 12; ++i) {
            require(core.getModule(types[i]) == f.contracts[i + 1], "a module is not the core's");
        }
        for (uint256 i; i < 13; ++i) {
            require(f.contracts[i].codehash == f.codeHashes[i], "a contract's code is not the pinned code");
        }
        require(IV2PositionModule(f.contracts[3]).i_token() == f.coin, "the coin is not v2's");
    }

    /// @notice Fails unless `signpost` is the pinned build, owned by TIMELOCK, holding exactly the first entry
    ///         `f` as building, with exactly the constructor's one log.
    function verify(OspexSignpost signpost, First memory f, VmSafe.Log[] memory logs) public view {
        // The pinned runtime code holds the owner, TIMELOCK, in its one immutable, so these two checks are
        // also the owner's.
        require(stockHash(address(signpost).code) == STOCK_CODE_HASH, "not the pinned build");
        require(keccak256(address(signpost).code) == EXACT_CODE_HASH, "the metadata is not the pinned build's");
        require(signpost.entryCount() == 1, "the signpost has other entries");

        OspexSignpost.Entry memory e = signpost.getEntry(0);
        require(e.kind == f.kind, "the first entry's kind");
        require(e.coin == f.coin, "the first entry's coin");
        require(keccak256(abi.encode(e.contracts)) == keccak256(abi.encode(f.contracts)), "the first entry's contracts");
        require(keccak256(abi.encode(e.codeHashes)) == keccak256(abi.encode(f.codeHashes)), "the first entry's code hashes");
        for (uint256 i; i < e.contracts.length; ++i) {
            require(e.codeHashes[i] == e.contracts[i].codehash, "a code hash is not the chain's");
        }
        require(e.commit == f.commit, "the first entry's commit");
        require(e.deployBlock == f.deployBlock, "the first entry's deploy block");
        // The reason needs no check of its own: the signpost writes one only on retirement, which this refuses.
        require(e.status == OspexSignpost.Status.Building, "the first entry is not building");

        // The constructor's one log, every field, and nothing else.
        require(logs.length == 1, "the signpost has other logs");
        VmSafe.Log memory l = logs[0];
        require(
            l.emitter == address(signpost) && l.topics.length == 3 && l.topics[0] == OspexSignpost.EntryAdded.selector
                && l.topics[1] == bytes32(0) && l.topics[2] == bytes32(uint256(uint160(f.coin)))
                && keccak256(l.data)
                    == keccak256(abi.encode(f.kind, f.contracts, f.codeHashes, f.commit, f.deployBlock)),
            "the first entry's log is not as ruled"
        );
    }

    /// @notice The constructor's arguments, ABI-encoded: the tail of the creation input, and what
    ///         Polygonscan's verification is given.
    function constructorArgs(First memory f) public pure returns (bytes memory) {
        return abi.encode(f.timelock, f.kind, f.coin, f.contracts, f.commit, f.deployBlock);
    }

    /// @notice keccak256 of `code` with the 32-byte source digest in solc's metadata zeroed, so every other
    ///         byte is compared. Checked before the exact hash, it tells a changed contract ("not the pinned
    ///         build") from a changed metadata. Zero unless `code` holds exactly one metadata section.
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

    /// @dev Checks the owner, the first entry and the build, deploys, and reads the signpost back, all
    ///      inside forge's simulation, so a failed check sends nothing.
    function _deploy(First memory f) internal returns (OspexSignpost signpost) {
        requireTimelock(f.timelock, f.k);
        requireV2(f);
        require(stockHash(type(OspexSignpost).creationCode) == STOCK_INIT_HASH, "not the pinned build");
        require(
            keccak256(type(OspexSignpost).creationCode) == EXACT_INIT_HASH, "the metadata is not the pinned build's"
        );

        vm.recordLogs();
        vm.startBroadcast();
        signpost = new OspexSignpost(f.timelock, f.kind, f.coin, f.contracts, f.commit, f.deployBlock);
        vm.stopBroadcast();

        verify(signpost, f, vm.getRecordedLogs());
        console.log("constructor arguments, for the verification:");
        console.logBytes(constructorArgs(f));
    }
}
