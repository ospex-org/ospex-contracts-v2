// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IGameReporters} from "../signpost/IGameReporters.sol";

// The numbers of every enum below are part of the frozen interface: the reads return them, the report call
// takes them, and the events carry them. In each enum but ReadingKind, 0 is never a valid value, so a
// zeroed field is refused or reads as "not a game" rather than as a real state.

/// @notice Where a game stands.
enum GameStatus {
    /// @dev 0: not a game. The reads refuse an id that is not a game, so they never return this.
    None,
    /// @dev 1: created; its start is not written yet.
    Unverified,
    /// @dev 2: its start is written.
    Verified,
    /// @dev 3: a dispute record is written. The game is not over: it takes its result from the day-7 clock.
    Disputed,
    /// @dev 4: its score is written. An end.
    Scored,
    /// @dev 5: a void is written. An end. A void is a status, never a scored 0-0.
    Voided,
    /// @dev 6: released. An end of its own; the betting set reads it as a void.
    Released
}

/// @notice A reporter's kind, recorded with the reporter.
enum ReporterKind {
    /// @dev 0: not a reporter. Never recorded.
    None,
    /// @dev 1: writes from the start. Inside n it is the only kind that may write.
    FirstN,
    /// @dev 2: writes only from start + n.
    AfterN
}

/// @notice What a report is.
enum ReportKind {
    /// @dev 0: no kind. Refused.
    None,
    /// @dev 1: the game's start.
    Start,
    /// @dev 2: the game's score.
    Score,
    /// @dev 3: a void.
    Void,
    /// @dev 4: a dispute record.
    Dispute
}

/// @notice What one feed gave, for one reading.
/// @dev 0 is a real value here: a zeroed reading reads as silent, which blocks a result as a silent feed does.
enum ReadingKind {
    /// @dev 0: the feed did not answer.
    Silent,
    /// @dev 1: the feed answered without a final.
    AnsweredNoFinal,
    /// @dev 2: the feed answered with a final.
    AnsweredFinal
}

/// @notice One feed's reading, as a report gives it. The games set emits readings and stores none.
/// @param seat The feed's seat: its number in the scoring program's feed table. A feed is never named here.
/// @param kind Silent, answered without a final, or answered with a final.
/// @param homeScore For a feed that answered, the home team's score as it gave it.
/// @param awayScore For a feed that answered, the away team's score as it gave it.
struct Reading {
    uint8 seat;
    ReadingKind kind;
    uint32 homeScore;
    uint32 awayScore;
}

/// @notice The one report shape. Every report from every reporter comes through `report` in this shape.
/// @param gameId The game.
/// @param kind What the report is.
/// @param start For a start: the game's start, in seconds since 1970. Zero for any other kind.
/// @param homeScore For a score: the home team's score. Zero for any other kind.
/// @param awayScore For a score: the away team's score. Zero for any other kind.
/// @param readings The readings the report rests on, one per feed asked.
/// @param payout The payout address. The games set never puts the sender in its place.
struct Report {
    uint256 gameId;
    ReportKind kind;
    uint64 start;
    uint32 homeScore;
    uint32 awayScore;
    Reading[] readings;
    address payout;
}

/// @notice A hint a game's creator gives: where one feed may list the game. A hint is not a lock. It rides
///         in the creation event and is not stored, and nothing in the games set reads it.
/// @param seat The feed's seat in the scoring program's feed table.
/// @param id The game's id at that feed, as the creator gives it.
struct Hint {
    uint8 seat;
    string id;
}

/**
 * @title IOspexGames
 * @author ospex.org
 * @notice The games set: games anyone creates, the reporters each game keeps, and the five reads that tell
 *         any contract what happened. A game copies the approved reporters, with their kinds, when it is
 *         created, and only those reporters ever write to it. Its start and its score are each written once.
 */
interface IOspexGames is IGameReporters {
    /// @notice Emitted when a game is created. It carries the game's identity, which is not stored.
    /// @param gameId The new game's id
    /// @param creator The address that created it
    /// @param league The league's short text id
    /// @param homeTeam The home team, as text
    /// @param awayTeam The away team, as text
    /// @param date The scheduled start, in seconds since 1970, as the creator gave it
    /// @param hints The creator's hints: seat and id pairs
    /// @param window n, the game's window in seconds, copied at creation
    /// @param reporters The game's reporters, copied from the approved list at creation
    /// @param kinds Each reporter's kind, in the same order
    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        string league,
        string homeTeam,
        string awayTeam,
        uint64 date,
        Hint[] hints,
        uint64 window,
        address[] reporters,
        uint8[] kinds
    );

    /// @notice Emitted for every report the games set takes. It names the reporter that wrote it.
    /// @param gameId The game
    /// @param reporter The reporter that wrote it: the sender, one of the game's recorded reporters
    /// @param kind What the report is
    /// @param start The start, for a start; otherwise zero
    /// @param homeScore The home team's score, for a score; otherwise zero
    /// @param awayScore The away team's score, for a score; otherwise zero
    /// @param readings The readings the report rests on, as given. They are not stored.
    /// @param payout The payout address in the report
    event GameReported(
        uint256 indexed gameId,
        address indexed reporter,
        ReportKind indexed kind,
        uint64 start,
        uint32 homeScore,
        uint32 awayScore,
        Reading[] readings,
        address payout
    );

    /// @notice Creates a game. Anyone may, the same real game twice included: each creation is its own
    ///         game, with its own id and its own copy of the reporters.
    /// @param league The league's short text id: 1 to 16 characters, each a-z or 0-9.
    /// @param homeTeam The home team: 1 to 64 printable ASCII characters.
    /// @param awayTeam The away team: 1 to 64 printable ASCII characters, not the same text as the home team.
    /// @param date The scheduled start, in seconds since 1970. Not zero.
    /// @param hints Up to 8 seat and id pairs, each id 1 to 64 printable ASCII characters.
    /// @return gameId The new game's id. Ids start at 1 and count up.
    function createGame(
        string calldata league,
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 date,
        Hint[] calldata hints
    ) external returns (uint256 gameId);

    /// @notice The one report call. Only the game's recorded reporters may send it.
    function report(Report calldata r) external;

    /// @notice How many games exist. Game ids run from 1 to this number.
    function gameCount() external view returns (uint256);

    /// @notice A game's status. Refuses an id that is not a game.
    function getGameStatus(uint256 gameId) external view returns (GameStatus);

    /// @notice A game's start, in seconds since 1970. Refuses a game whose start is not written.
    function getGameStart(uint256 gameId) external view returns (uint64);

    /// @notice A game's two scores. Refuses unless the game's status is Scored, so no game reads as scored,
    ///         at 0-0 or at any score, unless a score was written.
    function getGameScores(uint256 gameId) external view returns (uint32 homeScore, uint32 awayScore);

    /// @notice A game's n: its window, in seconds, copied when the game was created.
    function getGameWindow(uint256 gameId) external view returns (uint64);
}
