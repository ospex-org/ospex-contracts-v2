// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross's never-lines, third part: what an order must be before anything moves. The taking order's
///         thirty seconds; the signature, the type and the domain; the market, the side and the price; and an
///         admissible price and stake. Above each test, "Break:" names changes to src/betting that turn it red;
///         each is an entry of battery.json. Each case has one fault where one fault is possible: the order
///         among the checks is not promised, so a call with two faults could revert under either name. Two
///         faults come in pairs by nature, a price above the range, which meets no price, and a stake of zero,
///         which has no room; for those the order's own price and stake are tested first, and that is pinned.
contract OspexCrossOrdersTest is CrossBase {
    Signer internal tk;
    Signer internal m1;
    Signer internal m2;

    function setUp() public override {
        super.setUp();
        tk = _account("taking account");
        m1 = _account("resting one");
        m2 = _account("resting two");
        _register(tk.a, sender);
        _register(m1.a, sender);
        _register(m2.a, sender);
    }

    /// @dev The coin and the records of the three accounts, hashed.
    function _print() internal view returns (bytes32) {
        address[] memory who = new address[](3);
        who[0] = tk.a;
        who[1] = m1.a;
        who[2] = m2.a;
        return _fingerprint(who, new bytes32[](0));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 11. A taking order is unexpired and has at most thirty seconds left.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching.sol, make MAX_TAKING_LIFE 31. Others turn it red: the taking order's expiry test
    /// deleted, or made `>`; and the thirty seconds put on resting orders too.
    function test_neverLine_aTakingOrderIsUnexpiredAndHasAtMostThirtySecondsLeft() public {
        _lifeCases(Side.B);
        _lifeCases(Side.A);
    }

    function _lifeCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 now_ = vm.getBlockTimestamp();
        // A resting order with a day left, with room for every taking order below.
        OspexMatching.SignedOrder memory resting = _rest(m1, game, restingSide, 200, 1_000_000);

        // Thirty seconds left fills, and so does one.
        uint256[2] memory fills = [now_ + 30, now_ + 1];
        for (uint256 i; i < fills.length; ++i) {
            OspexMatching.SignedOrder memory taking = _takeUntil(tk, game, takingSide, 200, 10_000, fills[i]);
            _cross(sender, taking, _list(resting));
            assertEq(_filled(taking), 10_000, "a taking order with thirty seconds or less to its expiry");
        }
        // Thirty-one is refused, and so is any longer life.
        uint256[3] memory long = [now_ + 31, now_ + 1 days, type(uint256).max];
        for (uint256 i; i < long.length; ++i) {
            OspexMatching.SignedOrder memory taking = _takeUntil(tk, game, takingSide, 200, 10_000, long[i]);
            _refused(
                sender,
                taking,
                _list(resting),
                _refusal(OspexMatching.OspexMatching__TakingOrderTooLong.selector, taking),
                "a taking order with more than thirty seconds to its expiry"
            );
        }
        // None left is refused by name, and so is a past expiry, by the same name and not as an arithmetic error.
        uint256[4] memory dead = [now_, now_ - 1, now_ - 1 days, 0];
        for (uint256 i; i < dead.length; ++i) {
            OspexMatching.SignedOrder memory taking = _takeUntil(tk, game, takingSide, 200, 10_000, dead[i]);
            _refused(
                sender,
                taking,
                _list(resting),
                _refusal(OspexMatching.OspexMatching__TakingOrderExpired.selector, taking),
                "a taking order at or past its expiry"
            );
        }
        // An order with thirty seconds or less may rest: the thirty seconds are the taking order's alone.
        uint256[2] memory short = [now_ + 30, now_ + 1];
        for (uint256 i; i < short.length; ++i) {
            OspexMatching.SignedOrder memory brief = _restUntil(m2, game, restingSide, 200, 10_000, short[i]);
            _cross(sender, _take(tk, game, takingSide, 200, 10_000), _list(brief));
            assertEq(_filled(brief), 10_000, "a resting order with thirty seconds or less to its expiry");
        }
        assertEq(_filled(resting), 20_000, "the resting order with a day left");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 13. An order binds only the account that signed it, under this type and this domain.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev A Cross of one leg, 10,000 against 10,000 at 2.00, in which one order travels with `signature`: the
    ///      taking order when `taking` is true, the resting order otherwise. It must be refused as badly signed.
    function _badlySigned(
        OspexMatching.SignedOrder memory takingOrder,
        OspexMatching.SignedOrder memory restingOrder,
        bool taking,
        bytes memory signature,
        string memory what
    ) internal {
        OspexMatching.SignedOrder memory t = takingOrder;
        OspexMatching.SignedOrder memory r = restingOrder;
        if (taking) {
            t = OspexMatching.SignedOrder({order: takingOrder.order, signature: signature});
        } else {
            r = OspexMatching.SignedOrder({order: restingOrder.order, signature: signature});
        }
        _refused(
            sender,
            t,
            _list(r),
            _refusal(OspexMatching.OspexMatching__BadSignature.selector, taking ? takingOrder : restingOrder),
            string.concat(what, taking ? ", on the taking order" : ", on a resting order")
        );
    }

    /// Break: in OspexMatching._checkSigned, skip the signature for a resting order. Others turn it red: the
    /// signature skipped for the taking order; the signer compared with the sender in place of the account; the
    /// domain's version "3" made "1"; and each of the nine fields left out of the hash, one at a time.
    function test_neverLine_anOrderBindsOnlyTheAccountThatSignedIt() public {
        _signatureCases(Side.B);
        _signatureCases(Side.A);
    }

    function _signatureCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        uint256 otherGame = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, 10_000);
        OspexMatching.SignedOrder memory resting = _rest(m1, game, _other(takingSide), 200, 10_000);
        bytes32 before = _print();

        for (uint256 role; role < 2; ++role) {
            bool onTaking = role == 0;
            OspexMatching.OspexOrder memory o = onTaking ? taking.order : resting.order;
            uint256 key = onTaking ? tk.key : m1.key;
            bytes32 digest = _digest(o);

            // Another key's signature over the right hash.
            _badlySigned(taking, resting, onTaking, _signature(m2.key, digest), "another key's signature");
            // The sender's own key: the signer must be the account, not the address that sends.
            (, uint256 senderKey) = makeAddrAndKey("sender");
            _badlySigned(taking, resting, onTaking, _signature(senderKey, digest), "the sender's signature");
            // An empty signature, a short one of 64 bytes, and one of 66.
            bytes memory good = _signature(key, digest);
            _badlySigned(taking, resting, onTaking, "", "an empty signature");
            _badlySigned(taking, resting, onTaking, _slice(good, 64), "a signature of 64 bytes");
            _badlySigned(taking, resting, onTaking, bytes.concat(good, hex"00"), "a signature of 66 bytes");
            // The high-s twin of a good signature: the same key and the same hash, the other root.
            _badlySigned(taking, resting, onTaking, _highS(key, digest), "the high-s twin of a good signature");

            // The right key, over something else: v2's domain version; v2's name for the type; a first field
            // named maker; another chain; another contract's address.
            _badlySigned(
                taking,
                resting,
                onTaking,
                _signature(key, _digestUnder(o, ORDER_TYPE, "1", block.chainid, address(matching))),
                "signed under the version 1"
            );
            _badlySigned(
                taking,
                resting,
                onTaking,
                _signature(
                    key,
                    _digestUnder(
                        o,
                        "OspexCommitment(address account,uint256 gameId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry)",
                        DOMAIN_VERSION,
                        block.chainid,
                        address(matching)
                    )
                ),
                "signed under v2's name for the type"
            );
            _badlySigned(
                taking,
                resting,
                onTaking,
                _signature(
                    key,
                    _digestUnder(
                        o,
                        "OspexOrder(address maker,uint256 gameId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry)",
                        DOMAIN_VERSION,
                        block.chainid,
                        address(matching)
                    )
                ),
                "signed with the first field named maker"
            );
            _badlySigned(
                taking,
                resting,
                onTaking,
                _signature(key, _digestUnder(o, ORDER_TYPE, DOMAIN_VERSION, block.chainid + 1, address(matching))),
                "signed for another chain"
            );
            _badlySigned(
                taking,
                resting,
                onTaking,
                _signature(key, _digestUnder(o, ORDER_TYPE, DOMAIN_VERSION, block.chainid, address(positions))),
                "signed for another contract"
            );

            // Each of the nine values changed after signing, one at a time. The signature is the account's own,
            // over the order as it stood before the change; the order as sent is otherwise one that fills.
            for (uint256 field; field < 9; ++field) {
                OspexMatching.OspexOrder memory signedAs = _copy(o);
                if (field == 0) signedAs.account = m2.a;
                if (field == 1) signedAs.gameId = otherGame;
                if (field == 2) signedAs.scorer = address(spread);
                if (field == 3) signedAs.lineTicks = -35;
                if (field == 4) signedAs.positionType = _other(o.positionType);
                if (field == 5) signedAs.oddsTick = 210;
                if (field == 6) signedAs.riskAmount = 20_000;
                if (field == 7) signedAs.nonce = o.nonce + 1;
                if (field == 8) signedAs.expiry = o.expiry + 1;
                _badlySigned(
                    taking,
                    resting,
                    onTaking,
                    _signature(key, _digest(signedAs)),
                    string.concat("field ", vm.toString(field), " changed after signing")
                );
            }
        }
        assertEq(_print(), before, "a badly signed Cross left something");

        // The same two orders with their own signatures fill.
        _cross(sender, taking, _list(resting));
        assertEq(_filled(taking), 10_000, "the well signed Cross");
    }

    function _copy(OspexMatching.OspexOrder memory o) internal pure returns (OspexMatching.OspexOrder memory c) {
        c = _order(
            o.account, o.gameId, o.scorer, o.lineTicks, o.positionType, o.oddsTick, o.riskAmount, o.nonce, o.expiry
        );
    }

    function _slice(bytes memory b, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = b[i];
        }
    }

    /// @dev The other valid signature for the same key and hash: s replaced by the curve order less s, and the
    ///      recovery byte flipped. It recovers the same address, and the recovery the contract uses refuses it.
    function _highS(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 twin = bytes32(n - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;
        require(ecrecover(digest, flipped, r, twin) == vm.addr(key), "not the twin");
        return abi.encodePacked(r, twin, flipped);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 14. Every resting order is on the taking order's market, on the other side, at a price that meets.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkResting, delete the game's test. Others turn it red: the market contract's
    /// test deleted; the line's; the side's; and the prices'.
    function test_neverLine_everyRestingOrderIsOnTheTakingOrdersMarketSideAndPrice() public {
        _marketCases(Side.B);
        _marketCases(Side.A);
    }

    function _marketCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        uint256 otherGame = _verifiedGame();
        Side restingSide = _other(takingSide);
        uint256 soon = vm.getBlockTimestamp() + 1 days;
        // A taking order at 1.90, and a resting order that fills against it, listed first in every case.
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 190, 20_000);
        OspexMatching.SignedOrder memory good = _rest(m1, game, restingSide, 211, 10_000);
        bytes32 before = _print();

        // Another game.
        OspexMatching.SignedOrder memory bad = _rest(m2, otherGame, restingSide, 211, 10_000);
        _refused(
            sender,
            taking,
            _list(good, bad),
            _refusal(OspexMatching.OspexMatching__OtherGame.selector, bad),
            "another game"
        );
        // Another market contract.
        bad = _signed(_order(m2.a, game, address(spread), 0, restingSide, 211, 10_000, nextNonce++, soon), m2.key);
        _refused(
            sender,
            taking,
            _list(good, bad),
            _refusal(OspexMatching.OspexMatching__OtherScorer.selector, bad),
            "another market contract"
        );
        // Another line.
        bad = _signed(_order(m2.a, game, address(moneyline), 5, restingSide, 211, 10_000, nextNonce++, soon), m2.key);
        _refused(
            sender,
            taking,
            _list(good, bad),
            _refusal(OspexMatching.OspexMatching__OtherLine.selector, bad),
            "another line"
        );
        // The same side.
        bad = _rest(m2, game, takingSide, 211, 10_000);
        _refused(
            sender,
            taking,
            _list(good, bad),
            _refusal(OspexMatching.OspexMatching__SameSide.selector, bad),
            "the same side"
        );
        // A price one tick short: against 1.90, 2.11 is the last resting price that meets (111 x 90 = 9,990),
        // and 2.12 does not (112 x 90 = 10,080).
        bad = _rest(m2, game, restingSide, 212, 10_000);
        _refused(
            sender,
            taking,
            _list(good, bad),
            _refusal(OspexMatching.OspexMatching__PricesDoNotMeet.selector, bad),
            "a price one tick short"
        );
        assertEq(_print(), before, "a Cross with a resting order off the market left something");

        // A side that is neither: the fifth word of an order is 2, in the taking order and in a resting order.
        // The call reverts and nothing fills.
        bytes memory call = abi.encodeCall(OspexMatching.cross, (taking, _list(good)));
        uint256 takingAt = 4 + _wordAt(call, 4);
        uint256 listAt = 4 + _wordAt(call, 36);
        uint256 restingAt = listAt + 32 + _wordAt(call, listAt + 32);
        assertEq(_wordAt(call, takingAt + 4 * 32), uint8(takingSide), "the taking order's side, where it is expected");
        assertEq(
            _wordAt(call, restingAt + 4 * 32), uint8(restingSide), "the resting order's side, where it is expected"
        );
        // Each is signed for the side it then carries, so that its side is the one thing wrong with it.
        _neither(call, takingAt, taking, tk.key);
        _neither(call, restingAt, good, m1.key);
        assertEq(_print(), before, "a Cross with a side that is neither left something");

        // The untouched call fills: the resting order at the last price that meets.
        vm.prank(sender, crossOrigin);
        (bool filled,) = address(matching).call(call);
        assertTrue(filled, "the Cross whose orders are on one market, on two sides, at prices that meet");
        assertEq(_filled(good), 10_000, "a hundred lots at 2.11");
        assertEq(_filled(taking), 11_100, "the taking stake at 2.11: 111 for every 100");
    }

    /// @dev Sends `call` with the side of the order that starts at `structAt` written as 2, and with that
    ///      order's signature replaced by its account's signature over the order as it then reads. The call
    ///      reverts with no data: the side is refused where the order is read, before any check of the
    ///      Cross's own, and so not for its signature.
    function _neither(bytes memory call, uint256 structAt, OspexMatching.SignedOrder memory signed, uint256 key)
        internal
    {
        OspexMatching.OspexOrder memory o = signed.order;
        assertEq(_digestWithSide(o, uint8(o.positionType)), _hash(signed), "the digest, built word by word");
        uint256 sigAt = structAt + _wordAt(call, structAt + 9 * 32);
        assertEq(_wordAt(call, sigAt), 65, "the signature's length, where it is expected");
        bytes memory neither = bytes.concat(call);
        neither[structAt + 4 * 32 + 31] = 0x02;
        bytes memory signature = _signature(key, _digestWithSide(o, 2));
        for (uint256 i; i < 65; ++i) {
            neither[sigAt + 32 + i] = signature[i];
        }
        vm.prank(sender, crossOrigin);
        (bool ok, bytes memory err) = address(matching).call(neither);
        assertFalse(ok, "an order on a side that is neither filled");
        assertEq(err, "", "an order on a side that is neither, refused for another reason");
    }

    /// @dev An order's digest under this set's domain, with its side word written as `side`: a value the
    ///      Side type cannot hold may be given.
    function _digestWithSide(OspexMatching.OspexOrder memory o, uint8 side) internal view returns (bytes32) {
        bytes memory head = abi.encode(keccak256(bytes(ORDER_TYPE)), o.account, o.gameId, o.scorer, o.lineTicks);
        bytes memory tail = abi.encode(side, o.oddsTick, o.riskAmount, o.nonce, o.expiry);
        return keccak256(
            abi.encodePacked(hex"1901", _domainSeparator(address(matching)), keccak256(bytes.concat(head, tail)))
        );
    }

    /// @dev The 32-byte word of `data` that starts at `at`.
    function _wordAt(bytes memory data, uint256 at) internal pure returns (uint256 word) {
        require(at + 32 <= data.length, "past the end");
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), at))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // 15. An order that is not admissible fills in neither role.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMatching._checkSigned, delete the price's lower bound. Others turn it red: its upper
    /// bound deleted; the zero stake let through; the lot rule deleted; and the lot rule kept for resting
    /// orders alone.
    function test_neverLine_anOrderThatIsNotAdmissibleFillsInNeitherRole() public {
        _admissibleCases(Side.B);
        _admissibleCases(Side.A);
    }

    function _admissibleCases(Side takingSide) internal {
        uint256 game = _verifiedGame();
        Side restingSide = _other(takingSide);
        bytes32 before = _print();

        // A price out of range, in each role: 1.00 and under, and 101.01 and over.
        uint16[5] memory prices = [uint16(100), 99, 0, 10_101, type(uint16).max];
        for (uint256 i; i < prices.length; ++i) {
            OspexMatching.SignedOrder memory bad = _take(tk, game, takingSide, prices[i], 10_000);
            _refused(
                sender,
                bad,
                _list(_rest(m1, game, restingSide, 200, 10_000)),
                _refusal(OspexMatching.OspexMatching__PriceOutOfRange.selector, bad),
                "a taking order at a price out of range"
            );
            bad = _rest(m1, game, restingSide, prices[i], 10_000);
            _refused(
                sender,
                _take(tk, game, takingSide, 101, 10_000),
                _list(bad),
                _refusal(OspexMatching.OspexMatching__PriceOutOfRange.selector, bad),
                "a resting order at a price out of range"
            );
        }
        // A stake of zero, and stakes that are not whole lots, in each role.
        uint256[4] memory stakes = [uint256(0), 150, 99, 10_001];
        for (uint256 i; i < stakes.length; ++i) {
            OspexMatching.SignedOrder memory bad = _take(tk, game, takingSide, 200, stakes[i]);
            _refused(
                sender,
                bad,
                _list(_rest(m1, game, restingSide, 200, 10_000)),
                _refusal(OspexMatching.OspexMatching__StakeNotInLots.selector, bad),
                "a taking order for a stake that is not in lots"
            );
            bad = _rest(m1, game, restingSide, 200, stakes[i]);
            _refused(
                sender,
                _take(tk, game, takingSide, 200, 10_000),
                _list(bad),
                _refusal(OspexMatching.OspexMatching__StakeNotInLots.selector, bad),
                "a resting order for a stake that is not in lots"
            );
        }
        assertEq(_print(), before, "a Cross with an order that is not admissible left something");

        // The two ends of the price range are accepted, in each role: 1.01 resting against 101.00 taking, a
        // hundred lots against a hundred units; and 101.00 resting against 1.01 taking, one lot against 10,000.
        OspexMatching.SignedOrder memory low = _rest(m1, game, restingSide, 101, 10_000);
        OspexMatching.SignedOrder memory high = _take(tk, game, takingSide, 10_100, 100);
        _cross(sender, high, _list(low));
        assertEq(_filled(low), 10_000, "resting at 1.01");
        assertEq(_filled(high), 100, "taking at 101.00, for the smallest stake");
        low = _take(tk, game, takingSide, 101, 10_000);
        high = _rest(m1, game, restingSide, 10_100, 100);
        _cross(sender, low, _list(high));
        assertEq(_filled(high), 100, "resting at 101.00, for the smallest stake");
        assertEq(_filled(low), 10_000, "taking at 1.01");
    }
}

/// @notice One signature made outside the contracts, frozen. The typed data below was signed by two EIP-712
///         implementations that share no code with these tests or with the contracts, a command-line signer
///         and a Python library, and both gave the signature written out here. The matching module, placed at
///         the address the typed data names, on the chain it names, accepts it: the order fills.
///
///         The typed data: domain name "Ospex", version "3", chainId 137, verifyingContract
///         0x00000000000000000000000000000000C0550001; primary type OspexOrder, its nine fields in order, as
///         address, uint256, address, int32, uint8, uint16, uint256, uint256, uint256; message account
///         0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, gameId 1, scorer
///         0x00000000000000000000000000000000C0550002, lineTicks 0, positionType 0, oddsTick 200, riskAmount
///         10000, nonce 7, expiry 1900000000. The key is the test key 0xa11ce.
contract OspexCrossFrozenSignatureTest is CrossBase {
    address internal constant FROZEN_MATCHING = 0x00000000000000000000000000000000C0550001;
    address internal constant FROZEN_SCORER = 0x00000000000000000000000000000000c0550002;
    uint256 internal constant FROZEN_KEY = 0xa11ce;
    address internal constant FROZEN_ACCOUNT = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
    bytes32 internal constant FROZEN_DIGEST = 0x428d170f2fc43ee0a5b21f7433a1a99bba76a4203d2985a47cbc3b5f83549219;
    bytes internal constant FROZEN_SIGNATURE =
        hex"c088e0b30cebeb6ee484464468e0bca2311e2116ae979d6e6eb87b0ec732d4fc189b1131fb551598ea59adb2970ed025a1be002ee2b29ef20a9df2b23b6a29d71c";

    function setUp() public override {
        super.setUp();
        // The same set, with the matching module and the moneyline at the two addresses the typed data names,
        // on the chain it names.
        vm.chainId(137);
        vm.startPrank(deployer, deployer);
        core = new OspexBetting(address(games), address(token));
        markets = new OspexMarkets(address(core));
        positions = new OspexPositions(address(core));
        spread = new OspexSpreadScorer(address(core));
        total = new OspexTotalScorer(address(core));
        vm.stopPrank();
        deployCodeTo("OspexMatching.sol:OspexMatching", abi.encode(address(core)), FROZEN_MATCHING);
        deployCodeTo("OspexMoneylineScorer.sol:OspexMoneylineScorer", abi.encode(address(core)), FROZEN_SCORER);
        matching = OspexMatching(FROZEN_MATCHING);
        moneyline = OspexMoneylineScorer(FROZEN_SCORER);
        vm.startPrank(deployer, deployer);
        core.bootstrapModules(_types(), _modules());
        core.finalize();
        vm.stopPrank();
    }

    /// Break: in OspexMatching.sol, make the domain's version "1"; or name the type's first field `maker`; or
    /// leave any field out of the hash. The frozen signature is then over another hash, and the order is
    /// refused.
    function test_theFrozenOutsideSignatureIsAccepted() public {
        assertEq(vm.addr(FROZEN_KEY), FROZEN_ACCOUNT, "the frozen account is the frozen key's");
        assertEq(block.chainid, 137, "the chain");
        assertEq(address(matching), FROZEN_MATCHING, "the matching module's address");
        uint256 game = _verifiedGame();
        assertEq(game, 1, "the game's id");
        _fundCoin(FROZEN_ACCOUNT);
        Signer memory tk = _account("taking account");
        _register(FROZEN_ACCOUNT, sender);
        _register(tk.a, sender);

        OspexMatching.OspexOrder memory frozen =
            _order(FROZEN_ACCOUNT, 1, FROZEN_SCORER, 0, Side.A, 200, 10_000, 7, 1_900_000_000);
        // The contract's hash of the order is the digest the two outside signers signed, and so is the hash
        // these tests build.
        assertEq(matching.getOrderHash(frozen), FROZEN_DIGEST, "the contract's hash of the frozen order");
        assertEq(_digest(frozen), FROZEN_DIGEST, "the hash these tests build");
        assertEq(matching.ORDER_TYPEHASH(), keccak256(bytes(ORDER_TYPE)), "the typehash is the type string's");

        // The frozen signature fills.
        OspexMatching.SignedOrder memory resting =
            OspexMatching.SignedOrder({order: frozen, signature: FROZEN_SIGNATURE});
        OspexMatching.SignedOrder memory taking = _take(tk, game, Side.B, 200, 10_000);
        _cross(sender, taking, _list(resting));
        assertEq(matching.s_filledRisk(FROZEN_DIGEST), 10_000, "the frozen order filled");
        _assertPosition(1, FROZEN_ACCOUNT, Side.A, 10_000, 10_000, "the frozen account's position");
        _assertPosition(1, tk.a, Side.B, 10_000, 10_000, "the taking account's position");
    }
}
