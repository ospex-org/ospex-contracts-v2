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
 * @notice Handles user positions: fill recording, claiming, and transfer for Ospex protocol
 * @dev All business logic for positions is implemented here. Uses hybrid event emission pattern.
 */
contract PositionModule is IPositionModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Error for invalid address
    error PositionModule__InvalidAddress();
    /// @notice Error for caller being anyone other than Matching Module
    error PositionModule__NotMatchingModule();
    /// @notice Error for invalid amount
    error PositionModule__InvalidAmount();
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
    /// @notice Error for module not set
    error PositionModule__ModuleNotSet(bytes32 moduleType);

    // --- Storage ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The ERC20 token
    IERC20 public immutable i_token;

    // Positions: speculationId => user => positionType => Position
    mapping(uint256 => mapping(address => mapping(PositionType => Position)))
        public s_positions;

    // --- Events (module-local) ---

    /**
     * @notice Emitted when a position is filled.
     * @dev In this zero-vig protocol, maker's profit always equals takerRisk and
     *      taker's profit always equals makerRisk. Four economic values (makerRisk,
     *      makerProfit, takerRisk, takerProfit) are therefore derivable from the
     *      two emitted risk amounts alone.
     * @param speculationId The ID of the speculation
     * @param maker The address of the maker
     * @param taker The address of the taker
     * @param makerPositionType The type of position for the maker
     * @param takerPositionType The type of position for the taker
     * @param makerRisk The amount risked by the maker (also equals taker's profit)
     * @param takerRisk The amount risked by the taker (also equals maker's profit)
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

    /**
     * @notice Emitted when a position is transferred
     * @param speculationId The ID of the speculation
     * @param from The address of the from user
     * @param positionType The type of position
     * @param to The address of the to user
     * @param riskAmount The risk amount of the position
     * @param profitAmount The profit amount of the position
     */
    event PositionTransferred(
        uint256 indexed speculationId,
        address indexed from,
        PositionType positionType,
        address indexed to,
        uint256 riskAmount,
        uint256 profitAmount
    );

    /**
     * @notice Emitted when a position is claimed
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param positionType The type of position
     * @param payout The payout amount
     */
    event PositionClaimed(
        uint256 indexed speculationId,
        address indexed user,
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
     * @notice Enforces a minimum bet size on the taker's risk amount.
     * @dev No maximum is enforced on-chain. The natural upper bound is available
     *      liquidity. Enforcement is on taker risk only — maker risk is derived from
     *      taker risk and odds via MatchingModule, so applying bounds to both sides
     *      would create invalid-revert edge cases at extreme odds. Limits are
     *      conservative at launch and subject to increase.
     * @param takerRisk The taker's at-risk amount (USDC, 6 decimals)
     */
    modifier riskAmountInRange(uint256 takerRisk) {
        ISpeculationModule specModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        );
        if (takerRisk < specModule.s_minSpeculationAmount()) {
            revert PositionModule__InvalidAmount();
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
     * @notice Records a fill
     * @dev Only callable by Matching Module
     *      Tokens flow directly from maker/taker wallets to this contract.
     *      Creates the speculation, if necessary
     *      Bet-size enforcement (riskAmountInRange) applies to takerRisk only
     *      When a fill auto-creates a speculation, the taker (msg.sender of matchCommitment)
     *      becomes the speculationCreator. This is intentional: Any speculation creation
     *      fee is charged to the taker accordingly.
     * @param contestId The contest id
     * @param scorer The scorer address
     * @param lineTicks The number if applicable (10x)
     * @param leaderboardId The leaderboard id for fees if applicable
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerRisk Maker risk being consumed
     * @param taker The address of the taker
     * @param takerRisk The risk the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     * @return speculationId The speculation for the fill
     */

    function recordFill(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        uint256 leaderboardId,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external override nonReentrant returns (uint256) {
        // --- Access control ---
        if (
            msg.sender !=
            address(i_ospexCore.getModule(keccak256("MATCHING_MODULE")))
        ) revert PositionModule__NotMatchingModule();

        ISpeculationModule specModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
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
                taker,
                leaderboardId
            );
        }

        _recordFill(
            speculationId,
            makerPositionType,
            maker,
            makerRisk,
            taker,
            takerRisk,
            makerContributionAmount,
            takerContributionAmount
        );

        return speculationId;
    }

    /**
     * @notice Transfers a position
     * @dev This function does not enforce proportional risk/profit splits. It trusts the
     *      calling market-role contract to define valid transfer semantics.
     * @param speculationId The ID of the speculation
     * @param from The address of the from user
     * @param positionType The type of position
     * @param to The address of the to user
     * @param riskAmount The amount of risk being sold
     * @param profitAmount The amount of profit being sold
     */
    function transferPosition(
        uint256 speculationId,
        address from,
        PositionType positionType,
        address to,
        uint256 riskAmount,
        uint256 profitAmount
    ) external override speculationOpen(speculationId) {
        // Centralized access control: only approved market contracts can call
        if (!i_ospexCore.hasMarketRole(msg.sender)) {
            revert PositionModule__UnauthorizedMarket();
        }
        // Revert on self-transfer or zero address
        if (from == to || to == address(0)) {
            revert PositionModule__InvalidAddress();
        }
        // Get the position being transferred from
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
            keccak256("POSITION_TRANSFERRED"),
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

    /**
     * @notice Claims winnings from a position
     * @param speculationId The ID of the speculation
     * @param positionType The type of position
     */
    function claimPosition(
        uint256 speculationId,
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
            positionType
        );

        // Calculate payout for matched amount
        uint256 payout = _calculatePayout(speculationId, pos);

        // Check if there's anything to claim
        if (pos.riskAmount == 0 || payout == 0) {
            revert PositionModule__NoPayout();
        }

        // Zero out the position
        pos.riskAmount = 0;
        pos.profitAmount = 0;
        pos.claimed = true;

        // Transfer total payout
        i_token.safeTransfer(msg.sender, payout);

        // Emit module-local event
        emit PositionClaimed(speculationId, msg.sender, positionType, payout);
        // Emit core event
        i_ospexCore.emitCoreEvent(
            keccak256("POSITION_CLAIMED"),
            abi.encode(speculationId, msg.sender, positionType, payout)
        );
    }

    /**
     * @notice Gets a position
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param positionType The type of position
     */
    function getPosition(
        uint256 speculationId,
        address user,
        PositionType positionType
    ) external view override returns (Position memory position) {
        position = s_positions[speculationId][user][positionType];
    }

    // --- Internal functions ---

    /**
     * @notice Internal function to record fill
     *         riskAmountInRange is applied to takerRisk; makerRisk is unchecked.
     * @param speculationId The ID of the speculation
     * @param makerPositionType The position type of the maker (Upper or Lower)
     * @param maker The address of the maker
     * @param makerRisk Maker risk being consumed
     * @param taker The address of the taker
     * @param takerRisk The risk the taker is putting up
     * @param makerContributionAmount The amount of the contribution for the maker
     * @param takerContributionAmount The amount of the contribution for the taker
     */
    function _recordFill(
        uint256 speculationId,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) internal speculationOpen(speculationId) riskAmountInRange(takerRisk) {
        // --- Taker position type---
        PositionType takerPositionType = makerPositionType == PositionType.Upper
            ? PositionType.Lower
            : PositionType.Upper;

        // --- Maker position ---
        Position storage makerPos = s_positions[speculationId][maker][
            makerPositionType
        ];
        if (makerPos.riskAmount == 0) {
            makerPos.positionType = makerPositionType;
            makerPos.claimed = false;
        }
        makerPos.riskAmount += makerRisk;
        makerPos.profitAmount += takerRisk;

        // --- Taker position ---
        Position storage takerPos = s_positions[speculationId][taker][
            takerPositionType
        ];
        if (takerPos.riskAmount == 0) {
            takerPos.positionType = takerPositionType;
            takerPos.claimed = false;
        }
        takerPos.riskAmount += takerRisk;
        takerPos.profitAmount += makerRisk;

        // --- Token transfer ---
        i_token.safeTransferFrom(maker, address(this), makerRisk);
        i_token.safeTransferFrom(taker, address(this), takerRisk);

        // --- Contribution handling ---
        if (makerContributionAmount + takerContributionAmount > 0) {
            IContributionModule contributionModule = IContributionModule(
                _getModule(keccak256("CONTRIBUTION_MODULE"))
            );
            if (makerContributionAmount > 0) {
                contributionModule.handleContribution(
                    speculationId,
                    maker,
                    makerPositionType,
                    makerContributionAmount
                );
            }
            if (takerContributionAmount > 0) {
                contributionModule.handleContribution(
                    speculationId,
                    taker,
                    takerPositionType,
                    takerContributionAmount
                );
            }
        }

        // --- Event ---
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
            keccak256("POSITION_MATCHED_PAIR"),
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

    // --- Internal position getter with validation (v2-style) ---
    /**
     * @notice Gets a position
     * @param speculationId The ID of the speculation
     * @param user The address of the user
     * @param positionType The type of position
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
            return position.riskAmount; // Return original stake
        }

        // Calculate payout based on position type and win side
        bool isWinner = ((position.positionType == PositionType.Upper &&
            (speculation.winSide == WinSide.Away ||
                speculation.winSide == WinSide.Over)) ||
            (position.positionType == PositionType.Lower &&
                (speculation.winSide == WinSide.Home ||
                    speculation.winSide == WinSide.Under)));

        if (isWinner) {
            return position.riskAmount + position.profitAmount;
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
