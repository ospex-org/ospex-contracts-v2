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
     * @param lineTicks The spread value stored as 10x (e.g., -3.5 = -35)
     * @return WinSide The winning side
     */
    function determineWinSide(
        uint256 contestId,
        int32 lineTicks
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);

        return scoreSpread(contest.awayScore, contest.homeScore, lineTicks);
    }

    /**
     * @notice Scores a spread speculation
     * @param _awayScore Away team score (raw game score, not scaled)
     * @param _homeScore Home team score (raw game score, not scaled)
     * @param _lineTicks Point spread value, stored as 10x (e.g., -3.5 = -35).
     *                   Positive means home team is favored, negative means away team is favored.
     *                   Scores are scaled to 10x internally to match lineTicks's representation.
     *                   Away side covers when awayScore * 10 + lineTicks >= homeScore * 10.
     * @return WinSide The winning side of the speculation
     */
    function scoreSpread(
        uint32 _awayScore,
        uint32 _homeScore,
        int32 _lineTicks
    ) private pure returns (WinSide) {
        // casting to 'int32' is safe because sports scores * 10 never exceed int32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 scaledAway = int32(_awayScore) * 10;
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 scaledHome = int32(_homeScore) * 10;

        // add lineTicks to away
        int32 adjustedAway = scaledAway + _lineTicks;

        if (adjustedAway > scaledHome) {
            return WinSide.Away;
        } else if (adjustedAway < scaledHome) {
            return WinSide.Home;
        } else {
            return WinSide.Push;
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
