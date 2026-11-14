// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";
import {CallbackAccount, RetryingSender} from "./CrossFixtures.sol";

/// @notice The minimum fill: the signed order's tenth field, minFill, the least the order fills for in one Cross
///         unless the fill completes it. Never-lines 21, 22 and 24 to 26 and the tests beside them, on the lifted
///         base: the rule in either role, what a short Cross leaves, the report, the seventh reason's place among
///         the reasons, and the boundaries; 23, the field in the hash, is the next contract. Above each test,
///         "Breaks:" names the changes to src/betting that turn it red, each an entry of battery.json. Amounts are
///         literals worked out by hand. At 2.00 the two stakes of a leg are equal, so the priced cases at 2.10 and
///         2.07 are where a check that read the wrong stake is told apart from the right one.
contract OspexMinFillTest is CrossBase {
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
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m2.a, sender);
        _register(m3.a, sender);
    }

    /// @dev Everything a Cross can move for the four accounts and the sender, and these orders' filled amounts.
    function _print(OspexMatching.SignedOrder[] memory orders) internal view returns (bytes32) {
        address[] memory who = new address[](5);
        who[0] = tk.a;
        who[1] = m1.a;
        who[2] = m2.a;
        who[3] = m3.a;
        who[4] = sender;
        return _fingerprint(who, _hashes(orders));
    }

    function _hashes(OspexMatching.SignedOrder[] memory orders) internal view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](orders.length);
        for (uint256 i; i < orders.length; ++i) {
            hashes[i] = _hash(orders[i]);
        }
    }

    function _list4(
        OspexMatching.SignedOrder memory a,
        OspexMatching.SignedOrder memory b,
        OspexMatching.SignedOrder memory c,
        OspexMatching.SignedOrder memory d
    ) internal pure returns (OspexMatching.SignedOrder[] memory l) {
        l = new OspexMatching.SignedOrder[](4);
        l[0] = a;
        l[1] = b;
        l[2] = c;
        l[3] = d;
    }

    function _two(uint8 a, uint8 b) internal pure returns (uint8[] memory r) {
        r = new uint8[](2);
        r[0] = a;
        r[1] = b;
    }

    /// @dev The last 32-byte word of `data`.
    function _lastWord(bytes memory data) internal pure returns (uint256 word) {
        require(data.length >= 32, "no word");
        uint256 at = data.length - 32;
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), at))
        }
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev The bound's refusal: the order's hash and the two numbers.
    function _aboveStake(OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            OspexMatching.OspexMatching__MinFillAboveStake.selector, _hash(s), s.order.minFill, s.order.riskAmount
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 21. No order fills for less than its minimum fill, in either role, unless the fill takes all that is left.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Breaks: in OspexMatching.cross, delete the tail, the taking order's check after the walk; in
    /// OspexMatching._leg, delete the resting order's check; invert its comparison, skipping when
    /// `makerRisk >= r.minFill`; the tail comparing the resting stakes, `tally.makerRisk`, with the minimum; the
    /// leg comparing the taking stake, `takerRisk`, with the resting order's minimum; the leg comparing against
    /// the taking order's minimum, `t.minFill`; the tail measuring the order's whole filled amount,
    /// `s_filledRisk[takingHash]`, in place of this Cross's; and the tail reading the room before the walk.
    function test_neverLine_noFillBelowMinFillInEitherRole() public {
        _takingCases(Side.B);
        _takingCases(Side.A);
        _restingCases(Side.B);
        _restingCases(Side.A);
    }

    function _takingCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        uint256 snap = vm.snapshotState();

        // 10 USDC asking for all of it, against one resting 5 USDC at 2.00: short, by name, the one filled leg in
        // its report, and nothing moved. Against two resting 5 USDC: filled, complete.
        OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 200, 10_000_000, 10_000_000);
        OspexMatching.SignedOrder memory five = _rest(m1, game, restingSide, 200, 5_000_000);
        OspexMatching.SignedOrder memory five2 = _rest(m2, game, restingSide, 200, 5_000_000);
        bytes32 before = _print(_list(taking, five, five2));
        legs[0] = _filledLeg(five, 5_000_000, 5_000_000);
        _refused(
            sender,
            taking,
            _list(five),
            _short(taking, 5_000_000, 5_000_000, legs),
            "10 USDC asking for all of it, against one 5 USDC"
        );
        assertEq(_print(_list(taking, five, five2)), before, "the short Cross left something");
        _cross(sender, taking, _list(five, five2));
        assertEq(_filled(taking), 10_000_000, "10 USDC asking for all of it, against two 5 USDC");
        vm.revertToState(snap);

        // 10 USDC asking for 3 USDC: 5 USDC fills it. A second Cross on it, with 5 USDC left: 2 USDC is short,
        // 2 under 3 with 3 left; 5 USDC fills and completes it.
        taking = _takeMin(tk, game, takingSide, 200, 10_000_000, 3_000_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 5_000_000)));
        assertEq(_filled(taking), 5_000_000, "3 USDC asked, 5 USDC filled");
        OspexMatching.SignedOrder memory two = _rest(m2, game, restingSide, 200, 2_000_000);
        legs[0] = _filledLeg(two, 2_000_000, 2_000_000);
        _refused(
            sender,
            taking,
            _list(two),
            _short(taking, 2_000_000, 3_000_000, legs),
            "3 USDC asked, 2 USDC in a second Cross with 5 USDC left"
        );
        assertEq(_filled(taking), 5_000_000, "the short second Cross changed the filled amount");
        _cross(sender, taking, _list(_rest(m2, game, restingSide, 200, 5_000_000)));
        assertEq(_filled(taking), 10_000_000, "3 USDC asked, 5 USDC in a second Cross completes it");
        vm.revertToState(snap);

        // This Cross's own fill is measured, not the order's total: 3 USDC asked and 3 USDC filled in one Cross,
        // then 2 USDC in a second is short, though 5 USDC in all is above 3.
        taking = _takeMin(tk, game, takingSide, 200, 10_000_000, 3_000_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 3_000_000)));
        assertEq(_filled(taking), 3_000_000, "3 USDC asked, 3 USDC filled");
        two = _rest(m2, game, restingSide, 200, 2_000_000);
        legs[0] = _filledLeg(two, 2_000_000, 2_000_000);
        _refused(
            sender,
            taking,
            _list(two),
            _short(taking, 2_000_000, 5_000_000, legs),
            "3 USDC asked and filled, then 2 USDC: this Cross's own fill is measured"
        );
        assertEq(_filled(taking), 3_000_000, "the short second Cross changed the filled amount");
        vm.revertToState(snap);

        // The taking stake is measured, never the resting: 10,000 asking for 9,500, at a floor the resting 2.10
        // meets, fills 9,900 for 9,000 of the maker and leaves 100. It passes; read on the maker's 9,000, with a
        // lot left, it would be short.
        taking = _takeMin(tk, game, takingSide, 190, 10_000, 9_500);
        OspexMatching.SignedOrder memory longer = _rest(m1, game, restingSide, 210, 10_000);
        _cross(sender, taking, _list(longer));
        assertEq(_filled(taking), 9_900, "9,500 asked at 1.90: 9,900 filled at 2.10");
        assertEq(_filled(longer), 9_000, "the maker's 9,000 at 2.10");
        vm.revertToState(snap);

        // The room after the walk is what completeness is measured on: 10,000 asking for 6,000 fills 6,000 in a
        // first Cross, and 4,000 in a second completes it, though 4,000 is under 6,000. Before that walk the room
        // was 4,000; after it, 0.
        taking = _takeMin(tk, game, takingSide, 200, 10_000, 6_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 6_000)));
        assertEq(_filled(taking), 6_000, "6,000 asked, 6,000 filled");
        _cross(sender, taking, _list(_rest(m2, game, restingSide, 200, 4_000)));
        assertEq(_filled(taking), 10_000, "6,000 asked, the last 4,000 completes it");
        vm.revertToState(snap);

        // Zero asks for nothing: a taking order asking for nothing fills for one lot.
        taking = _take(tk, game, takingSide, 200, 10_000_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 100)));
        assertEq(_filled(taking), 100, "a taking order asking for nothing, filled for one lot");
        vm.revertToState(snap);
    }

    function _restingCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();

        // 10 USDC resting, asking for 9.99 USDC at least. A 5 USDC taker is skipped under 5, and the rest of its
        // Cross fills; a 9.99 USDC taker fills it; a 0.01 USDC taker then takes the 10,000 left, under the
        // minimum, since it is everything that is left.
        OspexMatching.SignedOrder memory resting = _restMin(m1, game, restingSide, 200, 10_000_000, 9_990_000);
        OspexMatching.SignedOrder memory other = _rest(m2, game, restingSide, 200, 5_000_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 5_000_000);
        vm.recordLogs();
        _cross(sender, taking, _list(resting, other));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "9.99 USDC asked, 5 USDC offered: one skip record");
        _assertSkip(skips[0], resting, taking, UNDER_MIN_FILL, "9.99 USDC asked, 5 USDC offered");
        assertEq(_filled(resting), 0, "9.99 USDC asked, 5 USDC offered: the resting order's filled amount");
        assertEq(_filled(other), 5_000_000, "the rest of the Cross fills");
        _cross(sender, _take(tk, game, takingSide, 200, 9_990_000), _list(resting));
        assertEq(_filled(resting), 9_990_000, "9.99 USDC asked, 9.99 USDC offered");
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(resting));
        assertEq(_filled(resting), 10_000_000, "the 10,000 left, taken whole though under the minimum");
        vm.revertToState(snap);

        // 1 USDC asked at least: 0.50 USDC is skipped, 1 USDC fills.
        resting = _restMin(m1, game, restingSide, 200, 10_000_000, 1_000_000);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 500_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "1 USDC asked, 0.50 USDC offered"
        );
        _cross(sender, _take(tk, game, takingSide, 200, 1_000_000), _list(resting));
        assertEq(_filled(resting), 1_000_000, "1 USDC asked, 1 USDC offered");
        vm.revertToState(snap);

        // The resting stake is measured, never the taking: room 20,000 at 2.10 asking for 9,500, against 10,000
        // at 1.90 asking for nothing. The leg would take 9,000 for 9,900 and leave 11,000: skipped under 5. Read
        // on the taker's 9,900, or against the taking order's 0, it would fill.
        resting = _restMin(m1, game, restingSide, 210, 20_000, 9_500);
        other = _rest(m2, game, restingSide, 200, 10_000);
        taking = _take(tk, game, takingSide, 190, 10_000);
        vm.recordLogs();
        _cross(sender, taking, _list(resting, other));
        skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "9,500 asked at 2.10, 9,000 offered: one skip record");
        _assertSkip(skips[0], resting, taking, UNDER_MIN_FILL, "9,500 asked at 2.10, 9,000 offered for 9,900");
        assertEq(_filled(resting), 0, "the resting order at 2.10 filled");
        assertEq(_filled(other), 10_000, "the resting order at 2.00 beside it fills");
        vm.revertToState(snap);

        // Zero asks for nothing: a resting order asking for nothing is taken for one lot.
        resting = _rest(m1, game, restingSide, 200, 10_000_000);
        _cross(sender, _take(tk, game, takingSide, 200, 100), _list(resting));
        assertEq(_filled(resting), 100, "a resting order asking for nothing, filled for one lot");
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 22. A short Cross commits nothing, and reverts by name.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Breaks: in OspexMatching.cross, the tail emitting Crossed and returning where it should revert; the tail
    /// reverting with no data where it should revert by name.
    function test_neverLine_aShortCrossCommitsNothing() public {
        _shortCases(Side.B);
        _shortCases(Side.A);
    }

    function _shortCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        // Three listed orders, two of which fill and one cancelled, against a taking order asking for 50,000: the
        // two fill 20,000, short. A fourth, 80,000, completes it.
        OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 200, 100_000, 50_000);
        OspexMatching.SignedOrder memory one = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory cancelled = _rest(m2, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory three = _rest(m3, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory fourth = _rest(m2, game, restingSide, 200, 80_000);
        vm.prank(m2.a);
        matching.cancelOrder(cancelled.order);
        assertTrue(matching.s_cancelledOrders(_hash(cancelled)), "the cancelled order is not marked");
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](3);
        legs[0] = _filledLeg(one, 10_000, 10_000);
        legs[1] = _skippedLeg(cancelled, CANCELLED);
        legs[2] = _filledLeg(three, 10_000, 10_000);
        bytes memory want = _short(taking, 20_000, 80_000, legs);
        OspexMatching.SignedOrder[] memory all = new OspexMatching.SignedOrder[](5);
        all[0] = taking;
        all[1] = one;
        all[2] = cancelled;
        all[3] = three;
        all[4] = fourth;
        uint256 snap = vm.snapshotState();

        // Refused by name, the refusal compared whole; every balance, every position, the market count, every
        // filled amount and the in-progress mark as before.
        bytes32 before = _print(all);
        uint256 count = markets.marketCount();
        _refused(sender, taking, _list(one, cancelled, three), want, "two legs filled, 20,000 of the 50,000 asked");
        assertEq(_print(all), before, "the short Cross left something");
        assertEq(markets.marketCount(), count, "the short Cross drew a market");
        assertEq(_filled(taking), 0, "the short Cross left the taking order a filled amount");
        assertEq(_filled(one), 0, "the short Cross left the first leg's filled amount");
        assertEq(_filled(three), 0, "the short Cross left the third leg's filled amount");
        // The mark is clean: a registration, which the mark would refuse, is taken.
        vm.prank(m1.a);
        matching.registerCourier(makeAddr("a courier registered after the short Cross"));
        // A retry with more depth fills, in the next transaction: three legs, one skip, one Cross.
        vm.recordLogs();
        _cross(sender, taking, _list4(one, cancelled, three, fourth));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, ORDER_MATCHED_TOPIC), 3, "three filled legs");
        assertEq(_count(logs, ORDER_SKIPPED_TOPIC), 1, "the one skip");
        assertEq(_count(logs, CROSSED_TOPIC), 1, "the Cross's event");
        assertEq(_filled(taking), 100_000, "the deeper Cross completes the taking order");
        assertEq(_filled(fourth), 80_000, "the fourth order");
        vm.revertToState(snap);

        // The same, in one transaction: a sender that is a contract sends the short Cross, swallows its refusal
        // and sends the deeper one. The second fills, so the mark is clean after a short revert inside the
        // transaction as well as after it.
        RetryingSender retrying = new RetryingSender();
        _register(tk.a, address(retrying));
        _register(m1.a, address(retrying));
        _register(m2.a, address(retrying));
        _register(m3.a, address(retrying));
        retrying.send(
            matching,
            abi.encodeCall(OspexMatching.cross, (taking, _list(one, cancelled, three))),
            abi.encodeCall(OspexMatching.cross, (taking, _list4(one, cancelled, three, fourth)))
        );
        assertFalse(retrying.firstFilled(), "the short Cross filled inside the transaction");
        assertEq(retrying.firstRefusal(), want, "the short Cross's refusal inside the transaction");
        assertEq(_filled(taking), 100_000, "the deeper Cross after a short one, in one transaction");
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 24. The report of a short Cross is exact.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Breaks: in OspexMatching.cross, every record written as skipped, `filled: false`; the record's `filled`
    /// read from its reason word, `filled: reason == SkipReason.NoCourier`, as a report built from the reasons
    /// array would read it; the stakes written zero on a filled record; the stakes written as the leg computed
    /// them on a skipped record; the last record left unwritten; the short refusal raised where nothing filled.
    function test_neverLine_theShortReportIsExact() public {
        _reportCases(Side.B);
        _reportCases(Side.A);
    }

    function _reportCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        Signer memory a4 = _account("no courier");
        Signer memory a5 = _account("expired");
        Signer memory a6 = _account("nothing fits");
        Signer memory a7 = _account("under its minimum");
        Signer memory a8 = _account("pull refused");
        _register(a5.a, sender);
        _register(a6.a, sender);
        _register(a7.a, sender);
        _register(a8.a, sender);
        IERC20 coin = _coin();
        uint256 snap = vm.snapshotState();

        // Nine entries, in order: fills whole; cancelled; fills; no courier; expired; the first again, now full;
        // nothing fits, 100 at 1.50, one lot paying 50; under its minimum, 10,000,000 asking for 6,000,000 against
        // the taker's last 1,000,000, 1,000,000 and 1,000,000 in hand when it skips; pull refused, its allowance
        // withdrawn. The taking order, 3,000,000 asking for 2,500,000, fills 2,000,000: short, 1,000,000 left.
        OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 200, 3_000_000, 2_500_000);
        OspexMatching.SignedOrder[] memory nine = new OspexMatching.SignedOrder[](9);
        nine[0] = _rest(m1, game, restingSide, 200, 1_000_000);
        nine[1] = _rest(m2, game, restingSide, 200, 1_000_000);
        vm.prank(m2.a);
        matching.cancelOrder(nine[1].order);
        nine[2] = _rest(m3, game, restingSide, 200, 1_000_000);
        nine[3] = _rest(a4, game, restingSide, 200, 1_000_000);
        nine[4] = _restUntil(a5, game, restingSide, 200, 1_000_000, vm.getBlockTimestamp());
        nine[5] = nine[0];
        nine[6] = _rest(a6, game, restingSide, 150, 100);
        nine[7] = _restMin(a7, game, restingSide, 200, 10_000_000, 6_000_000);
        nine[8] = _rest(a8, game, restingSide, 200, 1_000_000);
        vm.prank(a8.a);
        coin.approve(address(positions), 0);
        // The fixture, before the Cross: the states the walk is to find.
        assertTrue(matching.s_cancelledOrders(_hash(nine[1])), "the second entry is not cancelled");
        assertFalse(matching.isCourier(a4.a, sender), "the fourth entry's account registered the sender");
        assertGe(vm.getBlockTimestamp(), nine[4].order.expiry, "the fifth entry has not expired");
        assertEq(coin.allowance(a8.a, address(positions)), 0, "the ninth entry's allowance is not withdrawn");
        assertGe(coin.balanceOf(a8.a), 1_000_000, "the ninth entry's account holds no coin");

        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](9);
        legs[0] = _filledLeg(nine[0], 1_000_000, 1_000_000);
        legs[1] = _skippedLeg(nine[1], CANCELLED);
        legs[2] = _filledLeg(nine[2], 1_000_000, 1_000_000);
        legs[3] = _skippedLeg(nine[3], NO_COURIER);
        legs[4] = _skippedLeg(nine[4], EXPIRED);
        legs[5] = _skippedLeg(nine[0], NO_ROOM);
        legs[6] = _skippedLeg(nine[6], NOTHING_FITS);
        legs[7] = _skippedLeg(nine[7], UNDER_MIN_FILL);
        legs[8] = _skippedLeg(nine[8], PULL_REFUSED);
        address[] memory who = new address[](10);
        who[0] = tk.a;
        who[1] = m1.a;
        who[2] = m2.a;
        who[3] = m3.a;
        who[4] = a4.a;
        who[5] = a5.a;
        who[6] = a6.a;
        who[7] = a7.a;
        who[8] = a8.a;
        who[9] = sender;
        bytes32 before = _fingerprint(who, _hashes(nine));
        (bool ok, bytes memory err) = _tryCross(sender, taking, nine);
        assertFalse(ok, "filled: nine entries, two of them legs, short of 2,500,000");
        assertEq(err, _short(taking, 2_000_000, 1_000_000, legs), "the short refusal, whole");
        assertEq(_fingerprint(who, _hashes(nine)), before, "the short Cross left something");
        assertEq(_filled(taking), 0, "the short Cross left the taking order a filled amount");
        // And entry by entry.
        (bytes32 h, uint256 filledThisCross, uint256 minFill, uint256 room, OspexMatching.LegReport[] memory got) =
            _decodeShort(err);
        assertEq(h, _hash(taking), "the taking order's hash");
        assertEq(filledThisCross, 2_000_000, "what this Cross filled: the two legs' taking stakes");
        assertEq(minFill, 2_500_000, "the minimum asked");
        assertEq(room, 1_000_000, "the room left after the walk");
        assertEq(got.length, 9, "one record per listed occurrence");
        for (uint256 i; i < 9; ++i) {
            string memory at = string.concat("record ", vm.toString(i));
            assertEq(got[i].orderHash, legs[i].orderHash, string.concat(at, ": the hash"));
            assertEq(got[i].filled, legs[i].filled, string.concat(at, ": filled"));
            assertEq(uint8(got[i].reason), uint8(legs[i].reason), string.concat(at, ": the reason"));
            assertEq(got[i].makerRisk, legs[i].makerRisk, string.concat(at, ": the resting stake"));
            assertEq(got[i].takerRisk, legs[i].takerRisk, string.concat(at, ": the taking stake"));
        }

        // A list in which nothing fills reverts as nothing filled, with the reasons array, never as short.
        _refused(
            sender,
            taking,
            _list(nine[1], nine[3]),
            _nothingFilled(_two(CANCELLED, NO_COURIER)),
            "nothing filled: the refusal is the old one, not the short one"
        );
        // One filled and one skipped, short: the first record reads filled, not no-courier.
        (ok, err) = _tryCross(sender, taking, _list(nine[2], nine[1]));
        assertFalse(ok, "filled: one leg of 1,000,000 against 2,500,000 asked");
        (,,,, got) = _decodeShort(err);
        assertEq(got.length, 2, "two records");
        assertTrue(got[0].filled, "the first record reads skipped");
        assertEq(uint8(got[0].reason), 0, "the first record's reason word");
        assertEq(got[0].makerRisk, 1_000_000, "the first record's resting stake");
        assertEq(got[0].takerRisk, 1_000_000, "the first record's taking stake");
        assertFalse(got[1].filled, "the second record reads filled");
        assertEq(uint8(got[1].reason), CANCELLED, "the second record's reason");
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 25. The seventh reason has its place in the order: after nothing fits, before the pull; the bound on the
    //     minimum is tested before anything moves.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Breaks: in OspexMatching._leg, the minimum's check moved after the pull, into the positions call's
    /// success path; the check moved before the lot's minimum; in OspexMatching._checkSigned, the bound on the
    /// minimum deleted and made a skip at the top of OspexMatching._leg; in OspexMatching.cross, the hub copy of
    /// a skip under the minimum carrying a zero hash, caught by the test base's whole comparison of each skip's
    /// copy with its record.
    function test_neverLine_theSeventhReasonHasItsPlaceInTheOrder() public {
        // A counted expectation holds for the whole test and is set once: the coin is never asked for the stake of
        // the account under its minimum that cannot pay, in either role. The account is the one the cases make.
        vm.expectCall(
            address(_coin()),
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                makeAddr("under its minimum, cannot pay"),
                address(positions),
                uint256(10_000)
            ),
            0
        );
        _placeCases(Side.B);
        _placeCases(Side.A);
        // From here the coin is not asked at all: a refusal before the first leg pulls nothing. The game is made
        // first, since its creation fee is a pull of its own.
        uint256 game = _verifiedGame();
        vm.expectCall(address(_coin()), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        _stageACases(Side.B, game);
        _stageACases(Side.A, game);
    }

    function _placeCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        IERC20 coin = _coin();
        Signer memory c0 = _account("under its minimum, no courier");
        Signer memory c1 = _account("under its minimum, cancelled");
        Signer memory c2 = _account("under its minimum, expired");
        Signer memory c3 = _account("under its minimum, full");
        Signer memory c4 = _account("under its minimum, nothing fits");
        Signer memory c5 = _account("under its minimum, cannot pay");
        Signer memory c6 = _account("at its minimum, cannot pay");
        _register(c1.a, sender);
        _register(c2.a, sender);
        _register(c3.a, sender);
        _register(c4.a, sender);
        _register(c5.a, sender);
        _register(c6.a, sender);
        uint256 snap = vm.snapshotState();

        // The first five reasons come first. A taking order of 10,000 at 1.90; the first leg, at 2.07, takes
        // 9,300 for 9,951 and leaves 49, so nothing fits any later leg and the minimum's check is never reached:
        // each of the five, asking for its whole stake, is recorded under its earlier reason, 0 to 4.
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 190, 10_000);
        OspexMatching.SignedOrder memory first = _rest(m1, game, restingSide, 207, 10_000);
        OspexMatching.SignedOrder[] memory six = new OspexMatching.SignedOrder[](6);
        six[0] = first;
        six[1] = _restMin(c0, game, restingSide, 200, 10_000, 10_000);
        six[2] = _restMin(c1, game, restingSide, 200, 10_000, 10_000);
        vm.prank(c1.a);
        matching.cancelOrder(six[2].order);
        six[3] = _signed(
            _order(
                c2.a, game, address(moneyline), 0, restingSide, 200, 10_000, nextNonce++, vm.getBlockTimestamp(), 10_000
            ),
            c2.key
        );
        six[4] = _restMin(c3, game, restingSide, 200, 10_000, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(six[4]));
        assertEq(_filled(six[4]), 10_000, "the full one is not full");
        six[5] = _restMin(c4, game, restingSide, 150, 10_000, 10_000);
        vm.recordLogs();
        _cross(sender, taking, six);
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(_filled(taking), 9_951, "the first leg: 93 lots at 2.07, leaving 49");
        assertEq(_filled(first), 9_300, "the first leg's resting stake");
        assertEq(skips.length, 5, "five skip records");
        for (uint8 reason; reason < 5; ++reason) {
            _assertSkip(
                skips[reason],
                six[reason + 1],
                taking,
                reason,
                string.concat("under its minimum, and in the state of reason ", vm.toString(reason))
            );
        }
        vm.revertToState(snap);

        // With room to reach the check: under its minimum and unable to pay records 5, and the coin is not asked
        // for that account's stake (the expectation set in the test); at its minimum and unable to pay, the pull
        // is made and refused, 6.
        OspexMatching.SignedOrder memory under = _restMin(c5, game, restingSide, 200, 20_000, 15_000);
        OspexMatching.SignedOrder memory refused = _restMin(c6, game, restingSide, 200, 10_000, 10_000);
        vm.prank(c5.a);
        coin.approve(address(positions), 0);
        vm.prank(c6.a);
        coin.approve(address(positions), 0);
        assertEq(coin.allowance(c5.a, address(positions)), 0, "the fifth's allowance is not withdrawn");
        assertEq(coin.allowance(c6.a, address(positions)), 0, "the sixth's allowance is not withdrawn");
        assertEq(c5.a, makeAddr("under its minimum, cannot pay"), "the fifth is not the account the test names");
        taking = _take(tk, game, takingSide, 200, 10_000);
        OspexMatching.SignedOrder memory filler = _rest(m2, game, restingSide, 200, 10_000);
        vm.recordLogs();
        _cross(sender, taking, _list(under, refused, filler));
        skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 2, "two skip records");
        _assertSkip(skips[0], under, taking, UNDER_MIN_FILL, "under its minimum, from an account that cannot pay");
        _assertSkip(skips[1], refused, taking, PULL_REFUSED, "at its minimum, from an account that cannot pay");
        assertEq(_filled(under), 0, "the order under its minimum filled");
        assertEq(_filled(refused), 0, "the order whose pull was refused filled");
        assertEq(_filled(filler), 10_000, "the order beside them");
        assertEq(_filled(taking), 10_000, "the taking order");
        vm.revertToState(snap);
    }

    /// @dev A later resting entry asking for more than its stake, cancelled too, refuses the whole Cross by the
    ///      bound's name with its hash and both numbers, before the first leg: nothing moves and nothing is
    ///      pulled. The taking order asking for more than its stake is refused the same way.
    function _stageACases(Side takingSide, uint256 game) internal {
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        OspexMatching.SignedOrder memory good = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory bad = _restMin(m2, game, restingSide, 200, 10_000, 10_001);
        vm.prank(m2.a);
        matching.cancelOrder(bad.order);
        bytes32 before = _print(_list(taking, good, bad));
        _refused(
            sender,
            taking,
            _list(good, bad),
            _aboveStake(bad),
            "a later resting entry asking for 10,001 of its 10,000, cancelled too"
        );
        assertEq(_print(_list(taking, good, bad)), before, "the refused Cross left something");
        assertEq(_filled(good), 0, "the leg before the refused entry filled");
        OspexMatching.SignedOrder memory badTaking = _takeMin(tk, game, takingSide, 200, 10_000, 10_001);
        _refused(
            sender, badTaking, _list(good), _aboveStake(badTaking), "a taking order asking for 10,001 of its 10,000"
        );
        assertEq(_filled(good), 0, "the leg of the refused taking order filled");
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 26. The minimum holds at its boundaries: at equal, one under and one over.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Breaks: in OspexMatching.cross, the tail's `<` made `<=`; its `>=` made `>`; its `LOT` made `LOT + 1`; in
    /// OspexMatching._leg, the resting check's `<` made `<=`; its `>=` made `>`; in OspexMatching._checkSigned,
    /// the bound's `>` made `>=`.
    function test_neverLine_theMinimumHoldsAtItsBoundaries() public {
        _boundaryCases(Side.B);
        _boundaryCases(Side.A);
    }

    function _boundaryCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        uint256 snap = vm.snapshotState();

        // The taking fill: 5,000 filled with room left, asking for 4,999, 5,000 and 5,001: fills, fills, short.
        uint256[3] memory asks = [uint256(4_999), 5_000, 5_001];
        for (uint256 i; i < 3; ++i) {
            OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 200, 10_000, asks[i]);
            OspexMatching.SignedOrder memory resting = _rest(m1, game, restingSide, 200, 5_000);
            string memory what = string.concat("5,000 filled, asking for ", vm.toString(asks[i]));
            if (i < 2) {
                _cross(sender, taking, _list(resting));
                assertEq(_filled(taking), 5_000, what);
            } else {
                legs[0] = _filledLeg(resting, 5_000, 5_000);
                _refused(sender, taking, _list(resting), _short(taking, 5_000, 5_000, legs), what);
            }
        }
        vm.revertToState(snap);

        // The taking room, the whole stake asked, ample resting room: 200 at 2.01 fills 101 and leaves 99,
        // complete; 300 at 3.00 fills 200 and leaves 100, short; 300 at 2.99 fills 199 and leaves 101, short.
        OspexMatching.SignedOrder memory whole = _takeMin(tk, game, takingSide, 101, 200, 200);
        OspexMatching.SignedOrder memory ample = _rest(m1, game, restingSide, 201, 100_000);
        _cross(sender, whole, _list(ample));
        assertEq(_filled(whole), 101, "200 asked whole, at 2.01: 101 filled, 99 left, complete");
        assertEq(_filled(ample), 100, "one lot at 2.01");
        whole = _takeMin(tk, game, takingSide, 101, 300, 300);
        ample = _rest(m1, game, restingSide, 300, 100_000);
        legs[0] = _filledLeg(ample, 100, 200);
        _refused(
            sender, whole, _list(ample), _short(whole, 200, 100, legs), "300 asked whole, at 3.00: 200 filled, 100 left"
        );
        whole = _takeMin(tk, game, takingSide, 101, 300, 300);
        ample = _rest(m1, game, restingSide, 299, 100_000);
        legs[0] = _filledLeg(ample, 100, 199);
        _refused(
            sender, whole, _list(ample), _short(whole, 199, 101, legs), "300 asked whole, at 2.99: 199 filled, 101 left"
        );
        vm.revertToState(snap);

        // The resting fill: asking for 5,000 with ample room, against 4,900, 5,000 and 5,100: skipped, fills,
        // fills.
        uint256[3] memory stakes = [uint256(4_900), 5_000, 5_100];
        for (uint256 i; i < 3; ++i) {
            OspexMatching.SignedOrder memory resting = _restMin(m1, game, restingSide, 200, 100_000, 5_000);
            OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, stakes[i]);
            string memory what = string.concat("asking for 5,000, offered ", vm.toString(stakes[i]));
            if (i == 0) {
                _refused(sender, taking, _list(resting), _nothingFilled(_reasons(UNDER_MIN_FILL)), what);
            } else {
                _cross(sender, taking, _list(resting));
                assertEq(_filled(resting), stakes[i], what);
            }
        }
        vm.revertToState(snap);

        // The resting room, which need not be lot-aligned once the order has taken: three orders signed for
        // 10,000 asking for 2,100, each first a taker at 2.00 against a maker at 1.01 with room 790,100, 790,000
        // and 789,900, filling 7,901, 7,900 and 7,899 and leaving 2,099, 2,100 and 2,101; each then rests against
        // a taker of 2,000 at 2.00, whose leg is under 2,100 and leaves 99, 100 and 101: fills, skipped, skipped.
        Signer memory tk2 = _account("second taking account");
        _register(tk2.a, sender);
        Signer[3] memory makers = [m1, m2, m3];
        uint256[3] memory rooms = [uint256(790_100), 790_000, 789_900];
        uint256[3] memory lefts = [uint256(2_099), 2_100, 2_101];
        for (uint256 i; i < 3; ++i) {
            OspexMatching.SignedOrder memory dual = _takeMin(tk, game, takingSide, 200, 10_000, 2_100);
            _cross(sender, dual, _list(_rest(makers[i], game, restingSide, 101, rooms[i])));
            assertEq(_filled(dual), 10_000 - lefts[i], string.concat("taken at 1.01, leaving ", vm.toString(lefts[i])));
            OspexMatching.SignedOrder memory nibble = _take(tk2, game, restingSide, 200, 2_000);
            string memory what = string.concat("asking for 2,100 with ", vm.toString(lefts[i]), " left, offered 2,000");
            if (i == 0) {
                _cross(sender, nibble, _list(dual));
                assertEq(_filled(dual), 10_000 - lefts[i] + 2_000, what);
            } else {
                _refused(sender, nibble, _list(dual), _nothingFilled(_reasons(UNDER_MIN_FILL)), what);
            }
        }
        vm.revertToState(snap);

        // The bound at the signature checks: a minimum equal to the stake is accepted and one unit over refused,
        // with the two numbers, in either role.
        OspexMatching.SignedOrder memory atStake = _restMin(m1, game, restingSide, 200, 10_000, 10_000);
        _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(atStake));
        assertEq(_filled(atStake), 10_000, "a resting order asking for its whole stake");
        OspexMatching.SignedOrder memory over = _restMin(m1, game, restingSide, 200, 10_000, 10_001);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 10_000),
            _list(over),
            _aboveStake(over),
            "a resting order asking for one unit over its stake"
        );
        atStake = _takeMin(tk, game, takingSide, 200, 10_000, 10_000);
        _cross(sender, atStake, _list(_rest(m1, game, restingSide, 200, 10_000)));
        assertEq(_filled(atStake), 10_000, "a taking order asking for its whole stake");
        over = _takeMin(tk, game, takingSide, 200, 10_000, 10_001);
        _refused(
            sender,
            over,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            _aboveStake(over),
            "a taking order asking for one unit over its stake"
        );
        vm.revertToState(snap);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The rules beside the never-lines: duplicates and roles, and the events.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// A minimum across a Cross, across Crosses and across a duplicate listing: a resting order listed twice
    /// fills once and its second occurrence finds the taker without room; a taking order's minimum is met Cross
    /// by Cross, a short Cross leaving its filled amount as it was; a resting order's remainder under its minimum
    /// is taken whole.
    /// Break: in OspexMatching._leg, the resting check reading the room from the signed stake,
    /// `r.riskAmount - makerRisk`, in place of the room left.
    function test_minFill_aMinimumAcrossDuplicatesAndRoles() public {
        _dupCases(Side.B);
        _dupCases(Side.A);
    }

    function _dupCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        uint256 snap = vm.snapshotState();

        // Listed twice: 10 USDC asking for 4 USDC, twice, against 6 USDC. The first occurrence fills 6 USDC; the
        // second finds the taker with no room, and nothing fits.
        OspexMatching.SignedOrder memory twice = _restMin(m1, game, restingSide, 200, 10_000_000, 4_000_000);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 6_000_000);
        vm.recordLogs();
        _cross(sender, taking, _list(twice, twice));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip record for the second occurrence");
        _assertSkip(skips[0], twice, taking, NOTHING_FITS, "the second occurrence, the taker without room");
        assertEq(_filled(twice), 6_000_000, "the order listed twice filled once");
        assertEq(_filled(taking), 6_000_000, "the taking order");
        vm.revertToState(snap);

        // Across Crosses: 10 USDC asking for 3 USDC fills 3 USDC in one Cross; a second against 2 USDC is short,
        // and its filled amount still reads 3 USDC after the revert; a third against 7 USDC completes it.
        taking = _takeMin(tk, game, takingSide, 200, 10_000_000, 3_000_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 3_000_000)));
        assertEq(_filled(taking), 3_000_000, "3 USDC asked, 3 USDC filled");
        OspexMatching.SignedOrder memory two = _rest(m2, game, restingSide, 200, 2_000_000);
        legs[0] = _filledLeg(two, 2_000_000, 2_000_000);
        _refused(sender, taking, _list(two), _short(taking, 2_000_000, 5_000_000, legs), "2 USDC in a second Cross");
        assertEq(_filled(taking), 3_000_000, "the filled amount after the short Cross");
        _cross(sender, taking, _list(_rest(m3, game, restingSide, 200, 7_000_000)));
        assertEq(_filled(taking), 10_000_000, "7 USDC in a third Cross completes it");
        vm.revertToState(snap);

        // A remainder under its minimum, taken whole: 10 USDC asking for 4,000,100, 6 USDC filled, is taken for
        // its last 4,000,000 in a later Cross.
        OspexMatching.SignedOrder memory rest = _restMin(m1, game, restingSide, 200, 10_000_000, 4_000_100);
        _cross(sender, _take(tk, game, takingSide, 200, 6_000_000), _list(rest));
        assertEq(_filled(rest), 6_000_000, "6 USDC of the 10 asking for 4,000,100");
        _cross(sender, _take(tk, game, takingSide, 200, 4_000_000), _list(rest));
        assertEq(_filled(rest), 10_000_000, "the last 4,000,000, under 4,000,100, taken whole");
        vm.revertToState(snap);
    }

    /// The fill event carries the resting order's minimum, last, and its hub copy the same word; the cancel
    /// event carries the cancelled order's minimum, last, and its hub copy the same word.
    /// Breaks: in OspexMatching._emitMatched, the last word emitted as the taking order's minimum, in the event
    /// and its hub copy; the hub copy's last word left zero; in OspexMatching.cancelOrder, the event's minimum
    /// emitted as zero.
    function test_minFill_theEventsCarryTheOrdersOwnMinimum() public {
        _eventCases(Side.B);
        _eventCases(Side.A);
    }

    function _eventCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();

        // A resting order asking for 1,200 against a taking order asking for 5,600, both met: the fill event's
        // last word is 1,200, the resting order's, and so is its hub copy's.
        OspexMatching.SignedOrder memory resting = _restMin(m1, game, restingSide, 200, 10_000, 1_200);
        OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 200, 10_000, 5_600);
        vm.recordLogs();
        _cross(sender, taking, _list(resting));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        bytes memory data = abi.encode(
            game,
            market,
            address(moneyline),
            int32(0),
            restingSide,
            uint16(200),
            uint256(10_000),
            uint256(10_000),
            uint256(10_000),
            resting.order.nonce,
            resting.order.expiry,
            uint256(1_200)
        );
        bytes memory payload = bytes.concat(abi.encode(_hash(resting), m1.a, tk.a), data);
        bool seenEvent;
        bool seenHub;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(matching) && logs[i].topics[0] == ORDER_MATCHED_TOPIC) {
                assertEq(logs[i].topics[1], _hash(resting), "OrderMatched: the order's hash");
                assertEq(logs[i].topics[2], _word(m1.a), "OrderMatched: the maker");
                assertEq(logs[i].topics[3], _word(tk.a), "OrderMatched: the taker");
                assertEq(logs[i].data, data, "OrderMatched, whole");
                assertEq(_lastWord(logs[i].data), 1_200, "OrderMatched's last word is not the resting order's minimum");
                seenEvent = true;
            }
            if (
                logs[i].emitter == address(core) && logs[i].topics.length == 3
                    && logs[i].topics[1] == matching.EVENT_ORDER_MATCHED()
            ) {
                bytes memory copy = abi.decode(logs[i].data, (bytes));
                assertEq(copy, payload, "the hub copy of OrderMatched, whole");
                assertEq(_lastWord(copy), 1_200, "the hub copy's last word is not the resting order's minimum");
                seenHub = true;
            }
        }
        assertTrue(seenEvent, "no OrderMatched");
        assertTrue(seenHub, "no hub copy of OrderMatched");
        assertEq(_filled(taking), 10_000, "the fill");

        // A cancel of an order asking for 4,300: the event's tenth word, the minimum, with the sender after it,
        // and its hub copy's.
        OspexMatching.SignedOrder memory toCancel = _restMin(m2, game, restingSide, 200, 10_000, 4_300);
        OspexMatching.OspexOrder memory o = toCancel.order;
        vm.recordLogs();
        vm.prank(m2.a);
        matching.cancelOrder(o);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the cancel's two logs");
        data = abi.encode(
            o.gameId,
            o.scorer,
            o.lineTicks,
            o.positionType,
            o.oddsTick,
            o.riskAmount,
            o.nonce,
            o.expiry,
            o.minFill,
            m2.a
        );
        assertEq(logs[0].emitter, address(matching), "OrderCancelled: the emitter");
        assertEq(
            logs[0].topics[0],
            keccak256(
                "OrderCancelled(bytes32,address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256,address)"
            ),
            "OrderCancelled: the first topic"
        );
        assertEq(logs[0].topics[1], _hash(toCancel), "OrderCancelled: the hash");
        assertEq(logs[0].topics[2], _word(m2.a), "OrderCancelled: the account");
        assertEq(logs[0].data, data, "OrderCancelled, whole");
        assertEq(_wordBeforeLast(logs[0].data), 4_300, "OrderCancelled's tenth word is not the order's minimum");
        assertEq(_lastWord(logs[0].data), uint256(uint160(m2.a)), "OrderCancelled's last word is not the sender");
        assertEq(logs[1].emitter, address(core), "the hub copy's emitter");
        assertEq(logs[1].topics[1], matching.EVENT_ORDER_CANCELLED(), "the hub copy's tag");
        bytes memory cancelPayload = abi.decode(logs[1].data, (bytes));
        assertEq(
            cancelPayload,
            bytes.concat(abi.encode(_hash(toCancel), m2.a), data),
            "the hub copy of OrderCancelled, whole"
        );
        assertEq(_wordBeforeLast(cancelPayload), 4_300, "the hub copy's tenth word is not the order's minimum");
        assertEq(_lastWord(cancelPayload), uint256(uint160(m2.a)), "the hub copy's last word is not the sender");
        vm.revertToState(snap);
    }

    /// @dev The word before the last of an ABI-encoded payload.
    function _wordBeforeLast(bytes memory data) internal pure returns (uint256 w) {
        require(data.length >= 64, "no two words");
        assembly ("memory-safe") {
            w := mload(add(add(data, 0x20), sub(mload(data), 0x40)))
        }
    }
}

/// @notice Never-line 23, the field in the hash, in a contract of its own. Compiled as one contract with the
///         six tests above, this file's via-IR compile ran past two hours here before it was stopped; as two
///         contracts the file compiles in about two minutes. Same base, same lift, two of the accounts.
contract OspexMinFillHashTest is CrossBase {
    Signer internal tk;
    Signer internal m1;

    function setUp() public override {
        super.setUp();
        tk = _account("taking account");
        m1 = _account("resting one");
        _register(tk.a, sender);
        _register(m1.a, sender);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 23. The minimum fill is in the hash.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The type this build replaced, nine fields: what a signer that did not add the field would sign under.
    string internal constant NINE_FIELD_TYPE =
        "OspexOrder(address account,uint256 gameId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry)";

    /// @dev An order's digest under the nine-field type, the same nine values, this set's domain.
    function _nineFieldDigest(OspexMatching.OspexOrder memory o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(NINE_FIELD_TYPE)),
                o.account,
                o.gameId,
                o.scorer,
                o.lineTicks,
                uint8(o.positionType),
                o.oddsTick,
                o.riskAmount,
                o.nonce,
                o.expiry
            )
        );
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(address(matching)), structHash));
    }

    /// Breaks: in OspexMatching._hashOrder, drop `order.minFill` from the encode; hash it in lots,
    /// `order.minFill / LOT`, under which 100 and 150 are one hash; hash it as a flag, `order.minFill > 0`,
    /// under which 1 and 10,000 are one hash. Each also fails the equality with the digest built here.
    function test_neverLine_minFillIsInTheHash() public {
        _hashCases(Side.B);
        _hashCases(Side.A);
    }

    function _hashCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();

        // A signature over the nine-field type, the same nine values, the same account, domain and contract, is
        // refused in either role, asking for nothing and asking for 5,000: the digest differs. The same two orders
        // under the ten-field type fill.
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        OspexMatching.SignedOrder memory resting = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory asking = _restMin(m1, game, restingSide, 200, 10_000, 5_000);
        bytes4 bad = OspexMatching.OspexMatching__BadSignature.selector;
        _refused(
            sender,
            OspexMatching.SignedOrder({
                order: taking.order, signature: _signature(tk.key, _nineFieldDigest(taking.order))
            }),
            _list(resting),
            _refusal(bad, taking),
            "signed under the nine-field type, the taking order"
        );
        _refused(
            sender,
            taking,
            _list(
                OspexMatching.SignedOrder({
                    order: resting.order, signature: _signature(m1.key, _nineFieldDigest(resting.order))
                })
            ),
            _refusal(bad, resting),
            "signed under the nine-field type, a resting order"
        );
        _refused(
            sender,
            taking,
            _list(
                OspexMatching.SignedOrder({
                    order: asking.order, signature: _signature(m1.key, _nineFieldDigest(asking.order))
                })
            ),
            _refusal(bad, asking),
            "signed under the nine-field type, a resting order asking for 5,000"
        );
        _cross(sender, taking, _list(resting));
        assertEq(_filled(taking), 10_000, "the same two orders under the ten-field type");
        vm.revertToState(snap);

        // Six orders alike but for the minimum, 0, 1, 100, 150, 10,000 and the stake: the contract's hash of each
        // is the eleven-word digest built here, order by order, and the six are six hashes.
        uint256[6] memory minima = [uint256(0), 1, 100, 150, 10_000, 10_000_000];
        OspexMatching.SignedOrder[6] memory six;
        bytes32[6] memory hashes;
        for (uint256 i; i < 6; ++i) {
            six[i] = _signed(
                _order(
                    m1.a,
                    game,
                    address(moneyline),
                    0,
                    restingSide,
                    200,
                    10_000_000,
                    77,
                    vm.getBlockTimestamp() + 1 days,
                    minima[i]
                ),
                m1.key
            );
            hashes[i] = matching.getOrderHash(six[i].order);
            assertEq(
                hashes[i],
                _digest(six[i].order),
                string.concat("the contract's hash of the order asking for ", vm.toString(minima[i]))
            );
            for (uint256 j; j < i; ++j) {
                assertTrue(
                    hashes[i] != hashes[j],
                    string.concat("one hash for ", vm.toString(minima[j]), " and ", vm.toString(minima[i]))
                );
            }
        }
        // The pairs: 100 and 150, one hash if the field were hashed in lots; 1 and 10,000, one hash if it were
        // hashed as a flag. Each pair is executed both ways.
        _pairCases(game, takingSide, six[2], six[3]);
        _pairCases(game, takingSide, six[3], six[2]);
        _pairCases(game, takingSide, six[1], six[4]);
        _pairCases(game, takingSide, six[4], six[1]);
        vm.revertToState(snap);
    }

    /// @dev Two orders alike but for the minimum: cancelling `a` leaves `b` fillable, filling `b` leaves `a`'s
    ///      filled amount zero, and the two records differ by hash.
    function _pairCases(
        uint256 game,
        Side takingSide,
        OspexMatching.SignedOrder memory a,
        OspexMatching.SignedOrder memory b
    ) internal {
        uint256 snap = vm.snapshotState();
        string memory pair =
            string.concat("asking for ", vm.toString(a.order.minFill), " and ", vm.toString(b.order.minFill));
        vm.prank(m1.a);
        matching.cancelOrder(a.order);
        assertTrue(matching.s_cancelledOrders(_hash(a)), string.concat(pair, ": the cancelled one is not marked"));
        assertFalse(matching.s_cancelledOrders(_hash(b)), string.concat(pair, ": the other is marked"));
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 20_000);
        _cross(sender, taking, _list(b));
        assertEq(matching.s_filledRisk(_hash(b)), 20_000, string.concat(pair, ": the other did not fill"));
        assertEq(matching.s_filledRisk(_hash(a)), 0, string.concat(pair, ": the cancelled one filled"));
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 20_000),
            _list(a),
            _nothingFilled(_reasons(CANCELLED)),
            string.concat(pair, ": the cancelled one")
        );
        vm.revertToState(snap);
    }
}

/// @notice The minimum in the shapes the tests above do not reach, each in both roles: a price under 2.00, where
///         the taking stake of a leg is the smaller; a resting minimum one unit off; a resting order whose room is
///         already under its minimum; a taking order with a fill behind it whose room is under its minimum; the
///         Cross's own event after skips under reasons 5 and 6, on an order with a fill behind it; and the rule
///         with the taking account as the sender and as the origin, with code at an account, on the total and the
///         spread, with one account on both sides, through a contract sender, with thirty seconds to live, and
///         above thirty-two bits. The independent pass wrote one mutant per shape; each is a break of this test.
contract OspexMinFillShapesTest is CrossBase {
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
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m2.a, sender);
        _register(m3.a, sender);
    }

    /// @dev The bound's refusal: the order's hash and the two numbers.
    function _aboveStake(OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            OspexMatching.OspexMatching__MinFillAboveStake.selector, _hash(s), s.order.minFill, s.order.riskAmount
        );
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev A taking order with a minimum on any market of the game, thirty seconds to its expiry, signed.
    function _takeMinOn(
        Signer memory t,
        uint256 game,
        address scorer,
        int32 line,
        Side side,
        uint256 tick,
        uint256 risk,
        uint256 minFill
    ) internal returns (OspexMatching.SignedOrder memory) {
        uint256 expiry = vm.getBlockTimestamp() + 30;
        return _signed(_order(t.a, game, scorer, line, side, _tick(tick), risk, nextNonce++, expiry, minFill), t.key);
    }

    /// @dev A resting order with a minimum on any market of the game, live for a day, signed.
    function _restMinOn(
        Signer memory m,
        uint256 game,
        address scorer,
        int32 line,
        Side side,
        uint256 tick,
        uint256 risk,
        uint256 minFill
    ) internal returns (OspexMatching.SignedOrder memory) {
        uint256 expiry = vm.getBlockTimestamp() + 1 days;
        return _signed(_order(m.a, game, scorer, line, side, _tick(tick), risk, nextNonce++, expiry, minFill), m.key);
    }

    /// @dev A refusal, with the transaction's origin named.
    function _refusedAs(
        address from,
        address origin,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        bytes memory want,
        string memory what
    ) internal {
        (bool ok, bytes memory err) = _tryCrossAs(from, origin, taking, resting);
        assertFalse(ok, string.concat("filled: ", what));
        assertEq(err, want, what);
    }

    /// @dev The Cross's own event among a call's logs, once, and its hub copy once: the sender, the taking order
    ///      and its account, the market, and the two totals, which are returned.
    function _crossed(Vm.Log[] memory logs, address from, OspexMatching.SignedOrder memory taking, uint256 market)
        internal
        view
        returns (uint256 makerTotal, uint256 takerTotal)
    {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(matching) || logs[i].topics[0] != CROSSED_TOPIC) continue;
            ++seen;
            assertEq(logs[i].topics[1], _word(from), "Crossed: the sender");
            assertEq(logs[i].topics[2], _hash(taking), "Crossed: the taking order");
            assertEq(logs[i].topics[3], _word(taking.order.account), "Crossed: the taking account");
            uint256 m;
            (m, makerTotal, takerTotal) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(m, market, "Crossed: the market");
        }
        assertEq(seen, 1, "Crossed, once");
        bytes32 tag = matching.EVENT_CROSSED();
        seen = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics.length != 3 || logs[i].topics[1] != tag) continue;
            ++seen;
            bytes memory payload = abi.decode(logs[i].data, (bytes));
            assertEq(
                payload,
                abi.encode(from, _hash(taking), taking.order.account, market, makerTotal, takerTotal),
                "Crossed: the hub copy"
            );
        }
        assertEq(seen, 1, "Crossed: the hub's copies, once");
    }

    /// Breaks: the independent pass's mutants of OspexMatching, each named by this test in battery.json: the tail
    /// or the resting check waived for the taking account as the sender or the origin, for an account or a sender
    /// with code, off the zero line, for a resting account that is the taking account, with the cap in force, within
    /// thirty seconds of expiry, or compared in thirty-two bits or in whole lots; the tail waived once the room
    /// before the walk is under the minimum, or firing only with both totals under it; the short refusal carrying
    /// the larger total; a filled record's stakes written the smaller first; the resting check reading the room
    /// against the minimum; and the Cross's event tallying a skipped leg's stake, a refused pull's stake, or the
    /// taking order's whole filled amount.
    function test_minFill_theMinimumHoldsInEveryShape() public {
        _shapeCases(Side.B);
        _shapeCases(Side.A);
    }

    function _shapeCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        uint256 snap = vm.snapshotState();

        // Under 2.00 the taking stake of a leg is the smaller: 10,000 at 2.90 against 5,000 at 1.50 is fifty lots,
        // 5,000 of resting stake for 2,500 of taking stake. Asking for 2,501 is short, with the taking total and
        // the record's two stakes in their order; asking for 2,500 fills.
        OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 290, 10_000, 2_501);
        OspexMatching.SignedOrder memory resting = _rest(m1, game, restingSide, 150, 5_000);
        legs[0] = _filledLeg(resting, 5_000, 2_500);
        _refused(
            sender, taking, _list(resting), _short(taking, 2_500, 7_500, legs), "asking for 2,501 at 2.90 against 1.50"
        );
        taking = _takeMin(tk, game, takingSide, 290, 10_000, 2_500);
        _cross(sender, taking, _list(resting));
        assertEq(_filled(taking), 2_500, "asking for 2,500 at 2.90 against 1.50: the taking stake");
        assertEq(_filled(resting), 5_000, "asking for 2,500 at 2.90 against 1.50: the resting stake");
        vm.revertToState(snap);

        // And the resting minimum is measured on the resting stake alone: 100,000 at 1.50 asking for 15,000,
        // taken by 10,000 at 2.90, is two hundred lots, 20,000 of resting stake for 10,000 of taking stake, and it
        // fills though the taking stake is under the minimum. Asking for 20,001 is skipped.
        resting = _restMin(m1, game, restingSide, 150, 100_000, 15_000);
        taking = _take(tk, game, takingSide, 290, 10_000);
        _cross(sender, taking, _list(resting));
        assertEq(_filled(resting), 20_000, "asking for 15,000 at 1.50, taken for 20,000");
        assertEq(_filled(taking), 10_000, "the taking stake at 2.90");
        resting = _restMin(m1, game, restingSide, 150, 100_000, 20_001);
        _refused(
            sender,
            _take(tk, game, takingSide, 290, 10_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "asking for 20,001 at 1.50, offered 20,000"
        );
        vm.revertToState(snap);

        // The resting minimum is in units, not lots: asking for 5,001, offered 5,000, is skipped; asking for 4,999
        // fills.
        resting = _restMin(m1, game, restingSide, 200, 100_000, 5_001);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 5_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "asking for 5,001, offered 5,000"
        );
        resting = _restMin(m1, game, restingSide, 200, 100_000, 4_999);
        _cross(sender, _take(tk, game, takingSide, 200, 5_000), _list(resting));
        assertEq(_filled(resting), 5_000, "asking for 4,999, offered 5,000");
        vm.revertToState(snap);

        // A resting order whose room is already under its minimum: 10,000 asking for 4,100, filled 6,000, has
        // 4,000 left. A leg of 2,000 is skipped, since a lot or more would be left; a leg of 4,000 takes all of it.
        resting = _restMin(m1, game, restingSide, 200, 10_000, 4_100);
        _cross(sender, _take(tk, game, takingSide, 200, 6_000), _list(resting));
        assertEq(_filled(resting), 6_000, "the first fill of the order asking for 4,100");
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 2_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "2,000 of the 4,000 left, under a minimum of 4,100"
        );
        _cross(sender, _take(tk, game, takingSide, 200, 4_000), _list(resting));
        assertEq(_filled(resting), 10_000, "all 4,000 left, under a minimum of 4,100");
        vm.revertToState(snap);

        // A taking order whose room is already under its minimum: 10,000 asking for 3,000, filled 8,000, has 2,000
        // left. A Cross filling 1,000 is short, since a lot would be left; one filling 2,000 completes it.
        taking = _takeMin(tk, game, takingSide, 200, 10_000, 3_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 8_000)));
        assertEq(_filled(taking), 8_000, "the first fill of the order asking for 3,000");
        resting = _rest(m2, game, restingSide, 200, 1_000);
        legs[0] = _filledLeg(resting, 1_000, 1_000);
        _refused(
            sender,
            taking,
            _list(resting),
            _short(taking, 1_000, 1_000, legs),
            "1,000 of the 2,000 left, under a minimum of 3,000"
        );
        _cross(sender, taking, _list(_rest(m2, game, restingSide, 200, 2_000)));
        assertEq(_filled(taking), 10_000, "all 2,000 left, under a minimum of 3,000");
        vm.revertToState(snap);

        // The Cross's own event carries this Cross's totals of the filled legs alone. On a taking order that
        // filled 3,000 before, a Cross with a leg skipped under its minimum, a leg whose pull is refused and a leg
        // of 7,000 that fills reports 7,000 and 7,000, in the core's event and in the hub's copy.
        taking = _take(tk, game, takingSide, 200, 10_000);
        _cross(sender, taking, _list(_rest(m1, game, restingSide, 200, 3_000)));
        OspexMatching.SignedOrder memory under = _restMin(m2, game, restingSide, 200, 20_000, 15_000);
        OspexMatching.SignedOrder memory refused = _rest(m3, game, restingSide, 200, 10_000);
        IERC20 coin = _coin();
        vm.prank(m3.a);
        coin.approve(address(positions), 0);
        assertEq(coin.allowance(m3.a, address(positions)), 0, "the third's allowance is not withdrawn");
        OspexMatching.SignedOrder memory filler = _rest(m1, game, restingSide, 200, 7_000);
        vm.recordLogs();
        _cross(sender, taking, _list(under, refused, filler));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Skip[] memory skips = _skips(logs);
        assertEq(skips.length, 2, "two skip records");
        _assertSkip(skips[0], under, taking, UNDER_MIN_FILL, "under its minimum");
        _assertSkip(skips[1], refused, taking, PULL_REFUSED, "its pull refused");
        (uint256 makerTotal, uint256 takerTotal) =
            _crossed(logs, sender, taking, markets.getMarketId(game, address(moneyline), 0));
        assertEq(makerTotal, 7_000, "Crossed: this Cross's resting total");
        assertEq(takerTotal, 7_000, "Crossed: this Cross's taking total");
        assertEq(_filled(taking), 10_000, "the taking order, filled in two Crosses");
        vm.revertToState(snap);

        // The taking account as the sender: it registers itself, and the resting account registers it. Its order
        // asking for 6,000 against 5,000 is short; asking for more than its stake, it is refused by the bound. The
        // same, with the taking account as the origin and another sender.
        _register(tk.a, tk.a);
        _register(m1.a, tk.a);
        resting = _rest(m1, game, restingSide, 200, 5_000);
        taking = _takeMin(tk, game, takingSide, 200, 10_000, 6_000);
        legs[0] = _filledLeg(resting, 5_000, 5_000);
        _refused(tk.a, taking, _list(resting), _short(taking, 5_000, 5_000, legs), "short, sent by the taking account");
        taking = _takeMin(tk, game, takingSide, 200, 10_000, 10_001);
        _refused(tk.a, taking, _list(resting), _aboveStake(taking), "asking for 10,001 of 10,000, sent by its account");
        taking = _takeMin(tk, game, takingSide, 200, 10_000, 6_000);
        _refusedAs(
            sender,
            tk.a,
            taking,
            _list(resting),
            _short(taking, 5_000, 5_000, legs),
            "short, with the taking account as the origin"
        );
        // The resting account as the sender: its order under its minimum is skipped, and asking for more than its
        // stake it is refused by the bound.
        _register(m1.a, m1.a);
        _register(tk.a, m1.a);
        resting = _restMin(m1, game, restingSide, 200, 100_000, 5_000);
        _refused(
            m1.a,
            _take(tk, game, takingSide, 200, 4_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, sent by the resting account"
        );
        resting = _restMin(m1, game, restingSide, 200, 10_000, 10_001);
        _refused(
            m1.a,
            _take(tk, game, takingSide, 200, 4_000),
            _list(resting),
            _aboveStake(resting),
            "a resting order asking for 10,001 of 10,000, sent by its account"
        );
        vm.revertToState(snap);

        // An account with code, as the taking account and as the resting account: held to its minimum and to the
        // bound like any other.
        Signer memory coded = _account("account with code");
        vm.etch(coded.a, address(new CallbackAccount()).code);
        _register(coded.a, sender);
        resting = _rest(m1, game, restingSide, 200, 5_000);
        taking = _takeMin(coded, game, takingSide, 200, 10_000, 6_000);
        legs[0] = _filledLeg(resting, 5_000, 5_000);
        _refused(
            sender, taking, _list(resting), _short(taking, 5_000, 5_000, legs), "short, from a taking account with code"
        );
        taking = _takeMin(coded, game, takingSide, 200, 10_000, 10_001);
        _refused(sender, taking, _list(resting), _aboveStake(taking), "asking for 10,001 of 10,000, with code");
        resting = _restMin(coded, game, restingSide, 200, 100_000, 5_000);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 4_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, a resting account with code"
        );
        resting = _restMin(coded, game, restingSide, 200, 10_000, 10_001);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 4_000),
            _list(resting),
            _aboveStake(resting),
            "a resting order asking for 10,001 of 10,000, with code"
        );
        vm.revertToState(snap);

        // Off the zero line: the tail on the total at 45.5, the resting check on the spread at -3.5.
        taking = _takeMinOn(tk, game, address(total), 455, takingSide, 200, 10_000, 6_000);
        resting = _restOn(m1, game, address(total), 455, restingSide, 200, 5_000);
        legs[0] = _filledLeg(resting, 5_000, 5_000);
        _refused(sender, taking, _list(resting), _short(taking, 5_000, 5_000, legs), "short, on the total at 45.5");
        resting = _restMinOn(m1, game, address(spread), -35, restingSide, 200, 100_000, 5_000);
        _refused(
            sender,
            _takeOn(tk, game, address(spread), -35, takingSide, 200, 4_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, on the spread at -3.5"
        );
        vm.revertToState(snap);

        // The resting account is the taking account: held to its minimum.
        resting = _restMin(tk, game, restingSide, 200, 100_000, 5_000);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 4_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, resting against its own account"
        );
        vm.revertToState(snap);

        // A contract as the sender: the Cross it sends skips the order under its minimum, and the refusal comes
        // back to it unchanged; its second Cross, against an order asking for nothing, fills.
        RetryingSender viaContract = new RetryingSender();
        _register(tk.a, address(viaContract));
        _register(m1.a, address(viaContract));
        resting = _restMin(m1, game, restingSide, 200, 100_000, 5_000);
        taking = _take(tk, game, takingSide, 200, 4_000);
        OspexMatching.SignedOrder memory again = _take(tk, game, takingSide, 200, 4_000);
        viaContract.send(
            matching,
            abi.encodeCall(OspexMatching.cross, (taking, _list(resting))),
            abi.encodeCall(OspexMatching.cross, (again, _list(_rest(m1, game, restingSide, 200, 4_000))))
        );
        assertFalse(viaContract.firstFilled(), "under its minimum, sent by a contract: filled");
        assertEq(
            viaContract.firstRefusal(),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, sent by a contract"
        );
        assertEq(_filled(again), 4_000, "the contract's second Cross");
        vm.revertToState(snap);

        // A resting order with thirty seconds to live is a resting order still, held to its minimum.
        resting = _signed(
            _order(
                m1.a,
                game,
                address(moneyline),
                0,
                restingSide,
                _tick(200),
                100_000,
                nextNonce++,
                vm.getBlockTimestamp() + 30,
                5_000
            ),
            m1.key
        );
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 4_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, with thirty seconds to live"
        );
        vm.revertToState(snap);

        // Above thirty-two bits, in either role: 5,000 USDC asking for 4,500 USDC, offered 4,000 USDC.
        taking = _takeMin(tk, game, takingSide, 200, 5_000_000_000, 4_500_000_000);
        resting = _rest(m1, game, restingSide, 200, 4_000_000_000);
        legs[0] = _filledLeg(resting, 4_000_000_000, 4_000_000_000);
        _refused(
            sender,
            taking,
            _list(resting),
            _short(taking, 4_000_000_000, 1_000_000_000, legs),
            "short, above thirty-two bits"
        );
        resting = _restMin(m1, game, restingSide, 200, 5_000_000_000, 4_500_000_000);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 4_000_000_000),
            _list(resting),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "under its minimum, above thirty-two bits"
        );
        vm.revertToState(snap);
    }
}

/// @notice The minimum fill on a set whose cap is in force, as deployed: the one-cent bet the alpha allows, asking
///         for a minimum and asking for none, and what a one-cent leg costs either way.
contract OspexMinFillInCapTest is CrossBase {
    Signer internal tk;
    Signer internal m1;
    Signer internal m2;

    function setUp() public override {
        liftAtDeploy = false;
        super.setUp();
        tk = _account("taking account");
        m1 = _account("resting one");
        m2 = _account("resting two");
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m2.a, sender);
    }

    /// One cent at 1.90 against the maker's 2.10 fills 9,900 and leaves exactly a lot, so a minimum of 9,900 is
    /// met and a minimum of 10,000 is not; a second resting order at 2.00 behind it takes the last lot, and the
    /// minimum of 10,000 is met. The cap's refusal at 10,100 stands, and the bound on the minimum is tested before
    /// the cap, which reads the signed stake alone; a resting order is held to its minimum under the cap; and under
    /// 2.00, where the taking stake of a leg is the smaller, a short taking fill is refused whole with the cap in
    /// force.
    /// Breaks: in OspexMatching.cross, the cap comparing the stake less the minimum, or the minimum when one is
    /// set; the tail waived while the cap is in force where the taking stake of the Cross is the smaller; in
    /// OspexMatching._leg, the resting check waived while the cap is in force. 21's and 26's breaks are scored
    /// against their own tests.
    function test_minFill_aOneCentBetUnderTheCap() public {
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at deploy");
        _capCases(Side.B);
        _capCases(Side.A);
    }

    function _capCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        uint256 snap = vm.snapshotState();

        OspexMatching.SignedOrder memory longer = _rest(m1, game, restingSide, 210, 10_000);
        OspexMatching.SignedOrder memory taking = _takeMin(tk, game, takingSide, 190, 10_000, 9_900);
        _cross(sender, taking, _list(longer));
        assertEq(_filled(taking), 9_900, "one cent asking for 9,900, at 2.10");
        assertEq(_filled(longer), 9_000, "the maker's 9,000 at 2.10");
        assertEq(taking.order.riskAmount - _filled(taking), 100, "exactly a lot left");
        vm.revertToState(snap);

        taking = _takeMin(tk, game, takingSide, 190, 10_000, 10_000);
        legs[0] = _filledLeg(longer, 9_000, 9_900);
        _refused(
            sender,
            taking,
            _list(longer),
            _short(taking, 9_900, 100, legs),
            "one cent asking for all of it, at 2.10 alone"
        );
        OspexMatching.SignedOrder memory even = _rest(m2, game, restingSide, 200, 10_000);
        _cross(sender, taking, _list(longer, even));
        assertEq(_filled(taking), 10_000, "one cent asking for all of it, with a second order at 2.00 behind");
        assertEq(_filled(longer), 9_000, "the first leg at 2.10");
        assertEq(_filled(even), 100, "the last lot at 2.00");
        vm.revertToState(snap);

        // The cap's refusal stands, and the bound on the minimum comes before it.
        taking = _take(tk, game, takingSide, 200, 10_100);
        _refused(
            sender,
            taking,
            _list(_rest(m1, game, restingSide, 200, 10_100)),
            _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, taking),
            "10,100 before the switch"
        );
        taking = _takeMin(tk, game, takingSide, 200, 10_100, 10_101);
        _refused(
            sender,
            taking,
            _list(_rest(m1, game, restingSide, 200, 10_100)),
            abi.encodeWithSelector(
                OspexMatching.OspexMatching__MinFillAboveStake.selector, _hash(taking), uint256(10_101), uint256(10_100)
            ),
            "10,100 asking for 10,101: the bound on the minimum, before the cap"
        );
        vm.revertToState(snap);

        // The cap reads the signed stake, not the stake less the minimum nor the minimum itself: 1,000,000 asking
        // for 990,001, and asking for 100, are refused by the cap's name. And a resting order is held to its
        // minimum under the cap: 100,000 asking for 5,000 is skipped when offered 4,000 and fills when offered 5,000.
        taking = _takeMin(tk, game, takingSide, 200, 1_000_000, 990_001);
        _refused(
            sender,
            taking,
            _list(_rest(m1, game, restingSide, 200, 1_000_000)),
            _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, taking),
            "1,000,000 asking for 990,001, before the switch"
        );
        taking = _takeMin(tk, game, takingSide, 200, 1_000_000, 100);
        _refused(
            sender,
            taking,
            _list(_rest(m1, game, restingSide, 200, 1_000_000)),
            _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, taking),
            "1,000,000 asking for 100, before the switch"
        );
        OspexMatching.SignedOrder memory asking = _restMin(m1, game, restingSide, 200, 100_000, 5_000);
        _refused(
            sender,
            _take(tk, game, takingSide, 200, 4_000),
            _list(asking),
            _nothingFilled(_reasons(UNDER_MIN_FILL)),
            "asking for 5,000, offered 4,000, before the switch"
        );
        _cross(sender, _take(tk, game, takingSide, 200, 5_000), _list(asking));
        assertEq(_filled(asking), 5_000, "asking for 5,000, offered 5,000, before the switch");
        vm.revertToState(snap);

        // Under 2.00 the taking stake of a leg is the smaller, and the cap is in force: 10,000 at 2.90 against
        // 5,000 at 1.50 is fifty lots, 5,000 of resting stake for 2,500 of taking stake, with 7,500 left. Asking
        // for 2,501 is short, the whole refusal compared, and nothing moves; asking for 2,500 fills.
        OspexMatching.SignedOrder memory under = _rest(m1, game, restingSide, 150, 5_000);
        taking = _takeMin(tk, game, takingSide, 290, 10_000, 2_501);
        legs[0] = _filledLeg(under, 5_000, 2_500);
        address[] memory who = new address[](3);
        who[0] = tk.a;
        who[1] = m1.a;
        who[2] = sender;
        bytes32[] memory orders = new bytes32[](2);
        orders[0] = _hash(taking);
        orders[1] = _hash(under);
        bytes32 before = _fingerprint(who, orders);
        _refused(
            sender,
            taking,
            _list(under),
            _short(taking, 2_500, 7_500, legs),
            "asking for 2,501 at 2.90 against 1.50, before the switch"
        );
        assertEq(_fingerprint(who, orders), before, "the short Cross under the cap left something");
        assertEq(_filled(taking), 0, "the short Cross under the cap left the taking order a filled amount");
        assertEq(_filled(under), 0, "the short Cross under the cap left the resting order a filled amount");
        taking = _takeMin(tk, game, takingSide, 290, 10_000, 2_500);
        _cross(sender, taking, _list(under));
        assertEq(_filled(taking), 2_500, "asking for 2,500 at 2.90 against 1.50, before the switch: the taking stake");
        assertEq(_filled(under), 5_000, "asking for 2,500 at 2.90 against 1.50, before the switch: the resting stake");
        vm.revertToState(snap);
    }

    // ──────────────────────────── Gas ────────────────────

    /// What a one-cent leg costs, as the gas of the call into the matching module, each a market's first fill
    /// after a warming Cross: both orders asking for nothing, then both asking for the whole cent. Printed, not
    /// pinned.
    function test_gas_aOneCentLegWithAndWithoutAMinimum() public {
        uint256 warm = _verifiedGame();
        uint256 first = _verifiedGame();
        uint256 second = _verifiedGame();

        OspexMatching.SignedOrder memory taking = _take(tk, warm, Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(m1, warm, Side.A, 200, 10_000)));
        assertEq(_filled(taking), 10_000);

        taking = _take(tk, first, Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(m1, first, Side.A, 200, 10_000)));
        emit log_named_uint("one cent, one leg, the market's first fill, no minimum", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 10_000);

        taking = _takeMin(tk, second, Side.B, 200, 10_000, 10_000);
        _cross(sender, taking, _list(_restMin(m1, second, Side.A, 200, 10_000, 10_000)));
        emit log_named_uint(
            "one cent, one leg, the market's first fill, both asking for the whole cent", vm.lastCallGas().gasTotalUsed
        );
        assertEq(_filled(taking), 10_000);
    }
}
