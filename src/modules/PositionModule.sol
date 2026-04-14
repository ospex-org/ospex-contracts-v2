// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OspexCore} from "../core/OspexCore.sol";
import {
    Position,
    PositionType,
    Speculation,
    SpeculationStatus,
    WinSide
} from "../core/OspexTypes.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PositionModule
 * @notice Handles user positions for the Ospex protocol: fill recording, claiming,
 *         and transfers via the SecondaryMarketModule.
 * @dev Tokens are held by this contract between fill and claim. In this zero-vig protocol,
 *      maker's profit always equals taker's risk and vice versa.
 */
contract PositionModule is IPositionModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant LEADERBOARD_MODULE =
        keccak256("LEADERBOARD_MODULE");

    bytes32 public constant EVENT_POSITION_MATCHED_PAIR =
        keccak256("POSITION_MATCHED_PAIR");
    bytes32 public constant EVENT_POSITION_TRANSFERRED =
        keccak256("POSITION_TRANSFERRED");
    bytes32 public constant EVENT_POSITION_CLAIMED =
        keccak256("POSITION_CLAIMED");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when an address parameter is zero or a self-transfer is attempted
    error PositionModule__InvalidAddress();
    /// @notice Thrown when a non-MatchingModule address calls recordFill
    error PositionModule__NotMatchingModule();
    /// @notice Thrown when a risk amount is below the minimum or exceeds the position
    error PositionModule__InvalidAmount();
    /// @notice Thrown when a non-SecondaryMarketModule address calls transferPosition
    error PositionModule__UnauthorizedMarket();
    /// @notice Thrown when claiming a position on a speculation that is not yet settled
    error PositionModule__NotSettled();
    /// @notice Thrown when claiming a position that has already been claimed
    error PositionModule__AlreadyClaimed();
    /// @notice Thrown when attempting to transfer after the contest is scored but before settlement
    error PositionModule__ContestAlreadyScored();
    /// @notice Thrown when recording a fill on a speculation that is not open
    error PositionModule__SpeculationNotOpen();
    /// @notice Thrown when claiming a position with zero payout (loser or empty)
    error PositionModule__NoPayout();
    /// @notice Thrown when a required module is not registered in OspexCore
    error PositionModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when a transfer would reduce position below leaderboard-locked amounts
    error PositionModule__TransferLocked();

    // ──────────────────────────── Events ───────────────────────────────

    /**
     * @notice Emitted when a position is filled
     * @dev In this zero-vig protocol, maker's profit always equals takerRisk and
     *      taker's profit always equals makerRisk. Four economic values are derivable
     *      from the two emitted risk amounts alone.
     * @param speculationId The speculation ID
     * @param maker The maker address
     * @param taker The taker address
     * @param makerPositionType The maker's position type
     * @param takerPositionType The taker's position type
     * @param makerRisk The amount risked by the maker (= taker's profit)
     * @param takerRisk The amount risked by the taker (= maker's profit)
     */
    event PositionFilled(
        uint256 indexed speculationId,
        address indexed maker,
        address indexed taker,
        PositionType makerPositionType,
        PositionType takerPositionType,
        uint256 makerRisk,
        uint256 takerRisk
    );

    /// @notice Emitted when a position is transferred via the SecondaryMarketModule
    event PositionTransferred(
        uint256 indexed speculationId,
        address indexed from,
        PositionType positionType,
        address indexed to,
        uint256 riskAmount,
        uint256 profitAmount
    );

    /// @notice Emitted when a position is claimed
    event PositionClaimed(
        uint256 indexed speculationId,
        address indexed user,
        PositionType positionType,
        uint256 payout
    );

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @dev Ensures the speculation is in Open status
    modifier speculationOpen(uint256 speculationId) {
        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);
        if (spec.speculationStatus != SpeculationStatus.Open) {
            revert PositionModule__SpeculationNotOpen();
        }
        _;
    }

    /**
     * @notice Enforces a minimum bet size on the taker's risk amount
     * @dev No maximum is enforced on-chain. The natural upper bound is available
     *      liquidity. Enforcement is on taker risk only — maker risk is derived from
     *      taker risk and odds via MatchingModule, so applying bounds to both sides
     *      would create invalid-revert edge cases at extreme odds.
     * @param takerRisk The taker's at-risk amount (USDC, 6 decimals)
     */
    modifier riskAmountInRange(uint256 takerRisk) {
        ISpeculationModule specModule = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        );
        if (takerRisk < specModule.i_minSpeculationAmount()) {
            revert PositionModule__InvalidAmount();
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The USDC token contract
    IERC20 public immutable i_token;

    /// @notice Speculation ID → user → position type → Position
    mapping(uint256 => mapping(address => mapping(PositionType => Position)))
        public s_positions;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the PositionModule
    /// @param ospexCore_ The OspexCore contract address
    /// @param token_ The USDC token address
    constructor(address ospexCore_, address token_) {
        if (ospexCore_ == address(0) || token_ == address(0)) {
            revert PositionModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(ospexCore_);
        i_token = IERC20(token_);
    }

    // ──────────────────────────── Module Identity ─────────────────────

    /// @notice Returns the module type identifier
    function getModuleType() external pure override returns (bytes32) {
        return POSITION_MODULE;
    }

    // ──────────────────────────── Fill Recording ──────────────────────

    /**
     * @notice Records a fill. Only callable by MatchingModule.
     * @dev Tokens flow directly from maker/taker wallets to this contract.
     *      Creates the speculation if it doesn't exist yet. When a fill auto-creates
     *      a speculation, the creation fee is split between maker and taker via processSplitFee.
     *      Bet-size enforcement (riskAmountInRange) applies to takerRisk only.
     * @param contestId The contest ID
     * @param scorer The scorer address
     * @param lineTicks The line number (10x format, 0 for moneyline)
     * @param makerPositionType The maker's position type (Upper or Lower)
     * @param maker The maker address
     * @param makerRisk Maker risk being consumed
     * @param taker The taker address
     * @param takerRisk The taker's risk amount
     * @return speculationId The speculation ID for the fill
     */
    function recordFill(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) external override nonReentrant returns (uint256) {
        if (msg.sender != i_ospexCore.getModule(MATCHING_MODULE))
            revert PositionModule__NotMatchingModule();

        ISpeculationModule specModule = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        );

        uint256 speculationId = specModule.getSpeculationId(
            contestId,
            scorer,
            lineTicks
        );

        if (speculationId == 0) {
            speculationId = specModule.createSpeculation(
                contestId,
                scorer,
                lineTicks,
                maker,
                taker
            );
        }

        _recordFill(
            speculationId,
            makerPositionType,
            maker,
            makerRisk,
            taker,
            takerRisk
        );

        return speculationId;
    }

    // ──────────────────────────── Position Transfers ──────────────────

    /**
     * @notice Transfers a position between addresses. Only callable by SecondaryMarketModule.
     * @dev Does not enforce proportional risk/profit splits — trusts the calling contract
     *      to define valid transfer semantics. SecondaryMarketModule is set immutably in the
     *      module registry and is the only authorized caller.
     *      Transfers are blocked if the remaining position would fall below leaderboard-locked amounts.
     * @param speculationId The speculation ID
     * @param from The sender address
     * @param positionType The position type
     * @param to The recipient address
     * @param riskAmount The risk amount being transferred
     * @param profitAmount The profit amount being transferred
     */
    function transferPosition(
        uint256 speculationId,
        address from,
        PositionType positionType,
        address to,
        uint256 riskAmount,
        uint256 profitAmount
    ) external override speculationOpen(speculationId) {
        if (!i_ospexCore.isSecondaryMarket(msg.sender)) {
            revert PositionModule__UnauthorizedMarket();
        }
        if (from == to || to == address(0)) {
            revert PositionModule__InvalidAddress();
        }

        Speculation memory spec = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);
        if (
            IContestModule(_getModule(CONTEST_MODULE)).isContestScored(
                spec.contestId
            )
        ) {
            revert PositionModule__ContestAlreadyScored();
        }

        Position storage fromPos = _getPosition(
            speculationId,
            from,
            positionType
        );

        if (
            riskAmount > fromPos.riskAmount ||
            profitAmount > fromPos.profitAmount
        ) {
            revert PositionModule__InvalidAmount();
        }

        ILeaderboardModule lbModule = ILeaderboardModule(
            _getModule(LEADERBOARD_MODULE)
        );
        uint256 lockedRisk = lbModule.s_lockedRisk(
            speculationId,
            from,
            positionType
        );
        uint256 lockedProfit = lbModule.s_lockedProfit(
            speculationId,
            from,
            positionType
        );

        if (lockedRisk > 0 || lockedProfit > 0) {
            Position memory pos = s_positions[speculationId][from][
                positionType
            ];
            uint256 remainingRisk = pos.riskAmount - riskAmount;
            uint256 remainingProfit = pos.profitAmount - profitAmount;
            if (remainingRisk < lockedRisk || remainingProfit < lockedProfit) {
                revert PositionModule__TransferLocked();
            }
        }

        fromPos.riskAmount -= riskAmount;
        fromPos.profitAmount -= profitAmount;

        Position storage toPos = s_positions[speculationId][to][positionType];
        if (toPos.riskAmount == 0) {
            toPos.positionType = positionType;
            toPos.claimed = false;
        }
        toPos.riskAmount += riskAmount;
        toPos.profitAmount += profitAmount;

        emit PositionTransferred(
            speculationId,
            from,
            positionType,
            to,
            riskAmount,
            profitAmount
        );
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_TRANSFERRED,
            abi.encode(
                speculationId,
                from,
                positionType,
                to,
                riskAmount,
                profitAmount
            )
        );
    }

    // ──────────────────────────── Claiming ────────────────────────────

    /// @inheritdoc IPositionModule
    function claimPosition(
        uint256 speculationId,
        PositionType positionType
    ) external override nonReentrant {
        Speculation memory speculation = ISpeculationModule(
            _getModule(SPECULATION_MODULE)
        ).getSpeculation(speculationId);
        if (speculation.speculationStatus != SpeculationStatus.Closed) {
            revert PositionModule__NotSettled();
        }

        Position storage pos = _getPosition(
            speculationId,
            msg.sender,
            positionType
        );

        uint256 payout = _calculatePayout(speculation, pos);

        if (pos.riskAmount == 0 || payout == 0) {
            revert PositionModule__NoPayout();
        }

        pos.riskAmount = 0;
        pos.profitAmount = 0;
        pos.claimed = true;

        i_token.safeTransfer(msg.sender, payout);

        emit PositionClaimed(speculationId, msg.sender, positionType, payout);
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_CLAIMED,
            abi.encode(speculationId, msg.sender, positionType, payout)
        );
    }

    // ──────────────────────────── View Functions ──────────────────────

    /// @inheritdoc IPositionModule
    function getPosition(
        uint256 speculationId,
        address user,
        PositionType positionType
    ) external view override returns (Position memory position) {
        position = s_positions[speculationId][user][positionType];
    }

    // ──────────────────────────── Internal Helpers ─────────────────────

    /**
     * @notice Records a fill for both maker and taker
     * @dev riskAmountInRange applies to takerRisk; makerRisk is unchecked.
     * @param speculationId The speculation ID
     * @param makerPositionType The maker's position type
     * @param maker The maker address
     * @param makerRisk The maker's risk amount
     * @param taker The taker address
     * @param takerRisk The taker's risk amount
     */
    function _recordFill(
        uint256 speculationId,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk
    ) internal speculationOpen(speculationId) riskAmountInRange(takerRisk) {
        PositionType takerPositionType = makerPositionType == PositionType.Upper
            ? PositionType.Lower
            : PositionType.Upper;

        Position storage makerPos = s_positions[speculationId][maker][
            makerPositionType
        ];
        if (makerPos.riskAmount == 0) {
            makerPos.positionType = makerPositionType;
            makerPos.claimed = false;
        }
        makerPos.riskAmount += makerRisk;
        makerPos.profitAmount += takerRisk;

        Position storage takerPos = s_positions[speculationId][taker][
            takerPositionType
        ];
        if (takerPos.riskAmount == 0) {
            takerPos.positionType = takerPositionType;
            takerPos.claimed = false;
        }
        takerPos.riskAmount += takerRisk;
        takerPos.profitAmount += makerRisk;

        i_token.safeTransferFrom(maker, address(this), makerRisk);
        i_token.safeTransferFrom(taker, address(this), takerRisk);

        emit PositionFilled(
            speculationId,
            maker,
            taker,
            makerPositionType,
            takerPositionType,
            makerRisk,
            takerRisk
        );
        i_ospexCore.emitCoreEvent(
            EVENT_POSITION_MATCHED_PAIR,
            abi.encode(
                speculationId,
                maker,
                taker,
                makerPositionType,
                takerPositionType,
                makerRisk,
                takerRisk
            )
        );
    }

    /**
     * @notice Gets a position, reverting if already claimed
     * @param speculationId The speculation ID
     * @param user The user address
     * @param positionType The position type
     * @return position The position storage reference
     */
    function _getPosition(
        uint256 speculationId,
        address user,
        PositionType positionType
    ) internal view returns (Position storage position) {
        position = s_positions[speculationId][user][positionType];
        if (position.claimed) {
            revert PositionModule__AlreadyClaimed();
        }
        return position;
    }

    /**
     * @notice Calculates the payout for a position based on the speculation outcome
     * @param speculation The resolved speculation (must be Closed)
     * @param position The position to calculate payout for
     * @return The payout amount (risk + profit for winners, risk for push/void, 0 for losers)
     */
    function _calculatePayout(
        Speculation memory speculation,
        Position memory position
    ) internal pure returns (uint256) {
        if (
            speculation.winSide == WinSide.Push ||
            speculation.winSide == WinSide.Void
        ) {
            return position.riskAmount;
        }

        bool isWinner = ((position.positionType == PositionType.Upper &&
            (speculation.winSide == WinSide.Away ||
                speculation.winSide == WinSide.Over)) ||
            (position.positionType == PositionType.Lower &&
                (speculation.winSide == WinSide.Home ||
                    speculation.winSide == WinSide.Under)));

        if (isWinner) {
            return position.riskAmount + position.profitAmount;
        }
        return 0;
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
            revert PositionModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
