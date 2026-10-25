// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames, GameStatus, ReporterKind, ReportKind, Report, Hint} from "../../src/games/IOspexGames.sol";
import {IOspexReporter} from "../../src/games/IOspexReporter.sol";
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";
import {TrickCoin} from "./CoinFixtures.sol";

/// @dev An address that acts on its own and, when a coin calls it back, makes the calls it was queued, once and
///      in order. A queued call marked `must` passes its refusal on, so the transfer that called back fails with
///      it; any other records its answer. It also has the fixed-values read, so the games set can approve it as
///      a reporter.
contract Actor is IOspexReporter {
    struct Step {
        address target;
        bytes data;
        bool must;
    }

    Step[] internal s_steps;
    bool public armed;
    bool[] internal s_oks;
    bytes[] internal s_answers;

    function fixedValues() external pure returns (bytes memory) {
        return abi.encode(bytes32("an actor"));
    }

    /// @dev One call, as this address. A refusal is passed on.
    function act(address target, bytes calldata data) external returns (bytes memory answer) {
        bool ok;
        (ok, answer) = target.call(data);
        if (!ok) _bubble(answer);
    }

    function queue(address target, bytes calldata data, bool must) external {
        s_steps.push(Step(target, data, must));
        armed = true;
    }

    function clear() external {
        delete s_steps;
        armed = false;
    }

    function onCoin() external {
        if (!armed) return;
        armed = false;
        uint256 n = s_steps.length;
        for (uint256 i; i < n; ++i) {
            Step memory s = s_steps[i];
            (bool ok, bytes memory answer) = s.target.call(s.data);
            if (!ok && s.must) _bubble(answer);
            s_oks.push(ok);
            s_answers.push(answer);
        }
        delete s_steps;
    }

    function answerCount() external view returns (uint256) {
        return s_oks.length;
    }

    function answerAt(uint256 i) external view returns (bool, bytes memory) {
        return (s_oks[i], s_answers[i]);
    }

    function _bubble(bytes memory answer) private pure {
        assembly ("memory-safe") {
            revert(add(answer, 32), mload(answer))
        }
    }
}

/// @notice The creation fee under coins that do what USDC does not: keep a cut, charge the sender more, refund
///         some of a transfer, or call back into the games set in the middle of one. One creation or withdrawal
///         runs at a time, so no transfer's change in the balance is counted for another, and each balance
///         check sees its own transfer. Then two sequences that cross calls: a credit, then its address
///         approved as a reporter, then its withdrawal; and a withdrawal whose payment calls back to score
///         another game, withdraw and create, each tried inside the payment and again after it.
contract OspexGamesFeeCallbacksTest is GamesBase {
    TrickCoin internal coin;
    OspexGamesHarness internal g;
    /// @dev The games set's only reporter, first-n.
    MockReporter internal r;
    /// @dev The refusal of a creation or a withdrawal begun while one is running.
    bytes internal locked = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    function setUp() public override {
        super.setUp();
        coin = new TrickCoin();
        r = new MockReporter(IOspexGames(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        g = new OspexGamesHarness(
            address(timelock), coin, _launchTerms(), _one(address(r)), _kinds1(ReporterKind.FirstN), _hashes(_one(address(r)))
        );
        assertEq(address(r.i_games()), address(g), "the reporter points at the games set");
        coin.mint(creator, PURSE);
        vm.prank(creator);
        coin.approve(address(g), type(uint256).max);
    }

    // ──────────────────────────── Inside a creation's fee pull ─────────

    /// The coin keeps a cut of the fee and, as it takes it, calls the creator back; the call back makes a
    /// second creation that pays in full. Without the lock, the one rise in the balance answers both checks:
    /// two games hold more than arrived. Two ways: the coin keeps all of the fee and the call back turns the cut
    /// off and creates again from the same address; the coin keeps a tenth and an exempt sponsor creates a game
    /// whose fee is that tenth. The second creation is refused, and so the first: no game, no coin moved.
    /// Controls: the cut alone is refused by its own check, and with no cut and no call back the creation is
    /// made.
    /// Break: in createGame(), delete `nonReentrant`. Each way then makes two games on one fee's arrival.
    function test_create_aCreationInsideAFeePullIsRefused() public {
        Actor maker = _actor("maker");
        Actor sponsor = _actor("sponsor");
        address[] memory watched = _two(address(maker), address(sponsor));
        bytes32 money = _coinOf(watched);

        // All of the fee kept; the call back turns the cut off and creates again.
        coin.setCut(FEE);
        coin.setHooked(address(maker), true);
        maker.queue(address(coin), abi.encodeCall(TrickCoin.setCut, (0)), true);
        maker.queue(address(g), _createCall("nba", FEE), true);
        vm.expectRevert(locked);
        maker.act(address(g), _createCall("nba", FEE));
        assertEq(g.gameCount(), 0, "a game was made");
        assertEq(_coinOf(watched), money, "coin moved");

        // A tenth kept; an exempt sponsor creates a game whose fee is that tenth.
        maker.clear();
        _setTermsOn("nhl", FEE / 10);
        coin.setCut(FEE / 10);
        coin.setExempt(address(sponsor), true);
        maker.queue(address(sponsor), abi.encodeCall(Actor.act, (address(g), _createCall("nhl", FEE / 10))), true);
        vm.expectRevert(locked);
        maker.act(address(g), _createCall("nba", FEE));
        assertEq(g.gameCount(), 0, "a game was made");
        assertEq(_coinOf(watched), money, "coin moved");

        // Controls.
        maker.clear();
        coin.setHooked(address(maker), false);
        vm.expectRevert(
            abi.encodeWithSelector(OspexGames.OspexGames__FeeNotReceived.selector, uint256(FEE), 0, uint256(FEE) - FEE / 10)
        );
        maker.act(address(g), _createCall("nba", FEE));
        coin.setCut(0);
        maker.act(address(g), _createCall("nba", FEE));
        assertEq(g.gameCount(), 1, "control: the game is made");
        assertEq(coin.balanceOf(address(g)), FEE, "control: its fee arrived");
    }

    // ──────────────────────────── Inside a withdrawal's payment ────────

    /// A coin that charges the games set a fee's worth more than it pays, and calls the payee back, which
    /// creates a game: without the lock, the new fee's arrival would make up the charge, and the withdrawal's
    /// balance check would pass with another's credit spent. The creation is refused, and so the withdrawal:
    /// the credit stays and nothing moves. Control: with the charge and the call back gone, both credits are
    /// withdrawn whole.
    /// Break: in withdraw(), delete `nonReentrant`. The withdrawal is then taken, and the games set holds a
    /// fee less than it owes.
    function test_withdraw_aCreationInsideAPaymentIsRefused() public {
        Actor payee = _actor("payee");
        (uint256 a, uint256 b) = (_createOn(), _createOn());
        _startAndScore(a, address(payee));
        _startAndScore(b, payout);
        address[] memory watched = _two(address(payee), payout);
        bytes32 money = _coinOf(watched);

        coin.setCharge(FEE);
        coin.setHooked(address(payee), true);
        payee.queue(address(g), _createCall("nba", FEE), true);
        vm.expectRevert(locked);
        payee.act(address(g), abi.encodeCall(IOspexGames.withdraw, ()));
        assertEq(g.getCredit(address(payee)), FEE, "the credit stays");
        assertEq(g.gameCount(), 2, "a game was made");
        assertEq(coin.balanceOf(address(g)), 2 * uint256(FEE), "the games set's coin moved");
        assertEq(_coinOf(watched), money, "coin moved");

        payee.clear();
        coin.setHooked(address(payee), false);
        coin.setCharge(0);
        payee.act(address(g), abi.encodeCall(IOspexGames.withdraw, ()));
        vm.prank(payout);
        g.withdraw();
        assertEq(coin.balanceOf(address(g)), 0, "control: both credits withdrawn whole");
    }

    /// A coin that takes more from the games set than it pays, or less, on a withdrawal: refused by name, with
    /// the balance on each side, and the credit stays. Two credits of a fee each: charged 1 unit more, the
    /// withdrawal would have taken a unit of the other's; refunded 1 unit, the games set would keep a unit no
    /// one is owed. Control: with neither, both are withdrawn whole.
    /// Break: in withdraw(), delete the `if (balanceAfter + amount != balanceBefore)` check. The charged
    /// withdrawal is then taken, and the other credit can no longer be paid in full.
    function test_withdraw_aCoinThatTakesMoreOrLessThanItPaysIsRefused() public {
        address other = makeAddr("another payout address");
        (uint256 a, uint256 b) = (_createOn(), _createOn());
        _startAndScore(a, payout);
        _startAndScore(b, other);
        uint256 both = 2 * uint256(FEE);

        coin.setCharge(1);
        vm.prank(payout);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__WithdrawalNotExact.selector, uint256(FEE), both, uint256(FEE) - 1));
        g.withdraw();
        coin.setCharge(0);
        coin.setRefund(1);
        vm.prank(payout);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__WithdrawalNotExact.selector, uint256(FEE), both, uint256(FEE) + 1));
        g.withdraw();
        assertEq(g.getCredit(payout), FEE, "the credit stays");
        assertEq(coin.balanceOf(address(g)), both, "the games set's coin moved");

        coin.setRefund(0);
        vm.prank(payout);
        assertEq(g.withdraw(), FEE);
        vm.prank(other);
        assertEq(g.withdraw(), FEE);
        assertEq(coin.balanceOf(payout), FEE, "control: paid whole");
        assertEq(coin.balanceOf(other), FEE, "control: paid whole");
        assertEq(coin.balanceOf(address(g)), 0);
    }

    /// A coin that keeps a cut of what the games set pays, on the payee's side: the games set's balance falls
    /// by exactly the credit, so the withdrawal is taken; the payee receives the credit less the cut, and the
    /// event and the answer name the whole credit, which is what left the games set.
    function test_withdraw_aCutOnTheWayOutStillSpendsTheWholeCredit() public {
        uint256 a = _createOn();
        _startAndScore(a, payout);
        coin.setCut(7);
        vm.recordLogs();
        vm.prank(payout);
        assertEq(g.withdraw(), FEE, "the answer: the whole credit");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], IOspexGames.Withdrawn.selector);
        assertEq(abi.decode(logs[0].data, (uint256)), FEE, "the event: the whole credit");
        assertEq(coin.balanceOf(payout), uint256(FEE) - 7, "the payee received the rest");
        assertEq(coin.balanceOf(address(coin)), 7, "the coin kept its cut");
        assertEq(coin.balanceOf(address(g)), 0, "the games set paid the whole credit");
        assertEq(g.getCredit(payout), 0);
    }

    /// A coin that charges the sender: on a creation the creator is the sender, so it pays the fee and the
    /// coin's charge, and the games set's balance rises by exactly the fee, so the game is made holding it. On
    /// a withdrawal the games set is the sender, so every withdrawal is refused, and the credit stays, until
    /// the charge stops; then it is paid whole. The coin held stays what is held and credited throughout.
    function test_withdraw_underACoinThatChargesTheSenderWaitsForTheChargeToStop() public {
        coin.setCharge(1);
        uint256 paid = coin.balanceOf(creator);
        (uint256 a, uint256 b) = (_createOn(), _createOn());
        assertEq(paid - coin.balanceOf(creator), 2 * (uint256(FEE) + 1), "the creator paid the fees and the charges");
        assertEq(coin.balanceOf(address(g)), 2 * uint256(FEE), "the games set took the fees alone");
        _startAndScore(a, payout);
        _assertBooks(stranger); // the helper counts the payout address itself
        vm.prank(payout);
        vm.expectRevert(
            abi.encodeWithSelector(
                OspexGames.OspexGames__WithdrawalNotExact.selector, uint256(FEE), 2 * uint256(FEE), uint256(FEE) - 1
            )
        );
        g.withdraw();
        assertEq(g.getCredit(payout), FEE, "the credit stays");
        _assertBooks(stranger); // the helper counts the payout address itself
        coin.setCharge(0);
        vm.prank(payout);
        assertEq(g.withdraw(), FEE, "paid whole once the charge stops");
        assertEq(coin.balanceOf(payout), FEE);
        (uint96 held,) = g.getGameFee(b);
        assertEq(coin.balanceOf(address(g)), held, "the other game's fee is still held");
    }

    /// The exact check is on the balance, so it is a coin's cut alone that makes no game: a cut made up inside
    /// the pull by someone else's direct transfer leaves the balance risen by exactly the fee, and the game is
    /// made. Nothing is short: the coin held is the game's fee, paid partly by the one who made up the cut.
    function test_create_aCutMadeUpInsideThePullByAnotherIsTaken() public {
        Actor maker = _actor("maker");
        Actor donor = _actor("donor");
        coin.setCut(7);
        coin.setExempt(address(donor), true);
        coin.setHooked(address(maker), true);
        maker.queue(
            address(donor), abi.encodeCall(Actor.act, (address(coin), abi.encodeCall(IERC20.transfer, (address(g), 7)))), true
        );
        maker.act(address(g), _createCall("nba", FEE));
        assertEq(g.gameCount(), 1, "the game is made");
        assertEq(coin.balanceOf(address(g)), FEE, "the games set holds exactly its fee");
        assertEq(coin.balanceOf(address(coin)), 7, "the coin kept its cut");
        _assertBooks(address(maker));
    }

    // ──────────────────────────── A report inside a pull ───────────────

    /// The coin calls the creator back once the fee has arrived, and the call back starts and scores the game
    /// being made, then tries to withdraw and to create. The reports are taken: they move no coin. The game ends
    /// scored and its fee is credited once, to the score's payout address; the withdrawal and the creation are
    /// refused, as one creation or withdrawal runs at a time. The coin held is the one fee, now credited.
    function test_create_aPullThatEndsItsOwnGameCreditsOnce() public {
        Actor maker = _actor("maker");
        vm.warp(START + 10);
        uint256 id = g.gameCount() + 1;
        coin.setHooked(address(maker), true);
        maker.queue(address(r), abi.encodeCall(MockReporter.send, (_startReport(id, START))), true);
        maker.queue(address(r), abi.encodeCall(MockReporter.send, (_scoreReportTo(id, payout))), true);
        maker.queue(address(g), abi.encodeCall(IOspexGames.withdraw, ()), false);
        maker.queue(address(g), _createCall("nba", FEE), false);
        uint256 paid = coin.balanceOf(address(maker));

        vm.recordLogs();
        maker.act(address(g), _createCall("nba", FEE));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 credits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(g) && logs[i].topics[0] == IOspexGames.FeeCredited.selector) ++credits;
        }
        assertEq(credits, 1, "one credit");
        assertEq(uint8(g.getGameStatus(id)), uint8(GameStatus.Scored));
        assertEq(g.getCredit(payout), FEE, "the score's payout address, once");
        assertEq(paid - coin.balanceOf(address(maker)), FEE, "the creator paid the fee once");
        assertEq(coin.balanceOf(address(g)), FEE, "the coin held is the one fee");
        assertEq(maker.answerCount(), 4, "every queued call answered");
        (bool ok, bytes memory answer) = maker.answerAt(2);
        assertFalse(ok, "a withdrawal inside the pull");
        assertEq(answer, locked);
        (ok, answer) = maker.answerAt(3);
        assertFalse(ok, "a creation inside the pull");
        assertEq(answer, locked);
        assertEq(g.gameCount(), 1);
    }

    // ──────────────────────────── Two sequences across calls ───────────

    /// An address is credited as a score's payout, then approved as a reporter, then withdraws. The approval
    /// leaves the credit alone and the withdrawal pays it; from the approval on, a score naming the address is
    /// refused, a reporter now. The coin held is what is held and credited after each step.
    function test_fee_aCreditThenAnApprovalThenItsWithdrawal() public {
        Actor x = new Actor();
        uint256 a = _create();
        uint256 b = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, a, START);
        _startBy(first, b, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(a, address(x)));
        assertEq(games.getCredit(address(x)), FEE, "credited");
        _assertBooksOfGames(address(x));

        _approve(address(x), ReporterKind.AfterN);
        (ReporterKind kind,,) = games.getReporter(address(x));
        assertEq(uint8(kind), uint8(ReporterKind.AfterN), "approved");
        assertEq(games.getCredit(address(x)), FEE, "the approval left the credit");
        _assertBooksOfGames(address(x));

        assertEq(abi.decode(x.act(address(games), abi.encodeCall(IOspexGames.withdraw, ())), (uint256)), FEE);
        assertEq(token.balanceOf(address(x)), FEE, "paid");
        _assertBooksOfGames(address(x));

        (bool ok, bytes memory err) = _send(address(first), _scoreReportTo(b, address(x)));
        assertFalse(ok, "a score naming a reporter");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsAReporter.selector, ReportKind.Score, address(x)));
        _assertBooksOfGames(address(x));
    }

    /// A payee's withdrawal calls it back as the coin pays it, and the call back scores another game naming
    /// the payee, then tries to withdraw that new credit and to create a game. The score is taken, and the new
    /// credit stays whole after the first withdrawal returns; the withdrawal and the creation are refused
    /// inside the payment. After it, the same two calls are taken. The coin held is what is held and credited
    /// after each step.
    /// Break: in withdraw(), move `s_credits[msg.sender] = 0;` below the payment. The credit the call back
    /// made is then wiped as the first withdrawal finishes, and that game's fee is held by no one.
    function test_fee_aPaymentThatCallsBackScoresAnotherGameAndTheRestWaitsForIt() public {
        Actor x = _actor("payee");
        (uint256 a, uint256 b) = (_createOn(), _createOn());
        _startAndScore(a, address(x));
        _startOn(b);
        vm.warp(START + 10);
        _assertBooks(address(x));

        coin.setHooked(address(x), true);
        x.queue(address(r), abi.encodeCall(MockReporter.send, (_scoreReportTo(b, address(x)))), false);
        x.queue(address(g), abi.encodeCall(IOspexGames.withdraw, ()), false);
        x.queue(address(g), _createCall("nba", FEE), false);
        uint256 coinBefore = coin.balanceOf(address(x));
        assertEq(abi.decode(x.act(address(g), abi.encodeCall(IOspexGames.withdraw, ())), (uint256)), FEE);
        assertEq(coin.balanceOf(address(x)) - coinBefore, FEE, "paid the first credit");
        assertEq(x.answerCount(), 3);
        (bool ok, bytes memory answer) = x.answerAt(0);
        assertTrue(ok, "the score inside the payment");
        (ok, answer) = x.answerAt(1);
        assertEq(answer, locked, "the withdrawal inside the payment");
        (ok, answer) = x.answerAt(2);
        assertEq(answer, locked, "the creation inside the payment");
        assertEq(g.getCredit(address(x)), FEE, "the new credit, whole");
        assertEq(uint8(g.getGameStatus(b)), uint8(GameStatus.Scored));
        _assertBooks(address(x));

        assertEq(abi.decode(x.act(address(g), abi.encodeCall(IOspexGames.withdraw, ())), (uint256)), FEE);
        _assertBooks(address(x));
        uint256 c = abi.decode(x.act(address(g), _createCall("nba", FEE)), (uint256));
        assertEq(c, 3, "the creation, after");
        _assertBooks(address(x));
        assertEq(coin.balanceOf(address(g)), FEE, "the one game open holds the one fee");
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    /// @dev An actor with a purse of the coin that has allowed the games set to take it.
    function _actor(string memory name) internal returns (Actor a) {
        a = new Actor();
        vm.label(address(a), name);
        coin.mint(address(a), PURSE);
        a.act(address(coin), abi.encodeCall(IERC20.approve, (address(g), type(uint256).max)));
    }

    function _createCall(string memory league, uint256 maxFee) internal pure returns (bytes memory) {
        return abi.encodeCall(IOspexGames.createGame, (league, "Home", "Away", DATE, new Hint[](0), maxFee));
    }

    function _createOn() internal returns (uint256 id) {
        vm.prank(creator, creator);
        id = g.createGame("nba", "Home", "Away", DATE, new Hint[](0), FEE);
    }

    function _startOn(uint256 id) internal {
        vm.warp(DATE - 1 hours);
        r.send(_startReport(id, START));
    }

    function _startAndScore(uint256 id, address to) internal {
        _startOn(id);
        vm.warp(START + 10);
        r.send(_scoreReportTo(id, to));
    }

    /// @dev A league's terms on the second games set, through the timelock, with the launch clocks.
    function _setTermsOn(string memory league, uint96 fee) internal {
        bytes memory call = abi.encodeCall(IOspexGames.setTerms, (league, _feeTerms(fee)));
        bytes32 s = bytes32(++salt);
        vm.prank(timelockKey);
        timelock.schedule(address(g), 0, call, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        timelock.execute(address(g), 0, call, bytes32(0), s);
    }

    function _two(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    function _coinOf(address[] memory accounts) internal view returns (bytes32) {
        bytes memory out = abi.encode(coin.balanceOf(address(g)), coin.balanceOf(address(coin)));
        for (uint256 i; i < accounts.length; ++i) {
            out = abi.encodePacked(out, coin.balanceOf(accounts[i]), g.getCredit(accounts[i]));
        }
        return keccak256(out);
    }

    /// @dev On the second games set: the coin held equals the fees of games not ended plus the credits of the
    ///      payout address, the creator, the test's payout address and `x`, every address these tests credit.
    function _assertBooks(address x) internal view {
        uint256 owed = g.getCredit(x) + g.getCredit(creator) + g.getCredit(payout);
        for (uint256 id = 1; id <= g.gameCount(); ++id) {
            (uint96 held,) = g.getGameFee(id);
            owed += held;
        }
        assertEq(coin.balanceOf(address(g)), owed, "the coin held is what is held and credited");
    }

    /// @dev The same on the first games set.
    function _assertBooksOfGames(address x) internal view {
        uint256 owed = games.getCredit(x) + games.getCredit(creator) + games.getCredit(payout);
        for (uint256 id = 1; id <= games.gameCount(); ++id) {
            owed += _held(id);
        }
        assertEq(token.balanceOf(address(games)), owed, "the coin held is what is held and credited");
    }
}
