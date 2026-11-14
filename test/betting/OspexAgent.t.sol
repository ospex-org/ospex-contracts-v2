// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";
import {Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {Intermediary, WalletCode} from "./AgentFixtures.sol";
import {CrossBase} from "./CrossBase.sol";

/// @dev What the approved agent's tests share: a funded account A, its agent W, a key with no purse; a second
///      funded account B; the taking and resting accounts of the Crosses that show an order fills or does not;
///      a relay beside the set; and the readings a cancelling call can change, hashed. Above each test, "Break:"
///      names changes to src/betting that turn it red; each is an entry of battery.json. Each never-line test
///      runs twice, with the taking order on side B and on side A.
abstract contract AgentBase is CrossBase {
    using stdStorage for StdStorage;

    /// @dev The most one of W's orders may stake under the grants these tests make, unless a test names another.
    uint256 internal constant CAP = 100_000;
    /// @dev How long a grant stands, unless a test names another.
    uint256 internal constant LIFE = 1 hours;
    /// @dev The top order number, written out.
    uint96 internal constant TOP = type(uint96).max;
    /// @dev The wallet's magic answer, written out.
    bytes4 internal constant MAGIC = 0x1626ba7e;

    Signer internal A;
    Signer internal W;
    Signer internal B;
    Signer internal tk;
    Signer internal m1;
    /// @dev The relay beside the set, and the key that sends its Crosses.
    OspexCourierRelay internal relay;
    address internal relayKey = makeAddr("the relay's sender");

    function setUp() public virtual override {
        super.setUp();
        A = _account("the account");
        W = _key("its agent");
        B = _account("another account");
        tk = _account("taking account");
        m1 = _account("resting one");
        _register(A.a, sender);
        _register(B.a, sender);
        _register(tk.a, sender);
        _register(m1.a, sender);
        relay = new OspexCourierRelay(address(matching), relayKey);
    }

    // ──────────────────────────── Grants ───────────────────────────────

    /// @dev An hour from now, as a grant's end.
    function _inAnHour() internal view returns (uint64) {
        return _ends(vm.getBlockTimestamp() + LIFE);
    }

    /// @dev `acct` grants `agent` on every market at CAP for an hour.
    function _grantTo(Signer memory acct, Signer memory agent) internal returns (uint32 number) {
        vm.prank(acct.a);
        number = matching.grantAgent(agent.a, CAP, _inAnHour(), _noLines());
    }

    /// @dev A list of one line.
    function _oneLine(uint256 game, address scorer, int32 line) internal pure returns (OspexMatching.Line[] memory l) {
        l = new OspexMatching.Line[](1);
        l[0] = OspexMatching.Line({gameId: game, scorer: scorer, lineTicks: line});
    }

    // ──────────────────────────── Orders under a grant ─────────────────

    /// @dev A resting order for `account` on the game's moneyline, live for a day, signed by `by` with the nonce
    ///      given.
    function _restNonce(
        Signer memory by,
        address account,
        uint256 nonce,
        uint256 game,
        Side side,
        uint256 tick,
        uint256 risk
    ) internal view returns (OspexMatching.SignedOrder memory) {
        return _signed(
            _order(
                account, game, address(moneyline), 0, side, _tick(tick), risk, nonce, vm.getBlockTimestamp() + 1 days
            ),
            by.key
        );
    }

    /// @dev A taking order for `account`, thirty seconds to its expiry, signed by `by` with the nonce given.
    function _takeNonce(
        Signer memory by,
        address account,
        uint256 nonce,
        uint256 game,
        Side side,
        uint256 tick,
        uint256 risk
    ) internal view returns (OspexMatching.SignedOrder memory) {
        return _signed(
            _order(account, game, address(moneyline), 0, side, _tick(tick), risk, nonce, vm.getBlockTimestamp() + 30),
            by.key
        );
    }

    /// @dev A copy of an order with another nonce. A memory struct assigned to a second name is the same struct,
    ///      so a copy is built field by field.
    function _withNonce(OspexMatching.OspexOrder memory o, uint256 nonce)
        internal
        pure
        returns (OspexMatching.OspexOrder memory)
    {
        return OspexMatching.OspexOrder({
            account: o.account,
            gameId: o.gameId,
            scorer: o.scorer,
            lineTicks: o.lineTicks,
            positionType: o.positionType,
            oddsTick: o.oddsTick,
            riskAmount: o.riskAmount,
            nonce: nonce,
            expiry: o.expiry,
            minFill: o.minFill
        });
    }

    // ──────────────────────────── One leg, either role ─────────────────

    /// @dev `x`, a resting order on the other side of `takingSide`, fills 10,000 against the taking account's
    ///      order of 10,000 at 2.00: the one leg of a Cross the sender sends. Returns the market.
    function _restingFills(uint256 game, Side takingSide, OspexMatching.SignedOrder memory x, string memory what)
        internal
        returns (uint256 market)
    {
        uint256 before = _filled(x);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
        assertEq(_filled(x) - before, 10_000, string.concat(what, ": the resting order's fill"));
        market = markets.getMarketId(game, address(moneyline), 0);
    }

    /// @dev The same, with the Cross's result: for a resting order whose refusal names it.
    function _tryResting(uint256 game, Side takingSide, OspexMatching.SignedOrder memory x)
        internal
        returns (bool ok, bytes memory err)
    {
        return _tryCross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
    }

    /// @dev `x`, a resting order, is skipped for `reason` beside m1's order, which fills: one skip record, and
    ///      x's filled amount as it was.
    function _restingSkipped(
        uint256 game,
        Side takingSide,
        OspexMatching.SignedOrder memory x,
        uint8 reason,
        string memory what
    ) internal {
        uint256 before = _filled(x);
        OspexMatching.SignedOrder memory live = _rest(m1, game, _other(takingSide), 200, 10_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        vm.recordLogs();
        _cross(sender, taking, _list(x, live));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, string.concat(what, ": one skip record"));
        _assertSkip(skips[0], x, taking, reason, what);
        assertEq(_filled(x), before, string.concat(what, ": the skipped order filled"));
        assertEq(_filled(live), 10_000, string.concat(what, ": the order beside it"));
    }

    /// @dev `t`, a taking order on `takingSide` for 10,000 at 2.00, fills against m1's resting order of 10,000.
    function _takingFills(uint256 game, Side takingSide, OspexMatching.SignedOrder memory t, string memory what)
        internal
        returns (uint256 market)
    {
        uint256 before = _filled(t);
        _cross(sender, t, _list(_rest(m1, game, _other(takingSide), 200, 10_000)));
        assertEq(_filled(t) - before, 10_000, string.concat(what, ": the taking order's fill"));
        market = markets.getMarketId(game, address(moneyline), 0);
    }

    /// @dev The same, with the Cross's result.
    function _tryTaking(uint256 game, Side takingSide, OspexMatching.SignedOrder memory t)
        internal
        returns (bool ok, bytes memory err)
    {
        return _tryCross(sender, t, _list(_rest(m1, game, _other(takingSide), 200, 10_000)));
    }

    /// @dev A Cross of `t` against m1's resting order is refused with exactly `want`.
    function _takingRefused(
        uint256 game,
        Side takingSide,
        OspexMatching.SignedOrder memory t,
        bytes memory want,
        string memory what
    ) internal {
        _refused(sender, t, _list(_rest(m1, game, _other(takingSide), 200, 10_000)), want, what);
    }

    /// @dev Scores the game so that `side` wins its moneyline, home for side A and away for side B, and settles
    ///      the moneyline's market; the outcome is asserted.
    function _scoreFor(uint256 game, Side side) internal {
        if (side == Side.A) _score(game, HOME, AWAY);
        else _score(game, AWAY, HOME);
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(side == Side.A ? Outcome.Home : Outcome.Away), "the outcome");
    }

    // ──────────────────────────── Refusals ─────────────────────────────

    function _notAccountOrAgent(address account, address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OspexMatching.OspexMatching__NotAccountOrAgent.selector, account, caller);
    }

    function _grantGone(OspexMatching.SignedOrder memory s, uint32 grantNumber, uint32 current, uint64 endsAt)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            OspexMatching.OspexMatching__TakingOrderGrantGone.selector, _hash(s), grantNumber, current, endsAt
        );
    }

    /// @dev `from` makes `data` a call to `target`, which must be refused with exactly `want`.
    function _refusedCall(address from, address target, bytes memory data, bytes memory want, string memory what)
        internal
    {
        vm.prank(from, from);
        (bool ok, bytes memory err) = target.call(data);
        assertFalse(ok, string.concat(what, ": the call was taken"));
        assertEq(err, want, what);
    }

    /// @dev `data` finds no function on the matching module: refused with no data, and nothing changes.
    function _noSuchDoor(address from, bytes memory data, string memory what) internal {
        vm.prank(from);
        (bool ok, bytes memory err) = address(matching).call(data);
        assertFalse(ok, string.concat(what, ": the door opened"));
        assertEq(err.length, 0, string.concat(what, ": refused with data, so by a function that exists"));
    }

    /// @dev `from` makes `data` a call to the matching module, which must succeed.
    function _call(address from, bytes memory data) internal returns (bytes memory answer) {
        vm.prank(from);
        bool ok;
        (ok, answer) = address(matching).call(data);
        assertTrue(ok, string.concat("the call was refused: ", vm.toString(answer)));
    }

    // ──────────────────────────── What a cancel can change ─────────────

    /// @dev An account's cancelling state, hashed: its version, its grant count and current grant, its floor on
    ///      the game's moneyline at its current version, and the marks of the hashes named.
    function _cancelState(address account, uint256 game, bytes32[] memory hashes) internal view returns (bytes32 h) {
        h = keccak256(
            abi.encode(
                matching.s_version(account),
                matching.s_grantCount(account),
                matching.s_currentGrant(account),
                matching.getFloor(account, game, address(moneyline), 0)
            )
        );
        for (uint256 i; i < hashes.length; ++i) {
            h = keccak256(abi.encode(h, matching.s_cancelledOrders(hashes[i])));
        }
    }

    function _hashes(OspexMatching.SignedOrder memory a) internal view returns (bytes32[] memory out) {
        out = new bytes32[](1);
        out[0] = _hash(a);
    }

    /// @dev The number of logs the matching module and the core emitted among `logs`.
    function _emitted(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(matching) || logs[i].emitter == address(core)) ++n;
        }
    }

    // ──────────────────────────── Storage ──────────────────────────────

    /// @dev Writes an account's version: the one way to reach the top of the field in a test.
    function _writeVersion(address account, uint128 version) internal {
        stdstore.target(address(matching)).sig("s_version(address)").with_key(account).checked_write(uint256(version));
    }

    /// @dev Writes an account's grant count: the one way to reach the top of the count in a test.
    function _writeGrantCount(address account, uint32 count) internal {
        stdstore.target(address(matching)).sig("s_grantCount(address)").with_key(account).checked_write(uint256(count));
    }

    /// @dev Fixes the previous block's hash, and so the draw of the next cancelAll: the hash's first eight bytes
    ///      are `draw`.
    function _fixDraw(uint64 draw) internal {
        if (block.number < 2) vm.roll(100);
        vm.setBlockhash(block.number - 1, bytes32(uint256(draw) << 192) | bytes32(uint256(0x5a5a5a5a)));
    }
}

/// @notice The grant: its record, its number, its events and their hub copies, its refusals, the revoke, the
///         combined onboarding call, and the count's top.
contract OspexAgentGrantTest is AgentBase {
    /// Break: in OspexMatching._grant, write the record before the count check, or drop the count check. Others
    /// turn it red: `>` for `==` at the count; the number taken as the count, not the count plus one; the old
    /// grant's AgentRevoked dropped at a regrant; the lines written under the old number.
    function test_grant_isRecordedNumberedAndAnnounced() public {
        uint256 game = _verifiedGame();
        OspexMatching.Line[] memory lines = _oneLine(game, address(spread), -35);
        OspexMatching.Line[] memory otherLines = _oneLine(game, address(spread), -45);
        uint64 ends = _inAnHour();

        assertEq(matching.s_grantCount(A.a), 0);
        assertEq(matching.s_currentGrant(A.a), 0);
        assertFalse(matching.isLiveAgent(A.a, W.a));
        (address agent0, uint64 ends0, uint256 cap0, uint16 count0) = matching.getGrant(A.a, 1);
        assertEq(agent0, address(0));
        assertEq(ends0, 0);
        assertEq(cap0, 0);
        assertEq(count0, 0);

        // The first grant: number 1, announced itself and through the hub, no revoke before it.
        vm.recordLogs();
        vm.prank(A.a);
        uint32 number = matching.grantAgent(W.a, CAP, ends, lines);
        assertEq(number, 1, "the first grant's number");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_emitted(logs), 2, "one event and its hub copy");
        assertEq(logs[0].emitter, address(matching));
        assertEq(logs[0].topics[0], OspexMatching.AgentGranted.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(A.a))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(W.a))));
        assertEq(logs[0].data, abi.encode(uint32(1), CAP, ends, lines), "the grant event's data");
        assertEq(logs[1].emitter, address(core));
        assertEq(logs[1].topics[1], matching.EVENT_AGENT_GRANTED());
        assertEq(
            abi.decode(logs[1].data, (bytes)),
            abi.encode(A.a, W.a, uint32(1), CAP, ends, lines),
            "the hub copy's payload"
        );

        assertEq(matching.s_grantCount(A.a), 1);
        assertEq(matching.s_currentGrant(A.a), 1);
        assertTrue(matching.isLiveAgent(A.a, W.a));
        assertFalse(matching.isLiveAgent(A.a, A.a));
        assertFalse(matching.isLiveAgent(W.a, W.a), "the agent is nobody's agent by what it is");
        (address agent, uint64 endsAt, uint256 cap, uint16 lineCount) = matching.getGrant(A.a, 1);
        assertEq(agent, W.a);
        assertEq(endsAt, ends);
        assertEq(cap, CAP);
        assertEq(lineCount, 1);
        assertTrue(matching.isGrantLine(A.a, 1, game, address(spread), -35));
        assertFalse(matching.isGrantLine(A.a, 1, game, address(spread), -45));
        assertFalse(matching.isGrantLine(A.a, 1, game, address(moneyline), 0));
        assertFalse(matching.isGrantLine(A.a, 2, game, address(spread), -35), "a line under a number not made");

        // A second grant, to another key on another line: number 2, the first revoked first, both announced.
        Signer memory W2 = _key("a second agent");
        vm.recordLogs();
        vm.prank(A.a);
        assertEq(matching.grantAgent(W2.a, CAP + 1, ends + 1, otherLines), 2, "the second grant's number");
        logs = vm.getRecordedLogs();
        assertEq(_emitted(logs), 4, "the revoke, the grant, and their hub copies");
        assertEq(logs[0].topics[0], OspexMatching.AgentRevoked.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(A.a))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(W.a))));
        assertEq(logs[0].data, abi.encode(uint32(1)));
        assertEq(logs[1].topics[1], matching.EVENT_AGENT_REVOKED());
        assertEq(abi.decode(logs[1].data, (bytes)), abi.encode(A.a, W.a, uint32(1)));
        assertEq(logs[2].topics[0], OspexMatching.AgentGranted.selector);
        assertEq(logs[2].topics[2], bytes32(uint256(uint160(W2.a))));
        assertEq(logs[2].data, abi.encode(uint32(2), CAP + 1, ends + 1, otherLines));
        assertEq(matching.s_grantCount(A.a), 2);
        assertEq(matching.s_currentGrant(A.a), 2);
        assertFalse(matching.isLiveAgent(A.a, W.a), "the first agent is no longer live");
        assertTrue(matching.isLiveAgent(A.a, W2.a));
        // The first record is as it was written: never edited.
        (agent, endsAt, cap, lineCount) = matching.getGrant(A.a, 1);
        assertEq(agent, W.a);
        assertEq(endsAt, ends);
        assertEq(cap, CAP);
        assertEq(lineCount, 1);
        assertTrue(matching.isGrantLine(A.a, 1, game, address(spread), -35));
        assertFalse(
            matching.isGrantLine(A.a, 1, game, address(spread), -45), "the second grant's line reached the first record"
        );
        assertTrue(matching.isGrantLine(A.a, 2, game, address(spread), -45), "the second grant's line");
        assertFalse(
            matching.isGrantLine(A.a, 2, game, address(spread), -35), "the first grant's line reached the second record"
        );
        (,,, uint16 lineCount2) = matching.getGrant(A.a, 2);
        assertEq(lineCount2, 1, "the second grant's count of lines");

        // The revoke: the current grant goes to 0, the count and the records stay, announced twice.
        vm.recordLogs();
        vm.prank(A.a);
        matching.revokeAgent();
        logs = vm.getRecordedLogs();
        assertEq(_emitted(logs), 2);
        assertEq(logs[0].topics[0], OspexMatching.AgentRevoked.selector);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(W2.a))));
        assertEq(logs[0].data, abi.encode(uint32(2)));
        assertEq(abi.decode(logs[1].data, (bytes)), abi.encode(A.a, W2.a, uint32(2)));
        assertEq(matching.s_grantCount(A.a), 2);
        assertEq(matching.s_currentGrant(A.a), 0);
        assertFalse(matching.isLiveAgent(A.a, W2.a));
        (agent,,,) = matching.getGrant(A.a, 2);
        assertEq(agent, W2.a, "the revoked record stays");

        // A grant after the revoke is number 3, never 1 or 2 again, with no revoke before it.
        vm.recordLogs();
        vm.prank(A.a);
        assertEq(matching.grantAgent(W.a, CAP, ends, _noLines()), 3, "numbers are never reused");
        assertEq(_emitted(vm.getRecordedLogs()), 2, "no revoke when no grant stood");
        assertTrue(matching.isLiveAgent(A.a, W.a));
        assertEq(matching.s_grantCount(A.a), 3);

        // The grant is the caller's own: B's count and current grant are untouched by all of A's.
        assertEq(matching.s_grantCount(B.a), 0);
        assertEq(matching.s_currentGrant(B.a), 0);
        assertFalse(matching.isLiveAgent(B.a, W.a));
    }

    /// Break: in OspexMatching._grant, drop the refusal of the account as its own agent. Others turn it red: the
    /// zero agent accepted; `<` for `<=` at the end; the line limit dropped or made `>=`; the revoke of no grant
    /// accepted.
    function test_grant_refusesByName() public {
        uint64 ends = _inAnHour();
        bytes32 start = _cancelState(A.a, 7, new bytes32[](0));

        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (address(0), CAP, ends, _noLines())),
            abi.encodeWithSelector(OspexMatching.OspexMatching__ZeroAgent.selector),
            "a zero agent"
        );
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (A.a, CAP, ends, _noLines())),
            abi.encodeWithSelector(OspexMatching.OspexMatching__AgentIsAccount.selector),
            "the account as its own agent"
        );
        uint64 now_ = _ends(vm.getBlockTimestamp());
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (W.a, CAP, now_, _noLines())),
            abi.encodeWithSelector(OspexMatching.OspexMatching__GrantEndsInThePast.selector, now_, now_),
            "an end at the block's time"
        );
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (W.a, CAP, now_ - 1, _noLines())),
            abi.encodeWithSelector(OspexMatching.OspexMatching__GrantEndsInThePast.selector, now_ - 1, now_),
            "an end a second before"
        );
        OspexMatching.Line[] memory many = new OspexMatching.Line[](65);
        for (uint256 i; i < 65; ++i) {
            many[i] = OspexMatching.Line({gameId: i, scorer: address(moneyline), lineTicks: 0});
        }
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (W.a, CAP, ends, many)),
            abi.encodeWithSelector(OspexMatching.OspexMatching__TooManyLines.selector, uint256(65)),
            "sixty-five lines"
        );
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.revokeAgent, ()),
            abi.encodeWithSelector(OspexMatching.OspexMatching__NoGrantToRevoke.selector),
            "a revoke with no grant standing"
        );
        // The combined call refuses the same way, before the courier is written.
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgentAndRegisterCourier, (A.a, CAP, ends, _noLines(), relayKey)),
            abi.encodeWithSelector(OspexMatching.OspexMatching__AgentIsAccount.selector),
            "the combined call, the account as its own agent"
        );
        assertFalse(matching.isCourier(A.a, relayKey), "the courier was written by a refused combined call");
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgentAndRegisterCourier, (W.a, CAP, ends, _noLines(), address(0))),
            abi.encodeWithSelector(OspexMatching.OspexMatching__ZeroCourier.selector),
            "the combined call, a zero courier"
        );
        assertEq(matching.s_grantCount(A.a), 0, "a refused combined call wrote a grant");

        assertEq(_cancelState(A.a, 7, new bytes32[](0)), start, "a refused grant wrote something");

        // Sixty-four lines, an end a second ahead and a cap of zero are all taken.
        OspexMatching.Line[] memory sixtyFour = new OspexMatching.Line[](64);
        for (uint256 i; i < 64; ++i) {
            sixtyFour[i] = OspexMatching.Line({gameId: i, scorer: address(moneyline), lineTicks: 0});
        }
        vm.prank(A.a);
        assertEq(matching.grantAgent(W.a, 0, now_ + 1, sixtyFour), 1, "sixty-four lines, a cap of zero, an end ahead");
        (,,, uint16 lineCount) = matching.getGrant(A.a, 1);
        assertEq(lineCount, 64);
        for (uint256 i; i < 64; ++i) {
            assertTrue(matching.isGrantLine(A.a, 1, i, address(moneyline), 0));
        }
        assertFalse(matching.isGrantLine(A.a, 1, 64, address(moneyline), 0));
        assertTrue(matching.isLiveAgent(A.a, W.a));
        vm.warp(now_ + 1);
        assertFalse(matching.isLiveAgent(A.a, W.a), "at its end second the grant has ended");
    }

    /// Break: in OspexMatching.grantAgentAndRegisterCourier, register the courier before the grant. Others turn
    /// it red: the courier registered for the agent; a repeated courier registration reverting.
    function test_grant_theCombinedCallGrantsThenRegistersForTheCaller() public {
        uint64 ends = _inAnHour();
        address courier = makeAddr("the Ospex courier");
        vm.recordLogs();
        vm.prank(A.a);
        uint32 number = matching.grantAgentAndRegisterCourier(W.a, CAP, ends, _noLines(), courier);
        assertEq(number, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_emitted(logs), 4, "the grant and the registration, each with its hub copy");
        assertEq(logs[0].topics[0], OspexMatching.AgentGranted.selector, "the grant comes first");
        assertEq(logs[2].topics[0], OspexMatching.CourierRegistered.selector, "the registration second");
        assertEq(logs[2].topics[1], bytes32(uint256(uint160(A.a))), "the courier is the caller's");
        assertEq(logs[2].topics[2], bytes32(uint256(uint160(courier))));
        assertTrue(matching.isCourier(A.a, courier));
        assertFalse(matching.isCourier(W.a, courier), "the courier was written for the agent");
        assertTrue(matching.isLiveAgent(A.a, W.a));

        // Again, the same courier: the grant is replaced, the registration writes nothing and refuses nothing.
        vm.recordLogs();
        vm.prank(A.a);
        assertEq(matching.grantAgentAndRegisterCourier(W.a, CAP, ends, _noLines(), courier), 2);
        logs = vm.getRecordedLogs();
        assertEq(_emitted(logs), 4, "the revoke and the grant, each with its hub copy, and no registration");
        assertEq(logs[0].topics[0], OspexMatching.AgentRevoked.selector);
        assertEq(logs[2].topics[0], OspexMatching.AgentGranted.selector);
        assertTrue(matching.isCourier(A.a, courier));
        assertEq(matching.s_currentGrant(A.a), 2);
        // And again with a courier the account does not have yet, a grant standing: the grant is replaced and
        // the new courier is registered, both announced.
        address second = makeAddr("a second courier");
        vm.recordLogs();
        vm.prank(A.a);
        assertEq(matching.grantAgentAndRegisterCourier(W.a, CAP, ends, _noLines(), second), 3);
        logs = vm.getRecordedLogs();
        assertEq(_emitted(logs), 6, "the revoke, the grant and the registration, each with its hub copy");
        assertEq(logs[4].topics[0], OspexMatching.CourierRegistered.selector, "the registration comes last");
        assertEq(logs[4].topics[2], bytes32(uint256(uint160(second))));
        assertTrue(matching.isCourier(A.a, second), "the second courier was not registered beside a standing grant");
        assertTrue(matching.isCourier(A.a, courier));
        assertEq(matching.s_currentGrant(A.a), 3);
    }

    /// The nonce's three numbers, read back as they were put in, at their edges.
    /// Break: in OspexMatching.splitNonce, answer the grant number and the order number swapped.
    function test_splitNonce_answersTheThreeNumbers() public view {
        (uint128 v, uint32 g, uint96 o) = matching.splitNonce(_nonce(5, 7, 9));
        assertEq(v, 5);
        assertEq(g, 7);
        assertEq(o, 9);
        (v, g, o) = matching.splitNonce(_nonce(type(uint128).max, 0, TOP));
        assertEq(v, type(uint128).max);
        assertEq(g, 0);
        assertEq(o, TOP);
        (v, g, o) = matching.splitNonce(_nonce(0, type(uint32).max, 1));
        assertEq(v, 0);
        assertEq(g, type(uint32).max);
        assertEq(o, 1);
        (v, g, o) = matching.splitNonce(7);
        assertEq(v, 0);
        assertEq(g, 0);
        assertEq(o, 7);
    }

    /// The count's top, through both entries: the last number is taken, the next is refused by name before
    /// anything is written, and nothing wraps to 0.
    /// Break: in OspexMatching._grant, drop the count check: the next grant is number 0 in an unchecked wrap, or
    /// a panic in checked arithmetic. Others turn it red: `>` for `==`; the record written before the check.
    function test_grant_theCountHasATopAndRefusesByName() public {
        uint64 ends = _inAnHour();
        uint32 top = matching.MAX_GRANT_COUNT();
        assertEq(top, type(uint32).max);
        _writeGrantCount(A.a, top - 1);

        // The last number is taken, through grantAgent.
        vm.prank(A.a);
        assertEq(matching.grantAgent(W.a, CAP, ends, _noLines()), top, "the last number");
        assertEq(matching.s_grantCount(A.a), top);
        assertEq(matching.s_currentGrant(A.a), top);
        assertTrue(matching.isLiveAgent(A.a, W.a));
        (address agent,,,) = matching.getGrant(A.a, top);
        assertEq(agent, W.a);

        // The next, through both entries: refused by name, nothing written, the courier not registered.
        bytes memory exhausted = abi.encodeWithSelector(OspexMatching.OspexMatching__GrantCountExhausted.selector, A.a);
        Signer memory W2 = _key("a second agent");
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (W2.a, CAP, ends, _noLines())),
            exhausted,
            "grantAgent past the top"
        );
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgentAndRegisterCourier, (W2.a, CAP, ends, _noLines(), relayKey)),
            exhausted,
            "the combined call past the top"
        );
        assertEq(matching.s_grantCount(A.a), top, "the count moved");
        assertEq(matching.s_currentGrant(A.a), top, "the current grant moved");
        assertTrue(matching.isLiveAgent(A.a, W.a), "the standing grant was ended");
        assertFalse(matching.isLiveAgent(A.a, W2.a));
        (agent,,,) = matching.getGrant(A.a, 0);
        assertEq(agent, address(0), "a record wrapped to number 0");
        (agent,,,) = matching.getGrant(A.a, top);
        assertEq(agent, W.a, "the last record was overwritten");
        assertFalse(matching.isCourier(A.a, relayKey), "the courier was registered by a refused combined call");

        // The agent of the last grant still signs and still cancels; a revoke works; and after it the account,
        // which can grant no more, still signs at grant 0.
        uint256 game = _verifiedGame();
        _restingFills(game, Side.B, _restBy(W, A.a, top, game, Side.A, 200, 10_000), "the last grant's order");
        vm.prank(A.a);
        matching.revokeAgent();
        assertEq(matching.s_currentGrant(A.a), 0);
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.grantAgent, (W.a, CAP, ends, _noLines())),
            exhausted,
            "a grant after the revoke, past the top"
        );
        _restingFills(game, Side.B, _rest(A, game, Side.A, 200, 10_000), "the account's own order, grant 0");
        // B's count is its own: B grants as before.
        vm.prank(B.a);
        assertEq(matching.grantAgent(W.a, CAP, ends, _noLines()), 1, "another account's count");
    }
}

/// @notice An agent's orders in both roles: the signer resolved from the account and the nonce's grant number;
///         the record's cap and list, read at the fill from the grant the order names; the grant's standing,
///         revoked, replaced or ended; and the account's own orders, grant 0, beside them.
contract OspexAgentOrdersTest is AgentBase {
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L241. An order under a revoked or expired grant never fills, before or after a regrant.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, compare the order's grant number with `s_grantCount[r.account]` instead of
    /// `s_currentGrant[r.account]`. Others turn it red: the end's test dropped at the leg or at the taking check;
    /// `>` for `>=` at the end; the standing tested on grant 0 too; the same swap in _checkTaking.
    function test_neverLine_anOrderUnderARevokedOrExpiredGrantNeverFills() public {
        uint256 fresh = vm.snapshotState();
        _grantGoneCases(Side.B);
        vm.revertToState(fresh);
        _grantGoneCases(Side.A);
    }

    function _grantGoneCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        assertEq(_grantTo(A, W), 1, "the first grant");
        (, uint64 endsAt,,) = matching.getGrant(A.a, 1);
        OspexMatching.SignedOrder memory r1 = _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory t1 = _takeBy(W, A.a, 1, game, takingSide, 200, 10_000);
        uint256 snap = vm.snapshotState();

        // The control: under the grant as it stands, both roles fill.
        _restingFills(game, takingSide, r1, "the control, resting");
        _takingFills(game, takingSide, t1, "the control, taking");
        vm.revertToState(snap);

        // Revoked: the resting order skips 7, the taking order reverts by name.
        vm.prank(A.a);
        matching.revokeAgent();
        _restingSkipped(game, takingSide, r1, GRANT_GONE, "revoked, resting");
        _takingRefused(game, takingSide, t1, _grantGone(t1, 1, 0, endsAt), "revoked, taking");
        // The account's own orders, grant 0, are untouched by the revoke, in both roles: the fill debits the
        // account and records the account's position, and the agent holds nothing before or after.
        _ownOrdersFill(game, takingSide, "after the revoke");
        // Regrant the same key, grant 2: the grant-1 orders stay dead, grant-2 orders fill, grant 0 still fills.
        vm.prank(A.a);
        assertEq(matching.grantAgent(W.a, CAP, _inAnHour(), _noLines()), 2, "the regrant's number");
        _restingSkipped(game, takingSide, r1, GRANT_GONE, "regranted, the grant-1 resting order");
        _takingRefused(game, takingSide, t1, _grantGone(t1, 1, 2, endsAt), "regranted, the grant-1 taking order");
        _restingFills(game, takingSide, _restBy(W, A.a, 2, game, restingSide, 200, 10_000), "a grant-2 resting order");
        _takingFills(game, takingSide, _takeBy(W, A.a, 2, game, takingSide, 200, 10_000), "a grant-2 taking order");
        _ownOrdersFill(game, takingSide, "after the regrant");
        vm.revertToState(snap);

        // Replaced without a revoke, by a grant to another key: the grant-1 orders die the same way.
        Signer memory W2 = _key("a second agent");
        vm.prank(A.a);
        matching.grantAgent(W2.a, CAP, _inAnHour(), _noLines());
        _restingSkipped(game, takingSide, r1, GRANT_GONE, "replaced, resting");
        _takingRefused(game, takingSide, t1, _grantGone(t1, 1, 2, endsAt), "replaced, taking");
        vm.revertToState(snap);

        // Ended: a second before the end both roles fill; at the end second both are dead, and the account's own
        // orders are not.
        vm.warp(endsAt - 1);
        _restingFills(game, takingSide, r1, "a second before the end, resting");
        _takingFills(
            game, takingSide, _takeBy(W, A.a, 1, game, takingSide, 200, 10_000), "a second before the end, taking"
        );
        vm.warp(endsAt);
        OspexMatching.SignedOrder memory r1b = _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory t1b = _takeBy(W, A.a, 1, game, takingSide, 200, 10_000);
        assertFalse(matching.isLiveAgent(A.a, W.a), "live at its end second");
        _restingSkipped(game, takingSide, r1b, GRANT_GONE, "at the end second, resting");
        _takingRefused(game, takingSide, t1b, _grantGone(t1b, 1, 1, endsAt), "at the end second, taking");
        _ownOrdersFill(game, takingSide, "at the grant's end");
        vm.revertToState(snap);
    }

    /// @dev The account's own orders, grant 0, fill in both roles: the account's coin falls and its positions
    ///      grow, and the agent's coin and positions do not move.
    function _ownOrdersFill(uint256 game, Side takingSide, string memory what) internal {
        Side restingSide = _other(takingSide);
        uint256 aBefore = _coin().balanceOf(A.a);
        uint256 wBefore = _coin().balanceOf(W.a);
        OspexMatching.SignedOrder memory own = _rest(A, game, restingSide, 200, 10_000);
        uint256 market = _restingFills(game, takingSide, own, string.concat(what, ": the account's own resting order"));
        Position memory p = _position(market, A.a, restingSide);
        assertGe(p.risk, 10_000, string.concat(what, ": the account's position after its resting fill"));
        // The pull of the resting stake is the account's, before its taking fill on the other side nets it.
        assertEq(
            aBefore - _coin().balanceOf(A.a), 10_000, string.concat(what, ": the account was not debited its stake")
        );
        _takingFills(
            game, takingSide, _take(A, game, takingSide, 200, 10_000), string.concat(what, ": its own taking order")
        );
        assertGe(
            _position(market, A.a, takingSide).risk, 10_000, string.concat(what, ": its position after its taking fill")
        );
        assertEq(_coin().balanceOf(W.a), wBefore, string.concat(what, ": the agent's coin moved"));
        assertEq(_position(market, W.a, Side.A).risk, 0, string.concat(what, ": the agent holds a position"));
        assertEq(_position(market, W.a, Side.B).risk, 0, string.concat(what, ": the agent holds a position"));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Ruling 6, the signer: the account's key at grant 0, the grant's agent otherwise, and nothing else.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkSigned, resolve the signer as `order.account` for every grant number. Others
    /// turn it red: a grant never made resolved to the account instead of refused by name; the comparison taking
    /// either the account's key or the agent's under a nonzero grant; the signer read from the current grant
    /// instead of the grant the order names.
    function test_neverLine_theSignerIsTheAccountsKeyAtGrantZeroAndTheGrantsAgentOtherwise() public {
        uint256 fresh = vm.snapshotState();
        _signerCases(Side.B);
        vm.revertToState(fresh);
        _signerCases(Side.A);
    }

    function _signerCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        Signer memory S = _key("a stranger's key");
        uint256 snap = vm.snapshotState();

        // Before any grant: an order naming grant 1 is refused by name in both roles, whoever signed it.
        OspexMatching.SignedOrder memory r = _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _noSuchGrant(r, 1), "grant 1 before any grant, resting");
        OspexMatching.SignedOrder memory t = _takeBy(W, A.a, 1, game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, t, _noSuchGrant(t, 1), "grant 1 before any grant, taking");
        r = _restBy(A, A.a, 1, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(
            game, takingSide, r, _noSuchGrant(r, 1), "grant 1 signed by the account, before any grant"
        );

        // Under grant 1 to W.
        _grantTo(A, W);
        // The control: W's grant-1 orders fill in both roles.
        _restingFills(game, takingSide, _restBy(W, A.a, 1, game, restingSide, 200, 10_000), "the control, resting");
        _takingFills(game, takingSide, _takeBy(W, A.a, 1, game, takingSide, 200, 10_000), "the control, taking");
        // The account's own key under grant 1: a bad signature, both roles.
        r = _restBy(A, A.a, 1, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _bad(r), "the account's key under grant 1, resting");
        t = _takeBy(A, A.a, 1, game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, t, _bad(t), "the account's key under grant 1, taking");
        // The agent's key at grant 0: a bad signature, both roles, however live the agent is.
        r = _restBy(W, A.a, 0, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _bad(r), "the agent's key at grant 0, resting");
        t = _takeBy(W, A.a, 0, game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, t, _bad(t), "the agent's key at grant 0, taking");
        // A stranger's key under grant 1, and at grant 0.
        r = _restBy(S, A.a, 1, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _bad(r), "a stranger's key under grant 1");
        t = _takeBy(S, A.a, 0, game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, t, _bad(t), "a stranger's key at grant 0");
        // A grant never made, number 2, with W's signature: refused by name, not as a bad signature.
        r = _restBy(W, A.a, 2, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _noSuchGrant(r, 2), "grant 2, never made, resting");
        t = _takeBy(W, A.a, 2, game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, t, _noSuchGrant(t, 2), "grant 2, never made, taking");
        // A malformed signature under grant 1: 64 bytes, and 65 bytes of zeros.
        r = _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
        bytes memory good = r.signature;
        r.signature = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            r.signature[i] = good[i];
        }
        _restingRefusedUpFront(game, takingSide, r, _bad(r), "sixty-four bytes");
        r.signature = new bytes(65);
        _restingRefusedUpFront(game, takingSide, r, _bad(r), "sixty-five zero bytes");
        r.signature = good;
        _restingFills(game, takingSide, r, "the same order, signed as it was");
        // Another account's grant: W is A's agent and not B's. For B, grant 1 is never made; once B grants W2,
        // W's signature under B's grant 1 is a bad signature.
        r = _restBy(W, B.a, 1, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _noSuchGrant(r, 1), "another account's grant 1, never made");
        Signer memory W2 = _key("B's agent");
        _grantTo(B, W2);
        r = _restBy(W, B.a, 1, game, restingSide, 200, 10_000);
        _restingRefusedUpFront(game, takingSide, r, _bad(r), "another account's grant 1, to another key");
        t = _takeBy(W, B.a, 1, game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, t, _bad(t), "another account's grant 1, to another key, taking");
        _restingFills(
            game, takingSide, _restBy(W2, B.a, 1, game, restingSide, 200, 10_000), "B's agent, under B's grant"
        );
        vm.revertToState(snap);
    }

    function _bad(OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return _refusal(OspexMatching.OspexMatching__BadSignature.selector, s);
    }

    function _noSuchGrant(OspexMatching.SignedOrder memory s, uint32 number) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(OspexMatching.OspexMatching__NoSuchGrant.selector, _hash(s), s.order.account, number);
    }

    /// @dev A resting order refused before any leg: the whole Cross reverts with exactly `want`, and the live
    ///      order listed beside it fills nothing.
    function _restingRefusedUpFront(
        uint256 game,
        Side takingSide,
        OspexMatching.SignedOrder memory x,
        bytes memory want,
        string memory what
    ) internal {
        OspexMatching.SignedOrder memory live = _rest(m1, game, _other(takingSide), 200, 10_000);
        _refused(sender, _take(tk, game, takingSide, 200, 10_000), _list(live, x), want, what);
        assertEq(_filled(live), 0, string.concat(what, ": the order beside it filled"));
        assertEq(_filled(x), 0, string.concat(what, ": it filled"));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L72, L74. The limits at the fill: the cap on one order's signed stake, and the list of lines.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkSigned, drop the cap check, and in _leg skip the leg under GrantGone when
    /// `makerRisk > g.stakeCap`: the leg's stake is compared and not the signed stake, so the 20,000 order with
    /// a 5,000 leg proceeds. Others turn it red: the list read from the current grant's record instead of the
    /// order's; the cap read from the current grant; `>=` at the cap; an empty list passing nothing.
    function test_neverLine_theCapAndTheListAreTheGrantsAndAreReadAtTheFill() public {
        uint256 fresh = vm.snapshotState();
        _limitCases(Side.B);
        vm.revertToState(fresh);
        _limitCases(Side.A);
    }

    function _limitCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        uint256 game2 = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();

        // The cap: 10,000. At the cap fills, both roles; above it is refused by name before any effect, both
        // roles, even where the leg proposed is below the cap: a resting 20,000 against a taking 5,000, and a
        // taking 20,000 against a resting 5,000.
        vm.prank(A.a);
        matching.grantAgent(W.a, 10_000, _inAnHour(), _noLines());
        _restingFills(game, takingSide, _restBy(W, A.a, 1, game, restingSide, 200, 10_000), "at the cap, resting");
        _takingFills(game, takingSide, _takeBy(W, A.a, 1, game, takingSide, 200, 10_000), "at the cap, taking");
        OspexMatching.SignedOrder memory big = _restBy(W, A.a, 1, game, restingSide, 200, 20_000);
        OspexMatching.SignedOrder memory small = _take(tk, game, takingSide, 200, 5_000);
        bytes32 before = _print(game, big, small);
        _refused(sender, small, _list(big), _aboveCap(big, 20_000, 10_000), "a resting 20,000 under a cap of 10,000");
        assertEq(_print(game, big, small), before, "a refused order left an effect");
        big = _takeBy(W, A.a, 1, game, takingSide, 200, 20_000);
        small = _rest(m1, game, restingSide, 200, 5_000);
        before = _print(game, big, small);
        _refused(sender, big, _list(small), _aboveCap(big, 20_000, 10_000), "a taking 20,000 under a cap of 10,000");
        assertEq(_print(game, big, small), before, "a refused taking order left an effect");
        // A cap of zero: the agent cancels and never places.
        vm.prank(A.a);
        matching.grantAgent(W.a, 0, _inAnHour(), _noLines());
        OspexMatching.SignedOrder memory any = _restBy(W, A.a, 2, game, restingSide, 200, 100);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 100),
            _list(any),
            _aboveCap(any, 100, 0),
            "one lot under a cap of zero"
        );
        assertTrue(matching.isLiveAgent(A.a, W.a), "the zero-cap agent is live");
        OspexMatching.SignedOrder memory own = _rest(A, game, restingSide, 200, 10_000);
        vm.prank(W.a);
        matching.cancelOrder(own.order);
        assertTrue(matching.s_cancelledOrders(_hash(own)), "the zero-cap agent cancels");
        vm.revertToState(snap);

        // The list: one line, the game's moneyline. On it fills, both roles; the other game's moneyline, and the
        // same game's spread, are refused by name before any effect, both roles.
        vm.prank(A.a);
        matching.grantAgent(W.a, CAP, _inAnHour(), _oneLine(game, address(moneyline), 0));
        _restingFills(game, takingSide, _restBy(W, A.a, 1, game, restingSide, 200, 10_000), "on the list, resting");
        _takingFills(game, takingSide, _takeBy(W, A.a, 1, game, takingSide, 200, 10_000), "on the list, taking");
        OspexMatching.SignedOrder memory off = _restBy(W, A.a, 1, game2, restingSide, 200, 10_000);
        _refused(sender, _take(tk, game2, takingSide, 200, 10_000), _list(off), _offList(off), "another game, resting");
        assertEq(_filled(off), 0);
        off = _takeBy(W, A.a, 1, game2, takingSide, 200, 10_000);
        _refused(sender, off, _list(_rest(m1, game2, restingSide, 200, 10_000)), _offList(off), "another game, taking");
        off = _signed(
            _order(
                A.a,
                game,
                address(spread),
                -35,
                restingSide,
                _tick(200),
                10_000,
                _nonce(0, 1, _no(nextNonce++)),
                vm.getBlockTimestamp() + 1 days
            ),
            W.key
        );
        _refused(
            sender,
            _takeOn(tk, game, address(spread), -35, takingSide, 200, 10_000),
            _list(off),
            _offList(off),
            "the spread, resting"
        );
        off = _signed(
            _order(
                A.a,
                game,
                address(spread),
                -35,
                takingSide,
                _tick(200),
                10_000,
                _nonce(0, 1, _no(nextNonce++)),
                vm.getBlockTimestamp() + 30
            ),
            W.key
        );
        _refused(
            sender,
            off,
            _list(_restOn(m1, game, address(spread), -35, restingSide, 200, 10_000)),
            _offList(off),
            "the spread, taking"
        );
        // The account's own order on the other game is not on any list: grant 0 has no list.
        _cross(sender, _take(tk, game2, takingSide, 200, 10_000), _list(_rest(A, game2, restingSide, 200, 10_000)));
        vm.revertToState(snap);

        // An empty list passes every market: the moneyline, the spread and the total of either game.
        _grantTo(A, W);
        _restingFills(
            game, takingSide, _restBy(W, A.a, 1, game, restingSide, 200, 10_000), "every market: the moneyline"
        );
        _restingFills(
            game2, takingSide, _restBy(W, A.a, 1, game2, restingSide, 200, 10_000), "every market: another game"
        );
        OspexMatching.SignedOrder memory onSpread = _signed(
            _order(
                A.a,
                game,
                address(spread),
                -35,
                restingSide,
                _tick(200),
                10_000,
                _nonce(0, 1, _no(nextNonce++)),
                vm.getBlockTimestamp() + 1 days
            ),
            W.key
        );
        _cross(sender, _takeOn(tk, game, address(spread), -35, takingSide, 200, 10_000), _list(onSpread));
        assertEq(_filled(onSpread), 10_000, "every market: the spread");
        OspexMatching.SignedOrder memory onTotal = _signed(
            _order(
                A.a,
                game,
                address(total),
                2105,
                restingSide,
                _tick(200),
                10_000,
                _nonce(0, 1, _no(nextNonce++)),
                vm.getBlockTimestamp() + 1 days
            ),
            W.key
        );
        _cross(sender, _takeOn(tk, game, address(total), 2105, takingSide, 200, 10_000), _list(onTotal));
        assertEq(_filled(onTotal), 10_000, "every market: the total");
        vm.revertToState(snap);

        // The record is the order's, not the current grant's: grant 1 lists the moneyline, grant 2 the spread. A
        // grant-1 order on the moneyline reaches the grant-gone outcome, not the list's refusal, in both roles.
        vm.prank(A.a);
        matching.grantAgent(W.a, CAP, _inAnHour(), _oneLine(game, address(moneyline), 0));
        (, uint64 endsAt,,) = matching.getGrant(A.a, 1);
        OspexMatching.SignedOrder memory r1 = _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory t1 = _takeBy(W, A.a, 1, game, takingSide, 200, 10_000);
        // Grant 2's cap, 5,000, is under grant 1's orders' 10,000: a cap read from the current record, and not
        // the order's, would refuse them by name instead of letting the standing skip them.
        vm.prank(A.a);
        matching.grantAgent(W.a, 5_000, _inAnHour(), _oneLine(game, address(spread), -35));
        _restingSkipped(game, takingSide, r1, GRANT_GONE, "grant 1's list, after grant 2: the resting order skips 7");
        _takingRefused(game, takingSide, t1, _grantGone(t1, 1, 2, endsAt), "grant 1's list, after grant 2: taking");
        // And a grant-2 order on grant 1's line is off grant 2's list: refused by name.
        OspexMatching.SignedOrder memory r2 = _restBy(W, A.a, 2, game, restingSide, 200, 5_000);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 10_000),
            _list(r2),
            _offList(r2),
            "grant 2's order on grant 1's line"
        );
        vm.revertToState(snap);
    }

    function _aboveCap(OspexMatching.SignedOrder memory s, uint256 risk, uint256 cap)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(OspexMatching.OspexMatching__AgentStakeAboveCap.selector, _hash(s), risk, cap);
    }

    function _offList(OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return _refusal(OspexMatching.OspexMatching__LineNotInGrant.selector, s);
    }

    /// @dev The fingerprint of a Cross of two orders: the accounts of these tests and the two orders.
    function _print(uint256, OspexMatching.SignedOrder memory a, OspexMatching.SignedOrder memory b)
        internal
        view
        returns (bytes32)
    {
        address[] memory who = new address[](5);
        who[0] = A.a;
        who[1] = W.a;
        who[2] = tk.a;
        who[3] = m1.a;
        who[4] = sender;
        bytes32[] memory orders = new bytes32[](2);
        orders[0] = _hash(a);
        orders[1] = _hash(b);
        return _fingerprint(who, orders);
    }
}

/// @notice The three cancels: who may send them, whose state they key to, what the sender field names, what a
///         mark and a floor reach, and that none of them moves money. And what an agent cannot do: register a
///         courier for the account, or grant by signature.
contract OspexAgentCancelsTest is AgentBase {
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L244 (a), (b). Nobody but the account or its live agent changes the account's cancelling state, and an
    // agent's action is keyed to the funded account, never to the signer.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._requireAccountOrAgent, read `tx.origin` for the caller. Others turn it red: any
    /// account's live agent accepted; the grant read by count instead of current; the end not tested; the
    /// version written under msg.sender in cancelAll; the floor written under msg.sender; the grant keyed to
    /// tx.origin.
    function test_neverLine_onlyTheAccountOrItsLiveAgentChangesItsCancellingState() public {
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder memory own = _rest(A, game, Side.A, 200, 10_000);
        bytes32[] memory hashes = _hashes(own);
        Signer memory W2 = _key("B's agent");
        Signer memory W3 = _key("a later agent");
        _grantTo(A, W);
        _grantTo(B, W2);
        (, uint64 endsAt,,) = matching.getGrant(A.a, 1);
        uint256 snap = vm.snapshotState();

        // Refused, each of the three calls, by everyone who is not A or A's live agent.
        _threeRefused(stranger, own, game, hashes, "a stranger");
        _threeRefused(sender, own, game, hashes, "A's registered courier");
        _threeRefused(address(relay), own, game, hashes, "the relay");
        _threeRefused(deployer, own, game, hashes, "the set's deployer");
        _threeRefused(address(timelock), own, game, hashes, "the timelock");
        _threeRefused(W2.a, own, game, hashes, "another account's live agent");
        _threeRefused(B.a, own, game, hashes, "another account");
        vm.prank(A.a);
        matching.revokeAgent();
        _threeRefused(W.a, own, game, hashes, "A's revoked agent");
        vm.revertToState(snap);
        vm.warp(endsAt);
        _threeRefused(W.a, own, game, hashes, "A's agent at its grant's end");
        vm.revertToState(snap);
        vm.prank(A.a);
        matching.grantAgent(W3.a, CAP, _inAnHour(), _noLines());
        _threeRefused(W.a, own, game, hashes, "the agent of grant 1 after grant 2");
        vm.revertToState(snap);
        // One who has granted A as its own agent: the relation runs one way.
        Signer memory X = _account("one who granted A");
        vm.prank(X.a);
        matching.grantAgent(A.a, CAP, _inAnHour(), _noLines());
        assertTrue(matching.isLiveAgent(X.a, A.a));
        _threeRefused(X.a, own, game, hashes, "one who granted A as its agent");
        vm.revertToState(snap);

        // An unauthorized intermediary with A as the transaction's origin: refused on its own address, and
        // nothing of A's is written; its grant call writes its own grant and none of A's.
        Intermediary inter = new Intermediary();
        bytes32 before = _cancelState(A.a, game, hashes);
        _refusedCall(
            A.a,
            address(inter),
            abi.encodeCall(
                Intermediary.forward, (address(matching), abi.encodeCall(OspexMatching.cancelOrder, (own.order)))
            ),
            _notAccountOrAgent(A.a, address(inter)),
            "an intermediary's cancel, A as origin"
        );
        _refusedCall(
            A.a,
            address(inter),
            abi.encodeCall(
                Intermediary.forward,
                (address(matching), abi.encodeCall(OspexMatching.raiseFloor, (A.a, game, address(moneyline), 0, 9)))
            ),
            _notAccountOrAgent(A.a, address(inter)),
            "an intermediary's floor, A as origin"
        );
        _refusedCall(
            A.a,
            address(inter),
            abi.encodeCall(Intermediary.forward, (address(matching), abi.encodeCall(OspexMatching.cancelAll, (A.a)))),
            _notAccountOrAgent(A.a, address(inter)),
            "an intermediary's cancel-all, A as origin"
        );
        vm.prank(A.a, A.a);
        inter.forward(address(matching), abi.encodeCall(OspexMatching.grantAgent, (W3.a, CAP, _inAnHour(), _noLines())));
        assertEq(matching.s_grantCount(address(inter)), 1, "the intermediary's own grant");
        assertTrue(matching.isLiveAgent(address(inter), W3.a));
        assertEq(matching.s_grantCount(A.a), 1, "a grant keyed to the origin");
        assertTrue(matching.isLiveAgent(A.a, W.a), "A's grant was replaced through an intermediary");
        assertEq(_cancelState(A.a, game, hashes), before, "an intermediary changed A's state");

        // The agent's and a stranger's grant, revoke and combined calls change only their own state.
        before = _cancelState(A.a, game, hashes);
        vm.startPrank(W.a);
        matching.grantAgent(W3.a, CAP, _inAnHour(), _noLines());
        matching.revokeAgent();
        matching.grantAgentAndRegisterCourier(W3.a, CAP, _inAnHour(), _noLines(), stranger);
        matching.registerCourier(relayKey);
        matching.unregisterCourier(relayKey);
        vm.stopPrank();
        assertEq(matching.s_grantCount(W.a), 2, "the agent's own grants");
        assertTrue(matching.isCourier(W.a, stranger), "the agent's own courier");
        assertEq(matching.s_grantCount(A.a), 1, "A's count moved");
        assertEq(matching.s_currentGrant(A.a), 1);
        assertTrue(matching.isLiveAgent(A.a, W.a));
        assertFalse(matching.isCourier(A.a, stranger), "A's couriers moved");
        assertFalse(matching.isCourier(A.a, relayKey));
        assertEq(_cancelState(A.a, game, hashes), before);
        _refusedCall(
            stranger,
            address(matching),
            abi.encodeCall(OspexMatching.revokeAgent, ()),
            abi.encodeWithSelector(OspexMatching.OspexMatching__NoGrantToRevoke.selector),
            "a stranger's revoke is its own, and it has no grant"
        );
        assertTrue(matching.isLiveAgent(A.a, W.a), "a stranger's revoke ended A's grant");

        // The live agent's three calls are keyed to A: A's version, floor and mark move, and W's do not.
        bytes32 wBefore = _cancelState(W.a, game, new bytes32[](0));
        uint128 version = matching.s_version(A.a);
        vm.startPrank(W.a);
        matching.cancelOrder(own.order);
        matching.raiseFloor(A.a, game, address(moneyline), 0, 9);
        matching.cancelAll(A.a);
        vm.stopPrank();
        assertTrue(matching.s_cancelledOrders(_hash(own)), "A's order was not marked by its agent");
        assertEq(
            matching.s_floors(A.a, version, keccak256(abi.encode(game, address(moneyline), int32(0)))), 9, "A's floor"
        );
        assertTrue(matching.s_version(A.a) != version, "A's version did not move");
        assertEq(_cancelState(W.a, game, new bytes32[](0)), wBefore, "the agent's own state moved");
        assertEq(matching.s_version(W.a), 0);
        assertEq(matching.getFloor(W.a, game, address(moneyline), 0), 0);
        // And the account's own, after its agent's: each of the three, as itself.
        version = matching.s_version(A.a);
        OspexMatching.SignedOrder memory fresh = _restBy(A, A.a, 0, game, Side.A, 200, 10_000);
        vm.startPrank(A.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, 3);
        matching.cancelOrder(fresh.order);
        matching.cancelAll(A.a);
        vm.stopPrank();
        assertTrue(matching.s_cancelledOrders(_hash(fresh)), "the account's own cancel");
        assertTrue(matching.s_version(A.a) != version, "the account's own cancel-all");
    }

    /// @dev `who` is refused each of the three cancels on A, by name, and A's state is as it was.
    function _threeRefused(
        address who,
        OspexMatching.SignedOrder memory own,
        uint256 game,
        bytes32[] memory hashes,
        string memory what
    ) internal {
        bytes32 before = _cancelState(A.a, game, hashes);
        bytes memory want = _notAccountOrAgent(A.a, who);
        _refusedCall(
            who,
            address(matching),
            abi.encodeCall(OspexMatching.cancelOrder, (own.order)),
            want,
            string.concat(what, ": cancel")
        );
        _refusedCall(
            who,
            address(matching),
            abi.encodeCall(OspexMatching.raiseFloor, (A.a, game, address(moneyline), 0, 9)),
            want,
            string.concat(what, ": floor")
        );
        _refusedCall(
            who,
            address(matching),
            abi.encodeCall(OspexMatching.cancelAll, (A.a)),
            want,
            string.concat(what, ": cancel-all")
        );
        assertEq(_cancelState(A.a, game, hashes), before, string.concat(what, ": A's state moved"));
        assertFalse(matching.s_cancelledOrders(_hash(own)), string.concat(what, ": the mark"));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Ruling 4. The sender field names the party whose authority the contract checked, an address and never a
    // role; the hub's copy carries the same fields; no path writes a guess.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cancelOrder, write `tx.origin` as the sender. Others turn it red: `msg.sender`
    /// written as the cancel event's account; the hub payload's fields in another order, or a fixed sender;
    /// the same in raiseFloor and in cancelAll. A check moved after an emit that still reverts is not one: the
    /// revert takes the log with it.
    function test_neverLine_theSenderFieldNamesThePartyWhoseAuthorityWasChecked() public {
        uint256 game = _verifiedGame();
        _fixDraw(0x0102030405060708);
        // Five callers: the account; its agent, a key; a contract account as itself; a contract agent as the
        // account's live agent; and a key with code attached, as an account and as an agent.
        WalletCode C = new WalletCode();
        _fundCoin(address(C));
        C.exec(address(matching), abi.encodeCall(OspexMatching.registerCourier, (sender)));
        WalletCode G = new WalletCode();
        Signer memory D = _key("a key with code");
        vm.signAndAttachDelegation(address(new WalletCode()), D.key);
        assertEq(D.a.code.length, 23, "the delegation designator");
        _fundCoin(D.a);
        _register(D.a, sender);

        _grantTo(A, W);
        C.exec(address(matching), abi.encodeCall(OspexMatching.grantAgent, (address(G), CAP, _inAnHour(), _noLines())));
        vm.prank(B.a);
        matching.grantAgent(D.a, CAP, _inAnHour(), _noLines());

        // The account, as itself: sender = A, account = A.
        _threeAnnounce(A.a, A.a, _restBy(A, A.a, 0, game, Side.A, 200, 10_000), game, "the account");
        // Its agent, a key: sender = W, account = A.
        _threeAnnounce(W.a, A.a, _restBy(A, A.a, 0, game, Side.A, 200, 10_000), game, "the agent");
        // A contract account, as itself, through its own code: sender = C, account = C.
        _threeAnnounceVia(
            address(C), address(C), _restBy(W, address(C), 1, game, Side.A, 200, 10_000), game, "a contract account"
        );
        // A contract agent, through its own code, for C: sender = G, account = C.
        _threeAnnounceVia(
            address(G), address(C), _restBy(W, address(C), 1, game, Side.A, 200, 10_000), game, "a contract agent"
        );
        // A key with code, as an account, through the code at its address: sender = D, account = D.
        _threeAnnounceVia(
            D.a, D.a, _restBy(D, D.a, 0, game, Side.A, 200, 10_000), game, "a key with code, as the account"
        );
        // The same key with code, as B's agent: sender = D, account = B.
        _threeAnnounceVia(D.a, B.a, _restBy(D, B.a, 1, game, Side.A, 200, 10_000), game, "a key with code, as an agent");
        // A live-agent intermediary: granted by A, it forwards as itself, and the address written is its own.
        Intermediary inter = new Intermediary();
        vm.prank(A.a);
        matching.grantAgent(address(inter), CAP, _inAnHour(), _noLines());
        OspexMatching.SignedOrder memory x = _restBy(A, A.a, 0, game, Side.A, 200, 10_000);
        _expectCancelled(x, A.a, address(inter));
        vm.prank(stranger, stranger);
        inter.forward(address(matching), abi.encodeCall(OspexMatching.cancelOrder, (x.order)));
        _expectVersionChanged(A.a, address(inter));
        vm.prank(stranger, stranger);
        inter.forward(address(matching), abi.encodeCall(OspexMatching.cancelAll, (A.a)));
        // A forwarder that is nobody's agent, calling for A with A as the origin: refused, nothing written, and
        // no event, since nothing was written to announce.
        Intermediary other = new Intermediary();
        bytes32 before = _cancelState(A.a, game, _hashes(x));
        _refusedCall(
            A.a,
            address(other),
            abi.encodeCall(Intermediary.forward, (address(matching), abi.encodeCall(OspexMatching.cancelAll, (A.a)))),
            _notAccountOrAgent(A.a, address(other)),
            "a forwarder for A"
        );
        assertEq(_cancelState(A.a, game, _hashes(x)), before);
    }

    /// @dev `caller`, pranked, makes the three cancels on `account`'s order `x`: each event names `account` and
    ///      `caller`, and its hub copy carries the same fields in the same order.
    function _threeAnnounce(
        address caller,
        address account,
        OspexMatching.SignedOrder memory x,
        uint256 game,
        string memory
    ) internal {
        _expectCancelled(x, account, caller);
        vm.prank(caller, caller);
        matching.cancelOrder(x.order);
        uint96 floor = matching.getFloor(account, game, address(moneyline), 0) + 1;
        _expectFloorRaised(account, game, floor, caller);
        vm.prank(caller, caller);
        matching.raiseFloor(account, game, address(moneyline), 0, floor);
        _expectVersionChanged(account, caller);
        vm.prank(caller, caller);
        matching.cancelAll(account);
    }

    /// @dev The same, through the code at `caller`'s address, driven by a stranger: the immediate caller at the
    ///      matching module is `caller`, and the transaction's origin is not.
    function _threeAnnounceVia(
        address caller,
        address account,
        OspexMatching.SignedOrder memory x,
        uint256 game,
        string memory
    ) internal {
        _expectCancelled(x, account, caller);
        vm.prank(stranger, stranger);
        WalletCode(caller).exec(address(matching), abi.encodeCall(OspexMatching.cancelOrder, (x.order)));
        uint96 floor = matching.getFloor(account, game, address(moneyline), 0) + 1;
        _expectFloorRaised(account, game, floor, caller);
        vm.prank(stranger, stranger);
        WalletCode(caller)
            .exec(
                address(matching),
                abi.encodeCall(OspexMatching.raiseFloor, (account, game, address(moneyline), 0, floor))
            );
        _expectVersionChanged(account, caller);
        vm.prank(stranger, stranger);
        WalletCode(caller).exec(address(matching), abi.encodeCall(OspexMatching.cancelAll, (account)));
    }

    function _expectCancelled(OspexMatching.SignedOrder memory x, address account, address who) internal {
        OspexMatching.OspexOrder memory o = x.order;
        assertEq(o.account, account, "the fixture's order is not the account's");
        vm.expectEmit(true, true, true, true, address(matching));
        emit OspexMatching.OrderCancelled(
            _hash(x),
            account,
            o.gameId,
            o.scorer,
            o.lineTicks,
            o.positionType,
            o.oddsTick,
            o.riskAmount,
            o.nonce,
            o.expiry,
            o.minFill,
            who
        );
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            matching.EVENT_ORDER_CANCELLED(),
            address(matching),
            abi.encode(
                _hash(x),
                account,
                o.gameId,
                o.scorer,
                o.lineTicks,
                o.positionType,
                o.oddsTick,
                o.riskAmount,
                o.nonce,
                o.expiry,
                o.minFill,
                who
            )
        );
    }

    function _expectFloorRaised(address account, uint256 game, uint96 floor, address who) internal {
        uint128 version = matching.s_version(account);
        bytes32 key = keccak256(abi.encode(game, address(moneyline), int32(0)));
        vm.expectEmit(true, true, true, true, address(matching));
        emit OspexMatching.FloorRaised(account, version, game, address(moneyline), 0, floor, key, who);
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            matching.EVENT_FLOOR_RAISED(),
            address(matching),
            abi.encode(account, version, game, address(moneyline), int32(0), floor, key, who)
        );
    }

    function _expectVersionChanged(address account, address who) internal {
        uint128 previous = matching.s_version(account);
        uint128 next = previous + 1 + uint128(uint64(bytes8(blockhash(block.number - 1))));
        vm.expectEmit(true, true, true, true, address(matching));
        emit OspexMatching.VersionChanged(account, previous, next, who);
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            matching.EVENT_VERSION_CHANGED(), address(matching), abi.encode(account, previous, next, who)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L244 (f), (g). A mark reaches one hash at one version and is undone by nothing; a cancel moves no money,
    // reverses no fill and revives no remainder.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cancelOrder, drop the current-version gate. Others turn it red: the mark cleared
    /// by grantAgent; the mark keyed by the account and the order number; a cancel writing `s_filledRisk[hash]
    /// = 0`; a cancel that pays coin.
    function test_neverLine_aMarkReachesOneHashAndACancelMovesNoMoney() public {
        uint256 fresh = vm.snapshotState();
        _markCases(Side.B);
        vm.revertToState(fresh);
        _markCases(Side.A);
    }

    function _markCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        _grantTo(A, W);
        OspexMatching.SignedOrder memory x = _rest(A, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory t = _take(A, game, takingSide, 200, 10_000);
        uint256 snap = vm.snapshotState();

        // Marked by the account: dead in both roles; the same ten fields signed again are the same hash, dead.
        vm.startPrank(A.a);
        matching.cancelOrder(x.order);
        matching.cancelOrder(t.order);
        vm.stopPrank();
        _restingSkipped(game, takingSide, x, CANCELLED, "marked, resting");
        _takingRefused(
            game,
            takingSide,
            t,
            _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, t),
            "marked, taking"
        );
        _restingSkipped(game, takingSide, _signed(x.order, A.key), CANCELLED, "signed again");
        // An allowance set to zero and back changes nothing; a regrant changes nothing; the mark is on the hash.
        vm.startPrank(A.a);
        _coin().approve(address(positions), 0);
        _coin().approve(address(positions), type(uint256).max);
        matching.grantAgent(W.a, CAP, _inAnHour(), _noLines());
        vm.stopPrank();
        assertTrue(matching.s_cancelledOrders(_hash(x)), "the mark after a regrant");
        _restingSkipped(game, takingSide, x, CANCELLED, "after an allowance round trip and a regrant");
        _takingRefused(
            game,
            takingSide,
            t,
            _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, t),
            "after a regrant, taking"
        );
        // The same fields at the new version are another hash, live, and the old hash's mark stays.
        vm.prank(A.a);
        matching.cancelAll(A.a);
        uint128 version = matching.s_version(A.a);
        OspexMatching.SignedOrder memory y = _signed(_withNonce(x.order, _nonce(version, 0, _no(x.order.nonce))), A.key);
        assertTrue(_hash(y) != _hash(x), "the same hash at another version");
        assertFalse(matching.s_cancelledOrders(_hash(y)));
        _restingFills(game, takingSide, y, "the same fields at the new version");
        assertTrue(matching.s_cancelledOrders(_hash(x)), "the old mark");
        // The old-version order and a future-version order cannot be marked: refused by name, nothing written.
        OspexMatching.SignedOrder memory old = _restNonce(A, A.a, _nonce(0, 0, 77), game, restingSide, 200, 10_000);
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.cancelOrder, (old.order)),
            abi.encodeWithSelector(
                OspexMatching.OspexMatching__OrderNotAtCurrentVersion.selector, _hash(old), uint128(0), version
            ),
            "an old-version order"
        );
        assertFalse(matching.s_cancelledOrders(_hash(old)), "a mark on an old-version order");
        OspexMatching.SignedOrder memory future =
            _restNonce(A, A.a, _nonce(version + 5, 0, 77), game, restingSide, 200, 10_000);
        _refusedCall(
            W.a,
            address(matching),
            abi.encodeCall(OspexMatching.cancelOrder, (future.order)),
            abi.encodeWithSelector(
                OspexMatching.OspexMatching__OrderNotAtCurrentVersion.selector, _hash(future), version + 5, version
            ),
            "a future-version order"
        );
        assertFalse(matching.s_cancelledOrders(_hash(future)), "a mark on a future-version order");
        vm.revertToState(snap);

        // A cancel after a partial fill: the fill stands, nothing moves, and the remainder is dead. Each of the
        // three cancelling calls, by the agent.
        _cross(sender, _take(tk, game, takingSide, 200, 4_000), _list(x));
        assertEq(_filled(x), 4_000, "the partial fill");
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        uint256 filled = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            vm.revertToState(filled);
            bytes32 before = _moneyPrint(market, x);
            vm.prank(W.a);
            if (i == 0) matching.cancelOrder(x.order);
            else if (i == 1) matching.raiseFloor(A.a, game, address(moneyline), 0, _no(x.order.nonce + 1));
            else matching.cancelAll(A.a);
            assertEq(_moneyPrint(market, x), before, "a cancel moved coin, a position or a filled amount");
            assertEq(_filled(x), 4_000, "a cancel reset the filled amount");
            _assertPosition(market, A.a, restingSide, 4_000, 4_000, "the fill made before the cancel");
            _restingSkipped(game, takingSide, x, CANCELLED, "the remainder after a cancel");
            assertEq(_filled(x), 4_000);
        }
        vm.revertToState(snap);
    }

    /// @dev Coin and positions of everyone here, the positions module's and the matching module's coin, what is
    ///      held for the account, the market's total and the order's filled amount, hashed.
    function _moneyPrint(uint256 market, OspexMatching.SignedOrder memory x) internal view returns (bytes32) {
        IERC20 coin = _coin();
        bytes32 coins = keccak256(
            abi.encode(
                coin.balanceOf(A.a),
                coin.balanceOf(W.a),
                coin.balanceOf(tk.a),
                coin.balanceOf(m1.a),
                coin.balanceOf(sender),
                coin.balanceOf(address(positions)),
                coin.balanceOf(address(matching))
            )
        );
        bytes32 held = keccak256(abi.encode(positions.s_held(market, A.a), positions.s_heldTotal(market), _filled(x)));
        return keccak256(abi.encode(coins, held, _positionsPrint(market)));
    }

    /// @dev The two positions of the account, the agent and the taking account on a market, hashed.
    function _positionsPrint(uint256 market) internal view returns (bytes32 h) {
        address[3] memory who = [A.a, W.a, tk.a];
        for (uint256 i; i < 3; ++i) {
            Position memory a = _position(market, who[i], Side.A);
            Position memory b = _position(market, who[i], Side.B);
            h = keccak256(abi.encode(h, a.risk, a.profit, a.claimed, b.risk, b.profit, b.claimed));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L244 (e), L76, L304. A floor cancels below it on its own line at its own version, crosses nothing, may
    // reach the top order number, and leaves that number signable.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, key the floor by the line alone, `s_floors[r.account][0][marketKey]`.
    /// Others turn it red: `<=` at the floor; the floor keyed without the account; raiseFloor refusing the top;
    /// the floor read at the taking check from version 0.
    function test_neverLine_aFloorCancelsBelowItOnItsLineAtItsVersionAndLeavesTheTop() public {
        uint256 fresh = vm.snapshotState();
        _floorCases(Side.B);
        vm.revertToState(fresh);
        _floorCases(Side.A);
    }

    function _floorCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        _grantTo(A, W);
        OspexMatching.SignedOrder memory five = _restNonce(A, A.a, _nonce(0, 0, 5), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory nearTop =
            _restNonce(A, A.a, _nonce(0, 0, TOP - 1), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory top = _restNonce(A, A.a, _nonce(0, 0, TOP), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory agentTop =
            _restNonce(W, A.a, _nonce(0, 1, TOP), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory onSpread = _signed(
            _order(
                A.a,
                game,
                address(spread),
                -35,
                restingSide,
                _tick(200),
                10_000,
                _nonce(0, 0, 5),
                vm.getBlockTimestamp() + 1 days
            ),
            A.key
        );
        OspexMatching.SignedOrder memory bs = _restNonce(B, B.a, _nonce(0, 0, 5), game, restingSide, 200, 10_000);
        bytes32 key = keccak256(abi.encode(game, address(moneyline), int32(0)));
        uint256 snap = vm.snapshotState();

        // The agent raises A's floor on the moneyline to the top: 5 and TOP - 1 are dead, in both roles; TOP
        // fills, the account's and the agent's; the spread's 5 fills; B's 5 fills.
        vm.prank(W.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, TOP);
        assertEq(matching.getFloor(A.a, game, address(moneyline), 0), TOP);
        assertEq(matching.s_floors(A.a, 0, key), TOP);
        _restingSkipped(game, takingSide, five, CANCELLED, "order number 5 under a floor at the top");
        _restingSkipped(game, takingSide, nearTop, CANCELLED, "order number TOP - 1 under a floor at the top");
        OspexMatching.SignedOrder memory t5 = _takeNonce(A, A.a, _nonce(0, 0, 5), game, takingSide, 200, 10_000);
        _takingRefused(
            game, takingSide, t5, _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, t5), "taking, 5"
        );
        _restingFills(game, takingSide, top, "the top order number survives every floor");
        _restingFills(game, takingSide, agentTop, "the agent's order at the top order number");
        _takingFills(
            game, takingSide, _takeNonce(A, A.a, _nonce(0, 0, TOP), game, takingSide, 200, 10_000), "taking, at the top"
        );
        _cross(sender, _takeOn(tk, game, address(spread), -35, takingSide, 200, 10_000), _list(onSpread));
        assertEq(_filled(onSpread), 10_000, "another line of the same account");
        _restingFills(game, takingSide, bs, "the same line of another account");
        // The floor cannot rise further, and cannot fall.
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.raiseFloor, (A.a, game, address(moneyline), 0, TOP)),
            abi.encodeWithSelector(OspexMatching.OspexMatching__FloorMustRise.selector, TOP, TOP),
            "the floor at the top again"
        );
        _refusedCall(
            W.a,
            address(matching),
            abi.encodeCall(OspexMatching.raiseFloor, (A.a, game, address(moneyline), 0, 1)),
            abi.encodeWithSelector(OspexMatching.OspexMatching__FloorMustRise.selector, TOP, uint96(1)),
            "a lower floor"
        );
        // A floor above the top order number is no argument the call takes: the bytes are refused at the
        // door with no data, the floor is as it was, and the top order's twin on the other version still fills.
        bytes memory wide = abi.encodeWithSelector(
            OspexMatching.raiseFloor.selector, A.a, game, address(moneyline), int32(0), uint256(TOP) + 1
        );
        vm.prank(A.a);
        (bool ok, bytes memory err) = address(matching).call(wide);
        assertFalse(ok, "a floor of 2^96 was taken");
        assertEq(err.length, 0, "a floor of 2^96 was refused with data");
        assertEq(matching.getFloor(A.a, game, address(moneyline), 0), TOP);
        // The one number the floor leaves dies by its own cancel, or by a successful cancel-all: at the new
        // version the floor is 0 and order number 0 fills.
        OspexMatching.SignedOrder memory top2 = _restNonce(A, A.a, _nonce(0, 0, TOP), game, takingSide, 200, 10_000);
        vm.prank(W.a);
        matching.cancelAll(A.a);
        uint128 version = matching.s_version(A.a);
        assertEq(matching.getFloor(A.a, game, address(moneyline), 0), 0, "the new version's floor");
        assertEq(matching.s_floors(A.a, 0, key), TOP, "the old version's floor stays");
        _restingSkipped(game, _other(takingSide), top2, CANCELLED, "the top order number at the old version");
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(version, 0, 0), game, restingSide, 200, 10_000),
            "order number 0 at the new version"
        );
        _restingFills(
            game,
            takingSide,
            _restNonce(W, A.a, _nonce(version, 1, 0), game, restingSide, 200, 10_000),
            "the agent's order number 0 at the new version"
        );
        _takingFills(
            game,
            takingSide,
            _takeNonce(A, A.a, _nonce(version, 0, 0), game, takingSide, 200, 10_000),
            "taking, order number 0 at the new version"
        );
        vm.revertToState(snap);

        // A floor at 6 kills 5 and leaves 6 and 7, at this version; and a floor is the account's own: B's floor
        // on the same line leaves A's 5 alone.
        vm.prank(B.a);
        matching.raiseFloor(B.a, game, address(moneyline), 0, 6);
        _restingFills(game, takingSide, five, "A's 5 under B's floor at 6");
        vm.prank(A.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, 6);
        _restingSkipped(
            game,
            takingSide,
            _restNonce(W, A.a, _nonce(0, 1, 5), game, restingSide, 200, 10_000),
            CANCELLED,
            "the agent's 5 under A's floor at 6"
        );
        _restingFills(
            game, takingSide, _restNonce(A, A.a, _nonce(0, 0, 6), game, restingSide, 200, 10_000), "6 at a floor of 6"
        );
        _restingFills(
            game, takingSide, _restNonce(W, A.a, _nonce(0, 1, 7), game, restingSide, 200, 10_000), "the agent's 7"
        );
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Item 5, R2; ruling 6. An agent registers no courier for the account, and nothing is granted, revoked,
    // registered or cancelled by signature.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.sol, add `registerCourierFor(address account, address courier)`, open to the
    /// account's live agent, calling `_register(account, courier)`. Another turns it red: a `grantAgentBySig`
    /// that grants for the address a signature recovers to.
    function test_neverLine_anAgentRegistersNoCourierForTheAccountAndNothingIsGrantedBySignature() public {
        uint256 game = _verifiedGame();
        _grantTo(A, W);
        address courier = makeAddr("a courier the agent names");
        bytes32 before = _cancelState(A.a, game, new bytes32[](0));

        // The agent's own registration and drop move the agent's map, not the account's.
        vm.startPrank(W.a);
        matching.registerCourier(courier);
        assertTrue(matching.isCourier(W.a, courier));
        assertFalse(matching.isCourier(A.a, courier), "the agent registered a courier for the account");
        matching.unregisterCourier(courier);
        assertFalse(matching.isCourier(W.a, courier));
        assertTrue(matching.isCourier(A.a, sender), "the agent dropped the account's courier");
        // The combined call is the caller's own too.
        matching.grantAgentAndRegisterCourier(stranger, CAP, _inAnHour(), _noLines(), courier);
        vm.stopPrank();
        assertTrue(matching.isCourier(W.a, courier));
        assertFalse(matching.isCourier(A.a, courier));
        assertEq(matching.s_grantCount(A.a), 1);
        // A door that takes an account and a courier: no such function, so the bytes are refused and A's map
        // does not move.
        _noSuchDoor(
            W.a, abi.encodeWithSignature("registerCourierFor(address,address)", A.a, courier), "registerCourierFor"
        );
        _noSuchDoor(
            W.a, abi.encodeWithSignature("unregisterCourierFor(address,address)", A.a, sender), "unregisterCourierFor"
        );
        assertFalse(matching.isCourier(A.a, courier));
        assertTrue(matching.isCourier(A.a, sender));
        // Nothing by signature: a grant, a revoke, a registration or a cancel shaped as a call that carries a
        // signature is refused with no effect, whatever the bytes.
        bytes memory sig = _signature(A.key, keccak256("anything"));
        _noSuchDoor(
            stranger,
            abi.encodeWithSignature(
                "grantAgentBySig(address,address,uint256,uint64,(uint256,address,int32)[],bytes)",
                A.a,
                stranger,
                CAP,
                _inAnHour(),
                _noLines(),
                sig
            ),
            "grantAgentBySig"
        );
        _noSuchDoor(stranger, abi.encodeWithSignature("revokeAgentBySig(address,bytes)", A.a, sig), "revokeAgentBySig");
        _noSuchDoor(
            stranger,
            abi.encodeWithSignature("registerCourierBySig(address,address,bytes)", A.a, courier, sig),
            "registerCourierBySig"
        );
        _noSuchDoor(stranger, abi.encodeWithSignature("cancelAllBySig(address,bytes)", A.a, sig), "cancelAllBySig");
        assertEq(_cancelState(A.a, game, new bytes32[](0)), before, "something by signature");
        assertTrue(matching.isLiveAgent(A.a, W.a));
        assertEq(matching.s_grantCount(A.a), 1);
    }
}

/// @notice The version: drawn by the contract and never supplied; its top, refused by name with nothing written;
///         what a presigned successor-version order can do, and what a revoke does to it; every route and either
///         side reading the version, the current grant, the floor and the mark; and the lockout, within the
///         finite domain.
contract OspexAgentVersionTest is AgentBase {
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L243 as ruled. No supplied or arbitrary landing version; a successor-version order can fill; revoke stops
    // it.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cancelAll, `next = current + 1`, the draw dropped. Others turn it red: the draw
    /// read from the current block's hash, which is zero; a version the caller supplies.
    function test_neverLine_theVersionIsDrawnByTheContractAndAPresignedSuccessorOrderCanFill() public {
        uint256 fresh = vm.snapshotState();
        _versionCases(Side.B);
        vm.revertToState(fresh);
        _versionCases(Side.A);
    }

    function _versionCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        _grantTo(A, W);
        uint256 snap = vm.snapshotState();

        // The call takes the account and nothing else: a version beside it finds no door.
        _noSuchDoor(
            A.a, abi.encodeWithSignature("cancelAll(address,uint128)", A.a, uint128(5)), "cancelAll with a version"
        );
        _noSuchDoor(
            A.a, abi.encodeWithSignature("cancelAll(address,uint256)", A.a, uint256(5)), "cancelAll with a number"
        );
        assertEq(matching.s_version(A.a), 0);

        // Two cancels under two previous-block hashes land at old + 1 + the hash's first eight bytes, and differ.
        _fixDraw(0x1111111111111111);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        uint128 v1 = matching.s_version(A.a);
        assertEq(v1, 1 + 0x1111111111111111, "the first draw");
        vm.revertToState(snap);
        _fixDraw(0x2222222222222222);
        vm.prank(W.a);
        matching.cancelAll(A.a);
        uint128 v2 = matching.s_version(A.a);
        assertEq(v2, 1 + 0x2222222222222222, "the second draw");
        // A third, from v2: the draw is added to the version as it stands.
        _fixDraw(3);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), v2 + 4, "the third cancel, from the second version");
        vm.revertToState(snap);

        // The old + 1 presign: after a nonzero draw it names a version that is not the account's, dead in both
        // roles; with the draw zero it names the actual successor and fills.
        OspexMatching.SignedOrder memory plusOne = _restNonce(A, A.a, _nonce(1, 0, 10), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory plusOneT = _takeNonce(A, A.a, _nonce(1, 0, 11), game, takingSide, 200, 10_000);
        _fixDraw(7);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), 8);
        _restingSkipped(game, takingSide, plusOne, CANCELLED, "old + 1 after a draw of 7, resting");
        _takingRefused(
            game,
            takingSide,
            plusOneT,
            _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, plusOneT),
            "old + 1 after a draw of 7, taking"
        );
        vm.revertToState(snap);
        _fixDraw(0);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), 1);
        _restingFills(game, takingSide, plusOne, "old + 1 after a draw of 0, resting");
        _takingFills(game, takingSide, plusOneT, "old + 1 after a draw of 0, taking");
        vm.revertToState(snap);

        // The agent signs for the computed successor: dead before the cancel, live after it; a revoke stops the
        // other orders it signed for that version, in both roles.
        _fixDraw(0xab);
        uint128 successor = matching.s_version(A.a) + 1 + 0xab;
        OspexMatching.SignedOrder memory w1 =
            _restNonce(W, A.a, _nonce(successor, 1, 1), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory w2 =
            _restNonce(W, A.a, _nonce(successor, 1, 2), game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory wt = _takeNonce(W, A.a, _nonce(successor, 1, 3), game, takingSide, 200, 10_000);
        _restingSkipped(game, takingSide, w1, CANCELLED, "a successor-version order before the cancel");
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), successor, "the computed successor");
        _restingFills(game, takingSide, w1, "the presigned successor order after the cancel");
        vm.prank(A.a);
        matching.revokeAgent();
        (, uint64 endsAt,,) = matching.getGrant(A.a, 1);
        _restingSkipped(game, takingSide, w2, GRANT_GONE, "the revoke stops the other presigned order");
        _takingRefused(
            game, takingSide, wt, _grantGone(wt, 1, 0, endsAt), "the revoke stops the presigned taking order"
        );
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L244 (c), L245 as ruled. No caller's number, no wrap, no reuse, no version without a signable order
    // number; the top refuses by name with nothing written.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cancelAll, drop the top check and compute `next` in an unchecked block: the step
    /// past the top wraps. Others turn it red: the top check dropped with checked arithmetic, a panic where the
    /// name is asserted; the floors of the old version copied into the new.
    function test_neverLine_theVersionHasATopRefusedByNameAndEveryVersionHasSignableOrderNumbers() public {
        uint256 fresh = vm.snapshotState();
        _topCases(Side.B);
        vm.revertToState(fresh);
        _topCases(Side.A);
    }

    function _topCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint128 max = type(uint128).max;
        uint64 draw = 0x0f0f0f0f0f0f0f0f;
        _grantTo(A, W);
        uint256 snap = vm.snapshotState();

        // Onto the maximum exactly: the cancel succeeds.
        _fixDraw(draw);
        _writeVersion(A.a, max - 1 - draw);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), max, "onto the maximum");
        // The next, even with the draw zero, by the account and by its agent: refused by name, nothing written.
        _fixDraw(0);
        bytes32 before = _cancelState(A.a, game, new bytes32[](0));
        bytes memory atTop = abi.encodeWithSelector(OspexMatching.OspexMatching__VersionAtTop.selector, A.a, max);
        _refusedCall(
            A.a, address(matching), abi.encodeCall(OspexMatching.cancelAll, (A.a)), atTop, "past the top, the account"
        );
        _refusedCall(
            W.a, address(matching), abi.encodeCall(OspexMatching.cancelAll, (A.a)), atTop, "past the top, the agent"
        );
        assertEq(_cancelState(A.a, game, new bytes32[](0)), before, "a refused cancel-all wrote something");
        assertEq(matching.s_version(A.a), max);
        // At the maximum the account still places: order numbers 0 and the top, both roles, grant 0 and the
        // agent's.
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(max, 0, 0), game, restingSide, 200, 10_000),
            "at the top, order number 0"
        );
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(max, 0, TOP), game, restingSide, 200, 10_000),
            "at the top, the top number"
        );
        _takingFills(
            game,
            takingSide,
            _takeNonce(A, A.a, _nonce(max, 0, 0), game, takingSide, 200, 10_000),
            "at the top, taking, 0"
        );
        _takingFills(
            game,
            takingSide,
            _takeNonce(A, A.a, _nonce(max, 0, TOP), game, takingSide, 200, 10_000),
            "at the top, taking, top"
        );
        _restingFills(
            game,
            takingSide,
            _restNonce(W, A.a, _nonce(max, 1, 0), game, restingSide, 200, 10_000),
            "at the top, the agent's 0"
        );
        // The other cancels still work at the top.
        vm.prank(W.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, 5);
        assertEq(matching.getFloor(A.a, game, address(moneyline), 0), 5);
        vm.revertToState(snap);

        // The control, one step lower: lands one below the maximum; after it both order numbers fill; one more,
        // with the draw zero, lands on the maximum, and both fill again.
        _fixDraw(draw);
        _writeVersion(A.a, max - 2 - draw);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), max - 1, "one below the maximum");
        _restingFills(
            game, takingSide, _restNonce(A, A.a, _nonce(max - 1, 0, 0), game, restingSide, 200, 10_000), "one below, 0"
        );
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(max - 1, 0, TOP), game, restingSide, 200, 10_000),
            "one below, top"
        );
        _fixDraw(0);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), max, "the last step");
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(max, 0, 0), game, restingSide, 200, 10_000),
            "at the top after the last step, 0"
        );
        _takingFills(
            game,
            takingSide,
            _takeNonce(A, A.a, _nonce(max, 0, TOP), game, takingSide, 200, 10_000),
            "at the top after the last step, top"
        );
        vm.revertToState(snap);

        // A step that would pass the top by one is refused: the draw plus one is exactly one too many.
        _fixDraw(draw);
        _writeVersion(A.a, max - draw);
        _refusedCall(
            A.a,
            address(matching),
            abi.encodeCall(OspexMatching.cancelAll, (A.a)),
            abi.encodeWithSelector(OspexMatching.OspexMatching__VersionAtTop.selector, A.a, max - draw),
            "one past the top"
        );
        assertEq(matching.s_version(A.a), max - draw);
        vm.revertToState(snap);

        // The floors belong to a version: a floor at the top order number at one version, and the next version's
        // floor is zero, so order number 0 fills there.
        _fixDraw(5);
        vm.prank(A.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, TOP);
        vm.prank(A.a);
        matching.cancelAll(A.a);
        assertEq(matching.s_version(A.a), 6);
        assertEq(matching.getFloor(A.a, game, address(moneyline), 0), 0, "the new version's floor");
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(6, 0, 0), game, restingSide, 200, 10_000),
            "order number 0 at the new version"
        );
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L244 (d). No fill route and neither side skips the version, the current grant, the floor or the mark.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkTaking, drop `version != s_version[t.account]` from the cancelled test.
    /// Others turn it red: the mark, the floor or the grant's standing dropped from _checkTaking; each of the
    /// four dropped from _leg.
    function test_neverLine_everyRouteAndEitherSideReadsTheVersionTheGrantTheFloorAndTheMark() public {
        uint256 fresh = vm.snapshotState();
        _routeCases(Side.B);
        vm.revertToState(fresh);
        _routeCases(Side.A);
    }

    function _routeCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        _grantTo(A, W);
        (, uint64 endsAt,,) = matching.getGrant(A.a, 1);
        uint256 snap = vm.snapshotState();

        // The control: three live resting orders fill at every place.
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 30_000);
        _cross(
            sender,
            taking,
            _list(
                _rest(m1, game, restingSide, 200, 10_000),
                _rest(A, game, restingSide, 200, 10_000),
                _rest(B, game, restingSide, 200, 10_000)
            )
        );
        assertEq(_filled(taking), 30_000, "the control");
        vm.revertToState(snap);

        for (uint8 kind; kind < 4; ++kind) {
            vm.revertToState(snap);
            OspexMatching.SignedOrder memory x;
            OspexMatching.SignedOrder memory t;
            uint8 reason = CANCELLED;
            bytes memory want;
            if (kind == 0) {
                // The version: signed at version 0, then the account's version moves.
                x = _rest(A, game, restingSide, 200, 10_000);
                t = _take(A, game, takingSide, 200, 10_000);
                vm.prank(A.a);
                matching.cancelAll(A.a);
                want = _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, t);
            } else if (kind == 1) {
                // The current grant: signed under grant 1, then the grant is revoked.
                x = _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
                t = _takeBy(W, A.a, 1, game, takingSide, 200, 10_000);
                vm.prank(A.a);
                matching.revokeAgent();
                reason = GRANT_GONE;
                want = _grantGone(t, 1, 0, endsAt);
            } else if (kind == 2) {
                // The floor: raised past both order numbers.
                x = _rest(A, game, restingSide, 200, 10_000);
                t = _take(A, game, takingSide, 200, 10_000);
                vm.prank(W.a);
                matching.raiseFloor(A.a, game, address(moneyline), 0, _no(t.order.nonce + 1));
                want = _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, t);
            } else {
                // The mark.
                x = _rest(A, game, restingSide, 200, 10_000);
                t = _take(A, game, takingSide, 200, 10_000);
                vm.startPrank(W.a);
                matching.cancelOrder(x.order);
                matching.cancelOrder(t.order);
                vm.stopPrank();
                want = _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, t);
            }
            string memory what = string.concat("kind ", vm.toString(kind));
            // The resting order at the first, the middle and the last place of three: skipped for its reason,
            // the two beside it fill, and the Cross says so.
            for (uint256 place; place < 3; ++place) {
                OspexMatching.SignedOrder[] memory three = new OspexMatching.SignedOrder[](3);
                OspexMatching.SignedOrder memory one = _rest(m1, game, restingSide, 200, 10_000);
                OspexMatching.SignedOrder memory two = _rest(B, game, restingSide, 200, 10_000);
                three[place] = x;
                three[place == 0 ? 1 : 0] = one;
                three[place == 2 ? 1 : 2] = two;
                OspexMatching.SignedOrder memory tk3 = _take(tk, game, takingSide, 200, 30_000);
                vm.recordLogs();
                _cross(sender, tk3, three);
                Skip[] memory skips = _skips(vm.getRecordedLogs());
                assertEq(skips.length, 1, string.concat(what, ": one skip record"));
                _assertSkip(skips[0], x, tk3, reason, what);
                assertEq(_filled(x), 0, string.concat(what, ": the dead order filled"));
                assertEq(_filled(one), 10_000, string.concat(what, ": the order before or after it"));
                assertEq(_filled(two), 10_000, string.concat(what, ": the other order"));
                assertEq(_filled(tk3), 20_000, string.concat(what, ": the taking order"));
            }
            // The taking order: the Cross is refused by name.
            _takingRefused(game, takingSide, t, want, string.concat(what, ": taking"));
        }
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // L245 as ruled. The lockout, within the finite domain: whatever the agent sends, the account can place an
    // order that fills, cancel everything, and place another that fills.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.raiseFloor, take the floor as `uint256` and keep it in a `uint256` mapping: a
    /// caller-named floor above the top order number is accepted, and the boundary order cannot fill. The
    /// agent here sends that door's bytes without asserting their refusal, so the break is seen at the
    /// recovery and not at the door. Another turns it red: `<=` at the floor.
    function test_neverLine_theLockoutWithinTheFiniteDomain() public {
        uint256 game = _verifiedGame();
        _grantTo(A, W);
        // A fixed sequence of the agent's calls, each followed by the account's recovery.
        _recovers(game, Side.B, "before anything");
        vm.prank(W.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, TOP);
        _recovers(game, Side.B, "after a floor at the top");
        vm.prank(W.a);
        matching.cancelAll(A.a);
        _recovers(game, Side.A, "after a cancel-all");
        vm.prank(W.a);
        matching.raiseFloor(A.a, game, address(moneyline), 0, TOP);
        OspexMatching.SignedOrder memory topOrder =
            _restNonce(A, A.a, _nonce(matching.s_version(A.a), 0, TOP), game, Side.A, 199, 10_000);
        vm.prank(W.a);
        matching.cancelOrder(topOrder.order);
        _recovers(game, Side.B, "after a floor at the top and a mark on the top number");
        for (uint256 i; i < 5; ++i) {
            vm.prank(W.a);
            matching.cancelAll(A.a);
            vm.prank(W.a);
            matching.raiseFloor(A.a, game, address(moneyline), 0, uint96(1 + i));
        }
        _recovers(game, Side.A, "after five cancel-alls and floors");
        // The door that takes a wider floor: whatever it answers, the account recovers.
        vm.prank(W.a);
        (bool ok,) = address(matching)
            .call(
                abi.encodeWithSelector(
                    OspexMatching.raiseFloor.selector, A.a, game, address(moneyline), int32(0), uint256(TOP) + 1
                )
            );
        ok;
        _recovers(game, Side.B, "after the agent asked for a floor above the top");
        vm.prank(W.a);
        (ok,) = address(matching)
            .call(
                abi.encodeWithSignature(
                    "raiseFloor(address,uint256,address,int32,uint256)",
                    A.a,
                    game,
                    address(moneyline),
                    int32(0),
                    type(uint256).max
                )
            );
        _recovers(game, Side.A, "after the agent asked for a floor of 2^256 - 1");
    }

    /// Any sequence of the agent's cancelling calls, with any arguments; after each, the account recovers.
    /// Break: as the fixed sequence's.
    function testFuzz_neverLine_theLockoutWithinTheFiniteDomain(uint256 seed, uint96 floorArg, uint8 steps) public {
        uint256 game = _verifiedGame();
        _grantTo(A, W);
        steps = uint8(bound(steps, 1, 6));
        for (uint256 i; i < steps; ++i) {
            uint256 pick = uint256(keccak256(abi.encode(seed, i))) % 4;
            if (pick == 0) {
                vm.prank(W.a);
                matching.cancelAll(A.a);
            } else if (pick == 1) {
                uint96 current = matching.getFloor(A.a, game, address(moneyline), 0);
                if (current < TOP) {
                    uint96 next = floorArg > current ? floorArg : current + 1;
                    vm.prank(W.a);
                    matching.raiseFloor(A.a, game, address(moneyline), 0, next);
                }
            } else if (pick == 2) {
                // the cast takes the low bits of a hash: any order number
                // forge-lint: disable-next-line(unsafe-typecast)
                uint96 number = uint96(uint256(keccak256(abi.encode(seed, i, "n"))));
                OspexMatching.SignedOrder memory any =
                    _restNonce(A, A.a, _nonce(matching.s_version(A.a), 0, number), game, Side.A, 199, 10_000);
                vm.prank(W.a);
                matching.cancelOrder(any.order);
            } else {
                vm.prank(W.a);
                (bool ok,) = address(matching)
                    .call(
                        abi.encodeWithSelector(
                            OspexMatching.raiseFloor.selector,
                            A.a,
                            game,
                            address(moneyline),
                            int32(0),
                            uint256(floorArg) + uint256(TOP) + 1
                        )
                    );
                ok;
            }
            _recovers(game, i % 2 == 0 ? Side.B : Side.A, "a fuzzed step");
        }
    }

    /// @dev The recovery: the account places an order at its current version with the top order number, which no
    ///      floor cancels, at a price the agent's marks above do not share, so its hash is unmarked, and it fills;
    ///      the account cancels everything; and it places another at the new version, order number 0, which fills.
    ///      Every step with the version under the top.
    function _recovers(uint256 game, Side takingSide, string memory what) internal {
        Side restingSide = _other(takingSide);
        assertLt(matching.s_version(A.a), type(uint128).max, string.concat(what, ": the version at the top"));
        uint128 version = matching.s_version(A.a);
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(version, 0, TOP), game, restingSide, 198, 10_000),
            string.concat(what, ": the first order")
        );
        vm.prank(A.a);
        matching.cancelAll(A.a);
        uint128 next = matching.s_version(A.a);
        assertTrue(next != version, string.concat(what, ": the version did not move"));
        _restingFills(
            game,
            takingSide,
            _restNonce(A, A.a, _nonce(next, 0, 0), game, restingSide, 200, 10_000),
            string.concat(what, ": the second order")
        );
        _takingFills(
            game,
            takingSide,
            _takeNonce(A, A.a, _nonce(next, 0, 1), game, takingSide, 200, 10_000),
            string.concat(what, ": a taking order")
        );
    }
}

/// @notice Ruling 6, the key rule: the fill verifies one key signature against the resolved signer and asks no
///         wallet, no agent and no verifier anything; a wallet's yes authorizes nothing and its no refuses
///         nothing; a key with code attached signs as a key; a contract's own signature policy is not accepted.
contract OspexAgentKeyRuleTest is AgentBase {
    /// @dev The accesses of a Cross that must fill, recorded from its first call to its last.
    function _crossRecorded(OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
        internal
        returns (VmSafe.AccountAccess[] memory acc)
    {
        vm.startStateDiffRecording();
        _cross(sender, taking, resting);
        acc = vm.stopAndReturnStateDiff();
    }

    /// @dev Among the recorded accesses: no call of any kind by the matching module reached an address in
    ///      `never`, the funded account, the resolved agent, a wallet's code or a fallback verifier; the
    ///      matching module called the positions module, the core and the recovery precompile, and nothing else;
    ///      and no call by anyone carried the wallet question's selector. The recording is live: the matching
    ///      module's calls are counted and must be there.
    function _assertNeverAsked(VmSafe.AccountAccess[] memory acc, address[] memory never, string memory what)
        internal
        view
    {
        uint256 calls;
        for (uint256 i; i < acc.length; ++i) {
            VmSafe.AccountAccessKind k = acc[i].kind;
            bool isCall = k == VmSafe.AccountAccessKind.Call || k == VmSafe.AccountAccessKind.StaticCall
                || k == VmSafe.AccountAccessKind.DelegateCall || k == VmSafe.AccountAccessKind.CallCode;
            if (!isCall) continue;
            if (acc[i].data.length >= 4) {
                assertTrue(
                    bytes4(acc[i].data) != IERC1271.isValidSignature.selector,
                    string.concat(what, ": a wallet was asked its signature question")
                );
            }
            if (acc[i].accessor != address(matching)) continue;
            ++calls;
            for (uint256 j; j < never.length; ++j) {
                assertTrue(
                    acc[i].account != never[j],
                    string.concat(
                        what, ": the matching module called an account, an agent, a wallet's code or a verifier"
                    )
                );
            }
            assertTrue(
                acc[i].account == address(positions) || acc[i].account == address(core) || acc[i].account == address(1),
                string.concat(
                    what,
                    ": the matching module called something other than the positions module, the core and the recovery precompile"
                )
            );
        }
        assertGt(calls, 2, string.concat(what, ": the recording saw no Cross"));
    }

    function _never(address a, address b, address c) internal pure returns (address[] memory n) {
        n = new address[](3);
        n[0] = a;
        n[1] = b;
        n[2] = c;
    }

    /// @dev A contract account made ready: funded, the sender registered, through its own code.
    function _wallet(WalletCode.Mode mode) internal returns (WalletCode w) {
        w = new WalletCode();
        w.setMode(mode);
        _fundCoin(address(w));
        w.exec(address(matching), abi.encodeCall(OspexMatching.registerCourier, (sender)));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Ruling 6. The fill never asks: a wallet's answer neither authorizes a bad key signature nor refuses a
    // good one, because it is never asked.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkSigned, after the recovery, make the wallet's call with its result ignored,
    /// `signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (orderHash, signed.signature)));`: the
    /// zero-call assertion goes red. Others turn it red: the recovery replaced by
    /// `SignatureChecker.isValidSignatureNowCalldata(signer, orderHash, signed.signature)`, under which the
    /// yes-wallet's forged grant-0 order fills and the burning wallet's good order fails; a `code.length`
    /// branch anywhere on the fill path.
    function test_neverLine_theFillNeverAsksAVerifier() public {
        uint256 fresh = vm.snapshotState();
        _neverAsksCases(Side.B);
        vm.revertToState(fresh);
        _neverAsksCases(Side.A);
    }

    function _neverAsksCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        Signer memory S = _key("a key that is nobody's agent");
        uint256 snap = vm.snapshotState();

        // The yes-wallet: an account whose code answers yes to every signature question. It grants W.
        WalletCode Y = _wallet(WalletCode.Mode.Yes);
        Y.exec(address(matching), abi.encodeCall(OspexMatching.grantAgent, (W.a, CAP, _inAnHour(), _noLines())));
        assertEq(Y.isValidSignature(bytes32(0), ""), MAGIC, "the fixture's yes");
        // A grant-0 order for the wallet, signed by a key that is not its granted agent: refused, both roles. The
        // wallet's yes authorizes nothing.
        OspexMatching.SignedOrder memory forged =
            _restNonce(S, address(Y), _nonce(0, 0, 1), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, forged, "the yes-wallet, a stranger's key at grant 0");
        forged = _takeNonce(S, address(Y), _nonce(0, 0, 2), game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, forged, _bad(forged), "the yes-wallet, a stranger's key at grant 0, taking");
        // Its granted agent's key at grant 0: refused too. Grant 0 is the account's own key, which a wallet has not.
        forged = _restNonce(W, address(Y), _nonce(0, 0, 3), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, forged, "the yes-wallet, its agent's key at grant 0");
        // Its granted agent's key under grant 1: fills, both roles, and nothing asked the wallet.
        OspexMatching.SignedOrder memory good =
            _restNonce(W, address(Y), _nonce(0, 1, 4), game, restingSide, 200, 10_000);
        VmSafe.AccountAccess[] memory acc = _crossRecorded(_take(tk, game, takingSide, 200, 10_000), _list(good));
        assertEq(_filled(good), 10_000, "the yes-wallet's agent order, resting");
        _assertNeverAsked(acc, _never(address(Y), W.a, S.a), "the yes-wallet, resting");
        good = _takeNonce(W, address(Y), _nonce(0, 1, 5), game, takingSide, 200, 10_000);
        acc = _crossRecorded(good, _list(_rest(m1, game, restingSide, 200, 10_000)));
        assertEq(_filled(good), 10_000, "the yes-wallet's agent order, taking");
        _assertNeverAsked(acc, _never(address(Y), W.a, S.a), "the yes-wallet, taking");
        vm.revertToState(snap);

        // The hostile wallet, three ways: it burns every unit of gas, it refuses, it flips by block. Its granted
        // agent's good orders fill in both roles, and nothing asked it: its no refuses nothing.
        WalletCode.Mode[3] memory modes = [WalletCode.Mode.Burn, WalletCode.Mode.Refuse, WalletCode.Mode.Flip];
        for (uint256 i; i < 3; ++i) {
            WalletCode H = _wallet(modes[i]);
            H.exec(address(matching), abi.encodeCall(OspexMatching.grantAgent, (W.a, CAP, _inAnHour(), _noLines())));
            string memory what = string.concat("the hostile wallet, mode ", vm.toString(i));
            OspexMatching.SignedOrder memory r =
                _restNonce(W, address(H), _nonce(0, 1, 1), game, restingSide, 200, 10_000);
            acc = _crossRecorded(_take(tk, game, takingSide, 200, 10_000), _list(r));
            assertEq(_filled(r), 10_000, string.concat(what, ": resting"));
            _assertNeverAsked(acc, _never(address(H), W.a, S.a), string.concat(what, ": resting"));
            OspexMatching.SignedOrder memory t =
                _takeNonce(W, address(H), _nonce(0, 1, 2), game, takingSide, 200, 10_000);
            acc = _crossRecorded(t, _list(_rest(m1, game, restingSide, 200, 10_000)));
            assertEq(_filled(t), 10_000, string.concat(what, ": taking"));
            _assertNeverAsked(acc, _never(address(H), W.a, S.a), string.concat(what, ": taking"));
            // A forged grant-0 order for it is refused all the same: the mode decides nothing.
            OspexMatching.SignedOrder memory f =
                _restNonce(S, address(H), _nonce(0, 0, 3), game, restingSide, 200, 10_000);
            _refusedResting(game, takingSide, f, string.concat(what, ": a stranger's key at grant 0"));
            vm.revertToState(snap);
        }

        // A contract agent with no key cannot sign: A grants a contract; every signature offered under that grant
        // recovers to some key, never to the contract, and is refused. The contract still cancels, as itself.
        WalletCode G = new WalletCode();
        vm.prank(A.a);
        matching.grantAgent(address(G), CAP, _inAnHour(), _noLines());
        OspexMatching.SignedOrder memory byA = _restNonce(A, A.a, _nonce(0, 1, 1), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, byA, "a contract agent: the account's key under its grant");
        OspexMatching.SignedOrder memory byW = _restNonce(W, A.a, _nonce(0, 1, 2), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, byW, "a contract agent: another key under its grant");
        vm.prank(stranger, stranger);
        G.exec(address(matching), abi.encodeCall(OspexMatching.cancelOrder, (byA.order)));
        assertTrue(matching.s_cancelledOrders(_hash(byA)), "the contract agent cancels");
        // The account's own grant-0 orders fill while a keyless agent stands.
        acc = _crossRecorded(_take(tk, game, takingSide, 200, 10_000), _list(_rest(A, game, restingSide, 200, 10_000)));
        _assertNeverAsked(acc, _never(A.a, address(G), S.a), "a keyless agent standing, the account's own order");
        vm.revertToState(snap);
    }

    /// @dev A resting order whose signature is refused: the whole Cross reverts BadSignature, and nothing filled.
    function _refusedResting(uint256 game, Side takingSide, OspexMatching.SignedOrder memory x, string memory what)
        internal
    {
        OspexMatching.SignedOrder memory live = _rest(m1, game, _other(takingSide), 200, 10_000);
        _refused(sender, _take(tk, game, takingSide, 200, 10_000), _list(live, x), _bad(x), what);
        assertEq(_filled(x), 0, string.concat(what, ": it filled"));
        assertEq(_filled(live), 0, string.concat(what, ": the order beside it filled"));
    }

    function _bad(OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return _refusal(OspexMatching.OspexMatching__BadSignature.selector, s);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Ruling 6, the ordinary key: a key with code attached signs, and its delegate is never consulted.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkSigned, route a signer with code to its code: `if (signer.code.length != 0)
    /// { (bool ok, bytes memory a) = signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (orderHash,
    /// signed.signature))); if (!ok || bytes4(a) != IERC1271.isValidSignature.selector) revert
    /// OspexMatching__BadSignature(orderHash); } else` before the recovery. Another turns it red: the delegate's
    /// answer consulted beside the recovery.
    function test_neverLine_aKeyWithCodeAttachedSignsAndItsDelegateIsNeverConsulted() public {
        uint256 fresh = vm.snapshotState();
        _delegateCases(Side.B);
        vm.revertToState(fresh);
        _delegateCases(Side.A);
    }

    function _delegateCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        Signer memory S = _key("a key that is nobody's agent");
        WalletCode delegate = new WalletCode();
        uint256 snap = vm.snapshotState();

        WalletCode.Mode[3] memory modes = [WalletCode.Mode.Refuse, WalletCode.Mode.Burn, WalletCode.Mode.Yes];
        for (uint256 i; i < 3; ++i) {
            string memory what = string.concat("a delegate in mode ", vm.toString(i));
            // An account that is a key with code attached, and an agent that is one too: each attaches the
            // delegate and sets its mode in its own storage.
            Signer memory K = _key(string.concat("a key with code, account ", vm.toString(i)));
            Signer memory D = _key(string.concat("a key with code, agent ", vm.toString(i)));
            vm.signAndAttachDelegation(address(delegate), K.key);
            vm.signAndAttachDelegation(address(delegate), D.key);
            assertEq(K.a.code.length, 23, "the account's designator");
            assertEq(D.a.code.length, 23, "the agent's designator");
            WalletCode(K.a).setMode(modes[i]);
            WalletCode(D.a).setMode(modes[i]);
            _fundCoin(K.a);
            _register(K.a, sender);
            vm.prank(K.a);
            matching.grantAgent(D.a, CAP, _inAnHour(), _noLines());

            // The account's own key signs at grant 0, both roles, as if the code were not there.
            OspexMatching.SignedOrder memory r = _rest(K, game, restingSide, 200, 10_000);
            VmSafe.AccountAccess[] memory acc = _crossRecorded(_take(tk, game, takingSide, 200, 10_000), _list(r));
            assertEq(_filled(r), 10_000, string.concat(what, ": the account's key, resting"));
            _assertNeverAsked(
                acc, _never(K.a, D.a, address(delegate)), string.concat(what, ": the account's key, resting")
            );
            OspexMatching.SignedOrder memory t = _take(K, game, takingSide, 200, 10_000);
            acc = _crossRecorded(t, _list(_rest(m1, game, restingSide, 200, 10_000)));
            assertEq(_filled(t), 10_000, string.concat(what, ": the account's key, taking"));
            _assertNeverAsked(
                acc, _never(K.a, D.a, address(delegate)), string.concat(what, ": the account's key, taking")
            );
            // The agent's key signs under grant 1, both roles.
            r = _restBy(D, K.a, 1, game, restingSide, 200, 10_000);
            acc = _crossRecorded(_take(tk, game, takingSide, 200, 10_000), _list(r));
            assertEq(_filled(r), 10_000, string.concat(what, ": the agent's key, resting"));
            _assertNeverAsked(
                acc, _never(K.a, D.a, address(delegate)), string.concat(what, ": the agent's key, resting")
            );
            t = _takeBy(D, K.a, 1, game, takingSide, 200, 10_000);
            acc = _crossRecorded(t, _list(_rest(m1, game, restingSide, 200, 10_000)));
            assertEq(_filled(t), 10_000, string.concat(what, ": the agent's key, taking"));
            _assertNeverAsked(
                acc, _never(K.a, D.a, address(delegate)), string.concat(what, ": the agent's key, taking")
            );
            // A wrong key and a malformed signature are refused in both roles, whatever the delegate would say.
            OspexMatching.SignedOrder memory wrong = _restNonce(S, K.a, _nonce(0, 0, 9), game, restingSide, 200, 10_000);
            _refusedResting(game, takingSide, wrong, string.concat(what, ": a wrong key at grant 0"));
            wrong = _restNonce(S, K.a, _nonce(0, 1, 9), game, restingSide, 200, 10_000);
            _refusedResting(game, takingSide, wrong, string.concat(what, ": a wrong key under grant 1"));
            wrong = _takeNonce(S, K.a, _nonce(0, 1, 9), game, takingSide, 200, 10_000);
            _takingRefused(game, takingSide, wrong, _bad(wrong), string.concat(what, ": a wrong key, taking"));
            OspexMatching.SignedOrder memory cut = _restBy(D, K.a, 1, game, restingSide, 200, 10_000);
            bytes memory sig = cut.signature;
            cut.signature = new bytes(64);
            for (uint256 j; j < 64; ++j) {
                cut.signature[j] = sig[j];
            }
            _refusedResting(game, takingSide, cut, string.concat(what, ": sixty-four bytes"));
            cut.signature = hex"";
            _refusedResting(game, takingSide, cut, string.concat(what, ": no bytes"));
            // The agent with code cancels for the account through its code, as the live agent it is.
            vm.prank(stranger, stranger);
            WalletCode(D.a).exec(address(matching), abi.encodeCall(OspexMatching.cancelAll, (K.a)));
            assertTrue(matching.s_version(K.a) != 0, string.concat(what, ": the agent with code did not cancel"));
            vm.revertToState(snap);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Ruling 6, the owner's signature: a contract's own signature policy is not accepted; a contract account
    // trades through a key it granted.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkSigned, accept any signer whose `code.length > 0`, skipping the comparison.
    /// Another turns it red: the resolved signer replaced by `order.account` for a nonzero grant.
    function test_neverLine_aContractsOwnSignaturePolicyIsNotAccepted() public {
        uint256 fresh = vm.snapshotState();
        _ownerCases(Side.B);
        vm.revertToState(fresh);
        _ownerCases(Side.A);
    }

    function _ownerCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        uint256 game2 = _verifiedGame();
        Side restingSide = _other(takingSide);
        // A contract account whose owner is a key: the owner drives the contract. A yes-wallet, so that the
        // policy it would answer with is the most permissive one.
        Signer memory O = _key("the owner");
        WalletCode C = _wallet(WalletCode.Mode.Yes);
        uint256 snap = vm.snapshotState();

        // The owner's signature over the digest, offered at grant 0 for the contract's address: refused, both
        // roles, before and after the contract grants anyone.
        OspexMatching.SignedOrder memory asOwner =
            _restNonce(O, address(C), _nonce(0, 0, 1), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, asOwner, "the owner's signature at grant 0");
        OspexMatching.SignedOrder memory asOwnerT =
            _takeNonce(O, address(C), _nonce(0, 0, 2), game, takingSide, 200, 10_000);
        _takingRefused(game, takingSide, asOwnerT, _bad(asOwnerT), "the owner's signature at grant 0, taking");
        // The contract grants its owner: the owner's orders fill under the grant's number, both roles.
        vm.prank(O.a);
        C.exec(address(matching), abi.encodeCall(OspexMatching.grantAgent, (O.a, CAP, _inAnHour(), _noLines())));
        _refusedResting(game, takingSide, asOwner, "the owner's signature at grant 0, after the grant");
        OspexMatching.SignedOrder memory under =
            _restNonce(O, address(C), _nonce(0, 1, 3), game, restingSide, 200, 10_000);
        VmSafe.AccountAccess[] memory acc = _crossRecorded(_take(tk, game, takingSide, 200, 10_000), _list(under));
        assertEq(_filled(under), 10_000, "the owner as the granted agent, resting");
        _assertNeverAsked(acc, _never(address(C), O.a, address(0)), "the owner as the granted agent");
        OspexMatching.SignedOrder memory underT =
            _takeNonce(O, address(C), _nonce(0, 1, 4), game2, takingSide, 200, 10_000);
        _takingFills(game2, takingSide, underT, "the owner as the granted agent, taking");
        // The position and the payout are the contract's, not the owner's: the first game is scored for the
        // contract's side, and anyone's claim pays the contract.
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        _scoreFor(game, restingSide);
        Side winner = restingSide;
        uint256 cBefore = _coin().balanceOf(address(C));
        uint256 oBefore = _coin().balanceOf(O.a);
        vm.prank(stranger, stranger);
        uint256 paid = positions.claimPositionFor(market, address(C), winner);
        assertGt(paid, 0, "the contract's claim");
        assertEq(_coin().balanceOf(address(C)) - cBefore, paid, "the payout is the contract's");
        assertEq(_coin().balanceOf(O.a), oBefore, "the owner was paid");
        vm.revertToState(snap);

        // A stranger's signature under the owner's grant, and the owner's under another account's grant.
        vm.prank(O.a);
        C.exec(address(matching), abi.encodeCall(OspexMatching.grantAgent, (O.a, CAP, _inAnHour(), _noLines())));
        Signer memory S = _key("a stranger's key");
        OspexMatching.SignedOrder memory bad =
            _restNonce(S, address(C), _nonce(0, 1, 5), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, bad, "a stranger's key under the owner's grant");
        _grantTo(A, W);
        bad = _restNonce(O, A.a, _nonce(0, 1, 6), game, restingSide, 200, 10_000);
        _refusedResting(game, takingSide, bad, "the owner's key under another account's grant");
        vm.revertToState(snap);
    }
}

/// @notice L71, L240: the agent never withdraws or moves money. Every state-changing call of the eight contracts,
///         made by the agent with the account named, and the account's claim after a settled market, from the
///         user's side: a grant made, an order signed, filled through a courier the accounts registered, settled
///         on a scored game, claimed by anyone with the payout to the account.
contract OspexAgentMoneyTest is AgentBase {
    /// @dev Everyone's coin and every allowance among them, the positions of each on the market, the market's held
    ///      amounts and the order's filled amount, hashed.
    function _moneyPrint(uint256 market, OspexMatching.SignedOrder memory x) internal view returns (bytes32 h) {
        IERC20 coin = _coin();
        address[6] memory who = [A.a, W.a, stranger, address(positions), address(matching), address(relay)];
        for (uint256 i; i < 6; ++i) {
            h = keccak256(abi.encode(h, coin.balanceOf(who[i])));
            for (uint256 j; j < 6; ++j) {
                h = keccak256(abi.encode(h, coin.allowance(who[i], who[j])));
            }
            Position memory a = _position(market, who[i], Side.A);
            Position memory b = _position(market, who[i], Side.B);
            h = keccak256(abi.encode(h, a.risk, a.profit, a.claimed, b.risk, b.profit, b.claimed));
        }
        h = keccak256(
            abi.encode(
                h, positions.s_held(market, A.a), positions.s_heldTotal(market), _filled(x), markets.marketCount()
            )
        );
    }

    /// Break: in OspexPositions._claim, pay `msg.sender` when it is the account's live agent. Others turn it red:
    /// a grant that approves the agent as a spender of the account's coin, which the allowance fingerprint and
    /// the agent's transfer see; the signer resolved from A's grant record for an order naming B, so the agent is
    /// wrongly authorized for B and the fill reaches the assertion.
    function test_neverLine_theAgentNeverWithdrawsOrMovesMoney() public {
        uint256 fresh = vm.snapshotState();
        _moneyCases(Side.B);
        vm.revertToState(fresh);
        _moneyCases(Side.A);
    }

    function _moneyCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();
        // Three shapes of grant: every market at CAP; one line at a small cap; a cap of zero, cancels only.
        for (uint256 shape; shape < 3; ++shape) {
            vm.revertToState(snap);
            vm.prank(A.a);
            if (shape == 0) matching.grantAgent(W.a, CAP, _inAnHour(), _noLines());
            else if (shape == 1) matching.grantAgent(W.a, 10_000, _inAnHour(), _oneLine(game, address(moneyline), 0));
            else matching.grantAgent(W.a, 0, _ends(vm.getBlockTimestamp() + 365 days), _noLines());
            _oneShape(game, takingSide, restingSide, shape);
        }
        vm.revertToState(snap);
    }

    function _oneShape(uint256 game, Side takingSide, Side restingSide, uint256 shape) internal {
        string memory what = string.concat("shape ", vm.toString(shape));
        // The account's order rests and fills: by the agent under shapes 0 and 1, by the account under shape 2.
        OspexMatching.SignedOrder memory x =
            shape == 2 ? _rest(A, game, restingSide, 200, 10_000) : _restBy(W, A.a, 1, game, restingSide, 200, 10_000);
        uint256 market = _restingFills(game, takingSide, x, what);
        _assertPosition(market, A.a, restingSide, 10_000, 10_000, string.concat(what, ": the account's position"));
        _assertPosition(market, W.a, restingSide, 0, 0, string.concat(what, ": the agent's position"));
        assertEq(_coin().balanceOf(W.a), 0, string.concat(what, ": the agent holds coin"));

        // Every state-changing call of the eight contracts, by the agent, with the account named where a call
        // names anyone: what each answers is its own; none moves coin, an allowance, a position or a filled
        // amount. The claims are refused here because the market is open; they are the control below.
        bytes32 before = _moneyPrint(market, x);
        bytes[] memory calls = _everyWriter(game, market, x);
        for (uint256 i; i < calls.length; ++i) {
            address target = abi.decode(calls[i], (address));
            bytes memory data = _dataOf(calls[i]);
            vm.prank(W.a, W.a);
            (bool ok,) = target.call(data);
            ok;
            assertEq(_moneyPrint(market, x), before, string.concat(what, ": call ", vm.toString(i), " moved money"));
        }
        // The agent spends nothing of the account's: no permission the grant could have introduced exists.
        vm.prank(W.a);
        (bool spent,) = address(_coin()).call(abi.encodeCall(IERC20.transferFrom, (A.a, W.a, 1)));
        assertFalse(spent, string.concat(what, ": the agent spent the account's coin"));
        vm.prank(W.a);
        (spent,) = address(_coin()).call(abi.encodeCall(IERC20.transferFrom, (address(positions), W.a, 1)));
        assertFalse(spent, string.concat(what, ": the agent spent the positions module's coin"));
        assertEq(_moneyPrint(market, x), before, string.concat(what, ": the transfers moved money"));

        // The account claims as itself after the game is scored: the payout is the account's. The cancels the
        // agent made above do not touch the filled position.
        _scoreFor(game, restingSide);
        Side winner = restingSide;
        (bool lost,) = _tryClaim(A.a, market, takingSide);
        assertFalse(lost, string.concat(what, ": the empty record was paid"));
        uint256 claimed = vm.snapshotState();
        uint256 aBefore = _coin().balanceOf(A.a);
        assertEq(_claim(A.a, market, winner), 20_000, string.concat(what, ": the account's own claim"));
        assertEq(_coin().balanceOf(A.a) - aBefore, 20_000);
        assertEq(_coin().balanceOf(W.a), 0, string.concat(what, ": the agent was paid"));
        // The control, from the same pre-state: the claim for anyone pays the account whoever sends it, the agent
        // included; the caller's own claim reads only the caller's record, so the agent cannot claim the
        // account's record through it, and the account can.
        vm.revertToState(claimed);
        vm.prank(W.a, W.a);
        assertEq(
            positions.claimPositionFor(market, A.a, winner),
            20_000,
            string.concat(what, ": the agent's claim for the account")
        );
        assertEq(_coin().balanceOf(A.a) - aBefore, 20_000, string.concat(what, ": the payout went elsewhere"));
        assertEq(_coin().balanceOf(W.a), 0);
        vm.revertToState(claimed);
        vm.prank(stranger, stranger);
        assertEq(
            positions.claimPositionFor(market, A.a, winner),
            20_000,
            string.concat(what, ": a stranger's claim for the account")
        );
        assertEq(_coin().balanceOf(A.a) - aBefore, 20_000);
        vm.revertToState(claimed);
        (bool paid, bytes memory err) = _tryClaim(W.a, market, winner);
        assertFalse(paid, string.concat(what, ": the agent claimed the account's record as its own"));
        assertEq(
            err,
            abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector),
            string.concat(what, ": the agent's own record is empty")
        );
        assertEq(_coin().balanceOf(A.a), aBefore);
        assertEq(
            _claim(A.a, market, winner), 20_000, string.concat(what, ": the account's claim after the agent's attempt")
        );
    }

    /// @dev Every state-changing function of the eight contracts, as the agent would call it with the account
    ///      named: each entry is the target, then the call's bytes.
    function _everyWriter(uint256 game, uint256 market, OspexMatching.SignedOrder memory x)
        internal
        view
        returns (bytes[] memory calls)
    {
        calls = new bytes[](22);
        uint256 n;
        address[] memory makers = new address[](1);
        makers[0] = A.a;
        OspexMatching.SignedOrder[] memory list = new OspexMatching.SignedOrder[](1);
        list[0] = x;
        // The core: three.
        calls[n++] = abi.encode(address(core), abi.encodeCall(OspexBetting.bootstrapModules, (_types(), _modules())));
        calls[n++] = abi.encode(address(core), abi.encodeCall(OspexBetting.finalize, ()));
        calls[n++] =
            abi.encode(address(core), abi.encodeCall(OspexBetting.emitCoreEvent, (bytes32("x"), abi.encode(A.a))));
        // The markets module: two.
        calls[n++] = abi.encode(
            address(markets), abi.encodeCall(OspexMarkets.createMarket, (game, address(moneyline), 0, A.a, W.a))
        );
        calls[n++] = abi.encode(address(markets), abi.encodeCall(OspexMarkets.settleMarket, (market)));
        // The positions module: five.
        calls[n++] = abi.encode(
            address(positions),
            abi.encodeCall(OspexPositions.recordFill, (game, address(moneyline), 0, Side.A, A.a, 100, W.a, 100))
        );
        calls[n++] = abi.encode(address(positions), abi.encodeCall(OspexPositions.finishFills, (market, A.a, makers)));
        calls[n++] = abi.encode(address(positions), abi.encodeCall(OspexPositions.sendPayBack, (A.a, 1)));
        calls[n++] = abi.encode(address(positions), abi.encodeCall(OspexPositions.claimPosition, (market, Side.A)));
        calls[n++] =
            abi.encode(address(positions), abi.encodeCall(OspexPositions.claimPositionFor, (market, A.a, Side.A)));
        // The matching module: ten.
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.cross, (x, list)));
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.cancelOrder, (x.order)));
        calls[n++] = abi.encode(
            address(matching), abi.encodeCall(OspexMatching.raiseFloor, (A.a, game, address(moneyline), 0, 1))
        );
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.cancelAll, (A.a)));
        calls[n++] = abi.encode(
            address(matching), abi.encodeCall(OspexMatching.grantAgent, (A.a, CAP, _inAnHour(), _noLines()))
        );
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.revokeAgent, ()));
        calls[n++] = abi.encode(
            address(matching),
            abi.encodeCall(OspexMatching.grantAgentAndRegisterCourier, (A.a, CAP, _inAnHour(), _noLines(), A.a))
        );
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.registerCourier, (A.a)));
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.unregisterCourier, (A.a)));
        calls[n++] = abi.encode(address(matching), abi.encodeCall(OspexMatching.liftTakingStakeCap, ()));
        // The relay: two. The three market contracts change no state.
        calls[n++] = abi.encode(address(relay), abi.encodeCall(OspexCourierRelay.cross, (x, list)));
        calls[n++] = abi.encode(address(relay), abi.encodeCall(OspexCourierRelay.setSender, (A.a)));
        assertEq(n, 22, "every writer listed");
    }

    function _dataOf(bytes memory entry) internal pure returns (bytes memory data) {
        (, data) = abi.decode(entry, (address, bytes));
    }

    /// Binding: the agent is authorized by A and not by B. A W-signed order naming B is refused, and B's coin,
    /// positions and filled amounts are as they were; the same once B has granted another key.
    /// Break: in OspexMatching._checkSigned, read the grant record under a fixed account, `s_grants[A][n]`, for
    /// every order: the agent is authorized for B.
    function test_neverLine_theAgentIsBoundToTheAccountThatGrantedIt() public {
        uint256 fresh = vm.snapshotState();
        _bindingCases(Side.B);
        vm.revertToState(fresh);
        _bindingCases(Side.A);
    }

    function _bindingCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        _grantTo(A, W);
        OspexMatching.SignedOrder memory forB = _restBy(W, B.a, 1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory forBT = _takeBy(W, B.a, 1, game, takingSide, 200, 10_000);
        bytes32 before = _moneyPrintOf(B.a, forB, forBT);

        // B has made no grant 1: refused by name, both roles.
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 10_000),
            _list(forB),
            abi.encodeWithSelector(OspexMatching.OspexMatching__NoSuchGrant.selector, _hash(forB), B.a, uint32(1)),
            "W's order for B, no grant"
        );
        _takingRefused(
            game,
            takingSide,
            forBT,
            abi.encodeWithSelector(OspexMatching.OspexMatching__NoSuchGrant.selector, _hash(forBT), B.a, uint32(1)),
            "W's taking order for B, no grant"
        );
        assertEq(_moneyPrintOf(B.a, forB, forBT), before, "B's state moved");
        // B grants another key: W's order under B's grant 1 is a bad signature, both roles.
        Signer memory W2 = _key("B's agent");
        _grantTo(B, W2);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 10_000),
            _list(forB),
            _refusal(OspexMatching.OspexMatching__BadSignature.selector, forB),
            "W's order for B, under B's grant to another"
        );
        _takingRefused(
            game,
            takingSide,
            forBT,
            _refusal(OspexMatching.OspexMatching__BadSignature.selector, forBT),
            "W's taking order for B, under B's grant to another"
        );
        assertEq(_moneyPrintOf(B.a, forB, forBT), before, "B's state moved");
        // The control: W's order for A fills, and W2's for B.
        _restingFills(game, takingSide, _restBy(W, A.a, 1, game, restingSide, 200, 10_000), "W for A");
        _restingFills(game, takingSide, _restBy(W2, B.a, 1, game, restingSide, 200, 10_000), "W2 for B");
    }

    function _moneyPrintOf(address who, OspexMatching.SignedOrder memory a, OspexMatching.SignedOrder memory b)
        internal
        view
        returns (bytes32)
    {
        address[] memory list = new address[](1);
        list[0] = who;
        bytes32[] memory orders = new bytes32[](2);
        orders[0] = _hash(a);
        orders[1] = _hash(b);
        return _fingerprint(list, orders);
    }
}

/// @dev The two Safe calls these tests make, and the factory's.
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address paymentReceiver
    ) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    function nonce() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
    function getThreshold() external view returns (uint256);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @notice The approved agent for a contract account that cannot sign: a Safe, on a fork of Polygon mainnet at
///         FORK_BLOCK, made through the real factory on the real singleton, a one-owner Safe of 1.4.1 and a
///         two-owner Safe of 1.3.0. Each approves the positions module, registers the sender and grants a key
///         through `execTransaction` with its owners' real signatures; the granted key's order fills in each
///         role in Polygon's USDC; the position and the payout are the Safe's; the owners' signatures offered as
///         the Safe's own fail; a revoke and a new grant work; every balance to the unit; and the gas of the
///         Safe's leg beside a key's. Needs POLYGON_RPC_URL; without it (CI has no RPC) it is skipped.
contract OspexAgentForkTest is AgentBase {
    uint256 internal constant FORK_BLOCK = 96_885_149;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    /// @dev An address that holds USDC at the fork block: the accounts are funded from it.
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @dev Safe 1.4.1: the canonical L2 singleton, the proxy factory and the compatibility fallback handler.
    address internal constant SAFE_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant HANDLER_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    /// @dev Safe 1.3.0: the same three.
    address internal constant SAFE_130 = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address internal constant FACTORY_130 = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address internal constant HANDLER_130 = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    /// @dev What each account is funded with, 50 USDC; the leg, 10 USDC resting at 2.10 against 11 USDC.
    uint256 internal constant FUNDED = 50_000_000;
    uint256 internal constant RESTING_STAKE = 10_000_000;
    uint256 internal constant TAKING_STAKE = 11_000_000;
    uint256 internal constant SAFE_CAP = 20_000_000;

    IERC20 internal usdc = IERC20(USDC);
    Signer internal O1;
    Signer internal O2;
    Signer internal O3;
    /// @dev A key with USDC, the counterparty of every leg.
    Signer internal K;
    uint256 internal holderLeft;

    function setUp() public override {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        super.setUp();
        // The betting set again, on Polygon's USDC, its cap lifted through the stock timelock.
        _deploySetOn(USDC);
        assertTrue(matching.s_takingStakeCapLifted(), "the cap was not lifted for the 11 USDC legs");
        O1 = _key("owner one");
        O2 = _key("owner two");
        O3 = _key("owner three");
        K = _key("a key with USDC");
        _fundUsdc(K.a);
        _register(K.a, sender);
        holderLeft = usdc.balanceOf(HOLDER);
    }

    function _fundUsdc(address who) internal {
        assertEq(usdc.balanceOf(who), 0, "the account held USDC before it was funded");
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(who, FUNDED), "the funding transfer");
        if (who.code.length == 0) {
            vm.prank(who);
            assertTrue(usdc.approve(address(positions), type(uint256).max), "the approval");
        }
    }

    /// @dev A Safe through the real factory: `owners`, threshold `threshold`, the handler, no payment.
    function _safe(address factory, address singleton, address handler, Signer[] memory owners, uint256 threshold)
        internal
        returns (ISafe safe)
    {
        address[] memory addrs = new address[](owners.length);
        for (uint256 i; i < owners.length; ++i) {
            addrs[i] = owners[i].a;
        }
        bytes memory initializer =
            abi.encodeCall(ISafe.setup, (addrs, threshold, address(0), "", handler, address(0), 0, address(0)));
        safe = ISafe(ISafeProxyFactory(factory).createProxyWithNonce(singleton, initializer, 20_261_114));
        assertEq(safe.getThreshold(), threshold, "the threshold");
        for (uint256 i; i < owners.length; ++i) {
            assertTrue(safe.isOwner(owners[i].a), "an owner");
        }
        assertGt(address(safe).code.length, 0, "the proxy has code");
    }

    /// @dev The Safe makes `data` a call to `to`, signed by its owners over the Safe's own transaction hash: the
    ///      owners' real signatures, sorted as the Safe requires.
    function _exec(ISafe safe, Signer[] memory owners, address to, bytes memory data) internal {
        bytes32 h = safe.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        for (uint256 i; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (owners[j].a < owners[i].a) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        bytes memory sigs;
        for (uint256 i; i < owners.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(owners[i].key, h);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
        vm.prank(owners[0].a, owners[0].a);
        assertTrue(
            safe.execTransaction(to, 0, data, 0, 0, 0, 0, address(0), address(0), sigs), "the Safe's transaction"
        );
    }

    function _owners(Signer memory a) internal pure returns (Signer[] memory o) {
        o = new Signer[](1);
        o[0] = a;
    }

    function _owners(Signer memory a, Signer memory b) internal pure returns (Signer[] memory o) {
        o = new Signer[](2);
        o[0] = a;
        o[1] = b;
    }

    /// @dev The Safe made ready: funded, the positions module approved, the sender registered, W granted.
    function _ready(ISafe safe, Signer[] memory owners) internal {
        _fundUsdc(address(safe));
        _exec(safe, owners, USDC, abi.encodeCall(IERC20.approve, (address(positions), type(uint256).max)));
        _exec(safe, owners, address(matching), abi.encodeCall(OspexMatching.registerCourier, (sender)));
        _exec(
            safe,
            owners,
            address(matching),
            abi.encodeCall(
                OspexMatching.grantAgent, (W.a, SAFE_CAP, _ends(vm.getBlockTimestamp() + 365 days), _noLines())
            )
        );
        assertTrue(matching.isLiveAgent(address(safe), W.a), "the Safe's agent");
        assertEq(usdc.balanceOf(address(safe)), FUNDED);
    }

    function _bad(OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return _refusal(OspexMatching.OspexMatching__BadSignature.selector, s);
    }

    /// @dev A resting order for `account` in USDC, signed by `by` under `grant`: 10 USDC on side A at 2.10.
    function _safeRests(Signer memory by, address account, uint32 grant, uint256 game)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _restNonce(
            by, account, _nonce(matching.s_version(account), grant, _no(nextNonce++)), game, Side.A, 210, RESTING_STAKE
        );
    }

    /// @dev A taking order for `account` in USDC: 11 USDC on side B at 1.90.
    function _safeTakes(Signer memory by, address account, uint32 grant, uint256 game)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _takeNonce(
            by, account, _nonce(matching.s_version(account), grant, _no(nextNonce++)), game, Side.B, 190, TAKING_STAKE
        );
    }

    /// A one-owner Safe of 1.4.1: the owner's signature as the Safe's own fails; the granted key's order fills in
    /// each role, in USDC; the payout is the Safe's; a revoke kills the key's orders and a new grant restores
    /// them; every balance to the unit.
    function test_fork_aSafeTradesThroughTheKeyItGrantedAndNeverThroughItsOwners() public {
        ISafe safe = _safe(FACTORY_141, SAFE_141, HANDLER_141, _owners(O1), 1);
        address S = address(safe);
        _ready(safe, _owners(O1));
        assertEq(usdc.balanceOf(HOLDER), holderLeft - FUNDED, "the holder paid the Safe's funding");
        uint256 game = _verifiedGame();

        // The owner's signature over the digest, offered as the Safe's own at grant 0: refused, both roles.
        OspexMatching.SignedOrder memory asOwner = _safeRests(O1, S, 0, game);
        _refused(sender, _safeTakes(K, K.a, 0, game), _list(asOwner), _bad(asOwner), "the owner's signature at grant 0");
        OspexMatching.SignedOrder memory asOwnerT = _safeTakes(O1, S, 0, game);
        _refused(
            sender,
            asOwnerT,
            _list(_safeRests(K, K.a, 0, game)),
            _bad(asOwnerT),
            "the owner's signature at grant 0, taking"
        );
        // A stranger's key under the grant, and the owner's key under the grant: refused.
        OspexMatching.SignedOrder memory wrong = _safeRests(K, S, 1, game);
        _refused(sender, _safeTakes(K, K.a, 0, game), _list(wrong), _bad(wrong), "another key under the Safe's grant");
        wrong = _safeRests(O1, S, 1, game);
        _refused(
            sender, _safeTakes(K, K.a, 0, game), _list(wrong), _bad(wrong), "the owner's key under the Safe's grant"
        );
        assertEq(usdc.balanceOf(S), FUNDED, "a refused order moved the Safe's coin");

        // The granted key's order rests, and K takes it: 10 USDC against 11, to the unit.
        OspexMatching.SignedOrder memory resting = _safeRests(W, S, 1, game);
        OspexMatching.SignedOrder memory taking = _safeTakes(K, K.a, 0, game);
        uint256 gasBefore = gasleft();
        _cross(sender, taking, _list(resting));
        uint256 safeLegGas = gasBefore - gasleft();
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(_filled(resting), RESTING_STAKE);
        assertEq(usdc.balanceOf(S), FUNDED - RESTING_STAKE, "the Safe, after its resting fill");
        assertEq(usdc.balanceOf(K.a), FUNDED - TAKING_STAKE, "the key, after the fill");
        assertEq(usdc.balanceOf(address(positions)), RESTING_STAKE + TAKING_STAKE, "the positions module");
        assertEq(usdc.balanceOf(W.a), 0, "the agent holds USDC");
        assertEq(usdc.balanceOf(sender), 0);
        assertEq(usdc.balanceOf(address(matching)), 0);
        _assertPosition(market, S, Side.A, RESTING_STAKE, TAKING_STAKE, "the Safe's position");
        _assertPosition(market, W.a, Side.A, 0, 0, "the agent's position");
        // Scored home: side A, the Safe's, wins. Anyone's claim pays the Safe both stakes.
        _score(game, HOME, AWAY);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home));
        vm.prank(stranger, stranger);
        assertEq(positions.claimPositionFor(market, S, Side.A), RESTING_STAKE + TAKING_STAKE, "the Safe's claim");
        assertEq(usdc.balanceOf(S), FUNDED + TAKING_STAKE, "the Safe, paid");
        assertEq(usdc.balanceOf(K.a), FUNDED - TAKING_STAKE, "the key, after the loss");
        assertEq(usdc.balanceOf(address(positions)), 0);
        assertEq(usdc.balanceOf(W.a), 0, "the agent was paid");
        (bool ok,) = _tryClaim(W.a, market, Side.A);
        assertFalse(ok, "the agent's own claim on the Safe's market");

        // The taking role, on a second game: the key's order takes K's resting order; the game is scored for the
        // away team, the Safe's side B, and the Safe is paid both stakes again, to the unit.
        uint256 game2 = _verifiedGame();
        OspexMatching.SignedOrder memory safeTaking = _safeTakes(W, S, 1, game2);
        _cross(sender, safeTaking, _list(_safeRests(K, K.a, 0, game2)));
        uint256 market2 = markets.getMarketId(game2, address(moneyline), 0);
        assertEq(usdc.balanceOf(S), FUNDED, "the Safe, after its taking fill: what it was paid, less its stake");
        assertEq(usdc.balanceOf(K.a), FUNDED - TAKING_STAKE - RESTING_STAKE, "the key, after resting");
        _assertPosition(market2, S, Side.B, TAKING_STAKE, RESTING_STAKE, "the Safe's taking position");
        _score(game2, AWAY, HOME);
        _settle(market2);
        assertEq(uint8(_outcome(market2)), uint8(Outcome.Away));
        vm.prank(stranger, stranger);
        assertEq(positions.claimPositionFor(market2, S, Side.B), RESTING_STAKE + TAKING_STAKE, "the Safe's second win");
        (bool lost,) = _tryClaim(K.a, market2, Side.A);
        assertFalse(lost, "the key's losing claim was paid");
        assertEq(usdc.balanceOf(S), FUNDED + TAKING_STAKE + RESTING_STAKE, "the Safe, at the end");
        assertEq(usdc.balanceOf(K.a), FUNDED - TAKING_STAKE - RESTING_STAKE, "the key, at the end");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module, at the end");
        assertEq(usdc.balanceOf(address(matching)), 0);
        assertEq(usdc.balanceOf(sender), 0);
        assertEq(usdc.balanceOf(W.a), 0);
        assertEq(usdc.balanceOf(HOLDER), holderLeft - FUNDED, "the holder, at the end");

        // A revoke through the Safe: the key's grant-1 order is dead by name; a new grant, number 2, and the
        // key's grant-2 order fills; the owner still cannot sign as the Safe.
        uint256 game3 = _verifiedGame();
        OspexMatching.SignedOrder memory dead = _safeRests(W, S, 1, game3);
        _exec(safe, _owners(O1), address(matching), abi.encodeCall(OspexMatching.revokeAgent, ()));
        assertFalse(matching.isLiveAgent(S, W.a));
        (, uint64 endsAt,,) = matching.getGrant(S, 1);
        _refused(
            sender,
            _safeTakes(K, K.a, 0, game3),
            _list(dead),
            _nothingFilled(_reasons(GRANT_GONE)),
            "after the revoke, resting"
        );
        OspexMatching.SignedOrder memory deadT = _safeTakes(W, S, 1, game3);
        _refused(
            sender,
            deadT,
            _list(_safeRests(K, K.a, 0, game3)),
            _grantGone(deadT, 1, 0, endsAt),
            "after the revoke, taking"
        );
        _exec(
            safe,
            _owners(O1),
            address(matching),
            abi.encodeCall(
                OspexMatching.grantAgent, (W.a, SAFE_CAP, _ends(vm.getBlockTimestamp() + 365 days), _noLines())
            )
        );
        assertEq(matching.s_currentGrant(S), 2);
        OspexMatching.SignedOrder memory again = _safeRests(W, S, 2, game3);
        _cross(sender, _safeTakes(K, K.a, 0, game3), _list(again));
        assertEq(_filled(again), RESTING_STAKE, "the grant-2 order");
        asOwner = _safeRests(O1, S, 0, game3);
        _refused(
            sender,
            _safeTakes(K, K.a, 0, game3),
            _list(asOwner),
            _bad(asOwner),
            "the owner's signature, after the regrant"
        );

        // The gas of the Safe's leg beside a key's: the same leg shape, each the first fill of its market.
        uint256 game4 = _verifiedGame();
        Signer memory K2 = _key("a second key with USDC");
        _fundUsdc(K2.a);
        _register(K2.a, sender);
        gasBefore = gasleft();
        _cross(sender, _safeTakes(K, K.a, 0, game4), _list(_safeRests(K2, K2.a, 0, game4)));
        uint256 keyLegGas = gasBefore - gasleft();
        emit log_named_uint("gas: the Safe's agent-signed resting leg, a market's first fill", safeLegGas);
        emit log_named_uint("gas: a key's own resting leg, a market's first fill", keyLegGas);
    }

    /// A two-owner Safe of 1.3.0, threshold two: the same, with both owners' signatures on every Safe
    /// transaction, and neither owner's signature accepted as the Safe's own.
    function test_fork_aTwoOwnerSafeTradesThroughTheKeyItGranted() public {
        ISafe safe = _safe(FACTORY_130, SAFE_130, HANDLER_130, _owners(O2, O3), 2);
        address S = address(safe);
        _ready(safe, _owners(O2, O3));
        uint256 game = _verifiedGame();

        OspexMatching.SignedOrder memory asOwner = _safeRests(O2, S, 0, game);
        _refused(
            sender, _safeTakes(K, K.a, 0, game), _list(asOwner), _bad(asOwner), "the first owner's signature at grant 0"
        );
        asOwner = _safeRests(O3, S, 0, game);
        _refused(
            sender,
            _safeTakes(K, K.a, 0, game),
            _list(asOwner),
            _bad(asOwner),
            "the second owner's signature at grant 0"
        );
        asOwner = _safeRests(O2, S, 1, game);
        _refused(
            sender, _safeTakes(K, K.a, 0, game), _list(asOwner), _bad(asOwner), "an owner's signature under the grant"
        );

        OspexMatching.SignedOrder memory resting = _safeRests(W, S, 1, game);
        _cross(sender, _safeTakes(K, K.a, 0, game), _list(resting));
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(usdc.balanceOf(S), FUNDED - RESTING_STAKE, "the Safe, after its fill");
        assertEq(usdc.balanceOf(K.a), FUNDED - TAKING_STAKE);
        _assertPosition(market, S, Side.A, RESTING_STAKE, TAKING_STAKE, "the Safe's position");
        _score(game, HOME, AWAY);
        _settle(market);
        vm.prank(stranger, stranger);
        assertEq(positions.claimPositionFor(market, S, Side.A), RESTING_STAKE + TAKING_STAKE);
        assertEq(usdc.balanceOf(S), FUNDED + TAKING_STAKE, "the Safe, paid");
        assertEq(usdc.balanceOf(W.a), 0);
        assertEq(usdc.balanceOf(O2.a), 0);
        assertEq(usdc.balanceOf(O3.a), 0);
        assertEq(usdc.balanceOf(address(positions)), 0);
        // The owners revoke and regrant, both signing.
        _exec(safe, _owners(O2, O3), address(matching), abi.encodeCall(OspexMatching.revokeAgent, ()));
        assertFalse(matching.isLiveAgent(S, W.a));
        _exec(
            safe,
            _owners(O2, O3),
            address(matching),
            abi.encodeCall(
                OspexMatching.grantAgent, (W.a, SAFE_CAP, _ends(vm.getBlockTimestamp() + 365 days), _noLines())
            )
        );
        assertTrue(matching.isLiveAgent(S, W.a));
        assertEq(matching.s_currentGrant(S), 2);
        assertEq(usdc.balanceOf(HOLDER), holderLeft - FUNDED, "the holder, at the end");
    }
}
