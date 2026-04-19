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
    SignatureChecker
} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {
    Contest,
    ContestStatus,
    LeagueId,
    OracleRequestContext,
    OracleRequestType,
    ScriptApproval,
    ScriptPurpose
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

    bytes32 public constant EVENT_ORACLE_RESPONSE =
        keccak256("ORACLE_RESPONSE");
    bytes32 public constant EVENT_SCRIPT_APPROVAL_VERIFIED =
        keccak256("SCRIPT_APPROVAL_VERIFIED");
    bytes32 public constant EVENT_ORACLE_REQUEST_FAILED =
        keccak256("ORACLE_REQUEST_FAILED");

    /// @notice EIP-712 typehash for script approval
    bytes32 public constant SCRIPT_APPROVAL_TYPEHASH =
        keccak256(
            "ScriptApproval(bytes32 scriptHash,uint8 purpose,uint8 leagueId,uint16 version,uint64 validUntil)"
        );

    /// @notice EIP-712 domain separator typehash
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    // ──────────────────────────── Errors ───────────────────────────────

    /// @notice Thrown when a constructor address parameter is zero
    error OracleModule__InvalidAddress();
    /// @notice Thrown when a required module is not registered in OspexCore
    error OracleModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Thrown when the market updating JS hash does not match the per-contest stored hash
    error OracleModule__IncorrectUpdateSourceHash();
    /// @notice Thrown when the scoring JS hash does not match the per-contest stored hash
    error OracleModule__IncorrectScoreSourceHash();
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
    /// @notice Thrown when an EIP-712 script approval signature is invalid (wrong signer or malformed)
    error OracleModule__InvalidScriptApproval();
    /// @notice Thrown when a script approval has expired (validUntil != 0 and validUntil < block.timestamp)
    error OracleModule__ScriptApprovalExpired();
    /// @notice Thrown when a script approval's purpose field does not match the expected purpose slot
    error OracleModule__WrongApprovalPurpose();
    /// @notice Thrown when a script approval's scriptHash does not match the actual script hash
    error OracleModule__ScriptHashMismatch();
    /// @notice Thrown when two or more script approvals specify different non-Unknown leagueIds
    error OracleModule__ConflictingApprovalLeagues();

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted on every Chainlink Functions callback
    /// @param requestId The Chainlink request ID
    /// @param response The raw response bytes
    /// @param err The error bytes (empty on success)
    event Response(bytes32 indexed requestId, bytes response, bytes err);

    /// @notice Emitted for each script approval verified during contest creation
    /// @param contestId The contest ID (predictive — contest struct stored after verification)
    /// @param scriptHash The approved script hash
    /// @param purpose The script purpose (VERIFY, MARKET_UPDATE, or SCORE)
    /// @param leagueId The league binding from the approval (Unknown = wildcard)
    /// @param version The approval version for off-chain tracking
    event ScriptApprovalVerified(
        uint256 indexed contestId,
        bytes32 scriptHash,
        ScriptPurpose purpose,
        LeagueId leagueId,
        uint16 version
    );

    /// @notice Emitted on callback error
    /// @param requestId The oracle request id
    /// @param contestId The contest ID
    /// @param requestType The oracle request type
    /// @param err The actual error that caused the failure
    event OracleRequestFailed(
        bytes32 indexed requestId,
        uint256 indexed contestId,
        OracleRequestType requestType,
        bytes err
    );

    // ──────────────────────────── Structs ──────────────────────────────

    /// @notice Bundles contest identity strings and Chainlink request configuration
    /// @dev Passed as a single calldata struct alongside the two source hashes and script
    /// @param rundownId External ID from Rundown API
    /// @param sportspageId External ID from Sportspage API
    /// @param jsonoddsId External ID from JSONOdds API
    /// @param createContestSourceJS The JS source code for contest verification
    /// @param encryptedSecretsUrls Chainlink Functions encrypted secrets (credentials only)
    /// @param subscriptionId Chainlink Functions subscription ID
    /// @param gasLimit Gas limit for the Chainlink callback
    struct CreateContestParams {
        string rundownId;
        string sportspageId;
        string jsonoddsId;
        string createContestSourceJS;
        bytes encryptedSecretsUrls;
        uint64 subscriptionId;
        uint32 gasLimit;
    }

    /// @notice Bundles all three script approvals and their signatures for contest creation
    /// @dev Passed as a single calldata struct to avoid stack-too-deep in createContestFromOracle.
    ///      Each approval is verified via EIP-712 at creation time only; signatures are not stored.
    /// @param verifyApproval Approval for the verification script
    /// @param verifyApprovalSig EIP-712 signature over verifyApproval
    /// @param marketUpdateApproval Approval for the market update script
    /// @param marketUpdateApprovalSig EIP-712 signature over marketUpdateApproval
    /// @param scoreApproval Approval for the scoring script
    /// @param scoreApprovalSig EIP-712 signature over scoreApproval
    struct ScriptApprovals {
        ScriptApproval verifyApproval;
        bytes verifyApprovalSig;
        ScriptApproval marketUpdateApproval;
        bytes marketUpdateApprovalSig;
        ScriptApproval scoreApproval;
        bytes scoreApprovalSig;
    }

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

    /// @notice The trusted signer for script approvals (EOA or EIP-1271 contract wallet e.g. Safe)
    address public immutable i_approvedSigner;
    /// @notice EIP-712 domain separator, baked at deployment. Domain name "OspexOracle", version "1".
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Request ID → request context (type + contest ID)
    mapping(bytes32 => OracleRequestContext) public s_requestContext;
    /// @notice Contest ID → latest market update request ID (only the latest callback writes)
    mapping(uint256 => bytes32) internal s_latestMarketRequestId;

    // ──────────────────────────── Constructor ──────────────────────────

    /**
     * @notice Deploys the OracleModule with immutable Chainlink and approval configuration
     * @param ospexCore_ The OspexCore contract address
     * @param router The Chainlink Functions router address
     * @param linkAddress The LINK token address
     * @param donId The Chainlink Functions DON ID
     * @param linkDenominator Divisor for per-request LINK payment
     * @param approvedSigner The trusted signer for script approvals (EOA or EIP-1271 wallet)
     */
    constructor(
        address ospexCore_,
        address router,
        address linkAddress,
        bytes32 donId,
        uint256 linkDenominator,
        address approvedSigner
    ) FunctionsClient(router) {
        if (
            ospexCore_ == address(0) ||
            router == address(0) ||
            linkAddress == address(0) ||
            donId == bytes32(0) ||
            approvedSigner == address(0)
        ) {
            revert OracleModule__InvalidAddress();
        }
        if (linkDenominator == 0 || linkDenominator > LINK_DIVISIBILITY)
            revert OracleModule__InvalidValue();
        i_ospexCore = OspexCore(ospexCore_);
        i_linkAddress = linkAddress;
        i_donId = donId;
        i_linkDenominator = linkDenominator;
        i_approvedSigner = approvedSigner;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("OspexOracle"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ──────────────────────────── Contest Creation ─────────────────────

    /**
     * @notice Creates a contest and sends an oracle request to verify it
     * @dev Permissionless. Caller pays LINK for the oracle request and USDC for the
     *      contest creation fee. The contest is created as Unverified; the oracle callback
     *      sets league ID and start time via setContestLeagueIdAndStartTime.
     *
     *      Both the LINK payment (to the Chainlink Functions subscription) and the USDC
     *      contest creation fee are captured upfront and are non-refundable.
     *
     *      All three script approvals (verify, marketUpdate, score) are verified via
     *      EIP-712 signature at creation time only. After creation, scripts are validated
     *      by hash-match only (scoreContestFromOracle, updateContestMarketsFromOracle),
     *      so signer rotation and approval expiry cannot affect live contests.
     *
     *      DESIGN ASSUMPTION: encryptedSecretsUrls contain API credentials only (JSONOdds,
     *      Rundown, Sportspage keys). They do not alter JS execution behavior. The script
     *      hash fully determines behavior. If secrets ever become behavior-altering, a
     *      providerSetHash field must be added to the approval system.
     * @param params Contest identity strings and Chainlink request configuration
     * @param marketUpdateSourceHash Hash of the odds updating JS (stored per-contest)
     * @param scoreContestSourceHash Hash of the scoring JS (stored per-contest)
     * @param approvals The three script approvals and their EIP-712 signatures
     */
    function createContestFromOracle(
        CreateContestParams calldata params,
        bytes32 marketUpdateSourceHash,
        bytes32 scoreContestSourceHash,
        ScriptApprovals calldata approvals
    ) external nonReentrant handleLinkPayment(params.subscriptionId) {
        uint256 contestId;
        {
            bytes32 verifyHash = keccak256(
                abi.encodePacked(params.createContestSourceJS)
            );

            LeagueId approvedLeague = _validateApprovals(
                approvals,
                verifyHash,
                marketUpdateSourceHash,
                scoreContestSourceHash
            );

            contestId = IContestModule(_getModule(CONTEST_MODULE))
                .createContest(
                    params.rundownId,
                    params.sportspageId,
                    params.jsonoddsId,
                    verifyHash,
                    marketUpdateSourceHash,
                    scoreContestSourceHash,
                    approvedLeague,
                    msg.sender
                );
        }

        _emitApprovalEvents(approvals, contestId);

        string[] memory args = new string[](3);
        args[0] = params.rundownId;
        args[1] = params.sportspageId;
        args[2] = params.jsonoddsId;

        sendRequest(
            params.createContestSourceJS,
            params.encryptedSecretsUrls,
            args,
            params.subscriptionId,
            params.gasLimit,
            i_donId,
            OracleRequestType.ContestCreate,
            contestId
        );
    }

    /**
     * @notice Validates all three script approvals without emitting events
     * @dev Checks purpose binding, hash matching, and EIP-712 signature for each
     *      approval in lifecycle order (verify, marketUpdate, score). Separated from
     *      event emission so approvals can be validated before contest creation while
     *      events use the real (non-predicted) contestId.
     * @param approvals The three script approvals and their EIP-712 signatures
     * @param verifyHash keccak256 of the verification JS source
     * @param marketUpdateSourceHash Hash of the market update JS
     * @param scoreContestSourceHash Hash of the scoring JS
     * @return The resolved LeagueId from the three approvals
     */
    function _validateApprovals(
        ScriptApprovals calldata approvals,
        bytes32 verifyHash,
        bytes32 marketUpdateSourceHash,
        bytes32 scoreContestSourceHash
    ) internal view returns (LeagueId) {
        if (approvals.verifyApproval.purpose != ScriptPurpose.VERIFY)
            revert OracleModule__WrongApprovalPurpose();
        if (approvals.verifyApproval.scriptHash != verifyHash)
            revert OracleModule__ScriptHashMismatch();
        _verifyScriptApproval(
            approvals.verifyApproval,
            approvals.verifyApprovalSig
        );

        if (
            approvals.marketUpdateApproval.purpose !=
            ScriptPurpose.MARKET_UPDATE
        ) revert OracleModule__WrongApprovalPurpose();
        if (approvals.marketUpdateApproval.scriptHash != marketUpdateSourceHash)
            revert OracleModule__ScriptHashMismatch();
        _verifyScriptApproval(
            approvals.marketUpdateApproval,
            approvals.marketUpdateApprovalSig
        );

        if (approvals.scoreApproval.purpose != ScriptPurpose.SCORE)
            revert OracleModule__WrongApprovalPurpose();
        if (approvals.scoreApproval.scriptHash != scoreContestSourceHash)
            revert OracleModule__ScriptHashMismatch();
        _verifyScriptApproval(
            approvals.scoreApproval,
            approvals.scoreApprovalSig
        );

        return
            _resolveApprovedLeague(
                approvals.verifyApproval.leagueId,
                approvals.marketUpdateApproval.leagueId,
                approvals.scoreApproval.leagueId
            );
    }

    /**
     * @notice Emits ScriptApprovalVerified events for all three script approvals
     * @dev Called after contest creation so events carry the real contestId returned
     *      by ContestModule, not a predicted value. Emits both the local event and
     *      the OspexCore hub event for each approval.
     * @param approvals The three script approvals (already validated by _validateApprovals)
     * @param contestId The actual contest ID returned by ContestModule.createContest
     */
    function _emitApprovalEvents(
        ScriptApprovals calldata approvals,
        uint256 contestId
    ) internal {
        emit ScriptApprovalVerified(
            contestId,
            approvals.verifyApproval.scriptHash,
            approvals.verifyApproval.purpose,
            approvals.verifyApproval.leagueId,
            approvals.verifyApproval.version
        );
        i_ospexCore.emitCoreEvent(
            EVENT_SCRIPT_APPROVAL_VERIFIED,
            abi.encode(
                contestId,
                approvals.verifyApproval.scriptHash,
                approvals.verifyApproval.purpose,
                approvals.verifyApproval.leagueId,
                approvals.verifyApproval.version
            )
        );

        emit ScriptApprovalVerified(
            contestId,
            approvals.marketUpdateApproval.scriptHash,
            approvals.marketUpdateApproval.purpose,
            approvals.marketUpdateApproval.leagueId,
            approvals.marketUpdateApproval.version
        );
        i_ospexCore.emitCoreEvent(
            EVENT_SCRIPT_APPROVAL_VERIFIED,
            abi.encode(
                contestId,
                approvals.marketUpdateApproval.scriptHash,
                approvals.marketUpdateApproval.purpose,
                approvals.marketUpdateApproval.leagueId,
                approvals.marketUpdateApproval.version
            )
        );

        emit ScriptApprovalVerified(
            contestId,
            approvals.scoreApproval.scriptHash,
            approvals.scoreApproval.purpose,
            approvals.scoreApproval.leagueId,
            approvals.scoreApproval.version
        );
        i_ospexCore.emitCoreEvent(
            EVENT_SCRIPT_APPROVAL_VERIFIED,
            abi.encode(
                contestId,
                approvals.scoreApproval.scriptHash,
                approvals.scoreApproval.purpose,
                approvals.scoreApproval.leagueId,
                approvals.scoreApproval.version
            )
        );
    }

    // ──────────────────────────── Market Updates ──────────────────────

    /**
     * @notice Sends an oracle request to update market data for a verified contest
     * @dev Permissionless. Caller pays LINK. Contest must be in Verified status.
     *      Supersedes any in-flight market update for the same contest — only the
     *      latest request's callback writes; earlier callbacks are silently dropped.
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

        bytes32 reqId = sendRequest(
            contestMarketsUpdateSourceJS,
            encryptedSecretsUrls,
            args,
            subscriptionId,
            gasLimit,
            i_donId,
            OracleRequestType.ContestMarketsUpdate,
            contestId
        );
        s_latestMarketRequestId[contestId] = reqId;
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
        i_ospexCore.emitCoreEvent(
            EVENT_ORACLE_RESPONSE,
            abi.encode(requestId, response, err)
        );

        if (err.length > 0) {
            emit OracleRequestFailed(
                requestId,
                ctx.contestId,
                ctx.requestType,
                err
            );
            i_ospexCore.emitCoreEvent(
                EVENT_ORACLE_REQUEST_FAILED,
                abi.encode(requestId, ctx.contestId, ctx.requestType, err)
            );
            delete s_requestContext[requestId];
            return;
        }

        if (ctx.requestType == OracleRequestType.ContestCreate) {
            _handleContestCreate(ctx.contestId, response);
        } else if (ctx.requestType == OracleRequestType.ContestMarketsUpdate) {
            if (requestId != s_latestMarketRequestId[ctx.contestId]) {
                delete s_requestContext[requestId];
                return;
            }
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

        IContestModule(_getModule(CONTEST_MODULE)).updateContestMarkets(
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
        if (response.length != 32) {
            revert OracleModule__InputTooShort(response.length, 32);
        }
        uint32[2] memory scores = uintToResultScore(
            abi.decode(response, (uint32))
        );
        IContestModule(_getModule(CONTEST_MODULE)).setScores(
            contestId,
            scores[0],
            scores[1]
        );
    }

    // ──────────────────────────── Byte Conversion Utilities ───────────

    /**
     * @notice Converts a bytes response to uint256 (reads first 32 bytes)
     * @param input The raw bytes from the DON
     * @return output The uint256 value
     */
    function bytesToUint256(
        bytes memory input
    ) internal pure returns (uint256 output) {
        if (input.length != 32) {
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
        uint256 rawLeague = _uint / 1e18;
        if (rawLeague > type(uint8).max) revert OracleModule__InvalidValue();
        uint256 rawStartTime = _uint % 1e10;
        if (rawStartTime > type(uint32).max)
            revert OracleModule__InvalidValue();
        // forge-lint: disable-next-line(unsafe-typecast)
        leagueId = LeagueId(uint8(rawLeague));
        // forge-lint: disable-next-line(unsafe-typecast)
        startTime = uint32(rawStartTime);
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

    // ──────────────────────────── Script Approval Verification ────────

    /**
     * @notice Verifies an EIP-712 signed script approval against i_approvedSigner
     * @dev Uses SignatureChecker to support both EOA and EIP-1271 contract wallets (e.g. Safe).
     *      Checks signature validity first, then temporal validity (expiry).
     * @param approval The script approval struct from calldata
     * @param signature The EIP-712 signature bytes
     */
    function _verifyScriptApproval(
        ScriptApproval calldata approval,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                SCRIPT_APPROVAL_TYPEHASH,
                approval.scriptHash,
                uint8(approval.purpose),
                uint8(approval.leagueId),
                approval.version,
                approval.validUntil
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        if (
            !SignatureChecker.isValidSignatureNow(
                i_approvedSigner,
                digest,
                signature
            )
        ) {
            revert OracleModule__InvalidScriptApproval();
        }
        if (approval.validUntil != 0 && block.timestamp >= approval.validUntil) {
            revert OracleModule__ScriptApprovalExpired();
        }
    }

    /**
     * @notice Resolves the approved league from three script approvals
     * @dev If two or more approvals have different non-Unknown leagueIds, reverts.
     *      If exactly one is non-Unknown, returns it. If all Unknown, returns Unknown.
     * @param a LeagueId from the first approval
     * @param b LeagueId from the second approval
     * @param c LeagueId from the third approval
     * @return The resolved LeagueId to set on the Contest
     */
    function _resolveApprovedLeague(
        LeagueId a,
        LeagueId b,
        LeagueId c
    ) internal pure returns (LeagueId) {
        LeagueId resolved = LeagueId.Unknown;

        if (a != LeagueId.Unknown) {
            resolved = a;
        }
        if (b != LeagueId.Unknown) {
            if (resolved != LeagueId.Unknown && resolved != b) {
                revert OracleModule__ConflictingApprovalLeagues();
            }
            resolved = b;
        }
        if (c != LeagueId.Unknown) {
            if (resolved != LeagueId.Unknown && resolved != c) {
                revert OracleModule__ConflictingApprovalLeagues();
            }
            resolved = c;
        }

        return resolved;
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
