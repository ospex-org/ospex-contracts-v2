// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    ReadingKind,
    Reading,
    Report,
    Hint,
    Terms,
    OpenGame
} from "../../src/games/IOspexGames.sol";
import {GamesBase, GameWords, MockReporter, OspexGamesHarness} from "./GamesBase.sol";
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
///        from start + n of the game's own n; and no report takes a silent reading that carries a score, or two
///        readings for one seat;
///      - a score's readings support it: as many finals reading the score as the program scores on at the game's
///        clock, three inside n and on a disputed game, two from start + n on a game with no record, and no final
///        reading otherwise except on a disputed game from its day-7 clock; a void carries no finals that agree
///        in that count, at hour 24 or at day 7;
///      - a void from start + n of the game's own n, for either kind, and on a disputed game only once its own
///        day-7 clock has run from the record; a dispute record after the start (an after-n reporter's from
///        start + n), with no payout, the first writing the record's time and every later one an update that
///        writes nothing; every report refused from the game's own day-30 clock, counted from its date; a release
///        by anyone from that clock, or at once when every one of its reporters that could still write to it is
///        retired: every first-n reporter for a game with no start, every reporter otherwise;
///      - every game ends once, as a score, a void or a release, and after its end nothing more is written to it:
///        no report of any kind is taken, no release, and its storage stays word for word what it was at the end.
contract GamesHandler is Test {
    struct Ghost {
        address[] reporters;
        uint8[] kinds;
        uint64 date;
        Terms terms;
        uint64 start;
        bool started;
        bool disputed;
        uint64 disputedAt;
        bool scored;
        bool voided;
        bool released;
        uint32 home;
        uint32 away;
        /// @dev The game's storage, word for word, at the moment it ended.
        bytes32 endedRaw;
        /// @dev The readings the taken start carried, and each seat's last vote folded from the dispute reports
        ///      taken, by the program's rule: a reading that is not silent replaces the seat's entry or adds one.
        Reading[] startReadings;
        Reading[] votes;
        /// @dev The league the game was created in; its teams are always "Home Team" and "Away Team", no hints.
        string league;
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
    /// @dev The hash of the readings of every dispute report each game took: a repeat is refused.
    mapping(uint256 => mapping(bytes32 => bool)) internal disputeTaken;
    uint256 internal salt;
    uint256 public created;
    uint256 public disputesRepeated;
    /// @dev Calls where the contract and the model disagreed. Must stay 0.
    uint256 public mismatches;
    uint256 public taken;
    uint256 public refused;
    uint256 public startsTaken;
    uint256 public scoresTaken;
    uint256 public voidsTaken;
    uint256 public disputesTaken;
    uint256 public releasesTaken;
    uint256 public releasesRefused;
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
        try games.createGame(league, "Home Team", "Away Team", date, new Hint[](0), type(uint256).max) returns (uint256 id) {
            if (!expected || id != created + 1) ++mismatches;
            created = id;
            Ghost storage g = ghosts[id];
            g.reporters = curList;
            g.kinds = curKinds;
            g.date = date;
            g.terms = termsOf(league);
            g.league = league;
        } catch {
            if (expected) ++mismatches;
            ++createsRefused;
        }
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 2 days));
    }

    /// @dev A longer step, so the day-7 and day-30 clocks of the terms this run sets can run inside a sequence.
    function warpLong(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 20 days));
    }

    /// @dev shapeSeed: one time in seven the start carries a payout, one time in nine a silent reading carries
    ///      a score, one time in eleven two readings name one seat. Refused from the game's day-30 clock.
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
        if (shapeSeed % 7 == 1) r.payout = address(0xFEE00);
        bool expected = _exists(id) && _kindIn(g, who) == 1 && !retired[who] && _codeAsApproved(who)
            && !g.started && !_ended(g)
            && start != 0 && uint256(start) + DAY >= g.date && uint256(start) <= uint256(g.date) + DAY
            && _open(g) && shapeSeed % 7 != 1 && _readingsFine(shapeSeed);
        bool ok = _send(who, r);
        _check(ok, expected);
        if (ok && expected) {
            g.started = true;
            g.start = start;
            for (uint256 i; i < r.readings.length; ++i) {
                g.startReadings.push(r.readings[i]);
            }
            ++startsTaken;
        }
    }

    /// @dev shapeSeed: one time in nine a silent reading carries a score, one time in eleven two readings name one
    ///      seat; and by shapeSeed % 13 the readings behind the score: 1 two finals reading it beside silents,
    ///      which settles a game with no record from start + n and nothing else; 2 three finals reading it beside one
    ///      reading otherwise, which settles a disputed game from its day-7 clock and nothing else; 3 three finals
    ///      reading something else, never taken; otherwise three finals reading it beside a silent. A disputed game
    ///      takes a score like any other, on those readings. Refused from the game's day-30 clock.
    function reportScore(uint256 gameSeed, uint256 whoSeed, uint32 home, uint32 away, uint256 shapeSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        // Mostly real scores, sometimes over the limit.
        if (home % 17 != 0) home = home % 200;
        if (away % 19 != 0) away = away % 200;

        uint8 kind = _kindIn(g, who);
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 m = shapeSeed % 13;
        bool day7 = g.disputed && nowTs >= uint256(g.disputedAt) + g.terms.day7Clock;
        bool supported = m == 1
            ? !g.disputed && nowTs >= uint256(g.start) + g.terms.window
            : m == 2 ? day7 : m != 3;
        bool expected = _exists(id) && kind != 0 && !retired[who] && _codeAsApproved(who) && g.started
            && !_ended(g) && home <= MAX_SCORE
            && away <= MAX_SCORE && _open(g) && nowTs >= g.start
            && (kind != 2 || nowTs >= uint256(g.start) + g.terms.window) && _readingsFine(shapeSeed) && supported;
        bool ok = _send(who, _report(id, ReportKind.Score, 0, home, away, shapeSeed));
        _check(ok, expected);
        if (ok && expected) {
            g.scored = true;
            g.home = home;
            g.away = away;
            ++scoresTaken;
            _recordEnd(id);
        }
    }

    /// @dev A void: from start + n of the game's own n for either kind, and on a disputed game only once its own
    ///      day-7 clock has run from the record; refused from the game's day-30 clock. shapeSeed: one time in
    ///      nine a silent reading carries a score; one time in eleven two readings name one seat; one time in
    ///      seven the void carries a score of its own, which is refused; one time in thirteen (% 13 == 1) its
    ///      readings are three finals that agree, refused at either clock.
    function reportVoid(uint256 gameSeed, uint256 whoSeed, uint256 shapeSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        uint8 kind = _kindIn(g, who);
        uint256 nowTs = vm.getBlockTimestamp();
        Report memory r = _report(id, ReportKind.Void, 0, 0, 0, shapeSeed);
        if (shapeSeed % 7 == 1) r.homeScore = 3;
        bool expected = _exists(id) && kind != 0 && !retired[who] && _codeAsApproved(who) && g.started
            && !_ended(g) && _open(g) && nowTs >= uint256(g.start) + g.terms.window
            && (!g.disputed || nowTs >= uint256(g.disputedAt) + g.terms.day7Clock) && shapeSeed % 7 != 1
            && _readingsFine(shapeSeed) && shapeSeed % 13 != 1;
        bool ok = _send(who, r);
        _check(ok, expected);
        if (ok && expected) {
            g.voided = true;
            ++voidsTaken;
            _recordEnd(id);
        }
    }

    /// @dev A dispute record, or an update to one, with no payout; one time in seven it names a payout, which is
    ///      refused. Taken after the start, for an after-n reporter from start + n, and refused from the game's
    ///      day-30 clock. The first record writes the time the day-7 clock counts from; an update writes no
    ///      status and moves no clock. Seat 1's vote takes one of four values from the seed, so that a report can
    ///      repeat a game's earlier one: a repeat is refused, whoever sends it and at whatever hour. Few sequences
    ///      reach a dispute at all (time moves past most start windows: in one sequence of 5,000 calls, 95 games
    ///      were created, 3 started and none disputed), so the repeat refusal is proven by the never-line test and
    ///      by the scripted path below, not by the campaign.
    function reportDispute(uint256 gameSeed, uint256 whoSeed, uint256 shapeSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address who = _pickSenderFor(g, whoSeed);
        uint8 kind = _kindIn(g, who);
        uint256 nowTs = vm.getBlockTimestamp();
        Report memory r = _report(id, ReportKind.Dispute, 0, 0, 0, shapeSeed);
        r.payout = shapeSeed % 7 == 1 ? address(0xFEE00) : address(0);
        bytes32 readings = keccak256(abi.encode(r.readings));
        bool repeat = disputeTaken[id][readings];
        bool otherwise = _exists(id) && kind != 0 && !retired[who] && _codeAsApproved(who) && g.started
            && !_ended(g) && _open(g) && nowTs >= g.start
            && (kind != 2 || nowTs >= uint256(g.start) + g.terms.window) && shapeSeed % 7 != 1
            && _readingsFine(shapeSeed);
        bool expected = otherwise && !repeat;
        bool ok = _send(who, r);
        _check(ok, expected);
        if (ok && expected) {
            if (!g.disputed) {
                g.disputed = true;
                g.disputedAt = uint64(nowTs);
            }
            disputeTaken[id][readings] = true;
            _fold(g.votes, r.readings);
            ++disputesTaken;
        } else if (!ok && otherwise && repeat) {
            ++disputesRepeated; // refused for the repeat alone
        }
    }

    /// @dev The program's fold of a dispute report into each seat's last vote: a reading that is not silent
    ///      replaces the seat's entry or adds one; a silent reading changes nothing.
    function _fold(Reading[] storage votes, Reading[] memory readings) internal {
        for (uint256 i; i < readings.length; ++i) {
            if (readings[i].kind == ReadingKind.Silent) continue;
            uint256 j;
            while (j < votes.length && votes[j].seat != readings[i].seat) ++j;
            if (j < votes.length) votes[j] = readings[i];
            else votes.push(readings[i]);
        }
    }

    /// @dev A release, by anyone in the pool or outside it: once the game's own day-30 clock has run from its
    ///      date, or at once when every one of its reporters that could still write to it is retired.
    function release(uint256 gameSeed, uint256 callerSeed) external {
        uint256 id = _pickGame(gameSeed);
        Ghost storage g = ghosts[id];
        address caller = _pickSender(callerSeed);
        uint256 opensAt = uint256(g.date) + g.terms.day30Clock;
        bool expected = _exists(id) && !_ended(g) && (vm.getBlockTimestamp() >= opensAt || _everyRetired(g));
        vm.prank(caller, caller);
        (bool ok,) = address(games).call(abi.encodeCall(IOspexGames.release, (id)));
        if (ok != expected) ++mismatches;
        if (ok && expected) {
            g.released = true;
            ++releasesTaken;
            _recordEnd(id);
        } else {
            ++releasesRefused;
        }
    }

    /// @dev A report with no kind, from anyone, to any game: refused.
    function reportOther(uint256 gameSeed, uint256 whoSeed) external {
        uint256 id = _pickGame(gameSeed);
        address who = _pickSender(whoSeed);
        bool ok = _send(who, _report(id, ReportKind.None, 0, 0, 0, 0));
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
        return _everyRetired(ghosts[id]);
    }

    /// @dev Whether the model has the game ended, as a score, a void or a release.
    function ended(uint256 id) external view returns (bool) {
        return _ended(ghosts[id]);
    }

    function termsOf(string memory league) public view returns (Terms memory) {
        if (bytes(league).length == 0) return defaults;
        Terms memory own = ownTerms[keccak256(bytes(league))];
        return own.window != 0 ? own : defaults;
    }

    function leagueAt(uint256 i) external view returns (string memory) {
        return leagues[i];
    }

    /// @dev The league the model created a game in.
    function leagueOf(uint256 id) external view returns (string memory) {
        return ghosts[id].league;
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

    function _ended(Ghost storage g) internal view returns (bool) {
        return g.scored || g.voided || g.released;
    }

    /// @dev Whether the game's day-30 clock, from its date, has not run: before it a report may land, from it
    ///      only the release.
    function _open(Ghost storage g) internal view returns (bool) {
        return vm.getBlockTimestamp() < uint256(g.date) + g.terms.day30Clock;
    }

    /// @dev Whether a report's readings pass the checks every kind makes: no silent reading carrying a score
    ///      (shapeSeed % 9 == 1 plants one) and no seat twice (% 11 == 1 plants one).
    function _readingsFine(uint256 shapeSeed) internal pure returns (bool) {
        return shapeSeed % 9 != 1 && shapeSeed % 11 != 1;
    }

    /// @dev Every reporter that could still write to the game is retired: for a game with no start, every first-n
    ///      reporter (an after-n one writes no start); otherwise every reporter.
    function _everyRetired(Ghost storage g) internal view returns (bool) {
        for (uint256 i; i < g.reporters.length; ++i) {
            if (!g.started && g.kinds[i] == 2) continue;
            if (!retired[g.reporters[i]]) return false;
        }
        return true;
    }

    /// @dev Keeps the game's storage, word for word, as it stands at its end: nothing may write it afterwards.
    function _recordEnd(uint256 id) internal {
        ghosts[id].endedRaw = keccak256(GameWords.raw(address(games), id));
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

    /// @dev Four readings, seats 1 to 4, in the shape the program sends for the kind: a start's are the shape of
    ///      a game in play (two finals, one answer without a final, one silent); a score's three finals reading
    ///      the score beside a silent; a void's three answers without a final beside a silent; a dispute report's
    ///      two finals that differ beside an answer without a final and a silent. Then shapeSeed's faults: % 9 == 1
    ///      a silent reading carrying a score; % 11 == 1 two readings naming seat 1; and for a score by % 13: 1
    ///      two finals beside silents, 2 a dissenting fourth final, 3 three finals reading another score; for a
    ///      void, % 13 == 1 three finals that agree. A start pays nothing; any other kind names a payout.
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
        Reading[] memory readings = new Reading[](4);
        for (uint256 i; i < 4; ++i) {
            readings[i].seat = uint8(i + 1);
        }
        if (kind == ReportKind.Score) {
            for (uint256 i; i < 3; ++i) {
                readings[i] = Reading({seat: uint8(i + 1), kind: ReadingKind.AnsweredFinal, homeScore: home, awayScore: away});
            }
            uint256 m = shapeSeed % 13;
            if (m == 1) {
                readings[2].kind = ReadingKind.Silent;
                readings[2].homeScore = 0;
                readings[2].awayScore = 0;
            } else if (m == 2) {
                readings[3] = Reading({seat: 4, kind: ReadingKind.AnsweredFinal, homeScore: home ^ 1, awayScore: away});
            } else if (m == 3) {
                for (uint256 i; i < 3; ++i) {
                    readings[i].homeScore = home ^ 1; // another score, whatever the home score is
                }
            }
        } else if (kind == ReportKind.Void) {
            for (uint256 i; i < 3; ++i) {
                readings[i].kind = ReadingKind.AnsweredNoFinal;
            }
            if (shapeSeed % 13 == 1) {
                for (uint256 i; i < 3; ++i) {
                    readings[i] = Reading({seat: uint8(i + 1), kind: ReadingKind.AnsweredFinal, homeScore: 5, awayScore: 5});
                }
            }
        } else {
            // A dispute report's seat 1 votes one of four finals, by the seed's high bits, so that a later report
            // can repeat a game's earlier one or change its vote.
            uint32 vote = 7 + uint32((shapeSeed >> 16) % 4);
            readings[0] = Reading({seat: 1, kind: ReadingKind.AnsweredFinal, homeScore: vote, awayScore: 3});
            readings[1] = Reading({seat: 2, kind: ReadingKind.AnsweredFinal, homeScore: 7, awayScore: 4});
            readings[2] = Reading({seat: 3, kind: ReadingKind.AnsweredNoFinal, homeScore: 6, awayScore: 3});
        }
        if (shapeSeed % 9 == 1) {
            readings[3].kind = ReadingKind.Silent;
            readings[3].homeScore = 1;
            readings[3].awayScore = 0;
        }
        if (shapeSeed % 11 == 1) readings[3].seat = 1;
        r.readings = readings;
        if (kind != ReportKind.Start) r.payout = address(0xFEE00);
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
///         every game's status, start, scores and dispute record read as the model says; every game ends at
///         most once, by its own clocks, and after its end nothing more is written to it, its storage word for
///         word included, with retirements, updates, late scores and releases in the mix.
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

        bytes4[] memory selectors = new bytes4[](16);
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
        selectors[10] = GamesHandler.reportStart.selector; // starts twice as often: the ends need them
        selectors[11] = GamesHandler.reportVoid.selector;
        selectors[12] = GamesHandler.reportDispute.selector;
        selectors[13] = GamesHandler.reportDispute.selector; // records and updates
        selectors[14] = GamesHandler.release.selector;
        selectors[15] = GamesHandler.warpLong.selector;
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

            GameStatus want = g.released
                ? GameStatus.Released
                : g.voided
                    ? GameStatus.Voided
                    : g.scored
                        ? GameStatus.Scored
                        : g.disputed ? GameStatus.Disputed : g.started ? GameStatus.Verified : GameStatus.Unverified;
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

            if (g.disputed) {
                assertEq(games.getGameDisputedAt(id), g.disputedAt, "the dispute record's time moved");
            } else {
                try games.getGameDisputedAt(id) returns (uint64) {
                    revert("a dispute record read with none written");
                } catch {}
            }

            // What a scorer picks up: the identity as the handler created it, the start's readings as the taken
            // start carried them, each seat's last vote as the model folds the dispute reports taken, the
            // record's time beside them (0 until a record).
            (string memory league, string memory home, string memory away, uint64 date, Hint[] memory hints) =
                games.getGameIdentity(id);
            assertEq(league, handler.leagueOf(id), "a game's league moved");
            assertEq(home, "Home Team", "a game's home team moved");
            assertEq(away, "Away Team", "a game's away team moved");
            assertEq(date, g.date, "a game's date moved");
            assertEq(hints.length, 0, "a game's hints moved");
            (Reading[] memory startReadings, Reading[] memory votes, uint64 disputedAt) = games.getGameReadings(id);
            _assertSameReadings(startReadings, g.startReadings, "a game's start readings");
            _assertSameReadings(votes, g.votes, "a game's votes");
            assertEq(disputedAt, g.disputed ? g.disputedAt : 0, "a game's record time beside its votes");

            // One end per game, and nothing written after it: the model lets at most one end through (a second
            // would be a mismatch), and the storage stays what it was at the end, word for word.
            uint256 ends = (g.scored ? 1 : 0) + (g.voided ? 1 : 0) + (g.released ? 1 : 0);
            assertLe(ends, 1, "a game ended twice");
            if (ends == 1) {
                assertEq(keccak256(_rawGame(id)), g.endedRaw, "a game was written after its end");
                (uint96 held,) = games.getGameFee(id);
                assertEq(held, 0, "an ended game holds its fee");
            }
        }
    }

    /// The open list is exactly the games the model has not ended, each once, with its total; each row's words
    /// are the model's (its status, start, window, day-7 clock, record time and league; the handler gives no
    /// hint); every page of it is a slice of the whole; and no id on it is outside the games made.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_theOpenListIsTheGamesNotEnded() public view {
        uint256 count = handler.created();
        (OpenGame[] memory rows, uint256 total) = games.getOpenGames(0, type(uint256).max);
        assertEq(rows.length, total, "the whole list and its total");
        uint256 notEnded;
        for (uint256 id = 1; id <= count; ++id) {
            bool expectedOpen = !handler.ended(id);
            if (expectedOpen) ++notEnded;
            uint256 seen;
            for (uint256 i; i < rows.length; ++i) {
                if (rows[i].gameId == id) ++seen;
            }
            assertEq(seen, expectedOpen ? 1 : 0, "a game on the open list other than once while not ended");
        }
        assertEq(total, notEnded, "the open list's total is the games not ended");
        for (uint256 i; i < rows.length; ++i) {
            uint256 id = rows[i].gameId;
            assertTrue(id != 0 && id <= count, "an id that is not a game on the open list");
            GamesHandler.Ghost memory g = handler.ghostOf(id);
            GameStatus status =
                g.disputed ? GameStatus.Disputed : g.started ? GameStatus.Verified : GameStatus.Unverified;
            assertEq(uint8(rows[i].status), uint8(status), "a row's status is not the model's");
            assertEq(rows[i].start, g.started ? g.start : 0, "a row's start is not the model's");
            assertEq(rows[i].window, g.terms.window, "a row's window is not the model's");
            assertEq(rows[i].day7Clock, g.terms.day7Clock, "a row's day-7 clock is not the model's");
            assertEq(rows[i].disputedAt, g.disputedAt, "a row's record time is not the model's");
            assertEq(rows[i].league, g.league, "a row's league is not the model's");
            assertEq(rows[i].hints.length, 0, "a row's hints, where the creation gave none");
        }
        for (uint256 offset; offset < total; offset += 3) {
            (OpenGame[] memory page,) = games.getOpenGames(offset, 3);
            for (uint256 i; i < page.length; ++i) {
                assertEq(page[i].gameId, rows[offset + i].gameId, "a page is not a slice of the whole");
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
        handler.reportOther(1, 3); // a report with no kind: refused

        // The ends. Game 4 (nba, on the defaults set above: n 3 hours, the day-7 clock 4 days, the day-30 clock 25
        // days) was started at its date, two days back. Game 3 (nhl's own terms: n 2 hours, 3 days, 20 days) is
        // not started yet; an offset seed of 172801 writes its start a day after its date, which is minutes ago,
        // so now is inside its n. Shape 0 is a clean report; 8 a payout on a dispute record or a score on a void;
        // 10 a silent reading with a score. A game seed picks game 1 + seed % 5 here: 2 is game 3, 3 is game 4,
        // 5 is game 1. A sender seed of 3 picks the game's first reporter (first).
        handler.reportStart(2, 3, 172801, 0); // game 3 started, by first
        handler.reportDispute(2, 3, 8); // game 3, first, a payout on the record: refused
        handler.reportVoid(2, 3, 0); // game 3, first, inside n: refused
        handler.reportDispute(2, 3, 0); // game 3, first, inside n: the record
        handler.reportDispute(2, 3, 0); // first again, the record's readings again: refused, a repeat
        handler.reportDispute(2, 3, 65536); // first again, seat 1's vote changed: an update, writing nothing
        handler.warp(2 hours); // past start + n
        handler.reportVoid(2, 3, 0); // game 3, first, disputed, inside the day-7 clock: refused
        handler.release(2, 8); // game 3, by pool 8, before its day-30 clock, a reporter live: refused
        handler.warpLong(3 days); // the day-7 clock has run
        handler.reportVoid(2, 3, 8); // first, a score on the void: refused
        handler.reportVoid(2, 3, 0); // first: the day-7 void, the end
        handler.reportDispute(2, 3, 0); // an update after the end: refused
        handler.release(2, 8); // a release after the end: refused
        handler.warpLong(20 days);
        handler.warpLong(5 days); // past game 4's own day-30 clock
        handler.release(3, 8); // game 4, by pool 8, past its clock: taken
        handler.reportScore(3, 3, 1, 1, 0); // a score after the release: refused

        // Every reporter of game 1 retired: it reads so at once, and its first-n reporter writes nothing more.
        handler.retire(0); // first
        handler.retire(2); // second
        handler.reportStart(2, 3, inRange, 0); // first on game 3: retired, refused (and the game has ended)
        assertTrue(games.isEveryReporterRetired(1), "game 1's reporters are all retired");
        assertFalse(games.isEveryReporterRetired(3), "game 3 keeps pool 3");
        handler.retire(3); // pool 3: the list holds no first-n reporter now
        handler.create(date, 0); // refused: no start could be written
        // Game 1 was scored, so every reporter retired opens nothing there.
        handler.release(5, 8); // game 1, scored: refused, though every reporter is retired

        assertEq(handler.mismatches(), 0, "the contract and the model disagreed");
        assertEq(handler.startsTaken(), 4, "starts taken");
        assertEq(handler.scoresTaken(), 2, "scores taken");
        assertEq(handler.voidsTaken(), 1, "voids taken");
        assertEq(handler.disputesTaken(), 2, "dispute reports taken: a record and an update");
        assertEq(handler.disputesRepeated(), 1, "dispute reports refused as repeats");
        assertEq(handler.releasesTaken(), 1, "releases taken");
        assertEq(handler.releasesRefused(), 3, "releases refused");
        assertEq(handler.refused(), 19, "reports refused");
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
        invariant_theOpenListIsTheGamesNotEnded();
    }
}
