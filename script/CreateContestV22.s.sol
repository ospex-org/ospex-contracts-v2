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
    // Address of deployed contest manager on Amoy
    address constant ORACLE_MODULE = 0xc8536E7cca2af6E9B632167810Ff55CD203a5a81;
    address constant CONTEST_MODULE =
        0x8bE406158D7709A72f1331F3186881C19e0e6193;
    bytes constant ENCRYPTED_SECRETS_URLS =
        hex"53962f740dd4581471242d29d2a1994902f54872f87f69338234dcdca17201d64cb1448a421faac63ee5ecded2d534292a9d2d2d7e005ed13f0ae6e9b697422837494053436d7b68a0dd60d8e57f30254c2c54a5d8fa832e9a17b4e038c5107aaecd787310f8f877c21f9c3984cfae295a558ae6d1a7c69ccbbaeabe174e1cd6b078a58705f416552e9eb8b11127971aa324b0fcf86f2b64b6a63074895477b0880f560799e48f8ad67e71cbc3127d6e57da064b620196f3fe1b9fcea28aa2b5a592b760b197981805683ffe9c25ce46c7";

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
        console.log("\nCreating contest with following parameters:");
        console.log("RundownId: e5c7f9793d24c6c9fbf9976cd900ef84");
        console.log("SportspageId: 324283");
        console.log("JsonoddsId: a50f184a-ffda-4682-a0cb-9476e50f617d");
        console.log("SubscriptionId: 416");
        console.log("GasLimit: 300000");

        // Try to create a contest and catch any errors
        try
            oracleModule.createContestFromOracle(
                "e5c7f9793d24c6c9fbf9976cd900ef84",
                "324283",
                "a50f184a-ffda-4682-a0cb-9476e50f617d",
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
