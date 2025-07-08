// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title OracleModule
 * @author ospex.org
 * @notice Module for oracle interactions, contest verification, and scoring
 */

import {FunctionsClient} from "../../lib/chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "../../lib/chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1363} from "@openzeppelin/contracts/interfaces/IERC1363.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Contest, ContestStatus, LeagueId, OracleRequestContext, OracleRequestType, Speculation, SpeculationStatus} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";
import {ISpeculationModule} from "../interfaces/ISpeculationModule.sol";
import {IPositionModule} from "../interfaces/IPositionModule.sol";
import {ILeaderboardModule} from "../interfaces/ILeaderboardModule.sol";

contract OracleModule is FunctionsClient, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    /// @notice Error for not admin
    error OracleModule__NotAdmin(address admin);
    /// @notice Error for invalid module address
    error OracleModule__InvalidModuleAddress();
    /// @notice Error for module not set
    error OracleModule__ModuleNotSet(bytes32 moduleType);
    /// @notice Error for incorrect source hash
    error OracleModule__IncorrectSourceHash();
    /// @notice Error for incorrect score source hash
    error OracleModule__IncorrectScoreSourceHash();
    /// @notice Error for chainlink function error
    error OracleModule__ChainlinkFunctionError(bytes err);
    /// @notice Error for subscription payment failed
    error OracleModule__SubscriptionPaymentFailed(uint256 payment);
    /// @notice Error for contest module not set
    error OracleModule__ContestModuleNotSet();
    /// @notice Error for contest not verified
    error OracleModule__ContestNotVerified();
    /// @notice Error for contest not started
    error OracleModule__ContestNotStarted(uint256 contestId);
    /// @notice Error for speculation does not exist
    error OracleModule__SpeculationDoesNotExist(uint256 speculationId);
    /// @notice Error for speculation not open
    error OracleModule__SpeculationNotOpen(uint256 speculationId);
    /// @notice Error for speculation not for contest
    error OracleModule__SpeculationNotForContest(uint256 contestId);
    /// @notice Error for speculation started
    error OracleModule__SpeculationStarted(uint256 speculationId);
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

    // Chainlink Functions config
    address public s_router;
    bytes32 public s_donId;

    // Request tracking
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;
    mapping(bytes32 => uint256) public s_requestMapping;

    // Request context
    mapping(bytes32 => OracleRequestContext) public s_requestContext;

    // Events
    /**
     * @notice Emitted when a module is set
     * @param moduleType The type of the module
     * @param moduleAddress The address of the module
     */
    event ModuleSet(bytes32 indexed moduleType, address indexed moduleAddress);
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
            !IERC1363(i_linkAddress).transferAndCall(
                s_router,
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
        i_ospexCore = OspexCore(_ospexCore);
        s_router = router;
        i_linkAddress = linkAddress;
        s_donId = donId;
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
            s_donId,
            OracleRequestType.ContestCreate,
            contestId,
            0 // No speculationId for contest creation
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
            s_donId,
            OracleRequestType.ContestScore,
            contestId,
            0 // No speculationId for contest scoring
        );
    }



    function createSpeculationAndLeaderboardSpeculationFromOracle(
        uint256 contestId,
        uint32 startTimestamp,
        address scorer,
        int32 theNumber,
        uint256 leaderboardId,
        string calldata speculationSourceJS,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) returns (uint256) {
        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(contestId);

        // Contest must be verified
        if (contest.contestStatus != ContestStatus.Verified) {
            revert OracleModule__ContestNotVerified();
        }

        uint256 speculationId = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        ).createSpeculation(
            contestId,
            startTimestamp,
            scorer,
            theNumber,
            leaderboardId
        );

        // Prepare args array
        string[] memory args = new string[](3);
        args[0] = contest.rundownId;
        args[1] = contest.sportspageId;
        args[2] = contest.jsonoddsId;

        // Send oracle request
        sendRequest(
            speculationSourceJS,
            encryptedSecretsUrls,
            args,
            subscriptionId,
            gasLimit,
            s_donId,
            OracleRequestType.LeaderboardSpeculationCreate,
            contestId,
            speculationId
        );

        return speculationId;
    }

    function updateLeaderboardSpeculationFromOracle(
        uint256 speculationId,
        string calldata speculationSourceJS,
        bytes calldata encryptedSecretsUrls,
        uint64 subscriptionId,
        uint32 gasLimit
    ) external nonReentrant handleLinkPayment(subscriptionId) {
        ISpeculationModule speculationModule = ISpeculationModule(
            _getModule(keccak256("SPECULATION_MODULE"))
        );
        Speculation memory speculation = speculationModule.getSpeculation(
            speculationId
        );

        if (speculation.contestId == 0) {
            revert OracleModule__SpeculationDoesNotExist(speculationId);
        }

        Contest memory contest = IContestModule(
            _getModule(keccak256("CONTEST_MODULE"))
        ).getContest(speculation.contestId);

        // Contest must be verified
        if (contest.contestStatus != ContestStatus.Verified) {
            revert OracleModule__ContestNotVerified();
        }

        // Must be before the speculation start time
        if (block.timestamp >= speculation.startTimestamp) {
            revert OracleModule__SpeculationStarted(speculationId);
        }

        // Prepare args array
        string[] memory args = new string[](3);
        args[0] = contest.rundownId;
        args[1] = contest.sportspageId;
        args[2] = contest.jsonoddsId;

        // Send oracle request
        sendRequest(
            speculationSourceJS,
            encryptedSecretsUrls,
            args,
            subscriptionId,
            gasLimit,
            s_donId,
            OracleRequestType.LeaderboardSpeculationUpdate,
            speculation.contestId,
            speculationId
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
     * @param speculationId The ID of the speculation
     * @return requestId The ID of the request
     */
    function sendRequest(
        string memory source,
        bytes memory secrets,
        string[] memory args,
        uint64 subscriptionId,
        uint32 gasLimit,
        bytes32 donId,
        OracleRequestType requestType,
        uint256 contestId,
        uint256 speculationId
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
            contestId: contestId,
            speculationId: speculationId
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
        } else if (ctx.requestType == OracleRequestType.ContestScore) {
            _handleContestScore(ctx.contestId, response);
        } else if (
            ctx.requestType == OracleRequestType.LeaderboardSpeculationCreate
        ) {
            _handleLeaderboardSpeculationCreate(
                ctx.contestId,
                ctx.speculationId,
                response
            );
        } else if (
            ctx.requestType == OracleRequestType.LeaderboardSpeculationUpdate
        ) {
            _handleLeaderboardSpeculationUpdate(
                ctx.speculationId,
                response
            );
        } else {
            revert OracleModule__InvalidRequestType(ctx.requestType);
        }
    }

    function _handleContestCreate(
        uint256 contestId,
        bytes memory response
    ) internal {
        // 1. Extract contest data, leagueId, and start time from response
        uint256 contestData = bytesToUint256(response);
        (LeagueId leagueId, uint32 startTime) = extractLeagueIdAndStartTime(
            contestData
        );
        // 3. Store leagueId and start time
        IContestModule(_getModule(keccak256("CONTEST_MODULE")))
            .setContestLeagueIdAndStartTime(contestId, leagueId, startTime);
    }

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

    function _handleLeaderboardSpeculationCreate(
        uint256 contestId,
        uint256 speculationId,
        bytes memory response
    ) internal {
        // 1. Decode the response
        uint256 packedData = bytesToUint256(response);

        // 2. theNumber and odds
        (
            int32 theNumber,
            uint64 upperOdds,
            uint64 lowerOdds
        ) = extractLeaderboardSpeculationData(packedData);

        // 3. Create LeaderboardSpeculation
        ILeaderboardModule(
            _getModule(keccak256("LEADERBOARD_MODULE"))
        )
            .createLeaderboardSpeculation(
                contestId,
                speculationId,
                upperOdds,
                lowerOdds,
                theNumber
            );
    }

    function _handleLeaderboardSpeculationUpdate(
        uint256 speculationId,
        bytes memory response
    ) internal {
        // 1. Decode the response
        uint256 packedData = bytesToUint256(response);

        // 2. theNumber and odds
        (
            int32 theNumber,
            uint64 upperOdds,
            uint64 lowerOdds
        ) = extractLeaderboardSpeculationData(packedData);

        // 3. Update the LeaderboardSpeculation
        ILeaderboardModule(_getModule(keccak256("LEADERBOARD_MODULE")))
            .updateLeaderboardSpeculation(
                speculationId,
                upperOdds,
                lowerOdds,
                theNumber
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
     *      This packing is used to efficiently transmit multiple values in a single uint256 from the oracle.
     * @param _uint The packed uint256 response containing league, teams, and time data.
     * @return leagueId The league ID (as an enum).
     * @return startTime Unix timestamp of contest start.
     */
    function extractLeagueIdAndStartTime(
        uint256 _uint
    ) internal pure returns (LeagueId leagueId, uint32 startTime) {
        leagueId = LeagueId(uint8(_uint / 1e18));
        // Get last 10 digits (event time)
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
     * @notice Extracts theNumber, upperOdds, and lowerOdds from a packed uint256.
     * @dev The packed uint256 is formatted as:
     *      [theNumber (4 digits)][upperOdds (5 digits)][lowerOdds (5 digits)]
     *      - theNumber: (_uint / 1e10) % 1e4, then offset by -1000 to allow negative values.
     *      - upperOdds: (_uint / 1e5) % 1e5, then converted from American odds to scaled decimal odds.
     *      - lowerOdds: _uint % 1e5, then converted from American odds to scaled decimal odds.
     *      This packing is used to efficiently transmit multiple values in a single uint256 from the oracle.
     * @param _uint The packed uint256 containing leaderboard speculation data.
     * @return theNumber The market number (spread/total), offset to allow negatives.
     * @return upperOdds The upper odds, scaled.
     * @return lowerOdds The lower odds, scaled.
     */
    function extractLeaderboardSpeculationData(
        uint256 _uint
    )
        internal
        view
        returns (int32 theNumber, uint64 upperOdds, uint64 lowerOdds)
    {
        theNumber = int32(int256((_uint / 1e10) % 1e4)) - 1000; // 4 digits, offset back to +1000 (TODO: check this)
        upperOdds = americanToScaledDecimalOdds((_uint / 1e5) % 1e5); // next 5 digits
        lowerOdds = americanToScaledDecimalOdds(_uint % 1e5); // rightmost 5 digits
        return (theNumber, upperOdds, lowerOdds);
    }

    /**
     * @notice Converts American odds to a scaled decimal odds value.
     * @dev Uses ODDS_PRECISION (likely 1e7) as the scaling factor, matching the protocol's odds precision.
     *      - For positive American odds: decimalOdds = 1 + (americanOdds / 100)
     *      - For negative American odds: decimalOdds = 1 + (100 / abs(americanOdds))
     *      The +10000 offset is removed to allow for negative values.
     * @param americanOdds American odds format (e.g., +150, -110), offset by +10000 in the packed data.
     * @return uint64 Scaled decimal odds (e.g., 1.50 = 1.5e7).
     */
    function americanToScaledDecimalOdds(
        uint256 americanOdds
    ) internal view returns (uint64) {
        // --- Fetch the odds precision ---
        uint64 oddsPrecision = uint64(
            IPositionModule(_getModule(keccak256("POSITION_MODULE")))
                .ODDS_PRECISION()
        );

        // Remove the +10000 offset to get the actual American odds (which can be negative)
        int256 americanOddsReversedOffset = int256(americanOdds) - 10000;
        if (americanOddsReversedOffset > 0) {
            return
                uint64(
                    (oddsPrecision) +
                        (uint64(uint256(americanOddsReversedOffset)) *
                            oddsPrecision) /
                        100
                );
        } else {
            return
                uint64(
                    (oddsPrecision) +
                        (oddsPrecision * 100) /
                        uint64(uint256(-americanOddsReversedOffset))
                );
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
