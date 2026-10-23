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
    Hint
} from "./IOspexGames.sol";

/**
 * @title OspexGames
 * @author ospex.org
 * @notice The games contract of Ospex v3's games piece. The design it is built to is docs/spec-v3.md in this
 *         repository, which controls where the two differ.
 *
 *         Anyone creates a game. When it is created, a game copies the approved list of reporters as it
 *         stands, each with its kind, and nothing changes that copy afterwards. Only the game's recorded
 *         reporters write to it, all through one report call in one report shape. The start is written once,
 *         by a first-n reporter. The score is written once, never before the start, and is final. Five reads,
 *         open to any address, tell any contract what happened.
 *
 *         Three things a reader may look for here belong to other parts of the games piece, by design:
 *         - Who may report. This contract only checks that a sender is one of the game's recorded reporters.
 *           Admission to the approved list (its code hash checked, never a wallet, a proxy or a delegated
 *           wallet) and retirement from it are the approved list's, through the timelock. Spec: "The approved
 *           list" and "Retiring a reporter".
 *         - How a game ends other than by a score. The hour-24 void, the dispute record and day 7, and the
 *           day-30 release that gives every stake back are the ends. Spec: "How a game ends".
 *         - Correcting a start or a score. There is none: each is written once. Feeds that disagree lead to a
 *           dispute record, never to a correction. Spec: "The start is written once" and "A score is written
 *           once and is final".
 *         The games piece deploys once, with all of them. Spec: "Launch: one reporter, and the hooks".
 *
 *         As built here, the contract has no owner, no setter, no pause and no way to correct a start or a
 *         score. It refuses no league.
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
    /// @param window n, copied at creation
    /// @param start The start, once written. A written start is never 0 and is within START_BOUND of the date.
    /// @param homeScore The home team's score, once written
    /// @param awayScore The away team's score, once written
    struct Game {
        GameStatus status;
        uint64 date;
        uint64 window;
        uint64 start;
        uint32 homeScore;
        uint32 awayScore;
    }

    /// @dev A reporter and its kind.
    struct Reporter {
        address account;
        ReporterKind kind;
    }

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the constructor is given no reporters
    error OspexGames__NoReporters();
    /// @notice Thrown when the constructor's reporters and kinds differ in length
    error OspexGames__KindsLengthMismatch(uint256 reporters, uint256 kinds);
    /// @notice Thrown when a reporter given to the constructor is the zero address
    error OspexGames__ZeroReporter();
    /// @notice Thrown when a reporter given to the constructor has no kind
    error OspexGames__NoKind(address reporter);
    /// @notice Thrown when the constructor is given the same reporter twice
    error OspexGames__DuplicateReporter(address reporter);
    /// @notice Thrown when the constructor's reporters include no first-n reporter, so no start could be written
    error OspexGames__NoFirstNReporter();
    /// @notice Thrown when the constructor is given a window of 0
    error OspexGames__WindowZero();

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

    /// @dev How many games exist. Game ids run from 1 to this number.
    uint256 internal s_gameCount;

    /// @dev n for every new game, copied at its creation.
    uint64 internal s_window;

    /// @dev The approved reporters, each with its kind. A game copies this list at its creation.
    Reporter[] internal s_approved;

    /// @dev Game id to game.
    mapping(uint256 => Game) internal s_games;

    /// @dev Game id to the reporters it copied at creation. Nothing writes a game's list after its creation.
    mapping(uint256 => Reporter[]) internal s_gameReporters;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Writes the first approved reporters, each with its kind, and n for new games.
    /// @param reporters The first reporters. At least one, none zero, none twice.
    /// @param kinds Each reporter's kind, in the same order. At least one is first-n.
    /// @param window n for new games, in seconds. Not 0.
    constructor(address[] memory reporters, ReporterKind[] memory kinds, uint64 window) {
        uint256 count = reporters.length;
        if (count == 0) revert OspexGames__NoReporters();
        if (kinds.length != count) revert OspexGames__KindsLengthMismatch(count, kinds.length);
        if (window == 0) revert OspexGames__WindowZero();
        bool firstN = false;
        for (uint256 i; i < count; ++i) {
            address account = reporters[i];
            if (account == address(0)) revert OspexGames__ZeroReporter();
            if (kinds[i] == ReporterKind.None) revert OspexGames__NoKind(account);
            for (uint256 j; j < i; ++j) {
                if (reporters[j] == account) revert OspexGames__DuplicateReporter(account);
            }
            if (kinds[i] == ReporterKind.FirstN) firstN = true;
            s_approved.push(Reporter({account: account, kind: kinds[i]}));
        }
        if (!firstN) revert OspexGames__NoFirstNReporter();
        s_window = window;
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
        uint64 window = s_window;
        g.window = window;

        uint256 count = s_approved.length;
        address[] memory accounts = new address[](count);
        uint8[] memory kinds = new uint8[](count);
        for (uint256 i; i < count; ++i) {
            Reporter memory r = s_approved[i];
            s_gameReporters[gameId].push(r);
            accounts[i] = r.account;
            kinds[i] = uint8(r.kind);
        }

        emit GameCreated(gameId, msg.sender, league, homeTeam, awayTeam, date, hints, window, accounts, kinds);
    }

    // ──────────────────────────── The report call ──────────────────────

    /// @inheritdoc IOspexGames
    /// @dev A refused report reverts, so it changes nothing. A report this contract takes changes one game
    ///      and emits GameReported, naming the sender as the reporter that wrote it.
    function report(Report calldata r) external {
        Game storage g = _game(r.gameId);
        ReporterKind kind = _recordedKind(r.gameId, msg.sender);
        if (kind == ReporterKind.None) revert OspexGames__NotAReporter(r.gameId, msg.sender);
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

    /// @notice A game's reporters and their kinds, exactly as the game copied them at its creation.
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
        return _game(gameId).window;
    }

    /// @inheritdoc IOspexGames
    function gameCount() external view returns (uint256) {
        return s_gameCount;
    }

    // ──────────────────────────── Internal ─────────────────────────────

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
        uint256 opensAt = start + g.window;
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
