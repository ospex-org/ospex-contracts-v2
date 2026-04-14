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
 * @notice Handles all Chainlink Functions interactions for the Ospex protocol:
 *         contest creation/verification, market data updates, and scoring.
 * @dev Permissionless — any caller may trigger oracle requests by paying LINK.
 *      Scoring validates the source JS hash against the per-contest stored hash.
 *      Contest creation and market updates accept arbitrary JS.
 */

contract OracleModule is FunctionsClient, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");

    /// @notice LINK token base unit (1e18)
    uint256 internal constant LINK_DIVISIBILITY = 10 ** 18;
    /// @notice Odds scale factor (1.91 odds = 191 ticks)
    uint16 public constant ODDS_SCALE = 100;

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a constructor address parameter is zero
    error OracleModule__InvalidAddress();
    /// @notice Thrown when a required module is not registered in OspexCore
    error OracleModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the market updating JS hash does not match the per-contest stored hash
    error OracleModule__IncorrectUpdateSourceHash();
    /// @notice Thrown when the scoring JS hash does not match the per-contest stored hash
    error OracleModule__IncorrectScoreSourceHash();
    /// @notice Thrown when a Chainlink Functions callback contains an error
    error OracleModule__ChainlinkFunctionError(bytes err);
    /// @notice Thrown when LINK transferAndCall to the DON subscription fails
    error OracleModule__SubscriptionPaymentFailed(uint256 payment);
    /// @notice Thrown when a contest is not in Verified status
    error OracleModule__ContestNotVerified();
    /// @notice Thrown when attempting to score a contest that has not started
    error OracleModule__ContestNotStarted(uint256 contestId);
    /// @notice Thrown when a callback arrives for an unknown request ID
    error OracleModule__UnexpectedRequestId(bytes32 requestId);
    /// @notice Thrown when a bytes response is shorter than expected
    error OracleModule__InputTooShort(
        uint256 inputLength,
        uint256 expectedLength
    );
    /// @notice Thrown when a callback has an unrecognized request type
    error OracleModule__InvalidRequestType(OracleRequestType requestType);
    /// @notice Thrown when an immutable configuration value is invalid (e.g. zero denominator)
    error OracleModule__InvalidValue();

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted on every Chainlink Functions callback
    /// @param requestId The Chainlink request ID
    /// @param response The raw response bytes
    /// @param err The error bytes (empty on success)
    event Response(bytes32 indexed requestId, bytes response, bytes err);

    // ──────────────────────────── Modifiers ────────────────────────────

    /**
     * @notice Transfers LINK from the caller and funds the DON subscription
     * @param subscriptionId The Chainlink Functions subscription ID
     */
    modifier handleLinkPayment(uint64 subscriptionId) {
        uint256 payment = LINK_DIVISIBILITY / i_linkDenominator;

        IERC20(i_linkAddress).safeTransferFrom(
            msg.sender,
            address(this),
            payment
        );

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

    // ──────────────────────────── State ────────────────────────────────

    /// @notice The OspexCore contract
    OspexCore public immutable i_ospexCore;
    /// @notice The LINK token address
    address internal immutable i_linkAddress;
    /// @notice The Chainlink Functions DON ID
    bytes32 public immutable i_donId;
    /// @notice Divisor for LINK payment (payment = 1e18 / i_linkDenominator)
    uint256 public immutable i_linkDenominator;

    /// @notice Request ID → request context (type + contest ID)
    mapping(bytes32 => OracleRequestContext) public s_requestContext;

    // ──────────────────────────── Constructor ──────────────────────────

    /**
     * @notice Deploys the OracleModule with immutable Chainlink configuration
     * @param ospexCore_ The OspexCore contract address
     * @param router The Chainlink Functions router address
     * @param linkAddress The LINK token address
     * @param donId The Chainlink Functions DON ID
     * @param linkDenominator Divisor for per-request LINK payment
     */
    constructor(
        address ospexCore_,
        address router,
        address linkAddress,
        bytes32 donId,
        uint256 linkDenominator
    ) FunctionsClient(router) {
        if (
            ospexCore_ == address(0) ||
            router == address(0) ||
            linkAddress == address(0) ||
            donId == bytes32(0)
        ) {
            revert OracleModule__InvalidAddress();
        }
        if (linkDenominator == 0) revert OracleModule__InvalidValue();
        i_ospexCore = OspexCore(ospexCore_);
        i_linkAddress = linkAddress;
        i_donId = donId;
        i_linkDenominator = linkDenominator;
    }

    // ──────────────────────────── Contest Creation ─────────────────────

    /**
     * @notice Creates a contest and sends an oracle request to verify it
     * @dev Permissionless. Caller pays LINK for the oracle request and USDC for the
     *      contest creation fee. The contest is created as Unverified; the oracle callback
     *      sets league ID and start time via setContestLeagueIdAndStartTime.
     *      Note: contestId is predicted by reading the counter + 1. This is coupled to
     *      ContestModule's increment-then-assign pattern.
     * @param rundownId External ID from Rundown API
     * @param sportspageId External ID from Sportspage API
     * @param jsonoddsId External ID from JSONOdds API
     * @param createContestSourceJS The JS source code for contest verification
     * @param scoreContestSourceHash Hash of the scoring JS (stored per-contest)
     * @param marketUpdateSourceHash Hash of the odds updating JS (stored per-contest)
     * @param encryptedSecretsUrls Chainlink Functions encrypted secrets
     * @param subscriptionId Chainlink Functions subscription ID
     * @param gasLimit Gas limit for the callback
     */
    function createContestFromOracle(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId,
        string calldata createContestSourceJS,
        bytes32 scoreContestSourceHash,
        bytes32 marketUpdateSourceHash,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        IContestModule contestModule = IContestModule(
            _getModule(CONTEST_MODULE)
        );

        uint256 contestId = contestModule.s_contestIdCounter() + 1;

        string[] memory args = new string[](3);
        args[0] = rundownId;
        args[1] = sportspageId;
        args[2] = jsonoddsId;

        contestModule.createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            marketUpdateSourceHash,
            msg.sender
        );

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

    // ──────────────────────────── Market Updates ──────────────────────

    /**
     * @notice Sends an oracle request to update market data for a verified contest
     * @dev Permissionless. Caller pays LINK. Contest must be in Verified status.
     * @param contestId The contest ID
     * @param contestMarketsUpdateSourceJS The JS source code for market data extraction
     * @param encryptedSecretsUrls Chainlink Functions encrypted secrets
     * @param subscriptionId Chainlink Functions subscription ID
     * @param gasLimit Gas limit for the callback
     */
    function updateContestMarketsFromOracle(
        uint256 contestId,
        string calldata contestMarketsUpdateSourceJS,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        IContestModule contestModule = IContestModule(
            _getModule(CONTEST_MODULE)
        );

        Contest memory contest = contestModule.getContest(contestId);

        if (
            keccak256(abi.encodePacked(contestMarketsUpdateSourceJS)) !=
            contest.marketUpdateSourceHash
        ) {
            revert OracleModule__IncorrectUpdateSourceHash();
        }


        if (contest.contestStatus != ContestStatus.Verified) {
            revert OracleModule__ContestNotVerified();
        }

        string[] memory args = new string[](3);
        args[0] = contest.rundownId;
        args[1] = contest.sportspageId;
        args[2] = contest.jsonoddsId;

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

    // ──────────────────────────── Scoring ─────────────────────────────

    /**
     * @notice Sends an oracle request to score a verified contest
     * @dev Permissionless. Caller pays LINK. The scoring JS hash must match the
     *      per-contest stored hash. Contest must be Verified and must have started.
     *      Once a score is posted on-chain, it is final and cannot be overwritten.
     * @param contestId The contest ID
     * @param scoreContestSourceJS The JS source code for scoring
     * @param encryptedSecretsUrls Chainlink Functions encrypted secrets
     * @param subscriptionId Chainlink Functions subscription ID
     * @param gasLimit Gas limit for the callback
     */
    function scoreContestFromOracle(
        uint256 contestId,
        string calldata scoreContestSourceJS,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        IContestModule contestModule = IContestModule(
            _getModule(CONTEST_MODULE)
        );

        Contest memory contest = contestModule.getContest(contestId);

        if (contest.contestStatus != ContestStatus.Verified) {
            revert OracleModule__ContestNotVerified();
        }

        if (
            keccak256(abi.encodePacked(scoreContestSourceJS)) !=
            contest.scoreContestSourceHash
        ) {
            revert OracleModule__IncorrectScoreSourceHash();
        }

        if (block.timestamp < contestModule.s_contestStartTimes(contestId)) {
            revert OracleModule__ContestNotStarted(contestId);
        }

        string[] memory args = new string[](3);
        args[0] = contest.rundownId;
        args[1] = contest.sportspageId;
        args[2] = contest.jsonoddsId;

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

    // ──────────────────────────── Request Handling ────────────────────

    /**
     * @notice Builds and sends a Chainlink Functions request
     * @param source The JS source code
     * @param secrets The encrypted secrets reference
     * @param args The string arguments for the JS function
     * @param subscriptionId The Chainlink subscription ID
     * @param gasLimit The callback gas limit
     * @param donId The DON ID
     * @param requestType The type of oracle request
     * @param contestId The contest this request is for
     * @return requestId The Chainlink request ID
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
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donId
        );

        s_requestContext[requestId] = OracleRequestContext({
            requestType: requestType,
            contestId: contestId
        });

        return requestId;
    }

    // ──────────────────────────── Chainlink Callback ──────────────────

    /**
     * @notice Chainlink Functions callback. Routes the response to the appropriate handler.
     * @param requestId The Chainlink request ID
     * @param response The raw response bytes from the DON
     * @param err The error bytes (non-empty on DON-side failure)
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        OracleRequestContext memory ctx = s_requestContext[requestId];
        if (ctx.contestId == 0)
            revert OracleModule__UnexpectedRequestId(requestId);

        emit Response(requestId, response, err);

        if (err.length > 0) {
            revert OracleModule__ChainlinkFunctionError(err);
        }

        if (ctx.requestType == OracleRequestType.ContestCreate) {
            _handleContestCreate(ctx.contestId, response);
        } else if (ctx.requestType == OracleRequestType.ContestMarketsUpdate) {
            _handleContestMarketsUpdate(ctx.contestId, response);
        } else if (ctx.requestType == OracleRequestType.ContestScore) {
            _handleContestScore(ctx.contestId, response);
        } else {
            revert OracleModule__InvalidRequestType(ctx.requestType);
        }

        delete s_requestContext[requestId];
    }

    // ──────────────────────────── Response Handlers ───────────────────

    /**
     * @notice Handles contest creation callback — extracts league and start time
     * @param contestId The contest ID
     * @param response The raw oracle response
     */
    function _handleContestCreate(
        uint256 contestId,
        bytes memory response
    ) internal {
        uint256 contestData = bytesToUint256(response);
        (LeagueId leagueId, uint32 startTime) = extractLeagueIdAndStartTime(
            contestData
        );

        IContestModule(_getModule(CONTEST_MODULE))
            .setContestLeagueIdAndStartTime(contestId, leagueId, startTime);
    }

    /**
     * @notice Handles market update callback — extracts and stores all market data
     * @param contestId The contest ID
     * @param response The raw oracle response
     */
    function _handleContestMarketsUpdate(
        uint256 contestId,
        bytes memory response
    ) internal {
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

        IContestModule(_getModule(CONTEST_MODULE))
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
     * @notice Handles scoring callback — extracts scores and finalizes the contest
     * @param contestId The contest ID
     * @param response The raw oracle response
     */
    function _handleContestScore(
        uint256 contestId,
        bytes memory response
    ) internal {
        uint32[2] memory scores = uintToResultScore(bytesToUint32(response));
        IContestModule(_getModule(CONTEST_MODULE)).setScores(
            contestId,
            scores[0],
            scores[1]
        );
    }

    // ──────────────────────────── Byte Conversion Utilities ───────────

    /**
     * @notice Converts a bytes response to uint32 (reads first 32 bytes, returns as uint32)
     * @param input The raw bytes from the DON
     * @return output The uint32 value
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
     * @notice Converts a bytes response to uint256 (reads first 32 bytes)
     * @param input The raw bytes from the DON
     * @return output The uint256 value
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

    // ──────────────────────────── Oracle Data Extraction ──────────────

    /**
     * @notice Extracts leagueId and event start time from a packed uint256
     * @dev Format: [leagueId (2 digits)][...][startTime (10 digits)].
     *      leagueId = _uint / 1e18, startTime = _uint % 1e10.
     * @param _uint The packed oracle response
     * @return leagueId The league ID enum
     * @return startTime Unix timestamp of contest start
     */
    function extractLeagueIdAndStartTime(
        uint256 _uint
    ) internal pure returns (LeagueId leagueId, uint32 startTime) {
        // Safe cast: LeagueId enum has fewer than 256 values
        // forge-lint: disable-next-line(unsafe-typecast)
        leagueId = LeagueId(uint8(_uint / 1e18));
        // Safe cast: modulo 1e10 always fits in uint32 (max 4.29e9)
        // forge-lint: disable-next-line(unsafe-typecast)
        startTime = uint32(_uint % 1e10);
        return (leagueId, startTime);
    }

    /**
     * @notice Converts a packed uint32 score response into [away, home] scores
     * @dev Format: awayScore * 1000 + homeScore
     * @param _uint The packed score value
     * @return scoreArr [awayScore, homeScore]
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
     * @notice Extracts contest market data from a packed uint256
     * @dev The packed format (38 digits total):
     *      [moneylineAway(5)][moneylineHome(5)][spread(4)][spreadAway(5)][spreadHome(5)][total(4)][over(5)][under(5)]
     *      American odds are offset by +10000 in JS to handle negatives.
     *      Numbers (spread/total) are offset by +1000 and stored as 10x for half-point precision.
     * @param _uint The packed uint256 containing all market data
     * @return moneylineAwayOdds Away moneyline odds tick
     * @return moneylineHomeOdds Home moneyline odds tick
     * @return spreadLineTicks The spread (10x format)
     * @return spreadAwayOdds Away spread odds tick
     * @return spreadHomeOdds Home spread odds tick
     * @return totalLineTicks The total (10x format)
     * @return overOdds Over odds tick
     * @return underOdds Under odds tick
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
        moneylineAwayOdds = americanToOddsTick(((_uint / 1e33) % 1e5));
        moneylineHomeOdds = americanToOddsTick(((_uint / 1e28) % 1e5));
        spreadLineTicks = int32(int256((_uint / 1e24) % 1e4)) - 1000;
        spreadAwayOdds = americanToOddsTick(((_uint / 1e19) % 1e5));
        spreadHomeOdds = americanToOddsTick(((_uint / 1e14) % 1e5));
        totalLineTicks = int32(int256((_uint / 1e10) % 1e4)) - 1000;
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
     * @notice Converts American odds (offset by +10000) to a tick value
     * @dev Positive: tick = 100 + american. Negative: tick = 100 + round(10000 / |american|).
     *      Uses round-to-nearest so -110 → 191 (1.91), not 190.
     * @param americanOdds American odds offset by +10000 from the packed data
     * @return Odds tick (e.g. 191 = 1.91, 250 = 2.50)
     */
    function americanToOddsTick(
        uint256 americanOdds
    ) internal pure returns (uint16) {
        if (americanOdds == 10000) return 0;
        // Safe cast: americanOdds is a 5-digit packed value (max 99999)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 american = int256(americanOdds) - 10000;

        if (american > 0) {
            // +150 → 100 + 150 = 250 (2.50)
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint16(ODDS_SCALE + uint256(american));
        } else {
            // -110 → 100 + round(10000 / 110) = 191
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absAmerican = uint256(-american);
            uint256 profit = (uint256(ODDS_SCALE) * 100 + absAmerican / 2) /
                absAmerican;
            // casting to 'uint16' is safe, result is bounded by MAX_ODDS
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint16(ODDS_SCALE + profit);
        }
    }

    // ──────────────────────────── Module Lookup ───────────────────────

    /**
     * @notice Resolves a module address from OspexCore, reverting if not set
     * @param moduleType The module type identifier
     * @return module The module contract address
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
