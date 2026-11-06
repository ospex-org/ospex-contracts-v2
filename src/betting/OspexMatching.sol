// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IOspexModule} from "./IOspexModule.sol";
import {OspexBetting} from "./OspexBetting.sol";
import {Side} from "./OspexBettingTypes.sol";

/**
 * @title OspexMatching
 * @author ospex.org
 * @notice The matching module of the betting set: the signed order, its hash, the per-order cancel and the
 *         per-line nonce floor. The signed order is the nine-field type v2 signed, with one field renamed: the
 *         game it names is `gameId`, so the typehash is new and no v2 signature is a v3 order. The type's own
 *         name, OspexCommitment, and its other eight field names stay as the spec freezes them.
 *
 *         This contract has no fill path. The Cross, the one route a signed order fills by, in one transaction
 *         sent by a courier every account in it registered, is built with the courier's check, and until then
 *         nothing here calls the positions module. Spec: "How a bet happens".
 *
 *         What is here is a record. A cancel marks an order's hash and a raised floor is stored, each with its
 *         event, and nothing in the set checks an order against either yet: a fill is what does, and the set
 *         has no fill.
 *         The bounds below on an order's price and line, and the two other modules' types, are likewise read
 *         by no function here. The one call this contract makes is to the core's event hub.
 */
contract OspexMatching is IOspexModule, EIP712 {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant MARKET_MODULE = keccak256("MARKET_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");

    // The core event types this module emits through the core's hub. Each payload is the typed event's
    // parameters in the typed event's order.
    bytes32 public constant EVENT_COMMITMENT_CANCELLED = keccak256("COMMITMENT_CANCELLED");
    bytes32 public constant EVENT_MIN_NONCE_UPDATED = keccak256("MIN_NONCE_UPDATED");

    /// @notice EIP-712 typehash for the OspexCommitment struct: the nine fields, the game named `gameId`
    bytes32 public constant COMMITMENT_TYPEHASH = keccak256(
        "OspexCommitment(" "address maker," "uint256 gameId," "address scorer," "int32 lineTicks,"
        "uint8 positionType," "uint16 oddsTick," "uint256 riskAmount," "uint256 nonce," "uint256 expiry" ")"
    );

    /// @notice Odds scale factor (1.91 odds = 191 ticks). The scale is stated in OspexBettingTypes.sol.
    uint16 public constant ODDS_SCALE = 100;
    /// @notice Minimum valid odds (1.01)
    uint16 public constant MIN_ODDS = 101;
    /// @notice Maximum valid odds (101.00)
    uint16 public constant MAX_ODDS = 10100;
    /// @notice Absolute magnitude bound on an order's lineTicks (10x-scaled): 1,000,000, as on the markets module
    int32 public constant MAX_LINE_TICKS = 1_000_000;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when an address other than the maker cancels an order
    error OspexMatching__NotCommitmentMaker();
    /// @notice Thrown when the new minimum nonce is not higher than the current, or is the top value
    error OspexMatching__NonceMustIncrease();
    /// @notice Thrown when the core address is zero
    error OspexMatching__InvalidAddress();

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when a single order is cancelled by its maker
    event CommitmentCancelled(
        bytes32 indexed commitmentHash,
        address indexed maker,
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        Side positionType,
        uint16 oddsTick,
        uint256 riskAmount,
        uint256 nonce,
        uint256 expiry
    );

    /// @notice Emitted when a maker raises their minimum nonce for a market. marketKey is the key the floor is
    ///         stored under: keccak256(abi.encode(gameId, scorer, lineTicks)).
    event MinNonceUpdated(
        address indexed maker,
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        uint256 newMinNonce,
        bytes32 indexed marketKey
    );

    // ──────────────────────────── Structs ──────────────────────────────

    /**
     * @notice A signed order: the nine fields an account, or its approved agent, signs to take a position
     * @param maker The account whose order it is
     * @param gameId The game, in the games set
     * @param scorer The market contract: the moneyline, the spread or the total
     * @param lineTicks The line, scaled by 10: for a spread, the home team's handicap
     * @param positionType The side: 0 for side A, the home team or over; 1 for side B, the away team or under
     * @param oddsTick The price as an integer (193 = 1.93 odds)
     * @param riskAmount The stake, in the coin's smallest unit
     * @param nonce Invalidation threshold, not a unique order id: orders on one market may share a nonce, and
     *              raiseMinNonce() invalidates every order on the market with a nonce below the new minimum
     * @param expiry Unix timestamp after which the order is invalid
     */
    struct OspexCommitment {
        address maker;
        uint256 gameId;
        address scorer;
        int32 lineTicks;
        Side positionType;
        uint16 oddsTick;
        uint256 riskAmount;
        uint256 nonce;
        uint256 expiry;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The core
    OspexBetting public immutable i_ospexCore;

    /// @notice Per-market minimum valid nonce: maker → market key → minimum nonce. The market key is
    ///         keccak256(abi.encode(gameId, scorer, lineTicks)).
    mapping(address => mapping(bytes32 => uint256)) public s_minNonces;
    /// @notice Individually cancelled order hashes
    mapping(bytes32 => bool) public s_cancelledCommitments;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the matching module with EIP-712 domain "Ospex" version "1"
    /// @param core The betting set's core
    constructor(address core) EIP712("Ospex", "1") {
        if (core == address(0)) revert OspexMatching__InvalidAddress();
        i_ospexCore = OspexBetting(core);
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return MATCHING_MODULE;
    }

    // ──────────────────────────── Cancelling ──────────────────────────

    /**
     * @notice Cancel one order by its hash. Only the maker calls it.
     * @dev The mark is on the hash of the nine values under this contract's domain. The call checks that the
     *      caller is the address in the order's maker field, and nothing else about the order: not a
     *      signature, not its expiry. Cancelling an order again marks the same hash and emits again.
     * @param commitment The order to cancel
     */
    function cancelCommitment(OspexCommitment calldata commitment) external {
        if (msg.sender != commitment.maker) revert OspexMatching__NotCommitmentMaker();
        bytes32 commitmentHash = _hashCommitment(commitment);
        s_cancelledCommitments[commitmentHash] = true;

        emit CommitmentCancelled(
            commitmentHash,
            msg.sender,
            commitment.gameId,
            commitment.scorer,
            commitment.lineTicks,
            commitment.positionType,
            commitment.oddsTick,
            commitment.riskAmount,
            commitment.nonce,
            commitment.expiry
        );
        i_ospexCore.emitCoreEvent(
            EVENT_COMMITMENT_CANCELLED,
            abi.encode(
                commitmentHash,
                msg.sender,
                commitment.gameId,
                commitment.scorer,
                commitment.lineTicks,
                commitment.positionType,
                commitment.oddsTick,
                commitment.riskAmount,
                commitment.nonce,
                commitment.expiry
            )
        );
    }

    /**
     * @notice Raise the minimum valid nonce for a market, invalidating every order of the caller on it with a
     *         lower nonce.
     * @dev The scope is one market, the three fields a signed order names it by, whether or not a fill has
     *      drawn that market. Per-order cancellation is cancelCommitment(). The floor only rises, and the top
     *      value, type(uint256).max, is refused, so the floor reaches max - 1 at most: an order whose nonce is
     *      max - 1 or max is never under a floor, and is cancelled only by cancelCommitment(). Both refusals,
     *      a floor that does not rise and the top value, use the one error, NonceMustIncrease.
     * @param gameId The game
     * @param scorer The market contract
     * @param lineTicks The line, scaled by 10
     * @param newMinNonce The new minimum valid nonce: higher than the current one, and not the top value
     */
    function raiseMinNonce(uint256 gameId, address scorer, int32 lineTicks, uint256 newMinNonce) external {
        bytes32 marketKey = keccak256(abi.encode(gameId, scorer, lineTicks));
        if (newMinNonce == type(uint256).max || newMinNonce <= s_minNonces[msg.sender][marketKey]) {
            revert OspexMatching__NonceMustIncrease();
        }
        s_minNonces[msg.sender][marketKey] = newMinNonce;
        emit MinNonceUpdated(msg.sender, gameId, scorer, lineTicks, newMinNonce, marketKey);
        i_ospexCore.emitCoreEvent(
            EVENT_MIN_NONCE_UPDATED, abi.encode(msg.sender, gameId, scorer, lineTicks, newMinNonce, marketKey)
        );
    }

    // ──────────────────────────── Reads ───────────────────────────────

    /// @notice Returns the EIP-712 domain separator
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Computes the hash of an order, for signing off chain
    /// @param commitment The order to hash
    /// @return The EIP-712 typed data hash
    function getCommitmentHash(OspexCommitment calldata commitment) external view returns (bytes32) {
        return _hashCommitment(commitment);
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev The EIP-712 typed data hash of an order: the domain separator over the struct hash
    function _hashCommitment(OspexCommitment calldata commitment) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    COMMITMENT_TYPEHASH,
                    commitment.maker,
                    commitment.gameId,
                    commitment.scorer,
                    commitment.lineTicks,
                    uint8(commitment.positionType),
                    commitment.oddsTick,
                    commitment.riskAmount,
                    commitment.nonce,
                    commitment.expiry
                )
            )
        );
    }
}
