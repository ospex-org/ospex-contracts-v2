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
    Terms,
    OpenGame
} from "./IOspexGames.sol";
import {IOspexReporter} from "./IOspexReporter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title OspexGames
 * @author ospex.org
 * @notice The games contract of Ospex v3's games set. The design it is built to is docs/spec-v3.md in this
 *         repository, which controls where the two differ.
 *
 *         Anyone creates a game. When it is created, a game copies the approved list of reporters as it
 *         stands, each with its kind, and its league's four terms, and nothing changes either copy afterwards.
 *         Only the game's recorded reporters write to it, all through one report call in one report shape. A
 *         retired reporter writes to no game, and neither does a reporter whose code no longer hashes as it did
 *         when it was approved. The start is written once, by a first-n reporter. The score is written once,
 *         never before the start, and is final. Five reads, open to any address, tell any contract what
 *         happened.
 *
 *         The approved list and the terms change only by the Polygon timelock, after its delay, through three
 *         calls: set a league's terms (or the default terms), approve a reporter, and retire a reporter. The
 *         constructor writes the first state, the default terms and the first reporters, each reporter admitted
 *         as an approval admits one. This contract keeps no wait of its own. Spec: "The Polygon timelock's
 *         calls" and "What is written without a wait".
 *
 *         An approval checks on chain what it can: the reporter has code, the code is not a wallet's delegation
 *         (EIP-7702), and it hashes as the call named. The hash is stored with the reporter, and every report
 *         the reporter sends is checked against it. An approval does not show that a reporter's behaviour is
 *         fixed, that the values it reports are true, or that it scores correctly: that it has no owner and no
 *         setter and is not a proxy is for review, before the call is queued. Spec: "The approved list".
 *
 *         The creation fee. A creation takes the game's fee from its creator, in the coin fixed at deploy: the
 *         fee in the league's terms, copied into the game with them. The creator names the most it will pay; a
 *         fee above that is refused before the coin is called, so a raise past it is never taken. At 0 nothing
 *         is taken. Above 0, a creation is refused unless taking the fee raises this contract's balance by
 *         exactly the fee: a coin's cut of a transfer, or its addition to one, alone makes no game. A withdrawal
 *         is refused unless paying it lowers that balance by exactly the amount, so a coin that takes more from
 *         this contract than it sends pays no credit out of another's; under a coin that charges the sender,
 *         every withdrawal waits until the charge stops. Neither a creation nor a withdrawal can begin while
 *         either runs, so a coin that calls back during a transfer cannot have one transfer's balance change
 *         counted for another. A coin that changes balances outside a transfer, as a rebasing coin does, is
 *         outside these checks; USDC does none of these things. The game holds the fee until it ends. The
 *         report that ends it credits the amount to the payout address inside the report, and the sender never
 *         takes that address's place; a release credits it back to the creator.
 *         Each end credits once, through one internal call that writes the end and the credit together and
 *         refuses a game already ended. No coin moves inside an end: the address credited withdraws later, so a
 *         coin that refuses a transfer stops a withdrawal and never an end. The coin is held for games not yet
 *         ended and for credits not yet withdrawn; there is no receiver, no setter for one, and no other way
 *         out. Coin sent here directly is held by no one and stays. Spec: "The creation fee".
 *
 *         How a game ends. Every game ends once, as a score, a void or a release, and after its end nothing more
 *         is written to it: no report of any kind, and no release. A score and a void come through the report
 *         call, from one of the game's recorded reporters permitted at that hour, and each credits the fee to the
 *         payout address inside the report. A void is a status, never a score of 0-0, and is taken from start + n,
 *         that second included, by a reporter of either kind: the hour-24 void. A dispute record comes through
 *         the same call, from the start by a first-n reporter and from start + n by an after-n one; it carries no
 *         payout, credits nothing and ends nothing. It is a record, not a lock: a disputed game still takes a
 *         score from any of its reporters permitted at that hour, and takes later dispute reports as updates,
 *         which write nothing. What the first record does is start the day-7 clock, counted from that record and
 *         moved by nothing after it: on a disputed game a void is taken only from that clock. The release is the
 *         end no reporter writes. Anyone may release a game that has not ended once its day-30 clock has run,
 *         counted from the date given at creation; or at once, when every one of the game's reporters that could
 *         still write to it is retired: every first-n reporter for a game whose start is not written, since an
 *         after-n reporter writes no start, and every reporter otherwise. A release credits the fee back to the
 *         creator and nothing to the caller. The three clocks are the game's own copied terms, and each is set
 *         once: n, and with it the hour-24 void, counts from the start as written; the day-7 clock from the first
 *         dispute record; the day-30 clock from the date. No write after creation moves any of them, a start
 *         written early or late included. From the day-30 clock the release is the only door: a start, a score,
 *         a void, a dispute record or an update at or after it is refused (PastDay30Clock), so a game still open
 *         then, a dispute record or not, ends as a release and its fee goes back to the creator. Before that
 *         clock the first end to land is the game's. Spec: "How a game ends", "Retiring a reporter", "The
 *         terms".
 *
 *         The readings. A report carries the feeds' readings, one per seat, and every report is emitted with
 *         them. This contract refuses a report its own readings contradict, and re-derives no result: no two
 *         readings name one seat; a silent reading carries no score; a score is read as a final by as many of
 *         its readings as the scoring program scores on at that clock, AGREE inside n and on a disputed game,
 *         AGREE_AFTER_N from start + n on a game with no dispute record, and no final reads otherwise, except on
 *         a disputed game from its day-7 clock, where the rule settles three of four over one dissent; a void
 *         carries no finals that read the same in that count, at hour 24 or at day 7, since that is a score's
 *         agreement and the rule scores on it at either clock. Which readings settle a game is the scoring
 *         program's rule, behind the reporter's code hash; these checks are a second door, and a report that
 *         passes them is not thereby true. Spec: "The scoring program", "Must never happen".
 *
 *         Correcting a start or a score: there is none. Each is written once. Feeds that disagree lead to a
 *         dispute record and its updates, never to a correction. Spec: "The start is written once" and "A
 *         score is written once and is final".
 *
 *         What a scorer picks up. Whatever scores a game, a runner on a schedule or an agent checking a
 *         settlement, reads the game and never its events, so three reads beside the five hold what the events
 *         carry and the rest of this contract does not read: a game's identity as its creator gave it, stored
 *         at creation word for word (getGameIdentity); the readings its start report carried, stored as given,
 *         with each seat's last vote, which every dispute record and update writes for each seat whose reading
 *         is not silent while a silent reading leaves a seat's vote as it was, beside the time of the dispute
 *         record (getGameReadings); and the list of games not yet ended, which a game joins at creation and
 *         leaves at its end, read whole or by page as rows that carry, beside the id, the words a reader decides
 *         on (getOpenGames). A dispute report whose readings are those of
 *         a dispute report the game already took, in the same order, is refused, so an old decision delivered
 *         again cannot become the newest vote; this contract keeps the hash of every dispute report's readings
 *         it takes for the game. A seat's vote on record is what the day-7 run reads for a seat that no longer
 *         answers; a seat that answers is read fresh. Spec: "What a game is", "One report shape for every
 *         reporter", "Something asks for scores by itself".
 *
 *         It has no owner, no pause, no setter but the timelock's three calls, and no way to correct a start or
 *         a score. It refuses no league.
 *
 * @dev    What the report call and the release read, by whether it can change between a game's creation and
 *         its end. Each thing that could change and must not is either never written again or compared with
 *         what was recorded:
 *         - Pinned when written, and never written again: the game's reporters and their kinds, its four terms,
 *           its date and its identity, from its creation, the date being what its day-30 clock counts from;
 *           among the terms its creation fee, which is the amount the game holds and its end credits, whatever
 *           the league's fee is now; its start, once written, which n counts from, and the readings the start
 *           report carried; the time of its dispute record, once written, which the day-7 clock counts from
 *           and an update never moves; and this contract's own limits and coin, which are constants. A release
 *           reads one thing more, also pinned at creation: the creator it credits. Neither the report call nor
 *           the release reads the identity, the start's readings, the votes or the open list: they are written
 *           for readers outside this contract, and the dispute report's repeat check reads only the hashes of
 *           the game's own earlier dispute reports.
 *         - Checked at the door against a stored value: the sender's code. Its live hash must equal the hash
 *           recorded at its approval, or the report is refused (CodeChanged).
 *         - Live by design: the sender's retired flag, because a retirement is meant to reach games already
 *           made, and with it whether every reporter that could still write to a game is retired, which opens
 *           its release; the clock,
 *           because when a report or a release may land is what the gates decide; the game's status, because
 *           it is what the reports themselves write, each step once and never back, and whether the game still
 *           holds its fee is read from it; the payout address's credit, which an end adds to and only that
 *           address's withdrawal takes from; and whether the payout address was ever approved as a reporter,
 *           so a reporter approved after the game's creation is refused as its payout too.
 *         - Not read, so not checked here: what a reporter's own storage holds, such as a proxy's logic or an
 *           owner's setting. A reporter whose behaviour can change while its code stays the same keeps its
 *           hash; the public delay before its approval is for finding that. Values a reporter holds as
 *           immutables are written into its code, so its hash covers them. Nor the coin: no end calls it, so
 *           whether the coin would take or refuse a transfer has no say in an end.
 *
 *         n counts from the start as written. A first-n reporter writes from the start; an after-n reporter
 *         writes from start + n, that second included, so n's window is [start, start + n), the window the
 *         scoring program uses. A start written at or after start + n opens the after-n score, and the void,
 *         at once. The day-7 clock counts from the dispute record as written, so a record written late, or
 *         long after start + n, has its whole clock, and its void may fall due at or after the day-30 clock,
 *         where it is refused: the game ends as a release. The day-30 clock counts from the date, so a start
 *         written a day late or a day early moves nothing, and a start at or after that clock is refused like
 *         every other report then.
 *
 *         Every end is written by `_end` and nowhere else, and `_end` refuses a game already ended and a status
 *         that is not an end, whatever its caller checked. Each caller checks the status first for its own
 *         reason (StartNotWritten, GameEnded), so a reader learns why; `_end` is the one lock behind all of
 *         them, and the one place the fee is credited. Nothing writes a status back: a game moves Unverified,
 *         Verified, Disputed, then one end, and a retirement writes no game.
 *
 *         If every first-n reporter a game recorded is retired before its start is written, nothing can write
 *         that start: an after-n reporter writes no start, and a reporter approved later is not on the game's
 *         copy. Such a game counts as one whose every reporter is retired, since none left could write to it,
 *         and anyone releases it at once; its fee goes back to the creator.
 *
 *         A score and a void refuse as the payout address: address 0 and every address up to MAX_RESERVED_ADDRESS (the
 *         range EIP-1352 sets aside for precompiles and a chain's own contracts, which no key and no deployment
 *         reaches in practice), this contract and the coin, none of which calls `withdraw`; and any address ever
 *         approved as a reporter, retired ones included and the sender among them, since a reporter relays a
 *         report and is never the one it pays. It refuses no other, though the chain could name more that
 *         cannot call `withdraw`. That a payout address can call `withdraw` is for review: a contract named
 *         as payout, or a contract that creates games, with no way to call it leaves its credit here for good.
 *
 *         Operating rules for the timelock's calls, kept outside the code:
 *         - The stock timelock lets anyone run a ready call, in any order and at any later time. Chain calls
 *           that depend on each other through `predecessor`, and cancel a call that another replaces before it
 *           is ready.
 *         - Approve a new first-n reporter before retiring the last one, chained, or creation is refused in
 *           between.
 *         - A raised delay applies to calls scheduled after it: a call queued under the shorter delay runs once
 *           that delay is up. Read the queue, not only the delay.
 *         - The signpost checks only that this contract records each game's reporters. Before moving a games
 *           entry to live, check that the list holds a first-n reporter and that the named game's reporters are
 *           not all retired.
 *         - A reporter whose code changed writes nothing, but it is not retired, so no game counts it as
 *           retired. Retire it, so that a game left with no other reporter can be released at once.
 *         - A score needs as many finals reading it as the program scores on at that clock, AGREE inside n and
 *           on a disputed game, AGREE_AFTER_N from start + n on a game with no dispute record, and a disputed
 *           game's before its day-7 clock no final reading otherwise; a program that settles a disputed game on
 *           two finals, or beside a dissenting spare, has its report refused here and waits for a third, or for
 *           day 7. A void over that many finals that agree is refused at every clock, day 7 included: those
 *           finals score.
 */
contract OspexGames is IOspexGames, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────

    /// @notice The largest score accepted for one team. It is far above any real score in a sports league.
    ///         It exists so that the betting set's line arithmetic, which multiplies a score by 10 inside a
    ///         signed 32-bit integer, cannot overflow: 1,000,000 x 10 is under 2^31. A score that overflowed
    ///         there would leave a market that can never settle.
    uint32 public constant MAX_SCORE = 1_000_000;

    /// @notice How far a written start may lie from the date given at creation, either way, inclusive. A day is
    ///         a game's identity: a start further from its date than this is another game. It is fixed, and is
    ///         not the game's n, so a league's n never changes which starts a game takes. Writing a start moves
    ///         no clock: the day-30 clock counts from the date.
    uint64 public constant START_BOUND = 24 hours;

    /// @notice How many finals that read the same stand behind a result for this contract to call them
    ///         agreement inside n and on a disputed game: the count a score must carry there, and the count a
    ///         day-7 void may not. It is the scoring program's count for a score inside n and for a day-7
    ///         settlement, and the spec's "three agreeing recorded sources". A constant, not a term: a key that
    ///         could lower it could lower what settles a disputed game, and the program's count is frozen in its
    ///         fingerprint, so a new count is a new program and a new reporter approval either way.
    uint256 public constant AGREE = 3;

    /// @notice How many finals that read the same are agreement from start + n on a game with no dispute
    ///         record: the count a score must carry there, and the count an hour-24 void may not. It is the
    ///         scoring program's count for a score after n, where two counting seats that agree settle a game
    ///         the window did not. Which count a report is held to is the game's clock's to say: AGREE until
    ///         its start as written plus its own copied n, the second an after-n reporter writes from, and this
    ///         from it (see _agreement). A constant, as AGREE is, for the same reason.
    uint256 public constant AGREE_AFTER_N = 2;

    /// @notice How far ahead of its creation a game's date may be. A date further ahead is refused: it is far
    ///         more likely a mistake than a game, the likeliest being a time in milliseconds, which reads as
    ///         tens of thousands of years ahead. It also keeps every clock counted from the date or the start
    ///         far inside 64 bits. A game with a later date can be created nearer to it.
    uint64 public constant MAX_DATE_AHEAD = 365 days;

    /// @notice The longest the day-30 clock may be, and so the longest of a game's three clocks, which run in
    ///         order (see setTerms). A clock longer than a year is far more likely a mistake, such as
    ///         milliseconds, than a term.
    uint64 public constant MAX_CLOCK = 365 days;

    /// @notice The most reporters the approved list holds at once. A game copies the whole list when it is
    ///         created and its report call looks through that copy, so the list has a ceiling. A retired
    ///         reporter leaves the list and frees its place.
    uint256 public constant MAX_REPORTERS = 8;

    /// @notice The longest league id, in bytes. A league id is lowercase letters and digits only, so two ids
    ///         never differ by case alone. Which id names which league is a convention outside this contract.
    uint256 public constant MAX_LEAGUE_LENGTH = 16;

    /// @notice The longest team name, in bytes of printable ASCII.
    uint256 public constant MAX_TEAM_LENGTH = 64;

    /// @notice The most hints a creation may give.
    uint256 public constant MAX_HINTS = 8;

    /// @notice The longest hint id, in bytes of printable ASCII.
    uint256 public constant MAX_HINT_ID_LENGTH = 64;

    /// @notice The highest address a score refuses as payout for where it lies. Addresses 0 to this one are the
    ///         range EIP-1352 sets aside for precompiles and a chain's own contracts. Polygon's sit there, its
    ///         native coin's contract at 0x1010 among them, and none was written to call this contract. A key or
    ///         a deployment lands in the range only after about 2^144 tries.
    address public constant MAX_RESERVED_ADDRESS = address(0xffff);

    // ──────────────────────────── Types ────────────────────────────────

    /// @dev A game as stored: what the report call and the release read. Its identity (league, teams, hints)
    ///      is in the creation event and stored beside it (s_identities); nothing here reads it. Its creator is
    ///      in the event and stored too, because a release credits the creator.
    /// @param status Where the game stands
    /// @param date The scheduled start the creator gave
    /// @param start The start, once written. A written start is never 0 and is within START_BOUND of the date.
    /// @param homeScore The home team's score, once written
    /// @param awayScore The away team's score, once written
    /// @param terms The four terms, copied from the game's league at creation. Their fee is the amount the game
    ///        holds until it ends.
    /// @param creator The address that created the game and paid its fee: what a release credits
    /// @param disputedAt When the dispute record was written; 0 until then. The day-7 clock counts from it, and
    ///        nothing moves it once written: an update to the record writes nothing.
    /// @param openPlace The game's place on the open list plus one, while it has not ended; 0 from its end. It
    ///        shares the creator's word, so the list costs a game no word of its own.
    struct Game {
        GameStatus status;
        uint64 date;
        uint64 start;
        uint32 homeScore;
        uint32 awayScore;
        Terms terms;
        address creator;
        uint64 disputedAt;
        uint32 openPlace;
    }

    /// @dev A game's identity as its creator gave it, stored at creation and never written again, for the
    ///      readers that pick a game up. The date is in the game itself. Nothing in this contract reads it.
    struct Identity {
        string league;
        string homeTeam;
        string awayTeam;
        Hint[] hints;
    }

    /// @dev A reporter and its kind.
    struct Reporter {
        address account;
        ReporterKind kind;
    }

    /// @dev What the games set knows of an address as a reporter. A kind of None means never approved. A
    ///      retired reporter keeps its kind and its code hash, and stays retired for good. The code hash is the
    ///      one its approval named and the chain confirmed; every report the reporter sends is checked against
    ///      it. Nothing writes an admission again once it is approved, but its retirement.
    struct Admission {
        ReporterKind kind;
        bool retired;
        bytes32 codeHash;
    }

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the constructor's timelock has no code, or has only a wallet's delegation
    error OspexGames__TimelockNotAContract(address timelock);
    /// @notice Thrown when the constructor's timelock is the deployer itself
    error OspexGames__TimelockIsTheDeployer(address timelock);
    /// @notice Thrown when the constructor's coin has no code, or has only a wallet's delegation
    error OspexGames__TokenNotAContract(address token);
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
    /// @notice Thrown when a reporter to be approved has no fixed-values read, or its read reverts, tries to
    ///         write, or answers with no values. A read that answers with something that does not decode as
    ///         one bytes value is refused too, by the decoder, which gives no reason.
    error OspexGames__NoFixedValues(address reporter);
    /// @notice Thrown when a reporter that is not on the approved list is retired
    error OspexGames__NotApproved(address reporter);
    /// @notice Thrown when a set of terms does not run in order: n is 0, the day-7 clock is not longer than n,
    ///         n and the day-7 clock together are not shorter than the day-30 clock, or the day-30 clock is
    ///         longer than MAX_CLOCK
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
    /// @notice Thrown when a report's sender has code that hashes otherwise than the hash recorded at its
    ///         approval, no code at all included
    error OspexGames__CodeChanged(address reporter, bytes32 approved, bytes32 found);
    /// @notice Thrown for a report with no kind. (A kind past the last is refused by the decoder.)
    error OspexGames__ReportKindNotTaken(ReportKind kind);
    /// @notice Thrown when a report sets a field its kind does not use: a score or a payout on a start, a start
    ///         on a score, a start or a score on a void, and a start, a score or a payout on a dispute record
    error OspexGames__FieldNotEmpty(ReportKind kind);
    /// @notice Thrown when a report that ends a game names no payout address: address 0 can never withdraw
    error OspexGames__NoPayout(ReportKind kind);
    /// @notice Thrown when a report that ends a game names as its payout address one of the addresses from 1 to
    ///         MAX_RESERVED_ADDRESS: a precompile or a chain's own contract, which never calls withdraw
    error OspexGames__PayoutIsReserved(ReportKind kind, address payout);
    /// @notice Thrown when a report that ends a game names this contract as its payout address: this contract
    ///         never calls its own withdraw, so a credit to it could never be withdrawn
    error OspexGames__PayoutIsTheGamesSet(ReportKind kind);
    /// @notice Thrown when a report that ends a game names the coin's own address as its payout address: the
    ///         coin does not call withdraw, so a credit to it could never be withdrawn
    error OspexGames__PayoutIsTheCoin(ReportKind kind);
    /// @notice Thrown when a report that ends a game names as its payout address any address ever approved as a
    ///         reporter, retired ones included and the sender among them: a reporter relays a report and is never
    ///         the one it pays
    error OspexGames__PayoutIsAReporter(ReportKind kind, address reporter);
    /// @notice Thrown when taking a creation's fee does not raise this contract's coin balance by exactly the
    ///         fee: a coin that keeps a cut of a transfer, or adds to one. No game is made.
    error OspexGames__FeeNotReceived(uint256 fee, uint256 balanceBefore, uint256 balanceAfter);
    /// @notice Thrown when a creation's fee, its league's fee as the creation runs, is above the most its caller
    ///         named. Nothing is taken and the coin is not called.
    error OspexGames__FeeAboveMax(uint256 fee, uint256 maxFee);
    /// @notice Thrown when an address with no credit withdraws
    error OspexGames__NothingToWithdraw(address account);
    /// @notice Thrown when paying a withdrawal does not lower this contract's coin balance by exactly the amount:
    ///         a coin that charges this contract more than it sends, or less. The credit stays.
    error OspexGames__WithdrawalNotExact(uint256 amount, uint256 balanceBefore, uint256 balanceAfter);
    /// @notice Thrown when a reading marked silent carries a score: a feed that did not answer gave none
    error OspexGames__SilentReadingNotEmpty(uint256 index);
    /// @notice Thrown when two readings in one report name the same seat. The index is the second of the two.
    error OspexGames__ReadingSeatRepeated(uint256 index);
    /// @notice Thrown when fewer of a score's readings are finals that read the score than the game needs at
    ///         that clock: AGREE inside n and on a disputed game, AGREE_AFTER_N from start + n on a game with no
    ///         dispute record
    error OspexGames__TooFewFinalsAgree(uint256 agreeing, uint256 needed);
    /// @notice Thrown when a score carries a final that reads otherwise than the score, except on a disputed game
    ///         from its day-7 clock, where the rule settles over one dissent. The index is the first such reading.
    error OspexGames__FinalDissents(uint256 index);
    /// @notice Thrown when a void carries as many finals that read the same as a score needs at that clock,
    ///         AGREE_AFTER_N at hour 24 on a game with no dispute record and AGREE at day 7 on a disputed one:
    ///         that is a score's agreement, not a void's. The scores are the ones they agree on.
    error OspexGames__FinalsAgree(uint32 homeScore, uint32 awayScore);
    /// @notice Thrown for any report to a game that has ended, scored, voided or released, and for a release of
    ///         one: nothing more is written to an ended game
    error OspexGames__GameEnded(uint256 gameId, GameStatus status);
    /// @notice Thrown when `_end` is handed a status that is not an end. No call reaches it: it guards the one
    ///         place an end is written against a caller that names the wrong status.
    error OspexGames__NotAnEnd(GameStatus status);
    /// @notice Thrown when a start is reported for a game whose start is already written
    error OspexGames__StartAlreadyWritten(uint256 gameId);
    /// @notice Thrown when a start is reported by a reporter that is not first-n for the game
    error OspexGames__NotFirstN(uint256 gameId, address reporter);
    /// @notice Thrown when a reported start is 0, or more than START_BOUND from the date given at creation
    error OspexGames__StartOutOfRange(uint256 gameId, uint64 start);
    /// @notice Thrown when a score, a void or a dispute record is reported, or a start read, for a game whose
    ///         start is not written
    error OspexGames__StartNotWritten(uint256 gameId);
    /// @notice Thrown when a score or a dispute record is reported before the game's start
    error OspexGames__BeforeStart(uint256 gameId, uint64 start);
    /// @notice Thrown when an after-n reporter reports a score or a dispute record before start + n, and when a
    ///         reporter of either kind reports a void before start + n. The void opens at that second.
    error OspexGames__InsideWindow(uint256 gameId, uint256 opensAt);
    /// @notice Thrown when a void is reported for a disputed game before its day-7 clock has run: the clock
    ///         counts from the dispute record, and the void opens at that second
    error OspexGames__InsideDay7Clock(uint256 gameId, uint256 opensAt);
    /// @notice Thrown when a game that has not ended is released before its day-30 clock has run, while a
    ///         reporter that could still write to the game is not retired. The clock counts from the date given
    ///         at creation, and the release opens at that second.
    error OspexGames__ReleaseNotOpen(uint256 gameId, uint256 opensAt);
    /// @notice Thrown when a start, a score, a void, a dispute record or an update is reported at or after the
    ///         game's day-30 clock, counted from the date given at creation: from that second the release is the
    ///         only door, and it opens at it
    error OspexGames__PastDay30Clock(uint256 gameId, uint256 closedAt);
    /// @notice Thrown when a game's dispute record time is read and no dispute record is written
    error OspexGames__NotDisputed(uint256 gameId);
    /// @notice Thrown when a reported score is above MAX_SCORE
    error OspexGames__ScoreOutOfRange(uint32 homeScore, uint32 awayScore);
    /// @notice Thrown when a game's scores are read and the game is not scored
    error OspexGames__NotScored(uint256 gameId, GameStatus status);
    /// @notice Thrown when a dispute record or an update carries the readings of a dispute report the game
    ///         already took, in the same order: an old decision delivered again, which cannot become the newest
    ///         vote
    error OspexGames__DisputeReportRepeated(uint256 gameId);

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The Polygon timelock: the only address that changes the approved list or the terms
    address public immutable i_timelock;

    /// @notice The coin the creation fee is paid in, USDC at launch. Fixed at deploy.
    IERC20 public immutable i_token;

    /// @dev How many games exist. Game ids run from 1 to this number.
    uint256 internal s_gameCount;

    /// @dev The approved reporters, each with its kind, in the order they were approved. A game copies this
    ///      list at its creation. A retired reporter leaves it.
    Reporter[] internal s_approved;

    /// @dev Every address ever approved, with its kind, whether it is retired, and its code hash.
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

    /// @dev What each address has been credited and not yet withdrawn. An end adds a game's fee; only the
    ///      address's own withdrawal takes it away.
    mapping(address => uint256) internal s_credits;

    // What a scorer picks up: written by the creation and the reports, read by nothing in this contract but
    // the three reads for it, and the dispute report's repeat check.

    /// @dev Game id to its identity, written at creation and never again.
    mapping(uint256 => Identity) internal s_identities;

    /// @dev Game id to the readings its start report carried, as given, written with the start and never again.
    mapping(uint256 => Reading[]) internal s_startReadings;

    /// @dev Game id to each seat's last vote: one entry per seat that has ever voted, in the order the seats
    ///      first voted. Every dispute record and update replaces the entry of each seat whose reading is not
    ///      silent; a silent reading leaves the seat's entry as it was.
    mapping(uint256 => Reading[]) internal s_votes;

    /// @dev Game id to the hash of the readings of every dispute report it took. A dispute report whose readings
    ///      hash to one already here is refused.
    mapping(uint256 => mapping(bytes32 => bool)) internal s_disputeReportsTaken;

    /// @dev The games not yet ended. A game joins at its creation and leaves at its end, the last game on the
    ///      list moving into its place; each game's place, plus one, is in its own openPlace.
    uint256[] internal s_open;

    // ──────────────────────────── Constructor ──────────────────────────

    modifier onlyTimelock() {
        if (msg.sender != i_timelock) revert OspexGames__NotTheTimelock(msg.sender);
        _;
    }

    /// @notice Writes the first state, the one write that waits for no timelock: the timelock it answers to,
    ///         the coin the creation fee is paid in, the default terms, and the first reporters, each admitted
    ///         as an approval admits one, with its code hash checked and stored and its fixed values read and
    ///         emitted.
    /// @param timelock The Polygon timelock. A contract, and not the deployer.
    /// @param token The coin the creation fee is paid in: USDC on Polygon at launch. A contract.
    /// @param defaultTerms The terms of every league with none of its own. At launch: n 24 hours, the day-7
    ///        clock 7 days, the day-30 clock 30 days and the fee 1 USDC.
    /// @param reporters The first reporters. At least one, none twice, at most MAX_REPORTERS.
    /// @param kinds Each reporter's kind, in the same order. At least one is first-n.
    /// @param codeHashes The hash of each reporter's code, in the same order.
    constructor(
        address timelock,
        IERC20 token,
        Terms memory defaultTerms,
        address[] memory reporters,
        ReporterKind[] memory kinds,
        bytes32[] memory codeHashes
    ) {
        if (timelock.code.length == 0 || _isDelegated(timelock)) revert OspexGames__TimelockNotAContract(timelock);
        if (timelock == msg.sender) revert OspexGames__TimelockIsTheDeployer(timelock);
        i_timelock = timelock;
        emit TimelockSet(timelock);

        address coin = address(token);
        if (coin.code.length == 0 || _isDelegated(coin)) revert OspexGames__TokenNotAContract(coin);
        i_token = token;
        emit TokenSet(coin);

        _checkTerms(defaultTerms);
        s_defaultTerms = defaultTerms;
        emit TermsSet("", defaultTerms);

        uint256 count = reporters.length;
        if (count == 0) revert OspexGames__NoReporters();
        if (kinds.length != count || codeHashes.length != count) {
            revert OspexGames__LengthsDiffer(count, kinds.length, codeHashes.length);
        }
        for (uint256 i; i < count; ++i) {
            _admit(reporters[i], kinds[i], codeHashes[i]);
        }
        if (!_listHasFirstN()) revert OspexGames__NoFirstNReporter();
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
        Hint[] calldata hints,
        uint256 maxFee
    ) external nonReentrant returns (uint256 gameId) {
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
        // The fee as the creation runs, against the most its caller named: a fee raised since the caller looked
        // is refused here, before anything is written or the coin is called.
        Terms memory terms = _termsOf(league);
        if (terms.fee > maxFee) revert OspexGames__FeeAboveMax(terms.fee, maxFee);

        gameId = ++s_gameCount;
        Game storage g = s_games[gameId];
        g.status = GameStatus.Unverified;
        g.date = date;
        g.terms = terms;
        g.creator = msg.sender;
        _joinOpen(g, gameId);

        // The identity, word for word as given: what a reader that picks the game up needs, and what the
        // event below carries.
        Identity storage identity = s_identities[gameId];
        identity.league = league;
        identity.homeTeam = homeTeam;
        identity.awayTeam = awayTeam;
        for (uint256 i; i < hintCount; ++i) {
            Hint storage stored = identity.hints.push();
            stored.seat = hints[i].seat;
            stored.id = hints[i].id;
        }

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

        // The fee last, after every write: the only calls out, the pull and the balance reads around it. A fee
        // of 0 calls nothing, so a coin that refuses every transfer still lets a game be made at 0.
        if (terms.fee != 0) _takeFee(terms.fee);
    }

    // ──────────────────────────── The report call ──────────────────────

    /// @inheritdoc IOspexGames
    /// @dev A refused report reverts, so it changes nothing and moves no money. A report this contract takes
    ///      emits GameReported, naming the sender as the reporter that wrote it, and changes one game, or none:
    ///      an update to a dispute record writes nothing. A score and a void also credit the game's creation fee
    ///      to the payout address in the report (FeeCredited), and call no coin. The sender's standing is checked
    ///      before the report's kind is read, so every kind is refused the same way: not the game's reporter,
    ///      retired, or code changed.
    function report(Report calldata r) external {
        Game storage g = _game(r.gameId);
        ReporterKind kind = _recordedKind(r.gameId, msg.sender);
        if (kind == ReporterKind.None) revert OspexGames__NotAReporter(r.gameId, msg.sender);
        Admission storage a = s_admissions[msg.sender];
        if (a.retired) revert OspexGames__ReporterRetired(msg.sender);
        bytes32 found = msg.sender.codehash;
        if (found != a.codeHash) revert OspexGames__CodeChanged(msg.sender, a.codeHash, found);
        _checkReadings(r.readings);

        if (r.kind == ReportKind.Start) {
            _writeStart(g, r, kind);
        } else if (r.kind == ReportKind.Score) {
            _writeScore(g, r, kind);
        } else if (r.kind == ReportKind.Void) {
            _writeVoid(g, r);
        } else if (r.kind == ReportKind.Dispute) {
            _writeDispute(g, r, kind);
        } else {
            revert OspexGames__ReportKindNotTaken(r.kind);
        }

        emit GameReported(r.gameId, msg.sender, r.kind, r.start, r.homeScore, r.awayScore, r.readings, r.payout);
    }

    // ──────────────────────────── The release ──────────────────────────

    /// @inheritdoc IOspexGames
    /// @dev The one end no reporter writes. It reads the game's own copied day-30 clock, counted from the date
    ///      given at creation, the same second from which every report is refused; failing that, it looks for
    ///      every reporter that could still write to the game retired. Then it ends the game through `_release`,
    ///      which credits the creator and never the caller. It calls no coin, so it holds no lock. The status is
    ///      checked here first so an ended game is refused by that name, and `_end` refuses it again behind this
    ///      check.
    function release(uint256 gameId) external {
        Game storage g = _game(gameId);
        GameStatus status = g.status;
        if (status >= GameStatus.Scored) revert OspexGames__GameEnded(gameId, status);
        uint256 opensAt = _day30(g);
        if (block.timestamp < opensAt && !_everyReporterRetired(g, gameId)) {
            revert OspexGames__ReleaseNotOpen(gameId, opensAt);
        }
        _release(g, gameId);
        emit GameReleased(gameId, msg.sender);
    }

    // ──────────────────────────── Withdrawal ───────────────────────────

    /// @inheritdoc IOspexGames
    /// @dev The credit is spent before the coin is called, and the payment is refused unless this contract's
    ///      balance fell by exactly the amount, so no other game's fee or other address's credit pays any of it.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = s_credits[msg.sender];
        if (amount == 0) revert OspexGames__NothingToWithdraw(msg.sender);
        s_credits[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        uint256 balanceBefore = i_token.balanceOf(address(this));
        i_token.safeTransfer(msg.sender, amount);
        uint256 balanceAfter = i_token.balanceOf(address(this));
        if (balanceAfter + amount != balanceBefore) {
            revert OspexGames__WithdrawalNotExact(amount, balanceBefore, balanceAfter);
        }
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
        return _everyReporterRetired(_game(gameId), gameId);
    }

    /// @inheritdoc IOspexGames
    function getGameDisputedAt(uint256 gameId) external view returns (uint64) {
        Game storage g = _game(gameId);
        if (g.disputedAt == 0) revert OspexGames__NotDisputed(gameId);
        return g.disputedAt;
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
    function getReporter(address reporter) external view returns (ReporterKind kind, bool retired, bytes32 codeHash) {
        Admission storage a = s_admissions[reporter];
        return (a.kind, a.retired, a.codeHash);
    }

    /// @inheritdoc IOspexGames
    function getTerms(string calldata league) external view returns (Terms memory) {
        if (bytes(league).length == 0) return s_defaultTerms;
        if (!_isLeague(league)) revert OspexGames__LeagueNotValid();
        return _termsOf(league);
    }

    /// @inheritdoc IOspexGames
    function getCredit(address account) external view returns (uint256) {
        return s_credits[account];
    }

    /// @inheritdoc IOspexGames
    /// @dev Read from the status, which holds because every end goes through `_end`, the one place that writes
    ///      an end and credits the fee together. Scored, Voided and Released, the three ends, are the last three
    ///      statuses.
    function getGameFee(uint256 gameId) external view returns (uint96 held, address creator) {
        Game storage g = _game(gameId);
        held = g.status >= GameStatus.Scored ? 0 : g.terms.fee;
        creator = g.creator;
    }

    // ──────────────────────────── The reads for picking a game up ──────

    /// @inheritdoc IOspexGames
    function getGameIdentity(uint256 gameId)
        external
        view
        returns (string memory league, string memory homeTeam, string memory awayTeam, uint64 date, Hint[] memory hints)
    {
        Game storage g = _game(gameId);
        Identity storage identity = s_identities[gameId];
        return (identity.league, identity.homeTeam, identity.awayTeam, g.date, identity.hints);
    }

    /// @inheritdoc IOspexGames
    function getGameReadings(uint256 gameId)
        external
        view
        returns (Reading[] memory startReadings, Reading[] memory votes, uint64 disputedAt)
    {
        Game storage g = _game(gameId);
        return (s_startReadings[gameId], s_votes[gameId], g.disputedAt);
    }

    /// @inheritdoc IOspexGames
    /// @dev The page is clipped before any arithmetic on `count`, so a count of type(uint256).max reads the
    ///      whole list from `offset` and overflows nothing. Each row is filled from the game's own words and its
    ///      identity, the same storage the per-game reads answer from.
    function getOpenGames(uint256 offset, uint256 count)
        external
        view
        returns (OpenGame[] memory rows, uint256 total)
    {
        total = s_open.length;
        if (offset >= total) return (rows, total);
        uint256 left = total - offset;
        uint256 length = count < left ? count : left;
        rows = new OpenGame[](length);
        for (uint256 i; i < length; ++i) {
            uint256 gameId = s_open[offset + i];
            Game storage g = s_games[gameId];
            rows[i] = OpenGame({
                gameId: gameId,
                status: g.status,
                start: g.start,
                window: g.terms.window,
                day7Clock: g.terms.day7Clock,
                disputedAt: g.disputedAt,
                league: s_identities[gameId].league
            });
        }
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev Admits a reporter to the approved list: the constructor's first reporters, and every approval. It
    ///      checks on chain what it can. The reporter has a kind, is not on the list and was never retired, and
    ///      the list has room; it has code, the code is not a wallet's delegation, and it hashes as named. Then
    ///      it writes the reporter's entry, and only then makes the fixed-values read, so the read sees the
    ///      reporter as it will stand: no answer can turn on the reporter not being approved yet. The answer
    ///      must not be empty, and is emitted as read.
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

        a.kind = kind;
        a.codeHash = codeHash;
        s_approved.push(Reporter({account: reporter, kind: kind}));

        bytes memory values = _fixedValues(reporter);
        if (values.length == 0) revert OspexGames__NoFixedValues(reporter);
        emit ReporterApproved(reporter, kind, codeHash, values);
    }

    /// @dev True when the approved list, as it stands, holds a first-n reporter: the constructor's last check,
    ///      read from the list it has just written. (A creation checks the same of the copy it makes, as it
    ///      makes it.)
    function _listHasFirstN() private view returns (bool) {
        uint256 count = s_approved.length;
        for (uint256 i; i < count; ++i) {
            if (s_approved[i].kind == ReporterKind.FirstN) return true;
        }
        return false;
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

    /// @dev Refuses a set of terms whose clocks do not run in order: n at least a second, the day-7 clock longer
    ///      than n, the day-30 clock longer than n and the day-7 clock together, and the day-30 clock at most
    ///      MAX_CLOCK. That bounds n and the day-7 clock too. Any fee is legal, 0 included.
    function _checkTerms(Terms memory terms) private pure {
        if (
            terms.window == 0 || terms.day7Clock <= terms.window
                || uint256(terms.window) + terms.day7Clock >= terms.day30Clock || terms.day30Clock > MAX_CLOCK
        ) revert OspexGames__TermsNotValid();
    }

    /// @dev The terms a game in `league` made now copies: the league's own, or the default terms.
    function _termsOf(string calldata league) private view returns (Terms memory) {
        Terms memory own = s_leagueTerms[keccak256(bytes(league))];
        return own.window != 0 ? own : s_defaultTerms;
    }

    /// @dev Writes a start. The game must have no start written yet, the sender must be a first-n reporter,
    ///      the scores and the payout must be empty (a start pays nothing), the start must be within START_BOUND
    ///      of the date given at creation, either way, and the time before the game's day-30 clock (see
    ///      _checkDay30). Writing the start moves no clock: the day-30 clock counts from the date. The start's
    ///      readings are stored as given, for whatever picks the game up; a start is written once, so they are
    ///      written once, into an empty list.
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
        _checkDay30(g, r.gameId);
        g.start = r.start;
        g.status = GameStatus.Verified;
        Reading[] storage stored = s_startReadings[r.gameId];
        uint256 count = r.readings.length;
        for (uint256 i; i < count; ++i) {
            stored.push(r.readings[i]);
        }
    }

    /// @dev Writes a score, which ends the game. The game's start must be written and no end written, a dispute
    ///      record or not; the start field must be empty, the payout address one that can withdraw (see
    ///      _checkPayout), both scores at most MAX_SCORE, the readings behind the score in the count the program
    ///      scores on at the game's clock (see _agreement and _checkScoreReadings), the time before the game's
    ///      day-30 clock (see _checkDay30), at or after the start, and, for an after-n reporter, at or after
    ///      start + n (see _checkHour). The end credits the game's fee to the payout address. A disputed game
    ///      takes a score at any hour a reporter may write: the record is a record, not a lock; its score needs
    ///      AGREE finals reading it at every clock, and takes a dissenting final only from its day-7 clock.
    function _writeScore(Game storage g, Report calldata r, ReporterKind kind) private {
        GameStatus status = g.status;
        if (status != GameStatus.Verified && status != GameStatus.Disputed) _refuseResult(r.gameId, status);
        if (r.start != 0) revert OspexGames__FieldNotEmpty(ReportKind.Score);
        _checkPayout(ReportKind.Score, r.payout);
        if (r.homeScore > MAX_SCORE || r.awayScore > MAX_SCORE) {
            revert OspexGames__ScoreOutOfRange(r.homeScore, r.awayScore);
        }
        bool disputed = status == GameStatus.Disputed;
        _checkScoreReadings(
            r, _agreement(g, disputed), disputed && block.timestamp >= uint256(g.disputedAt) + g.terms.day7Clock
        );
        _checkDay30(g, r.gameId);
        _checkHour(g, r.gameId, kind);
        g.homeScore = r.homeScore;
        g.awayScore = r.awayScore;
        _end(g, r.gameId, GameStatus.Scored, r.payout);
    }

    /// @dev Writes a void, which ends the game. The game's start must be written and no end written; the start
    ///      and both scores must be empty, since a void is a status and never a 0-0; the payout address one that
    ///      can withdraw (see _checkPayout); the readings must hold no finals that agree in the count the program
    ///      scores on at the game's clock, AGREE_AFTER_N at hour 24 and AGREE at day 7 (see _agreement and
    ///      _checkVoidReadings); the time before the game's day-30 clock (see _checkDay30), and at or after
    ///      start + n, that second included, for a reporter of either kind: the hour-24 void. On a disputed game
    ///      the time must also be at or after the dispute record plus the day-7 clock: the day-7 void, the one
    ///      end a dispute holds back. The end credits the game's fee to the payout address.
    function _writeVoid(Game storage g, Report calldata r) private {
        GameStatus status = g.status;
        if (status != GameStatus.Verified && status != GameStatus.Disputed) _refuseResult(r.gameId, status);
        if (r.start != 0 || r.homeScore != 0 || r.awayScore != 0) revert OspexGames__FieldNotEmpty(ReportKind.Void);
        _checkPayout(ReportKind.Void, r.payout);
        _checkVoidReadings(r.readings, _agreement(g, status == GameStatus.Disputed));
        _checkDay30(g, r.gameId);
        uint256 voidOpensAt = uint256(g.start) + g.terms.window;
        if (block.timestamp < voidOpensAt) revert OspexGames__InsideWindow(r.gameId, voidOpensAt);
        if (status == GameStatus.Disputed) {
            uint256 day7OpensAt = uint256(g.disputedAt) + g.terms.day7Clock;
            if (block.timestamp < day7OpensAt) revert OspexGames__InsideDay7Clock(r.gameId, day7OpensAt);
        }
        _end(g, r.gameId, GameStatus.Voided, r.payout);
    }

    /// @dev Writes a dispute record, or takes an update to one. The game's start must be written and no end
    ///      written; the start, both scores and the payout must be empty, since a dispute record credits
    ///      nothing; the time before the game's day-30 clock (see _checkDay30), at or after the start and, for an
    ///      after-n reporter, at or after start + n (see _checkHour); and the readings must not be those of a
    ///      dispute report the game already took, in the same order (DisputeReportRepeated), checked last so a
    ///      clock's refusal names first. On a game not yet disputed it writes Disputed and the time, which the
    ///      day-7 clock counts from. On a disputed game it writes no status and moves no clock: the report is
    ///      taken and emitted as an update. Either way it keeps the hash of the readings and writes each seat's
    ///      vote from them (see _writeVotes).
    function _writeDispute(Game storage g, Report calldata r, ReporterKind kind) private {
        GameStatus status = g.status;
        if (status != GameStatus.Verified && status != GameStatus.Disputed) _refuseResult(r.gameId, status);
        if (r.start != 0 || r.homeScore != 0 || r.awayScore != 0 || r.payout != address(0)) {
            revert OspexGames__FieldNotEmpty(ReportKind.Dispute);
        }
        _checkDay30(g, r.gameId);
        _checkHour(g, r.gameId, kind);
        mapping(bytes32 => bool) storage taken = s_disputeReportsTaken[r.gameId];
        bytes32 readings = keccak256(abi.encode(r.readings));
        if (taken[readings]) revert OspexGames__DisputeReportRepeated(r.gameId);
        taken[readings] = true;
        if (status == GameStatus.Verified) {
            g.status = GameStatus.Disputed;
            g.disputedAt = uint64(block.timestamp);
        }
        _writeVotes(s_votes[r.gameId], r.readings);
    }

    /// @dev Writes each seat's vote from a dispute report's readings: a reading that is not silent replaces the
    ///      seat's entry, or adds one for a seat that has not voted; a silent reading changes nothing, since a
    ///      seat that gave no answer takes nothing back. The scoring program folds a game's dispute reports the
    ///      same way, so what it reads here is what it would fold from the events.
    function _writeVotes(Reading[] storage votes, Reading[] calldata readings) private {
        uint256 count = readings.length;
        for (uint256 i; i < count; ++i) {
            Reading calldata reading = readings[i];
            if (reading.kind == ReadingKind.Silent) continue;
            uint256 have = votes.length;
            uint256 j;
            while (j < have && votes[j].seat != reading.seat) ++j;
            if (j < have) votes[j] = reading;
            else votes.push(reading);
        }
    }

    /// @dev Puts a game on the open list, at its end, and records its place in the game. Called once per game,
    ///      at its creation.
    function _joinOpen(Game storage g, uint256 gameId) private {
        s_open.push(gameId);
        // The list holds at most one entry per game not yet ended, each made for a fee, so its length is far
        // inside 32 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.openPlace = uint32(s_open.length);
    }

    /// @dev Takes a game off the open list: the last game on the list moves into its place, and the game's
    ///      place reads 0 from then on. Called once per game, by `_end`, which refuses a game already ended, so
    ///      the game is on the list when this runs.
    function _leaveOpen(Game storage g) private {
        uint256 place = g.openPlace;
        uint256 last = s_open.length;
        if (place != last) {
            uint256 moved = s_open[last - 1];
            s_open[place - 1] = moved;
            // A place read from a game's own openPlace, which _joinOpen wrote from a length inside 32 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            s_games[moved].openPlace = uint32(place);
        }
        s_open.pop();
        g.openPlace = 0;
    }

    /// @dev Refuses any report at or after the game's day-30 clock: from that second the release is the only
    ///      door, and it opens at that same second. Every report checks this after its fields and before its own
    ///      clock, so a refusal here is the one that says "release it", and a game still open then ends as a
    ///      release and nothing else.
    function _checkDay30(Game storage g, uint256 gameId) private view {
        uint256 closesAt = _day30(g);
        if (block.timestamp >= closesAt) revert OspexGames__PastDay30Clock(gameId, closesAt);
    }

    /// @dev The game's day-30 clock: the date given at creation plus the game's own copied clock. Both are
    ///      written at creation and never again, so no write moves it, a start written late or early included.
    function _day30(Game storage g) private view returns (uint256) {
        return uint256(g.date) + g.terms.day30Clock;
    }

    /// @dev Refuses a score or a dispute record before the game's start and, from an after-n reporter, before
    ///      start + n: from start + n, that second included, an after-n reporter writes. A void has its own
    ///      clock, start + n for a reporter of either kind, in _writeVoid.
    function _checkHour(Game storage g, uint256 gameId, ReporterKind kind) private view {
        uint256 start = g.start;
        if (block.timestamp < start) revert OspexGames__BeforeStart(gameId, g.start);
        uint256 opensAt = start + g.terms.window;
        if (kind == ReporterKind.AfterN && block.timestamp < opensAt) {
            revert OspexGames__InsideWindow(gameId, opensAt);
        }
    }

    /// @dev How many finals that read the same the scoring program scores on, for this game at this second:
    ///      AGREE on a disputed game at every clock and on any game inside n, AGREE_AFTER_N from start + n on a
    ///      game with no dispute record. The clock is the game's own: its start as written plus its copied n,
    ///      the second an after-n reporter writes from (see _checkHour) and the hour-24 void opens at (see
    ///      _writeVoid). A score must carry this many finals reading it, and a void may not (see
    ///      _checkScoreReadings and _checkVoidReadings).
    function _agreement(Game storage g, bool disputed) private view returns (uint256) {
        if (disputed || block.timestamp < uint256(g.start) + g.terms.window) return AGREE;
        return AGREE_AFTER_N;
    }

    /// @dev Refuses a score its own readings do not support. It counts the readings that are finals reading the
    ///      score (agreeing) and notes the first final reading otherwise (a dissent): fewer agreeing than
    ///      `needed`, the program's count at the game's clock (see _agreement), is refused, and a dissent is
    ///      refused unless `dissentAllowed`. A game with no dispute record takes no dissent, since two finals that
    ///      differ are what a dispute record is for; a disputed game takes a dissent only from its day-7 clock,
    ///      where the rule settles three of four. Nothing here re-derives the score: a report whose readings
    ///      support it may still be false, which is the scoring program's and the record's to catch.
    function _checkScoreReadings(Report calldata r, uint256 needed, bool dissentAllowed) private pure {
        Reading[] calldata readings = r.readings;
        uint256 count = readings.length;
        uint256 agreeing = 0;
        uint256 dissent = type(uint256).max;
        for (uint256 i; i < count; ++i) {
            Reading calldata reading = readings[i];
            if (reading.kind != ReadingKind.AnsweredFinal) continue;
            if (reading.homeScore == r.homeScore && reading.awayScore == r.awayScore) ++agreeing;
            else if (dissent == type(uint256).max) dissent = i;
        }
        if (agreeing < needed) revert OspexGames__TooFewFinalsAgree(agreeing, needed);
        if (dissent != type(uint256).max && !dissentAllowed) revert OspexGames__FinalDissents(dissent);
    }

    /// @dev Refuses a void whose readings hold `agreement` finals that read the same, the program's count at the
    ///      game's clock (see _agreement), at hour 24 and at day 7 alike: that is a score's agreement, and the
    ///      void contradicts its own readings. The rule scores on that many agreeing votes at every clock, two
    ///      after n and three on a disputed game, so no void it sends carries that many finals alike; a day-7
    ///      void carries at most two. Fewer finals that agree are not agreement (one final beside silents is
    ///      still an hour-24 void's shape here), and finals that differ are a dispute's shape, which the void
    ///      does not refuse.
    function _checkVoidReadings(Reading[] calldata readings, uint256 agreement) private pure {
        uint256 count = readings.length;
        for (uint256 i; i < count; ++i) {
            Reading calldata a = readings[i];
            if (a.kind != ReadingKind.AnsweredFinal) continue;
            uint256 alike = 1;
            for (uint256 j = i + 1; j < count; ++j) {
                Reading calldata b = readings[j];
                if (b.kind == ReadingKind.AnsweredFinal && b.homeScore == a.homeScore && b.awayScore == a.awayScore) {
                    ++alike;
                }
            }
            if (alike >= agreement) revert OspexGames__FinalsAgree(a.homeScore, a.awayScore);
        }
    }

    /// @dev Refuses as payout address: address 0 and the rest of the reserved range up to MAX_RESERVED_ADDRESS,
    ///      this contract and the coin, none of which calls withdraw (this contract never calls its own); and any
    ///      address ever approved as a reporter, retired ones included and the sender among them, since a
    ///      reporter relays a report and is never the one it pays. An admission's kind is never None once
    ///      approved, and a retirement keeps it, so one read covers every reporter ever approved. A score and a
    ///      void, the two reports that end a game, check their payout here; a release names none.
    function _checkPayout(ReportKind kind, address payout) private view {
        if (payout == address(0)) revert OspexGames__NoPayout(kind);
        if (uint160(payout) <= uint160(MAX_RESERVED_ADDRESS)) revert OspexGames__PayoutIsReserved(kind, payout);
        if (payout == address(this)) revert OspexGames__PayoutIsTheGamesSet(kind);
        if (payout == address(i_token)) revert OspexGames__PayoutIsTheCoin(kind);
        if (s_admissions[payout].kind != ReporterKind.None) revert OspexGames__PayoutIsAReporter(kind, payout);
    }

    /// @dev Takes a creation's fee from its creator, through SafeERC20, and refuses the creation unless this
    ///      contract's coin balance rose by exactly the fee: a coin that keeps a cut of a transfer, or adds to
    ///      one, makes no game, so a game holds what arrived. The balance is read on each side of the pull, so
    ///      coin sent here directly before or after the creation does not count, and no other creation or
    ///      withdrawal can run between the two reads (both are nonReentrant). Called only for a fee above 0,
    ///      after every other write of the creation.
    function _takeFee(uint256 fee) private {
        uint256 balanceBefore = i_token.balanceOf(address(this));
        i_token.safeTransferFrom(msg.sender, address(this), fee);
        uint256 balanceAfter = i_token.balanceOf(address(this));
        if (balanceAfter != balanceBefore + fee) revert OspexGames__FeeNotReceived(fee, balanceBefore, balanceAfter);
    }

    /// @dev Ends a game and credits its creation fee, in one place, so that every end credits and nothing but
    ///      an end does. It refuses a status that is not an end, an id that is not a game and a game already
    ///      ended, whatever its caller has checked, so a game's fee is credited at most once and only with an
    ///      end. (Scored, Voided and Released, the three ends, are the last three statuses.) The amount is the
    ///      fee the game copied at its creation, whatever its league's fee is now; a fee of 0 credits nothing.
    ///      No coin moves here: the address credited withdraws later. Internal, not private, so a test can reach
    ///      the gate itself; nothing outside this contract calls it.
    function _end(Game storage g, uint256 gameId, GameStatus end, address account) internal {
        if (end < GameStatus.Scored) revert OspexGames__NotAnEnd(end);
        GameStatus status = g.status;
        if (status == GameStatus.None) revert OspexGames__UnknownGame(gameId);
        if (status >= GameStatus.Scored) revert OspexGames__GameEnded(gameId, status);
        g.status = end;
        _leaveOpen(g);
        uint96 fee = g.terms.fee;
        if (fee != 0) {
            s_credits[account] += fee;
            emit FeeCredited(gameId, account, fee);
        }
    }

    /// @dev Releases a game: ends it as Released and credits its creation fee back to its creator, never to the
    ///      caller. `release` decides who may release a game and when, and calls this; `_end` refuses a game
    ///      already ended behind it.
    function _release(Game storage g, uint256 gameId) internal {
        _end(g, gameId, GameStatus.Released, g.creator);
    }

    /// @dev True when every one of the game's recorded reporters that could still write to it is retired, so
    ///      nothing can write to the game again and its release is open at once. For a game whose start is not
    ///      written that is every first-n reporter: an after-n reporter writes no start and nothing before one,
    ///      so it holds nothing open. For a game with a start, every reporter. Read live, since a retirement is
    ///      meant to reach games already made.
    function _everyReporterRetired(Game storage g, uint256 gameId) private view returns (bool) {
        bool unstarted = g.start == 0;
        Reporter[] storage list = s_gameReporters[gameId];
        uint256 count = list.length;
        for (uint256 i; i < count; ++i) {
            Reporter storage r = list[i];
            if (unstarted && r.kind == ReporterKind.AfterN) continue;
            if (!s_admissions[r.account].retired) return false;
        }
        return true;
    }

    /// @dev Names why a start is refused, from a status other than Unverified. Always reverts.
    function _refuseStart(uint256 gameId, GameStatus status) private pure {
        if (status == GameStatus.Verified || status == GameStatus.Disputed) {
            revert OspexGames__StartAlreadyWritten(gameId);
        }
        revert OspexGames__GameEnded(gameId, status);
    }

    /// @dev Names why a score, a void or a dispute record is refused, from a status other than Verified or
    ///      Disputed: the start is not written, or the game has ended. Always reverts.
    function _refuseResult(uint256 gameId, GameStatus status) private pure {
        if (status == GameStatus.Unverified) revert OspexGames__StartNotWritten(gameId);
        revert OspexGames__GameEnded(gameId, status);
    }

    /// @dev Refuses, in a report of any kind, a reading marked silent that carries a score, and two readings that
    ///      name one seat. A score's and a void's readings are read against the result they carry in
    ///      _checkScoreReadings and _checkVoidReadings; nothing else in a reading is checked, and all are emitted
    ///      as the feeds gave them, not stored.
    function _checkReadings(Reading[] calldata readings) private pure {
        uint256 count = readings.length;
        uint256 seats = 0;
        for (uint256 i; i < count; ++i) {
            Reading calldata reading = readings[i];
            if (reading.kind == ReadingKind.Silent && (reading.homeScore != 0 || reading.awayScore != 0)) {
                revert OspexGames__SilentReadingNotEmpty(i);
            }
            uint256 seat = uint256(1) << reading.seat;
            if (seats & seat != 0) revert OspexGames__ReadingSeatRepeated(i);
            seats |= seat;
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
