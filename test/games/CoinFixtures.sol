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

/// @dev What a coin with transfer hooks calls back.
interface ICoinHook {
    function onCoin() external;
}

/// @dev A coin that does, on request, what coins with transfer fees, rebates and hooks do, none of which USDC
///      does. With a cut it keeps that much of each transfer (all of a smaller one) and delivers the rest. With
///      a charge it takes that much more from the sender than it sends. With a refund it gives the sender back
///      that much of each transfer, minting it. A sender marked exempt meets none of the three. After a
///      transfer from or to an address it was told to call, it calls that address back, and what that address
///      does from there is its own. Minting and burning take nothing and call no one.
contract TrickCoin is TestCoin {
    uint256 public cut;
    uint256 public charge;
    uint256 public refund;
    mapping(address => bool) public exempt;
    mapping(address => bool) public hooked;

    function setCut(uint256 cut_) external {
        cut = cut_;
    }

    function setCharge(uint256 charge_) external {
        charge = charge_;
    }

    function setRefund(uint256 refund_) external {
        refund = refund_;
    }

    function setExempt(address account, bool on) external {
        exempt[account] = on;
    }

    function setHooked(address account, bool on) external {
        hooked[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool plain = from == address(0) || to == address(0) || exempt[from];
        uint256 kept = plain ? 0 : value < cut ? value : cut;
        if (kept != 0) super._update(from, address(this), kept);
        super._update(from, to, value - kept);
        if (!plain && charge != 0) super._update(from, address(this), charge);
        if (!plain && refund != 0) super._update(address(0), from, refund);
        if (from == address(0) || to == address(0)) return;
        if (hooked[from]) ICoinHook(from).onCoin();
        if (hooked[to]) ICoinHook(to).onCoin();
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
