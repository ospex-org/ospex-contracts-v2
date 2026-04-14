// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../src/modules/SpeculationModule.sol";
import {WinSide, Speculation} from "../../src/core/OspexTypes.sol";

contract MockSpeculationModule is SpeculationModule {
    constructor(address core, uint8 tokenDecimals, uint32 voidCooldown, uint256 minSpeculationAmount)
        SpeculationModule(core, tokenDecimals, voidCooldown, minSpeculationAmount)
    {}

    // Test-only helper to set winSide for a speculation
    function setSpeculationWinSide(uint256 specId, WinSide side) external {
        s_speculations[specId].winSide = side;
    }

    // Test-only helper to set a complete speculation for testing
    // This populates the parent contract's storage directly
    function setTestSpeculation(uint256 specId, Speculation memory speculation) external {
        s_speculations[specId] = speculation;
    }
} 