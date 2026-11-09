// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexMatching} from "./OspexMatching.sol";

/**
 * @title OspexCourierRelay
 * @author ospex.org
 * @notice The Ospex courier's address on chain: the address an account registers as its courier on the matching
 *         contract. It is a relay and not a key. It passes a Cross through to the matching contract from its one
 *         sender, and the Polygon timelock sets that sender, so the key that sends can be replaced and nothing
 *         any account registered changes. It is deployed beside the betting set and is not a module of its core.
 *         Spec: item 21 of the first milestone, with items 1, 5 and 6.
 *
 *         The pass-through. cross(taking, resting) is declared with the matching contract's own types, so its
 *         selector is the matching contract's. Only s_sender may call it. The relay hands the call's bytes to
 *         the matching contract as they arrived. It reads no order and no signature, and checks nothing about
 *         them but what the compiler checks at the entry of any function of this shape: that the two
 *         arguments' offsets and the list's length lie within the call, which the matching contract's own
 *         entry checks of the same bytes. The matching contract decodes them, checks each signature under its
 *         own domain, and sees this contract as the Cross's sender, its courier.
 *         A Cross that succeeds returns nothing. A Cross the matching contract refuses reverts here with the
 *         refusal's data whole.
 *
 *         The sender. One address, set when this contract is deployed and changed only by setSender, which only
 *         the timelock may call, after its delay, and never to zero. Each change emits SenderSet.
 *
 *         The timelock. Read once, in the constructor, from the matching contract, which read it from the games
 *         set at its own deploy. It is kept, and no function changes it.
 *
 *         No coin. No function here moves a coin or takes native money: the relay pulls nothing, holds nothing
 *         for anyone and pays nothing. The positions contract pulls each stake from the account that signed for
 *         it. A token sent to this address unasked is not prevented and has no way out.
 */
contract OspexCourierRelay {
    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown by the constructor when the matching address has no code, or has only a wallet's delegation
    error OspexCourierRelay__MatchingNotAContract(address matching);
    /// @notice Thrown by the constructor when the timelock the matching contract answers has no code, or has
    ///         only a wallet's delegation. The zero address has no code.
    error OspexCourierRelay__TimelockNotAContract(address timelock);
    /// @notice Thrown by the constructor and by setSender when the sender to set is the zero address
    error OspexCourierRelay__ZeroSender();
    /// @notice Thrown by cross when the caller is not the sender
    error OspexCourierRelay__NotTheSender(address caller);
    /// @notice Thrown by setSender when the caller is not the timelock
    error OspexCourierRelay__NotTheTimelock(address caller);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when the sender is set: once by the constructor, with the zero address as `previous`, and
    ///         by every setSender after it, also when `current` is the address it already was
    /// @param previous The sender until this change
    /// @param current The sender from this change
    event SenderSet(address indexed previous, address indexed current);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The matching contract of the betting set: the one address this contract calls
    address public immutable i_matching;
    /// @notice The timelock: the one address that may set the sender. It is the matching contract's own, read
    ///         from it when this contract was deployed.
    address public immutable i_timelock;
    /// @notice The sender: the one address that may send a Cross through this contract
    address public s_sender;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the relay against a matching contract, reads the timelock from it once, and sets the
    ///         first sender
    /// @dev The matching address and the timelock it answers each get the check the games set makes on its own
    ///      timelock: a contract, and not a wallet's delegation. The matching address is checked before it is
    ///      asked for its timelock. A read that fails, or that answers anything but an address, fails the
    ///      deploy: nothing is taken as the timelock in its place. These checks say nothing of which betting
    ///      set the matching address belongs to; the deploy's own checks do.
    /// @param matching The betting set's matching contract
    /// @param sender The first sender
    constructor(address matching, address sender) {
        if (matching.code.length == 0 || _isDelegated(matching)) {
            revert OspexCourierRelay__MatchingNotAContract(matching);
        }
        address timelock = OspexMatching(matching).i_timelock();
        if (timelock.code.length == 0 || _isDelegated(timelock)) {
            revert OspexCourierRelay__TimelockNotAContract(timelock);
        }
        if (sender == address(0)) revert OspexCourierRelay__ZeroSender();
        i_matching = matching;
        i_timelock = timelock;
        s_sender = sender;
        emit SenderSet(address(0), sender);
    }

    // ──────────────────────────── The Cross ────────────────────────────

    /**
     * @notice Send a Cross through to the matching contract. Only the sender calls it.
     * @dev The caller is msg.sender, the immediate caller, and never tx.origin. The call's bytes are handed to
     *      the matching contract as they arrived, selector included, with no value. The two arguments are
     *      declared so that this function's selector and ABI are the matching contract's own, and no field of
     *      them is read here. The compiler's entry check for a function of this shape runs first, before the
     *      caller's check: bytes whose two offsets, or whose list's length, do not lie within the call revert
     *      here with no data, as they would at the matching contract's own entry. Nothing else about them is
     *      checked here: the matching contract is the decoder and the validator of the same bytes.
     *
     *      Nothing is returned when the Cross succeeds, as the matching contract's Cross returns nothing. When
     *      the matching contract reverts, this call reverts with the same data, whatever its length.
     *
     *      No exclusion is kept here. The sender is read before the call, so a setSender run while a Cross is in
     *      progress, by an account's code that a coin calls during a pull and that runs a ready timelock
     *      operation, changes the sender for the next call and leaves the Cross in progress as it was. The
     *      matching contract keeps its own exclusion over the Cross.
     *
     *      The first argument is the taking order and its signature; the second, the resting orders, each with
     *      its signature, in the order they are to fill.
     */
    function cross(OspexMatching.SignedOrder calldata, OspexMatching.SignedOrder[] calldata) external {
        if (msg.sender != s_sender) revert OspexCourierRelay__NotTheSender(msg.sender);
        (bool ok, bytes memory refusal) = i_matching.call(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(refusal, 0x20), mload(refusal))
            }
        }
    }

    // ──────────────────────────── The sender ───────────────────────────

    /**
     * @notice Set the sender. Only the timelock calls it.
     * @dev The caller is msg.sender, which must be i_timelock, so a change of the sender waits the timelock's
     *      delay and is public while it waits, and the key that holds the timelock is refused here like any
     *      other address. The caller is checked before the address to set. Zero is refused: this sets a sender,
     *      and does not stop the relay. Nothing else is asked of `next`, and setting the address the sender
     *      already is changes nothing but the event. No account's registration of this contract changes.
     * @param next The sender from this call
     */
    function setSender(address next) external {
        if (msg.sender != i_timelock) revert OspexCourierRelay__NotTheTimelock(msg.sender);
        if (next == address(0)) revert OspexCourierRelay__ZeroSender();
        emit SenderSet(s_sender, next);
        s_sender = next;
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev True when the account's code is a wallet's delegation (EIP-7702): 23 bytes, 0xef0100 and an address.
    ///      The games set's own check.
    function _isDelegated(address account) private view returns (bool) {
        return account.code.length == 23 && bytes3(account.code) == 0xef0100;
    }
}
