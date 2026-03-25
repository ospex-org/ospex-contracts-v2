// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OspexCore} from "../core/OspexCore.sol";
import {
    Position,
    PositionType,
    Speculation,
    SpeculationStatus,
    OddsPair,
    WinSide
} from "../core/OspexTypes.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {IContributionModule} from "../interfaces/IContributionModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
    /// @notice Error for insufficient amount remaining
    error PositionModule__InsufficientAmountRemaining(
        uint256 makerAmountRemaining,
        uint256 matchableAmount
    );
    /// @notice Error for odds out of range
    error PositionModule__OddsOutOfRange(uint64 odds);
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
     * @notice Emitted when a position is matched
     * @param speculationId The ID of the speculation
     * @param maker The address of the maker
     * @param taker The address of the taker
     * @param oddsPairId The ID of the odds pair
     * @param makerPositionType The type of position for the maker
     * @param takerPositionType The type of position for the taker
     * @param makerAmount The amount of the maker's position
     * @param takerAmount The amount of the taker's position
     * @param upperOdds The upper odds
     * @param lowerOdds The lower odds
     */
    event PositionMatchedPair(
        uint256 indexed speculationId,
        address indexed maker,
        address indexed taker,
        uint128 oddsPairId,
        PositionType makerPositionType,
        PositionType takerPositionType,
        uint256 makerAmount,
        uint256 takerAmount,
        uint64 upperOdds,
        uint64 lowerOdds
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
     * @param takerAmount The amount of the taker's position
     */
    modifier amountInRange(uint256 takerAmount) {
        ISpeculationModule specModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        );
        if (
            takerAmount < specModule.s_minSpeculationAmount() ||
            takerAmount > specModule.s_maxSpeculationAmount()
        ) {
            revert PositionModule__InvalidAmount();
        }
        _;
    }

    /**
     * @notice Modifier to ensure the odds are in range
     * @param odds The odds of the position
     */
    modifier oddsInRange(uint64 odds) {
        if (odds < MIN_ODDS || odds > MAX_ODDS) {
            revert PositionModule__OddsOutOfRange(odds);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor sets the OspexCore address and token
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
     * @notice Creates a fully matched pair atomically — both sides in a single call
     * @dev Only callable by contracts with MARKET_ROLE (e.g., MatchingModule).
     *      Tokens flow directly from maker/taker wallets to this contract.
     * @param speculationId The ID of the speculation
     * @param odds The odds for the maker's position
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerAmountRemaining The amount the maker has remaining
     * @param taker The address of the taker
     * @param takerAmount The amount the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return makerAmountConsumed The amount that is consumed by the match
     */

    function createMatchedPair(
        uint256 speculationId,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external override nonReentrant returns (uint256) {
        // --- Access control ---
        if (!i_ospexCore.hasMarketRole(msg.sender)) {
            revert PositionModule__UnauthorizedMarket();
        }
        return
            _createMatchedPair(
                speculationId,
                odds,
                makerPositionType,
                maker,
                makerAmountRemaining,
                taker,
                takerAmount,
                makerContributionAmount,
                takerContributionAmount
            );
    }

    /**
     * @notice Creates a fully matched pair atomically — both sides in a single call with a speculation
     * @dev Only callable by contracts with MARKET_ROLE (e.g., MatchingModule).
     *      Tokens flow directly from maker/taker wallets to this contract.
     *      This function unconditionally creates the speculation, so ensure that the caller
     *      has already checked that the speculation does not exist.
     * @param contestId The ID of the contest
     * @param scorer The scorer of the speculation
     * @param theNumber The line/spread/total number
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @param odds The odds for the maker's position
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerAmountRemaining The amount the maker is putting up
     * @param taker The address of the taker
     * @param takerAmount The amount the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return makerAmountConsumed The amount that is consumed by the match
     */
    function createMatchedPairWithSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256 leaderboardId,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external override nonReentrant returns (uint256) {
        // --- Access control ---
        if (!i_ospexCore.hasMarketRole(msg.sender)) {
            revert PositionModule__UnauthorizedMarket();
        }

        ISpeculationModule specModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        );
        // @dev createSpeculationWithUnmatchedPair is a legacy name from SpeculationModule.
        //      The function creates a speculation generically; "UnmatchedPair" in the name
        //      is a misnomer retained to avoid redeploying SpeculationModule for a rename.
        uint256 speculationId = specModule.createSpeculationWithUnmatchedPair(
            contestId,
            scorer,
            theNumber,
            taker,
            leaderboardId
        );
        return
            _createMatchedPair(
                speculationId,
                odds,
                makerPositionType,
                maker,
                makerAmountRemaining,
                taker,
                takerAmount,
                makerContributionAmount,
                takerContributionAmount
            );
    }

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
        if (amount == 0 || amount > fromPos.matchedAmount) {
            revert PositionModule__InvalidAmount();
        }

        // Calculate proportional takerAmount to transfer
        uint256 takerAmountToTransfer = (amount * fromPos.takerAmount) /
            fromPos.matchedAmount;

        fromPos.matchedAmount -= amount;
        fromPos.takerAmount -= takerAmountToTransfer;

        Position storage toPos = s_positions[speculationId][to][oddsPairId][
            positionType
        ];
        if (toPos.poolId == 0) {
            toPos.poolId = oddsPairId;
            toPos.positionType = positionType;
        }
        toPos.matchedAmount += amount;
        toPos.takerAmount += takerAmountToTransfer;
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
     * @notice Claims winnings from a position
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

        // Calculate payout for matched amount
        uint256 payout = _calculatePayout(speculationId, pos);

        // Check if there's anything to claim
        if (pos.matchedAmount == 0 || payout == 0) {
            revert PositionModule__NoPayout();
        }

        // Zero out the position
        pos.matchedAmount = 0;
        pos.takerAmount = 0;
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

    // --- Internal functions ---

    /**
     * @notice Creates a fully matched pair atomically — both sides in a single call
     * @param speculationId The ID of the speculation
     * @param odds The odds for the maker's position
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerAmountRemaining The amount the maker has remaining
     * @param taker The address of the taker
     * @param takerAmount The amount the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return makerAmountConsumed The amount that is consumed by the match
     */
    function _createMatchedPair(
        uint256 speculationId,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    )
        internal
        speculationOpen(speculationId)
        oddsInRange(odds)
        amountInRange(takerAmount)
        returns (uint256)
    {
        // --- Odds pair ID logic ---
        (
            uint128 oddsPairId,
            uint64 upperOdds,
            uint64 lowerOdds
        ) = _getOrCreateOddsPairId(odds, makerPositionType);

        // --- Determine if the maker has adequate amount remaining ---
        uint64 relevantOdds = makerPositionType == PositionType.Upper
            ? upperOdds
            : lowerOdds;
        uint256 matchableAmount = (makerAmountRemaining *
            (relevantOdds - ODDS_PRECISION)) / ODDS_PRECISION;

        if (matchableAmount < takerAmount) {
            revert PositionModule__InsufficientAmountRemaining(
                makerAmountRemaining,
                matchableAmount
            );
        }

        // Calculate how much of maker's position this match consumes
        uint256 makerAmountConsumed = (takerAmount *
            (
                makerPositionType == PositionType.Upper
                    ? lowerOdds - ODDS_PRECISION
                    : upperOdds - ODDS_PRECISION
            )) / ODDS_PRECISION;

        // --- Taker position type---
        PositionType takerPositionType = makerPositionType == PositionType.Upper
            ? PositionType.Lower
            : PositionType.Upper;

        // --- Maker position ---
        Position storage makerPos = s_positions[speculationId][maker][
            oddsPairId
        ][makerPositionType];
        if (makerPos.poolId == 0) {
            makerPos.poolId = oddsPairId;
            makerPos.positionType = makerPositionType;
            makerPos.claimed = false;
        }
        makerPos.matchedAmount += makerAmountConsumed;
        makerPos.takerAmount += takerAmount;

        // --- Taker position ---
        Position storage takerPos = s_positions[speculationId][taker][
            oddsPairId
        ][takerPositionType];
        if (takerPos.poolId == 0) {
            takerPos.poolId = oddsPairId;
            takerPos.positionType = takerPositionType;
            takerPos.claimed = false;
        }
        takerPos.matchedAmount += takerAmount;
        takerPos.takerAmount += makerAmountConsumed;

        // --- Token transfer ---
        i_token.safeTransferFrom(maker, address(this), makerAmountConsumed);
        i_token.safeTransferFrom(taker, address(this), takerAmount);

        // --- Contribution handling ---
        IContributionModule contributionModule = IContributionModule(
            _getModule(keccak256("CONTRIBUTION_MODULE"))
        );
        contributionModule.handleContribution(
            speculationId,
            maker,
            oddsPairId,
            makerPositionType,
            makerContributionAmount
        );
        contributionModule.handleContribution(
            speculationId,
            taker,
            oddsPairId,
            takerPositionType,
            takerContributionAmount
        );

        // --- Event ---
        emit PositionMatchedPair(
            speculationId,
            maker,
            taker,
            oddsPairId,
            makerPositionType,
            takerPositionType,
            makerAmountConsumed,
            takerAmount,
            upperOdds,
            lowerOdds
        );
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_MATCHED_PAIR"),
            abi.encode(
                speculationId,
                maker,
                taker,
                oddsPairId,
                makerPositionType,
                takerPositionType,
                makerAmountConsumed,
                takerAmount,
                upperOdds,
                lowerOdds
            )
        );
        return makerAmountConsumed;
    }

    /**
     * @notice Gets or creates an odds pair ID
     * @param odds The odds to get or create
     * @param positionType The type of position
     */
    function _getOrCreateOddsPairId(
        uint64 odds,
        PositionType positionType
    ) internal returns (uint128 oddsPairId, uint64 upperOdds, uint64 lowerOdds) {
        uint64 normalizedOdds = roundOddsToNearestIncrement(odds);
        uint64 inverseOdds = calculateAndRoundInverseOdds(normalizedOdds);
        uint16 oddsIndex = uint16((normalizedOdds - MIN_ODDS) / ODDS_INCREMENT);
        uint128 baseOddsPairId = uint128(oddsIndex);
        // Apply offset for Lower (home/under) positions
        oddsPairId = (positionType == PositionType.Lower)
            ? baseOddsPairId + 10000
            : baseOddsPairId;
        OddsPair storage oddsPair = s_oddsPairs[oddsPairId];
        // Check if pair exists for this speculation/oddsPairId
        if (oddsPair.oddsPairId == 0) {
            // Store original and inverse odds
            s_originalRequestedOdds[oddsPairId] = normalizedOdds;
            s_inverseCalculatedOdds[oddsPairId] = inverseOdds;
            oddsPair.oddsPairId = oddsPairId;
            oddsPair.upperOdds = (positionType == PositionType.Upper)
                ? normalizedOdds
                : inverseOdds;
            oddsPair.lowerOdds = (positionType == PositionType.Upper)
                ? inverseOdds
                : normalizedOdds;
        }
        return (oddsPairId, oddsPair.upperOdds, oddsPair.lowerOdds);
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
     * @param position The position to calculate the payout for
     */
    function _calculatePayout(
        uint256 speculationId,
        Position memory position
    ) internal view returns (uint256) {
        Speculation memory speculation = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).getSpeculation(speculationId);

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
            return position.matchedAmount + position.takerAmount;
        }
        return 0; // Losing position gets nothing
    }

    // --- Helper Function for Module Lookups ---
    /**
     * @notice Gets the module address
     * @param moduleType The type of module
     */
    function _getModule(
        bytes32 moduleType
    ) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) {
            revert PositionModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
