// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GameStatus} from "../../src/games/IOspexGames.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross's never-lines, first part: the courier, the close, the signed stake, the cancel, the price,
///         the minimum, and that nothing stays in the contract or goes to the sender. One test per line. Above
///         each test, "Break:" names changes to src/betting that turn it red; each is an entry of battery.json.
///         Each test runs twice, with the taking order on side B and on side A.
contract OspexCrossNeverLinesTest is CrossBase {
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

    /// @dev The four accounts register `to`.
    function _registerAll(address to) internal {
        _register(tk.a, to);
        _register(m1.a, to);
        _register(m2.a, to);
        _register(m3.a, to);
    }

    /// @dev A taking order for 30,000 at 2.00 and three resting orders of 10,000 at 2.00 on the other side, one
    ///      from each resting account: three legs of 10,000 against 10,000.
    function _threeLegs(uint256 game, Side takingSide)
        internal
        returns (OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
    {
        taking = _take(tk, game, takingSide, 200, 30_000);
        resting = _list(
            _rest(m1, game, _other(takingSide), 200, 10_000),
            _rest(m2, game, _other(takingSide), 200, 10_000),
            _rest(m3, game, _other(takingSide), 200, 10_000)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 1. An order never fills through a courier its account has not registered. A resting order is skipped;
    //    the taking order fails the Cross.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cross, delete the taking account's check, `if (!s_couriers[t.account][msg.sender])
    /// revert OspexMatching__SenderNotCourier(t.account, msg.sender);`. Others turn it red: the resting row
    /// deleted from _leg; that row made a revert of the whole call; that row reading the taking account's
    /// entry; either check reading tx.origin; and either check counting an account as its own courier.
    function test_neverLine_anOrderNeverFillsThroughACourierItsAccountHasNotRegistered() public {
        _courierCases(Side.B);
        _courierCases(Side.A);
    }

    function _courierCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        (OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting) =
            _threeLegs(game, takingSide);
        _theTakingAccountsCourier(taking, resting);
        _aRestingAccountsCourier(taking, resting, takingSide);
        _otherSenders(taking, resting, takingSide);
    }

    function _makers() internal view returns (Signer[3] memory makers) {
        makers[0] = m1;
        makers[1] = m2;
        makers[2] = m3;
    }

    /// @dev The control, and the taking account's cases: the Cross reverts when it has not registered the sender.
    function _theTakingAccountsCourier(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting
    ) internal {
        Signer[3] memory makers = _makers();
        uint256 snap = vm.snapshotState();

        // The control: every account registered the sender, and the three legs fill.
        _registerAll(sender);
        _cross(sender, taking, resting);
        assertEq(_filled(taking), 30_000, "the control: the taking order's filled amount");
        for (uint256 i; i < 3; ++i) {
            assertEq(_filled(resting[i]), 10_000, "the control: a resting order's filled amount");
        }
        vm.revertToState(snap);

        // The taking account has not registered the sender: the Cross reverts, naming it and the sender.
        bytes memory notTheirs =
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, tk.a, sender);
        for (uint256 i; i < 3; ++i) {
            _register(makers[i].a, sender);
        }
        _refused(sender, taking, resting, notTheirs, "registered by the resting accounts only");
        vm.revertToState(snap);
        _refused(sender, taking, resting, notTheirs, "registered by nobody");
        // The set's deployer is nobody's courier either: no address has a courier's standing by what it is.
        bytes memory notTheDeployer =
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, tk.a, deployer);
        _refused(deployer, taking, resting, notTheDeployer, "sent by the set's deployer");
        _register(stranger, sender);
        _refused(sender, taking, resting, notTheirs, "registered by a third account only");
        vm.revertToState(snap);
        // The taking account sends its own Cross and has not registered itself: there is no implied courier.
        for (uint256 i; i < 3; ++i) {
            _register(makers[i].a, tk.a);
        }
        bytes memory notItsOwn =
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, tk.a, tk.a);
        _refused(tk.a, taking, resting, notItsOwn, "the taking account as its own sender, unregistered");
        _register(tk.a, tk.a);
        _cross(tk.a, taking, resting);
        assertEq(_filled(taking), 30_000, "the taking account as its own sender, registered by itself");
        vm.revertToState(snap);
    }

    /// @dev A resting account's cases: its order is skipped when it has not registered the sender, and the rest
    ///      fill.
    function _aRestingAccountsCourier(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        Side takingSide
    ) internal {
        Signer[3] memory makers = _makers();
        uint256 snap = vm.snapshotState();

        // A resting account has not registered the sender: its order is skipped and the others fill, with it
        // listed first, in the middle and last.
        for (uint256 k; k < 3; ++k) {
            _register(tk.a, sender);
            for (uint256 i; i < 3; ++i) {
                if (i != k) _register(makers[i].a, sender);
            }
            uint256 coin = _coin().balanceOf(makers[k].a);
            vm.recordLogs();
            _cross(sender, taking, resting);
            Skip[] memory skips = _skips(vm.getRecordedLogs());
            assertEq(skips.length, 1, "one skip record for the unregistered account's order");
            _assertSkip(skips[0], resting[k], taking, NO_COURIER, "the unregistered account's order");
            assertEq(_filled(resting[k]), 0, "the unregistered account's order filled");
            assertEq(_coin().balanceOf(makers[k].a), coin, "the unregistered account's coin moved");
            _assertPosition(markets.marketCount(), makers[k].a, _other(takingSide), 0, 0, "its position");
            assertEq(_filled(taking), 20_000, "the two other legs filled");
            for (uint256 i; i < 3; ++i) {
                if (i != k) assertEq(_filled(resting[i]), 10_000, "a registered account's leg");
            }
            vm.revertToState(snap);
        }

        // No resting account registered the sender: nothing fills, and the refusal carries the reason for each.
        _register(tk.a, sender);
        bytes memory nothing = _nothingFilled(new uint8[](3));
        _refused(sender, taking, resting, nothing, "no resting account registered the sender");
        vm.revertToState(snap);

        // A drop made just before the Cross. Everyone registered the sender and the Cross would fill three
        // legs; the second resting account drops the sender in its own transaction, and the same Cross is sent.
        _registerAll(sender);
        vm.prank(m2.a);
        matching.unregisterCourier(sender);
        vm.recordLogs();
        _cross(sender, taking, resting);
        Skip[] memory dropped = _skips(vm.getRecordedLogs());
        assertEq(dropped.length, 1, "one skip record after the drop");
        _assertSkip(dropped[0], resting[1], taking, NO_COURIER, "the order of the account that dropped the sender");
        assertEq(_filled(resting[0]), 10_000, "the first leg, beside the drop");
        assertEq(_filled(resting[1]), 0, "the dropped account's order");
        assertEq(_filled(resting[2]), 10_000, "the third leg, beside the drop");
        assertEq(_filled(taking), 20_000, "the taking order filled by the two legs");
        // It registers the sender again, and its order fills against what the taking order has left.
        _register(m2.a, sender);
        _cross(sender, taking, _list(resting[1]));
        assertEq(_filled(resting[1]), 10_000, "the order, once its account registered the sender again");
        assertEq(_filled(taking), 30_000, "the taking order, filled in full");
        vm.revertToState(snap);

        // A resting account sends the Cross. It is every other account's courier and not its own: its own order
        // is skipped. Once it has registered itself, its order fills too.
        _register(tk.a, m1.a);
        _register(m2.a, m1.a);
        _register(m3.a, m1.a);
        uint256 own = vm.snapshotState();
        vm.recordLogs();
        _cross(m1.a, taking, resting);
        Skip[] memory itsOwn = _skips(vm.getRecordedLogs());
        assertEq(itsOwn.length, 1, "one skip record for the sender's own order");
        _assertSkip(itsOwn[0], resting[0], taking, NO_COURIER, "the sender's own order");
        assertEq(_filled(taking), 20_000, "the two other legs, sent by a resting account");
        vm.revertToState(own);
        _register(m1.a, m1.a);
        _cross(m1.a, taking, resting);
        assertEq(_filled(taking), 30_000, "sent by a resting account that registered itself");
        vm.revertToState(snap);
    }

    /// @dev A second courier; the registered address as the transaction's origin; and an unregistered account's
    ///      order that has a fault of its own.
    function _otherSenders(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        Side takingSide
    ) internal {
        uint256 snap = vm.snapshotState();

        // A second courier that every account registered fills too.
        address second = makeAddr("a second courier");
        _registerAll(sender);
        _registerAll(second);
        _cross(second, taking, resting);
        assertEq(_filled(taking), 30_000, "sent by a second courier");
        vm.revertToState(snap);

        // The registered address as the transaction's origin, behind another immediate caller: refused, since
        // the caller is not the taking account's courier.
        _registerAll(sender);
        (bool ok, bytes memory err) = _tryCrossAs(stranger, sender, taking, resting);
        assertFalse(ok, "filled through the transaction's origin");
        assertEq(err, abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, tk.a, stranger));
        vm.revertToState(snap);

        // An unregistered account's order that is also badly signed, or off the market, reverts the Cross: the
        // checks fixed in the signed order come before the walk.
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m3.a, sender);
        OspexMatching.SignedOrder memory forged =
            OspexMatching.SignedOrder({order: resting[1].order, signature: _signature(m3.key, _hash(resting[1]))});
        bytes memory badlySigned = _refusal(OspexMatching.OspexMatching__BadSignature.selector, resting[1]);
        _refused(
            sender,
            taking,
            _list(resting[0], forged, resting[2]),
            badlySigned,
            "an unregistered account's order, badly signed"
        );
        OspexMatching.SignedOrder memory elsewhere = _rest(m2, _verifiedGame(), _other(takingSide), 200, 10_000);
        bytes memory otherGame = _refusal(OspexMatching.OspexMatching__OtherGame.selector, elsewhere);
        _refused(
            sender,
            taking,
            _list(resting[0], elsewhere, resting[2]),
            otherGame,
            "an unregistered account's order, on another game"
        );
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 3. No fill once bets close: when the game scores, or at start + n, whichever comes first.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The side the taking order of this section's legs is on.
    Side internal closeTakingSide = Side.B;

    /// @dev One leg at the time the call is made: 10,000 against 10,000 at 2.00 on the game's moneyline.
    function _oneLeg(uint256 game) internal returns (bool ok, bytes memory err) {
        OspexMatching.SignedOrder memory taking = _take(tk, game, closeTakingSide, 200, 10_000);
        (ok, err) = _tryCross(sender, taking, _list(_rest(m1, game, _other(closeTakingSide), 200, 10_000)));
    }

    function _fills(uint256 game, string memory what) internal {
        (bool ok, bytes memory err) = _oneLeg(game);
        assertTrue(ok, string.concat("refused: ", what, ": ", vm.toString(err)));
    }

    /// @dev Refused through the Cross, and refused the same way when the fill is sent to the positions module
    ///      as the matching module sends one: the gate is on every fill.
    function _closed(uint256 game, bytes memory want, string memory what) internal {
        (bool ok, bytes memory err) = _oneLeg(game);
        assertFalse(ok, string.concat("filled: ", what));
        assertEq(err, want, what);
        (ok, err) = _tryRawFill(game, address(moneyline), 0, _other(closeTakingSide), 10_000, 10_000);
        assertFalse(ok, string.concat("filled, sent to the positions module: ", what));
        assertEq(err, want, string.concat(what, ", sent to the positions module"));
    }

    /// Break: in OspexMarkets.requireBetsOpen, turn the clock test's `>=` into `>`. Others turn it red: the
    /// status test deleted; the clock test deleted; the settled test deleted; a constant day in place of the
    /// game's own n; the clock read for a verified game only; and the gate called only when the market is
    /// drawn.
    function test_neverLine_noFillOnceBetsClose() public {
        _registerAll(sender);
        uint256 snap = vm.snapshotState();
        _closeCases();
        vm.revertToState(snap);
        closeTakingSide = Side.A;
        _closeCases();
    }

    function _closeCases() internal {
        // A league whose n is twelve hours, for one game; every other game has the launch n, a day.
        _setTerms("nba", _terms(12 hours));
        uint256 short = _verifiedGame();
        _setTerms("nba", _launchTerms());
        uint256 open = _verifiedGame();
        uint256 fresh = _verifiedGame();
        uint256 scored = _verifiedGame();
        uint256 scoredNoMarket = _verifiedGame();
        uint256 voided = _verifiedGame();
        uint256 released = _create();
        uint256 unverified = _create();
        uint256 disputed = _verifiedGame();

        // Before the start, on every game: fills. Each game but two now has a market.
        _fills(short, "before the start, the twelve-hour game");
        _fills(open, "before the start");
        _fills(scored, "before the start, the game to be scored");
        _fills(voided, "before the start, the game to be voided");
        _fills(released, "before any start is written, the game to be released");
        _fills(unverified, "before any start is written");
        _fills(disputed, "before the start, the game to be disputed");
        assertEq(markets.marketCount(), 7, "a market drawn on each");

        // No kickoff check: at the start, and after it inside n, a fill lands.
        vm.warp(START);
        _fills(open, "at the start");
        vm.warp(START + 1);
        _fills(open, "one second after the start");

        // A dispute record is not an end: the disputed game fills inside n.
        _disputeBy(first, disputed);
        assertEq(uint8(_status(disputed)), uint8(GameStatus.Disputed));
        _fills(disputed, "disputed, inside n");

        // Scored inside n: refused from that second, with its market and without one.
        _scoreBy(first, scored, HOME, AWAY);
        _scoreBy(first, scoredNoMarket, HOME, AWAY);
        bytes memory ended =
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, scored, GameStatus.Scored);
        _closed(scored, ended, "scored inside n");
        _closed(
            scoredNoMarket,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, scoredNoMarket, GameStatus.Scored),
            "scored inside n, with no market drawn"
        );
        // Its market settled: refused under the market's own name.
        uint256 settledMarket = markets.getMarketId(scored, address(moneyline), 0);
        _settle(settledMarket);
        _closed(
            scored,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__MarketSettled.selector, settledMarket),
            "a settled market"
        );

        // The twelve-hour game closes at its own start + n, twelve hours, and no later.
        vm.warp(START + 12 hours - 1);
        _fills(short, "one second before start + n, n twelve hours");
        vm.warp(START + 12 hours);
        _closed(
            short,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__BetsClosed.selector, short, START + 12 hours),
            "at start + n, n twelve hours"
        );
        _fills(open, "twelve hours in, on a game whose n is a day");

        // The last second fills. Start + n is refused, and so is the second after, with a market and without.
        vm.warp(START + WINDOW - 1);
        _fills(open, "one second before start + n");
        _fills(disputed, "disputed, one second before start + n");
        vm.warp(START + WINDOW);
        bytes memory closed =
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__BetsClosed.selector, open, START + WINDOW);
        _closed(open, closed, "at start + n");
        _closed(
            fresh,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__BetsClosed.selector, fresh, START + WINDOW),
            "at start + n, with no market drawn"
        );
        _closed(
            disputed,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__BetsClosed.selector, disputed, START + WINDOW),
            "disputed, at start + n"
        );
        vm.warp(START + WINDOW + 1);
        _closed(open, closed, "one second after start + n");

        // Voided: refused.
        vm.warp(START + WINDOW);
        _voidBy(first, voided);
        _closed(
            voided,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, voided, GameStatus.Voided),
            "voided"
        );

        // A game whose start is not written has no start + n: it still fills, days later, until it is released.
        vm.warp(_day30(released) - 1);
        _fills(unverified, "unverified, a second before its day-30 clock");
        _fills(released, "unverified, a second before its release");
        vm.warp(_day30(released));
        _releaseBy(stranger, released);
        _closed(
            released,
            abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, released, GameStatus.Released),
            "released with no start"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 4. An order never fills past its signed stake: one filled amount per order, by its hash, in either role
    //    and across Crosses.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, delete the resting order's filled write, `s_filledRisk[restingHash] =
    /// restingFilled + makerRisk;`. Others turn it red: the taking order's write deleted; the resting write
    /// keyed by the taking order's hash; the resting write recording the taking stake; and the filled amount
    /// left out of the room.
    function test_neverLine_anOrderNeverFillsPastItsSignedStake() public {
        _registerAll(sender);
        _signedStakeCases(Side.B);
        _signedStakeCases(Side.A);
    }

    function _signedStakeCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);

        // In parts across Crosses: a resting order of 10,000 at 2.10, taken three times.
        OspexMatching.SignedOrder memory r = _rest(m1, game, restingSide, 210, 10_000);
        OspexMatching.SignedOrder memory t1 = _take(tk, game, takingSide, 190, 3_300);
        _cross(sender, t1, _list(r));
        assertEq(_filled(r), 3_000, "after the first Cross: 30 lots");
        assertEq(_filled(t1), 3_300, "the first taking order: 30 lots at 110 each");
        OspexMatching.SignedOrder memory t2 = _take(tk, game, takingSide, 190, 4_400);
        _cross(sender, t2, _list(r));
        assertEq(_filled(r), 7_000, "after the second Cross: 40 lots more");
        assertEq(_filled(t2), 4_400, "the second taking order");
        // Offered more than its room, it fills its room exactly.
        OspexMatching.SignedOrder memory t3 = _take(tk, game, takingSide, 190, 5_500);
        _cross(sender, t3, _list(r));
        assertEq(_filled(r), 10_000, "after the third Cross: its signed stake, and no more");
        assertEq(_filled(t3), 3_300, "the third taking order took what the room allowed: 30 lots");
        // The next Cross skips it. Signed again, the same ten values are the same order and the same record.
        OspexMatching.SignedOrder memory again = _signed(r.order, m1.key);
        assertEq(_hash(again), _hash(r), "the same ten values are another order");
        OspexMatching.SignedOrder memory t4 = _take(tk, game, takingSide, 190, 1_100);
        _refused(sender, t4, _list(again), _nothingFilled(_reasons(NO_ROOM)), "a full order, offered again");
        assertEq(_filled(r), 10_000, "a full order's filled amount moved");
        // The taking order of the third Cross has 2,200 left: it takes that from another order, and then it is
        // full too, and a Cross that sends it again is refused by name.
        OspexMatching.SignedOrder memory r2 = _rest(m2, game, restingSide, 210, 5_000);
        _cross(sender, t3, _list(r2));
        assertEq(_filled(t3), 5_500, "a taking order filled in two Crosses, to its signed stake");
        assertEq(_filled(r2), 2_000, "the order it took the rest from: 20 lots");
        _refused(
            sender,
            t3,
            _list(r2),
            _refusal(OspexMatching.OspexMatching__TakingOrderFilled.selector, t3),
            "a full taking order"
        );

        // Taking in one Cross and resting in the next, on one record: an order of 10,000 at 2.00 takes 4,000,
        // then rests against another taking order, which finds 6,000 of room.
        OspexMatching.SignedOrder memory both = _take(m3, game, takingSide, 200, 10_000);
        _cross(sender, both, _list(_rest(m1, game, restingSide, 200, 4_000)));
        assertEq(_filled(both), 4_000, "as a taking order");
        OspexMatching.SignedOrder memory against = _take(tk, game, restingSide, 200, 10_000);
        _cross(sender, against, _list(both));
        assertEq(_filled(both), 10_000, "as a resting order, on the same record");
        assertEq(_filled(against), 6_000, "what the order had left as room");
        _refused(
            sender,
            _take(tk, game, restingSide, 200, 1_000),
            _list(both),
            _nothingFilled(_reasons(NO_ROOM)),
            "an order filled in both roles, offered again"
        );

        // Listed twice in one Cross: once the first entry has filled, the second is skipped. When the order's room is what ran out
        // at the first entry, the second is "no room".
        OspexMatching.SignedOrder memory small = _rest(m1, game, restingSide, 200, 5_000);
        OspexMatching.SignedOrder memory wide = _take(tk, game, takingSide, 200, 10_000);
        vm.recordLogs();
        _cross(sender, wide, _list(small, small));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record for the second entry");
        _assertSkip(skips[0], small, wide, NO_ROOM, "the second entry, the room having run out");
        assertEq(_filled(small), 5_000, "an order listed twice filled past its stake");
        assertEq(_filled(wide), 5_000, "the taking order, against an order listed twice");
        // When the taking stake is what ran out, the second is "nothing fits".
        OspexMatching.SignedOrder memory large = _rest(m2, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory narrow = _take(tk, game, takingSide, 200, 5_500);
        vm.recordLogs();
        _cross(sender, narrow, _list(large, large));
        skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record for the second entry");
        _assertSkip(skips[0], large, narrow, NOTHING_FITS, "the second entry, the taking stake having run out");
        assertEq(_filled(large), 5_500, "the first entry took the taking stake");
        assertEq(_filled(narrow), 5_500, "the taking order, spent at the first entry");

        // After a skipped leg, a later Cross finds the room the order had. Its filled amount is put back to the
        // figure it stood at, 3,000, not to zero and not to the leg's. The order is the second resting account's,
        // which is on one side only: its pull is asked, and refused. (The third account now has a record on the
        // other side, so a resting order of its on this side would lower its worst loss and fill with no pull,
        // which is the netting's rule and not this line's subject.)
        OspexMatching.SignedOrder memory held = _rest(m2, game, restingSide, 200, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 3_000), _list(held));
        assertEq(_filled(held), 3_000, "before the refused pull");
        IERC20 coin = _coin();
        vm.prank(m2.a);
        coin.approve(address(positions), 0);
        OspexMatching.SignedOrder memory later = _take(tk, game, takingSide, 200, 9_000);
        vm.recordLogs();
        _cross(sender, later, _list(held, _rest(m1, game, restingSide, 200, 2_000)));
        skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record for the refused pull");
        _assertSkip(skips[0], held, later, PULL_REFUSED, "the order whose pull was refused");
        assertEq(_filled(held), 3_000, "the filled amount after a refused pull");
        assertEq(_filled(later), 2_000, "the taking order, filled by the other leg alone");
        vm.prank(m2.a);
        coin.approve(address(positions), type(uint256).max);
        _cross(sender, later, _list(held));
        assertEq(_filled(held), 10_000, "the room it had, taken in a later Cross: 7,000");
        assertEq(_filled(later), 9_000, "the taking order, filled in full");
    }

    /// A filled amount above a signed stake cannot arise through the Cross: no test above could make one.
    /// Written straight into the module's storage, it reads as a full order in either role, a skip for no room
    /// when the order rests and the taking order's own refusal when it takes, and never as an arithmetic error.
    /// Break: in OspexMatching._leg, make the room's test `==`. Another turns it red: the taking order's room
    /// test made `==`.
    function test_neverLine_aFilledAmountPastASignedStakeReadsAsFull() public {
        _registerAll(sender);
        _plantedCases(Side.B);
        _plantedCases(Side.A);
    }

    function _plantedCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory over = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory good = _rest(m2, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        _plantFilled(over, 10_100);
        assertEq(_filled(over), 10_100, "the planted amount");

        vm.recordLogs();
        _cross(sender, taking, _list(over, good));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record");
        _assertSkip(skips[0], over, taking, NO_ROOM, "an order filled past its stake");
        assertEq(_filled(over), 10_100, "its filled amount moved");
        assertEq(_filled(good), 10_000, "the order beside it");

        OspexMatching.SignedOrder memory spent = _take(tk, game, takingSide, 200, 10_000);
        _plantFilled(spent, 10_100);
        _refused(
            sender,
            spent,
            _list(_rest(m2, game, restingSide, 200, 10_000)),
            _refusal(OspexMatching.OspexMatching__TakingOrderFilled.selector, spent),
            "a taking order filled past its stake"
        );
    }

    /// @dev Writes an order's filled amount straight into the matching module's storage, at the one slot the
    ///      module reads when it is asked for that order's filled amount.
    function _plantFilled(OspexMatching.SignedOrder memory s, uint256 amount) internal {
        bytes32 orderHash = _hash(s);
        vm.record();
        matching.s_filledRisk(orderHash);
        (bytes32[] memory reads,) = vm.accesses(address(matching));
        assertEq(reads.length, 1, "the read of a filled amount touches one slot");
        vm.store(address(matching), reads[0], bytes32(amount));
        assertEq(matching.s_filledRisk(orderHash), amount, "the planted amount is not what the module reads");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 5. A cancelled order never fills, in either role: by its own cancel, or under its account's floor.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, delete the cancel mark's test of the resting row, `s_cancelledOrders
    /// [restingHash] ||`. Others turn it red: the same test deleted for the taking order; the floor's test
    /// deleted, for each role; the floor's `<` made `<=`, for each role; the sender's floor read in place of the
    /// account's, for each role; the floor read under another key than the market's, for each role; and the
    /// floor's key built without the game.
    function test_neverLine_aCancelledOrderNeverFillsInEitherRole() public {
        _registerAll(sender);
        _cancelCases(Side.B);
        _cancelCases(Side.A);
    }

    function _cancelCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory dead = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory live = _rest(m2, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        uint256 snap = vm.snapshotState();

        // Resting, by its own cancel: skipped as cancelled, and the rest fill.
        vm.prank(m1.a);
        matching.cancelOrder(dead.order);
        _restingIsSkippedAsCancelled(taking, dead, live, "cancelled by its account");
        // Signing it again revives nothing: the same ten values are the same hash, and the mark is on the hash.
        vm.revertToState(snap);
        vm.prank(m1.a);
        matching.cancelOrder(dead.order);
        _restingIsSkippedAsCancelled(taking, _signed(dead.order, m1.key), live, "cancelled, then signed again");
        vm.revertToState(snap);

        // Resting, under its account's floor: a nonce one under the floor is dead.
        vm.prank(m1.a);
        matching.raiseMinNonce(game, address(moneyline), 0, dead.order.nonce + 1);
        _restingIsSkippedAsCancelled(taking, dead, live, "one under its account's floor");
        vm.revertToState(snap);
        // A nonce at the floor fills.
        vm.prank(m1.a);
        matching.raiseMinNonce(game, address(moneyline), 0, dead.order.nonce);
        _cross(sender, taking, _list(dead, live));
        assertEq(_filled(dead), 10_000, "a resting order at its account's floor");
        vm.revertToState(snap);
        // Another account's floor on the market, and the same account's floor on another market, do not touch
        // it: not the sender's, not the taking account's, not another resting account's.
        vm.prank(m2.a);
        matching.raiseMinNonce(game, address(moneyline), 0, dead.order.nonce + 1);
        vm.prank(sender);
        matching.raiseMinNonce(game, address(moneyline), 0, type(uint256).max - 1);
        vm.prank(m1.a);
        matching.raiseMinNonce(game, address(spread), -35, dead.order.nonce + 1);
        vm.prank(m1.a);
        matching.raiseMinNonce(game + 1, address(moneyline), 0, dead.order.nonce + 1);
        _cross(sender, taking, _list(dead));
        assertEq(_filled(dead), 10_000, "an order under another account's floor, or another market's");
        vm.revertToState(snap);

        // Taking, by its own cancel: the Cross reverts by name.
        bytes memory cancelled = _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, taking);
        vm.prank(tk.a);
        matching.cancelOrder(taking.order);
        _refused(sender, taking, _list(dead, live), cancelled, "a cancelled taking order");
        vm.revertToState(snap);
        // Taking, under its account's floor; and at the floor, where it fills.
        vm.prank(tk.a);
        matching.raiseMinNonce(game, address(moneyline), 0, taking.order.nonce + 1);
        _refused(sender, taking, _list(dead, live), cancelled, "a taking order one under its account's floor");
        vm.revertToState(snap);
        vm.prank(tk.a);
        matching.raiseMinNonce(game, address(moneyline), 0, taking.order.nonce);
        vm.prank(sender);
        matching.raiseMinNonce(game, address(moneyline), 0, type(uint256).max - 1);
        _cross(sender, taking, _list(dead));
        assertEq(_filled(taking), 10_000, "a taking order at its account's floor");
        vm.revertToState(snap);

        // Cancelled after a partial fill: the fill and the filled amount stand, and the remainder is dead.
        _cross(sender, _take(tk, game, takingSide, 200, 4_000), _list(dead));
        assertEq(_filled(dead), 4_000, "before the cancel");
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        vm.prank(m1.a);
        matching.cancelOrder(dead.order);
        _restingIsSkippedAsCancelled(taking, dead, live, "cancelled after a partial fill");
        assertEq(_filled(dead), 4_000, "the filled amount after the cancel");
        _assertPosition(market, m1.a, restingSide, 4_000, 4_000, "the fill made before the cancel");
        vm.revertToState(snap);
    }

    /// @dev The Cross of `dead` and `live` fills the live order and skips the dead one as cancelled.
    function _restingIsSkippedAsCancelled(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder memory dead,
        OspexMatching.SignedOrder memory live,
        string memory what
    ) internal {
        uint256 before = _filled(dead);
        vm.recordLogs();
        _cross(sender, taking, _list(dead, live));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, string.concat(what, ": one skip record"));
        _assertSkip(skips[0], dead, taking, CANCELLED, what);
        assertEq(_filled(dead), before, string.concat(what, ": it filled"));
        assertEq(_filled(live), 10_000, string.concat(what, ": the order beside it"));
        assertEq(_filled(taking), 10_000, string.concat(what, ": the taking order"));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 6. The fill is at the resting price, inside both floors.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, bring v2's clip back: the lots counted from the taking stake rounded up,
    /// `(left * LOT + p - 1) / p / LOT`, and the taking stake clipped to what is left. Others turn it red: the
    /// meeting test loosened to 10,100; the price taken from the taking order; and a lot of 10 units.
    function test_neverLine_theFillIsAtTheRestingPriceInsideBothFloors() public {
        _registerAll(sender);
        _priceCases(Side.B);
        _priceCases(Side.A);
        _everyRestingTick(Side.B);
        _everyRestingTick(Side.A);
    }

    function _priceCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 market;

        // The design record's four rows, as literals: what is asked, the resting price, and the two stakes.
        uint256[4][4] memory rows = [
            [uint256(10_000), 210, 9_000, 9_900],
            [uint256(1_000_000), 210, 909_000, 999_900],
            [uint256(10_000), 166, 15_100, 9_966],
            [uint256(1_000_000), 166, 1_515_100, 999_966]
        ];
        for (uint256 i; i < rows.length; ++i) {
            OspexMatching.SignedOrder memory resting = _rest(m1, game, restingSide, rows[i][1], 10_000_000);
            OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 101, rows[i][0]);
            uint256 restingCoin = _coin().balanceOf(m1.a);
            uint256 takingCoin = _coin().balanceOf(tk.a);
            _cross(sender, taking, _list(resting));
            assertEq(_filled(resting), rows[i][2], "a row's resting stake");
            assertEq(_filled(taking), rows[i][3], "a row's taking stake");
            assertEq(restingCoin - _coin().balanceOf(m1.a), rows[i][2], "the resting account's coin");
            assertEq(takingCoin - _coin().balanceOf(tk.a), rows[i][3], "the taking account's coin");
            // The taking account is never pulled for more than it signed.
            assertLe(takingCoin - _coin().balanceOf(tk.a), rows[i][0], "pulled for more than the signed stake");
        }
        market = markets.getMarketId(game, address(moneyline), 0);
        // The four rows' positions, added: each account's risk is its stakes, its profit the other's.
        _assertPosition(market, m1.a, restingSide, 2_448_200, 2_019_732, "the resting account, over the four rows");
        _assertPosition(market, tk.a, takingSide, 2_019_732, 2_448_200, "the taking account, over the four rows");

        // A taking order at 1.50 against a resting 2.10 fills at 2.10: the taking account gets the whole gap.
        OspexMatching.SignedOrder memory at210 = _rest(m2, game, restingSide, 210, 10_000);
        OspexMatching.SignedOrder memory at150 = _take(tk, game, takingSide, 150, 11_000);
        _cross(sender, at150, _list(at210));
        assertEq(_filled(at210), 10_000, "the resting stake, at its own price");
        assertEq(_filled(at150), 11_000, "the taking stake, at the resting price: 110 for every 100");

        // No clip. At 100.01 a taking stake of 19,800 is a hair under two lots' worth, 19,802: one lot fills,
        // 100 against 9,901, and the resting account is not paid 19,800 for 200.
        OspexMatching.SignedOrder memory long = _rest(m3, game, restingSide, 10_001, 10_000);
        OspexMatching.SignedOrder memory under = _take(tk, game, takingSide, 101, 19_800);
        _cross(sender, under, _list(long));
        assertEq(_filled(long), 100, "one lot of resting stake");
        assertEq(_filled(under), 9_901, "the taking stake for one lot at 100.01");
    }

    /// @dev At every resting price, 1.01 to 101.00: a hundred lots fill at that price to the unit; the taking
    ///      price is accepted at its last tick and refused one tick past it.
    function _everyRestingTick(Side takingSide) internal {
        uint256 game = _verifiedGame();
        for (uint256 tick = 101; tick <= 10_100; ++tick) {
            // Each tick in a call of its own, so that the memory of ten thousand Crosses is not held at once.
            this.oneRestingTick(game, tick, takingSide);
        }
    }

    /// @dev One tick of the loop above. Called by this contract alone.
    function oneRestingTick(uint256 game, uint256 tick, Side takingSide) external {
        assertEq(msg.sender, address(this), "called from outside this test");
        uint256 p = tick - 100;
        // The last taking tick that meets: (resting - 100) x (taking - 100) <= 10,000.
        uint256 last = 100 + 10_000 / p;
        OspexMatching.SignedOrder memory resting = _rest(m1, game, _other(takingSide), tick, 10_000);
        if (last < 10_100) {
            OspexMatching.SignedOrder memory past = _take(tk, game, takingSide, last + 1, 100 * p);
            (bool ok, bytes memory err) = _tryCross(sender, past, _list(resting));
            assertFalse(ok, "a taking price one tick past the last that meets");
            assertEq(err, _refusal(OspexMatching.OspexMatching__PricesDoNotMeet.selector, resting));
        }
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, last, 100 * p);
        uint256 restingCoin = _coin().balanceOf(m1.a);
        uint256 takingCoin = _coin().balanceOf(tk.a);
        _cross(sender, taking, _list(resting));
        // A hundred lots of resting stake against a hundred times p: p to 100, the resting price less one.
        assertEq(restingCoin - _coin().balanceOf(m1.a), 10_000, "the resting stake at a tick");
        assertEq(takingCoin - _coin().balanceOf(tk.a), 100 * p, "the taking stake at a tick");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 7. Neither stake of a fill is under $0.0001, a hundred units.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, delete the minimum, `if (lots * p < LOT) return (false,
    /// SkipReason.NothingFits);`. Another turns it red: the minimum weakened to refuse only a leg of no lots.
    function test_neverLine_neitherStakeOfAFillIsUnderTheMinimum() public {
        _registerAll(sender);
        _minimumCases(Side.B);
        _minimumCases(Side.A);
    }

    function _minimumCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);

        // At 1.01 each lot of resting stake is one unit of taking stake. Ninety-nine lots are 99 units, under
        // the minimum: nothing fits. A hundred lots fill: 10,000 against 100.
        OspexMatching.SignedOrder memory at101 = _rest(m1, game, restingSide, 101, 9_900);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        _refused(sender, taking, _list(at101), _nothingFilled(_reasons(NOTHING_FITS)), "99 lots at 1.01");
        OspexMatching.SignedOrder memory hundred = _rest(m1, game, restingSide, 101, 10_000);
        _cross(sender, taking, _list(hundred));
        assertEq(_filled(hundred), 10_000, "a hundred lots at 1.01");
        assertEq(_filled(taking), 100, "against a hundred units");

        // At 1.50 one lot is 100 against 50: refused. Two are 200 against 100: filled.
        OspexMatching.SignedOrder memory oneLot = _rest(m2, game, restingSide, 150, 100);
        OspexMatching.SignedOrder memory forHalf = _take(tk, game, takingSide, 200, 10_000);
        _refused(sender, forHalf, _list(oneLot), _nothingFilled(_reasons(NOTHING_FITS)), "one lot at 1.50");
        OspexMatching.SignedOrder memory twoLots = _rest(m2, game, restingSide, 150, 200);
        _cross(sender, forHalf, _list(twoLots));
        assertEq(_filled(twoLots), 200, "two lots at 1.50");
        assertEq(_filled(forHalf), 100, "against a hundred units");

        // A taking stake left of 99 units fits nothing at any price. The taking order signs 10,000 and fills
        // 9,901 against one lot at 100.01, which leaves it 99.
        OspexMatching.SignedOrder memory spent = _take(tk, game, takingSide, 101, 10_000);
        _cross(sender, spent, _list(_rest(m3, game, restingSide, 10_001, 10_000)));
        assertEq(_filled(spent), 9_901, "one lot at 100.01");
        uint16[4] memory ticks = [uint16(101), 199, 200, 10_100];
        uint8[] memory four = new uint8[](4);
        OspexMatching.SignedOrder[] memory any = new OspexMatching.SignedOrder[](4);
        for (uint256 i; i < ticks.length; ++i) {
            any[i] = _rest(m3, game, restingSide, ticks[i], 1_000_000);
            four[i] = NOTHING_FITS;
        }
        _refused(sender, spent, any, _nothingFilled(four), "99 units left, at four prices");
        assertEq(_filled(spent), 9_901, "a taking order with 99 units left filled further");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 8. Nothing stays in the contract, and nothing belongs to an address for sending the Cross.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Who plays each part in one layout of the worked Cross.
    struct Layout {
        Signer taking;
        Signer first;
        Signer cancelled;
        Signer third;
        address from;
        string name;
    }

    /// Break: in OspexPositions._record, pull one unit more than is recorded, `makerRisk + 1` in the maker's
    /// pull. Others turn it red: one unit less profit recorded than is pulled; the sender passed to the
    /// positions module as the taker; and the sender passed as the maker.
    function test_neverLine_nothingStaysAndNothingBelongsToTheSender() public {
        Signer memory outsider = Signer({a: sender, key: 0});
        _fundCoin(sender);
        // Every role a different address.
        _layout(Layout(tk, m1, m2, m3, sender, "every role a different address"), outsider);
        // The sender is the taking account.
        _layout(Layout(tk, m1, m2, m3, tk.a, "the sender is the taking account"), outsider);
        // The sender is a resting account.
        _layout(Layout(tk, m1, m2, m3, m3.a, "the sender is a resting account"), outsider);
        // One account on both sides, sent by another address, and sent by itself.
        _layout(Layout(tk, tk, m2, m3, sender, "one account on both sides"), outsider);
        _layout(Layout(tk, tk, m2, m3, tk.a, "one account on both sides, which sends"), outsider);
    }

    /// @dev The worked Cross, in one layout, with the taking order on each side: a taking order of 10,000 at
    ///      1.90 against 5,000 of room at 2.10, a cancelled order at 2.05, and 100,000 of room at 2.00. Two
    ///      legs fill, 5,000 against 5,500 and 4,500 against 4,500, and one order is skipped.
    function _layout(Layout memory l, Signer memory outsider) internal {
        _oneLayout(l, outsider, Side.B);
        _oneLayout(l, outsider, Side.A);
    }

    /// @dev Every address claims on both sides of the settled market, side A having won. Which addresses hold
    ///      a position on side A is read from the layout, not from the contract: the taking account when the
    ///      taking order is on side A, the first and third resting accounts otherwise. Every claim that must
    ///      be refused is made first, while the contract still holds every stake, so that none can fail for
    ///      want of coin; then the winners are paid.
    function _claimAll(Layout memory l, address[5] memory who, uint256 market, Side takingSide)
        internal
        returns (uint256 paid)
    {
        bytes memory noPayout = abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector);
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 i; i < 5; ++i) {
                bool seen;
                for (uint256 j; j < i; ++j) {
                    if (who[j] == who[i]) seen = true;
                }
                if (seen) continue;
                bool wins = takingSide == Side.A ? who[i] == l.taking.a : (who[i] == l.first.a || who[i] == l.third.a);
                // The account on both sides that took side B holds exactly its loss on side B: nothing to pay.
                if (who[i] == l.taking.a && l.first.a == l.taking.a && takingSide == Side.B) wins = false;
                if (pass == 1) {
                    if (wins) paid += _claim(who[i], market, Side.A);
                    continue;
                }
                (bool ok, bytes memory err) = _tryClaim(who[i], market, Side.B);
                assertFalse(ok, string.concat(l.name, ": the losing side was paid"));
                assertEq(err, noPayout, string.concat(l.name, ": the losing side's refusal"));
                if (wins) continue;
                (ok, err) = _tryClaim(who[i], market, Side.A);
                assertFalse(ok, string.concat(l.name, ": an address with nothing on the winning side was paid"));
                assertEq(err, noPayout, string.concat(l.name, ": its refusal"));
            }
        }
    }

    function _oneLayout(Layout memory l, Signer memory outsider, Side takingSide) internal {
        uint256 snap = vm.snapshotState();
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        address[5] memory who = [l.taking.a, l.first.a, l.cancelled.a, l.third.a, outsider.a];
        for (uint256 i; i < 4; ++i) {
            _register(who[i], l.from);
        }
        OspexMatching.SignedOrder memory taking = _take(l.taking, game, takingSide, 190, 10_000);
        OspexMatching.SignedOrder memory first = _rest(l.first, game, restingSide, 210, 5_000);
        OspexMatching.SignedOrder memory cancelled = _rest(l.cancelled, game, restingSide, 205, 10_000);
        OspexMatching.SignedOrder memory third = _rest(l.third, game, restingSide, 200, 100_000);
        vm.prank(l.cancelled.a);
        matching.cancelOrder(cancelled.order);

        uint256[5] memory coin;
        for (uint256 i; i < 5; ++i) {
            coin[i] = _coin().balanceOf(who[i]);
        }
        _cross(l.from, taking, _list(first, cancelled, third));
        uint256 market = markets.getMarketId(game, address(moneyline), 0);

        // Every address's coin change is exactly what the legs ask of its own orders, added over the parts it
        // plays: 10,000 as the taking account, 5,000 as the first resting account, nothing as the skipped one,
        // 4,500 as the third, and nothing for sending. An account on both sides, the taking account resting
        // first, is pulled its worst loss once, at the end: 4,500, the 10,000 it takes less the 5,500 its own
        // resting order wins it, and nothing at its own leg.
        bool twoSided = l.first.a == l.taking.a;
        uint256[5] memory part = [uint256(twoSided ? 4_500 : 10_000), twoSided ? 0 : 5_000, 0, 4_500, 0];
        for (uint256 i; i < 5; ++i) {
            uint256 owed;
            for (uint256 j; j < 5; ++j) {
                if (who[j] == who[i]) owed += part[j];
            }
            assertEq(coin[i] - _coin().balanceOf(who[i]), owed, string.concat(l.name, ": an address's coin change"));
        }
        // The positions module's coin rose by what was pulled, and this market holds it all: both stakes of the
        // two filled legs, or, with one account on both sides, that account's worst loss and the third's stake.
        assertEq(
            _coin().balanceOf(address(positions)), twoSided ? 9_000 : 19_500, string.concat(l.name, ": the stakes held")
        );

        // Every position is what the legs give: the taking account risks 10,000 to win 9,500; the first resting
        // account 5,000 to win 5,500; the third 4,500 to win 4,500. Where one account plays two parts on a side,
        // its position is their sum.
        uint256[2][5] memory restingWant =
            [[uint256(0), 0], [uint256(5_000), 5_500], [uint256(0), 0], [uint256(4_500), 4_500], [uint256(0), 0]];
        for (uint256 i; i < 5; ++i) {
            uint256 risk;
            uint256 profit;
            for (uint256 j; j < 5; ++j) {
                if (who[j] == who[i]) {
                    risk += restingWant[j][0];
                    profit += restingWant[j][1];
                }
            }
            _assertPosition(market, who[i], restingSide, risk, profit, string.concat(l.name, ": on the resting side"));
            bool takes = who[i] == l.taking.a;
            _assertPosition(
                market,
                who[i],
                takingSide,
                takes ? 10_000 : 0,
                takes ? 9_500 : 0,
                string.concat(l.name, ": on the taking side")
            );
        }
        assertEq(_filled(cancelled), 0, string.concat(l.name, ": the skipped order"));

        // After settlement every claim is paid and the market's coin is gone. Home wins 104 to 97: side A is
        // paid what it holds plus its net, which for a one-sided account is its risk and its profit, side B
        // nothing. The account on both sides is paid 9,000 on its side A record when it took side A, 4,500 held
        // plus 9,500 won less 5,000 lost; when it took side B its net is the 4,500 it holds, lost, and both of
        // its records are refused.
        _score(game, HOME, AWAY);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home));
        uint256 paid = _claimAll(l, who, market, takingSide);
        assertEq(paid, twoSided ? 9_000 : 19_500, string.concat(l.name, ": what the winning side was paid"));
        assertEq(_coin().balanceOf(address(positions)), 0, string.concat(l.name, ": coin left in the contract"));
        vm.revertToState(snap);
    }
}
