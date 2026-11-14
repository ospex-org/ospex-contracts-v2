// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {GameStatus, IOspexGames} from "../../src/games/IOspexGames.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {TrickCoin} from "../games/CoinFixtures.sol";
import {CallbackAccount, ScriptedCoin, TwoCrosses} from "./CrossFixtures.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross against a coin that calls the debited account during a transfer, which USDC does not: what
///         an account's own code can and cannot do from inside a pull. The set here is deployed on such a coin,
///         and two of its accounts are keys with code at their address, so they sign and can be called back.
///         Above each test, "Break:" names changes to src/betting that turn it red; each is an entry of
///         battery.json.
contract OspexCrossCallbacksTest is CrossBase {
    /// @dev The exclusion's refusal: four bytes, the error's selector.
    bytes internal IN_PROGRESS = abi.encodeWithSelector(OspexMatching.OspexMatching__CrossInProgress.selector);

    TrickCoin internal trick;
    /// @dev A resting account and the taking account, each a key with code.
    Signer internal y;
    Signer internal tk;
    /// @dev A resting account that is a plain key.
    Signer internal m1;
    /// @dev The two accounts of a second Cross, which the resting account with code may send.
    Signer internal u;
    Signer internal v;

    function setUp() public override {
        super.setUp();
        trick = new TrickCoin();
        _deploySetOn(address(trick));
        y = _account("resting account with code");
        tk = _account("taking account with code");
        m1 = _account("resting one");
        u = _account("another taking account");
        v = _account("another resting account");
        bytes memory code = address(new CallbackAccount()).code;
        vm.etch(y.a, code);
        vm.etch(tk.a, code);
        _register(y.a, sender);
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(u.a, y.a);
        _register(v.a, y.a);
    }

    /// @dev What the armed call-back's one call answered.
    function _answer(Signer memory who) internal view returns (bool ok, bytes memory answer) {
        (bool[] memory oks, bytes[] memory answers) = CallbackAccount(who.a).results();
        assertEq(oks.length, 1, "the call-back made one call");
        return (oks[0], answers[0]);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 12. Nothing in the matching contract changes while a Cross is in progress.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev One case: `who`, called back during the pull of its own stake in the first leg, makes `call` to the
    ///      matching module. The call is refused by the exclusion's own name, and the outer Cross fills both
    ///      legs with the stakes it would have had. The same call, made outside a Cross, succeeds: the refusal
    ///      is the exclusion's and not an argument's.
    function _sibling(
        Signer memory who,
        bytes memory call,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        string memory what
    ) internal {
        uint256 snap = vm.snapshotState();
        // The control.
        vm.prank(who.a);
        (bool alone,) = address(matching).call(call);
        assertTrue(alone, string.concat(what, ": the call is refused outside a Cross too"));
        vm.revertToState(snap);

        trick.setHooked(who.a, true);
        CallbackAccount(who.a).arm(address(matching), call);
        _cross(sender, taking, resting);
        (bool ok, bytes memory answer) = _answer(who);
        assertFalse(ok, string.concat(what, ": the call from inside a pull was taken"));
        assertEq(answer, IN_PROGRESS, string.concat(what, ": refused, but not by the exclusion"));
        assertEq(_filled(taking), 20_000, string.concat(what, ": the taking order"));
        assertEq(_filled(resting[0]), 10_000, string.concat(what, ": the first leg"));
        assertEq(_filled(resting[1]), 10_000, string.concat(what, ": the second leg"));
    }

    /// Break: in OspexMatching.cancelOrder, delete the exclusion's check, `if (_crossInProgress()) revert
    /// OspexMatching__CrossInProgress();`. Others turn it red: the same check deleted from raiseFloor, from
    /// cancelAll, from registerCourier, from unregisterCourier, from cross, from _grant, which grantAgent and
    /// grantAgentAndRegisterCourier share, and from revokeAgent; the mark never set; and the two filled
    /// amounts written after the positions call, which the read from inside the pull shows.
    function test_neverLine_nothingInTheMatchingContractChangesWhileACrossIsInProgress() public {
        _inProgressCases(Side.B);
        _inProgressCases(Side.A);
    }

    function _inProgressCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        OspexMatching.SignedOrder memory first = _rest(y, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory second = _rest(y, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder[] memory resting = _list(first, second);
        address other = makeAddr("another courier");
        uint256 snap = vm.snapshotState();

        // 1. From inside the first leg's pull, the resting account cancels its second order.
        _sibling(y, abi.encodeCall(OspexMatching.cancelOrder, (second.order)), taking, resting, "a cancel");
        assertFalse(matching.s_cancelledOrders(_hash(second)), "the second order was cancelled from inside a pull");
        vm.revertToState(snap);

        // 2. It raises its floor past its second order's nonce.
        _sibling(
            y,
            abi.encodeCall(OspexMatching.raiseFloor, (y.a, game, address(moneyline), 0, _no(second.order.nonce + 1))),
            taking,
            resting,
            "a raised floor"
        );
        assertEq(matching.getFloor(y.a, game, address(moneyline), 0), 0, "the floor was raised from inside a pull");
        vm.revertToState(snap);

        // 3. It drops the sender as its courier.
        _sibling(y, abi.encodeWithSignature("unregisterCourier(address)", sender), taking, resting, "a drop");
        assertTrue(matching.isCourier(y.a, sender), "the sender was dropped from inside a pull");
        vm.revertToState(snap);

        // 4. It registers another courier.
        _sibling(y, abi.encodeWithSignature("registerCourier(address)", other), taking, resting, "a registration");
        assertFalse(matching.isCourier(y.a, other), "a courier was registered from inside a pull");
        vm.revertToState(snap);

        // 4b. It cancels everything, and it grants an agent, with and without a courier beside the grant.
        _sibling(y, abi.encodeCall(OspexMatching.cancelAll, (y.a)), taking, resting, "a cancel-all");
        assertEq(matching.s_version(y.a), 0, "the version moved from inside a pull");
        vm.revertToState(snap);
        uint64 ends = _ends(vm.getBlockTimestamp() + 1 hours);
        _sibling(y, abi.encodeCall(OspexMatching.grantAgent, (other, 1, ends, _noLines())), taking, resting, "a grant");
        assertEq(matching.s_grantCount(y.a), 0, "a grant was made from inside a pull");
        assertEq(matching.s_currentGrant(y.a), 0);
        vm.revertToState(snap);
        _sibling(
            y,
            abi.encodeCall(OspexMatching.grantAgentAndRegisterCourier, (other, 1, ends, _noLines(), other)),
            taking,
            resting,
            "a grant with a courier"
        );
        assertEq(matching.s_grantCount(y.a), 0, "a grant with a courier was made from inside a pull");
        assertFalse(matching.isCourier(y.a, other), "its courier was registered from inside a pull");
        vm.revertToState(snap);
        // 4c. With a grant standing, it revokes, and it replaces the grant: neither moves the current grant.
        vm.prank(y.a);
        matching.grantAgent(other, 1, ends, _noLines());
        uint256 granted = vm.snapshotState();
        _sibling(y, abi.encodeCall(OspexMatching.revokeAgent, ()), taking, resting, "a revoke");
        assertEq(matching.s_currentGrant(y.a), 1, "the grant was revoked from inside a pull");
        assertTrue(matching.isLiveAgent(y.a, other));
        vm.revertToState(granted);
        _sibling(
            y, abi.encodeCall(OspexMatching.grantAgent, (sender, 1, ends, _noLines())), taking, resting, "a regrant"
        );
        assertEq(matching.s_grantCount(y.a), 1, "a regrant was made from inside a pull");
        assertTrue(matching.isLiveAgent(y.a, other), "the standing grant was replaced from inside a pull");
        vm.revertToState(snap);

        // 5. It sends a second Cross, for which it is a registered courier, with orders that fill on their own.
        OspexMatching.SignedOrder memory innerTaking = _take(u, game, takingSide, 200, 10_000);
        OspexMatching.SignedOrder memory innerResting = _rest(v, game, restingSide, 200, 10_000);
        _sibling(
            y,
            abi.encodeCall(OspexMatching.cross, (innerTaking, _list(innerResting))),
            taking,
            resting,
            "a second Cross"
        );
        assertEq(_filled(innerTaking), 0, "the nested Cross filled its taking order");
        assertEq(_filled(innerResting), 0, "the nested Cross filled its resting order");
        assertEq(positions.getPosition(1, u.a, takingSide).risk, 0, "the nested Cross wrote a position");
        assertEq(trick.balanceOf(address(positions)), 40_000, "the stakes held are the outer Cross's alone");
        vm.revertToState(snap);

        // 6. The same first three from the taking account, during the pull of its stake: it cancels its taking
        //    order, raises its floor past it, and drops the sender.
        _sibling(
            tk,
            abi.encodeCall(OspexMatching.cancelOrder, (taking.order)),
            taking,
            resting,
            "the taking account's cancel"
        );
        assertFalse(matching.s_cancelledOrders(_hash(taking)), "the taking order was cancelled from inside a pull");
        vm.revertToState(snap);
        _sibling(
            tk,
            abi.encodeCall(OspexMatching.raiseFloor, (tk.a, game, address(moneyline), 0, _no(taking.order.nonce + 1))),
            taking,
            resting,
            "the taking account's raised floor"
        );
        assertEq(
            matching.getFloor(tk.a, game, address(moneyline), 0),
            0,
            "the taking account's floor was raised from inside a pull"
        );
        vm.revertToState(snap);
        _sibling(
            tk,
            abi.encodeWithSignature("unregisterCourier(address)", sender),
            taking,
            resting,
            "the taking account's drop"
        );
        assertTrue(matching.isCourier(tk.a, sender), "the taking account dropped the sender from inside a pull");
        vm.revertToState(snap);

        // What a read from inside the pull returns. In the first leg, at the pull of the resting stake, both
        // orders' filled amounts already hold that leg, 10,000 each, and the second order's holds nothing: the
        // amounts are written before the positions module is called.
        trick.setHooked(y.a, true);
        CallbackAccount(y.a).arm(address(matching), abi.encodeCall(matching.s_filledRisk, (_hash(first))));
        CallbackAccount(y.a).armAlso(address(matching), abi.encodeCall(matching.s_filledRisk, (_hash(taking))));
        CallbackAccount(y.a).armAlso(address(matching), abi.encodeCall(matching.s_filledRisk, (_hash(second))));
        CallbackAccount(y.a).armAlso(address(matching), abi.encodeCall(matching.isCourier, (y.a, sender)));
        _cross(sender, taking, resting);
        (bool[] memory oks, bytes[] memory answers) = CallbackAccount(y.a).results();
        assertEq(oks.length, 4, "the four reads");
        for (uint256 i; i < 4; ++i) {
            assertTrue(oks[i], "a read was refused during a Cross");
        }
        assertEq(answers[0], abi.encode(uint256(10_000)), "the first order's filled amount, read from inside its pull");
        assertEq(answers[1], abi.encode(uint256(10_000)), "the taking order's filled amount, read from inside the pull");
        assertEq(answers[2], abi.encode(uint256(0)), "the second order's filled amount, read before its leg");
        assertEq(answers[3], abi.encode(true), "the courier read, from inside the pull");
        vm.revertToState(start);
    }

    /// A claim made from inside a pull is refused by the positions module's own guard. The resting account
    /// holds a winning position on a settled market; called back during the pull of its stake in a fill on
    /// another game, it claims that position: refused. Outside a fill the same claim is paid.
    /// Break: in OspexPositions.sol, take `nonReentrant` off recordFill. Another turns it red: taken off
    /// claimPosition.
    function test_neverLine_aClaimFromInsideAPullIsRefused() public {
        _claimCases(Side.B);
        _claimCases(Side.A);
    }

    /// @dev With the taking order on side B the resting account holds side A, and the home side is scored
    ///      the winner; with it on side A the resting account holds side B, and the away side is. Either
    ///      way the resting account's position is the winning one.
    function _claimCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        Side restingSide = _other(takingSide);
        uint256 settled = _verifiedGame();
        uint256 open = _verifiedGame();
        _cross(sender, _take(tk, settled, takingSide, 200, 10_000), _list(_rest(y, settled, restingSide, 200, 10_000)));
        uint256 market = markets.getMarketId(settled, address(moneyline), 0);
        if (restingSide == Side.A) {
            _score(settled, HOME, AWAY);
        } else {
            _score(settled, AWAY, HOME);
        }
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(restingSide == Side.A ? Outcome.Home : Outcome.Away));
        uint256 snap = vm.snapshotState();

        // The control: outside a fill, the claim is paid.
        assertEq(_claim(y.a, market, restingSide), 20_000, "the claim, outside a fill");
        vm.revertToState(snap);

        trick.setHooked(y.a, true);
        CallbackAccount(y.a)
            .arm(address(positions), abi.encodeCall(OspexPositions.claimPosition, (market, restingSide)));
        uint256 held = trick.balanceOf(address(positions));
        _cross(sender, _take(tk, open, takingSide, 200, 10_000), _list(_rest(y, open, restingSide, 200, 10_000)));
        (bool ok, bytes memory answer) = _answer(y);
        assertFalse(ok, "a claim from inside a pull was paid");
        assertEq(answer, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        assertEq(trick.balanceOf(address(positions)), held + 20_000, "the fill's two stakes, and no claim paid");
        assertFalse(
            positions.getPosition(market, y.a, restingSide).claimed, "the position was claimed from inside a pull"
        );
        // After the fill the claim is paid.
        assertEq(_claim(y.a, market, restingSide), 20_000, "the claim, after the fill");
        vm.revertToState(start);
    }

    /// Two Crosses sent one after the other in one transaction both fill, with a cancel between them: the
    /// exclusion's mark is cleared when a Cross ends.
    /// Break: in OspexMatching.cross, delete the line that clears the mark at the end.
    function test_neverLine_theExclusionEndsWithItsCross() public {
        _endCases(Side.B);
        _endCases(Side.A);
    }

    function _endCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        Side restingSide = _other(takingSide);
        uint256 game = _verifiedGame();
        TwoCrosses batch = new TwoCrosses();
        _register(tk.a, address(batch));
        _register(m1.a, address(batch));
        OspexMatching.SignedOrder memory takingOne = _take(tk, game, takingSide, 200, 10_000);
        OspexMatching.SignedOrder memory restingOne = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory takingTwo = _take(tk, game, takingSide, 200, 5_000);
        OspexMatching.SignedOrder memory restingTwo = _rest(m1, game, restingSide, 200, 5_000);
        // An order whose account is the sender itself: only that account may cancel it.
        OspexMatching.OspexOrder memory own = _order(
            address(batch), game, address(moneyline), 0, restingSide, 200, 10_000, 1, vm.getBlockTimestamp() + 1 days
        );

        batch.send(
            matching,
            abi.encodeCall(OspexMatching.cross, (takingOne, _list(restingOne))),
            own,
            abi.encodeCall(OspexMatching.cross, (takingTwo, _list(restingTwo)))
        );
        assertEq(_filled(takingOne), 10_000, "the first Cross");
        assertEq(_filled(restingOne), 10_000, "the first Cross's resting order");
        assertTrue(matching.s_cancelledOrders(_digest(own)), "the cancel between the two Crosses");
        assertEq(_filled(takingTwo), 5_000, "the second Cross");
        assertEq(_filled(restingTwo), 5_000, "the second Cross's resting order");
        vm.revertToState(start);
    }

    /// @dev The four calls an account may make to the matching module on its own behalf.
    function _fourCalls(uint256 game, OspexMatching.SignedOrder memory spare, address other)
        internal
        view
        returns (bytes[4] memory calls)
    {
        calls[0] = abi.encodeCall(OspexMatching.cancelOrder, (spare.order));
        calls[1] =
            abi.encodeCall(OspexMatching.raiseFloor, (y.a, game, address(moneyline), 0, _no(spare.order.nonce + 1)));
        calls[2] = abi.encodeWithSignature("unregisterCourier(address)", sender);
        calls[3] = abi.encodeWithSignature("registerCourier(address)", other);
    }

    /// @dev One case in a later leg: the resting account with code is listed second, and is called back during
    ///      the pull of its stake, after the first entry filled or was skipped. Its call to the matching module
    ///      is refused by the exclusion's own name, and its leg fills.
    function _laterSibling(
        bytes memory call,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        uint256 takingFilled,
        string memory what
    ) internal {
        trick.setHooked(y.a, true);
        CallbackAccount(y.a).arm(address(matching), call);
        _cross(sender, taking, resting);
        (bool ok, bytes memory answer) = _answer(y);
        assertFalse(ok, string.concat(what, ": the call from inside a later pull was taken"));
        assertEq(answer, IN_PROGRESS, string.concat(what, ": refused, but not by the exclusion"));
        assertEq(_filled(resting[1]), 10_000, string.concat(what, ": the leg the call was made from"));
        assertEq(_filled(taking), takingFilled, string.concat(what, ": the taking order"));
    }

    /// @dev Seven resting orders, each of an account of its own and each in one state that skips: the order at
    ///      a number is skipped under that number's reason, against a taking order of 20,000.
    function _sevenSkipped(uint256 game, Side restingSide) internal returns (OspexMatching.SignedOrder[] memory seven) {
        seven = new OspexMatching.SignedOrder[](7);
        Signer[7] memory who;
        for (uint256 i; i < 7; ++i) {
            who[i] = _account(string.concat("an account whose order is skipped for reason ", vm.toString(i)));
            if (i != NO_COURIER) _register(who[i].a, sender);
        }
        seven[NO_COURIER] = _rest(who[NO_COURIER], game, restingSide, 200, 10_000);
        seven[CANCELLED] = _rest(who[CANCELLED], game, restingSide, 200, 10_000);
        vm.prank(who[CANCELLED].a);
        matching.cancelOrder(seven[CANCELLED].order);
        seven[EXPIRED] = _restUntil(who[EXPIRED], game, restingSide, 200, 10_000, vm.getBlockTimestamp());
        // Filled to its signed stake by an earlier Cross.
        seven[NO_ROOM] = _rest(who[NO_ROOM], game, restingSide, 200, 10_000);
        _cross(sender, _take(tk, game, _other(restingSide), 200, 10_000), _list(seven[NO_ROOM]));
        // One lot at 1.50 is 100 against 50.
        seven[NOTHING_FITS] = _rest(who[NOTHING_FITS], game, restingSide, 150, 100);
        // Under its minimum: 30,000 asking for 25,000 at least; a taking order of 20,000 would take 20,000 of it
        // and leave 10,000, a lot or more.
        seven[UNDER_MIN_FILL] = _restMin(who[UNDER_MIN_FILL], game, restingSide, 200, 30_000, 25_000);
        // Its account lets the positions module take nothing.
        seven[PULL_REFUSED] = _rest(who[PULL_REFUSED], game, restingSide, 200, 10_000);
        vm.prank(who[PULL_REFUSED].a);
        trick.approve(address(positions), 0);
    }

    /// @dev Nothing the four calls would have changed is changed.
    function _untouched(uint256 game, OspexMatching.SignedOrder memory spare, address other) internal view {
        assertFalse(matching.s_cancelledOrders(_hash(spare)), "an order was cancelled from inside a later pull");
        assertEq(matching.getFloor(y.a, game, address(moneyline), 0), 0, "a floor was raised from inside a later pull");
        assertTrue(matching.isCourier(y.a, sender), "the sender was dropped from inside a later pull");
        assertFalse(matching.isCourier(y.a, other), "a courier was registered from inside a later pull");
    }

    /// The exclusion holds from the first check of a Cross to its end: through a leg that filled, and past an
    /// order that was skipped, for each of the seven reasons.
    /// Break: in OspexMatching._leg, clear the exclusion's mark once a leg has filled. Others turn it red: the
    /// mark cleared in cross once an order has been skipped; cleared in _leg after a refused pull; and cleared
    /// in _leg where an order nothing fits is skipped.
    function test_neverLine_theExclusionHoldsThroughEveryLeg() public {
        _throughCases(Side.B);
        _throughCases(Side.A);
    }

    function _throughCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        Side restingSide = _other(takingSide);
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        OspexMatching.SignedOrder memory fills = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder[] memory seven = _sevenSkipped(game, restingSide);
        OspexMatching.SignedOrder memory hooked = _rest(y, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory spare = _rest(y, game, restingSide, 200, 10_000);
        address other = makeAddr("another courier");
        bytes[4] memory calls = _fourCalls(game, spare, other);
        uint256 snap = vm.snapshotState();

        for (uint256 i; i < 4; ++i) {
            // The control: outside a Cross the call is taken.
            vm.prank(y.a);
            (bool alone,) = address(matching).call(calls[i]);
            assertTrue(alone, "the call is refused outside a Cross too");
            vm.revertToState(snap);

            _laterSibling(calls[i], taking, _list(fills, hooked), 20_000, "after a leg that filled");
            _untouched(game, spare, other);
            vm.revertToState(snap);
            for (uint8 reason; reason < 7; ++reason) {
                _laterSibling(
                    calls[i],
                    taking,
                    _list(seven[reason], hooked),
                    10_000,
                    string.concat("after an order skipped for reason ", vm.toString(reason))
                );
                _untouched(game, spare, other);
                vm.revertToState(snap);
            }
        }
        vm.revertToState(start);
    }

    /// The two filled amounts a leg writes are written before the positions module is called, and both are put
    /// back if the leg is skipped. The resting account, called back in the pull of its stake, reads a filled
    /// amount from the matching module and refuses the transfer if it reads this leg's amount: so the leg is
    /// skipped only if the amount was already written, and the amounts afterwards show whether it was put back.
    /// Break: in OspexMatching._leg, write the resting order's filled amount after the positions call. Another
    /// turns it red: the taking order's written after it.
    function test_neverLine_aSkippedLegsFilledAmountsAreWrittenFirstAndPutBack() public {
        _writtenCases(Side.B);
        _writtenCases(Side.A);
    }

    function _writtenCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        Side restingSide = _other(takingSide);
        uint256 game = _verifiedGame();
        // At 2.10 a leg of a hundred lots is 10,000 against 11,000.
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 190, 22_000);
        OspexMatching.SignedOrder memory refusing = _rest(y, game, restingSide, 210, 10_000);
        OspexMatching.SignedOrder memory plain = _rest(m1, game, restingSide, 210, 10_000);
        trick.setHooked(y.a, true);
        uint256 snap = vm.snapshotState();

        // The control: with nothing armed, both legs fill.
        _cross(sender, taking, _list(refusing, plain));
        assertEq(_filled(taking), 22_000, "the control");
        vm.revertToState(snap);

        bytes[2] memory reads;
        reads[0] = abi.encodeCall(matching.s_filledRisk, (_hash(refusing)));
        reads[1] = abi.encodeCall(matching.s_filledRisk, (_hash(taking)));
        uint256[2] memory written = [uint256(10_000), 11_000];
        for (uint256 i; i < 2; ++i) {
            CallbackAccount(y.a).armRefusal(address(matching), reads[i], abi.encode(written[i]));
            vm.recordLogs();
            _cross(sender, taking, _list(refusing, plain));
            Skip[] memory skips = _skips(vm.getRecordedLogs());
            assertEq(skips.length, 1, "the read from inside the pull did not answer the leg's amount");
            _assertSkip(skips[0], refusing, taking, PULL_REFUSED, "the leg whose pull its account refused");
            assertEq(_filled(refusing), 0, "the skipped leg's resting amount was not put back");
            assertEq(_filled(plain), 10_000, "the leg beside it");
            assertEq(_filled(taking), 11_000, "the skipped leg's taking amount was not put back");
            vm.revertToState(snap);
        }
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The receipt: a fill reverts unless the positions module's balance rose by at least the two stakes. Coin
    // the contract did not ask for cannot fail it; a short receipt always does.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexPositions._record, make the receipt's test exact, `held != owed`. Others turn it red:
    /// the receipt's test deleted, and the receipt tested only when the resting order is on side A.
    function test_neverLine_theReceiptCheckIsAtLeastTheTwoStakes() public {
        _receiptCases(Side.B);
        _receiptCases(Side.A);
    }

    function _receiptCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        OspexMatching.SignedOrder memory first = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory second = _rest(y, game, restingSide, 200, 10_000);
        bytes memory oneUnit = abi.encodeCall(IERC20.transfer, (address(positions), 1));
        uint256 snap = vm.snapshotState();

        // A resting account sends one unit to the positions module from inside its own pull: the leg fills, the
        // Cross fills, the positions are the stakes', and the unit stays in the contract, counted by nothing.
        trick.setHooked(y.a, true);
        CallbackAccount(y.a).arm(address(trick), oneUnit);
        uint256 coin = trick.balanceOf(y.a);
        _cross(sender, taking, _list(first, second));
        (bool sent,) = _answer(y);
        assertTrue(sent, "the unit was not sent");
        assertEq(_filled(taking), 20_000, "the Cross, with a unit sent during a resting pull");
        assertEq(_filled(second), 10_000, "the leg during which the unit arrived");
        assertEq(coin - trick.balanceOf(y.a), 10_001, "the account paid its stake and gave one unit away");
        assertEq(trick.balanceOf(address(positions)), 40_001, "four stakes and the unit");
        _assertPosition(1, y.a, restingSide, 10_000, 10_000, "the position of the account that sent the unit");
        _assertPosition(1, tk.a, takingSide, 20_000, 20_000, "the taking account's position");
        vm.revertToState(snap);

        // The taking account does the same from inside the pull of its stake.
        trick.setHooked(tk.a, true);
        CallbackAccount(tk.a).arm(address(trick), oneUnit);
        _cross(sender, taking, _list(first, second));
        (sent,) = _answer(tk);
        assertTrue(sent, "the unit was not sent");
        assertEq(_filled(taking), 20_000, "the Cross, with a unit sent during the taking pull");
        assertEq(trick.balanceOf(address(positions)), 40_001, "four stakes and the unit");
        _assertPosition(1, tk.a, takingSide, 20_000, 20_000, "the taking account's position");
        vm.revertToState(snap);

        // A short receipt on the resting pull, after a leg that filled: the coin keeps one unit of each transfer
        // from the second resting account and of nobody else's. Each pull has its own receipt: the first leg's
        // 10,000 is in, the second leg's pull of 10,000 is owed on top of it, and one unit short arrives. The
        // Cross reverts by name, with what was owed and what was held, and nothing of it remains.
        trick.setCut(1);
        trick.setExempt(m1.a, true);
        trick.setExempt(tk.a, true);
        _refused(
            sender,
            taking,
            _list(first, second),
            abi.encodeWithSelector(OspexPositions.OspexPositions__ShortReceipt.selector, 20_000, 19_999),
            "a short receipt on the resting pull"
        );
        assertEq(trick.balanceOf(address(positions)), 0, "a reverted Cross left coin");
        assertEq(_filled(first), 0, "a reverted Cross left a filled amount");
        vm.revertToState(snap);

        // A short receipt on the taking pull: the coin keeps one unit of each transfer from the taking account,
        // whose one pull of 20,000 comes after the walk, with both resting stakes already in.
        trick.setCut(1);
        trick.setExempt(m1.a, true);
        trick.setExempt(y.a, true);
        _refused(
            sender,
            taking,
            _list(first, second),
            abi.encodeWithSelector(OspexPositions.OspexPositions__ShortReceipt.selector, 40_000, 39_999),
            "a short receipt on the taking pull"
        );
        assertEq(trick.balanceOf(address(positions)), 0, "a reverted Cross left coin");
        vm.revertToState(snap);

        // With no cut and no unit sent, the same Cross fills and the contract holds exactly the four stakes.
        _cross(sender, taking, _list(first, second));
        assertEq(trick.balanceOf(address(positions)), 40_000, "exactly the four stakes");
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The stated limit. With a coin that calls the debited account during a transfer, that account can make the
    // Cross fail: by ending the game from inside its pull, or by spending the gas passed to it. Neither moves
    // coin or leaves a record. USDC makes no such call. These tests record the limit; nothing is built against
    // it, and they have no break.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_limit_aReleaseFromInsideAnEarlierPullFailsTheCross() public {
        // A game whose start is not written, at its day-30 clock: its release is open to anyone, and until it
        // is released a fill lands.
        uint256 game = _create();
        vm.warp(_day30(game));
        OspexMatching.SignedOrder memory taking = _take(tk, game, Side.B, 200, 20_000);
        OspexMatching.SignedOrder memory first = _rest(y, game, Side.A, 200, 10_000);
        OspexMatching.SignedOrder memory second = _rest(m1, game, Side.A, 200, 10_000);
        trick.setHooked(y.a, true);
        uint256 snap = vm.snapshotState();

        // From inside the first leg's pull the resting account releases the game. The second leg meets the close
        // gate, the whole Cross reverts under the gate's name, and the release reverts with it.
        CallbackAccount(y.a).arm(address(games), abi.encodeCall(IOspexGames.release, (game)));
        _refused(
            sender,
            taking,
            _list(first, second),
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, game, GameStatus.Released),
            "a release from inside the first leg's pull"
        );
        assertEq(uint8(_status(game)), uint8(GameStatus.Unverified), "the release stood");
        assertEq(trick.balanceOf(address(positions)), 0, "the failed Cross moved coin");
        assertEq(_filled(taking), 0, "the failed Cross left a filled amount");
        assertEq(markets.marketCount(), 0, "the failed Cross drew a market");
        vm.revertToState(snap);

        // Made from inside the last leg's pull, the release stands and the fill lands. The market then settles
        // as a void, and each account claims its stake back.
        CallbackAccount(y.a).arm(address(games), abi.encodeCall(IOspexGames.release, (game)));
        _cross(sender, taking, _list(first));
        assertEq(uint8(_status(game)), uint8(GameStatus.Released), "the release made from inside the last pull");
        _settle(1);
        assertEq(uint8(_outcome(1)), uint8(Outcome.Void));
        assertEq(_claim(y.a, 1, Side.A), 10_000, "the resting stake back");
        assertEq(_claim(tk.a, 1, Side.B), 10_000, "the taking stake back");
        assertEq(trick.balanceOf(address(positions)), 0, "coin left after the void's claims");
        vm.revertToState(snap);

        // From inside the last leg's pull it releases the game and settles the market the leg has just drawn.
        // The fill still lands, into a market that is now a void; a claim made in the same call-back is refused
        // by the positions module's guard; and afterwards each account claims its stake back.
        CallbackAccount(y.a).arm(address(games), abi.encodeCall(IOspexGames.release, (game)));
        CallbackAccount(y.a).armAlso(address(markets), abi.encodeCall(OspexMarkets.settleMarket, (1)));
        CallbackAccount(y.a).armAlso(address(positions), abi.encodeCall(OspexPositions.claimPosition, (1, Side.A)));
        _cross(sender, taking, _list(first));
        (bool[] memory oks, bytes[] memory answers) = CallbackAccount(y.a).results();
        assertTrue(oks[0], "the release from inside the pull");
        assertTrue(oks[1], "the settlement from inside the pull");
        assertFalse(oks[2], "a claim from inside the pull was paid");
        assertEq(
            answers[2],
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "the claim from inside the pull, refused by another name than the guard's"
        );
        assertEq(uint8(_outcome(1)), uint8(Outcome.Void), "the market settled from inside the pull");
        assertEq(trick.balanceOf(address(positions)), 20_000, "the two stakes of the fill");
        assertEq(_claim(y.a, 1, Side.A), 10_000, "the resting stake back");
        assertEq(_claim(tk.a, 1, Side.B), 10_000, "the taking stake back");
        assertEq(trick.balanceOf(address(positions)), 0, "coin left after the void's claims");
    }

    function test_limit_gasSpentInsideAPullFailsTheCross() public {
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(tk, game, Side.B, 200, 20_000);
        OspexMatching.SignedOrder memory first = _rest(y, game, Side.A, 200, 10_000);
        OspexMatching.SignedOrder memory second = _rest(m1, game, Side.A, 200, 10_000);
        bytes memory call = abi.encodeCall(OspexMatching.cross, (taking, _list(first, second)));
        uint256 snap = vm.snapshotState();

        // The control: with a million gas and nothing spent in the call-back, the Cross fills both legs.
        vm.prank(sender, crossOrigin);
        (bool ok,) = address(matching).call{gas: 1_000_000}(call);
        assertTrue(ok, "the control ran out of gas");
        assertEq(_filled(taking), 20_000, "the control");
        vm.revertToState(snap);

        // Called back in the first leg's pull, the resting account spends every unit of gas passed to it. With
        // the same million gas, what is kept back does not finish the walk: the Cross fails, and nothing of it
        // remains.
        trick.setHooked(y.a, true);
        CallbackAccount(y.a).setBurn(type(uint256).max);
        vm.prank(sender, crossOrigin);
        (ok,) = address(matching).call{gas: 1_000_000}(call);
        assertFalse(ok, "the Cross survived the gas spent in its first pull");
        assertEq(trick.balanceOf(address(positions)), 0, "the failed Cross moved coin");
        assertEq(_filled(taking), 0, "the failed Cross left a filled amount");

        // With gas to spare the same pull fails for want of gas and reads as refused: that order is skipped, the
        // other leg fills, and the account that spent the gas has paid nothing.
        uint256 coin = trick.balanceOf(y.a);
        vm.recordLogs();
        vm.prank(sender, crossOrigin);
        (ok,) = address(matching).call{gas: 60_000_000}(call);
        assertTrue(ok, "the Cross with gas to spare");
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record");
        _assertSkip(skips[0], first, taking, PULL_REFUSED, "the order whose pull ran out of gas");
        assertEq(_filled(second), 10_000, "the other leg");
        assertEq(trick.balanceOf(y.a), coin, "the account that spent the gas paid coin");
    }
}

/// @notice The one failure of a fill that skips: the positions module's MakerPullRefused, for this leg's resting
///         account and this leg's resting stake. The set here is deployed on a coin a test scripts, so that a
///         pull is refused each way a coin can refuse one, and so that the positions call can be made to revert
///         with bytes of the test's choosing.
contract OspexCrossRefusalBytesTest is CrossBase {
    ScriptedCoin internal scripted;
    Signer internal tk;
    Signer internal m1;
    Signer internal m2;
    uint256 internal game;

    function setUp() public override {
        super.setUp();
        scripted = new ScriptedCoin();
        _deploySetOn(address(scripted));
        tk = _account("taking account");
        m1 = _account("resting one");
        m2 = _account("resting two");
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m2.a, sender);
        game = _verifiedGame();
    }

    /// @dev The side the taking order of this contract's one leg is on.
    Side internal legTakingSide = Side.B;

    function _oneLeg()
        internal
        returns (OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
    {
        taking = _take(tk, game, legTakingSide, 200, 10_000);
        resting = _list(_rest(m1, game, _other(legTakingSide), 200, 10_000));
    }

    /// @dev The maker's refusal in its three words, the amount asked being the stake: for an account with
    ///      nothing on the market, the netted pull is the stake.
    function _makerRefused(address account, uint256 amount) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(IOspexPositions.OspexPositions__MakerPullRefused.selector, account, amount, amount);
    }

    /// Break: in OspexMatching._isMakerPullRefused, delete the length's test. Others turn it red: the selector
    /// not compared; the account not compared, or compared as an address; the amount not compared; the coin's
    /// own revert data passed up from the maker's pull; the taker's refusal raised under the maker's error; and
    /// the taker's stake pulled first.
    function test_neverLine_aRefusedPullIsRecognisedBySelectorLengthAndBothArguments() public {
        uint256 snap = vm.snapshotState();
        _refusalCases();
        vm.revertToState(snap);
        legTakingSide = Side.A;
        _refusalCases();
    }

    function _refusalCases() internal {
        (OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting) = _oneLeg();
        bytes memory skipped = _nothingFilled(_reasons(PULL_REFUSED));
        bytes memory takerRefused =
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, tk.a, 10_000);

        // A refused resting pull is a skip however the coin refuses: by reverting, by reverting with bytes of
        // its own, even bytes that spell another refusal, and by answering false.
        scripted.setRefusal(m1.a, ScriptedCoin.Refusal.Reverts, "");
        _refused(sender, taking, resting, skipped, "the coin reverts on the resting pull");
        scripted.setRefusal(m1.a, ScriptedCoin.Refusal.RevertsWith, takerRefused);
        _refused(sender, taking, resting, skipped, "the coin reverts with bytes of its own on the resting pull");
        scripted.setRefusal(m1.a, ScriptedCoin.Refusal.AnswersFalse, "");
        _refused(sender, taking, resting, skipped, "the coin answers false on the resting pull");
        // The resting stake is pulled first: with both accounts refused, the leg is a skip, and the taking
        // account's refusal is never reached.
        scripted.setRefusal(m1.a, ScriptedCoin.Refusal.Reverts, "");
        scripted.setRefusal(tk.a, ScriptedCoin.Refusal.Reverts, "");
        _refused(sender, taking, resting, skipped, "the coin refuses both pulls");
        scripted.setRefusal(tk.a, ScriptedCoin.Refusal.None, "");
        scripted.setRefusal(m1.a, ScriptedCoin.Refusal.None, "");

        // A refused taking pull reverts the Cross under the positions module's own name, whatever the coin's
        // bytes say: the coin's revert data never reaches the matching module.
        scripted.setRefusal(tk.a, ScriptedCoin.Refusal.Reverts, "");
        _refused(sender, taking, resting, takerRefused, "the coin reverts on the taking pull");
        scripted.setRefusal(tk.a, ScriptedCoin.Refusal.RevertsWith, _makerRefused(m1.a, 10_000));
        _refused(
            sender,
            taking,
            resting,
            takerRefused,
            "the coin reverts on the taking pull, spelling a refused resting pull"
        );
        scripted.setRefusal(tk.a, ScriptedCoin.Refusal.AnswersFalse, "");
        _refused(sender, taking, resting, takerRefused, "the coin answers false on the taking pull");
        scripted.setRefusal(tk.a, ScriptedCoin.Refusal.None, "");

        // Any other revert of the positions call is passed up unchanged, byte for byte. The coin's balance
        // read, which the positions module makes before the pulls, is made to revert with each of these.
        bytes memory exact = _makerRefused(m1.a, 10_000);
        bytes[] memory passed = new bytes[](11);
        passed[0] = _makerRefused(m1.a, 9_999);
        passed[1] = _makerRefused(m1.a, 10_001);
        passed[2] = _makerRefused(m2.a, 10_000);
        // The right account under bits that are not an address's.
        passed[3] = abi.encodePacked(
            IOspexPositions.OspexPositions__MakerPullRefused.selector,
            bytes32(uint256(uint160(m1.a)) | (uint256(1) << 255)),
            uint256(10_000),
            uint256(10_000)
        );
        // The selector alone; the exact bytes less their last byte; the exact bytes and a word more.
        passed[4] = abi.encodePacked(IOspexPositions.OspexPositions__MakerPullRefused.selector);
        passed[5] = _first(exact, 99);
        passed[6] = bytes.concat(exact, bytes32(0));
        // The other pull's error with the same two values; the maker's error in two words, the account and the
        // stake with no third; a string; nothing at all.
        passed[7] = abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, m1.a, 10_000);
        passed[8] = abi.encodeWithSelector(IOspexPositions.OspexPositions__MakerPullRefused.selector, m1.a, 10_000);
        passed[9] = abi.encodeWithSignature("Error(string)", "no");
        passed[10] = "";
        for (uint256 i; i < passed.length; ++i) {
            scripted.setBalanceRevert(address(positions), passed[i]);
            (bool ok, bytes memory err) = _tryCross(sender, taking, resting);
            assertFalse(ok, "a Cross filled through a positions call that reverted");
            assertEq(err, passed[i], string.concat("revert data ", vm.toString(i), " was not passed up unchanged"));
        }

        // The exact bytes, from whatever the positions module calls, read as a refused resting pull: the bound
        // of recognising a refusal by its bytes. The leg is skipped, and nothing of it remains.
        scripted.setBalanceRevert(address(positions), exact);
        _refused(sender, taking, resting, skipped, "the exact bytes of a refused resting pull");
        scripted.setBalanceRevert(address(0), "");
        assertEq(_filled(resting[0]), 0, "a refused Cross left a filled amount");
        // The third word, the amount the positions module asked, is not compared: the same bytes with zero or
        // half the stake there read as the refusal too.
        bytes4 makerSelector = IOspexPositions.OspexPositions__MakerPullRefused.selector;
        scripted.setBalanceRevert(address(positions), abi.encodeWithSelector(makerSelector, m1.a, 10_000, 0));
        _refused(sender, taking, resting, skipped, "the refusal with a zero third word");
        scripted.setBalanceRevert(address(positions), abi.encodeWithSelector(makerSelector, m1.a, 10_000, 5_000));
        _refused(sender, taking, resting, skipped, "the refusal with another amount asked");
        scripted.setBalanceRevert(address(0), "");

        // With nothing scripted the same Cross fills.
        _cross(sender, taking, resting);
        assertEq(_filled(taking), 10_000, "the Cross on an unscripted coin");
    }

    /// Whether a pull is refused is the coin's answer to the transfer, and nothing the positions module reads
    /// before it. Here the coin moves a stake for the positions module with no allowance given, and reports
    /// each account's balance to the positions module as nothing: a fill pulls both stakes all the same.
    /// Break: in OspexPositions._record, read the maker's allowance before the pull and refuse on a short read.
    /// Another turns it red: the maker's balance read before the pull, and a short read refused.
    function test_neverLine_aPullIsTheCoinsTransferAndNoReadBeforeIt() public {
        uint256 snap = vm.snapshotState();
        _noReadCases();
        vm.revertToState(snap);
        legTakingSide = Side.A;
        _noReadCases();
    }

    function _noReadCases() internal {
        (OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting) = _oneLeg();
        scripted.setTrusted(address(positions), true);
        scripted.setHidden(m1.a, address(positions));
        scripted.setHidden(tk.a, address(positions));
        vm.prank(m1.a);
        scripted.approve(address(positions), 0);
        vm.prank(tk.a);
        scripted.approve(address(positions), 0);
        uint256 coin = scripted.balanceOf(m1.a);

        _cross(sender, taking, resting);
        assertEq(_filled(taking), 10_000, "the fill, on a coin that asks these accounts for no allowance");
        assertEq(coin - scripted.balanceOf(m1.a), 10_000, "the resting stake, pulled");
        assertEq(scripted.balanceOf(address(positions)), 20_000, "the two stakes, held");
    }

    function _first(bytes memory b, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = b[i];
        }
    }
}
