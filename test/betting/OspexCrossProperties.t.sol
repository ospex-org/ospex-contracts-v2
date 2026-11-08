// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross end to end, its books under random Crosses, and what it costs. The end-to-end test builds
///         its digests from the type and domain strings written out in the test itself; the property test
///         draws orders, prices, stakes and standings from a seed and checks the books after every Cross.
contract OspexCrossPropertiesTest is CrossBase {
    Signer internal tk;
    Signer[4] internal makers;

    function setUp() public override {
        super.setUp();
        tk = _account("taking account");
        _register(tk.a, sender);
        string[4] memory names = ["resting one", "resting two", "resting three", "resting four"];
        for (uint256 i; i < 4; ++i) {
            makers[i] = _account(names[i]);
            _register(makers[i].a, sender);
        }
    }

    // ──────────────────────────── End to end ───────────────────────────

    /// Two accounts each register the courier from their own address; one signs a resting order and the other a
    /// taking order; an address neither registered is refused; the courier fills them; the game is scored 121
    /// to 99; the market settles; the winner claims its stake and its winnings; the loser's claim is refused;
    /// and the positions module holds none of the market's coin.
    /// Break: in OspexMatching.cross, delete the taking account's courier check. The address neither account
    /// registered then fills the two orders.
    function test_endToEnd_twoAccountsACourierAScoreAndAClaim() public {
        (address home, uint256 homeKey) = makeAddrAndKey("an account backing the home team");
        (address away, uint256 awayKey) = makeAddrAndKey("an account backing the away team");
        address courier = makeAddr("the courier");
        address unregistered = makeAddr("an address neither account registered");
        _fundCoin(home);
        _fundCoin(away);
        IERC20 coin = _coin();

        // Each account registers the courier, from its own address.
        vm.prank(home, crossOrigin);
        matching.registerCourier(courier);
        vm.prank(away, crossOrigin);
        matching.registerCourier(courier);

        uint256 game = _verifiedGame();
        // The resting order: the home team, side A, at 2.10, for up to 100,000 units. The taking order: the away
        // team, side B, at 1.90 or better, for 10,000 units, a cent, live for thirty seconds.
        OspexMatching.OspexOrder memory restingOrder =
            _order(home, game, address(moneyline), 0, Side.A, 210, 100_000, 1, vm.getBlockTimestamp() + 1 days);
        OspexMatching.OspexOrder memory takingOrder =
            _order(away, game, address(moneyline), 0, Side.B, 190, 10_000, 1, vm.getBlockTimestamp() + 30);

        // The digests, from the type string and the domain's two strings, written out here.
        bytes32 typehash = keccak256(
            "OspexOrder(address account,uint256 gameId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry,uint256 minFill)"
        );
        assertEq(
            typehash, 0x9f84ebcb32dbe12642da2b9008bc0ec2e6332472ec69f27f13e8abebbb92934c, "the typehash, as a literal"
        );
        assertEq(matching.ORDER_TYPEHASH(), typehash, "the contract's typehash");
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Ospex"),
                keccak256("3"),
                block.chainid,
                address(matching)
            )
        );
        assertEq(matching.getDomainSeparator(), domain, "the contract's domain separator");
        OspexMatching.SignedOrder memory resting = OspexMatching.SignedOrder({
            order: restingOrder, signature: _signature(homeKey, _endToEndDigest(domain, typehash, restingOrder))
        });
        OspexMatching.SignedOrder memory taking = OspexMatching.SignedOrder({
            order: takingOrder, signature: _signature(awayKey, _endToEndDigest(domain, typehash, takingOrder))
        });

        // A sender neither account registered: refused, and nothing has moved.
        uint256 homeCoin = coin.balanceOf(home);
        uint256 awayCoin = coin.balanceOf(away);
        _refused(
            unregistered,
            taking,
            _list(resting),
            abi.encodeWithSelector(OspexMatching.OspexMatching__SenderNotCourier.selector, away, unregistered),
            "a sender neither account registered"
        );
        assertEq(coin.balanceOf(home), homeCoin, "the refused Cross moved the resting account's coin");
        assertEq(coin.balanceOf(away), awayCoin, "the refused Cross moved the taking account's coin");
        assertEq(coin.balanceOf(address(positions)), 0, "the refused Cross moved coin");
        assertEq(markets.marketCount(), 0, "the refused Cross drew a market");
        assertEq(_filled(resting), 0, "the refused Cross left a filled amount");
        assertEq(_filled(taking), 0, "the refused Cross left a filled amount");

        // The registered courier sends the same call: filled. Ninety lots at 2.10: 9,000 against 9,900.
        vm.recordLogs();
        _cross(courier, taking, _list(resting));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, ORDER_MATCHED_TOPIC), 1, "one leg matched");
        assertEq(_count(logs, ORDER_SKIPPED_TOPIC), 0, "a skip record");
        assertEq(_count(logs, CROSSED_TOPIC), 1, "the Cross's event");
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(homeCoin - coin.balanceOf(home), 9_000, "the resting stake");
        assertEq(awayCoin - coin.balanceOf(away), 9_900, "the taking stake");
        assertEq(coin.balanceOf(address(positions)), 18_900, "the two stakes held");
        assertEq(coin.balanceOf(courier), 0, "the courier holds coin");
        _assertPosition(market, home, Side.A, 9_000, 9_900, "the resting account's position");
        _assertPosition(market, away, Side.B, 9_900, 9_000, "the taking account's position");
        _assertPosition(market, courier, Side.A, 0, 0, "the courier's position");
        _assertPosition(market, courier, Side.B, 0, 0, "the courier's position");
        assertEq(_filled(resting), 9_000, "the resting order's filled amount");
        assertEq(_filled(taking), 9_900, "the taking order's filled amount");

        // The game is scored 121 to 99 through the report path: the home team wins.
        _score(game, 121, 99);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home), "home wins the moneyline");
        // The winner claims its stake and its winnings; the loser's claim is refused; the market's coin is gone.
        assertEq(_claim(home, market, Side.A), 18_900, "the winner's stake and winnings");
        (bool ok, bytes memory err) = _tryClaim(away, market, Side.B);
        assertFalse(ok, "the loser was paid");
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector));
        assertEq(coin.balanceOf(address(positions)), 0, "coin of the market left in the positions module");
    }

    /// @dev The EIP-712 digest of an order, from a domain separator and a typehash.
    function _endToEndDigest(bytes32 domain, bytes32 typehash, OspexMatching.OspexOrder memory o)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                typehash,
                o.account,
                o.gameId,
                o.scorer,
                o.lineTicks,
                uint8(o.positionType),
                o.oddsTick,
                o.riskAmount,
                o.nonce,
                o.expiry,
                o.minFill
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    // ──────────────────────────── The books, under random Crosses ──────

    /// Two Crosses drawn from a seed, on one market: up to four resting orders, each at a price from 1.01 to
    /// 101.00, for up to 2,000 lots, asking for a minimum fill of zero, of the whole stake or of any amount
    /// between, plain, cancelled, expired, unpaid or with the sender dropped; and two taking orders at a price
    /// that every resting price meets, each with a minimum drawn the same way. After each: the positions module
    /// holds exactly what the market's positions risk; no order has filled past its signed stake; in every
    /// filled leg the resting stake times the price's ticks over 100 is the taking stake times 100, the resting
    /// stake is in whole lots, neither stake is under 100 units, and the resting stake is at least its order's
    /// minimum or the leg left under a lot of that order's room; a Cross that succeeded filled its taking order
    /// for at least its minimum, or left it under a lot of room; and a Cross that is refused is refused for
    /// filling nothing, or as short, with a report that names every listed order, and leaves the books as they
    /// were.
    function testFuzz_aCrossKeepsItsBooks(uint256 seed) public {
        uint256 game = _verifiedGame();
        Side takingSide = seed % 2 == 0 ? Side.B : Side.A;
        Side restingSide = _other(takingSide);
        IERC20 coin = _coin();
        uint256 n = 1 + (seed >> 1) % 4;
        OspexMatching.SignedOrder[] memory resting = new OspexMatching.SignedOrder[](n);
        uint256[] memory standings = new uint256[](n);
        uint256 shortest = 10_000;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 p = 1 + r % 10_000;
            uint256 lots = 1 + (r >> 16) % 2_000;
            uint256 standing = (r >> 32) % 6;
            standings[i] = standing;
            if (10_000 / p < shortest) shortest = 10_000 / p;
            uint256 expiry = standing == 3 ? vm.getBlockTimestamp() : vm.getBlockTimestamp() + 1 days;
            resting[i] = _signed(
                _order(
                    makers[i].a,
                    game,
                    address(moneyline),
                    0,
                    restingSide,
                    _tick(100 + p),
                    lots * 100,
                    nextNonce++,
                    expiry,
                    _drawMinFill(r >> 40, lots * 100)
                ),
                makers[i].key
            );
            if (standing == 2) {
                vm.prank(makers[i].a);
                matching.cancelOrder(resting[i].order);
            } else if (standing == 4) {
                vm.prank(makers[i].a);
                coin.approve(address(positions), 0);
            } else if (standing == 5) {
                vm.prank(makers[i].a);
                matching.unregisterCourier(sender);
            }
        }
        for (uint256 round; round < 2; ++round) {
            uint256 r = uint256(keccak256(abi.encode(seed, "taking", round)));
            // A taking price every resting price meets: its ticks over 100 are at most 10,000 over the longest
            // resting price's.
            uint256 tick = 100 + 1 + r % shortest;
            uint256 stake = (1 + (r >> 16) % 5_000) * 100;
            OspexMatching.SignedOrder memory taking =
                _takeMin(tk, game, takingSide, tick, stake, _drawMinFill(r >> 40, stake));
            _oneRandomCross(taking, resting, restingSide, takingSide);
            _assertStandings(resting, standings);
        }
    }

    /// @dev A minimum fill drawn from `r` for an order of `stake`: zero in a third of the draws, the whole stake
    ///      in a third, and any amount from one unit to the stake in the rest.
    function _drawMinFill(uint256 r, uint256 stake) internal pure returns (uint256) {
        uint256 kind = r % 3;
        if (kind == 0) return 0;
        if (kind == 1) return stake;
        return 1 + (r >> 2) % stake;
    }

    function _oneRandomCross(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        Side restingSide,
        Side takingSide
    ) internal {
        IERC20 coin = _coin();
        uint256 heldBefore = coin.balanceOf(address(positions));
        uint256[] memory filledBefore = new uint256[](resting.length);
        for (uint256 i; i < resting.length; ++i) {
            filledBefore[i] = _filled(resting[i]);
        }
        vm.recordLogs();
        (bool ok, bytes memory err) = _tryCross(sender, taking, resting);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        lastSkips = abi.encode(ok ? _skips(logs) : new Skip[](0));
        lastOk = ok;
        if (!ok) {
            // Every order is well formed, so the refusals left are that nothing filled, or that the taking order
            // was left short of its minimum, with the report.
            if (_selector(err) == OspexMatching.OspexMatching__TakingOrderUnderMinFill.selector) {
                _assertShort(taking, resting, err);
            } else {
                assertEq(
                    _selector(err), OspexMatching.OspexMatching__NothingFilled.selector, "refused for another reason"
                );
            }
            assertEq(coin.balanceOf(address(positions)), heldBefore, "a refused Cross moved coin");
            assertEq(_filled(taking), 0, "a refused Cross filled its taking order");
            for (uint256 i; i < resting.length; ++i) {
                assertEq(_filled(resting[i]), filledBefore[i], "a refused Cross filled a resting order");
            }
            return;
        }
        // Each filled leg, from its record.
        uint256 makerTotal;
        uint256 takerTotal;
        uint256 legs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(matching) || logs[i].topics[0] != ORDER_MATCHED_TOPIC) continue;
            (,,,,, uint16 tick, uint256 makerRisk, uint256 takerRisk,,,, uint256 orderMinFill) = abi.decode(
                logs[i].data,
                (uint256, uint256, address, int32, uint8, uint16, uint256, uint256, uint256, uint256, uint256, uint256)
            );
            OspexMatching.SignedOrder memory o = _orderOf(resting, logs[i].topics[1]);
            assertEq(tick, o.order.oddsTick, "a leg's record carries another price than its order");
            assertEq(orderMinFill, o.order.minFill, "a leg's record carries another minimum than its order");
            assertEq(makerRisk * (uint256(tick) - 100), takerRisk * 100, "a leg off the resting price");
            assertEq(makerRisk % 100, 0, "a resting stake off the lot");
            assertGe(makerRisk, 100, "a resting stake under the minimum");
            assertGe(takerRisk, 100, "a taking stake under the minimum");
            // The resting order's minimum, met or moot: the leg took at least it, or left under a lot of room.
            assertTrue(
                makerRisk >= o.order.minFill || o.order.riskAmount - _filled(o) < 100,
                "a leg under the resting order's minimum, with a lot or more left"
            );
            makerTotal += makerRisk;
            takerTotal += takerRisk;
            ++legs;
        }
        assertGt(legs, 0, "a Cross that filled nothing succeeded");
        assertEq(legs + _skips(logs).length, resting.length, "an order neither filled nor skipped");
        // No order filled past its signed stake, and the taking order filled by exactly its legs.
        assertEq(_filled(taking), takerTotal, "the taking order's filled amount");
        assertLe(_filled(taking), taking.order.riskAmount, "the taking order filled past its stake");
        // The taking order's minimum, met or moot: this Cross filled at least it, or left under a lot of room.
        assertTrue(
            takerTotal >= taking.order.minFill || taking.order.riskAmount - _filled(taking) < 100,
            "a Cross short of its taking order's minimum succeeded"
        );
        uint256 restingFilled;
        for (uint256 i; i < resting.length; ++i) {
            assertLe(_filled(resting[i]), resting[i].order.riskAmount, "a resting order filled past its stake");
            restingFilled += _filled(resting[i]) - filledBefore[i];
        }
        assertEq(restingFilled, makerTotal, "the resting orders' filled amounts");
        // The positions module took in exactly the two stakes of the filled legs, and holds exactly what the
        // market's positions risk.
        assertEq(coin.balanceOf(address(positions)) - heldBefore, makerTotal + takerTotal, "coin taken in");
        uint256 market = markets.marketCount();
        uint256 risked = positions.getPosition(market, tk.a, takingSide).risk;
        for (uint256 i; i < 4; ++i) {
            risked += positions.getPosition(market, makers[i].a, restingSide).risk;
        }
        assertEq(coin.balanceOf(address(positions)), risked, "the coin held is not what the positions risk");
    }

    /// @dev The skip records of the last random Cross, and whether it filled anything.
    bytes internal lastSkips;
    bool internal lastOk;

    /// @dev The order among `resting` whose hash is `orderHash`.
    function _orderOf(OspexMatching.SignedOrder[] memory resting, bytes32 orderHash)
        internal
        view
        returns (OspexMatching.SignedOrder memory)
    {
        for (uint256 i; i < resting.length; ++i) {
            if (_hash(resting[i]) == orderHash) return resting[i];
        }
        revert("a leg's record names an order that was not listed");
    }

    /// @dev A short refusal, read against the list it refused: the taking order's hash and minimum; a fill under
    ///      the minimum with a lot or more left, the room being the stake less what the order had filled before
    ///      and in this Cross; one record per listed order, in list order, at least one of them filled; a filled
    ///      record's stakes at the resting price, a lot or more, adding up to the fill; a skipped record's zero.
    function _assertShort(
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        bytes memory err
    ) internal view {
        (
            bytes32 takingHash,
            uint256 filledThisCross,
            uint256 minFill,
            uint256 roomLeft,
            OspexMatching.LegReport[] memory legs
        ) = _decodeShort(err);
        assertEq(takingHash, _hash(taking), "the short refusal names another order");
        assertEq(minFill, taking.order.minFill, "the short refusal's minimum");
        assertLt(filledThisCross, minFill, "a short refusal of a fill at the minimum");
        assertGe(roomLeft, 100, "a short refusal of a complete order");
        assertEq(roomLeft, taking.order.riskAmount - _filled(taking) - filledThisCross, "the room left after the walk");
        assertEq(legs.length, resting.length, "a record per listed order");
        uint256 filledLegs;
        uint256 takerTotal;
        for (uint256 i; i < legs.length; ++i) {
            assertEq(legs[i].orderHash, _hash(resting[i]), "a record out of list order");
            if (legs[i].filled) {
                ++filledLegs;
                takerTotal += legs[i].takerRisk;
                assertEq(uint8(legs[i].reason), 0, "a filled record carries a reason");
                assertEq(
                    legs[i].makerRisk * (uint256(resting[i].order.oddsTick) - 100),
                    legs[i].takerRisk * 100,
                    "a filled record off the resting price"
                );
                assertGe(legs[i].makerRisk, 100, "a filled record under a lot");
            } else {
                assertEq(legs[i].makerRisk, 0, "a skipped record carries a resting stake");
                assertEq(legs[i].takerRisk, 0, "a skipped record carries a taking stake");
            }
        }
        assertGt(filledLegs, 0, "a short refusal with nothing filled");
        assertEq(takerTotal, filledThisCross, "the filled records do not add up to the fill");
    }

    /// @dev After a Cross that filled: an order drawn cancelled, expired or with the sender dropped is among
    ///      the skip records under that reason, an unpaid order has filled nothing, and a skip record of any
    ///      other order is for its room, for the lot's minimum or for its own minimum. The standings are the
    ///      ones the seed drew, not a second copy of the walk.
    function _assertStandings(OspexMatching.SignedOrder[] memory resting, uint256[] memory standings) internal view {
        if (!lastOk) return;
        Skip[] memory skips = abi.decode(lastSkips, (Skip[]));
        for (uint256 i; i < resting.length; ++i) {
            (bool skipped, uint8 reason) = _skipOf(skips, _hash(resting[i]));
            if (standings[i] == 2) {
                assertTrue(skipped && reason == CANCELLED, "a cancelled order was not skipped as cancelled");
            } else if (standings[i] == 3) {
                assertTrue(skipped && reason == EXPIRED, "an expired order was not skipped as expired");
            } else if (standings[i] == 5) {
                assertTrue(skipped && reason == NO_COURIER, "an order with the sender dropped was not skipped for it");
            } else if (standings[i] == 4) {
                assertEq(_filled(resting[i]), 0, "an order whose account pays nothing filled");
                assertTrue(skipped && reason >= NOTHING_FITS, "an unpaid order, skipped under a reason of another row");
            } else if (skipped) {
                assertTrue(
                    reason == NO_ROOM || reason == NOTHING_FITS || reason == UNDER_MIN_FILL,
                    "a live order, skipped under another reason"
                );
            }
        }
    }

    /// @dev Whether `orderHash` has a skip record among `skips`, and its reason.
    function _skipOf(Skip[] memory skips, bytes32 orderHash) internal pure returns (bool skipped, uint8 reason) {
        for (uint256 i; i < skips.length; ++i) {
            if (skips[i].orderHash == orderHash) return (true, skips[i].reason);
        }
    }

    // ──────────────────────────── Gas ──────────────────────────────────

    /// What a Cross costs, as the gas of the call into the matching module: one leg and three, each as a
    /// market's first fill and as a later fill by accounts that already hold positions on it. The figures are
    /// printed, not pinned: the test asserts only that each Cross filled.
    function test_gas_aCrossOfOneLegAndOfThree() public {
        uint256 first = _verifiedGame();
        uint256 second = _verifiedGame();

        // One leg, the market's first fill.
        OspexMatching.SignedOrder memory taking = _take(tk, first, Side.B, 190, 10_000);
        _cross(sender, taking, _list(_rest(makers[0], first, Side.A, 210, 100_000)));
        emit log_named_uint("one leg, the market's first fill", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 9_900);

        // Three legs, the market's first fill.
        taking = _take(tk, second, Side.B, 190, 30_000);
        _cross(
            sender,
            taking,
            _list(
                _rest(makers[0], second, Side.A, 200, 10_000),
                _rest(makers[1], second, Side.A, 200, 10_000),
                _rest(makers[2], second, Side.A, 200, 10_000)
            )
        );
        emit log_named_uint("three legs, the market's first fill", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 30_000);

        // One leg, a later fill: the market exists and both accounts hold positions on it.
        taking = _take(tk, second, Side.B, 190, 10_000);
        _cross(sender, taking, _list(_rest(makers[0], second, Side.A, 200, 10_000)));
        emit log_named_uint("one leg, a later fill", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 10_000);

        // Three legs, a later fill.
        taking = _take(tk, second, Side.B, 190, 30_000);
        _cross(
            sender,
            taking,
            _list(
                _rest(makers[0], second, Side.A, 200, 10_000),
                _rest(makers[1], second, Side.A, 200, 10_000),
                _rest(makers[2], second, Side.A, 200, 10_000)
            )
        );
        emit log_named_uint("three legs, a later fill", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 30_000);
    }
}
