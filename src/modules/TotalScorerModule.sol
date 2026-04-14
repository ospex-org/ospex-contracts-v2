// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {Contest, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";

/**
 * @title TotalScorerModule
 * @author ospex.org
 * @notice Scores total (over/under) speculations. Combined score is scaled to 10x
 *         and compared against the total line. Over wins if total > line. Equal = Push.
 */
contract TotalScorerModule is IScorerModule {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a non-SpeculationModule address calls determineWinSide
    error TotalScorerModule__NotSpeculationModule(address caller);
    /// @notice Thrown when a required module is not registered in OspexCore
    error TotalScorerModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the OspexCore address is zero
    error TotalScorerModule__InvalidOspexCore();

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @dev Restricts access to the registered SpeculationModule
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(SPECULATION_MODULE)) {
            revert TotalScorerModule__NotSpeculationModule(msg.sender);
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the TotalScorerModule
    /// @param ospexCore_ The OspexCore contract address
    constructor(address ospexCore_) {
        if (ospexCore_ == address(0))
            revert TotalScorerModule__InvalidOspexCore();
        i_ospexCore = OspexCore(ospexCore_);
    }

    // ──────────────────────────── Scoring ──────────────────────────────

    /// @inheritdoc IScorerModule
    function determineWinSide(
        uint256 contestId,
        int32 lineTicks
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(_getModule(CONTEST_MODULE))
            .getContest(contestId);

        return _scoreTotal(contest.awayScore, contest.homeScore, lineTicks);
    }

    /**
     * @notice Scores a total points speculation
     * @dev Combined score is scaled to 10x to match lineTicks representation.
     *      Over wins when (awayScore + homeScore) * 10 > lineTicks.
     *      Exact equality results in a Push.
     * @param awayScore Away team score (raw, not scaled)
     * @param homeScore Home team score (raw, not scaled)
     * @param lineTicks Total line (10x format, e.g. 2205 = 220.5)
     * @return The winning side (Over, Under, or Push)
     */
    function _scoreTotal(
        uint32 awayScore,
        uint32 homeScore,
        int32 lineTicks
    ) private pure returns (WinSide) {
        // Safe cast: combined sports scores * 10 never exceed int32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 scaledTotal = int32(awayScore + homeScore) * 10;

        if (scaledTotal > lineTicks) {
            return WinSide.Over;
        } else if (scaledTotal < lineTicks) {
            return WinSide.Under;
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
            revert TotalScorerModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
