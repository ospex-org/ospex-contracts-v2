// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross's never-lines, second part: what a skip leaves and what may skip; a Cross that fills
///         nothing; and the events of a Cross, log by log. Above each test, "Break:" names changes to
///         src/betting that turn it red; each is an entry of battery.json.
contract OspexCrossSkipsTest is CrossBase {
    Signer internal tk;
    Signer internal m1;
    Signer internal m2;
    Signer internal m3;

    function setUp() public override {
        super.setUp();
        tk = _account("taking account");
        m1 = _account("resting one");
        m2 = _account("resting two");
        m3 = _account("resting three");
    }

    function _registerAll(address to) internal {
        _register(tk.a, to);
        _register(m1.a, to);
        _register(m2.a, to);
        _register(m3.a, to);
    }

    /// @dev The addresses and the orders a fingerprint is taken over in these tests.
    function _print(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder memory one,
        OspexMatching.SignedOrder memory two,
        OspexMatching.SignedOrder memory three
    ) internal view returns (bytes32) {
        address[] memory who = new address[](5);
        who[0] = tk.a;
        who[1] = m1.a;
        who[2] = m2.a;
        who[3] = m3.a;
        who[4] = sender;
        bytes32[] memory orders = new bytes32[](4);
        orders[0] = _hash(taking);
        orders[1] = _hash(one);
        orders[2] = _hash(two);
        orders[3] = _hash(three);
        return _fingerprint(who, orders);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 9. A skipped order leaves nothing, and only the eight reasons skip.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The second resting account's order `x`, listed between two orders that fill, is skipped for `reason`
    ///      and leaves what a Cross without it leaves: balances, positions, the market count and every filled
    ///      amount. The next order takes the stake.
    function _skippedInTheMiddle(
        uint256 game,
        Side takingSide,
        OspexMatching.SignedOrder memory x,
        uint8 reason,
        string memory what
    ) internal {
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory one = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory three = _rest(m3, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        uint256 before = _filled(x);
        uint256 snap = vm.snapshotState();

        vm.recordLogs();
        _cross(sender, taking, _list(one, x, three));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, string.concat(what, ": one skip record"));
        _assertSkip(skips[0], x, taking, reason, what);
        assertEq(_filled(x), before, string.concat(what, ": the skipped order's filled amount"));
        assertEq(_filled(one), 10_000, string.concat(what, ": the leg before it"));
        assertEq(_filled(three), 10_000, string.concat(what, ": the next order takes the stake"));
        assertEq(_filled(taking), 20_000, string.concat(what, ": the taking order"));
        bytes32 with = _print(taking, one, x, three);

        vm.revertToState(snap);
        _cross(sender, taking, _list(one, three));
        assertEq(with, _print(taking, one, x, three), string.concat(what, ": not as if it had not been listed"));
        vm.revertToState(snap);
    }

    /// Break: in OspexMatching._leg, catch every error of the positions call as a skip. Others turn it red: the
    /// two filled amounts not put back after a refused pull, and each of them alone; the selector not compared
    /// in the refused pull's recognition; the taking stake's minimum dropped, so that an order nothing fits
    /// reaches the pull; each neighbouring pair of the walk's first four rows swapped; and a resting order's
    /// expiry not tested, or tested with `>`; the floor tested after the expiry and the room; the grant's
    /// standing tested after the expiry, or before the cancel; and the hub's copy of a skip record carrying one
    /// fixed reason. And one break of the tests themselves, scored once to show the pins bite:
    /// `CrossBase.PULL_REFUSED` left at 5, the number the refused pull had before the seventh reason, under
    /// which each refused pull here is asserted against the wrong number.
    function test_neverLine_aSkippedOrderLeavesNothingAndOnlyTheEightReasonsSkip() public {
        _skipCases(Side.B);
        _skipCases(Side.A);
    }

    function _skipCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        IERC20 coin = _coin();
        uint256 start = vm.snapshotState();
        uint256 snap = start;

        // No courier: its account has not registered the sender.
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m3.a, sender);
        _skippedInTheMiddle(game, takingSide, _rest(m2, game, restingSide, 200, 10_000), NO_COURIER, "no courier");
        vm.revertToState(snap);
        _registerAll(sender);
        snap = vm.snapshotState();

        // Cancelled.
        OspexMatching.SignedOrder memory x = _rest(m2, game, restingSide, 200, 10_000);
        vm.prank(m2.a);
        matching.cancelOrder(x.order);
        _skippedInTheMiddle(game, takingSide, x, CANCELLED, "cancelled");
        vm.revertToState(snap);

        // Grant gone, three ways: an agent's order under a grant the account revoked; under a grant the
        // account replaced, the same key regranted; and under a grant that ended, at its end second. The
        // control: under the grant as it stands, the order fills.
        Signer memory agent = _key("the resting account's agent");
        vm.prank(m2.a);
        matching.grantAgent(agent.a, 10_000, _ends(vm.getBlockTimestamp() + 1 hours), _noLines());
        x = _restBy(agent, m2.a, 1, game, restingSide, 200, 10_000);
        uint256 granted = vm.snapshotState();
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
        assertEq(_filled(x), 10_000, "the control: an agent's order under its grant");
        vm.revertToState(granted);
        vm.prank(m2.a);
        matching.revokeAgent();
        _skippedInTheMiddle(game, takingSide, x, GRANT_GONE, "grant gone: revoked");
        vm.revertToState(granted);
        vm.prank(m2.a);
        matching.grantAgent(agent.a, 10_000, _ends(vm.getBlockTimestamp() + 1 hours), _noLines());
        _skippedInTheMiddle(game, takingSide, x, GRANT_GONE, "grant gone: replaced by a regrant of the same key");
        vm.revertToState(granted);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _skippedInTheMiddle(game, takingSide, x, GRANT_GONE, "grant gone: ended, at its end second");
        vm.revertToState(snap);

        // Expired: at its expiry, and a second past it.
        _skippedInTheMiddle(
            game,
            takingSide,
            _restUntil(m2, game, restingSide, 200, 10_000, vm.getBlockTimestamp()),
            EXPIRED,
            "at its expiry"
        );
        _skippedInTheMiddle(
            game,
            takingSide,
            _restUntil(m2, game, restingSide, 200, 10_000, vm.getBlockTimestamp() - 1),
            EXPIRED,
            "a second past its expiry"
        );

        // No room: filled to its signed stake by an earlier Cross.
        x = _rest(m2, game, restingSide, 200, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
        _skippedInTheMiddle(game, takingSide, x, NO_ROOM, "no room");
        vm.revertToState(snap);

        // Nothing fits: one lot at 1.50 is 100 against 50, under the minimum.
        _skippedInTheMiddle(game, takingSide, _rest(m2, game, restingSide, 150, 100), NOTHING_FITS, "nothing fits");

        // Under its minimum: a resting 20,000 asking for 15,000 at least, against the 10,000 the taking order has
        // left after the first leg. The leg would take 10,000 and leave 10,000, a lot or more, so it is skipped.
        _skippedInTheMiddle(
            game, takingSide, _restMin(m2, game, restingSide, 200, 20_000, 15_000), UNDER_MIN_FILL, "under its minimum"
        );

        // Pull refused, three ways, each on an order an earlier Cross filled 2,000 of: the filled amount is put
        // back to that figure. No balance.
        x = _rest(m2, game, restingSide, 200, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 2_000), _list(x));
        assertEq(_filled(x), 2_000, "before the refused pulls");
        uint256 funded = vm.snapshotState();
        uint256 all = coin.balanceOf(m2.a);
        vm.prank(m2.a);
        assertTrue(coin.transfer(stranger, all), "the transfer out");
        _skippedInTheMiddle(game, takingSide, x, PULL_REFUSED, "pull refused: no balance");
        vm.revertToState(funded);
        // No allowance.
        vm.prank(m2.a);
        coin.approve(address(positions), 0);
        _skippedInTheMiddle(game, takingSide, x, PULL_REFUSED, "pull refused: no allowance");
        vm.revertToState(funded);
        // Blocked by the coin, while its balance and its allowance read as enough.
        token.setBlocked(m2.a, true);
        assertGe(coin.balanceOf(m2.a), 8_000, "the blocked account's balance");
        assertGe(coin.allowance(m2.a, address(positions)), 8_000, "the blocked account's allowance");
        _skippedInTheMiddle(game, takingSide, x, PULL_REFUSED, "pull refused: blocked by the coin");
        vm.revertToState(snap);

        // Precedence: an order in two states is recorded under the first, for each neighbouring pair.
        // No courier over cancelled.
        x = _rest(m2, game, restingSide, 200, 10_000);
        vm.startPrank(m2.a);
        matching.cancelOrder(x.order);
        matching.unregisterCourier(sender);
        vm.stopPrank();
        _skippedInTheMiddle(game, takingSide, x, NO_COURIER, "no courier, and cancelled");
        vm.revertToState(snap);
        // No courier over grant gone: an agent's order whose account dropped the sender and revoked the grant
        // records 0, not 7.
        vm.prank(m2.a);
        matching.grantAgent(agent.a, 10_000, _ends(vm.getBlockTimestamp() + 1 hours), _noLines());
        x = _restBy(agent, m2.a, 1, game, restingSide, 200, 10_000);
        vm.startPrank(m2.a);
        matching.revokeAgent();
        matching.unregisterCourier(sender);
        vm.stopPrank();
        _skippedInTheMiddle(game, takingSide, x, NO_COURIER, "no courier, and its grant gone");
        vm.revertToState(snap);
        // Cancelled over expired.
        x = _restUntil(m2, game, restingSide, 200, 10_000, vm.getBlockTimestamp());
        vm.prank(m2.a);
        matching.cancelOrder(x.order);
        _skippedInTheMiddle(game, takingSide, x, CANCELLED, "cancelled, and expired");
        vm.revertToState(snap);
        // Cancelled over grant gone: an agent's order, cancelled by the account and then its grant revoked,
        // records 1, not 7.
        vm.prank(m2.a);
        matching.grantAgent(agent.a, 10_000, _ends(vm.getBlockTimestamp() + 1 hours), _noLines());
        x = _restBy(agent, m2.a, 1, game, restingSide, 200, 10_000);
        vm.startPrank(m2.a);
        matching.cancelOrder(x.order);
        matching.revokeAgent();
        vm.stopPrank();
        _skippedInTheMiddle(game, takingSide, x, CANCELLED, "cancelled, and its grant gone");
        vm.revertToState(snap);
        // Grant gone over expired: an agent's order whose grant the account revoked, at its own expiry,
        // records 7, not 2.
        vm.prank(m2.a);
        matching.grantAgent(agent.a, 10_000, _ends(vm.getBlockTimestamp() + 1 hours), _noLines());
        x = _signed(
            _order(
                m2.a,
                game,
                address(moneyline),
                0,
                restingSide,
                _tick(200),
                10_000,
                _nonce(0, 1, _no(nextNonce++)),
                vm.getBlockTimestamp()
            ),
            agent.key
        );
        vm.prank(m2.a);
        matching.revokeAgent();
        _skippedInTheMiddle(game, takingSide, x, GRANT_GONE, "its grant gone, and expired");
        vm.revertToState(snap);
        // The floor is the second half of the same row: under its account's floor over expired, and over
        // full.
        x = _restUntil(m2, game, restingSide, 200, 10_000, vm.getBlockTimestamp());
        vm.prank(m2.a);
        matching.raiseFloor(m2.a, game, address(moneyline), 0, _no(x.order.nonce + 1));
        _skippedInTheMiddle(game, takingSide, x, CANCELLED, "under its floor, and expired");
        vm.revertToState(snap);
        x = _rest(m2, game, restingSide, 200, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
        vm.prank(m2.a);
        matching.raiseFloor(m2.a, game, address(moneyline), 0, _no(x.order.nonce + 1));
        _skippedInTheMiddle(game, takingSide, x, CANCELLED, "under its floor, and full");
        vm.revertToState(snap);
        // Expired over no room: filled to its stake, and then its expiry passes.
        x = _restUntil(m2, game, restingSide, 200, 10_000, vm.getBlockTimestamp() + 10);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
        vm.warp(vm.getBlockTimestamp() + 10);
        _skippedInTheMiddle(game, takingSide, x, EXPIRED, "expired, and full");
        vm.revertToState(snap);
        // No room over nothing fits: a full order fits nothing, and is recorded as full.
        x = _rest(m2, game, restingSide, 150, 200);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(x));
        assertEq(_filled(x), 200, "two lots at 1.50");
        _skippedInTheMiddle(game, takingSide, x, NO_ROOM, "full, and nothing fits");
        vm.revertToState(snap);
        // Nothing fits over a refused pull: an order nothing fits, from an account that could not pay, is
        // recorded as "nothing fits". (The test below shows the coin is not asked.)
        x = _rest(m2, game, restingSide, 150, 100);
        vm.prank(m2.a);
        coin.approve(address(positions), 0);
        _skippedInTheMiddle(game, takingSide, x, NOTHING_FITS, "nothing fits, from an account that could not pay");
        vm.revertToState(snap);

        // A refused pull on the first order of a market no fill has drawn: the market the leg drew goes with
        // the leg, the next order draws it, and its id is the one a Cross without the skipped order gives.
        uint256 undrawn = _verifiedGame();
        x = _rest(m2, undrawn, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory next = _rest(m3, undrawn, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory first = _take(tk, undrawn, takingSide, 200, 10_000);
        vm.prank(m2.a);
        coin.approve(address(positions), 0);
        uint256 drawn = markets.marketCount();
        uint256 beforeTheSkip = vm.snapshotState();
        vm.recordLogs();
        _cross(sender, first, _list(x, next));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record for the first order");
        _assertSkip(skips[0], x, first, PULL_REFUSED, "a refused pull on the first order of an undrawn market");
        assertEq(markets.marketCount(), drawn + 1, "a market drawn for the skipped leg");
        assertEq(markets.getMarketId(undrawn, address(moneyline), 0), drawn + 1, "the market's id");
        bytes32 with = _print(first, x, next, next);
        vm.revertToState(beforeTheSkip);
        _cross(sender, first, _list(next));
        assertEq(with, _print(first, x, next, next), "not as if the first order had not been listed");
        vm.revertToState(snap);

        _notSkips(game, takingSide);
        // Back to the state this began in, in which nobody has registered the sender.
        vm.revertToState(start);
    }

    /// @dev What is not a skip: each reverts the whole Cross, after a leg that would have filled, and leaves
    ///      nothing of it. A later valid Cross then finds every order's room as it was.
    function _notSkips(uint256 game, Side takingSide) internal {
        Side restingSide = _other(takingSide);
        IERC20 coin = _coin();
        OspexMatching.SignedOrder memory one = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory two = _rest(m2, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory three = _rest(m3, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        uint256 snap = vm.snapshotState();

        // The taking account cannot pay at the end: it holds 15,000, and its one pull, after the walk, is its
        // worst loss over both legs, 20,000. The refusal carries that netted pull, not a leg's stake.
        uint256 spare = coin.balanceOf(tk.a) - 15_000;
        vm.prank(tk.a);
        assertTrue(coin.transfer(stranger, spare), "the transfer out");
        bytes32 before = _print(taking, one, two, three);
        _refused(
            sender,
            taking,
            _list(one, three),
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, tk.a, 20_000),
            "the taking account cannot pay for the two legs"
        );
        assertEq(_print(taking, one, two, three), before, "a reverted Cross left something");
        // Paid back, the same Cross fills both legs: every order's room is as it was.
        vm.prank(stranger);
        assertTrue(coin.transfer(tk.a, spare), "the transfer back");
        _cross(sender, taking, _list(one, three));
        assertEq(_filled(taking), 20_000, "the same Cross, once the taking account can pay");
        assertEq(_filled(one), 10_000, "the first order's room, as it was");
        vm.revertToState(snap);

        // One account on both sides at 2.00: its own resting leg pulls nothing, and its one pull at the end is
        // its worst loss, 10,000, the 20,000 it takes less the 10,000 its own resting order wins it back. Holding
        // 25,000 it fills, and its coin falls by 10,000, not by its two stakes.
        OspexMatching.SignedOrder memory own = _rest(tk, game, restingSide, 200, 10_000);
        spare = coin.balanceOf(tk.a) - 25_000;
        vm.prank(tk.a);
        assertTrue(coin.transfer(stranger, spare), "the transfer out");
        _cross(sender, taking, _list(one, own));
        assertEq(_filled(own), 10_000, "the taking account's own resting order");
        assertEq(coin.balanceOf(tk.a), 15_000, "the account on both sides paid its worst loss, once");
        vm.revertToState(snap);
        // Holding 9,999 the end's pull of 10,000 is refused. That is the taking account's error, carrying the
        // netted pull, and it reverts the Cross: it is not read as a refused resting pull.
        spare = coin.balanceOf(tk.a) - 9_999;
        vm.prank(tk.a);
        assertTrue(coin.transfer(stranger, spare), "the transfer out");
        _refused(
            sender,
            taking,
            _list(one, own),
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, tk.a, 10_000),
            "one account on both sides, short for its worst loss"
        );
        assertEq(_filled(own), 0, "a reverted Cross left a filled amount");
        vm.revertToState(snap);

        // Bets closed: at start + n the Cross reverts, whatever would have filled. The orders are signed at that
        // second, so nothing about them is stale.
        vm.warp(START + WINDOW);
        OspexMatching.SignedOrder memory late = _take(tk, game, takingSide, 200, 20_000);
        one = _rest(m1, game, restingSide, 200, 10_000);
        three = _rest(m3, game, restingSide, 200, 10_000);
        before = _print(late, one, two, three);
        _refused(
            sender,
            late,
            _list(one, three),
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__BetsClosed.selector, game, START + WINDOW),
            "bets closed"
        );
        assertEq(_print(late, one, two, three), before, "a Cross refused at the close left something");
        // A second earlier the same resting orders fill, against a taking order signed at that second.
        vm.warp(START + WINDOW - 1);
        late = _take(tk, game, takingSide, 200, 20_000);
        _cross(sender, late, _list(one, three));
        assertEq(_filled(late), 20_000, "one second before the close");
        vm.revertToState(snap);
    }

    /// The coin is not asked for the stake of an order nothing fits. The order's account could not pay: a
    /// pull, had one been made, would be refused and the order recorded for that instead. Over the whole test
    /// the coin is never asked to move that account's coin.
    /// Break: in OspexMatching._leg, weaken the minimum to refuse only a leg of no lots: the leg is then
    /// attempted, and the coin is asked.
    function test_neverLine_anOrderNothingFitsNeverReachesTheCoin() public {
        _registerAll(sender);
        uint256 game = _verifiedGame();
        IERC20 coin = _coin();
        vm.prank(m2.a);
        coin.approve(address(positions), 0);
        vm.expectCall(address(coin), abi.encodeWithSelector(IERC20.transferFrom.selector, m2.a), 0);
        _neverAsked(game, Side.B);
        _neverAsked(game, Side.A);
    }

    function _neverAsked(uint256 game, Side takingSide) internal {
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory nothingFits = _rest(m2, game, restingSide, 150, 100);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        vm.recordLogs();
        _cross(
            sender,
            taking,
            _list(_rest(m1, game, restingSide, 200, 10_000), nothingFits, _rest(m3, game, restingSide, 200, 10_000))
        );
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record");
        _assertSkip(
            skips[0], nothingFits, taking, NOTHING_FITS, "an order nothing fits, from an account that could not pay"
        );
        assertEq(_filled(taking), 20_000, "the two orders beside it");
    }

    /// A full order whose account cannot pay is recorded as full, and the coin is not asked: an order's room
    /// is looked at before anything is pulled. The account cannot pay in each of three ways: it holds no coin,
    /// it has withdrawn its allowance, and the coin has blocked it. From the two fills that make its two
    /// orders full to the end of this test, the coin is not asked to move that account's coin.
    /// Break: in OspexMatching._leg, delete the room's row and count the lots from the signed stake: a full
    /// order goes to the pull, and its account, which cannot pay, is recorded as refused. Another turns it
    /// red: the room's row asking the coin for a lot before it records the order as full.
    function test_neverLine_aFullOrderThatCannotPayIsRecordedAsFullAndTheCoinIsNotAsked() public {
        _registerAll(sender);
        uint256 game = _verifiedGame();
        IERC20 coin = _coin();
        // Two orders of the second resting account, one on each side, each filled to its signed stake while
        // the account can pay.
        OspexMatching.SignedOrder memory onA = _rest(m2, game, Side.A, 200, 10_000);
        OspexMatching.SignedOrder memory onB = _rest(m2, game, Side.B, 200, 10_000);
        _cross(sender, _take(tk, game, Side.B, 200, 10_000), _list(onA));
        _cross(sender, _take(tk, game, Side.A, 200, 10_000), _list(onB));
        assertEq(_filled(onA), 10_000, "the order on side A is full");
        assertEq(_filled(onB), 10_000, "the order on side B is full");
        // From here the coin must not be asked to move this account's coin.
        vm.expectCall(address(coin), abi.encodeWithSelector(IERC20.transferFrom.selector, m2.a), 0);
        uint256 snap = vm.snapshotState();

        // It holds no coin.
        uint256 all = coin.balanceOf(m2.a);
        vm.prank(m2.a);
        assertTrue(coin.transfer(stranger, all), "the transfer out");
        _fullAndCannotPay(game, onA, onB, "holds no coin");
        vm.revertToState(snap);
        // It has withdrawn its allowance.
        vm.prank(m2.a);
        coin.approve(address(positions), 0);
        _fullAndCannotPay(game, onA, onB, "has withdrawn its allowance");
        vm.revertToState(snap);
        // The coin has blocked it.
        token.setBlocked(m2.a, true);
        _fullAndCannotPay(game, onA, onB, "is blocked by the coin");
        vm.revertToState(snap);
    }

    /// @dev Each of the two full orders, listed between two orders that fill, is skipped for no room and leaves
    ///      what a Cross without it leaves: the one on side A under a taking order on side B, and the other way.
    function _fullAndCannotPay(
        uint256 game,
        OspexMatching.SignedOrder memory onA,
        OspexMatching.SignedOrder memory onB,
        string memory how
    ) internal {
        _skippedInTheMiddle(game, Side.B, onA, NO_ROOM, string.concat("full, and its account ", how));
        _skippedInTheMiddle(game, Side.A, onB, NO_ROOM, string.concat("full on the other side, and its account ", how));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 10. A Cross that fills nothing reverts and leaves nothing. Its refusal carries each order's reason.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cross, delete the final check, `if (tally.legs == 0) revert
    /// OspexMatching__NothingFilled(reasons);`. A Cross of skips alone then succeeds. Another turns it red: the
    /// reasons not written into the refusal.
    function test_neverLine_aCrossThatFillsNothingRevertsAndLeavesNothing() public {
        _nothingCases(Side.B);
        _nothingCases(Side.A);
    }

    function _nothingCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        Signer memory unregistered = _account("unregistered");
        Signer memory full = _account("full");
        Signer memory under = _account("under its minimum");
        Signer memory unpaid = _account("unpaid");
        Signer memory granting = _account("granting");
        Signer memory agent = _key("its revoked agent");
        _registerAll(sender);
        _register(full.a, sender);
        _register(under.a, sender);
        _register(unpaid.a, sender);
        _register(granting.a, sender);

        // One order in each of the eight states.
        OspexMatching.SignedOrder[] memory eight = new OspexMatching.SignedOrder[](8);
        eight[NO_COURIER] = _rest(unregistered, game, restingSide, 200, 10_000);
        eight[CANCELLED] = _rest(m1, game, restingSide, 200, 10_000);
        vm.prank(m1.a);
        matching.cancelOrder(eight[CANCELLED].order);
        eight[EXPIRED] = _restUntil(m2, game, restingSide, 200, 10_000, vm.getBlockTimestamp());
        eight[NO_ROOM] = _rest(full, game, restingSide, 200, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(eight[NO_ROOM]));
        eight[NOTHING_FITS] = _rest(m3, game, restingSide, 150, 100);
        // Under its minimum: 30,000 asking for 25,000 at least, against a taking order of 20,000, which would
        // take 20,000 of it and leave 10,000, a lot or more.
        eight[UNDER_MIN_FILL] = _restMin(under, game, restingSide, 200, 30_000, 25_000);
        eight[PULL_REFUSED] = _rest(unpaid, game, restingSide, 200, 10_000);
        IERC20 coin = _coin();
        vm.prank(unpaid.a);
        coin.approve(address(positions), 0);
        // Grant gone: an agent's order, its grant revoked.
        vm.prank(granting.a);
        matching.grantAgent(agent.a, 10_000, _ends(vm.getBlockTimestamp() + 1 hours), _noLines());
        eight[GRANT_GONE] = _restBy(agent, granting.a, 1, game, restingSide, 200, 10_000);
        vm.prank(granting.a);
        matching.revokeAgent();

        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        bytes32 before = _print(taking, eight[CANCELLED], eight[EXPIRED], eight[NOTHING_FITS]);
        uint256 held = coin.balanceOf(address(positions));

        // An empty list.
        _refused(sender, taking, _list(), _nothingFilled(new uint8[](0)), "an empty list");
        // Each of the eight alone.
        for (uint8 reason; reason < 8; ++reason) {
            _refused(sender, taking, _list(eight[reason]), _nothingFilled(_reasons(reason)), "one skip alone");
        }
        // All eight together: the refusal carries the reasons in list order, here and in another order.
        uint8[] memory inOrder = new uint8[](8);
        for (uint8 i; i < 8; ++i) {
            inOrder[i] = i;
        }
        _refused(sender, taking, eight, _nothingFilled(inOrder), "all eight, in the order of the reasons");
        uint8[] memory shuffled = new uint8[](5);
        shuffled[0] = PULL_REFUSED;
        shuffled[1] = GRANT_GONE;
        shuffled[2] = UNDER_MIN_FILL;
        shuffled[3] = NO_ROOM;
        shuffled[4] = NO_COURIER;
        OspexMatching.SignedOrder[] memory five = new OspexMatching.SignedOrder[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = eight[shuffled[i]];
        }
        _refused(sender, taking, five, _nothingFilled(shuffled), "five of them, in another order");
        // Nothing of any of them remains.
        assertEq(
            _print(taking, eight[CANCELLED], eight[EXPIRED], eight[NOTHING_FITS]),
            before,
            "a refused Cross left something"
        );
        assertEq(coin.balanceOf(address(positions)), held, "a refused Cross moved coin");
        assertEq(_filled(eight[PULL_REFUSED]), 0, "a refused Cross left a filled amount");
        assertEq(_filled(eight[UNDER_MIN_FILL]), 0, "a refused Cross left a filled amount under the minimum");
        assertEq(_filled(eight[GRANT_GONE]), 0, "a refused Cross left a filled amount under a dead grant");
        assertEq(_filled(taking), 0, "a refused Cross filled the taking order");

        // The same orders in a later Cross beside one that fills: the eight skips are recorded then, in order.
        OspexMatching.SignedOrder[] memory nine = new OspexMatching.SignedOrder[](9);
        for (uint256 i; i < 8; ++i) {
            nine[i] = eight[i];
        }
        nine[8] = _rest(m1, game, restingSide, 200, 10_000);
        vm.recordLogs();
        _cross(sender, taking, nine);
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 8, "eight skip records beside one fill");
        for (uint8 reason; reason < 8; ++reason) {
            _assertSkip(skips[reason], eight[reason], taking, reason, "a skip beside a fill");
        }
        assertEq(_filled(taking), 10_000, "the one order that fills");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 16. The fill names the taking account, and the Cross's event names the sender.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    bytes32 internal constant MARKET_CREATED_TOPIC =
        keccak256("MarketCreated(uint256,uint256,address,int32,address,address)");
    bytes32 internal constant POSITION_FILLED_TOPIC =
        keccak256("PositionFilled(uint256,address,address,uint8,uint8,uint256,uint256)");
    bytes32 internal constant CORE_EVENT_TOPIC = keccak256("CoreEventEmitted(bytes32,address,bytes)");
    bytes32 internal constant HELD_CHANGED_TOPIC = keccak256("HeldChanged(uint256,address,uint256,uint256,uint256)");

    /// @dev The logs of a call that the set's contracts emitted, in order: the coin's are left out.
    function _setLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory out) {
        out = new Vm.Log[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            address e = logs[i].emitter;
            if (e == address(matching) || e == address(positions) || e == address(markets) || e == address(core)) {
                out[n++] = logs[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    /// @dev The log at `at` is HeldChanged for a pull of `pulled` that left `held` held for `who`, and the next
    ///      its hub copy.
    function _assertHeld(
        Vm.Log[] memory logs,
        uint256 at,
        uint256 market,
        address who,
        uint256 pulled,
        uint256 held,
        string memory what
    ) internal view {
        _assertPair(
            logs,
            at,
            address(positions),
            [HELD_CHANGED_TOPIC, bytes32(market), _word(who), bytes32(0)],
            3,
            abi.encode(pulled, uint256(0), held),
            positions.EVENT_HELD_CHANGED(),
            abi.encode(market, who, pulled, uint256(0), held),
            what
        );
    }

    /// @dev One log is a typed event of `emitter` with these topics and this data, and the log after it is its
    ///      copy through the core's hub: the tag, the emitter, and the same values as the payload.
    function _assertPair(
        Vm.Log[] memory logs,
        uint256 at,
        address emitter,
        bytes32[4] memory topics,
        uint256 topicCount,
        bytes memory data,
        bytes32 tag,
        bytes memory payload,
        string memory what
    ) internal view {
        assertEq(logs[at].emitter, emitter, string.concat(what, ": the emitter"));
        assertEq(logs[at].topics.length, topicCount, string.concat(what, ": how many topics"));
        for (uint256 i; i < topicCount; ++i) {
            assertEq(logs[at].topics[i], topics[i], string.concat(what, ": topic ", vm.toString(i)));
        }
        assertEq(logs[at].data, data, string.concat(what, ": the data"));
        assertEq(logs[at + 1].emitter, address(core), string.concat(what, ": the hub copy's emitter"));
        assertEq(logs[at + 1].topics.length, 3, string.concat(what, ": the hub copy's topics"));
        assertEq(logs[at + 1].topics[0], CORE_EVENT_TOPIC, string.concat(what, ": the hub's event"));
        assertEq(logs[at + 1].topics[1], tag, string.concat(what, ": the hub copy's tag"));
        assertEq(
            logs[at + 1].topics[2], bytes32(uint256(uint160(emitter))), string.concat(what, ": the hub copy's module")
        );
        assertEq(logs[at + 1].data, abi.encode(payload), string.concat(what, ": the hub copy's payload"));
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// Break: in OspexMatching._leg, pass the sender to the positions module as the taker. Others turn it red:
    /// the sender named as the taker in OrderMatched; the taking account named as the courier in Crossed; each
    /// of the three hub copies dropped; Crossed emitted twice; the two stakes swapped in OrderMatched; a skip
    /// record emitted for a filled leg; the two hashes swapped in the skip record; the taking account named in
    /// the skip record; the two totals swapped in Crossed; the market left out of Crossed; the game's id
    /// carried as the market's, in OrderMatched and in Crossed; and the line's sign turned in OrderMatched.
    function test_neverLine_theFillNamesTheTakingAccountAndTheCrossNamesTheSender() public {
        _registerAll(sender);
        _eventCases(Side.B);
        _eventCases(Side.A);
    }

    function _eventCases(Side takingSide) internal {
        uint256 snap = vm.snapshotState();
        // Two games first, so that this game's id is not its market's; and a market on a line that is not 0,
        // the spread at -3.5. The records carry the game, the market and the line.
        _verifiedGame();
        _verifiedGame();
        uint256 game = _verifiedGame();
        address s = address(spread);
        Side restingSide = _other(takingSide);
        // The sender, the taking account and the three resting accounts are five addresses, and every amount is
        // its own. A taking order of 10,000 at 1.90; 100,000 resting at 2.10, of which 90 lots fill, 9,000
        // against 9,900; a cancelled order; and 50,000 resting at 1.50, of which the 100 units left take two
        // lots, 200 against 100.
        OspexMatching.SignedOrder memory taking = _takeOn(tk, game, s, -35, takingSide, 190, 10_000);
        OspexMatching.SignedOrder memory one = _restOn(m1, game, s, -35, restingSide, 210, 100_000);
        OspexMatching.SignedOrder memory skipped = _restOn(m2, game, s, -35, restingSide, 205, 7_000);
        OspexMatching.SignedOrder memory three = _signed(
            _order(m3.a, game, s, -35, restingSide, 150, 50_000, nextNonce++, vm.getBlockTimestamp() + 2 days), m3.key
        );
        vm.prank(m2.a);
        matching.cancelOrder(skipped.order);
        uint256 clean = vm.snapshotState();

        vm.recordLogs();
        _cross(sender, taking, _list(one, skipped, three));
        Vm.Log[] memory logs = _setLogs(vm.getRecordedLogs());
        assertEq(logs.length, 20, "the number of logs: ten events, each with its hub copy");
        uint256 market = 1;
        assertEq(markets.getMarketId(game, s, -35), market, "the market's id");
        assertTrue(game != market, "the game's id is the market's");

        // The first filled leg draws the market.
        _assertPair(
            logs,
            0,
            address(markets),
            [MARKET_CREATED_TOPIC, bytes32(market), bytes32(game), bytes32(0)],
            3,
            abi.encode(s, int32(-35), m1.a, tk.a),
            markets.EVENT_MARKET_CREATED(),
            abi.encode(market, game, s, int32(-35), m1.a, tk.a),
            "MarketCreated"
        );
        // The resting account's pull, before the fill it belongs to: its held amount rises by its stake.
        _assertHeld(logs, 2, market, m1.a, 9_000, 9_000, "HeldChanged, the first resting pull");
        // The fill: its taker is the taking account, never the sender.
        _assertPair(
            logs,
            4,
            address(positions),
            [POSITION_FILLED_TOPIC, bytes32(market), _word(m1.a), _word(tk.a)],
            4,
            abi.encode(restingSide, takingSide, uint256(9_000), uint256(9_900)),
            positions.EVENT_POSITION_MATCHED_PAIR(),
            abi.encode(market, m1.a, tk.a, restingSide, takingSide, uint256(9_000), uint256(9_900)),
            "PositionFilled, first leg"
        );
        _assertMatched(logs, 6, one, market, 9_000, 9_900, "OrderMatched, first leg");
        // The skip, between the two fills, with its four fields.
        _assertPair(
            logs,
            8,
            address(matching),
            [ORDER_SKIPPED_TOPIC, _hash(skipped), _word(m2.a), _hash(taking)],
            4,
            abi.encode(CANCELLED),
            matching.EVENT_ORDER_SKIPPED(),
            abi.encode(_hash(skipped), m2.a, _hash(taking), CANCELLED),
            "OrderSkipped"
        );
        _assertHeld(logs, 10, market, m3.a, 200, 200, "HeldChanged, the second resting pull");
        _assertPair(
            logs,
            12,
            address(positions),
            [POSITION_FILLED_TOPIC, bytes32(market), _word(m3.a), _word(tk.a)],
            4,
            abi.encode(restingSide, takingSide, uint256(200), uint256(100)),
            positions.EVENT_POSITION_MATCHED_PAIR(),
            abi.encode(market, m3.a, tk.a, restingSide, takingSide, uint256(200), uint256(100)),
            "PositionFilled, second leg"
        );
        _assertMatched(logs, 14, three, market, 200, 100, "OrderMatched, second leg");
        // After the walk, the taking account's one pull: both legs' stakes, 9,900 and 100.
        _assertHeld(logs, 16, market, tk.a, 10_000, 10_000, "HeldChanged, the taking account's pull at the end");
        // Once, and last: the Cross's own event names the sender, the immediate caller.
        _assertPair(
            logs,
            18,
            address(matching),
            [CROSSED_TOPIC, _word(sender), _hash(taking), _word(tk.a)],
            4,
            abi.encode(market, uint256(9_200), uint256(10_000)),
            matching.EVENT_CROSSED(),
            abi.encode(sender, _hash(taking), tk.a, market, uint256(9_200), uint256(10_000)),
            "Crossed"
        );

        // A clean Cross, every leg filled, has no skip record: nine events, each with its hub copy.
        vm.revertToState(clean);
        vm.recordLogs();
        _cross(sender, taking, _list(one, three));
        Vm.Log[] memory raw = vm.getRecordedLogs();
        assertEq(_setLogs(raw).length, 18, "the number of logs of a clean Cross");
        assertEq(_count(raw, ORDER_SKIPPED_TOPIC), 0, "a skip record on a clean Cross");
        assertEq(_count(raw, ORDER_MATCHED_TOPIC), 2, "OrderMatched, once per filled leg");
        assertEq(_count(raw, CROSSED_TOPIC), 1, "Crossed, once");
        vm.revertToState(snap);
    }

    /// @dev The log at `at` is OrderMatched for `resting` with these two stakes, and the next its hub copy.
    function _assertMatched(
        Vm.Log[] memory logs,
        uint256 at,
        OspexMatching.SignedOrder memory resting,
        uint256 market,
        uint256 makerRisk,
        uint256 takerRisk,
        string memory what
    ) internal view {
        OspexMatching.OspexOrder memory o = resting.order;
        bytes memory rest = abi.encode(o.oddsTick, makerRisk, takerRisk, o.riskAmount, o.nonce, o.expiry, o.minFill);
        bytes memory data = bytes.concat(abi.encode(o.gameId, market, o.scorer, o.lineTicks, o.positionType), rest);
        bytes memory payload = bytes.concat(abi.encode(_hash(resting), o.account, tk.a), data);
        _assertPair(
            logs,
            at,
            address(matching),
            [ORDER_MATCHED_TOPIC, _hash(resting), _word(o.account), _word(tk.a)],
            4,
            data,
            matching.EVENT_ORDER_MATCHED(),
            payload,
            what
        );
    }
}
