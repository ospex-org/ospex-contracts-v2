// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ApproveLinkForOracle
 * @notice Script to approve LINK spending for the OracleModule
 * @dev Run with: forge script script/ApproveLinkForOracle.s.sol:ApproveLinkForOracle --rpc-url $AMOY_RPC_URL --broadcast --account deployer
 */
contract ApproveLinkForOracle is Script {
    // Contract addresses
    address constant LINK_TOKEN = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    address constant ORACLE_MODULE = 0xc8536E7cca2af6E9B632167810Ff55CD203a5a81;
    
    // Approve a large amount (10000 LINK should be plenty)
    uint256 constant APPROVAL_AMOUNT = 10000 * 10**18;

    function run() external {
        // Get deployer address
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        vm.startBroadcast(deployer);
        
        IERC20 linkToken = IERC20(LINK_TOKEN);
        
        // Check current LINK balance
        uint256 balance = linkToken.balanceOf(deployer);
        console.log("Current LINK balance:", balance / 10**18, "LINK");
        
        // Check current allowance
        uint256 currentAllowance = linkToken.allowance(deployer, ORACLE_MODULE);
        console.log("Current allowance:", currentAllowance / 10**18, "LINK");
        
        if (balance == 0) {
            console.log("ERROR: No LINK tokens in wallet");
            vm.stopBroadcast();
            return;
        }
        
        // Approve LINK spending
        bool success = linkToken.approve(ORACLE_MODULE, APPROVAL_AMOUNT);
        
        if (success) {
            console.log("Successfully approved", APPROVAL_AMOUNT / 10**18, "LINK for OracleModule");
            
            // Verify the approval
            uint256 newAllowance = linkToken.allowance(deployer, ORACLE_MODULE);
            console.log("New allowance:", newAllowance / 10**18, "LINK");
        } else {
            console.log("ERROR: Failed to approve LINK");
        }
        
        vm.stopBroadcast();
    }
} 