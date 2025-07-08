// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC20 (USDC-like, 6 decimals)
 * @notice Minimal ERC20 implementation for testing purposes. Mimics USDC (6 decimals).
 *         Used in tests to simulate a real ERC20 token with 6 decimals, such as USDC.
 *         The total supply is minted to the deployer for convenience.
 *
 * Usage:
 *   - Use this contract in tests where a 6-decimal token is required.
 *   - Set min/max bet amounts in test to match 6 decimals (e.g., 1 USDC = 1_000_000).
 */
contract MockERC20 is IERC20 {
    string public name = "Mock USDC";
    string public symbol = "MOCKUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply = 1_000_000_000_000_000; // 1 trillion units (1,000,000,000 USDC)
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Not allowed");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
} 