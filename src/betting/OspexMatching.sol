// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IOspexModule} from "./IOspexModule.sol";
import {IOspexPositions} from "./IOspexPositions.sol";
import {OspexBetting} from "./OspexBetting.sol";
import {Side} from "./OspexBettingTypes.sol";

/// @dev The one read the matching module makes of the games set, in its constructor: the timelock the games set
///      answers to, a public immutable of OspexGames that IOspexGames does not declare.
interface IOspexGamesTimelock {
    function i_timelock() external view returns (address);
}

/**
 * @title OspexMatching
 * @author ospex.org
 * @notice The matching module of the betting set: the signed order and its hash, the Cross that fills orders,
 *         the approved agent and its grant, the three cancels, and each account's couriers.
 *
 *         The signed order. An account signs OspexOrder, ten fields, under the EIP-712 domain "Ospex",
 *         version "3", this chain and this contract. Nothing in an order says which role it plays: the same
 *         signed order rests or takes. Its first field, account, is the account whose money backs it; its last,
 *         minFill, is the least it fills for in one Cross. Its nonce holds three numbers, high to low: the
 *         account's version (128 bits), the number of the grant it was signed under (32 bits; 0 when the
 *         account signed it itself) and an order number (96 bits). Spec: "How a bet happens", "The nonce,
 *         split", and items 3, 8, 9, 10, 13, 20 and 23 of its first milestone.
 *
 *         How an order is signed. Order-signature authorization recovers the existing 65-byte
 *         EIP-712/secp256k1 signature and compares it with the resolved signer without inspecting that
 *         signer's code or consulting any wallet verifier: the signer is the account when the nonce's grant
 *         number is 0, and the agent of the grant that number names otherwise. A code-bearing key, including
 *         an EIP-7702 key, keeps this signing route. A keyless contract account, one that cannot produce the
 *         accepted signature from its own address, trades only through a suitable current numbered grant.
 *         This rule does not remove the Cross's existing token, positions, market or hub calls, or
 *         token-triggered callbacks. A signature that does not recover to the resolved signer fails the whole
 *         Cross, in either role. Spec: item 23 of its first milestone, which supersedes L77 and item 15's
 *         "Signatures".
 *
 *         The approved agent. An account grants one agent from its own address: an address that may sign
 *         orders and send cancels for the account, the most one order it signs may stake, the second at which
 *         the grant ends and, optionally, a list of lines, each a game, a market contract and a line, an empty
 *         list passing every market. Each grant has a number, one more than the account's count, starting at
 *         1 and never reused; its record is written once and never edited, so an order's limits are fixed by
 *         the number it names. An account has one current grant: a new grant replaces it, and a revoke ends
 *         it. An order signed under a grant that is not the account's current one, or that has ended, is dead,
 *         before or after a regrant; the account's own orders, grant 0, are untouched by a revoke. The agent
 *         is nothing to the positions module: a pay-back and a claim pay the account, and no call here moves
 *         coin. Spec: "The approved agent", and item 23.
 *
 *         Couriers. A courier is an address an account names to send the fills of its orders. An account
 *         registers one, and drops one, with a call from its own address: the account is the caller, and
 *         neither call takes an account, a signature or a grant, so only an account writes its own couriers.
 *         An account may hold several. There is no default: an account that registered none has none, this
 *         contract has no owner, and registerCourier, unregisterCourier and grantAgentAndRegisterCourier, which
 *         registers for its caller as registerCourier does, are its only functions that write a courier. An
 *         agent, under any grant, registers no courier for the account. Spec: "How a bet happens", and items
 *         1, 5 and 6 of its first milestone.
 *
 *         The Cross. cross(taking, resting) is the one path a fill arrives by, and the only function here
 *         that calls the positions module. Its sender, the immediate caller, lists one taking order and the
 *         resting orders it is to fill against, in order, each with its signature, and decides nothing else:
 *         no price, size, market, deadline or recipient is an argument. An order never fills through a courier
 *         its account has not registered: the taking account must have registered the sender, or the call
 *         reverts; a resting order whose account has not is skipped. Each leg fills at the resting order's
 *         price, in lots of 100 units of resting stake, and a resting order that cannot fill is skipped, for
 *         one of eight reasons, while the rest fill. A Cross that fills nothing reverts, and so does one that
 *         leaves its taking order short of its minimum fill. Spec: "How a bet happens", and items 4, 11, 12,
 *         14, 15, 20 and 23 of its first milestone.
 *
 *         One Cross at a time. While a Cross is in progress this contract refuses another Cross, the three
 *         cancels, a grant, a revoke, a registration, a drop and the cap's lift, each by the same name. So from
 *         the first check of a Cross to its end nothing but that Cross changes a cancel mark, a floor, a
 *         version, a grant, a courier, a filled amount or the cap's flag. The reads are not held: one made
 *         from inside a Cross, by a contract the coin calls during a pull, shows the legs done so far and the
 *         leg in progress, which is taken back if that leg is skipped. Such a read is not a finished Cross.
 *
 *         Who calls it, and what it calls. Anyone calls anything here; what a call may do is decided by who the
 *         caller is to the accounts it names. It calls the positions module's recordFill, once per attempted
 *         leg, and its finishFills, once after the walk of a Cross that filled, with the taking account and the
 *         resting accounts of the filled legs; and the core, for the positions module's address and its event
 *         hub. It holds no coin and is approved for none: the positions module pulls the stakes, netted per
 *         account per market, and pays back what a fill leaves held above an account's worst loss.
 *
 *         The cancels. Three calls, each naming the account, each sent by the account or by its live agent
 *         and refused by name from anyone else, each keyed to the account named and never to the caller. The
 *         per-order cancel, cancelOrder, marks the hash of an order at the account's current version. The
 *         per-line floor, raiseFloor, cancels every order number under it on one line at the account's
 *         current version; it may reach the top order number, so that number is always signable. The
 *         account-wide cancel, cancelAll, takes no number: it moves the account to the old version plus one
 *         plus the first 64 bits of the previous block's hash, in checked arithmetic that refuses by name a
 *         step past the top, so every order naming the old version is dead, whoever signed it, and the new
 *         version's floors are zero. Revoke ends that grant's remaining authority. Cancel-all invalidates
 *         orders outside the resulting current version; an order signed beforehand for the resulting version
 *         may still fill while every other condition holds. Each cancelling event names the account and the
 *         address whose authority the contract checked for that call, the immediate caller, an address and
 *         never a role. Spec: "Cancelling", "The nonce, split", and item 23.
 *
 *         The cap and its switch. Until the switch, a taking order's signed stake is at most TAKING_STAKE_CAP,
 *         one cent: a taking order signed for more is refused by name before anything moves, whatever it has
 *         filled so far and on either side. Resting stakes are not capped: what the other side puts up follows
 *         from the odds. The switch is liftTakingStakeCap, which only the Polygon timelock may call, once, and
 *         which nothing reverses. The timelock's address is read once, from the games set the core names, when
 *         this contract is deployed, and kept as i_timelock. Spec: the alpha's one-cent cap, the Polygon
 *         timelock's calls, and item 16 of its first milestone.
 *
 *         The minimum fill. An order's tenth field, minFill, is the least it fills for in one Cross, in the
 *         coin's smallest unit and in the order's own stake, unless the fill completes it: an order is complete
 *         when less than one lot of its stake is left, which nothing can ever fill. Zero, the default, asks for
 *         nothing. A minimum above the signed stake is refused by name wherever the signature is checked, in
 *         either role, before anything moves. A taking order that this Cross fills for less than its minimum,
 *         with a lot or more left, reverts the whole Cross by name, the refusal carrying the fate of every
 *         listed order; a resting order a leg would fill for less than its minimum, leaving a lot or more, is
 *         skipped, the seventh reason, tested after nothing-fits and before the pull. Spec: item 20 of its
 *         first milestone.
 */
contract OspexMatching is IOspexModule, EIP712 {
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    // ──────────────────────────── Constants ────────────────────────────

    // The module types. This contract looks up the positions module, in cross; the markets module's type is
    // declared and read by no function here.
    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant MARKET_MODULE = keccak256("MARKET_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");

    // The core event types this module emits through the core's hub. Each payload is the typed event's
    // parameters in the typed event's order.
    bytes32 public constant EVENT_ORDER_CANCELLED = keccak256("ORDER_CANCELLED");
    bytes32 public constant EVENT_FLOOR_RAISED = keccak256("FLOOR_RAISED");
    bytes32 public constant EVENT_VERSION_CHANGED = keccak256("VERSION_CHANGED");
    bytes32 public constant EVENT_COURIER_REGISTERED = keccak256("COURIER_REGISTERED");
    bytes32 public constant EVENT_COURIER_UNREGISTERED = keccak256("COURIER_UNREGISTERED");
    bytes32 public constant EVENT_ORDER_MATCHED = keccak256("ORDER_MATCHED");
    bytes32 public constant EVENT_ORDER_SKIPPED = keccak256("ORDER_SKIPPED");
    bytes32 public constant EVENT_CROSSED = keccak256("CROSSED");
    bytes32 public constant EVENT_TAKING_STAKE_CAP_LIFTED = keccak256("TAKING_STAKE_CAP_LIFTED");

    /// @notice EIP-712 typehash for the OspexOrder struct: the ten fields, the first named `account`, the last
    ///         `minFill`
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "OspexOrder(" "address account," "uint256 gameId," "address scorer," "int32 lineTicks," "uint8 positionType,"
        "uint16 oddsTick," "uint256 riskAmount," "uint256 nonce," "uint256 expiry," "uint256 minFill" ")"
    );

    /// @notice Odds scale factor (1.91 odds = 191 ticks). The scale is stated in OspexBettingTypes.sol.
    uint16 public constant ODDS_SCALE = 100;
    /// @notice Minimum valid odds (1.01)
    uint16 public constant MIN_ODDS = 101;
    /// @notice Maximum valid odds (101.00)
    uint16 public constant MAX_ODDS = 10100;
    /// @notice Absolute magnitude bound on an order's lineTicks (10x-scaled): 1,000,000, as on the markets
    ///         module, which is where a line is checked, when its market is drawn
    int32 public constant MAX_LINE_TICKS = 1_000_000;
    /// @notice The lot: 100 units of resting stake, $0.0001 in a coin of six decimals. A signed stake is a
    ///         whole number of lots, a leg's resting stake is a whole number of lots, and neither stake of a
    ///         leg is under one lot's worth of units.
    uint256 public constant LOT = 100;
    /// @notice The most seconds a taking order may have left to its expiry when its Cross runs
    uint256 public constant MAX_TAKING_LIFE = 30;
    /// @notice The most a taking order may sign until the switch: one cent, 10,000 units of a coin of six
    ///         decimals, 100 lots. A taking order signed for more is refused by name while
    ///         s_takingStakeCapLifted is false. Resting stakes are not capped.
    uint256 public constant TAKING_STAKE_CAP = 10_000;
    /// @notice Where the nonce's three numbers sit: the version is the nonce shifted right by VERSION_SHIFT, the
    ///         grant number the 32 bits above GRANT_SHIFT, and the order number the low 96 bits
    uint256 public constant VERSION_SHIFT = 128;
    uint256 public constant GRANT_SHIFT = 96;
    /// @notice The top order number, 2^96 - 1: the largest floor a line can take, and so always signable
    uint96 public constant MAX_ORDER_NUMBER = type(uint96).max;

    /// @dev The first four bytes of a word: where revert data carries its error's selector.
    bytes32 private constant SELECTOR_MASK = bytes32(bytes4(0xffffffff));
    /// @dev Where the Cross-in-progress mark is kept, in transient storage: set by cross for the length of the
    ///      call, read by the nine other state-changing functions, and gone at the transaction's end.
    bytes32 private constant CROSS_IN_PROGRESS_SLOT = keccak256("ospex.matching.cross-in-progress");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown by the three cancels when the caller is neither the account named nor its live agent
    error OspexMatching__NotAccountOrAgent(address account, address caller);
    /// @notice Thrown by cancelOrder when the order's version is not its account's current version: a mark
    ///         reaches one version, the current one
    error OspexMatching__OrderNotAtCurrentVersion(bytes32 orderHash, uint128 orderVersion, uint128 currentVersion);
    /// @notice Thrown by raiseFloor when the floor asked is not above the line's current floor
    error OspexMatching__FloorMustRise(uint96 current, uint96 asked);
    /// @notice Thrown by cancelAll when the next version would pass the top of the field: nothing is written
    error OspexMatching__VersionAtTop(address account, uint128 current);
    /// @notice Thrown when the core address is zero
    error OspexMatching__InvalidAddress();
    /// @notice Thrown when the address to register as a courier is zero
    error OspexMatching__ZeroCourier();
    /// @notice Thrown when an account drops a courier it does not have
    error OspexMatching__CourierNotRegistered(address account, address courier);
    /// @notice Thrown by the constructor when the games set the core names has no code, or has only a wallet's
    ///         delegation
    error OspexMatching__GamesNotAContract(address games);
    /// @notice Thrown by the constructor when the games set the core names answers no timelock
    error OspexMatching__GamesHasNoTimelock(address games);
    /// @notice Thrown by liftTakingStakeCap when the caller is not the timelock
    error OspexMatching__NotTheTimelock(address caller);
    /// @notice Thrown by liftTakingStakeCap when the cap has been lifted already
    error OspexMatching__CapAlreadyLifted();

    /// @notice Thrown by cross, cancelOrder, raiseFloor, cancelAll,
    ///         grantAgentAndRegisterCourier, registerCourier, unregisterCourier and liftTakingStakeCap while a
    ///         Cross is in progress
    error OspexMatching__CrossInProgress();
    /// @notice Thrown by cross when the taking order's account has not registered the sender as a courier
    error OspexMatching__SenderNotCourier(address account, address sender);
    /// @notice Thrown by cross when an order's signature is not its resolved signer's, the account's for grant 0
    ///         and the grant's agent's otherwise: the wrong key, the wrong type or domain, a changed field, a
    ///         length other than 65 bytes, or a signature the recovery refuses
    error OspexMatching__BadSignature(bytes32 orderHash);
    /// @notice Thrown by cross when an order's price is outside MIN_ODDS to MAX_ODDS, in either role
    error OspexMatching__PriceOutOfRange(bytes32 orderHash);
    /// @notice Thrown by cross when an order's signed stake is zero or not a whole number of lots, in either role
    error OspexMatching__StakeNotInLots(bytes32 orderHash);
    /// @notice Thrown by cross when an order's minimum fill is above its signed stake, in either role: no fill
    ///         could ever meet it. Carries the two numbers.
    error OspexMatching__MinFillAboveStake(bytes32 orderHash, uint256 minFill, uint256 riskAmount);
    /// @notice Thrown by cross when the taking order's signed stake is above TAKING_STAKE_CAP and the cap has
    ///         not been lifted
    error OspexMatching__TakingStakeAboveCap(bytes32 orderHash);
    /// @notice Thrown by cross when the taking order is cancelled: its hash is marked, its version is not its
    ///         account's current version, or its order number is under its account's floor for the line
    error OspexMatching__TakingOrderCancelled(bytes32 orderHash);
    /// @notice Thrown by cross when the taking order has expired: the block's time is at or past its expiry
    error OspexMatching__TakingOrderExpired(bytes32 orderHash);
    /// @notice Thrown by cross when the taking order has more than MAX_TAKING_LIFE seconds left to its expiry
    error OspexMatching__TakingOrderTooLong(bytes32 orderHash);
    /// @notice Thrown by cross when the taking order has no room left: it has filled its signed stake
    error OspexMatching__TakingOrderFilled(bytes32 orderHash);
    /// @notice Thrown by cross when a resting order names another game than the taking order's
    error OspexMatching__OtherGame(bytes32 orderHash);
    /// @notice Thrown by cross when a resting order names another market contract than the taking order's
    error OspexMatching__OtherScorer(bytes32 orderHash);
    /// @notice Thrown by cross when a resting order names another line than the taking order's
    error OspexMatching__OtherLine(bytes32 orderHash);
    /// @notice Thrown by cross when a resting order is on the taking order's side
    error OspexMatching__SameSide(bytes32 orderHash);
    /// @notice Thrown by cross when a resting order's price does not meet the taking order's:
    ///         (resting tick - 100) x (taking tick - 100) is above 10,000
    error OspexMatching__PricesDoNotMeet(bytes32 orderHash);
    /// @notice Thrown by cross when no leg filled: an empty list, or every listed order skipped. It carries
    ///         each listed order's reason, in list order, since the skip records of a reverted call do not exist.
    error OspexMatching__NothingFilled(SkipReason[] reasons);
    /// @notice Thrown by cross when at least one leg filled and the taking order is left short: this Cross filled
    ///         it for less than its minimum fill and a lot or more of its room is left. Nothing of the Cross
    ///         remains. It carries the taking order's hash, what this Cross filled of it, its minimum, the room it
    ///         has left, and one record per listed order: filled with both stakes, or skipped with its reason and
    ///         zero stakes.
    error OspexMatching__TakingOrderUnderMinFill(
        bytes32 takingHash, uint256 filledThisCross, uint256 minFill, uint256 roomLeft, LegReport[] legs
    );

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when an order is cancelled, by its account or by its account's live agent. Its fields are
    ///         the order's, in the order's order, the minimum fill after them, and last the sender: the
    ///         immediate caller, whose authority the contract checked for this call, an address and never a
    ///         role. The account is the order's account, which may not be the sender.
    event OrderCancelled(
        bytes32 indexed orderHash,
        address indexed account,
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        Side positionType,
        uint16 oddsTick,
        uint256 riskAmount,
        uint256 nonce,
        uint256 expiry,
        uint256 minFill,
        address sender
    );

    /// @notice Emitted when a floor is raised, by the account or by its live agent, for one line at the
    ///         account's current version. lineKey is the key the floor is stored under beside the account and
    ///         the version: keccak256(abi.encode(gameId, scorer, lineTicks)). The sender is the immediate
    ///         caller, whose authority the contract checked for this call.
    event FloorRaised(
        address indexed account,
        uint128 version,
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        uint96 floor,
        bytes32 indexed lineKey,
        address sender
    );

    /// @notice Emitted when an account's version changes, by its own cancelAll or its live agent's. The sender
    ///         is the immediate caller, whose authority the contract checked for this call.
    event VersionChanged(address indexed account, uint128 previous, uint128 next, address sender);

    /// @notice Emitted when an account registers a courier. The account is the caller.
    event CourierRegistered(address indexed account, address indexed courier);

    /// @notice Emitted when an account drops a courier. The account is the caller.
    event CourierUnregistered(address indexed account, address indexed courier);

    /// @notice Emitted once, when the timelock lifts the cap on a taking order's signed stake. From then on only
    ///         the signed stake bounds a fill.
    event TakingStakeCapLifted();

    /// @notice Emitted once for each leg of a Cross that fills, after the positions module's PositionFilled.
    /// @param orderHash The resting order's hash
    /// @param maker The resting order's account
    /// @param taker The taking order's account, never the address that sent the Cross
    /// @param gameId The game
    /// @param marketId The market the leg filled into
    /// @param scorer The market contract
    /// @param lineTicks The line, scaled by 10
    /// @param makerPositionType The resting order's side; the taking account took the other
    /// @param oddsTick The resting order's price, which is the price the leg filled at
    /// @param makerRisk The resting stake of this leg: what the resting account risks
    /// @param takerRisk The taking stake of this leg: what the taking account risks
    /// @param orderRiskAmount The resting order's signed stake
    /// @param nonce The resting order's nonce
    /// @param expiry The resting order's expiry
    /// @param orderMinFill The resting order's minimum fill, never the taking order's
    event OrderMatched(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 gameId,
        uint256 marketId,
        address scorer,
        int32 lineTicks,
        Side makerPositionType,
        uint16 oddsTick,
        uint256 makerRisk,
        uint256 takerRisk,
        uint256 orderRiskAmount,
        uint256 nonce,
        uint256 expiry,
        uint256 orderMinFill
    );

    /// @notice Emitted once for each resting order a Cross skips, with the one reason it was skipped for. It
    ///         exists only for a Cross in which at least one leg filled: a Cross that fills nothing reverts,
    ///         its records with it, and carries the reasons in its refusal instead. A record says what this
    ///         Cross found for this sender, and nothing about the order elsewhere: an order skipped here for no
    ///         courier still fills through a courier its account did register.
    /// @param orderHash The skipped order's hash
    /// @param account The skipped order's account
    /// @param takingOrderHash The hash of the taking order of the Cross that skipped it
    /// @param reason Why it was skipped
    event OrderSkipped(
        bytes32 indexed orderHash, address indexed account, bytes32 indexed takingOrderHash, SkipReason reason
    );

    /// @notice Emitted once at the end of a Cross that filled at least one leg.
    /// @param courier The address that sent the Cross: the immediate caller
    /// @param takingOrderHash The taking order's hash
    /// @param taker The taking order's account
    /// @param marketId The market its legs filled into
    /// @param totalMakerRisk The resting stakes of its filled legs, added
    /// @param totalTakerRisk The taking stakes of its filled legs, added: what the taking order filled by
    event Crossed(
        address indexed courier,
        bytes32 indexed takingOrderHash,
        address indexed taker,
        uint256 marketId,
        uint256 totalMakerRisk,
        uint256 totalTakerRisk
    );

    // ──────────────────────────── Types ────────────────────────────────

    /**
     * @notice A signed order: the ten fields an account signs to take a position, in either role
     * @param account The account whose money backs the order
     * @param gameId The game, in the games set
     * @param scorer The market contract: the moneyline, the spread or the total
     * @param lineTicks The line, scaled by 10: for a spread, the home team's handicap; for a total, the total;
     *                  for a moneyline, zero
     * @param positionType The side: 0 for side A, the home team or over; 1 for side B, the away team or under
     * @param oddsTick The order's price, a floor, as an integer (193 = 1.93 odds): MIN_ODDS to MAX_ODDS
     * @param riskAmount The most the account stakes on this order, in the coin's smallest unit: above zero and
     *                   a whole number of lots
     * @param nonce Three numbers, high to low: the account's version (128 bits), which must be the account's
     *              current version for the order to fill; the number of the grant it was signed under (32 bits),
     *              0 when the account signed it itself; and an order number (96 bits), which raiseFloor
     *              invalidates for every order on the line with an order number below the floor. Orders may
     *              share a nonce: it is not a unique order id
     * @param expiry Unix timestamp: the order is live while the block's time is before it
     * @param minFill The least this order fills for in one Cross, in the coin's smallest unit and in the order's
     *                own stake, unless the fill completes the order: zero asks for nothing; at most riskAmount
     */
    struct OspexOrder {
        address account;
        uint256 gameId;
        address scorer;
        int32 lineTicks;
        Side positionType;
        uint16 oddsTick;
        uint256 riskAmount;
        uint256 nonce;
        uint256 expiry;
        uint256 minFill;
    }

    /// @notice An order with its signature: 65 bytes, ECDSA, over getOrderHash(order), by the order's resolved
    ///         signer: its account when the nonce's grant number is 0, the agent of that grant otherwise
    struct SignedOrder {
        OspexOrder order;
        bytes signature;
    }

    /// @notice Why a Cross skipped a resting order. The numbers are stable tags, not the order the reasons are
    ///         tested in: item 23 of the spec's first milestone states that order, and a resting order in two of
    ///         these states is recorded under the reason tested first there.
    enum SkipReason {
        /// @dev 0: the order's account has not registered the sender as a courier.
        NoCourier,
        /// @dev 1: the order's hash is marked cancelled, its version is not its account's current version, or
        ///      its order number is under its account's floor for the line.
        Cancelled,
        /// @dev 2: the block's time is at or past the order's expiry.
        Expired,
        /// @dev 3: the order has filled its signed stake.
        NoRoom,
        /// @dev 4: no whole number of lots fits the order's room and the taking stake left with both stakes at
        ///      or above one lot's worth of units.
        NothingFits,
        /// @dev 5: the leg would take less than the order's minimum fill and leave a lot or more of its room.
        UnderMinFill,
        /// @dev 6: the coin refused the pull of the resting stake from the order's account.
        PullRefused
    }

    /// @notice One listed order's fate in a Cross that reverted short: filled, with the leg's two stakes, or
    ///         skipped, with its reason and zero stakes. A hash listed twice is two records.
    /// @param orderHash The resting order's hash
    /// @param filled Whether the leg filled
    /// @param reason Why it was skipped, when it was not filled; 0 and not a reason when it was
    /// @param makerRisk The resting stake of the leg when it filled, else zero
    /// @param takerRisk The taking stake of the leg when it filled, else zero
    struct LegReport {
        bytes32 orderHash;
        bool filled;
        SkipReason reason;
        uint256 makerRisk;
        uint256 takerRisk;
    }

    /// @dev What a Cross has filled so far.
    struct Tally {
        uint256 legs;
        uint256 marketId;
        uint256 makerRisk;
        uint256 takerRisk;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The core
    OspexBetting public immutable i_ospexCore;
    /// @notice The Polygon timelock: the one address that lifts the cap. Read once from the games set the core
    ///         names, when this contract is deployed, and kept: what that games set answers later changes
    ///         nothing here.
    address public immutable i_timelock;

    /// @notice Each account's current version: 0 to begin with, moved only by cancelAll. An order fills only
    ///         while the version in its nonce is this.
    mapping(address => uint128) public s_version;
    /// @notice Per-line floor inside one version: account → version → line key → floor. An order whose order
    ///         number is under the floor is cancelled. The line key is keccak256(abi.encode(gameId, scorer,
    ///         lineTicks)).
    mapping(address => mapping(uint128 => mapping(bytes32 => uint96))) public s_floors;
    /// @notice Individually cancelled order hashes
    mapping(bytes32 => bool) public s_cancelledOrders;
    /// @notice What each order has filled, by its hash, in the order's own stake: the same record whichever
    ///         role the order played, and across Crosses. Written by cross alone. Read during a Cross, from a
    ///         call the coin makes inside a pull, it shows the leg in progress, which is taken back if that leg
    ///         is skipped.
    mapping(bytes32 => uint256) public s_filledRisk;
    /// @dev Each account's couriers: account → courier → registered. Written by registerCourier and
    ///      unregisterCourier, each at the caller's own entry and no other, and read through isCourier and,
    ///      by the same read, by the Cross.
    mapping(address => mapping(address => bool)) internal s_couriers;
    /// @notice Whether the cap on a taking order's signed stake has been lifted. False at deploy; written once,
    ///         to true, by liftTakingStakeCap, and by nothing else.
    bool public s_takingStakeCapLifted;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the matching module with EIP-712 domain "Ospex" version "3", and reads the timelock once
    ///         from the games set the core names
    /// @param core The betting set's core
    constructor(address core) EIP712("Ospex", "3") {
        if (core == address(0)) revert OspexMatching__InvalidAddress();
        i_ospexCore = OspexBetting(core);
        // The timelock, read once and kept. The games address gets the check the games set makes on its own
        // timelock: a contract, and not a wallet's delegation.
        address games = address(OspexBetting(core).i_games());
        if (games.code.length == 0 || _isDelegated(games)) revert OspexMatching__GamesNotAContract(games);
        address timelock = IOspexGamesTimelock(games).i_timelock();
        if (timelock == address(0)) revert OspexMatching__GamesHasNoTimelock(games);
        i_timelock = timelock;
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @inheritdoc IOspexModule
    function getModuleType() external pure override returns (bytes32) {
        return MATCHING_MODULE;
    }

    // ──────────────────────────── The Cross ───────────────────────────

    /**
     * @notice Fill a taking order against resting orders, in the order listed.
     * @dev The sender is msg.sender, the immediate caller and never tx.origin.
     *
     *      Before anything moves, each of these reverts the whole call under its own name. The order among
     *      them is not promised, but for this: an order's own price and stake are tested before its room is
     *      read and before its price is compared with another order's, since a zero stake has no room and a
     *      price out of range meets no price. A call with two faults otherwise reverts under either name.
     *      - A Cross is already in progress.
     *      - The taking order's account has not registered the sender.
     *      - The taking order: its signature is not its resolved signer's, or it names a grant never made; its
     *        price or its stake is not admissible; its minimum fill is above its signed stake; under a grant,
     *        its stake is above the grant's cap or its line is off the grant's list; its signed stake is above
     *        TAKING_STAKE_CAP and the cap has not been lifted; it is cancelled, by its own cancel, by its version
     *        not being its account's current one, or by its order number being under its account's floor for
     *        the line; its grant is not its account's current one or has ended; it has expired; it has more
     *        than MAX_TAKING_LIFE seconds left; it has no room left.
     *      - A resting order, anywhere in the list: its signature is not its resolved signer's, or it names a
     *        grant never made; its price or its stake is not admissible; its minimum fill is above its signed
     *        stake; under a grant, its stake is above the grant's cap or its line is off the grant's list; its
     *        game, market contract or line is not the taking order's; it is on the taking order's side; its
     *        price does not meet the taking order's.
     *
     *      Then the walk: one leg per resting order, in list order. Each is filled or skipped, and a skipped
     *      order is recorded under the first of the eight reasons that applies, in the order item 23 of the
     *      spec's first milestone states. A
     *      leg takes k lots, k being the smaller of the resting order's room / LOT and the taking stake left
     *      / p, p being the resting price less ODDS_SCALE: the resting account stakes k x LOT and the taking
     *      account k x p, which is the resting price to the unit. A leg fills only if its taking stake is at
     *      least LOT units, which makes its resting stake at least LOT units too; and only if its resting stake
     *      is at least the resting order's minimum fill, or leaves less than a lot of that order's room, else
     *      the order is skipped under its minimum. Both filled amounts are raised before the positions module
     *      is called, and written back as they were if the leg is skipped for a refused pull.
     *
     *      A leg is skipped for a refused pull only when the positions call reverts with exactly its
     *      MakerPullRefused error, three words, for this leg's resting account and resting stake: the third
     *      word, the amount the positions module asked, which is the resting account's netted pull and at most
     *      its stake, is not compared. Every other revert of that call reverts the Cross, with its data
     *      unchanged: a short receipt, the close gate, a market that cannot be drawn, and running out of gas
     *      among them.
     *
     *      If no leg filled the call reverts, carrying each listed order's reason. If legs filled but this
     *      Cross filled the taking order for less than its minimum fill, with a lot or more of its room left,
     *      the call reverts under its own name, carrying what it filled, the minimum, the room and one record
     *      per listed order, and nothing of the Cross remains: the pulls, the positions, a market it drew, the
     *      filled amounts and the logs are all undone. Otherwise the positions module's finishFills is called
     *      once, with the taking account and the resting accounts of the filled legs in list order: it pulls
     *      the taking account once, over every leg of the Cross, and a pull the coin refuses reverts the whole
     *      Cross with the positions module's TakerPullRefused, its second word that netted pull; then it pays
     *      back every account of the Cross held above its worst loss. Then Crossed is emitted.
     *
     *      What the coin can do. The positions module pulls each resting account what lifts its held amount to
     *      its worst loss, at the leg, and the taking account once at the end, and the coin is fixed at the
     *      set's deploy. A coin that calls the debited account during a transfer hands that account a call in
     *      the middle of a Cross, and so does a pay-back to an account with code: it cannot cancel, raise a
     *      floor, cancel everything, grant, revoke, change a courier or start a Cross from there, which this
     *      contract refuses, but it can make
     *      the Cross fail, by spending the gas passed to it or by ending the game, where its release is open, so
     *      that the next leg meets the close gate. No gas limit is put on a pull or a pay-back and no leg is
     *      skipped at the close gate. USDC makes no such call.
     * @param taking The taking order and its signature
     * @param resting The resting orders, each with its signature, in the order they are to fill
     */
    function cross(SignedOrder calldata taking, SignedOrder[] calldata resting) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        CROSS_IN_PROGRESS_SLOT.asBoolean().tstore(true);

        OspexOrder calldata t = taking.order;
        if (!_isCourier(t.account, msg.sender)) revert OspexMatching__SenderNotCourier(t.account, msg.sender);

        bytes32 marketKey = _lineKey(t.gameId, t.scorer, t.lineTicks);
        bytes32 takingHash = _checkTaking(taking, marketKey);
        bytes32[] memory hashes = _checkResting(t, resting);

        IOspexPositions positions = IOspexPositions(i_ospexCore.getModule(POSITION_MODULE));
        LegReport[] memory report = new LegReport[](resting.length);
        // The resting accounts of the filled legs, in list order, for the end call: one entry per filled leg,
        // so an account resting twice is listed twice. Sized for every leg and cut to the filled ones below.
        address[] memory makers = new address[](resting.length);
        Tally memory tally;
        for (uint256 i; i < resting.length; ++i) {
            (bool filled, SkipReason reason, uint256 makerRisk, uint256 takerRisk) =
                _leg(positions, t, takingHash, marketKey, resting[i].order, hashes[i], tally);
            // A filled leg's record carries its two stakes and no reason; a skipped order's its reason and zero
            // stakes, whatever the leg had computed before it skipped.
            report[i] = LegReport({
                orderHash: hashes[i],
                filled: filled,
                reason: filled ? SkipReason.NoCourier : reason,
                makerRisk: filled ? makerRisk : 0,
                takerRisk: filled ? takerRisk : 0
            });
            if (filled) {
                // The leg just counted is the last filled one.
                makers[tally.legs - 1] = resting[i].order.account;
                continue;
            }
            emit OrderSkipped(hashes[i], resting[i].order.account, takingHash, reason);
            i_ospexCore.emitCoreEvent(
                EVENT_ORDER_SKIPPED, abi.encode(hashes[i], resting[i].order.account, takingHash, reason)
            );
        }
        if (tally.legs == 0) revert OspexMatching__NothingFilled(_reasonsOf(report));
        // The taking order's minimum, on what this Cross filled of it: met, or the order is complete, with less
        // than a lot left, which nothing could ever fill. The room never underflows: a leg takes at most what
        // is left.
        uint256 room = t.riskAmount - s_filledRisk[takingHash];
        if (tally.takerRisk < t.minFill && room >= LOT) {
            revert OspexMatching__TakingOrderUnderMinFill(takingHash, tally.takerRisk, t.minFill, room, report);
        }

        // The end call: the taking account's one pull and the pay-backs, on the market every leg filled into. The
        // list is cut to the filled legs, which are its first entries; its length only shrinks here, within the
        // memory it was given. A refusal of the taking pull reverts here with the positions module's own data.
        uint256 legs = tally.legs;
        assembly ("memory-safe") {
            mstore(makers, legs)
        }
        positions.finishFills(tally.marketId, t.account, makers);

        emit Crossed(msg.sender, takingHash, t.account, tally.marketId, tally.makerRisk, tally.takerRisk);
        i_ospexCore.emitCoreEvent(
            EVENT_CROSSED,
            abi.encode(msg.sender, takingHash, t.account, tally.marketId, tally.makerRisk, tally.takerRisk)
        );

        CROSS_IN_PROGRESS_SLOT.asBoolean().tstore(false);
    }

    /// @dev The taking order's own checks, each a revert of the whole call: signature and limits, price and
    ///      stake, the cap on its signed stake until the switch, its standing (the mark, the version, the floor),
    ///      its grant's standing (current, not ended), expiry, the life left, room. The expiry is tested before
    ///      the life left is subtracted, so an expired order is refused by name and not as an arithmetic error;
    ///      the room is a comparison, with nothing subtracted.
    function _checkTaking(SignedOrder calldata taking, bytes32 marketKey) private view returns (bytes32 orderHash) {
        OspexOrder calldata t = taking.order;
        orderHash = _checkSigned(taking);
        // The cap compares the signed stake, never what is left to fill, and reads the switch only for a stake
        // above it: a stake at or under the cap makes no storage read here.
        if (t.riskAmount > TAKING_STAKE_CAP && !s_takingStakeCapLifted) {
            revert OspexMatching__TakingStakeAboveCap(orderHash);
        }
        (uint128 version,, uint96 orderNumber) = _split(t.nonce);
        if (
            s_cancelledOrders[orderHash] || version != s_version[t.account]
                || orderNumber < s_floors[t.account][version][marketKey]
        ) {
            revert OspexMatching__TakingOrderCancelled(orderHash);
        }
        if (block.timestamp >= t.expiry) revert OspexMatching__TakingOrderExpired(orderHash);
        if (t.expiry - block.timestamp > MAX_TAKING_LIFE) revert OspexMatching__TakingOrderTooLong(orderHash);
        if (s_filledRisk[orderHash] >= t.riskAmount) revert OspexMatching__TakingOrderFilled(orderHash);
    }

    /// @dev Every resting order's checks that are fixed in the signed order, each a revert of the whole call,
    ///      made for the whole list before the first leg: signature, price and stake, the taking order's game,
    ///      market contract and line, the other side, and prices that meet.
    function _checkResting(OspexOrder calldata t, SignedOrder[] calldata resting)
        private
        view
        returns (bytes32[] memory hashes)
    {
        hashes = new bytes32[](resting.length);
        uint256 takingP = uint256(t.oddsTick) - ODDS_SCALE;
        for (uint256 i; i < resting.length; ++i) {
            OspexOrder calldata r = resting[i].order;
            bytes32 orderHash = _checkSigned(resting[i]);
            if (r.gameId != t.gameId) revert OspexMatching__OtherGame(orderHash);
            if (r.scorer != t.scorer) revert OspexMatching__OtherScorer(orderHash);
            if (r.lineTicks != t.lineTicks) revert OspexMatching__OtherLine(orderHash);
            if (r.positionType == t.positionType) revert OspexMatching__SameSide(orderHash);
            if ((uint256(r.oddsTick) - ODDS_SCALE) * takingP > uint256(ODDS_SCALE) * ODDS_SCALE) {
                revert OspexMatching__PricesDoNotMeet(orderHash);
            }
            hashes[i] = orderHash;
        }
    }

    /// @dev What every listed order must be, in either role: signed by its resolved signer, at an admissible
    ///      price, for an admissible stake, with a minimum fill it could meet, and, under a grant, within that
    ///      grant's cap and on its list. The signer is the account when the nonce's grant number is 0 and the
    ///      agent of the grant that number names otherwise; a grant never made is refused by name. The signature
    ///      is recovered and compared with the signer, and nothing is called: no account, agent or verifier is
    ///      asked, and no code is read. The cap and the list are read from the record the order names, which is
    ///      fixed for that number, so they are the sender's to know and refuse the whole call; the grant's
    ///      standing, current and not ended, is read where the order's standing is, at the taking check and at
    ///      the leg. Returns the order's hash.
    function _checkSigned(SignedOrder calldata signed) private view returns (bytes32 orderHash) {
        OspexOrder calldata order = signed.order;
        orderHash = _hashOrder(order);
        address signer = order.account;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(orderHash, signed.signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) {
            revert OspexMatching__BadSignature(orderHash);
        }
        if (order.oddsTick < MIN_ODDS || order.oddsTick > MAX_ODDS) revert OspexMatching__PriceOutOfRange(orderHash);
        if (order.riskAmount == 0 || order.riskAmount % LOT != 0) revert OspexMatching__StakeNotInLots(orderHash);
        if (order.minFill > order.riskAmount) {
            revert OspexMatching__MinFillAboveStake(orderHash, order.minFill, order.riskAmount);
        }
    }

    /// @dev One leg: the eight skip tests in the order item 23 states, then the fill. Both orders' filled amounts
    ///      are read from storage here, at this leg, so an order listed twice meets at its second entry what
    ///      its first used. Returns the leg's verdict, the reason where it skipped, and the two stakes it had in
    ///      hand: both zero where it skipped before they were computed, the computed pair where it skipped under
    ///      the minimum or for a refused pull, and the leg's where it filled.
    function _leg(
        IOspexPositions positions,
        OspexOrder calldata t,
        bytes32 takingHash,
        bytes32 marketKey,
        OspexOrder calldata r,
        bytes32 restingHash,
        Tally memory tally
    ) private returns (bool filled, SkipReason reason, uint256 makerRisk, uint256 takerRisk) {
        if (!_isCourier(r.account, msg.sender)) return (false, SkipReason.NoCourier, 0, 0);
        {
            (uint128 version,, uint96 orderNumber) = _split(r.nonce);
            if (
                s_cancelledOrders[restingHash] || version != s_version[r.account]
                    || orderNumber < s_floors[r.account][version][marketKey]
            ) {
                return (false, SkipReason.Cancelled, 0, 0);
            }
        }
        if (block.timestamp >= r.expiry) return (false, SkipReason.Expired, 0, 0);

        uint256 restingFilled = s_filledRisk[restingHash];
        if (restingFilled >= r.riskAmount) return (false, SkipReason.NoRoom, 0, 0);

        uint256 takingFilled = s_filledRisk[takingHash];
        uint256 left = takingFilled >= t.riskAmount ? 0 : t.riskAmount - takingFilled;
        uint256 p = uint256(r.oddsTick) - ODDS_SCALE;
        uint256 lots = (r.riskAmount - restingFilled) / LOT;
        if (left / p < lots) lots = left / p;
        // The minimum, on the taking stake. It holds the resting stake too: a taking stake of LOT units or more
        // is at least one lot of resting stake, and no lots are no taking stake.
        if (lots * p < LOT) return (false, SkipReason.NothingFits, 0, 0);

        makerRisk = lots * LOT;
        takerRisk = lots * p;
        // The resting order's minimum, on its own stake: the leg takes at least minFill of it, or every whole
        // lot it has left, leaving less than a lot, which nothing could ever fill. Its room is at least the
        // stake taken: the lots were counted from it.
        if (makerRisk < r.minFill && (r.riskAmount - restingFilled) - makerRisk >= LOT) {
            return (false, SkipReason.UnderMinFill, makerRisk, takerRisk);
        }
        s_filledRisk[restingHash] = restingFilled + makerRisk;
        s_filledRisk[takingHash] = takingFilled + takerRisk;

        try positions.recordFill(
            t.gameId, t.scorer, t.lineTicks, r.positionType, r.account, makerRisk, t.account, takerRisk
        ) returns (
            uint256 marketId
        ) {
            tally.legs += 1;
            tally.marketId = marketId;
            tally.makerRisk += makerRisk;
            tally.takerRisk += takerRisk;
            _emitMatched(restingHash, r, t.account, marketId, makerRisk, takerRisk);
            // The reason beside a filled leg is not read.
            return (true, SkipReason.NoCourier, makerRisk, takerRisk);
        } catch (bytes memory refusal) {
            if (!_isMakerPullRefused(refusal, r.account, makerRisk)) {
                assembly ("memory-safe") {
                    revert(add(refusal, 0x20), mload(refusal))
                }
            }
            s_filledRisk[restingHash] = restingFilled;
            s_filledRisk[takingHash] = takingFilled;
            return (false, SkipReason.PullRefused, makerRisk, takerRisk);
        }
    }

    /// @dev The reasons of a Cross in which no leg filled, one per listed order, drawn from its report: every
    ///      record is a skip, so each reason is one.
    function _reasonsOf(LegReport[] memory report) private pure returns (SkipReason[] memory reasons) {
        reasons = new SkipReason[](report.length);
        for (uint256 i; i < report.length; ++i) {
            reasons[i] = report[i].reason;
        }
    }

    /// @dev True only for the positions module's MakerPullRefused carrying this leg's resting account and
    ///      resting stake: 100 bytes, the error's selector, then the three arguments, the first two compared as
    ///      whole words and the third, the amount the positions module asked of the account, not compared.
    ///      Revert data of any other length, selector, account or stake is not this error.
    function _isMakerPullRefused(bytes memory refusal, address maker, uint256 makerRisk) private pure returns (bool) {
        if (refusal.length != 100) return false;
        bytes32 head;
        bytes32 account;
        bytes32 amount;
        assembly ("memory-safe") {
            head := mload(add(refusal, 0x20))
            account := mload(add(refusal, 0x24))
            amount := mload(add(refusal, 0x44))
        }
        return (head & SELECTOR_MASK) == bytes32(IOspexPositions.OspexPositions__MakerPullRefused.selector)
            && account == bytes32(uint256(uint160(maker))) && amount == bytes32(makerRisk);
    }

    /// @dev A filled leg's event, and its copy through the hub.
    function _emitMatched(
        bytes32 restingHash,
        OspexOrder calldata r,
        address taker,
        uint256 marketId,
        uint256 makerRisk,
        uint256 takerRisk
    ) private {
        emit OrderMatched(
            restingHash,
            r.account,
            taker,
            r.gameId,
            marketId,
            r.scorer,
            r.lineTicks,
            r.positionType,
            r.oddsTick,
            makerRisk,
            takerRisk,
            r.riskAmount,
            r.nonce,
            r.expiry,
            r.minFill
        );
        i_ospexCore.emitCoreEvent(
            EVENT_ORDER_MATCHED,
            abi.encode(
                restingHash,
                r.account,
                taker,
                r.gameId,
                marketId,
                r.scorer,
                r.lineTicks,
                r.positionType,
                r.oddsTick,
                makerRisk,
                takerRisk,
                r.riskAmount,
                r.nonce,
                r.expiry,
                r.minFill
            )
        );
    }

    // ──────────────────────────── Couriers ────────────────────────────

    /**
     * @notice Register a courier for the caller.
     * @dev The account is msg.sender, the immediate caller and never tx.origin, so a contract account
     *      registers as itself and a contract an account calls registers nothing for it. Any address but zero
     *      is taken, a key or a contract, the account's own included: nothing is read from the courier. An
     *      account may register several.
     *
     *      Registering a courier the account already has succeeds, with no write and no event, so every
     *      CourierRegistered is a change. It is not refused because a repeated registration costs the account
     *      nothing beyond the call's gas, where a refusal could revert a transaction that carries the
     *      registration beside other calls.
     *
     *      Refused while a Cross is in progress.
     * @param courier The address to register as the caller's courier
     */
    function registerCourier(address courier) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        _register(msg.sender, courier);
    }

    /**
     * @notice Drop one of the caller's couriers.
     * @dev The account is msg.sender, as in registerCourier. It drops the one courier named and leaves the
     *      account's others. A dropped courier may be registered again. From the drop on, a Cross that courier
     *      sends skips the account's resting orders and is refused for its taking orders.
     *
     *      Dropping a courier the account does not have is refused by name, the zero address included, so
     *      every CourierUnregistered is a change. It is refused, where a repeated registration is not, because
     *      a drop that changes nothing must not read as done: a call that named the wrong address would
     *      succeed while the courier the account meant to drop stayed registered.
     *
     *      Refused while a Cross is in progress.
     * @param courier The courier to drop
     */
    function unregisterCourier(address courier) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        if (!s_couriers[msg.sender][courier]) revert OspexMatching__CourierNotRegistered(msg.sender, courier);
        s_couriers[msg.sender][courier] = false;
        emit CourierUnregistered(msg.sender, courier);
        i_ospexCore.emitCoreEvent(EVENT_COURIER_UNREGISTERED, abi.encode(msg.sender, courier));
    }

    // ──────────────────────────── Cancelling ──────────────────────────

    /**
     * @notice Cancel one order by its hash. The order's account calls it, or that account's live agent.
     * @dev The caller is msg.sender, the immediate caller and never tx.origin: it must be the address in the
     *      order's account field, or the agent of that account's current grant while that grant stands. A call
     *      passed through another contract is authorized on that contract's address, as the account or as the
     *      live agent, and on nothing else. The order's version must be its account's current one, or the call
     *      is refused by name and nothing is written: a mark reaches one version. Then the mark is set on the
     *      hash of the ten values under this contract's domain, and nothing else about the order is checked:
     *      not a signature, not its expiry. Cancelling an order again marks the same hash and emits again. A
     *      cancelled order fills no further, in either role: what it filled before the cancel stands. The event
     *      names the order's account and, last, the caller whose authority was checked.
     *
     *      Refused while a Cross is in progress.
     * @param order The order to cancel
     */
    function cancelOrder(OspexOrder calldata order) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        _requireAccountOrAgent(order.account);
        bytes32 orderHash = _hashOrder(order);
        (uint128 version,,) = _split(order.nonce);
        uint128 current = s_version[order.account];
        if (version != current) revert OspexMatching__OrderNotAtCurrentVersion(orderHash, version, current);
        s_cancelledOrders[orderHash] = true;

        emit OrderCancelled(
            orderHash,
            order.account,
            order.gameId,
            order.scorer,
            order.lineTicks,
            order.positionType,
            order.oddsTick,
            order.riskAmount,
            order.nonce,
            order.expiry,
            order.minFill,
            msg.sender
        );
        i_ospexCore.emitCoreEvent(
            EVENT_ORDER_CANCELLED,
            abi.encode(
                orderHash,
                order.account,
                order.gameId,
                order.scorer,
                order.lineTicks,
                order.positionType,
                order.oddsTick,
                order.riskAmount,
                order.nonce,
                order.expiry,
                order.minFill,
                msg.sender
            )
        );
    }

    /**
     * @notice Raise an account's floor for one line at its current version, invalidating every order of the
     *         account on that line, at that version, whose order number is under the floor. The account calls
     *         it, or its live agent.
     * @dev The scope is one account, its current version and one line, the three fields a signed order names a
     *      market by, whether or not a fill has drawn that market. The floor only rises, and its type ends it at
     *      MAX_ORDER_NUMBER, the top order number: only order numbers strictly below the floor are cancelled,
     *      so the top order number survives every floor and dies by its own cancel or by cancelAll. An order
     *      whose order number is at the floor is live; one under it fills no further, in either role. The
     *      floors of a new version start at zero. The caller is msg.sender, the account named or its live
     *      agent, and the event names the account and the caller.
     *
     *      Refused while a Cross is in progress.
     * @param account The account whose floor rises
     * @param gameId The game
     * @param scorer The market contract
     * @param lineTicks The line, scaled by 10
     * @param floor The new floor: above the line's current floor at the account's current version
     */
    function raiseFloor(address account, uint256 gameId, address scorer, int32 lineTicks, uint96 floor) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        _requireAccountOrAgent(account);
        bytes32 lineKey = _lineKey(gameId, scorer, lineTicks);
        uint128 version = s_version[account];
        uint96 current = s_floors[account][version][lineKey];
        if (floor <= current) revert OspexMatching__FloorMustRise(current, floor);
        s_floors[account][version][lineKey] = floor;
        emit FloorRaised(account, version, gameId, scorer, lineTicks, floor, lineKey, msg.sender);
        i_ospexCore.emitCoreEvent(
            EVENT_FLOOR_RAISED, abi.encode(account, version, gameId, scorer, lineTicks, floor, lineKey, msg.sender)
        );
    }

    /**
     * @notice Cancel every order of an account, whoever signed it: move the account to a new version, which the
     *         contract draws. The account calls it, or its live agent. It takes no number.
     * @dev The next version is the current one plus one plus the first 64 bits of the previous block's hash, in
     *      checked arithmetic: a step that would pass the top of the field is refused by name and writes
     *      nothing, so the version only rises, never wraps, and takes at least 2^64 successful cancels to fill.
     *      Every order naming the old version is dead, and the new version's floors are zero. The previous
     *      block's hash is public once that block is mined, so the next version is predictable conditional on
     *      execution against that state; the caller supplies no version argument but can select when and how
     *      often to call, and a successful cancel invalidates orders naming other versions, not every signature
     *      already made: an order signed beforehand for the resulting version may still fill while every other
     *      condition holds. Revoke ends that grant's remaining authority. The caller is msg.sender, the account
     *      named or its live agent, and the event names the account and the caller.
     *
     *      Refused while a Cross is in progress.
     * @param account The account whose version moves
     */
    function cancelAll(address account) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        _requireAccountOrAgent(account);
        uint128 current = s_version[account];
        uint128 draw = uint128(uint64(bytes8(blockhash(block.number - 1))));
        if (type(uint128).max - current < draw + 1) revert OspexMatching__VersionAtTop(account, current);
        uint128 next = current + 1 + draw;
        s_version[account] = next;
        emit VersionChanged(account, current, next, msg.sender);
        i_ospexCore.emitCoreEvent(EVENT_VERSION_CHANGED, abi.encode(account, current, next, msg.sender));
    }

    // ──────────────────────────── The cap ─────────────────────────────

    /**
     * @notice Lift the cap on a taking order's signed stake. Only the timelock calls it, and once.
     * @dev The caller is msg.sender, which must be i_timelock: the Polygon timelock, read from the games set
     *      when this contract was deployed. So a lift waits the timelock's delay and is public while it waits,
     *      and the key that holds the timelock is refused here like any other address. A second lift is refused
     *      by name, and no function puts the cap back. It writes the one flag and emits TakingStakeCapLifted
     *      and its hub copy; it moves no coin, draws no market and writes no position.
     *
     *      Refused while a Cross is in progress: the stock timelock lets anyone run a ready call, so a coin
     *      that calls out during a pull could otherwise run the lift from inside a leg.
     */
    function liftTakingStakeCap() external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        if (msg.sender != i_timelock) revert OspexMatching__NotTheTimelock(msg.sender);
        if (s_takingStakeCapLifted) revert OspexMatching__CapAlreadyLifted();
        s_takingStakeCapLifted = true;
        emit TakingStakeCapLifted();
        i_ospexCore.emitCoreEvent(EVENT_TAKING_STAKE_CAP_LIFTED, "");
    }

    // ──────────────────────────── Reads ───────────────────────────────

    /// @notice Whether an account has a courier registered: true from the account's registerCourier until its
    ///         unregisterCourier, and false otherwise.
    /// @param account The account
    /// @param courier The address asked about
    /// @return True when `courier` is one of `account`'s couriers
    function isCourier(address account, address courier) external view returns (bool) {
        return _isCourier(account, courier);
    }

    /// @notice Returns the EIP-712 domain separator
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Computes the hash of an order, for signing off chain
    /// @param order The order to hash
    /// @return The EIP-712 typed data hash
    function getOrderHash(OspexOrder calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    /// @notice An account's floor for a line at its current version.
    function getFloor(address account, uint256 gameId, address scorer, int32 lineTicks) external view returns (uint96) {
        return s_floors[account][s_version[account]][_lineKey(gameId, scorer, lineTicks)];
    }

    /// @notice The three numbers a nonce holds, high to low: the version, the grant number and the order number.
    function splitNonce(uint256 nonce) external pure returns (uint128 version, uint32 grantNumber, uint96 orderNumber) {
        return _split(nonce);
    }

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev Whether `account` has registered `courier`: the one read of the record, behind isCourier and
    ///      behind the Cross's check of its sender against the taking account and each resting account.
    function _isCourier(address account, address courier) private view returns (bool) {
        return s_couriers[account][courier];
    }

    /// @dev The one write of a courier: `account` registers `courier`. The zero address is refused by name; a
    ///      courier the account already has is left as it is, with no write and no event.
    function _register(address account, address courier) private {
        if (courier == address(0)) revert OspexMatching__ZeroCourier();
        if (s_couriers[account][courier]) return;
        s_couriers[account][courier] = true;
        emit CourierRegistered(account, courier);
        i_ospexCore.emitCoreEvent(EVENT_COURIER_REGISTERED, abi.encode(account, courier));
    }

    /// @dev The three cancels' rule: the caller is the account named, else refused by name.
    ///      The caller is msg.sender, the immediate caller, whatever contract a call came through.
    function _requireAccountOrAgent(address account) private view {
        if (msg.sender != account) {
            revert OspexMatching__NotAccountOrAgent(account, msg.sender);
        }
    }

    /// @dev The key a line is stored under, for floors and for a grant's list: the three fields a signed order
    ///      names a market by.
    function _lineKey(uint256 gameId, address scorer, int32 lineTicks) private pure returns (bytes32) {
        return keccak256(abi.encode(gameId, scorer, lineTicks));
    }

    /// @dev The three numbers a nonce holds. Each cast takes exactly its field of the word.
    function _split(uint256 nonce) private pure returns (uint128 version, uint32 grantNumber, uint96 orderNumber) {
        // forge-lint: disable-next-line(unsafe-typecast)
        version = uint128(nonce >> VERSION_SHIFT);
        // forge-lint: disable-next-line(unsafe-typecast)
        grantNumber = uint32(nonce >> GRANT_SHIFT);
        // forge-lint: disable-next-line(unsafe-typecast)
        orderNumber = uint96(nonce);
    }

    /// @dev Whether a Cross is in progress in this transaction.
    function _crossInProgress() private view returns (bool) {
        return CROSS_IN_PROGRESS_SLOT.asBoolean().tload();
    }

    /// @dev True when the account's code is a wallet's delegation (EIP-7702): 23 bytes, 0xef0100 and an address.
    ///      The games set's own check, made here on the games address the constructor reads.
    function _isDelegated(address account) private view returns (bool) {
        return account.code.length == 23 && bytes3(account.code) == 0xef0100;
    }

    /// @dev The EIP-712 typed data hash of an order: the domain separator over the struct hash
    function _hashOrder(OspexOrder calldata order) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.account,
                    order.gameId,
                    order.scorer,
                    order.lineTicks,
                    uint8(order.positionType),
                    order.oddsTick,
                    order.riskAmount,
                    order.nonce,
                    order.expiry,
                    order.minFill
                )
            )
        );
    }
}
