// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GameStatus} from "../../src/games/IOspexGames.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross with the coin the set is to be deployed with: the betting set on Polygon's USDC, on a fork
///         of Polygon mainnet at FORK_BLOCK. Two accounts are funded with that coin by a transfer from an
///         address that holds it at the fork block; a sender both have registered sends one Cross; the market
///         is settled; and the claims are paid in the same coin. Every balance is asserted to the unit. The
///         games set under the betting set is the test base's own, deployed on the fork, so that a game can be
///         scored and voided here. These tests need POLYGON_RPC_URL; without it (CI has no RPC) they are
///         skipped, which is how a run reports that no fork was used.
contract OspexCrossForkTest is CrossBase {
    uint256 internal constant FORK_BLOCK = 96_180_000;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    /// @dev An address that holds USDC at the fork block: the two accounts are funded from it.
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @dev What each account is funded with: 50 USDC, in six decimals.
    uint256 internal constant FUNDED = 50_000_000;
    /// @dev The one leg: 10 USDC of resting stake at 2.10, against 11 USDC.
    uint256 internal constant RESTING_STAKE = 10_000_000;
    uint256 internal constant TAKING_STAKE = 11_000_000;

    IERC20 internal usdc = IERC20(USDC);
    Signer internal restingAccount;
    Signer internal takingAccount;
    /// @dev What the holder has left once the two accounts are funded.
    uint256 internal holderLeft;

    function setUp() public override {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        super.setUp();
        // The betting set again, this time on Polygon's USDC.
        _deploySetOn(USDC);
        (restingAccount.a, restingAccount.key) = makeAddrAndKey("resting account");
        (takingAccount.a, takingAccount.key) = makeAddrAndKey("taking account");
        uint256 held = usdc.balanceOf(HOLDER);
        _fundWithUsdc(restingAccount.a);
        _fundWithUsdc(takingAccount.a);
        holderLeft = usdc.balanceOf(HOLDER);
        assertEq(held - holderLeft, 2 * FUNDED, "the holder paid exactly the two fundings");
        _register(restingAccount.a, sender);
        _register(takingAccount.a, sender);
    }

    /// @dev Funds `who` with FUNDED of Polygon's USDC from the holder, and lets the positions module take it.
    function _fundWithUsdc(address who) internal {
        assertEq(usdc.balanceOf(who), 0, "the account held the coin before it was funded");
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(who, FUNDED), "the funding transfer");
        vm.prank(who);
        assertTrue(usdc.approve(address(positions), type(uint256).max), "the approval");
        assertEq(usdc.balanceOf(who), FUNDED, "the funded balance");
    }

    /// @dev The fork is Polygon at the pinned block, and the set's coin is the contract at Polygon's USDC
    ///      address, which has code there.
    function _assertTheCoinIsPolygonsUsdc() internal view {
        assertEq(block.chainid, 137, "the chain");
        assertGt(USDC.code.length, 0, "Polygon's USDC has no code at the fork block");
        assertEq(address(positions.i_token()), USDC, "the positions module's coin");
        assertEq(address(core.i_token()), USDC, "the core's coin");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module held coin before any fill");
        assertEq(usdc.balanceOf(sender), 0, "the sender held coin");
    }

    /// @dev One Cross of one leg on the game's moneyline, sent by the registered sender: 10 USDC resting on
    ///      side A at 2.10, against a taking order of 11 USDC on side B at 1.90. Every balance after it, to the
    ///      unit: each account paid its own stake, the positions module holds the two, and the sender and the
    ///      matching module hold nothing.
    function _oneCross(uint256 game) internal returns (uint256 market) {
        OspexMatching.SignedOrder memory resting = _rest(restingAccount, game, Side.A, 210, RESTING_STAKE);
        OspexMatching.SignedOrder memory taking = _take(takingAccount, game, Side.B, 190, TAKING_STAKE);
        _cross(sender, taking, _list(resting));
        market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(_filled(resting), RESTING_STAKE, "the resting order's filled amount");
        assertEq(_filled(taking), TAKING_STAKE, "the taking order's filled amount");
        assertEq(usdc.balanceOf(restingAccount.a), FUNDED - RESTING_STAKE, "the resting account, after the Cross");
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED - TAKING_STAKE, "the taking account, after the Cross");
        assertEq(
            usdc.balanceOf(address(positions)), RESTING_STAKE + TAKING_STAKE, "the positions module, after the Cross"
        );
        assertEq(usdc.balanceOf(sender), 0, "the sender, after the Cross");
        assertEq(usdc.balanceOf(address(matching)), 0, "the matching module, after the Cross");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, after the Cross");
        _assertPosition(market, restingAccount.a, Side.A, RESTING_STAKE, TAKING_STAKE, "the resting account's position");
        _assertPosition(market, takingAccount.a, Side.B, TAKING_STAKE, RESTING_STAKE, "the taking account's position");
    }

    /// A Cross in Polygon's USDC, and a winner paid in it. The game is scored 104 to 97, home: side A, the
    /// resting account's, is paid both stakes, 21 USDC, and side B's claim is refused.
    function test_fork_aCrossInPolygonsUsdcPaysTheWinnerInIt() public {
        _assertTheCoinIsPolygonsUsdc();
        uint256 game = _verifiedGame();
        uint256 market = _oneCross(game);

        _score(game, HOME, AWAY);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home), "the outcome");
        (bool ok, bytes memory err) = _tryClaim(takingAccount.a, market, Side.B);
        assertFalse(ok, "the losing side was paid");
        assertEq(
            err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector), "the losing side's refusal"
        );
        assertEq(_claim(restingAccount.a, market, Side.A), RESTING_STAKE + TAKING_STAKE, "the winner's claim");

        assertEq(
            usdc.balanceOf(restingAccount.a), FUNDED + TAKING_STAKE, "the winner: what it had, and the other stake"
        );
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED - TAKING_STAKE, "the loser: what it had, less its stake");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module, after the claim");
        assertEq(usdc.balanceOf(sender), 0, "the sender, at the end");
        assertEq(usdc.balanceOf(address(matching)), 0, "the matching module, at the end");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, at the end");
    }

    /// A Cross in Polygon's USDC on a game that is then voided: the market settles as a void, and each account
    /// claims its own stake back in the same coin, to the unit.
    function test_fork_aCrossInPolygonsUsdcPaysBothStakesBackOnAVoid() public {
        _assertTheCoinIsPolygonsUsdc();
        uint256 game = _verifiedGame();
        uint256 market = _oneCross(game);

        vm.warp(START + WINDOW);
        _voidBy(first, game);
        assertEq(uint8(_status(game)), uint8(GameStatus.Voided), "the game's status");
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Void), "the outcome");
        assertEq(_claim(restingAccount.a, market, Side.A), RESTING_STAKE, "the resting account's claim");
        assertEq(usdc.balanceOf(address(positions)), TAKING_STAKE, "the positions module, between the two claims");
        assertEq(_claim(takingAccount.a, market, Side.B), TAKING_STAKE, "the taking account's claim");

        assertEq(usdc.balanceOf(restingAccount.a), FUNDED, "the resting account: what it had");
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED, "the taking account: what it had");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module, after the claims");
        assertEq(usdc.balanceOf(sender), 0, "the sender, at the end");
        assertEq(usdc.balanceOf(address(matching)), 0, "the matching module, at the end");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, at the end");
    }
}
