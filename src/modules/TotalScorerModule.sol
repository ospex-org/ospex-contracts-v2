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
    /// @notice Error for score not finalized
    error TotalScorerModule__ScoreNotFinalized(uint256 contestId);
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
     * @param theNumber The predicted total combined score
     * @return WinSide The winning side
     */
    function determineWinSide(
        uint256 contestId,
        int32 theNumber
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);

        return scoreTotal(contest.awayScore, contest.homeScore, theNumber);
    }

    /**
     * @notice Scores a total points speculation
     * @param _awayScore Away team score
     * @param _homeScore Home team score
     * @param _theNumber Predicted total combined score for the speculation
     *                   For example:
     *                   - If _theNumber is 195 and the combined score is 196, the result is Over
     *                   - If _theNumber is 195 and the combined score is 194, the result is Under
     *                   - If the combined score equals _theNumber, the result is Over
     * @return WinSide The winning side of the speculation
     */
    function scoreTotal(
        uint32 _awayScore,
        uint32 _homeScore,
        int32 _theNumber
    ) private pure returns (WinSide) {
        if (int32(_awayScore + _homeScore) >= _theNumber) {
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
