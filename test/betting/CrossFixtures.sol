// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {ICoinHook, TestCoin} from "../games/CoinFixtures.sol";

// Fixtures for the Cross's tests: an account that is a key with code at its address, so it both signs and can be
// called back by a coin with transfer hooks; a coin whose refusals and answers a test scripts account by
// account; and a sender that is a contract, for two Crosses in one transaction.

/// @dev Code a test places at a key's address. The key still signs. When the coin calls the address back, during
///      a transfer from it, it makes the calls it was armed with, once, and keeps what each answered: what an
///      account's own code could try from inside a pull. Unarmed, it does nothing.
contract CallbackAccount is ICoinHook {
    struct Step {
        address target;
        bytes data;
    }

    Step[] internal steps;
    bool public armed;
    /// @notice How many times the coin has called this address back.
    uint256 public calls;
    bool[] public succeeded;
    bytes[] public answers;
    /// @notice Gas to burn on a call-back, in a loop, before anything else. Zero burns none.
    uint256 public burn;
    /// @dev A read to make on the next call-back, and the answer on which the call-back refuses the transfer.
    address internal refuseOn;
    bytes internal refuseRead;
    bytes internal refuseAnswer;

    /// @notice Arm the next call-back with one call.
    function arm(address target, bytes calldata data) external {
        delete steps;
        delete succeeded;
        delete answers;
        steps.push(Step(target, data));
        armed = true;
    }

    /// @notice Add a second call to an armed call-back.
    function armAlso(address target, bytes calldata data) external {
        steps.push(Step(target, data));
    }

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    /// @notice On the next call-back, make this read, and revert if it answers exactly `answer`: the transfer
    ///         the coin is making then fails. If it answers anything else the call-back returns and the
    ///         transfer goes through. So whether the transfer failed says what the read returned, which a
    ///         reverted call-back could not otherwise report.
    function armRefusal(address target, bytes calldata read, bytes calldata answer) external {
        refuseOn = target;
        refuseRead = read;
        refuseAnswer = answer;
    }

    function onCoin() external {
        ++calls;
        if (burn != 0) {
            uint256 until = gasleft() > burn ? gasleft() - burn : 0;
            uint256 sink;
            while (gasleft() > until) {
                ++sink;
            }
        }
        if (refuseOn != address(0)) {
            (bool read, bytes memory got) = refuseOn.staticcall(refuseRead);
            if (read && keccak256(got) == keccak256(refuseAnswer)) revert("the read answered as armed");
        }
        if (!armed) return;
        armed = false;
        for (uint256 i; i < steps.length; ++i) {
            (bool ok, bytes memory answer) = steps[i].target.call(steps[i].data);
            succeeded.push(ok);
            answers.push(answer);
        }
    }

    /// @notice What the armed call-back's calls answered, in order.
    function results() external view returns (bool[] memory ok, bytes[] memory answer) {
        return (succeeded, answers);
    }
}

/// @dev A coin a test scripts. For a named account it refuses a transfer from it by reverting, by reverting with
///      bytes the test chose, or by answering false; and for a named caller it answers that caller's reads of a
///      balance with a revert that carries bytes the test chose. Otherwise it is a plain six-decimal coin.
contract ScriptedCoin is TestCoin {
    enum Refusal {
        None,
        Reverts,
        RevertsWith,
        AnswersFalse
    }

    mapping(address => Refusal) public refusal;
    mapping(address => bytes) public refusalData;
    address public balanceReader;
    bytes public balanceRevert;
    /// @notice A spender whose transfers need no allowance, as some coins give a contract they trust.
    mapping(address => bool) public trusted;
    /// @notice An account whose balance reads as zero to one reader, while its coin moves as ever.
    mapping(address => address) public hiddenFrom;

    error Refused(address account);

    function setRefusal(address account, Refusal how, bytes calldata data) external {
        refusal[account] = how;
        refusalData[account] = data;
    }

    /// @notice From now, every balance read made by `reader` reverts with `data`. The zero address clears it.
    function setBalanceRevert(address reader, bytes calldata data) external {
        balanceReader = reader;
        balanceRevert = data;
    }

    function setTrusted(address spender, bool on) external {
        trusted[spender] = on;
    }

    function setHidden(address account, address reader) external {
        hiddenFrom[account] = reader;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (hiddenFrom[account] != address(0) && msg.sender == hiddenFrom[account]) return 0;
        if (balanceReader != address(0) && msg.sender == balanceReader) {
            bytes memory data = balanceRevert;
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        return super.balanceOf(account);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        Refusal how = refusal[from];
        if (how == Refusal.Reverts) revert Refused(from);
        if (how == Refusal.RevertsWith) {
            bytes memory data = refusalData[from];
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        if (how == Refusal.AnswersFalse) return false;
        if (trusted[msg.sender]) {
            _transfer(from, to, value);
            return true;
        }
        return super.transferFrom(from, to, value);
    }
}

/// @dev A sender that is a contract: it sends one Cross, cancels an order of its own, and sends a second Cross,
///      all in one transaction. Each Cross arrives as the call's bytes, and a refusal comes back unchanged.
contract TwoCrosses {
    function send(
        OspexMatching matching,
        bytes calldata crossOne,
        OspexMatching.OspexOrder calldata ownOrder,
        bytes calldata crossTwo
    ) external {
        _call(address(matching), crossOne);
        matching.cancelOrder(ownOrder);
        _call(address(matching), crossTwo);
    }

    function _call(address target, bytes calldata data) private {
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}

/// @dev A sender that is a contract: it sends one Cross, swallows its refusal and keeps it, and sends a second
///      Cross in the same transaction, whose refusal, if any, comes back unchanged. For a Cross that reverts short
///      and a deeper one after it: the second must find no Cross in progress.
contract RetryingSender {
    bool public firstFilled;
    bytes public firstRefusal;

    function send(OspexMatching matching, bytes calldata crossOne, bytes calldata crossTwo) external {
        (bool ok, bytes memory err) = address(matching).call(crossOne);
        firstFilled = ok;
        firstRefusal = err;
        (ok, err) = address(matching).call(crossTwo);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}
