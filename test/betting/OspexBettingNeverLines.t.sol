// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {GameStatus} from "../../src/games/IOspexGames.sol";
import {IOspexModuleWiring, OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {IOspexModule} from "../../src/betting/IOspexModule.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {BettingBase} from "./BettingBase.sol";

/// @dev A module of a type the set does not require.
contract ExtraModule is IOspexModule {
    function getModuleType() external pure returns (bytes32) {
        return keccak256("EXTRA_MODULE");
    }
}

/// @dev A contract that registers and drops a courier when it is called: what a contract an account calls
///      could do, if the account whose couriers a call writes were the transaction's origin and not the caller.
contract CourierCaller {
    function register(OspexMatching matching, address courier) external {
        matching.registerCourier(courier);
    }

    function unregister(OspexMatching matching, address courier) external {
        matching.unregisterCourier(courier);
    }
}

/// @notice One test per line that must never happen in the betting set as it stands: a score is never read in
///         v2's order, away then home; a market settles on nothing but its game's own status; a void and a
///         release are voids; the Cross is the one fill path in the betting set; only an account changes its couriers,
///         and no account has one by default; the registry is exactly the required set and the deployer keeps
///         nothing; a module wired wrong is refused at bootstrap, where the core asks a module of its type for
///         its core, its games set or its coin, so finalize locks no set wired wrong; and the zero address is
///         never an approved market contract. Above each test, "Break:" names a change to src/betting, most
///         of one line, that turns it red.
contract OspexBettingNeverLinesTest is BettingBase {
    /// @dev The scored game of the rulings: home 121, away 99. Home wins the moneyline; home -3.5 covers. The
    ///      two scores differ, so a read in the other order gives the other team the win.
    uint32 internal constant HOME_121 = 121;
    uint32 internal constant AWAY_99 = 99;

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // (home, away): the games set returns the home team's score then the away team's; v2's market contracts
    // took away then home. The moneyline and the spread are pinned on 121-99, where a swap moves the win.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexScorer._scores, swap the two: `(awayScore, homeScore) = i_games.getGameScores(gameId);`.
    /// The away team then wins 99-121.
    function test_neverLine_theScoreIsReadHomeThenAway_moneyline() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, HOME_121, AWAY_99);
        (uint32 home, uint32 away) = games.getGameScores(game);
        assertEq(home, HOME_121, "the games set's home score");
        assertEq(away, AWAY_99, "the games set's away score");

        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home), "home wins the moneyline");

        // Side A, the home team, is paid its risk and its profit; side B, the away team, nothing.
        assertEq(_claim(maker, market, Side.A), 2 * STAKE, "side A is paid");
        (bool ok, bytes memory err) = _tryClaim(taker, market, Side.B);
        assertFalse(ok, "side B is paid");
        assertEq(_selector(err), OspexPositions.OspexPositions__NoPayout.selector);
    }

    /// Break: in OspexSpreadScorer._outcome, put the handicap on the away team, v2's orientation:
    /// `int32 home = int32(homeScore) * 10;` and `int32 away = int32(awayScore) * 10 + homeLine;`. Home -22.5
    /// then covers 121-99, and so does home -22. The read swap above turns this red too.
    function test_neverLine_theScoreIsReadHomeThenAway_spread() public {
        uint256 game = _verifiedGame();
        // Home -3.5 covers: 121 - 3.5 > 99.
        uint256 covers = _market(game, address(spread), -35);
        // Home +3.5 covers too: the home team getting points.
        uint256 plus = _market(game, address(spread), 35);
        // Home -22.5 does not: 121 - 22.5 < 99, so the away team covers.
        uint256 awayCovers = _market(game, address(spread), -225);
        // Home -22 is a push: 121 - 22 = 99.
        uint256 push = _market(game, address(spread), -220);
        _score(game, HOME_121, AWAY_99);

        _settle(covers);
        _settle(plus);
        _settle(awayCovers);
        _settle(push);
        assertEq(uint8(_outcome(covers)), uint8(Outcome.Home), "home -3.5 covers");
        assertEq(uint8(_outcome(plus)), uint8(Outcome.Home), "home +3.5 covers");
        assertEq(uint8(_outcome(awayCovers)), uint8(Outcome.Away), "away +22.5 covers");
        assertEq(uint8(_outcome(push)), uint8(Outcome.Push), "home -22 is a push");

        // The money follows: side A on the covers, side B on the away cover, both their stakes on the push.
        assertEq(_claim(maker, covers, Side.A), 2 * STAKE, "side A paid on home -3.5");
        assertEq(_claim(taker, awayCovers, Side.B), 2 * STAKE, "side B paid on home -22.5");
        assertEq(_claim(maker, push, Side.A), STAKE, "side A's stake back on the push");
        assertEq(_claim(taker, push, Side.B), STAKE, "side B's stake back on the push");
        (bool ok, bytes memory err) = _tryClaim(maker, awayCovers, Side.A);
        assertFalse(ok, "side A paid on home -22.5");
        assertEq(_selector(err), OspexPositions.OspexPositions__NoPayout.selector);
    }

    /// The sum of the two scores does not change when they are swapped, so no outcome on 121-99 can show the
    /// total reading them in v2's order. Pinned instead: the total reads the game through the one read the
    /// three market contracts share, which the two tests above pin on an asymmetric score; all three read the
    /// games set the core names; and the declared order of the two scores in each market contract's own read is
    /// the home team's then the away team's, taken from the compiled artifacts, as is the games set's.
    /// Break: in OspexTotalScorer.outcome and _outcome, swap the two parameter names:
    /// `(uint32 awayScore, uint32 homeScore, int32 lineTicks)`.
    function test_neverLine_theTotalsArgumentOrderIsPinned() public {
        uint256 game = _verifiedGame();
        // 220 points: over 219.5, under 220.5, a push at 220.
        uint256 over = _market(game, address(total), 2195);
        uint256 under = _market(game, address(total), 2205);
        uint256 push = _market(game, address(total), 2200);
        _score(game, HOME_121, AWAY_99);
        _settle(over);
        _settle(under);
        _settle(push);
        assertEq(uint8(_outcome(over)), uint8(Outcome.Over), "220 is over 219.5");
        assertEq(uint8(_outcome(under)), uint8(Outcome.Under), "220 is under 220.5");
        assertEq(uint8(_outcome(push)), uint8(Outcome.Push), "220 is a push at 220");
        assertEq(_claim(maker, over, Side.A), 2 * STAKE, "side A, over, paid");
        assertEq(_claim(taker, under, Side.B), 2 * STAKE, "side B, under, paid");

        // The total's read of the game answers as its arithmetic on (121, 99) does, through the shared read.
        assertEq(uint8(total.outcomeOf(game, 2195)), uint8(total.outcome(HOME_121, AWAY_99, 2195)));
        assertEq(address(total.i_games()), address(games), "the total reads the games set");
        assertEq(address(spread.i_games()), address(games), "the spread reads the games set");
        assertEq(address(moneyline.i_games()), address(games), "the moneyline reads the games set");
        assertEq(address(core.i_games()), address(games), "the core names the games set");

        // The declared order, from the artifacts: the home team's score, then the away team's, then the line.
        _assertParams(
            _artifact("OspexTotalScorer"),
            "$.abi[?(@.name == 'outcome')].inputs",
            "homeScore;awayScore;lineTicks",
            "uint32;uint32;int32"
        );
        _assertParams(
            _artifact("OspexMoneylineScorer"),
            "$.abi[?(@.name == 'outcome')].inputs",
            "homeScore;awayScore;lineTicks",
            "uint32;uint32;int32"
        );
        _assertParams(
            _artifact("OspexSpreadScorer"),
            "$.abi[?(@.name == 'outcome')].inputs",
            "homeScore;awayScore;homeLine",
            "uint32;uint32;int32"
        );
        _assertParams(
            _artifact("IOspexGames"),
            "$.abi[?(@.name == 'getGameScores')].outputs",
            "homeScore;awayScore",
            "uint32;uint32"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // "A market settles on anything but its game's own status."
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexMarkets.settleMarket, replace `revert OspexMarkets__GameNotEnded(m.gameId, status);` with
    /// `outcome = Outcome.Void;`. A market on a game still in play then settles as a void.
    function test_neverLine_aMarketSettlesOnlyOnItsGamesOwnStatus() public {
        // A game at each status short of an end, its score fields planted so that a read of the fields alone
        // would settle the market: the status is what decides, and it refuses by name.
        GameStatus[3] memory open = [GameStatus.Unverified, GameStatus.Verified, GameStatus.Disputed];
        for (uint256 i; i < open.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 game = _inStatus(open[i]);
            games.harnessSetScoreFields(game, HOME_121, AWAY_99);
            uint256 market = _market(game, address(moneyline), 0);

            (bool ok, bytes memory err) = _trySettle(market);
            assertFalse(ok, "settled on a game still in play");
            assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameNotEnded.selector, game, open[i]));
            Market memory m = markets.getMarket(market);
            assertEq(uint8(m.status), uint8(MarketStatus.Open), "the market closed");
            assertEq(uint8(m.outcome), uint8(Outcome.None), "the market has an outcome");
            (ok, err) = _tryClaim(maker, market, Side.A);
            assertFalse(ok, "claimed on a market not settled");
            assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NotSettled.selector, market));
        }

        // The score written through the report door ends the game, and the market settles on it.
        vm.warp(DATE - 1 hours);
        uint256 scored = _verifiedGame();
        uint256 live = _market(scored, address(moneyline), 0);
        vm.warp(START + 1);
        _scoreBy(first, scored, HOME_121, AWAY_99);
        _settle(live);
        assertEq(uint8(_outcome(live)), uint8(Outcome.Home));
    }

    /// Break: in OspexMarkets.settleMarket, change `status == GameStatus.Voided || status == GameStatus.Released`
    /// to `status == GameStatus.Voided`. A released game's market then never settles.
    function test_neverLine_aVoidAndAReleaseAreVoids() public {
        // Positions are taken while the game is open, then the game ends without a score, each way.
        GameStatus[2] memory ends = [GameStatus.Voided, GameStatus.Released];
        for (uint256 i; i < ends.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 game = _create();
            uint256 market = _market(game, address(spread), -35);
            if (ends[i] == GameStatus.Voided) {
                _startBy(first, game, START);
                vm.warp(START + WINDOW);
                _voidBy(first, game);
            } else {
                vm.warp(_day30(game));
                _releaseBy(stranger, game);
            }
            assertEq(uint8(_status(game)), uint8(ends[i]));

            _settle(market);
            assertEq(uint8(_outcome(market)), uint8(Outcome.Void), "the end reads as a void");
            assertEq(_claim(maker, market, Side.A), STAKE, "side A's stake back");
            assertEq(_claim(taker, market, Side.B), STAKE, "side B's stake back");
        }
        assertEq(token.balanceOf(address(positions)), 0, "coin left behind");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The Cross is the one fill path. The matching module's functions are exactly a written list, six of
    // them state-changing; the Cross is the only one that records a fill, and the positions module takes a
    // fill from the matching module alone. The claim is this set's: v2's matching module, in src/modules/,
    // keeps its own fill as deployed and is not in the set.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: add to OspexMatching a second function that records a fill, such as
    /// `function fill(uint256 gameId, address scorer, int32 lineTicks, Side side, address maker,
    /// uint256 makerRisk, uint256 takerRisk) external { IOspexPositions(i_ospexCore.getModule(POSITION_MODULE))
    /// .recordFill(gameId, scorer, lineTicks, side, maker, makerRisk, msg.sender, takerRisk); }`. Two more turn
    /// it red: cancelOrder made to record a fill of the order it cancels, and recordFill's caller check dropped.
    function test_neverLine_theCrossIsTheOneFillPath() public {
        // The matching module's functions are exactly these: the Cross, the per-order cancel, the per-line
        // floor, the two courier registration calls, the cap's lift, the reads and the constants.
        string[] memory want = vm.split(
            "EVENT_COURIER_REGISTERED();EVENT_COURIER_UNREGISTERED();EVENT_CROSSED();EVENT_MIN_NONCE_UPDATED();"
            "EVENT_ORDER_CANCELLED();EVENT_ORDER_MATCHED();EVENT_ORDER_SKIPPED();EVENT_TAKING_STAKE_CAP_LIFTED();"
            "LOT();MARKET_MODULE();MATCHING_MODULE();MAX_LINE_TICKS();MAX_ODDS();MAX_TAKING_LIFE();MIN_ODDS();"
            "ODDS_SCALE();ORDER_TYPEHASH();POSITION_MODULE();TAKING_STAKE_CAP();"
            "cancelOrder((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256));"
            "cross(((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256),bytes),"
            "((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256),bytes)[]);" "eip712Domain();"
            "getOrderHash((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256));"
            "getDomainSeparator();getModuleType();i_ospexCore();i_timelock();isCourier(address,address);"
            "liftTakingStakeCap();raiseMinNonce(uint256,address,int32,uint256);registerCourier(address);"
            "s_cancelledOrders(bytes32);s_filledRisk(bytes32);s_minNonces(address,bytes32);"
            "s_takingStakeCapLifted();unregisterCourier(address)",
            ";"
        );
        string memory json = _artifact("OspexMatching");
        _assertSameSet(vm.parseJsonKeys(json, "$.methodIdentifiers"), want, "function");
        // Six of them change state, by the compiled interface: every other one is a view or a constant.
        _assertSameSet(
            _stateChanging(json),
            vm.split("cancelOrder;cross;liftTakingStakeCap;raiseMinNonce;registerCourier;unregisterCourier", ";"),
            "state-changing function"
        );

        uint256 game = _verifiedGame();

        // Four of the five that are not the Cross, each on its success path, made by an account that holds coin
        // and has approved the positions module for it: no coin moves, no market is drawn and no position is
        // written. The fifth, the cap's lift, follows on a set of its own.
        OspexMatching.OspexOrder memory order =
            _order(maker, game, address(moneyline), 0, Side.A, 200, STAKE, 1, vm.getBlockTimestamp() + 1 days);
        uint256 makerCoin = token.balanceOf(maker);
        assertGe(makerCoin, STAKE, "the account holds no coin a fill could move");
        assertGe(token.allowance(maker, address(positions)), STAKE, "the account has not approved the positions module");
        vm.startPrank(maker, maker);
        matching.registerCourier(taker);
        matching.cancelOrder(order);
        matching.raiseMinNonce(game, address(moneyline), 0, 2);
        matching.unregisterCourier(taker);
        vm.stopPrank();
        assertTrue(matching.s_cancelledOrders(matching.getOrderHash(order)), "the cancel did not land");
        assertEq(token.balanceOf(maker), makerCoin, "a call of the matching module moved the account's coin");
        assertEq(token.balanceOf(address(positions)), 0, "a call of the matching module moved coin");
        assertEq(markets.marketCount(), 0, "a call of the matching module drew a market");
        assertEq(positions.getPosition(1, maker, Side.A).risk, 0, "a call of the matching module wrote a position");

        // The sixth, the cap's lift, on a set of its own whose cap is still in force, made by the timelock's
        // address: it moves no coin, draws no market and writes no position.
        OspexBetting capped = new OspexBetting(address(games), address(token));
        (bytes32[] memory types, address[] memory addrs) = _freshSet(capped);
        capped.bootstrapModules(types, addrs);
        capped.finalize();
        OspexMatching cappedMatching = OspexMatching(addrs[2]);
        assertFalse(cappedMatching.s_takingStakeCapLifted(), "the fresh set's cap was lifted at deploy");
        vm.prank(address(timelock));
        cappedMatching.liftTakingStakeCap();
        assertTrue(cappedMatching.s_takingStakeCapLifted(), "the lift did not land");
        assertEq(token.balanceOf(maker), makerCoin, "the lift moved the account's coin");
        assertEq(token.balanceOf(addrs[1]), 0, "the lift moved coin");
        assertEq(OspexMarkets(addrs[0]).marketCount(), 0, "the lift drew a market");
        assertEq(OspexPositions(addrs[1]).getPosition(1, maker, Side.A).risk, 0, "the lift wrote a position");

        // The positions module takes a fill, and the end of a Cross, from the matching module alone: from every
        // other address each is refused by name, and nothing moves. A courier both accounts registered is one of
        // them.
        address registered = makeAddr("a courier both accounts registered");
        _register(maker, registered);
        _register(taker, registered);
        address[] memory makers = new address[](1);
        makers[0] = maker;
        address[12] memory callers = [
            stranger,
            deployer,
            maker,
            taker,
            registered,
            address(core),
            address(markets),
            address(moneyline),
            address(spread),
            address(total),
            address(games),
            address(this)
        ];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i], callers[i]);
            (bool ok, bytes memory err) = address(positions)
                .call(
                    abi.encodeCall(
                        OspexPositions.recordFill, (game, address(moneyline), 0, Side.A, maker, STAKE, taker, STAKE)
                    )
                );
            assertFalse(ok, "a fill from an outsider was taken");
            assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NotMatchingModule.selector, callers[i]));
            vm.prank(callers[i], callers[i]);
            (ok, err) = address(positions).call(abi.encodeCall(OspexPositions.finishFills, (1, taker, makers)));
            assertFalse(ok, "an end call from an outsider was taken");
            assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NotMatchingModule.selector, callers[i]));
        }
        assertEq(token.balanceOf(address(positions)), 0, "coin moved");
        assertEq(markets.marketCount(), 0, "a market was drawn");
        assertEq(positions.getPosition(1, maker, Side.A).risk, 0, "a position was written");

        // And the Cross does fill: the same two stakes, through signed orders, sent by a registered courier,
        // on another market of the game, since the floor raised above stands on the first.
        uint256 market = _market(game, address(spread), -35);
        assertEq(token.balanceOf(address(positions)), 2 * STAKE, "the Cross moved the two stakes");
        assertEq(positions.getPosition(market, maker, Side.A).risk, STAKE, "the Cross wrote the resting position");
        assertEq(positions.getPosition(market, taker, Side.B).risk, STAKE, "the Cross wrote the taking position");
    }

    /// @dev The names of an artifact's functions that are neither view nor pure.
    function _stateChanging(string memory json) internal view returns (string[] memory out) {
        string[] memory found = new string[](64);
        uint256 n;
        for (uint256 i; vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat("$.abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".type")))) != keccak256("function")) {
                continue;
            }
            bytes32 mutability = keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".stateMutability"))));
            if (mutability == keccak256("view") || mutability == keccak256("pure")) continue;
            found[n++] = vm.parseJsonString(json, string.concat(entry, ".name"));
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = found[i];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Couriers: only an account changes its couriers, and no account has one by default. The account is the
    // caller of the call. What an agent's grant may do is not built; these two calls take no grant, no
    // signature and no account, which is the part of that line this set can hold today.
    //
    // The courier calls below are sent both ways a call arrives: with the caller as the transaction's origin,
    // and with another address as its origin, so a line that read tx.origin where it should read msg.sender,
    // or that told the two cases apart, would change what a test sees. The pairs read are every pair of
    // twenty-one addresses: those the module can reach by reading, which are the caller, the origin, itself,
    // its core and what its core names; with the accounts, this contract and the zero address. An address
    // the code spelled out or computed would be outside them. Every one of the twenty-one but zero makes the
    // calls, a contract as a key does, so a line that set the deployer or a contract apart as a caller would
    // show too. For what a list of addresses cannot reach, the writes to the module's storage are counted:
    // one slot for each call that changes state, none for a call that does not, and none at deploy.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev How many of _everyone()'s addresses name every address in the sweep: its first four. Each other
    ///      address but zero makes the calls too, and names one.
    uint256 internal constant CALLERS = 4;

    /// @dev The transaction origin these tests give a call when the caller is not to be its own origin. In the
    ///      sweep it is a caller too, as every address of _everyone() but zero is.
    address internal origin = makeAddr("origin");

    /// @dev What each account's couriers should be, written here as the calls are made.
    mapping(address => mapping(address => bool)) internal wantCourier;
    /// @dev The last floor a test raised: each raise has to be higher than the one before.
    uint256 internal lastFloor;

    /// Break: in OspexMatching.registerCourier, swap the two keys of the write:
    /// `s_couriers[courier][msg.sender] = true;`. The caller then writes the couriers of the address it names.
    /// The same swap in unregisterCourier's write turns it red too; so does `tx.origin` in place of
    /// `msg.sender` in either write; a courier written by the cancel or by the floor; a drop that takes a
    /// second courier with it; a registration written only when the caller is its own origin, or only when
    /// it is not; a second write for an address spelled out in the code, by a registration or by the cancel;
    /// a repeated registration that writes at all, for such an address or for the transaction's origin; a
    /// write that goes to another account's entry when the caller is the set's deployer; a drop that takes a
    /// second courier with it only when it names one address; and an event of the couriers' emitted by the
    /// cancel.
    function test_neverLine_onlyTheAccountChangesItsCouriers() public {
        // The two calls take one address, the courier, and no account.
        string memory json = _artifact("OspexMatching");
        _assertParams(json, "$.abi[?(@.name == 'registerCourier')].inputs", "courier", "address");
        _assertParams(json, "$.abi[?(@.name == 'unregisterCourier')].inputs", "courier", "address");

        address[] memory all = _everyone();
        address courier = all[3];
        // Every address but the last, the zero address, is registered.
        uint256 named = all.length - 1;

        // The sweep. Each of the first four addresses, as the caller, names each of the twenty that are not
        // zero, itself and the other callers included. Each of the other sixteen, the set's own contracts and
        // its deployer among them, is a caller too and names one, the next in the list. There are four passes:
        // each caller registers what it names, registers it again, drops it, and drops it again. After every
        // call every pair is read. After a registration or a drop the caller's entry for the address it named
        // has moved, and no other has. After a repeated registration, which changes nothing, and after a
        // repeated drop, which is refused by name, none has. Each call's writes to the module's storage and
        // its events are counted: one slot and two events for a change, none of either otherwise. Of the
        // module's four calls that change state, the two registration calls are the only ones that write a
        // courier: before the registrations, with no entry set, and before the drops, with every caller's
        // entries set, the cancel and the floor move no entry. All of it runs twice. Sent with another address
        // as the origin, the addresses are named in the list's order; sent by the callers themselves, in
        // reverse, so that a call that moved a second entry of the caller's own shows whichever of the two is
        // named first.
        for (uint256 direct; direct < 2; ++direct) {
            _theCancelAndTheFloorWriteNoCourier(all, direct == 1);
            for (uint256 pass; pass < 4; ++pass) {
                for (uint256 i; i < named; ++i) {
                    for (uint256 k; k < named; ++k) {
                        uint256 j = direct == 1 ? named - 1 - k : k;
                        if (i < CALLERS || j == (i + 1) % named) _sweepCall(all, i, j, pass, direct == 1);
                    }
                }
                if (pass == 1) _theCancelAndTheFloorWriteNoCourier(all, direct == 1);
            }
        }

        // The maker's courier stands when the others try to drop it: a stranger, the other account and the
        // courier itself each send the drop, naming the courier and naming the maker, and each is refused for
        // an entry of its own that it does not have.
        vm.prank(maker, origin);
        matching.registerCourier(courier);
        address[3] memory others = [stranger, taker, courier];
        address[2] memory target = [courier, maker];
        for (uint256 i; i < others.length; ++i) {
            for (uint256 j; j < target.length; ++j) {
                vm.prank(others[i], origin);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        OspexMatching.OspexMatching__CourierNotRegistered.selector, others[i], target[j]
                    )
                );
                matching.unregisterCourier(target[j]);
            }
            assertTrue(matching.isCourier(maker, courier), "another address dropped the account's courier");
        }

        // The account is the caller, not the transaction's origin: what an account's own call into another
        // contract could do. Below, the origin of each call is the account that sent it, as on chain, and the
        // caller the module sees is the contract.
        CourierCaller relay = new CourierCaller();
        address lure = makeAddr("lure");

        // The taker calls a contract that registers a courier: the entry written is the contract's, and the
        // contract is the account both of its events name.
        vm.recordLogs();
        vm.prank(taker, taker);
        relay.register(matching, lure);
        VmSafe.Log[] memory relayLogs = vm.getRecordedLogs();
        assertEq(relayLogs.length, 2, "the calling contract's registration did not emit twice");
        assertEq(relayLogs[0].topics[1], bytes32(uint256(uint160(address(relay)))), "the account its event names");
        assertEq(
            abi.decode(relayLogs[1].data, (bytes)), abi.encode(address(relay), lure), "the account its hub event names"
        );
        assertTrue(matching.isCourier(address(relay), lure), "the calling contract's own entry");
        assertFalse(matching.isCourier(taker, lure), "a contract the account called registered a courier for it");

        // The contract has the courier and the stranger does not. Sent by the stranger, the contract's second
        // registration is the contract's repeat: it emits nothing and writes nothing for the stranger. Its
        // drop is taken.
        vm.recordLogs();
        vm.prank(stranger, stranger);
        relay.register(matching, lure);
        assertEq(vm.getRecordedLogs().length, 0, "the calling contract's repeat was taken as a first registration");
        assertTrue(matching.isCourier(address(relay), lure), "the calling contract's entry, after its repeat");
        assertFalse(matching.isCourier(stranger, lure), "a contract's repeat registered a courier for its sender");
        vm.prank(stranger, stranger);
        relay.unregister(matching, lure);
        assertFalse(matching.isCourier(address(relay), lure), "the calling contract's own entry was not dropped");

        // The taker has the courier and the contract does not. Sent by the taker, the contract's drop is
        // refused as the contract's and the taker's courier stands; the contract's registration is taken.
        vm.prank(taker, taker);
        matching.registerCourier(lure);
        vm.prank(taker, taker);
        vm.expectRevert(
            abi.encodeWithSelector(OspexMatching.OspexMatching__CourierNotRegistered.selector, address(relay), lure)
        );
        relay.unregister(matching, lure);
        assertTrue(matching.isCourier(taker, lure), "a contract the account called dropped its courier");
        vm.prank(taker, taker);
        relay.register(matching, lure);
        assertTrue(matching.isCourier(address(relay), lure), "the calling contract's registration was refused");

        // Both have it. Sent by the taker, the contract's drop takes the contract's entry and leaves the
        // taker's.
        vm.prank(taker, taker);
        relay.unregister(matching, lure);
        assertFalse(matching.isCourier(address(relay), lure), "the calling contract's entry, after its drop");
        assertTrue(matching.isCourier(taker, lure), "the account's courier, after the contract's drop");

        // Each of the module's four calls that change state writes one slot of its storage and no more, sent
        // either way: a registration and a drop the caller's pair, the cancel its mark, the floor its floor.
        // The one slot is shown to be that one by reading it before and after. It is shown here for one
        // account naming a fresh address; the sweep above counts the same for every call it makes. A
        // repeated registration, which changes nothing, writes no slot at all. A write made only for a
        // caller or an address that neither sends is not counted.
        vm.record();
        for (uint256 direct; direct < 2; ++direct) {
            address sentFrom = direct == 1 ? stranger : origin;
            address fresh = makeAddr(direct == 1 ? "one more courier" : "another courier");
            OspexMatching.OspexOrder memory order = OspexMatching.OspexOrder({
                account: stranger,
                gameId: 7,
                scorer: fresh,
                lineTicks: 0,
                positionType: Side.A,
                oddsTick: 200,
                riskAmount: STAKE,
                nonce: 1,
                expiry: 1_900_000_000,
                minFill: 0
            });
            bytes32 hash = matching.getOrderHash(order);
            bytes32 key = keccak256(abi.encode(uint256(7), fresh, int32(0)));
            assertFalse(matching.isCourier(stranger, fresh), "the fresh courier is registered already");
            assertFalse(matching.s_cancelledOrders(hash), "the fresh order is cancelled already");
            assertEq(matching.s_minNonces(stranger, key), 0, "the fresh floor is raised already");
            uint256 before = _slotsWritten();

            vm.prank(stranger, sentFrom);
            matching.registerCourier(fresh);
            assertEq(_slotsWritten() - before, 1, "a registration did not write exactly one slot");
            assertTrue(matching.isCourier(stranger, fresh), "the slot a registration wrote is not the caller's pair");

            vm.prank(stranger, sentFrom);
            matching.registerCourier(fresh);
            assertEq(_slotsWritten() - before, 1, "a repeated registration wrote a slot");

            vm.prank(stranger, sentFrom);
            matching.cancelOrder(order);
            assertEq(_slotsWritten() - before, 2, "a cancel did not write exactly one slot");
            assertTrue(matching.s_cancelledOrders(hash), "the slot a cancel wrote is not its mark");

            vm.prank(stranger, sentFrom);
            matching.raiseMinNonce(7, fresh, 0, ++lastFloor);
            assertEq(_slotsWritten() - before, 3, "a raised floor did not write exactly one slot");
            assertEq(matching.s_minNonces(stranger, key), lastFloor, "the slot a raised floor wrote is not its floor");

            vm.prank(stranger, sentFrom);
            matching.unregisterCourier(fresh);
            assertEq(_slotsWritten() - before, 4, "a drop did not write exactly one slot");
            assertFalse(matching.isCourier(stranger, fresh), "the slot a drop wrote is not the caller's pair");
        }
    }

    /// Break: in OspexMatching.isCourier, give every account a courier it did not register:
    /// `return s_couriers[account][courier] || courier == i_ospexCore.i_deployer();`. More turn it red: the
    /// transaction's origin as that courier; a second courier written beside the one the caller named; the
    /// caller's courier written for a second account; a courier that appears, or lapses, with time; and a
    /// courier written at deploy, for an address read here or not.
    function test_neverLine_noAccountHasACourierByDefault() public {
        // The set as deployed and finalized, with nothing registered: no pair of the addresses reads as
        // registered.
        assertTrue(core.s_finalized(), "the set is not finalized");
        address[] memory all = _everyone();
        _assertCouriers(all, "a courier nobody registered");

        // One registration writes one pair. The maker registers a courier: no other account has it, or any
        // other, and the maker has no second one.
        vm.prank(maker, origin);
        matching.registerCourier(all[3]);
        assertTrue(matching.isCourier(maker, all[3]), "the maker's courier was not registered");
        wantCourier[maker][all[3]] = true;
        _assertCouriers(all, "a courier the account did not register");

        // The same from an account that sends its own call.
        vm.prank(taker, taker);
        matching.registerCourier(all[4]);
        assertTrue(matching.isCourier(taker, all[4]), "the taker's courier was not registered");
        wantCourier[taker][all[4]] = true;
        _assertCouriers(all, "a courier the account did not register");

        // Time gives no courier and takes none: a hundred years and a billion blocks on, every pair reads as
        // it did.
        vm.warp(block.timestamp + 36_500 days);
        vm.roll(block.number + 1_000_000_000);
        _assertCouriers(all, "a hundred years on");

        // The module's constructor writes nothing. Deployed again here with its storage watched, it has no
        // slot written, so no courier is set at deploy for any address, read above or not.
        vm.record();
        OspexMatching again = new OspexMatching(address(core));
        (, bytes32[] memory written) = vm.accesses(address(again));
        assertEq(written.length, 0, "the constructor wrote to storage");
    }

    /// @dev The addresses whose pairs the courier tests read. The first four are the accounts that name every
    ///      address in the sweep, and the last is the zero address, read and never registered. Between them: a
    ///      fifth account; the origin the tests give a call; the origin of this test's own reads; this
    ///      contract; and every address the matching module can reach by reading, itself, its core and what
    ///      its core names, the deployer, the other modules, the games set and the coin, with the games set's
    ///      timelock and its key.
    function _everyone() internal returns (address[] memory all) {
        all = new address[](21);
        all[0] = maker;
        all[1] = taker;
        all[2] = stranger;
        all[3] = makeAddr("courier");
        all[4] = makeAddr("third");
        all[5] = origin;
        all[6] = tx.origin;
        all[7] = address(this);
        all[8] = address(matching);
        all[9] = address(core);
        all[10] = deployer;
        all[11] = address(markets);
        all[12] = address(positions);
        all[13] = address(moneyline);
        all[14] = address(spread);
        all[15] = address(total);
        all[16] = address(games);
        all[17] = address(token);
        all[18] = address(timelock);
        all[19] = timelockKey;
        all[20] = address(0);
    }

    /// @dev One call of the sweep, and what is read after it. all[i] is the caller and all[j] the address it
    ///      names. Pass 0: the caller registers it; 1: registers it again; 2: drops it; 3: drops it again,
    ///      which is refused. `direct`: the caller sends its own call; otherwise the origin is another address.
    function _sweepCall(address[] memory all, uint256 i, uint256 j, uint256 pass, bool direct) internal {
        string memory when = pass == 0
            ? "after a registration"
            : pass == 1 ? "after a repeated registration" : pass == 2 ? "after a drop" : "after a repeated drop";
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(all[i], direct ? all[i] : origin);
        if (pass == 3) {
            vm.expectRevert(
                abi.encodeWithSelector(OspexMatching.OspexMatching__CourierNotRegistered.selector, all[i], all[j])
            );
        }
        if (pass < 2) matching.registerCourier(all[j]);
        else matching.unregisterCourier(all[j]);
        // A change writes one slot of the module's storage and emits twice, itself and through the hub; a
        // repeat and a refused drop write none and emit nothing.
        assertEq(
            _moduleSlotsWritten(vm.stopAndReturnStateDiff()), pass % 2 == 0 ? 1 : 0, string.concat("slots, ", when)
        );
        assertEq(vm.getRecordedLogs().length, pass % 2 == 0 ? 2 : 0, string.concat("events, ", when));
        wantCourier[all[i]][all[j]] = pass < 2;
        _assertCouriers(all, when);
    }

    /// @dev How many writes to the matching module's storage a recorded stretch of calls made and kept.
    function _moduleSlotsWritten(VmSafe.AccountAccess[] memory accesses) internal view returns (uint256 n) {
        for (uint256 a; a < accesses.length; ++a) {
            VmSafe.StorageAccess[] memory slots = accesses[a].storageAccesses;
            for (uint256 s; s < slots.length; ++s) {
                if (slots[s].account == address(matching) && slots[s].isWrite && !slots[s].reverted) ++n;
            }
        }
    }

    /// @dev Each of the four callers cancels an order and raises a floor, on an order that names each of the
    ///      addresses as its market contract: every pair still reads as written in wantCourier, and the two
    ///      calls emit their own four events and no fifth. `direct`: the callers send their own calls;
    ///      otherwise the origin is another address.
    function _theCancelAndTheFloorWriteNoCourier(address[] memory all, bool direct) internal {
        for (uint256 i; i < CALLERS; ++i) {
            for (uint256 j; j < all.length; ++j) {
                OspexMatching.OspexOrder memory order = OspexMatching.OspexOrder({
                    account: all[i],
                    gameId: 7,
                    scorer: all[j],
                    lineTicks: 0,
                    positionType: Side.A,
                    oddsTick: 200,
                    riskAmount: STAKE,
                    nonce: 1,
                    expiry: 1_900_000_000,
                    minFill: 0
                });
                vm.recordLogs();
                vm.startPrank(all[i], direct ? all[i] : origin);
                matching.cancelOrder(order);
                matching.raiseMinNonce(7, all[j], 0, ++lastFloor);
                vm.stopPrank();
                // Each emits twice, its own event and the hub's: no event of the couriers' beside them.
                assertEq(vm.getRecordedLogs().length, 4, "the events of a cancel and a raised floor");
            }
        }
        _assertCouriers(all, "after the cancel and the floor");
    }

    /// @dev How many storage writes the matching module has made since the test began recording them.
    function _slotsWritten() internal returns (uint256) {
        (, bytes32[] memory writes) = vm.accesses(address(matching));
        return writes.length;
    }

    /// @dev Every pair of `all`, account then courier, reads as written in wantCourier. A failure names the
    ///      two by their place in `all`.
    function _assertCouriers(address[] memory all, string memory when) internal view {
        for (uint256 a; a < all.length; ++a) {
            for (uint256 c; c < all.length; ++c) {
                bool got = matching.isCourier(all[a], all[c]);
                if (got != wantCourier[all[a]][all[c]]) {
                    assertEq(
                        got,
                        wantCourier[all[a]][all[c]],
                        string.concat(when, ": account ", vm.toString(a), ", courier ", vm.toString(c))
                    );
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The registry is exactly the required set, and the deployer keeps nothing.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: in OspexBetting.finalize, delete the count check, `if (s_moduleCount != required.length) revert
    /// OspexBetting__ModuleCountMismatch(s_moduleCount, required.length);`. A seventh module then finalizes.
    function test_neverLine_theRegistryIsExactlyTheRequiredSet() public {
        vm.startPrank(deployer, deployer);

        // Five of the six: refused by the count.
        OspexBetting five = new OspexBetting(address(games), address(token));
        (bytes32[] memory types, address[] memory addrs) = _freshSet(five);
        bytes32[] memory fiveTypes = new bytes32[](5);
        address[] memory fiveAddrs = new address[](5);
        for (uint256 i; i < 5; ++i) {
            fiveTypes[i] = types[i];
            fiveAddrs[i] = addrs[i];
        }
        five.bootstrapModules(fiveTypes, fiveAddrs);
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleCountMismatch.selector, 5, 6));
        five.finalize();

        // Six under their types and a seventh of another type: refused by the count, whatever the seventh is.
        OspexBetting seven = new OspexBetting(address(games), address(token));
        (types, addrs) = _freshSet(seven);
        bytes32[] memory sevenTypes = new bytes32[](7);
        address[] memory sevenAddrs = new address[](7);
        for (uint256 i; i < 6; ++i) {
            sevenTypes[i] = types[i];
            sevenAddrs[i] = addrs[i];
        }
        sevenTypes[6] = keccak256("EXTRA_MODULE");
        sevenAddrs[6] = address(new ExtraModule());
        seven.bootstrapModules(sevenTypes, sevenAddrs);
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleCountMismatch.selector, 7, 6));
        seven.finalize();

        // Six, one of them under another required type: refused at bootstrap, by the module's own answer.
        OspexBetting swapped = new OspexBetting(address(games), address(token));
        (types, addrs) = _freshSet(swapped);
        (addrs[0], addrs[1]) = (addrs[1], addrs[0]);
        vm.expectRevert(
            abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleTypeMismatch.selector, addrs[0], types[0], types[1])
        );
        swapped.bootstrapModules(types, addrs);

        // Six, each of a required type but one of another: the count passes and the missing type is named.
        OspexBetting missing = new OspexBetting(address(games), address(token));
        (types, addrs) = _freshSet(missing);
        types[5] = keccak256("EXTRA_MODULE");
        addrs[5] = address(new ExtraModule());
        missing.bootstrapModules(types, addrs);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexBetting.OspexBetting__ModuleNotRegistered.selector, missing.TOTAL_SCORER_MODULE()
            )
        );
        missing.finalize();

        // Exactly the six: finalized, and from then on the deployer can register nothing and finalize nothing.
        OspexBetting six = new OspexBetting(address(games), address(token));
        (types, addrs) = _freshSet(six);
        six.bootstrapModules(types, addrs);
        six.finalize();
        assertTrue(six.s_finalized());
        vm.expectRevert(OspexBetting.OspexBetting__AlreadyFinalized.selector);
        six.bootstrapModules(types, addrs);
        vm.expectRevert(OspexBetting.OspexBetting__AlreadyFinalized.selector);
        six.finalize();
        vm.stopPrank();

        // Before finalize, nobody but the deployer registers or finalizes.
        vm.prank(deployer, deployer);
        OspexBetting fresh = new OspexBetting(address(games), address(token));
        vm.prank(deployer, deployer);
        (types, addrs) = _freshSet(fresh);
        vm.prank(stranger, stranger);
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__NotDeployer.selector, stranger));
        fresh.bootstrapModules(types, addrs);
        vm.prank(stranger, stranger);
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__NotDeployer.selector, stranger));
        fresh.finalize();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // The wiring is checked when a module is registered. The core asks a module for what a module of its type
    // was deployed with: the three modules for their core, the markets module and the three market contracts
    // for their games set, the positions module for its coin. One whose answer is not the core's own is wired
    // wrong, and is refused at bootstrap, so finalize finds nothing wired wrong to lock. A market contract is
    // asked for no core: it holds none, and is checked on its games set alone. And the zero address is never
    // one of the three market contracts.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev What the wiring tests hold between their steps: the core under test, the six types and its own six
    ///      modules in the core's order, its positions module where a step fills, and the two counts. In
    ///      storage, so that each step is a short function of its own.
    OspexBetting internal wCore;
    bytes32[] internal wTypes;
    address[] internal wOwn;
    OspexPositions internal wPositions;
    uint256 internal wRefused;
    uint256 internal wNotRefused;

    /// The eighteen: the six kinds of module, built from src/, each deployed with each of the three other
    /// cores. A module of this repository takes its games set and its coin from its core, so the three ways of
    /// being wired wrong are three kinds of other core. What each is told, one row for each other core and
    /// one letter for each kind, in the core's order (markets, positions, matching, moneyline, spread, total):
    /// G the games set's refusal, T the coin's, C the core's, and "-" for a module that registers.
    ///
    ///   the other core differs in its address alone   C C C - - -
    ///   the other core names the second games set     G C C G G G
    ///   the other core names the second coin          C T C - - -
    ///
    /// The six that register are market contracts whose games set is this core's. A market contract keeps
    /// nothing of the core it was deployed with but the games set it copied: each of the six has the code hash
    /// of this core's own market contract, the games set's address included, and each of the three that are
    /// refused has another.
    ///
    /// Break: in OspexBetting._checkWiring, delete the core's comparison, `if (core != address(this)) revert
    /// OspexBetting__ModuleCoreMismatch(moduleAddress, core);`. Or make it `if (core == address(0))`; or drop
    /// one type from its condition; or drop one type from the games set's condition; or delete the coin's
    /// comparison; or, in bootstrapModules, check only the first address of a call, `if (i == 0)
    /// _checkWiring(moduleTypes[i], moduleAddresses[i]);`.
    function test_neverLine_aModuleWiredWrongIsRefusedAtBootstrap() public {
        _deployOtherCores();
        vm.startPrank(deployer, deployer);
        _aCoreWithItsOwnSix();
        _theSixOfAnotherCoreAreRefusedOrRegister(coreOfSameValues, "CCC---");
        _theSixOfAnotherCoreAreRefusedOrRegister(coreOfGames2, "GCCGGG");
        _theSixOfAnotherCoreAreRefusedOrRegister(coreOfToken2, "CTC---");
        assertEq(wRefused, 12, "the modules refused");
        assertEq(wNotRefused, 6, "the market contracts that register");

        // The control: the six deployed with this core register, here in one call and on another core one at
        // a time. Every refusal above was made by this core, and none of them wrote to it.
        assertEq(wCore.s_moduleCount(), 0, "a refusal moved the count");
        vm.expectEmit(true, true, true, true, address(wCore));
        emit OspexBetting.ModulesBootstrapped(6);
        wCore.bootstrapModules(wTypes, wOwn);
        wCore.finalize();
        assertTrue(wCore.s_finalized(), "the right six did not finalize");

        _aCoreWithItsOwnSix();
        for (uint256 j; j < 6; ++j) {
            (bytes32[] memory t, address[] memory a) = _single(wTypes[j], wOwn[j]);
            wCore.bootstrapModules(t, a);
            assertEq(wCore.getModule(wTypes[j]), wOwn[j], "a right module, alone, was not registered");
        }
        wCore.finalize();
        assertTrue(wCore.s_finalized(), "the right six, one at a time, did not finalize");
        vm.stopPrank();
    }

    /// For each of the twelve that are refused: the other five register, the wrong one is refused, and finalize
    /// refuses the five. Then the right module registers under the same type and the set finalizes, so the
    /// refusal did not use up the type. A whole set of another core, sent in one call, registers nothing. And
    /// the steps that on a core without the check pay a spread market on another games set's score stop at
    /// the registration. finalize itself reads no module. What keeps a set wired wrong from being locked is
    /// that its wrong module is never registered, so every refusal of finalize here is the count's.
    ///
    /// Break: in OspexBetting.bootstrapModules, delete `_checkWiring(moduleTypes[i], moduleAddresses[i]);`.
    function test_neverLine_finalizeLocksNoSetWiredWrong() public {
        _deployOtherCores();
        vm.startPrank(deployer, deployer);
        _noSetLocksWithAModuleOfAnotherCore(coreOfSameValues, "CCC---");
        _noSetLocksWithAModuleOfAnotherCore(coreOfGames2, "GCCGGG");
        _noSetLocksWithAModuleOfAnotherCore(coreOfToken2, "CTC---");
        vm.stopPrank();
        assertEq(wRefused, 12, "the sets a wrong module was kept out of");
        assertEq(wNotRefused, 6, "the market contracts that are not wired wrong");

        // The money case, step for step. A core on the first games set, five modules deployed with it, and a
        // spread contract deployed with a core of the second games set. A game of the same number in both sets
        // ends home 121, away 99 in the first and home 99, away 121 in the second. On a core that checks a
        // module's type alone the six register, a market on that spread contract settles on the second set's
        // score, and the away side is paid. Here the six are refused, and so is the spread contract alone; a
        // fill that names it is refused; and with this core's own spread contract registered in its place the
        // market settles on its own game's score, and the home side is paid.
        address wrong = _theSecondSetsSpreadContractIsRefused();
        _fund(maker, address(wPositions));
        _fund(taker, address(wPositions));
        uint256 game = _verifiedGame();
        assertEq(_verifiedGameOnGames2(), game, "the game's number differs between the two sets");
        _assertAFillIsRefused(game, wrong);
        _theSetLocksAndPaysOnItsOwnGamesScore(game, wrong);
    }

    /// Eight cores, one for each subset of the three market contracts registered, from none to all three. On
    /// each the zero address is not approved, before the registrations, after each of them and at the end;
    /// each market contract registered is approved, and each one not registered is not. Then, on each, the
    /// three modules and a module of a type outside the six register beside them, so that up to seven are
    /// registered with a market contract missing or not, and the same holds. Then a whole set, before finalize
    /// and after it. Then what it would let through: on a core with the moneyline and the
    /// total registered and the spread not, a fill that names the zero address as its market contract is
    /// refused, no market is drawn and no coin moves, while a fill that names the moneyline is taken.
    ///
    /// Break: in OspexBetting.isApprovedScorer, delete `if (addr == address(0)) return false;`.
    function test_neverLine_theZeroAddressIsNeverAnApprovedScorer() public {
        vm.startPrank(deployer, deployer);
        for (uint256 subset; subset < 8; ++subset) {
            _theZeroAddressIsNotApprovedWith(subset);
        }

        // A whole set: before finalize and after it.
        _aCoreWithItsOwnSix();
        wCore.bootstrapModules(wTypes, wOwn);
        assertFalse(wCore.isApprovedScorer(address(0)), "approved with the six registered");
        wCore.finalize();
        assertFalse(wCore.isApprovedScorer(address(0)), "approved after finalize");
        for (uint256 i = 3; i < 6; ++i) {
            assertTrue(wCore.isApprovedScorer(wOwn[i]), "a market contract of the finalized set");
        }

        // Every module but the spread registered.
        _aCoreWithItsOwnSix();
        (bytes32[] memory types, address[] memory addrs) = _without(wTypes, wOwn, 4);
        wCore.bootstrapModules(types, addrs);
        vm.stopPrank();
        assertEq(wCore.getModule(wCore.SPREAD_SCORER_MODULE()), address(0), "the spread is registered");
        assertFalse(wCore.isApprovedScorer(address(0)), "approved with the spread not registered");

        _fund(maker, address(wPositions));
        _fund(taker, address(wPositions));
        uint256 game = _verifiedGame();
        _assertAFillIsRefused(game, address(0));
        // The same fill on the moneyline, which is registered, is taken: the refusal was the zero address's.
        uint256 market = _wFill(game, wOwn[3], 0);
        assertEq(OspexMarkets(wOwn[0]).getMarket(market).scorer, wOwn[3], "the market's contract");
        assertEq(token.balanceOf(address(wPositions)), 2 * STAKE, "the two stakes");
    }

    // ──────────────────────────── The wiring's steps ───────────────────

    /// @dev A fresh core on the first games set and the first coin, with six modules built from src/ and
    ///      deployed with it, none registered.
    function _aCoreWithItsOwnSix() internal {
        wCore = new OspexBetting(address(games), address(token));
        (bytes32[] memory types, address[] memory right) = _freshSet(wCore);
        wTypes = types;
        wOwn = right;
        wPositions = OspexPositions(right[1]);
    }

    /// @dev A fill of STAKE against STAKE on `game`, the maker on side A, sent to the positions module of the
    ///      core under test as that core's matching module sends one. The Cross has its own tests; these
    ///      are about what the core registers.
    function _wFill(uint256 game, address scorer, int32 line) internal returns (uint256 market) {
        vm.prank(wOwn[2]);
        market = wPositions.recordFill(game, scorer, line, Side.A, maker, STAKE, taker, STAKE);
        // The end call, as the Cross makes it after its walk: the taker's one pull.
        address[] memory makers = new address[](1);
        makers[0] = maker;
        vm.prank(wOwn[2]);
        wPositions.finishFills(market, taker, makers);
    }

    /// @dev The six modules of `other`, each offered to the core under test: by `told`, one letter a kind,
    ///      refused with the letter's refusal or, for "-", registered.
    function _theSixOfAnotherCoreAreRefusedOrRegister(OspexBetting other, string memory told) internal {
        (, address[] memory wrong) = _freshSet(other);
        for (uint256 j; j < 6; ++j) {
            if (bytes(told)[j] == "-") {
                _aMarketContractOfAnotherCoreRegisters(j, wrong[j]);
            } else {
                _aModuleWiredWrongIsRefused(j, wrong[j], _wiringRefusal(bytes(told)[j], wrong[j], address(other)));
            }
        }
    }

    /// @dev `module`, of kind `j`, is refused by the core under test with `refusal`: alone under its own type,
    ///      and as the last of a call of six whose other five are the core's own. Nothing is written either
    ///      time. A market contract that is refused does not have the code hash of this core's own.
    function _aModuleWiredWrongIsRefused(uint256 j, address module, bytes memory refusal) internal {
        if (j >= 3) {
            assertTrue(module.codehash != wOwn[j].codehash, "a refused market contract like this core's own");
        }
        _assertRefusedAlone(wCore, wTypes[j], module, refusal);

        bytes32[] memory t = wTypes;
        address[] memory a = wOwn;
        (t[j], t[5]) = (t[5], t[j]);
        a[j] = a[5];
        a[5] = module;
        vm.expectRevert(refusal);
        wCore.bootstrapModules(t, a);
        for (uint256 i; i < 6; ++i) {
            _assertNotRegistered(wCore, t[i], a[i]);
        }
        assertEq(wCore.s_moduleCount(), 0, "the count moved");
        ++wRefused;
    }

    /// @dev `module`, a market contract of kind `j` deployed with another core that names this games set, has
    ///      the code hash of this core's own; a fresh core takes it in place of its own, with its other five
    ///      in one call, and finalizes.
    function _aMarketContractOfAnotherCoreRegisters(uint256 j, address module) internal {
        assertEq(module.codehash, wOwn[j].codehash, "a market contract unlike this core's own");
        OspexBetting d = new OspexBetting(address(games), address(token));
        (bytes32[] memory types, address[] memory addrs) = _freshSet(d);
        addrs[j] = module;
        d.bootstrapModules(types, addrs);
        d.finalize();
        assertTrue(d.s_finalized(), "the set did not finalize");
        assertEq(d.getModule(types[j]), module, "the module was not registered");
        assertTrue(d.isApprovedScorer(module), "the market contract is not approved");
        assertEq(IOspexModuleWiring(module).i_games(), address(games), "its games set is not this core's");
        ++wNotRefused;
    }

    /// @dev For each module of `other` that `told` refuses: a fresh core registers its own other five, refuses
    ///      the wrong one, cannot finalize, then registers its own under the same type and finalizes. Then the
    ///      whole set of `other`, in one call: the first address, the markets module, is refused, and with it
    ///      the call.
    function _noSetLocksWithAModuleOfAnotherCore(OspexBetting other, string memory told) internal {
        (bytes32[] memory types, address[] memory wrong) = _freshSet(other);
        for (uint256 j; j < 6; ++j) {
            if (bytes(told)[j] == "-") {
                // A market contract that names this core's games set is not wired wrong: the test above
                // registers it and finalizes.
                ++wNotRefused;
            } else {
                _finalizeWaitsForTheRightModule(j, wrong[j], _wiringRefusal(bytes(told)[j], wrong[j], address(other)));
                ++wRefused;
            }
        }

        OspexBetting c = new OspexBetting(address(games), address(token));
        vm.expectRevert(_wiringRefusal(bytes(told)[0], wrong[0], address(other)));
        c.bootstrapModules(types, wrong);
        assertEq(c.s_moduleCount(), 0, "a module of the other core's set was counted");
        for (uint256 j; j < 6; ++j) {
            _assertNotRegistered(c, types[j], wrong[j]);
        }
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleCountMismatch.selector, 0, 6));
        c.finalize();
        assertFalse(c.s_finalized(), "a core with nothing registered finalized");
    }

    /// @dev On a fresh core: its five modules other than kind `j` register; `wrong` is refused under kind `j`'s
    ///      type with `refusal`; finalize refuses the five; the core's own module of kind `j` registers under
    ///      the same type; and the set finalizes.
    function _finalizeWaitsForTheRightModule(uint256 j, address wrong, bytes memory refusal) internal {
        _aCoreWithItsOwnSix();
        (bytes32[] memory t, address[] memory a) = _without(wTypes, wOwn, j);
        wCore.bootstrapModules(t, a);
        assertEq(wCore.s_moduleCount(), 5, "the five");

        _assertRefusedAlone(wCore, wTypes[j], wrong, refusal);
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleCountMismatch.selector, 5, 6));
        wCore.finalize();
        assertFalse(wCore.s_finalized(), "five modules finalized");

        (t, a) = _single(wTypes[j], wOwn[j]);
        wCore.bootstrapModules(t, a);
        vm.expectEmit(true, true, true, true, address(wCore));
        emit OspexBetting.Finalized();
        wCore.finalize();
        assertTrue(wCore.s_finalized(), "the right six did not finalize");
        assertEq(wCore.getModule(wTypes[j]), wOwn[j], "the type holds another address");
        assertFalse(wCore.isRegisteredModule(wrong), "the wrong module is registered");
    }

    /// @dev A fresh core and its own six, with a spread contract deployed with the core of the second games set
    ///      in the spread's place. The six in one call, as a run on a core without the check sends them, are
    ///      refused, and there is no set to lock. The five without it register, and the spread contract alone
    ///      is refused. Returns the spread contract.
    function _theSecondSetsSpreadContractIsRefused() internal returns (address wrong) {
        vm.startPrank(deployer, deployer);
        _aCoreWithItsOwnSix();
        wrong = address(new OspexSpreadScorer(address(coreOfGames2)));
        bytes memory refusal =
            abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleGamesMismatch.selector, wrong, address(games2));
        address[] memory six = wOwn;
        six[4] = wrong;
        vm.expectRevert(refusal);
        wCore.bootstrapModules(wTypes, six);
        vm.expectRevert(abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleCountMismatch.selector, 0, 6));
        wCore.finalize();

        (bytes32[] memory t, address[] memory a) = _without(wTypes, wOwn, 4);
        wCore.bootstrapModules(t, a);
        _assertRefusedAlone(wCore, wTypes[4], wrong, refusal);
        vm.stopPrank();
    }

    /// @dev The core's own spread contract registers under the type the refusal left free, and the set locks.
    ///      A market on it, on `game`, settles on the first set's score, home 121 and away 99, and side A, the
    ///      home team, is paid; `wrong`, which reads the second set, answers the other way for the same game.
    function _theSetLocksAndPaysOnItsOwnGamesScore(uint256 game, address wrong) internal {
        vm.startPrank(deployer, deployer);
        (bytes32[] memory t, address[] memory a) = _single(wTypes[4], wOwn[4]);
        wCore.bootstrapModules(t, a);
        wCore.finalize();
        vm.stopPrank();
        uint256 market = _wFill(game, wOwn[4], -35);

        _score(game, HOME_121, AWAY_99);
        _scoreOnGames2(game, AWAY_99, HOME_121);
        (uint32 home2, uint32 away2) = games2.getGameScores(game);
        assertEq(home2, AWAY_99, "the second set's home score");
        assertEq(away2, HOME_121, "the second set's away score");
        assertEq(uint8(OspexSpreadScorer(wrong).outcomeOf(game, -35)), uint8(Outcome.Away), "the second set's read");

        OspexMarkets m = OspexMarkets(wOwn[0]);
        m.settleMarket(market);
        assertEq(uint8(m.getMarket(market).outcome), uint8(Outcome.Home), "home -3.5 covers 121-99");
        uint256 before = token.balanceOf(maker);
        vm.prank(maker, maker);
        wPositions.claimPosition(market, Side.A);
        assertEq(token.balanceOf(maker) - before, 2 * STAKE, "side A, the home team, is paid");
        vm.prank(taker, taker);
        vm.expectRevert(OspexPositions.OspexPositions__NoPayout.selector);
        wPositions.claimPosition(market, Side.B);
    }

    /// @dev A fresh core with the market contracts of `subset` registered, bit 0 the moneyline, bit 1 the
    ///      spread and bit 2 the total. The zero address is not approved before the registrations, after each
    ///      and at the end; a market contract is approved if it is registered, and not if it is not. The same
    ///      once the three modules and a module of a type outside the six are registered beside them.
    function _theZeroAddressIsNotApprovedWith(uint256 subset) internal {
        _aCoreWithItsOwnSix();
        assertFalse(wCore.isApprovedScorer(address(0)), "approved with nothing registered");
        for (uint256 i; i < 3; ++i) {
            if (((subset >> i) & 1) != 0) {
                (bytes32[] memory t, address[] memory a) = _single(wTypes[3 + i], wOwn[3 + i]);
                wCore.bootstrapModules(t, a);
                assertFalse(wCore.isApprovedScorer(address(0)), "approved after a registration");
            }
        }
        for (uint256 i; i < 3; ++i) {
            assertEq(wCore.isApprovedScorer(wOwn[3 + i]), ((subset >> i) & 1) != 0, "a market contract's approval");
        }
        assertFalse(wCore.isApprovedScorer(address(0)), "approved at the end");

        // The three modules and a module of a type outside the six beside them: four more, so six or seven
        // are registered on the cores where a market contract is still missing.
        bytes32[] memory types = new bytes32[](4);
        address[] memory addrs = new address[](4);
        for (uint256 i; i < 3; ++i) {
            types[i] = wTypes[i];
            addrs[i] = wOwn[i];
        }
        types[3] = keccak256("EXTRA_MODULE");
        addrs[3] = address(new ExtraModule());
        wCore.bootstrapModules(types, addrs);
        assertFalse(wCore.isApprovedScorer(address(0)), "approved beside the modules");
        for (uint256 i; i < 3; ++i) {
            assertEq(wCore.isApprovedScorer(wOwn[3 + i]), ((subset >> i) & 1) != 0, "an approval moved");
        }
        for (uint256 i; i < 4; ++i) {
            assertFalse(wCore.isApprovedScorer(addrs[i]), "a module that is no market contract is approved");
        }
    }

    /// @dev A fill on `game` that names `scorer` as its market contract is refused by the markets module by
    ///      name, through the positions module of the core under test: no market is drawn and no coin moves.
    function _assertAFillIsRefused(uint256 game, address scorer) internal {
        uint256 held = token.balanceOf(address(wPositions));
        uint256 makerCoin = token.balanceOf(maker);
        uint256 takerCoin = token.balanceOf(taker);
        uint256 drawn = OspexMarkets(wOwn[0]).marketCount();
        bytes memory fill =
            abi.encodeCall(OspexPositions.recordFill, (game, scorer, -35, Side.A, maker, STAKE, taker, STAKE));
        vm.prank(wOwn[2]);
        (bool ok, bytes memory err) = address(wPositions).call(fill);
        assertFalse(ok, "the fill was taken");
        assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__ScorerNotApproved.selector, scorer));
        assertEq(OspexMarkets(wOwn[0]).marketCount(), drawn, "a market was drawn");
        assertEq(token.balanceOf(address(wPositions)), held, "coin was pulled");
        assertEq(token.balanceOf(maker), makerCoin, "the maker's coin moved");
        assertEq(token.balanceOf(taker), takerCoin, "the taker's coin moved");
    }

    // ──────────────────────────── The wiring's helpers ─────────────────

    /// @dev One type and one address, as the two arrays bootstrap takes.
    function _single(bytes32 moduleType, address module)
        internal
        pure
        returns (bytes32[] memory types, address[] memory addrs)
    {
        types = new bytes32[](1);
        addrs = new address[](1);
        types[0] = moduleType;
        addrs[0] = module;
    }

    /// @dev The two arrays without their entry `j`, the others in their order.
    function _without(bytes32[] memory types, address[] memory addrs, uint256 j)
        internal
        pure
        returns (bytes32[] memory t, address[] memory a)
    {
        t = new bytes32[](types.length - 1);
        a = new address[](types.length - 1);
        for (uint256 i; i < t.length; ++i) {
            uint256 from = i < j ? i : i + 1;
            t[i] = types[from];
            a[i] = addrs[from];
        }
    }

    /// @dev The refusal a table's letter names, for `module` deployed with `other`: G names the second games
    ///      set as what was found, T the second coin, C the other core. Any other letter is an error in the
    ///      table.
    function _wiringRefusal(bytes1 letter, address module, address other) internal view returns (bytes memory) {
        bytes4 selector;
        address found;
        if (letter == "G") {
            (selector, found) = (OspexBetting.OspexBetting__ModuleGamesMismatch.selector, address(games2));
        } else if (letter == "T") {
            (selector, found) = (OspexBetting.OspexBetting__ModuleTokenMismatch.selector, address(token2));
        } else {
            require(letter == "C", "a letter the table does not have");
            (selector, found) = (OspexBetting.OspexBetting__ModuleCoreMismatch.selector, other);
        }
        return abi.encodeWithSelector(selector, module, found);
    }

    /// @dev Nothing of `module` is in `c`'s registry under `moduleType`.
    function _assertNotRegistered(OspexBetting c, bytes32 moduleType, address module) internal view {
        assertEq(c.getModule(moduleType), address(0), "the type was taken");
        assertFalse(c.isRegisteredModule(module), "the address was registered");
        assertFalse(c.isApprovedScorer(module), "the address is an approved market contract");
    }

    /// @dev `module`, alone under `moduleType`, is refused by `c` with `refusal`, and nothing is written.
    function _assertRefusedAlone(OspexBetting c, bytes32 moduleType, address module, bytes memory refusal) internal {
        uint256 count = c.s_moduleCount();
        (bytes32[] memory t, address[] memory a) = _single(moduleType, module);
        vm.expectRevert(refusal);
        c.bootstrapModules(t, a);
        _assertNotRegistered(c, moduleType, module);
        assertEq(c.s_moduleCount(), count, "the count moved");
    }
}
