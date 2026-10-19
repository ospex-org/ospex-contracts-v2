// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IGameReporters} from "./IGameReporters.sol";

/**
 * @title OspexSignpost
 * @author ospex.org
 * @notice The public list of Ospex's sets on Polygon: where each set's contracts are, and what state the
 *         set is in.
 *
 *         Its owner is the Polygon timelock, fixed at deploy. The constructor writes the first entry. After
 *         that only the timelock can write, with two calls: add an entry, and move an entry's status
 *         forward. So every later write waits the timelock's delay. The signpost keeps no wait and no key
 *         of its own, and the deployer keeps nothing.
 *
 *         The list is append-only. No call edits or removes an entry. A status moves forward only:
 *         building, live, retired, with an optional one-line reason on retirement. Retiring an entry is a
 *         mark on this list and nothing more: the signpost has no power over the set's own contracts.
 *
 *         An entry that holds games moves to live only once its first contract answers the reporters read
 *         ({IGameReporters}) for a game. The first entry, written by the constructor, never moves to live.
 */
contract OspexSignpost {
    // ──────────────────────────── Types ────────────────────────────────

    /// @notice What a set holds. `Both` is a set whose games and betting are one set.
    enum Kind {
        Games,
        Betting,
        Both
    }

    /// @notice Where a set stands. A status only moves forward.
    enum Status {
        Building,
        Live,
        Retired
    }

    /// @notice One set on the list.
    /// @param kind What the set holds.
    /// @param coin The coin the set's bets are held in; zero for a set that holds no bets.
    /// @param contracts Every contract in the set. The first is the one a reader starts from.
    /// @param codeHashes Each contract's code hash, in the same order, read from the chain when the entry
    ///        was written.
    /// @param commit The git commit of the set's source.
    /// @param deployBlock The block in which the set's first contract was created, as the entry gives it.
    ///        The signpost checks only that it is above 0 and not after the block the entry is written in.
    /// @param status Where the set stands.
    /// @param reason The reason given on retirement, if any: no line feed and no carriage return.
    struct Entry {
        Kind kind;
        address coin;
        address[] contracts;
        bytes32[] codeHashes;
        bytes20 commit;
        uint64 deployBlock;
        Status status;
        string reason;
    }

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when anything but the timelock calls a write
    error OspexSignpost__NotTheTimelock(address caller);
    /// @notice Thrown when the owner given at deploy holds no contract code, or holds a wallet's delegation
    error OspexSignpost__TimelockNotAContract(address timelock);
    /// @notice Thrown when the owner given at deploy is the deployer
    error OspexSignpost__TimelockIsTheDeployer(address timelock);
    /// @notice Thrown when an entry lists no contracts
    error OspexSignpost__NoContracts();
    /// @notice Thrown when a listed contract or coin holds no code, or holds a wallet's delegation
    error OspexSignpost__NotAContract(address account);
    /// @notice Thrown when a coin is given for a set that holds no bets, or none for a set that does
    error OspexSignpost__WrongCoin(Kind kind, address coin);
    /// @notice Thrown when an entry's commit is zero
    error OspexSignpost__NoCommit();
    /// @notice Thrown when an entry's deploy block is zero or after the current block
    error OspexSignpost__WrongDeployBlock(uint64 deployBlock);
    /// @notice Thrown when an entry id is not on the list
    error OspexSignpost__UnknownEntry(uint256 id);
    /// @notice Thrown when a move does not go forward
    error OspexSignpost__NotForward(uint256 id, Status from, Status to);
    /// @notice Thrown when the constructor's entry is asked to move to live
    error OspexSignpost__FirstEntryNeverLive();
    /// @notice Thrown when an entry's games contract does not answer the reporters read for `game`
    error OspexSignpost__ReportersNotRecorded(address games, uint256 game);
    /// @notice Thrown when a reason is given for a move that is not a retirement
    error OspexSignpost__ReasonOnlyOnRetirement();
    /// @notice Thrown when a reason holds a line feed or a carriage return
    error OspexSignpost__ReasonNotOneLine();

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when an entry is written, by the constructor or by the timelock
    event EntryAdded(
        uint256 indexed id,
        Kind kind,
        address indexed coin,
        address[] contracts,
        bytes32[] codeHashes,
        bytes20 commit,
        uint64 deployBlock
    );

    /// @notice Emitted when an entry's status moves forward
    event StatusMoved(uint256 indexed id, Status from, Status to, string reason);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The Polygon timelock: the only address that can write after deploy
    address public immutable i_timelock;

    Entry[] private s_entries;

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier onlyTimelock() {
        if (msg.sender != i_timelock) revert OspexSignpost__NotTheTimelock(msg.sender);
        _;
    }

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Fixes the owner and writes the first entry, marked building.
    /// @param timelock The Polygon timelock
    /// @param kind What the first entry's set holds
    /// @param coin The coin its bets are held in, or zero for a set that holds no bets
    /// @param contracts Every contract in its set, the one a reader starts from first
    /// @param commit The git commit of its source
    /// @param deployBlock The block in which its first contract was created
    constructor(
        address timelock,
        Kind kind,
        address coin,
        address[] memory contracts,
        bytes20 commit,
        uint64 deployBlock
    ) {
        if (!_isContract(timelock)) revert OspexSignpost__TimelockNotAContract(timelock);
        if (timelock == msg.sender) revert OspexSignpost__TimelockIsTheDeployer(timelock);
        i_timelock = timelock;
        _add(kind, coin, contracts, commit, deployBlock);
    }

    // ──────────────────────────── The timelock's calls ─────────────────

    /// @notice Adds an entry, marked building. Each contract's code hash is read from the chain now.
    /// @return id The new entry's id: its place on the list
    function addEntry(Kind kind, address coin, address[] calldata contracts, bytes20 commit, uint64 deployBlock)
        external
        onlyTimelock
        returns (uint256 id)
    {
        return _add(kind, coin, contracts, commit, deployBlock);
    }

    /// @notice Moves an entry's status forward: building to live, building to retired, or live to retired.
    /// @param id The entry
    /// @param to The new status
    /// @param game For a move to live of an entry that holds games: the game whose reporters read is
    ///        checked. Not read for any other move.
    /// @param reason For a retirement: an optional one-line reason. Empty for a move to live.
    function moveForward(uint256 id, Status to, uint256 game, string calldata reason) external onlyTimelock {
        if (id >= s_entries.length) revert OspexSignpost__UnknownEntry(id);
        Entry storage e = s_entries[id];
        Status from = e.status;
        if (uint8(to) <= uint8(from)) revert OspexSignpost__NotForward(id, from, to);

        if (to == Status.Retired) {
            _requireOneLine(reason);
            e.reason = reason;
        } else {
            if (bytes(reason).length != 0) revert OspexSignpost__ReasonOnlyOnRetirement();
            if (id == 0) revert OspexSignpost__FirstEntryNeverLive();
            if (e.kind != Kind.Betting) _requireRecordedReporters(e.contracts[0], game);
        }

        e.status = to;
        emit StatusMoved(id, from, to, reason);
    }

    // ──────────────────────────── Reads ────────────────────────────────

    /// @notice How many entries the list holds. Ids run from 0 to one less than this.
    function entryCount() external view returns (uint256) {
        return s_entries.length;
    }

    /// @notice One entry, every field.
    function getEntry(uint256 id) external view returns (Entry memory) {
        if (id >= s_entries.length) revert OspexSignpost__UnknownEntry(id);
        return s_entries[id];
    }

    // ──────────────────────────── Internal ─────────────────────────────

    function _add(Kind kind, address coin, address[] memory contracts, bytes20 commit, uint64 deployBlock)
        private
        returns (uint256 id)
    {
        uint256 n = contracts.length;
        if (n == 0) revert OspexSignpost__NoContracts();
        bytes32[] memory codeHashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            codeHashes[i] = _codeHashOf(contracts[i]);
        }
        if ((kind == Kind.Games) != (coin == address(0))) revert OspexSignpost__WrongCoin(kind, coin);
        if (coin != address(0)) _codeHashOf(coin);
        if (commit == bytes20(0)) revert OspexSignpost__NoCommit();
        if (deployBlock == 0 || deployBlock > block.number) revert OspexSignpost__WrongDeployBlock(deployBlock);

        id = s_entries.length;
        Entry storage e = s_entries.push();
        e.kind = kind;
        e.coin = coin;
        e.contracts = contracts;
        e.codeHashes = codeHashes;
        e.commit = commit;
        e.deployBlock = deployBlock;
        emit EntryAdded(id, kind, coin, contracts, codeHashes, commit, deployBlock);
    }

    /// @dev The account's code hash. Refuses an account that is not a contract (see {_isContract}).
    function _codeHashOf(address account) private view returns (bytes32) {
        if (!_isContract(account)) revert OspexSignpost__NotAContract(account);
        return account.codehash;
    }

    /// @dev True for an account holding contract code. False for one with no code, and for a wallet that has
    ///      delegated its code (EIP-7702: 23 bytes, starting 0xef0100), whose code its owner can change.
    function _isContract(address account) private view returns (bool) {
        uint256 size = account.code.length;
        return size != 0 && !(size == 23 && bytes3(account.code) == 0xef0100);
    }

    /// @dev Refuses unless `games` answers the reporters read for `game` with at least one reporter and a
    ///      kind for each. An answer too short to hold two lists is refused by name; a longer answer that
    ///      is not two well-formed lists reverts in the decoding. This checks the answer's shape for one
    ///      game. Whether the games contract records each game's reporters at its creation is that
    ///      contract's own rule; the entry's code hashes are what let a reader check which code it is.
    function _requireRecordedReporters(address games, uint256 game) private view {
        (bool ok, bytes memory answer) = games.staticcall(abi.encodeCall(IGameReporters.getGameReporters, (game)));
        if (!ok || answer.length < 128) revert OspexSignpost__ReportersNotRecorded(games, game);
        (address[] memory reporters, uint8[] memory kinds) = abi.decode(answer, (address[], uint8[]));
        if (reporters.length == 0 || reporters.length != kinds.length) {
            revert OspexSignpost__ReportersNotRecorded(games, game);
        }
    }

    /// @dev Refuses a reason holding a line feed or a carriage return.
    function _requireOneLine(string calldata reason) private pure {
        bytes calldata b = bytes(reason);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == 0x0a || b[i] == 0x0d) revert OspexSignpost__ReasonNotOneLine();
        }
    }
}
