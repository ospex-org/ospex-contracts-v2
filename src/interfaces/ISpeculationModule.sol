// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Speculation} from "../core/OspexTypes.sol";
import {IModule} from "./IModule.sol";

/**
 * @title ISpeculationModule
 * @notice Interface for the Ospex SpeculationModule. Handles creation and settlement
 *         of speculations (betting markets) for contests.
 */
interface ISpeculationModule is IModule {
    /// @notice Returns the immutable void cooldown in seconds
    function i_voidCooldown() external view returns (uint32);

    /// @notice Returns the immutable minimum speculation amount (USDC token units)
    function i_minSpeculationAmount() external view returns (uint256);

    /// @notice Returns the token decimals (e.g. 6 for USDC)
    function i_tokenDecimals() external view returns (uint8);

    /// @notice Creates a new speculation. Only callable by PositionModule.
    /// @param contestId The contest this speculation is for
    /// @param scorer The scorer module address
    /// @param lineTicks The line number (10x format, 0 for moneyline)
    /// @param maker The address that initiated the market (pays floor half of creation fee)
    /// @param taker The address that completed the market (pays remainder of creation fee)
    /// @return speculationId The new speculation ID
    function createSpeculation(
        uint256 contestId,
        address scorer,
        int32 lineTicks,
        address maker,
        address taker
    ) external returns (uint256 speculationId);

    /// @notice Settles a speculation after the contest is scored. Permissionless.
    /// @dev Auto-voids if the void cooldown has elapsed and the contest remains unscored.
    /// @param speculationId The speculation to settle
    function settleSpeculation(uint256 speculationId) external;

    /// @notice Gets the details of a speculation
    /// @param speculationId The speculation ID
    /// @return speculation The Speculation struct
    function getSpeculation(
        uint256 speculationId
    ) external view returns (Speculation memory speculation);

    /// @notice Gets a speculation ID by its unique key (contest/scorer/line)
    /// @param contestId The contest ID
    /// @param scorer The scorer module address
    /// @param lineTicks The line number (10x format)
    /// @return speculationId The speculation ID (0 if none exists)
    function getSpeculationId(
        uint256 contestId,
        address scorer,
        int32 lineTicks
    ) external view returns (uint256 speculationId);
}
