// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OspexCore} from "../core/OspexCore.sol";
import {Position, PositionType, Speculation, SpeculationStatus, OddsPair, WinSide} from "../core/OspexTypes.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {IContributionModule} from "../interfaces/IContributionModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PositionModule
 * @notice Handles user positions: creation, matching, claiming, etc. for Ospex protocol
 * @dev All business logic for positions is implemented here. Uses hybrid event emission pattern.
 */
contract PositionModule is IPositionModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Error for invalid address
    error PositionModule__InvalidAddress();
    /// @notice Error for invalid amount
    error PositionModule__InvalidAmount();
    /// @notice Error for invalid unmatched expiry
    error PositionModule__InvalidUnmatchedExpiry();
    /// @notice Error for position already exists
    error PositionModule__PositionAlreadyExists();
    /// @notice Error for odds out of range
    error PositionModule__OddsOutOfRange(uint64 odds);
    /// @notice Error for insufficient unmatched amount
    error PositionModule__InsufficientUnmatchedAmount(
        uint256 requested,
        uint256 available
    );
    /// @notice Error for unmatched position expired
    error PositionModule__UnmatchedExpired();
    /// @notice Error for unauthorized market
    error PositionModule__UnauthorizedMarket();
    /// @notice Error for speculation not settled
    error PositionModule__NotSettled();
    /// @notice Error for already claimed
    error PositionModule__AlreadyClaimed();
    /// @notice Error for speculation not open
    error PositionModule__SpeculationNotOpen();
    /// @notice Error for no payout
    error PositionModule__NoPayout();
    /// @notice Error for position does not exist
    error PositionModule__PositionDoesNotExist();
    /// @notice Error for array length mismatch
    error PositionModule__ArrayLengthMismatch();
    /// @notice Error for module not set
    error PositionModule__ModuleNotSet(bytes32 moduleType);

    // --- Storage ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The ERC20 token
    IERC20 public immutable i_token;
    /// @notice The odds precision
    uint64 public constant ODDS_PRECISION = 10_000_000; // 1e7
    /// @notice The odds increment
    uint64 public constant ODDS_INCREMENT = 100_000; // 0.01
    /// @notice The minimum odds
    uint64 public constant MIN_ODDS = 10_100_000; // 1.01 (example, can be set via function)
    /// @notice The maximum odds
    uint64 public constant MAX_ODDS = 1_010_000_000; // 101.00 (example, can be set via function)

    // Positions: speculationId => user => oddsPairId => positionType => Position
    mapping(uint256 => mapping(address => mapping(uint128 => mapping(PositionType => Position))))
        public s_positions;

    // --- OddsPair Storage ---
    // oddsPairId => OddsPair
    mapping(uint128 => OddsPair) public s_oddsPairs;
    // oddsPairId => original requested odds
    mapping(uint128 => uint64) public s_originalRequestedOdds;
    // oddsPairId => inverse calculated odds
    mapping(uint128 => uint64) public s_inverseCalculatedOdds;

    // --- Events (module-local) ---
    /**
     * @notice Emitted when a new unmatched pair is created
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param unmatchedExpiry The expiry of the unmatched position
     * @param positionType The type of position
     * @param amount The amount of the position
     */
    event PositionCreated(
        uint256 indexed speculationId,
        address indexed user,
        uint128 oddsPairId,
        uint32 unmatchedExpiry,
        PositionType positionType,
        uint256 amount
    );

    /**
     * @notice Emitted when an unmatched pair is adjusted
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param amount The amount of the position
     */
    event PositionAdjusted(
        uint256 indexed speculationId,
        address indexed user,
        uint128 oddsPairId,
        uint32 unmatchedExpiry,
        PositionType positionType,
        int256 amount
    );

    /**
     * @notice Emitted when an unmatched pair is matched
     * @param speculationId The ID of the speculation
     * @param maker The address of the maker
     * @param oddsPairId The ID of the odds pair
     * @param makerPositionType The type of position
     * @param taker The address of the taker
     * @param amount The amount of the position
     */
    event PositionMatched(
        uint256 indexed speculationId,
        address indexed maker,
        uint128 oddsPairId,
        PositionType makerPositionType,
        address indexed taker,
        uint256 amount
    );

    /**
     * @notice Emitted when a position is transferred
     * @param speculationId The ID of the speculation
     * @param from The address of the from user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param to The address of the to user
     * @param amount The amount of the position
     */
    event PositionTransferred(
        uint256 indexed speculationId,
        address indexed from,
        uint128 oddsPairId,
        PositionType positionType,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Emitted when a position is claimed
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param payout The payout amount
     */
    event PositionClaimed(
        uint256 indexed speculationId,
        address indexed user,
        uint128 oddsPairId,
        PositionType positionType,
        uint256 payout
    );

    // --- Modifiers ---
    /**
     * @notice Modifier to ensure the speculation is open
     * @param speculationId The ID of the speculation
     */
    modifier speculationOpen(uint256 speculationId) {
        Speculation memory spec = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);
        if (spec.speculationStatus != SpeculationStatus.Open) {
            revert PositionModule__SpeculationNotOpen();
        }
        _;
    }

    /**
     * @notice Modifier to ensure the amount is in range
     * @param amount The amount of the position
     */
    modifier amountInRange(uint256 amount) {
        ISpeculationModule specModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        );
        if (
            amount < specModule.s_minSpeculationAmount() ||
            amount > specModule.s_maxSpeculationAmount()
        ) {
            revert PositionModule__InvalidAmount();
        }
        _;
    }

    modifier unmatchedExpiryInFuture(uint32 unmatchedExpiry) {
        if (unmatchedExpiry != 0 && unmatchedExpiry < block.timestamp) {
            revert PositionModule__InvalidUnmatchedExpiry();
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor sets the OspexCore address, token, and speculation module
     * @param _ospexCore The address of the OspexCore contract
     * @param _token The address of the ERC20 token
     */
    constructor(address _ospexCore, address _token) {
        if (_ospexCore == address(0) || _token == address(0)) {
            revert PositionModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(_ospexCore);
        i_token = IERC20(_token);
    }

    // --- IModule ---
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("POSITION_MODULE");
    }

    // --- IPositionModule ---

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Creates a new unmatched pair
     * @param speculationId The ID of the speculation
     * @param odds The odds of the position
     * @param unmatchedExpiry The expiry of the unmatched position
     * @param positionType The type of position
     * @param amount The amount of the position
     * @param contributionAmount The amount of the contribution
     */
    function createUnmatchedPair(
        uint256 speculationId,
        uint64 odds,
        uint32 unmatchedExpiry,
        PositionType positionType,
        uint256 amount,
        uint256 contributionAmount
    )
        external
        override
        nonReentrant
        speculationOpen(speculationId)
        amountInRange(amount)
        unmatchedExpiryInFuture(unmatchedExpiry)
    {
        // --- Validation ---
        // Check odds are in range
        if (odds < MIN_ODDS || odds > MAX_ODDS) {
            revert PositionModule__OddsOutOfRange(odds);
        }
        // --- Odds pair ID logic ---
        uint128 oddsPairId = getOrCreateOddsPairId(odds, positionType);
        // --- Position storage ---
        Position storage pos = s_positions[speculationId][msg.sender][
            oddsPairId
        ][positionType];
        // --- Check if position already exists ---
        if (pos.poolId != 0) {
            revert PositionModule__PositionAlreadyExists();
        }
        // --- Token transfer ---
        i_token.safeTransferFrom(msg.sender, address(this), amount);
        // --- Position setup ---
        pos.poolId = oddsPairId;
        pos.unmatchedExpiry = unmatchedExpiry;
        pos.matchedAmount = 0;
        pos.unmatchedAmount = amount;
        pos.positionType = positionType;
        pos.claimed = false;
        // --- Contribution handling ---
        IContributionModule(_getModule(keccak256("CONTRIBUTION_MODULE")))
            .handleContribution(
                speculationId,
                msg.sender,
                oddsPairId,
                positionType,
                contributionAmount
            );
        // --- Emit events ---
        emit PositionCreated(
            speculationId,
            msg.sender,
            oddsPairId,
            unmatchedExpiry,
            positionType,
            amount
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_CREATED"),
            abi.encode(
                speculationId,
                msg.sender,
                oddsPairId,
                unmatchedExpiry,
                positionType,
                amount
            )
        );
    }

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Adjusts an unmatched pair
     * @param speculationId The ID of the speculation
     * @param oddsPairId The ID of the odds pair
     * @param newUnmatchedExpiry The new expiry of the unmatched position
     * @param positionType The type of position
     * @param amount The amount of the position
     * @param contributionAmount The amount of the contribution
     */
    function adjustUnmatchedPair(
        uint256 speculationId,
        uint128 oddsPairId,
        uint32 newUnmatchedExpiry,
        PositionType positionType,
        int256 amount,
        uint256 contributionAmount
    )
        external
        override
        nonReentrant
        speculationOpen(speculationId)
        unmatchedExpiryInFuture(newUnmatchedExpiry)
    {
        // Get position
        Position storage pos = _getPosition(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType
        );

        // Handle contribution if any
        IContributionModule(_getModule(keccak256("CONTRIBUTION_MODULE")))
            .handleContribution(
                speculationId,
                msg.sender,
                oddsPairId,
                positionType,
                contributionAmount
            );

        // Update unmatched expiry if provided
        if (
            newUnmatchedExpiry != 0 && newUnmatchedExpiry != pos.unmatchedExpiry
        ) {
            pos.unmatchedExpiry = newUnmatchedExpiry;
        }

        // Adjustment logic
        if (amount > 0) {
            uint256 addAmount = uint256(amount);
            if (
                pos.unmatchedAmount + addAmount >
                ISpeculationModule(_getModule(keccak256("SPECULATION_MODULE")))
                    .s_maxSpeculationAmount()
            ) {
                revert PositionModule__InvalidAmount();
            }
            i_token.safeTransferFrom(msg.sender, address(this), addAmount);
            pos.unmatchedAmount += addAmount;
        } else if (amount < 0) {
            uint256 reduceAmount = uint256(-amount);
            if (reduceAmount > pos.unmatchedAmount) {
                revert PositionModule__InvalidAmount();
            }
            pos.unmatchedAmount -= reduceAmount;
            i_token.safeTransfer(msg.sender, reduceAmount);
        }

        emit PositionAdjusted(
            speculationId,
            msg.sender,
            oddsPairId,
            newUnmatchedExpiry,
            positionType,
            amount
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_ADJUSTED"),
            abi.encode(
                speculationId,
                msg.sender,
                oddsPairId,
                newUnmatchedExpiry,
                positionType,
                amount
            )
        );
    }

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Completes an unmatched pair
     * @param speculationId The ID of the speculation
     * @param maker The address of the maker
     * @param oddsPairId The ID of the odds pair
     * @param makerPositionType The type of position
     * @param amount The amount of the position
     */
    function completeUnmatchedPair(
        uint256 speculationId,
        address maker,
        uint128 oddsPairId,
        PositionType makerPositionType,
        uint256 amount
    ) external override nonReentrant {
        _completeUnmatchedPair(
            speculationId,
            maker,
            oddsPairId,
            makerPositionType,
            amount,
            msg.sender
        );
    }

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Completes an unmatched pair batch
     * @param speculationId The ID of the speculation
     * @param makers The addresses of the makers
     * @param oddsPairIds The IDs of the odds pairs
     * @param makerPositionTypes The types of positions
     * @param amounts The amounts of the positions
     */
    function completeUnmatchedPairBatch(
        uint256 speculationId,
        address[] calldata makers,
        uint128[] calldata oddsPairIds,
        PositionType[] calldata makerPositionTypes,
        uint256[] calldata amounts
    ) external override nonReentrant {
        if (
            makers.length != oddsPairIds.length ||
            makers.length != makerPositionTypes.length ||
            makers.length != amounts.length
        ) {
            revert PositionModule__ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < makers.length; i++) {
            _completeUnmatchedPair(
                speculationId,
                makers[i],
                oddsPairIds[i],
                makerPositionTypes[i],
                amounts[i],
                msg.sender
            );
        }
    }

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Transfers a position
     * @param speculationId The ID of the speculation
     * @param from The address of the from user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     * @param to The address of the to user
     * @param amount The amount of the position
     */
    function transferPosition(
        uint256 speculationId,
        address from,
        uint128 oddsPairId,
        PositionType positionType,
        address to,
        uint256 amount
    ) external override speculationOpen(speculationId) {
        // Centralized access control: only approved market contracts can call
        if (!i_ospexCore.hasMarketRole(msg.sender)) {
            revert PositionModule__UnauthorizedMarket();
        }
        // Get the position being transferred from
        Position storage fromPos = _getPosition(
            speculationId,
            from,
            oddsPairId,
            positionType
        );
        if (amount > fromPos.matchedAmount) {
            revert PositionModule__InvalidAmount();
        }

        fromPos.matchedAmount -= amount;
        Position storage toPos = s_positions[speculationId][to][oddsPairId][
            positionType
        ];
        if (toPos.poolId == 0) {
            toPos.poolId = oddsPairId;
            toPos.positionType = positionType;
        }
        toPos.matchedAmount += amount;
        toPos.unmatchedAmount = 0;
        toPos.claimed = false;

        emit PositionTransferred(
            speculationId,
            from,
            oddsPairId,
            positionType,
            to,
            amount
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_TRANSFERRED"),
            abi.encode(
                speculationId,
                from,
                oddsPairId,
                positionType,
                to,
                amount
            )
        );
    }

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Claims a position
     * @param speculationId The ID of the speculation
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     */
    function claimPosition(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType
    ) external override nonReentrant {
        // Get speculation and ensure it's closed
        Speculation memory speculation = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);
        if (speculation.speculationStatus != SpeculationStatus.Closed) {
            revert PositionModule__NotSettled();
        }

        // Get the position
        Position storage pos = _getPosition(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType
        );

        // Check if there's anything to claim
        if (pos.matchedAmount == 0 && pos.unmatchedAmount == 0) {
            revert PositionModule__NoPayout();
        }

        // Calculate payout for matched amount
        uint256 payout = calculatePayout(speculationId, oddsPairId, pos);

        // Add any unmatched amount to the payout
        payout += pos.unmatchedAmount;

        // Zero out the position
        pos.unmatchedAmount = 0;
        pos.matchedAmount = 0;
        pos.claimed = true;

        // Transfer total payout
        i_token.safeTransfer(msg.sender, payout);

        // Emit module-local event
        emit PositionClaimed(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType,
            payout
        );
        // Emit core event
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_CLAIMED"),
            abi.encode(
                speculationId,
                msg.sender,
                oddsPairId,
                positionType,
                payout
            )
        );
    }

    /**
     * @inheritdoc IPositionModule
     */

    /**
     * @notice Gets a position
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     */
    function getPosition(
        uint256 speculationId,
        address user,
        uint128 oddsPairId,
        PositionType positionType
    ) external view override returns (Position memory position) {
        position = s_positions[speculationId][user][oddsPairId][positionType];
    }

    /**
     * @notice Gets an odds pair
     * @param oddsPairId The ID of the odds pair
     */
    function getOddsPair(
        uint128 oddsPairId
    ) public view returns (OddsPair memory) {
        return s_oddsPairs[oddsPairId];
    }

    /**
     * @notice Gets the original odds
     * @param oddsPairId The ID of the odds pair
     */
    function getOriginalOdds(uint128 oddsPairId) public view returns (uint64) {
        return s_originalRequestedOdds[oddsPairId];
    }

    /**
     * @notice Gets the inverse odds
     * @param oddsPairId The ID of the odds pair
     */
    function getInverseOdds(uint128 oddsPairId) public view returns (uint64) {
        return s_inverseCalculatedOdds[oddsPairId];
    }

    // --- Odds Logic ---
    /**
     * @notice Rounds odds to the nearest increment
     * @param odds The odds to round
     */
    function roundOddsToNearestIncrement(
        uint64 odds
    ) public pure returns (uint64) {
        if (odds < MIN_ODDS) return MIN_ODDS;
        if (odds > MAX_ODDS) return MAX_ODDS;
        uint64 remainder = odds % ODDS_INCREMENT;
        if (remainder >= ODDS_INCREMENT / 2) {
            return odds + (ODDS_INCREMENT - remainder);
        } else {
            return odds - remainder;
        }
    }

    /**
     * @notice Calculates and rounds inverse odds
     * @param odds The odds to calculate and round
     */
    function calculateAndRoundInverseOdds(
        uint64 odds
    ) public pure returns (uint64) {
        // First calculate the exact inverse
        uint64 numerator = ODDS_PRECISION * ODDS_PRECISION;
        uint64 denominator = odds - ODDS_PRECISION;
        uint64 exactInverse = uint64(
            (numerator / denominator) + ODDS_PRECISION
        );
        // Then round to nearest valid increment
        return roundOddsToNearestIncrement(exactInverse);
    }

    /**
     * @notice Gets or creates an odds pair ID
     * @param odds The odds to get or create
     * @param positionType The type of position
     */
    function getOrCreateOddsPairId(
        uint64 odds,
        PositionType positionType
    ) public returns (uint128 oddsPairId) {
        uint64 normalizedOdds = roundOddsToNearestIncrement(odds);
        uint64 inverseOdds = calculateAndRoundInverseOdds(normalizedOdds);
        uint64 smallerOdds = normalizedOdds < inverseOdds
            ? normalizedOdds
            : inverseOdds;
        uint16 oddsIndex = uint16((smallerOdds - MIN_ODDS) / ODDS_INCREMENT);
        uint128 baseOddsPairId = uint128(oddsIndex);
        // Apply offset for Lower (home/under) positions
        oddsPairId = (positionType == PositionType.Lower)
            ? baseOddsPairId + 10000
            : baseOddsPairId;
        // Check if pair exists for this speculation/oddsPairId
        if (s_oddsPairs[oddsPairId].oddsPairId == 0) {
            // Store original and inverse odds
            s_originalRequestedOdds[oddsPairId] = normalizedOdds;
            s_inverseCalculatedOdds[oddsPairId] = inverseOdds;
            OddsPair memory oddsPair = OddsPair({
                oddsPairId: oddsPairId,
                upperOdds: (positionType == PositionType.Upper)
                    ? normalizedOdds
                    : inverseOdds,
                lowerOdds: (positionType == PositionType.Upper)
                    ? inverseOdds
                    : normalizedOdds
            });
            s_oddsPairs[oddsPairId] = oddsPair;
        }
        return oddsPairId;
    }

    // --- Internal complete unmatched pair ---
    /**
     * @notice Completes an unmatched pair
     * @param speculationId The ID of the speculation
     * @param maker The address of the maker
     * @param oddsPairId The ID of the odds pair
     * @param makerPositionType The type of position
     * @param amount The amount of the position
     */
    function _completeUnmatchedPair(
        uint256 speculationId,
        address maker,
        uint128 oddsPairId,
        PositionType makerPositionType,
        uint256 amount,
        address taker
    ) internal speculationOpen(speculationId) amountInRange(amount) {
        // Get maker's position (base or repeat)
        Position storage makerPos = _getPosition(
            speculationId,
            maker,
            oddsPairId,
            makerPositionType
        );

        // Check if unmatched position has expired
        if (
            makerPos.unmatchedExpiry != 0 &&
            makerPos.unmatchedExpiry < block.timestamp
        ) {
            revert PositionModule__UnmatchedExpired();
        }

        // Get the odds pair
        OddsPair memory oddsPair = getOddsPair(oddsPairId);

        // Calculate how much can be matched
        uint64 relevantOdds = makerPos.positionType == PositionType.Upper
            ? oddsPair.upperOdds
            : oddsPair.lowerOdds;
        uint256 matchableAmount = (makerPos.unmatchedAmount *
            (relevantOdds - ODDS_PRECISION)) / ODDS_PRECISION;

        // Validate maker's position
        if (matchableAmount < amount) {
            revert PositionModule__InsufficientUnmatchedAmount(
                amount,
                matchableAmount
            );
        }

        // Transfer tokens from taker
        i_token.safeTransferFrom(taker, address(this), amount);

        // Calculate how much of maker's position this match consumes
        uint256 makerAmountConsumed = (amount *
            (
                makerPos.positionType == PositionType.Upper
                    ? oddsPair.lowerOdds - ODDS_PRECISION
                    : oddsPair.upperOdds - ODDS_PRECISION
            )) / ODDS_PRECISION;

        // Update maker's position
        makerPos.matchedAmount += makerAmountConsumed;
        makerPos.unmatchedAmount -= makerAmountConsumed;

        // Determine taker position type
        PositionType takerPositionType = makerPositionType == PositionType.Upper
            ? PositionType.Lower
            : PositionType.Upper;

        // Check if taker already has a position at this speculationId/oddsPairId/positionType
        Position storage takerPos = s_positions[speculationId][taker][
            oddsPairId
        ][takerPositionType];
        if (takerPos.poolId == 0) {
            takerPos.poolId = oddsPairId;
            takerPos.positionType = takerPositionType;
        }
        takerPos.matchedAmount += amount;
        takerPos.unmatchedAmount = 0;
        takerPos.claimed = false;

        emit PositionMatched(
            speculationId,
            maker,
            oddsPairId,
            makerPositionType,
            taker,
            amount
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_MATCHED"),
            abi.encode(
                speculationId,
                maker,
                oddsPairId,
                makerPositionType,
                taker,
                amount
            )
        );
    }

    // --- Internal position getter with validation (v2-style) ---
    /**
     * @notice Gets a position
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param oddsPairId The ID of the odds pair
     * @param positionType The type of position
     */
    function _getPosition(
        uint256 speculationId,
        address user,
        uint128 oddsPairId,
        PositionType positionType
    ) internal view returns (Position storage position) {
        position = s_positions[speculationId][user][oddsPairId][positionType];
        if (position.poolId == 0) {
            revert PositionModule__PositionDoesNotExist();
        }
        if (position.claimed) {
            revert PositionModule__AlreadyClaimed();
        }
        return position;
    }

    // --- Internal payout calculation helper ---
    /**
     * @notice Calculates the payout for a position
     * @param speculationId The ID of the speculation
     * @param oddsPairId The ID of the odds pair
     * @param position The position to calculate the payout for
     */
    function calculatePayout(
        uint256 speculationId,
        uint128 oddsPairId,
        Position memory position
    ) internal view returns (uint256) {
        Speculation memory speculation = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);
        OddsPair memory oddsPair = getOddsPair(oddsPairId);

        // Handle special cases first
        if (
            speculation.winSide == WinSide.Push ||
            speculation.winSide == WinSide.Void ||
            speculation.winSide == WinSide.Forfeit
        ) {
            return position.matchedAmount; // Return original stake
        }

        // Calculate payout based on position type and odds
        bool isWinner = ((position.positionType == PositionType.Upper &&
            (speculation.winSide == WinSide.Away ||
                speculation.winSide == WinSide.Over)) ||
            (position.positionType == PositionType.Lower &&
                (speculation.winSide == WinSide.Home ||
                    speculation.winSide == WinSide.Under)));

        if (isWinner) {
            uint64 odds = position.positionType == PositionType.Upper
                ? oddsPair.upperOdds
                : oddsPair.lowerOdds;
            return (position.matchedAmount * odds) / ODDS_PRECISION;
        }
        return 0; // Losing position gets nothing
    }

    // --- Helper Function for Module Lookups ---
    /**
     * @notice Gets the module address
     * @param moduleType The type of module
     */
    function _getModule(bytes32 moduleType) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) {
            revert PositionModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
