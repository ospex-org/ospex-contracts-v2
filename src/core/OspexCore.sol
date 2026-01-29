// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OspexCore
 * @author ospex.org
 * @notice Minimal core contract for Ospex protocol: manages module registry and access control
 * @dev Implements the minimal core + plug-in modules pattern. All business logic is in modules.
 *      The core manages module addresses, access control, and protocol-wide event emission.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {FeeType} from "./OspexTypes.sol";

contract OspexCore is AccessControl {
    /// @notice Emitted when a module address is invalid
    /// @param moduleAddress The address of the module
    error OspexCore__InvalidModuleAddress(address moduleAddress);
    /// @notice Emitted when a new admin address is invalid
    /// @param newAdmin The address of the new admin
    error OspexCore__InvalidAdminAddress(address newAdmin);
    /// @notice Emitted when a module is not registered
    /// @param moduleAddress The address of the module
    error OspexCore__NotRegisteredModule(address moduleAddress);
    /// @notice Emitted when a non-pending admin attempts to set a new admin
    /// @param caller The address of the caller
    error OspexCore__NotPendingAdmin(address caller);

    /// @notice Emitted when a module is registered or updated
    /// @param moduleType The bytes32 identifier for the module type
    /// @param moduleAddress The address of the module contract
    event ModuleRegistered(
        bytes32 indexed moduleType,
        address indexed moduleAddress
    );

    /// @notice Emitted when the protocol admin is changed
    /// @param previousAdmin The previous admin address
    /// @param newAdmin The new admin address
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Emitted when a new admin is proposed
    /// @param currentAdmin The current admin address
    /// @param pendingAdmin The pending admin address
    event AdminTransferProposed(
        address indexed currentAdmin,
        address indexed pendingAdmin
    );

    /// @notice Emitted when a protocol-wide event is emitted for off-chain indexing
    /// @param eventType The bytes32 event type identifier
    /// @param eventData Arbitrary event data (encoded)
    event CoreEventEmitted(bytes32 indexed eventType, bytes eventData);

    /// @notice Role for managing modules
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    /// @notice Role for approved market contracts
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");
    /// @notice The address of the admin
    address public s_admin;
    /// @notice The address of the pending admin
    address public s_pendingAdmin;

    /// @notice Registry of module addresses by module type
    mapping(bytes32 => address) public s_moduleRegistry;
    /// @notice Reverse mapping to efficiently check if an address is a registered module
    mapping(address => bool) public s_isModuleRegistered;

    /**
     * @notice Constructor sets deployer as protocol admin and module admin
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MODULE_ADMIN_ROLE, msg.sender);
        s_admin = msg.sender;
    }

    /**
     * @notice Registers or updates a module address for a given module type
     * @dev Only callable by MODULE_ADMIN_ROLE
     * @param moduleType The bytes32 identifier for the module type (e.g., keccak256("POSITION_MODULE"))
     * @param moduleAddress The address of the module contract
     */
    function registerModule(
        bytes32 moduleType,
        address moduleAddress
    ) external onlyRole(MODULE_ADMIN_ROLE) {
        if (moduleAddress == address(0)) {
            revert OspexCore__InvalidModuleAddress(moduleAddress);
        }
        address oldAddress = s_moduleRegistry[moduleType];
        if (oldAddress != address(0) && oldAddress != moduleAddress) {
            s_isModuleRegistered[oldAddress] = false; // Mark old address as no longer registered (for this type)
        }
        s_moduleRegistry[moduleType] = moduleAddress;
        s_isModuleRegistered[moduleAddress] = true; // Mark new address as registered
        emit ModuleRegistered(moduleType, moduleAddress);
    }

    /**
     * @notice Returns the address of the registered module for a given type
     * @param moduleType The bytes32 identifier for the module type
     * @return moduleAddress The address of the module contract
     */
    function getModule(
        bytes32 moduleType
    ) external view returns (address moduleAddress) {
        moduleAddress = s_moduleRegistry[moduleType];
    }

    /**
     * @notice Proposes a new admin
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param newAdmin The address of the new admin
     */
    function proposeAdmin(
        address newAdmin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) {
            revert OspexCore__InvalidAdminAddress(newAdmin);
        }
        s_pendingAdmin = newAdmin;
        emit AdminTransferProposed(msg.sender, newAdmin);
    }

    /**
     * @notice Accepts the proposed admin
     * @dev Only callable by the pending admin
     */
    function acceptAdmin() external {
        if (msg.sender != s_pendingAdmin) {
            revert OspexCore__NotPendingAdmin(msg.sender);
        }
        address oldAdmin = s_admin;
        _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        s_pendingAdmin = address(0);
        s_admin = msg.sender;
        emit AdminChanged(oldAdmin, msg.sender);
    }

    /**
     * @notice Emits a protocol-wide event for off-chain indexing
     * @dev Callable by any registered module
     * @param eventType The bytes32 event type identifier
     * @param eventData Arbitrary event data (encoded)
     */
    function emitCoreEvent(
        bytes32 eventType,
        bytes calldata eventData
    ) external {
        if (!isRegisteredModule(msg.sender)) {
            revert OspexCore__NotRegisteredModule(msg.sender);
        }
        emit CoreEventEmitted(eventType, eventData);
    }

    /**
     * @notice Checks if an address is a registered module
     * @param moduleAddress The address to check
     * @return isRegistered True if the address is a registered module
     */
    function isRegisteredModule(
        address moduleAddress
    ) public view returns (bool) {
        // Checks the reverse mapping populated during registration
        return s_isModuleRegistered[moduleAddress];
    }

    /**
     * @notice Grants or revokes the MARKET_ROLE for a market contract
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param market The address of the market contract
     * @param approved True to grant, false to revoke
     */
    function setMarketRole(
        address market,
        bool approved
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (approved) {
            _grantRole(MARKET_ROLE, market);
        } else {
            _revokeRole(MARKET_ROLE, market);
        }
    }

    /**
     * @notice Checks if an address has the MARKET_ROLE
     * @param market The address to check
     * @return True if the address has MARKET_ROLE
     */
    function hasMarketRole(address market) external view returns (bool) {
        return hasRole(MARKET_ROLE, market);
    }

    /**
     * @notice Processes a fee for a given payer, amount, fee type, and leaderboard ID
     * @dev Only callable by registered modules
     * @param payer The address of the payer
     * @param amount The amount of the fee
     * @param feeType The type of fee
     * @param leaderboardId The ID of the leaderboard
     */
    function processFee(
        address payer,
        uint256 amount,
        FeeType feeType,
        uint256 leaderboardId
    ) external {
        if (!isRegisteredModule(msg.sender)) {
            revert OspexCore__NotRegisteredModule(msg.sender);
        }
        address treasuryModule = s_moduleRegistry[keccak256("TREASURY_MODULE")];
        ITreasuryModule(treasuryModule).processFee(
            payer,
            amount,
            feeType,
            leaderboardId
        );
    }

    /**
     * @notice Processes a leaderboard entry fee for a given payer and amount
     * @dev Only callable by registered modules
     * @param payer The address of the payer
     * @param amount The amount of the fee
     * @param leaderboardId The ID of the leaderboard
     */
    function processLeaderboardEntryFee(
        address payer,
        uint256 amount,
        uint256 leaderboardId
    ) external {
        if (!isRegisteredModule(msg.sender)) {
            revert OspexCore__NotRegisteredModule(msg.sender);
        }
        address treasuryModule = s_moduleRegistry[keccak256("TREASURY_MODULE")];
        ITreasuryModule(treasuryModule).processLeaderboardEntryFee(
            payer,
            amount,
            leaderboardId
        );
    }
}
