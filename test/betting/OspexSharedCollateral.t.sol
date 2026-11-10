// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOspexGames} from "../../src/games/IOspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {FalseCoin, LyingCoin, RefusingCoin, TestCoin, TrickCoin} from "../games/CoinFixtures.sol";
import {CallbackAccount} from "./CrossFixtures.sol";
import {CrossBase} from "./CrossBase.sol";
import {GrossPositionsReference} from "./GrossPositionsReference.sol";

/// @dev A contract that sends a claim for anyone: the claim's caller is a contract, not a key.
contract ClaimCaller {
    function claim(OspexPositions positions, uint256 marketId, address account, Side side) external returns (uint256) {
        return positions.claimPositionFor(marketId, account, side);
    }
}

/// @dev What shared collateral's tests share. Amounts are literals worked by hand, in the plan's USDC figures
///      times U where the plan speaks USDC and in raw units where it speaks units; the worst loss is written out
///      here once, as the oracle a test re-derives from the fills it sent, never read from the contract.
abstract contract SharedCollateralBase is CrossBase {
    /// @dev One USDC in a coin of six decimals.
    uint256 internal constant U = 1_000_000;
    bytes32 internal constant HELD_CHANGED_TOPIC = keccak256("HeldChanged(uint256,address,uint256,uint256,uint256)");
    bytes32 internal constant PAY_BACK_REFUSED_TOPIC = keccak256("PayBackRefused(uint256,address,uint256,uint256)");
    bytes32 internal constant POSITION_FILLED_TOPIC =
        keccak256("PositionFilled(uint256,address,address,uint8,uint8,uint256,uint256)");

    struct Held {
        uint256 marketId;
        address account;
        uint256 pulled;
        uint256 paidBack;
        uint256 held;
    }

    struct Refused {
        uint256 marketId;
        address account;
        uint256 amount;
        uint256 held;
    }

    /// @dev The maker and the bettor of the plan's example, keys; funded and registered by _ready.
    Signer internal M;
    Signer internal T;

    function setUp() public virtual override {
        super.setUp();
        (M.a, M.key) = makeAddrAndKey("the maker");
        (T.a, T.key) = makeAddrAndKey("the bettor");
    }

    /// @dev Funds `x` in the set's coin, approves the positions module, and registers the sender as its courier.
    function _ready(Signer memory x) internal {
        _fundCoin(x.a);
        _register(x.a, sender);
    }

    // ──────────────────────────── Legs ─────────────────────────────────

    /// @dev A resting order of `m` on `side` of the game's moneyline at the price that makes the taking stake
    ///      `takerRisk` against `makerRisk`: 100 + takerRisk x 100 / makerRisk ticks, which must be whole.
    function _restFor(Signer memory m, uint256 game, Side side, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (OspexMatching.SignedOrder memory)
    {
        require(makerRisk != 0 && makerRisk % 100 == 0, "a resting stake not in lots");
        require((takerRisk * 100) % makerRisk == 0, "no price in ticks makes this leg");
        uint256 p = takerRisk * 100 / makerRisk;
        require(p >= 1 && p <= 10_000, "the price is not admissible");
        return _rest(m, game, side, 100 + p, makerRisk);
    }

    /// @dev One Cross of one leg on the game's moneyline, sent by the sender: `t` takes `takerSide` for
    ///      `takerRisk`, at 1.01, against `m` resting the other side for `makerRisk`.
    function _tryLeg(
        Signer memory m,
        Signer memory t,
        uint256 game,
        Side takerSide,
        uint256 makerRisk,
        uint256 takerRisk
    ) internal returns (bool ok, bytes memory err) {
        return _tryCross(
            sender,
            _take(t, game, takerSide, 101, takerRisk),
            _list(_restFor(m, game, _other(takerSide), makerRisk, takerRisk))
        );
    }

    /// @dev The same leg, which must fill. Returns the market.
    function _leg(Signer memory m, Signer memory t, uint256 game, Side takerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (uint256 market)
    {
        (bool ok, bytes memory err) = _tryLeg(m, t, game, takerSide, makerRisk, takerRisk);
        assertTrue(ok, string.concat("the leg was refused: ", vm.toString(err)));
        market = markets.getMarketId(game, address(moneyline), 0);
    }

    /// @dev A Cross of several legs, one taking order for their sum, each resting order at its own price.
    function _tryLegs(
        Signer memory t,
        uint256 game,
        Side takerSide,
        Signer[] memory ms,
        uint256[] memory makerRisks,
        uint256[] memory takerRisks
    ) internal returns (bool ok, bytes memory err) {
        uint256 sum;
        OspexMatching.SignedOrder[] memory resting = new OspexMatching.SignedOrder[](ms.length);
        for (uint256 i; i < ms.length; ++i) {
            sum += takerRisks[i];
            resting[i] = _restFor(ms[i], game, _other(takerSide), makerRisks[i], takerRisks[i]);
        }
        return _tryCross(sender, _take(t, game, takerSide, 101, sum), resting);
    }

    function _legs(
        Signer memory t,
        uint256 game,
        Side takerSide,
        Signer[] memory ms,
        uint256[] memory makerRisks,
        uint256[] memory takerRisks
    ) internal returns (uint256 market) {
        (bool ok, bytes memory err) = _tryLegs(t, game, takerSide, ms, makerRisks, takerRisks);
        assertTrue(ok, string.concat("the Cross was refused: ", vm.toString(err)));
        market = markets.getMarketId(game, address(moneyline), 0);
    }

    function _two(Signer memory a, Signer memory b) internal pure returns (Signer[] memory s) {
        s = new Signer[](2);
        s[0] = a;
        s[1] = b;
    }

    function _three(Signer memory a, Signer memory b, Signer memory c) internal pure returns (Signer[] memory s) {
        s = new Signer[](3);
        s[0] = a;
        s[1] = b;
        s[2] = c;
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory n) {
        n = new uint256[](2);
        n[0] = a;
        n[1] = b;
    }

    function _triple(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory n) {
        n = new uint256[](3);
        n[0] = a;
        n[1] = b;
        n[2] = c;
    }

    // ──────────────────────────── Settlement and claims ────────────────

    function _settleHome(uint256 game, uint256 market) internal {
        _score(game, HOME, AWAY);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home), "the outcome is not Home");
    }

    function _settleAway(uint256 game, uint256 market) internal {
        _score(game, AWAY, HOME);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Away), "the outcome is not Away");
    }

    function _settlePush(uint256 game, uint256 market) internal {
        _score(game, 100, 100);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Push), "the outcome is not Push");
    }

    /// @dev The void written by the report at start + n.
    function _settleVoid(uint256 game, uint256 market) internal {
        vm.warp(START + WINDOW);
        _voidBy(first, game);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Void), "the outcome is not Void");
    }

    function _tryClaimFor(address caller, uint256 market, address account, Side side)
        internal
        returns (bool ok, bytes memory err)
    {
        vm.prank(caller, caller);
        (ok, err) = address(positions).call(abi.encodeCall(OspexPositions.claimPositionFor, (market, account, side)));
    }

    /// @dev A claim for anyone that must pay: what the account received, which the call must also answer; the
    ///      caller's coin, when the caller is not the account, does not move.
    function _claimFor(address caller, uint256 market, address account, Side side) internal returns (uint256 paid) {
        uint256 before = _coin().balanceOf(account);
        uint256 callerBefore = _coin().balanceOf(caller);
        (bool ok, bytes memory err) = _tryClaimFor(caller, market, account, side);
        assertTrue(ok, string.concat("the claim was refused: ", vm.toString(err)));
        paid = _coin().balanceOf(account) - before;
        assertEq(abi.decode(err, (uint256)), paid, "the claim's answer is not what was paid");
        if (caller != account) assertEq(_coin().balanceOf(caller), callerBefore, "the caller's coin moved");
    }

    /// @dev A claim refused with exactly the error named, no argument: by name and not by a panic.
    function _refusedClaim(
        address caller,
        uint256 market,
        address account,
        Side side,
        bytes4 selector,
        string memory what
    ) internal {
        (bool ok, bytes memory err) = _tryClaimFor(caller, market, account, side);
        assertFalse(ok, string.concat("paid: ", what));
        assertEq(err, abi.encodeWithSelector(selector), what);
    }

    bytes4 internal constant NO_PAYOUT = bytes4(keccak256("OspexPositions__NoPayout()"));
    bytes4 internal constant ALREADY_CLAIMED = bytes4(keccak256("OspexPositions__AlreadyClaimed()"));

    /// @dev The coin change of `who` since `before`, signed.
    function _change(uint256 before, address who) internal view returns (int256) {
        return int256(_coin().balanceOf(who)) - int256(before);
    }

    // ──────────────────────────── The oracle ───────────────────────────

    /// @dev The worst loss, written out here: if side A wins the account wins profitA and loses riskB; if side
    ///      B wins, the mirror; a push or a void loses nothing.
    function _worstByHand(uint256 riskA, uint256 profitA, uint256 riskB, uint256 profitB)
        internal
        pure
        returns (uint256)
    {
        uint256 ifA = riskB > profitA ? riskB - profitA : 0;
        uint256 ifB = riskA > profitB ? riskA - profitB : 0;
        return ifA > ifB ? ifA : ifB;
    }

    // ──────────────────────────── The events ───────────────────────────

    /// @dev The held changes among a call's logs, in order, each checked against its copy through the hub.
    function _heldChanges(Vm.Log[] memory logs) internal view returns (Held[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(positions) && logs[i].topics[0] == HELD_CHANGED_TOPIC) ++n;
        }
        out = new Held[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(positions) || logs[i].topics[0] != HELD_CHANGED_TOPIC) continue;
            (uint256 pulled, uint256 paidBack, uint256 held) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            out[n++] = Held({
                marketId: uint256(logs[i].topics[1]),
                account: address(uint160(uint256(logs[i].topics[2]))),
                pulled: pulled,
                paidBack: paidBack,
                held: held
            });
        }
        bytes[] memory hub = _hubCopies(logs, keccak256("HELD_CHANGED"));
        assertEq(hub.length, n, "the held changes and their hub copies are not the same number");
        for (uint256 i; i < n; ++i) {
            assertEq(
                hub[i],
                abi.encode(out[i].marketId, out[i].account, out[i].pulled, out[i].paidBack, out[i].held),
                "a held change's hub copy differs from the event"
            );
        }
    }

    /// @dev The refused pay-backs among a call's logs, in order, each checked against its hub copy.
    function _refusals(Vm.Log[] memory logs) internal view returns (Refused[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(positions) && logs[i].topics[0] == PAY_BACK_REFUSED_TOPIC) ++n;
        }
        out = new Refused[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(positions) || logs[i].topics[0] != PAY_BACK_REFUSED_TOPIC) continue;
            (uint256 amount, uint256 held) = abi.decode(logs[i].data, (uint256, uint256));
            out[n++] = Refused({
                marketId: uint256(logs[i].topics[1]),
                account: address(uint160(uint256(logs[i].topics[2]))),
                amount: amount,
                held: held
            });
        }
        bytes[] memory hub = _hubCopies(logs, keccak256("PAY_BACK_REFUSED"));
        assertEq(hub.length, n, "the refusals and their hub copies are not the same number");
        for (uint256 i; i < n; ++i) {
            assertEq(
                hub[i],
                abi.encode(out[i].marketId, out[i].account, out[i].amount, out[i].held),
                "a refusal's hub copy differs from the event"
            );
        }
    }

    /// @dev The payloads of the hub's copies under `tag`, emitted for the positions module, in order.
    function _hubCopies(Vm.Log[] memory logs, bytes32 tag) internal view returns (bytes[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics.length == 3 && logs[i].topics[1] == tag) ++n;
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics.length != 3 || logs[i].topics[1] != tag) continue;
            assertEq(
                logs[i].topics[2], bytes32(uint256(uint160(address(positions)))), "a hub copy names another module"
            );
            out[n++] = abi.decode(logs[i].data, (bytes));
        }
    }

    /// @dev How many of the held changes are `who`'s.
    function _heldOf(Held[] memory hs, address who) internal pure returns (uint256 n) {
        for (uint256 i; i < hs.length; ++i) {
            if (hs[i].account == who) ++n;
        }
    }

    /// @dev One held change, field by field.
    function _assertHeld(
        Held memory got,
        address who,
        uint256 pulled,
        uint256 paidBack,
        uint256 held,
        string memory what
    ) internal pure {
        assertEq(got.account, who, string.concat(what, ": the account"));
        assertEq(got.pulled, pulled, string.concat(what, ": pulled"));
        assertEq(got.paidBack, paidBack, string.concat(what, ": paid back"));
        assertEq(got.held, held, string.concat(what, ": held after"));
    }

    /// @dev The index of the last PositionFilled among the logs, or the length when there is none.
    function _lastFilled(Vm.Log[] memory logs) internal view returns (uint256 at) {
        at = logs.length;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(positions) && logs[i].topics[0] == POSITION_FILLED_TOPIC) at = i;
        }
    }

    /// @dev The index among the logs of the first held change of `who` at or after `from`, or the length.
    function _firstHeldOf(Vm.Log[] memory logs, address who, uint256 from) internal view returns (uint256) {
        for (uint256 i = from; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(positions) && logs[i].topics[0] == HELD_CHANGED_TOPIC
                    && address(uint160(uint256(logs[i].topics[2]))) == who
            ) return i;
        }
        return logs.length;
    }

    /// @dev The storage slot of s_heldTotal[market]: the mapping is the module's third state variable.
    function _heldTotalSlot(uint256 market) internal pure returns (bytes32) {
        return keccak256(abi.encode(market, uint256(2)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// L229. What the contract holds for an account never falls below its worst loss on that market, under any
// order of fills, voids and settlement.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralHeldTest is SharedCollateralBase {
    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
    }

    /// Break: in OspexPositions._worst, drop the first term, `uint256 ifAWins = 0;`. Others turn it red: the
    /// second term dropped; the terms paired wrongly, riskB - profitB and riskA - profitA; the zero branch
    /// replaced by the reversed difference; the taking account's pull removed from finishFills; the resting pull
    /// removed from _record. Swapping A and B throughout is equivalent and is no break.
    function test_neverLine_heldCoversTheWorstLoss_everyOrderOfFills() public {
        _theRulingsRows();
        _partOnesThreeFills();
        _fourFillsInEveryOrder();
    }

    /// @dev The ruling's five rows, the maker against one bettor at 2.10, the fifth row as two fills: held
    ///      200, 145, 130, 20, 115, 0 against gross 200, 250, 550, 650, 850, 1,000, a two-sided book whose worst
    ///      loss is zero at the end. Each row's coin movement is a literal; at the end the maker's claim is 50
    ///      on either win and nothing on a push, and the bettor's 50 on a push alone.
    function _theRulingsRows() internal {
        uint256 game = _verifiedGame();
        // The bettor's side, the maker's stake and the bettor's, each row; the maker rests the other side.
        uint8[6] memory sides = [0, 1, 1, 0, 0, 1];
        uint256[6] memory ms = [uint256(200), 50, 300, 100, 200, 150];
        uint256[6] memory ts = [uint256(220), 55, 330, 110, 220, 165];
        uint256[6] memory heldM = [uint256(200), 145, 130, 20, 115, 0];
        uint256[6] memory heldT = [uint256(220), 170, 185, 85, 200, 50];
        uint256[6] memory gross = [uint256(200), 250, 550, 650, 850, 1000];
        int256[6] memory moveM = [int256(-200), 55, 15, 110, -95, 115];
        int256[6] memory moveT = [int256(-220), 50, -15, 100, -115, 150];
        uint256 market;
        uint256 staked;
        for (uint256 i; i < 6; ++i) {
            string memory row = string.concat("row ", vm.toString(i + 1));
            uint256 mBefore = _coin().balanceOf(M.a);
            uint256 tBefore = _coin().balanceOf(T.a);
            vm.recordLogs();
            market = _leg(M, T, game, Side(sides[i]), ms[i] * U, ts[i] * U);
            staked += ms[i] * U;
            assertEq(staked, gross[i] * U, string.concat(row, ": the gross count"));
            assertEq(positions.s_held(market, M.a), heldM[i] * U, string.concat(row, ": the maker's held amount"));
            assertEq(positions.s_held(market, T.a), heldT[i] * U, string.concat(row, ": the bettor's held amount"));
            assertEq(positions.s_heldTotal(market), (heldM[i] + heldT[i]) * U, string.concat(row, ": the total"));
            assertEq(_change(mBefore, M.a), moveM[i] * int256(U), string.concat(row, ": the maker's coin"));
            assertEq(_change(tBefore, T.a), moveT[i] * int256(U), string.concat(row, ": the bettor's coin"));
            assertEq(
                _coin().balanceOf(address(positions)), (heldM[i] + heldT[i]) * U, string.concat(row, ": the contract")
            );
            // No pull above the row's stake of the account pulled.
            Held[] memory hs = _heldChanges(vm.getRecordedLogs());
            for (uint256 j; j < hs.length; ++j) {
                uint256 stake = hs[j].account == M.a ? ms[i] * U : ts[i] * U;
                assertLe(hs[j].pulled, stake, string.concat(row, ": a pull above the stake"));
            }
        }
        assertEq(_coin().balanceOf(address(positions)), 50 * U, "the fifth row's book holds the bettor's 50 alone");

        uint256 snap = vm.snapshotState();
        _settleHome(game, market);
        assertEq(_claimFor(stranger, market, M.a, Side.A), 50 * U, "home: the maker's 50, on its side A record");
        _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, "home: the maker's side B record");
        _refusedClaim(stranger, market, T.a, Side.A, NO_PAYOUT, "home: the bettor's side A record");
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, "home: the bettor's side B record");
        assertEq(positions.s_heldTotal(market), 0, "home: the total after every claim");
        assertEq(_coin().balanceOf(address(positions)), 0, "home: coin left in the contract");
        vm.revertToState(snap);

        _settleAway(game, market);
        assertEq(_claimFor(stranger, market, M.a, Side.B), 50 * U, "away: the maker's 50, on its side B record");
        _refusedClaim(stranger, market, M.a, Side.A, NO_PAYOUT, "away: the maker's side A record");
        _refusedClaim(stranger, market, T.a, Side.A, NO_PAYOUT, "away: the bettor's side A record");
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, "away: the bettor's side B record");
        assertEq(_coin().balanceOf(address(positions)), 0, "away: coin left in the contract");
        vm.revertToState(snap);

        _settlePush(game, market);
        _refusedClaim(
            stranger, market, M.a, Side.A, NO_PAYOUT, "push: the maker, whose worst loss is zero, holds nothing"
        );
        _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, "push: the maker's side B record");
        assertEq(_claimFor(stranger, market, T.a, Side.A), 50 * U, "push: the bettor's 50, on its side A record");
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, "push: the bettor's side B record, the rest, nothing");
        assertEq(_coin().balanceOf(address(positions)), 0, "push: coin left in the contract");
        vm.revertToState(snap);
    }

    /// @dev Part 1's three fills: held 100/110, 45/60, 40/65; the market 210, 105, 105; fill 2 pays 55 and 50
    ///      back, fill 3 pulls the bettor 5 and pays the maker 5; the claim after a home win pays the maker 105
    ///      on its side A record, and nobody ends anywhere else.
    function _partOnesThreeFills() internal {
        uint256 game = _verifiedGame();
        uint256 mStart = _coin().balanceOf(M.a);
        uint256 tStart = _coin().balanceOf(T.a);
        uint256 cStart = _coin().balanceOf(address(positions));

        vm.recordLogs();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 110 * U);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "fill 1: two pulls");
        _assertHeld(hs[0], M.a, 100 * U, 0, 100 * U, "fill 1: the maker's pull, at its leg");
        _assertHeld(hs[1], T.a, 110 * U, 0, 110 * U, "fill 1: the bettor's pull, at the end");
        assertEq(hs[0].marketId, market, "fill 1: the maker's pull names the market");
        assertEq(hs[1].marketId, market, "fill 1: the bettor's pull names the market");
        assertEq(positions.s_heldTotal(market), 210 * U, "fill 1: the market");

        // Fill 2 is sent with a cancelled order of the maker's listed first: the maker's filled leg is the second
        // listed and the first filled, and its pay-back is made all the same.
        OspexMatching.SignedOrder memory dead = _restFor(M, game, Side.A, 50 * U, 55 * U);
        vm.prank(M.a);
        matching.cancelOrder(dead.order);
        vm.recordLogs();
        _cross(sender, _take(T, game, Side.B, 101, 55 * U), _list(dead, _restFor(M, game, Side.A, 50 * U, 55 * U)));
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "fill 2: two pay-backs and no pull");
        _assertHeld(hs[0], T.a, 0, 50 * U, 60 * U, "fill 2: the bettor's pay-back, the taking account first");
        _assertHeld(hs[1], M.a, 0, 55 * U, 45 * U, "fill 2: the maker's pay-back, after a skipped order");
        assertEq(hs[0].marketId, market, "fill 2: the bettor's pay-back names the market");
        assertEq(hs[1].marketId, market, "fill 2: the maker's pay-back names the market");
        assertEq(positions.s_held(market, M.a), 45 * U, "fill 2: the maker's held amount");
        assertEq(positions.s_held(market, T.a), 60 * U, "fill 2: the bettor's held amount");
        assertEq(positions.s_heldTotal(market), 105 * U, "fill 2: the market");

        vm.recordLogs();
        _leg(M, T, game, Side.B, 100 * U, 110 * U);
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "fill 3: one pull and one pay-back");
        _assertHeld(hs[0], T.a, 5 * U, 0, 65 * U, "fill 3: the bettor pulled 5");
        _assertHeld(hs[1], M.a, 0, 5 * U, 40 * U, "fill 3: the maker paid 5 back");
        assertEq(positions.s_held(market, M.a), 40 * U, "fill 3: the maker's held amount");
        assertEq(positions.s_held(market, T.a), 65 * U, "fill 3: the bettor's held amount");
        assertEq(positions.s_heldTotal(market), 105 * U, "fill 3: the market");
        assertEq(_change(cStart, address(positions)), 105 * int256(U), "after the three fills: the contract");
        // The effective release: the maker staked 250 and holds 40; the bettor 275 and 65.
        assertEq(_change(mStart, M.a), -40 * int256(U), "the maker has 40 in and the rest outside");
        assertEq(_change(tStart, T.a), -65 * int256(U), "the bettor has 65 in and the rest outside");
        Position memory ma = _position(market, M.a, Side.A);
        Position memory mb = _position(market, M.a, Side.B);
        assertEq(ma.risk, 150 * U);
        assertEq(ma.profit, 165 * U);
        assertEq(mb.risk, 100 * U);
        assertEq(mb.profit, 110 * U);

        uint256 snap = vm.snapshotState();
        _settleHome(game, market);
        assertEq(_claimFor(stranger, market, M.a, Side.A), 105 * U, "home: the maker's whole amount, 40 + 65");
        _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, "home: the maker's losing record");
        _refusedClaim(stranger, market, T.a, Side.A, NO_PAYOUT, "home: the bettor's side A record, by name");
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, "home: the bettor's side B record, by name");
        assertEq(_change(cStart, address(positions)), 0, "home: the market's 105 is paid out to the unit");
        assertEq(_change(mStart, M.a), 65 * int256(U), "home: the maker is 65 up");
        assertEq(_change(tStart, T.a), -65 * int256(U), "home: the bettor is 65 down");
        vm.revertToState(snap);

        _settleAway(game, market);
        _refusedClaim(stranger, market, M.a, Side.A, NO_PAYOUT, "away: the maker's side A record");
        _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, "away: the maker's whole amount is zero");
        assertEq(_claimFor(stranger, market, T.a, Side.B), 105 * U, "away: the bettor's whole amount, 65 + 40");
        _refusedClaim(stranger, market, T.a, Side.A, NO_PAYOUT, "away: the bettor's losing record");
        assertEq(_change(mStart, M.a), -40 * int256(U), "away: the maker is 40 down");
        assertEq(_change(tStart, T.a), 40 * int256(U), "away: the bettor is 40 up");
        assertEq(_change(cStart, address(positions)), 0, "away: coin left in the contract");
        vm.revertToState(snap);

        _settleVoid(game, market);
        assertEq(_claimFor(stranger, market, M.a, Side.A), 40 * U, "void: the maker gets back what it has in");
        _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, "void: the maker's side B record, the rest, nothing");
        assertEq(_claimFor(stranger, market, T.a, Side.A), 65 * U, "void: the bettor gets back what it has in");
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, "void: the bettor's side B record");
        assertEq(_change(mStart, M.a), 0, "void: the maker is even");
        assertEq(_change(tStart, T.a), 0, "void: the bettor is even");
        assertEq(_change(cStart, address(positions)), 0, "void: coin left in the contract");
        vm.revertToState(snap);
    }

    /// @dev Four fills in all 24 orders, each order on a game of its own: after every Cross each account's
    ///      held amount is at least its worst loss over the fills so far, worked here from the fills sent, and
    ///      no pull is above that fill's stake; the end is the same in every order, the maker 135 and the
    ///      bettor 180; and each outcome pays as the ledger says.
    function _fourFillsInEveryOrder() internal {
        // The bettor's side, the maker's stake and the bettor's, of the four fills.
        uint8[4] memory sides = [0, 1, 1, 0];
        uint256[4] memory ms = [uint256(100), 50, 100, 200];
        uint256[4] memory ts = [uint256(110), 55, 110, 220];
        for (uint256 order; order < 24; ++order) {
            uint8[4] memory seq = _permutation(order);
            string memory name = string.concat("order ", vm.toString(order));
            uint256 game = _verifiedGame();
            uint256 mStart = _coin().balanceOf(M.a);
            uint256 tStart = _coin().balanceOf(T.a);
            uint256 cStart = _coin().balanceOf(address(positions));
            // The ledger: the maker's and the bettor's records, summed here from the fills sent.
            uint256[4] memory maker; // riskA, profitA, riskB, profitB
            uint256[4] memory bettor;
            uint256 market;
            for (uint256 k; k < 4; ++k) {
                uint256 f = seq[k];
                vm.recordLogs();
                market = _leg(M, T, game, Side(sides[f]), ms[f] * U, ts[f] * U);
                // The bettor's record on its side grows by its stake and the maker's; the maker's record on the
                // other side by the maker's stake and the bettor's.
                if (sides[f] == 0) {
                    bettor[0] += ts[f] * U;
                    bettor[1] += ms[f] * U;
                    maker[2] += ms[f] * U;
                    maker[3] += ts[f] * U;
                } else {
                    bettor[2] += ts[f] * U;
                    bettor[3] += ms[f] * U;
                    maker[0] += ms[f] * U;
                    maker[1] += ts[f] * U;
                }
                assertGe(
                    positions.s_held(market, M.a),
                    _worstByHand(maker[0], maker[1], maker[2], maker[3]),
                    string.concat(name, ": the maker held under its worst loss")
                );
                assertGe(
                    positions.s_held(market, T.a),
                    _worstByHand(bettor[0], bettor[1], bettor[2], bettor[3]),
                    string.concat(name, ": the bettor held under its worst loss")
                );
                Held[] memory hs = _heldChanges(vm.getRecordedLogs());
                for (uint256 j; j < hs.length; ++j) {
                    uint256 stake = hs[j].account == M.a ? ms[f] * U : ts[f] * U;
                    assertLe(hs[j].pulled, stake, string.concat(name, ": a pull above the fill's stake"));
                }
                assertEq(
                    positions.s_heldTotal(market),
                    positions.s_held(market, M.a) + positions.s_held(market, T.a),
                    string.concat(name, ": the total is the sum of the held amounts")
                );
            }
            assertEq(positions.s_held(market, M.a), 135 * U, string.concat(name, ": the maker's end"));
            assertEq(positions.s_held(market, T.a), 180 * U, string.concat(name, ": the bettor's end"));
            assertEq(positions.s_heldTotal(market), 315 * U, string.concat(name, ": the market's end"));
            assertEq(_change(mStart, M.a), -135 * int256(U), string.concat(name, ": the maker's coin at the end"));
            assertEq(_change(tStart, T.a), -180 * int256(U), string.concat(name, ": the bettor's coin at the end"));

            // Home: the maker loses 300 on B and wins 165 on A, 135 down; the bettor 135 up, paid 315 on A.
            uint256 snap = vm.snapshotState();
            _settleHome(game, market);
            assertEq(_claimFor(stranger, market, T.a, Side.A), 315 * U, string.concat(name, ": home, the bettor"));
            _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, string.concat(name, ": home, the bettor's B"));
            _refusedClaim(stranger, market, M.a, Side.A, NO_PAYOUT, string.concat(name, ": home, the maker's A"));
            _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, string.concat(name, ": home, the maker's B"));
            assertEq(_change(mStart, M.a), -135 * int256(U), string.concat(name, ": home, the maker's end"));
            assertEq(_change(tStart, T.a), 135 * int256(U), string.concat(name, ": home, the bettor's end"));
            assertEq(_change(cStart, address(positions)), 0, string.concat(name, ": home, coin left"));
            vm.revertToState(snap);
            // Away: the maker wins 330 on B and loses 150 on A, 180 up, paid 315 on B; the bettor 180 down.
            _settleAway(game, market);
            assertEq(_claimFor(stranger, market, M.a, Side.B), 315 * U, string.concat(name, ": away, the maker"));
            _refusedClaim(stranger, market, M.a, Side.A, NO_PAYOUT, string.concat(name, ": away, the maker's A"));
            _refusedClaim(stranger, market, T.a, Side.A, NO_PAYOUT, string.concat(name, ": away, the bettor's A"));
            _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, string.concat(name, ": away, the bettor's B"));
            assertEq(_change(mStart, M.a), 180 * int256(U), string.concat(name, ": away, the maker's end"));
            assertEq(_change(tStart, T.a), -180 * int256(U), string.concat(name, ": away, the bettor's end"));
            assertEq(_change(cStart, address(positions)), 0, string.concat(name, ": away, coin left"));
            vm.revertToState(snap);
            // Push: each gets back what it holds, on its side A record, whose risk is above it.
            _settlePush(game, market);
            assertEq(_claimFor(stranger, market, M.a, Side.A), 135 * U, string.concat(name, ": push, the maker"));
            assertEq(_claimFor(stranger, market, T.a, Side.A), 180 * U, string.concat(name, ": push, the bettor"));
            _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, string.concat(name, ": push, the maker's B"));
            _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, string.concat(name, ": push, the bettor's B"));
            assertEq(_change(mStart, M.a), 0, string.concat(name, ": push, the maker's end"));
            assertEq(_change(tStart, T.a), 0, string.concat(name, ": push, the bettor's end"));
            assertEq(_change(cStart, address(positions)), 0, string.concat(name, ": push, coin left"));
            vm.revertToState(snap);
        }
    }

    /// @dev The `index`th of the 24 orders of four, by the factorial number system; each of the four once.
    function _permutation(uint256 index) internal pure returns (uint8[4] memory order) {
        uint8[4] memory pool = [0, 1, 2, 3];
        uint256 n = 4;
        for (uint256 i; i < 4; ++i) {
            uint256 f = 1;
            for (uint256 k = 2; k < n; ++k) {
                f *= k;
            }
            uint256 pick = index / f;
            index %= f;
            order[i] = pool[pick];
            for (uint256 j = pick; j + 1 < n; ++j) {
                pool[j] = pool[j + 1];
            }
            --n;
        }
        uint256 seen;
        for (uint256 i; i < 4; ++i) {
            seen |= 1 << order[i];
        }
        require(seen == 15, "not a permutation");
    }

    /// previewFill answers one account's pull or pay-back for one growth of one record against what is held,
    /// each here a literal worked by hand: the maker's and the bettor's forecasts of part 1's second fill and of a
    /// growth on their held side, and a fresh account's on either side.
    /// Break: in OspexPositions.previewFill, grow the other side's record. Others turn it red: the two answers
    /// swapped; the forecast measured against the market's total; the growth's profit added to the risk.
    function test_preview_answersOneAccountsPullOrPayBackForOneGrowth() public {
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 110 * U);
        // The maker, held 100 on side B 100/110: resting 50 on side A against 55 lowers its worst loss to 45.
        (uint256 pull, uint256 payBack) = positions.previewFill(market, M.a, Side.A, 50 * U, 55 * U);
        assertEq(pull, 0, "the maker's pull for fill 2");
        assertEq(payBack, 55 * U, "the maker's pay-back for fill 2");
        // Resting 100 more on side B against 110 lifts it to 200.
        (pull, payBack) = positions.previewFill(market, M.a, Side.B, 100 * U, 110 * U);
        assertEq(pull, 100 * U, "the maker's pull for a growth on its held side");
        assertEq(payBack, 0);
        // The bettor, held 110 on side A 110/100: taking 55 on side B against 50 lowers its worst loss to 60.
        (pull, payBack) = positions.previewFill(market, T.a, Side.B, 55 * U, 50 * U);
        assertEq(pull, 0, "the bettor's pull for fill 2");
        assertEq(payBack, 50 * U, "the bettor's pay-back for fill 2");
        (pull, payBack) = positions.previewFill(market, T.a, Side.A, 110 * U, 100 * U);
        assertEq(pull, 110 * U, "the bettor's pull for a growth on its held side");
        assertEq(payBack, 0);
        // A fresh account: its first growth is pulled whole, on either side, and nothing is paid back.
        (pull, payBack) = positions.previewFill(market, stranger, Side.A, 300 * U, 330 * U);
        assertEq(pull, 300 * U, "a fresh account's first growth on side A");
        assertEq(payBack, 0);
        (pull, payBack) = positions.previewFill(market, stranger, Side.B, 300 * U, 330 * U);
        assertEq(pull, 300 * U, "a fresh account's first growth on side B");
        assertEq(payBack, 0);
        // The forecast is the fill: fill 2 moves what the two previews said.
        vm.recordLogs();
        _leg(M, T, game, Side.B, 50 * U, 55 * U);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        _assertHeld(hs[0], T.a, 0, 50 * U, 60 * U, "the bettor's pay-back, as previewed");
        _assertHeld(hs[1], M.a, 0, 55 * U, 45 * U, "the maker's pay-back, as previewed");
    }

    /// A pull and a pay-back under a lot of 100 units: the maker, resting 300 at 1.50 on side A and 400 at 1.50
    /// on side B, is paid 50 back at its second fill, and its third, 200 at 1.50 on side A, pulls 50. Every
    /// order's stake is in whole lots; the first leg's taking order declares 200 and fills 150 of it, three lots.
    /// Break: in OspexPositions._pull, skip a pull under 100 units, `if (pull < 100) return (0, true);`. Another
    /// turns it red: a pay-back under 100 units skipped in _payBack.
    function test_netting_aPullAndAPayBackUnderALot() public {
        uint256 game = _verifiedGame();
        vm.recordLogs();
        (bool ok, bytes memory err) =
            _tryCross(sender, _take(T, game, Side.B, 101, 200), _list(_restFor(M, game, Side.A, 300, 150)));
        assertTrue(ok, string.concat("the first leg was refused: ", vm.toString(err)));
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        _assertHeld(hs[0], M.a, 300, 0, 300, "the maker's first pull");
        _assertHeld(hs[1], T.a, 150, 0, 150, "the bettor's first pull");
        // The maker's side B 400 against 200: its worst loss is max(400 - 150, 300 - 200) = 250, paid 50 back;
        // the bettor's book is balanced, max(150 - 400, 200 - 300) = 0, and its 150 comes back.
        vm.recordLogs();
        _leg(M, T, game, Side.A, 400, 200);
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "the second fill: two pay-backs");
        _assertHeld(hs[0], T.a, 0, 150, 0, "the bettor's pay-back");
        _assertHeld(hs[1], M.a, 0, 50, 250, "the maker's pay-back of 50, under a lot");
        // The maker's side A 200 more against 100: max(400 - 250, 500 - 200) = 300, pulled 50.
        vm.recordLogs();
        _leg(M, T, game, Side.B, 200, 100);
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 1, "the third fill: the maker's pull alone");
        _assertHeld(hs[0], M.a, 50, 0, 300, "the maker's pull of 50, under a lot");
        assertEq(positions.s_held(market, M.a), 300);
        assertEq(positions.s_held(market, T.a), 0);
        assertEq(positions.s_heldTotal(market), 300);
        assertEq(_coin().balanceOf(address(positions)), 300, "the contract holds the total");
    }

    /// The rows' third fill, 330 on the bettor's side B against 300 at 2.10, filled whole and in three pieces of
    /// 110 against 100: whole, the maker is paid 15 back, 145 to 130, and the bettor pulled 15; in pieces the
    /// maker is paid 110, then 5, then pulled 100, the bettor paid 100, then pulled 5, then 110, and both end at
    /// the same 130 and 185 with the same records.
    /// Break: in OspexPositions._pull, pull the whole worst loss instead of the difference, `pull = worst;`.
    function test_netting_anOrderFilledWholeAndInPiecesEndsInTheSamePlace() public {
        uint256 whole = _verifiedGame();
        uint256 pieces = _verifiedGame();
        for (uint256 g; g < 2; ++g) {
            uint256 game = g == 0 ? whole : pieces;
            _leg(M, T, game, Side.A, 200 * U, 220 * U);
            _leg(M, T, game, Side.B, 50 * U, 55 * U);
        }
        uint256 wm = markets.getMarketId(whole, address(moneyline), 0);
        uint256 pm = markets.getMarketId(pieces, address(moneyline), 0);
        assertEq(positions.s_held(wm, M.a), 145 * U);
        assertEq(positions.s_held(wm, T.a), 170 * U);

        vm.recordLogs();
        _leg(M, T, whole, Side.B, 300 * U, 330 * U);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "whole: two movements");
        _assertHeld(hs[0], T.a, 15 * U, 0, 185 * U, "whole: the bettor pulled 15");
        _assertHeld(hs[1], M.a, 0, 15 * U, 130 * U, "whole: the maker paid 15 back");

        uint256[3] memory makerPulled = [uint256(0), 0, 100 * U];
        uint256[3] memory makerPaid = [uint256(110 * U), 5 * U, 0];
        uint256[3] memory makerHeld = [uint256(35 * U), 30 * U, 130 * U];
        uint256[3] memory bettorPulled = [uint256(0), 5 * U, 110 * U];
        uint256[3] memory bettorPaid = [uint256(100 * U), 0, 0];
        uint256[3] memory bettorHeld = [uint256(70 * U), 75 * U, 185 * U];
        for (uint256 i; i < 3; ++i) {
            string memory piece = string.concat("piece ", vm.toString(i + 1));
            vm.recordLogs();
            _leg(M, T, pieces, Side.B, 100 * U, 110 * U);
            hs = _heldChanges(vm.getRecordedLogs());
            assertEq(hs.length, 2, string.concat(piece, ": two movements"));
            // A pull of the maker comes at its leg, before the end; the end's movements, the bettor's first.
            (uint256 m, uint256 t) = makerPulled[i] != 0 ? (0, 1) : (1, 0);
            _assertHeld(hs[t], T.a, bettorPulled[i], bettorPaid[i], bettorHeld[i], string.concat(piece, ": the bettor"));
            _assertHeld(hs[m], M.a, makerPulled[i], makerPaid[i], makerHeld[i], string.concat(piece, ": the maker"));
        }
        assertEq(positions.s_held(pm, M.a), positions.s_held(wm, M.a), "the maker ends in the same place");
        assertEq(positions.s_held(pm, T.a), positions.s_held(wm, T.a), "the bettor ends in the same place");
        assertEq(positions.s_held(pm, M.a), 130 * U);
        assertEq(positions.s_heldTotal(pm), positions.s_heldTotal(wm), "the two markets hold the same");
        assertEq(positions.s_heldTotal(pm), 315 * U);
        for (uint256 s; s < 2; ++s) {
            Position memory a = _position(wm, M.a, Side(s));
            Position memory b = _position(pm, M.a, Side(s));
            assertEq(a.risk, b.risk, "the maker's records differ");
            assertEq(a.profit, b.profit, "the maker's records differ");
            a = _position(wm, T.a, Side(s));
            b = _position(pm, T.a, Side(s));
            assertEq(a.risk, b.risk, "the bettor's records differ");
            assertEq(a.profit, b.profit, "the bettor's records differ");
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Both roles, the same account twice in a Cross, and an empty wallet.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralRolesTest is SharedCollateralBase {
    Signer internal M1;
    Signer internal M2;
    Signer internal X;

    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
        M1 = _account("maker one");
        M2 = _account("maker two");
        X = _account("an old counterparty");
        _register(M1.a, sender);
        _register(M2.a, sender);
        _register(X.a, sender);
    }

    /// Break: in OspexPositions._record, remove the self-leg exception, `if (maker != taker)`: the self leg
    /// pulls the account as a maker and the end asks it 5,000. Another turns it red: a pay-back made at the leg.
    function test_netting_bothRolesAndTheSameAccountRestingTwice() public {
        _theSelfLeg();
        _againstItselfAlone();
        _restingTwice();
        _listedTwiceAndRefused();
        _twoMakersPaidBackInListOrder();
    }

    /// @dev (e) Two distinct makers both held above their worst loss after a Cross are each paid back, in list
    ///      order, after the taking account: three movements, the bettor's, the first maker's, the second's.
    function _twoMakersPaidBackInListOrder() internal {
        uint256 game = _verifiedGame();
        uint256 market = _legs(T, game, Side.A, _two(M1, M2), _pair(100 * U, 100 * U), _pair(100 * U, 100 * U));
        assertEq(positions.s_heldTotal(market), 400 * U);
        vm.recordLogs();
        _legs(T, game, Side.B, _two(M1, M2), _pair(100 * U, 100 * U), _pair(100 * U, 100 * U));
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 3, "three pay-backs");
        _assertHeld(hs[0], T.a, 0, 200 * U, 0, "the taking account's pay-back, first");
        _assertHeld(hs[1], M1.a, 0, 100 * U, 0, "the first listed maker's pay-back, second");
        _assertHeld(hs[2], M2.a, 0, 100 * U, 0, "the second listed maker's pay-back, last");
        assertEq(positions.s_heldTotal(market), 0, "every book is balanced: nothing is held");
    }

    /// @dev (a) A Cross of three legs, a maker's 10,000 at 2.00, the taking account's own 200 at 1.50, which
    ///      takes 100 of it, and a second maker's 5,000 at 2.00, the taking account holding 10,000 of coin: the
    ///      end asks it 15,000, its worst loss,
    ///      and is refused, so nothing of the Cross remains. Funded, the same Cross emits no held change for the
    ///      taking account before the last PositionFilled and one at the end, for 15,000. Then the attack's two
    ///      orders of a 5,000 leg and a 100 self leg, on an account already holding 10,000, end held 15,000
    ///      either way.
    function _theSelfLeg() internal {
        uint256 game = _verifiedGame();
        IERC20 coin = _coin();
        uint256 spare = coin.balanceOf(T.a) - 10_000;
        vm.prank(T.a);
        assertTrue(coin.transfer(stranger, spare), "the transfer out");
        Signer[] memory ms = _three(M1, T, M2);
        uint256[] memory makerStakes = _triple(10_000, 200, 5_000);
        uint256[] memory takerStakes = _triple(10_000, 100, 5_000);
        (bool ok, bytes memory err) = _tryLegs(T, game, Side.A, ms, makerStakes, takerStakes);
        assertFalse(ok, "the Cross filled with the taking account holding 10,000 against a worst loss of 15,000");
        assertEq(
            err,
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, T.a, 15_000),
            "the end's refusal names the taking account and its one netted pull"
        );
        assertEq(markets.marketCount(), 0, "a reverted Cross drew a market");
        assertEq(coin.balanceOf(T.a), 10_000, "a reverted Cross moved the taking account's coin");
        assertEq(coin.balanceOf(address(positions)), 0, "a reverted Cross left coin");

        vm.prank(stranger);
        assertTrue(coin.transfer(T.a, spare), "the transfer back");
        vm.recordLogs();
        uint256 market = _legs(T, game, Side.A, ms, makerStakes, takerStakes);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 lastFilled = _lastFilled(logs);
        assertLt(lastFilled, logs.length, "no PositionFilled");
        assertEq(
            _firstHeldOf(logs, T.a, 0),
            _firstHeldOf(logs, T.a, lastFilled),
            "the taking account was pulled before the last leg"
        );
        Held[] memory hs = _heldChanges(logs);
        assertEq(hs.length, 3, "three movements: two resting pulls and the taking account's one");
        _assertHeld(hs[0], M1.a, 10_000, 0, 10_000, "the first maker's pull");
        _assertHeld(hs[1], M2.a, 5_000, 0, 5_000, "the second maker's pull, after the self leg pulled nothing");
        _assertHeld(hs[2], T.a, 15_000, 0, 15_000, "the taking account's one pull, at the end");
        assertEq(positions.s_held(market, T.a), 15_000);
        assertEq(positions.s_heldTotal(market), 30_000);
        Position memory ta = _position(market, T.a, Side.A);
        Position memory tb = _position(market, T.a, Side.B);
        assertEq(ta.risk, 15_100, "the taking account's side A risk, its own leg included");
        assertEq(ta.profit, 15_200, "its side A profit: the makers' stakes, its own 200 at 1.50 among them");
        assertEq(tb.risk, 200, "the taking account's side B record, from its own leg");
        assertEq(tb.profit, 100);

        // The attack's two orders.
        uint256 game2 = _verifiedGame();
        uint256 m2 = _leg(X, T, game2, Side.A, 10_000, 10_000);
        assertEq(positions.s_held(m2, T.a), 10_000);
        uint256 snap = vm.snapshotState();
        for (uint256 selfFirst; selfFirst < 2; ++selfFirst) {
            Signer[] memory two = selfFirst == 1 ? _two(T, M1) : _two(M1, T);
            uint256[] memory s = selfFirst == 1 ? _pair(100, 5_000) : _pair(5_000, 100);
            vm.recordLogs();
            _legs(T, game2, Side.A, two, s, s);
            hs = _heldChanges(vm.getRecordedLogs());
            assertEq(_heldOf(hs, T.a), 1, "the taking account moved more than once");
            assertEq(hs[hs.length - 1].account, T.a, "the taking account's movement is not the last");
            assertEq(hs[hs.length - 1].pulled, 5_000, "the taking account's pull at the end");
            assertEq(positions.s_held(m2, T.a), 15_000, "held 15,000 either way");
            vm.revertToState(snap);
        }
    }

    /// @dev (b) An account against itself alone, held at its worst loss, moves no coin; one held above it,
    ///      after a refused pay-back, is paid the excess at the end of such a Cross: the attack's maker, held
    ///      5,000 against 3,000, is paid the 2,000.
    function _againstItselfAlone() internal {
        uint256 game = _verifiedGame();
        uint256 market = _leg(X, T, game, Side.A, 10_000, 10_000);
        uint256 coinBefore = _coin().balanceOf(T.a);
        vm.recordLogs();
        _leg(T, T, game, Side.A, 100, 100);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 0, "an account against itself alone, at its worst loss, moved coin");
        assertEq(_coin().balanceOf(T.a), coinBefore, "its coin moved");
        assertEq(positions.s_held(market, T.a), 10_000);
        assertEq(_position(market, T.a, Side.A).risk, 10_100, "both records are written");
        assertEq(_position(market, T.a, Side.B).risk, 100, "both records are written");

        uint256 game2 = _verifiedGame();
        uint256 m2 = _leg(M, T, game2, Side.A, 5_000, 5_000);
        token.setBlocked(M.a, true);
        vm.recordLogs();
        _leg(M, T, game2, Side.B, 2_000, 2_000);
        Refused[] memory rs = _refusals(vm.getRecordedLogs());
        assertEq(rs.length, 1, "one refusal");
        assertEq(rs[0].account, M.a);
        assertEq(rs[0].amount, 2_000);
        assertEq(rs[0].held, 5_000);
        assertEq(rs[0].marketId, m2, "the refusal names its market");
        token.setBlocked(M.a, false);
        assertEq(positions.s_held(m2, M.a), 5_000, "the maker holds 5,000 against a worst loss of 3,000");
        assertEq(positions.s_held(m2, T.a), 3_000);
        coinBefore = _coin().balanceOf(M.a);
        vm.recordLogs();
        _leg(M, M, game2, Side.A, 100, 100);
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 1, "one movement: the excess paid back at the end");
        _assertHeld(hs[0], M.a, 0, 2_000, 3_000, "the maker's pay-back at the end of a Cross against itself");
        assertEq(_change(coinBefore, M.a), 2_000, "the maker's coin");
        assertEq(positions.s_heldTotal(m2), 6_000);
    }

    /// @dev (c) Resting twice in one Cross with an allowance of 20: the proof's third example. The maker, held
    ///      100 on side B 100/100, rests side A 60 then 160 against the bettor's side B 220: its worst loss
    ///      falls to 40 and rises to 120, and it is pulled 20 once, at the second leg, never paid and pulled in
    ///      one Cross; the bettor's end pulls 20.
    function _restingTwice() internal {
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 100 * U);
        vm.prank(M.a);
        _coin().approve(address(positions), 20 * U);
        vm.recordLogs();
        _legs(T, game, Side.B, _two(M, M), _pair(60 * U, 160 * U), _pair(60 * U, 160 * U));
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "two movements");
        _assertHeld(hs[0], M.a, 20 * U, 0, 120 * U, "the maker's one pull, at its second leg");
        _assertHeld(hs[1], T.a, 20 * U, 0, 120 * U, "the bettor's one pull, at the end");
        assertEq(positions.s_heldTotal(market), 240 * U);
        assertEq(_position(market, M.a, Side.A).risk, 220 * U);
        assertEq(_position(market, T.a, Side.B).risk, 220 * U);
        vm.prank(M.a);
        _coin().approve(address(positions), type(uint256).max);
    }

    /// @dev (d) Listed twice with its pay-back refused: the maker rests twice, held above its worst loss at the
    ///      end, and the coin refuses it: two refusals, the numbers unchanged.
    function _listedTwiceAndRefused() internal {
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 100 * U);
        token.setBlocked(M.a, true);
        vm.recordLogs();
        _legs(T, game, Side.B, _two(M, M), _pair(30 * U, 30 * U), _pair(30 * U, 30 * U));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Refused[] memory rs = _refusals(logs);
        assertEq(rs.length, 2, "an account listed twice is visited twice, and refused twice");
        for (uint256 i; i < 2; ++i) {
            assertEq(rs[i].account, M.a);
            assertEq(rs[i].amount, 60 * U, "the excess, 100 held against a worst loss of 40");
            assertEq(rs[i].held, 100 * U);
        }
        Held[] memory hs = _heldChanges(logs);
        assertEq(hs.length, 1, "the bettor's pay-back alone");
        _assertHeld(hs[0], T.a, 0, 60 * U, 40 * U, "the bettor's pay-back");
        assertEq(positions.s_held(market, M.a), 100 * U, "the refused amount stays held");
        assertEq(positions.s_heldTotal(market), 140 * U);
        assertEq(rs[0].marketId, market, "a refusal names its market");
        token.setBlocked(M.a, false);
        // A later Cross that lists an order of the maker's and skips it pays the maker nothing: the end call
        // visits the filled legs' accounts alone, and the maker's excess waits for its own next fill or its claim.
        OspexMatching.SignedOrder memory dead = _restFor(M, game, Side.A, 100 * U, 100 * U);
        vm.prank(M.a);
        matching.cancelOrder(dead.order);
        uint256 mCoin = _coin().balanceOf(M.a);
        vm.recordLogs();
        _cross(sender, _take(T, game, Side.B, 101, 100 * U), _list(dead, _restFor(X, game, Side.A, 100 * U, 100 * U)));
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(_heldOf(hs, M.a), 0, "the skipped order's account was visited at the end");
        assertEq(_coin().balanceOf(M.a), mCoin, "the skipped order's account was paid");
        assertEq(positions.s_held(market, M.a), 100 * U, "the skipped order's account's held amount moved");
    }

    /// L83, item 11. A resting order is skipped for its pull only when its netted pull fails. An account with
    /// no coin and no allowance: the leg that lowers its worst loss fills and pays it back; the leg that raises
    /// it is skipped under the sixth reason; as the taking account the Cross reverts with the netted sum of its
    /// legs; a short receipt reverts by name and is not read as a skip; and a direct fill on a two-sided maker
    /// whose pull is between zero and its stake reverts with the exact 100-byte refusal.
    /// Break: in OspexPositions._pull, pull the stake in full: in _record pass the stake as the amount. Others
    /// turn it red: the taking pull asking the Cross's stakes in full; the third word of the refusal written as
    /// the stake or as zero, which the direct call's bytes see and a Cross does not.
    function test_netting_anEmptyWalletFillsWhatLowersItsWorstLoss() public {
        Signer memory E = _account("the account that will be empty");
        _register(E.a, sender);
        IERC20 coin = _coin();
        uint256 game = _verifiedGame();
        uint256 market = _leg(E, T, game, Side.A, 10_000, 10_000);
        assertEq(positions.s_held(market, E.a), 10_000);
        // Emptied: no coin and no allowance.
        vm.startPrank(E.a);
        assertTrue(coin.transfer(stranger, coin.balanceOf(E.a)), "the transfer out");
        coin.approve(address(positions), 0);
        vm.stopPrank();
        assertEq(coin.balanceOf(E.a), 0);

        // The leg that lowers its worst loss, 10,000 to 6,000, fills and pays it 4,000 back.
        vm.recordLogs();
        _leg(E, T, game, Side.B, 4_000, 4_000);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(_heldOf(hs, E.a), 1);
        _assertHeld(hs[hs.length - 1], E.a, 0, 4_000, 6_000, "the empty account's pay-back");
        assertEq(coin.balanceOf(E.a), 4_000, "paid back into an empty wallet");
        assertEq(positions.s_held(market, E.a), 6_000);

        // The leg that raises it, 20,000 more on side A, is skipped under the sixth reason; the leg beside it
        // fills.
        Signer memory F = _account("a funded maker");
        _register(F.a, sender);
        OspexMatching.SignedOrder memory taking = _take(T, game, Side.B, 101, 30_000);
        OspexMatching.SignedOrder memory raising = _restFor(E, game, Side.A, 20_000, 20_000);
        OspexMatching.SignedOrder memory beside = _restFor(F, game, Side.A, 10_000, 10_000);
        vm.recordLogs();
        _cross(sender, taking, _list(raising, beside));
        Skip[] memory skips = _skips(vm.getRecordedLogs());
        assertEq(skips.length, 1, "one skip");
        _assertSkip(skips[0], raising, taking, PULL_REFUSED, "the leg that raises the empty account's worst loss");
        assertEq(_filled(beside), 10_000, "the leg beside it");
        assertEq(_filled(raising), 0);
        assertEq(positions.s_held(market, E.a), 6_000, "a skipped leg left the held amount as it was");
        assertEq(_position(market, E.a, Side.A).risk, 4_000, "a skipped leg left the record as it was");

        // As the taking account: the end asks the netted sum of its legs, 20,000, and is refused.
        uint256 game2 = _verifiedGame();
        (bool ok, bytes memory err) =
            _tryLegs(E, game2, Side.A, _two(M1, M2), _pair(10_000, 10_000), _pair(10_000, 10_000));
        assertFalse(ok, "the empty account took two legs");
        assertEq(
            err,
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, E.a, 20_000),
            "the taking refusal carries the netted sum of the legs"
        );
        // On the market it already holds on, 6,000 against side A 4,000 and side B 10,000: taking 20,000 more on
        // side B lifts its worst loss to 26,000, and the refusal carries the 20,000 asked, not the worst loss.
        (ok, err) = _tryLeg(M1, E, game, Side.B, 20_000, 20_000);
        assertFalse(ok, "the empty account took a leg on the market it holds on");
        assertEq(
            err,
            abi.encodeWithSelector(IOspexPositions.OspexPositions__TakerPullRefused.selector, E.a, 20_000),
            "the taking refusal carries the netted pull, not the worst loss"
        );

        // A short receipt reverts by name and is not a skip: the coin keeps one unit of every transfer.
        token.setCut(1);
        uint256 before = coin.balanceOf(address(positions));
        (ok, err) = _tryLeg(M1, T, game2, Side.A, 10_000, 10_000);
        assertFalse(ok, "a short receipt was taken");
        assertEq(
            err,
            abi.encodeWithSelector(
                OspexPositions.OspexPositions__ShortReceipt.selector, before + 10_000, before + 9_999
            ),
            "the short receipt"
        );
        token.setCut(0);

        // A direct fill from the matching module's address: the two-sided maker's pull is 8,000, between zero
        // and its stake of 20,000, and the refusal carries all three words.
        vm.prank(address(matching));
        (ok, err) = address(positions)
            .call(
                abi.encodeCall(
                    OspexPositions.recordFill, (game, address(moneyline), 0, Side.A, E.a, 20_000, T.a, 20_000)
                )
            );
        assertFalse(ok, "the direct fill was taken");
        assertEq(err.length, 100, "the refusal is not 100 bytes");
        assertEq(
            err,
            abi.encodeWithSelector(IOspexPositions.OspexPositions__MakerPullRefused.selector, E.a, 20_000, 8_000),
            "the maker's refusal: the account, the stake and the amount asked"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// The cap and the minimum fill compare stakes, not pulls.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralCapTest is SharedCollateralBase {
    Signer internal M2;

    constructor() {
        liftAtDeploy = false;
    }

    function setUp() public override {
        super.setUp();
        assertFalse(matching.s_takingStakeCapLifted(), "the cap is lifted");
        _ready(M);
        _ready(T);
        M2 = _account("maker two");
        _register(M2.a, sender);
    }

    /// Break: in OspexMatching._checkTaking, compare the cap with what the fill would pull: there is no pull to
    /// read there, so the nearest mutant is the cap compared with the stake left to fill, `t.riskAmount -
    /// s_filledRisk[orderHash]`, which lets a 10,100 order half filled through. Another turns it red: the
    /// minimum compared with the pull.
    function test_netting_underTheCapAndWithAMinimum() public {
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 10_000, 10_000);
        uint256 coinBefore = _coin().balanceOf(T.a);
        // A one-cent taking order on the other side pulls nothing and pays the bettor's 10,000 back: it fills.
        vm.recordLogs();
        _leg(M2, T, game, Side.B, 10_000, 10_000);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(_heldOf(hs, T.a), 1);
        _assertHeld(hs[hs.length - 1], T.a, 0, 10_000, 0, "the bettor's pay-back: its book is balanced");
        assertEq(_change(coinBefore, T.a), 10_000, "the bettor got its cent back");
        assertEq(positions.s_held(market, T.a), 0);
        // One signed for 10,100 that would also pull nothing is refused for the cap, before anything moves.
        OspexMatching.SignedOrder memory over = _take(T, game, Side.B, 101, 10_100);
        _refused(
            sender,
            over,
            _list(_restFor(M2, game, Side.A, 10_100, 10_100)),
            _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, over),
            "a taking order above the cap, though its pull would be zero"
        );
        // A minimum is measured on the stake filled, not the pull: half a cent asked and half a cent filled, the
        // rest of the cent left, nothing pulled and 5,000 paid back.
        uint256 game2 = _verifiedGame();
        _leg(M, T, game2, Side.A, 10_000, 10_000);
        OspexMatching.SignedOrder memory asking = _takeMin(T, game2, Side.B, 101, 10_000, 5_000);
        vm.recordLogs();
        _cross(sender, asking, _list(_restFor(M2, game2, Side.A, 5_000, 5_000)));
        assertEq(_filled(asking), 5_000, "a minimum met exactly by a fill that pulled nothing");
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(_heldOf(hs, T.a), 1);
        _assertHeld(hs[hs.length - 1], T.a, 0, 5_000, 5_000, "the bettor's pay-back: nothing pulled");
        // And a minimum the stake filled does not meet refuses the Cross, though the pull is zero too.
        uint256 game3 = _verifiedGame();
        _leg(M, T, game3, Side.A, 10_000, 10_000);
        asking = _takeMin(T, game3, Side.B, 101, 10_000, 10_000);
        OspexMatching.SignedOrder memory half = _restFor(M2, game3, Side.A, 5_000, 5_000);
        OspexMatching.LegReport[] memory legs = new OspexMatching.LegReport[](1);
        legs[0] = _filledLeg(half, 5_000, 5_000);
        _refused(sender, asking, _list(half), _short(asking, 5_000, 5_000, legs), "a short fill under the minimum");
        // The minimum is checked before the end call: with the taking account unfunded and the short leg its
        // first on the market, the Cross is refused for the minimum, and the pull it would have asked is never
        // asked.
        uint256 game4 = _verifiedGame();
        vm.startPrank(T.a);
        assertTrue(_coin().transfer(stranger, _coin().balanceOf(T.a)), "the transfer out");
        _coin().approve(address(positions), 0);
        vm.stopPrank();
        asking = _takeMin(T, game4, Side.B, 101, 10_000, 10_000);
        half = _restFor(M2, game4, Side.A, 5_000, 5_000);
        legs[0] = _filledLeg(half, 5_000, 5_000);
        _refused(sender, asking, _list(half), _short(asking, 5_000, 5_000, legs), "a short fill by an unfunded account");
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// L230, L232, L233, and the two card lines on refusals: pay-backs, the market's total, and the claim for anyone.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralPayBackTest is SharedCollateralBase {
    OspexCourierRelay internal relay;
    address internal relayKey = makeAddr("the relay's key");
    address internal registered = makeAddr("a stranger both accounts registered");

    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
        relay = new OspexCourierRelay(address(matching), relayKey);
        _register(M.a, address(relay));
        _register(T.a, address(relay));
        _register(M.a, registered);
        _register(T.a, registered);
    }

    /// @dev Part 1's three fills sent by `from`, through the relay when `viaRelay`: the pay-backs of fill 2, 55
    ///      and 50, and of fill 3, 5, go to the maker and the bettor and to nobody else. Whoever sends changes
    ///      by exactly its own entitlement as an owner, which for an address that owns nothing is nothing.
    function _partOneBy(address from, bool viaRelay) internal {
        uint256 game = _verifiedGame();
        address[5] memory watched = [from, address(relay), crossOrigin, stranger, sender];
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = _coin().balanceOf(watched[i]);
        }
        uint256 mBefore = _coin().balanceOf(M.a);
        uint256 tBefore = _coin().balanceOf(T.a);
        int256[3] memory wantM = [int256(-100), 55, 5];
        int256[3] memory wantT = [int256(-110), 50, -5];
        uint8[3] memory sides = [0, 1, 1];
        uint256[3] memory ms = [uint256(100), 50, 100];
        uint256[3] memory ts = [uint256(110), 55, 110];
        for (uint256 f; f < 3; ++f) {
            OspexMatching.SignedOrder memory taking = _take(T, game, Side(sides[f]), 101, ts[f] * U);
            OspexMatching.SignedOrder[] memory resting =
                _list(_restFor(M, game, _other(Side(sides[f])), ms[f] * U, ts[f] * U));
            bytes memory call = abi.encodeCall(OspexMatching.cross, (taking, resting));
            vm.prank(from, crossOrigin);
            (bool ok, bytes memory err) = (viaRelay ? address(relay) : address(matching)).call(call);
            assertTrue(ok, string.concat("the fill was refused: ", vm.toString(err)));
            int256 m = wantM[f] * int256(U);
            int256 t = wantT[f] * int256(U);
            assertEq(_change(mBefore, M.a), m, "the maker's coin");
            assertEq(_change(tBefore, T.a), t, "the bettor's coin");
            mBefore = _coin().balanceOf(M.a);
            tBefore = _coin().balanceOf(T.a);
            for (uint256 i; i < 5; ++i) {
                int256 own = watched[i] == M.a ? m : watched[i] == T.a ? t : int256(0);
                assertEq(
                    _change(before[i], watched[i]), own, "an address's coin changed by other than its own entitlement"
                );
                before[i] = _coin().balanceOf(watched[i]);
            }
        }
    }

    /// Break: in OspexPositions._payBack, pay `msg.sender` instead of the account. Another turns it red: pay
    /// `tx.origin`.
    function test_neverLine_aPayBackGoesOnlyToItsAccount() public {
        _partOneBy(sender, false);
        _partOneBy(relayKey, true);
        _partOneBy(registered, false);
        // Sent by the resting account itself, and by the taking account itself.
        _register(T.a, M.a);
        _register(M.a, M.a);
        _partOneBy(M.a, false);
        _register(M.a, T.a);
        _register(T.a, T.a);
        _partOneBy(T.a, false);
    }

    /// Break: in OspexPositions._claim, delete the comparison with the market's total: the planted claim then
    /// reverts with the compiler's panic, not the asserted MarketShort bytes, the subtraction being checked.
    /// Others turn it red: the comparison deleted at the pay-back; the total not raised at a pull.
    function test_neverLine_oneMarketsShortfallStaysOnThatMarket() public {
        // Two markets in one contract, both funded by real fills: part 1's book, and one leg on a second game.
        uint256 game1 = _verifiedGame();
        uint256 game2 = _verifiedGame();
        uint256 m1 = _leg(M, T, game1, Side.A, 100 * U, 110 * U);
        uint256 snap = vm.snapshotState();

        // The claim path. The first market's total planted one unit under its last claim.
        _leg(M, T, game1, Side.B, 50 * U, 55 * U);
        _leg(M, T, game1, Side.B, 100 * U, 110 * U);
        uint256 m2 = _leg(M, T, game2, Side.A, 100 * U, 100 * U);
        assertEq(positions.s_heldTotal(m1), 105 * U);
        assertEq(positions.s_heldTotal(m2), 200 * U);
        _settleHome(game1, m1);
        _settleHome(game2, m2);
        bytes32 slot = _heldTotalSlot(m1);
        assertEq(uint256(vm.load(address(positions), slot)), 105 * U, "the slot read is not the first market's total");
        vm.store(address(positions), slot, bytes32(uint256(104 * U)));
        assertEq(positions.s_heldTotal(m1), 104 * U, "the plant");
        (bool ok, bytes memory err) = _tryClaimFor(stranger, m1, M.a, Side.A);
        assertFalse(ok, "a claim above the market's total was paid");
        assertEq(
            err,
            abi.encodeWithSelector(IOspexPositions.OspexPositions__MarketShort.selector, m1, 105 * U, 104 * U),
            "the exact bytes of the refusal"
        );
        assertFalse(_position(m1, M.a, Side.A).claimed, "the refused claim marked the record");
        assertEq(positions.s_heldTotal(m1), 104 * U, "the refused claim moved the total");
        // Every claim on the second market pays in full, from the second market's money.
        assertEq(_claimFor(stranger, m2, T.a, Side.A), 200 * U, "the second market's claim");
        _refusedClaim(stranger, m2, M.a, Side.B, NO_PAYOUT, "the second market's loser");
        assertEq(positions.s_heldTotal(m2), 0);
        vm.revertToState(snap);

        // The pay-back path. After fill 1 the first market holds 210; fill 2 pulls nothing and pays the bettor 50
        // back first: the total planted at 49 refuses that pay-back by name, and the whole Cross with it.
        slot = _heldTotalSlot(m1);
        assertEq(uint256(vm.load(address(positions), slot)), 210 * U);
        vm.store(address(positions), slot, bytes32(uint256(49 * U)));
        OspexMatching.SignedOrder memory taking = _take(T, game1, Side.B, 101, 55 * U);
        OspexMatching.SignedOrder memory resting = _restFor(M, game1, Side.A, 50 * U, 55 * U);
        _refused(
            sender,
            taking,
            _list(resting),
            abi.encodeWithSelector(IOspexPositions.OspexPositions__MarketShort.selector, m1, 50 * U, 49 * U),
            "a pay-back above the market's total"
        );
        assertEq(_filled(taking), 0, "a reverted Cross left a filled amount");
        assertEq(_filled(resting), 0, "a reverted Cross left a filled amount");
        assertEq(_position(m1, M.a, Side.A).risk, 0, "a reverted Cross left a record");
        assertEq(positions.s_held(m1, M.a), 100 * U, "a reverted Cross moved a held amount");
        assertEq(positions.s_heldTotal(m1), 49 * U, "the plant, as it was");
        // The second market's fills, pay-backs and claims go through.
        m2 = _leg(M, T, game2, Side.A, 100 * U, 110 * U);
        _leg(M, T, game2, Side.B, 50 * U, 55 * U);
        _leg(M, T, game2, Side.B, 100 * U, 110 * U);
        assertEq(positions.s_heldTotal(m2), 105 * U);
        _settleHome(game2, m2);
        assertEq(_claimFor(stranger, m2, M.a, Side.A), 105 * U, "the second market's claim");
        assertEq(positions.s_heldTotal(m2), 0);
        vm.revertToState(snap);

        // The boundary: a pay-back equal to what the market still holds is not short. A second fill that mirrors
        // the first balances both books: the bettor is paid its 100 back first, leaving 100, and the maker's
        // pay-back of 100 is the whole of it.
        uint256 game3 = _verifiedGame();
        uint256 m3 = _leg(M, T, game3, Side.A, 100 * U, 100 * U);
        assertEq(positions.s_heldTotal(m3), 200 * U);
        vm.recordLogs();
        _leg(M, T, game3, Side.B, 100 * U, 100 * U);
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "the mirror fill: two pay-backs");
        _assertHeld(hs[0], T.a, 0, 100 * U, 0, "the bettor's pay-back, leaving 100");
        _assertHeld(hs[1], M.a, 0, 100 * U, 0, "the maker's pay-back, the whole of what the market held");
        assertEq(positions.s_heldTotal(m3), 0, "the market holds nothing");
    }

    /// L233, L85. A claim by anyone pays only the owner.
    /// Break: in OspexPositions._claim, pay `msg.sender`.
    function test_neverLine_aClaimByAnyonePaysOnlyTheOwner() public {
        // Part 1's book, settled home: the maker's whole amount is 105 on a record whose risk and profit are 150
        // and 165, so the payout the event and its hub copy carry is the net figure and not the gross.
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 110 * U);
        _leg(M, T, game, Side.B, 50 * U, 55 * U);
        _leg(M, T, game, Side.B, 100 * U, 110 * U);
        _settleHome(game, market);
        ClaimCaller contractCaller = new ClaimCaller();
        address[4] memory callers = [stranger, sender, relayKey, address(contractCaller)];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            uint256 ownerBefore = _coin().balanceOf(M.a);
            uint256 callerBefore = _coin().balanceOf(callers[i]);
            // The event names the owner and the net payout, and so does its copy through the hub.
            vm.expectEmit(true, true, true, true, address(positions));
            emit IOspexPositions.PositionClaimed(market, M.a, Side.A, 105 * U);
            vm.expectEmit(true, true, true, true, address(core));
            emit OspexBetting.CoreEventEmitted(
                keccak256("POSITION_CLAIMED"), address(positions), abi.encode(market, M.a, Side.A, 105 * U)
            );
            uint256 answered;
            if (callers[i] == address(contractCaller)) {
                answered = contractCaller.claim(positions, market, M.a, Side.A);
            } else {
                vm.prank(callers[i], callers[i]);
                answered = positions.claimPositionFor(market, M.a, Side.A);
            }
            assertEq(answered, 105 * U, "the answer");
            assertEq(_change(ownerBefore, M.a), 105 * int256(U), "the owner is paid");
            assertEq(_coin().balanceOf(callers[i]), callerBefore, "the caller's coin moved");
            // Repeated, by the owner and by the caller: refused by name.
            _refusedClaim(callers[i], market, M.a, Side.A, ALREADY_CLAIMED, "a repeated claim by the caller");
            (bool ok, bytes memory err) = _tryClaim(M.a, market, Side.A);
            assertFalse(ok, "a repeated claim by the owner was paid");
            assertEq(err, abi.encodeWithSelector(ALREADY_CLAIMED), "the owner's repeated claim");
            vm.revertToState(snap);
        }
        // The owner's own call still works and answers the payout, with another address as the transaction's
        // origin: the owner is the caller, never the origin.
        uint256 before = _coin().balanceOf(M.a);
        vm.prank(M.a, crossOrigin);
        assertEq(positions.claimPosition(market, Side.A), 105 * U, "the owner's own claim answers the payout");
        assertEq(_change(before, M.a), 105 * int256(U), "the owner is paid by its own call");
        assertEq(_coin().balanceOf(crossOrigin), 0, "the origin was paid");
        assertEq(_coin().balanceOf(address(positions)), 0);
        vm.revertToState(snap);
        // The zero account is refused by name, from a stranger and from an owner whose own record would pay:
        // the zero account is nobody's, the caller's included.
        _refusedClaim(stranger, market, address(0), Side.A, NO_PAYOUT, "the zero account");
        _refusedClaim(M.a, market, address(0), Side.A, NO_PAYOUT, "the zero account, from an owner");
        _refusedClaim(stranger, market, address(0), Side.B, NO_PAYOUT, "the zero account, side B");
        // The records with nothing to pay, by anyone: refused by name.
        _refusedClaim(stranger, market, M.a, Side.B, NO_PAYOUT, "the maker's losing record");
        _refusedClaim(stranger, market, T.a, Side.A, NO_PAYOUT, "the bettor's side A record");
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, "the bettor's side B record");
    }

    /// The card: a refused claim changes nothing and pays later.
    /// Break: in OspexPositions._claim, make the transfer non-reverting with its answer unread,
    /// `i_token.trySafeTransfer(account, payout);`: the record is marked and nothing is paid.
    function test_neverLine_aRefusedClaimChangesNothingAndPaysLater() public {
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 110 * U);
        _leg(M, T, game, Side.B, 50 * U, 55 * U);
        _leg(M, T, game, Side.B, 100 * U, 110 * U);
        _settleVoid(game, market);
        uint256 snap = vm.snapshotState();

        // The recipient blocked at the claim: the call reverts with the coin's refusal, the record is unclaimed,
        // the total unmoved; the other account's claim pays meanwhile; unblocked, the same call pays the same.
        token.setBlocked(T.a, true);
        (bool ok, bytes memory err) = _tryClaimFor(stranger, market, T.a, Side.A);
        assertFalse(ok, "paid while the coin refused");
        assertEq(err, abi.encodeWithSelector(RefusingCoin.Blocked.selector, T.a), "the coin's refusal, passed up");
        assertFalse(_position(market, T.a, Side.A).claimed, "marked while unpaid");
        assertEq(positions.s_heldTotal(market), 105 * U, "the total moved for a refused claim");
        assertEq(_claimFor(stranger, market, M.a, Side.A), 40 * U, "the other account's claim, meanwhile");
        token.setBlocked(T.a, false);
        assertEq(_claimFor(stranger, market, T.a, Side.A), 65 * U, "the same call, once the coin allows");
        assertEq(positions.s_heldTotal(market), 0);
        vm.revertToState(snap);

        // The coin paused: every claim reverts while it is paused, and the same call pays after the unpause.
        token.setPaused(true);
        (ok, err) = _tryClaimFor(stranger, market, M.a, Side.A);
        assertFalse(ok, "paid while paused");
        assertEq(err, abi.encodeWithSelector(RefusingCoin.Paused.selector));
        (ok, err) = _tryClaim(T.a, market, Side.A);
        assertFalse(ok, "paid while paused");
        assertEq(err, abi.encodeWithSelector(RefusingCoin.Paused.selector));
        assertEq(positions.s_heldTotal(market), 105 * U);
        token.setPaused(false);
        assertEq(_claimFor(stranger, market, M.a, Side.A), 40 * U, "the maker, after the unpause");
        assertEq(_claim(T.a, market, Side.A), 65 * U, "the bettor, after the unpause");
        assertEq(_coin().balanceOf(address(positions)), 0);
        vm.revertToState(snap);
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// The card: a refused pay-back blocks no fill and loses nothing, with three coins.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralRefusedPayBackTest is SharedCollateralBase {
    /// Break: in OspexPositions._payBack, remove the try: call `this.sendPayBack(account, amount);` so a refusal
    /// reverts the Cross. Others turn it red: the held amount not put back; the total not put back; the
    /// self-call removed and the transfer made inline with the non-reverting form, under the lying coin.
    function test_neverLine_aRefusedPayBackBlocksNoFillAndLosesNothing() public {
        for (uint256 kind; kind < 3; ++kind) {
            uint256 snap = vm.snapshotState();
            _withCoin(kind);
            vm.revertToState(snap);
        }
    }

    /// @dev The coin: 0 refuses by reverting, 1 answers false and moves nothing, 2 moves the balance and then
    ///      answers false.
    function _refuse(uint256 kind, address who, bool on) internal {
        address coin = address(positions.i_token());
        if (kind == 0) RefusingCoin(coin).setBlocked(who, on);
        else if (kind == 1) FalseCoin(coin).setRefuseTo(who, on);
        else LyingCoin(coin).setLyingTo(who, on);
    }

    function _withCoin(uint256 kind) internal {
        string memory name = kind == 0 ? "the reverting coin" : kind == 1 ? "the false coin" : "the lying coin";
        address coin;
        if (kind == 0) coin = address(new RefusingCoin());
        else if (kind == 1) coin = address(new FalseCoin());
        else coin = address(new LyingCoin());
        _deploySetOn(coin);
        _ready(M);
        _ready(T);
        uint256 game = _verifiedGame();
        uint256 mStart = _coin().balanceOf(M.a);
        uint256 tStart = _coin().balanceOf(T.a);
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 110 * U);

        // Fill 2 with the maker's pay-back refused: the Cross completes, the bettor is paid its 50, the maker's
        // 55 stays held and counted, one refusal names it, and the contract's coin equals the market's total.
        _refuse(kind, M.a, true);
        vm.recordLogs();
        _leg(M, T, game, Side.B, 50 * U, 55 * U);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Refused[] memory rs = _refusals(logs);
        assertEq(rs.length, 1, string.concat(name, ": one refusal"));
        assertEq(rs[0].account, M.a, string.concat(name, ": the refused account"));
        assertEq(rs[0].amount, 55 * U, string.concat(name, ": the refused amount"));
        assertEq(rs[0].held, 100 * U, string.concat(name, ": what stays held"));
        Held[] memory hs = _heldChanges(logs);
        assertEq(hs.length, 1, string.concat(name, ": the bettor's pay-back alone"));
        _assertHeld(hs[0], T.a, 0, 50 * U, 60 * U, string.concat(name, ": the bettor's pay-back"));
        assertEq(positions.s_held(market, M.a), 100 * U, string.concat(name, ": the maker's held amount, unchanged"));
        assertEq(positions.s_held(market, T.a), 60 * U, string.concat(name, ": the bettor's held amount"));
        assertEq(positions.s_heldTotal(market), 160 * U, string.concat(name, ": the total"));
        assertEq(
            _coin().balanceOf(address(positions)), 160 * U, string.concat(name, ": the contract's coin is the total")
        );
        assertEq(_change(mStart, M.a), -100 * int256(U), string.concat(name, ": the maker's coin did not move"));
        assertEq(_change(tStart, T.a), -60 * int256(U), string.concat(name, ": the bettor's coin"));
        assertEq(_position(market, M.a, Side.A).risk, 50 * U, string.concat(name, ": the fill landed"));

        // (a) Unblocked, its next fill pays the excess out: fill 3 pays the maker 60, the proof's fifth example.
        uint256 snap = vm.snapshotState();
        _refuse(kind, M.a, false);
        vm.recordLogs();
        _leg(M, T, game, Side.B, 100 * U, 110 * U);
        hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, string.concat(name, ": fill 3, two movements"));
        _assertHeld(hs[0], T.a, 5 * U, 0, 65 * U, string.concat(name, ": fill 3, the bettor pulled 5"));
        _assertHeld(hs[1], M.a, 0, 60 * U, 40 * U, string.concat(name, ": fill 3, the maker paid 60"));
        assertEq(_change(mStart, M.a), -40 * int256(U), string.concat(name, ": the maker after fill 3"));
        _settlePush(game, market);
        assertEq(_claimFor(stranger, market, M.a, Side.A), 40 * U, string.concat(name, ": (a) the maker's claim"));
        assertEq(_claimFor(stranger, market, T.a, Side.A), 65 * U, string.concat(name, ": (a) the bettor's claim"));
        assertEq(_change(mStart, M.a), 0, string.concat(name, ": (a) the maker ends where the ledger says"));
        assertEq(_change(tStart, T.a), 0, string.concat(name, ": (a) the bettor ends where the ledger says"));
        assertEq(_coin().balanceOf(address(positions)), 0, string.concat(name, ": (a) coin left"));
        vm.revertToState(snap);

        // (b) Left blocked until the score, then unblocked: its claim pays it, on a push as two positive shares.
        _settlePush(game, market);
        _refuse(kind, M.a, false);
        assertEq(_claimFor(stranger, market, M.a, Side.A), 50 * U, string.concat(name, ": (b) side A, up to its risk"));
        assertEq(_claimFor(stranger, market, M.a, Side.B), 50 * U, string.concat(name, ": (b) side B, the rest"));
        assertEq(_claimFor(stranger, market, T.a, Side.A), 60 * U, string.concat(name, ": (b) the bettor"));
        _refusedClaim(stranger, market, T.a, Side.B, NO_PAYOUT, string.concat(name, ": (b) the bettor's side B"));
        assertEq(_change(mStart, M.a), 0, string.concat(name, ": (b) the maker ends where the ledger says"));
        assertEq(_change(tStart, T.a), 0, string.concat(name, ": (b) the bettor ends where the ledger says"));
        assertEq(_coin().balanceOf(address(positions)), 0, string.concat(name, ": (b) coin left"));
        vm.revertToState(snap);
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// L232, the loss: a wrong transfer on one market is seen on the other, with the lying coin.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralLyingCoinTest is SharedCollateralBase {
    LyingCoin internal lying;

    function setUp() public override {
        super.setUp();
        lying = new LyingCoin();
        _deploySetOn(address(lying));
        _ready(M);
        _ready(T);
    }

    /// Break: in OspexPositions._payBack, remove the self-call and make the transfer inline with the
    /// non-reverting form, `if (!i_token.trySafeTransfer(account, amount)) { ...put back... }`: under the lying
    /// coin the 55 leaves and the numbers still count it, the first market pays 160 from 105 of its own and 55
    /// of the second's, and the second market's claim of 210 fails in the coin.
    function test_neverLine_aLossOnOneMarketIsSeenOnTheOther() public {
        uint256 game1 = _verifiedGame();
        uint256 game2 = _verifiedGame();
        uint256 m1 = _leg(M, T, game1, Side.A, 100 * U, 110 * U);
        lying.setLyingTo(M.a, true);
        vm.recordLogs();
        _leg(M, T, game1, Side.B, 50 * U, 55 * U);
        Refused[] memory rs = _refusals(vm.getRecordedLogs());
        assertEq(rs.length, 1, "the lying coin's refusal is recorded");
        assertEq(rs[0].account, M.a);
        assertEq(rs[0].amount, 55 * U);
        lying.setLyingTo(M.a, false);
        assertEq(positions.s_heldTotal(m1), 160 * U, "the first market's total");
        assertEq(lying.balanceOf(address(positions)), 160 * U, "the coin moved and then lied: the move was undone");
        // The second market, funded above the 55 a mutant could over-pay: 210 in.
        uint256 m2 = _leg(M, T, game2, Side.A, 100 * U, 110 * U);
        assertEq(positions.s_heldTotal(m2), 210 * U);
        assertEq(lying.balanceOf(address(positions)), 370 * U);

        _settleHome(game1, m1);
        _settleHome(game2, m2);
        assertEq(_claimFor(stranger, m1, M.a, Side.A), 55 * U, "the first market pays the maker 55");
        assertEq(_claimFor(stranger, m1, T.a, Side.A), 105 * U, "and the bettor 105");
        assertEq(positions.s_heldTotal(m1), 0);
        assertEq(
            lying.balanceOf(address(positions)), positions.s_heldTotal(m2), "the balance is the second market's total"
        );
        assertEq(lying.balanceOf(address(positions)), 210 * U);
        assertEq(_claimFor(stranger, m2, T.a, Side.A), 210 * U, "the second market's one paying claim");
        assertEq(lying.balanceOf(address(positions)), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// L231. A claim neither forgets the early money nor takes it twice.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralClaimTest is SharedCollateralBase {
    Signer internal O;
    Signer internal M1;
    Signer internal M2;

    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
        O = _account("the attack's owner");
        M1 = _account("maker one");
        M2 = _account("maker two");
        _register(O.a, sender);
        _register(M1.a, sender);
        _register(M2.a, sender);
    }

    /// @dev Both orders of an account's two claims, the owner sending one and a stranger the other: each record
    ///      pays its literal once, a record with nothing to pay is refused by name, and a second claim of a paid
    ///      record is refused by name. `settle` is 0 home, 1 away, 2 push, 3 void.
    function _bothOrders(uint256 game, uint256 market, Signer memory who, uint256 settle, uint256 wantA, uint256 wantB)
        internal
    {
        string memory name =
            string.concat(settle == 0 ? "home" : settle == 1 ? "away" : settle == 2 ? "push" : "void", " ");
        for (uint256 bFirst; bFirst < 2; ++bFirst) {
            uint256 snap = vm.snapshotState();
            if (settle == 0) _settleHome(game, market);
            else if (settle == 1) _settleAway(game, market);
            else if (settle == 2) _settlePush(game, market);
            else _settleVoid(game, market);
            uint256 before = _coin().balanceOf(who.a);
            Side first = bFirst == 1 ? Side.B : Side.A;
            Side second = _other(first);
            uint256 wantFirst = first == Side.A ? wantA : wantB;
            uint256 wantSecond = first == Side.A ? wantB : wantA;
            _oneClaim(who.a, market, who.a, first, wantFirst, string.concat(name, "first, by the owner"));
            _oneClaim(stranger, market, who.a, second, wantSecond, string.concat(name, "second, by a stranger"));
            // Again, both: refused by name, as paid or as nothing to pay.
            _oneClaim(stranger, market, who.a, first, wantFirst == 0 ? 0 : 1, string.concat(name, "first again"));
            _oneClaim(who.a, market, who.a, second, wantSecond == 0 ? 0 : 1, string.concat(name, "second again"));
            assertEq(_change(before, who.a), int256(wantA + wantB), string.concat(name, "the account's coin"));
            vm.revertToState(snap);
        }
    }

    /// @dev One claim: paid exactly `want` when it is above one; refused NoPayout when it is zero; refused
    ///      AlreadyClaimed when it is one, the mark of a record paid already.
    function _oneClaim(address caller, uint256 market, address account, Side side, uint256 want, string memory what)
        internal
    {
        if (want == 0) {
            _refusedClaim(caller, market, account, side, NO_PAYOUT, string.concat(what, ": nothing to pay"));
        } else if (want == 1) {
            _refusedClaim(caller, market, account, side, ALREADY_CLAIMED, string.concat(what, ": paid already"));
        } else {
            assertEq(_claimFor(caller, market, account, side), want, what);
        }
    }

    /// Break: in OspexPositions._share, pay the winning record `risk + profit` as today: part 1's maker is paid
    /// 315, not 105. Others turn it red: held left out of the whole; side B paid what is held instead of the
    /// rest; side A paid the whole on a push without the cap at its risk; the claimed mark not written; the net
    /// subtracted without the comparison.
    function test_neverLine_theClaimIsNetOfEarlyMoneyOnce() public {
        // Part 1's book: the maker 40 and the bettor 65.
        uint256 game = _verifiedGame();
        uint256 market = _leg(M, T, game, Side.A, 100 * U, 110 * U);
        _leg(M, T, game, Side.B, 50 * U, 55 * U);
        _leg(M, T, game, Side.B, 100 * U, 110 * U);
        _bothOrders(game, market, M, 0, 105 * U, 0);
        _bothOrders(game, market, T, 0, 0, 0);
        _bothOrders(game, market, M, 1, 0, 0);
        _bothOrders(game, market, T, 1, 0, 105 * U);
        _bothOrders(game, market, M, 2, 40 * U, 0);
        _bothOrders(game, market, T, 2, 65 * U, 0);
        _bothOrders(game, market, M, 3, 40 * U, 0);
        _bothOrders(game, market, T, 3, 65 * U, 0);

        // The proof's third example: the maker resting twice, both held 120; the bettor's push shares are 100
        // on side A and 20 on side B, both positive.
        uint256 game2 = _verifiedGame();
        uint256 m2 = _leg(M, T, game2, Side.A, 100 * U, 100 * U);
        _legs(T, game2, Side.B, _two(M, M), _pair(60 * U, 160 * U), _pair(60 * U, 160 * U));
        assertEq(positions.s_held(m2, M.a), 120 * U);
        assertEq(positions.s_held(m2, T.a), 120 * U);
        _bothOrders(game2, m2, M, 0, 240 * U, 0);
        _bothOrders(game2, m2, T, 0, 0, 0);
        _bothOrders(game2, m2, M, 1, 0, 0);
        _bothOrders(game2, m2, T, 1, 0, 240 * U);
        _bothOrders(game2, m2, M, 2, 120 * U, 0);
        _bothOrders(game2, m2, T, 2, 100 * U, 20 * U);
        _bothOrders(game2, m2, M, 3, 120 * U, 0);
        _bothOrders(game2, m2, T, 3, 100 * U, 20 * U);

        // The attack's: the owner takes 100 on side A and 10,000 on side B against two makers; held 9,900; a
        // push pays 100 and 9,800.
        uint256 game3 = _verifiedGame();
        uint256 m3 = _leg(M1, O, game3, Side.A, 100, 100);
        _leg(M2, O, game3, Side.B, 10_000, 10_000);
        assertEq(positions.s_held(m3, O.a), 9_900);
        _bothOrders(game3, m3, O, 0, 0, 0);
        _bothOrders(game3, m3, M2, 0, 20_000, 0);
        _bothOrders(game3, m3, M1, 0, 0, 0);
        _bothOrders(game3, m3, O, 1, 0, 19_800);
        _bothOrders(game3, m3, M1, 1, 0, 200);
        _bothOrders(game3, m3, M2, 1, 0, 0);
        _bothOrders(game3, m3, O, 2, 100, 9_800);
        _bothOrders(game3, m3, M1, 2, 0, 100);
        _bothOrders(game3, m3, M2, 2, 10_000, 0);
        _bothOrders(game3, m3, O, 3, 100, 9_800);
        _bothOrders(game3, m3, M1, 3, 0, 100);
        _bothOrders(game3, m3, M2, 3, 10_000, 0);
        // Every claim on the attack's book on a push, and the market empties.
        uint256 snap = vm.snapshotState();
        _settlePush(game3, m3);
        assertEq(_claimFor(stranger, m3, O.a, Side.B), 9_800, "a stranger claiming side B first");
        assertEq(_claimFor(stranger, m3, O.a, Side.A), 100);
        assertEq(_claimFor(stranger, m3, M1.a, Side.B), 100);
        assertEq(_claimFor(stranger, m3, M2.a, Side.A), 10_000);
        assertEq(positions.s_heldTotal(m3), 0, "the market empties");
        assertEq(positions.s_held(m3, O.a), 9_900, "the frozen held amount does not move at a claim");
        vm.revertToState(snap);
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// L230, after the writes: a pay-back comes after every write, with a coin that calls the paid account back;
// and the pay-back entry.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralCallbackTest is SharedCollateralBase {
    TrickCoin internal trick;
    Signer internal Y;
    Signer internal TK;

    function setUp() public override {
        super.setUp();
        trick = new TrickCoin();
        _deploySetOn(address(trick));
        _ready(M);
        _ready(T);
        Y = _account("resting account with code");
        TK = _account("taking account");
        bytes memory code = address(new CallbackAccount()).code;
        vm.etch(Y.a, code);
        _register(Y.a, sender);
        _register(TK.a, sender);
    }

    /// @dev What the armed receiver answered, in order.
    function _answers() internal view returns (bool[] memory ok, bytes[] memory answer) {
        return CallbackAccount(Y.a).results();
    }

    /// Break: in OspexPositions._payBack, move the two writes below the self-call: the held amount the receiver
    /// reads from inside is 100, not 40. Others turn it red: the pay-backs made at each leg, which the proof's
    /// witness in the roles test sees; the guard removed from finishFills or from claimPositionFor, which
    /// changes the refusal's name here.
    function test_neverLine_aPayBackComesAfterEveryWrite_withACoinThatCallsBack() public {
        _inPlay();
        _releasedFromInside();
    }

    /// @dev On a game in play: from inside its pay-back the receiver tries every write of the set and reads the
    ///      numbers. The matching module's six are refused CrossInProgress; the positions module's fill, end
    ///      call and both claims ReentrancyGuardReentrantCall; the pay-back entry NotSelf; settlement
    ///      GameNotEnded. The reads show both records, the held amounts and the total as written before the
    ///      transfer: the receiver's 40 of 100 and the taking account's 40, the total 80.
    function _inPlay() internal {
        uint256 game = _verifiedGame();
        uint256 market = _leg(Y, TK, game, Side.A, 100 * U, 100 * U);
        assertEq(positions.s_held(market, Y.a), 100 * U);
        trick.setHooked(Y.a, true);
        OspexMatching.SignedOrder memory taking = _take(TK, game, Side.B, 101, 60 * U);
        OspexMatching.SignedOrder memory resting = _restFor(Y, game, Side.A, 60 * U, 60 * U);
        OspexMatching.SignedOrder memory spare = _rest(Y, game, Side.A, 200, 10_000);
        address[] memory nobody = new address[](0);
        CallbackAccount r = CallbackAccount(Y.a);
        r.arm(address(matching), abi.encodeCall(OspexMatching.cross, (taking, _list(spare))));
        r.armAlso(address(matching), abi.encodeCall(OspexMatching.cancelOrder, (spare.order)));
        r.armAlso(address(matching), abi.encodeCall(OspexMatching.raiseMinNonce, (game, address(moneyline), 0, 7)));
        r.armAlso(address(matching), abi.encodeCall(OspexMatching.registerCourier, (stranger)));
        r.armAlso(address(matching), abi.encodeCall(OspexMatching.unregisterCourier, (sender)));
        r.armAlso(address(matching), abi.encodeCall(OspexMatching.liftTakingStakeCap, ()));
        r.armAlso(
            address(positions),
            abi.encodeCall(OspexPositions.recordFill, (game, address(moneyline), 0, Side.A, Y.a, 100, TK.a, 100))
        );
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.finishFills, (market, Y.a, nobody)));
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.claimPosition, (market, Side.A)));
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.claimPositionFor, (market, Y.a, Side.A)));
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.sendPayBack, (Y.a, 1)));
        r.armAlso(address(markets), abi.encodeCall(OspexMarkets.settleMarket, (market)));
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.getPosition, (market, Y.a, Side.A)));
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.getPosition, (market, Y.a, Side.B)));
        r.armAlso(address(positions), abi.encodeCall(IOspexPositions.s_held, (market, Y.a)));
        r.armAlso(address(positions), abi.encodeCall(IOspexPositions.s_heldTotal, (market)));
        r.armAlso(address(positions), abi.encodeCall(IOspexPositions.s_held, (market, TK.a)));

        uint256 yBefore = trick.balanceOf(Y.a);
        _cross(sender, taking, _list(resting));
        assertEq(trick.balanceOf(Y.a) - yBefore, 60 * U, "the receiver's pay-back");
        assertEq(r.calls(), 1, "the coin called the receiver back once in this Cross");
        (bool[] memory ok, bytes[] memory answer) = _answers();
        assertEq(ok.length, 17, "seventeen calls from inside");
        bytes memory inProgress = abi.encodeWithSelector(OspexMatching.OspexMatching__CrossInProgress.selector);
        bytes memory reentrant = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        for (uint256 i; i < 6; ++i) {
            assertFalse(ok[i], "a matching write from inside a pay-back was taken");
            assertEq(answer[i], inProgress, string.concat("matching write ", vm.toString(i)));
        }
        for (uint256 i = 6; i < 10; ++i) {
            assertFalse(ok[i], "a positions write from inside a pay-back was taken");
            assertEq(answer[i], reentrant, string.concat("positions write ", vm.toString(i)));
        }
        assertFalse(ok[10], "the pay-back entry from inside was taken");
        assertEq(
            answer[10],
            abi.encodeWithSelector(IOspexPositions.OspexPositions__NotSelf.selector, Y.a),
            "the entry refuses by its own name, not the guard's"
        );
        assertFalse(ok[11], "a game in play was settled from inside");
        assertEq(
            answer[11],
            abi.encodeWithSelector(
                OspexMarkets.OspexMarkets__GameNotEnded.selector, game, uint8(games.getGameStatus(game))
            ),
            "settlement's refusal of a game in play"
        );
        for (uint256 i = 12; i < 17; ++i) {
            assertTrue(ok[i], "a read from inside failed");
        }
        Position memory a = abi.decode(answer[12], (Position));
        Position memory b = abi.decode(answer[13], (Position));
        assertEq(a.risk, 60 * U, "the receiver's side A record, written before the pay-back");
        assertEq(a.profit, 60 * U);
        assertEq(b.risk, 100 * U, "the receiver's side B record");
        assertEq(b.profit, 100 * U);
        assertEq(abi.decode(answer[14], (uint256)), 40 * U, "the receiver's held amount, lowered before the transfer");
        assertEq(abi.decode(answer[15], (uint256)), 80 * U, "the total, both pay-backs taken off before the transfer");
        assertEq(abi.decode(answer[16], (uint256)), 40 * U, "the taking account's held amount, paid back first");
        // After the Cross, the same numbers stand.
        assertEq(positions.s_held(market, Y.a), 40 * U);
        assertEq(positions.s_held(market, TK.a), 40 * U);
        assertEq(positions.s_heldTotal(market), 80 * U);
        assertFalse(_position(market, Y.a, Side.A).claimed, "a claim from inside landed");
        trick.setHooked(Y.a, false);
    }

    /// @dev On an unverified game past its day-30 clock: from inside its pay-back the receiver releases the game
    ///      and settles the market, which neither guard holds; the Cross completes, the market reads void, and
    ///      every claim pays what is held.
    function _releasedFromInside() internal {
        uint256 game = _create();
        uint256 market = _leg(Y, TK, game, Side.A, 100 * U, 100 * U);
        vm.warp(DATE + 30 days);
        trick.setHooked(Y.a, true);
        CallbackAccount r = CallbackAccount(Y.a);
        r.arm(address(games), abi.encodeCall(IOspexGames.release, (game)));
        r.armAlso(address(markets), abi.encodeCall(OspexMarkets.settleMarket, (market)));
        vm.recordLogs();
        _leg(Y, TK, game, Side.B, 60 * U, 60 * U);
        (bool[] memory ok,) = _answers();
        assertEq(ok.length, 2);
        assertTrue(ok[0], "the release from inside was refused");
        assertTrue(ok[1], "the settlement from inside was refused");
        assertEq(uint8(_outcome(market)), uint8(Outcome.Void), "the market settled as a void from inside");
        Held[] memory hs = _heldChanges(vm.getRecordedLogs());
        assertEq(hs.length, 2, "the Cross completed with both pay-backs");
        _assertHeld(hs[0], TK.a, 0, 60 * U, 40 * U, "the taking account's pay-back");
        _assertHeld(
            hs[1], Y.a, 0, 60 * U, 40 * U, "the receiver's pay-back, the one the settlement came from inside of"
        );
        assertEq(_claimFor(stranger, market, Y.a, Side.A), 40 * U, "the receiver gets back what it holds");
        _refusedClaim(stranger, market, Y.a, Side.B, NO_PAYOUT, "the receiver's side B record");
        assertEq(_claimFor(stranger, market, TK.a, Side.A), 40 * U, "the taking account gets back what it holds");
        _refusedClaim(stranger, market, TK.a, Side.B, NO_PAYOUT, "the taking account's side B record");
        assertEq(positions.s_heldTotal(market), 0);
        trick.setHooked(Y.a, false);
    }

    /// The writes come before the coin moves, at a pull and at a claim: an account the coin calls back during
    /// its own pull reads its held amount and the market's total already raised; a recipient the coin calls back
    /// during its claim reads its record marked and the total already lowered, and its own claim from inside
    /// refused by the guard.
    /// Break: in OspexPositions._pull, move the two writes below the transfer. Another turns it red: in _claim,
    /// the mark and the total written after the transfer.
    function test_neverLine_theWritesComeBeforeTheCoinMoves() public {
        uint256 game = _verifiedGame();
        uint256 market = markets.marketCount() + 1;
        trick.setHooked(Y.a, true);
        CallbackAccount r = CallbackAccount(Y.a);
        r.arm(address(positions), abi.encodeCall(IOspexPositions.s_held, (market, Y.a)));
        r.armAlso(address(positions), abi.encodeCall(IOspexPositions.s_heldTotal, (market)));
        assertEq(_leg(Y, TK, game, Side.B, 100 * U, 100 * U), market, "the market drawn");
        (bool[] memory ok, bytes[] memory answer) = _answers();
        assertEq(ok.length, 2, "two reads from inside the pull");
        assertTrue(ok[0] && ok[1], "a read from inside the pull failed");
        assertEq(abi.decode(answer[0], (uint256)), 100 * U, "the receiver's held amount, raised before the pull");
        assertEq(abi.decode(answer[1], (uint256)), 100 * U, "the total, raised before the pull");

        _settleHome(game, market);
        r.arm(address(positions), abi.encodeCall(OspexPositions.getPosition, (market, Y.a, Side.A)));
        r.armAlso(address(positions), abi.encodeCall(IOspexPositions.s_heldTotal, (market)));
        r.armAlso(address(positions), abi.encodeCall(OspexPositions.claimPosition, (market, Side.A)));
        assertEq(_claimFor(stranger, market, Y.a, Side.A), 200 * U, "the receiver's claim");
        (ok, answer) = _answers();
        assertEq(ok.length, 3, "three calls from inside the claim");
        assertTrue(ok[0] && ok[1], "a read from inside the claim failed");
        assertTrue(abi.decode(answer[0], (Position)).claimed, "the record is not yet marked inside the transfer");
        assertEq(abi.decode(answer[1], (uint256)), 0, "the total, lowered before the transfer");
        assertFalse(ok[2], "a claim from inside a claim's transfer was taken");
        assertEq(answer[2], abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        trick.setHooked(Y.a, false);
    }

    /// The pay-back entry: only the contract calls it, and it carries no guard of its own.
    /// Break: in OspexPositions.sendPayBack, delete the self-only check: a stranger calls it and is paid. Another
    /// turns it red: a guard added to the entry, so every pay-back from inside finishFills is refused and
    /// recorded, and the positive control goes red.
    function test_payBackEntry_isTheContractsAloneAndUnguarded() public {
        uint256 game = _verifiedGame();
        _leg(M, T, game, Side.A, 100 * U, 110 * U);
        uint256 funded = trick.balanceOf(address(positions));
        assertEq(funded, 210 * U, "the contract is funded");
        address[5] memory callers = [stranger, M.a, sender, address(matching), address(core)];
        for (uint256 i; i < 5; ++i) {
            uint256 before = trick.balanceOf(M.a);
            vm.prank(callers[i], callers[i]);
            (bool ok, bytes memory err) =
                address(positions).call(abi.encodeCall(OspexPositions.sendPayBack, (M.a, 1 * U)));
            assertFalse(ok, "the entry took a call from outside");
            assertEq(
                err,
                abi.encodeWithSelector(IOspexPositions.OspexPositions__NotSelf.selector, callers[i]),
                "the entry's refusal names the caller"
            );
            assertEq(trick.balanceOf(M.a), before, "coin moved");
            assertEq(trick.balanceOf(address(positions)), funded, "coin left the contract");
        }
        // From inside a pay-back: refused by that name and not by the guard's (the callback test's case 11 sees
        // it too); here the receiver is armed with that one call.
        uint256 game2 = _verifiedGame();
        uint256 m2 = _leg(Y, TK, game2, Side.A, 100 * U, 100 * U);
        trick.setHooked(Y.a, true);
        CallbackAccount(Y.a).arm(address(positions), abi.encodeCall(OspexPositions.sendPayBack, (Y.a, 1)));
        _leg(Y, TK, game2, Side.B, 60 * U, 60 * U);
        (bool[] memory oks, bytes[] memory answers) = _answers();
        assertEq(oks.length, 1);
        assertFalse(oks[0], "the entry took a call from inside a pay-back");
        assertEq(answers[0], abi.encodeWithSelector(IOspexPositions.OspexPositions__NotSelf.selector, Y.a));
        assertEq(positions.s_held(m2, Y.a), 40 * U);
        trick.setHooked(Y.a, false);

        // The positive control: part 1's fill 2 pays its two pay-backs, 55 and 50, through the entry, end to
        // end: one call of the entry each, one held change each, and no refusal.
        vm.expectCall(address(positions), abi.encodeCall(OspexPositions.sendPayBack, (T.a, 50 * U)), 1);
        vm.expectCall(address(positions), abi.encodeCall(OspexPositions.sendPayBack, (M.a, 55 * U)), 1);
        uint256 mBefore = trick.balanceOf(M.a);
        uint256 tBefore = trick.balanceOf(T.a);
        vm.recordLogs();
        _leg(M, T, game, Side.B, 50 * U, 55 * U);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Held[] memory hs = _heldChanges(logs);
        assertEq(hs.length, 2, "two pay-backs");
        _assertHeld(hs[0], T.a, 0, 50 * U, 60 * U, "the bettor's pay-back through the entry");
        _assertHeld(hs[1], M.a, 0, 55 * U, 45 * U, "the maker's pay-back through the entry");
        assertEq(_refusals(logs).length, 0, "a refusal");
        assertEq(trick.balanceOf(M.a) - mBefore, 55 * U);
        assertEq(trick.balanceOf(T.a) - tBefore, 50 * U);
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Sizing 10. Netting changes when money moves, never how much anyone ends with: the gross reference.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralReferenceTest is SharedCollateralBase {
    Signer internal X;
    /// @dev The second set: today's positions module frozen, on a core of its own, with a matching module built
    ///      from src/ and the same games set and coin.
    OspexBetting internal grossCore;
    OspexMarkets internal grossMarkets;
    GrossPositionsReference internal gross;
    OspexMatching internal grossMatching;
    OspexMoneylineScorer internal grossMoneyline;

    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
        X = _account("another account");
        _register(X.a, sender);
        vm.startPrank(deployer, deployer);
        grossCore = new OspexBetting(address(games), address(token));
        grossMarkets = new OspexMarkets(address(grossCore));
        gross = new GrossPositionsReference(address(grossCore));
        grossMatching = new OspexMatching(address(grossCore));
        OspexMoneylineScorer ml = new OspexMoneylineScorer(address(grossCore));
        grossMoneyline = ml;
        OspexSpreadScorer sp = new OspexSpreadScorer(address(grossCore));
        OspexTotalScorer to = new OspexTotalScorer(address(grossCore));
        bytes32[] memory types = new bytes32[](6);
        address[] memory addrs = new address[](6);
        types[0] = grossCore.MARKET_MODULE();
        addrs[0] = address(grossMarkets);
        types[1] = grossCore.POSITION_MODULE();
        addrs[1] = address(gross);
        types[2] = grossCore.MATCHING_MODULE();
        addrs[2] = address(grossMatching);
        types[3] = grossCore.MONEYLINE_SCORER_MODULE();
        addrs[3] = address(ml);
        types[4] = grossCore.SPREAD_SCORER_MODULE();
        addrs[4] = address(sp);
        types[5] = grossCore.TOTAL_SCORER_MODULE();
        addrs[5] = address(to);
        grossCore.bootstrapModules(types, addrs);
        grossCore.finalize();
        vm.stopPrank();
        _throughTimelockTo(address(grossMatching), abi.encodeCall(OspexMatching.liftTakingStakeCap, ()));
        assertTrue(grossMatching.s_takingStakeCapLifted(), "the gross set's cap was not lifted");
        Signer[3] memory all = [M, T, X];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(all[i].a);
            token.approve(address(gross), type(uint256).max);
            grossMatching.registerCourier(sender);
            vm.stopPrank();
        }
    }

    /// @dev An order signed for the gross set's matching module.
    function _grossSigned(OspexMatching.OspexOrder memory o, uint256 key)
        internal
        view
        returns (OspexMatching.SignedOrder memory)
    {
        return OspexMatching.SignedOrder({order: o, signature: _signature(key, _digestOn(address(grossMatching), o))});
    }

    /// @dev One Cross on the set named: `t` takes `takerSide` for the sum against `ms` resting the other side.
    function _crossOn(
        bool onGross,
        Signer memory t,
        uint256 game,
        Side takerSide,
        Signer[] memory ms,
        uint256[] memory makerRisks,
        uint256[] memory takerRisks
    ) internal {
        uint256 sum;
        OspexMatching.SignedOrder[] memory resting = new OspexMatching.SignedOrder[](ms.length);
        for (uint256 i; i < ms.length; ++i) {
            sum += takerRisks[i];
            uint256 p = takerRisks[i] * 100 / makerRisks[i];
            OspexMatching.OspexOrder memory o = _order(
                ms[i].a,
                game,
                onGross ? address(grossMoneyline) : address(moneyline),
                0,
                _other(takerSide),
                _tick(100 + p),
                makerRisks[i],
                nextNonce++,
                vm.getBlockTimestamp() + 1 days
            );
            resting[i] = onGross ? _grossSigned(o, ms[i].key) : _signed(o, ms[i].key);
        }
        OspexMatching.OspexOrder memory to = _order(
            t.a,
            game,
            onGross ? address(grossMoneyline) : address(moneyline),
            0,
            takerSide,
            101,
            sum,
            nextNonce++,
            vm.getBlockTimestamp() + 30
        );
        OspexMatching.SignedOrder memory taking = onGross ? _grossSigned(to, t.key) : _signed(to, t.key);
        vm.prank(sender, crossOrigin);
        (bool ok, bytes memory err) = (onGross ? address(grossMatching) : address(matching))
        .call(abi.encodeCall(OspexMatching.cross, (taking, resting)));
        assertTrue(ok, string.concat(onGross ? "gross: " : "netted: ", "the Cross was refused: ", vm.toString(err)));
    }

    /// @dev The same Crosses into the set named: part 1's three fills, the maker resting twice, a self leg beside
    ///      another maker, and a leg at 2.10 taken by the third account.
    function _theSameCrosses(bool onGross, uint256 game) internal {
        _crossOn(onGross, T, game, Side.A, _one(M), _one(100 * U), _one(110 * U));
        _crossOn(onGross, T, game, Side.B, _one(M), _one(50 * U), _one(55 * U));
        _crossOn(onGross, T, game, Side.B, _one(M), _one(100 * U), _one(110 * U));
        _crossOn(onGross, T, game, Side.B, _two(M, M), _pair(60 * U, 160 * U), _pair(60 * U, 160 * U));
        _crossOn(onGross, T, game, Side.A, _two(X, T), _pair(5_000 * U, 100 * U), _pair(5_000 * U, 100 * U));
        _crossOn(onGross, X, game, Side.B, _one(M), _one(300 * U), _one(330 * U));
    }

    function _one(Signer memory a) internal pure returns (Signer[] memory s) {
        s = new Signer[](1);
        s[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory n) {
        n = new uint256[](1);
        n[0] = a;
    }

    /// @dev Every claim of the three accounts on both sides, by a stranger on the netted set and by each owner
    ///      on the gross one, refusals ignored.
    function _claimEverything(bool onGross, uint256 market) internal {
        Signer[3] memory all = [M, T, X];
        for (uint256 i; i < 3; ++i) {
            for (uint256 s; s < 2; ++s) {
                bool ok;
                bytes memory err;
                if (onGross) {
                    vm.prank(all[i].a, all[i].a);
                    (ok, err) =
                        address(gross).call(abi.encodeCall(GrossPositionsReference.claimPosition, (market, Side(s))));
                } else {
                    (ok, err) = _tryClaimFor(stranger, market, all[i].a, Side(s));
                }
                if (!ok) assertEq(err, abi.encodeWithSelector(NO_PAYOUT), "a claim refused for another reason");
            }
        }
    }

    /// Break: none of its own; it is a second witness for the worst-loss and claim breaks above.
    function test_reference_everyAccountEndsWhereGrossEndsIt() public {
        Signer[3] memory all = [M, T, X];
        for (uint256 settle; settle < 4; ++settle) {
            uint256 start = vm.snapshotState();
            uint256 game = _verifiedGame();
            // The netted set.
            _theSameCrosses(false, game);
            uint256 market = markets.getMarketId(game, address(moneyline), 0);
            _settleAs(settle, game, market, false);
            _claimEverything(false, market);
            uint256[3] memory netted;
            for (uint256 i; i < 3; ++i) {
                netted[i] = token.balanceOf(all[i].a);
            }
            assertEq(token.balanceOf(address(positions)), 0, "netted: coin left in the contract");
            vm.revertToState(start);
            // The gross set, the same game, the same Crosses.
            game = _verifiedGame();
            _theSameCrosses(true, game);
            market = grossMarkets.getMarketId(game, address(grossMoneyline), 0);
            _settleAs(settle, game, market, true);
            _claimEverything(true, market);
            for (uint256 i; i < 3; ++i) {
                assertEq(
                    token.balanceOf(all[i].a),
                    netted[i],
                    string.concat("outcome ", vm.toString(settle), ": an account ends elsewhere than gross puts it")
                );
            }
            assertEq(token.balanceOf(address(gross)), 0, "gross: coin left in the contract");
            vm.revertToState(start);
        }
    }

    function _settleAs(uint256 settle, uint256 game, uint256 market, bool onGross) internal {
        if (settle == 0) {
            _score(game, HOME, AWAY);
        } else if (settle == 1) {
            _score(game, AWAY, HOME);
        } else if (settle == 2) {
            _score(game, 100, 100);
        } else {
            vm.warp(START + WINDOW);
            _voidBy(first, game);
        }
        if (onGross) grossMarkets.settleMarket(market);
        else _settle(market);
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Sizing 5. The stateful fuzz, with a per-market ledger.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralFuzzTest is SharedCollateralBase {
    Signer internal X;
    uint256 internal rng;

    /// @dev The ledger: market → account → [riskA, profitA, riskB, profitB], summed here from the fills that
    ///      landed, read from the fill events.
    mapping(uint256 => mapping(address => uint256[4])) internal ledger;
    /// @dev Whether a pay-back to the account on the market was ever refused: from then on its held amount may
    ///      sit above its worst loss.
    mapping(uint256 => mapping(address => bool)) internal refusedOnce;

    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
        X = _account("the third account");
        _register(X.a, sender);
    }

    function _next(uint256 bound) internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return rng % bound;
    }

    function _who(uint256 i) internal view returns (Signer memory) {
        return i == 0 ? M : i == 1 ? T : X;
    }

    /// @dev Reads the fills a Cross landed into the ledger.
    function _ledgerFrom(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(positions) || logs[i].topics[0] != POSITION_FILLED_TOPIC) continue;
            uint256 market = uint256(logs[i].topics[1]);
            address maker = address(uint160(uint256(logs[i].topics[2])));
            address taker = address(uint160(uint256(logs[i].topics[3])));
            (Side makerSide,, uint256 makerRisk, uint256 takerRisk) =
                abi.decode(logs[i].data, (Side, Side, uint256, uint256));
            uint256 m = makerSide == Side.A ? 0 : 2;
            uint256 t = 2 - m;
            ledger[market][maker][m] += makerRisk;
            ledger[market][maker][m + 1] += takerRisk;
            ledger[market][taker][t] += takerRisk;
            ledger[market][taker][t + 1] += makerRisk;
        }
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(positions) || logs[i].topics[0] != PAY_BACK_REFUSED_TOPIC) continue;
            refusedOnce[uint256(logs[i].topics[1])][address(uint160(uint256(logs[i].topics[2])))] = true;
        }
    }

    /// @dev What the ledger says `who` wins or loses on `market` at `settle` (0 home, 1 away, 2 push).
    function _net(uint256 market, address who, uint256 settle) internal view returns (int256) {
        uint256[4] memory r = ledger[market][who];
        if (settle == 0) return int256(r[1]) - int256(r[2]);
        if (settle == 1) return int256(r[3]) - int256(r[0]);
        return 0;
    }

    /// @dev After every call: each held amount at least its worst loss by the ledger; each open market's total
    ///      the sum of its held amounts; the contract's coin the sum of the totals; the sender unmoved.
    function _invariants(uint256[2] memory mkts, uint256 senderCoin) internal view {
        uint256 totals;
        for (uint256 k; k < 2; ++k) {
            if (mkts[k] == 0) continue;
            uint256 sum;
            for (uint256 i; i < 3; ++i) {
                address who = _who(i).a;
                uint256[4] memory r = ledger[mkts[k]][who];
                uint256 worst = _worstByHand(r[0], r[1], r[2], r[3]);
                assertGe(positions.s_held(mkts[k], who), worst, "held under the worst loss");
                // With no pay-back ever refused, the held amount is the worst loss and not a unit more.
                if (!refusedOnce[mkts[k]][who]) {
                    assertEq(positions.s_held(mkts[k], who), worst, "held above the worst loss");
                }
                sum += positions.s_held(mkts[k], who);
            }
            assertEq(positions.s_heldTotal(mkts[k]), sum, "an open market's total is not the sum of its held amounts");
            totals += sum;
        }
        assertEq(_coin().balanceOf(address(positions)), totals, "the contract's coin is not the sum of the totals");
        assertEq(_coin().balanceOf(sender), senderCoin, "the sender's coin moved");
    }

    /// Break: none of its own: evidence beside the named witnesses.
    function testFuzz_randomBooksEndWhereTheLedgerPutsThem(uint256 seed) public {
        rng = seed;
        uint256[2] memory game = [_verifiedGame(), _verifiedGame()];
        uint256[2] memory mkts;
        uint256[3] memory start = [_coin().balanceOf(M.a), _coin().balanceOf(T.a), _coin().balanceOf(X.a)];
        uint256 senderCoin = _coin().balanceOf(sender);
        uint256 crosses = 4 + _next(8);
        for (uint256 c; c < crosses; ++c) {
            uint256 k = _next(2);
            Signer memory t = _who(_next(3));
            Side side = Side(_next(2));
            uint256 legs = 1 + _next(3);
            Signer[] memory ms = new Signer[](legs);
            uint256[] memory mr = new uint256[](legs);
            uint256[] memory tr = new uint256[](legs);
            uint256[4] memory prices = [uint256(50), 100, 110, 200];
            for (uint256 l; l < legs; ++l) {
                ms[l] = _who(_next(3));
                mr[l] = (1 + _next(50)) * 100 * U;
                tr[l] = mr[l] * prices[_next(4)] / 100;
            }
            // A random refusal: one account blocked for this Cross, so its pull is refused or its pay-back is.
            address blocked;
            if (_next(4) == 0) {
                blocked = _who(_next(3)).a;
                token.setBlocked(blocked, true);
            }
            vm.recordLogs();
            (bool ok, bytes memory err) = _tryLegs(t, game[k], side, ms, mr, tr);
            if (ok) {
                _ledgerFrom(vm.getRecordedLogs());
                mkts[k] = markets.getMarketId(game[k], address(moneyline), 0);
            } else {
                // A Cross is refused here for a refused pull and for nothing else: the taking account's, or
                // every leg skipped for its account's.
                bytes4 why = _selector(err);
                assertTrue(
                    why == IOspexPositions.OspexPositions__TakerPullRefused.selector
                        || why == OspexMatching.OspexMatching__NothingFilled.selector,
                    "a Cross refused for another reason than a refused pull"
                );
            }
            if (blocked != address(0)) token.setBlocked(blocked, false);
            _invariants(mkts, senderCoin);
        }
        // Settlement at a random outcome each, then every claim in a random order, by owners and strangers.
        uint256[2] memory settle = [_next(3), _next(3)];
        for (uint256 k; k < 2; ++k) {
            if (mkts[k] == 0) continue;
            if (settle[k] == 0) _score(game[k], HOME, AWAY);
            else if (settle[k] == 1) _score(game[k], AWAY, HOME);
            else _score(game[k], 100, 100);
            _settle(mkts[k]);
        }
        uint256[12] memory jobs;
        for (uint256 j; j < 12; ++j) {
            jobs[j] = j;
        }
        for (uint256 j = 11; j > 0; --j) {
            uint256 pick = _next(j + 1);
            (jobs[j], jobs[pick]) = (jobs[pick], jobs[j]);
        }
        for (uint256 j; j < 12; ++j) {
            uint256 k = jobs[j] / 6;
            uint256 i = (jobs[j] % 6) / 2;
            Side s = Side(jobs[j] % 2);
            if (mkts[k] == 0) continue;
            address caller = _next(2) == 0 ? _who(i).a : stranger;
            (bool ok, bytes memory err) = _tryClaimFor(caller, mkts[k], _who(i).a, s);
            if (!ok) assertEq(err, abi.encodeWithSelector(NO_PAYOUT), "a claim refused for another reason");
            // A second claim of the same record is refused by name: paid already, or nothing to pay.
            (ok, err) = _tryClaimFor(stranger, mkts[k], _who(i).a, s);
            assertFalse(ok, "a record paid twice");
            assertTrue(
                keccak256(err) == keccak256(abi.encodeWithSelector(ALREADY_CLAIMED))
                    || keccak256(err) == keccak256(abi.encodeWithSelector(NO_PAYOUT)),
                "a second claim refused for another reason"
            );
        }
        for (uint256 i; i < 3; ++i) {
            int256 net;
            for (uint256 k; k < 2; ++k) {
                if (mkts[k] != 0) net += _net(mkts[k], _who(i).a, settle[k]);
            }
            assertEq(
                int256(_coin().balanceOf(_who(i).a)) - int256(start[i]),
                net,
                "an account ends elsewhere than the ledger puts it"
            );
        }
        for (uint256 k; k < 2; ++k) {
            if (mkts[k] != 0) assertEq(positions.s_heldTotal(mkts[k]), 0, "a market did not empty");
        }
        assertEq(_coin().balanceOf(address(positions)), 0, "coin left in the contract");
        assertEq(_coin().balanceOf(sender), senderCoin, "the sender's coin moved");
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Gas, printed and not pinned.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

contract OspexSharedCollateralGasTest is SharedCollateralBase {
    Signer internal M2;
    OspexCourierRelay internal relay;
    address internal relayKey = makeAddr("the relay's key");

    function setUp() public override {
        super.setUp();
        _ready(M);
        _ready(T);
        M2 = _account("maker two");
        _register(M2.a, sender);
        relay = new OspexCourierRelay(address(matching), relayKey);
        _register(M.a, address(relay));
        _register(T.a, address(relay));
    }

    /// What a one-cent leg costs, as the gas of the call into the matching module: a market's first fill by two
    /// accounts new to it, after a warming Cross, the same shape the minimum fill's gas test measures; then a
    /// later fill by the same two accounts on that market, no pay-back; a fill that pays an account back; a fill
    /// that pulls nothing from an account; a fill whose pay-back is refused; a Cross of three legs with a self
    /// leg; and a one-cent first fill through the relay.
    function test_gas_sharedCollateral() public {
        uint256 warm = _verifiedGame();
        uint256 first = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(T, warm, Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(M, warm, Side.A, 200, 10_000)));

        taking = _take(T, first, Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(M, first, Side.A, 200, 10_000)));
        emit log_named_uint(
            "one cent, one leg, the market's first fill, two accounts new to it", vm.lastCallGas().gasTotalUsed
        );

        taking = _take(T, first, Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(M, first, Side.A, 200, 10_000)));
        emit log_named_uint(
            "a later fill by the same two accounts on that market, no pay-back", vm.lastCallGas().gasTotalUsed
        );

        // The other way: both accounts' worst losses fall, so nothing is pulled and both are paid back.
        taking = _take(T, first, Side.A, 200, 10_000);
        _cross(sender, taking, _list(_rest(M, first, Side.B, 200, 10_000)));
        emit log_named_uint("a fill that pulls nothing and pays both accounts back", vm.lastCallGas().gasTotalUsed);

        // A fill that pulls nothing from one account and pays the other back: a third account takes the
        // bettor's side against the maker, whose book is balanced and now tips.
        taking = _take(M2, first, Side.B, 200, 10_000);
        _cross(sender, taking, _list(_rest(M, first, Side.A, 200, 10_000)));
        emit log_named_uint("a fill that pulls a new account and pulls the maker", vm.lastCallGas().gasTotalUsed);

        // A refused pay-back: the maker blocked, its pay-back at the end recorded and not made.
        token.setBlocked(M.a, true);
        taking = _take(T, first, Side.A, 200, 10_000);
        _cross(sender, taking, _list(_rest(M, first, Side.B, 200, 10_000)));
        emit log_named_uint("a fill whose pay-back the coin refuses", vm.lastCallGas().gasTotalUsed);
        token.setBlocked(M.a, false);

        // Three legs, one of them the taking account's own, on a fresh market.
        uint256 three = _verifiedGame();
        OspexMatching.SignedOrder[] memory legs = new OspexMatching.SignedOrder[](3);
        legs[0] = _rest(M, three, Side.A, 200, 10_000);
        legs[1] = _rest(T, three, Side.A, 200, 100);
        legs[2] = _rest(M2, three, Side.A, 200, 5_000);
        taking = _take(T, three, Side.B, 200, 15_100);
        _cross(sender, taking, legs);
        emit log_named_uint("three legs, a self leg among them, a market's first fill", vm.lastCallGas().gasTotalUsed);

        // Through the relay, a one-cent first fill after a warming Cross by the same path.
        uint256 relayWarm = _verifiedGame();
        uint256 relayFirst = _verifiedGame();
        for (uint256 i; i < 2; ++i) {
            uint256 g = i == 0 ? relayWarm : relayFirst;
            taking = _take(T, g, Side.B, 200, 10_000);
            bytes memory call = abi.encodeCall(OspexMatching.cross, (taking, _list(_rest(M, g, Side.A, 200, 10_000))));
            vm.prank(relayKey, crossOrigin);
            (bool ok,) = address(relay).call(call);
            assertTrue(ok, "the relayed Cross");
        }
        emit log_named_uint(
            "one cent, one leg, a market's first fill, through the relay", vm.lastCallGas().gasTotalUsed
        );
    }
}
