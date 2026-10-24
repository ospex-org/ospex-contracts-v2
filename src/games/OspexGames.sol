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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
 *         fee in the league's terms, copied into the game with them. At a fee of 0 nothing is taken. The game
 *         holds that amount until it ends. The report that ends it credits the amount to the payout address
 *         inside the report, and the sender never takes that address's place; a release credits it back to the
 *         creator. Each end credits once, through one internal call that writes the end and the credit together
 *         and refuses a game already ended. The amount is booked as the fee, not measured as received: right for
 *         USDC, which takes no fee on a transfer, and wrong for a coin that does. No coin moves inside an end:
 *         the address credited withdraws later, so a coin that refuses a transfer stops a withdrawal and never
 *         an end. The coin is held for games not yet ended and for credits not yet withdrawn; there is no
 *         receiver, no setter for one, and no other way out. Coin sent here directly is held by no one and
 *         stays. Spec: "The creation fee".
 *
 *         Two things a reader may look for here belong to other parts of the games set, by design:
 *         - How a game ends other than by a score. The hour-24 void, the dispute record and day 7, and the
 *           day-30 release that gives every stake back are the ends, and a game whose every reporter is retired
 *           can be released at once. This contract copies each game's clocks and says when every reporter of a
 *           game is retired; it writes no end but a score. The credit each end makes is here already: an end
 *           that names a payout checks it as a score does and credits through `_end`, and a release credits
 *           the creator through `_release`. Spec: "How a game ends".
 *         - Correcting a start or a score. There is none: each is written once. Feeds that disagree lead to a
 *           dispute record, never to a correction. Spec: "The start is written once" and "A score is written
 *           once and is final".
 *         The games set deploys once, with all of them. Spec: "Launch: one reporter, and the hooks".
 *
 *         It has no owner, no pause, no setter but the timelock's three calls, and no way to correct a start or
 *         a score. It refuses no league.
 *
 * @dev    What the report call reads, by whether it can change between a game's creation and its score. Each
 *         thing that could change and must not is either never written again or compared with what was
 *         recorded:
 *         - Pinned when written, and never written again: the game's reporters and their kinds, its four terms
 *           and its date, from its creation; among the terms its creation fee, which is the amount the game
 *           holds and its end credits, whatever the league's fee is now; its start, once written; and this
 *           contract's own limits and coin, which are constants. A release reads one thing more, also pinned
 *           at creation: the creator it credits.
 *         - Checked at the door against a stored value: the sender's code. Its live hash must equal the hash
 *           recorded at its approval, or the report is refused (CodeChanged).
 *         - Live by design: the sender's retired flag, because a retirement is meant to reach games already
 *           made; the clock, because when a report may land is what the gate decides; the game's status,
 *           because it is what the reports themselves write, each step once, and whether the game still holds
 *           its fee is read from it; and the payout address's credit, which an end adds to and only that
 *           address's withdrawal takes from.
 *         - Not read, so not checked here: what a reporter's own storage holds, such as a proxy's logic or an
 *           owner's setting. A reporter whose behaviour can change while its code stays the same keeps its
 *           hash; the public delay before its approval is for finding that. Values a reporter holds as
 *           immutables are written into its code, so its hash covers them. Nor the coin: no end calls it, so
 *           whether the coin would take or refuse a transfer has no say in an end.
 *
 *         n counts from the start as written. A first-n reporter writes from the start; an after-n reporter
 *         writes from start + n, that second included, so n's window is [start, start + n), the window the
 *         scoring program uses. A start written at or after start + n opens the after-n score at once.
 *
 *         A tradeoff kept: if every first-n reporter a game recorded is retired before its start is written,
 *         nothing can write that start. An after-n reporter writes no start, and a reporter approved later is
 *         not on the game's copy. While an after-n reporter on the copy is not retired, the game is not one
 *         whose every reporter is retired, so it waits for the day-30 release, counted from its date. The
 *         release is the recovery.
 *
 *         A score refuses three payout addresses: address 0 and this contract, which can never withdraw, and the
 *         reporter sending the report, since the payout is never the sender. It refuses no other, though the
 *         chain could name more that cannot call `withdraw`, such as the coin's own address or the game's other
 *         reporters. That a payout address can call `withdraw` is for review: a contract named as payout, or a
 *         contract that creates games, with no way to call it leaves its credit here for good.
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
 */
contract OspexGames is IOspexGames {
    using SafeERC20 for IERC20;

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

    // ──────────────────────────── Types ────────────────────────────────

    /// @dev A game as stored. Its identity (league, teams, hints) is in the creation event only. Its creator is
    ///      in the event and stored too, because a release credits the creator.
    /// @param status Where the game stands
    /// @param date The scheduled start the creator gave
    /// @param start The start, once written. A written start is never 0 and is within START_BOUND of the date.
    /// @param homeScore The home team's score, once written
    /// @param awayScore The away team's score, once written
    /// @param terms The four terms, copied from the game's league at creation. Their fee is the amount the game
    ///        holds until it ends.
    /// @param creator The address that created the game and paid its fee: what a release credits
    struct Game {
        GameStatus status;
        uint64 date;
        uint64 start;
        uint32 homeScore;
        uint32 awayScore;
        Terms terms;
        address creator;
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
    /// @notice Thrown for a report kind this contract does not take: no kind, a void or a dispute record
    error OspexGames__ReportKindNotTaken(ReportKind kind);
    /// @notice Thrown when a report sets a field its kind does not use: a score or a payout on a start, a start
    ///         on a score
    error OspexGames__FieldNotEmpty(ReportKind kind);
    /// @notice Thrown when a report that ends a game names no payout address: address 0 can never withdraw
    error OspexGames__NoPayout(ReportKind kind);
    /// @notice Thrown when a report that ends a game names this contract as its payout address: this contract
    ///         never calls its own withdraw, so a credit to it could never be withdrawn
    error OspexGames__PayoutIsTheGamesSet(ReportKind kind);
    /// @notice Thrown when a report that ends a game names the reporter sending it as its payout address: the
    ///         payout rides inside the report and is never the sender
    error OspexGames__PayoutIsTheReporter(ReportKind kind, address reporter);
    /// @notice Thrown when an address with no credit withdraws
    error OspexGames__NothingToWithdraw(address account);
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
        g.creator = msg.sender;

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

        // The fee last, after every write: the one call out. A fee of 0 calls nothing, so a coin that refuses
        // every transfer still lets a game be made at 0.
        if (terms.fee != 0) i_token.safeTransferFrom(msg.sender, address(this), terms.fee);
    }

    // ──────────────────────────── The report call ──────────────────────

    /// @inheritdoc IOspexGames
    /// @dev A refused report reverts, so it changes nothing and moves no money. A report this contract takes
    ///      changes one game and emits GameReported, naming the sender as the reporter that wrote it; a score
    ///      also credits the game's creation fee to the payout address in the report (FeeCredited), and calls
    ///      no coin. The sender's standing is checked before the report's kind is read, so every kind, those
    ///      the ends add included, is refused the same way: not the game's reporter, retired, or code changed.
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
        } else {
            revert OspexGames__ReportKindNotTaken(r.kind);
        }

        emit GameReported(r.gameId, msg.sender, r.kind, r.start, r.homeScore, r.awayScore, r.readings, r.payout);
    }

    // ──────────────────────────── Withdrawal ───────────────────────────

    /// @inheritdoc IOspexGames
    function withdraw() external returns (uint256 amount) {
        amount = s_credits[msg.sender];
        if (amount == 0) revert OspexGames__NothingToWithdraw(msg.sender);
        s_credits[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        i_token.safeTransfer(msg.sender, amount);
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

    /// @dev Writes a score, which ends the game. The game's start must be written and no end written, the start
    ///      field must be empty, the payout address one that can withdraw (see _checkPayout), both scores at
    ///      most MAX_SCORE, the time at or after the start, and, for an after-n reporter, at or after start + n:
    ///      from start + n, that second included. The end credits the game's fee to the payout address.
    function _writeScore(Game storage g, Report calldata r, ReporterKind kind) private {
        GameStatus status = g.status;
        if (status != GameStatus.Verified) _refuseScore(r.gameId, status);
        if (r.start != 0) revert OspexGames__FieldNotEmpty(ReportKind.Score);
        _checkPayout(ReportKind.Score, r.payout);
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
        _end(g, r.gameId, GameStatus.Scored, r.payout);
    }

    /// @dev Refuses three payout addresses: address 0 and this contract, which can never withdraw (this contract
    ///      never calls its own withdraw), and the reporter sending the report, since the payout rides inside the
    ///      report and is never the sender. A score checks its payout here, and so is meant to every other report
    ///      that ends a game.
    function _checkPayout(ReportKind kind, address payout) private view {
        if (payout == address(0)) revert OspexGames__NoPayout(kind);
        if (payout == address(this)) revert OspexGames__PayoutIsTheGamesSet(kind);
        if (payout == msg.sender) revert OspexGames__PayoutIsTheReporter(kind, payout);
    }

    /// @dev Ends a game and credits its creation fee, in one place, so that every end credits and nothing but
    ///      an end does. It refuses an id that is not a game and a game already ended, whatever its caller has
    ///      checked, so a game's fee is credited at most once. (Scored, Voided and Released, the three ends, are
    ///      the last three statuses.) The amount is the fee the game copied at its creation, whatever its
    ///      league's fee is now; a fee of 0 credits nothing. No coin moves here: the address credited withdraws
    ///      later.
    function _end(Game storage g, uint256 gameId, GameStatus end, address account) private {
        GameStatus status = g.status;
        if (status == GameStatus.None) revert OspexGames__UnknownGame(gameId);
        if (status >= GameStatus.Scored) revert OspexGames__GameEnded(gameId, status);
        g.status = end;
        uint96 fee = g.terms.fee;
        if (fee != 0) {
            s_credits[account] += fee;
            emit FeeCredited(gameId, account, fee);
        }
    }

    /// @dev Releases a game: ends it as Released and credits its creation fee back to its creator, never to the
    ///      caller. The release call itself, which decides who may release a game and when, is not built yet; it
    ///      will call this, and `_end` refuses a game already ended.
    function _release(Game storage g, uint256 gameId) internal {
        _end(g, gameId, GameStatus.Released, g.creator);
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
    ///      reading is checked: the readings are emitted as the feeds gave them, not stored.
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
