// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {GameStatus} from "../../src/games/IOspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {IOspexModule} from "../../src/betting/IOspexModule.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {BettingBase, OspexPositionsHarness} from "./BettingBase.sol";

/// @dev A module of a type the set does not require.
contract ExtraModule is IOspexModule {
    function getModuleType() external pure returns (bytes32) {
        return keccak256("EXTRA_MODULE");
    }
}

/// @notice One test per line that must never happen in the betting set as cut: a score is never read in v2's
///         order, away then home; a market settles on nothing but its game's own status; a void and a release
///         are voids; there is no fill path in the tree; the registry is exactly the required set and the
///         deployer keeps nothing. Above each test, "Break:" names the one-line change to src/betting that
///         turns it red.
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
            _artifact("OspexTotalScorer"), "$.abi[?(@.name == 'outcome')].inputs", "homeScore;awayScore;lineTicks", "uint32;uint32;int32"
        );
        _assertParams(
            _artifact("OspexMoneylineScorer"),
            "$.abi[?(@.name == 'outcome')].inputs",
            "homeScore;awayScore;lineTicks",
            "uint32;uint32;int32"
        );
        _assertParams(
            _artifact("OspexSpreadScorer"), "$.abi[?(@.name == 'outcome')].inputs", "homeScore;awayScore;homeLine", "uint32;uint32;int32"
        );
        _assertParams(
            _artifact("IOspexGames"), "$.abi[?(@.name == 'getGameScores')].outputs", "homeScore;awayScore", "uint32;uint32"
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
    // No fill path in the tree: nothing in the set takes a signed order into a position until the Cross is
    // built with the courier's check inside it.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// Break: add to OspexMatching a function that records a fill, such as
    /// `function matchCommitment(uint256 gameId, address scorer, int32 lineTicks, Side side, address maker,
    /// uint256 makerRisk, uint256 takerRisk) external { IOspexPositions(i_ospexCore.getModule(POSITION_MODULE))
    /// .recordFill(gameId, scorer, lineTicks, side, maker, makerRisk, msg.sender, takerRisk); }`.
    function test_neverLine_noFillPathInTheTree() public {
        // The matching module's functions are exactly these: the per-order cancel, the per-line floor, the
        // reads and the constants. None records a fill, and none takes a signature.
        string[] memory want = vm.split(
            "COMMITMENT_TYPEHASH();EVENT_COMMITMENT_CANCELLED();EVENT_MIN_NONCE_UPDATED();MARKET_MODULE();"
            "MATCHING_MODULE();MAX_LINE_TICKS();MAX_ODDS();MIN_ODDS();ODDS_SCALE();POSITION_MODULE();"
            "cancelCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256));"
            "eip712Domain();"
            "getCommitmentHash((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256));"
            "getDomainSeparator();getModuleType();i_ospexCore();raiseMinNonce(uint256,address,int32,uint256);"
            "s_cancelledCommitments(bytes32);s_minNonces(address,bytes32)",
            ";"
        );
        string[] memory got = vm.parseJsonKeys(_artifact("OspexMatching"), "$.methodIdentifiers");
        _assertSameSet(got, want, "function");

        // The positions module takes a fill from the matching module alone, and that module sends none: from
        // every other address a fill is refused by name, and nothing moves.
        uint256 game = _verifiedGame();
        address[11] memory callers = [
            stranger,
            deployer,
            maker,
            taker,
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
            (bool ok, bytes memory err) = address(positions).call(
                abi.encodeCall(
                    OspexPositions.recordFill, (game, address(moneyline), 0, Side.A, maker, STAKE, taker, STAKE)
                )
            );
            assertFalse(ok, "a fill from an outsider was taken");
            assertEq(
                err, abi.encodeWithSelector(OspexPositions.OspexPositions__NotMatchingModule.selector, callers[i])
            );
        }
        assertEq(token.balanceOf(address(positions)), 0, "coin moved");
        assertEq(markets.marketCount(), 0, "a market was drawn");
        assertEq(positions.getPosition(1, maker, Side.A).risk, 0, "a position was written");
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
            abi.encodeWithSelector(
                OspexBetting.OspexBetting__ModuleTypeMismatch.selector, addrs[0], types[0], types[1]
            )
        );
        swapped.bootstrapModules(types, addrs);

        // Six, each of a required type but one of another: the count passes and the missing type is named.
        OspexBetting missing = new OspexBetting(address(games), address(token));
        (types, addrs) = _freshSet(missing);
        types[5] = keccak256("EXTRA_MODULE");
        addrs[5] = address(new ExtraModule());
        missing.bootstrapModules(types, addrs);
        vm.expectRevert(
            abi.encodeWithSelector(OspexBetting.OspexBetting__ModuleNotRegistered.selector, missing.TOTAL_SCORER_MODULE())
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

    /// @dev Six fresh modules on `c`, with their types, in the core's order.
    function _freshSet(OspexBetting c) internal returns (bytes32[] memory types, address[] memory addrs) {
        types = new bytes32[](6);
        addrs = new address[](6);
        types[0] = c.MARKET_MODULE();
        addrs[0] = address(new OspexMarkets(address(c)));
        types[1] = c.POSITION_MODULE();
        addrs[1] = address(new OspexPositions(address(c)));
        types[2] = c.MATCHING_MODULE();
        addrs[2] = address(new OspexMatching(address(c)));
        types[3] = c.MONEYLINE_SCORER_MODULE();
        addrs[3] = address(new OspexMoneylineScorer(address(c)));
        types[4] = c.SPREAD_SCORER_MODULE();
        addrs[4] = address(new OspexSpreadScorer(address(c)));
        types[5] = c.TOTAL_SCORER_MODULE();
        addrs[5] = address(new OspexTotalScorer(address(c)));
    }
}
