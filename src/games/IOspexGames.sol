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
    /// @dev 3: a dispute record is written. The game is not over: it still takes a score from any of its
    ///      reporters permitted at that hour, and later dispute reports as updates; its void opens only when the
    ///      day-7 clock, counted from the record, has run.
    Disputed,
    /// @dev 4: its score is written. An end.
    Scored,
    /// @dev 5: a void is written. An end. A void is a status, never a scored 0-0.
    Voided,
    /// @dev 6: released. An end of its own, by anyone once the day-30 clock has run from the date given at
    ///      creation, or every reporter that could still write to the game is retired; the betting set reads it
    ///      as a void.
    Released
}

/// @notice A reporter's kind, recorded with the reporter.
enum ReporterKind {
    /// @dev 0: not a reporter. Never recorded.
    None,
    /// @dev 1: writes from the start, inside n and after it. Inside n, [start, start + n), it is the only kind
    ///      that may write.
    FirstN,
    /// @dev 2: writes from start + n, that second included. It writes no start.
    AfterN
}

/// @notice What a report is.
enum ReportKind {
    /// @dev 0: no kind. Refused.
    None,
    /// @dev 1: the game's start.
    Start,
    /// @dev 2: the game's score. An end.
    Score,
    /// @dev 3: a void. An end, from start + n; on a disputed game, from the day-7 clock.
    Void,
    /// @dev 4: a dispute record, which starts the day-7 clock; on a disputed game, an update to it, which
    ///      writes nothing.
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

/// @notice One feed's reading, as a report gives it. The games set emits readings and stores none, and refuses a
///         report its own readings contradict (see Report).
/// @param seat The feed's seat: its number in the scoring program's feed table. A feed is never named here, and
///        no two readings in one report name the same seat.
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
/// @param readings The readings the report rests on, one per feed asked, no seat twice, and a silent one at 0-0.
///        The games set reads them against the result the report carries and refuses a contradiction: a score
///        must be read as a final by at least one of them, and by AGREE of them on a disputed game, and no final
///        may read otherwise than the score, except on a disputed game from its day-7 clock, where the rule
///        settles over one dissent; a void may not carry AGREE finals that read the same, at hour 24 or at day 7,
///        since the rule scores on them. Nothing else in a reading is checked.
/// @param payout The payout address: where the report that ends a game credits its creation fee. The games set
///        never puts the sender in its place. Zero for a start and for a dispute record, which pay nothing. A
///        score and a void refuse as payout: zero and the rest of the reserved range up to 0xffff, where
///        precompiles and a chain's own contracts lie, the games set's own address and the coin's, none of which
///        withdraws; and any address ever approved as a reporter, retired ones included and the sender among
///        them, since a reporter relays a report and is never the one it pays.
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
///         it is created and keeps them. A change reaches only games made after it. The clocks are named for
///         their launch values (7 days, 30 days); a league's may be others, so read a game's own terms.
/// @param window n, in seconds: the game's window, [start, start + n), the same n the scoring program uses.
///        Inside it only a first-n reporter writes; an after-n reporter writes from start + n, that second
///        included, and the hour-24 void can post from then. n counts from the start as written.
/// @param day7Clock In seconds: how long after a dispute record a disputed game's void opens. Longer than n. A
///        disputed game takes a score at any hour a reporter may write; only its void waits for this clock.
/// @param day30Clock In seconds: how long after the date given at creation anyone may release a game that has
///        not ended, and from when every report to it is refused. Set at creation and moved by nothing after,
///        the start included. Longer than n and the day-7 clock together.
/// @param fee The creation fee, in the smallest unit of the coin the games set takes it in. Zero is legal, and
///        at zero nothing is taken. A game holds the fee it copied until it ends, whatever its league's is now.
struct Terms {
    uint64 window;
    uint64 day7Clock;
    uint64 day30Clock;
    uint96 fee;
}

/**
 * @title IOspexGames
 * @author ospex.org
 * @notice The games set: games anyone creates, the reporters each game keeps, how each game ends, and the five
 *         reads that tell any contract what happened. A game copies the approved reporters, with their kinds,
 *         and its league's terms when it is created, and only those reporters ever write to it. Its start and
 *         its score are each written once. The approved list and the terms change only by the Polygon
 *         timelock's three calls.
 *
 *         Every game ends once, as a score, a void or a release, and after its end nothing more is written to
 *         it. A score and a void are reports; a dispute record is a report that ends nothing and starts the
 *         day-7 clock, after which a disputed game's void opens; a release is anyone's call once the day-30
 *         clock has run, counted from the game's date, or every one of the game's reporters that could still
 *         write to it is retired. From the day-30 clock the release is the only door: no report is taken. The
 *         games set refuses a report its own readings contradict, and re-derives no result.
 *
 *         A game's creator pays its creation fee when it is created, and the games set holds it until the game
 *         ends. The report that ends the game credits it to the payout address inside that report; a release
 *         credits it back to the creator. Whoever is credited withdraws it later: no coin moves inside an end.
 */
interface IOspexGames is IGameReporters {
    /// @notice Emitted once, by the constructor: the timelock that alone makes the three calls. It never
    ///         changes, so an indexer reading events alone can check it against the timelock it expects.
    /// @param timelock The timelock's address
    event TimelockSet(address indexed timelock);

    /// @notice Emitted once, by the constructor: the coin the creation fee is paid in. It never changes.
    /// @param token The coin's address
    event TokenSet(address indexed token);

    /// @notice Emitted when a game's end credits its creation fee: to the payout address in the report that
    ///         ended it, or to its creator when it is released. A game's fee is credited once. A fee of 0
    ///         credits nothing and emits nothing.
    /// @param gameId The game
    /// @param account The address credited, which withdraws it
    /// @param amount The fee the game copied at its creation
    event FeeCredited(uint256 indexed gameId, address indexed account, uint256 amount);

    /// @notice Emitted when an address withdraws everything it has been credited.
    /// @param account The address that withdrew, and was paid
    /// @param amount Its whole credit, which is what the games set's coin balance fell by. A coin that keeps a
    ///        cut on the way delivers the account less.
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice Emitted when a game is released: ended with no score and no void, by anyone, once its day-30 clock
    ///         has run or every one of its reporters that could still write to it is retired. Its creation fee is
    ///         credited back to its creator
    ///         (FeeCredited, emitted before this), never to the caller. The game's other ends, a score and a void,
    ///         are reports and emit GameReported.
    /// @param gameId The game
    /// @param caller The address that released it, which pays the gas and gets nothing
    event GameReleased(uint256 indexed gameId, address caller);

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
    /// @param terms The four terms. The clocks run in order: n at least one second, the day-7 clock longer than
    ///        n, the day-30 clock longer than n and the day-7 clock together, and at most MAX_CLOCK. This
    ///        orders the clocks' lengths; a dispute recorded late can still have its day-7 result fall due at or
    ///        after the day-30 clock, where it is refused and the game ends as a release.
    function setTerms(string calldata league, Terms calldata terms) external;

    /// @notice Approves a reporter. Only the timelock calls it. The code at the address must hash as named, so
    ///         what is approved is what the queued call announced. The hash is stored with the reporter, and a
    ///         report it sends is taken only while its code still hashes the same. Games made after it copy
    ///         it; games already made never gain it.
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
    ///         game, with its own id, its own copy of the reporters and the terms, and its own creation fee.
    ///         Refused while the approved list holds no first-n reporter, since nothing could write such a
    ///         game's start. The creator pays the creation fee its league's terms name as the creation runs, in
    ///         the coin fixed at deploy, so the creator first allows this contract to take it; at a fee of 0
    ///         nothing is taken and the coin is not called. Refused, before the coin is called, when that fee is
    ///         above `maxFee`, so a fee change that lands between the creator's look and its creation never takes
    ///         more than the creator named. Refused unless taking the fee raises this contract's coin balance by
    ///         exactly the fee. The games set holds the fee until the game ends.
    /// @param league The league's short text id: 1 to 16 characters, each a-z or 0-9.
    /// @param homeTeam The home team: 1 to 64 printable ASCII characters, not all spaces.
    /// @param awayTeam The away team: 1 to 64 printable ASCII characters, not all spaces, and not the same text
    ///        as the home team.
    /// @param date The scheduled start, in seconds since 1970. Not zero, and at most 365 days after the creation.
    /// @param hints Up to 8 seat and id pairs, no seat twice, each id 1 to 64 printable ASCII characters, not all
    ///        spaces.
    /// @param maxFee The most the creator will pay, in the coin's smallest unit: the fee read from getTerms
    ///        before sending, or anything above it. The creation takes the fee as it runs, never this amount.
    /// @return gameId The new game's id. Ids start at 1 and count up.
    function createGame(
        string calldata league,
        string calldata homeTeam,
        string calldata awayTeam,
        uint64 date,
        Hint[] calldata hints,
        uint256 maxFee
    ) external returns (uint256 gameId);

    /// @notice The one report call. Only the game's recorded reporters may send it, none that is retired, and
    ///         none whose code hashes otherwise than the hash recorded at its approval. A first-n reporter writes
    ///         from the game's start; an after-n reporter from start + n, that second included. A start is
    ///         written once, by a first-n reporter, and credits nothing. A score ends the game and credits its
    ///         creation fee to the payout address in the report; it is taken at or after the start, a dispute
    ///         record or not. A void ends the game the same way, with no score stored, from start + n for a
    ///         reporter of either kind, and on a disputed game only once its day-7 clock has run. A dispute
    ///         record carries a zero payout, credits nothing and ends nothing: the first one writes Disputed and
    ///         starts the day-7 clock; every later one is an update, taken and emitted, writing nothing. Every
    ///         report the games set takes is emitted with its readings, which are not stored. An update's event
    ///         has the record's shape; a game's first dispute event is its record, and getGameDisputedAt gives
    ///         the record's time. A game that has ended takes no report of any kind, and no game takes one at or
    ///         after its day-30 clock (PastDay30Clock), counted from the date given at creation: from that second
    ///         the release is the only door. A report its own readings contradict is refused (see Report).
    function report(Report calldata r) external;

    /// @notice Releases a game that has not ended: no score, no void, no release, a dispute record or not.
    ///         Anyone may, once the game's day-30 clock has run, counted from the date given at creation, which
    ///         no write after creation moves; or at once, for a game whose every recorded reporter that could
    ///         still write to it is retired (see isEveryReporterRetired). A release is an end of its own: the
    ///         game's status reads Released, the betting set reads it as a void, and its creation fee is credited
    ///         back to its creator, who withdraws it later. The caller pays the gas and gets nothing. Refused for
    ///         an id that is not a game, for a game that has ended (GameEnded), and otherwise while the clock has
    ///         not run and such a reporter is not retired (ReleaseNotOpen). The clock opens the release and at the
    ///         same second closes every report: a score or a void that lands before it ends the game, and from
    ///         it the release is the only door, a dispute record or not.
    function release(uint256 gameId) external;

    /// @notice Pays the caller everything it has been credited, and sets its credit to 0. Only the address
    ///         credited withdraws, and only to itself. When the coin refuses the transfer (the coin paused, or
    ///         the caller or this contract blocked by it), or the payment lowers this contract's coin balance by
    ///         other than the amount, this call alone fails and the credit stays.
    /// @return amount The whole credit, which is what this contract's coin balance fell by
    function withdraw() external returns (uint256 amount);

    /// @notice What an address has been credited and not yet withdrawn.
    function getCredit(address account) external view returns (uint256);

    /// @notice A game's creation fee as the games set holds it: the amount held for the game, read from its
    ///         status (its fee until it ends, 0 after), and the creator a release credits it back to.
    function getGameFee(uint256 gameId) external view returns (uint96 held, address creator);

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

    /// @notice True when every one of the game's recorded reporters that could still write to it is retired:
    ///         for a game whose start is not written, every first-n reporter, since an after-n reporter writes no
    ///         start and nothing before one; for a game with a start, every reporter. Nothing can write to such a
    ///         game again, so it can be released at once, ahead of its day-30 clock.
    function isEveryReporterRetired(uint256 gameId) external view returns (bool);

    /// @notice When a game's dispute record was written, in seconds since 1970: the time its day-7 clock counts
    ///         from, which nothing after the record moves. Refuses a game with no dispute record, whatever its
    ///         status; a game that ended after its record still answers.
    function getGameDisputedAt(uint256 gameId) external view returns (uint64);

    /// @notice The approved list as it stands: what a game made now copies, in the order it copies it.
    function getApprovedReporters() external view returns (address[] memory reporters, uint8[] memory kinds);

    /// @notice A reporter's kind, whether it is retired, and the code hash recorded at its approval, which
    ///         every report it sends is checked against. A kind of None and a hash of 0 mean it was never
    ///         approved.
    function getReporter(address reporter) external view returns (ReporterKind kind, bool retired, bytes32 codeHash);

    /// @notice The terms a game in `league` made now would copy: the league's own, or the default terms if it
    ///         has none. An empty `league` reads the default terms.
    function getTerms(string calldata league) external view returns (Terms memory);
}
