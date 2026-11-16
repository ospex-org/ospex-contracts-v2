// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// Fixtures for the approved agent's tests: code a contract account, a contract agent or a key's address (EIP-7702)
// can carry, which answers a wallet's signature question in one of four ways and acts as itself when driven; and
// a contract that passes a call along, so that the immediate caller at the matching module is the contract and
// not whoever asked it.

/// @dev A wallet's code. Its signature check answers as its mode says: yes to everything, the magic value; burn,
///      which spends every unit of gas it is given; refuse, a revert; or flip, the magic value on even blocks
///      and nothing on odd ones. Nothing in the betting set ever asks it, which is what the tests show: a wallet
///      of any mode trades the same. `exec` lets a test drive the wallet as itself, so that a call's msg.sender
///      is this address: a fixture's door, open to anyone, and no part of a wallet anyone would deploy.
contract WalletCode {
    enum Mode {
        Yes,
        Burn,
        Refuse,
        Flip
    }

    bytes4 internal constant MAGIC = 0x1626ba7e;
    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    /// @notice A wallet's signature question, EIP-1271: the answer the mode says.
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        Mode m = mode;
        if (m == Mode.Yes) return MAGIC;
        if (m == Mode.Refuse) revert("the wallet refuses");
        if (m == Mode.Flip) return block.number % 2 == 0 ? MAGIC : bytes4(0);
        // Burn: a loop that writes the scratch space until the gas is gone.
        assembly ("memory-safe") {
            for {} 1 {} { mstore(0, keccak256(0, 0x20)) }
        }
        return bytes4(0);
    }

    /// @notice Make `data` a call of this address to `target`. A refusal comes back as the target gave it.
    function exec(address target, bytes calldata data) external returns (bytes memory answer) {
        bool ok;
        (ok, answer) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
    }
}

/// @dev A contract that passes a call along as its own: whoever asks it, the contract is the immediate caller at
///      the target, and tx.origin is whoever sent the transaction. A refusal comes back as the target gave it.
contract Intermediary {
    function forward(address target, bytes calldata data) external returns (bytes memory answer) {
        bool ok;
        (ok, answer) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
    }
}
