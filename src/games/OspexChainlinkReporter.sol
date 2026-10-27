// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOspexGames, Report, ReportKind} from "./IOspexGames.sol";
import {IOspexReporter} from "./IOspexReporter.sol";
import {IReceiver} from "../interfaces/cre/IReceiver.sol";
import {IERC165} from "../interfaces/cre/IERC165.sol";

/**
 * @title OspexChainlinkReporter
 * @author ospex.org
 * @notice The Chainlink reporter of Ospex v3's games set. The games set knows nothing of Chainlink: Chainlink
 *         sits in this one small contract, which takes a report from Chainlink's forwarder and passes it on to
 *         the games set in the one report shape every reporter uses. Its forwarder, its workflow owner, its
 *         workflow id and the games set's address are fixed when it is deployed and never change: it has no
 *         owner, no setter and no storage, and it is not a proxy. If Chainlink moves, a new reporter is
 *         approved and the games set stays. The design is docs/spec-v3.md, "The Chainlink reporter".
 *
 *         What it checks. The forwarder is the only address that may call onReport (NotTheForwarder). The
 *         forwarder hands over the report's metadata, 64 bytes on a live report: the workflow id, a hash of
 *         the workflow's name, the workflow owner and a two-byte report id. The report is taken only when the
 *         metadata's owner and id are the two fixed here; a report from any other workflow, or from the same
 *         workflow under another owner, is refused with nothing written (NotTheWorkflowOwner,
 *         NotTheWorkflowId). The id is a hash of the workflow's owner, name, compiled program and config, so a
 *         changed program, a changed config or a changed owner is a new id, which this reporter refuses: a new
 *         build of the scoring program is a new reporter and a new approval. The name is inside the id and is
 *         not read on its own.
 *
 *         What it passes on. The report is the games set's Report, ABI-encoded by the workflow, decoded here
 *         and handed to the games set's one report call as decoded: the game, the kind, the start, the scores,
 *         the readings and the payout address. The bytes received must be the one shape's own encoding of what
 *         was decoded: the decoded report is encoded again and compared with the bytes received, so a report in
 *         any other shape that happens to decode (a field more, a wider reading, an outer tuple) is refused by
 *         name (NotTheOneShape), and so is one the decoder refuses. The payout address rides in the report,
 *         which only the forwarder delivers; this contract never puts its caller, the transaction's sender or
 *         itself in its place, and holds no payout address of its own. Whether the report is taken is the
 *         games set's to decide: every refusal there reverts through here, so a refused report writes nothing
 *         in this contract or the games set. The forwarder itself records the delivery, taken or refused,
 *         without reverting its own transaction, so a score is confirmed by reading the game, not the
 *         transaction.
 *
 *         What it holds. Nothing: no coin and no credit. The games set refuses every reporter as a payout
 *         address, this one included, and nothing here calls the games set's withdraw. It emits one event for
 *         each report it passes on; the games set emits the report itself.
 *
 * @dev    The metadata is read as today's live reports carry it: the id at bytes 0 to 32, the name at 32 to
 *         42, the owner at 42 to 62, the report id at 62 to 64. Shorter metadata is refused; longer metadata
 *         is read the same and its tail ignored. The forwarder checks ERC-165 for IReceiver before it calls,
 *         and calls with the gas it allots to the receiver.
 *
 *         Fixed at deploy. The games set's address is fixed before the games set exists: on deploy day the
 *         reporter is deployed first, at an address predicted from the deployer's nonce, so the workflow's
 *         config can name it, and the games set is deployed after, at the address this reporter was given.
 */
contract OspexChainlinkReporter is IOspexReporter, IReceiver {
    // ──────────────────────────── Constants ────────────────────────────

    /// @notice The metadata the forwarder hands over with a live report: the workflow id (32 bytes), the hash
    ///         of the workflow's name (10), the workflow owner (20) and the report id (2). Shorter is refused.
    uint256 public constant METADATA_LENGTH = 64;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the constructor's forwarder has no code
    error OspexChainlinkReporter__ForwarderNotAContract(address forwarder);
    /// @notice Thrown when the constructor's workflow owner is the zero address
    error OspexChainlinkReporter__NoWorkflowOwner();
    /// @notice Thrown when the constructor's workflow id is zero
    error OspexChainlinkReporter__NoWorkflowId();
    /// @notice Thrown when the constructor's games set is the zero address
    error OspexChainlinkReporter__NoGames();
    /// @notice Thrown when anything but the forwarder calls onReport
    error OspexChainlinkReporter__NotTheForwarder(address sender);
    /// @notice Thrown when the metadata is shorter than a live report's
    error OspexChainlinkReporter__MetadataTooShort(uint256 length);
    /// @notice Thrown when the metadata names a workflow owner other than the one fixed at deploy
    error OspexChainlinkReporter__NotTheWorkflowOwner(address found);
    /// @notice Thrown when the metadata names a workflow id other than the one fixed at deploy
    error OspexChainlinkReporter__NotTheWorkflowId(bytes32 found);
    /// @notice Thrown when the report's bytes are not the one shape's encoding of what they decode to
    error OspexChainlinkReporter__NotTheOneShape(uint256 received, uint256 encoded);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted for every report this contract passes on, after the games set has taken it. The games
    ///         set's own event carries the whole report; this one ties it to the forwarder's report id.
    /// @param gameId The game the report names
    /// @param kind What the report is
    /// @param reportId The two-byte report id from the forwarder's metadata
    /// @param payout The payout address as the report carried it
    event ReportRelayed(uint256 indexed gameId, ReportKind indexed kind, bytes2 reportId, address payout);

    // ──────────────────────────── Immutables ───────────────────────────

    /// @notice Chainlink's forwarder on this chain: the only address that may call onReport
    address public immutable i_forwarder;
    /// @notice The workflow owner every report's metadata must name
    address public immutable i_workflowOwner;
    /// @notice The workflow id every report's metadata must name: the fingerprint of one build of the scoring
    ///         program, under one owner, with one config
    bytes32 public immutable i_workflowId;
    /// @notice The games set every report is passed on to
    IOspexGames public immutable i_games;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @param forwarder Chainlink's forwarder on this chain. A contract, and not a wallet with delegated code
    ///        (EIP-7702), whose code its owner can change; the same check the games set makes.
    /// @param workflowOwner The workflow owner. Not zero.
    /// @param workflowId The workflow id. Not zero.
    /// @param games The games set, at the address it will have: predicted from the deployer's nonce when this
    ///        contract is deployed first, as the deploy script does. Not zero; not checked for code, since on
    ///        deploy day it does not exist yet.
    constructor(address forwarder, address workflowOwner, bytes32 workflowId, IOspexGames games) {
        if (forwarder.code.length == 0 || _isDelegated(forwarder)) {
            revert OspexChainlinkReporter__ForwarderNotAContract(forwarder);
        }
        if (workflowOwner == address(0)) revert OspexChainlinkReporter__NoWorkflowOwner();
        if (workflowId == bytes32(0)) revert OspexChainlinkReporter__NoWorkflowId();
        if (address(games) == address(0)) revert OspexChainlinkReporter__NoGames();
        i_forwarder = forwarder;
        i_workflowOwner = workflowOwner;
        i_workflowId = workflowId;
        i_games = games;
    }

    // ──────────────────────────── The forwarder's call ─────────────────

    /// @inheritdoc IReceiver
    /// @dev The sender is checked first, then the metadata's length, its owner and its id, then the report is
    ///      decoded, encoded again and compared with the bytes received, and passed on. Every refusal reverts,
    ///      here or in the games set, so a refused report writes nothing in this contract or the games set;
    ///      what the forwarder records of a refused delivery is the forwarder's. The event follows the games
    ///      set's call, so it is emitted only for a report the games set took.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (msg.sender != i_forwarder) revert OspexChainlinkReporter__NotTheForwarder(msg.sender);
        if (metadata.length < METADATA_LENGTH) revert OspexChainlinkReporter__MetadataTooShort(metadata.length);
        address workflowOwner = address(bytes20(metadata[42:62]));
        if (workflowOwner != i_workflowOwner) revert OspexChainlinkReporter__NotTheWorkflowOwner(workflowOwner);
        bytes32 workflowId = bytes32(metadata[0:32]);
        if (workflowId != i_workflowId) revert OspexChainlinkReporter__NotTheWorkflowId(workflowId);

        Report memory r = abi.decode(report, (Report));
        bytes memory encoded = abi.encode(r);
        if (encoded.length != report.length || keccak256(encoded) != keccak256(report)) {
            revert OspexChainlinkReporter__NotTheOneShape(report.length, encoded.length);
        }
        i_games.report(r);
        emit ReportRelayed(r.gameId, r.kind, bytes2(metadata[62:64]), r.payout);
    }

    // ──────────────────────────── The reads ────────────────────────────

    /// @inheritdoc IOspexReporter
    /// @dev `abi.encode(address forwarder, address workflowOwner, bytes32 workflowId)`, as IOspexReporter
    ///      documents for the launch reporter. The games set emits it at this reporter's approval.
    function fixedValues() external view override returns (bytes memory) {
        return abi.encode(i_forwarder, i_workflowOwner, i_workflowId);
    }

    /// @inheritdoc IERC165
    /// @dev The forwarder calls this before onReport, and routes nothing to a receiver that does not answer
    ///      for IReceiver.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    /// @dev True when the account's code is a wallet's delegation (EIP-7702): 23 bytes, 0xef0100 and an address.
    function _isDelegated(address account) private view returns (bool) {
        return account.code.length == 23 && bytes3(account.code) == 0xef0100;
    }
}
