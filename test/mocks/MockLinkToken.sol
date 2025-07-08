// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {console} from "forge-std/console.sol";

/// @title Mock LINK Token
/// @notice A simplified mock of the Chainlink LINK token for testing
/// @dev Extends OpenZeppelin's ERC20 implementation
contract MockLinkToken is ERC20 {
    bool public forceTransferAndCallReturnFalse = false;
    function setForceTransferAndCallReturnFalse(bool val) external {
        forceTransferAndCallReturnFalse = val;
    }

    constructor() ERC20("Mock LINK", "LINK") {
        // Mint initial supply to deployer
        _mint(msg.sender, 1000000 * 10**18);
    }

    /// @notice Mint tokens to a specified address
    /// @param to Address to receive tokens
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferAndCall(
        address to,
        uint256 amount,
        bytes memory data
    ) public returns (bool) {
        if (forceTransferAndCallReturnFalse) {
            return false;
        }
        console.log("transferAndCall called");
        console.log("to:", to);
        console.log("amount:", amount);
        console.log("data length:", data.length);

        bool transferred = transfer(to, amount);
        if (!transferred) {
            console.log("Transfer failed");
            return false;
        }

        IERC1363Receiver receiver = IERC1363Receiver(to);
        bytes4 retval = receiver.onTransferReceived(msg.sender, msg.sender, amount, data);
        
        console.log("Receiver response:", uint32(retval));
        require(retval == IERC1363Receiver.onTransferReceived.selector, "ERC1363: receiver returned wrong value");
        
        return true;
    }
} 