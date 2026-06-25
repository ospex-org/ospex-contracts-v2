// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IReceiver} from "../interfaces/cre/IReceiver.sol";
import {IERC165} from "../interfaces/cre/IERC165.sol";
import {LeagueId, OracleRequestType, Contest, ContestStatus} from "../core/OspexTypes.sol";
import {OspexCore} from "../core/OspexCore.sol";
import {IContestModule} from "../interfaces/IContestModule.sol";

/**
 * @title CreOracleReceiver
 * @author ospex.org
 * @notice Chainlink CRE oracle for the Ospex protocol. Replaces the Chainlink Functions
 *         OracleModule in the ORACLE_MODULE registry slot. It has two responsibilities:
 *           1. REQUEST — permissionless entrypoints that emit a {CreOracleRequested} event a CRE
 *              workflow watches via an EVM log trigger: verify (creates the contest), market-update
 *              and score (for an existing Verified contest). The requests are permissionless and charge
 *              no fee — the CRE workflow run is funded off-chain by the workflow owner, not paid
 *              per-call. Griefing is bounded off-chain: the CRE platform's per-workflow log-trigger
 *              rate limit caps the billed run rate, and the workflow owner controls the funded balance.
 *           2. RECEIVE — {onReport} is the KeystoneForwarder callback that carries the DON's
 *              signed report; it enforces the trust model, guards against replay/staleness, and
 *              applies the verified result to the protocol.
 *
 * @dev Trust model (NON-NEGOTIABLE — this design redeploys to immutable mainnet):
 *        (a) msg.sender MUST be the immutable KeystoneForwarder;
 *        (b) the report's workflow OWNER (and, when configured, NAME) parsed from the metadata MUST
 *            match our deployed workflow. The workflow OWNER is the {CreWorkflowOwner} governance
 *            adapter on a governed mainnet deploy (an EOA only on a trial deploy) — an address
 *            comparison either way. The workflow ID is deliberately NOT pinned: CRE rotates the id
 *            on every workflow update, so pinning it would brick a timelocked update;
 *        (c) the report's chainId + receiver MUST match this chain/contract (domain separation — the
 *            KeystoneForwarder already routes per chain/receiver, so this is defense-in-depth);
 *        (d) a given report applies at most once (per-report idempotency), AND every state-changing
 *            report MUST correspond to a receiver-emitted request (fail-closed request/report binding):
 *            verify/score require the contest's per-type request flag (set when the request was emitted),
 *            and a market report must carry a nonce that was actually requested (0 < nonce <=
 *            s_marketNonce) and not yet superseded (nonce > s_lastAppliedMarketNonce) — so stale odds
 *            can't overwrite fresh ones AND permissionless request spam can't invalidate an in-flight
 *            legitimate report.
 *
 *      Zero-admin / immutable, matching the Ospex trust model: forwarder, workflow owner and workflow
 *      name are immutable and set at construction. There is deliberately NO Ownable and NO setter —
 *      that would violate the protocol's finalized zero-admin guarantee. Sibling modules are resolved
 *      live from OspexCore.
 *
 *      Report envelope: `abi.encode(uint8 requestType, uint256 chainId, address receiver,
 *      uint64 requestNonce, bytes payload)`; {onReport} validates (a)–(d) then dispatches on
 *      requestType to decode the type-specific `payload`.
 */
contract CreOracleReceiver is IReceiver {
    // ──────────────────────────── Constants ────────────────────────────

    bytes32 public constant CONTEST_MODULE = keccak256("CONTEST_MODULE");

    /// @notice Minimum length of the KeystoneForwarder metadata: 32 (workflowId) + 10
    ///         (workflowName) + 20 (workflowOwner). Production delivers 64 (+ bytes2 reportId), which
    ///         passes the `>=` check; trailing bytes are intentionally ignored.
    uint256 internal constant METADATA_MIN_LENGTH = 62;

    // ──────────────────────────── Errors ───────────────────────────────

    error CreOracleReceiver__InvalidAddress();
    error CreOracleReceiver__InvalidSender(address sender, address expected);
    error CreOracleReceiver__InvalidWorkflowOwner(address received, address expected);
    error CreOracleReceiver__InvalidWorkflowName(bytes10 received, bytes10 expected);
    error CreOracleReceiver__ReportAlreadyProcessed(bytes32 reportKey);
    error CreOracleReceiver__InvalidRequestType(uint8 requestType);
    error CreOracleReceiver__InvalidMetadata(uint256 length);
    error CreOracleReceiver__ModuleNotSet(bytes32 moduleType);
    error CreOracleReceiver__ContestNotVerified(uint256 contestId);
    error CreOracleReceiver__WrongChainId(uint256 received, uint256 expected);
    error CreOracleReceiver__WrongReceiver(address received, address expected);
    error CreOracleReceiver__StaleMarketReport(uint256 contestId, uint64 received, uint64 lastApplied);
    error CreOracleReceiver__UnrequestedMarketReport(uint256 contestId, uint64 received, uint64 latestRequested);
    error CreOracleReceiver__VerifyNotRequested(uint256 contestId);
    error CreOracleReceiver__ScoreNotRequested(uint256 contestId);
    error CreOracleReceiver__PrematureScoreRequest(uint256 contestId, uint32 startTime, uint256 timestamp);

    // ──────────────────────────── Events ───────────────────────────────

    /// @notice Emitted on a permissionless oracle request. A CRE workflow watches this via an EVM
    ///         log trigger and responds with a signed report to {onReport}.
    /// @param contestId The contest id (newly created for verify; existing for market/score)
    /// @param requestType The oracle request type (0 = verify, 1 = market-update, 2 = score)
    /// @param requestNonce For market-update, the contest's market request nonce (the workflow echoes
    ///        it in the report; {onReport} requires it to be a real, not-yet-applied request). 0 for
    ///        verify/score, which are bound by per-contest request flags instead of a nonce.
    /// @param rundownId External id from the Rundown API
    /// @param sportspageId External id from the Sportspage API
    /// @param jsonoddsId External id from the JSONOdds API
    event CreOracleRequested(
        uint256 indexed contestId,
        uint8 indexed requestType,
        uint64 requestNonce,
        string rundownId,
        string sportspageId,
        string jsonoddsId
    );

    /// @notice Emitted when a DON report passes the trust model and is applied
    /// @param reportKey keccak256 of the report bytes (the idempotency key)
    /// @param requestType The oracle request type carried by the report
    /// @param contestId The contest the report resolved
    event CreReportProcessed(
        bytes32 indexed reportKey,
        uint8 requestType,
        uint256 indexed contestId
    );

    // ──────────────────────────── Immutables ───────────────────────────

    /// @notice The OspexCore contract (module registry + event hub)
    OspexCore public immutable i_ospexCore;
    /// @notice The trusted Chainlink KeystoneForwarder — the only valid {onReport} caller
    address public immutable i_forwarder;
    /// @notice The expected workflow owner. On a governed mainnet deploy this is the
    ///         {CreWorkflowOwner} adapter address (NOT the timelock, NOT an EOA); a trial deploy may
    ///         use an EOA. Always enforced — pure address comparison.
    address public immutable i_workflowOwner;
    /// @notice The expected workflow name (bytes10). Enforced when non-zero. The workflow ID is
    ///         deliberately not pinned (CRE rotates it on every update).
    bytes10 public immutable i_workflowName;

    // ──────────────────────────── State ────────────────────────────────

    /// @notice keccak256(report) → processed. Replay guard; reverts roll the flag back so a
    ///         first-delivery out-of-gas revert can be retried by the forwarder.
    mapping(bytes32 => bool) public s_processedReport;

    /// @notice contestId → latest market-update request nonce (the highest REQUESTED). Bumped on every
    ///         {requestMarketUpdate}. A market report is accepted only if its echoed nonce is a real
    ///         request (<= this) and not yet superseded by an applied report (> s_lastAppliedMarketNonce).
    mapping(uint256 => uint64) public s_marketNonce;

    /// @notice contestId → a verify request was emitted for it (set in {createContestAndRequestVerify}
    ///         when the contest is created). {_handleVerify} is fail-closed on this, so a verify report
    ///         for contest 0 / any uncreated, unrequested slot can never create a ghost Verified contest.
    mapping(uint256 => bool) public s_verifyRequested;

    /// @notice contestId → a score request was emitted for it (set in {requestScore}). {_handleScore}
    ///         is fail-closed on this, so an unrequested score report is rejected.
    mapping(uint256 => bool) public s_scoreRequested;

    /// @notice contestId → the highest market nonce already APPLIED by a report. A market report is
    ///         accepted only if its nonce is > this (and <= s_marketNonce). Comparing to the last
    ///         APPLIED nonce (not the latest REQUESTED) blocks stale overwrites while ensuring a cheap
    ///         permissionless {requestMarketUpdate} cannot invalidate an in-flight legitimate report.
    mapping(uint256 => uint64) public s_lastAppliedMarketNonce;

    // ──────────────────────────── Constructor ──────────────────────────

    /**
     * @param ospexCore_ The OspexCore contract address
     * @param forwarder_ The Chainlink KeystoneForwarder for the target chain
     * @param workflowOwner_ The CRE workflow owner address — the {CreWorkflowOwner} adapter on a
     *        governed mainnet deploy (an EOA only on a trial deploy)
     * @param workflowName_ The CRE workflow name as bytes10 (0 to not enforce)
     */
    constructor(
        address ospexCore_,
        address forwarder_,
        address workflowOwner_,
        bytes10 workflowName_
    ) {
        if (
            ospexCore_ == address(0) ||
            forwarder_ == address(0) ||
            workflowOwner_ == address(0)
        ) {
            revert CreOracleReceiver__InvalidAddress();
        }
        i_ospexCore = OspexCore(ospexCore_);
        i_forwarder = forwarder_;
        i_workflowOwner = workflowOwner_;
        i_workflowName = workflowName_;
    }

    // ──────────────────────────── Request (verify) ─────────────────────

    /**
     * @notice Permissionless. Creates a contest (Unverified) and emits a verify request that
     *         the CRE workflow resolves. The caller pays the USDC contest-creation fee (charged
     *         by ContestModule via OspexCore); the CRE workflow run itself is workflow-owner-funded.
     * @param rundownId External id from the Rundown API
     * @param sportspageId External id from the Sportspage API
     * @param jsonoddsId External id from the JSONOdds API
     * @return contestId The newly created contest id
     */
    function createContestAndRequestVerify(
        string calldata rundownId,
        string calldata sportspageId,
        string calldata jsonoddsId
    ) external returns (uint256 contestId) {
        contestId = IContestModule(_getModule(CONTEST_MODULE)).createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            bytes32(0), // verifySourceHash — no caller-supplied JS under CRE
            bytes32(0), // marketUpdateSourceHash
            bytes32(0), // scoreContestSourceHash
            LeagueId.Unknown, // resolved by the verify report
            msg.sender
        );
        // Bind the (future) verify report to this on-chain request; {_handleVerify} is fail-closed on it.
        s_verifyRequested[contestId] = true;
        // Verify is one-shot (ContestModule enforces Unverified->Verified), so nonce = 0.
        emit CreOracleRequested(
            contestId,
            uint8(OracleRequestType.ContestCreate),
            0,
            rundownId,
            sportspageId,
            jsonoddsId
        );
    }

    /**
     * @notice Permissionless. Emits a market-update request for an existing (Verified) contest. The
     *         CRE workflow fetches current odds and writes them back via {onReport}. No fee.
     * @dev Bumps the contest's market nonce. {onReport} then accepts a market report whose echoed nonce
     *      is a real request (<= the latest) and not yet superseded by an applied report (>
     *      s_lastAppliedMarketNonce) — so stale odds can't overwrite fresh ones, AND this permissionless
     *      bump can't invalidate an in-flight legitimate report. Reverts unless the contest is Verified
     *      (ContestModule re-checks on apply; this is a fast-fail).
     * @param contestId The contest to refresh markets for
     * @return requestNonce The new latest market nonce for the contest
     */
    function requestMarketUpdate(uint256 contestId) external returns (uint64 requestNonce) {
        Contest memory c = IContestModule(_getModule(CONTEST_MODULE)).getContest(
            contestId
        );
        if (c.contestStatus != ContestStatus.Verified) {
            revert CreOracleReceiver__ContestNotVerified(contestId);
        }
        requestNonce = ++s_marketNonce[contestId];
        emit CreOracleRequested(
            contestId,
            uint8(OracleRequestType.ContestMarketsUpdate),
            requestNonce,
            c.rundownId,
            c.sportspageId,
            c.jsonoddsId
        );
    }

    /**
     * @notice Permissionless. Emits a score request for an existing (Verified) contest whose game has
     *         started. The CRE workflow fetches the final scores and writes them back via {onReport}.
     *         No fee, no LINK.
     * @dev Reverts unless the contest is Verified AND its start time has passed — scoring a game that
     *      has not started is necessarily premature (the workflow would fail anyway, but we avoid
     *      emitting known-premature, workflow-owner-funded requests). Score is one-shot at the
     *      ContestModule, so it carries no nonce.
     * @param contestId The contest to score
     */
    function requestScore(uint256 contestId) external {
        address contestModule = _getModule(CONTEST_MODULE);
        Contest memory c = IContestModule(contestModule).getContest(contestId);
        if (c.contestStatus != ContestStatus.Verified) {
            revert CreOracleReceiver__ContestNotVerified(contestId);
        }
        uint32 startTime = IContestModule(contestModule).s_contestStartTimes(contestId);
        if (block.timestamp < startTime) {
            revert CreOracleReceiver__PrematureScoreRequest(contestId, startTime, block.timestamp);
        }
        // Bind the (future) score report to this on-chain request; {_handleScore} is fail-closed on it.
        s_scoreRequested[contestId] = true;
        emit CreOracleRequested(
            contestId,
            uint8(OracleRequestType.ContestScore),
            0,
            c.rundownId,
            c.sportspageId,
            c.jsonoddsId
        );
    }

    // ──────────────────────────── Receive (onReport) ──────────────────

    /// @inheritdoc IReceiver
    function onReport(
        bytes calldata metadata,
        bytes calldata report
    ) external override {
        // (a) trusted forwarder
        if (msg.sender != i_forwarder) {
            revert CreOracleReceiver__InvalidSender(msg.sender, i_forwarder);
        }

        // (b) bind to our workflow (owner always; name when configured; id never pinned)
        (bytes10 workflowName, address workflowOwner) = _decodeMetadata(metadata);
        if (workflowOwner != i_workflowOwner) {
            revert CreOracleReceiver__InvalidWorkflowOwner(workflowOwner, i_workflowOwner);
        }
        if (i_workflowName != bytes10(0) && workflowName != i_workflowName) {
            revert CreOracleReceiver__InvalidWorkflowName(workflowName, i_workflowName);
        }

        // (c) idempotency — set BEFORE dispatch (checks-effects-interactions); a revert in the
        //     handler rolls this back so the forwarder can retry a first delivery.
        bytes32 reportKey = keccak256(report);
        if (s_processedReport[reportKey]) {
            revert CreOracleReceiver__ReportAlreadyProcessed(reportKey);
        }
        s_processedReport[reportKey] = true;

        // (d) decode the envelope + domain separation (chain + receiver). Defense-in-depth: the
        //     forwarder already routes per chain/receiver, but binding them in the signed report
        //     makes cross-chain / cross-contract replay impossible regardless of forwarder behavior.
        (
            uint8 requestType,
            uint256 chainId,
            address reportReceiver,
            uint64 requestNonce,
            bytes memory payload
        ) = abi.decode(report, (uint8, uint256, address, uint64, bytes));
        if (chainId != block.chainid) {
            revert CreOracleReceiver__WrongChainId(chainId, block.chainid);
        }
        if (reportReceiver != address(this)) {
            revert CreOracleReceiver__WrongReceiver(reportReceiver, address(this));
        }

        // (e) dispatch on requestType: Verify (ContestCreate) / MarketUpdate / Score.
        if (requestType == uint8(OracleRequestType.ContestCreate)) {
            uint256 contestId = _handleVerify(payload);
            emit CreReportProcessed(reportKey, requestType, contestId);
        } else if (requestType == uint8(OracleRequestType.ContestMarketsUpdate)) {
            uint256 contestId = _handleMarket(payload, requestNonce);
            emit CreReportProcessed(reportKey, requestType, contestId);
        } else if (requestType == uint8(OracleRequestType.ContestScore)) {
            uint256 contestId = _handleScore(payload);
            emit CreReportProcessed(reportKey, requestType, contestId);
        } else {
            revert CreOracleReceiver__InvalidRequestType(requestType);
        }
    }

    // ──────────────────────────── Handlers ────────────────────────────

    /**
     * @notice Applies a verify report: sets league + start time and flips the contest to
     *         Verified. ContestModule enforces the one-shot Unverified→Verified transition,
     *         a non-Unknown league and a non-zero start time, so a malformed or duplicate
     *         verify is rejected there as defense-in-depth.
     * @param payload abi.encode(uint256 contestId, uint8 leagueId, uint32 startTime, uint16 workflowVersion)
     * @return contestId The resolved contest id
     */
    function _handleVerify(
        bytes memory payload
    ) internal returns (uint256 contestId) {
        uint8 leagueId;
        uint32 startTime;
        // workflowVersion is decoded for forward-compatibility/observability but unused on-chain.
        (contestId, leagueId, startTime, ) = abi.decode(
            payload,
            (uint256, uint8, uint32, uint16)
        );
        // Fail-closed request/report binding: only a contest this receiver created (which set the flag
        // and emitted the verify request) can be verified — blocks a verify report for contest 0 / any
        // uncreated or unrequested slot, which would otherwise mint a ghost Verified contest.
        if (!s_verifyRequested[contestId]) {
            revert CreOracleReceiver__VerifyNotRequested(contestId);
        }
        IContestModule(_getModule(CONTEST_MODULE)).setContestLeagueIdAndStartTime(
            contestId,
            LeagueId(leagueId), // reverts if out of enum range
            startTime
        );
    }

    /**
     * @notice Applies a market-update report: writes the moneyline/spread/total odds + lines for the
     *         contest. Rejects an unrequested report (nonce 0 or above the latest requested) and a stale
     *         one (nonce already superseded by an applied report). ContestModule enforces Verified status,
     *         all six odds ticks non-zero and totalLineTicks >= 0, so malformed market data is rejected
     *         there as defense-in-depth.
     * @param payload abi.encode(uint256 contestId, uint16 moneylineAwayOdds, uint16 moneylineHomeOdds,
     *        int32 spreadLineTicks, uint16 spreadAwayOdds, uint16 spreadHomeOdds, int32 totalLineTicks,
     *        uint16 overOdds, uint16 underOdds, uint16 workflowVersion). Odds are decimal ticks
     *        (×100); spread/total are signed 10× ints.
     * @param requestNonce The market nonce echoed by the report; accepted when
     *        s_lastAppliedMarketNonce[contestId] < requestNonce <= s_marketNonce[contestId]
     *        (a real, not-yet-superseded request)
     * @return contestId The resolved contest id
     */
    function _handleMarket(
        bytes memory payload,
        uint64 requestNonce
    ) internal returns (uint256 contestId) {
        uint16 moneylineAwayOdds;
        uint16 moneylineHomeOdds;
        int32 spreadLineTicks;
        uint16 spreadAwayOdds;
        uint16 spreadHomeOdds;
        int32 totalLineTicks;
        uint16 overOdds;
        uint16 underOdds;
        // workflowVersion (trailing field) is decoded for observability but unused on-chain.
        (
            contestId,
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadLineTicks,
            spreadAwayOdds,
            spreadHomeOdds,
            totalLineTicks,
            overOdds,
            underOdds,

        ) = abi.decode(
            payload,
            (uint256, uint16, uint16, int32, uint16, uint16, int32, uint16, uint16, uint16)
        );
        // Request/report binding + freshness. Two guards:
        //   1. The nonce must be one this receiver actually emitted: 0 < nonce <= s_marketNonce.
        //      nonce 0 (or above the latest requested) means no matching request — fail closed.
        //   2. The nonce must not be superseded by an already-APPLIED report: nonce > lastApplied.
        //      Comparing to the last APPLIED nonce (not the latest REQUESTED) prevents stale overwrites
        //      WITHOUT letting a cheap, permissionless {requestMarketUpdate} bump invalidate an
        //      in-flight legitimate report.
        uint64 requested = s_marketNonce[contestId];
        if (requestNonce == 0 || requestNonce > requested) {
            revert CreOracleReceiver__UnrequestedMarketReport(contestId, requestNonce, requested);
        }
        uint64 applied = s_lastAppliedMarketNonce[contestId];
        if (requestNonce <= applied) {
            revert CreOracleReceiver__StaleMarketReport(contestId, requestNonce, applied);
        }
        // Effect before interaction (CEI): mark this nonce applied so a later report can't re-apply or
        // an out-of-order older one overwrite it. A revert in updateContestMarkets rolls this back.
        s_lastAppliedMarketNonce[contestId] = requestNonce;
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
     * @notice Applies a score report: sets the final away/home scores and flips Verified -> Scored.
     *         ContestModule enforces the contest is Verified (one-shot), so a malformed or duplicate
     *         score is rejected there as defense-in-depth.
     * @param payload abi.encode(uint256 contestId, uint32 awayScore, uint32 homeScore, uint16 workflowVersion)
     * @return contestId The resolved contest id
     */
    function _handleScore(
        bytes memory payload
    ) internal returns (uint256 contestId) {
        uint32 awayScore;
        uint32 homeScore;
        // workflowVersion (trailing field) is decoded for observability but unused on-chain.
        (contestId, awayScore, homeScore, ) = abi.decode(
            payload,
            (uint256, uint32, uint32, uint16)
        );
        // Fail-closed request/report binding: a score report applies only if a score request was emitted.
        if (!s_scoreRequested[contestId]) {
            revert CreOracleReceiver__ScoreNotRequested(contestId);
        }
        IContestModule(_getModule(CONTEST_MODULE)).setScores(
            contestId,
            awayScore,
            homeScore
        );
    }

    // ──────────────────────────── Metadata decode ─────────────────────

    /**
     * @notice Decodes the KeystoneForwarder metadata. Layout (abi.encodePacked):
     *         [bytes32 workflowId][bytes10 workflowName][address workflowOwner]( [bytes2 reportId] ).
     *         The workflowId (first 32 bytes) is intentionally NOT returned/validated — CRE rotates
     *         it on every workflow update.
     * @dev Uses calldata slicing at static offsets (clean, explicit; no dirty-bytes risk).
     */
    function _decodeMetadata(
        bytes calldata metadata
    ) internal pure returns (bytes10 workflowName, address workflowOwner) {
        if (metadata.length < METADATA_MIN_LENGTH) {
            revert CreOracleReceiver__InvalidMetadata(metadata.length);
        }
        workflowName = bytes10(metadata[32:42]);
        workflowOwner = address(bytes20(metadata[42:62]));
    }

    // ──────────────────────────── Module lookup ───────────────────────

    function _getModule(
        bytes32 moduleType
    ) internal view returns (address module) {
        module = i_ospexCore.getModule(moduleType);
        if (module == address(0)) {
            revert CreOracleReceiver__ModuleNotSet(moduleType);
        }
        return module;
    }

    // ──────────────────────────── ERC165 ──────────────────────────────

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == type(IReceiver).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
