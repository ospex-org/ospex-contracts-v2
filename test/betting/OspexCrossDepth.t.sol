// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {Side} from "../../src/betting/OspexBettingTypes.sol";
import {TestCoin} from "../games/CoinFixtures.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross's never-lines, where the other files' fixtures are all of one shape: a fault and a dead
///         order at each place of a list of five; a market on a line that is not 0; an order that rests before
///         it takes; a refused pull at a price that is not 2.00; and stakes of many lots. Above each test,
///         "Break:" names changes to src/betting that turn it red; each is an entry of battery.json. Each test
///         runs twice, with the taking order on side B and on side A.
contract OspexCrossDepthTest is CrossBase {
    Signer internal tk;
    Signer[5] internal makers;
    /// @dev A sixth resting account, whose order is the one a test kills.
    Signer internal extra;
    /// @dev An account that has registered nobody.
    Signer internal lone;

    function setUp() public override {
        super.setUp();
        tk = _account("taking account");
        _register(tk.a, sender);
        for (uint256 i; i < 5; ++i) {
            makers[i] = _account(string.concat("resting ", vm.toString(i)));
            _register(makers[i].a, sender);
        }
        extra = _account("a sixth resting account");
        _register(extra.a, sender);
        lone = _account("an account with no courier");
    }

    /// @dev Five resting orders of 10,000 at 2.00 on the game's moneyline, one from each resting account.
    function _five(uint256 game, Side restingSide) internal returns (OspexMatching.SignedOrder[] memory five) {
        five = new OspexMatching.SignedOrder[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = _rest(makers[i], game, restingSide, 200, 10_000);
        }
    }

    /// @dev `five` with `x` in the place `at`.
    function _with(OspexMatching.SignedOrder[] memory five, OspexMatching.SignedOrder memory x, uint256 at)
        internal
        pure
        returns (OspexMatching.SignedOrder[] memory out)
    {
        out = new OspexMatching.SignedOrder[](five.length);
        for (uint256 i; i < five.length; ++i) {
            out[i] = i == at ? x : five[i];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 13, 14, 15. A resting order with a fault of its own, or off the taking order's market, side or price,
    // reverts the Cross wherever it is listed, and whoever's it is.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Fourteen resting orders, each with one fault, and the refusal each must raise. The last three are
    ///      the taking account's own.
    function _faults(uint256 game, Side takingSide)
        internal
        returns (OspexMatching.SignedOrder[] memory faulty, bytes4[] memory names)
    {
        Side restingSide = _other(takingSide);
        Signer memory m = makers[0];
        bytes memory junk = new bytes(65);
        for (uint256 i; i < 65; ++i) {
            junk[i] = 0x11;
        }
        faulty = new OspexMatching.SignedOrder[](14);
        names = new bytes4[](14);

        // Signed by another account's key; and signed by nobody, 65 bytes that are no signature.
        faulty[0] = _rest(m, game, restingSide, 200, 10_000);
        faulty[0].signature = _signature(makers[1].key, _hash(faulty[0]));
        names[0] = OspexMatching.OspexMatching__BadSignature.selector;
        faulty[1] = _rest(m, game, restingSide, 200, 10_000);
        faulty[1].signature = junk;
        names[1] = OspexMatching.OspexMatching__BadSignature.selector;
        // A price one tick under the range, and one over it.
        faulty[2] = _rest(m, game, restingSide, 100, 10_000);
        names[2] = OspexMatching.OspexMatching__PriceOutOfRange.selector;
        faulty[3] = _rest(m, game, restingSide, 10_101, 10_000);
        names[3] = OspexMatching.OspexMatching__PriceOutOfRange.selector;
        // A stake that is not in lots, and no stake.
        faulty[4] = _rest(m, game, restingSide, 200, 10_050);
        names[4] = OspexMatching.OspexMatching__StakeNotInLots.selector;
        faulty[5] = _rest(m, game, restingSide, 200, 0);
        names[5] = OspexMatching.OspexMatching__StakeNotInLots.selector;
        // Another game, another scorer, another line.
        faulty[6] = _rest(m, _verifiedGame(), restingSide, 200, 10_000);
        names[6] = OspexMatching.OspexMatching__OtherGame.selector;
        faulty[7] = _restOn(m, game, address(total), 0, restingSide, 200, 10_000);
        names[7] = OspexMatching.OspexMatching__OtherScorer.selector;
        faulty[8] = _restOn(m, game, address(moneyline), -35, restingSide, 200, 10_000);
        names[8] = OspexMatching.OspexMatching__OtherLine.selector;
        // The taking order's side; and a price that does not meet it: 3.00 against 1.90 is 200 times 90.
        faulty[9] = _rest(m, game, takingSide, 200, 10_000);
        names[9] = OspexMatching.OspexMatching__SameSide.selector;
        faulty[10] = _rest(m, game, restingSide, 300, 10_000);
        names[10] = OspexMatching.OspexMatching__PricesDoNotMeet.selector;
        // The taking account's own resting order: signed by nobody; priced out of range; not in lots.
        faulty[11] = _rest(tk, game, restingSide, 200, 10_000);
        faulty[11].signature = junk;
        names[11] = OspexMatching.OspexMatching__BadSignature.selector;
        faulty[12] = _rest(tk, game, restingSide, 100, 10_000);
        names[12] = OspexMatching.OspexMatching__PriceOutOfRange.selector;
        faulty[13] = _rest(tk, game, restingSide, 200, 10_050);
        names[13] = OspexMatching.OspexMatching__StakeNotInLots.selector;
    }

    /// Break: in OspexMatching._checkResting, test an order's signature, price and stake only at the first two
    /// places of the list. Others turn it red: the same for its game, for its side and for the meeting of the
    /// prices; and an order whose account is the taking account not tested for its signature, price or stake.
    function test_neverLine_aFaultAtAnyPlaceInTheListRevertsTheCross() public {
        _faultCases(Side.B);
        _faultCases(Side.A);
    }

    function _faultCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 190, 50_000);
        OspexMatching.SignedOrder[] memory five = _five(game, _other(takingSide));
        (OspexMatching.SignedOrder[] memory faulty, bytes4[] memory names) = _faults(game, takingSide);

        for (uint256 f; f < faulty.length; ++f) {
            bytes memory want = _refusal(names[f], faulty[f]);
            for (uint256 at; at < 5; ++at) {
                _refused(
                    sender,
                    taking,
                    _with(five, faulty[f], at),
                    want,
                    string.concat("fault ", vm.toString(f), " at place ", vm.toString(at))
                );
            }
        }

        // The controls. The five orders without a fault fill, five legs of 10,000 against 10,000; and so do
        // four of them with a sound order of the taking account's own among them.
        uint256 snap = vm.snapshotState();
        _cross(sender, taking, five);
        assertEq(_filled(taking), 50_000, "the control: the five orders fill");
        vm.revertToState(snap);
        OspexMatching.SignedOrder memory own = _rest(tk, game, _other(takingSide), 200, 10_000);
        _cross(sender, taking, _with(five, own, 2));
        assertEq(_filled(taking), 50_000, "the control: with the taking account's own order among them");
        assertEq(_filled(own), 10_000, "the control: the taking account's own resting order");
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 5, 9. A dead order is skipped under its own reason wherever it is listed, and the four beside it fill.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev An order of the sixth account in one of seven states that skip, and the reason it must be recorded
    ///      under. Each state is made here, in the chain's state as it stands.
    function _dead(uint8 kind, uint256 game, Side restingSide)
        internal
        returns (OspexMatching.SignedOrder memory x, uint8 reason)
    {
        if (kind == 0) {
            // Its account has registered nobody.
            return (_rest(lone, game, restingSide, 200, 10_000), NO_COURIER);
        }
        if (kind == 3) {
            // At its expiry.
            return (_restUntil(extra, game, restingSide, 200, 10_000, vm.getBlockTimestamp()), EXPIRED);
        }
        if (kind == 5) {
            // One lot at 1.50 is 100 against 50.
            return (_rest(extra, game, restingSide, 150, 100), NOTHING_FITS);
        }
        x = _rest(extra, game, restingSide, 200, 10_000);
        if (kind == 1) {
            vm.prank(extra.a);
            matching.cancelOrder(x.order);
            return (x, CANCELLED);
        }
        if (kind == 2) {
            // One under its account's floor on the market.
            vm.prank(extra.a);
            matching.raiseFloor(extra.a, game, address(moneyline), 0, _no(x.order.nonce + 1));
            return (x, CANCELLED);
        }
        if (kind == 4) {
            // Filled to its signed stake by an earlier Cross.
            _cross(sender, _take(tk, game, _other(restingSide), 200, 10_000), _list(x));
            return (x, NO_ROOM);
        }
        // Its account lets the positions module take nothing.
        IERC20 coin = _coin();
        vm.prank(extra.a);
        coin.approve(address(positions), 0);
        return (x, PULL_REFUSED);
    }

    /// @dev `dead`, in the place `at` of the five, is skipped for `reason` and the four other orders fill.
    function _skippedAt(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory five,
        OspexMatching.SignedOrder memory dead,
        uint8 reason,
        uint256 at
    ) internal {
        uint256 snap = vm.snapshotState();
        string memory what = string.concat("reason ", vm.toString(reason), " at place ", vm.toString(at));
        uint256 before = _filled(dead);
        vm.recordLogs();
        _cross(sender, taking, _with(five, dead, at));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, string.concat(what, ": one skip record"));
        _assertSkip(skips[0], dead, taking, reason, what);
        assertEq(_filled(dead), before, string.concat(what, ": the dead order's filled amount"));
        assertEq(_filled(taking), 40_000, string.concat(what, ": the four other legs"));
        for (uint256 i; i < 5; ++i) {
            if (i != at) assertEq(_filled(five[i]), 10_000, string.concat(what, ": an order beside it"));
        }
        vm.revertToState(snap);
    }

    /// Break: in OspexMatching._leg, test a resting order's cancel mark only until two legs of the Cross have
    /// filled. Another turns it red: the same for its expiry.
    function test_neverLine_aDeadOrderAtAnyPlaceInTheListIsSkipped() public {
        _deadCases(Side.B);
        _deadCases(Side.A);
    }

    function _deadCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder[] memory five = _five(game, _other(takingSide));
        for (uint8 kind; kind < 7; ++kind) {
            uint256 snap = vm.snapshotState();
            (OspexMatching.SignedOrder memory dead, uint8 reason) = _dead(kind, game, _other(takingSide));
            OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 190, 50_000);
            for (uint256 at; at < 5; ++at) {
                _skippedAt(taking, five, dead, reason, at);
            }
            vm.revertToState(snap);
        }
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 5. A floor cancels on its own market: on a line that is not 0, and from no other line.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.cross, build the floor's key with the line 0 in place of the taking order's line.
    function test_neverLine_aFloorCancelsOnItsOwnLineAndFromNoOther() public {
        _floorCases(Side.B);
        _floorCases(Side.A);
    }

    function _floorCases(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        address s = address(spread);
        OspexMatching.SignedOrder memory dead = _restOn(makers[0], game, s, -35, _other(takingSide), 200, 10_000);
        OspexMatching.SignedOrder memory live = _restOn(makers[1], game, s, -35, _other(takingSide), 200, 10_000);
        OspexMatching.SignedOrder memory taking = _takeOn(tk, game, s, -35, takingSide, 200, 10_000);
        int32[4] memory otherLines = [int32(0), 35, -30, -36];
        uint256 snap = vm.snapshotState();

        // The control: on the spread at -3.5 the first order fills.
        _cross(sender, taking, _list(dead, live));
        assertEq(_filled(dead), 10_000, "the control: the first order fills");
        vm.revertToState(snap);

        // Resting, one under its account's floor on that line: skipped as cancelled, and the next order fills.
        vm.prank(makers[0].a);
        matching.raiseFloor(makers[0].a, game, s, -35, _no(dead.order.nonce + 1));
        vm.recordLogs();
        _cross(sender, taking, _list(dead, live));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record");
        _assertSkip(skips[0], dead, taking, CANCELLED, "an order under its account's floor on the spread at -3.5");
        assertEq(_filled(dead), 0, "an order under its floor filled");
        assertEq(_filled(live), 10_000, "the order beside it");
        vm.revertToState(snap);
        // Its account's floors on the same game and scorer at other lines do not touch it.
        for (uint256 i; i < otherLines.length; ++i) {
            vm.prank(makers[0].a);
            matching.raiseFloor(makers[0].a, game, s, otherLines[i], _no(dead.order.nonce + 1));
        }
        _cross(sender, taking, _list(dead));
        assertEq(_filled(dead), 10_000, "an order under floors raised on other lines");
        vm.revertToState(snap);

        // Taking, one under its account's floor on that line: the Cross reverts by name.
        vm.prank(tk.a);
        matching.raiseFloor(tk.a, game, s, -35, _no(taking.order.nonce + 1));
        _refused(
            sender,
            taking,
            _list(dead, live),
            _refusal(OspexMatching.OspexMatching__TakingOrderCancelled.selector, taking),
            "a taking order under its account's floor on the spread at -3.5"
        );
        vm.revertToState(snap);
        for (uint256 i; i < otherLines.length; ++i) {
            vm.prank(tk.a);
            matching.raiseFloor(tk.a, game, s, otherLines[i], _no(taking.order.nonce + 1));
        }
        _cross(sender, taking, _list(dead));
        assertEq(_filled(taking), 10_000, "a taking order under floors raised on other lines");
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 4. An order never fills past its signed stake: resting first and taking after, on one record.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.sol, keep what an order filled while resting apart from its room as a taking
    /// order, so that an order that rested takes its whole signed stake again.
    function test_neverLine_anOrderThatRestedThenTakesHasOnlyWhatIsLeft() public {
        _restThenTake(Side.B);
        _restThenTake(Side.A);
    }

    function _restThenTake(Side side) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        // An order of 10,000 at 2.00, with thirty seconds to its expiry so that it may take.
        OspexMatching.SignedOrder memory both = _take(makers[0], game, side, 200, 10_000);
        // It rests first: a taking order on the other side fills 6,000 of it.
        _cross(sender, _take(tk, game, _other(side), 200, 6_000), _list(both));
        assertEq(_filled(both), 6_000, "as a resting order");
        // Then it takes, against 10,000 of room: it has 4,000 left, and takes that and no more.
        OspexMatching.SignedOrder memory against = _rest(makers[1], game, _other(side), 200, 10_000);
        _cross(sender, both, _list(against));
        assertEq(_filled(both), 10_000, "as a taking order, on the same record: its signed stake");
        assertEq(_filled(against), 4_000, "what the order had left to take");
        _assertPosition(
            markets.getMarketId(game, address(moneyline), 0), makers[0].a, side, 10_000, 10_000, "its position"
        );
        // Full, in both roles.
        _refused(
            sender,
            both,
            _list(against),
            _refusal(OspexMatching.OspexMatching__TakingOrderFilled.selector, both),
            "an order filled in both roles, sent as the taking order"
        );
        _refused(
            sender,
            _take(tk, game, _other(side), 200, 1_000),
            _list(both),
            _nothingFilled(_reasons(NO_ROOM)),
            "an order filled in both roles, listed as a resting order"
        );
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 9. A refused pull, at a price where the two stakes of a leg are not the same number.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._leg, recognise the refused resting pull against the leg's taking stake. Another
    /// turns it red: the taking account's refusal carrying the resting stake.
    function test_neverLine_aRefusedPullAtAPriceThatIsNotEven() public {
        _unevenRefusals(Side.B);
        _unevenRefusals(Side.A);
    }

    function _unevenRefusals(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        uint256 game = _verifiedGame();
        IERC20 coin = _coin();
        // At 2.10 a leg of a hundred lots is 10,000 against 11,000.
        OspexMatching.SignedOrder memory unpaid = _rest(makers[0], game, _other(takingSide), 210, 10_000);
        OspexMatching.SignedOrder memory paid = _rest(makers[1], game, _other(takingSide), 210, 10_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 190, 22_000);
        uint256 snap = vm.snapshotState();

        // The control: both legs fill.
        _cross(sender, taking, _list(unpaid, paid));
        assertEq(_filled(taking), 22_000, "the control: two legs of 11,000");
        vm.revertToState(snap);

        // The resting pull is refused: that order is skipped, and the next fills.
        vm.prank(makers[0].a);
        coin.approve(address(positions), 0);
        vm.recordLogs();
        _cross(sender, taking, _list(unpaid, paid));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record");
        _assertSkip(skips[0], unpaid, taking, PULL_REFUSED, "a refused resting pull at 2.10");
        assertEq(_filled(unpaid), 0, "the order whose pull was refused");
        assertEq(_filled(paid), 10_000, "the order beside it");
        assertEq(_filled(taking), 11_000, "the taking order: one leg");
        vm.revertToState(snap);

        // The taking pull is refused: the Cross reverts, naming the taking account and its one netted pull after
        // the walk, both legs' 11,000, not a leg's stake.
        vm.prank(tk.a);
        coin.approve(address(positions), 0);
        _refused(
            sender,
            taking,
            _list(unpaid, paid),
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, tk.a, 22_000),
            "a refused taking pull at 2.10"
        );
        vm.revertToState(start);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 4, 6. A stake of many lots fills in full: once the switch is lifted, as it is here, the contracts put no cap
    // on a stake.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Three legs at 3.00, each a whole resting stake against twice as much: twenty million lots, ten thousand
    /// million lots, and 10^28 lots, which is past 64 bits.
    /// Break: in OspexMatching._leg, cut a leg's lot count to 24 bits.
    function test_neverLine_aStakeOfManyLotsFillsInFull() public {
        _manyLots(Side.B);
        _manyLots(Side.A);
    }

    function _manyLots(Side takingSide) internal {
        uint256 start = vm.snapshotState();
        Side restingSide = _other(takingSide);
        uint256 game = _verifiedGame();
        TestCoin coin = TestCoin(address(_coin()));
        uint256[3] memory stakes = [uint256(2_000_000_000), 1_000_000_000_000, 1e30];
        uint256 all;
        for (uint256 i; i < stakes.length; ++i) {
            uint256 stake = stakes[i];
            coin.mint(makers[0].a, stake);
            coin.mint(tk.a, 2 * stake);
            OspexMatching.SignedOrder memory resting = _rest(makers[0], game, restingSide, 300, stake);
            OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 150, 2 * stake);
            uint256 held = coin.balanceOf(address(positions));
            _cross(sender, taking, _list(resting));
            assertEq(_filled(resting), stake, "the resting order, in full");
            assertEq(_filled(taking), 2 * stake, "the taking order, in full");
            assertEq(coin.balanceOf(address(positions)) - held, 3 * stake, "the two stakes, held");
            all += stake;
        }
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        _assertPosition(market, makers[0].a, restingSide, all, 2 * all, "the resting account's position");
        _assertPosition(market, tk.a, takingSide, 2 * all, all, "the taking account's position");
        vm.revertToState(start);
    }
}
