// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19 ^0.8.20;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// lib/openzeppelin-contracts/contracts/access/IAccessControl.sol

// OpenZeppelin Contracts (last updated v5.1.0) (access/IAccessControl.sol)

/**
 * @dev External interface of AccessControl declared to support ERC-165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted signaling this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).
     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// src/interfaces/IModule.sol

/**
 * @title IModule
 * @notice Base interface for all Ospex plug-in modules
 */
interface IModule {
    /// @notice Returns the module type identifier (e.g., keccak256("CONTEST_MODULE"))
    /// @return moduleType The bytes32 module type
    function getModuleType() external pure returns (bytes32 moduleType);
}

// src/core/OspexTypes.sol

/**
 * @title OspexTypes
 * @author ospex.org
 * @notice Shared types and data structures for the Ospex protocol
 * @dev Contains all common structs and enums used across the protocol
 */

/// @notice Represents a contest with its scores and metadata
struct Contest {
    uint32 awayScore;                // Final away team score
    uint32 homeScore;                // Final home team score
    LeagueId leagueId;               // League ID
    ContestStatus contestStatus;     // Current status of the contest
    address contestCreator;          // Address that created the contest
    bytes32 scoreContestSourceHash;  // Hash of the scoring source code
    string rundownId;                // Contest ID from Rundown API
    string sportspageId;             // Contest ID from Sportspage API
    string jsonoddsId;               // Contest ID from JSONOdds API
}

/// @notice Possible states of a contest
enum ContestStatus {
    Unverified,              // Initial state
    Verified,                // Contest verified by oracle
    Scored,                  // Final scores recorded
    ScoredManually           // Manually scored by admin
}

/// @notice League Id
enum LeagueId {
    Unknown,
    NCAAF,
    NFL,
    MLB,
    NBA,
    NCAAB,
    NHL,
    MMA,
    WNBA,
    CFL,
    MLS,
    EPL
}

/// @notice Represents a speculation on a contest outcome
struct Speculation {
    uint256 contestId;                   // Associated contest ID
    uint32 startTimestamp;               // Time when speculation starts
    address speculationScorer;           // Scorer contract address
    int32 theNumber;                     // Line/spread/total number
    address speculationCreator;          // Creator address
    SpeculationStatus speculationStatus; // Current status
    WinSide winSide;                     // Winning side
}

/// @notice Status of a speculation
enum SpeculationStatus {
    Open,      // Taking bets, trading allowed
    Closed     // Scored and claimable
}

/// @notice Possible winning sides of a speculation
enum WinSide {
    TBD,                     // To be determined
    Away,                    // Away team wins
    Home,                    // Home team wins
    Over,                    // Over the total
    Under,                   // Under the total
    Push,                    // Tie/Push
    Forfeit,                 // Contest canceled
    Void                     // Unresolved and voided
}

/// @notice User's position in a speculation
struct Position {
    uint256 matchedAmount;
    uint256 unmatchedAmount;
    uint128 poolId;
    uint32 unmatchedExpiry;
    PositionType positionType;
    bool claimed;
}

/// @notice Type of position taken in a speculation
enum PositionType {
    Upper,                   // Away team or Over
    Lower                    // Home team or Under
}

/// @notice Type of fee charged in the protocol
/// @dev Used for fee routing and allocation in FeeModule
enum FeeType {
    ContestCreation,      // Fee for creating a contest
    SpeculationCreation,  // Fee for creating a speculation/market
    LeaderboardEntry      // Fee for entering a leaderboard
}

/// @notice Represents an odds pool for a contest
struct OddsPair {
    uint128 oddsPairId;       // Odds pair ID
    uint64 upperOdds;         // Upper odds
    uint64 lowerOdds;         // Lower odds
}

/// @notice Represents a sale listing for one side of a matched pair
struct SaleListing {
    uint256 price;            // Price of the sale listing
    uint256 amount;           // Amount of position to sell
}

/// @notice Represents a leaderboard and its configuration/state
struct Leaderboard {
    uint256 minBankroll;          // Minimum bankroll required to participate
    uint256 maxBankroll;          // Maximum bankroll allowed
    uint256 prizePool;            // Total prize pool
    uint256 entryFee;             // Entry fee (if any)
    address yieldStrategy;        // Optional yield strategy contract
    address winner;               // Winner address (set after scoring)
    uint32 startTime;             // Leaderboard start timestamp
    uint32 endTime;               // Leaderboard end timestamp
    uint32 safetyPeriodDuration;  // Safety period after end (seconds)
    uint32 claimWindow;           // Claim window after end (seconds)
    uint16 minBetPercentage;      // Minimum bet as % of bankroll (bps, e.g., 100 = 1%)
    uint16 maxBetPercentage;      // Maximum bet as % of bankroll (bps)
    uint16 minBets;               // Minimum number of bets required
    uint16 oddsEnforcementBps;    // Odds enforcement (bps, e.g., 2500 = 25%, 0 = no limit)
    bool isScored;                // True if leaderboard has been scored
    bool isPaid;                  // True if prize has been paid
}

/// @notice Stores current market odds/number and metadata for leaderboard enforcement
struct LeaderboardSpeculation {
    uint256 contestId;          // Associated contest ID (copied for convenience)
    uint256 speculationId;      // Associated speculation ID
    bytes32 leagueId;           // League identifier (for enforcement rules)
    address speculationScorer;  // Address of the scorer/market type contract
    uint64 upperOdds;           // Current market odds for upper position (e.g., Away/Over)
    uint64 lowerOdds;           // Current market odds for lower position (e.g., Home/Under)
    int32 theNumber;            // Current market number (spread/total), if applicable
    uint32 startTimestamp;      // Start time of the speculation (copied for convenience)
    uint32 lastUpdated;         // Timestamp of last odds update
}

/// @notice Tracks a user's leaderboard-eligible position
struct LeaderboardPosition {
    uint256 contestId;            // Contest ID
    uint256 speculationId;        // Speculation ID
    uint256 amount;               // Amount eligible for leaderboard
    address user;                 // User address
    uint64 odds;                  // Odds at entry (for this position)
    PositionType positionType;    // Position type (Upper/Lower)
}

/// @notice Type of oracle request
enum OracleRequestType {
    ContestCreate,
    ContestScore,
    SpeculationCreateOrUpdate
}

/// @notice Context for oracle requests
struct OracleRequestContext {
    OracleRequestType requestType;
    uint256 contestId;             // Used for contest related requests
    uint256 speculationId;         // Used for speculation/leaderboard related requests
}

// lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/ERC165.sol)

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC-165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// src/interfaces/IFeeModule.sol

/**
 * @title IFeeModule
 * @notice Interface for the FeeModule in the Ospex protocol
 * @dev Handles fee collection, routing, and allocation for contest creation, speculation creation, and leaderboard entry.
 */
interface IFeeModule is IModule {
    /**
     * @notice Handles a fee payment, splits between protocol and prize pools per config and user allocation.
     * @param payer The address paying the fee
     * @param amount The total fee amount
     * @param feeType The type of fee (see FeeType enum)
     * @param leaderboardId The leaderboard ID to allocate
     */
    function handleFee(
        address payer,
        uint256 amount,
        FeeType feeType,
        uint256 leaderboardId
    ) external;

    /**
     * @notice Admin: sets the fee rate for a given fee type
     * @param feeType The type of fee
     * @param rate The new fee rate (in token units or bps, per config)
     */
    function setFeeRates(FeeType feeType, uint256 rate) external;

    /**
     * @notice Admin: sets the protocol cut (in basis points)
     * @param cutBps The new protocol cut (e.g., 500 = 5%)
     */
    function setProtocolCut(uint256 cutBps) external;

    /**
     * @notice Admin: sets the protocol revenue receiver address
     * @param receiver The new protocol receiver address
     */
    function setProtocolReceiver(address receiver) external;

    /**
     * @notice Allows LeaderboardModule to transfer prize pool funds to winners
     * @param leaderboardId The leaderboard to claim from
     * @param to The address to send funds to
     */
    function claimPrizePool(uint256 leaderboardId, address to) external;

    /**
     * @notice Returns the current fee rate for a given type
     * @param feeType The type of fee
     * @return rate The current fee rate
     */
    function getFeeRate(FeeType feeType) external view returns (uint256 rate);

    /**
     * @notice Returns the current prize pool balance for a leaderboard
     * @param leaderboardId The leaderboard ID
     * @return balance The current prize pool balance
     */
    function getPrizePool(
        uint256 leaderboardId
    ) external view returns (uint256 balance);

}

// lib/openzeppelin-contracts/contracts/access/AccessControl.sol

// OpenZeppelin Contracts (last updated v5.0.0) (access/AccessControl.sol)

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` to `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}

// src/core/OspexCore.sol

/**
 * @title OspexCore
 * @author ospex.org
 * @notice Minimal core contract for Ospex protocol: manages module registry and access control
 * @dev Implements the minimal core + plug-in modules pattern. All business logic is in modules.
 *      The core manages module addresses, access control, and protocol-wide event emission.
 */

contract OspexCore is AccessControl {
    /// @notice Emitted when a module is not the caller
    /// @param caller The address of the caller
    /// @param module The address of the module
    error OspexCore__NotModule(address caller, address module);
    /// @notice Emitted when a module address is invalid
    /// @param moduleAddress The address of the module
    error OspexCore__InvalidModuleAddress(address moduleAddress);
    /// @notice Emitted when a new admin address is invalid
    /// @param newAdmin The address of the new admin
    error OspexCore__InvalidAdminAddress(address newAdmin);
    /// @notice Emitted when a module is not registered
    /// @param moduleAddress The address of the module
    error OspexCore__NotRegisteredModule(address moduleAddress);

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

    /// @notice Emitted when a protocol-wide event is emitted for off-chain indexing
    /// @param eventType The bytes32 event type identifier
    /// @param eventData Arbitrary event data (encoded)
    event CoreEventEmitted(bytes32 indexed eventType, bytes eventData);

    /// @notice Role for managing modules
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    /// @notice Role for approved market contracts
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    /// @notice Registry of module addresses by module type
    mapping(bytes32 => address) public s_moduleRegistry;
    /// @notice Reverse mapping to efficiently check if an address is a registered module
    mapping(address => bool) public s_isModuleRegistered;

    /**
     * @notice Restricts function to only the registered module of the given type
     * @param moduleType The module type identifier
     */
    modifier onlyModule(bytes32 moduleType) {
        if (msg.sender != s_moduleRegistry[moduleType]) {
            revert OspexCore__NotModule(
                msg.sender,
                s_moduleRegistry[moduleType]
            );
        }
        _;
    }

    /**
     * @notice Constructor sets deployer as protocol admin and module admin
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MODULE_ADMIN_ROLE, msg.sender);
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
     * @notice Changes the protocol admin (DEFAULT_ADMIN_ROLE)
     * @dev Only callable by current DEFAULT_ADMIN_ROLE
     * @param newAdmin The address of the new admin
     */
    function setAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) {
            revert OspexCore__InvalidAdminAddress(newAdmin);
        }
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        emit AdminChanged(msg.sender, newAdmin);
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
     * @notice Handles a fee for a given payer, amount, fee type, and leaderboard ID
     * @dev Only callable by registered modules
     * @param payer The address of the payer
     * @param amount The amount of the fee
     * @param feeType The type of fee
     * @param leaderboardId The ID of the leaderboard
     */
    function handleFee(
        address payer,
        uint256 amount,
        FeeType feeType,
        uint256 leaderboardId
    ) external {
        if (!isRegisteredModule(msg.sender)) {
            revert OspexCore__NotRegisteredModule(msg.sender);
        }
        address feeModule = s_moduleRegistry[keccak256("FEE_MODULE")];
        IFeeModule(feeModule).handleFee(payer, amount, feeType, leaderboardId);
    }
}

