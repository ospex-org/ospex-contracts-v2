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
    /// @dev keccak256 of TimelockController's runtime code from OpenZeppelin v5.5.0 (commit fcbae53),
    ///      built with this repo's foundry.toml, minus solc's 53-byte metadata trailer. The trailer
    ///      hashes the source text, which changes with a checkout's line endings, so it is left out.
    ///      v5.6.1 and v5.7.0 build to the same code, so the release is checked on its own as well.
    bytes32 public constant STOCK_CODE_HASH = 0xc3bc13a3ed744700e803d10a97d2d3305b017bd75c917bdc407a7fd02c0b944c;
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

    /// @notice keccak256 of `code` without solc's metadata trailer, whose length (0x33) is the last two
    ///         bytes. Zero when the code does not end that way.
    function stockHash(bytes memory code) public pure returns (bytes32 h) {
        uint256 n = code.length;
        if (n < 53 || code[n - 2] != 0x00 || code[n - 1] != 0x33) return bytes32(0);
        assembly ("memory-safe") {
            h := keccak256(add(code, 0x20), sub(n, 53))
        }
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
