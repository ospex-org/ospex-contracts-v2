// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";
import "../src/modules/OracleModule.sol";

/**
 * @title UpdateOracleModule
 * @notice Script to redeploy OracleModule and update the core registry
 * @dev Updates OracleModule with same Chainlink Functions configuration
 */
contract UpdateOracleModule is Script {
    // Amoy testnet-specific addresses (same as DeployAmoy.s.sol)
    address constant LINK_ADDRESS = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    address constant FUNCTIONS_ROUTER = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De;
    bytes32 constant DON_ID = bytes32("fun-polygon-amoy-1");

    struct ModuleConfig {
        address ospexCoreAddress;
    }

    function run() external {
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));

        ModuleConfig memory config = ModuleConfig({
            ospexCoreAddress: vm.envOr("OSPEX_CORE_ADDRESS", 0x829A2B2deaBd3b06f6E5938220eCfB450CE75e24)
        });

        require(config.ospexCoreAddress != address(0), "OSPEX_CORE_ADDRESS required");

        console.log("=== UPDATE ORACLE MODULE ===");
        console.log("Deployer:", deployer);
        console.log("OspexCore:", config.ospexCoreAddress);
        console.log("LINK Token:", LINK_ADDRESS);
        console.log("Functions Router:", FUNCTIONS_ROUTER);
        console.log("DON ID:", string(abi.encodePacked(DON_ID)));

        vm.startBroadcast(deployer);

        // Deploy new OracleModule
        address newOracleModule = address(new OracleModule(
            config.ospexCoreAddress,
            FUNCTIONS_ROUTER,
            LINK_ADDRESS,
            DON_ID
        ));
        console.log("OracleModule deployed:", newOracleModule);

        // Update registry
        OspexCore core = OspexCore(config.ospexCoreAddress);

        core.registerModule(keccak256("ORACLE_MODULE"), newOracleModule);
        console.log("OracleModule registered");

        // Summary
        console.log("\n=== UPDATE COMPLETE ===");
        console.log("ORACLE_MODULE_ADDRESS=", newOracleModule);
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Fund the new OracleModule with LINK tokens");
        console.log("2. Approve LINK spending for the new OracleModule");
        console.log("3. Update frontend and MCP server configs with new address");

        vm.stopBroadcast();
    }
}
