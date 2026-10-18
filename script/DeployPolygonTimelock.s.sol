// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployPolygonTimelock
 * @notice Deploys OpenZeppelin's TimelockController, v5.5.0 as shipped, as the Polygon timelock. The
 *         constructor alone sets the whole layout: the key K proposes and cancels, anyone may run a call
 *         once its delay is up, the timelock is its own admin, and the sender holds no role.
 *
 *         Deploy:    --sig "run(address,uint256,uint256)" <K> <chain id> <delay in seconds> --broadcast
 *         Read back: --sig "check(address,address,address,uint256,uint256)"
 *                    <timelock> <K> <deployer> <delay in seconds> <creation block>
 *
 *         Both fail unless the timelock's code, roles, delay and logs are exactly that layout.
 */
contract DeployPolygonTimelock is Script {
    /// @dev The frozen artifact: OpenZeppelin v5.5.0's TimelockController (commit fcbae53) with LF source
    ///      text, built by solc 0.8.26 with this repo's foundry.toml and remappings.txt. keccak256 of its
    ///      creation code and of its runtime code, every byte, the metadata included. A standalone compile
    ///      of the verification input gives the same bytes.
    bytes32 public constant EXACT_INIT_HASH = 0x352e04ba86c69a442bc4b3d0d009723eb1677dd9a81e9731a48befbd1fa11b4a;
    bytes32 public constant EXACT_CODE_HASH = 0x1f4a487e94bf4ae08bcad7a0fda749625eb1fb682e5edd89400ee412b93833e7;
    /// @dev The same two as stockHash, with the metadata's source digest zeroed: every executable byte.
    ///      v5.6.1 and v5.7.0 build to the same executable bytes, so the release is checked on its own.
    bytes32 public constant STOCK_INIT_HASH = 0x06e4a76c9b1409ecf842a8bb6d4a1e17eb1d2514f0a08c3f090ab894ee4ff757;
    bytes32 public constant STOCK_CODE_HASH = 0x2ded0b376fdbd407ed64919fa8ebf624dcd3ee6a65293a08bce7cee8cad2231a;
    string public constant OPENZEPPELIN = "5.5.0";
    uint256 public constant POLYGON = 137;

    function run(address k, uint256 chainId, uint256 delay) external returns (TimelockController timelock) {
        require(k != address(0), "K is missing");
        require(chainId != 0, "chain id is missing");
        require(delay != 0, "delay is missing");
        require(chainId == POLYGON, "chain id is not 137");
        require(block.chainid == chainId, "the RPC is not on chain 137");
        string memory release = vm.parseJsonString(vm.readFile("lib/openzeppelin-contracts/package.json"), ".version");
        require(keccak256(bytes(release)) == keccak256(bytes(OPENZEPPELIN)), "OpenZeppelin is not v5.5.0");
        require(stockHash(type(TimelockController).creationCode) == STOCK_INIT_HASH, "not the pinned build");
        require(
            keccak256(type(TimelockController).creationCode) == EXACT_INIT_HASH, "the metadata is not the pinned build's"
        );

        vm.recordLogs();
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(k != sender, "K is the sender");
        timelock = new TimelockController(delay, _one(k), _one(address(0)), address(0));
        vm.stopBroadcast();

        verify(timelock, k, sender, delay, vm.getRecordedLogs());
        console.log("timelock", address(timelock));
    }

    /// @notice Reads a deployed timelock back from the chain: its state now, and every log it emitted
    ///         from `creationBlock` to now.
    function check(TimelockController timelock, address k, address deployer, uint256 delay, uint256 creationBlock)
        external
    {
        require(block.chainid == POLYGON, "the RPC is not on chain 137");
        VmSafe.EthGetLogs[] memory raw = vm.eth_getLogs(creationBlock, block.number, address(timelock), new bytes32[](0));
        VmSafe.Log[] memory logs = new VmSafe.Log[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            logs[i] = VmSafe.Log(raw[i].topics, raw[i].data, raw[i].emitter);
        }
        verify(timelock, k, deployer, delay, logs);
        console.log("read back as ruled", address(timelock));
    }

    /// @notice Fails unless `timelock` is the ruled layout, judged by its code, delay, roles and every log
    ///         it has emitted. AccessControl cannot list a role's holders, so the logs are what show that
    ///         no other address was ever granted a role, even for a moment.
    function verify(TimelockController timelock, address k, address deployer, uint256 delay, VmSafe.Log[] memory logs)
        public
        view
    {
        require(stockHash(address(timelock).code) == STOCK_CODE_HASH, "not the pinned build");
        require(keccak256(address(timelock).code) == EXACT_CODE_HASH, "the metadata is not the pinned build's");
        require(timelock.getMinDelay() == delay, "delay is not the input");

        address[4] memory who = [k, address(0), address(timelock), deployer];
        bytes32[4] memory roles = [
            timelock.PROPOSER_ROLE(), timelock.CANCELLER_ROLE(), timelock.EXECUTOR_ROLE(), timelock.DEFAULT_ADMIN_ROLE()
        ];
        // Rows: K, address(0), the timelock, the deployer. Columns: proposer, canceller, executor, admin.
        bool[4][4] memory ruled = [
            [true, true, false, false],
            [false, false, true, false],
            [false, false, false, true],
            [false, false, false, false]
        ];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                require(timelock.hasRole(roles[j], who[i]) == ruled[i][j], "a role is not as ruled");
            }
        }

        // The constructor's five logs, in order, and nothing else: no other grant and no revoke.
        require(logs.length == 5, "the timelock has other logs");
        _requireGrant(logs[0], timelock, roles[3], address(timelock), deployer);
        _requireGrant(logs[1], timelock, roles[0], k, deployer);
        _requireGrant(logs[2], timelock, roles[1], k, deployer);
        _requireGrant(logs[3], timelock, roles[2], address(0), deployer);
        require(
            logs[4].emitter == address(timelock) && logs[4].topics.length == 1
                && logs[4].topics[0] == TimelockController.MinDelayChange.selector
                && keccak256(logs[4].data) == keccak256(abi.encode(uint256(0), delay)),
            "the delay log is not as ruled"
        );
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

    function _one(address a) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _requireGrant(VmSafe.Log memory l, TimelockController timelock, bytes32 role, address account, address by)
        private
        pure
    {
        require(
            l.emitter == address(timelock) && l.data.length == 0 && l.topics.length == 4
                && l.topics[0] == IAccessControl.RoleGranted.selector && l.topics[1] == role
                && l.topics[2] == bytes32(uint256(uint160(account))) && l.topics[3] == bytes32(uint256(uint160(by))),
            "a role log is not as ruled"
        );
    }
}
