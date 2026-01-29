// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IModule
 * @notice Base interface for all Ospex plug-in modules
 */
interface IModule {
    /// @notice Returns the module type identifier (e.g., keccak256("CONTEST_MODULE"))
    /// @return moduleType The bytes32 module type
    function getModuleType() external pure returns (bytes32 moduleType);
}
