// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IOspexModule
 * @author ospex.org
 * @notice What every module of the betting set answers: its type, which the core checks against the type it is
 *         registered under at bootstrap.
 */
interface IOspexModule {
    /// @notice The module's type: the hash of its name, keccak256("MARKET_MODULE") for the markets module.
    function getModuleType() external pure returns (bytes32 moduleType);
}
