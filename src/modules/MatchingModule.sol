// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OspexCore} from "../core/OspexCore.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
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
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");

    bytes32 public constant EVENT_COMMITMENT_MATCHED =
        keccak256("COMMITMENT_MATCHED");
    bytes32 public constant EVENT_COMMITMENT_CANCELLED =
        keccak256("COMMITMENT_CANCELLED");
    bytes32 public constant EVENT_MIN_NONCE_UPDATED =
        keccak256("MIN_NONCE_UPDATED");

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
            "uint256 nonce,"
            "uint256 expiry"
            ")"
        );

    /// @notice Odds scale factor (1.91 odds = 191 ticks)
    uint16 public constant ODDS_SCALE = 100;
    /// @notice Minimum valid odds (1.01)
    uint16 public constant MIN_ODDS = 101;
    /// @notice Maximum valid odds (101.00)
    uint16 public constant MAX_ODDS = 10100;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the recovered signer does not match the commitment maker
    error MatchingModule__InvalidSignature();
    /// @notice Thrown when odds are below MIN_ODDS or above MAX_ODDS
    error MatchingModule__OddsOutOfRange(uint16 oddsTick);
    /// @notice Thrown when a commitment has expired
    error MatchingModule__CommitmentExpired();
    /// @notice Thrown when a commitment nonce is below the maker's minimum for this speculation
    error MatchingModule__NonceTooLow();
    /// @notice Thrown when a commitment has been individually cancelled
    error MatchingModule__CommitmentCancelled();
    /// @notice Thrown when riskAmount is not a multiple of ODDS_SCALE
    error MatchingModule__InvalidLotSize();
    /// @notice Thrown when the maker address is zero
    error MatchingModule__InvalidMakerAddress();
    /// @notice Thrown when takerDesiredRisk is zero
    error MatchingModule__InvalidTakerDesiredRisk();
    /// @notice Thrown when the calculated maker fill is zero or exceeds remaining capacity
    error MatchingModule__InvalidFillMakerRisk();
    /// @notice Thrown when a non-maker tries to cancel a commitment
    error MatchingModule__NotCommitmentMaker();
    /// @notice Thrown when the new minimum nonce is not higher than the current
    error MatchingModule__NonceMustIncrease();
    /// @notice Thrown when a constructor address is zero
    error MatchingModule__InvalidAddress();
    /// @notice Thrown when a commitment has no remaining capacity
    error MatchingModule__CommitmentFullyFilled();
    /// @notice Thrown when a required module is not registered in OspexCore
    error MatchingModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the contest has already been scored
    error MatchingModule__ContestAlreadyScored();
    /// @notice Thrown when the contest has elapsed its void cooldown and new fills are rejected
    error MatchingModule__ContestPastCooldown();

    // ──────────────────────────── Events ───────────────────────────────

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

    // ──────────────────────────── Structs ──────────────────────────────

    /**
     * @notice Represents a signed commitment from a maker to take a position
     * @param maker The maker's wallet address (recovered from signature)
     * @param contestId The contest to bet on
     * @param scorer The scorer module address
     * @param lineTicks The line/spread/total number (10x format)
     * @param positionType 0 = Upper (away/over), 1 = Lower (home/under)
     * @param oddsTick Maker's quoted price as an integer (193 = 1.93 odds)
     * @param riskAmount Risk amount in USDC the maker will commit (6 decimals, must be multiple of ODDS_SCALE)
     * @param nonce Invalidation threshold (NOT a unique order ID). Multiple commitments
     *              on the same speculation may share the same nonce. When the maker calls
     *              raiseMinNonce(), all commitments with nonce < newMinNonce are invalidated.
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
        uint256 nonce;
        uint256 expiry;
    }

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @dev Ensures odds are within the valid range
    modifier oddsInRange(uint16 oddsTick) {
        if (oddsTick < MIN_ODDS || oddsTick > MAX_ODDS) {
            revert MatchingModule__OddsOutOfRange(oddsTick);
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Per-speculation minimum valid nonce: maker → speculationKey → minNonce
    mapping(address => mapping(bytes32 => uint256)) public s_minNonces;
    /// @notice Filled risk per commitment hash (for partial fills)
    mapping(bytes32 => uint256) public s_filledRisk;
    /// @notice Individually cancelled commitment hashes
    mapping(bytes32 => bool) public s_cancelledCommitments;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the MatchingModule with EIP-712 domain "Ospex" version "1"
    /// @param ospexCore_ The OspexCore contract address
    constructor(address ospexCore_) EIP712("Ospex", "1") {
        if (ospexCore_ == address(0)) {
            revert MatchingModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(ospexCore_);
    }

    // ──────────────────────────── Module Identity ─────────────────────
    function getModuleType() external pure override returns (bytes32) {
        return MATCHING_MODULE;
    }

    // ──────────────────────────── Matching ─────────────────────────────

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
     * @param takerDesiredRisk The amount of risk the taker wants to fill (USDC, 6 decimals).
     *                         Actual fill may be slightly less due to lot-size rounding on the maker side.
     */
    function matchCommitment(
        OspexCommitment calldata commitment,
        bytes calldata signature,
        uint256 takerDesiredRisk
    ) external nonReentrant oddsInRange(commitment.oddsTick) {
        if (takerDesiredRisk == 0) {
            revert MatchingModule__InvalidTakerDesiredRisk();
        }

        if (
            IContestModule(_getModule(CONTEST_MODULE)).isContestTerminal(
                commitment.contestId
            )
        ) {
            revert MatchingModule__ContestAlreadyScored();
        }

        if (
            ISpeculationModule(_getModule(SPECULATION_MODULE))
                .isContestPastCooldown(commitment.contestId)
        ) {
            revert MatchingModule__ContestPastCooldown();
        }

        bytes32 commitmentHash = _validateCommitment(commitment, signature);

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

        if (makerProfit > takerDesiredRisk) {
            makerProfit = takerDesiredRisk;
        }

        s_filledRisk[commitmentHash] += fillMakerRisk;

        uint256 speculationId = IPositionModule(_getModule(POSITION_MODULE))
            .recordFill(
                commitment.contestId,
                commitment.scorer,
                commitment.lineTicks,
                commitment.positionType,
                commitment.maker,
                fillMakerRisk,
                msg.sender,
                makerProfit
            );

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
        i_ospexCore.emitCoreEvent(
            EVENT_COMMITMENT_MATCHED,
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

    // ──────────────────────────── Cancellation ────────────────────────

    /**
     * @notice Cancel a specific commitment by its hash. Only callable by the maker.
     * @param commitment The commitment to cancel
     */
    function cancelCommitment(OspexCommitment calldata commitment) external {
        if (msg.sender != commitment.maker) {
            revert MatchingModule__NotCommitmentMaker();
        }
        bytes32 commitmentHash = _hashCommitment(commitment);
        s_cancelledCommitments[commitmentHash] = true;

        emit CommitmentCancelled(commitmentHash, msg.sender);
        i_ospexCore.emitCoreEvent(
            EVENT_COMMITMENT_CANCELLED,
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
     *      There is no partial opt-out. This is an intentional design choice.
     *
     *      Per-commitment cancellation is available separately via cancelCommitment().
     * @param contestId The contest ID
     * @param scorer The scorer module address
     * @param lineTicks The line number (10x format)
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
            EVENT_MIN_NONCE_UPDATED,
            abi.encode(msg.sender, speculationKey, newMinNonce)
        );
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @notice Returns the EIP-712 domain separator
    /// @return The domain separator bytes32
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Computes the commitment hash for a given commitment (for off-chain use)
    /// @param commitment The commitment to hash
    /// @return The EIP-712 typed data hash
    function getCommitmentHash(
        OspexCommitment calldata commitment
    ) external view returns (bytes32) {
        return _hashCommitment(commitment);
    }

    // ──────────────────────────── Internal Functions ──────────────────

    /**
     * @notice Validates a commitment signature and checks all preconditions
     * @dev Expiry is the sole temporal guard on commitments. The protocol does not check
     *      contest start time or speculation state at match time (though matchCommitment
     *      checks if the contest has been scored and will revert if it has).
     *      Off-chain infrastructure is responsible for setting sensible defaults.
     *      Makers who set long expiries accept the risk of stale fills.
     *      Signature validation can revert with two different error families:
     *      - MatchingModule__InvalidSignature: valid signature format, wrong signer
     *      - OpenZeppelin ECDSA errors: malformed signature bytes
     *      Both are terminal reverts with no state change.
     * @param commitment The signed commitment from the maker
     * @param signature The EIP-712 signature
     * @return commitmentHash The EIP-712 hash of the commitment
     */
    function _validateCommitment(
        OspexCommitment calldata commitment,
        bytes calldata signature
    ) internal view returns (bytes32 commitmentHash) {
        if (commitment.maker == address(0)) {
            revert MatchingModule__InvalidMakerAddress();
        }

        if (block.timestamp >= commitment.expiry) {
            revert MatchingModule__CommitmentExpired();
        }

        if (commitment.riskAmount % ODDS_SCALE != 0) {
            revert MatchingModule__InvalidLotSize();
        }

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

        commitmentHash = _hashCommitment(commitment);

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
                        commitment.nonce,
                        commitment.expiry
                    )
                )
            );
    }

    // ──────────────────────────── Module Lookup ───────────────────────

    /**
     * @notice Resolves a module address from OspexCore, reverting if not set
     * @param moduleType The module type identifier
     * @return module The module contract address
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
