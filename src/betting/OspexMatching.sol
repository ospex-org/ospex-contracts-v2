// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IOspexModule} from "./IOspexModule.sol";
import {IOspexPositions} from "./IOspexPositions.sol";
import {OspexBetting} from "./OspexBetting.sol";
import {Side} from "./OspexBettingTypes.sol";

/**
 * @title OspexMatching
 * @author ospex.org
 * @notice The matching module of the betting set: the signed order and its hash, the Cross that fills orders,
 *         the per-order cancel, the per-market nonce floor and each account's couriers.
 *
 *         The signed order. An account signs OspexOrder, nine fields, under the EIP-712 domain "Ospex",
 *         version "3", this chain and this contract. Nothing in an order says which role it plays: the same
 *         signed order rests or takes. Its first field, account, is the account whose money backs it. In this
 *         build the account's own key signs, with a 65-byte ECDSA signature. Spec: "How a bet happens", and
 *         items 3, 8, 9, 10 and 13 of its first milestone.
 *
 *         Couriers. A courier is an address an account names to send the fills of its orders. An account
 *         registers one, and drops one, with a call from its own address: the account is the caller, and
 *         neither call takes an account, a signature or a grant, so only an account writes its own couriers.
 *         An account may hold several. There is no default: an account that registered none has none, this
 *         contract has no owner, and registerCourier and unregisterCourier are its only functions that write a
 *         courier. Spec: "How a bet happens", and items 1, 5 and 6 of its first milestone.
 *
 *         The Cross. cross(taking, resting) is the one path a fill arrives by, and the only function here
 *         that calls the positions module. Its sender, the immediate caller, lists one taking order and the
 *         resting orders it is to fill against, in order, each with its signature, and decides nothing else:
 *         no price, size, market, deadline or recipient is an argument. An order never fills through a courier
 *         its account has not registered: the taking account must have registered the sender, or the call
 *         reverts; a resting order whose account has not is skipped. Each leg fills at the resting order's
 *         price, in lots of 100 units of resting stake, and a resting order that cannot fill is skipped, for
 *         one of six reasons, while the rest fill. A Cross that fills nothing reverts. Spec: "How a bet
 *         happens", and items 4, 11, 12, 14 and 15 of its first milestone.
 *
 *         One Cross at a time. While a Cross is in progress this contract refuses another Cross, a cancel, a
 *         raised floor, a registration and a drop, each by the same name. So from the first check of a Cross
 *         to its end nothing but that Cross changes a cancel mark, a floor, a courier or a filled amount. The
 *         reads are not held: one made from inside a Cross, by a contract the coin calls during a pull, shows
 *         the legs done so far and the leg in progress, which is taken back if that leg is skipped. Such a
 *         read is not a finished Cross.
 *
 *         Who calls it, and what it calls. Anyone calls anything here; what a call may do is decided by who the
 *         caller is to the accounts it names. It calls the positions module's recordFill, once per attempted
 *         leg, and the core, for the positions module's address and its event hub. It holds no coin and is
 *         approved for none: the positions module pulls the stakes.
 *
 *         What this build is not. Each stake is pulled in full at each leg: netting, one rebalance for the
 *         taking account and pay-backs come with shared collateral. The account's own key signs: the approved
 *         agent and contract wallets come with the agent. An order's nonce is compared whole with its
 *         account's floor. There is no cap on a stake.
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
    bytes32 public constant EVENT_MIN_NONCE_UPDATED = keccak256("MIN_NONCE_UPDATED");
    bytes32 public constant EVENT_COURIER_REGISTERED = keccak256("COURIER_REGISTERED");
    bytes32 public constant EVENT_COURIER_UNREGISTERED = keccak256("COURIER_UNREGISTERED");
    bytes32 public constant EVENT_ORDER_MATCHED = keccak256("ORDER_MATCHED");
    bytes32 public constant EVENT_ORDER_SKIPPED = keccak256("ORDER_SKIPPED");
    bytes32 public constant EVENT_CROSSED = keccak256("CROSSED");

    /// @notice EIP-712 typehash for the OspexOrder struct: the nine fields, the first named `account`
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "OspexOrder(" "address account," "uint256 gameId," "address scorer," "int32 lineTicks," "uint8 positionType,"
        "uint16 oddsTick," "uint256 riskAmount," "uint256 nonce," "uint256 expiry" ")"
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

    /// @dev The first four bytes of a word: where revert data carries its error's selector.
    bytes32 private constant SELECTOR_MASK = bytes32(bytes4(0xffffffff));
    /// @dev Where the Cross-in-progress mark is kept, in transient storage: set by cross for the length of the
    ///      call, read by the four other state-changing functions, and gone at the transaction's end.
    bytes32 private constant CROSS_IN_PROGRESS_SLOT = keccak256("ospex.matching.cross-in-progress");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when an address other than the order's account cancels an order
    error OspexMatching__NotOrderAccount();
    /// @notice Thrown when the new minimum nonce is not higher than the current, or is the top value
    error OspexMatching__NonceMustIncrease();
    /// @notice Thrown when the core address is zero
    error OspexMatching__InvalidAddress();
    /// @notice Thrown when the address to register as a courier is zero
    error OspexMatching__ZeroCourier();
    /// @notice Thrown when an account drops a courier it does not have
    error OspexMatching__CourierNotRegistered(address account, address courier);

    /// @notice Thrown by cross, cancelOrder, raiseMinNonce, registerCourier and unregisterCourier while a Cross
    ///         is in progress
    error OspexMatching__CrossInProgress();
    /// @notice Thrown by cross when the taking order's account has not registered the sender as a courier
    error OspexMatching__SenderNotCourier(address account, address sender);
    /// @notice Thrown by cross when an order's signature is not its account's: the wrong key, the wrong type or
    ///         domain, a changed field, a length other than 65 bytes, or a signature the recovery refuses
    error OspexMatching__BadSignature(bytes32 orderHash);
    /// @notice Thrown by cross when an order's price is outside MIN_ODDS to MAX_ODDS, in either role
    error OspexMatching__PriceOutOfRange(bytes32 orderHash);
    /// @notice Thrown by cross when an order's signed stake is zero or not a whole number of lots, in either role
    error OspexMatching__StakeNotInLots(bytes32 orderHash);
    /// @notice Thrown by cross when the taking order is cancelled: its hash is marked, or its nonce is under its
    ///         account's floor for the market
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

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted when an order is cancelled by its account
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
        uint256 expiry
    );

    /// @notice Emitted when an account raises its minimum nonce for a market. marketKey is the key the floor is
    ///         stored under: keccak256(abi.encode(gameId, scorer, lineTicks)).
    event MinNonceUpdated(
        address indexed account,
        uint256 gameId,
        address scorer,
        int32 lineTicks,
        uint256 newMinNonce,
        bytes32 indexed marketKey
    );

    /// @notice Emitted when an account registers a courier. The account is the caller.
    event CourierRegistered(address indexed account, address indexed courier);

    /// @notice Emitted when an account drops a courier. The account is the caller.
    event CourierUnregistered(address indexed account, address indexed courier);

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
        uint256 expiry
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
     * @notice A signed order: the nine fields an account signs to take a position, in either role
     * @param account The account whose money backs the order
     * @param gameId The game, in the games set
     * @param scorer The market contract: the moneyline, the spread or the total
     * @param lineTicks The line, scaled by 10: for a spread, the home team's handicap; for a total, the total;
     *                  for a moneyline, zero
     * @param positionType The side: 0 for side A, the home team or over; 1 for side B, the away team or under
     * @param oddsTick The order's price, a floor, as an integer (193 = 1.93 odds): MIN_ODDS to MAX_ODDS
     * @param riskAmount The most the account stakes on this order, in the coin's smallest unit: above zero and
     *                   a whole number of lots
     * @param nonce Invalidation threshold, not a unique order id: orders on one market may share a nonce, and
     *              raiseMinNonce() invalidates every order on the market with a nonce below the new minimum
     * @param expiry Unix timestamp: the order is live while the block's time is before it
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
    }

    /// @notice An order with its signature: 65 bytes, ECDSA, by the order's account, over getOrderHash(order)
    struct SignedOrder {
        OspexOrder order;
        bytes signature;
    }

    /// @notice Why a Cross skipped a resting order. The numbers are in the order the reasons are tested, so an
    ///         order in two of these states is recorded under the lower number.
    enum SkipReason {
        /// @dev 0: the order's account has not registered the sender as a courier.
        NoCourier,
        /// @dev 1: the order's hash is marked cancelled, or its nonce is under its account's floor for the market.
        Cancelled,
        /// @dev 2: the block's time is at or past the order's expiry.
        Expired,
        /// @dev 3: the order has filled its signed stake.
        NoRoom,
        /// @dev 4: no whole number of lots fits the order's room and the taking stake left with both stakes at
        ///      or above one lot's worth of units.
        NothingFits,
        /// @dev 5: the coin refused the pull of the resting stake from the order's account.
        PullRefused
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

    /// @notice Per-market minimum valid nonce: account → market key → minimum nonce. The market key is
    ///         keccak256(abi.encode(gameId, scorer, lineTicks)).
    mapping(address => mapping(bytes32 => uint256)) public s_minNonces;
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

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the matching module with EIP-712 domain "Ospex" version "3"
    /// @param core The betting set's core
    constructor(address core) EIP712("Ospex", "3") {
        if (core == address(0)) revert OspexMatching__InvalidAddress();
        i_ospexCore = OspexBetting(core);
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
     *      - The taking order: its signature is not its account's; its price or its stake is not admissible;
     *        it is cancelled, by its own cancel or under its account's floor; it has expired; it has more than
     *        MAX_TAKING_LIFE seconds left; it has no room left.
     *      - A resting order, anywhere in the list: its signature is not its account's; its price or its stake
     *        is not admissible; its game, market contract or line is not the taking order's; it is on the
     *        taking order's side; its price does not meet the taking order's.
     *
     *      Then the walk: one leg per resting order, in list order. Each is filled or skipped, and a skipped
     *      order is recorded under the first of the six reasons that applies, in the order of SkipReason. A
     *      leg takes k lots, k being the smaller of the resting order's room / LOT and the taking stake left
     *      / p, p being the resting price less ODDS_SCALE: the resting account stakes k x LOT and the taking
     *      account k x p, which is the resting price to the unit. A leg fills only if its taking stake is at
     *      least LOT units, which makes its resting stake at least LOT units too. Both filled amounts are
     *      raised before the positions module is called, and written back as they were if the leg is skipped
     *      for a refused pull.
     *
     *      A leg is skipped for a refused pull only when the positions call reverts with exactly its
     *      MakerPullRefused error for this leg's resting account and resting stake. Every other revert of that
     *      call reverts the Cross, with its data unchanged: the taking account's refused pull, a short receipt,
     *      the close gate, a market that cannot be drawn, and running out of gas among them.
     *
     *      If no leg filled the call reverts, carrying each listed order's reason. Otherwise Crossed is
     *      emitted.
     *
     *      What the coin can do. The positions module pulls the two stakes of a leg, and the coin is fixed at
     *      the set's deploy. A coin that calls the debited account during a transfer hands that account a call
     *      in the middle of a Cross: it cannot cancel, raise a floor, change a courier or start a Cross from
     *      there, which this contract refuses, but it can make the Cross fail, by spending the gas passed to
     *      it or by ending the game, where its release is open, so that the next leg meets the close gate. No
     *      gas limit is put on a pull and no leg is skipped at the close gate. USDC makes no such call.
     * @param taking The taking order and its signature
     * @param resting The resting orders, each with its signature, in the order they are to fill
     */
    function cross(SignedOrder calldata taking, SignedOrder[] calldata resting) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        CROSS_IN_PROGRESS_SLOT.asBoolean().tstore(true);

        OspexOrder calldata t = taking.order;
        if (!_isCourier(t.account, msg.sender)) revert OspexMatching__SenderNotCourier(t.account, msg.sender);

        bytes32 marketKey = keccak256(abi.encode(t.gameId, t.scorer, t.lineTicks));
        bytes32 takingHash = _checkTaking(taking, marketKey);
        bytes32[] memory hashes = _checkResting(t, resting);

        IOspexPositions positions = IOspexPositions(i_ospexCore.getModule(POSITION_MODULE));
        SkipReason[] memory reasons = new SkipReason[](resting.length);
        Tally memory tally;
        for (uint256 i; i < resting.length; ++i) {
            (bool filled, SkipReason reason) =
                _leg(positions, t, takingHash, marketKey, resting[i].order, hashes[i], tally);
            if (filled) continue;
            reasons[i] = reason;
            emit OrderSkipped(hashes[i], resting[i].order.account, takingHash, reason);
            i_ospexCore.emitCoreEvent(
                EVENT_ORDER_SKIPPED, abi.encode(hashes[i], resting[i].order.account, takingHash, reason)
            );
        }
        if (tally.legs == 0) revert OspexMatching__NothingFilled(reasons);

        emit Crossed(msg.sender, takingHash, t.account, tally.marketId, tally.makerRisk, tally.takerRisk);
        i_ospexCore.emitCoreEvent(
            EVENT_CROSSED,
            abi.encode(msg.sender, takingHash, t.account, tally.marketId, tally.makerRisk, tally.takerRisk)
        );

        CROSS_IN_PROGRESS_SLOT.asBoolean().tstore(false);
    }

    /// @dev The taking order's own checks, each a revert of the whole call: signature, price and stake, cancel
    ///      and floor, expiry, the life left, room. The expiry is tested before the life left is subtracted,
    ///      so an expired order is refused by name and not as an arithmetic error; the room is a comparison,
    ///      with nothing subtracted.
    function _checkTaking(SignedOrder calldata taking, bytes32 marketKey) private view returns (bytes32 orderHash) {
        OspexOrder calldata t = taking.order;
        orderHash = _checkSigned(taking);
        if (s_cancelledOrders[orderHash] || t.nonce < s_minNonces[t.account][marketKey]) {
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

    /// @dev What every listed order must be, in either role: signed by its account, at an admissible price,
    ///      for an admissible stake. Returns the order's hash.
    function _checkSigned(SignedOrder calldata signed) private view returns (bytes32 orderHash) {
        OspexOrder calldata order = signed.order;
        orderHash = _hashOrder(order);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(orderHash, signed.signature);
        if (err != ECDSA.RecoverError.NoError || signer != order.account) {
            revert OspexMatching__BadSignature(orderHash);
        }
        if (order.oddsTick < MIN_ODDS || order.oddsTick > MAX_ODDS) revert OspexMatching__PriceOutOfRange(orderHash);
        if (order.riskAmount == 0 || order.riskAmount % LOT != 0) revert OspexMatching__StakeNotInLots(orderHash);
    }

    /// @dev One leg: the six skip tests in the order of SkipReason, then the fill. Both orders' filled amounts
    ///      are read from storage here, at this leg, so an order listed twice meets at its second entry what
    ///      its first used.
    function _leg(
        IOspexPositions positions,
        OspexOrder calldata t,
        bytes32 takingHash,
        bytes32 marketKey,
        OspexOrder calldata r,
        bytes32 restingHash,
        Tally memory tally
    ) private returns (bool filled, SkipReason reason) {
        if (!_isCourier(r.account, msg.sender)) return (false, SkipReason.NoCourier);
        if (s_cancelledOrders[restingHash] || r.nonce < s_minNonces[r.account][marketKey]) {
            return (false, SkipReason.Cancelled);
        }
        if (block.timestamp >= r.expiry) return (false, SkipReason.Expired);

        uint256 restingFilled = s_filledRisk[restingHash];
        if (restingFilled >= r.riskAmount) return (false, SkipReason.NoRoom);

        uint256 takingFilled = s_filledRisk[takingHash];
        uint256 left = takingFilled >= t.riskAmount ? 0 : t.riskAmount - takingFilled;
        uint256 p = uint256(r.oddsTick) - ODDS_SCALE;
        uint256 lots = (r.riskAmount - restingFilled) / LOT;
        if (left / p < lots) lots = left / p;
        // The minimum, on the taking stake. It holds the resting stake too: a taking stake of LOT units or more
        // is at least one lot of resting stake, and no lots are no taking stake.
        if (lots * p < LOT) return (false, SkipReason.NothingFits);

        uint256 makerRisk = lots * LOT;
        uint256 takerRisk = lots * p;
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
            return (true, SkipReason.NoCourier);
        } catch (bytes memory refusal) {
            if (!_isMakerPullRefused(refusal, r.account, makerRisk)) {
                assembly ("memory-safe") {
                    revert(add(refusal, 0x20), mload(refusal))
                }
            }
            s_filledRisk[restingHash] = restingFilled;
            s_filledRisk[takingHash] = takingFilled;
            return (false, SkipReason.PullRefused);
        }
    }

    /// @dev True only for the positions module's MakerPullRefused carrying this leg's resting account and
    ///      resting stake: 68 bytes, the error's selector, then the two arguments, each compared as a whole
    ///      word. Revert data of any other length, selector, account or amount is not this error.
    function _isMakerPullRefused(bytes memory refusal, address maker, uint256 makerRisk) private pure returns (bool) {
        if (refusal.length != 68) return false;
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
            r.expiry
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
                r.expiry
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
        if (courier == address(0)) revert OspexMatching__ZeroCourier();
        if (s_couriers[msg.sender][courier]) return;
        s_couriers[msg.sender][courier] = true;
        emit CourierRegistered(msg.sender, courier);
        i_ospexCore.emitCoreEvent(EVENT_COURIER_REGISTERED, abi.encode(msg.sender, courier));
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
     * @notice Cancel one order by its hash. Only the order's account calls it.
     * @dev The mark is on the hash of the nine values under this contract's domain. The call checks that the
     *      caller is the address in the order's account field, and nothing else about the order: not a
     *      signature, not its expiry. Cancelling an order again marks the same hash and emits again. A
     *      cancelled order fills no further, in either role: what it filled before the cancel stands.
     *
     *      Refused while a Cross is in progress.
     * @param order The order to cancel
     */
    function cancelOrder(OspexOrder calldata order) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        if (msg.sender != order.account) revert OspexMatching__NotOrderAccount();
        bytes32 orderHash = _hashOrder(order);
        s_cancelledOrders[orderHash] = true;

        emit OrderCancelled(
            orderHash,
            msg.sender,
            order.gameId,
            order.scorer,
            order.lineTicks,
            order.positionType,
            order.oddsTick,
            order.riskAmount,
            order.nonce,
            order.expiry
        );
        i_ospexCore.emitCoreEvent(
            EVENT_ORDER_CANCELLED,
            abi.encode(
                orderHash,
                msg.sender,
                order.gameId,
                order.scorer,
                order.lineTicks,
                order.positionType,
                order.oddsTick,
                order.riskAmount,
                order.nonce,
                order.expiry
            )
        );
    }

    /**
     * @notice Raise the minimum valid nonce for a market, invalidating every order of the caller on it with a
     *         lower nonce.
     * @dev The scope is one market, the three fields a signed order names it by, whether or not a fill has
     *      drawn that market. Per-order cancellation is cancelOrder(). The floor only rises, and the top
     *      value, type(uint256).max, is refused, so the floor reaches max - 1 at most: an order whose nonce is
     *      max - 1 or max is never under a floor, and is cancelled only by cancelOrder(). Both refusals,
     *      a floor that does not rise and the top value, use the one error, NonceMustIncrease. An order whose
     *      nonce is at the floor is live; one under it fills no further, in either role.
     *
     *      Refused while a Cross is in progress.
     * @param gameId The game
     * @param scorer The market contract
     * @param lineTicks The line, scaled by 10
     * @param newMinNonce The new minimum valid nonce: higher than the current one, and not the top value
     */
    function raiseMinNonce(uint256 gameId, address scorer, int32 lineTicks, uint256 newMinNonce) external {
        if (_crossInProgress()) revert OspexMatching__CrossInProgress();
        bytes32 marketKey = keccak256(abi.encode(gameId, scorer, lineTicks));
        if (newMinNonce == type(uint256).max || newMinNonce <= s_minNonces[msg.sender][marketKey]) {
            revert OspexMatching__NonceMustIncrease();
        }
        s_minNonces[msg.sender][marketKey] = newMinNonce;
        emit MinNonceUpdated(msg.sender, gameId, scorer, lineTicks, newMinNonce, marketKey);
        i_ospexCore.emitCoreEvent(
            EVENT_MIN_NONCE_UPDATED, abi.encode(msg.sender, gameId, scorer, lineTicks, newMinNonce, marketKey)
        );
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

    // ──────────────────────────── Internal ─────────────────────────────

    /// @dev Whether `account` has registered `courier`: the one read of the record, behind isCourier and
    ///      behind the Cross's check of its sender against the taking account and each resting account.
    function _isCourier(address account, address courier) private view returns (bool) {
        return s_couriers[account][courier];
    }

    /// @dev Whether a Cross is in progress in this transaction.
    function _crossInProgress() private view returns (bool) {
        return CROSS_IN_PROGRESS_SLOT.asBoolean().tload();
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
                    order.expiry
                )
            )
        );
    }
}
