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
/// @param homeScore For a feed that answered, the home team's score as it gave it. Zero for a silent feed.
/// @param awayScore For a feed that answered, the away team's score as it gave it. Zero for a silent feed.
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
/// @param payout The payout address. The games set never puts the sender in its place. Zero for a start, which
///        pays nothing.
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

/// @notice A game's four terms. The games set keeps them per league, and a game copies its league's terms when
///         it is created and keeps them. A change reaches only games made after it.
/// @param window n, in seconds: the game's window. Inside it only a first-n reporter writes; an after-n reporter
///        writes from start + n, and the hour-24 void can post from start + n.
/// @param day7Clock In seconds: how long after a dispute record the game takes its day-7 result.
/// @param day30Clock In seconds: how long after the start, or after the date for a game never started, anyone
///        may release a game that has not ended.
/// @param fee The creation fee, in the smallest unit of the coin the games set takes it in. Zero is legal.
struct Terms {
    uint64 window;
    uint64 day7Clock;
    uint64 day30Clock;
    uint96 fee;
}

/**
 * @title IOspexGames
 * @author ospex.org
 * @notice The games set: games anyone creates, the reporters each game keeps, and the five reads that tell
 *         any contract what happened. A game copies the approved reporters, with their kinds, and its league's
 *         terms when it is created, and only those reporters ever write to it. Its start and its score are each
 *         written once. The approved list and the terms change only by the Polygon timelock's three calls.
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
    /// @param terms The game's four terms, copied from its league's at creation
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
        Terms terms,
        address[] reporters,
        uint8[] kinds
    );

    /// @notice Emitted when a reporter is approved: by the constructor for the first reporters, by the timelock
    ///         after that. A game made from now on copies it.
    /// @param reporter The reporter's address
    /// @param kind Its kind
    /// @param codeHash The hash of its code, as the approval named it and the chain confirmed it
    /// @param fixedValues What the reporter's own fixed-values read returned at the moment of approval
    event ReporterApproved(address indexed reporter, ReporterKind kind, bytes32 codeHash, bytes fixedValues);

    /// @notice Emitted when the timelock retires a reporter. It writes nothing more to any game, and leaves the
    ///         approved list for good.
    /// @param reporter The reporter retired
    event ReporterRetired(address indexed reporter);

    /// @notice Emitted when a league's terms are set: by the constructor for the default terms, by the timelock
    ///         after that. Games made from now on copy them.
    /// @param league The league's short text id, or empty for the default terms
    /// @param terms The four terms
    event TermsSet(string league, Terms terms);

    /// @notice Sets a league's four terms, or the default terms when `league` is empty. Only the timelock calls
    ///         it. Games made after it copy the new terms; games already made keep theirs.
    /// @param league The league's short text id, as a creation gives it, or empty for the default terms
    /// @param terms The four terms. Each clock is at least one second and at most MAX_CLOCK.
    function setTerms(string calldata league, Terms calldata terms) external;

    /// @notice Approves a reporter. Only the timelock calls it. The code at the address must hash as named, so
    ///         what is approved is what the queued call announced. Games made after it copy it; games already
    ///         made never gain it.
    /// @param reporter A contract: not a wallet, and not a wallet with delegated code
    /// @param kind Its kind: first-n or after-n
    /// @param codeHash The hash of the code the reporter must have when the approval runs
    function approveReporter(address reporter, ReporterKind kind, bytes32 codeHash) external;

    /// @notice Retires a reporter, for good. Only the timelock calls it. The reporter writes nothing more to any
    ///         game, made before or after, and no game made from now on copies it. A retirement writes no game's
    ///         status and moves no money.
    /// @param reporter An approved reporter not yet retired
    function retireReporter(address reporter) external;

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
    ///         game, with its own id and its own copy of the reporters and the terms. Refused while the approved
    ///         list holds no first-n reporter, since nothing could write such a game's start.
    /// @param league The league's short text id: 1 to 16 characters, each a-z or 0-9.
    /// @param homeTeam The home team: 1 to 64 printable ASCII characters, not all spaces.
    /// @param awayTeam The away team: 1 to 64 printable ASCII characters, not all spaces, and not the same text
    ///        as the home team.
    /// @param date The scheduled start, in seconds since 1970. Not zero, and at most 365 days after the creation.
    /// @param hints Up to 8 seat and id pairs, no seat twice, each id 1 to 64 printable ASCII characters, not all
    ///        spaces.
    /// @return gameId The new game's id. Ids start at 1 and count up.
    function createGame(
        string calldata league,
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 date,
        Hint[] calldata hints
    ) external returns (uint256 gameId);

    /// @notice The one report call. Only the game's recorded reporters may send it, and none that is retired.
    function report(Report calldata r) external;

    /// @notice How many games exist. Game ids run from 1 to this number.
    function gameCount() external view returns (uint256);

    /// @notice A game's status. Refuses an id that is not a game.
    function getGameStatus(uint256 gameId) external view returns (GameStatus);

    /// @notice A game's start, in seconds since 1970. Refuses a game whose start is not written, whatever its
    ///         status. A written start is never 0 and lies within a day of the date the game was created with.
    function getGameStart(uint256 gameId) external view returns (uint64);

    /// @notice A game's two scores. Refuses unless the game's status is Scored, so no game reads as scored,
    ///         at 0-0 or at any score, unless a score was written.
    function getGameScores(uint256 gameId) external view returns (uint32 homeScore, uint32 awayScore);

    /// @notice A game's n: its window, in seconds, copied when the game was created.
    function getGameWindow(uint256 gameId) external view returns (uint64);

    /// @notice A game's four terms, copied from its league's when the game was created.
    function getGameTerms(uint256 gameId) external view returns (Terms memory);

    /// @notice True when every one of the game's recorded reporters is retired. Nothing can write to such a
    ///         game again, so it can be released at once, ahead of its day-30 clock.
    function isEveryReporterRetired(uint256 gameId) external view returns (bool);

    /// @notice The approved list as it stands: what a game made now copies, in the order it copies it.
    function getApprovedReporters() external view returns (address[] memory reporters, uint8[] memory kinds);

    /// @notice A reporter's kind and whether it is retired. A kind of None means it was never approved.
    function getReporter(address reporter) external view returns (ReporterKind kind, bool retired);

    /// @notice The terms a game in `league` made now would copy: the league's own, or the default terms if it
    ///         has none. An empty `league` reads the default terms.
    function getTerms(string calldata league) external view returns (Terms memory);
}
