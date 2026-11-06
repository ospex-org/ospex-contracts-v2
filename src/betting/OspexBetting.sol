// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOspexGames} from "../games/IOspexGames.sol";
import {IOspexModule} from "./IOspexModule.sol";

/**
 * @title IOspexModuleWiring
 * @author ospex.org
 * @notice The reads the core makes of a module at bootstrap, beside its type: the module's own deploy values.
 *         Each is the public getter of an immutable the module declares, read here as an address, and the
 *         core asks a module only for those a module of its type holds. No module inherits this interface:
 *         it is the core's view of them.
 */
interface IOspexModuleWiring {
    /// @notice The core the module was deployed with. Asked of the markets, positions and matching modules.
    function i_ospexCore() external view returns (address);

    /// @notice The games set the module copied from its core. Asked of the markets module and of each market
    ///         contract.
    function i_games() external view returns (address);

    /// @notice The coin the module copied from its core. Asked of the positions module.
    function i_token() external view returns (address);
}

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
 *         parameter, never hardcoded. Both are immutable here, and a module deployed with this contract's
 *         address copies them from here at its own deploy: the markets module and the three market contracts
 *         the games set, the positions module the coin. So a set whose modules were all deployed with this
 *         core has one games set and one coin. Spec: "Two pieces".
 *
 *         The wiring. Registration reads those values back from each module's own getters and refuses a
 *         module, by name, on a wrong one: the markets, positions and matching modules must name this core
 *         (i_ospexCore), the markets module and the three market contracts this games set (i_games), and the
 *         positions module this coin (i_token). A market contract is checked on its games set alone. It holds
 *         no core: it copies the games set at its deploy and never calls the core again, so one deployed
 *         with another core that names this games set is the same code holding the same value. The reads are
 *         believed, and no code is read. They stop a mistake at the deploy: a module that names another
 *         core, another games set or another coin. They do not stop a contract written to answer falsely.
 *         That each address holds this repository's build, and that the games set and the coin given to this
 *         contract's own constructor are the right ones, are the deploy's to prove.
 *
 *         The registry. The deployer registers the six modules, each checked on the type it is registered
 *         under and on its wiring, and calls finalize, which refuses any count but six and any set but the
 *         required one. A refused registration writes nothing, so its type stays free for the right module.
 *         A type registers once: nothing rewrites its address, before finalize or after. After finalize no
 *         module is added, removed or swapped, and the deployer keeps no power: the lookups the modules make
 *         through the registry are wired once, then locked, not swap machinery. Spec: "From the July
 *         fresh-eyes review", the finalize item.
 *
 *         The hub. The markets, positions and matching modules emit each of their events twice: their own
 *         typed event, and through this contract one event that carries the event's type, the module that
 *         emitted it and the payload, the typed event's parameters in the typed event's order. So an indexer
 *         reads one address for the whole set. This contract checks that the emitter is a registered module,
 *         and nothing about the type or the payload.
 *
 *         No function of this contract pulls coin, sends it or keeps an account of it: the stakes are pulled,
 *         held and paid by the positions module. Coin sent to this address belongs to nothing here, and no
 *         function sends it back.
 *
 *         How the set's contracts call one another, call by call, is in docs/ARCHITECTURE.md, under "v3: the
 *         betting set's seams".
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
    /// @notice Thrown when the markets module or a market contract names a games set other than this core's
    error OspexBetting__ModuleGamesMismatch(address moduleAddress, address found);
    /// @notice Thrown when the positions module names a coin other than this core's
    error OspexBetting__ModuleTokenMismatch(address moduleAddress, address found);
    /// @notice Thrown when the markets, the positions or the matching module names a core other than this one
    error OspexBetting__ModuleCoreMismatch(address moduleAddress, address found);
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
     * @notice Registers module addresses. Each module type can only be registered once, each module must
     *         answer the type it is registered under, and a module of the six must name this core's values.
     * @dev Each address is read before it is written, each read the module's own getter. First
     *      getModuleType(), of every address. Then the value its type holds: i_games(), of the markets module
     *      and of each market contract; i_token(), of the positions module. Last i_ospexCore(), of the
     *      markets, the positions and the matching module. A market contract is not asked for a core: it
     *      holds none. A refusal reverts the whole call, so no address of the call is registered, the count
     *      does not move and nothing is emitted. A read that fails fails the call with the read's own revert
     *      data, which is empty for an address that has no such function. Any type may be registered here,
     *      not only the six, and a type outside the six is asked its type and nothing else: finalize is what
     *      refuses a set that is not exactly the required one.
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
            _checkWiring(moduleTypes[i], moduleAddresses[i]);
            s_moduleRegistry[moduleTypes[i]] = moduleAddresses[i];
            s_isModuleRegistered[moduleAddresses[i]] = true;
        }
        s_moduleCount += moduleTypes.length;
        emit ModulesBootstrapped(moduleTypes.length);
    }

    /// @dev The wiring reads of one address, made after its type's: the value its type holds, a games set
    ///      or a coin, and then its core, each asked only of the types that hold it. No type holds both a
    ///      games set and a coin, so those two reads have no order between them. The core is asked last so
    ///      that a module of this repository deployed with another core is told which of its values is
    ///      wrong: it copied that core's games set and coin, and asked first, the core's refusal would hide
    ///      theirs. Each read is a static call, so a module's code cannot write while it answers.
    function _checkWiring(bytes32 moduleType, address moduleAddress) private view {
        IOspexModuleWiring module = IOspexModuleWiring(moduleAddress);
        if (
            moduleType == MARKET_MODULE || moduleType == MONEYLINE_SCORER_MODULE || moduleType == SPREAD_SCORER_MODULE
                || moduleType == TOTAL_SCORER_MODULE
        ) {
            address games = module.i_games();
            if (games != address(i_games)) revert OspexBetting__ModuleGamesMismatch(moduleAddress, games);
        }
        if (moduleType == POSITION_MODULE) {
            address token = module.i_token();
            if (token != address(i_token)) revert OspexBetting__ModuleTokenMismatch(moduleAddress, token);
        }
        if (moduleType == MARKET_MODULE || moduleType == POSITION_MODULE || moduleType == MATCHING_MODULE) {
            address core = module.i_ospexCore();
            if (core != address(this)) revert OspexBetting__ModuleCoreMismatch(moduleAddress, core);
        }
    }

    /**
     * @notice Locks the registry. It proves exactly the required set: six modules registered, one under each
     *         required type. After this call, no module can be added, removed, or swapped.
     * @dev Nothing is read from a module here. Every address this finds passed the reads of bootstrapModules
     *      when it was registered, and the registry has not changed it since.
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
     * @dev Returns address(0) if the module type was never registered. A type's address is written once, at
     *      its registration, and nothing rewrites it: for a registered type this answers the same address at
     *      every call.
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
     * @dev It answers false for the zero address, at every stage, and otherwise compares addr with the three
     *      registered addresses. While a market contract's type is not yet registered its slot is the zero
     *      address, which is why the zero address is refused first: it is never a market contract. So this
     *      answers true for the market contracts registered so far and for nothing else, and from finalize
     *      on for the three.
     * @param addr The address to check
     * @return True if addr is a registered market contract
     */
    function isApprovedScorer(address addr) external view returns (bool) {
        if (addr == address(0)) return false;
        return addr == s_moduleRegistry[MONEYLINE_SCORER_MODULE] || addr == s_moduleRegistry[SPREAD_SCORER_MODULE]
            || addr == s_moduleRegistry[TOTAL_SCORER_MODULE];
    }

    // ──────────────────────────── Event Emission ──────────────────────

    /**
     * @notice Emits a protocol-wide event for off-chain indexing
     * @dev Only callable by registered modules, from their registration on, before finalize as after. The
     *      type and the payload are the caller's: nothing here checks either.
     * @param eventType The bytes32 event type identifier
     * @param eventData ABI-encoded event payload
     */
    function emitCoreEvent(bytes32 eventType, bytes calldata eventData) external onlyRegisteredModule {
        emit CoreEventEmitted(eventType, msg.sender, eventData);
    }
}
