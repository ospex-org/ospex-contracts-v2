// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {Contest, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";

/**
 * @title MoneylineScorerModule
 * @author ospex.org
 * @notice Module for moneyline (straight win/loss) scoring logic
 */

contract MoneylineScorerModule is IScorerModule {
    /// @notice Error for not a score manager
    error MoneylineScorerModule__NotSpeculationModule(address caller);
    /// @notice Error for module not set
    error MoneylineScorerModule__ModuleNotSet(bytes32 moduleType);

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    /// @notice Modifier to check if the caller is a speculation module
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(keccak256("SPECULATION_MODULE"))) {
            revert MoneylineScorerModule__NotSpeculationModule(msg.sender);
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
     * @notice Determines the winning side for a moneyline speculation
     * @param contestId The ID of the contest to score
     * @return WinSide The winning side
     */
    function determineWinSide(
        uint256 contestId,
        int32 /*theNumber*/
    ) external view override onlySpeculationModule returns (WinSide) {
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);

        return scoreMoneyline(contest.awayScore, contest.homeScore);
    }

    /**
     * @notice Scores a moneyline speculation
     * @param _awayScore Away team score
     * @param _homeScore Home team score
     * @return WinSide The winning side of the speculation
     */
    function scoreMoneyline(
        uint32 _awayScore,
        uint32 _homeScore
    ) private pure returns (WinSide) {
        if (_awayScore > _homeScore) {
            return WinSide.Away;
        } else if (_homeScore > _awayScore) {
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
            revert MoneylineScorerModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
