// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    Reading,
    Report,
    Hint
} from "../../src/games/IOspexGames.sol";
import {GamesBase, MockReporter, OspexGamesHarness} from "./GamesBase.sol";

/// @dev Drives the games contract at random and keeps its own model of what each call should do. The model
///      is written from the spec's rules, never read back from the contract: a game copies the list the
///      handler last set; only a game's recorded reporters write; a start once, by a first-n reporter, within
///      the window of the date; a score once, after the start, and for an after-n reporter from start + n.
contract GamesHandler is Test {
    struct Ghost {
        address[] reporters;
        uint8[] kinds;
        uint64 date;
        uint64 window;
        uint64 start;
        bool started;
        bool scored;
        uint32 home;
        uint32 away;
        uint256 scoredAt;
        uint8 scorerKind;
    }

    uint32 internal constant MAX_SCORE = 1_000_000;
    uint64 internal constant BASE = 1_800_000_037;

    OspexGamesHarness public immutable games;
    MockReporter[] internal pool;
    address[] internal outsiders;

    // The list and the window the handler last gave the games contract.
    address[] internal curList;
    uint8[] internal curKinds;
    uint64 internal curWindow;

    mapping(uint256 => Ghost) internal ghosts;
    uint256 public created;
    /// @dev Calls where the contract and the model disagreed. Must stay 0.
    uint256 public mismatches;
    uint256 public taken;
    uint256 public refused;
    uint256 public listChanges;
    uint256 public startsTaken;
    uint256 public scoresTaken;

    constructor(
        OspexGamesHarness games_,
        MockReporter[] memory pool_,
        address[] memory outsiders_,
        address[] memory list,
        uint8[] memory kinds,
        uint64 window
    ) {
        games = games_;
        for (uint256 i; i < pool_.length; ++i) {
            pool.push(pool_[i]);
        }
        outsiders = outsiders_;
        curList = list;
        curKinds = kinds;
        curWindow = window;
    }

    // ──────────────────────────── Actions ──────────────────────────────

    function create(uint256 dateSeed) external {
        uint64 date = uint64(bound(dateSeed, BASE - 10 days, BASE + 10 days));
        vm.prank(address(0xC0FFEE), address(0xC0FFEE));
        uint256 id = games.createGame("nba", "Home Team", "Away Team", date, new Hint[](0));
        if (id != created + 1) ++mismatches;
        created = id;
        Ghost storage g = ghosts[id];
        g.reporters = curList;
        g.kinds = curKinds;
        g.date = date;
        g.window = curWindow;
    }

    /// @dev A new approved list, drawn from the pool with random kinds and at least one first-n reporter,
    ///      and sometimes a new window: what approvals, retirements and term changes will do.
    function changeList(uint256 seed, uint256 windowSeed) external {
        uint256 count = bound(seed, 1, pool.length);
        address[] memory list = new address[](count);
        uint8[] memory kinds = new uint8[](count);
        ReporterKind[] memory enumKinds = new ReporterKind[](count);
        uint256 offset = (seed >> 8) % pool.length;
        bool firstN;
        for (uint256 i; i < count; ++i) {
            list[i] = address(pool[(offset + i) % pool.length]);
            kinds[i] = uint8(((seed >> (16 + i)) & 1) + 1);
            if (kinds[i] == 1) firstN = true;
        }
        if (!firstN) kinds[0] = 1;
        for (uint256 i; i < count; ++i) {
            enumKinds[i] = ReporterKind(kinds[i]);
        }
        games.harnessSetApproved(list, enumKinds);
        curList = list;
        curKinds = kinds;
        if (windowSeed % 3 == 0) {
            curWindow = uint64(bound(windowSeed, 1, 3 days));
            games.harnessSetWindow(curWindow);
        }
        ++listChanges;
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 2 days));
    }

    function reportStart(uint256 gameSeed, uint256 whoSeed, uint256 offsetSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        // Mostly inside the window of the date, sometimes just outside it, sometimes 0.
        uint64 start;
        if (offsetSeed % 11 != 0 && g.window != 0) {
            uint256 span = uint256(g.window) * 2 + 3;
            uint256 low = uint256(g.date) > uint256(g.window) + 1 ? uint256(g.date) - g.window - 1 : 0;
            start = uint64(low + (offsetSeed % span));
        }

        Report memory r = _report(id, ReportKind.Start, start, 0, 0);
        bool expected = _exists(id) && _kindOf(g, who) == 1 && !g.started && !g.scored && start != 0
            && uint256(start) + g.window >= g.date && uint256(start) <= uint256(g.date) + g.window;
        bool ok = _send(who, r);
        _check(ok, expected);
        if (ok && expected) {
            g.started = true;
            g.start = start;
            ++startsTaken;
        }
    }

    function reportScore(uint256 gameSeed, uint256 whoSeed, uint32 home, uint32 away) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        // Mostly real scores, sometimes over the limit.
        if (home % 17 != 0) home = home % 200;
        if (away % 19 != 0) away = away % 200;

        uint8 kind = _kindOf(g, who);
        uint256 nowTs = vm.getBlockTimestamp();
        bool expected = _exists(id) && kind != 0 && g.started && !g.scored && home <= MAX_SCORE
            && away <= MAX_SCORE && nowTs >= g.start && (kind != 2 || nowTs >= uint256(g.start) + g.window);
        bool ok = _send(who, _report(id, ReportKind.Score, 0, home, away));
        _check(ok, expected);
        if (ok && expected) {
            g.scored = true;
            g.home = home;
            g.away = away;
            g.scoredAt = nowTs;
            g.scorerKind = kind;
            ++scoresTaken;
        }
    }

    /// @dev A report of a kind this contract does not take, from anyone, to any game.
    function reportOther(uint256 gameSeed, uint256 whoSeed, uint8 kindSeed) external {
        uint256 id = _pickGame(gameSeed);
        address who = _pickSender(whoSeed);
        ReportKind kind = [ReportKind.None, ReportKind.Void, ReportKind.Dispute][kindSeed % 3];
        bool ok = _send(who, _report(id, kind, 0, 0, 0));
        _check(ok, false);
    }

    // ──────────────────────────── Reads for the invariants ─────────────

    function ghostOf(uint256 id) external view returns (Ghost memory) {
        return ghosts[id];
    }

    // ──────────────────────────── Internal ─────────────────────────────

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

    function _kindOf(Ghost storage g, address who) internal view returns (uint8) {
        for (uint256 i; i < g.reporters.length; ++i) {
            if (g.reporters[i] == who) return g.kinds[i];
        }
        return 0;
    }

    function _report(uint256 id, ReportKind kind, uint64 start, uint32 home, uint32 away)
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
        r.payout = address(0xFEE);
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

/// @notice The stateful run. After every call of a random sequence: the contract took exactly what the
///         model allows; every game's reporters and kinds are the list it copied at creation, whatever the
///         list became since; its start and score are the first ones taken; and its status, start, scores
///         and window read as the model says, with the scores readable only once a score was taken.
contract OspexGamesInvariantTest is GamesBase {
    GamesHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockReporter[] memory pool = new MockReporter[](6);
        pool[0] = first;
        pool[1] = later;
        pool[2] = second;
        for (uint256 i = 3; i < 6; ++i) {
            pool[i] = new MockReporter(games);
        }
        address[] memory outsiders = new address[](4);
        outsiders[0] = makeAddr("stranger");
        outsiders[1] = timelockKey;
        outsiders[2] = deployer;
        outsiders[3] = address(0xC0FFEE); // the creator the handler uses
        (address[] memory list, uint8[] memory kinds) = games.harnessApproved();
        handler = new GamesHandler(games, pool, outsiders, list, kinds, WINDOW);
        vm.warp(1_800_000_037 - 2 days);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = GamesHandler.create.selector;
        selectors[1] = GamesHandler.changeList.selector;
        selectors[2] = GamesHandler.warp.selector;
        selectors[3] = GamesHandler.reportStart.selector;
        selectors[4] = GamesHandler.reportScore.selector;
        selectors[5] = GamesHandler.reportOther.selector;
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
            assertEq(games.getGameWindow(id), g.window, "window moved");

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
        handler.create(date); // game 1: first (first-n), later (after-n), second (first-n)
        handler.create(date); // game 2, the same list
        // seed 3 -> game reporter 0 (first); 1 -> reporter 1 (later); 8 -> an outsider (the deployer).
        uint256 inRange = 86_401; // start = date
        handler.reportStart(1, 1, inRange); // after-n start: refused
        handler.reportStart(1, 8, inRange); // outsider: refused
        handler.reportStart(1, 3, 0); // start 0: refused
        handler.reportStart(1, 3, inRange); // taken
        handler.reportStart(1, 3, inRange); // second start: refused
        handler.reportStart(2, 3, inRange); // taken
        handler.reportScore(1, 1, 3, 5); // after-n inside n: refused
        handler.reportScore(2, 3, 7, 9); // first-n at the start: taken
        handler.reportScore(2, 3, 7, 9); // second score: refused
        handler.warp(1 days); // to start + n
        handler.reportScore(1, 1, 3, 5); // after-n from start + n: taken
        handler.changeList(1, 3); // a new list and window for games made from now
        handler.create(date);
        handler.reportOther(1, 3, 1); // a void: not taken here
        assertEq(handler.mismatches(), 0, "the contract and the model disagreed");
        assertEq(handler.startsTaken(), 2, "starts taken");
        assertEq(handler.scoresTaken(), 2, "scores taken");
        assertEq(handler.refused(), 7, "reports refused");
        assertEq(handler.listChanges(), 1, "list changes");
        invariant_everyGameReadsAsItsModel();
    }
}
