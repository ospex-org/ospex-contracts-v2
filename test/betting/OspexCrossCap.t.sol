// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {Side} from "../../src/betting/OspexBettingTypes.sol";
import {TrickCoin} from "../games/CoinFixtures.sol";
import {CrossBase} from "./CrossBase.sol";
import {CallbackAccount} from "./CrossFixtures.sol";

/// @notice The cap on a taking order's signed stake, one cent until the switch, and the switch itself: the
///         Polygon timelock's one call, once, never back. Every set in this file is deployed with the cap in
///         force, which the test base lifts for every other test; the tests that lift say so, and lift the way it
///         is lifted live, through the stock timelock the games base deploys, or by the timelock's own address
///         where the delay is not the subject. Amounts are literals: 10,000 units is one cent of a six-decimal
///         coin, 100 lots.
contract OspexCrossCapTest is CrossBase {
    uint256 internal constant CAP = 10_000;
    /// @dev The event's first topic, the hub tag and the hub event's first topic, each written out.
    bytes32 internal constant CAP_LIFTED_TOPIC = keccak256("TakingStakeCapLifted()");
    bytes32 internal constant CAP_LIFTED_TAG = keccak256("TAKING_STAKE_CAP_LIFTED");
    bytes32 internal constant CORE_EVENT_TOPIC = keccak256("CoreEventEmitted(bytes32,address,bytes)");

    Signer internal m1;
    Signer internal m2;
    Signer internal tk;

    function setUp() public override {
        liftAtDeploy = false;
        super.setUp();
        m1 = _account("resting one");
        m2 = _account("resting two");
        tk = _account("taking account");
        _register(m1.a, sender);
        _register(m2.a, sender);
        _register(tk.a, sender);
    }

    // ──────────────────────────── Helpers ────────────────────

    /// @dev The lift's calldata.
    function _lift() internal pure returns (bytes memory) {
        return abi.encodeCall(OspexMatching.liftTakingStakeCap, ());
    }

    /// @dev Everything a refused Cross must leave alone, hashed: the market count, the positions module's coin,
    ///      the coin of the taking account and of each resting account and their positions on every market drawn,
    ///      both sides, and each order's filled amount.
    function _state(OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
        internal
        view
        returns (bytes32)
    {
        address[] memory who = new address[](resting.length + 1);
        bytes32[] memory orders = new bytes32[](resting.length + 1);
        who[0] = taking.order.account;
        orders[0] = _hash(taking);
        for (uint256 i; i < resting.length; ++i) {
            who[i + 1] = resting[i].order.account;
            orders[i + 1] = _hash(resting[i]);
        }
        return _fingerprint(who, orders);
    }

    /// @dev A Cross that the cap alone refuses. `from` sends it with `origin` as the transaction's origin: it is
    ///      refused by the cap's name, the 36 bytes compared whole, and nothing moves; then, in a state thrown
    ///      away afterwards, the cap is lifted and the same Cross fills, so the refusal was the cap's and not
    ///      another check's.
    function _refusedByTheCapAlone(
        address from,
        address origin,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        string memory what
    ) internal {
        _refusedByTheCap(from, origin, taking, resting, what);
        _fillsOnceLifted(from, origin, taking, resting, what);
    }

    /// @dev The refusal alone: by the cap's name, with nothing moved.
    function _refusedByTheCap(
        address from,
        address origin,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        string memory what
    ) internal {
        bytes32 before = _state(taking, resting);
        (bool ok, bytes memory err) = _tryCrossAs(from, origin, taking, resting);
        assertFalse(ok, string.concat("filled: ", what));
        assertEq(err, _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, taking), what);
        assertEq(_state(taking, resting), before, string.concat(what, ": the refused Cross moved something"));
    }

    /// @dev In a state thrown away afterwards: the timelock's address lifts the cap, and the same Cross fills.
    function _fillsOnceLifted(
        address from,
        address origin,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting,
        string memory what
    ) internal {
        uint256 lifted = vm.snapshotState();
        uint256 filled = _filled(taking);
        vm.prank(address(timelock), address(timelock));
        matching.liftTakingStakeCap();
        (bool ok, bytes memory err) = _tryCrossAs(from, origin, taking, resting);
        assertTrue(ok, string.concat(what, ": once lifted, the same Cross was refused: ", vm.toString(err)));
        assertGt(_filled(taking), filled, string.concat(what, ": once lifted, the taking order did not fill"));
        vm.revertToState(lifted);
    }

    /// @dev A taking order of `stake` at 2.00, listed with two resting orders that would fill, is refused by the
    ///      cap alone.
    function _refusedAboveCap(uint256 game, Side takingSide, uint256 stake) internal {
        Side restingSide = _other(takingSide);
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, stake);
        OspexMatching.SignedOrder memory r1 = _rest(m1, game, restingSide, 200, 10_000);
        OspexMatching.SignedOrder memory r2 = _rest(m2, game, restingSide, 200, 10_000);
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            taking,
            _list(r1, r2),
            string.concat("a taking stake of ", vm.toString(stake), " before the switch")
        );
    }

    /// @dev A taking order of `stake` at 2.00 fills in full against a resting order of the same stake.
    function _fillsAboveCap(uint256 game, Side takingSide, uint256 stake) internal {
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, stake);
        OspexMatching.SignedOrder memory resting = _rest(m1, game, _other(takingSide), 200, stake);
        _cross(sender, taking, _list(resting));
        assertEq(_filled(taking), stake, "the taking order, after the switch");
        assertEq(_filled(resting), stake, "the resting order, after the switch");
    }

    /// @dev The timelock's execute of the lift under `s`, by a stranger, refused with `want`.
    function _executeRefused(bytes32 s, bytes memory want, string memory what) internal {
        vm.prank(stranger);
        (bool ok, bytes memory err) = address(timelock)
            .call(abi.encodeCall(TimelockController.execute, (address(matching), 0, _lift(), bytes32(0), s)));
        assertFalse(ok, string.concat(what, ": the lift ran"));
        assertEq(err, want, what);
    }

    /// @dev K schedules the lift under a fresh salt, at the delay; the operation's id and its salt.
    function _schedule() internal returns (bytes32 id, bytes32 s) {
        s = bytes32(++salt);
        vm.prank(timelockKey);
        timelock.schedule(address(matching), 0, _lift(), bytes32(0), s, DELAY);
        id = timelock.hashOperation(address(matching), 0, _lift(), bytes32(0), s);
    }

    // ──────────────────────────── 17 ────────────────────

    /// Breaks: in OspexMatching._checkTaking, delete the cap's check; `>` to `>=`; compare the remainder,
    /// `t.riskAmount - s_filledRisk[orderHash]`, instead of the signed stake; compare the lot count,
    /// `t.riskAmount / LOT`; TAKING_STAKE_CAP 10_000 to 100_000; to 1_000; `bytes32(0)` in the refusal; the cap's
    /// check moved ahead of _checkSigned; the cap waived at the shortest price, `&& t.oddsTick > 101`; waived on a
    /// positive line, `&& t.lineTicks <= 0`.
    function test_neverLine_noTakingStakeAboveOneCentFillsBeforeTheSwitch() public {
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at deploy");
        _capCases(Side.B);
        _capCases(Side.A);
    }

    function _capCases(Side takingSide) internal {
        Side restingSide = _other(takingSide);
        uint256 snap = vm.snapshotState();
        uint256 game = _verifiedGame();

        // One cent fills: 100 lots at 2.00, 10,000 against 10,000.
        OspexMatching.SignedOrder memory taking = _take(tk, game, takingSide, 200, CAP);
        OspexMatching.SignedOrder memory resting = _rest(m1, game, restingSide, 200, 10_000);
        _cross(sender, taking, _list(resting));
        assertEq(_filled(taking), 10_000, "one cent at 2.00, the taking order");
        assertEq(_filled(resting), 10_000, "one cent at 2.00, the resting order");
        // And one lot at the longest price: a resting 100 at 101.00 against one cent at 1.01.
        taking = _take(tk, game, takingSide, 101, CAP);
        resting = _rest(m2, game, restingSide, 10_100, 100);
        _cross(sender, taking, _list(resting));
        assertEq(_filled(taking), 10_000, "one cent at 101.00, the taking order");
        assertEq(_filled(resting), 100, "one cent at 101.00, the resting order");
        vm.revertToState(snap);

        // Above a cent: refused by name, listed with resting orders that would fill, and nothing moves.
        game = _verifiedGame();
        _refusedAboveCap(game, takingSide, 10_100);
        _refusedAboveCap(game, takingSide, 1_000_000);

        // The signed stake decides, not the remainder: an order signed for 20,000 that rested and filled 10,000
        // is refused as the taking order, and its filled amount stands.
        OspexMatching.SignedOrder memory big = _take(tk, game, takingSide, 200, 20_000);
        _cross(sender, _take(m1, game, restingSide, 200, 10_000), _list(big));
        assertEq(_filled(big), 10_000, "the order filled 10,000 while resting");
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            big,
            _list(_rest(m2, game, restingSide, 200, 10_000)),
            "an order signed for 20,000, half filled while resting, as the taking order"
        );
        assertEq(_filled(big), 10_000, "the refusal moved the filled amount");

        // The check's place: after the signature, the price and the lot, each of which is refused by its own
        // name on a stake the cap would refuse too.
        OspexMatching.SignedOrder memory oddLots = _take(tk, game, takingSide, 200, 10_050);
        _refused(
            sender,
            oddLots,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            _refusal(OspexMatching.OspexMatching__StakeNotInLots.selector, oddLots),
            "10,050: not in lots, tested before the cap"
        );
        OspexMatching.SignedOrder memory badSignature = _take(tk, game, takingSide, 200, 10_100);
        badSignature.signature = _signature(m1.key, _digest(badSignature.order));
        _refused(
            sender,
            badSignature,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            _refusal(OspexMatching.OspexMatching__BadSignature.selector, badSignature),
            "another key's signature at 10,100, tested before the cap"
        );
        OspexMatching.SignedOrder memory badPrice = _take(tk, game, takingSide, 100, 20_000);
        _refused(
            sender,
            badPrice,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            _refusal(OspexMatching.OspexMatching__PriceOutOfRange.selector, badPrice),
            "a price of 1.00 at 20,000, tested before the cap"
        );
        vm.revertToState(snap);

        // The shapes an independent pass and an attack on the built cap found the cases above holding constant,
        // each refused by the cap alone: by its name, with nothing moved, and filling once the cap is lifted.
        game = _verifiedGame();
        // 10,100 against one resting 10,000: a check made after the walk on what filled would let it fill.
        OspexMatching.SignedOrder memory one = _take(tk, game, takingSide, 200, 10_100);
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            one,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            "10,100 against one resting 10,000"
        );
        // A one-cent order that filled 5,000 while resting takes for the rest: the signed stake, not the sum.
        OspexMatching.SignedOrder memory cent = _take(tk, game, takingSide, 200, CAP);
        _cross(sender, _take(m1, game, restingSide, 200, 5_000), _list(cent));
        assertEq(_filled(cent), 5_000, "the cent filled 5,000 while resting");
        _cross(sender, cent, _list(_rest(m2, game, restingSide, 200, 10_000)));
        assertEq(_filled(cent), 10_000, "the cent, taken for its rest");
        // An order signed for 20,000 that filled 10,100 while resting is still refused as the taking order.
        OspexMatching.SignedOrder memory past = _take(tk, game, takingSide, 200, 20_000);
        _cross(sender, _take(m1, game, restingSide, 200, 10_000), _list(past));
        _cross(sender, _take(m1, game, restingSide, 200, 100), _list(past));
        assertEq(_filled(past), 10_100, "the order filled 10,100 while resting");
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            past,
            _list(_rest(m2, game, restingSide, 200, 10_000)),
            "an order signed for 20,000, filled 10,100 while resting, as the taking order"
        );
        // Magnitudes: past a 16-bit lot count, past 32 bits, past a dollar and past a hundred dollars.
        _refusedAboveCap(game, takingSide, 6_553_700);
        _refusedAboveCap(game, takingSide, 4_294_967_300);
        _refusedAboveCap(game, takingSide, 100_000_100);
        _refusedAboveCap(game, takingSide, 1_000_000_000_000);
        // Another market, a positive line, two other prices, the taking account as its own sender, as the origin,
        // and with code.
        OspexMatching.SignedOrder memory onSpread = _takeOn(tk, game, address(spread), -35, takingSide, 200, 10_100);
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            onSpread,
            _list(_restOn(m1, game, address(spread), -35, restingSide, 200, 10_000)),
            "10,100 on the spread"
        );
        OspexMatching.SignedOrder memory onTotal = _takeOn(tk, game, address(total), 455, takingSide, 200, 10_100);
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            onTotal,
            _list(_restOn(m1, game, address(total), 455, restingSide, 200, 10_000)),
            "10,100 on the total at 45.5"
        );
        OspexMatching.SignedOrder memory shorter = _take(tk, game, takingSide, 190, 10_100);
        _refusedByTheCapAlone(
            sender, crossOrigin, shorter, _list(_rest(m1, game, restingSide, 210, 10_000)), "10,100 at 1.90"
        );
        // The shortest price, where a taking stake buys the fewest lots: 10,100 at 1.01 against one resting lot at
        // 101.00, which is one leg of one lot but for the cap.
        OspexMatching.SignedOrder memory shortest = _take(tk, game, takingSide, 101, 10_100);
        _refusedByTheCapAlone(
            sender, crossOrigin, shortest, _list(_rest(m1, game, restingSide, 10_100, 100)), "10,100 at 1.01"
        );
        // The taking account sends its own Cross: it has registered itself, and so has the resting account, so the
        // leg would fill but for the cap.
        _register(tk.a, tk.a);
        _register(m1.a, tk.a);
        OspexMatching.SignedOrder memory own = _take(tk, game, takingSide, 200, 10_100);
        _refusedByTheCapAlone(
            tk.a, crossOrigin, own, _list(_rest(m1, game, restingSide, 200, 10_000)), "10,100 sent by its own account"
        );
        OspexMatching.SignedOrder memory asOrigin = _take(tk, game, takingSide, 200, 10_100);
        _refusedByTheCapAlone(
            sender,
            tk.a,
            asOrigin,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            "10,100 with its account as the origin"
        );
        Signer memory coded = _account("taking account with code");
        vm.etch(coded.a, address(new CallbackAccount()).code);
        _register(coded.a, sender);
        OspexMatching.SignedOrder memory byCode = _take(coded, game, takingSide, 200, 10_100);
        _refusedByTheCapAlone(
            sender,
            crossOrigin,
            byCode,
            _list(_rest(m1, game, restingSide, 200, 10_000)),
            "10,100 from an account with code"
        );
        // And the cap does not expire by the clock: a decade on, on a game created and started then, so that its
        // window is open and the leg would fill but for the cap.
        vm.warp(2_100_000_000);
        uint256 late = _createAt(uint64(vm.getBlockTimestamp()));
        _startBy(first, late, uint64(vm.getBlockTimestamp()));
        _refusedAboveCap(late, takingSide, 10_100);
        vm.revertToState(snap);
    }

    /// A refused taking stake never reaches the coin: from here to the end of the test the coin must not be asked
    /// to move anything, whatever a check made after the pulls would undo. The refusals are taken without the
    /// lifted control, which fills: these shapes are shown to fill once lifted in 17.
    /// Break: in OspexMatching, move the cap's check to after the walk, on the taking order's filled amount.
    function test_neverLine_aRefusedTakingStakeNeverReachesTheCoin() public {
        uint256 game = _verifiedGame();
        vm.expectCall(address(_coin()), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        _refusedByTheCap(
            sender,
            crossOrigin,
            _take(tk, game, Side.B, 200, 10_100),
            _list(_rest(m1, game, Side.A, 200, 10_000), _rest(m2, game, Side.A, 200, 10_000)),
            "10,100 against two resting 10,000s, side B"
        );
        _refusedByTheCap(
            sender,
            crossOrigin,
            _take(tk, game, Side.A, 200, 10_100),
            _list(_rest(m1, game, Side.B, 200, 10_000), _rest(m2, game, Side.B, 200, 10_000)),
            "10,100 against two resting 10,000s, side A"
        );
        _refusedByTheCap(
            sender,
            crossOrigin,
            _take(tk, game, Side.B, 200, 10_100),
            _list(_rest(m1, game, Side.A, 200, 10_000)),
            "10,100 against one resting 10,000"
        );
    }

    // ──────────────────────────── 18 ────────────────────

    /// Breaks: in OspexMatching._checkResting, refuse a resting order whose signed stake is above
    /// TAKING_STAKE_CAP; in OspexMatching._leg, refuse a leg whose resting stake is above TAKING_STAKE_CAP.
    function test_neverLine_theOtherSideIsNotCapped() public {
        _otherSideCases(Side.B);
        _otherSideCases(Side.A);
    }

    function _otherSideCases(Side takingSide) internal {
        Side restingSide = _other(takingSide);
        uint256 dollar = _verifiedGame();
        uint256 fifty = _verifiedGame();

        // A dollar against a cent at the shortest price: 1,000,000 at 1.01 against 10,000 at 101.00.
        OspexMatching.SignedOrder memory resting = _rest(m1, dollar, restingSide, 101, 1_000_000);
        OspexMatching.SignedOrder memory taking = _take(tk, dollar, takingSide, 10_100, CAP);
        _cross(sender, taking, _list(resting));
        uint256 dollarMarket = markets.getMarketId(dollar, address(moneyline), 0);
        assertEq(_filled(resting), 1_000_000, "the dollar, filled");
        assertEq(_filled(taking), 10_000, "the cent against the dollar, filled");
        _assertPosition(dollarMarket, m1.a, restingSide, 1_000_000, 10_000, "the dollar's position");
        _assertPosition(dollarMarket, tk.a, takingSide, 10_000, 1_000_000, "the cent's position against the dollar");

        // Fifty dollars at 2.10 against a cent at 1.90: 90 lots, 9,000 against 9,900, 100 units of the cent left.
        resting = _rest(m2, fifty, restingSide, 210, 50_000_000);
        taking = _take(tk, fifty, takingSide, 190, CAP);
        _cross(sender, taking, _list(resting));
        uint256 fiftyMarket = markets.getMarketId(fifty, address(moneyline), 0);
        assertEq(_filled(resting), 9_000, "the fifty dollars, filled");
        assertEq(_filled(taking), 9_900, "the cent against the fifty dollars, filled");
        _assertPosition(fiftyMarket, m2.a, restingSide, 9_000, 9_900, "the fifty dollars' position");
        _assertPosition(fiftyMarket, tk.a, takingSide, 9_900, 9_000, "the cent's position against the fifty dollars");

        // Both games scored home: side A, whichever account holds it, is paid both stakes of its leg.
        _score(dollar, HOME, AWAY);
        _score(fifty, HOME, AWAY);
        _settle(dollarMarket);
        _settle(fiftyMarket);
        (address winsDollar, address losesDollar) = restingSide == Side.A ? (m1.a, tk.a) : (tk.a, m1.a);
        (address winsFifty, address losesFifty) = restingSide == Side.A ? (m2.a, tk.a) : (tk.a, m2.a);
        assertEq(_claim(winsDollar, dollarMarket, Side.A), 1_010_000, "the dollar and the cent, to side A");
        assertEq(_claim(winsFifty, fiftyMarket, Side.A), 18_900, "9,000 and 9,900, to side A");
        (bool ok,) = _tryClaim(losesDollar, dollarMarket, Side.B);
        assertFalse(ok, "side B was paid on the dollar's market");
        (ok,) = _tryClaim(losesFifty, fiftyMarket, Side.B);
        assertFalse(ok, "side B was paid on the fifty dollars' market");
        assertEq(_coin().balanceOf(address(positions)), 0, "the positions module holds coin after the claims");

        // A resting order signed past fifty dollars fills the same leg, settles and pays the same, and none of it
        // moved the flag.
        uint256 more = _verifiedGame();
        resting = _rest(m2, more, restingSide, 210, 50_000_100);
        taking = _take(tk, more, takingSide, 190, CAP);
        _cross(sender, taking, _list(resting));
        uint256 moreMarket = markets.getMarketId(more, address(moneyline), 0);
        assertEq(_filled(resting), 9_000, "fifty dollars and a lot, filled");
        _score(more, HOME, AWAY);
        _settle(moreMarket);
        (address winsMore, address losesMore) = restingSide == Side.A ? (m2.a, tk.a) : (tk.a, m2.a);
        assertEq(_claim(winsMore, moreMarket, Side.A), 18_900, "9,000 and 9,900, to side A, past fifty dollars");
        (ok,) = _tryClaim(losesMore, moreMarket, Side.B);
        assertFalse(ok, "side B was paid past fifty dollars");
        assertEq(_coin().balanceOf(address(positions)), 0, "the positions module holds coin at the end");
        assertFalse(matching.s_takingStakeCapLifted(), "a resting fill moved the flag");
    }

    // ──────────────────────────── 19 ────────────────────

    /// Breaks: in OspexMatching.liftTakingStakeCap, delete the caller's check; accept the timelock's key too,
    /// `msg.sender != i_timelock && msg.sender != ...`; read tx.origin in place of msg.sender; delete the once
    /// check; write nothing; delete the local event; delete the hub copy; `returns (bool)` with `return true`;
    /// in the constructor, `s_takingStakeCapLifted = true`.
    function test_neverLine_theSwitchActsOnceByTheTimelockAloneAndNeverBack() public {
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at deploy");
        assertEq(matching.i_timelock(), address(timelock), "the timelock the matching module read at its deploy");
        uint256 game = _verifiedGame();
        _refusedAboveCap(game, Side.B, 10_100);

        // Anyone but the timelock: refused by name, the flag unmoved, and 10,100 still refused. Among them the
        // contracts of the set, the games set, the coin, and a second stock timelock with the same code.
        TimelockController twin = new TimelockController(DELAY, _one(timelockKey), _one(address(0)), address(0));
        address[13] memory callers = [
            deployer,
            address(core),
            timelockKey,
            sender,
            m1.a,
            tk.a,
            stranger,
            address(games),
            address(positions),
            address(markets),
            address(matching),
            address(_coin()),
            address(twin)
        ];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i], callers[i]);
            (bool taken, bytes memory refusal) = address(matching).call(_lift());
            assertFalse(taken, string.concat("the lift was taken from ", vm.toString(callers[i])));
            assertEq(
                refusal,
                abi.encodeWithSelector(OspexMatching.OspexMatching__NotTheTimelock.selector, callers[i]),
                "the refusal of a caller that is not the timelock"
            );
        }
        // The transaction's origin being the timelock is not the timelock calling.
        vm.prank(stranger, address(timelock));
        (bool okOrigin, bytes memory errOrigin) = address(matching).call(_lift());
        assertFalse(okOrigin, "the lift was taken with the timelock as the origin");
        assertEq(
            errOrigin,
            abi.encodeWithSelector(OspexMatching.OspexMatching__NotTheTimelock.selector, stranger),
            "the refusal with the timelock as the origin"
        );
        assertFalse(matching.s_takingStakeCapLifted(), "the flag moved under a refused lift");
        _refusedAboveCap(game, Side.A, 10_100);
        // The caller's check does not expire by the clock.
        uint256 later = vm.snapshotState();
        vm.warp(2_100_000_000);
        vm.prank(stranger, stranger);
        (bool okLater, bytes memory errLater) = address(matching).call(_lift());
        assertFalse(okLater, "a stranger lifted the cap years later");
        assertEq(
            errLater,
            abi.encodeWithSelector(OspexMatching.OspexMatching__NotTheTimelock.selector, stranger),
            "a stranger's lift, years later"
        );
        vm.revertToState(later);

        // The timelock's address lifts it: zero bytes back, the two logs as literals, the flag true.
        vm.recordLogs();
        vm.prank(address(timelock), address(timelock));
        (bool ok, bytes memory returned) = address(matching).call(_lift());
        assertTrue(ok, "the timelock's lift was refused");
        assertEq(returned.length, 0, "the lift returned a value");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the lift's logs");
        assertEq(logs[0].emitter, address(matching), "the first log's emitter");
        assertEq(logs[0].topics.length, 1, "the first log's topics");
        assertEq(logs[0].topics[0], CAP_LIFTED_TOPIC, "the first log's topic");
        assertEq(logs[0].data.length, 0, "the first log's data");
        assertEq(logs[1].emitter, address(core), "the hub copy's emitter");
        assertEq(logs[1].topics.length, 3, "the hub copy's topics");
        assertEq(logs[1].topics[0], CORE_EVENT_TOPIC, "the hub copy's first topic");
        assertEq(logs[1].topics[1], CAP_LIFTED_TAG, "the hub copy's tag");
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(address(matching)))), "the hub copy's emitter field");
        assertEq(logs[1].data, abi.encode(bytes("")), "the hub copy's payload");
        assertTrue(matching.s_takingStakeCapLifted(), "the flag after the lift");

        // In the same transaction 10,100 fills, so the lift left the in-progress mark clean; and a dollar fills.
        _fillsAboveCap(game, Side.B, 10_100);
        _fillsAboveCap(game, Side.A, 10_100);
        _fillsAboveCap(game, Side.B, 1_000_000);
        _fillsAboveCap(game, Side.A, 1_000_000);
        // Past a hundred dollars too: after the lift only the signed stake bounds a fill.
        _fillsAboveCap(game, Side.B, 100_000_100);

        // Twice: refused by name, and the flag stays.
        vm.prank(address(timelock), address(timelock));
        (bool okAgain, bytes memory errAgain) = address(matching).call(_lift());
        assertFalse(okAgain, "a second lift was taken");
        assertEq(
            errAgain, abi.encodeWithSelector(OspexMatching.OspexMatching__CapAlreadyLifted.selector), "a second lift"
        );
        assertTrue(matching.s_takingStakeCapLifted(), "the flag after a refused second lift");
    }

    /// The source has one write of s_takingStakeCapLifted, in liftTakingStakeCap. Here every other state-changing
    /// function runs on its success path with the cap in force and leaves the flag false; then the lift, through
    /// the stock timelock; then each runs again and leaves it true.
    /// Break: in OspexMatching.registerCourier, add `s_takingStakeCapLifted = true;`.
    function test_neverLine_theLiftIsTheOnlyWriteOfTheFlag() public {
        uint256 game = _verifiedGame();
        // Every other state-changing function, on its success path and on its other branches, with the storage
        // writes of the matching module recorded.
        vm.record();
        _eachOtherFunctionLeavesTheFlag(game, false);
        (, bytes32[] memory writesBefore) = vm.accesses(address(matching));
        // The lift: one storage slot of the matching module written, the flag's.
        vm.record();
        _liftTheCap();
        (, bytes32[] memory liftWrites) = vm.accesses(address(matching));
        assertEq(liftWrites.length, 1, "the lift writes one slot");
        bytes32 flagSlot = liftWrites[0];
        vm.record();
        _eachOtherFunctionLeavesTheFlag(game, true);
        (, bytes32[] memory writesAfter) = vm.accesses(address(matching));
        // Nothing but the lift wrote that slot, before or after.
        for (uint256 i; i < writesBefore.length; ++i) {
            assertTrue(writesBefore[i] != flagSlot, "the flag's slot was written before the lift by another call");
        }
        for (uint256 i; i < writesAfter.length; ++i) {
            assertTrue(writesAfter[i] != flagSlot, "the flag's slot was written after the lift by another call");
        }
    }

    function _eachOtherFunctionLeavesTheFlag(uint256 game, bool expected) internal {
        address other = makeAddr("another courier");
        OspexMatching.OspexOrder memory toCancel = _rest(m1, game, Side.A, 200, 10_000).order;
        uint96 floor = matching.getFloor(m1.a, game, address(spread), -35) + 1;
        vm.startPrank(m1.a, m1.a);
        matching.registerCourier(other);
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a registration");
        matching.registerCourier(other);
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a repeated registration");
        matching.unregisterCourier(other);
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a drop");
        matching.cancelOrder(toCancel);
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a cancel");
        matching.raiseFloor(m1.a, game, address(spread), -35, floor);
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a raised floor");
        vm.stopPrank();
        // A Cross that fills one leg.
        _cross(sender, _take(tk, game, Side.B, 200, CAP), _list(_rest(m1, game, Side.A, 200, 10_000)));
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a Cross");
        // A Cross that skips a leg for no courier, then fills: the skip record's branch.
        Signer memory unregistered = _account(expected ? "unregistered, after" : "unregistered, before");
        OspexMatching.SignedOrder memory skipped = _rest(unregistered, game, Side.A, 200, 10_000);
        OspexMatching.SignedOrder memory filled = _rest(m1, game, Side.A, 200, 10_000);
        _cross(sender, _take(tk, game, Side.B, 200, CAP), _list(skipped, filled));
        assertEq(_filled(skipped), 0, "the unregistered account's order was not skipped");
        assertEq(_filled(filled), 10_000, "the leg after the skip did not fill");
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a Cross with a skipped leg");
        // A Cross whose first leg's pull is refused, then fills: the put-back branch. The coin is read before the
        // prank, so the prank reaches the approval.
        Signer memory broke = _account(expected ? "cannot pay, after" : "cannot pay, before");
        _register(broke.a, sender);
        IERC20 coin = _coin();
        vm.prank(broke.a);
        coin.approve(address(positions), 0);
        assertEq(coin.allowance(broke.a, address(positions)), 0, "the account still has an allowance");
        OspexMatching.SignedOrder memory refused = _rest(broke, game, Side.A, 200, 10_000);
        filled = _rest(m1, game, Side.A, 200, 10_000);
        _cross(sender, _take(tk, game, Side.B, 200, CAP), _list(refused, filled));
        assertEq(_filled(refused), 0, "the order whose pull was refused filled");
        assertEq(_filled(filled), 10_000, "the leg after the refused pull did not fill");
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a Cross with a refused pull");
        // A leg whose resting order is signed for far more than the cap.
        _cross(sender, _take(tk, game, Side.B, 200, CAP), _list(_rest(m1, game, Side.A, 200, 200_000)));
        assertEq(matching.s_takingStakeCapLifted(), expected, "after a leg against a large resting order");
    }

    /// The lift is a timelock operation anyone may run once it is ready, so an account whose code the coin calls
    /// during a pull can try to run it from inside a leg. It is refused by the exclusion's name, the outer Cross
    /// fills, the flag and the operation are as they were, and the same operation runs outside a Cross.
    /// Breaks: in OspexMatching.liftTakingStakeCap, delete the in-progress check; add
    /// `CROSS_IN_PROGRESS_SLOT.asBoolean().tstore(false);` before the in-progress check.
    function test_neverLine_aLiftFromInsideAPullIsRefused() public {
        // A set on a coin that calls the debited account back during a pull, with the cap in force.
        TrickCoin trick = new TrickCoin();
        _deploySetOn(address(trick));
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at deploy");
        Signer memory y = _account("resting account with code");
        Signer memory t = _account("taking account on the trick coin");
        vm.etch(y.a, address(new CallbackAccount()).code);
        _register(y.a, sender);
        _register(t.a, sender);
        uint256 game = _verifiedGame();

        // The lift, scheduled by K and ready, so that anyone may run it.
        (bytes32 id, bytes32 s) = _schedule();
        vm.warp(vm.getBlockTimestamp() + DELAY);
        assertTrue(timelock.isOperationReady(id), "the operation is not ready");

        // From inside the pull of its first leg, the resting account runs the ready operation.
        trick.setHooked(y.a, true);
        CallbackAccount(y.a)
            .arm(
                address(timelock),
                abi.encodeCall(TimelockController.execute, (address(matching), 0, _lift(), bytes32(0), s))
            );
        OspexMatching.SignedOrder memory taking = _take(t, game, Side.B, 200, CAP);
        OspexMatching.SignedOrder memory first = _rest(y, game, Side.A, 200, 5_000);
        OspexMatching.SignedOrder memory second = _rest(y, game, Side.A, 200, 5_000);
        _cross(sender, taking, _list(first, second));
        (bool[] memory oks, bytes[] memory answers) = CallbackAccount(y.a).results();
        assertEq(oks.length, 1, "the call-back made one call");
        assertFalse(oks[0], "the lift from inside a pull was taken");
        assertEq(
            answers[0],
            abi.encodeWithSelector(OspexMatching.OspexMatching__CrossInProgress.selector),
            "refused, but not by the exclusion"
        );
        assertEq(_filled(taking), 10_000, "the outer Cross's taking order");
        assertEq(_filled(first), 5_000, "the outer Cross's first leg");
        assertEq(_filled(second), 5_000, "the outer Cross's second leg");
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted from inside a pull");
        assertTrue(timelock.isOperationReady(id), "the operation is no longer ready");

        // Outside a Cross the same operation runs.
        vm.prank(stranger);
        timelock.execute(address(matching), 0, _lift(), bytes32(0), s);
        assertTrue(matching.s_takingStakeCapLifted(), "the operation did not lift the cap outside a Cross");
    }

    // ──────────────────────────── 20 ────────────────────

    /// On the stock timelock as deployed: K schedules and cancels, the delay passes, anyone runs a ready call, a
    /// done call does not run again, and a second lift fails in the matching module and stays ready. No break of
    /// its own: the timelock is not under test, and 17's and 19's breaks are scored against their own tests.
    function test_neverLine_theLiftWaitsTheDelayAndCanBeCancelled() public {
        uint256 game = _verifiedGame();
        bytes32 ready = bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));

        // K schedules; before the delay the operation is not ready, and the cap stands.
        (bytes32 first, bytes32 s1) = _schedule();
        _executeRefused(
            s1,
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, first, ready),
            "before the delay"
        );
        _refusedAboveCap(game, Side.B, 10_100);

        // K cancels; the delay passes; the cancelled operation does not run, and the cap stands.
        vm.prank(timelockKey);
        timelock.cancel(first);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _executeRefused(
            s1,
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, first, ready),
            "after the cancel"
        );
        _refusedAboveCap(game, Side.A, 10_100);
        assertFalse(matching.s_takingStakeCapLifted(), "the flag after a cancelled lift");

        // Scheduled again under a fresh salt; the delay passes; a stranger runs it.
        (bytes32 second, bytes32 s2) = _schedule();
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        timelock.execute(address(matching), 0, _lift(), bytes32(0), s2);
        assertTrue(matching.s_takingStakeCapLifted(), "the flag after the lift");
        assertTrue(timelock.isOperationDone(second), "the operation is not done");
        _fillsAboveCap(game, Side.B, 10_100);

        // The same operation again: done, so the timelock refuses it.
        _executeRefused(
            s2,
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, second, ready),
            "a second run of the done operation"
        );

        // A second lift, scheduled afresh: ready, refused by the matching module's name, and still ready.
        (bytes32 third, bytes32 s3) = _schedule();
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _executeRefused(
            s3, abi.encodeWithSelector(OspexMatching.OspexMatching__CapAlreadyLifted.selector), "a second lift"
        );
        assertTrue(timelock.isOperationReady(third), "the refused second lift is no longer ready");

        // Only K schedules.
        vm.prank(stranger);
        (bool ok, bytes memory err) = address(timelock)
            .call(
                abi.encodeCall(
                    TimelockController.schedule, (address(matching), 0, _lift(), bytes32(0), bytes32(++salt), DELAY)
                )
            );
        assertFalse(ok, "a stranger scheduled a lift");
        assertEq(
            err,
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, timelock.PROPOSER_ROLE()
            ),
            "a stranger's schedule"
        );
    }

    // ──────────────────────────── End to end ────────────────────

    /// From a user's side, on both sides: a one-cent bet before the switch fills, settles and pays; a bet of
    /// 10,100 is refused by name; the lift, through the stock timelock; a bet of 10,100 fills, settles and pays.
    function test_endToEnd_aOneCentBetBeforeTheSwitchAndALargerOneAfterIt() public {
        uint256[2] memory earlier = [_verifiedGame(), _verifiedGame()];
        uint256[2] memory later = [_verifiedGame(), _verifiedGame()];
        Side[2] memory takingSides = [Side.B, Side.A];
        uint256[2] memory beforeMarkets;
        uint256[2] memory afterMarkets;

        // One cent at 1.90 against the maker's 10,000 at 2.10: 90 lots, 9,000 against 9,900.
        for (uint256 i; i < 2; ++i) {
            OspexMatching.SignedOrder memory resting = _rest(m1, earlier[i], _other(takingSides[i]), 210, 10_000);
            OspexMatching.SignedOrder memory taking = _take(tk, earlier[i], takingSides[i], 190, CAP);
            _cross(sender, taking, _list(resting));
            beforeMarkets[i] = markets.getMarketId(earlier[i], address(moneyline), 0);
            assertEq(_filled(taking), 9_900, "the cent, filled");
            assertEq(_filled(resting), 9_000, "the maker's order, filled");
            _refusedAboveCap(later[i], takingSides[i], 10_100);
        }
        // Scored 121 to 99, home: side A is paid 18,900 on each, side B is refused.
        for (uint256 i; i < 2; ++i) {
            _score(earlier[i], 121, 99);
            _settle(beforeMarkets[i]);
            (address winner, address loser) = takingSides[i] == Side.A ? (tk.a, m1.a) : (m1.a, tk.a);
            assertEq(_claim(winner, beforeMarkets[i], Side.A), 18_900, "side A's claim before the switch");
            (bool ok, bytes memory err) = _tryClaim(loser, beforeMarkets[i], Side.B);
            assertFalse(ok, "side B was paid");
            assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector), "side B's refusal");
        }
        assertEq(_coin().balanceOf(address(positions)), 0, "the positions module, after the claims");

        // The lift, the way it is lifted live.
        _liftTheCap();

        // A bet of 10,100 at 2.00 against the maker's 10,100 fills in full, settles and pays 20,200 to side A.
        for (uint256 i; i < 2; ++i) {
            OspexMatching.SignedOrder memory resting = _rest(m1, later[i], _other(takingSides[i]), 200, 10_100);
            OspexMatching.SignedOrder memory taking = _take(tk, later[i], takingSides[i], 200, 10_100);
            _cross(sender, taking, _list(resting));
            afterMarkets[i] = markets.getMarketId(later[i], address(moneyline), 0);
            assertEq(_filled(taking), 10_100, "10,100, filled after the switch");
            assertEq(_filled(resting), 10_100, "the maker's order, filled after the switch");
        }
        for (uint256 i; i < 2; ++i) {
            _score(later[i], 121, 99);
            _settle(afterMarkets[i]);
            (address winner, address loser) = takingSides[i] == Side.A ? (tk.a, m1.a) : (m1.a, tk.a);
            assertEq(_claim(winner, afterMarkets[i], Side.A), 20_200, "side A's claim after the switch");
            (bool ok,) = _tryClaim(loser, afterMarkets[i], Side.B);
            assertFalse(ok, "side B was paid after the switch");
        }
        assertEq(_coin().balanceOf(address(positions)), 0, "the positions module, at the end");
    }

    /// Before the lift only a stake at or under the cap fills; after it, only the signed stake bounds a fill.
    function testFuzz_onlyAStakeAtOrUnderTheCapFillsBeforeTheLift(uint256 lots) public {
        // Up to half the purse: past a 16-bit lot count and a 32-bit unit count.
        lots = bound(lots, 1, 5_000_000_000);
        uint256 stake = lots * 100;
        uint256 game = _verifiedGame();
        OspexMatching.SignedOrder memory taking = _take(tk, game, Side.B, 200, stake);
        OspexMatching.SignedOrder memory resting = _rest(m1, game, Side.A, 200, stake);
        if (stake > CAP) {
            _refused(
                sender,
                taking,
                _list(resting),
                _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, taking),
                "above the cap, before the lift"
            );
            assertEq(_filled(taking), 0, "a refused taking order filled");
        } else {
            _cross(sender, taking, _list(resting));
            assertEq(_filled(taking), stake, "at or under the cap, before the lift");
        }
        _liftTheCap();
        taking = _take(tk, game, Side.B, 200, stake);
        _cross(sender, taking, _list(_rest(m2, game, Side.A, 200, stake)));
        assertEq(_filled(taking), stake, "after the lift only the signed stake bounds a fill");
    }

    // ──────────────────────────── Gas ────────────────────

    /// What a one-cent leg costs, as the gas of the call into the matching module, before and after the lift,
    /// each a market's first fill; and a leg of 10,100 after it, which reads the flag. A first Cross warms the
    /// accounts and the contracts, so the three figures differ in the leg alone. Printed, not pinned.
    function test_gas_aOneCentLegBeforeAndAfterTheLift() public {
        uint256 warm = _verifiedGame();
        uint256 first = _verifiedGame();
        uint256 second = _verifiedGame();
        uint256 third = _verifiedGame();

        OspexMatching.SignedOrder memory taking = _take(tk, warm, Side.B, 200, CAP);
        _cross(sender, taking, _list(_rest(m1, warm, Side.A, 200, 10_000)));
        assertEq(_filled(taking), 10_000);

        taking = _take(tk, first, Side.B, 200, CAP);
        _cross(sender, taking, _list(_rest(m1, first, Side.A, 200, 10_000)));
        emit log_named_uint(
            "one cent, one leg, the market's first fill, before the lift", vm.lastCallGas().gasTotalUsed
        );
        assertEq(_filled(taking), 10_000);

        _liftTheCap();

        taking = _take(tk, second, Side.B, 200, CAP);
        _cross(sender, taking, _list(_rest(m1, second, Side.A, 200, 10_000)));
        emit log_named_uint("one cent, one leg, the market's first fill, after the lift", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 10_000);

        taking = _take(tk, third, Side.B, 200, 10_100);
        _cross(sender, taking, _list(_rest(m1, third, Side.A, 200, 10_100)));
        emit log_named_uint("10,100, one leg, the market's first fill, after the lift", vm.lastCallGas().gasTotalUsed);
        assertEq(_filled(taking), 10_100);
    }
}

/// @dev A core that answers the one read the matching module's constructor makes of it, and takes the hub's call:
///      what a matching module is deployed against in the constructor tests below.
contract AnsweringCore {
    address public i_games;

    constructor(address games) {
        i_games = games;
    }

    function emitCoreEvent(bytes32, bytes calldata) external {}
}

/// @dev A games set whose timelock answer can be changed: what a live read would follow, and a stored one not.
contract AnsweringGames {
    address public i_timelock;

    function set(address timelock) external {
        i_timelock = timelock;
    }
}

/// @notice The matching module's constructor: the timelock read once from the games set the core names and
///         kept, and the games addresses it refuses.
contract OspexCrossCapConstructorTest is CrossBase {
    function setUp() public override {
        liftAtDeploy = false;
        super.setUp();
    }

    /// The timelock is the games set's answer when the matching module is deployed, and nothing the games set
    /// answers later changes it: a lift by the later answer is refused, and a lift by the first succeeds.
    /// Break: in OspexMatching.liftTakingStakeCap, compare the caller with the games set's answer read then,
    /// `IOspexGamesTimelock(address(i_ospexCore.i_games())).i_timelock()`, instead of i_timelock.
    function test_neverLine_theTimelockIsReadOnceAtDeployAndKept() public {
        address first = makeAddr("the timelock at the deploy");
        address later = makeAddr("a timelock answered later");
        AnsweringGames answering = new AnsweringGames();
        answering.set(first);
        OspexMatching m = new OspexMatching(address(new AnsweringCore(address(answering))));
        assertEq(m.i_timelock(), first, "the timelock read at the deploy");

        answering.set(later);
        assertEq(answering.i_timelock(), later, "the games set's later answer");
        assertEq(m.i_timelock(), first, "the matching module followed the games set's later answer");
        vm.prank(later, later);
        (bool ok, bytes memory err) = address(m).call(abi.encodeCall(OspexMatching.liftTakingStakeCap, ()));
        assertFalse(ok, "the later answer lifted the cap");
        assertEq(
            err,
            abi.encodeWithSelector(OspexMatching.OspexMatching__NotTheTimelock.selector, later),
            "the later answer's refusal"
        );
        assertFalse(m.s_takingStakeCapLifted(), "the flag after the later answer's refusal");
        vm.prank(first, first);
        m.liftTakingStakeCap();
        assertTrue(m.s_takingStakeCapLifted(), "the first answer did not lift the cap");
    }

    /// The constructor refuses a games address it cannot read a timelock from: one with no code, one whose code is a
    /// wallet's delegation, and one that answers zero. The delegation is the one the core itself lets through, since
    /// the core checks only that the address has code.
    /// Breaks: in OspexMatching's constructor, drop `games.code.length == 0 ||`; drop `|| _isDelegated(games)`; drop
    /// the zero check.
    function test_neverLine_theConstructorRefusesAGamesAddressItCannotReadATimelockFrom() public {
        address empty = makeAddr("a games address with no code");
        AnsweringCore emptyCore = new AnsweringCore(empty);
        vm.expectRevert(abi.encodeWithSelector(OspexMatching.OspexMatching__GamesNotAContract.selector, empty));
        new OspexMatching(address(emptyCore));

        address delegated = makeAddr("a games address that is a wallet's delegation");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(games)));
        assertEq(delegated.code.length, 23, "the delegation's length");
        // The core takes it: its check is that the address has code.
        OspexBetting coreOnDelegation = new OspexBetting(delegated, address(token));
        assertEq(address(coreOnDelegation.i_games()), delegated, "the core's games address");
        vm.expectRevert(abi.encodeWithSelector(OspexMatching.OspexMatching__GamesNotAContract.selector, delegated));
        new OspexMatching(address(coreOnDelegation));

        AnsweringGames silent = new AnsweringGames();
        AnsweringCore silentCore = new AnsweringCore(address(silent));
        vm.expectRevert(
            abi.encodeWithSelector(OspexMatching.OspexMatching__GamesHasNoTimelock.selector, address(silent))
        );
        new OspexMatching(address(silentCore));
    }

    /// The cap is in force at deploy on every chain: the flag is false under Polygon's chain id as under the test's.
    /// Break: in OspexMatching's constructor, `s_takingStakeCapLifted = block.chainid == 137;`.
    function test_neverLine_theCapIsInForceAtDeployOnEveryChain() public {
        assertFalse(matching.s_takingStakeCapLifted(), "the flag at deploy, on the test's chain");
        uint256 chain = block.chainid;
        vm.chainId(137);
        _deploySetWith(address(games), address(token));
        assertFalse(matching.s_takingStakeCapLifted(), "the flag at deploy, under Polygon's chain id");
        vm.chainId(chain);
    }
}
