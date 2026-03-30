// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {Contest, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";

/**
 * @title TotalScorerModule
 * @author ospex.org
 * @notice Module for total (over/under) scoring logic
 */

contract TotalScorerModule is IScorerModule {
    /// @notice Error for not a speculation module
    error TotalScorerModule__NotSpeculationModule(address caller);
    /// @notice Error for module not set
    error TotalScorerModule__ModuleNotSet(bytes32 moduleType);

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Modifier to check if the caller is a speculation module
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(keccak256("SPECULATION_MODULE"))) {
            revert TotalScorerModule__NotSpeculationModule(msg.sender);
        }
        _;
    }

    /**
     * @notice Constructor
     * @param _ospexCore The address of the OspexCore contract
     */
    constructor(address _ospexCore) {
        i_ospexCore = OspexCore(_ospexCore);
    }

    /**
     * @notice Determines the winning side for a total (over/under) speculation
     * @param contestId The ID of the contest to score
     * @param lineTicks The total line, stored as 10x (e.g., 220.5 = 2205)
     * @return WinSide The winning side
     */
    function determineWinSide(
        uint256 contestId,
        int32 lineTicks
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);

        return scoreTotal(contest.awayScore, contest.homeScore, lineTicks);
    }

    /**
     * @notice Scores a total points speculation
     * @param _awayScore Away team score (raw game score, not scaled)
     * @param _homeScore Home team score (raw game score, not scaled)
     * @param _lineTicks Total line, stored as 10x (e.g., 220.5 = 2205).
     *                   Over wins when (awayScore + homeScore) * 10 >= lineTicks.
     *                   For example:
     *                   - If _lineTicks is 2205 (220.5) and combined score is 221, scaled to 2210: Over
     *                   - If _lineTicks is 2205 (220.5) and combined score is 220, scaled to 2200: Under
     * @return WinSide The winning side of the speculation
     */
    function scoreTotal(
        uint32 _awayScore,
        uint32 _homeScore,
        int32 _lineTicks
    ) private pure returns (WinSide) {
        // casting to 'int32' is safe because combined sports scores * 10 never exceed int32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 scaledTotal = int32(_awayScore + _homeScore) * 10;

        if (scaledTotal >= _lineTicks) {
            return WinSide.Over;
        } else {
            return WinSide.Under;
        }
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
            revert TotalScorerModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
