// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GameStatus, Hint, IOspexGames} from "../../src/games/IOspexGames.sol";
import {OspexSignpost} from "../../src/signpost/OspexSignpost.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";
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

/// @notice The courier relay's sender, set through the live Polygon timelock, on the games set the signpost names.
///         A second betting set is deployed on Polygon's USDC against the live games contract, with the cap left
///         in force, and a relay on its matching module, so that the relay's timelock is the live one. Two funded
///         accounts register the relay; a one-cent Cross from the key fills in USDC; K, the key that holds the
///         live timelock's proposer role, schedules the new sender at the delay read from the timelock; before
///         the delay it does not run; a stranger runs it after; the old key, K and a stranger are refused at the
///         relay; and the new key's Cross fills in USDC for the same two accounts, who made no call in between.
///         This reads one block of Polygon: it does not show today's roles or delay. Skipped without
///         POLYGON_RPC_URL, and a skip is not a pass.
contract OspexRelayForkTest is CrossBase {
    uint256 internal constant FORK_BLOCK = 96_885_149;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    /// @dev The signpost; the Polygon timelock, a contract, which the signpost, the games set, the matching module
    ///      and the relay answer to; and K, the key that holds that timelock's proposer role. Three addresses with
    ///      the relay's key: K schedules, the timelock calls, the key sends.
    address internal constant SIGNPOST = 0x6A487d62aA9D803cF465F3d8fcF363d6cEb1602A;
    address internal constant TIMELOCK = 0x8CED8e82cf1488B7365C0726aEeD795b6C07582C;
    address internal constant K = 0x3BD1e22Dc38376b776072a20c581DDb716e21d8E;
    uint256 internal constant FUNDED = 50_000_000;
    bytes32 internal constant SENDER_SET_TOPIC = keccak256("SenderSet(address,address)");

    IERC20 internal usdc = IERC20(USDC);
    IOspexGames internal liveGames;
    OspexCourierRelay internal relay;
    address internal courierKey = makeAddr("the courier's key on the fork");
    address internal newKey = makeAddr("the courier's next key on the fork");
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
        assertGt(entry.contracts.length, 0, "the entry names no contract");
        liveGames = IOspexGames(entry.contracts[0]);
        assertGt(entry.contracts[0].code.length, 0, "the games contract the entry names has no code");

        // The betting set on Polygon's USDC against that games set, the cap in force, and the relay on its
        // matching module: each read the live timelock at its deploy.
        _deploySetWith(address(liveGames), USDC);
        assertEq(matching.i_timelock(), TIMELOCK, "the matching module's timelock is not the live one");
        assertFalse(matching.s_takingStakeCapLifted(), "the cap was lifted at deploy");
        vm.prank(deployer, deployer);
        relay = new OspexCourierRelay(address(matching), courierKey);
        assertEq(relay.i_timelock(), TIMELOCK, "the relay's timelock is not the live one");
        assertEq(relay.i_matching(), address(matching), "the relay's target");
        assertEq(relay.s_sender(), courierKey, "the relay's first sender");

        (restingAccount.a, restingAccount.key) = makeAddrAndKey("resting account behind the relay");
        (takingAccount.a, takingAccount.key) = makeAddrAndKey("taking account behind the relay");
        uint256 held = usdc.balanceOf(HOLDER);
        _fundWithUsdc(restingAccount.a);
        _fundWithUsdc(takingAccount.a);
        holderLeft = usdc.balanceOf(HOLDER);
        assertEq(held - holderLeft, 2 * FUNDED, "the holder paid exactly the two fundings");
        _register(restingAccount.a, address(relay));
        _register(takingAccount.a, address(relay));
    }

    function _fundWithUsdc(address who) internal {
        assertEq(usdc.balanceOf(who), 0, "the account held the coin before it was funded");
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(who, FUNDED), "the funding transfer");
        vm.prank(who);
        assertTrue(usdc.approve(address(positions), type(uint256).max), "the approval");
        assertEq(usdc.balanceOf(who), FUNDED, "the funded balance");
    }

    /// @dev `from` sends a Cross to the relay, as caller and origin, with the result.
    function _tryThroughRelay(
        address from,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting
    ) internal returns (bool ok, bytes memory out) {
        vm.prank(from, from);
        (ok, out) = address(relay).call(abi.encodeCall(OspexMatching.cross, (taking, resting)));
    }

    /// @dev What the two accounts registered: the relay, and neither key.
    function _assertRegistrations(string memory when) internal view {
        assertTrue(matching.isCourier(restingAccount.a, address(relay)), string.concat(when, ": the resting account"));
        assertTrue(matching.isCourier(takingAccount.a, address(relay)), string.concat(when, ": the taking account"));
        assertFalse(matching.isCourier(restingAccount.a, courierKey), string.concat(when, ": the old key, resting"));
        assertFalse(matching.isCourier(takingAccount.a, courierKey), string.concat(when, ": the old key, taking"));
        assertFalse(matching.isCourier(restingAccount.a, newKey), string.concat(when, ": the new key, resting"));
        assertFalse(matching.isCourier(takingAccount.a, newKey), string.concat(when, ": the new key, taking"));
    }

    function test_fork_theLiveTimelockSetsTheRelaysSender() public {
        assertEq(block.chainid, 137, "the chain");
        assertEq(address(core.i_games()), address(liveGames), "the core's games set");
        assertEq(address(core.i_token()), USDC, "the core's coin");
        TimelockController live = TimelockController(payable(TIMELOCK));
        assertTrue(live.hasRole(live.PROPOSER_ROLE(), K), "K does not hold the live timelock's proposer role");
        assertFalse(live.hasRole(live.PROPOSER_ROLE(), stranger), "the stranger holds the proposer role");
        assertFalse(live.hasRole(live.PROPOSER_ROLE(), courierKey), "the key holds the proposer role");
        assertTrue(K != TIMELOCK && K != courierKey && courierKey != TIMELOCK, "the three addresses are not apart");
        _assertRegistrations("before the rotation");

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

        // One cent at 1.90 against 10,000 resting at 2.10, through the relay from the key: 9,000 against 9,900.
        OspexMatching.SignedOrder memory resting = _rest(restingAccount, game, Side.A, 210, 10_000);
        OspexMatching.SignedOrder memory taking = _take(takingAccount, game, Side.B, 190, 10_000);
        (bool ok, bytes memory out) = _tryThroughRelay(courierKey, taking, _list(resting));
        assertTrue(ok, string.concat("the key's Cross was refused: ", vm.toString(out)));
        uint256 market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(_filled(resting), 9_000, "the resting order, filled");
        assertEq(_filled(taking), 9_900, "the cent, filled");
        assertEq(usdc.balanceOf(restingAccount.a), restingHas - 9_000, "the resting account, after the cent");
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED - 9_900, "the taking account, after the cent");
        assertEq(usdc.balanceOf(address(positions)), 18_900, "the positions module, after the cent");
        _assertPosition(market, restingAccount.a, Side.A, 9_000, 9_900, "the resting position");
        _assertPosition(market, takingAccount.a, Side.B, 9_900, 9_000, "the taking position");

        // The rotation, through the live timelock. K's own call is refused; K schedules it at the delay the
        // timelock answers; before the delay it does not run.
        uint256 delay = live.getMinDelay();
        assertGt(delay, 0, "the live timelock's delay");
        bytes memory toNew = abi.encodeCall(OspexCourierRelay.setSender, (newKey));
        bytes32 s = keccak256("the relay's sender, rehearsed on a fork");
        vm.prank(K, K);
        (ok, out) = address(relay).call(toNew);
        assertFalse(ok, "K set the sender without the timelock");
        assertEq(
            out, abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheTimelock.selector, K), "K's own call"
        );
        vm.prank(K);
        live.schedule(address(relay), 0, toNew, bytes32(0), s, delay);
        bytes32 id = live.hashOperation(address(relay), 0, toNew, bytes32(0), s);
        assertTrue(live.isOperationPending(id), "the rotation is not pending");
        vm.prank(stranger);
        (ok,) =
            address(live).call(abi.encodeCall(TimelockController.execute, (address(relay), 0, toNew, bytes32(0), s)));
        assertFalse(ok, "the rotation ran before the delay");
        assertEq(relay.s_sender(), courierKey, "the sender moved before the delay");

        // The delay passes; a stranger runs it; the relay's one log names the two keys, and no account's
        // registration moved.
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.recordLogs();
        vm.prank(stranger);
        live.execute(address(relay), 0, toNew, bytes32(0), s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 ofRelay;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(relay)) {
                assertEq(logs[i].emitter, TIMELOCK, "the rotation made another contract emit");
                continue;
            }
            ++ofRelay;
            assertEq(logs[i].topics[0], SENDER_SET_TOPIC, "the relay's log of the rotation");
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(courierKey))), "the rotation's previous sender");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(newKey))), "the rotation's current sender");
        }
        assertEq(ofRelay, 1, "the relay's logs of the rotation");
        assertEq(relay.s_sender(), newKey, "the live timelock did not set the sender");
        assertTrue(live.isOperationDone(id), "the rotation is not done");
        _assertRegistrations("after the rotation");

        // After it: the old key, K and a stranger are refused at the relay, and the new key's Cross fills in USDC
        // for the same two accounts, to the unit.
        resting = _rest(restingAccount, game, Side.A, 210, 10_000);
        taking = _take(takingAccount, game, Side.B, 190, 10_000);
        address[3] memory refusedNow = [courierKey, K, stranger];
        for (uint256 i; i < refusedNow.length; ++i) {
            (ok, out) = _tryThroughRelay(refusedNow[i], taking, _list(resting));
            assertFalse(ok, string.concat("after the rotation the relay passed ", vm.toString(refusedNow[i])));
            assertEq(
                out,
                abi.encodeWithSelector(OspexCourierRelay.OspexCourierRelay__NotTheSender.selector, refusedNow[i]),
                "the refusal after the rotation"
            );
        }
        (ok, out) = _tryThroughRelay(newKey, taking, _list(resting));
        assertTrue(ok, string.concat("the new key's Cross was refused: ", vm.toString(out)));
        assertEq(_filled(resting), 9_000, "the resting order, filled through the new key");
        assertEq(_filled(taking), 9_900, "the cent, filled through the new key");
        assertEq(usdc.balanceOf(restingAccount.a), restingHas - 18_000, "the resting account, at the end");
        assertEq(usdc.balanceOf(takingAccount.a), FUNDED - 19_800, "the taking account, at the end");
        assertEq(usdc.balanceOf(address(positions)), 37_800, "the positions module, at the end");
        _assertPosition(market, restingAccount.a, Side.A, 18_000, 19_800, "the resting position, at the end");
        _assertPosition(market, takingAccount.a, Side.B, 19_800, 18_000, "the taking position, at the end");
        assertEq(usdc.balanceOf(address(relay)), 0, "the relay, at the end");
        assertEq(usdc.balanceOf(courierKey), 0, "the old key, at the end");
        assertEq(usdc.balanceOf(newKey), 0, "the new key, at the end");
        assertEq(usdc.balanceOf(address(matching)), 0, "the matching module, at the end");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, at the end");
    }
}

/// @dev Polygon's USDC, the two controls the fork tests exercise: its blacklister blocks an address, and its
///      pauser pauses every transfer. The functions of Circle's FiatToken that the tests call.
interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
    function pauser() external view returns (address);
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

/// @notice Shared collateral with the coin the set is to be deployed with: the betting set on Polygon's USDC, on a
///         fork of Polygon mainnet at FORK_BLOCK, the games set the test base's own. USDC's real behaviour on a
///         pay-back: its blacklister blocks an account between two fills, and the second fill, which lowers that
///         account's worst loss, completes with the pay-back refused and recorded; unblocked, a third fill pays
///         it. And its pauser pauses at the claim, which reverts and pays after the unpause. Every balance is
///         asserted to the unit. These tests need POLYGON_RPC_URL; without it (CI has no RPC) they are skipped,
///         which is how a run reports that no fork was used.
contract OspexSharedCollateralForkTest is CrossBase {
    uint256 internal constant FORK_BLOCK = 96_885_149;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant HOLDER = 0x16Dc5D67D080a5521ef2c79680dBfC2aBf724D30;
    uint256 internal constant FUNDED = 50_000_000;
    bytes32 internal constant PAY_BACK_REFUSED_TOPIC = keccak256("PayBackRefused(uint256,address,uint256,uint256)");

    IERC20 internal usdc = IERC20(USDC);
    IFiatToken internal fiat = IFiatToken(USDC);
    Signer internal R;
    Signer internal K;
    uint256 internal holderLeft;

    function setUp() public override {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        super.setUp();
        _deploySetOn(USDC);
        assertTrue(matching.s_takingStakeCapLifted(), "the cap was not lifted for the USDC Crosses");
        (R.a, R.key) = makeAddrAndKey("the resting account on the fork");
        (K.a, K.key) = makeAddrAndKey("the taking account on the fork");
        uint256 held = usdc.balanceOf(HOLDER);
        _fundWithUsdc(R.a);
        _fundWithUsdc(K.a);
        holderLeft = usdc.balanceOf(HOLDER);
        assertEq(held - holderLeft, 2 * FUNDED, "the holder paid exactly the two fundings");
        _register(R.a, sender);
        _register(K.a, sender);
        assertTrue(fiat.blacklister() != address(0), "USDC names no blacklister at the fork block");
        assertTrue(fiat.pauser() != address(0), "USDC names no pauser at the fork block");
        assertFalse(fiat.paused(), "USDC is paused at the fork block");
    }

    function _fundWithUsdc(address who) internal {
        assertEq(usdc.balanceOf(who), 0, "the account held the coin before it was funded");
        vm.prank(HOLDER);
        assertTrue(usdc.transfer(who, FUNDED), "the funding transfer");
        vm.prank(who);
        assertTrue(usdc.approve(address(positions), type(uint256).max), "the approval");
        assertEq(usdc.balanceOf(who), FUNDED, "the funded balance");
    }

    /// @dev The first fill of both tests: the resting account's 10 USDC on side A at 2.10 against the taking
    ///      account's 11 USDC on side B; held 10 and 11.
    function _firstFill(uint256 game) internal returns (uint256 market) {
        _cross(sender, _take(K, game, Side.B, 190, 11_000_000), _list(_rest(R, game, Side.A, 210, 10_000_000)));
        market = markets.getMarketId(game, address(moneyline), 0);
        assertEq(positions.s_held(market, R.a), 10_000_000, "the resting account's held amount after fill 1");
        assertEq(positions.s_held(market, K.a), 11_000_000, "the taking account's held amount after fill 1");
        assertEq(usdc.balanceOf(address(positions)), 21_000_000, "the positions module after fill 1");
    }

    /// How many PayBackRefused the positions module emitted among the logs, and the amount of the last.
    function _refusalsOf(Vm.Log[] memory logs) internal view returns (uint256 n, uint256 amount, uint256 held) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(positions) && logs[i].topics[0] == PAY_BACK_REFUSED_TOPIC) {
                ++n;
                (amount, held) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    /// USDC's blacklister blocks the resting account between two fills. The second fill, 5 USDC on the other
    /// side at 2.10, lowers that account's worst loss from 10 to 4.5: its pay-back of 5.5 is refused by the real
    /// coin and recorded, the Cross completes, and the taking account's 5 is paid. Unblocked, a third fill of 1
    /// USDC pays the resting account 6.6, its excess then; settled home, it is paid the 8.4 it holds plus its net.
    function test_fork_usdcBlocksAnAccountBetweenTwoFillsAndThePayBackWaitsForTheUnblock() public {
        uint256 game = _verifiedGame();
        uint256 market = _firstFill(game);

        vm.prank(fiat.blacklister());
        fiat.blacklist(R.a);
        assertTrue(fiat.isBlacklisted(R.a), "the resting account was not blocked");

        vm.recordLogs();
        _cross(sender, _take(K, game, Side.A, 190, 5_500_000), _list(_rest(R, game, Side.B, 210, 5_000_000)));
        (uint256 n, uint256 amount, uint256 held) = _refusalsOf(vm.getRecordedLogs());
        assertEq(n, 1, "one refusal");
        assertEq(amount, 5_500_000, "the refused pay-back: 10 held against a worst loss of 4.5");
        assertEq(held, 10_000_000, "what stays held");
        assertEq(usdc.balanceOf(R.a), FUNDED - 10_000_000, "the blocked account's coin did not move");
        assertEq(usdc.balanceOf(K.a), FUNDED - 11_000_000 + 5_000_000, "the taking account was paid 5 back");
        assertEq(positions.s_held(market, R.a), 10_000_000, "the refused amount stays held");
        assertEq(positions.s_held(market, K.a), 6_000_000, "the taking account's held amount");
        assertEq(positions.s_heldTotal(market), 16_000_000, "the total");
        assertEq(usdc.balanceOf(address(positions)), 16_000_000, "the positions module holds the total");

        vm.prank(fiat.blacklister());
        fiat.unBlacklist(R.a);
        assertFalse(fiat.isBlacklisted(R.a), "the resting account is still blocked");
        vm.recordLogs();
        _cross(sender, _take(K, game, Side.A, 190, 1_100_000), _list(_rest(R, game, Side.B, 210, 1_000_000)));
        (n,,) = _refusalsOf(vm.getRecordedLogs());
        assertEq(n, 0, "a refusal after the unblock");
        assertEq(usdc.balanceOf(R.a), FUNDED - 10_000_000 + 6_600_000, "the resting account, paid its excess, 6.6");
        assertEq(usdc.balanceOf(K.a), FUNDED - 11_000_000 + 5_000_000 + 1_000_000, "the taking account, paid 1");
        assertEq(positions.s_held(market, R.a), 3_400_000, "the resting account holds its worst loss, 10 less 6.6");
        assertEq(positions.s_held(market, K.a), 5_000_000, "the taking account holds its worst loss");
        assertEq(positions.s_heldTotal(market), 8_400_000, "the total");
        assertEq(usdc.balanceOf(address(positions)), 8_400_000, "the positions module holds the total");

        // Home: the resting account wins 11 on side A and loses 6 on side B, 5 up, paid 8.4 on its side A record;
        // the taking account's net is the 5 it holds, lost.
        _score(game, HOME, AWAY);
        _settle(market);
        assertEq(uint8(_outcome(market)), uint8(Outcome.Home), "the outcome");
        vm.prank(stranger, stranger);
        assertEq(positions.claimPositionFor(market, R.a, Side.A), 8_400_000, "the resting account's whole amount");
        (bool ok, bytes memory err) = _tryClaim(K.a, market, Side.B);
        assertFalse(ok, "the taking account was paid");
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector));
        (ok, err) = _tryClaim(K.a, market, Side.A);
        assertFalse(ok, "the taking account's side A record was paid");
        assertEq(err, abi.encodeWithSelector(OspexPositions.OspexPositions__NoPayout.selector));
        assertEq(usdc.balanceOf(R.a), FUNDED + 5_000_000, "the resting account: 5 up");
        assertEq(usdc.balanceOf(K.a), FUNDED - 5_000_000, "the taking account: 5 down");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module, at the end");
        assertEq(usdc.balanceOf(sender), 0, "the sender, at the end");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, at the end");
    }

    /// USDC's pauser pauses at the claim: the claim reverts, the record stays unclaimed and the total unmoved;
    /// after the unpause the same claim pays 21 USDC.
    function test_fork_usdcPausedAtTheClaimRevertsAndTheClaimPaysAfterTheUnpause() public {
        uint256 game = _verifiedGame();
        uint256 market = _firstFill(game);
        _score(game, HOME, AWAY);
        _settle(market);

        vm.prank(fiat.pauser());
        fiat.pause();
        assertTrue(fiat.paused(), "USDC was not paused");
        vm.prank(stranger, stranger);
        (bool ok,) = address(positions).call(abi.encodeCall(OspexPositions.claimPositionFor, (market, R.a, Side.A)));
        assertFalse(ok, "paid while the coin was paused");
        assertFalse(_position(market, R.a, Side.A).claimed, "marked while unpaid");
        assertEq(positions.s_heldTotal(market), 21_000_000, "the total moved for a refused claim");
        assertEq(usdc.balanceOf(R.a), FUNDED - 10_000_000, "the resting account's coin moved");

        vm.prank(fiat.pauser());
        fiat.unpause();
        assertFalse(fiat.paused(), "USDC is still paused");
        vm.prank(stranger, stranger);
        assertEq(positions.claimPositionFor(market, R.a, Side.A), 21_000_000, "the same claim, after the unpause");
        assertEq(usdc.balanceOf(R.a), FUNDED + 11_000_000, "the winner: what it had, and the other stake");
        assertEq(usdc.balanceOf(K.a), FUNDED - 11_000_000, "the loser: what it had, less its stake");
        assertEq(positions.s_heldTotal(market), 0, "the total after the claim");
        assertEq(usdc.balanceOf(address(positions)), 0, "the positions module, at the end");
        assertEq(usdc.balanceOf(HOLDER), holderLeft, "the holder, at the end");
    }
}
