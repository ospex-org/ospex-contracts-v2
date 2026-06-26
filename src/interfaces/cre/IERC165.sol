// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Copied verbatim from the Chainlink CRE consumer-contract docs:
/// https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts.md
/// Mirrors OpenZeppelin's IERC165 (kept local so the CRE receiver interfaces are
/// self-contained, matching the official CRE template layout).
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
