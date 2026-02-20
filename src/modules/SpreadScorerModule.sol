// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {Contest, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";

/**
 * @title SpreadScorerModule
 * @author ospex.org
 * @notice Module for spread (point difference) scoring logic
 */

contract SpreadScorerModule is IScorerModule {
    /// @notice Error for not a speculation module
    error SpreadScorerModule__NotSpeculationModule(address caller);
    /// @notice Error for score not finalized
    error SpreadScorerModule__ScoreNotFinalized(uint256 contestId);
    /// @notice Error for module not set
    error SpreadScorerModule__ModuleNotSet(bytes32 moduleType);

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Modifier to check if the caller is a speculation module
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(keccak256("SPECULATION_MODULE"))) {
            revert SpreadScorerModule__NotSpeculationModule(msg.sender);
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
     * @notice Determines the winning side for a spread speculation
     * @param contestId The ID of the contest to score
     * @param theNumber The spread value (positive: home favored, negative: away favored)
     * @return WinSide The winning side
     */
    function determineWinSide(
        uint256 contestId,
        int32 theNumber
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);

        return scoreSpread(contest.awayScore, contest.homeScore, theNumber);
    }

    /**
     * @notice Scores a spread speculation
     * @param _awayScore Away team score
     * @param _homeScore Home team score
     * @param _theNumber Point spread value. Positive means home team is favored, negative means away team is favored
     *                   Positive values indicate the home team is favored and must win by more than this value to cover the spread.
     *                   Negative values indicate the away team is favored and the home team must either win outright or lose by less than the absolute value of the spread to cover.
     *                   For example:
     *                   - If _theNumber is 3, the home team must win by more than 3 points/goals/runs to cover.
     *                   - If _theNumber is -4, the home team covers the spread by either winning outright or losing by less than 4 points/goals/runs.
     * @return WinSide The winning side of the speculation
     */
    function scoreSpread(
        uint32 _awayScore,
        uint32 _homeScore,
        int32 _theNumber
    ) private pure returns (WinSide) {
        if (int32(_awayScore) + _theNumber >= int32(_homeScore)) {
            return WinSide.Away;
        } else {
            return WinSide.Home;
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
            revert SpreadScorerModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
