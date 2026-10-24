// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    Reading,
    Report,
    Hint,
    Terms
} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";
import {SwappedRelay} from "./ReporterFixtures.sol";

/// @dev A contract with code and no fixed-values read: refused by an approval.
contract NoRead {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Drives the games contract at random and keeps its own model of what each call should do. The model
///      is written from the spec's rules, never read back from the contract:
///      - the list changes only by the timelock's calls, each run through the stock timelock after its delay:
///        an approval needs a kind, an address with code that answers the fixed-values read, the code hash it
///        names, an address never approved, and room on the list; a retirement needs an approved reporter not
///        yet retired, and is for good; a league's terms need a valid league (or none, for the defaults) and
///        clocks in order: n at least a second, the day-7 clock longer than n, the day-30 clock longer than
///        both together and at most a year;
///      - a game's date is at most a year ahead, and a game is made only while the list holds a first-n
///        reporter; it copies the list and its league's terms as they stand;
///      - only a game's recorded reporters write, never one retired since, and never one whose code now hashes
///        otherwise than at its approval; a start once, by a first-n reporter,
///        within a day of the date, with no payout; a score once, after the start, and for an after-n reporter
///        from start + n of the game's own n; and no report takes a silent reading that carries a score.
contract GamesHandler is Test {
    struct Ghost {
        address[] reporters;
        uint8[] kinds;
        uint64 date;
        Terms terms;
        uint64 start;
        bool started;
        bool scored;
        uint32 home;
        uint32 away;
    }

    uint32 internal constant MAX_SCORE = 1_000_000;
    uint64 internal constant BASE = 1_800_000_037;
    uint64 internal constant DAY = 86_400;
    uint64 internal constant YEAR = 31_536_000;
    uint256 internal constant LIST_MAX = 8;
    uint256 internal constant DELAY = 60;

    OspexGamesHarness public immutable games;
    TimelockController public immutable timelock;
    address internal immutable i_key;
    /// @dev Reporters that may be approved: the three first ones and more, past the list's ceiling.
    MockReporter[] internal pool;
    /// @dev Addresses an approval must refuse whatever it names: no code, or no fixed-values read.
    address[] internal unfit;
    address[] internal outsiders;
    string[4] internal leagues = ["nba", "nhl", "mlb", ""];

    // The model of the list and the terms.
    address[] internal curList;
    uint8[] internal curKinds;
    mapping(address => uint8) internal kindOf;
    mapping(address => bool) internal retired;
    mapping(bytes32 => Terms) internal ownTerms;
    Terms internal defaults;
    /// @dev The code a pool reporter has now, its own or the other code, and the one it had when approved.
    bytes internal ownCode;
    bytes internal otherCode;
    bytes32 internal ownHash;
    bytes32 internal otherHash;
    mapping(address => bool) internal swapped;
    mapping(address => bool) internal swappedAtApproval;

    mapping(uint256 => Ghost) internal ghosts;
    uint256 internal salt;
    uint256 public created;
    /// @dev Calls where the contract and the model disagreed. Must stay 0.
    uint256 public mismatches;
    uint256 public taken;
    uint256 public refused;
    uint256 public startsTaken;
    uint256 public scoresTaken;
    uint256 public createsRefused;
    uint256 public approvals;
    uint256 public approvalsRefused;
    uint256 public retirements;
    uint256 public retirementsRefused;
    uint256 public termChanges;
    uint256 public termChangesRefused;
    uint256 public swaps;

    constructor(
        OspexGamesHarness games_,
        TimelockController timelock_,
        address key,
        MockReporter[] memory pool_,
        address[] memory unfit_,
        address[] memory outsiders_,
        Terms memory launch,
        bytes memory otherCode_
    ) {
        games = games_;
        timelock = timelock_;
        i_key = key;
        for (uint256 i; i < pool_.length; ++i) {
            pool.push(pool_[i]);
        }
        unfit = unfit_;
        outsiders = outsiders_;
        // The constructor's list: the first three of the pool, first-n, after-n, first-n.
        uint8[3] memory k = [uint8(1), 2, 1];
        for (uint256 i; i < 3; ++i) {
            curList.push(address(pool_[i]));
            curKinds.push(k[i]);
            kindOf[address(pool_[i])] = k[i];
        }
        defaults = launch;
        ownCode = address(pool_[0]).code;
        ownHash = address(pool_[0]).codehash;
        otherCode = otherCode_;
        otherHash = keccak256(otherCode_);
    }

    // ──────────────────────────── The timelock's calls ─────────────────

    /// @dev Mostly a pool reporter with its own code hash; one time in seven a wrong hash; one time in nine an
    ///      address that cannot be a reporter; one time in eleven no kind.
    function approve(uint256 seed) external {
        address who;
        bool fit = seed % 9 != 0;
        if (fit) who = address(pool[seed % pool.length]);
        else who = unfit[seed % unfit.length];
        uint8 kind = seed % 11 == 0 ? 0 : uint8(((seed >> 8) & 1) + 1);
        bytes32 hash = seed % 7 == 0 ? keccak256(abi.encode(seed)) : who.codehash;

        bool expected = fit && kind != 0 && kindOf[who] == 0 && !retired[who] && curList.length < LIST_MAX
            && hash == who.codehash;
        bool ok = _run(abi.encodeCall(IOspexGames.approveReporter, (who, ReporterKind(kind), hash)));
        if (ok != expected) ++mismatches;
        if (ok) {
            kindOf[who] = kind;
            swappedAtApproval[who] = swapped[who];
            curList.push(who);
            curKinds.push(kind);
            ++approvals;
        } else {
            ++approvalsRefused;
        }
    }

    /// @dev Mostly a pool reporter, approved or not, retired or not.
    function retire(uint256 seed) external {
        address who = address(pool[seed % pool.length]);
        bool expected = kindOf[who] != 0 && !retired[who];
        bool ok = _run(abi.encodeCall(IOspexGames.retireReporter, (who)));
        if (ok != expected) ++mismatches;
        if (ok) {
            retired[who] = true;
            uint256 n = curList.length;
            uint256 i;
            while (curList[i] != who) ++i;
            for (; i + 1 < n; ++i) {
                curList[i] = curList[i + 1];
                curKinds[i] = curKinds[i + 1];
            }
            curList.pop();
            curKinds.pop();
            ++retirements;
        } else {
            ++retirementsRefused;
        }
    }

    /// @dev A league's terms or the defaults. One time in thirteen a league that is not valid; one time in
    ///      seven a clock of 0 or past a year.
    function setTerms(uint256 seed, uint64 w, uint64 d7, uint64 d30, uint96 fee) external {
        string memory league = seed % 13 == 0 ? "NBA" : leagues[seed % 4];
        Terms memory t = Terms({
            window: uint64(bound(w, 1, 3 days)),
            day7Clock: uint64(bound(d7, 1, 10 days)),
            day30Clock: uint64(bound(d30, 1, YEAR)),
            fee: fee
        });
        if (seed % 7 == 3) t.window = 0;
        if (seed % 7 == 4) t.day30Clock = YEAR + 1;
        if (seed % 7 == 5) t.day7Clock = 0;
        bool expected = seed % 13 != 0 && t.window != 0 && t.day7Clock > t.window
            && uint256(t.window) + t.day7Clock < t.day30Clock && t.day30Clock <= YEAR;
        bool ok = _run(abi.encodeCall(IOspexGames.setTerms, (league, t)));
        if (ok != expected) ++mismatches;
        if (ok) {
            if (bytes(league).length == 0) defaults = t;
            else ownTerms[keccak256(bytes(league))] = t;
            ++termChanges;
        } else {
            ++termChangesRefused;
        }
    }

    /// @dev Swaps a pool reporter's code for the other code, or back: what a self-destruct and a redeploy at
    ///      the same address would leave. A reporter writes only while its code is what it was approved with.
    function swapCode(uint256 seed) external {
        address who = address(pool[seed % pool.length]);
        swapped[who] = !swapped[who];
        vm.etch(who, swapped[who] ? otherCode : ownCode);
        ++swaps;
    }

    // ──────────────────────────── Anyone's calls ───────────────────────

    /// @dev Mostly a date near the base; one time in thirteen a date past a year ahead, and one time in thirteen
    ///      a date exactly a year ahead.
    function create(uint256 dateSeed, uint256 leagueSeed) external {
        uint256 nowTs = vm.getBlockTimestamp();
        uint64 date;
        if (dateSeed % 13 == 5) date = uint64(nowTs + YEAR + 1 + (dateSeed % 1000));
        else if (dateSeed % 13 == 6) date = uint64(nowTs + YEAR);
        else date = uint64(bound(dateSeed, BASE - 10 days, BASE + 10 days));
        string memory league = leagues[leagueSeed % 3];
        bool expected = date != 0 && uint256(date) <= nowTs + YEAR && _listHasFirstN();

        vm.prank(address(0xC0FFEE), address(0xC0FFEE));
        try games.createGame(league, "Home Team", "Away Team", date, new Hint[](0)) returns (uint256 id) {
            if (!expected || id != created + 1) ++mismatches;
            created = id;
            Ghost storage g = ghosts[id];
            g.reporters = curList;
            g.kinds = curKinds;
            g.date = date;
            g.terms = termsOf(league);
        } catch {
            if (expected) ++mismatches;
            ++createsRefused;
        }
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 2 days));
    }

    /// @dev shapeSeed: one time in seven the start carries a payout, one time in nine a silent reading carries
    ///      a score.
    function reportStart(uint256 gameSeed, uint256 whoSeed, uint256 offsetSeed, uint256 shapeSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        // Mostly within a day of the date, whatever the game's n; sometimes just outside it; sometimes 0.
        uint64 start;
        if (offsetSeed % 11 != 0 && g.date != 0) {
            uint256 span = uint256(DAY) * 2 + 3;
            uint256 low = uint256(g.date) > uint256(DAY) + 1 ? uint256(g.date) - DAY - 1 : 0;
            start = uint64(low + (offsetSeed % span));
        }

        Report memory r = _report(id, ReportKind.Start, start, 0, 0, shapeSeed);
        if (shapeSeed % 7 == 1) r.payout = address(0xFEE);
        bool expected = _exists(id) && _kindIn(g, who) == 1 && !retired[who] && _codeAsApproved(who)
            && !g.started && !g.scored
            && start != 0 && uint256(start) + DAY >= g.date && uint256(start) <= uint256(g.date) + DAY
            && shapeSeed % 7 != 1 && shapeSeed % 9 != 1;
        bool ok = _send(who, r);
        _check(ok, expected);
        if (ok && expected) {
            g.started = true;
            g.start = start;
            ++startsTaken;
        }
    }

    /// @dev shapeSeed: one time in nine a silent reading carries a score.
    function reportScore(uint256 gameSeed, uint256 whoSeed, uint32 home, uint32 away, uint256 shapeSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        // Mostly real scores, sometimes over the limit.
        if (home % 17 != 0) home = home % 200;
        if (away % 19 != 0) away = away % 200;

        uint8 kind = _kindIn(g, who);
        uint256 nowTs = vm.getBlockTimestamp();
        bool expected = _exists(id) && kind != 0 && !retired[who] && _codeAsApproved(who) && g.started
            && !g.scored && home <= MAX_SCORE
            && away <= MAX_SCORE && nowTs >= g.start && (kind != 2 || nowTs >= uint256(g.start) + g.terms.window)
            && shapeSeed % 9 != 1;
        bool ok = _send(who, _report(id, ReportKind.Score, 0, home, away, shapeSeed));
        _check(ok, expected);
        if (ok && expected) {
            g.scored = true;
            g.home = home;
            g.away = away;
            ++scoresTaken;
        }
    }

    /// @dev A report of a kind this contract does not take, from anyone, to any game.
    function reportOther(uint256 gameSeed, uint256 whoSeed, uint8 kindSeed) external {
        uint256 id = _pickGame(gameSeed);
        address who = _pickSender(whoSeed);
        ReportKind kind = [ReportKind.None, ReportKind.Void, ReportKind.Dispute][kindSeed % 3];
        bool ok = _send(who, _report(id, kind, 0, 0, 0, 0));
        _check(ok, false);
    }

    // ──────────────────────────── Reads for the invariants ─────────────

    function ghostOf(uint256 id) external view returns (Ghost memory) {
        return ghosts[id];
    }

    function list() external view returns (address[] memory, uint8[] memory) {
        return (curList, curKinds);
    }

    function poolMembers() external view returns (MockReporter[] memory) {
        return pool;
    }

    function admission(address who) external view returns (uint8, bool, bytes32) {
        bytes32 hash = kindOf[who] == 0 ? bytes32(0) : swappedAtApproval[who] ? otherHash : ownHash;
        return (kindOf[who], retired[who], hash);
    }

    function everyRetired(uint256 id) external view returns (bool) {
        Ghost storage g = ghosts[id];
        for (uint256 i; i < g.reporters.length; ++i) {
            if (!retired[g.reporters[i]]) return false;
        }
        return true;
    }

    function termsOf(string memory league) public view returns (Terms memory) {
        if (bytes(league).length == 0) return defaults;
        Terms memory own = ownTerms[keccak256(bytes(league))];
        return own.window != 0 ? own : defaults;
    }

    function leagueAt(uint256 i) external view returns (string memory) {
        return leagues[i];
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev K schedules the call, the delay passes, a stranger runs it. True if it ran.
    function _run(bytes memory call) internal returns (bool ok) {
        bytes32 s = bytes32(++salt);
        vm.prank(i_key);
        timelock.schedule(address(games), 0, call, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(address(0x5157));
        try timelock.execute(address(games), 0, call, bytes32(0), s) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// @dev Whether `who` has the code it was approved with. Only pool reporters ever have their code swapped.
    function _codeAsApproved(address who) internal view returns (bool) {
        return swapped[who] == swappedAtApproval[who];
    }

    function _listHasFirstN() internal view returns (bool) {
        for (uint256 i; i < curKinds.length; ++i) {
            if (curKinds[i] == 1) return true;
        }
        return false;
    }

    function _check(bool ok, bool expected) internal {
        if (ok != expected) ++mismatches;
        if (ok) ++taken;
        else ++refused;
    }

    function _exists(uint256 id) internal view returns (bool) {
        return id != 0 && id <= created;
    }

    /// @dev Mostly an existing game; sometimes id 0 or the next id, which are not games.
    function _pickGame(uint256 seed) internal view returns (uint256) {
        if (created == 0 || seed % 13 == 0) return seed % 2 == 0 ? 0 : created + 1;
        return 1 + (seed % created);
    }

    /// @dev Three times in four, one of the game's own reporters; otherwise anyone in the pool or outside it.
    function _pickSenderFor(Ghost storage g, uint256 seed) internal view returns (address) {
        if (seed % 4 != 0 && g.reporters.length != 0) return g.reporters[seed % g.reporters.length];
        return _pickSender(seed);
    }

    function _pickSender(uint256 seed) internal view returns (address) {
        uint256 total = pool.length + outsiders.length;
        uint256 i = seed % total;
        return i < pool.length ? address(pool[i]) : outsiders[i - pool.length];
    }

    function _kindIn(Ghost storage g, address who) internal view returns (uint8) {
        for (uint256 i; i < g.reporters.length; ++i) {
            if (g.reporters[i] == who) return g.kinds[i];
        }
        return 0;
    }

    /// @dev One silent reading, at 0-0 unless shapeSeed says otherwise. A start pays nothing; any other kind
    ///      names a payout.
    function _report(uint256 id, ReportKind kind, uint64 start, uint32 home, uint32 away, uint256 shapeSeed)
        internal
        pure
        returns (Report memory r)
    {
        r.gameId = id;
        r.kind = kind;
        r.start = start;
        r.homeScore = home;
        r.awayScore = away;
        r.readings = new Reading[](1);
        if (shapeSeed % 9 == 1) r.readings[0].homeScore = 1;
        if (kind != ReportKind.Start) r.payout = address(0xFEE);
    }

    function _send(address who, Report memory r) internal returns (bool ok) {
        bool isPool;
        for (uint256 i; i < pool.length; ++i) {
            if (address(pool[i]) == who) isPool = true;
        }
        if (isPool) {
            (ok,) = who.call(abi.encodeCall(MockReporter.send, (r)));
        } else {
            vm.prank(who, who);
            (ok,) = address(games).call(abi.encodeCall(IOspexGames.report, (r)));
        }
    }
}

/// @notice The stateful run. After every call of a random sequence: the contract took exactly what the model
///         allows; the approved list, each reporter's standing and each league's terms read as the model says;
///         every game's reporters, kinds and terms are what it copied at creation, whatever the list and the
///         terms became since, so no term change or approval reaches a game already made; a retired reporter
///         wrote nothing more to any game, and a game whose every reporter is retired reads as such at once;
///         and every game's status, start and scores read as the model says.
contract OspexGamesInvariantTest is GamesBase {
    GamesHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockReporter[] memory pool = new MockReporter[](11);
        pool[0] = first;
        pool[1] = later;
        pool[2] = second;
        for (uint256 i = 3; i < pool.length; ++i) {
            pool[i] = new MockReporter(games);
        }
        address[] memory unfit = new address[](3);
        unfit[0] = makeAddr("a wallet");
        unfit[1] = address(new NoRead());
        unfit[2] = makeAddr("a delegated wallet");
        vm.etch(unfit[2], abi.encodePacked(hex"ef0100", address(pool[3])));
        address[] memory outsiders = new address[](5);
        outsiders[0] = stranger;
        outsiders[1] = timelockKey;
        outsiders[2] = deployer;
        outsiders[3] = address(0xC0FFEE); // the creator the handler uses
        outsiders[4] = address(timelock);
        bytes memory otherCode = address(new SwappedRelay(games)).code;
        handler =
            new GamesHandler(games, timelock, timelockKey, pool, unfit, outsiders, _launchTerms(), otherCode);
        // The handler's creator pays any fee the run sets, up to the largest a term can name, every game of a run.
        token.mint(address(0xC0FFEE), type(uint128).max);
        vm.prank(address(0xC0FFEE));
        token.approve(address(games), type(uint256).max);
        vm.warp(1_800_000_037 - 2 days);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = GamesHandler.create.selector;
        selectors[1] = GamesHandler.approve.selector;
        selectors[2] = GamesHandler.retire.selector;
        selectors[3] = GamesHandler.setTerms.selector;
        selectors[4] = GamesHandler.warp.selector;
        selectors[5] = GamesHandler.reportStart.selector;
        selectors[6] = GamesHandler.reportScore.selector;
        selectors[7] = GamesHandler.reportOther.selector;
        selectors[8] = GamesHandler.create.selector; // creation twice as often
        selectors[9] = GamesHandler.swapCode.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_theContractTakesExactlyWhatTheModelAllows() public view {
        assertEq(handler.mismatches(), 0, "the contract and the model disagreed");
        assertEq(games.gameCount(), handler.created(), "game count");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_theListAndTheTermsReadAsTheModel() public view {
        (address[] memory wantList, uint8[] memory wantKinds) = handler.list();
        (address[] memory r, uint8[] memory k) = games.getApprovedReporters();
        assertEq(r, wantList, "the approved list");
        assertEq(k.length, wantKinds.length, "the approved kinds");
        for (uint256 i; i < k.length; ++i) {
            assertEq(k[i], wantKinds[i], "an approved kind");
        }
        MockReporter[] memory pool = handler.poolMembers();
        for (uint256 i; i < pool.length; ++i) {
            (uint8 kind, bool isRetired, bytes32 hash) = handler.admission(address(pool[i]));
            (ReporterKind gotKind, bool gotRetired, bytes32 gotHash) = games.getReporter(address(pool[i]));
            assertEq(uint8(gotKind), kind, "a reporter's kind");
            assertEq(gotRetired, isRetired, "a reporter's retirement");
            assertEq(gotHash, hash, "a reporter's stored code hash");
        }
        for (uint256 i; i < 4; ++i) {
            string memory league = handler.leagueAt(i);
            _assertTerms(games.getTerms(league), handler.termsOf(league), "a league's terms");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_everyGameReadsAsItsModel() public view {
        uint256 count = handler.created();
        for (uint256 id = 1; id <= count; ++id) {
            GamesHandler.Ghost memory g = handler.ghostOf(id);

            (address[] memory r, uint8[] memory k) = games.getGameReporters(id);
            assertEq(r.length, g.reporters.length, "reporter count moved");
            for (uint256 i; i < r.length; ++i) {
                assertEq(r[i], g.reporters[i], "a reporter moved");
                assertEq(k[i], g.kinds[i], "a kind moved");
            }
            _assertTerms(games.getGameTerms(id), g.terms, "a game's terms moved");
            assertEq(games.getGameWindow(id), g.terms.window, "window moved");
            assertEq(_rawDate(id), g.date, "a game's date moved"); // no read returns it: from storage
            assertEq(games.isEveryReporterRetired(id), handler.everyRetired(id), "every reporter retired");

            GameStatus want = g.scored ? GameStatus.Scored : g.started ? GameStatus.Verified : GameStatus.Unverified;
            assertEq(uint8(games.getGameStatus(id)), uint8(want), "status");

            if (g.started) {
                assertEq(games.getGameStart(id), g.start, "start moved");
            } else {
                try games.getGameStart(id) returns (uint64) {
                    revert("a start read with no start written");
                } catch {}
            }

            if (g.scored) {
                (uint32 h, uint32 a) = games.getGameScores(id);
                assertEq(h, g.home, "home moved");
                assertEq(a, g.away, "away moved");
            } else {
                try games.getGameScores(id) returns (uint32, uint32) {
                    revert("unscored game read as scored");
                } catch {}
            }
        }
    }

    /// The model's every path, driven in a fixed order, agrees with the contract: so the random runs above
    /// compare two things that can each say yes, and each say no.
    function test_handlerModelAgreesOnEveryPath() public {
        uint64 date = uint64(1_800_000_037 - 2 days); // the handler's clock starts here
        handler.create(date, 0); // game 1, nba: first (first-n), later (after-n), second (first-n)
        handler.create(date, 0); // game 2, the same list
        // seed 3 -> game reporter 0 (first); 1 -> reporter 1 (later); 8 -> pool 8, not one of game 1's.
        uint256 inRange = 86_401; // start = date
        // shape 0: clean; 8: a payout on a start; 10: a silent reading with a score.
        handler.reportStart(1, 1, inRange, 0); // after-n start: refused
        handler.reportStart(1, 8, inRange, 0); // outsider: refused
        handler.reportStart(1, 3, 0, 0); // start 0: refused
        handler.reportStart(1, 3, inRange, 8); // a payout on a start: refused
        handler.reportStart(1, 3, inRange, 10); // a silent reading with a score: refused
        handler.reportStart(1, 3, inRange, 0); // taken
        handler.reportStart(1, 3, inRange, 0); // second start: refused
        handler.reportStart(2, 3, inRange, 0); // taken
        handler.reportScore(1, 1, 3, 5, 0); // after-n inside n: refused
        handler.reportScore(2, 3, 7, 9, 10); // a silent reading with a score: refused
        handler.reportScore(2, 3, 7, 9, 0); // first-n at the start: taken
        handler.reportScore(2, 3, 7, 9, 0); // second score: refused
        handler.warp(1 days); // to start + n
        handler.reportScore(1, 1, 3, 5, 0); // after-n from start + n: taken

        // The timelock's calls. An approval's seed picks pool[seed % 11]; a seed divisible by 9 an unfit address,
        // by 7 a wrong hash, by 11 no kind; bit 8 clear first-n.
        handler.approve(1); // pool 1 (later), already approved: refused
        handler.approve(3); // pool 3 with its own hash, first-n: taken
        handler.approve(25); // pool 3 again: already approved: refused
        handler.approve(28); // pool 6 with a wrong hash: refused
        handler.approve(9); // a wallet: refused
        handler.approve(55); // no kind: refused
        handler.retire(1); // later: taken
        handler.retire(1); // later again: refused, retirement is for good
        handler.approve(12); // pool 1 (later) again: refused, retired
        handler.retire(5); // pool 5, never approved: refused
        // A terms seed picks leagues[seed % 4] ("" is the defaults); divisible by 13 "NBA"; 3 to 5 mod 7 a bad clock.
        handler.setTerms(1, 2 hours, 3 days, 20 days, 5); // nhl's own terms: taken
        handler.setTerms(7, 3 hours, 4 days, 25 days, 0); // the defaults: taken
        handler.setTerms(13, 1 hours, 1 days, 1 days, 0); // "NBA": refused
        handler.setTerms(17, 1 hours, 1 days, 1 days, 0); // 17 % 7 = 3, a window of 0: refused
        handler.create(date, 1); // game 3, nhl: its own terms; first, second, pool 3
        handler.create(date, 0); // game 4, nba: the new defaults
        handler.create(5, 2); // a date past a year ahead: refused
        handler.create(6, 2); // a date exactly a year ahead: game 5
        // A code swap: game 3's first reporter (first) is refused while its code is other, and writes once it
        // is back. A reporter never approved, given the other code, is approved with that code's hash.
        handler.swapCode(0); // first takes the other code
        handler.reportStart(3, 3, inRange, 0); // first on game 3, its code changed: refused
        handler.swapCode(0); // first's own code back
        handler.reportStart(3, 3, inRange, 0); // first on game 3: taken
        handler.swapCode(7); // pool 7, never approved, takes the other code
        handler.approve(260); // pool 7 (260 % 11), after-n (bit 8 set), with its code's hash: taken
        handler.reportOther(1, 3, 1); // a void: not taken here

        // Every reporter of game 1 retired: it reads so at once, and its first-n reporter writes nothing more.
        handler.retire(0); // first
        handler.retire(2); // second
        handler.reportStart(3, 3, inRange, 0); // first on game 3: retired, refused
        assertTrue(games.isEveryReporterRetired(1), "game 1's reporters are all retired");
        assertFalse(games.isEveryReporterRetired(3), "game 3 keeps pool 3");
        handler.retire(3); // pool 3: the list holds no first-n reporter now
        handler.create(date, 0); // refused: no start could be written

        assertEq(handler.mismatches(), 0, "the contract and the model disagreed");
        assertEq(handler.startsTaken(), 3, "starts taken");
        assertEq(handler.scoresTaken(), 2, "scores taken");
        assertEq(handler.refused(), 12, "reports refused");
        assertEq(handler.createsRefused(), 2, "creations refused");
        assertEq(handler.created(), 5, "games made");
        assertEq(handler.approvals(), 2, "approvals");
        assertEq(handler.approvalsRefused(), 6, "approvals refused");
        assertEq(handler.retirements(), 4, "retirements");
        assertEq(handler.retirementsRefused(), 2, "retirements refused");
        assertEq(handler.termChanges(), 2, "term changes");
        assertEq(handler.termChangesRefused(), 2, "term changes refused");
        assertEq(handler.swaps(), 3, "code swaps");
        assertTrue(games.isEveryReporterRetired(3), "game 3's reporters are all retired");
        invariant_everyGameReadsAsItsModel();
        invariant_theListAndTheTermsReadAsTheModel();
    }
}
