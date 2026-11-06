// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {GameStatus} from "../../src/games/IOspexGames.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {IOspexMarkets} from "../../src/betting/IOspexMarkets.sol";
import {IOspexScorer} from "../../src/betting/IOspexScorer.sol";
import {Market, MarketStatus, Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {BettingBase} from "./BettingBase.sol";

/// @notice The markets module and the three market contracts: what drawing a market accepts and refuses, what
///         settlement reads and how each refusal is named, each outcome on a real scored game, and the
///         arithmetic of the three market contracts over a matrix of scores and lines.
contract OspexMarketsTest is BettingBase {
    // ──────────────────────────── Drawing a market ─────────────────────

    function test_create_drawsTheMarketAtTheFirstFill() public {
        uint256 game = _verifiedGame();
        assertEq(markets.marketCount(), 0);
        assertEq(markets.getMarketId(game, address(spread), -35), 0, "an id before any fill");

        _readyToFill();
        vm.expectEmit(true, true, true, true, address(markets));
        emit IOspexMarkets.MarketCreated(1, game, address(spread), -35, maker, taker);
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            markets.EVENT_MARKET_CREATED(), address(markets), abi.encode(1, game, address(spread), -35, maker, taker)
        );
        uint256 market = _market(game, address(spread), -35);

        assertEq(market, 1);
        assertEq(markets.marketCount(), 1);
        assertEq(markets.getMarketId(game, address(spread), -35), 1);
        Market memory m = markets.getMarket(market);
        assertEq(m.gameId, game);
        assertEq(m.scorer, address(spread));
        assertEq(m.lineTicks, -35);
        assertEq(uint8(m.status), uint8(MarketStatus.Open));
        assertEq(uint8(m.outcome), uint8(Outcome.None));

        // A second fill on the same three fields joins the market; another line is another market.
        assertEq(_fill(game, address(spread), -35, Side.B, STAKE, STAKE), 1, "the second fill joins");
        assertEq(_market(game, address(spread), -45), 2, "another line is another market");
        assertEq(_market(game, address(moneyline), 0), 3, "another market contract is another market");
        assertEq(markets.marketCount(), 3);
    }

    function test_create_onAGameNotYetStartedAndOnADisputedGame() public {
        // Nothing checks the start at a fill: a market is drawn before the start is written.
        uint256 unverified = _create();
        assertEq(uint8(_status(unverified)), uint8(GameStatus.Unverified));
        assertEq(_market(unverified, address(total), 2205), 1);
        // A dispute record is not an end: the market is drawn, and is not settled.
        uint256 disputed = _inStatus(GameStatus.Disputed);
        assertEq(_market(disputed, address(moneyline), 0), 2);
        (bool ok, bytes memory err) = _trySettle(2);
        assertFalse(ok);
        assertEq(
            err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameNotEnded.selector, disputed, GameStatus.Disputed)
        );
    }

    function test_create_refusesAGameThatHasEnded() public {
        GameStatus[3] memory ends = [GameStatus.Scored, GameStatus.Voided, GameStatus.Released];
        for (uint256 i; i < ends.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 game = _inStatus(ends[i]);
            (bool ok, bytes memory err) = _tryFill(game, address(moneyline), 0, Side.A, STAKE, STAKE);
            assertFalse(ok, "a market drawn on an ended game");
            assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, game, ends[i]));
            // The markets module's own refusal, at its own door: asked by the positions module to draw the
            // market, with no fill behind the call, it refuses the same way. (Behind a fill the close gate
            // would refuse an ended game too.)
            vm.prank(address(positions));
            (ok, err) = address(markets)
                .call(abi.encodeCall(OspexMarkets.createMarket, (game, address(moneyline), 0, maker, taker)));
            assertFalse(ok, "a market drawn on an ended game, at the positions module's asking");
            assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameEnded.selector, game, ends[i]));
        }
        assertEq(markets.marketCount(), 0);
    }

    /// The close gate is a read anyone makes: it returns for an open market on a game still in play, and
    /// refuses an id that is not a market, by name.
    function test_gate_isAReadThatRefusesAnIdThatIsNotAMarket() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        vm.prank(stranger);
        markets.requireBetsOpen(market);
        uint256[2] memory bad = [uint256(0), market + 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(OspexMarkets.OspexMarkets__UnknownMarket.selector, bad[i]));
            markets.requireBetsOpen(bad[i]);
        }
    }

    function test_create_refusesAnIdThatIsNotAGame() public {
        uint256 count = games.gameCount();
        uint256[2] memory bad = [uint256(0), count + 1];
        for (uint256 i; i < bad.length; ++i) {
            (bool ok, bytes memory err) = _tryFill(bad[i], address(moneyline), 0, Side.A, STAKE, STAKE);
            assertFalse(ok, "a market drawn on an id that is not a game");
            // The games set's own refusal comes through: its status read refuses the id by name.
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, bad[i]));
        }
    }

    function test_create_refusesAMarketContractNotOnTheSet() public {
        uint256 game = _verifiedGame();
        address[3] memory not = [stranger, address(markets), address(core)];
        for (uint256 i; i < not.length; ++i) {
            (bool ok, bytes memory err) = _tryFill(game, not[i], 0, Side.A, STAKE, STAKE);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__ScorerNotApproved.selector, not[i]));
        }
    }

    function test_create_refusesALineTheMarketContractDoesNotTake() public {
        uint256 game = _verifiedGame();
        // A moneyline has no line.
        (bool ok, bytes memory err) = _tryFill(game, address(moneyline), 35, Side.A, STAKE, STAKE);
        assertFalse(ok);
        assertEq(
            err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__InvalidLineTicks.selector, address(moneyline), 35)
        );
        // A total is never below 0.
        (ok, err) = _tryFill(game, address(total), -5, Side.A, STAKE, STAKE);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__InvalidLineTicks.selector, address(total), -5));
        // A spread takes any line inside the bound, a total any line from 0.
        assertEq(_market(game, address(spread), -1_000_000), 1);
        assertEq(_market(game, address(spread), 1_000_000), 2);
        assertEq(_market(game, address(total), 0), 3);
        assertEq(_market(game, address(total), 1_000_000), 4);
    }

    function test_create_refusesALineOutOfRange() public {
        uint256 game = _verifiedGame();
        int32[2] memory out = [int32(1_000_001), int32(-1_000_001)];
        for (uint256 i; i < out.length; ++i) {
            (bool ok, bytes memory err) = _tryFill(game, address(spread), out[i], Side.A, STAKE, STAKE);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__LineTicksOutOfRange.selector, out[i]));
        }
    }

    function test_create_onlyThePositionsModuleDrawsAMarket() public {
        uint256 game = _verifiedGame();
        address[4] memory callers = [stranger, deployer, address(matching), address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i], callers[i]);
            vm.expectRevert(abi.encodeWithSelector(OspexMarkets.OspexMarkets__NotAuthorized.selector, callers[i]));
            markets.createMarket(game, address(moneyline), 0, maker, taker);
        }
        // The positions module may, once per three fields.
        vm.prank(address(positions));
        assertEq(markets.createMarket(game, address(moneyline), 0, maker, taker), 1);
        vm.prank(address(positions));
        vm.expectRevert(abi.encodeWithSelector(OspexMarkets.OspexMarkets__MarketExists.selector, 1));
        markets.createMarket(game, address(moneyline), 0, maker, taker);
    }

    // ──────────────────────────── Settlement ──────────────────────────

    function test_settle_eachOutcomeOnAScoredGame() public {
        // One game, HOME-AWAY (104-97): a market of each outcome but Void.
        uint256 game = _verifiedGame();
        uint256 home = _market(game, address(moneyline), 0);
        uint256 awayCovers = _market(game, address(spread), -75); // 104 - 7.5 < 97
        uint256 pushSpread = _market(game, address(spread), -70); // 104 - 7 = 97
        uint256 over = _market(game, address(total), 2005); // 201 > 200.5
        uint256 under = _market(game, address(total), 2015); // 201 < 201.5
        uint256 pushTotal = _market(game, address(total), 2010); // 201 = 201
        _score(game, HOME, AWAY);

        vm.expectEmit(true, true, true, true, address(markets));
        emit IOspexMarkets.MarketSettled(home, Outcome.Home, address(moneyline));
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            markets.EVENT_MARKET_SETTLED(), address(markets), abi.encode(home, Outcome.Home, address(moneyline))
        );
        _settle(home);
        _settle(awayCovers);
        _settle(pushSpread);
        _settle(over);
        _settle(under);
        _settle(pushTotal);

        assertEq(uint8(_outcome(home)), uint8(Outcome.Home));
        assertEq(uint8(_outcome(awayCovers)), uint8(Outcome.Away));
        assertEq(uint8(_outcome(pushSpread)), uint8(Outcome.Push));
        assertEq(uint8(_outcome(over)), uint8(Outcome.Over));
        assertEq(uint8(_outcome(under)), uint8(Outcome.Under));
        assertEq(uint8(_outcome(pushTotal)), uint8(Outcome.Push));
        assertEq(uint8(markets.getMarket(home).status), uint8(MarketStatus.Closed));
    }

    function test_settle_aTieIsAPushOnTheMoneyline() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, 100, 100);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Push));
    }

    function test_settle_anywhereAnyoneOnce() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, HOME, AWAY);
        vm.prank(stranger, stranger);
        markets.settleMarket(market);
        vm.expectRevert(abi.encodeWithSelector(OspexMarkets.OspexMarkets__AlreadySettled.selector, market));
        markets.settleMarket(market);
    }

    function test_settle_refusesAnIdThatIsNotAMarket() public {
        uint256 game = _verifiedGame();
        _market(game, address(moneyline), 0);
        uint256[2] memory bad = [uint256(0), uint256(2)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(OspexMarkets.OspexMarkets__UnknownMarket.selector, bad[i]));
            markets.settleMarket(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(OspexMarkets.OspexMarkets__UnknownMarket.selector, bad[i]));
            markets.getMarket(bad[i]);
        }
    }

    function test_settle_refusesAGameNotEnded() public {
        GameStatus[3] memory open = [GameStatus.Unverified, GameStatus.Verified, GameStatus.Disputed];
        for (uint256 i; i < open.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 game = _inStatus(open[i]);
            uint256 market = _market(game, address(total), 2005);
            (bool ok, bytes memory err) = _trySettle(market);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__GameNotEnded.selector, game, open[i]));
        }
    }

    function test_settle_aVoidedGameVoidsEveryMarketOnIt() public {
        uint256 game = _verifiedGame();
        uint256[3] memory ms = [_market(game, address(moneyline), 0), _market(game, address(spread), -35), _market(game, address(total), 2005)];
        vm.warp(START + WINDOW);
        _voidBy(first, game);
        for (uint256 i; i < ms.length; ++i) {
            _settle(ms[i]);
            assertEq(uint8(_outcome(ms[i])), uint8(Outcome.Void));
        }
    }

    // ──────────────────────────── The market contracts ─────────────────

    function test_scorers_readTheGamesSetOnlyOnAScoredGame() public {
        uint256 game = _verifiedGame();
        IOspexScorer[3] memory scorers = [IOspexScorer(moneyline), IOspexScorer(spread), IOspexScorer(total)];
        for (uint256 i; i < scorers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(OspexGames.OspexGames__NotScored.selector, game, GameStatus.Verified)
            );
            scorers[i].outcomeOf(game, 0);
        }
        _score(game, HOME, AWAY);
        assertEq(uint8(moneyline.outcomeOf(game, 0)), uint8(Outcome.Home));
        assertEq(uint8(spread.outcomeOf(game, -75)), uint8(Outcome.Away));
        assertEq(uint8(total.outcomeOf(game, 2005)), uint8(Outcome.Over));
    }

    /// The moneyline over a matrix of scores: the team with more points wins; equal is a push; the line is
    /// ignored.
    function test_scorers_theMoneylinesArithmetic() public view {
        uint32[5] memory scores = [uint32(0), 1, 97, 104, 1_000_000];
        int32[3] memory lines = [int32(0), -35, 1_000_000];
        for (uint256 h; h < scores.length; ++h) {
            for (uint256 a; a < scores.length; ++a) {
                for (uint256 l; l < lines.length; ++l) {
                    Outcome want = scores[h] > scores[a]
                        ? Outcome.Home
                        : scores[h] < scores[a] ? Outcome.Away : Outcome.Push;
                    assertEq(uint8(moneyline.outcome(scores[h], scores[a], lines[l])), uint8(want));
                }
            }
        }
    }

    /// The spread: home covers when home + homeLine > away, away when below, a push when equal; the sign is the
    /// home team's handicap, and the bound of a score and a line do not overflow.
    function test_scorers_theSpreadsArithmetic() public view {
        // (home, away, homeLine) → outcome, written out.
        assertEq(uint8(spread.outcome(121, 99, -35)), uint8(Outcome.Home), "home -3.5 covers 121-99");
        assertEq(uint8(spread.outcome(121, 99, -220)), uint8(Outcome.Push), "home -22 pushes 121-99");
        assertEq(uint8(spread.outcome(121, 99, -225)), uint8(Outcome.Away), "home -22.5 loses 121-99");
        assertEq(uint8(spread.outcome(99, 121, 225)), uint8(Outcome.Home), "home +22.5 covers 99-121");
        assertEq(uint8(spread.outcome(99, 121, 220)), uint8(Outcome.Push), "home +22 pushes 99-121");
        assertEq(uint8(spread.outcome(99, 121, 215)), uint8(Outcome.Away), "home +21.5 loses 99-121");
        assertEq(uint8(spread.outcome(99, 121, 35)), uint8(Outcome.Away), "home +3.5 loses 99-121");
        assertEq(uint8(spread.outcome(100, 100, 0)), uint8(Outcome.Push), "a pick on a tie");
        assertEq(uint8(spread.outcome(100, 100, 5)), uint8(Outcome.Home), "home +0.5 on a tie");
        assertEq(uint8(spread.outcome(100, 100, -5)), uint8(Outcome.Away), "home -0.5 on a tie");
        assertEq(uint8(spread.outcome(1_000_000, 0, -1_000_000)), uint8(Outcome.Home), "the bounds");
        assertEq(uint8(spread.outcome(0, 1_000_000, 1_000_000)), uint8(Outcome.Away), "the bounds");
        assertEq(uint8(spread.outcome(1_000_000, 1_000_000, 1_000_000)), uint8(Outcome.Home), "the bounds");
        // Over a matrix, against the rule written out in the spec's words.
        uint32[4] memory scores = [uint32(0), 3, 97, 104];
        int32[7] memory lines = [int32(-75), -70, -65, 0, 65, 70, 75];
        for (uint256 h; h < scores.length; ++h) {
            for (uint256 a; a < scores.length; ++a) {
                for (uint256 l; l < lines.length; ++l) {
                    int256 adjusted = int256(uint256(scores[h])) * 10 + int256(lines[l]);
                    int256 away = int256(uint256(scores[a])) * 10;
                    Outcome want = adjusted > away ? Outcome.Home : adjusted < away ? Outcome.Away : Outcome.Push;
                    assertEq(uint8(spread.outcome(scores[h], scores[a], lines[l])), uint8(want));
                }
            }
        }
    }

    /// The total: the sum against the line; over, under, push; the bounds do not overflow.
    function test_scorers_theTotalsArithmetic() public view {
        assertEq(uint8(total.outcome(121, 99, 2195)), uint8(Outcome.Over));
        assertEq(uint8(total.outcome(121, 99, 2200)), uint8(Outcome.Push));
        assertEq(uint8(total.outcome(121, 99, 2205)), uint8(Outcome.Under));
        assertEq(uint8(total.outcome(0, 0, 0)), uint8(Outcome.Push));
        assertEq(uint8(total.outcome(0, 1, 0)), uint8(Outcome.Over));
        assertEq(uint8(total.outcome(1_000_000, 1_000_000, 1_000_000)), uint8(Outcome.Over), "the bounds");
        assertEq(uint8(total.outcome(0, 0, 1_000_000)), uint8(Outcome.Under), "the bounds");
        uint32[4] memory scores = [uint32(0), 3, 97, 104];
        int32[5] memory lines = [int32(0), 995, 1000, 1005, 2010];
        for (uint256 h; h < scores.length; ++h) {
            for (uint256 a; a < scores.length; ++a) {
                for (uint256 l; l < lines.length; ++l) {
                    int256 sum = (int256(uint256(scores[h])) + int256(uint256(scores[a]))) * 10;
                    Outcome want = sum > lines[l] ? Outcome.Over : sum < lines[l] ? Outcome.Under : Outcome.Push;
                    assertEq(uint8(total.outcome(scores[h], scores[a], lines[l])), uint8(want));
                }
            }
        }
    }

    function test_scorers_eachAnswersItsTypeAndTheGamesSet() public view {
        assertEq(moneyline.getModuleType(), core.MONEYLINE_SCORER_MODULE());
        assertEq(spread.getModuleType(), core.SPREAD_SCORER_MODULE());
        assertEq(total.getModuleType(), core.TOTAL_SCORER_MODULE());
        assertEq(markets.getModuleType(), core.MARKET_MODULE());
        assertEq(address(markets.i_games()), address(games));
        assertEq(address(markets.i_ospexCore()), address(core));
        assertTrue(core.isApprovedScorer(address(moneyline)));
        assertTrue(core.isApprovedScorer(address(spread)));
        assertTrue(core.isApprovedScorer(address(total)));
        assertFalse(core.isApprovedScorer(address(markets)));
        assertFalse(core.isApprovedScorer(stranger));
    }
}
