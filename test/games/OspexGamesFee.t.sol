// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames, GameStatus, ReporterKind, ReportKind, Report, Hint} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter} from "./GamesBase.sol";
import {TestCoin, RefusingCoin, FalseCoin} from "./CoinFixtures.sol";

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

/// @dev A payout address that, when the coin pays it, withdraws again before the first withdrawal returns.
contract CoinReceiver {
    IOspexGames internal immutable i_games;
    uint256 public reentered;
    bool public tried;

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
        } catch {}
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

    // ──────────────────────────── Creation ─────────────────────────────

    /// A creation takes exactly the game's fee from its creator, under an allowance of exactly that much, and
    /// the game holds it. A second creation with the allowance spent is refused by the coin, and makes nothing.
    function test_create_takesTheFeeFromTheCreator() public {
        address who = makeAddr("a creator with one fee allowed");
        token.mint(who, 5 * uint256(FEE));
        vm.prank(who);
        token.approve(address(games), FEE);

        vm.prank(who, who);
        uint256 game = games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
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
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        assertEq(games.gameCount(), 1, "a refused creation made a game");
    }

    /// No allowance, or no coin: the coin refuses and nothing is created.
    function test_create_refusedWithoutTheFee() public {
        address broke = makeAddr("no coin");
        vm.prank(broke, broke);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(games), 0, FEE)
        );
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        vm.prank(broke);
        token.approve(address(games), FEE);
        vm.prank(broke, broke);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, broke, 0, FEE));
        games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        assertEq(games.gameCount(), 0, "a refused creation made a game");
        assertEq(token.balanceOf(address(games)), 0);
    }

    /// At a fee of 0 nothing is taken and the coin is not called: a creator with no coin and no allowance
    /// creates, and so does one while the coin refuses every transfer. Its end credits nothing and emits no
    /// credit, and there is nothing to withdraw.
    /// Break: in createGame(), change `if (terms.fee != 0) i_token.safeTransferFrom(msg.sender, address(this),
    /// terms.fee);` to `i_token.safeTransferFrom(msg.sender, address(this), terms.fee);`. The paused coin then
    /// refuses the creation.
    function test_create_atAFeeOfZeroTakesNothingAndCallsNoCoin() public {
        _setTerms("", _feeTerms(0));
        address broke = makeAddr("no coin");
        token.setPaused(true);
        vm.expectCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.prank(broke, broke);
        uint256 game = games.createGame("nba", "Home", "Away", DATE, new Hint[](0));
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
    /// Break: in createGame(), change `i_token.safeTransferFrom(msg.sender, address(this), terms.fee);` to
    /// `i_token.transferFrom(msg.sender, address(this), terms.fee);`. The game is then made holding nothing.
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
        g.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        assertEq(g.gameCount(), 0, "a game was made on a transfer that moved nothing");

        coin.setRefusing(false);
        vm.prank(creator, creator);
        uint256 game = g.createGame("nba", "Home", "Away", DATE, new Hint[](0));
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
    /// is refused, because its credit was spent before the coin was called. Another game's held fee is still
    /// there, and the payee is paid once.
    /// Break: in withdraw(), move `s_credits[msg.sender] = 0;` below `i_token.safeTransfer(msg.sender, amount);`.
    /// The call back is then paid a second time, out of the other game's fee.
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
        uint256 a = g.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        uint256 b = g.createGame("nba", "Home", "Away", DATE, new Hint[](0));
        vm.stopPrank();
        vm.warp(DATE - 1 hours);
        r.send(_startReport(a, START));
        vm.warp(START + 10);
        r.send(_scoreReportTo(a, address(receiver)));

        assertEq(receiver.withdraw(), FEE, "paid once");
        assertTrue(receiver.tried(), "the coin called back");
        assertEq(receiver.reentered(), 0, "the call back was paid");
        assertEq(coin.balanceOf(address(receiver)), FEE);
        assertEq(coin.balanceOf(address(g)), FEE, "the other game's fee is still held");
        (uint96 held,) = g.getGameFee(b);
        assertEq(held, FEE);
    }

    // ──────────────────────────── The read ─────────────────────────────

    /// What a game holds: its fee while it has not ended (created, started, disputed), and 0 once it has
    /// (scored, voided, released). The creator reads back throughout. An id that is not a game is refused.
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
            uint256 game = _create();
            games.harnessSetStatus(game, statuses[i]);
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
        vm.prank(stranger);
        games.harnessRelease(c);
        assertEq(games.getCredit(payout), 2 * uint256(max), "past one fee's width");
        assertEq(games.getCredit(creator), max);
        vm.prank(payout);
        assertEq(games.withdraw(), 2 * uint256(max));
        assertEq(token.balanceOf(payout), 2 * uint256(max));
        assertEq(token.balanceOf(address(games)), max);
    }

    // ──────────────────────────── One end per game, for the fee ─────────

    /// The gate every end shares, in the production code: an end of an id that is not a game, or of a game
    /// already ended (scored, voided or released), is refused, credits nothing and moves no coin. Here through
    /// the release, the end whose own call is not built yet; the score reaches the same gate behind its own.
    /// Break: in _end(), delete `if (status >= GameStatus.Scored) revert OspexGames__GameEnded(gameId, status);`.
    /// A second release then credits the creator a second fee, out of another game's.
    function test_end_refusesAGameAlreadyEnded() public {
        uint256 scored = _create();
        uint256 released = _create();
        uint256 voided = _create();
        uint256 open = _create(); // holds a fee another end could be paid from
        vm.warp(DATE - 1 hours);
        _startBy(first, scored, START);
        vm.warp(START + 10);
        _take(address(first), _scoreReportTo(scored, payout));
        vm.prank(stranger);
        games.harnessRelease(released);
        games.harnessSetStatus(voided, GameStatus.Voided);

        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (creator, payout, stranger);
        uint256[3] memory ended = [scored, released, voided];
        GameStatus[3] memory statuses = [GameStatus.Scored, GameStatus.Released, GameStatus.Voided];
        for (uint256 i; i < ended.length; ++i) {
            bytes32 money = _money(accounts);
            vm.recordLogs();
            vm.prank(stranger);
            (bool ok, bytes memory err) =
                address(games).call(abi.encodeCall(games.harnessRelease, (ended[i])));
            assertFalse(ok, "an ended game was released");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__GameEnded.selector, ended[i], statuses[i]));
            assertEq(vm.getRecordedLogs().length, 0, "a refused end emitted");
            assertEq(_money(accounts), money, "a refused end moved money");
        }
        assertEq(games.getCredit(creator), FEE, "the creator, once");
        assertEq(_held(open), FEE, "the open game keeps its fee");
        // Control: the open game releases.
        vm.prank(stranger);
        games.harnessRelease(open);
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
            (bool ok, bytes memory err) = address(games).call(abi.encodeCall(games.harnessRelease, (ids[i])));
            assertFalse(ok, "an id that is not a game was released");
            assertEq(err, abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, ids[i]));
            vm.expectRevert(abi.encodeWithSelector(OspexGames.OspexGames__UnknownGame.selector, ids[i]));
            games.getGameStatus(ids[i]);
        }
        assertEq(games.gameCount(), 1, "the count moved");
    }
}
