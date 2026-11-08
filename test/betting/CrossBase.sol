// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {TestCoin} from "../games/CoinFixtures.sol";
import {BettingBase} from "./BettingBase.sol";

/// @dev What the Cross's tests share: accounts that are keys, funded in the set's coin; orders on one market,
///      the moneyline of a game, unless a test names another; the records a Cross leaves; and a fingerprint of
///      everything a Cross can move. Amounts in the tests are literals, worked out by hand; the digests are
///      built from the type and domain strings written out in the base, never read from the contract.
abstract contract CrossBase is BettingBase {
    /// @dev An account that is a key.
    struct Signer {
        address a;
        uint256 key;
    }

    /// @dev One skip record of a Cross, as its event carries it.
    struct Skip {
        bytes32 orderHash;
        address account;
        bytes32 takingOrderHash;
        uint8 reason;
    }

    uint8 internal constant NO_COURIER = 0;
    uint8 internal constant CANCELLED = 1;
    uint8 internal constant EXPIRED = 2;
    uint8 internal constant NO_ROOM = 3;
    uint8 internal constant NOTHING_FITS = 4;
    uint8 internal constant UNDER_MIN_FILL = 5;
    uint8 internal constant PULL_REFUSED = 6;

    /// @dev The first topics of the matching module's three Cross events, each the hash of its signature
    ///      written out.
    bytes32 internal constant ORDER_MATCHED_TOPIC = keccak256(
        "OrderMatched(bytes32,address,address,uint256,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant ORDER_SKIPPED_TOPIC = keccak256("OrderSkipped(bytes32,address,bytes32,uint8)");
    bytes32 internal constant CROSSED_TOPIC = keccak256("Crossed(address,bytes32,address,uint256,uint256,uint256)");

    /// @dev The address that sends the Crosses of most tests: a key that is no account of theirs.
    address internal sender = makeAddr("sender");
    /// @dev The nonce of the next order the helpers sign, so that no two are the same order by accident.
    uint256 internal nextNonce = 1000;

    // ──────────────────────────── Accounts ─────────────────────────────

    /// @dev A new account that is a key, with a purse of the set's coin and the positions module approved.
    function _account(string memory name) internal returns (Signer memory x) {
        (x.a, x.key) = makeAddrAndKey(name);
        _fundCoin(x.a);
    }

    /// @dev Gives `who` a purse of the set's coin and lets the positions module take from it.
    function _fundCoin(address who) internal {
        TestCoin coin = TestCoin(address(positions.i_token()));
        coin.mint(who, PURSE);
        vm.prank(who);
        coin.approve(address(positions), type(uint256).max);
    }

    function _coin() internal view returns (IERC20) {
        return positions.i_token();
    }

    // ──────────────────────────── Orders ───────────────────────────────

    /// @dev A resting order of `m` on the game's moneyline, live for a day, signed.
    function _rest(Signer memory m, uint256 game, Side side, uint256 tick, uint256 risk)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _signed(
            _order(
                m.a, game, address(moneyline), 0, side, _tick(tick), risk, nextNonce++, vm.getBlockTimestamp() + 1 days
            ),
            m.key
        );
    }

    /// @dev A resting order of `m` on any market of the game, live for a day, signed.
    function _restOn(Signer memory m, uint256 game, address scorer, int32 line, Side side, uint256 tick, uint256 risk)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _signed(
            _order(m.a, game, scorer, line, side, _tick(tick), risk, nextNonce++, vm.getBlockTimestamp() + 1 days),
            m.key
        );
    }

    /// @dev A taking order of `t` on any market of the game, with thirty seconds to its expiry, signed.
    function _takeOn(Signer memory t, uint256 game, address scorer, int32 line, Side side, uint256 tick, uint256 risk)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _signed(
            _order(t.a, game, scorer, line, side, _tick(tick), risk, nextNonce++, vm.getBlockTimestamp() + 30), t.key
        );
    }

    /// @dev The same, with its expiry named.
    function _restUntil(Signer memory m, uint256 game, Side side, uint256 tick, uint256 risk, uint256 expiry)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _signed(_order(m.a, game, address(moneyline), 0, side, _tick(tick), risk, nextNonce++, expiry), m.key);
    }

    /// @dev A taking order of `t` on the game's moneyline, with thirty seconds to its expiry, signed.
    function _take(Signer memory t, uint256 game, Side side, uint256 tick, uint256 risk)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _signed(
            _order(t.a, game, address(moneyline), 0, side, _tick(tick), risk, nextNonce++, vm.getBlockTimestamp() + 30),
            t.key
        );
    }

    /// @dev The same, with its expiry named.
    function _takeUntil(Signer memory t, uint256 game, Side side, uint256 tick, uint256 risk, uint256 expiry)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        return _signed(_order(t.a, game, address(moneyline), 0, side, _tick(tick), risk, nextNonce++, expiry), t.key);
    }

    /// @dev A resting order of `m` on the game's moneyline with a minimum fill, live for a day, signed.
    function _restMin(Signer memory m, uint256 game, Side side, uint256 tick, uint256 risk, uint256 minFill)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        uint256 expiry = vm.getBlockTimestamp() + 1 days;
        return
            _signed(
                _order(m.a, game, address(moneyline), 0, side, _tick(tick), risk, nextNonce++, expiry, minFill), m.key
            );
    }

    /// @dev A taking order of `t` on the game's moneyline with a minimum fill, thirty seconds to its expiry,
    ///      signed.
    function _takeMin(Signer memory t, uint256 game, Side side, uint256 tick, uint256 risk, uint256 minFill)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        uint256 expiry = vm.getBlockTimestamp() + 30;
        return
            _signed(
                _order(t.a, game, address(moneyline), 0, side, _tick(tick), risk, nextNonce++, expiry, minFill), t.key
            );
    }

    /// @dev The hash a signer would sign for an order under another type string, version, chain or contract:
    ///      what a signature made for something else is over.
    function _digestUnder(
        OspexMatching.OspexOrder memory o,
        string memory orderType,
        string memory version,
        uint256 chainId,
        address verifying
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(DOMAIN_NAME)), keccak256(bytes(version)), chainId, verifying)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, _structHash(o, orderType)));
    }

    function _list() internal pure returns (OspexMatching.SignedOrder[] memory l) {
        l = new OspexMatching.SignedOrder[](0);
    }

    function _list(OspexMatching.SignedOrder memory a, OspexMatching.SignedOrder memory b)
        internal
        pure
        returns (OspexMatching.SignedOrder[] memory l)
    {
        l = new OspexMatching.SignedOrder[](2);
        l[0] = a;
        l[1] = b;
    }

    function _list(
        OspexMatching.SignedOrder memory a,
        OspexMatching.SignedOrder memory b,
        OspexMatching.SignedOrder memory c
    ) internal pure returns (OspexMatching.SignedOrder[] memory l) {
        l = new OspexMatching.SignedOrder[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
    }

    /// @dev An order's hash, built here.
    function _hash(OspexMatching.SignedOrder memory s) internal view returns (bytes32) {
        return _digest(s.order);
    }

    /// @dev What an order has filled, as the matching module holds it.
    function _filled(OspexMatching.SignedOrder memory s) internal view returns (uint256) {
        return matching.s_filledRisk(_digest(s.order));
    }

    // ──────────────────────────── Refusals ─────────────────────────────

    /// @dev A refusal that carries an order's hash.
    function _refusal(bytes4 selector, OspexMatching.SignedOrder memory s) internal view returns (bytes memory) {
        return abi.encodeWithSelector(selector, _hash(s));
    }

    /// @dev The nothing-filled refusal, carrying these reasons in list order, laid out here word by word: the
    ///      selector, the offset of the one array, its length, then a word for each reason.
    function _nothingFilled(uint8[] memory reasons) internal pure returns (bytes memory out) {
        out = abi.encodePacked(OspexMatching.OspexMatching__NothingFilled.selector, uint256(0x20), reasons.length);
        for (uint256 i; i < reasons.length; ++i) {
            out = bytes.concat(out, bytes32(uint256(reasons[i])));
        }
    }

    function _reasons(uint8 a) internal pure returns (uint8[] memory r) {
        r = new uint8[](1);
        r[0] = a;
    }

    /// @dev The short refusal, laid out as the contract lays it out: the selector, the taking order's hash,
    ///      what this Cross filled of it, its minimum, the room it has left, and one record per listed order.
    function _short(
        OspexMatching.SignedOrder memory taking,
        uint256 filledThisCross,
        uint256 roomLeft,
        OspexMatching.LegReport[] memory legs
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            OspexMatching.OspexMatching__TakingOrderUnderMinFill.selector,
            _hash(taking),
            filledThisCross,
            taking.order.minFill,
            roomLeft,
            legs
        );
    }

    /// @dev A filled leg's record: the order's hash, filled, no reason, the leg's two stakes.
    function _filledLeg(OspexMatching.SignedOrder memory s, uint256 makerRisk, uint256 takerRisk)
        internal
        view
        returns (OspexMatching.LegReport memory)
    {
        return OspexMatching.LegReport({
            orderHash: _hash(s),
            filled: true,
            reason: OspexMatching.SkipReason.NoCourier,
            makerRisk: makerRisk,
            takerRisk: takerRisk
        });
    }

    /// @dev A skipped order's record: the order's hash, not filled, its reason, zero stakes.
    function _skippedLeg(OspexMatching.SignedOrder memory s, uint8 reason)
        internal
        view
        returns (OspexMatching.LegReport memory)
    {
        return OspexMatching.LegReport({
            orderHash: _hash(s), filled: false, reason: OspexMatching.SkipReason(reason), makerRisk: 0, takerRisk: 0
        });
    }

    /// @dev The short refusal's five fields, decoded from a Cross's revert data: refuses any other selector.
    function _decodeShort(bytes memory err)
        internal
        pure
        returns (
            bytes32 takingHash,
            uint256 filledThisCross,
            uint256 minFill,
            uint256 roomLeft,
            OspexMatching.LegReport[] memory legs
        )
    {
        assertGe(err.length, 4, "no selector in the refusal");
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(err, 0x20))
        }
        assertEq(
            bytes32(selector),
            bytes32(OspexMatching.OspexMatching__TakingOrderUnderMinFill.selector),
            "not the short refusal"
        );
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        return abi.decode(body, (bytes32, uint256, uint256, uint256, OspexMatching.LegReport[]));
    }

    /// @dev A Cross that must be refused with exactly `want`.
    function _refused(
        address from,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        bytes memory want,
        string memory what
    ) internal {
        (bool ok, bytes memory err) = _tryCross(from, taking, resting);
        assertFalse(ok, string.concat("filled: ", what));
        assertEq(err, want, what);
    }

    // ──────────────────────────── What a Cross leaves ──────────────────

    /// @dev The skip records among a call's logs, in order. Each is checked against its copy through the
    ///      hub, which is read from the core's own log: the same number of them, and each copy's payload the
    ///      record's four words, the skipped order's hash, its account, the taking order's hash and the reason.
    function _skips(Vm.Log[] memory logs) internal view returns (Skip[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(matching) && logs[i].topics[0] == ORDER_SKIPPED_TOPIC) ++n;
        }
        out = new Skip[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(matching) || logs[i].topics[0] != ORDER_SKIPPED_TOPIC) continue;
            out[n++] = Skip({
                orderHash: logs[i].topics[1],
                account: address(uint160(uint256(logs[i].topics[2]))),
                takingOrderHash: logs[i].topics[3],
                reason: abi.decode(logs[i].data, (uint8))
            });
        }
        bytes[] memory hub = _hubSkipCopies(logs);
        assertEq(hub.length, n, "the skip records and their hub copies are not the same number");
        for (uint256 i; i < n; ++i) {
            assertEq(
                hub[i],
                abi.encode(out[i].orderHash, out[i].account, out[i].takingOrderHash, out[i].reason),
                "a skip record's hub copy differs from the record"
            );
        }
    }

    /// @dev The payloads of the hub's copies of a call's skip records, in order: each copy is the core's event
    ///      under the skip's tag, emitted for the matching module, and its payload is the record's four words.
    function _hubSkipCopies(Vm.Log[] memory logs) internal view returns (bytes[] memory out) {
        bytes32 tag = keccak256("ORDER_SKIPPED");
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics.length == 3 && logs[i].topics[1] == tag) ++n;
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics.length != 3 || logs[i].topics[1] != tag) continue;
            assertEq(
                logs[i].topics[2],
                bytes32(uint256(uint160(address(matching)))),
                "a skip record's hub copy names another module"
            );
            out[n++] = abi.decode(logs[i].data, (bytes));
        }
    }

    /// @dev How many of a call's logs the matching module emitted under `topic`.
    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(matching) && logs[i].topics[0] == topic) ++n;
        }
    }

    /// @dev One skip record, field by field.
    function _assertSkip(
        Skip memory got,
        OspexMatching.SignedOrder memory order,
        OspexMatching.SignedOrder memory taking,
        uint8 reason,
        string memory what
    ) internal view {
        assertEq(got.orderHash, _hash(order), string.concat(what, ": the skipped order's hash"));
        assertEq(got.account, order.order.account, string.concat(what, ": the skipped order's account"));
        assertEq(got.takingOrderHash, _hash(taking), string.concat(what, ": the taking order's hash"));
        assertEq(got.reason, reason, string.concat(what, ": the reason"));
    }

    /// @dev Everything a Cross can move, hashed: the market count, the positions module's coin, each named
    ///      address's coin and its two positions on every market, and each named order's filled amount.
    function _fingerprint(address[] memory who, bytes32[] memory orders) internal view returns (bytes32 h) {
        uint256 count = markets.marketCount();
        h = keccak256(abi.encode(count, _coin().balanceOf(address(positions))));
        for (uint256 i; i < who.length; ++i) {
            h = keccak256(abi.encode(h, _coin().balanceOf(who[i])));
            for (uint256 m = 1; m <= count; ++m) {
                Position memory a = positions.getPosition(m, who[i], Side.A);
                Position memory b = positions.getPosition(m, who[i], Side.B);
                h = keccak256(abi.encode(h, a.risk, a.profit, a.claimed, b.risk, b.profit, b.claimed));
            }
        }
        for (uint256 i; i < orders.length; ++i) {
            h = keccak256(abi.encode(h, matching.s_filledRisk(orders[i])));
        }
    }

    /// @dev An account's position on a market's side, as two numbers.
    function _assertPosition(uint256 marketId, address who, Side side, uint256 risk, uint256 profit, string memory what)
        internal
        view
    {
        Position memory p = positions.getPosition(marketId, who, side);
        assertEq(p.risk, risk, string.concat(what, ": risk"));
        assertEq(p.profit, profit, string.concat(what, ": profit"));
        // A position that holds a stake records the side it was asked for.
        if (risk != 0) assertEq(uint8(p.side), uint8(side), string.concat(what, ": the side it records"));
    }
}
