// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {OracleModule} from "../src/modules/OracleModule.sol";
import {ContestModule} from "../src/modules/ContestModule.sol";

/**
 * @title CreateContest
 * @notice Script to create a new contest with teams on the Ospex platform
 * @dev Run with: forge script script/contest/CreateContest.s.sol:CreateContest --rpc-url [RPC_URL] --broadcast --account [ACCOUNT]
 */
contract CreateContestV22 is Script {
    // Amoy v2.3 deployment (2026-04-10)
    address constant ORACLE_MODULE = 0x18F8BFfB2250635A419982eAe69099d97f596F8F;
    address constant CONTEST_MODULE = 0x817f555E131042F0dbCc5F6C6b9F9E30bC9aBe62;
    bytes constant ENCRYPTED_SECRETS_URLS =
        hex"d32013655bd4b1e55a6bf1b7e9df07280379d299a2e13b2e6aa7f033eb350502373d4e9b4d0feb9815338c6806e04f17636b64b989ce8065060163d51309b71324fb7c8952361b9eb91bb743b58596c404886518e9c0541b905f235f8db209fadd41615c1f436fbfc4cbfbb84124a4921ac3e83ad351189e145317ce17e49ecaeae9919bd6d44a3436de52df4f441e1ba9f5d74d562a541cadbaef5963a206490e2d2fd62b291d3d79ef98521ee0ed50345f6f7aab1d0d0a78af95a015ec051dd00eda0fd3eff0beb853c2d3a5b94a6589";

    // Function to read the file content as a string during script compilation
    function getSourceCode() internal view returns (string memory) {
        string memory path = "chainlink-functions/createContest.js";
        return vm.readFile(path);
    }

    function run() external {
        // Get deployer address
        address deployer = vm.envOr(
            "DEPLOYER",
            address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3)
        );
        vm.startBroadcast(deployer);

        OracleModule oracleModule = OracleModule(ORACLE_MODULE);

        ContestModule contestModule = ContestModule(CONTEST_MODULE);

        // Get the source code
        string memory sourceCode = getSourceCode();

        // Calculate hash from source code
        bytes32 calculatedHash = keccak256(abi.encodePacked(sourceCode));
        console.log("Source code length:", bytes(sourceCode).length, "bytes");
        console.log("Calculated source hash:");
        console.logBytes32(calculatedHash);

        // Get current hash from contract
        bytes32 contractHash;
        try contestModule.s_createContestSourceHash() returns (
            bytes32 currentHash
        ) {
            contractHash = currentHash;
            console.log("Current contract hash:");
            console.logBytes32(contractHash);

            if (calculatedHash == contractHash) {
                console.log("MATCH: Source hash matches contract hash");
            } else {
                console.log("MISMATCH: Source hash differs from contract hash");
            }
        } catch {
            console.log("Failed to read current hash from contract");
        }

        // Log information before creating the contest
        // Phoenix Suns @ Los Angeles Lakers — NBA — 2026-04-11 02:30 UTC
        console.log("\nCreating contest with following parameters:");
        console.log("RundownId: afe40b8598c5675226a0f6b6acacf820");
        console.log("SportspageId: 329277");
        console.log("JsonoddsId: c76d1939-52b3-4df2-b64c-026ca51e852e");
        console.log("SubscriptionId: 416");
        console.log("GasLimit: 300000");

        // Try to create a contest and catch any errors
        try
            oracleModule.createContestFromOracle(
                "afe40b8598c5675226a0f6b6acacf820",
                "329277",
                "c76d1939-52b3-4df2-b64c-026ca51e852e",
                sourceCode,
                bytes32(
                    0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd
                ),
                1,
                ENCRYPTED_SECRETS_URLS,
                416,
                300000
            )
        {
            console.log("Contest creation transaction submitted successfully");
        } catch Error(string memory reason) {
            console.log("Error:", reason);

            // If we have a revert reason, check if it's the hash error
            if (
                bytes(reason).length > 0 &&
                keccak256(abi.encodePacked(reason)) ==
                keccak256(
                    abi.encodePacked(
                        "OspexContestManager__IncorrectSourceHash()"
                    )
                )
            ) {
                console.log("\nDetected IncorrectSourceHash error!");
                console.log("Attempted source hash:");
                console.logBytes32(calculatedHash);

                if (contractHash != bytes32(0)) {
                    console.log("Contract expected hash:");
                    console.logBytes32(contractHash);

                    console.log("\nTo fix this issue, either:");
                    console.log(
                        "1. Update your source code to match the expected hash"
                    );
                    console.log("2. Update the contract's expected hash with:");
                    console.log(
                        "   contestManager.setContestSourceHash(calculatedHash)"
                    );
                }
            }
        } catch (bytes memory lowLevelData) {
            console.log("Failed with low level error");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }
}
