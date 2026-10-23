// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {
    IOspexGames,
    GameStatus,
    ReporterKind,
    ReportKind,
    ReadingKind,
    Reading,
    Report,
    Hint,
    Terms
} from "./IOspexGames.sol";
import {IOspexReporter} from "./IOspexReporter.sol";

/**
 * @title OspexGames
 * @author ospex.org
 * @notice The games contract of Ospex v3's games piece. The design it is built to is docs/spec-v3.md in this
 *         repository, which controls where the two differ.
 *
 *         Anyone creates a game. When it is created, a game copies the approved list of reporters as it
 *         stands, each with its kind, and its league's four terms, and nothing changes either copy afterwards.
 *         Only the game's recorded reporters write to it, all through one report call in one report shape, and
 *         a retired reporter writes to no game. The start is written once, by a first-n reporter. The score is
 *         written once, never before the start, and is final. Five reads, open to any address, tell any
 *         contract what happened.
 *
 *         The approved list and the terms change only by the Polygon timelock, after its delay, through three
 *         calls: set a league's terms (or the default terms), approve a reporter, and retire a reporter. The
 *         constructor writes the first state, the default terms and the first reporters, each reporter admitted
 *         as an approval admits one. This contract keeps no wait of its own. Spec: "The Polygon timelock's
 *         calls" and "What is written without a wait".
 *
 *         An approval checks on chain what it can: the reporter has code, the code is not a wallet's delegation
 *         (EIP-7702), and it hashes as the call named. That a reporter has no owner and no setter and is not a
 *         proxy is for review, before the call is queued. Spec: "The approved list".
 *
 *         Two things a reader may look for here belong to other parts of the games piece, by design:
 *         - How a game ends other than by a score, and the creation fee changing hands. The hour-24 void, the
 *           dispute record and day 7, and the day-30 release that gives every stake back are the ends, and a
 *           game whose every reporter is retired can be released at once. This contract copies each game's
 *           clocks and fee and says when every reporter of a game is retired; it takes no fee and writes no end
 *           but a score. Spec: "How a game ends" and "The creation fee".
 *         - Correcting a start or a score. There is none: each is written once. Feeds that disagree lead to a
 *           dispute record, never to a correction. Spec: "The start is written once" and "A score is written
 *           once and is final".
 *         The games piece deploys once, with all of them. Spec: "Launch: one reporter, and the hooks".
 *
 *         It has no owner, no pause, no setter but the timelock's three calls, and no way to correct a start or
 *         a score. It refuses no league.
 */
contract OspexGames is IOspexGames {
    // ──────────────────────────── Constants ────────────────────────────

    /// @notice The largest score accepted for one team. It is far above any real score in a sports league.
    ///         It exists so that the betting set's line arithmetic, which multiplies a score by 10 inside a
    ///         signed 32-bit integer, cannot overflow: 1,000,000 x 10 is under 2^31. A score that overflowed
    ///         there would leave a market that can never settle.
    uint32 public constant MAX_SCORE = 1_000_000;

    /// @notice How far a written start may lie from the date given at creation, either way, inclusive. A day is
    ///         a game's identity: a start further from its date than this is another game. The day-30 release
    ///         counts from the start, so writing a start moves it by at most this much. It is fixed, and is
    ///         not the game's n, so a league's n never changes which starts a game takes.
    uint64 public constant START_BOUND = 24 hours;

    /// @notice How far ahead of its creation a game's date may be. A date further ahead is refused: it is far
    ///         more likely a mistake than a game, the likeliest being a time in milliseconds, which reads as
    ///         tens of thousands of years ahead. It also keeps every clock counted from the date or the start
    ///         far inside 64 bits. A game with a later date can be created nearer to it.
    uint64 public constant MAX_DATE_AHEAD = 365 days;

    /// @notice The longest any of a game's three clocks may be: n, the day-7 clock and the day-30 clock. A
    ///         clock longer than a year is far more likely a mistake, such as milliseconds, than a term.
    uint64 public constant MAX_CLOCK = 365 days;

    /// @notice The most reporters the approved list holds at once. A game copies the whole list when it is
    ///         created and its report call looks through that copy, so the list has a ceiling. A retired
    ///         reporter leaves the list and frees its place.
    uint256 public constant MAX_REPORTERS = 8;

    /// @notice The longest league id, in bytes. A league id is lowercase letters and digits only, so one
    ///         league has one spelling.
    uint256 public constant MAX_LEAGUE_LENGTH = 16;

    /// @notice The longest team name, in bytes of printable ASCII.
    uint256 public constant MAX_TEAM_LENGTH = 64;

    /// @notice The most hints a creation may give.
    uint256 public constant MAX_HINTS = 8;

    /// @notice The longest hint id, in bytes of printable ASCII.
    uint256 public constant MAX_HINT_ID_LENGTH = 64;

    // ──────────────────────────── Types ────────────────────────────────

    /// @dev A game as stored. Its identity (league, teams, hints, creator) is in the creation event only.
    /// @param status Where the game stands
    /// @param date The scheduled start the creator gave
    /// @param start The start, once written. A written start is never 0 and is within START_BOUND of the date.
    /// @param homeScore The home team's score, once written
    /// @param awayScore The away team's score, once written
    /// @param terms The four terms, copied from the game's league at creation
    struct Game {
        GameStatus status;
        uint64 date;
        uint64 start;
        uint32 homeScore;
        uint32 awayScore;
        Terms terms;
    }

    /// @dev A reporter and its kind.
    struct Reporter {
        address account;
        ReporterKind kind;
    }

    /// @dev What the games set knows of an address as a reporter. A kind of None means never approved. A
    ///      retired reporter keeps its kind and stays retired for good.
    struct Admission {
        ReporterKind kind;
        bool retired;
    }

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the constructor's timelock has no code, or has only a wallet's delegation
    error OspexGames__TimelockNotAContract(address timelock);
    /// @notice Thrown when the constructor's timelock is the deployer itself
    error OspexGames__TimelockIsTheDeployer(address timelock);
    /// @notice Thrown when anything but the timelock calls one of its three calls
    error OspexGames__NotTheTimelock(address caller);
    /// @notice Thrown when the constructor is given no reporters
    error OspexGames__NoReporters();
    /// @notice Thrown when the constructor's reporters, kinds and code hashes differ in length
    error OspexGames__LengthsDiffer(uint256 reporters, uint256 kinds, uint256 codeHashes);
    /// @notice Thrown when the constructor's reporters include no first-n reporter, or when a game is created
    ///         while the approved list holds none: no start could be written
    error OspexGames__NoFirstNReporter();

    /// @notice Thrown when a reporter is approved with no kind
    error OspexGames__NoKind(address reporter);
    /// @notice Thrown when a reporter already on the approved list is approved again
    error OspexGames__AlreadyApproved(address reporter);
    /// @notice Thrown when a retired reporter is approved or retired again, or sends a report: retirement is
    ///         for good
    error OspexGames__ReporterRetired(address reporter);
    /// @notice Thrown when an approval would put more than MAX_REPORTERS on the approved list
    error OspexGames__ListFull();
    /// @notice Thrown when a reporter to be approved has no code: a wallet, or nothing
    error OspexGames__NoCode(address reporter);
    /// @notice Thrown when a reporter to be approved is a wallet with delegated code (EIP-7702)
    error OspexGames__Delegated(address reporter);
    /// @notice Thrown when the code at a reporter to be approved hashes otherwise than the approval named
    error OspexGames__CodeHashMismatch(address reporter, bytes32 named, bytes32 found);
    /// @notice Thrown when a reporter to be approved has no fixed-values read, or its read reverts or tries to
    ///         write. A read that answers with something that does not decode as one bytes value is refused
    ///         too, by the decoder, which gives no reason.
    error OspexGames__NoFixedValues(address reporter);
    /// @notice Thrown when a reporter that is not on the approved list is retired
    error OspexGames__NotApproved(address reporter);
    /// @notice Thrown when a clock in a set of terms is 0 or more than MAX_CLOCK
    error OspexGames__TermsNotValid();

    /// @notice Thrown when a league id is empty, too long, or holds a character other than a-z and 0-9
    error OspexGames__LeagueNotValid();
    /// @notice Thrown when a team name is too long, holds a character outside printable ASCII, or holds no
    ///         character but spaces (so an empty name too)
    error OspexGames__TeamNotValid();
    /// @notice Thrown when the home team and the away team are the same text
    error OspexGames__SameTeams();
    /// @notice Thrown when a creation's date is 0, or more than MAX_DATE_AHEAD after the creation
    error OspexGames__DateNotValid(uint64 date);
    /// @notice Thrown when a creation gives more than MAX_HINTS hints
    error OspexGames__TooManyHints(uint256 count);
    /// @notice Thrown when a hint's id is too long, holds a character outside printable ASCII, or holds no
    ///         character but spaces (so an empty id too)
    error OspexGames__HintNotValid(uint256 index);
    /// @notice Thrown when a creation gives two hints for one seat. The index is the second of the two.
    error OspexGames__HintSeatRepeated(uint256 index);

    /// @notice Thrown when an id is not a game
    error OspexGames__UnknownGame(uint256 gameId);
    /// @notice Thrown when the sender is not among the game's recorded reporters
    error OspexGames__NotAReporter(uint256 gameId, address sender);
    /// @notice Thrown for a report kind this contract does not take: no kind, a void or a dispute record
    error OspexGames__ReportKindNotTaken(ReportKind kind);
    /// @notice Thrown when a report sets a field its kind does not use: a score or a payout on a start, a start
    ///         on a score
    error OspexGames__FieldNotEmpty(ReportKind kind);
    /// @notice Thrown when a reading marked silent carries a score: a feed that did not answer gave none
    error OspexGames__SilentReadingNotEmpty(uint256 index);
    /// @notice Thrown for any report to a game that has ended: scored, voided or released
    error OspexGames__GameEnded(uint256 gameId, GameStatus status);
    /// @notice Thrown when a start is reported for a game whose start is already written
    error OspexGames__StartAlreadyWritten(uint256 gameId);
    /// @notice Thrown when a start is reported by a reporter that is not first-n for the game
    error OspexGames__NotFirstN(uint256 gameId, address reporter);
    /// @notice Thrown when a reported start is 0, or more than START_BOUND from the date given at creation
    error OspexGames__StartOutOfRange(uint256 gameId, uint64 start);
    /// @notice Thrown when a score is reported, or a start read, for a game whose start is not written
    error OspexGames__StartNotWritten(uint256 gameId);
    /// @notice Thrown when a score is reported for a game whose dispute record is written
    error OspexGames__Disputed(uint256 gameId);
    /// @notice Thrown when a score is reported before the game's start
    error OspexGames__BeforeStart(uint256 gameId, uint64 start);
    /// @notice Thrown when an after-n reporter reports a score before start + n
    error OspexGames__InsideWindow(uint256 gameId, uint256 opensAt);
    /// @notice Thrown when a reported score is above MAX_SCORE
    error OspexGames__ScoreOutOfRange(uint32 homeScore, uint32 awayScore);
    /// @notice Thrown when a game's scores are read and the game is not scored
    error OspexGames__NotScored(uint256 gameId, GameStatus status);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The Polygon timelock: the only address that changes the approved list or the terms
    address public immutable i_timelock;

    /// @dev How many games exist. Game ids run from 1 to this number.
    uint256 internal s_gameCount;

    /// @dev The approved reporters, each with its kind, in the order they were approved. A game copies this
    ///      list at its creation. A retired reporter leaves it.
    Reporter[] internal s_approved;

    /// @dev Every address ever approved, with its kind and whether it is retired.
    mapping(address => Admission) internal s_admissions;

    /// @dev The terms of a league with terms of its own, by the hash of its id. A league's own terms always
    ///      have a window above 0, so a window of 0 here means the league takes the default terms.
    mapping(bytes32 => Terms) internal s_leagueTerms;

    /// @dev The terms of every league with none of its own.
    Terms internal s_defaultTerms;

    /// @dev Game id to game.
    mapping(uint256 => Game) internal s_games;

    /// @dev Game id to the reporters it copied at creation. Nothing writes a game's list after its creation.
    mapping(uint256 => Reporter[]) internal s_gameReporters;

    // ──────────────────────────── Constructor ──────────────────────────

    modifier onlyTimelock() {
        if (msg.sender != i_timelock) revert OspexGames__NotTheTimelock(msg.sender);
        _;
    }

    /// @notice Writes the first state, the one write that waits for no timelock: the default terms, and the
    ///         first reporters, each admitted as an approval admits one, with its code hash checked and its
    ///         fixed values read and emitted.
    /// @param timelock The Polygon timelock. A contract, and not the deployer.
    /// @param defaultTerms The terms of every league with none of its own. At launch: n 24 hours, the day-7
    ///        clock 7 days, the day-30 clock 30 days and the fee 1 USDC.
    /// @param reporters The first reporters. At least one, none twice, at most MAX_REPORTERS.
    /// @param kinds Each reporter's kind, in the same order. At least one is first-n.
    /// @param codeHashes The hash of each reporter's code, in the same order.
    constructor(
        address timelock,
        Terms memory defaultTerms,
        address[] memory reporters,
        ReporterKind[] memory kinds,
        bytes32[] memory codeHashes
    ) {
        if (timelock.code.length == 0 || _isDelegated(timelock)) revert OspexGames__TimelockNotAContract(timelock);
        if (timelock == msg.sender) revert OspexGames__TimelockIsTheDeployer(timelock);
        i_timelock = timelock;

        _checkTerms(defaultTerms);
        s_defaultTerms = defaultTerms;
        emit TermsSet("", defaultTerms);

        uint256 count = reporters.length;
        if (count == 0) revert OspexGames__NoReporters();
        if (kinds.length != count || codeHashes.length != count) {
            revert OspexGames__LengthsDiffer(count, kinds.length, codeHashes.length);
        }
        bool firstN = false;
        for (uint256 i; i < count; ++i) {
            _admit(reporters[i], kinds[i], codeHashes[i]);
            if (kinds[i] == ReporterKind.FirstN) firstN = true;
        }
        if (!firstN) revert OspexGames__NoFirstNReporter();
    }

    // ──────────────────────────── The timelock's three calls ───────────

    /// @inheritdoc IOspexGames
    function setTerms(string calldata league, Terms calldata terms) external onlyTimelock {
        bool isDefault = bytes(league).length == 0;
        if (!isDefault && !_isLeague(league)) revert OspexGames__LeagueNotValid();
        _checkTerms(terms);
        if (isDefault) s_defaultTerms = terms;
        else s_leagueTerms[keccak256(bytes(league))] = terms;
        emit TermsSet(league, terms);
    }

    /// @inheritdoc IOspexGames
    function approveReporter(address reporter, ReporterKind kind, bytes32 codeHash) external onlyTimelock {
        _admit(reporter, kind, codeHash);
    }

    /// @inheritdoc IOspexGames
    function retireReporter(address reporter) external onlyTimelock {
        Admission storage a = s_admissions[reporter];
        if (a.retired) revert OspexGames__ReporterRetired(reporter);
        if (a.kind == ReporterKind.None) revert OspexGames__NotApproved(reporter);
        a.retired = true;

        // An approved reporter not yet retired is on the list exactly once: find it, and close the gap so the
        // others keep their order.
        uint256 count = s_approved.length;
        uint256 i = 0;
        while (s_approved[i].account != reporter) ++i;
        for (; i + 1 < count; ++i) {
            s_approved[i] = s_approved[i + 1];
        }
        s_approved.pop();
        emit ReporterRetired(reporter);
    }

    // ──────────────────────────── Creation ─────────────────────────────

    /// @inheritdoc IOspexGames
    function createGame(
        string calldata league,
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 date,
        Hint[] calldata hints
    ) external returns (uint256 gameId) {
        if (!_isLeague(league)) revert OspexGames__LeagueNotValid();
        if (!_isText(homeTeam, MAX_TEAM_LENGTH) || !_isText(awayTeam, MAX_TEAM_LENGTH)) {
            revert OspexGames__TeamNotValid();
        }
        if (keccak256(bytes(homeTeam)) == keccak256(bytes(awayTeam))) revert OspexGames__SameTeams();
        if (date == 0 || date > block.timestamp + MAX_DATE_AHEAD) revert OspexGames__DateNotValid(date);
        uint256 hintCount = hints.length;
        if (hintCount > MAX_HINTS) revert OspexGames__TooManyHints(hintCount);
        uint256 seats = 0;
        for (uint256 i; i < hintCount; ++i) {
            if (!_isText(hints[i].id, MAX_HINT_ID_LENGTH)) revert OspexGames__HintNotValid(i);
            uint256 seat = uint256(1) << hints[i].seat;
            if (seats & seat != 0) revert OspexGames__HintSeatRepeated(i);
            seats |= seat;
        }

        gameId = ++s_gameCount;
        Game storage g = s_games[gameId];
        g.status = GameStatus.Unverified;
        g.date = date;
        Terms memory terms = _termsOf(league);
        g.terms = terms;

        uint256 count = s_approved.length;
        address[] memory accounts = new address[](count);
        uint8[] memory kinds = new uint8[](count);
        bool firstN = false;
        for (uint256 i; i < count; ++i) {
            Reporter memory r = s_approved[i];
            s_gameReporters[gameId].push(r);
            accounts[i] = r.account;
            kinds[i] = uint8(r.kind);
            if (r.kind == ReporterKind.FirstN) firstN = true;
        }
        if (!firstN) revert OspexGames__NoFirstNReporter();

        emit GameCreated(gameId, msg.sender, league, homeTeam, awayTeam, date, hints, terms, accounts, kinds);
    }

    // ──────────────────────────── The report call ──────────────────────

    /// @inheritdoc IOspexGames
    /// @dev A refused report reverts, so it changes nothing. A report this contract takes changes one game
    ///      and emits GameReported, naming the sender as the reporter that wrote it.
    function report(Report calldata r) external {
        Game storage g = _game(r.gameId);
        ReporterKind kind = _recordedKind(r.gameId, msg.sender);
        if (kind == ReporterKind.None) revert OspexGames__NotAReporter(r.gameId, msg.sender);
        if (s_admissions[msg.sender].retired) revert OspexGames__ReporterRetired(msg.sender);
        _checkReadings(r.readings);

        if (r.kind == ReportKind.Start) {
            _writeStart(g, r, kind);
        } else if (r.kind == ReportKind.Score) {
            _writeScore(g, r, kind);
        } else {
            revert OspexGames__ReportKindNotTaken(r.kind);
        }

        emit GameReported(r.gameId, msg.sender, r.kind, r.start, r.homeScore, r.awayScore, r.readings, r.payout);
    }

    // ──────────────────────────── The five reads ───────────────────────

    /// @inheritdoc IOspexGames
    function getGameStatus(uint256 gameId) external view returns (GameStatus) {
        return _game(gameId).status;
    }

    /// @inheritdoc IOspexGames
    function getGameStart(uint256 gameId) external view returns (uint64) {
        Game storage g = _game(gameId);
        if (g.start == 0) revert OspexGames__StartNotWritten(gameId);
        return g.start;
    }

    /// @notice A game's reporters and their kinds, exactly as the game copied them at its creation. A reporter
    ///         retired since stays here, as the game recorded it; it writes nothing more.
    /// @dev The read the signpost calls before it moves a games entry to live. Kinds are ReporterKind numbers.
    function getGameReporters(uint256 gameId)
        external
        view
        returns (address[] memory reporters, uint8[] memory kinds)
    {
        _game(gameId);
        Reporter[] storage list = s_gameReporters[gameId];
        uint256 count = list.length;
        reporters = new address[](count);
        kinds = new uint8[](count);
        for (uint256 i; i < count; ++i) {
            reporters[i] = list[i].account;
            kinds[i] = uint8(list[i].kind);
        }
    }

    /// @inheritdoc IOspexGames
    function getGameScores(uint256 gameId) external view returns (uint32 homeScore, uint32 awayScore) {
        Game storage g = _game(gameId);
        if (g.status != GameStatus.Scored) revert OspexGames__NotScored(gameId, g.status);
        return (g.homeScore, g.awayScore);
    }

    /// @inheritdoc IOspexGames
    function getGameWindow(uint256 gameId) external view returns (uint64) {
        return _game(gameId).terms.window;
    }

    // ──────────────────────────── Other reads ──────────────────────────

    /// @inheritdoc IOspexGames
    function gameCount() external view returns (uint256) {
        return s_gameCount;
    }

    /// @inheritdoc IOspexGames
    function getGameTerms(uint256 gameId) external view returns (Terms memory) {
        return _game(gameId).terms;
    }

    /// @inheritdoc IOspexGames
    function isEveryReporterRetired(uint256 gameId) external view returns (bool) {
        _game(gameId);
        Reporter[] storage list = s_gameReporters[gameId];
        uint256 count = list.length;
        for (uint256 i; i < count; ++i) {
            if (!s_admissions[list[i].account].retired) return false;
        }
        return true;
    }

    /// @inheritdoc IOspexGames
    function getApprovedReporters() external view returns (address[] memory reporters, uint8[] memory kinds) {
        uint256 count = s_approved.length;
        reporters = new address[](count);
        kinds = new uint8[](count);
        for (uint256 i; i < count; ++i) {
            reporters[i] = s_approved[i].account;
            kinds[i] = uint8(s_approved[i].kind);
        }
    }

    /// @inheritdoc IOspexGames
    function getReporter(address reporter) external view returns (ReporterKind kind, bool retired) {
        Admission storage a = s_admissions[reporter];
        return (a.kind, a.retired);
    }

    /// @inheritdoc IOspexGames
    function getTerms(string calldata league) external view returns (Terms memory) {
        if (bytes(league).length == 0) return s_defaultTerms;
        if (!_isLeague(league)) revert OspexGames__LeagueNotValid();
        return _termsOf(league);
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev Admits a reporter to the approved list: the constructor's first reporters, and every approval. It
    ///      checks on chain what it can. The reporter has a kind, is not on the list and was never retired, and
    ///      the list has room; it has code, the code is not a wallet's delegation, and it hashes as named; and it
    ///      answers the fixed-values read, whose answer is emitted as read.
    function _admit(address reporter, ReporterKind kind, bytes32 codeHash) private {
        if (kind == ReporterKind.None) revert OspexGames__NoKind(reporter);
        Admission storage a = s_admissions[reporter];
        if (a.retired) revert OspexGames__ReporterRetired(reporter);
        if (a.kind != ReporterKind.None) revert OspexGames__AlreadyApproved(reporter);
        if (s_approved.length >= MAX_REPORTERS) revert OspexGames__ListFull();
        if (reporter.code.length == 0) revert OspexGames__NoCode(reporter);
        if (_isDelegated(reporter)) revert OspexGames__Delegated(reporter);
        bytes32 found = reporter.codehash;
        if (found != codeHash) revert OspexGames__CodeHashMismatch(reporter, codeHash, found);
        bytes memory values = _fixedValues(reporter);

        a.kind = kind;
        s_approved.push(Reporter({account: reporter, kind: kind}));
        emit ReporterApproved(reporter, kind, codeHash, values);
    }

    /// @dev The reporter's answer to the fixed-values read, made as a read (STATICCALL: the interface marks it
    ///      view), so the read can change nothing, here or anywhere else. A read that is missing, reverts or tries
    ///      to write is refused by name; an answer that does not decode as bytes is refused by the decoder.
    function _fixedValues(address reporter) private view returns (bytes memory) {
        try IOspexReporter(reporter).fixedValues() returns (bytes memory values) {
            return values;
        } catch {
            revert OspexGames__NoFixedValues(reporter);
        }
    }

    /// @dev True when the account's code is a wallet's delegation (EIP-7702): 23 bytes, 0xef0100 and an address.
    function _isDelegated(address account) private view returns (bool) {
        return account.code.length == 23 && bytes3(account.code) == 0xef0100;
    }

    /// @dev Refuses a set of terms with a clock of 0 or more than MAX_CLOCK. Any fee is legal, 0 included.
    function _checkTerms(Terms memory terms) private pure {
        if (
            terms.window == 0 || terms.window > MAX_CLOCK || terms.day7Clock == 0 || terms.day7Clock > MAX_CLOCK
                || terms.day30Clock == 0 || terms.day30Clock > MAX_CLOCK
        ) revert OspexGames__TermsNotValid();
    }

    /// @dev The terms a game in `league` made now copies: the league's own, or the default terms.
    function _termsOf(string calldata league) private view returns (Terms memory) {
        Terms memory own = s_leagueTerms[keccak256(bytes(league))];
        return own.window != 0 ? own : s_defaultTerms;
    }

    /// @dev Writes a start. The game must have no start written yet, the sender must be a first-n reporter,
    ///      the scores and the payout must be empty (a start pays nothing), and the start must be within
    ///      START_BOUND of the date given at creation, either way.
    function _writeStart(Game storage g, Report calldata r, ReporterKind kind) private {
        GameStatus status = g.status;
        if (status != GameStatus.Unverified) _refuseStart(r.gameId, status);
        if (kind != ReporterKind.FirstN) revert OspexGames__NotFirstN(r.gameId, msg.sender);
        if (r.homeScore != 0 || r.awayScore != 0 || r.payout != address(0)) {
            revert OspexGames__FieldNotEmpty(ReportKind.Start);
        }
        uint256 start = r.start;
        uint256 date = g.date;
        if (start == 0 || start + START_BOUND < date || start > date + START_BOUND) {
            revert OspexGames__StartOutOfRange(r.gameId, r.start);
        }
        g.start = r.start;
        g.status = GameStatus.Verified;
    }

    /// @dev Writes a score. The game's start must be written and no end written, the start field must be
    ///      empty, both scores at most MAX_SCORE, the time at or after the start, and, for an after-n
    ///      reporter, at or after start + n.
    function _writeScore(Game storage g, Report calldata r, ReporterKind kind) private {
        GameStatus status = g.status;
        if (status != GameStatus.Verified) _refuseScore(r.gameId, status);
        if (r.start != 0) revert OspexGames__FieldNotEmpty(ReportKind.Score);
        if (r.homeScore > MAX_SCORE || r.awayScore > MAX_SCORE) {
            revert OspexGames__ScoreOutOfRange(r.homeScore, r.awayScore);
        }
        uint256 start = g.start;
        if (block.timestamp < start) revert OspexGames__BeforeStart(r.gameId, g.start);
        uint256 opensAt = start + g.terms.window;
        if (kind == ReporterKind.AfterN && block.timestamp < opensAt) {
            revert OspexGames__InsideWindow(r.gameId, opensAt);
        }
        g.homeScore = r.homeScore;
        g.awayScore = r.awayScore;
        g.status = GameStatus.Scored;
    }

    /// @dev Names why a start is refused, from a status other than Unverified. Always reverts.
    function _refuseStart(uint256 gameId, GameStatus status) private pure {
        if (status == GameStatus.Verified || status == GameStatus.Disputed) {
            revert OspexGames__StartAlreadyWritten(gameId);
        }
        revert OspexGames__GameEnded(gameId, status);
    }

    /// @dev Names why a score is refused, from a status other than Verified. Always reverts.
    function _refuseScore(uint256 gameId, GameStatus status) private pure {
        if (status == GameStatus.Unverified) revert OspexGames__StartNotWritten(gameId);
        if (status == GameStatus.Disputed) revert OspexGames__Disputed(gameId);
        revert OspexGames__GameEnded(gameId, status);
    }

    /// @dev Refuses a reading marked silent that carries a score, in a report of any kind. Nothing else in a
    ///      reading is checked: the readings are emitted, not stored.
    function _checkReadings(Reading[] calldata readings) private pure {
        uint256 count = readings.length;
        for (uint256 i; i < count; ++i) {
            Reading calldata reading = readings[i];
            if (reading.kind == ReadingKind.Silent && (reading.homeScore != 0 || reading.awayScore != 0)) {
                revert OspexGames__SilentReadingNotEmpty(i);
            }
        }
    }

    /// @dev The game, or a refusal if the id is not a game.
    function _game(uint256 gameId) private view returns (Game storage g) {
        g = s_games[gameId];
        if (g.status == GameStatus.None) revert OspexGames__UnknownGame(gameId);
    }

    /// @dev The account's kind among the game's recorded reporters, or None if it is not one of them.
    function _recordedKind(uint256 gameId, address account) private view returns (ReporterKind) {
        Reporter[] storage list = s_gameReporters[gameId];
        uint256 count = list.length;
        for (uint256 i; i < count; ++i) {
            if (list[i].account == account) return list[i].kind;
        }
        return ReporterKind.None;
    }

    /// @dev True for 1 to MAX_LEAGUE_LENGTH bytes, each a-z or 0-9.
    function _isLeague(string calldata s) private pure returns (bool) {
        bytes calldata b = bytes(s);
        uint256 length = b.length;
        if (length == 0 || length > MAX_LEAGUE_LENGTH) return false;
        for (uint256 i; i < length; ++i) {
            bytes1 c = b[i];
            if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39))) return false;
        }
        return true;
    }

    /// @dev True for at most `max` bytes, each printable ASCII (0x20 to 0x7e), at least one of them not a
    ///      space. Empty text has no such byte, so it is refused too.
    function _isText(string calldata s, uint256 max) private pure returns (bool) {
        bytes calldata b = bytes(s);
        uint256 length = b.length;
        if (length > max) return false;
        bool printed = false;
        for (uint256 i; i < length; ++i) {
            bytes1 c = b[i];
            if (c < 0x20 || c > 0x7e) return false;
            if (c != 0x20) printed = true;
        }
        return printed;
    }
}
