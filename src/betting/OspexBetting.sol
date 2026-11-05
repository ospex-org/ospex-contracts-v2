// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOspexGames} from "../games/IOspexGames.sol";
import {IOspexModule} from "./IOspexModule.sol";

/**
 * @title OspexBetting
 * @author ospex.org
 * @notice The core of Ospex v3's betting set: the contract a reader starts from. It holds the set's two deploy
 *         values, the games set it settles on and the coin the bets are held in, and the registry of the set's
 *         six modules, which it locks once at finalize. The design it is built to is docs/spec-v3.md in this
 *         repository, which controls where the two differ.
 *
 *         The betting set is a frozen add-on beside a games set, deployed after it with that set's address
 *         fixed at deploy, and more than one may sit beside the same games set over time. The coin is a deploy
 *         parameter, never hardcoded. Both are immutable here, and the modules read them from here at their own
 *         deploy, so the set has one games set and one coin. Spec: "Two pieces".
 *
 *         The registry. The deployer registers the six modules, each checked against the type it is registered
 *         under, and calls finalize, which refuses any count but six and any set but the required one. After
 *         that no module is added, removed or swapped, and the deployer keeps no power: the lookups the modules
 *         make through the registry are wired once, then locked, not swap machinery. Spec: "From the July
 *         fresh-eyes review", the finalize item.
 *
 *         The hub. Every module emits its events through this contract as well as its own, one event with the
 *         module's type and the payload, so an indexer reads one address for the whole set.
 *
 *         Nothing here takes or holds coin. The stakes sit in the positions module.
 */
contract OspexBetting {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant MARKET_MODULE = keccak256("MARKET_MODULE");
    bytes32 public constant POSITION_MODULE = keccak256("POSITION_MODULE");
    bytes32 public constant MATCHING_MODULE = keccak256("MATCHING_MODULE");
    bytes32 public constant MONEYLINE_SCORER_MODULE = keccak256("MONEYLINE_SCORER_MODULE");
    bytes32 public constant SPREAD_SCORER_MODULE = keccak256("SPREAD_SCORER_MODULE");
    bytes32 public constant TOTAL_SCORER_MODULE = keccak256("TOTAL_SCORER_MODULE");

    /// @notice How many modules the set has: the markets, the positions, the matching and the three market
    ///         contracts. Finalize refuses any other count.
    uint256 public constant MODULE_COUNT = 6;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when the games address given at deploy has no code
    error OspexBetting__GamesNotAContract(address games);
    /// @notice Thrown when the coin given at deploy has no code
    error OspexBetting__TokenNotAContract(address token);
    /// @notice Thrown when a module address is the zero address
    error OspexBetting__InvalidModuleAddress(address moduleAddress);
    /// @notice Thrown when a caller is not a registered module
    error OspexBetting__NotRegisteredModule(address moduleAddress);
    /// @notice Thrown when finalize() has already been called
    error OspexBetting__AlreadyFinalized();
    /// @notice Thrown when a non-deployer calls a deployer-only function
    error OspexBetting__NotDeployer(address caller);
    /// @notice Thrown when bootstrap array lengths do not match
    error OspexBetting__ArrayLengthMismatch();
    /// @notice Thrown when a module type is registered more than once
    error OspexBetting__DuplicateModuleType(bytes32 moduleType);
    /// @notice Thrown when a module answers a type other than the one it is registered under
    error OspexBetting__ModuleTypeMismatch(address moduleAddress, bytes32 named, bytes32 found);
    /// @notice Thrown when finalize is called with a count of registered modules other than MODULE_COUNT
    error OspexBetting__ModuleCountMismatch(uint256 registered, uint256 required);
    /// @notice Thrown when a required module type is not registered
    error OspexBetting__ModuleNotRegistered(bytes32 moduleType);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted once, by the constructor: the games set this betting set settles on. It never changes.
    /// @param games The games contract's address
    event GamesSet(address indexed games);

    /// @notice Emitted once, by the constructor: the coin the bets are held in. It never changes.
    /// @param token The coin's address
    event TokenSet(address indexed token);

    /// @notice Emitted by registered modules for off-chain indexing
    /// @param eventType The bytes32 event type identifier
    /// @param emitter The module that emitted the event
    /// @param eventData ABI-encoded event payload
    event CoreEventEmitted(bytes32 indexed eventType, address indexed emitter, bytes eventData);

    /// @notice Emitted when modules are registered during bootstrap
    /// @param moduleCount The number of modules registered by this call
    event ModulesBootstrapped(uint256 moduleCount);

    /// @notice Emitted when the registry is locked
    event Finalized();

    // ──────────────────────────── Modifiers ────────────────────────────

    modifier onlyDeployer() {
        if (msg.sender != i_deployer) revert OspexBetting__NotDeployer(msg.sender);
        _;
    }

    modifier notFinalized() {
        if (s_finalized) revert OspexBetting__AlreadyFinalized();
        _;
    }

    modifier onlyRegisteredModule() {
        if (!s_isModuleRegistered[msg.sender]) {
            revert OspexBetting__NotRegisteredModule(msg.sender);
        }
        _;
    }

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The games set this betting set settles on. Fixed at deploy.
    IOspexGames public immutable i_games;

    /// @notice The coin the bets are held in, USDC at launch. Fixed at deploy.
    IERC20 public immutable i_token;

    /// @notice The deployer address; only has power before finalize()
    address public immutable i_deployer;

    /// @notice Whether the registry is locked
    bool public s_finalized;

    /// @notice How many modules have been registered
    uint256 public s_moduleCount;

    /// @notice Module type → module contract address
    mapping(bytes32 => address) public s_moduleRegistry;

    /// @notice Reverse lookup: is this address a registered module?
    mapping(address => bool) public s_isModuleRegistered;

    // ──────────────────────────── Constructor ──────────────────────────

    /// @notice Deploys the core with the set's two deploy values.
    /// @param games The games contract of the games set this betting set settles on
    /// @param token The coin the bets are held in
    constructor(address games, address token) {
        if (games.code.length == 0) revert OspexBetting__GamesNotAContract(games);
        if (token.code.length == 0) revert OspexBetting__TokenNotAContract(token);
        i_games = IOspexGames(games);
        i_token = IERC20(token);
        i_deployer = msg.sender;
        emit GamesSet(games);
        emit TokenSet(token);
    }

    // ──────────────────────────── Bootstrap ────────────────────────────

    /**
     * @notice Registers module addresses. Each module type can only be registered once, and each module must
     *         answer the type it is registered under.
     * @param moduleTypes Array of bytes32 module type identifiers
     * @param moduleAddresses Array of corresponding module contract addresses
     */
    function bootstrapModules(bytes32[] calldata moduleTypes, address[] calldata moduleAddresses)
        external
        onlyDeployer
        notFinalized
    {
        if (moduleTypes.length != moduleAddresses.length) {
            revert OspexBetting__ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            if (moduleAddresses[i] == address(0)) {
                revert OspexBetting__InvalidModuleAddress(moduleAddresses[i]);
            }
            if (s_moduleRegistry[moduleTypes[i]] != address(0)) {
                revert OspexBetting__DuplicateModuleType(moduleTypes[i]);
            }
            bytes32 found = IOspexModule(moduleAddresses[i]).getModuleType();
            if (found != moduleTypes[i]) {
                revert OspexBetting__ModuleTypeMismatch(moduleAddresses[i], moduleTypes[i], found);
            }
            s_moduleRegistry[moduleTypes[i]] = moduleAddresses[i];
            s_isModuleRegistered[moduleAddresses[i]] = true;
        }
        s_moduleCount += moduleTypes.length;
        emit ModulesBootstrapped(moduleTypes.length);
    }

    /**
     * @notice Locks the registry. It proves exactly the required set: six modules registered, one under each
     *         required type. After this call, no module can be added, removed, or swapped.
     */
    function finalize() external onlyDeployer notFinalized {
        bytes32[6] memory required = [
            MARKET_MODULE,
            POSITION_MODULE,
            MATCHING_MODULE,
            MONEYLINE_SCORER_MODULE,
            SPREAD_SCORER_MODULE,
            TOTAL_SCORER_MODULE
        ];
        if (s_moduleCount != required.length) {
            revert OspexBetting__ModuleCountMismatch(s_moduleCount, required.length);
        }
        for (uint256 i = 0; i < required.length; i++) {
            if (s_moduleRegistry[required[i]] == address(0)) {
                revert OspexBetting__ModuleNotRegistered(required[i]);
            }
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
    function getModule(bytes32 moduleType) external view returns (address moduleAddress) {
        moduleAddress = s_moduleRegistry[moduleType];
    }

    /**
     * @notice Checks if an address is a registered module
     * @param moduleAddress The address to check
     * @return True if the address is a registered module
     */
    function isRegisteredModule(address moduleAddress) external view returns (bool) {
        return s_isModuleRegistered[moduleAddress];
    }

    /**
     * @notice Checks if an address is one of the three market contracts
     * @param addr The address to check
     * @return True if addr is a registered market contract
     */
    function isApprovedScorer(address addr) external view returns (bool) {
        return addr == s_moduleRegistry[MONEYLINE_SCORER_MODULE] || addr == s_moduleRegistry[SPREAD_SCORER_MODULE]
            || addr == s_moduleRegistry[TOTAL_SCORER_MODULE];
    }

    // ──────────────────────────── Event Emission ──────────────────────

    /**
     * @notice Emits a protocol-wide event for off-chain indexing
     * @dev Only callable by registered modules
     * @param eventType The bytes32 event type identifier
     * @param eventData ABI-encoded event payload
     */
    function emitCoreEvent(bytes32 eventType, bytes calldata eventData) external onlyRegisteredModule {
        emit CoreEventEmitted(eventType, msg.sender, eventData);
    }
}
