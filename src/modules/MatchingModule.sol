// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OspexCore} from "../core/OspexCore.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {PositionType} from "../core/OspexTypes.sol";

/**
 * @title MatchingModule
 * @notice Verifies EIP-712 signed commitments and executes atomic matches via PositionModule.
 * @dev This contract never custodies funds. USDC flows directly from maker/taker wallets
 *      to the PositionModule via safeTransferFrom. Both parties must approve the PositionModule
 *      contract for USDC spending, NOT this contract.
 *
 *      The MatchingModule must be granted MARKET_ROLE on OspexCore to call
 *      createMatchedPair / createMatchedPairWithSpeculation on the PositionModule.
 */
contract MatchingModule is EIP712, ReentrancyGuard {
    // --- Errors ---
    /// @notice Commitment signature is invalid
    error MatchingModule__InvalidSignature();
    /// @notice Commitment has expired
    error MatchingModule__CommitmentExpired();
    /// @notice Commitment nonce is below the minimum valid nonce for this speculation
    error MatchingModule__NonceTooLow();
    /// @notice Commitment has been individually cancelled
    error MatchingModule__CommitmentCancelled();
    /// @notice Maker address cannot be zero
    error MatchingModule__InvalidMakerAddress();
    /// @notice Taker amount is zero
    error MatchingModule__InvalidTakerAmount();
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

    // --- Events ---
    /// @notice Emitted when a commitment is matched (fully or partially)
    event CommitmentMatched(
        bytes32 indexed commitmentHash,
        address indexed maker,
        address indexed taker,
        uint256 contestId,
        uint256 speculationId,
        PositionType positionType,
        uint64 odds,
        uint256 makerFillAmount,
        uint256 takerFillAmount
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
            "int32 theNumber,"
            "uint8 positionType,"
            "uint64 odds,"
            "uint256 maxAmount,"
            "uint256 nonce,"
            "uint256 expiry"
            ")"
        );

    // --- Immutables ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    // --- Storage ---
    /// @notice Per-speculation minimum valid nonce: maker => speculationKey => minNonce
    mapping(address => mapping(bytes32 => uint256)) public s_minNonces;

    /// @notice Filled amount per commitment hash (for partial fills)
    mapping(bytes32 => uint256) public s_filledAmounts;

    /// @notice Individually cancelled commitment hashes
    mapping(bytes32 => bool) public s_cancelledCommitments;

    // --- Structs ---
    /**
     * @notice Represents a signed commitment from a maker to take a position
     * @param maker The maker's wallet address (recovered from signature)
     * @param contestId The contest to bet on
     * @param scorer The scorer of the speculation
     * @param theNumber The line/spread/total number
     * @param positionType 0 = Upper (away/over), 1 = Lower (home/under)
     * @param odds Decimal odds in fixed point (1e7 precision, e.g., 1.91 = 19100000)
     * @param maxAmount Maximum USDC the maker will commit (6 decimals)
     * @param nonce Per-speculation nonce for cancellation/replay prevention
     * @param expiry Unix timestamp after which this commitment is invalid
     */
    struct OspexCommitment {
        address maker;
        uint256 contestId;
        address scorer;
        int32 theNumber;
        PositionType positionType;
        uint64 odds;
        uint256 maxAmount;
        uint256 nonce;
        uint256 expiry;
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

    // --- External Functions ---

    /**
     * @notice Match against a signed commitment, creating the speculation if it doesn't exist
     * @dev The taker is msg.sender. Both maker and taker must have approved the
     *      PositionModule contract for USDC spending.
     *
     *      Fill accounting — why makerAmountRemaining != makerAmountFilled:
     *      `makerAmountRemaining` is passed to PositionModule as a CEILING, not as a
     *      fill request. PositionModule determines the actual amount consumed
     *      (`makerAmountConsumed`) from `takerAmount` and the odds-derived inverse
     *      calculation. The return value will always be <= makerAmountRemaining.
     *
     *      `s_filledAmounts` accumulates the actual return values, not the passed-in
     *      remaining. This means a commitment with maxAmount = 100 USDC can be filled
     *      in multiple taker-sized increments until cumulative fills equal maxAmount.
     *
     *      PositionModule enforces that takerAmount does not exceed what
     *      makerAmountRemaining can support at the given odds (reverts with
     *      InsufficientAmountRemaining if so). MatchingModule does NOT pre-cap
     *      takerAmount — it delegates that validation entirely to PositionModule.
     *
     * @param commitment The maker's signed commitment
     * @param signature The EIP-712 signature over the commitment
     * @param takerAmount The amount the taker wants to fill (in USDC, 6 decimals)
     * @param leaderboardId The leaderboard ID (where the fee will be allocated)
     * @param takerContributionAmount The taker's contribution amount
     * @param makerContributionAmount The maker's contribution amount
     */
    function matchCommitment(
        OspexCommitment calldata commitment,
        bytes calldata signature,
        uint256 takerAmount,
        uint256 leaderboardId,
        uint256 takerContributionAmount,
        uint256 makerContributionAmount
    ) external nonReentrant {
        // --- Validate commitment ---
        bytes32 commitmentHash = _validateCommitment(
            commitment,
            signature,
            takerAmount
        );

        // --- Calculate maker amount remaining (if any) ---
        uint256 makerAmountRemaining = commitment.maxAmount -
            s_filledAmounts[commitmentHash];
        if (makerAmountRemaining == 0) {
            revert MatchingModule__CommitmentFullyFilled();
        }

        ISpeculationModule specModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        );
        IPositionModule posModule = IPositionModule(
            _getModule(keccak256("POSITION_MODULE"))
        );

        // --- Get speculation ID (if exists) ---
        uint256 speculationId = specModule.getSpeculationId(
            commitment.contestId,
            commitment.scorer,
            commitment.theNumber
        );

        uint256 makerAmountFilled;

        // --- Create speculation if it doesn't exist ---
        if (speculationId == 0) {
            makerAmountFilled = posModule.createMatchedPairWithSpeculation(
                commitment.contestId,
                commitment.scorer,
                commitment.theNumber,
                leaderboardId,
                commitment.odds,
                commitment.positionType,
                commitment.maker,
                makerAmountRemaining,
                msg.sender,
                takerAmount,
                makerContributionAmount,
                takerContributionAmount
            );
            speculationId = specModule.getSpeculationId(
                commitment.contestId,
                commitment.scorer,
                commitment.theNumber
            );
        } else {
            makerAmountFilled = posModule.createMatchedPair(
                speculationId,
                commitment.odds,
                commitment.positionType,
                commitment.maker,
                makerAmountRemaining,
                msg.sender,
                takerAmount,
                makerContributionAmount,
                takerContributionAmount
            );
        }

        // --- Record fill ---
        s_filledAmounts[commitmentHash] += makerAmountFilled;

        // --- Event ---
        emit CommitmentMatched(
            commitmentHash,
            commitment.maker,
            msg.sender,
            commitment.contestId,
            speculationId,
            commitment.positionType,
            commitment.odds,
            makerAmountFilled,
            takerAmount
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
                commitment.odds,
                makerAmountFilled,
                takerAmount
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
     *         commitments with a lower nonce
     * @dev Only affects the caller's own commitments on the specified speculation
     * @param contestId The contest to bet on
     * @param scorer The scorer of the speculation
     * @param theNumber The line/spread/total number
     * @param newMinNonce The new minimum valid nonce (must be higher than current)
     */
    function raiseMinNonce(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256 newMinNonce
    ) external {
        bytes32 speculationKey = keccak256(
            abi.encode(contestId, scorer, theNumber)
        );
        if (newMinNonce <= s_minNonces[msg.sender][speculationKey]) {
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
     * @notice Returns the remaining fillable amount for a commitment
     * @param commitment The commitment to check
     * @return remaining The amount still available to fill
     */
    function getRemainingAmount(
        OspexCommitment calldata commitment
    ) external view returns (uint256 remaining) {
        bytes32 commitmentHash = _hashCommitment(commitment);
        remaining = commitment.maxAmount - s_filledAmounts[commitmentHash];
    }

    /**
     * @notice Returns the minimum valid nonce for a maker on a speculation
     * @param maker The maker address
     * @param contestId The contest to bet on
     * @param scorer The scorer of the speculation
     * @param theNumber The line/spread/total number
     * @return The minimum valid nonce
     */
    function getMinNonce(
        address maker,
        uint256 contestId,
        address scorer,
        int32 theNumber
    ) external view returns (uint256) {
        bytes32 speculationKey = keccak256(
            abi.encode(contestId, scorer, theNumber)
        );
        return s_minNonces[maker][speculationKey];
    }

    /**
     * @notice Check if a specific commitment hash has been individually cancelled
     * @param commitmentHash The hash to check
     * @return True if cancelled
     */
    function isCancelled(bytes32 commitmentHash) external view returns (bool) {
        return s_cancelledCommitments[commitmentHash];
    }

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
     * @param commitment The signed commitment from the maker
     * @param signature The EIP-712 signature
     * @param takerAmount The amount the taker wants to put up
     * @return commitmentHash The EIP-712 hash of the commitment
     */
    function _validateCommitment(
        OspexCommitment calldata commitment,
        bytes calldata signature,
        uint256 takerAmount
    ) internal view returns (bytes32 commitmentHash) {
        // --- Zero address check (fails fast before any other work) ---
        if (commitment.maker == address(0)) {
            revert MatchingModule__InvalidMakerAddress();
        }
        if (takerAmount == 0) {
            revert MatchingModule__InvalidTakerAmount();
        }

        // --- Check expiry ---
        if (block.timestamp > commitment.expiry) {
            revert MatchingModule__CommitmentExpired();
        }

        // --- Check nonce ---
        bytes32 speculationKey = keccak256(
            abi.encode(
                commitment.contestId,
                commitment.scorer,
                commitment.theNumber
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
                        commitment.theNumber,
                        uint8(commitment.positionType),
                        commitment.odds,
                        commitment.maxAmount,
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
