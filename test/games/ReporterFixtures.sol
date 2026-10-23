// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IOspexGames, Report} from "../../src/games/IOspexGames.sol";
import {IOspexReporter} from "../../src/games/IOspexReporter.sol";

// Review fixtures for an approval: the reporters the spec names ("a plain reporter, an owner or setter, a proxy
// and a delegated wallet"), reporters that lack the fixed-values read, and reporters whose read writes. A
// delegated wallet is not a contract; the tests make one with vm.etch.

/// @dev What an approved reporter should look like: everything fixed at deploy, no owner, no setter. Shaped like
///      the Chainlink reporter: its forwarder, its workflow owner and its workflow id, and the games address.
contract PlainReporter is IOspexReporter {
    IOspexGames public immutable i_games;
    address public immutable i_forwarder;
    address public immutable i_workflowOwner;
    bytes32 public immutable i_workflowId;

    constructor(IOspexGames games, address forwarder, address workflowOwner, bytes32 workflowId) {
        i_games = games;
        i_forwarder = forwarder;
        i_workflowOwner = workflowOwner;
        i_workflowId = workflowId;
    }

    function send(Report calldata r) external {
        i_games.report(r);
    }

    function fixedValues() external view returns (bytes memory) {
        return abi.encode(i_forwarder, i_workflowOwner, i_workflowId);
    }
}

/// @dev A reporter with an owner and a setter. Its code never changes, so its code hash cannot show that what it
///      does can: the owner moves its forwarder after it is approved. Review refuses it; the chain cannot.
contract OwnedReporter is IOspexReporter {
    IOspexGames public immutable i_games;
    address public owner;
    address public forwarder;

    constructor(IOspexGames games, address forwarder_) {
        i_games = games;
        owner = msg.sender;
        forwarder = forwarder_;
    }

    function setForwarder(address forwarder_) external {
        require(msg.sender == owner, "not the owner");
        forwarder = forwarder_;
    }

    function send(Report calldata r) external {
        require(msg.sender == forwarder, "not the forwarder");
        i_games.report(r);
    }

    function fixedValues() external view returns (bytes memory) {
        return abi.encode(forwarder);
    }
}

/// @dev One implementation behind the proxy below.
contract ReporterLogicA is IOspexReporter {
    function fixedValues() external pure returns (bytes memory) {
        return abi.encode(bytes32("logic A"));
    }
}

/// @dev Another implementation, swapped in after approval.
contract ReporterLogicB is IOspexReporter {
    function fixedValues() external pure returns (bytes memory) {
        return abi.encode(bytes32("logic B"));
    }
}

/// @dev A proxy reporter: its own code is a forwarder to whatever logic its admin points it at. Its code hash
///      is the proxy's, and stays the same when the admin swaps the logic. Review refuses it; the chain cannot.
contract ProxyReporter {
    /// @dev The ERC-1967 slots, so that tooling would read it as the proxy it is.
    bytes32 internal constant IMPLEMENTATION = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    constructor(address logic) {
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION, logic)
            sstore(ADMIN, caller())
        }
    }

    function upgradeTo(address logic) external {
        address admin;
        assembly ("memory-safe") {
            admin := sload(ADMIN)
        }
        require(msg.sender == admin, "not the admin");
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION, logic)
        }
    }

    fallback() external {
        assembly {
            let logic := sload(IMPLEMENTATION)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @dev A reporter without the fixed-values read.
contract NoReadReporter {
    IOspexGames public immutable i_games;

    constructor(IOspexGames games) {
        i_games = games;
    }

    function send(Report calldata r) external {
        i_games.report(r);
    }
}

/// @dev A reporter whose fixed-values read refuses to answer.
contract RevertingReadReporter {
    function fixedValues() external pure returns (bytes memory) {
        revert("no values");
    }
}

/// @dev A contract that answers every call, the read included, with nothing.
contract SilentReporter {
    fallback() external {}
}

/// @dev A reporter whose fixed-values read writes: it counts its reads. It answers with a well-formed value,
///      so only the read being made as a read (STATICCALL) can refuse it.
contract WritingReadReporter {
    uint256 public reads;

    function fixedValues() external returns (bytes memory) {
        ++reads;
        return abi.encode(reads);
    }
}

/// @dev A reporter whose fixed-values read, once armed, runs another ready call through the timelock before
///      answering. It answers with a well-formed value either way.
contract ReenteringReporter {
    TimelockController public timelock;
    address public target;
    bytes public payload;
    bytes32 public salt;
    bool public armed;

    function arm(TimelockController timelock_, address target_, bytes calldata payload_, bytes32 salt_) external {
        (timelock, target, payload, salt, armed) = (timelock_, target_, payload_, salt_, true);
    }

    function disarm() external {
        armed = false;
    }

    function fixedValues() external returns (bytes memory) {
        if (armed) {
            armed = false;
            timelock.execute(target, 0, payload, bytes32(0), salt);
        }
        return abi.encode(address(this));
    }
}
