// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    FunctionsClient
} from "../../lib/chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {
    FunctionsRequest
} from "../../lib/chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Contest,
    ContestStatus,
    LeagueId,
    OracleRequestContext,
    OracleRequestType
} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";

/// @notice Minimal interface for LINK token's transferAndCall (ERC677)
interface ILinkToken {
    function transferAndCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool);
}

/**
 * @title OracleModule
 * @author ospex.org
 * @notice Module for oracle interactions, contest verification, and scoring
 */

contract OracleModule is FunctionsClient, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    /// @notice Error for not admin
    error OracleModule__NotAdmin(address admin);
    /// @notice Error for invalid address
    error OracleModule__InvalidAddress();
    /// @notice Error for module not set
    error OracleModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Error for incorrect source hash
    error OracleModule__IncorrectSourceHash();
    /// @notice Error for incorrect score source hash
    error OracleModule__IncorrectScoreSourceHash();
    /// @notice Error for incorrect update source hash
    error OracleModule__IncorrectUpdateSourceHash();
    /// @notice Error for chainlink function error
    error OracleModule__ChainlinkFunctionError(bytes err);
    /// @notice Error for subscription payment failed
    error OracleModule__SubscriptionPaymentFailed(uint256 payment);
    /// @notice Error for contest not verified
    error OracleModule__ContestNotVerified();
    /// @notice Error for contest not started
    error OracleModule__ContestNotStarted(uint256 contestId);
    /// @notice Error for unexpected request id
    error OracleModule__UnexpectedRequestId(bytes32 requestId);
    /// @notice Error for input too short
    error OracleModule__InputTooShort(
        uint256 inputLength,
        uint256 expectedLength
    );
    /// @notice Error for invalid request type
    error OracleModule__InvalidRequestType(OracleRequestType requestType);

    // --- Constants ---
    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice Address of the LINK token
    address internal immutable i_linkAddress;
    /// @notice LINK token divisibility
    uint256 internal constant LINK_DIVISIBILITY = 10 ** 18;
    /// @notice LINK payment denominator
    uint256 public s_linkDenominator = 250;
    /// @notice The odds scale factor (1.91 odds = 191 ticks)
    uint16 public constant ODDS_SCALE = 100;

    // Chainlink Functions config
    bytes32 public immutable i_donId;

    // Request tracking
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;
    mapping(bytes32 => uint256) public s_requestMapping;

    // Request context
    mapping(bytes32 => OracleRequestContext) public s_requestContext;

    // Events
    /**
     * @notice Emitted when a response is received from the OracleModule
     * @param requestId The ID of the request
     * @param response The response from the OracleModule
     * @param err The error from the OracleModule
     */
    event Response(bytes32 indexed requestId, bytes response, bytes err);
    /**
     * @notice Emitted when the LINK denominator is set
     * @param denominator The denominator for the LINK payment
     */
    event LinkDenominatorSet(uint256 denominator);

    // --- Modifiers ---
    /**
     * @notice Modifier to ensure the caller is the OspexCore contract
     */
    modifier onlyAdmin() {
        if (
            !i_ospexCore.hasRole(i_ospexCore.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert OracleModule__NotAdmin(msg.sender);
        }
        _;
    }

    /**
     * @notice Modifier to handle LINK payment and subscription
     * @param subscriptionId The ID of the subscription
     */
    modifier handleLinkPayment(uint64 subscriptionId) {
        uint256 payment = LINK_DIVISIBILITY / s_linkDenominator;

        // Transfer LINK from caller to contract
        IERC20(i_linkAddress).safeTransferFrom(
            msg.sender,
            address(this),
            payment
        );

        // Pay subscription fee to DON
        if (
            !ILinkToken(i_linkAddress).transferAndCall(
                address(i_router),
                payment,
                abi.encode(subscriptionId)
            )
        ) {
            revert OracleModule__SubscriptionPaymentFailed(payment);
        }
        _;
    }

    // --- Constructor ---
    /**
     * @notice Constructor for the OracleModule
     * @param _ospexCore The address of the OspexCore contract
     * @param router The address of the Chainlink router
     * @param linkAddress The address of the LINK token
     * @param donId The ID of the DON
     */
    constructor(
        address _ospexCore,
        address router,
        address linkAddress,
        bytes32 donId
    ) FunctionsClient(router) {
        if (
            _ospexCore == address(0) ||
            router == address(0) ||
            linkAddress == address(0) ||
            donId == bytes32(0)
        ) {
            revert OracleModule__InvalidAddress();
        }
        i_ospexCore = OspexCore(_ospexCore);
        i_linkAddress = linkAddress;
        i_donId = donId;
    }

    /**
     * @notice Can be called by any user to create a contest
     * @dev Calls ContestModule to actually create the contest
     * @param rundownId The rundown ID
     * @param sportspageId The sportspage ID
     * @param jsonoddsId The jsonodds ID
     * @param createContestSourceJS The create contest source JS
     * @param scoreContestSourceHash The score contest source hash
     * @param leaderboardId The leaderboard ID
     * @param encryptedSecretsUrls The encrypted secrets URLs
     * @param subscriptionId The subscription ID
     * @param gasLimit The gas limit
     */
    function createContestFromOracle(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId,
        string calldata createContestSourceJS,
        bytes32 scoreContestSourceHash,
        uint256 leaderboardId,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        IContestModule contestModule = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        );
        // Check source hash for contest creation
        if (
            keccak256(abi.encodePacked(createContestSourceJS)) !=
            IContestModule(contestModule).s_createContestSourceHash()
        ) {
            revert OracleModule__IncorrectSourceHash();
        }

        // Get next contestId
        uint256 contestId = IContestModule(contestModule).s_contestIdCounter() +
            1;

        // Prepare args array
        string[] memory args = new string[](3);
        args[0] = rundownId;
        args[1] = sportspageId;
        args[2] = jsonoddsId;

        // Initialize contest as unverified
        IContestModule(contestModule).createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            msg.sender,
            leaderboardId
        );

        // Send oracle request
        sendRequest(
            createContestSourceJS,
            encryptedSecretsUrls,
            args,
            subscriptionId,
            gasLimit,
            i_donId,
            OracleRequestType.ContestCreate,
            contestId
        );
    }

    /**
     * @notice Updates a contest market from the oracle
     * @param contestId The ID of the contest
     * @param contestMarketsUpdateSourceJS The source code for the contest markets update function
     * @param encryptedSecretsUrls The encrypted secrets URLs
     * @param subscriptionId The ID of the subscription
     * @param gasLimit The gas limit for the request
     */
    function updateContestMarketsFromOracle(
        uint256 contestId,
        string calldata contestMarketsUpdateSourceJS,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        IContestModule contestModule = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        );

        // Check source hash for contest markets update
        if (
            keccak256(abi.encodePacked(contestMarketsUpdateSourceJS)) !=
            contestModule.s_updateContestMarketsSourceHash()
        ) {
            revert OracleModule__IncorrectUpdateSourceHash();
        }

        Contest memory contest = contestModule.getContest(contestId);

        // Contest must be verified
        if (contest.contestStatus != ContestStatus.Verified) {
            revert OracleModule__ContestNotVerified();
        }

        // Prepare args array
        string[] memory args = new string[](3);
        args[0] = contest.rundownId;
        args[1] = contest.sportspageId;
        args[2] = contest.jsonoddsId;

        // Send oracle request
        sendRequest(
            contestMarketsUpdateSourceJS,
            encryptedSecretsUrls,
            args,
            subscriptionId,
            gasLimit,
            i_donId,
            OracleRequestType.ContestMarketsUpdate,
            contestId
        );
    }

    /**
     * @notice Can be called by any user to score a contest
     * @dev Calls ContestModule to actually score the contest
     * @param contestId The ID of the contest
     * @param scoreContestSourceJS The source code for the score contest function
     * @param encryptedSecretsUrls The encrypted secrets URLs
     * @param subscriptionId The ID of the subscription
     * @param gasLimit The gas limit for the request
     */
    function scoreContestFromOracle(
        uint256 contestId,
        string calldata scoreContestSourceJS,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        IContestModule contestModule = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        );
        // Retrieve contest data from ContestModule
        Contest memory contest = contestModule.getContest(contestId);
        // Validations, done prior to involving the oracle
        // Contest must be verified
        if (contest.contestStatus != ContestStatus.Verified) {
            revert OracleModule__ContestNotVerified();
        }
        // Score contest source hash must match
        if (
            keccak256(abi.encodePacked(scoreContestSourceJS)) !=
            contest.scoreContestSourceHash
        ) {
            revert OracleModule__IncorrectScoreSourceHash();
        }
        // Contest must have started
        if (block.timestamp < contestModule.s_contestStartTimes(contestId)) {
            revert OracleModule__ContestNotStarted(contestId);
        }

        // Prepare args array
        string[] memory args = new string[](3);
        args[0] = contest.rundownId;
        args[1] = contest.sportspageId;
        args[2] = contest.jsonoddsId;

        // Send oracle request
        sendRequest(
            scoreContestSourceJS,
            encryptedSecretsUrls,
            args,
            subscriptionId,
            gasLimit,
            i_donId,
            OracleRequestType.ContestScore,
            contestId
        );
    }

    /**
     * @notice Sends a request to the oracle
     * @param source The source code for the function
     * @param secrets The encrypted secrets URLs
     * @param args The arguments for the function
     * @param subscriptionId The ID of the subscription
     * @param gasLimit The gas limit for the request
     * @param donId The ID of the DON
     * @param requestType The type of request
     * @param contestId The ID of the contest
     * @return requestId The ID of the request
     *
     */
    function sendRequest(
        string memory source,
        bytes memory secrets,
        string[] memory args,
        uint64 subscriptionId,
        uint32 gasLimit,
        bytes32 donId,
        OracleRequestType requestType,
        uint256 contestId
    ) internal returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        if (secrets.length > 0) {
            req.addSecretsReference(secrets);
        }
        if (args.length > 0) {
            req.setArgs(args);
        }
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donId
        );

        // Store the context for the request
        s_requestContext[s_lastRequestId] = OracleRequestContext({
            requestType: requestType,
            contestId: contestId
        });

        // Map requestId to contestId
        s_requestMapping[s_lastRequestId] = contestId;
        return s_lastRequestId;
    }

    // Chainlink Functions callback
    /**
     * @notice Callback function for Chainlink Functions
     * @param requestId The ID of the request
     * @param response The response from the oracle
     * @param err The error from the oracle
     *
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (requestId != s_lastRequestId)
            revert OracleModule__UnexpectedRequestId(requestId);

        s_lastResponse = response;
        s_lastError = err;

        emit Response(requestId, response, err);

        if (err.length > 0) {
            revert OracleModule__ChainlinkFunctionError(err);
        }

        OracleRequestContext memory ctx = s_requestContext[requestId];
        if (ctx.requestType == OracleRequestType.ContestCreate) {
            _handleContestCreate(ctx.contestId, response);
        } else if (ctx.requestType == OracleRequestType.ContestMarketsUpdate) {
            _handleContestMarketsUpdate(ctx.contestId, response);
        } else if (ctx.requestType == OracleRequestType.ContestScore) {
            _handleContestScore(ctx.contestId, response);
        } else {
            revert OracleModule__InvalidRequestType(ctx.requestType);
        }
    }

    /**
     * @notice Handles the contest create request
     * @param contestId The ID of the contest
     * @param response The response from the oracle
     */
    function _handleContestCreate(
        uint256 contestId,
        bytes memory response
    ) internal {
        // 1. Extract contest data, leagueId, and start time from response
        uint256 contestData = bytesToUint256(response);
        (LeagueId leagueId, uint32 startTime) = extractLeagueIdAndStartTime(
            contestData
        );
        // 2. Store leagueId and start time
        IContestModule(_getModule(keccak256("CONTEST_MODULE")))
            .setContestLeagueIdAndStartTime(contestId, leagueId, startTime);
    }

    /**
     * @notice Handles the contest market update request
     * @param contestId The ID of the contest
     * @param response The response from the oracle
     */
    function _handleContestMarketsUpdate(
        uint256 contestId,
        bytes memory response
    ) internal {
        // 1. Extract market data (all odds and numbers)
        uint256 marketData = bytesToUint256(response);
        (
            uint16 moneylineAwayOdds,
            uint16 moneylineHomeOdds,
            int32 spreadLineTicks,
            uint16 spreadAwayOdds,
            uint16 spreadHomeOdds,
            int32 totalLineTicks,
            uint16 overOdds,
            uint16 underOdds
        ) = extractContestMarketData(marketData);

        // 3. Update all contest markets with the extracted data
        IContestModule(_getModule(keccak256("CONTEST_MODULE")))
            .updateContestMarkets(
                contestId,
                moneylineAwayOdds,
                moneylineHomeOdds,
                spreadLineTicks,
                spreadAwayOdds,
                spreadHomeOdds,
                totalLineTicks,
                overOdds,
                underOdds
            );
    }

    /**
     * @notice Handles the contest score request
     * @param contestId The ID of the contest
     * @param response The response from the oracle
     */
    function _handleContestScore(
        uint256 contestId,
        bytes memory response
    ) internal {
        // 1. Extract scores from response
        uint32[2] memory scores = uintToResultScore(bytesToUint32(response));
        // 2. Set scores
        IContestModule(_getModule(keccak256("CONTEST_MODULE"))).setScores(
            contestId,
            scores[0],
            scores[1]
        );
    }

    // --- Utility functions (from v2) ---

    /**
     * @notice Converts bytes response from the DON to a uint32
     * @param input The bytes response from the DON, this conversion takes place prior to converting the score
     * @return output The uint32 output
     */
    function bytesToUint32(
        bytes memory input
    ) internal pure returns (uint32 output) {
        if (input.length < 4) {
            revert OracleModule__InputTooShort(input.length, 4);
        }

        assembly {
            output := mload(add(input, 32))
        }
    }

    /**
     * @notice Converts bytes response from the DON to a uint256
     * @param input The bytes response from the DON containing contest data
     * @return output The uint256 output
     */
    function bytesToUint256(
        bytes memory input
    ) internal pure returns (uint256 output) {
        if (input.length < 32) {
            revert OracleModule__InputTooShort(input.length, 32);
        }
        assembly {
            output := mload(add(input, 32))
        }
    }

    /**
     * @notice Extracts leagueId and event start time from a packed uint256.
     * @dev The packed uint256 is formatted as: [leagueId (2 digits)][...][startTime (10 digits)].
     *      - leagueId is extracted by dividing by 1e18 (shifts right by 18 digits).
     *      - startTime is extracted by taking the last 10 digits (modulo 1e10).
     *      This packing is used to transmit multiple values in a single uint256 from the oracle.
     * @param _uint The packed uint256 response containing league, teams, and time data.
     * @return leagueId The league ID (as an enum).
     * @return startTime Unix timestamp of contest start.
     */
    function extractLeagueIdAndStartTime(
        uint256 _uint
    ) internal pure returns (LeagueId leagueId, uint32 startTime) {
        // casting to 'uint8' is safe because LeagueId enum has fewer than 256 values
        // forge-lint: disable-next-line(unsafe-typecast)
        leagueId = LeagueId(uint8(_uint / 1e18));
        // Get last 10 digits (event time)
        // casting to 'uint32' is safe because modulo 1e10 always fits in uint32 (max 4.29e9)
        // forge-lint: disable-next-line(unsafe-typecast)
        startTime = uint32(_uint % 1e10);
        return (leagueId, startTime);
    }

    /**
     * @notice Converts uint response from the DON to contest score
     * @param _uint The uint response from the DON that will contain both the away and home team's score
     * @return scoreArr The uint32[2] array containing the away and home team's score
     */
    function uintToResultScore(
        uint32 _uint
    ) internal pure returns (uint32[2] memory) {
        uint32[2] memory scoreArr;
        scoreArr[1] = _uint % 1000;
        scoreArr[0] = (_uint - scoreArr[1]) / 1000;
        return scoreArr;
    }

    /**
     * @notice Extracts contest market data from a packed uint256.
     * @dev The _uint parameter contains data encoded in the following format (38 digits total):
     *      [moneylineAway(5)][moneylineHome(5)][spread(4)][spreadAwayLine(5)][spreadHomeLine(5)][total(4)][overLine(5)][underLine(5)]
     *      - moneylineAway: ((_uint / 1e33) % 1e5), converted via americanToOddsTick
     *      - moneylineHome: ((_uint / 1e28) % 1e5), converted via americanToOddsTick
     *      - spread: ((_uint / 1e24) % 1e4) - 1000, stored as 10x (e.g., -3.5 = -35)
     *      - spreadAwayLine: ((_uint / 1e19) % 1e5), converted via americanToOddsTick
     *      - spreadHomeLine: ((_uint / 1e14) % 1e5), converted via americanToOddsTick
     *      - total: ((_uint / 1e10) % 1e4) - 1000, stored as 10x (e.g., 220.5 = 2205)
     *      - overLine: ((_uint / 1e5) % 1e5), converted via americanToOddsTick
     *      - underLine: (_uint % 1e5), converted via americanToOddsTick
     *      American odds are offset by +10000 in JavaScript to handle negatives before packing.
     *      Numbers (spread/total) are offset by +1000 and stored as 10x for half-point precision.
     * @param _uint The packed uint256 containing all contest market data.
     * @return moneylineAwayOdds Odds tick for away team moneyline (e.g., 191 = 1.91)
     * @return moneylineHomeOdds Odds tick for home team moneyline
     * @return spreadLineTicks The point spread, stored as 10x (e.g., -35 = -3.5)
     * @return spreadAwayOdds Odds tick for away spread
     * @return spreadHomeOdds Odds tick for home spread
     * @return totalLineTicks The total points line, stored as 10x (e.g., 2205 = 220.5)
     * @return overOdds Odds tick for over
     * @return underOdds Odds tick for under
     */
    function extractContestMarketData(
        uint256 _uint
    )
        internal
        pure
        returns (
            uint16 moneylineAwayOdds,
            uint16 moneylineHomeOdds,
            int32 spreadLineTicks,
            uint16 spreadAwayOdds,
            uint16 spreadHomeOdds,
            int32 totalLineTicks,
            uint16 overOdds,
            uint16 underOdds
        )
    {
        // Extract moneyline odds (5 digits each, offset back from +10000, then convert to scaled decimal)
        moneylineAwayOdds = americanToOddsTick(((_uint / 1e33) % 1e5));
        moneylineHomeOdds = americanToOddsTick(((_uint / 1e28) % 1e5));

        // Extract spread (4 digits, offset back from +1000)
        spreadLineTicks = int32(int256((_uint / 1e24) % 1e4)) - 1000;

        // Extract spread odds (5 digits each, offset back from +10000, then convert to scaled decimal)
        spreadAwayOdds = americanToOddsTick(((_uint / 1e19) % 1e5));
        spreadHomeOdds = americanToOddsTick(((_uint / 1e14) % 1e5));

        // Extract total (4 digits, offset back from +1000)
        totalLineTicks = int32(int256((_uint / 1e10) % 1e4)) - 1000;

        // Extract total odds (5 digits each, offset back from +10000, then convert to scaled decimal)
        overOdds = americanToOddsTick(((_uint / 1e5) % 1e5));
        underOdds = americanToOddsTick((_uint % 1e5));

        return (
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadLineTicks,
            spreadAwayOdds,
            spreadHomeOdds,
            totalLineTicks,
            overOdds,
            underOdds
        );
    }

    /**
     * @notice Converts American odds to a tick value (uint16).
     * @dev - For positive American odds: tick = 100 + (american)
     *      - For negative American odds: tick = 100 + round(10000 / abs(american))
     *      Uses round-to-nearest so -110 becomes 191 (1.91), not 190 (1.90).
     * @param americanOdds American odds offset by +10000 in the packed data.
     * @return uint16 Odds tick (e.g., 1.91 = 191, 2.50 = 250).
     */
    function americanToOddsTick(
        uint256 americanOdds
    ) internal pure returns (uint16) {
        if (americanOdds == 10000) return 0; // invalid odds, return 0 to signal no data
        // casting to 'int256' is safe because americanOdds is a 5-digit packed value (max 99999)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 american = int256(americanOdds) - 10000;

        if (american > 0) {
            // +150 → 100 + 150 = 250 (2.50) — always exact, no rounding needed
            // casting to 'uint256' is safe because american is positive in this branch
            // casting to 'uint16' is safe because MAX_ODDS (10100) fits in uint16
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint16(ODDS_SCALE + uint256(american));
        } else {
            // -110 → 100 + round(10000 / 110) = 100 + round(90.909...) = 100 + 91 = 191
            // casting to 'uint256' is safe because -american is positive in this branch
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absAmerican = uint256(-american);
            uint256 profit = (uint256(ODDS_SCALE) * 100 + absAmerican / 2) /
                absAmerican;
            // casting to 'uint16' is safe because result is bounded by MAX_ODDS
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint16(ODDS_SCALE + profit);
        }
    }

    /**
     * @notice Sets the LINK denominator
     * @param denominator The denominator for the LINK payment
     */
    function setLinkDenominator(uint256 denominator) external onlyAdmin {
        s_linkDenominator = denominator;
        emit LinkDenominatorSet(denominator);
        i_ospexCore.emitCoreEvent(
            keccak256("LINK_DENOMINATOR_SET"),
            abi.encode(denominator)
        );
    }

    // --- Helper Function for Module Lookups ---
    /**
     * @notice Gets the module address
     * @param moduleType The type of module
     */
    function _getModule(
        bytes32 moduleType
    ) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) {
            revert OracleModule__ModuleNotSet(moduleType);
        }
        return module;
    }
}
