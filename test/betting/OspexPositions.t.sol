// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {GameStatus} from "../../src/games/IOspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {BettingBase} from "./BettingBase.sol";

/// @notice The positions module: what a fill writes and pulls, the openness gate, and what a claim pays on
///         each outcome, to whom, once; and that the coin the module holds is what its positions can claim.
contract OspexPositionsTest is BettingBase {
    // ──────────────────────────── Fills ────────────────────────────────

    function test_fill_writesBothPositionsAndPullsBothStakes() public {
        uint256 game = _verifiedGame();
        uint256 makerBefore = token.balanceOf(maker);
        uint256 takerBefore = token.balanceOf(taker);

        vm.expectEmit(true, true, true, true, address(positions));
        emit IOspexPositions.PositionFilled(1, maker, taker, Side.B, Side.A, 3_000_000, 5_000_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            positions.EVENT_POSITION_MATCHED_PAIR(),
            address(positions),
            abi.encode(1, maker, taker, Side.B, Side.A, 3_000_000, 5_000_000)
        );
        uint256 market = _fill(game, address(spread), -35, Side.B, 3_000_000, 5_000_000);

        Position memory m = _position(market, maker, Side.B);
        assertEq(m.risk, 3_000_000, "the maker's risk");
        assertEq(m.profit, 5_000_000, "the maker's profit is the taker's risk");
        assertEq(uint8(m.side), uint8(Side.B));
        assertFalse(m.claimed);
        Position memory t = _position(market, taker, Side.A);
        assertEq(t.risk, 5_000_000, "the taker's risk");
        assertEq(t.profit, 3_000_000, "the taker's profit is the maker's risk");
        assertEq(uint8(t.side), uint8(Side.A));
        assertEq(token.balanceOf(maker), makerBefore - 3_000_000, "the maker's stake pulled");
        assertEq(token.balanceOf(taker), takerBefore - 5_000_000, "the taker's stake pulled");
        assertEq(token.balanceOf(address(positions)), 8_000_000, "the module holds both");
        // Neither account holds anything on the other side.
        assertEq(_position(market, maker, Side.A).risk, 0);
        assertEq(_position(market, taker, Side.B).risk, 0);
    }

    function test_fill_aSecondFillAddsToThePositions() public {
        uint256 game = _verifiedGame();
        uint256 market = _fill(game, address(moneyline), 0, Side.A, 1_000_000, 2_000_000);
        assertEq(_fill(game, address(moneyline), 0, Side.A, 4_000_000, 3_000_000), market);
        assertEq(_position(market, maker, Side.A).risk, 5_000_000);
        assertEq(_position(market, maker, Side.A).profit, 5_000_000);
        assertEq(_position(market, taker, Side.B).risk, 5_000_000);
        assertEq(_position(market, taker, Side.B).profit, 5_000_000);
        assertEq(token.balanceOf(address(positions)), 10_000_000);
    }

    function test_fill_refusesAZeroStake() public {
        uint256 game = _verifiedGame();
        (bool ok, bytes memory err) = _tryFill(game, address(moneyline), 0, Side.A, 0, STAKE);
        assertFalse(ok);
        assertEq(_selector(err), OspexPositions.OspexPositions__InvalidAmount.selector);
        (ok, err) = _tryFill(game, address(moneyline), 0, Side.A, STAKE, 0);
        assertFalse(ok);
        assertEq(_selector(err), OspexPositions.OspexPositions__InvalidAmount.selector);
        assertEq(markets.marketCount(), 0, "a market drawn for a refused fill");
    }

    function test_fill_refusesASettledMarket() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, HOME, AWAY);
        _settle(market);
        // The market exists and is closed: refused at the openness gate by name. (A fill into an ended game's
        // market cannot draw a new one either: the game has ended.)
        (bool ok, bytes memory err) = _tryFill(game, address(moneyline), 0, Side.A, STAKE, STAKE);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__MarketNotOpen.selector, market));
    }

    function test_fill_aStakeTheCoinRefusesIsNoFill() public {
        uint256 game = _verifiedGame();
        token.setBlocked(taker, true);
        (bool ok,) = _tryFill(game, address(moneyline), 0, Side.A, STAKE, STAKE);
        assertFalse(ok, "a fill whose stake the coin refused");
        assertEq(token.balanceOf(address(positions)), 0, "the maker's stake kept without the taker's");
        assertEq(_position(1, maker, Side.A).risk, 0, "a position written without its stake");
        token.setBlocked(taker, false);
        assertEq(_market(game, address(moneyline), 0), 1);
    }

    // ──────────────────────────── Claims ───────────────────────────────

    function test_claim_paysAWinnerRiskAndProfitOnce() public {
        uint256 game = _verifiedGame();
        uint256 market = _fill(game, address(moneyline), 0, Side.A, 3_000_000, 5_000_000);
        _score(game, HOME, AWAY);
        _settle(market);

        vm.expectEmit(true, true, true, true, address(positions));
        emit IOspexPositions.PositionClaimed(market, maker, Side.A, 8_000_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            positions.EVENT_POSITION_CLAIMED(), address(positions), abi.encode(market, maker, Side.A, 8_000_000)
        );
        assertEq(_claim(maker, market, Side.A), 8_000_000, "risk and profit");
        Position memory p = _position(market, maker, Side.A);
        assertTrue(p.claimed);
        assertEq(p.risk, 0);
        assertEq(p.profit, 0);
        (bool ok, bytes memory err) = _tryClaim(maker, market, Side.A);
        assertFalse(ok, "claimed twice");
        assertEq(_selector(err), OspexPositions.OspexPositions__AlreadyClaimed.selector);
        assertEq(token.balanceOf(address(positions)), 0, "the loser's stake is the winner's profit");
    }

    function test_claim_paysALoserNothing() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, HOME, AWAY);
        _settle(market);
        (bool ok, bytes memory err) = _tryClaim(taker, market, Side.B);
        assertFalse(ok);
        assertEq(_selector(err), OspexPositions.OspexPositions__NoPayout.selector);
        assertFalse(_position(market, taker, Side.B).claimed, "a refused claim marked the position claimed");
    }

    function test_claim_paysEachItsStakeOnAPushAndOnAVoid() public {
        // A push: the spread at the margin.
        uint256 game = _verifiedGame();
        uint256 push = _fill(game, address(spread), -70, Side.A, 3_000_000, 5_000_000);
        _score(game, HOME, AWAY);
        _settle(push);
        assertEq(_claim(maker, push, Side.A), 3_000_000);
        assertEq(_claim(taker, push, Side.B), 5_000_000);
        // A void: the game voided at hour 24.
        vm.warp(DATE - 1 hours);
        uint256 voided = _verifiedGame();
        uint256 market = _fill(voided, address(total), 2005, Side.B, 3_000_000, 5_000_000);
        vm.warp(START + WINDOW);
        _voidBy(first, voided);
        _settle(market);
        assertEq(_claim(maker, market, Side.B), 3_000_000);
        assertEq(_claim(taker, market, Side.A), 5_000_000);
        assertEq(token.balanceOf(address(positions)), 0);
    }

    function test_claim_refusesAMarketNotSettledOrNotAMarket() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        (bool ok, bytes memory err) = _tryClaim(maker, market, Side.A);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NotSettled.selector, market));
        (ok, err) = _tryClaim(maker, 2, Side.A);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__UnknownMarket.selector, 2));
        (ok, err) = _tryClaim(maker, 0, Side.A);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OspexMarkets.OspexMarkets__UnknownMarket.selector, 0));
    }

    function test_claim_paysOnlyAPositionsOwner() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, HOME, AWAY);
        _settle(market);
        // A stranger, and the taker on the maker's side, hold nothing there.
        (bool ok, bytes memory err) = _tryClaim(stranger, market, Side.A);
        assertFalse(ok);
        assertEq(_selector(err), OspexPositions.OspexPositions__NoPayout.selector);
        (ok, err) = _tryClaim(taker, market, Side.A);
        assertFalse(ok);
        assertEq(_selector(err), OspexPositions.OspexPositions__NoPayout.selector);
        assertEq(_claim(maker, market, Side.A), 2 * STAKE);
    }

    function test_claim_aRefusedTransferLeavesThePositionClaimable() public {
        uint256 game = _verifiedGame();
        uint256 market = _market(game, address(moneyline), 0);
        _score(game, HOME, AWAY);
        _settle(market);
        token.setPaused(true);
        (bool ok,) = _tryClaim(maker, market, Side.A);
        assertFalse(ok, "paid while the coin refused");
        Position memory p = _position(market, maker, Side.A);
        assertFalse(p.claimed, "marked claimed while unpaid");
        assertEq(p.risk, STAKE, "zeroed while unpaid");
        token.setPaused(false);
        assertEq(_claim(maker, market, Side.A), 2 * STAKE, "paid once the coin allows");
    }

    function test_module_answersItsTypeAndTheCoin() public view {
        assertEq(positions.getModuleType(), core.POSITION_MODULE());
        assertEq(address(positions.i_token()), address(token));
        assertEq(address(positions.i_ospexCore()), address(core));
        assertEq(address(core.i_token()), address(token));
    }
}
