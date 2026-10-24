// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Coins for the creation fee's tests. The games set takes its fee in one coin, fixed at deploy: USDC on
// Polygon at launch. These stand in for it.

/// @dev A coin with six decimals, as USDC has. Anyone mints.
contract TestCoin is ERC20 {
    constructor() ERC20("Test USD Coin", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A coin that refuses a transfer the two ways USDC can: every transfer while it is paused, and any
///      transfer from or to an address it has blocked. Anyone pauses and blocks; the tests do.
contract RefusingCoin is TestCoin {
    bool public paused;
    mapping(address => bool) public blocked;

    error Paused();
    error Blocked(address account);

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlocked(address account, bool blocked_) external {
        blocked[account] = blocked_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}

/// @dev A coin that, once set to refuse, answers false and moves nothing instead of reverting, as some coins
///      do. A caller that reads no answer would take the call as paid.
contract FalseCoin is TestCoin {
    bool public refusing;

    function setRefusing(bool refusing_) external {
        refusing = refusing_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (refusing) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (refusing) return false;
        return super.transferFrom(from, to, value);
    }
}
