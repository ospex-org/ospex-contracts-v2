// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IScorerModule} from "../interfaces/IScorerModule.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {Contest, WinSide} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";

/**
 * @title SpreadScorerModule
 * @author ospex.org
 * @notice Scores spread (point difference) speculations. The away team's score is adjusted
 *         by the spread line; if adjusted away > home, Away wins. Equal = Push.
 */
contract SpreadScorerModule is IScorerModule {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a non-SpeculationModule address calls determineWinSide
    error SpreadScorerModule__NotSpeculationModule(address caller);
    /// @notice Thrown when a required module is not registered in OspexCore
    error SpreadScorerModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the OspexCore address is zero
    error SpreadScorerModule__InvalidOspexCore();

    // ──────────────────────────── Modifiers ────────────────────────────

    /// @dev Restricts access to the registered SpeculationModule
    modifier onlySpeculationModule() {
        if (msg.sender != _getModule(SPECULATION_MODULE)) {
            revert SpreadScorerModule__NotSpeculationModule(msg.sender);
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the SpreadScorerModule
    /// @param ospexCore_ The OspexCore contract address
    constructor(address ospexCore_) {
        if (ospexCore_ == address(0))
            revert SpreadScorerModule__InvalidOspexCore();
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

        return _scoreSpread(contest.awayScore, contest.homeScore, lineTicks);
    }

    /**
     * @notice Scores a spread speculation
     * @dev Scores are scaled to 10x internally to match lineTicks representation.
     *      Away side covers when awayScore * 10 + lineTicks > homeScore * 10.
     *      Exact equality on the adjusted spread results in a Push.
     * @param awayScore Away team score (raw, not scaled)
     * @param homeScore Home team score (raw, not scaled)
     * @param lineTicks Point spread (10x format, e.g. -35 = -3.5)
     * @return The winning side (Away, Home, or Push)
     */
    function _scoreSpread(
        uint32 awayScore,
        uint32 homeScore,
        int32 lineTicks
    ) private pure returns (WinSide) {
        // Safe cast: sports scores * 10 never exceed int32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 scaledAway = int32(awayScore) * 10;
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 scaledHome = int32(homeScore) * 10;

        int32 adjustedAway = scaledAway + lineTicks;

        if (adjustedAway > scaledHome) {
            return WinSide.Away;
        } else if (adjustedAway < scaledHome) {
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
            revert SpreadScorerModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
