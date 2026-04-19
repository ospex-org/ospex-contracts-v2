// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title OspexCore
 * @author ospex.org
 * @notice Immutable core contract for the Ospex protocol. Manages the module
 *         registry, cross-module access control, and protocol-wide event emission.
 * @dev Implements a bootstrap-then-finalize pattern: the deployer registers all
 *      modules once, calls finalize(), and no admin key remains. All business
 *      logic lives in the registered modules.
 */

import {ITreasuryModule} from "../interfaces/ITreasuryModule.sol";
import {FeeType} from "./OspexTypes.sol";

contract OspexCore {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");
    bytes32 public constant SPECULATION_MODULE =
        keccak256("SPECULATION_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant ORACLE_MODULE = keccak256("ORACLE_MODULE");
    bytes32 public constant TREASURY_MODULE = keccak256("TREASURY_MODULE");
    bytes32 public constant LEADERBOARD_MODULE =
        keccak256("LEADERBOARD_MODULE");
    bytes32 public constant RULES_MODULE = keccak256("RULES_MODULE");
    bytes32 public constant SECONDARY_MARKET_MODULE =
        keccak256("SECONDARY_MARKET_MODULE");
    bytes32 public constant MONEYLINE_SCORER_MODULE =
        keccak256("MONEYLINE_SCORER_MODULE");
    bytes32 public constant SPREAD_SCORER_MODULE =
        keccak256("SPREAD_SCORER_MODULE");
    bytes32 public constant TOTAL_SCORER_MODULE =
        keccak256("TOTAL_SCORER_MODULE");

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a module address is the zero address
    error OspexCore__InvalidModuleAddress(address moduleAddress);
    /// @notice Thrown when a caller is not a registered module
    error OspexCore__NotRegisteredModule(address moduleAddress);
    /// @notice Thrown when finalize() has already been called
    error OspexCore__AlreadyFinalized();
    /// @notice Thrown when a non-deployer calls a deployer-only function
    error OspexCore__NotDeployer(address caller);
    /// @notice Thrown when bootstrap array lengths do not match
    error OspexCore__ArrayLengthMismatch();
    /// @notice Thrown when a module type is registered more than once
    error OspexCore__DuplicateModuleType(bytes32 moduleType);
    /// @notice Thrown when a module type is not registered
    error OspexCore__ModuleNotRegistered(bytes32 moduleType);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted by registered modules for off-chain indexing
    /// @param eventType The bytes32 event type identifier
    /// @param emitter The module that emitted the event
    /// @param eventData ABI-encoded event payload
    event CoreEventEmitted(
        bytes32 indexed eventType,
        address indexed emitter,
        bytes eventData
    );

    /// @notice Emitted when all modules are registered during bootstrap
    /// @param moduleCount The number of modules registered
    event ModulesBootstrapped(uint256 moduleCount);

    /// @notice Emitted when the protocol is finalized
    event Finalized();

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier onlyDeployer() {
        if (msg.sender != i_deployer) revert OspexCore__NotDeployer(msg.sender);
        _;
    }

    modifier notFinalized() {
        if (s_finalized) revert OspexCore__AlreadyFinalized();
        _;
    }

    modifier onlyRegisteredModule() {
        if (!s_isModuleRegistered[msg.sender])
            revert OspexCore__NotRegisteredModule(msg.sender);
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The deployer address; only has power before finalize()
    address public immutable i_deployer;

    /// @notice Whether the protocol has been finalized
    bool public s_finalized;

    /// @notice Module type → module contract address
    mapping(bytes32 => address) public s_moduleRegistry;

    /// @notice Reverse lookup: is this address a registered module?
    mapping(address => bool) public s_isModuleRegistered;

    // ──────────────────────────── Constructor ──────────────────────────

    constructor() {
        i_deployer = msg.sender;
    }

    // ──────────────────────────── Bootstrap ────────────────────────────

    /**
     * @notice Registers module addresses.
     *         Each module type can only be registered once.
     * @param moduleTypes Array of bytes32 module type identifiers
     * @param moduleAddresses Array of corresponding module contract addresses
     */
    function bootstrapModules(
        bytes32[] calldata moduleTypes,
        address[] calldata moduleAddresses
    ) external onlyDeployer notFinalized {
        if (moduleTypes.length != moduleAddresses.length)
            revert OspexCore__ArrayLengthMismatch();
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            if (moduleAddresses[i] == address(0))
                revert OspexCore__InvalidModuleAddress(moduleAddresses[i]);
            if (s_moduleRegistry[moduleTypes[i]] != address(0))
                revert OspexCore__DuplicateModuleType(moduleTypes[i]);
            s_moduleRegistry[moduleTypes[i]] = moduleAddresses[i];
            s_isModuleRegistered[moduleAddresses[i]] = true;
        }
        emit ModulesBootstrapped(moduleTypes.length);
    }

    /**
     * @notice Finalizes the protocol. After this call, no modules
     *         can be added, removed, or swapped.
     */
    function finalize() external onlyDeployer notFinalized {
        bytes32[12] memory required = [
            CONTEST_MODULE,
            SPECULATION_MODULE,
            POSITION_MODULE,
            MATCHING_MODULE,
            ORACLE_MODULE,
            TREASURY_MODULE,
            LEADERBOARD_MODULE,
            RULES_MODULE,
            SECONDARY_MARKET_MODULE,
            MONEYLINE_SCORER_MODULE,
            SPREAD_SCORER_MODULE,
            TOTAL_SCORER_MODULE
        ];
        for (uint256 i = 0; i < required.length; i++) {
            if (s_moduleRegistry[required[i]] == address(0))
                revert OspexCore__ModuleNotRegistered(required[i]);
        }
        s_finalized = true;
        emit Finalized();
    }

    // ──────────────────────────── Module Queries ───────────────────────

    /**
     * @notice Returns the address of the module registered for a given type
     * @dev Returns address(0) if the module type was never registered
     * @param moduleType The bytes32 identifier for the module type
     * @return moduleAddress The module contract address
     */
    function getModule(
        bytes32 moduleType
    ) external view returns (address moduleAddress) {
        moduleAddress = s_moduleRegistry[moduleType];
    }

    /**
     * @notice Checks if an address is a registered module
     * @param moduleAddress The address to check
     * @return True if the address is a registered module
     */
    function isRegisteredModule(
        address moduleAddress
    ) external view returns (bool) {
        return s_isModuleRegistered[moduleAddress];
    }

    /**
     * @notice Checks if an address is the registered SecondaryMarketModule
     * @param addr The address to check
     * @return True if addr is the secondary market module
     */
    function isSecondaryMarket(address addr) external view returns (bool) {
        return addr == s_moduleRegistry[SECONDARY_MARKET_MODULE];
    }

    /**
     * @notice Checks if an address is one of the three approved scorer modules
     * @param addr The address to check
     * @return True if addr is a registered scorer module
     */
    function isApprovedScorer(address addr) external view returns (bool) {
        return
            addr == s_moduleRegistry[MONEYLINE_SCORER_MODULE] ||
            addr == s_moduleRegistry[SPREAD_SCORER_MODULE] ||
            addr == s_moduleRegistry[TOTAL_SCORER_MODULE];
    }

    // ──────────────────────────── Event Emission ──────────────────────

    /**
     * @notice Emits a protocol-wide event for off-chain indexing
     * @dev Only callable by registered modules
     * @param eventType The bytes32 event type identifier
     * @param eventData ABI-encoded event payload
     */
    function emitCoreEvent(
        bytes32 eventType,
        bytes calldata eventData
    ) external onlyRegisteredModule {
        emit CoreEventEmitted(eventType, msg.sender, eventData);
    }

    // ──────────────────────────── Fee Processing ──────────────────────

    /**
     * @notice Routes a protocol fee to the TreasuryModule
     * @dev Only callable by registered modules
     * @param payer The address paying the fee
     * @param feeType The category of fee being charged
     */
    function processFee(
        address payer,
        FeeType feeType
    ) external onlyRegisteredModule {
        ITreasuryModule(s_moduleRegistry[TREASURY_MODULE]).processFee(
            payer,
            feeType
        );
    }

    /**
     * @notice Routes a split protocol fee to the TreasuryModule
     * @dev Only callable by registered modules. Fee is split equally between two payers.
     * @param payer1 First payer (charged floor half)
     * @param payer2 Second payer (charged remainder)
     * @param feeType The category of fee being charged
     */
    function processSplitFee(
        address payer1,
        address payer2,
        FeeType feeType
    ) external onlyRegisteredModule {
        ITreasuryModule(s_moduleRegistry[TREASURY_MODULE]).processSplitFee(
            payer1,
            payer2,
            feeType
        );
    }

    /**
     * @notice Routes a leaderboard entry fee to the TreasuryModule
     * @dev Only callable by registered modules. Entry fees go to the prize pool,
     *      not the protocol receiver.
     * @param payer The address paying the entry fee
     * @param amount The entry fee amount in USDC
     * @param leaderboardId The leaderboard receiving the entry
     */
    function processLeaderboardEntryFee(
        address payer,
        uint256 amount,
        uint256 leaderboardId
    ) external onlyRegisteredModule {
        ITreasuryModule(s_moduleRegistry[TREASURY_MODULE])
            .processLeaderboardEntryFee(payer, amount, leaderboardId);
    }
}
