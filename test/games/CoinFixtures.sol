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
///      transfer from or to an address it has blocked. Anyone pauses and blocks; the tests do. It also does one
///      thing USDC does not: given a cut, it keeps that much of each transfer for itself (all of a smaller one)
///      and delivers the rest, as a coin with a transfer fee does. Minting takes no cut.
contract RefusingCoin is TestCoin {
    bool public paused;
    mapping(address => bool) public blocked;
    uint256 public cut;

    error Paused();
    error Blocked(address account);

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlocked(address account, bool blocked_) external {
        blocked[account] = blocked_;
    }

    function setCut(uint256 cut_) external {
        cut = cut_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        uint256 kept = from == address(0) || to == address(0) ? 0 : value < cut ? value : cut;
        if (kept != 0) super._update(from, address(this), kept);
        super._update(from, to, value - kept);
    }
}

/// @dev A coin that, given a bonus, delivers that much more than was sent on each transfer, minting it: the
///      other way a transfer can move a balance by other than the amount sent.
contract BonusCoin is TestCoin {
    uint256 public bonus;

    function setBonus(uint256 bonus_) external {
        bonus = bonus_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && bonus != 0) super._update(address(0), to, bonus);
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
