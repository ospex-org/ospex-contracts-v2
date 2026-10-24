// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames, ReporterKind, ReportKind, Reading, Report, Hint, Terms} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";
import {RefusingCoin} from "./CoinFixtures.sol";

/// @dev Drives the creation fee at random and keeps its own ledger, written from the rules, never read back
///      from the contract:
///      - a creation takes the fee its league has in the model from its creator, and is refused when the coin
///        would refuse that transfer (paused, or the creator or the games set blocked, or a creator with no
///        coin), and by name when the coin keeps a cut of it; at a fee of 0 it takes nothing, whatever the
///        coin's state;
///      - a start credits nothing;
///      - a score is taken only for a started game that has not ended, from one of its reporters at an hour it
///        may write (an after-n reporter from start + n), naming a payout address that is not 0, not the games
///        set, not the coin and not any reporter ever approved, the retired one included; it credits the game's
///        fee to that address;
///      - a release is taken only for a game that has not ended, and credits the game's fee to its creator. It
///        runs through the test harness's hook, which calls the production code's release credit; who may
///        release, and when, is the release call's and is not modelled;
///      - a report of a kind the contract does not take is refused;
///      - a withdrawal pays the caller its whole credit when the coin would move it, and otherwise leaves it;
///        under a cut the games set pays it all and the coin keeps its cut on the way;
///      - coin sent to the games set directly is held by no one and stays, less any cut.
///      Every FeeCredited event is checked against the model as it is emitted.
contract FeeHandler is Test {
    struct Ghost {
        address creator;
        uint96 fee;
        bool started;
        uint64 start;
        bool ended;
        address paidTo;
        uint256 creditEvents;
    }

    uint64 internal constant BASE = 1_800_000_037;
    uint64 internal constant WINDOW = 1 days;
    uint256 internal constant DELAY = 60;

    OspexGamesHarness public immutable games;
    RefusingCoin public immutable coin;
    TimelockController public immutable timelock;
    address internal immutable i_key;
    MockReporter internal immutable i_first; // first-n
    MockReporter internal immutable i_later; // after-n
    MockReporter internal immutable i_second; // first-n
    MockReporter internal immutable i_retired; // approved and retired before any game

    /// @dev Three creators with coin and an allowance, and one with neither.
    address[4] internal creators;
    address[3] internal payouts;
    address internal stranger;
    address internal donor;
    /// @dev Every address the ledger tracks a credit or a coin balance for.
    address[] internal accounts;

    Terms internal launch;
    uint96 internal defaultFee;
    uint96 internal nbaFee;
    bool internal nbaOwn;

    mapping(uint256 => Ghost) internal ghosts;
    uint256 public created;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public coinOf;
    uint256 public donated;
    bool internal paused;
    mapping(address => bool) internal blocked;
    /// @dev What the coin keeps of each transfer (all of a smaller one); 0 for none.
    uint256 internal cut;
    uint256 internal salt;

    /// @dev Calls where the contract and the model disagreed. Must stay 0.
    uint256 public mismatches;
    uint256[19] public counts;
    // Indexes into counts.
    uint256 internal constant CREATES = 0;
    uint256 internal constant CREATES_REFUSED = 1;
    uint256 internal constant STARTS = 2;
    uint256 internal constant STARTS_REFUSED = 3;
    uint256 internal constant SCORES = 4;
    uint256 internal constant SCORES_REFUSED = 5;
    uint256 internal constant RELEASES = 6;
    uint256 internal constant RELEASES_REFUSED = 7;
    uint256 internal constant OTHERS_REFUSED = 8;
    uint256 internal constant WITHDRAWALS = 9;
    uint256 internal constant WITHDRAWALS_REFUSED = 10;
    uint256 internal constant FEE_CHANGES = 11;
    uint256 internal constant DONATIONS = 12;
    uint256 internal constant COIN_TOGGLES = 13;
    uint256 internal constant CREDITS = 14;
    uint256 internal constant ENDS_AT_ZERO = 15;
    uint256 internal constant CUT_CHANGES = 16;
    /// @dev Creations refused by name because the coin kept a cut: part of CREATES_REFUSED.
    uint256 internal constant CREATES_CUT_REFUSED = 17;
    /// @dev Scores refused for their payout address alone, that address the coin or a reporter: part of
    ///      SCORES_REFUSED.
    uint256 internal constant PAYOUTS_COIN_OR_REPORTER = 18;

    constructor(
        OspexGamesHarness games_,
        RefusingCoin coin_,
        TimelockController timelock_,
        address key,
        MockReporter first_,
        MockReporter later_,
        MockReporter second_,
        MockReporter retired_,
        Terms memory launch_
    ) {
        games = games_;
        coin = coin_;
        timelock = timelock_;
        i_key = key;
        i_first = first_;
        i_later = later_;
        i_second = second_;
        i_retired = retired_;
        launch = launch_;
        defaultFee = launch_.fee;
        for (uint256 i; i < 4; ++i) {
            creators[i] = makeAddr(string.concat("creator ", vm.toString(i)));
            accounts.push(creators[i]);
        }
        for (uint256 i; i < 3; ++i) {
            payouts[i] = makeAddr(string.concat("payout ", vm.toString(i)));
            accounts.push(payouts[i]);
        }
        stranger = makeAddr("stranger");
        donor = makeAddr("donor");
        accounts.push(stranger);
        accounts.push(donor);
        accounts.push(address(first_));
        accounts.push(address(later_));
        accounts.push(address(second_));
        accounts.push(address(0));
        accounts.push(address(retired_));
        accounts.push(address(coin_)); // where the coin keeps its cut
        // Coin: three creators and the donor; the fourth creator has none and allows nothing.
        for (uint256 i; i < 3; ++i) {
            _mint(creators[i], 1 << 120);
            vm.prank(creators[i]);
            coin_.approve(address(games_), type(uint256).max);
        }
        _mint(donor, 1 << 120);
    }

    // ──────────────────────────── Actions ──────────────────────────────

    function create(uint256 whoSeed, uint256 leagueSeed) external {
        uint256 w = whoSeed % 4;
        address who = creators[w];
        bool nba = leagueSeed % 2 == 0;
        uint96 fee = nba && nbaOwn ? nbaFee : defaultFee;
        bool coinMoves = w != 3 && !paused && !blocked[who] && !blocked[address(games)];
        bool cutRefuses = fee != 0 && coinMoves && cut != 0;
        bool expected = fee == 0 || (coinMoves && cut == 0);
        // Under a cut, the refusal names the balance on each side of the pull.
        uint256 balance = coin.balanceOf(address(games));
        uint256 arrives = cut >= fee ? 0 : fee - cut;
        bytes memory cutRefusal =
            abi.encodeWithSelector(OspexGames.OspexGames__FeeNotReceived.selector, uint256(fee), balance, balance + arrives);

        vm.recordLogs();
        vm.prank(who, who);
        try games.createGame(nba ? "nba" : "nhl", "Home", "Away", BASE, new Hint[](0)) returns (uint256 id) {
            if (!expected || id != created + 1 || coinOf[who] < fee) ++mismatches;
            created = id;
            ghosts[id].creator = who;
            ghosts[id].fee = fee;
            if (coinOf[who] >= fee) coinOf[who] -= fee;
            ++counts[CREATES];
        } catch (bytes memory err) {
            if (expected) ++mismatches;
            if (cutRefuses) {
                if (keccak256(err) != keccak256(cutRefusal)) ++mismatches;
                ++counts[CREATES_CUT_REFUSED];
            }
            ++counts[CREATES_REFUSED];
        }
        _expectNoCredit(vm.getRecordedLogs());
    }

    /// @dev The default fee or nba's own, through the timelock: 0 one time in five.
    function setFee(uint256 seed, uint96 fee) external {
        fee = seed % 5 == 0 ? 0 : uint96(bound(fee, 1, 50_000_000));
        bool nba = seed % 2 == 0;
        Terms memory t = launch;
        t.fee = fee;
        if (!_run(abi.encodeCall(IOspexGames.setTerms, (nba ? "nba" : "", t)))) ++mismatches;
        if (nba) {
            nbaOwn = true;
            nbaFee = fee;
        } else {
            defaultFee = fee;
        }
        ++counts[FEE_CHANGES];
    }

    /// @dev Mostly a first-n reporter; one time in four the after-n reporter, which writes no start.
    function start(uint256 gameSeed, uint256 whoSeed, uint256 offset) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        MockReporter who = whoSeed % 4 == 0 ? i_later : whoSeed % 2 == 0 ? i_first : i_second;
        uint64 s = uint64(BASE + (offset % 2 hours));
        bool expected = _exists(id) && !g.started && !g.ended && who != i_later;

        vm.recordLogs();
        bool ok = _send(address(who), _report(id, ReportKind.Start, s, address(0)));
        if (ok != expected) ++mismatches;
        if (ok && expected) {
            g.started = true;
            g.start = s;
            ++counts[STARTS];
        } else {
            ++counts[STARTS_REFUSED];
        }
        _expectNoCredit(vm.getRecordedLogs());
    }

    /// @dev Three times in four, a game the model has started and not ended, if there is one.
    function score(uint256 gameSeed, uint256 whoSeed, uint256 payoutSeed) external {
        uint256 id = gameSeed % 4 != 0 ? _pickOpenStarted(gameSeed >> 2) : _pickGame(gameSeed >> 2);
        Ghost storage g = ghosts[id];
        address who = _pickSender(whoSeed);
        address to = _pickPayout(payoutSeed, g.creator, who);
        bool isReporter = who == address(i_first) || who == address(i_later) || who == address(i_second);
        bool coinOrReporter = to == address(coin) || _everApproved(to);
        bool payoutTaken = to != address(0) && to != address(games) && !coinOrReporter;
        uint256 nowTs = vm.getBlockTimestamp();
        bool rest = _exists(id) && g.started && !g.ended && isReporter && nowTs >= g.start
            && (who != address(i_later) || nowTs >= uint256(g.start) + WINDOW);
        bool expected = rest && payoutTaken;

        vm.recordLogs();
        bool ok = _send(who, _report(id, ReportKind.Score, 0, to));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok != expected) ++mismatches;
        if (ok && expected) {
            g.ended = true;
            g.paidTo = to;
            credit[to] += g.fee;
            ++counts[SCORES];
            _expectCredit(logs, id, to, g.fee);
        } else {
            ++counts[SCORES_REFUSED];
            if (rest && coinOrReporter) ++counts[PAYOUTS_COIN_OR_REPORTER];
            _expectNoCredit(logs);
        }
    }

    /// @dev Released by anyone at any hour, through the harness's hook: the release call's own rules are not
    ///      built yet.
    function release(uint256 gameSeed, uint256 callerSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address caller = accounts[callerSeed % accounts.length];
        bool expected = _exists(id) && !g.ended;

        vm.recordLogs();
        vm.prank(caller);
        (bool ok,) = address(games).call(abi.encodeCall(OspexGamesHarness.harnessRelease, (id)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok != expected) ++mismatches;
        if (ok && expected) {
            g.ended = true;
            g.paidTo = g.creator;
            credit[g.creator] += g.fee;
            ++counts[RELEASES];
            _expectCredit(logs, id, g.creator, g.fee);
        } else {
            ++counts[RELEASES_REFUSED];
            _expectNoCredit(logs);
        }
    }

    /// @dev A report of a kind the contract does not take, from a reporter, naming any payout: refused.
    function reportOther(uint256 gameSeed, uint256 kindSeed, uint256 payoutSeed) external {
        uint256 id = _pickGame(gameSeed);
        ReportKind kind = [ReportKind.None, ReportKind.Void, ReportKind.Dispute][kindSeed % 3];
        vm.recordLogs();
        bool ok = _send(address(i_first), _report(id, kind, 0, payouts[payoutSeed % 3]));
        if (ok) ++mismatches;
        ++counts[OTHERS_REFUSED];
        _expectNoCredit(vm.getRecordedLogs());
    }

    /// @dev Half the time an address the model holds a credit for, if there is one; otherwise anyone tracked.
    function withdraw(uint256 whoSeed) external {
        address who = whoSeed % 2 == 0 ? _pickCredited(whoSeed >> 1) : accounts[(whoSeed >> 1) % accounts.length];
        uint256 owed = credit[who];
        bool expected = owed > 0 && !paused && !blocked[who] && !blocked[address(games)];
        uint256 kept = cut < owed ? cut : owed;
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        try games.withdraw() returns (uint256 amount) {
            if (!expected || amount != owed || coin.balanceOf(who) != before + owed - kept) ++mismatches;
            credit[who] = 0;
            coinOf[who] += owed - kept;
            coinOf[address(coin)] += kept;
            ++counts[WITHDRAWALS];
        } catch {
            if (expected) ++mismatches;
            ++counts[WITHDRAWALS_REFUSED];
        }
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 12 hours));
    }

    /// @dev Pauses or unpauses the coin, or blocks or unblocks an account or the games set.
    function toggleCoin(uint256 seed) external {
        uint256 k = seed % 3;
        if (k == 0) {
            paused = !paused;
            coin.setPaused(paused);
        } else {
            address a = k == 1 ? accounts[(seed >> 8) % accounts.length] : address(games);
            blocked[a] = !blocked[a];
            coin.setBlocked(a, blocked[a]);
        }
        ++counts[COIN_TOGGLES];
    }

    /// @dev The coin keeps a cut of every transfer, from 1 unit to 3 USDC, half the time; otherwise none.
    function setCut(uint256 seed) external {
        cut = seed % 2 == 0 ? 0 : bound(seed >> 1, 1, 3_000_000);
        coin.setCut(cut);
        ++counts[CUT_CHANGES];
    }

    /// @dev The coin takes every transfer again, whole: unpaused, nothing blocked, no cut.
    function healCoin() external {
        cut = 0;
        coin.setCut(0);
        paused = false;
        coin.setPaused(false);
        for (uint256 i; i < accounts.length; ++i) {
            blocked[accounts[i]] = false;
            coin.setBlocked(accounts[i], false);
        }
        blocked[address(games)] = false;
        coin.setBlocked(address(games), false);
    }

    /// @dev Coin sent to the games set directly, by no game.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 5_000_000);
        bool expected = !paused && !blocked[donor] && !blocked[address(games)];
        uint256 kept = cut < amount ? cut : amount;
        vm.prank(donor);
        try coin.transfer(address(games), amount) {
            if (!expected) ++mismatches;
            donated += amount - kept;
            coinOf[donor] -= amount;
            coinOf[address(coin)] += kept;
            ++counts[DONATIONS];
        } catch {
            if (expected) ++mismatches;
        }
    }

    // ──────────────────────────── Reads for the invariants ─────────────

    function ghostOf(uint256 id) external view returns (Ghost memory) {
        return ghosts[id];
    }

    function accountList() external view returns (address[] memory) {
        return accounts;
    }

    // ──────────────────────────── Internal ─────────────────────────────

    function _mint(address to, uint256 amount) internal {
        coin.mint(to, amount);
        coinOf[to] += amount;
    }

    function _run(bytes memory call) internal returns (bool ok) {
        bytes32 s = bytes32(++salt);
        vm.prank(i_key);
        timelock.schedule(address(games), 0, call, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(stranger);
        try timelock.execute(address(games), 0, call, bytes32(0), s) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// @dev The logs hold one FeeCredited, for this game, account and amount; none at all for a fee of 0.
    function _expectCredit(Vm.Log[] memory logs, uint256 id, address account, uint96 fee) internal {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(games) || logs[i].topics[0] != IOspexGames.FeeCredited.selector) continue;
            ++seen;
            ++ghosts[uint256(logs[i].topics[1])].creditEvents;
            if (uint256(logs[i].topics[1]) != id) ++mismatches;
            if (address(uint160(uint256(logs[i].topics[2]))) != account) ++mismatches;
            if (abi.decode(logs[i].data, (uint256)) != fee) ++mismatches;
        }
        if (seen != (fee == 0 ? 0 : 1)) ++mismatches;
        if (fee == 0) ++counts[ENDS_AT_ZERO];
        else ++counts[CREDITS];
    }

    function _expectNoCredit(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(games) && logs[i].topics[0] == IOspexGames.FeeCredited.selector) {
                ++mismatches;
                ++ghosts[uint256(logs[i].topics[1])].creditEvents;
            }
        }
    }

    function _exists(uint256 id) internal view returns (bool) {
        return id != 0 && id <= created;
    }

    /// @dev Mostly an existing game; sometimes id 0 or the next id, which are not games.
    function _pickGame(uint256 seed) internal view returns (uint256) {
        if (created == 0 || seed % 11 == 0) return seed % 2 == 0 ? 0 : created + 1;
        return 1 + (seed % created);
    }

    /// @dev A game the model has started and not ended, looking from a random one on; any game if none is.
    function _pickOpenStarted(uint256 seed) internal view returns (uint256) {
        if (created == 0) return 0;
        for (uint256 i; i < created; ++i) {
            uint256 id = 1 + ((seed + i) % created);
            if (ghosts[id].started && !ghosts[id].ended) return id;
        }
        return 1 + (seed % created);
    }

    /// @dev An address the model holds a credit for, looking from a random one on; any address if none is.
    function _pickCredited(uint256 seed) internal view returns (address) {
        uint256 n = accounts.length;
        for (uint256 i; i < n; ++i) {
            address a = accounts[(seed + i) % n];
            if (credit[a] != 0) return a;
        }
        return accounts[seed % n];
    }

    /// @dev One of the three reporters, or a stranger.
    function _pickSender(uint256 seed) internal view returns (address) {
        uint256 k = seed % 4;
        return k == 0 ? address(i_first) : k == 1 ? address(i_later) : k == 2 ? address(i_second) : stranger;
    }

    /// @dev One of the three payout addresses, the game's creator, or one the chain refuses: 0, the games set,
    ///      the sender, the coin, a reporter other than the sender, and the retired reporter.
    function _pickPayout(uint256 seed, address gameCreator, address sender) internal view returns (address) {
        uint256 k = seed % 10;
        if (k < 3) return payouts[k];
        if (k == 3) return gameCreator == address(0) ? payouts[0] : gameCreator;
        if (k == 4) return address(0);
        if (k == 5) return address(games);
        if (k == 6) return sender;
        if (k == 7) return address(coin);
        if (k == 8) return sender == address(i_first) ? address(i_second) : address(i_first);
        return address(i_retired);
    }

    /// @dev Every address ever approved as a reporter, as the model knows them.
    function _everApproved(address a) internal view returns (bool) {
        return a == address(i_first) || a == address(i_later) || a == address(i_second) || a == address(i_retired);
    }

    function _report(uint256 id, ReportKind kind, uint64 s, address to) internal pure returns (Report memory r) {
        r.gameId = id;
        r.kind = kind;
        r.start = s;
        r.readings = new Reading[](0);
        r.payout = to;
    }

    function _send(address who, Report memory r) internal returns (bool ok) {
        if (who == address(i_first) || who == address(i_later) || who == address(i_second)) {
            (ok,) = who.call(abi.encodeCall(MockReporter.send, (r)));
        } else {
            vm.prank(who, who);
            (ok,) = address(games).call(abi.encodeCall(IOspexGames.report, (r)));
        }
    }
}

/// @notice The stateful run for the creation fee's routing. After every call of a random sequence of creations,
///         fee changes, starts, scores, refused reports, releases, withdrawals, coin pauses, blocks and cuts,
///         and coin sent in directly: the contract took exactly what the model allows; each game's fee was
///         credited at most once, and once it ended, to the payout address in the report that ended it or to
///         its creator, in the amount it copied at creation; every address's credit and coin read as the model
///         says, the coin's own included; and the coin the games set holds equals the fees of games not yet
///         ended, plus what is credited and not withdrawn, plus what arrived from coin sent to it directly.
contract OspexGamesFeeInvariantTest is GamesBase {
    FeeHandler internal handler;

    function setUp() public override {
        super.setUp();
        // A reporter approved and retired before any game is made: on no game's copy, refused as payout.
        MockReporter retired = new MockReporter(games);
        _approve(address(retired), ReporterKind.AfterN);
        _retire(address(retired));
        handler = new FeeHandler(games, token, timelock, timelockKey, first, later, second, retired, _launchTerms());
        // An hour before the games' date: starts land at once, and after-n scores a day and more later.
        vm.warp(1_800_000_037 - 1 hours);

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = FeeHandler.create.selector;
        selectors[1] = FeeHandler.create.selector; // creation twice as often
        selectors[2] = FeeHandler.setFee.selector;
        selectors[3] = FeeHandler.start.selector;
        selectors[4] = FeeHandler.start.selector;
        selectors[5] = FeeHandler.score.selector;
        selectors[6] = FeeHandler.score.selector;
        selectors[7] = FeeHandler.release.selector;
        selectors[8] = FeeHandler.reportOther.selector;
        selectors[9] = FeeHandler.withdraw.selector;
        selectors[10] = FeeHandler.withdraw.selector;
        selectors[11] = FeeHandler.warp.selector;
        selectors[12] = FeeHandler.toggleCoin.selector;
        selectors[13] = FeeHandler.healCoin.selector;
        selectors[14] = FeeHandler.healCoin.selector; // the coin refuses less often than it takes
        selectors[15] = FeeHandler.donate.selector;
        selectors[16] = FeeHandler.setCut.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// The one stateful run, with every check after every call. One run, so that the per-run summary below
    /// adds up without two campaigns writing at once.
    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 100
    function invariant_theCreationFeesRouting() public view {
        _checkTheModel();
        _checkEachFeeIsCreditedAtMostOnceToTheEndsAddress();
        _checkTheCoinHeldIsWhatIsHeldPlusWhatIsCredited();
    }

    /// @dev After each run, its counts are added to the totals so far, kept in the process's environment
    ///      (the only state a run leaves behind), and the totals are logged. The last line logged is the whole
    ///      campaign's: runs, then each count in FeeHandler's order.
    function afterInvariant() external {
        string memory line = string.concat("fee-campaign runs ", vm.toString(_addToTotal("RUNS", 1)));
        for (uint256 i; i < 19; ++i) {
            line = string.concat(line, " ", vm.toString(_addToTotal(vm.toString(i), handler.counts(i))));
        }
        console.log(line);
    }

    function _addToTotal(string memory key, uint256 amount) internal returns (uint256 total) {
        string memory name = string.concat("OSPEX_FEE_CAMPAIGN_", key);
        total = vm.envOr(name, uint256(0)) + amount;
        vm.setEnv(name, vm.toString(total));
    }

    function _checkTheModel() internal view {
        assertEq(handler.mismatches(), 0, "the contract and the model disagreed");
        assertEq(games.gameCount(), handler.created(), "game count");
    }

    function _checkEachFeeIsCreditedAtMostOnceToTheEndsAddress() internal view {
        uint256 count = handler.created();
        for (uint256 id = 1; id <= count; ++id) {
            FeeHandler.Ghost memory g = handler.ghostOf(id);
            assertLe(g.creditEvents, 1, "a fee credited twice");
            assertEq(g.creditEvents, g.ended && g.fee != 0 ? 1 : 0, "an end that did not credit, or a credit with no end");
            (uint96 held, address creator) = games.getGameFee(id);
            assertEq(held, g.ended ? 0 : g.fee, "held");
            assertEq(creator, g.creator, "creator");
        }
    }

    function _checkTheCoinHeldIsWhatIsHeldPlusWhatIsCredited() internal view {
        uint256 held;
        uint256 count = handler.created();
        for (uint256 id = 1; id <= count; ++id) {
            FeeHandler.Ghost memory g = handler.ghostOf(id);
            if (!g.ended) held += g.fee;
        }
        uint256 owed;
        address[] memory accounts = handler.accountList();
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(games.getCredit(accounts[i]), handler.credit(accounts[i]), "an address's credit");
            owed += handler.credit(accounts[i]);
            if (accounts[i] != address(0)) {
                assertEq(token.balanceOf(accounts[i]), handler.coinOf(accounts[i]), "an address's coin");
            }
        }
        assertEq(games.getCredit(address(games)), 0, "the games set credited itself");
        assertEq(token.balanceOf(address(games)), held + owed + handler.donated(), "held + credited + sent directly");
    }

    /// The model's every path, driven in a fixed order, agrees with the contract: so the random runs above
    /// compare two things that can each say yes, and each say no.
    function test_feeHandlerModelAgreesOnEveryPath() public {
        // create(whoSeed, leagueSeed): who = creators[seed % 4], 3 has no coin; league even = nba.
        handler.create(0, 1); // game 1, nhl, the default 1 USDC
        handler.create(3, 1); // the creator with no coin: refused
        handler.setFee(5, 0); // 5 % 5 == 0: fee 0; odd: the default
        handler.create(3, 1); // game 2: at 0 the creator with no coin creates
        handler.setFee(2, 7_000_000); // even: nba's own, 7
        handler.create(1, 0); // game 3, nba at 7
        handler.toggleCoin(0); // paused
        handler.create(2, 0); // nba at 7, coin paused: refused
        handler.create(2, 1); // game 4, nhl at 0: the paused coin is not called
        handler.toggleCoin(0); // unpaused

        // A game seed picks game 1 + seed % created (seed % 11 == 0 picks no game). With four games: seed 4 is
        // game 1, 1 is game 2, 2 is game 3, 3 is game 4.
        // start(gameSeed, whoSeed, offset): who 0 mod 4 is the after-n reporter, else even first, odd second.
        handler.start(4, 1, 30); // game 1, second: taken
        handler.start(4, 4, 30); // game 1, after-n: refused, and already started besides
        handler.start(2, 0, 30); // game 3, after-n: refused
        handler.start(2, 2, 30); // game 3, first: taken
        handler.start(1, 2, 30); // game 2, first: taken

        // score(gameSeed, whoSeed, payoutSeed): a game seed divisible by 4 picks a game as above from seed / 4;
        // who 0 first, 1 later, 2 second, 3 stranger; payout 0-2 payouts, 3 the creator, 4 address 0, 5 the games
        // set, 6 the sender, 7 the coin, 8 another reporter, 9 the retired reporter.
        for (uint256 i; i < 3; ++i) {
            handler.warp(12 hours); // a day and a half: past every start + n
        }
        handler.score(16, 3, 0); // game 1 from a stranger: refused
        handler.score(16, 0, 4); // payout 0: refused
        handler.score(16, 0, 5); // payout the games set: refused
        handler.score(16, 0, 6); // payout the sender: refused, as a reporter
        handler.score(16, 0, 7); // payout the coin: refused
        handler.score(16, 0, 8); // payout the second reporter: refused
        handler.score(16, 0, 9); // payout the retired reporter: refused
        handler.score(16, 0, 1); // game 1, first, payout 1: taken, 1 USDC
        handler.score(16, 2, 2); // game 1 again: refused
        handler.score(8, 1, 3); // game 3, after-n past start + n, payout its creator: taken, 7
        handler.score(4, 0, 0); // game 2, made at 0: taken, nothing credited
        handler.score(12, 0, 0); // game 4, not started: refused
        handler.reportOther(3, 1, 0); // a void: refused

        // release(gameSeed, callerSeed): anyone.
        handler.release(3, 7); // game 4, not started: taken, made at 0, nothing credited
        handler.release(3, 7); // again: refused
        handler.release(4, 7); // game 1, scored: refused
        handler.create(0, 1); // game 5, nhl at 0
        handler.setFee(1, 3_000_000); // the default, 3
        handler.create(0, 1); // game 6, nhl at 3
        handler.release(5, 8); // six games now: seed 5 is game 6, taken, 3 to creator 0

        // withdraw(whoSeed): an odd seed picks accounts[(seed >> 1) % 15], so 2j + 1 picks account j: 0-3 the
        // creators, 4-6 the payout addresses, 7 the stranger, 8 the donor.
        // toggleCoin(seed): seed % 3 == 1 blocks or unblocks accounts[(seed >> 8) % 15]; 1282 is payout 1.
        handler.toggleCoin(1282); // block payout 1 (account 5)
        handler.withdraw(11); // payout 1, blocked: refused, the credit stays
        handler.toggleCoin(1282); // unblock
        handler.withdraw(11); // payout 1: taken, 1
        handler.withdraw(11); // nothing left: refused
        handler.toggleCoin(2); // block the games set
        handler.withdraw(3); // creator 1: refused
        handler.donate(1_000); // refused: the games set is blocked
        handler.healCoin(); // everything unblocked
        handler.withdraw(3); // creator 1: taken, 7
        handler.withdraw(1); // creator 0: taken, 3
        handler.withdraw(15); // stranger: refused
        handler.donate(1_000); // taken

        // setCut(seed): an odd seed sets a cut of seed >> 1 (here 1 unit), an even one none. The default fee is 3
        // and nba's own 7.
        handler.setCut(3);
        handler.create(0, 1); // nhl at 3, of which the coin keeps 1: refused by name
        handler.create(0, 0); // nba at 7: refused the same
        handler.setFee(5, 0); // the default to 0
        handler.create(0, 1); // game 7, nhl at 0: the coin is not called, so its cut does not matter
        handler.setFee(1, 3_000_000); // the default back to 3
        handler.setCut(0);
        handler.create(0, 1); // game 8, nhl at 3: taken whole
        handler.release(7, 8); // eight games: seed 7 is game 8, 3 to creator 0
        handler.setCut(3);
        handler.withdraw(1); // creator 0: the games set pays 3, the coin keeps 1 of it
        handler.donate(1_000); // 999 arrives
        handler.healCoin(); // no cut

        assertEq(handler.mismatches(), 0, "the contract and the model disagreed");
        assertEq(handler.counts(0), 8, "creations");
        assertEq(handler.counts(1), 4, "creations refused");
        assertEq(handler.counts(17), 2, "creations refused for the cut");
        assertEq(handler.counts(2), 3, "starts");
        assertEq(handler.counts(3), 2, "starts refused");
        assertEq(handler.counts(4), 3, "scores");
        assertEq(handler.counts(5), 9, "scores refused");
        assertEq(handler.counts(18), 4, "scores refused for a payout of the coin or a reporter");
        assertEq(handler.counts(6), 3, "releases");
        assertEq(handler.counts(7), 2, "releases refused");
        assertEq(handler.counts(9), 4, "withdrawals");
        assertEq(handler.counts(10), 4, "withdrawals refused");
        assertEq(handler.counts(14), 4, "fees credited");
        assertEq(handler.counts(15), 2, "ends at a fee of 0");
        assertEq(handler.counts(16), 3, "cut changes");
        assertEq(token.balanceOf(address(games)), 1_999, "the games set holds only what arrived from coin sent to it");
        assertEq(token.balanceOf(address(token)), 2, "the coin kept 1 of the withdrawal and 1 of the donation");
        _checkEachFeeIsCreditedAtMostOnceToTheEndsAddress();
        _checkTheCoinHeldIsWhatIsHeldPlusWhatIsCredited();
    }
}
