// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {TestCoin, TrickCoin} from "../games/CoinFixtures.sol";
import {CrossBase} from "./CrossBase.sol";
import {CallbackAccount} from "./CrossFixtures.sol";

// The courier relay's tests: never-lines 27 to 31 and the tests beside them, in four test contracts with a setUp
// each. Above each test, "Breaks:" names the changes to src/betting/OspexCourierRelay.sol that turn it red, each an
// entry of battery.json. Three addresses are kept apart throughout. K is the key that holds the timelock: the one
// proposer and canceller of the stock timelock the games base deploys, `timelockKey` here. The timelock is that
// contract, whose executor is open. The key, `courierKey`, is the relay's sender. Amounts are literals worked out
// by hand: a one-cent taking order at 1.90 against 10,000 resting at 2.10 fills 90 lots, 9,000 of resting stake
// against 9,900 of taking stake.

/// @dev A caller that is a contract: it hands on the bytes it is given, and a refusal comes back unchanged. For a
///      call whose origin is one address and whose immediate caller is another.
contract HandingCaller {
    function send(address target, bytes calldata data) external {
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}

/// @dev The answering target: what a relay is deployed against where the read of the timelock is the subject. It
///      answers every call, the read of `i_timelock()` among them, with the bytes a test scripted, raw, as a
///      return or as a revert: an address, a short answer, a word that is not an address, a refusal.
contract AnsweringTarget {
    bool internal reverts;
    bytes internal answer;

    function script(bool reverts_, bytes calldata answer_) external {
        reverts = reverts_;
        answer = answer_;
    }

    fallback() external {
        bytes memory a = answer;
        bool r = reverts;
        assembly ("memory-safe") {
            if r { revert(add(a, 0x20), mload(a)) }
            return(add(a, 0x20), mload(a))
        }
    }
}

/// @dev The scripted target: what a relay is deployed against where the call's bytes and the refusal's bytes are
///      the subject. It has a working `i_timelock()`. Any other call either reverts with the bytes a test
///      scripted, or is recorded whole, its calldata and its caller, counted, and answered with the bytes scripted.
contract ScriptedTarget {
    address public i_timelock;
    bool internal reverts;
    bytes internal answer;
    bytes public lastData;
    address public lastCaller;
    uint256 public calls;

    constructor(address timelock) {
        i_timelock = timelock;
    }

    function script(bool reverts_, bytes calldata answer_) external {
        reverts = reverts_;
        answer = answer_;
    }

    fallback() external {
        bytes memory a = answer;
        if (reverts) {
            assembly ("memory-safe") {
                revert(add(a, 0x20), mload(a))
            }
        }
        lastData = msg.data;
        lastCaller = msg.sender;
        ++calls;
        assembly ("memory-safe") {
            return(add(a, 0x20), mload(a))
        }
    }
}

/// @dev What the relay's tests share: the set with the cap in force, as at launch; the relay on its matching
///      contract with `courierKey` as its first sender; and two accounts, each a key, that registered the relay and
///      nothing else.
abstract contract RelayBase is CrossBase {
    /// @dev The first topics of the relay's event, of the matching contract's two courier events and of the coin's
    ///      transfer, each the hash of its signature written out.
    bytes32 internal constant SENDER_SET_TOPIC = keccak256("SenderSet(address,address)");
    bytes32 internal constant COURIER_REGISTERED_TOPIC = keccak256("CourierRegistered(address,address)");
    bytes32 internal constant COURIER_UNREGISTERED_TOPIC = keccak256("CourierUnregistered(address,address)");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    OspexCourierRelay internal relay;
    /// @dev The key: the relay's first sender.
    address internal courierKey = makeAddr("the courier's key");
    /// @dev The key a rotation sets.
    address internal newKey = makeAddr("the courier's next key");
    /// @dev The resting account and the taking account of most tests.
    Signer internal mk;
    Signer internal tk;

    function setUp() public virtual override {
        liftAtDeploy = false;
        super.setUp();
        relay = _deployRelay(address(matching), courierKey);
        mk = _account("resting account");
        tk = _account("taking account");
        _register(mk.a, address(relay));
        _register(tk.a, address(relay));
    }

    // ──────────────────────────── The relay ────────────────────────────

    /// @dev A relay on `target` with `key` as its first sender, deployed by the set's deployer.
    function _deployRelay(address target, address key) internal returns (OspexCourierRelay made) {
        vm.prank(deployer, deployer);
        made = new OspexCourierRelay(target, key);
    }

    /// @dev The setter's calldata.
    function _setSender(address next) internal pure returns (bytes memory) {
        return abi.encodeCall(OspexCourierRelay.setSender, (next));
    }

    /// @dev A Cross's calldata, as the compiler encodes it: the bytes a sender sends.
    function _crossData(OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(OspexMatching.cross, (taking, resting));
    }

    /// @dev `from` sends `data` to a relay, with the transaction's origin named, and the result.
    function _tryRelayOn(OspexCourierRelay on, address from, address origin, bytes memory data)
        internal
        returns (bool ok, bytes memory out)
    {
        vm.prank(from, origin);
        (ok, out) = address(on).call(data);
    }

    /// @dev The same, to the set's relay.
    function _tryRelay(address from, address origin, bytes memory data) internal returns (bool ok, bytes memory out) {
        return _tryRelayOn(relay, from, origin, data);
    }

    /// @dev A Cross through the relay that must fill, sent by `from` as caller and origin. It returns nothing.
    function _relayed(address from, OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
        internal
    {
        (bool ok, bytes memory out) = _tryRelay(from, from, _crossData(taking, resting));
        assertTrue(ok, string.concat("the Cross through the relay was refused: ", vm.toString(out)));
        assertEq(out.length, 0, "the relay returned a value");
    }

    /// @dev The reference call: the same bytes sent to the matching contract from the relay's own address, so
    ///      that the matching contract sees the sender it sees through the relay.
    function _tryAsRelay(address origin, bytes memory data) internal returns (bool ok, bytes memory out) {
        vm.prank(address(relay), origin);
        (ok, out) = address(matching).call(data);
    }

    /// @dev A refusal of the matching contract, through the relay: the bytes equal `want`, a literal, and equal
    ///      those of the reference call from the relay's own address.
    function _sameRefusal(bytes memory data, bytes memory want, string memory what) internal {
        (bool okRef, bytes memory fromRelay) = _tryAsRelay(courierKey, data);
        assertFalse(okRef, string.concat(what, ": the reference call filled"));
        assertEq(fromRelay, want, string.concat(what, ": the reference call's refusal"));
        (bool ok, bytes memory got) = _tryRelay(courierKey, courierKey, data);
        assertFalse(ok, string.concat(what, ": filled through the relay"));
        assertEq(got, want, string.concat(what, ": the refusal through the relay"));
    }

    // ──────────────────────────── Orders and state ─────────────────────

    /// @dev One cent on a game's moneyline: the resting account rests 10,000 at 2.10 on the other side, and the
    ///      taking account takes 10,000 at 1.90 on `takingSide`. Filled, it is 9,000 against 9,900.
    function _oneCent(uint256 game, Side takingSide)
        internal
        returns (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking)
    {
        resting = _rest(mk, game, _other(takingSide), 210, 10_000);
        taking = _take(tk, game, takingSide, 190, 10_000);
    }

    /// @dev One cent through the relay from `from`, filled: 9,000 against 9,900.
    function _fillsOneCent(address from, uint256 game, Side takingSide) internal {
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(game, takingSide);
        _relayed(from, taking, _list(resting));
        assertEq(_filled(resting), 9_000, "the resting order's filled amount");
        assertEq(_filled(taking), 9_900, "the taking order's filled amount");
    }

    /// @dev Everything a Cross can move for the two accounts, the relay and the two keys, and two orders' filled
    ///      amounts.
    function _print(OspexMatching.SignedOrder memory a, OspexMatching.SignedOrder memory b)
        internal
        view
        returns (bytes32)
    {
        address[] memory who = new address[](5);
        who[0] = mk.a;
        who[1] = tk.a;
        who[2] = address(relay);
        who[3] = courierKey;
        who[4] = newKey;
        bytes32[] memory orders = new bytes32[](2);
        orders[0] = _hash(a);
        orders[1] = _hash(b);
        return _fingerprint(who, orders);
    }

    /// @dev What the two accounts registered: the relay, and neither key; and the relay itself registered no one.
    function _assertRegistrations(string memory when) internal view {
        assertTrue(matching.isCourier(mk.a, address(relay)), string.concat(when, ": the resting account's relay"));
        assertTrue(matching.isCourier(tk.a, address(relay)), string.concat(when, ": the taking account's relay"));
        address[2] memory keys = [courierKey, newKey];
        for (uint256 i; i < keys.length; ++i) {
            assertFalse(matching.isCourier(mk.a, keys[i]), string.concat(when, ": the resting account has a key"));
            assertFalse(matching.isCourier(tk.a, keys[i]), string.concat(when, ": the taking account has a key"));
            assertFalse(matching.isCourier(address(relay), keys[i]), string.concat(when, ": the relay has a courier"));
        }
    }

    /// @dev Scores a game now, or one second after its start if that is still ahead.
    function _scoreNow(uint256 game, uint32 home, uint32 away) internal {
        if (vm.getBlockTimestamp() < START + 1) vm.warp(START + 1);
        _scoreBy(first, game, home, away);
    }

    // ──────────────────────────── The timelock ─────────────────────────

    /// @dev K schedules `call` on the relay under a fresh salt, at the delay; the operation's id and its salt.
    function _schedule(bytes memory call) internal returns (bytes32 id, bytes32 s) {
        s = bytes32(++salt);
        vm.prank(timelockKey);
        timelock.schedule(address(relay), 0, call, bytes32(0), s, DELAY);
        id = timelock.hashOperation(address(relay), 0, call, bytes32(0), s);
    }

    /// @dev A stranger's run of a scheduled call on the relay, which must fail with exactly `want`.
    function _executeRefused(bytes memory call, bytes32 s, bytes memory want, string memory what) internal {
        vm.prank(stranger);
        (bool ok, bytes memory err) =
            address(timelock).call(abi.encodeCall(TimelockController.execute, (address(relay), 0, call, bytes32(0), s)));
        assertFalse(ok, string.concat(what, ": the operation ran"));
        assertEq(err, want, what);
    }

    /// @dev A rotation as it runs live: K schedules it on the stock timelock, the delay passes, a stranger runs it.
    function _rotate(address next) internal {
        _throughTimelockTo(address(relay), _setSender(next));
        assertEq(relay.s_sender(), next, "the rotation did not set the sender");
    }

    // ──────────────────────────── Logs ─────────────────────────────────

    /// @dev A call's logs are one, the relay's event, with these two addresses, read as literals.
    function _assertOneSenderSet(Vm.Log[] memory logs, address emitter, address previous, address current)
        internal
        pure
    {
        assertEq(logs.length, 1, "the logs of a set sender");
        assertEq(logs[0].emitter, emitter, "the event's emitter");
        assertEq(logs[0].topics.length, 3, "the event's topics");
        assertEq(logs[0].topics[0], SENDER_SET_TOPIC, "the event's first topic");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(previous))), "the event's previous sender");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(current))), "the event's current sender");
        assertEq(logs[0].data.length, 0, "the event's data");
    }

    /// @dev How many of a call's logs `emitter` emitted.
    function _countOf(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++n;
        }
    }

    // ──────────────────────────── Bytes ────────────────────────────────

    /// @dev `n` bytes of hash output, different for each seed: no two scripted answers are alike, and none is a
    ///      run of one byte.
    function _noise(uint256 n, uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(n);
        bytes32 word;
        for (uint256 i; i < n; ++i) {
            if (i % 32 == 0) word = keccak256(abi.encode("the relay's tests", seed, i / 32));
            out[i] = word[i % 32];
        }
    }

    /// @dev The bytes of `b` from `from` up to `to`.
    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = b[i];
        }
    }

    /// @dev The parts of a Cross's calldata as the compiler encodes it: the selector, and the two arguments'
    ///      tails, the taking order's first.
    function _parts(bytes memory canonical)
        internal
        pure
        returns (bytes memory selector, bytes memory takingTail, bytes memory restingTail)
    {
        selector = _slice(canonical, 0, 4);
        (uint256 toTaking, uint256 toResting) = abi.decode(_slice(canonical, 4, 68), (uint256, uint256));
        assertEq(toTaking, 0x40, "the compiler's encoding does not start its first tail after the head");
        takingTail = _slice(canonical, 4 + toTaking, 4 + toResting);
        restingTail = _slice(canonical, 4 + toResting, canonical.length);
    }

    /// @dev The same call with `gap` between the head and the tails, and the two offsets moved to match.
    function _gapped(bytes memory canonical, bytes memory gap) internal pure returns (bytes memory) {
        (bytes memory selector, bytes memory takingTail, bytes memory restingTail) = _parts(canonical);
        return bytes.concat(
            selector, abi.encode(0x40 + gap.length, 0x40 + gap.length + takingTail.length), gap, takingTail, restingTail
        );
    }

    /// @dev The same call with its two tails in the other order, and the two offsets to match.
    function _swapped(bytes memory canonical) internal pure returns (bytes memory) {
        (bytes memory selector, bytes memory takingTail, bytes memory restingTail) = _parts(canonical);
        return bytes.concat(selector, abi.encode(0x40 + restingTail.length, uint256(0x40)), restingTail, takingTail);
    }
}

/// @notice Never-lines 27, 29, 30 on the real set, and 31, with the end-to-end test and the gas beside them.
contract OspexCourierRelayTest is RelayBase {
    // ──────────────────────────── 27 ────────────────────

    /// Only the sender passes a Cross through. The key's Cross fills, the matching contract's record naming the
    /// relay as its courier, and it leaves what the same bytes leave when they are sent to the matching contract
    /// from the relay's own address: the two runs differ in the relay's code alone. Anyone else is refused by
    /// name, whoever the transaction's origin is.
    /// Breaks: in OspexCourierRelay.cross, delete the sender's check; compare tx.origin with the sender in place
    /// of msg.sender; let the timelock send too, `msg.sender != s_sender && msg.sender != i_timelock`.
    function test_neverLine_onlyTheSenderPassesACrossThrough() public {
        assertEq(relay.s_sender(), courierKey, "the first sender");
        assertEq(relay.i_matching(), address(matching), "the relay's target");
        _assertRegistrations("at the start");
        uint256 game = _verifiedGame();
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(game, Side.B);
        bytes memory data = _crossData(taking, _list(resting));

        // The reference, in a snapshot: the same bytes from the relay's own address, under the same origin.
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        (bool okRef, bytes memory outRef) = _tryAsRelay(courierKey, data);
        Vm.Log[] memory refLogs = vm.getRecordedLogs();
        assertTrue(okRef, "the reference Cross was refused");
        assertEq(outRef.length, 0, "the reference Cross returned a value");
        assertEq(_filled(taking), 9_900, "the reference Cross did not fill");
        bytes32 printRef = _print(resting, taking);
        assertTrue(vm.revertToState(snap), "the snapshot was not taken back");
        assertEq(_filled(taking), 0, "the reference Cross was left in place");

        // Through the relay, from the key.
        vm.recordLogs();
        (bool ok, bytes memory out) = _tryRelay(courierKey, courierKey, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, string.concat("the key's Cross was refused: ", vm.toString(out)));
        assertEq(out.length, 0, "the relay returned a value");
        assertEq(_print(resting, taking), printRef, "through the relay, the state is not the reference's");
        assertEq(logs.length, refLogs.length, "through the relay, the logs are not as many as the reference's");
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, refLogs[i].emitter, "a log's emitter differs from the reference's");
            assertEq(logs[i].topics.length, refLogs[i].topics.length, "a log's topics differ in number");
            for (uint256 j; j < logs[i].topics.length; ++j) {
                assertEq(logs[i].topics[j], refLogs[i].topics[j], "a log's topic differs from the reference's");
            }
            assertEq(logs[i].data, refLogs[i].data, "a log's data differs from the reference's");
        }
        assertEq(_countOf(logs, address(relay)), 0, "the relay emitted during a Cross");
        _assertCrossedBy(logs, taking);
        _assertOneCentFilled(game, resting, taking);
        assertEq(_coin().balanceOf(address(relay)), 0, "the relay holds coin");
        assertEq(_coin().balanceOf(courierKey), 0, "the key holds coin");

        // The key's Cross under another origin fills too: the relay reads its caller, not the origin.
        uint256 other = _verifiedGame();
        (resting, taking) = _oneCent(other, Side.A);
        (ok, out) = _tryRelay(courierKey, crossOrigin, _crossData(taking, _list(resting)));
        assertTrue(ok, "the key's Cross under another origin was refused");
        assertEq(_filled(taking), 9_900, "the key's Cross under another origin did not fill");

        // Anyone else: refused by name, and nothing filled.
        uint256 third = _verifiedGame();
        (resting, taking) = _oneCent(third, Side.B);
        data = _crossData(taking, _list(resting));
        bytes32 before = _print(resting, taking);
        HandingCaller handing = new HandingCaller();
        address[11] memory callers = [
            stranger,
            timelockKey,
            address(timelock),
            deployer,
            mk.a,
            tk.a,
            address(matching),
            address(core),
            address(positions),
            address(relay),
            newKey
        ];
        for (uint256 i; i < callers.length; ++i) {
            (ok, out) = _tryRelay(callers[i], callers[i], data);
            assertFalse(ok, string.concat("the relay passed a Cross from ", vm.toString(callers[i])));
            assertEq(out, _notTheSender(callers[i]), "the refusal of a caller that is not the sender");
        }
        // The key as the origin is not the key calling: a stranger, and a contract the key calls.
        (ok, out) = _tryRelay(stranger, courierKey, data);
        assertFalse(ok, "the relay passed a stranger's Cross with the key as the origin");
        assertEq(out, _notTheSender(stranger), "the refusal with the key as the origin");
        vm.prank(courierKey, courierKey);
        (ok, out) = address(handing).call(abi.encodeCall(HandingCaller.send, (address(relay), data)));
        assertFalse(ok, "the relay passed a Cross from a contract the key called");
        assertEq(out, _notTheSender(address(handing)), "the refusal of a contract the key called");
        assertEq(_print(resting, taking), before, "a refused sender moved something");
        assertEq(_filled(taking), 0, "a refused sender's Cross filled");

        // The same bytes from the key fill: what was refused was the caller, not the Cross.
        (ok, out) = _tryRelay(courierKey, courierKey, data);
        assertTrue(ok, "the bytes the others were refused with did not fill from the key");
        assertEq(_filled(taking), 9_900, "the key's Cross of the refused bytes");
    }

    function _notTheSender(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheSender.selector, caller);
    }

    /// @dev Among a Cross's logs the matching contract's record is one, and it names the relay as the courier, the
    ///      taking order and the taking account.
    function _assertCrossedBy(Vm.Log[] memory logs, OspexMatching.SignedOrder memory taking) internal view {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(matching) || logs[i].topics[0] != CROSSED_TOPIC) continue;
            ++n;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(relay)))), "the Cross's courier");
            assertEq(logs[i].topics[2], _hash(taking), "the Cross's taking order");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(taking.order.account))), "the Cross's taking account");
        }
        assertEq(n, 1, "the Cross's records");
    }

    /// @dev One cent filled on a game's moneyline, the first fill of its two accounts: every amount to the unit.
    function _assertOneCentFilled(
        uint256 game,
        OspexMatching.SignedOrder memory resting,
        OspexMatching.SignedOrder memory taking
    ) internal view {
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(_filled(resting), 9_000, "the resting order's filled amount");
        assertEq(_filled(taking), 9_900, "the taking order's filled amount");
        assertEq(_coin().balanceOf(mk.a), PURSE - 9_000, "the resting account paid its own stake");
        assertEq(_coin().balanceOf(tk.a), PURSE - 9_900, "the taking account paid its own stake");
        assertEq(_coin().balanceOf(address(positions)), 18_900, "the positions contract holds the two stakes");
        _assertPosition(market, mk.a, resting.order.positionType, 9_000, 9_900, "the resting account's position");
        _assertPosition(market, tk.a, taking.order.positionType, 9_900, 9_000, "the taking account's position");
    }

    // ──────────────────────────── 29 ────────────────────

    /// A rotation changes no registration. Accounts that registered the relay before a real delayed rotation fill
    /// after it, with no call of theirs between: what each registered reads the same, the rotation's logs are the
    /// timelock's and the relay's one, and the same two accounts' fresh orders fill through the new key, settle and
    /// pay on both sides. After it the old key, a stranger and K are refused at the relay, and K is refused at the
    /// matching contract too, which no account named it to.
    /// Breaks: in OspexCourierRelay.cross, make the forward a delegatecall; in setSender, also register the new
    /// sender on the matching contract, `OspexMatching(i_matching).registerCourier(next);`.
    function test_neverLine_aRotationChangesNoRegistration() public {
        uint256 gameOne = _verifiedGame();
        uint256 gameTwo = _verifiedGame();
        _assertRegistrations("before the rotation");
        // Accounts that registered the relay, and no key, fill through it.
        _fillsOneCent(courierKey, gameOne, Side.B);

        vm.recordLogs();
        _rotate(newKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(relay)) continue;
            assertEq(logs[i].emitter, address(timelock), "the rotation made a contract of the set emit");
            assertTrue(
                logs[i].topics[0] != COURIER_REGISTERED_TOPIC && logs[i].topics[0] != COURIER_UNREGISTERED_TOPIC,
                "a registration event during the rotation"
            );
        }
        assertEq(_countOf(logs, address(relay)), 1, "the relay's logs during the rotation");
        assertEq(_countOf(logs, address(matching)), 0, "the matching contract's logs during the rotation");
        assertEq(_countOf(logs, address(core)), 0, "the hub's logs during the rotation");
        _assertRegistrations("after the rotation");

        // After it: the old key, a stranger and K, each at the relay; and K at the matching contract direct.
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(gameOne, Side.B);
        bytes memory data = _crossData(taking, _list(resting));
        address[3] memory refusedNow = [courierKey, stranger, timelockKey];
        for (uint256 i; i < refusedNow.length; ++i) {
            (bool passed, bytes memory refusal) = _tryRelay(refusedNow[i], refusedNow[i], data);
            assertFalse(passed, string.concat("after the rotation the relay passed ", vm.toString(refusedNow[i])));
            assertEq(refusal, _notTheSender(refusedNow[i]), "the refusal after the rotation");
        }
        (bool ok, bytes memory out) = _tryCrossAs(timelockKey, timelockKey, taking, _list(resting));
        assertFalse(ok, "K's own Cross at the matching contract filled");
        assertEq(
            out,
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, tk.a, timelockKey),
            "K's own Cross at the matching contract"
        );
        assertEq(_filled(taking), 0, "a refused Cross filled after the rotation");

        // The new key: the same bytes fill, and a fresh pair on the other side.
        (ok, out) = _tryRelay(newKey, newKey, data);
        assertTrue(ok, string.concat("the new key's Cross was refused: ", vm.toString(out)));
        assertEq(_filled(resting), 9_000, "the new key's Cross, the resting order");
        assertEq(_filled(taking), 9_900, "the new key's Cross, the taking order");
        _fillsOneCent(newKey, gameTwo, Side.A);
        _assertRegistrations("after the new key's fills");

        // Scored 121 to 99, home: side A is paid. On the first game the resting account holds side A twice over,
        // 18,000 against 19,800; on the second the taking account holds it, 9,900 against 9,000.
        _scoreNow(gameOne, 121, 99);
        _scoreNow(gameTwo, 121, 99);
        uint256 marketOne = markets.getMarketId(gameOne, address(moneyline), 0);
        uint256 marketTwo = markets.getMarketId(gameTwo, address(moneyline), 0);
        _settle(marketOne);
        _settle(marketTwo);
        assertEq(_claim(mk.a, marketOne, Side.A), 37_800, "the resting account's claim on the first game");
        assertEq(_claim(tk.a, marketTwo, Side.A), 18_900, "the taking account's claim on the second game");
        _assertNoPayout(tk.a, marketOne, Side.B);
        _assertNoPayout(mk.a, marketTwo, Side.B);
        assertEq(_coin().balanceOf(address(positions)), 0, "the positions contract holds coin at the end");
        assertEq(_coin().balanceOf(mk.a), PURSE + 10_800, "the resting account at the end");
        assertEq(_coin().balanceOf(tk.a), PURSE - 10_800, "the taking account at the end");
    }

    function _assertNoPayout(address who, uint256 market, Side side) internal {
        (bool ok, bytes memory err) = _tryClaim(who, market, side);
        assertFalse(ok, "the losing side was paid");
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector), "the losing side");
    }

    /// The relay keeps no exclusion of its own, and reads its sender before it calls. A rotation that is ready may
    /// be run by anyone, so an account whose code the coin calls during a pull can run it from inside a leg of the
    /// old key's Cross. That Cross fills whole; the sender is the new key from then; and the old key's next Cross
    /// is refused.
    function test_aRotationRunFromInsideAPullLeavesTheCrossInProgressWhole() public {
        // A set on a coin that calls the debited account back during a pull, and a relay on its matching contract.
        TrickCoin trick = new TrickCoin();
        _deploySetOn(address(trick));
        OspexCourierRelay onTrick = _deployRelay(address(matching), courierKey);
        Signer memory y = _account("resting account with code");
        Signer memory t = _account("taking account on the trick coin");
        vm.etch(y.a, address(new CallbackAccount()).code);
        _register(y.a, address(onTrick));
        _register(t.a, address(onTrick));
        uint256 game = _verifiedGame();

        // The rotation, scheduled by K and ready, so that anyone may run it.
        bytes memory toNew = _setSender(newKey);
        bytes32 s = keccak256("a rotation, made ready");
        vm.prank(timelockKey);
        timelock.schedule(address(onTrick), 0, toNew, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        bytes32 id = timelock.hashOperation(address(onTrick), 0, toNew, bytes32(0), s);
        assertTrue(timelock.isOperationReady(id), "the operation is not ready");

        // From inside the pull of the first leg, the resting account runs it.
        trick.setHooked(y.a, true);
        CallbackAccount(y.a)
            .arm(
                address(timelock),
                abi.encodeCall(TimelockController.execute, (address(onTrick), 0, toNew, bytes32(0), s))
            );
        OspexMatching.SignedOrder memory taking = _take(t, game, Side.B, 200, 10_000);
        OspexMatching.SignedOrder memory legOne = _rest(y, game, Side.A, 200, 5_000);
        OspexMatching.SignedOrder memory legTwo = _rest(y, game, Side.A, 200, 5_000);
        (bool ok, bytes memory out) =
            _tryRelayOn(onTrick, courierKey, courierKey, _crossData(taking, _list(legOne, legTwo)));
        assertTrue(ok, string.concat("the Cross in progress was refused: ", vm.toString(out)));
        (bool[] memory oks,) = CallbackAccount(y.a).results();
        assertEq(oks.length, 1, "the call-back made one call");
        assertTrue(oks[0], "the rotation from inside the pull did not run");
        assertTrue(timelock.isOperationDone(id), "the operation is not done");
        assertEq(onTrick.s_sender(), newKey, "the sender after the Cross");
        assertEq(_filled(taking), 10_000, "the Cross in progress, its taking order");
        assertEq(_filled(legOne), 5_000, "the Cross in progress, its first leg");
        assertEq(_filled(legTwo), 5_000, "the Cross in progress, its second leg");

        // The old key's next Cross is refused, and the same bytes fill from the new key.
        taking = _take(t, game, Side.B, 200, 10_000);
        bytes memory next = _crossData(taking, _list(_rest(y, game, Side.A, 200, 10_000)));
        (ok, out) = _tryRelayOn(onTrick, courierKey, courierKey, next);
        assertFalse(ok, "the old key's next Cross was passed");
        assertEq(out, _notTheSender(courierKey), "the old key's next Cross");
        (ok, out) = _tryRelayOn(onTrick, newKey, newKey, next);
        assertTrue(ok, string.concat("the new key's Cross was refused: ", vm.toString(out)));
        assertEq(_filled(taking), 10_000, "the new key's Cross");
    }

    // ──────────────────────────── 30, on the real set ────────────────────

    /// A refusal of the matching contract comes back through the relay whole. Each of these, a sample and not
    /// every refusal of the set, is compared with a literal built here and with the refusal of the same bytes sent
    /// to the matching contract from the relay's own address: a refusal that carries the sender carries the relay,
    /// so a call from the key is no reference. The breaks that cut or replace a refusal are named beside the
    /// scripted target's test, which holds every length.
    function test_neverLine_aRefusalOfTheMatchingContractComesBackWhole() public {
        uint256 game = _verifiedGame();
        IERC20 coin = _coin();
        Signer memory lone = _account("an account that registered the key");
        _register(lone.a, courierKey);
        OspexMatching.SignedOrder memory resting = _rest(mk, game, Side.A, 210, 10_000);

        // The sender is not the taking account's courier: the refusal names the relay.
        OspexMatching.SignedOrder memory taking = _take(lone, game, Side.B, 190, 10_000);
        bytes memory want =
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, lone.a, address(relay));
        _sameRefusal(_crossData(taking, _list(resting)), want, "an account that registered the key, not the relay");
        // The key's own call to the matching contract is refused otherwise, which is why it is no reference.
        (bool ok, bytes memory fromKey) = _tryCrossAs(courierKey, courierKey, taking, _list(resting));
        assertFalse(ok, "the key's own call filled");
        assertEq(fromKey, _nothingFilled(_reasons(NO_COURIER)), "the key's own call to the matching contract");
        assertTrue(keccak256(fromKey) != keccak256(want), "the key's own call would have served as a reference");

        // A taking order signed by another key.
        taking = _take(tk, game, Side.B, 190, 10_000);
        OspexMatching.SignedOrder memory forged =
            OspexMatching.SignedOrder({order: taking.order, signature: _signature(mk.key, _digest(taking.order))});
        _sameRefusal(
            _crossData(forged, _list(resting)),
            _refusal(OspexMatching.OspexMatching__BadSignature.selector, forged),
            "a taking order signed by another key"
        );

        // Nothing filled, with two reasons in list order: no courier, then cancelled.
        OspexMatching.SignedOrder memory unregistered = _rest(lone, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory cancelled = _rest(mk, game, Side.A, 210, 10_000);
        vm.prank(mk.a);
        matching.cancelOrder(cancelled.order);
        uint8[] memory reasons = new uint8[](2);
        reasons[0] = NO_COURIER;
        reasons[1] = CANCELLED;
        _sameRefusal(
            _crossData(taking, _list(unregistered, cancelled)), _nothingFilled(reasons), "nothing filled, two reasons"
        );

        // The short refusal of the minimum fill, with its list of legs: 5,000 at 2.10 fills 5,500 of the 10,000
        // the taking order asks for at the least, and leaves it 4,500.
        OspexMatching.SignedOrder memory asking = _takeMin(tk, game, Side.B, 190, 10_000, 10_000);
        OspexMatching.SignedOrder memory small = _rest(mk, game, Side.A, 210, 5_000);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        legs[0] = _filledLeg(small, 5_000, 5_500);
        _sameRefusal(
            _crossData(asking, _list(small)), _short(asking, 5_500, 4_500, legs), "short of the taking order's minimum"
        );

        // The taking account's refused pull.
        Signer memory broke = _account("a taking account that withdrew its approval");
        _register(broke.a, address(relay));
        vm.prank(broke.a);
        coin.approve(address(positions), 0);
        assertEq(coin.allowance(broke.a, address(positions)), 0, "the approval was not withdrawn");
        taking = _take(broke, game, Side.B, 190, 10_000);
        _sameRefusal(
            _crossData(taking, _list(resting)),
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, broke.a, uint256(9_900)),
            "the taking account's refused pull"
        );
        assertEq(_filled(resting), 0, "a refused Cross filled the resting order");

        // Above the cap. The lift is scheduled first and made ready, so that the bytes refused before it are the
        // bytes that fill after it, inside the taking order's thirty seconds: the cap was what refused them.
        bytes memory lift = abi.encodeCall(OspexMatching.liftTakingStakeCap, ());
        bytes32 s = keccak256("the lift, made ready");
        vm.prank(timelockKey);
        timelock.schedule(address(matching), 0, lift, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        OspexMatching.SignedOrder memory above = _take(tk, game, Side.B, 200, 10_100);
        OspexMatching.SignedOrder memory large = _rest(mk, game, Side.A, 200, 10_100);
        bytes memory aboveData = _crossData(above, _list(large));
        _sameRefusal(
            aboveData,
            _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, above),
            "10,100 before the lift"
        );
        vm.prank(stranger);
        timelock.execute(address(matching), 0, lift, bytes32(0), s);
        assertTrue(matching.s_takingStakeCapLifted(), "the cap was not lifted");
        (ok,) = _tryRelay(courierKey, courierKey, aboveData);
        assertTrue(ok, "the bytes refused under the cap did not fill after the lift");
        assertEq(_filled(above), 10_100, "10,100 after the lift");
        assertEq(_filled(large), 10_100, "the resting 10,100 after the lift");

        // At the close gate: the game's start and its window have passed.
        vm.warp(uint256(START) + WINDOW);
        resting = _rest(mk, game, Side.A, 210, 10_000);
        taking = _take(tk, game, Side.B, 190, 10_000);
        _sameRefusal(
            _crossData(taking, _list(resting)),
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__BetsClosed.selector, game, uint256(START) + WINDOW),
            "at the close gate"
        );
    }

    // ──────────────────────────── 31 ────────────────────

    /// The relay is a party to no transfer. It takes no native money by any door; across a fill the coin moves
    /// from the two accounts to the positions contract and nowhere else, and nobody has approved the relay. A
    /// token sent to its address unasked, and native coin forced on it, are not prevented: a fill leaves each
    /// exactly as it was, and no function sends either out. Its functions, errors and events are pinned whole in
    /// OspexBettingInterface.t.sol, where a function added here turns the pin red.
    /// Breaks: in OspexCourierRelay, add `receive() external payable {}`; make `cross` payable.
    function test_neverLine_theRelayIsAPartyToNoTransfer() public {
        IERC20 coin = _coin();
        uint256 game = _verifiedGame();
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(game, Side.B);
        bytes memory data = _crossData(taking, _list(resting));

        // No door takes native money: a plain transfer, the Cross with value, the setter with value, a selector the
        // relay does not have, and no calldata at all.
        vm.deal(address(this), 1 ether);
        vm.deal(courierKey, 1 ether);
        vm.deal(address(timelock), 1 ether);
        (bool ok,) = address(relay).call{value: 1}("");
        assertFalse(ok, "the relay took a plain transfer of native money");
        vm.prank(courierKey, courierKey);
        (ok,) = address(relay).call{value: 1}(data);
        assertFalse(ok, "the relay took native money with a Cross");
        assertEq(_filled(taking), 0, "a Cross sent with value filled");
        vm.prank(address(timelock), address(timelock));
        (ok,) = address(relay).call{value: 1}(_setSender(newKey));
        assertFalse(ok, "the relay took native money with a rotation");
        assertEq(relay.s_sender(), courierKey, "a rotation sent with value set the sender");
        (ok,) = address(relay).call(abi.encodeWithSignature("sweep(address,address)", address(coin), address(this)));
        assertFalse(ok, "the relay answered a selector it does not have");
        (ok,) = address(relay).call("");
        assertFalse(ok, "the relay answered a call with no calldata");
        assertEq(address(relay).balance, 0, "the relay holds native money");

        // A token sent unasked, and native coin forced on the address, as a destroyed contract's balance is.
        TestCoin(address(coin)).mint(address(relay), 777);
        vm.deal(address(relay), 5);

        // Across a fill: the coin moves from the two accounts to the positions contract, the resting account's
        // stake first, and nowhere else.
        vm.recordLogs();
        _relayed(courierKey, taking, _list(resting));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 moves;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(coin)) continue;
            assertEq(logs[i].topics[0], TRANSFER_TOPIC, "the coin emitted something that is not a transfer");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(positions)))), "a transfer to another address");
            address from = moves == 0 ? mk.a : tk.a;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(from))), "a transfer from another address");
            assertEq(abi.decode(logs[i].data, (uint256)), moves == 0 ? 9_000 : 9_900, "a transfer of another amount");
            ++moves;
        }
        assertEq(moves, 2, "the coin's transfers during the fill");
        assertEq(coin.balanceOf(address(positions)), 18_900, "the positions contract holds the two stakes");
        assertEq(coin.balanceOf(mk.a), PURSE - 9_000, "the resting account paid its own stake");
        assertEq(coin.balanceOf(tk.a), PURSE - 9_900, "the taking account paid its own stake");
        assertEq(coin.balanceOf(address(relay)), 777, "the fill moved the token sent to the relay");
        assertEq(address(relay).balance, 5, "the fill moved the native coin forced on the relay");
        assertEq(coin.balanceOf(courierKey), 0, "the key holds coin");
        address[4] memory spenders = [address(relay), courierKey, address(matching), address(timelock)];
        for (uint256 i; i < spenders.length; ++i) {
            assertEq(coin.allowance(mk.a, spenders[i]), 0, "the resting account approved something but the positions");
            assertEq(coin.allowance(tk.a, spenders[i]), 0, "the taking account approved something but the positions");
            assertEq(coin.allowance(address(relay), spenders[i]), 0, "the relay approved something");
        }
        assertEq(coin.allowance(address(relay), address(positions)), 0, "the relay approved the positions contract");
    }

    // ──────────────────────────── End to end ────────────────────

    /// From a user's side. A maker signs a quote and a bettor a one-cent bet; the key sends the Cross through the
    /// relay; the game is scored 121 to 99; the winner claims, the loser is refused, and the positions contract
    /// holds none of the market's coin; then the same with the sides the other way. Then the key is rotated, the
    /// real way and after the real delay, and a fresh pair of orders from the same two accounts, who did nothing
    /// in between, fills through the new key, settles and pays.
    function test_endToEnd_aBetThroughTheRelayBeforeAndAfterARotation() public {
        IERC20 coin = _coin();
        uint256[2] memory earlier = [_verifiedGame(), _verifiedGame()];
        uint256 afterwards = _verifiedGame();
        Side[2] memory bettorSides = [Side.B, Side.A];
        uint256[2] memory m;
        for (uint256 i; i < 2; ++i) {
            _fillsOneCent(courierKey, earlier[i], bettorSides[i]);
            m[i] = markets.getMarketId(earlier[i], address(moneyline), 0);
        }
        assertEq(coin.balanceOf(address(positions)), 37_800, "the positions contract, after the two bets");
        assertEq(coin.balanceOf(mk.a), PURSE - 18_000, "the maker, after the two bets");
        assertEq(coin.balanceOf(tk.a), PURSE - 19_800, "the bettor, after the two bets");

        // Scored 121 to 99, home: side A is paid both stakes, 18,900, and side B is refused.
        for (uint256 i; i < 2; ++i) {
            _scoreNow(earlier[i], 121, 99);
            _settle(m[i]);
            assertEq(uint8(_outcome(m[i])), uint8(Outcome.Home), "the outcome");
        }
        assertEq(_claim(mk.a, m[0], Side.A), 18_900, "the maker's claim, the bettor on side B");
        _assertNoPayout(tk.a, m[0], Side.B);
        assertEq(_claim(tk.a, m[1], Side.A), 18_900, "the bettor's claim, the bettor on side A");
        _assertNoPayout(mk.a, m[1], Side.B);
        assertEq(coin.balanceOf(address(positions)), 0, "the positions contract, after the claims");
        assertEq(coin.balanceOf(mk.a), PURSE + 900, "the maker, after the claims");
        assertEq(coin.balanceOf(tk.a), PURSE - 900, "the bettor, after the claims");

        // The rotation, through the stock timelock: K schedules, the delay passes, a stranger runs it.
        _rotate(newKey);
        _assertRegistrations("after the rotation");

        // The same two accounts, a fresh pair of orders: refused from the old key, filled from the new.
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) =
            _oneCent(afterwards, Side.B);
        bytes memory data = _crossData(taking, _list(resting));
        (bool ok, bytes memory out) = _tryRelay(courierKey, courierKey, data);
        assertFalse(ok, "the old key's Cross was passed after the rotation");
        assertEq(out, _notTheSender(courierKey), "the old key's Cross after the rotation");
        (ok, out) = _tryRelay(newKey, newKey, data);
        assertTrue(ok, string.concat("the new key's Cross was refused: ", vm.toString(out)));
        assertEq(_filled(taking), 9_900, "the bet through the new key");
        uint256 market = markets.getMarketId(afterwards, address(moneyline), 0);
        _scoreNow(afterwards, 121, 99);
        _settle(market);
        assertEq(_claim(mk.a, market, Side.A), 18_900, "the maker's claim after the rotation");
        _assertNoPayout(tk.a, market, Side.B);
        assertEq(coin.balanceOf(address(positions)), 0, "the positions contract, at the end");
        assertEq(coin.balanceOf(mk.a), PURSE + 10_800, "the maker, at the end");
        assertEq(coin.balanceOf(tk.a), PURSE - 10_800, "the bettor, at the end");
        assertEq(coin.balanceOf(address(relay)), 0, "the relay, at the end");
    }

    // ──────────────────────────── Gas ────────────────────

    /// What the relay adds to a Cross, as the gas of the call a sender makes: a one-cent leg at 2.00, a market's
    /// first fill, sent to the matching contract direct by a sender both accounts registered, and the same leg on
    /// another game sent through the relay. A first Cross by each path warms the accounts and the contracts, so
    /// the two figures differ in the path alone; in a transaction of its own the relayed Cross also pays for the
    /// first touch of the matching contract's address and of the relay's sender word, which a warm test does not
    /// show. Printed, not pinned.
    function test_gas_aOneCentLegThroughTheRelayBesideTheDirectCross() public {
        _register(mk.a, sender);
        _register(tk.a, sender);
        uint256[4] memory g = [_verifiedGame(), _verifiedGame(), _verifiedGame(), _verifiedGame()];
        _cross(sender, _take(tk, g[0], Side.B, 200, 10_000), _list(_rest(mk, g[0], Side.A, 200, 10_000)));
        _relayed(courierKey, _take(tk, g[1], Side.B, 200, 10_000), _list(_rest(mk, g[1], Side.A, 200, 10_000)));

        OspexMatching.SignedOrder memory taking = _take(tk, g[2], Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(mk, g[2], Side.A, 200, 10_000)));
        uint256 direct = vm.lastCallGas().gasTotalUsed;
        assertEq(_filled(taking), 10_000, "the direct Cross did not fill");

        taking = _take(tk, g[3], Side.B, 200, 10_000);
        bytes memory data = _crossData(taking, _list(_rest(mk, g[3], Side.A, 200, 10_000)));
        vm.prank(courierKey, courierKey);
        (bool ok,) = address(relay).call(data);
        uint256 relayed = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok, "the relayed Cross was refused");
        assertEq(_filled(taking), 10_000, "the relayed Cross did not fill");

        emit log_named_uint("one cent, one leg, the market's first fill, sent direct", direct);
        emit log_named_uint("the same leg sent through the relay", relayed);
        emit log_named_uint("what the relay adds", relayed - direct);
    }
}

/// @notice Never-line 28 where the caller and the delay are the subject: who sets the sender, and how a rotation
///         waits.
contract OspexCourierRelayRotationTest is RelayBase {
    function _notTheTimelock(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheTimelock.selector, caller);
    }

    /// Only the timelock sets the sender. Every other caller is refused by name: K, which holds the timelock and
    /// must schedule like anyone's notice; the deployer; the current sender and the next; a stranger; contracts of
    /// the set; the relay itself; a second stock timelock with the same code; and a stranger whose transaction
    /// the timelock began. The caller is checked before the address, so a stranger's zero is refused as a
    /// stranger's. The timelock's own call sets the sender and emits the one event, read here as literals; zero is
    /// refused by name; the address the sender already is, and an address with code, are taken.
    /// Breaks: in OspexCourierRelay.setSender, delete the caller's check; accept K, the timelock's proposer; accept
    /// the current sender, `msg.sender != i_timelock && msg.sender != s_sender`; compare tx.origin in place of
    /// msg.sender; write nothing; delete the zero check; put the zero check ahead of the caller's; swap the
    /// event's arguments; emit after the write.
    function test_neverLine_onlyTheTimelockSetsTheSender() public {
        assertEq(relay.i_timelock(), address(timelock), "the timelock the relay read at its deploy");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), timelockKey), "K is not the stock timelock's proposer");
        assertTrue(timelockKey != address(timelock) && timelockKey != courierKey, "the three addresses are not apart");
        TimelockController twin = new TimelockController(DELAY, _one(timelockKey), _one(address(0)), address(0));
        bytes memory toNew = _setSender(newKey);
        address[10] memory callers = [
            timelockKey,
            deployer,
            courierKey,
            newKey,
            stranger,
            mk.a,
            address(matching),
            address(core),
            address(relay),
            address(twin)
        ];
        bool ok;
        bytes memory out;
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i], callers[i]);
            (ok, out) = address(relay).call(toNew);
            assertFalse(ok, string.concat("the sender was set by ", vm.toString(callers[i])));
            assertEq(out, _notTheTimelock(callers[i]), "the refusal of a caller that is not the timelock");
        }
        // The transaction's origin being the timelock is not the timelock calling.
        vm.prank(stranger, address(timelock));
        (ok, out) = address(relay).call(toNew);
        assertFalse(ok, "the sender was set with the timelock as the origin");
        assertEq(out, _notTheTimelock(stranger), "the refusal with the timelock as the origin");
        // The caller is checked first: a zero from anyone but the timelock is refused for its caller.
        vm.prank(stranger, stranger);
        (ok, out) = address(relay).call(_setSender(address(0)));
        assertFalse(ok, "a stranger's zero was taken");
        assertEq(out, _notTheTimelock(stranger), "a stranger's zero");
        vm.prank(courierKey, courierKey);
        (ok, out) = address(relay).call(_setSender(address(0)));
        assertFalse(ok, "the current sender's zero was taken");
        assertEq(out, _notTheTimelock(courierKey), "the current sender's zero");
        assertEq(relay.s_sender(), courierKey, "the sender moved under a refused call");

        // The timelock's own call: nothing returned, the one event as literals, the sender set.
        vm.recordLogs();
        vm.prank(address(timelock), address(timelock));
        (ok, out) = address(relay).call(toNew);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "the timelock's call was refused");
        assertEq(out.length, 0, "the setter returned a value");
        _assertOneSenderSet(logs, address(relay), courierKey, newKey);
        assertEq(relay.s_sender(), newKey, "the sender after the timelock's call");

        // Zero: refused by name, no log, the sender as it was.
        vm.recordLogs();
        vm.prank(address(timelock), address(timelock));
        (ok, out) = address(relay).call(_setSender(address(0)));
        logs = vm.getRecordedLogs();
        assertFalse(ok, "the timelock set the sender to zero");
        assertEq(out, abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__ZeroSender.selector), "zero");
        assertEq(logs.length, 0, "a refused zero left a log");
        assertEq(relay.s_sender(), newKey, "the sender after a refused zero");

        // The address the sender already is: taken, and the event says so.
        vm.recordLogs();
        vm.prank(address(timelock), address(timelock));
        (ok, out) = address(relay).call(toNew);
        logs = vm.getRecordedLogs();
        assertTrue(ok, "a rotation to the current sender was refused");
        _assertOneSenderSet(logs, address(relay), newKey, newKey);
        assertEq(relay.s_sender(), newKey, "the sender after a rotation to itself");

        // An address with code: nothing but zero is asked of the address.
        address withCode = address(new HandingCaller());
        vm.recordLogs();
        vm.prank(address(timelock), address(timelock));
        (ok, out) = address(relay).call(_setSender(withCode));
        logs = vm.getRecordedLogs();
        assertTrue(ok, "a rotation to an address with code was refused");
        _assertOneSenderSet(logs, address(relay), newKey, withCode);
        assertEq(relay.s_sender(), withCode, "the sender after a rotation to an address with code");
    }

    /// On the stock timelock as deployed: K schedules and cancels, the delay passes, anyone runs a ready call, a
    /// done call does not run again, and a rotation to zero fails in the relay and stays ready. The old key sends
    /// until the rotation runs, and not after. No break of its own: the timelock is not under test, and the
    /// setter's breaks are scored against the test above.
    function test_neverLine_theRotationWaitsTheDelayAndCanBeCancelled() public {
        uint256 game = _verifiedGame();
        bytes32 ready = bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));
        bytes memory toNew = _setSender(newKey);

        // K schedules; before the delay the operation does not run, and the old key still fills.
        (bytes32 idOne, bytes32 saltOne) = _schedule(toNew);
        _executeRefused(
            toNew,
            saltOne,
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, idOne, ready),
            "before the delay"
        );
        assertEq(relay.s_sender(), courierKey, "the sender moved before the delay");
        _fillsOneCent(courierKey, game, Side.B);

        // K cancels; the delay passes; the cancelled operation does not run, and is no operation.
        vm.prank(timelockKey);
        timelock.cancel(idOne);
        assertFalse(timelock.isOperation(idOne), "the cancelled operation is still an operation");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _executeRefused(
            toNew,
            saltOne,
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, idOne, ready),
            "after the cancel"
        );
        assertEq(relay.s_sender(), courierKey, "the sender moved under a cancelled rotation");
        _fillsOneCent(courierKey, game, Side.A);

        // Scheduled again under a fresh salt; the delay passes; a stranger runs it.
        (bytes32 idTwo, bytes32 saltTwo) = _schedule(toNew);
        assertTrue(timelock.isOperationPending(idTwo), "the second operation is not pending");
        assertFalse(timelock.isOperationReady(idTwo), "the second operation is ready at once");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        assertTrue(timelock.isOperationReady(idTwo), "the second operation is not ready after the delay");
        vm.recordLogs();
        vm.prank(stranger);
        timelock.execute(address(relay), 0, toNew, bytes32(0), saltTwo);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(relay)) continue;
            ++seen;
            assertEq(logs[i].topics[0], SENDER_SET_TOPIC, "the relay's log of the rotation");
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(courierKey))), "the rotation's previous sender");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(newKey))), "the rotation's current sender");
        }
        assertEq(seen, 1, "the relay's logs of the rotation");
        assertEq(relay.s_sender(), newKey, "the sender after the rotation");
        assertTrue(timelock.isOperationDone(idTwo), "the operation is not done");

        // From then the old key is refused and the new key fills the same bytes.
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(game, Side.B);
        bytes memory data = _crossData(taking, _list(resting));
        (bool ok, bytes memory out) = _tryRelay(courierKey, courierKey, data);
        assertFalse(ok, "the old key's Cross was passed after the rotation");
        assertEq(
            out,
            abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheSender.selector, courierKey),
            "the old key's Cross after the rotation"
        );
        (ok, out) = _tryRelay(newKey, newKey, data);
        assertTrue(ok, string.concat("the new key's Cross was refused: ", vm.toString(out)));
        assertEq(_filled(taking), 9_900, "the new key's Cross");

        // The same operation again: done, so the timelock refuses it.
        _executeRefused(
            toNew,
            saltTwo,
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, idTwo, ready),
            "a second run of the done operation"
        );

        // A rotation to zero, scheduled and ready: refused by the relay's name, still ready, the sender as it was.
        bytes memory toZero = _setSender(address(0));
        (bytes32 idThree, bytes32 saltThree) = _schedule(toZero);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _executeRefused(
            toZero,
            saltThree,
            abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__ZeroSender.selector),
            "a rotation to zero"
        );
        assertTrue(timelock.isOperationReady(idThree), "the refused rotation to zero is no longer ready");
        assertEq(relay.s_sender(), newKey, "the sender after a refused rotation to zero");

        // Only K schedules.
        vm.prank(stranger);
        (ok, out) = address(timelock)
            .call(
                abi.encodeCall(
                    TimelockController.schedule, (address(relay), 0, toNew, bytes32(0), bytes32(++salt), DELAY)
                )
            );
        assertFalse(ok, "a stranger scheduled a rotation");
        assertEq(
            out,
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, timelock.PROPOSER_ROLE()
            ),
            "a stranger's schedule"
        );
    }
}

/// @notice Never-line 28 at the deploy: the timelock read once and kept, the addresses the constructor refuses and
///         the order it refuses them in, and a read that fails.
contract OspexCourierRelayConstructorTest is RelayBase {
    function _matchingNotAContract(address target) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__MatchingNotAContract.selector, target);
    }

    function _timelockNotAContract(address read) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__TimelockNotAContract.selector, read);
    }

    function _zeroSender() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__ZeroSender.selector);
    }

    /// @dev A deploy from this contract, which has code, that must be refused with exactly `want`.
    function _refusedDeploy(address target, address key, bytes memory want) internal {
        vm.expectRevert(want);
        new OspexCourierRelay(target, key);
    }

    /// @dev A deploy from this contract, which has code, with whether it failed and the data it failed with.
    function _tryDeploy(address target, address key) internal returns (bool failed, bytes memory err) {
        try new OspexCourierRelay(target, key) returns (OspexCourierRelay) {
            failed = false;
        } catch (bytes memory reason) {
            failed = true;
            err = reason;
        }
    }

    /// @dev An address whose code is a wallet's delegation to `to`: 23 bytes, 0xef0100 and the address.
    function _delegation(string memory name, address to) internal returns (address at) {
        at = makeAddr(name);
        vm.etch(at, abi.encodePacked(hex"ef0100", to));
        assertEq(at.code.length, 23, "the delegation's length");
    }

    /// @dev An answering target that answers `read` as its timelock.
    function _answering(address read) internal returns (AnsweringTarget target) {
        target = new AnsweringTarget();
        target.script(false, abi.encode(read));
    }

    /// The timelock is the matching contract's answer when the relay is deployed, and nothing the matching address
    /// answers later changes it: the later answer is refused as a caller, and the first sets the sender. The first
    /// sender is the constructor's, and its one log names zero as the sender before it.
    /// Breaks: in OspexCourierRelay's constructor, `i_timelock = msg.sender;`; `emit SenderSet(msg.sender, sender);`.
    /// In setSender, compare the caller with the matching contract's answer read then,
    /// `OspexMatching(i_matching).i_timelock()`, instead of i_timelock.
    function test_neverLine_theRelayKeepsTheTimelockItReadAtItsDeploy() public {
        // On the real set the relay's timelock is the matching contract's, which is the games set's.
        assertEq(matching.i_timelock(), address(timelock), "the matching contract's timelock");
        assertEq(relay.i_timelock(), address(timelock), "the timelock the relay read at its deploy");
        assertEq(relay.i_matching(), address(matching), "the relay's target");
        assertTrue(relay.i_timelock() != deployer, "the relay kept its deployer as the timelock");

        // The first sender, and the deploy's one log.
        vm.recordLogs();
        OspexCourierRelay made = _deployRelay(address(matching), courierKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertOneSenderSet(logs, address(made), address(0), courierKey);
        assertEq(made.s_sender(), courierKey, "the first sender");

        // A target whose answer changes after the deploy.
        TimelockController twin = new TimelockController(DELAY, _one(timelockKey), _one(address(0)), address(0));
        AnsweringTarget answering = _answering(address(timelock));
        OspexCourierRelay onAnswering = _deployRelay(address(answering), courierKey);
        assertEq(onAnswering.i_timelock(), address(timelock), "the timelock read at the deploy");
        assertEq(onAnswering.i_matching(), address(answering), "the target kept at the deploy");
        answering.script(false, abi.encode(address(twin)));
        assertEq(OspexMatching(address(answering)).i_timelock(), address(twin), "the target's later answer");
        assertEq(onAnswering.i_timelock(), address(timelock), "the relay followed the target's later answer");
        assertEq(onAnswering.i_matching(), address(answering), "the relay's target moved");
        vm.prank(address(twin), address(twin));
        (bool ok, bytes memory err) = address(onAnswering).call(_setSender(newKey));
        assertFalse(ok, "the later answer set the sender");
        assertEq(
            err,
            abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheTimelock.selector, address(twin)),
            "the later answer's refusal"
        );
        assertEq(onAnswering.s_sender(), courierKey, "the sender after the later answer's refusal");
        vm.prank(address(timelock), address(timelock));
        onAnswering.setSender(newKey);
        assertEq(onAnswering.s_sender(), newKey, "the first answer did not set the sender");
    }

    /// The constructor refuses, by name, a matching address and a timelock that are not contracts: no code, or a
    /// wallet's delegation; then a zero sender; in that order, shown by fixtures that are wrong twice. The
    /// delegation at the matching address has its read answered by a mock, so that the delegation check is the one
    /// thing that refuses it. What it takes: code of 23 bytes that is not a delegation.
    /// Breaks: in OspexCourierRelay's constructor, drop `timelock.code.length == 0 ||`; drop
    /// `|| _isDelegated(timelock)`; drop `matching.code.length == 0 ||`; drop `|| _isDelegated(matching)`; drop the
    /// zero-sender check; move the zero-sender check to the constructor's first line.
    function test_neverLine_theConstructorRefusesWhatItCannotAnswerTo() public {
        bytes memory read = abi.encodeWithSelector(matching.i_timelock.selector);

        // The matching address: zero, no code, a delegation.
        _refusedDeploy(address(0), courierKey, _matchingNotAContract(address(0)));
        address empty = makeAddr("a matching address with no code");
        _refusedDeploy(empty, courierKey, _matchingNotAContract(empty));
        address delegated = _delegation("a matching address that is a wallet's delegation", address(matching));
        vm.mockCall(delegated, read, abi.encode(address(timelock)));
        assertEq(OspexMatching(delegated).i_timelock(), address(timelock), "the mock does not answer the read");
        _refusedDeploy(delegated, courierKey, _matchingNotAContract(delegated));

        // The timelock the target answers: zero, no code, a delegation.
        _refusedDeploy(address(_answering(address(0))), courierKey, _timelockNotAContract(address(0)));
        address bare = makeAddr("a timelock with no code");
        _refusedDeploy(address(_answering(bare)), courierKey, _timelockNotAContract(bare));
        address delegatedLock = _delegation("a timelock that is a wallet's delegation", address(timelock));
        _refusedDeploy(address(_answering(delegatedLock)), courierKey, _timelockNotAContract(delegatedLock));

        // The sender: zero, against the real matching contract.
        _refusedDeploy(address(matching), address(0), _zeroSender());

        // The order: each of these is wrong twice, and is refused for the earlier of the two.
        _refusedDeploy(empty, address(0), _matchingNotAContract(empty));
        _refusedDeploy(delegated, address(0), _matchingNotAContract(delegated));
        _refusedDeploy(address(_answering(bare)), address(0), _timelockNotAContract(bare));
        _refusedDeploy(address(_answering(delegatedLock)), address(0), _timelockNotAContract(delegatedLock));

        // What is taken: 23 bytes of code that is not a delegation, as the timelock and as the matching address.
        // Code that begins 0xef0100 at another length is not a case here: no such code can be deployed (EIP-3541),
        // and the test tool refuses to place it.
        address shortCode = makeAddr("23 bytes of code that is not a delegation");
        vm.etch(shortCode, abi.encodePacked(hex"600060", address(timelock)));
        assertEq(shortCode.code.length, 23, "the 23 bytes");
        assertEq(new OspexCourierRelay(address(_answering(shortCode)), courierKey).i_timelock(), shortCode);
        vm.mockCall(shortCode, read, abi.encode(address(timelock)));
        assertEq(new OspexCourierRelay(shortCode, courierKey).i_matching(), shortCode);
    }

    /// A read of the timelock that fails, fails the deploy, and nothing is taken as the timelock in its place: a
    /// getter that reverts, with its own bytes; one that reverts with none; one that answers nothing, or 31 bytes;
    /// one that answers a word that is not an address; and a contract of the set that has no such read. Each is
    /// deployed from this contract, which has code and is no delegation, so a relay that fell back on its deployer
    /// would deploy.
    /// Break: in OspexCourierRelay's constructor, read the timelock with a low-level call and take msg.sender when
    /// the call fails or answers anything but 32 bytes.
    function test_neverLine_aReadOfTheTimelockThatFailsFailsTheDeploy() public {
        assertGt(address(this).code.length, 0, "the deployer of these relays has no code");
        AnsweringTarget target = new AnsweringTarget();

        // The getter's own refusal comes back as the deploy's, also when the sender is zero too: the read is
        // before the sender's check.
        bytes memory own = abi.encodeWithSignature("TheGettersOwnRefusal(bytes32)", keccak256("its own"));
        target.script(true, own);
        _refusedDeploy(address(target), courierKey, own);
        _refusedDeploy(address(target), address(0), own);

        // The rest fail the deploy.
        bytes[5] memory answers = [
            bytes(""),
            _noise(31, 1),
            abi.encode(uint256(uint160(address(timelock))) | (uint256(1) << 160)),
            abi.encode(type(uint256).max),
            _noise(1, 2)
        ];
        bool failed;
        for (uint256 i; i < answers.length; ++i) {
            target.script(false, answers[i]);
            (failed,) = _tryDeploy(address(target), courierKey);
            assertTrue(failed, string.concat("a relay was deployed on a read that answered ", vm.toString(answers[i])));
        }
        target.script(true, "");
        (failed,) = _tryDeploy(address(target), courierKey);
        assertTrue(failed, "a relay was deployed on a read that reverted with no data");
        // Contracts that have no such read.
        (failed,) = _tryDeploy(address(core), courierKey);
        assertTrue(failed, "a relay was deployed on the core");
        (failed,) = _tryDeploy(address(positions), courierKey);
        assertTrue(failed, "a relay was deployed on the positions contract");

        // The control: the same target answering a contract deploys, so what failed above was the read.
        target.script(false, abi.encode(address(timelock)));
        (failed,) = _tryDeploy(address(target), courierKey);
        assertFalse(failed, "a relay was refused on a read that answered a contract");
    }
}

/// @notice Never-line 30 where the bytes are the subject: a relay on the scripted target, which reverts with
///         scripted bytes or records what it was called with; and the real set, sent an encoding the compiler
///         would not produce.
contract OspexCourierRelayBytesTest is RelayBase {
    ScriptedTarget internal target;
    OspexCourierRelay internal onTarget;

    function setUp() public override {
        super.setUp();
        target = new ScriptedTarget(address(timelock));
        onTarget = _deployRelay(address(target), courierKey);
        assertEq(onTarget.i_matching(), address(target), "the relay's scripted target");
        assertEq(onTarget.i_timelock(), address(timelock), "the timelock the scripted target answered");
    }

    /// Whatever the target reverts with comes back whole: twelve lengths, from none to 1,024 bytes, each of hash
    /// output so that no two are alike and equal bytes show the target was reached. The refusal of no bytes is
    /// compared at length zero, once more by itself. A call that succeeds returns nothing, also when the target
    /// returns bytes.
    /// Breaks: in OspexCourierRelay.cross, delete the revert, so a failure is swallowed; revert with a fixed error
    /// in place of the data; cut the data to four bytes, `revert(add(refusal, 0x20), 4)`; swallow a refusal of no
    /// bytes, `if (!ok && refusal.length != 0)`.
    function test_neverLine_anyRevertDataComesBackWhole() public {
        uint256 game = _verifiedGame();
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(game, Side.B);
        bytes memory data = _crossData(taking, _list(resting));
        uint16[12] memory lengths = [uint16(0), 1, 3, 4, 5, 31, 32, 33, 36, 68, 100, 1024];
        bool ok;
        bytes memory got;
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory scripted = _noise(lengths[i], i);
            target.script(true, scripted);
            (ok, got) = _tryRelayOn(onTarget, courierKey, courierKey, data);
            assertFalse(ok, string.concat("a refusal was swallowed, of bytes ", vm.toString(uint256(lengths[i]))));
            assertEq(got.length, lengths[i], "the refusal's length through the relay");
            assertEq(got, scripted, "the refusal's bytes through the relay");
        }
        // No bytes at all.
        target.script(true, "");
        (ok, got) = _tryRelayOn(onTarget, courierKey, courierKey, data);
        assertFalse(ok, "a refusal of no bytes was swallowed");
        assertEq(got.length, 0, "a refusal of no bytes came back with bytes");
        assertEq(target.calls(), 0, "a reverted call left a record");

        // Success: nothing returned, whatever the target returns.
        uint16[4] memory returned = [uint16(0), 4, 32, 100];
        for (uint256 i; i < returned.length; ++i) {
            target.script(false, _noise(returned[i], 100 + i));
            (ok, got) = _tryRelayOn(onTarget, courierKey, courierKey, data);
            assertTrue(ok, "a call the target took was refused");
            assertEq(got.length, 0, "the relay returned a value");
            assertEq(target.calls(), i + 1, "the target's count of calls");
        }
    }

    /// The call's bytes arrive unchanged: what the target records is what the sender sent, selector included,
    /// from the relay, once. For the compiler's own encoding of the ten-field call, with no, one and three resting
    /// orders; and for encodings of the same values the compiler would not produce and a decoder still takes:
    /// bytes after the last tail, a gap between the head and the tails, and the two tails in the other order.
    /// Breaks: in OspexCourierRelay.cross, forward msg.data short of its first four bytes; forward the two
    /// arguments encoded again, `abi.encodeCall(OspexMatching.cross, (taking, resting))`.
    function test_neverLine_theCallsBytesArriveUnchanged() public {
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(tk, game, Side.B, 190, 10_000);
        OspexMatching.SignedOrder memory a = _rest(mk, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory b = _rest(mk, game, Side.A, 207, 20_000);
        OspexMatching.SignedOrder memory c = _restMin(mk, game, Side.A, 200, 30_000, 5_000);
        bytes memory none = _crossData(taking, _list());
        bytes memory one = _crossData(taking, _list(a));
        bytes memory three = _crossData(taking, _list(a, b, c));
        _recorded(none, "no resting order");
        _recorded(one, "one resting order");
        _recorded(three, "three resting orders");

        bytes memory appended = bytes.concat(one, _noise(33, 7));
        bytes memory gapped = _gapped(one, _noise(32, 8));
        bytes memory oddGap = _gapped(three, _noise(33, 9));
        bytes memory swapped = _swapped(three);
        bytes memory both = bytes.concat(_gapped(three, _noise(64, 10)), _noise(5, 11));
        assertEq(gapped.length, one.length + 32, "the gapped encoding's length");
        assertEq(swapped.length, three.length, "the swapped encoding's length");
        assertTrue(keccak256(gapped) != keccak256(one), "the gapped encoding is the compiler's");
        assertTrue(keccak256(swapped) != keccak256(three), "the swapped encoding is the compiler's");
        _recorded(appended, "bytes after the last tail");
        _recorded(gapped, "a gap between the head and the tails");
        _recorded(oddGap, "a gap of 33 bytes");
        _recorded(swapped, "the two tails in the other order");
        _recorded(both, "a gap, and bytes after the last tail");
        assertEq(target.calls(), 8, "the calls recorded");
    }

    /// @dev The key sends `sent` through the relay on the scripted target, and the target's record is those bytes.
    function _recorded(bytes memory sent, string memory what) internal {
        uint256 before = target.calls();
        (bool ok, bytes memory out) = _tryRelayOn(onTarget, courierKey, courierKey, sent);
        assertTrue(ok, string.concat(what, ": the relay refused the call: ", vm.toString(out)));
        assertEq(out.length, 0, string.concat(what, ": the relay returned a value"));
        assertEq(target.calls(), before + 1, string.concat(what, ": the target was not called once"));
        bytes memory got = target.lastData();
        assertEq(got.length, sent.length, string.concat(what, ": the length of what arrived"));
        assertEq(got, sent, string.concat(what, ": the bytes that arrived"));
        assertEq(bytes32(bytes4(got)), bytes32(bytes4(0x84075346)), string.concat(what, ": the selector that arrived"));
        assertEq(target.lastCaller(), address(onTarget), string.concat(what, ": the target's caller"));
    }

    /// An encoding the compiler would not produce, sent to the real set through the relay, fills as the same
    /// Cross: a gap after the head and bytes after the last tail. The matching contract decodes the bytes the
    /// sender sent and checks the signatures under its own domain; the amounts are the one-cent Cross's, and the
    /// state is what the same bytes leave when they are sent from the relay's own address.
    function test_neverLine_anEncodingTheCompilerWouldNotProduceFillsAsTheSameCross() public {
        uint256 game = _verifiedGame();
        (OspexMatching.SignedOrder memory resting, OspexMatching.SignedOrder memory taking) = _oneCent(game, Side.B);
        bytes memory canonical = _crossData(taking, _list(resting));
        bytes memory sent = bytes.concat(_gapped(canonical, _noise(32, 12)), _noise(33, 13));
        assertTrue(keccak256(sent) != keccak256(canonical), "the encoding is the compiler's own");
        assertEq(sent.length, canonical.length + 65, "the encoding's length");

        uint256 snap = vm.snapshotState();
        (bool okRef, bytes memory outRef) = _tryAsRelay(courierKey, sent);
        assertTrue(okRef, string.concat("the matching contract refused the encoding: ", vm.toString(outRef)));
        bytes32 printRef = _print(resting, taking);
        assertTrue(vm.revertToState(snap), "the snapshot was not taken back");
        assertEq(_filled(taking), 0, "the reference Cross was left in place");

        (bool ok, bytes memory out) = _tryRelay(courierKey, courierKey, sent);
        assertTrue(ok, string.concat("the relay refused the encoding: ", vm.toString(out)));
        assertEq(out.length, 0, "the relay returned a value");
        assertEq(_print(resting, taking), printRef, "through the relay, the state is not the reference's");
        assertEq(_filled(resting), 9_000, "the resting order's filled amount");
        assertEq(_filled(taking), 9_900, "the taking order's filled amount");
        assertEq(_coin().balanceOf(mk.a), PURSE - 9_000, "the resting account paid its own stake");
        assertEq(_coin().balanceOf(tk.a), PURSE - 9_900, "the taking account paid its own stake");
        assertEq(_coin().balanceOf(address(positions)), 18_900, "the positions contract holds the two stakes");
    }
}
