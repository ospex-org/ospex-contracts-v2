// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OspexCore} from "../core/OspexCore.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {PositionType} from "../core/OspexTypes.sol";
import {IModule} from "../interfaces/IModule.sol";

/**
 * @title MatchingModule
 * @notice Verifies EIP-712 signed commitments and executes atomic matches via PositionModule.
 * @dev This contract never custodies funds. USDC flows directly from maker/taker wallets
 *      to the PositionModule via safeTransferFrom. Both parties must approve the PositionModule
 *      contract for USDC spending, NOT this contract.
 *
 *      The MatchingModule must be registered as MATCHING_MODULE in OspexCore.
 *      PositionModule.recordFill restricts callers to the registered MATCHING_MODULE address.
 */
contract MatchingModule is IModule, EIP712, ReentrancyGuard {
    // --- Errors ---
    /// @notice Commitment signature is invalid
    error MatchingModule__InvalidSignature();
    /// @notice Commitment odds are out of range
    error MatchingModule__OddsOutOfRange(uint16 oddsTick);
    /// @notice Commitment has expired
    error MatchingModule__CommitmentExpired();
    /// @notice Commitment nonce is below the minimum valid nonce for this speculation
    error MatchingModule__NonceTooLow();
    /// @notice Commitment has been individually cancelled
    error MatchingModule__CommitmentCancelled();
    /// @notice Lot size leaves remainder which makes it invalid
    error MatchingModule__InvalidLotSize();
    /// @notice Maker address cannot be zero
    error MatchingModule__InvalidMakerAddress();
    /// @notice Taker amount is zero
    error MatchingModule__InvalidTakerDesiredRisk();
    /// @notice Maker does not have adequate risk available for taker
    error MatchingModule__InvalidFillMakerRisk();
    /// @notice Only the commitment maker can cancel their own commitment
    error MatchingModule__NotCommitmentMaker();
    /// @notice New minimum nonce must be higher than current
    error MatchingModule__NonceMustIncrease();
    /// @notice Module addresses cannot be zero
    error MatchingModule__InvalidAddress();
    /// @notice Commitment is fully filled
    error MatchingModule__CommitmentFullyFilled();
    /// @notice Error for module not set
    error MatchingModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Contest has already been scored (status is Scored or ScoredManually)
    error MatchingModule__ContestAlreadyScored();

    // --- Events ---
    /// @notice Emitted when a commitment is matched (fully or partially)
    event CommitmentMatched(
        bytes32 indexed commitmentHash,
        address indexed maker,
        address indexed taker,
        uint256 contestId,
        uint256 speculationId,
        PositionType makerPositionType,
        uint16 oddsTick,
        uint256 makerProfitAmount,
        uint256 takerProfitAmount
    );

    /// @notice Emitted when a single commitment is cancelled by its maker
    event CommitmentCancelled(
        bytes32 indexed commitmentHash,
        address indexed maker
    );

    /// @notice Emitted when a maker raises their minimum nonce for a speculation
    event MinNonceUpdated(
        address indexed maker,
        bytes32 indexed speculationKey,
        uint256 newMinNonce
    );

    // --- Constants ---
    /// @notice EIP-712 typehash for the OspexCommitment struct
    bytes32 public constant COMMITMENT_TYPEHASH =
        keccak256(
            "OspexCommitment("
            "address maker,"
            "uint256 contestId,"
            "address scorer,"
            "int32 lineTicks,"
            "uint8 positionType,"
            "uint16 oddsTick,"
            "uint256 riskAmount,"
            "uint256 contributionAmount,"
            "uint256 nonce,"
            "uint256 expiry"
            ")"
        );

    // --- Immutables ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The odds precision
    uint16 public constant ODDS_SCALE = 100;
    /// @notice The minimum odds
    uint16 public constant MIN_ODDS = 101; // 1.01
    /// @notice The maximum odds
    uint16 public constant MAX_ODDS = 10100; // 101.00

    // --- Storage ---
    /// @notice Per-speculation minimum valid nonce: maker => speculationKey => minNonce
    mapping(address => mapping(bytes32 => uint256)) public s_minNonces;

    /// @notice Filled risk per commitment hash (for partial fills)
    mapping(bytes32 => uint256) public s_filledRisk;

    /// @notice Individually cancelled commitment hashes
    mapping(bytes32 => bool) public s_cancelledCommitments;

    /// @notice Tracks whether the maker contribution has been charged for a commitment
    mapping(bytes32 => bool) public s_contributionCharged;

    // --- Structs ---
    /**
     * @notice Represents a signed commitment from a maker to take a position
     * @param maker The maker's wallet address (recovered from signature)
     * @param contestId The contest to bet on
     * @param scorer The scorer of the speculation
     * @param lineTicks The line/spread/total number (10x)
     * @param positionType 0 = Upper (away/over), 1 = Lower (home/under)
     * @param oddsTick Maker's quoted price, as an integer (193 = 1.93 odds)
     * @param riskAmount Risk amount in USDC maker will commit (6 decimals)
     * @param contributionAmount The amount of the optional contribution (USDC, 6 decimals)
     * @param nonce Invalidation threshold (NOT a unique order ID). Multiple commitments
     *              on the same speculation may share the same nonce. When the maker calls
     *              raiseMinNonce(), all commitments with nonce < newMinNonce are invalidated.
     *              This may be viewed as a generation counter, not a sequence number.
     * @param expiry Unix timestamp after which this commitment is invalid
     */
    struct OspexCommitment {
        address maker;
        uint256 contestId;
        address scorer;
        int32 lineTicks;
        PositionType positionType;
        uint16 oddsTick;
        uint256 riskAmount;
        uint256 contributionAmount;
        uint256 nonce;
        uint256 expiry;
    }

    /**
     * @notice Modifier to ensure the odds are in range
     * @param oddsTick The odds of the position
     */
    modifier oddsInRange(uint16 oddsTick) {
        if (oddsTick < MIN_ODDS || oddsTick > MAX_ODDS) {
            revert MatchingModule__OddsOutOfRange(oddsTick);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor sets the OspexCore address and version for EIP-712
     * @param _ospexCore The address of the OspexCore contract
     */
    constructor(address _ospexCore) EIP712("Ospex", "1") {
        if (_ospexCore == address(0)) {
            revert MatchingModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(_ospexCore);
    }

    // --- IModule ---
    function getModuleType() external pure override returns (bytes32) {
        return keccak256("MATCHING_MODULE");
    }

    // --- External Functions ---

    /**
     * @notice Match against a signed commitment, creating the speculation if it doesn't exist
     * @dev The taker is msg.sender. Both maker and taker must have approved the
     *      PositionModule contract for USDC spending.
     *      This function reverts if fillMakerRisk exceeds remaining capacity — it does
     *      not auto-clip to the remainder. Off-chain callers must read s_filledRisk and
     *      size takerDesiredRisk accordingly. This is intentional: revert-or-exact-fill
     *      prevents dust positions from partial remainders at unintended economics.
     *      Self-matching (maker == msg.sender) is intentionally allowed.
     *      If volume-based incentives are added in the future, wash-trade prevention
     *      will need to be enforced at the incentive/leaderboard layer, not here.
     * @param commitment The maker's signed commitment
     * @param signature The EIP-712 signature over the commitment
     * @param takerDesiredRisk The amount of risk the taker wants to fill (in USDC, 6 decimals)
     *                         Actual fill may be slightly less due to lot-size rounding on the maker side
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @param takerContributionAmount The taker's contribution amount
     */
    function matchCommitment(
        OspexCommitment calldata commitment,
        bytes calldata signature,
        uint256 takerDesiredRisk,
        uint256 leaderboardId,
        uint256 takerContributionAmount
    ) external nonReentrant oddsInRange(commitment.oddsTick) {
        // --- Validate amount ---
        if (takerDesiredRisk == 0) {
            revert MatchingModule__InvalidTakerDesiredRisk();
        }

        // --- Check if contest has been scored ---
        if (
            IContestModule(_getModule(keccak256("CONTEST_MODULE")))
                .isContestScored(commitment.contestId)
        ) {
            revert MatchingModule__ContestAlreadyScored();
        }

        // --- Validate commitment ---
        bytes32 commitmentHash = _validateCommitment(commitment, signature);

        // --- Calculate maker amount of risk remaining ---
        uint256 makerRiskRemaining = commitment.riskAmount -
            s_filledRisk[commitmentHash];
        if (makerRiskRemaining == 0) {
            revert MatchingModule__CommitmentFullyFilled();
        }

        uint256 profitTicks = uint256(commitment.oddsTick - ODDS_SCALE);
        uint256 rawFillMakerRisk = (takerDesiredRisk *
            uint256(ODDS_SCALE) +
            profitTicks -
            1) / profitTicks;
        uint256 fillMakerRisk = rawFillMakerRisk -
            (rawFillMakerRisk % ODDS_SCALE);

        if (fillMakerRisk == 0 || fillMakerRisk > makerRiskRemaining) {
            revert MatchingModule__InvalidFillMakerRisk();
        }

        uint256 makerProfit = (fillMakerRisk * profitTicks) / ODDS_SCALE;

        // Lot-size alignment can produce a fillMakerRisk at a ODDS_SCALE boundary where
        // (fillMakerRisk * profitTicks / ODDS_SCALE) exceeds takerDesiredRisk by 1 base unit.
        // Clamp to prevent the taker from overpaying.
        if (makerProfit > takerDesiredRisk) {
            makerProfit = takerDesiredRisk;
        }

        // --- Record fill ---
        s_filledRisk[commitmentHash] += fillMakerRisk;

        // --- Gate maker contribution to first fill only ---
        uint256 effectiveMakerContribution = 0;
        if (
            commitment.contributionAmount > 0 &&
            !s_contributionCharged[commitmentHash]
        ) {
            effectiveMakerContribution = commitment.contributionAmount;
            s_contributionCharged[commitmentHash] = true;
        }

        IPositionModule posModule = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        );

        // --- Return speculation id ---
        uint256 speculationId = posModule.recordFill(
            commitment.contestId,
            commitment.scorer,
            commitment.lineTicks,
            leaderboardId,
            commitment.positionType,
            commitment.maker,
            fillMakerRisk,
            msg.sender,
            makerProfit,
            effectiveMakerContribution,
            takerContributionAmount
        );

        // --- Event ---
        emit CommitmentMatched(
            commitmentHash,
            commitment.maker,
            msg.sender,
            commitment.contestId,
            speculationId,
            commitment.positionType,
            commitment.oddsTick,
            makerProfit,
            fillMakerRisk
        );
        // Emit core event
        i_ospexCore.emitCoreEvent(
            keccak256("COMMITMENT_MATCHED"),
            abi.encode(
                commitmentHash,
                commitment.maker,
                msg.sender,
                commitment.contestId,
                speculationId,
                commitment.positionType,
                commitment.oddsTick,
                makerProfit,
                fillMakerRisk
            )
        );
    }

    /**
     * @notice Cancel a specific commitment by its hash
     * @dev Only the maker of the commitment can cancel it
     * @param commitment The commitment to cancel (used to verify caller is the maker)
     */
    function cancelCommitment(OspexCommitment calldata commitment) external {
        if (msg.sender != commitment.maker) {
            revert MatchingModule__NotCommitmentMaker();
        }
        bytes32 commitmentHash = _hashCommitment(commitment);
        s_cancelledCommitments[commitmentHash] = true;

        emit CommitmentCancelled(commitmentHash, msg.sender);
        i_ospexCore.emitCoreEvent(
            keccak256("COMMITMENT_CANCELLED"),
            abi.encode(commitmentHash, msg.sender)
        );
    }

    /**
     * @notice Raise the minimum valid nonce for a speculation, invalidating all
     *         commitments with a lower nonce.
     * @dev Nonce semantics: nonces are lower-bound invalidation thresholds, NOT unique
     *      per-commitment identifiers. A maker can have many active commitments on a
     *      speculation all sharing the same nonce value. Raising the min nonce
     *      invalidates all of them at once.
     *
     *      The scope is deliberately per-speculation, not per-commitment. When a user
     *      decides to withdraw from a speculation, they withdraw entirely — all of their
     *      unmatched commitments on that speculation are invalidated in a single call.
     *      There is no partial opt-out. This is an intentional design choice: pulling out
     *      of a speculation is all-or-nothing.
     *
     *      Per-commitment cancellation is available separately via cancelCommitment().
     * @param contestId The contest to bet on
     * @param scorer The scorer of the speculation
     * @param lineTicks The line/spread/total number (10x)
     * @param newMinNonce The new minimum valid nonce (must be higher than current)
     */
    function raiseMinNonce(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        uint256 newMinNonce
    ) external {
        bytes32 speculationKey = keccak256(
            abi.encode(contestId, scorer, lineTicks)
        );
        if (
            newMinNonce == type(uint256).max ||
            newMinNonce <= s_minNonces[msg.sender][speculationKey]
        ) {
            revert MatchingModule__NonceMustIncrease();
        }
        s_minNonces[msg.sender][speculationKey] = newMinNonce;
        emit MinNonceUpdated(msg.sender, speculationKey, newMinNonce);
        i_ospexCore.emitCoreEvent(
            keccak256("MIN_NONCE_UPDATED"),
            abi.encode(msg.sender, speculationKey, newMinNonce)
        );
    }

    // --- View Functions ---

    /**
     * @notice Returns the EIP-712 domain separator
     * @return The domain separator bytes32
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Computes the commitment hash for a given commitment (for off-chain use)
     * @param commitment The commitment to hash
     * @return The EIP-712 typed data hash
     */
    function getCommitmentHash(
        OspexCommitment calldata commitment
    ) external view returns (bytes32) {
        return _hashCommitment(commitment);
    }

    // --- Internal Functions ---

    /**
     * @notice Validates a commitment signature, checks all preconditions
     * @dev Expiry is the sole temporal guard on commitments. The protocol does not check
     *      contest start time or speculation state at match time (though matchCommitment() 
     *      checks if the contest has been scored and will revert if it has).
     *      Off-chain infrastructure is responsible for setting sensible defaults.
     *      Makers who set long expiries accept the risk of stale fills.
     *      Signature validation can revert with two different error families:
     *      - MatchingModule__InvalidSignature: valid signature format, wrong signer
     *      - OpenZeppelin ECDSA errors (ECDSAInvalidSignature,
     *        ECDSAInvalidSignatureLength, ECDSAInvalidSignatureS): malformed signature bytes
     *      Both are terminal reverts with no state change. Off-chain callers should
     *      treat either error family as "invalid signature," not just the custom error.
     * @param commitment The signed commitment from the maker
     * @param signature The EIP-712 signature
     * @return commitmentHash The EIP-712 hash of the commitment
     */
    function _validateCommitment(
        OspexCommitment calldata commitment,
        bytes calldata signature
    ) internal view returns (bytes32 commitmentHash) {
        // --- Zero address check ---
        if (commitment.maker == address(0)) {
            revert MatchingModule__InvalidMakerAddress();
        }

        // --- Check expiry ---
        if (block.timestamp > commitment.expiry) {
            revert MatchingModule__CommitmentExpired();
        }

        // --- Check riskAmount sizing ---
        if (commitment.riskAmount % ODDS_SCALE != 0) {
            revert MatchingModule__InvalidLotSize();
        }

        // --- Check nonce ---
        bytes32 speculationKey = keccak256(
            abi.encode(
                commitment.contestId,
                commitment.scorer,
                commitment.lineTicks
            )
        );
        if (commitment.nonce < s_minNonces[commitment.maker][speculationKey]) {
            revert MatchingModule__NonceTooLow();
        }

        // --- Verify EIP-712 signature ---
        commitmentHash = _hashCommitment(commitment);

        // --- Check not individually cancelled ---
        if (s_cancelledCommitments[commitmentHash]) {
            revert MatchingModule__CommitmentCancelled();
        }

        address recoveredSigner = ECDSA.recover(commitmentHash, signature);
        if (recoveredSigner != commitment.maker) {
            revert MatchingModule__InvalidSignature();
        }
    }

    /**
     * @notice Computes the EIP-712 typed data hash for a commitment
     * @param commitment The commitment to hash
     * @return The fully encoded EIP-712 hash (domain separator + struct hash)
     */
    function _hashCommitment(
        OspexCommitment calldata commitment
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        COMMITMENT_TYPEHASH,
                        commitment.maker,
                        commitment.contestId,
                        commitment.scorer,
                        commitment.lineTicks,
                        uint8(commitment.positionType),
                        commitment.oddsTick,
                        commitment.riskAmount,
                        commitment.contributionAmount,
                        commitment.nonce,
                        commitment.expiry
                    )
                )
            );
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
            revert MatchingModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
