// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {Contest, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";

/**
 * @title MoneylineScorerModule
 * @author ospex.org
 * @notice Scores moneyline (straight win/loss) speculations. The team with more
 *         points wins; equal scores result in a Push.
 */
contract MoneylineScorerModule is IScorerModule {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a non-SpeculationModule address calls determineWinSide
    error MoneylineScorerModule__NotSpeculationModule(address caller);
    /// @notice Thrown when a required module is not registered in OspexCore
    error MoneylineScorerModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the OspexCore address is zero
    error MoneylineScorerModule__InvalidOspexCore();

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @dev Restricts access to the registered SpeculationModule
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(SPECULATION_MODULE)) {
            revert MoneylineScorerModule__NotSpeculationModule(msg.sender);
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the MoneylineScorerModule
    /// @param ospexCore_ The OspexCore contract address
    constructor(address ospexCore_) {
        if (ospexCore_ == address(0))
            revert MoneylineScorerModule__InvalidOspexCore();
        i_ospexCore = OspexCore(ospexCore_);
    }

    // ──────────────────────────── Scoring ──────────────────────────────

    /// @inheritdoc IScorerModule
    function determineWinSide(
        uint256 contestId,
        int32 /*lineTicks*/
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(_getModule(CONTEST_MODULE))
            .getContest(contestId);

        return _scoreMoneyline(contest.awayScore, contest.homeScore);
    }

    /**
     * @notice Scores a moneyline speculation
     * @param awayScore Away team score
     * @param homeScore Home team score
     * @return The winning side (Away, Home, or Push on tie)
     */
    function _scoreMoneyline(
        uint32 awayScore,
        uint32 homeScore
    ) private pure returns (WinSide) {
        if (awayScore > homeScore) {
            return WinSide.Away;
        } else if (homeScore > awayScore) {
            return WinSide.Home;
        } else {
            return WinSide.Push;
        }
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
            revert MoneylineScorerModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
