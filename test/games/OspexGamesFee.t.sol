// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames, GameStatus, ReporterKind, ReportKind, Report, Hint} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter} from "./GamesBase.sol";
import {TestCoin, RefusingCoin, FalseCoin, BonusCoin} from "./CoinFixtures.sol";

/// @dev A coin that, as it pays an address it was told to, calls that address back: what a coin with transfer
///      hooks does.
contract CallingBackCoin is TestCoin {
    mapping(address => bool) public hooked;

    function hook(address account) external {
        hooked[account] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hooked[to]) CoinReceiver(to).onPaid();
    }
}

/// @dev A payout address that, when the coin pays it, withdraws again before the first withdrawal returns, and
///      keeps the refusal.
contract CoinReceiver {
    IOspexGames internal immutable i_games;
    uint256 public reentered;
    bool public tried;
    bytes public refusal;

    constructor(IOspexGames games) {
        i_games = games;
    }

    function withdraw() external returns (uint256) {
        return i_games.withdraw();
    }

    function onPaid() external {
        if (tried) return;
        tried = true;
        try i_games.withdraw() returns (uint256 amount) {
            reentered = amount;
        } catch (bytes memory err) {
            refusal = err;
        }
    }
}

/// @notice The creation fee beyond its never-lines: what a creation takes, what each end credits, what a
///         withdrawal pays, and the coin's own ways of refusing.
contract OspexGamesFeeTest is GamesBase {
    // ──────────────────────────── The constructor's coin ───────────────

    /// The coin must be a contract: not address 0, not a wallet, not a wallet with delegated code. A fee taken in
    /// a coin with no code would be a transfer that always succeeds and moves nothing.
    /// Break: in the constructor, delete `if (coin.code.length == 0 || _isDelegated(coin)) revert
    /// OspexGames__TokenNotAContract(coin);`.
    function test_constructor_refusesACoinThatIsNotAContract() public {
        address delegated = makeAddr("a delegated wallet");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(token)));
        address[3] memory bad = [address(0), makeAddr("a wallet"), delegated];
        address only = address(new MockReporter(IOspexGames(address(0))));
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__TokenNotAContract.selector, bad[i]));
            new OspexGames(
                address(timelock), IERC20(bad[i]), _launchTerms(), _one(only), _kinds1(ReporterKind.FirstN), _hashes(_one(only))
            );
        }
        // Control: a coin with code deploys, and reads back.
        OspexGames g = new OspexGames(
            address(timelock), token, _launchTerms(), _one(only), _kinds1(ReporterKind.FirstN), _hashes(_one(only))
        );
        assertEq(address(g.i_token()), address(token));
    }

    /// The constructor's arguments, by name and type: the deploy script is written against them.
    function test_constructor_takesTheseArguments() public view {
        string memory impl = _artifact("OspexGames");
        _assertParams(
            impl,
            "$.abi[?(@.type == 'constructor')].inputs",
            "timelock;token;defaultTerms;reporters;kinds;codeHashes",
            "address;address;tuple;address[];uint8[];bytes32[]"
        );
    }

    /// The coin's check refuses no code and a wallet's delegation, and nothing else. Code of 1, 22, 23 and 24
    /// bytes that is no delegation is a contract, and is taken: among them 23 bytes that do not begin 0xef, and
    /// 23 bytes that begin 0xef0000. A delegation is 23 bytes too, 0xef0100 and an address, so a check of the
    /// length alone would refuse what is not one. Control: the delegation itself is refused.
    /// Break: in the constructor, change `if (coin.code.length == 0 || _isDelegated(coin))` to
    /// `if (coin.code.length <= 23)`. The 23-byte coins that are no delegation are then refused.
    function test_constructor_takesACoinOfAnyLengthThatIsNotADelegation() public {
        address only = address(new MockReporter(IOspexGames(address(0))));
        bytes[5] memory codes = [
            bytes(hex"00"),
            abi.encodePacked(hex"60", bytes21(keccak256("twenty-two"))),
            abi.encodePacked(hex"60", bytes22(keccak256("twenty-three"))),
            abi.encodePacked(hex"ef0000", address(token)),
            abi.encodePacked(hex"60", bytes23(keccak256("twenty-four")))
        ];
        uint256[5] memory lengths = [uint256(1), 22, 23, 23, 24];
        for (uint256 i; i < codes.length; ++i) {
            address coin = makeAddr(string.concat("a coin of length ", vm.toString(i)));
            vm.etch(coin, codes[i]);
            assertEq(coin.code.length, lengths[i], "the code's length");
            OspexGames g = new OspexGames(
                address(timelock), IERC20(coin), _launchTerms(), _one(only), _kinds1(ReporterKind.FirstN), _hashes(_one(only))
            );
            assertEq(address(g.i_token()), coin, "the coin taken");
        }
        address delegated = makeAddr("a delegation");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(token)));
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__TokenNotAContract.selector, delegated));
        new OspexGames(
            address(timelock), IERC20(delegated), _launchTerms(), _one(only), _kinds1(ReporterKind.FirstN), _hashes(_one(only))
        );
    }

    // ──────────────────────────── Creation ─────────────────────────────

    /// A creation takes exactly the game's fee from its creator, under an allowance of exactly that much, and
    /// the game holds it. A second creation with the allowance spent is refused by the coin, and makes nothing.
    function test_create_takesTheFeeFromTheCreator() public {
        address who = makeAddr("a creator with one fee allowed");
        token.mint(who, 5 * uint256(FEE));
        vm.prank(who);
        token.approve(address(games), FEE);

        vm.prank(who, who);
        uint256 game = games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        assertEq(token.balanceOf(who), 4 * uint256(FEE), "the creator paid the fee");
        assertEq(token.balanceOf(address(games)), FEE, "the games set holds it");
        assertEq(token.allowance(who, address(games)), 0, "the allowance is spent");
        (uint96 held, address recorded) = games.getGameFee(game);
        assertEq(held, FEE, "the game holds its fee");
        assertEq(recorded, who, "the creator recorded");

        vm.prank(who, who);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(games), 0, FEE)
        );
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        assertEq(games.gameCount(), 1, "a refused creation made a game");
    }

    /// No allowance, or no coin: the coin refuses and nothing is created.
    function test_create_refusedWithoutTheFee() public {
        address broke = makeAddr("no coin");
        vm.prank(broke, broke);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(games), 0, FEE)
        );
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        vm.prank(broke);
        token.approve(address(games), FEE);
        vm.prank(broke, broke);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, broke, 0, FEE));
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        assertEq(games.gameCount(), 0, "a refused creation made a game");
        assertEq(token.balanceOf(address(games)), 0);
    }

    /// At a fee of 0 nothing is taken and the coin is not called, not even to read a balance: a creator with no
    /// coin and no allowance creates, and so does one while the coin refuses every transfer. Its end credits
    /// nothing and emits no credit, and there is nothing to withdraw.
    /// Break: in createGame(), change `if (terms.fee != 0) _takeFee(terms.fee);` to `_takeFee(terms.fee);`. The
    /// paused coin then refuses the creation.
    function test_create_atAFeeOfZeroTakesNothingAndCallsNoCoin() public {
        _setTerms("", _feeTerms(0));
        address broke = makeAddr("no coin");
        token.setPaused(true);
        vm.expectCall(address(token), "", 0); // no call of any kind
        vm.prank(broke, broke);
        uint256 game = games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        (uint96 held, address recorded) = games.getGameFee(game);
        assertEq(held, 0, "a game made at 0 holds nothing");
        assertEq(recorded, broke, "its creator is recorded all the same");

        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + 10);
        vm.recordLogs();
        _take(address(first), _scoreReportTo(game, payout));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the report's event");
        assertEq(logs[0].topics[0], IOspexGames.GameReported.selector);
        assertEq(games.getCredit(payout), 0, "a fee of 0 credits nothing");
        vm.prank(payout);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NothingToWithdraw.selector, payout));
        games.withdraw();
    }

    /// A coin that answers false instead of refusing: the creation is refused by name, and nothing is created,
    /// so no game holds a fee the games set did not receive. A withdrawal it answers false to is refused too,
    /// and the credit stays.
    /// Break: in _takeFee(), change `i_token.safeTransferFrom(msg.sender, address(this), fee);` to
    /// `i_token.transferFrom(msg.sender, address(this), fee);`. The false answer is then read by nothing, and
    /// only the balance check stops the creation, under its own name.
    function test_create_aCoinThatAnswersFalseIsRefused() public {
        FalseCoin coin = new FalseCoin();
        MockReporter r = new MockReporter(IOspexGames(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        OspexGames g =
            new OspexGames(address(timelock), coin, _launchTerms(), _one(address(r)), _kinds1(ReporterKind.FirstN), _hashes(_one(address(r))));
        assertEq(address(r.i_games()), address(g), "the reporter points at the games set");
        coin.mint(creator, PURSE);
        vm.prank(creator);
        coin.approve(address(g), type(uint256).max);

        coin.setRefusing(true);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(coin)));
        g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        assertEq(g.gameCount(), 0, "a game was made on a transfer that moved nothing");

        coin.setRefusing(false);
        vm.prank(creator, creator);
        uint256 game = g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        vm.warp(DATE - 1 hours);
        r.send(_startReport(game, START));
        vm.warp(START + 10);
        r.send(_scoreReportTo(game, payout));
        coin.setRefusing(true);
        vm.prank(payout);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(coin)));
        g.withdraw();
        assertEq(g.getCredit(payout), FEE, "the credit stays");
        coin.setRefusing(false);
        vm.prank(payout);
        g.withdraw();
        assertEq(coin.balanceOf(payout), FEE);
    }

    /// A coin that keeps a cut of each transfer: taking the fee raises the games set's balance by less than the
    /// fee, so the creation is refused by name, with the balance on each side, and no game is made and no coin
    /// moves. A cut of 1 unit, and a cut larger than the fee, so that nothing arrives. The games set already
    /// holds a fee, so neither balance read is 0. Control: with no cut, the same creation is made and the game
    /// holds its fee.
    /// Break: in _takeFee(), delete `if (balanceAfter != balanceBefore + fee) revert
    /// OspexGames__FeeNotReceived(fee, balanceBefore, balanceAfter);`. The game is then made holding a fee the
    /// games set did not receive.
    function test_create_aCoinThatKeepsACutIsRefused() public {
        _create();
        uint256 held = token.balanceOf(address(games));
        assertEq(held, FEE, "one fee held already");
        uint256 purse = token.balanceOf(creator);
        uint256[2] memory cuts = [uint256(1), uint256(FEE) + 5];
        for (uint256 i; i < cuts.length; ++i) {
            token.setCut(cuts[i]);
            uint256 arrives = cuts[i] >= FEE ? 0 : FEE - cuts[i];
            vm.prank(creator, creator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    OspexGames.OspexGames__FeeNotReceived.selector, uint256(FEE), held, held + arrives
                )
            );
            games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
            assertEq(games.gameCount(), 1, "a game was made on a fee that did not arrive");
            assertEq(token.balanceOf(address(games)), held, "the games set's coin moved");
            assertEq(token.balanceOf(creator), purse, "the creator's coin moved");
            assertEq(token.balanceOf(address(token)), 0, "the coin kept a cut of a refused creation");
        }
        token.setCut(0);
        vm.prank(creator, creator);
        uint256 game = games.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        assertEq(_held(game), FEE, "control: the game holds its fee");
        assertEq(token.balanceOf(address(games)), held + FEE, "control: the fee arrived");
    }

    /// A coin that adds to a transfer: taking the fee raises the games set's balance by more than the fee, and
    /// the creation is refused too. The check is for exactly the fee. Control: with no bonus, the creation is
    /// made.
    /// Break: in _takeFee(), change `balanceAfter != balanceBefore + fee` to `balanceAfter < balanceBefore +
    /// fee`. The creation is then made, and the bonus is held by no game.
    function test_create_aCoinThatAddsToATransferIsRefused() public {
        BonusCoin coin = new BonusCoin();
        MockReporter r = new MockReporter(IOspexGames(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        OspexGames g =
            new OspexGames(address(timelock), coin, _launchTerms(), _one(address(r)), _kinds1(ReporterKind.FirstN), _hashes(_one(address(r))));
        assertEq(address(r.i_games()), address(g), "the reporter points at the games set");
        coin.mint(creator, PURSE);
        vm.prank(creator);
        coin.approve(address(g), type(uint256).max);

        coin.setBonus(7);
        vm.prank(creator, creator);
        vm.expectRevert(
            abi.encodeWithSelector(OspexGames.OspexGames__FeeNotReceived.selector, uint256(FEE), 0, uint256(FEE) + 7)
        );
        g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        assertEq(g.gameCount(), 0, "a game was made on more than its fee");
        assertEq(coin.balanceOf(address(g)), 0);

        coin.setBonus(0);
        vm.prank(creator, creator);
        uint256 game = g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        (uint96 held,) = g.getGameFee(game);
        assertEq(held, FEE, "control: the game holds its fee");
        assertEq(coin.balanceOf(address(g)), FEE, "control: the fee arrived");
    }

    // ──────────────────────────── The most a creator pays ─────────────

    /// A creation pays its fee as it runs, never the most it named: named exactly, named a unit above, and named
    /// any amount, each takes the one fee; after a cut to half a fee, naming a whole one takes the half. Named a
    /// unit below the fee, it is refused by name with both amounts, and nothing is taken; named 0, the same: 0
    /// is a most of 0, not "any". At a fee of 0, naming 0 is enough.
    /// Break: in createGame(), change `terms.fee > maxFee` to `terms.fee >= maxFee`. Naming the fee exactly is
    /// then refused. And `terms.fee > maxFee && maxFee != 0`: naming 0 is then taken as no limit.
    function test_create_paysTheFeeAsItRunsNeverTheMostNamed() public {
        address who = makeAddr("a creator");
        token.mint(who, 100 * uint256(FEE));
        vm.prank(who);
        token.approve(address(games), type(uint256).max);
        uint256[3] memory named = [uint256(FEE), uint256(FEE) + 1, ANY_FEE];
        for (uint256 i; i < named.length; ++i) {
            uint256 before = token.balanceOf(who);
            vm.prank(who, who);
            uint256 game = games.createGame("nba", "Home", "Away", DATE, new Hint[](0), named[i]);
            assertEq(before - token.balanceOf(who), FEE, "paid the fee, not the most named");
            assertEq(_held(game), FEE, "the game holds the fee");
        }
        _setTerms("", _feeTerms(FEE / 2));
        uint256 b = token.balanceOf(who);
        vm.prank(who, who);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), FEE);
        assertEq(b - token.balanceOf(who), FEE / 2, "a lower fee is paid as it stands");

        uint256 count = games.gameCount();
        b = token.balanceOf(who);
        vm.prank(who, who);
        vm.expectRevert(
            abi.encodeWithSelector(OspexGames.OspexGames__FeeAboveMax.selector, uint256(FEE / 2), uint256(FEE / 2) - 1)
        );
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), uint256(FEE / 2) - 1);
        vm.prank(who, who);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__FeeAboveMax.selector, uint256(FEE / 2), 0));
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), 0);
        assertEq(games.gameCount(), count, "a game was made");
        assertEq(token.balanceOf(who), b, "coin was taken");

        _setTerms("", _feeTerms(0));
        vm.prank(who, who);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), 0);
        assertEq(games.gameCount(), count + 1, "at 0, naming 0 creates");
        assertEq(token.balanceOf(who), b, "at 0 nothing is taken");
    }

    /// A creation whose fee is above the most named is refused by that name before the coin is called, so the
    /// coin's state has no say. Five states in which the pull itself would be refused under its own name: the
    /// coin paused, the creator blocked, the games set blocked, a cut kept, and a creator with no coin and no
    /// allowance. Each time the refusal is the same, and the call reached no coin address at all. Control:
    /// named the fee, with the coin taking transfers, the same creation is made.
    /// Break: in createGame(), move `if (terms.fee > maxFee) revert OspexGames__FeeAboveMax(terms.fee, maxFee);`
    /// to just after `if (terms.fee != 0) _takeFee(terms.fee);`. The coin is then called first, and its own
    /// refusal, or the cut's, is named instead.
    function test_create_aFeeAboveTheMostNamedIsRefusedBeforeTheCoinIsCalled() public {
        address broke = makeAddr("no coin, no allowance");
        bytes memory refusal =
            abi.encodeWithSelector(OspexGames.OspexGames__FeeAboveMax.selector, uint256(FEE), uint256(FEE) - 1);
        for (uint256 i; i < 5; ++i) {
            if (i == 0) token.setPaused(true);
            if (i == 1) {
                token.setPaused(false);
                token.setBlocked(creator, true);
            }
            if (i == 2) {
                token.setBlocked(creator, false);
                token.setBlocked(address(games), true);
            }
            if (i == 3) {
                token.setBlocked(address(games), false);
                token.setCut(1);
            }
            if (i == 4) token.setCut(0);
            vm.startStateDiffRecording();
            vm.prank(i == 4 ? broke : creator, i == 4 ? broke : creator);
            (bool ok, bytes memory err) = address(games).call(
                abi.encodeCall(IOspexGames.createGame, ("nba", "Home", "Away", DATE, new Hint[](0), uint256(FEE) - 1))
            );
            VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
            assertFalse(ok, "a creation above the most named");
            assertEq(err, refusal, "the refusal");
            assertGt(accesses.length, 0, "nothing was recorded");
            for (uint256 j; j < accesses.length; ++j) {
                assertTrue(accesses[j].account != address(token), "the coin was called");
            }
        }
        assertEq(games.gameCount(), 0, "a game was made");
        vm.prank(creator, creator);
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0), FEE);
        assertEq(games.gameCount(), 1, "control: named the fee, the game is made");
    }

    // ──────────────────────────── The ends ─────────────────────────────

    /// A start ends nothing and credits nothing: its only event is its report's, and the money reads as before.
    function test_start_creditsNothing() public {
        uint256 game = _create();
        address[] memory accounts = new address[](4);
        (accounts[0], accounts[1], accounts[2], accounts[3]) = (address(first), creator, payout, address(0));
        bytes32 money = _money(accounts);
        vm.warp(DATE - 1 hours);
        vm.recordLogs();
        _startBy(first, game, START);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the report's event");
        assertEq(logs[0].topics[0], IOspexGames.GameReported.selector);
        assertEq(_money(accounts), money, "a start moved money");
        assertEq(_held(game), FEE, "a started game holds its fee");
    }

    /// A score credits the game's fee once, by event and by read; the game holds nothing after; the payout
    /// address withdraws it once, and a second withdrawal finds nothing.
    function test_score_creditsTheFeeOnceAndItIsWithdrawnOnce() public {
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(game, payout));
        assertEq(games.getCredit(payout), FEE, "credited");
        assertEq(_held(game), 0, "a scored game holds nothing");
        (bool ok, bytes memory err) = _send(address(second), _scoreReportTo(game, stranger));
        assertFalse(ok, "a second score");
        assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, game, GameStatus.Scored));
        assertEq(games.getCredit(stranger), 0);

        vm.recordLogs();
        vm.prank(payout);
        assertEq(games.withdraw(), FEE, "the amount returned");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the withdrawal and the coin's transfer");
        assertEq(logs[0].emitter, address(games));
        assertEq(logs[0].topics[0], IOspexGames.Withdrawn.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(payout))));
        assertEq(abi.decode(logs[0].data, (uint256)), FEE);
        assertEq(token.balanceOf(payout), FEE, "paid");
        assertEq(games.getCredit(payout), 0, "the credit is spent");
        vm.prank(payout);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NothingToWithdraw.selector, payout));
        games.withdraw();
    }

    /// A score's refusals name its first fault in one order: the game's status, a start field set, the payout
    /// address, then the scores, the start's hour and n's window. A score whose payout is the games set and
    /// which is faulty in a later way too is refused for its payout, each way: a score above MAX_SCORE, a score
    /// sent before the start, and a score sent by an after-n reporter inside n. The same score with its start
    /// field set is refused for the start field. Controls: each later fault alone is refused by its own name.
    /// Break: in _writeScore(), move `_checkPayout(ReportKind.Score, r.payout);` from above the score's range
    /// check to below the InsideWindow check. A faulty payout is then named only once the score and the clock
    /// pass.
    function test_score_namesAPayoutFaultBeforeTheScoreAndTheClock() public {
        uint256 game = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, game, START);
        bytes memory payoutFault =
            abi.encodeWithSelector(OspexGames.OspexGames__PayoutIsTheGamesSet.selector, ReportKind.Score);
        uint32 tooHigh = games.MAX_SCORE() + 1;

        vm.warp(START + 10);
        Report memory high = _scoreReportTo(game, address(games));
        high.homeScore = tooHigh;
        _assertRefusedWith(first, high, payoutFault);
        _assertRefusedWith(later, _scoreReportTo(game, address(games)), payoutFault); // inside n
        Report memory withStart = _scoreReportTo(game, address(games));
        withStart.start = START;
        _assertRefusedWith(
            first, withStart, abi.encodeWithSelector(OspexGames.OspexGames__FieldNotEmpty.selector, ReportKind.Score)
        );
        vm.warp(START - 1);
        _assertRefusedWith(first, _scoreReportTo(game, address(games)), payoutFault); // before the start

        // Controls: each later fault alone.
        _assertRefusedWith(
            first, _scoreReport(game, HOME, AWAY), abi.encodeWithSelector(OspexGames.OspexGames__BeforeStart.selector, game, START)
        );
        vm.warp(START + 10);
        _assertRefusedWith(
            first,
            _scoreReport(game, tooHigh, AWAY),
            abi.encodeWithSelector(OspexGames.OspexGames__ScoreOutOfRange.selector, tooHigh, AWAY)
        );
        _assertRefusedWith(
            later,
            _scoreReport(game, HOME, AWAY),
            abi.encodeWithSelector(OspexGames.OspexGames__InsideWindow.selector, game, uint256(START) + WINDOW)
        );
        _take(address(first), _scoreReport(game, HOME, AWAY));
    }

    // ──────────────────────────── Withdrawal ───────────────────────────

    /// Credits add up across games and fees, for each address apart. A withdrawal pays its caller its own
    /// credit, all of it, and touches no one else's; an address with nothing credited is refused.
    /// Break: in withdraw(), change `i_token.safeTransfer(msg.sender, amount);` to
    /// `i_token.safeTransfer(tx.origin, amount);`. The caller's credit is spent and the coin goes elsewhere.
    function test_withdraw_paysTheCallerItsOwnCreditAndNoOneElses() public {
        address q = makeAddr("another payout address");
        uint256[3] memory ids;
        ids[0] = _create(); // 1
        _setTerms("", _feeTerms(2_500_000));
        ids[1] = _create(); // 2.5
        _setTerms("", _feeTerms(0));
        ids[2] = _create(); // 0
        _setTerms("", _feeTerms(4 * FEE));
        uint256 four = _create(); // 4
        vm.warp(DATE - 1 hours);
        for (uint256 i; i < 3; ++i) {
            _startBy(first, ids[i], START);
        }
        _startBy(first, four, START);
        vm.warp(START + 10);
        for (uint256 i; i < 3; ++i) {
            _take(address(first), _scoreReportTo(ids[i], payout));
        }
        _take(address(first), _scoreReportTo(four, q));
        assertEq(games.getCredit(payout), 3_500_000, "1 + 2.5 + 0");
        assertEq(games.getCredit(q), 4 * uint256(FEE));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__NothingToWithdraw.selector, stranger));
        games.withdraw();
        vm.prank(payout);
        assertEq(games.withdraw(), 3_500_000, "all of its own credit");
        assertEq(token.balanceOf(payout), 3_500_000);
        assertEq(games.getCredit(q), 4 * uint256(FEE), "another's credit moved");
        assertEq(token.balanceOf(address(games)), 4 * uint256(FEE), "what is left is what is owed");
        vm.prank(q);
        games.withdraw();
        assertEq(token.balanceOf(address(games)), 0);
    }

    /// A coin that calls the payee back as it pays: the payee withdraws again from inside the payment, and
    /// is refused, because one withdrawal runs at a time; its credit was spent before the coin was called as
    /// well. Another game's held fee is still there, and the payee is paid once.
    /// Break: in withdraw(), delete `nonReentrant`. The call back is then refused for the spent credit instead
    /// (NothingToWithdraw), and this test reads the other refusal. The spent credit's own break is in
    /// OspexGamesFeeCallbacks.t.sol.
    function test_withdraw_aCoinThatCallsBackPaysOnce() public {
        CallingBackCoin coin = new CallingBackCoin();
        MockReporter r = new MockReporter(IOspexGames(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        OspexGames g =
            new OspexGames(address(timelock), coin, _launchTerms(), _one(address(r)), _kinds1(ReporterKind.FirstN), _hashes(_one(address(r))));
        CoinReceiver receiver = new CoinReceiver(g);
        coin.hook(address(receiver));
        coin.mint(creator, PURSE);
        vm.prank(creator);
        coin.approve(address(g), type(uint256).max);
        vm.startPrank(creator, creator);
        uint256 a = g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        uint256 b = g.createGame("nba", "Home", "Away", DATE, new Hint[](0), ANY_FEE);
        vm.stopPrank();
        vm.warp(DATE - 1 hours);
        r.send(_startReport(a, START));
        vm.warp(START + 10);
        r.send(_scoreReportTo(a, address(receiver)));

        assertEq(receiver.withdraw(), FEE, "paid once");
        assertTrue(receiver.tried(), "the coin called back");
        assertEq(receiver.reentered(), 0, "the call back was paid");
        assertEq(
            receiver.refusal(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "refused as a second withdrawal running inside the first"
        );
        assertEq(coin.balanceOf(address(receiver)), FEE);
        assertEq(coin.balanceOf(address(g)), FEE, "the other game's fee is still held");
        (uint96 held,) = g.getGameFee(b);
        assertEq(held, FEE);
    }

    // ──────────────────────────── The read ─────────────────────────────

    /// What a game holds: its fee while it has not ended (created, started, disputed), and 0 once it has
    /// (scored, voided, released), each status reached through its own path. The creator reads back throughout.
    /// An id that is not a game is refused.
    function test_getGameFee_readsWhatAGameHolds() public {
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, 0));
        games.getGameFee(0);
        GameStatus[6] memory statuses = [
            GameStatus.Unverified,
            GameStatus.Verified,
            GameStatus.Disputed,
            GameStatus.Scored,
            GameStatus.Voided,
            GameStatus.Released
        ];
        for (uint256 i; i < statuses.length; ++i) {
            vm.warp(DATE - 1 hours);
            uint256 game = _inStatus(statuses[i]);
            assertEq(uint8(_status(game)), uint8(statuses[i]), "status");
            (uint96 held, address recorded) = games.getGameFee(game);
            assertEq(held, i < 3 ? FEE : 0, "held");
            assertEq(recorded, creator, "creator");
        }
        uint256 next = games.gameCount() + 1;
        vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, next));
        games.getGameFee(next);
    }

    // ──────────────────────────── The largest fee ──────────────────────

    /// The largest fee a term can name, on two games ending to one payout address: the credits add up past a
    /// single fee's width, and the withdrawal pays them all. A third game released credits its creator the same.
    /// Break: in OspexGames.sol, change `mapping(address => uint256) internal s_credits;` to
    /// `mapping(address => uint96) internal s_credits;`. The second credit then overflows and the score reverts.
    function test_fee_theLargestFeeAddsUp() public {
        uint96 max = type(uint96).max;
        token.mint(creator, 3 * uint256(max));
        _setTerms("", _feeTerms(max));
        uint256 a = _create();
        uint256 b = _create();
        uint256 c = _create();
        vm.warp(DATE - 1 hours);
        _startBy(first, a, START);
        _startBy(first, b, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(a, payout));
        _take(address(first), _scoreReportTo(b, payout));
        vm.warp(DATE + DAY30);
        _releaseBy(stranger, c);
        assertEq(games.getCredit(payout), 2 * uint256(max), "past one fee's width");
        assertEq(games.getCredit(creator), max);
        vm.prank(payout);
        assertEq(games.withdraw(), 2 * uint256(max));
        assertEq(token.balanceOf(payout), 2 * uint256(max));
        assertEq(token.balanceOf(address(games)), max);
    }

    // ──────────────────────────── One end per game, for the fee ─────────

    /// The gate every end shares, in the production code: an end of an id that is not a game, or of a game
    /// already ended (scored, voided or released), is refused, credits nothing and moves no coin. Reached
    /// through the test harness's hook, which calls `_end` with none of the checks its callers make first, so the
    /// gate under test is `_end`'s own; the score, the void and the release each reach it behind their own.
    /// Break: in _end(), delete `if (status >= GameStatus.Scored) revert OspexGames__GameEnded(gameId, status);`.
    /// A second end then credits the creator a second fee, out of another game's.
    function test_end_refusesAGameAlreadyEnded() public {
        uint256 scored = _create();
        uint256 released = _create();
        uint256 voided = _create();
        uint256 open = _create(); // holds a fee another end could be paid from
        vm.warp(DATE - 1 hours);
        _startBy(first, scored, START);
        _startBy(first, voided, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(scored, payout));
        vm.warp(START + WINDOW);
        _take(address(first), _voidReportTo(voided, payout));
        vm.warp(DATE + DAY30);
        _releaseBy(stranger, released);

        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, stranger);
        uint256[3] memory ended = [scored, released, voided];
        GameStatus[3] memory statuses = [GameStatus.Scored, GameStatus.Released, GameStatus.Voided];
        GameStatus[3] memory ends = [GameStatus.Released, GameStatus.Voided, GameStatus.Scored];
        for (uint256 i; i < ended.length; ++i) {
            for (uint256 e; e < ends.length; ++e) {
                bytes32 money = _money(accounts);
                vm.recordLogs();
                vm.prank(stranger);
                (bool ok, bytes memory err) =
                    address(games).call(abi.encodeCall(games.harnessEnd, (ended[i], ends[e], creator)));
                assertFalse(ok, "an ended game was ended again");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, ended[i], statuses[i]));
                assertEq(vm.getRecordedLogs().length, 0, "a refused end emitted");
                assertEq(_money(accounts), money, "a refused end moved money");
                assertEq(uint8(_status(ended[i])), uint8(statuses[i]), "a refused end changed the status");
            }
        }
        assertEq(games.getCredit(creator), FEE, "the creator, once");
        assertEq(games.getCredit(payout), 2 * uint256(FEE), "the payout address, twice");
        assertEq(_held(open), FEE, "the open game keeps its fee");
        // Control: the open game ends through the same hook.
        vm.prank(stranger);
        games.harnessEnd(open, GameStatus.Released, creator);
        assertEq(games.getCredit(creator), 2 * uint256(FEE));
    }

    /// The same gate's other half: an id that is not a game is refused, and does not become one.
    /// Break: in _end(), delete `if (status == GameStatus.None) revert OspexGames__UnknownGame(gameId);`. Id 0
    /// then reads as a released game.
    function test_end_refusesAnIdThatIsNotAGame() public {
        _create();
        uint256[2] memory ids = [uint256(0), games.gameCount() + 1];
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory err) =
                address(games).call(abi.encodeCall(games.harnessEnd, (ids[i], GameStatus.Released, creator)));
            assertFalse(ok, "an id that is not a game was released");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, ids[i]));
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, ids[i]));
            games.getGameStatus(ids[i]);
        }
        assertEq(games.gameCount(), 1, "the count moved");
    }

    /// The gate's third part: `_end` handed a status that is not an end (None, Unverified, Verified, Disputed)
    /// is refused by name, credits nothing, writes no status and leaves the game open, so no caller can credit a
    /// fee without ending the game, or move a status back. Control: the three ends are taken, each crediting.
    /// Break: in _end(), delete `if (end < GameStatus.Scored) revert OspexGames__NotAnEnd(end);`. A game is then
    /// "ended" as Disputed: the fee is credited, the status stays below an end, and a second end credits again.
    function test_end_refusesAStatusThatIsNotAnEnd() public {
        GameStatus[4] memory notEnds =
            [GameStatus.None, GameStatus.Unverified, GameStatus.Verified, GameStatus.Disputed];
        GameStatus[3] memory ends = [GameStatus.Scored, GameStatus.Voided, GameStatus.Released];
        for (uint256 e; e < ends.length; ++e) {
            vm.warp(DATE - 1 hours);
            uint256 game = _inStatus(GameStatus.Disputed);
            address[] memory accounts = new address[](3);
            (accounts[0], accounts[1], accounts[2]) = (creator, payout, stranger);
            for (uint256 i; i < notEnds.length; ++i) {
                bytes32 money = _money(accounts);
                bytes32 state = _viewAll();
                vm.recordLogs();
                vm.prank(stranger);
                (bool ok, bytes memory err) =
                    address(games).call(abi.encodeCall(games.harnessEnd, (game, notEnds[i], payout)));
                assertFalse(ok, "a status that is not an end was written as one");
                assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__NotAnEnd.selector, notEnds[i]));
                assertEq(vm.getRecordedLogs().length, 0, "a refused end emitted");
                assertEq(_money(accounts), money, "a refused end moved money");
                assertEq(_viewAll(), state, "a refused end changed a game");
                assertEq(uint8(_status(game)), uint8(GameStatus.Disputed), "the status moved");
                assertEq(_held(game), FEE, "the game keeps its fee");
            }
            // Control: the end is taken, credits once, and a second end of any kind is refused.
            vm.prank(stranger);
            games.harnessEnd(game, ends[e], payout);
            assertEq(uint8(_status(game)), uint8(ends[e]), "the end");
            assertEq(games.getCredit(payout), (e + 1) * uint256(FEE), "credited once per game");
            vm.prank(stranger);
            (bool okAgain,) = address(games).call(abi.encodeCall(games.harnessEnd, (game, ends[e], payout)));
            assertFalse(okAgain, "ended twice");
        }
    }

    function _assertRefusedWith(MockReporter by, Report memory r, bytes memory why) internal {
        (bool ok, bytes memory err) = _send(address(by), r);
        assertFalse(ok, "a faulty score was taken");
        assertEq(err, why, "the refusal");
    }
}
