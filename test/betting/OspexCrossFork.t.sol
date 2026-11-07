// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GameStatus, Hint, IOspexGames} from "../../src/games/IOspexGames.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {CrossBase} from "./CrossBase.sol";

/// @notice The Cross with the coin the set is to be deployed with: the betting set on Polygon's USDC, on a fork
///         of Polygon mainnet at FORK_BLOCK. Two accounts are funded with that coin by a transfer from an
///         address that holds it at the fork block; a sender both have registered sends one Cross; the market
///         is settled; and the claims are paid in the same coin. Every balance is asserted to the unit. The
///         games set under the betting set is the test base's own, deployed on the fork, so that a game can be
///         scored and voided here, and the cap on a taking order's signed stake is lifted the way it is lifted
///         live, through the test base's stock timelock, since both Crosses here are of 11 USDC. These tests need
///         POLYGON_RPC_URL; without it (CI has no RPC) they are skipped, which is how a run reports that no fork
///         was used.
contract OspexCrossForkTest is CrossBase {
    /// @dev A block after the games set's entry on the signpost: the signpost lists the games set, and its
    ///      timelock's delay is a minute.
    uint256 internal constant FORK_BLOCK = 96_885_149;
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
        // The betting set again, this time on Polygon's USDC, its cap lifted through the stock timelock.
        _deploySetOn(USDC);
        assertTrue(matching.s_takingStakeCapLifted(), "the cap was not lifted for the 11 USDC Crosses");
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

/// @notice The cap's switch through the live Polygon timelock, on the games set the signpost names. A second
///         betting set is deployed on Polygon's USDC against the games contract at the signpost's games entry,
///         so that its matching module reads the live timelock at its deploy; a game is created on that games
///         set for its fee, and, unverified, it takes fills; one cent fills; 10,100 is refused; K schedules the
///         lift on the live timelock at its delay, the delay passes, a stranger runs it; and 10,100 fills in
///         USDC, every balance to the unit. "Live" is the deployed code the entry names, whose status is
///         Building: nothing here asks the signpost for a live status. Skipped without POLYGON_RPC_URL.
contract OspexCapForkTest is CrossBase {
    uint256 internal constant FORK_BLOCK = 96_885_149;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @dev The signpost, the Polygon timelock it and the games set answer to, and the key that holds it.
    address internal constant SIGNPOST = 0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A;
    address internal constant TIMELOCK = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;
    address internal constant K = 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E;
    uint256 internal constant FUNDED = 50_000_000;
    uint256 internal constant CAP = 10_000;

    IERC20 internal usdc = IERC20(USDC);
    IOspexGames internal liveGames;
    Signer internal restingAccount;
    Signer internal takingAccount;
    uint256 internal holderLeft;

    function setUp() public override {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        liftAtDeploy = false;
        super.setUp();

        // The games set the signpost names, at its games entry, and the timelock both answer to.
        OspexSignpost signpost = OspexSignpost(SIGNPOST);
        assertEq(signpost.i_timelock(), TIMELOCK, "the signpost's timelock");
        OspexSignpost.Entry memory entry = signpost.getEntry(1);
        assertEq(uint8(entry.kind), uint8(OspexSignpost.Kind.Games), "the entry's kind");
        assertEq(uint8(entry.status), uint8(OspexSignpost.Status.Building), "the entry's status");
        assertGt(entry.contracts.length, 0, "the entry names no contract");
        liveGames = IOspexGames(entry.contracts[0]);
        assertGt(entry.contracts[0].code.length, 0, "the games contract the entry names has no code");

        // The betting set on Polygon's USDC against that games set, with the cap in force: its matching module
        // read the live timelock at its deploy.
        _deploySetWith(address(liveGames), USDC);
        assertEq(matching.i_timelock(), TIMELOCK, "the matching module's timelock is not the live one");
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at deploy");

        (restingAccount.a, restingAccount.key) = makeAddrAndKey("resting account on the live games set");
        (takingAccount.a, takingAccount.key) = makeAddrAndKey("taking account on the live games set");
        uint256 held = usdc.balanceOf(HOLDER);
        _fundWithUsdc(restingAccount.a);
        _fundWithUsdc(takingAccount.a);
        holderLeft = usdc.balanceOf(HOLDER);
        assertEq(held - holderLeft, 2 * FUNDED, "the holder paid exactly the two fundings");
        _register(restingAccount.a, sender);
        _register(takingAccount.a, sender);
    }

    function _fundWithUsdc(address who) internal {
        assertEq(usdc.balanceOf(who), 0, "the account held the coin before it was funded");
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(who, FUNDED), "the funding transfer");
        vm.prank(who);
        assertTrue(usdc.approve(address(positions), type(uint256).max), "the approval");
        assertEq(usdc.balanceOf(who), FUNDED, "the funded balance");
    }

    function test_fork_theLiveTimelockLiftsTheCapOnTheLiveGamesSet() public {
        assertEq(block.chainid, 137, "the chain");
        assertEq(address(core.i_games()), address(liveGames), "the core's games set");
        assertEq(address(core.i_token()), USDC, "the core's coin");

        // A game on the live games set, created for its fee by the resting account: unverified, so it fills.
        uint256 fee = liveGames.getTerms("nba").fee;
        vm.startPrank(restingAccount.a);
        assertTrue(usdc.approve(address(liveGames), fee), "the fee's approval");
        uint256 game = liveGames.createGame(
            "nba", "Home Team", "Away Team", uint64(vm.getBlockTimestamp() + 1 days), new Hint[](0), fee
        );
        vm.stopPrank();
        assertEq(uint8(liveGames.getGameStatus(game)), uint8(GameStatus.Unverified), "the game's status");
        uint256 restingHas = FUNDED - fee;
        assertEq(usdc.balanceOf(restingAccount.a), restingHas, "the resting account, after the fee");

        // One cent at 1.90 against 10,000 resting at 2.10: 90 lots, 9,000 against 9,900.
        OspexMatching.SignedOrder memory resting = _rest(restingAccount, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory taking = _take(takingAccount, game, Side.B, 190, CAP);
        _cross(sender, taking, _list(resting));
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(_filled(resting), 9_000, "the resting order, filled");
        assertEq(_filled(taking), 9_900, "the cent, filled");
        assertEq(usdc.balanceOf(restingAccount.a), restingHas - 9_000, "the resting account, after the cent");
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED - 9_900, "the taking account, after the cent");
        assertEq(usdc.balanceOf(address(positions)), 18_900, "the positions module, after the cent");
        _assertPosition(market, restingAccount.a, Side.A, 9_000, 9_900, "the resting position");
        _assertPosition(market, takingAccount.a, Side.B, 9_900, 9_000, "the taking position");

        // 10,100 is refused by name before the lift, and nothing moves.
        OspexMatching.SignedOrder memory above = _take(takingAccount, game, Side.B, 200, 10_100);
        _refused(
            sender,
            above,
            _list(_rest(restingAccount, game, Side.A, 200, 10_100)),
            _refusal(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, above),
            "10,100 before the lift"
        );
        assertEq(usdc.balanceOf(address(positions)), 18_900, "the positions module, after the refusal");

        // The lift, through the live timelock: K schedules it at the delay, the delay passes, a stranger runs it.
        TimelockController live = TimelockController(payable(TIMELOCK));
        uint256 delay = live.getMinDelay();
        bytes memory lift = abi.encodeCall(OspexMatching.liftTakingStakeCap, ());
        bytes32 s = keccak256("the lift, rehearsed on a fork");
        vm.prank(K);
        live.schedule(address(matching), 0, lift, bytes32(0), s, delay);
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at the schedule");
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(stranger);
        live.execute(address(matching), 0, lift, bytes32(0), s);
        assertTrue(matching.s_takingStakeCapLifted(), "the live timelock did not lift the cap");

        // 10,100 at 2.00 against 10,100 fills in USDC, to the unit.
        above = _take(takingAccount, game, Side.B, 200, 10_100);
        resting = _rest(restingAccount, game, Side.A, 200, 10_100);
        _cross(sender, above, _list(resting));
        assertEq(_filled(above), 10_100, "10,100, filled after the lift");
        assertEq(_filled(resting), 10_100, "the resting 10,100, filled");
        assertEq(usdc.balanceOf(restingAccount.a), restingHas - 9_000 - 10_100, "the resting account, at the end");
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED - 9_900 - 10_100, "the taking account, at the end");
        assertEq(usdc.balanceOf(address(positions)), 18_900 + 20_200, "the positions module, at the end");
        assertEq(usdc.balanceOf(sender), 0, "the sender, at the end");
        assertEq(usdc.balanceOf(address(matching)), 0, "the matching module, at the end");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, at the end");
    }
}
