# Deployment Parameters — Ospex v2.3 (Zero-Admin)

All values are immutable after `finalize()`. There is no upgrade path — a mistake means redeploying the entire protocol.

## Constructor Parameters

| Parameter | Anvil | Amoy | Mainnet | Description | Notes |
|-----------|-------|------|---------|-------------|-------|
| **Protocol Receiver** | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (Anvil #0) | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` (deployer) | `0xdaC630aE52b868FF0A180458eFb9ac88e7425114` | TreasuryModule `protocolReceiver_` — receives all protocol fees | Confirmed |
| **Void Cooldown** | `3 days` (259200) | `1 days` (86400) | `7 days` (604800) | SpeculationModule `voidCooldown` — time after which an unmatched speculation can be voided | Confirmed — differentiated per network for fast Amoy testing and conservative mainnet window |
| **Contest Creation Fee** | `1_000_000` | `1_000_000` | `1_000_000` | TreasuryModule `contestCreationFeeRate` — 1.00 USDC | Same across all networks |
| **Speculation Creation Fee** | `500_000` | `500_000` | `500_000` | TreasuryModule `speculationCreationFeeRate` — 0.50 USDC split between maker and taker | Same across all networks |
| **Leaderboard Creation Fee** | `500_000` | `500_000` | `500_000` | TreasuryModule `leaderboardCreationFeeRate` — 0.50 USDC | Updated from 0.25 USDC per Vince's confirmation |
| **LINK Denominator** | `10` | `250` | `200` | OracleModule `linkDenominator` — payment per oracle call = 1e18 / value. 10 = 0.1 LINK, 250 = 0.004 LINK, 200 = 0.005 LINK | Anvil uses mock LINK so value is irrelevant; Amoy = ~$0.06 per call (kept at R3 value, not redeploying); Mainnet = 200 (~$0.075 per call) — calibrated against R3 sub-191 history (median ~0.0036, avg ~0.006, high-gas spikes ~0.0085 LINK) |
| **DON ID** | `bytes32("test_don_id")` | `bytes32("fun-polygon-amoy-1")` | `bytes32("fun-polygon-mainnet-1")` | OracleModule `donId` — Chainlink Functions DON identifier | Anvil mock router ignores this |
| **Approved Signer** | `vm.addr(0xA11CE)` | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` | `0xfd6c7fc1f182de53aa636584f1c6b80d9d885886` | OracleModule `approvedSigner` — signs EIP-712 ScriptApproval structs for oracle JS sources | Amoy = deployer EOA; Mainnet = deployer EOA (same wallet as the deployer; EIP-712 signing via the EOA's private key) |

## External Contract Addresses

| Parameter | Anvil | Amoy | Mainnet | Description |
|-----------|-------|------|---------|-------------|
| **USDC** | Mock ERC20 (deployed by script) | `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | Token for TreasuryModule, PositionModule, SecondaryMarketModule |
| **LINK** | Mock LinkToken (deployed by script) | `0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904` | `0xb0897686c545045aFc77CF20eC7A532E3120E0F1` | OracleModule `linkAddress` |
| **Functions Router** | Mock FunctionsRouter (deployed by script) | `0xC22a79eBA640940ABB6dF0f7982cc119578E11De` | `0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10` | OracleModule `router` (also FunctionsClient base) |

## Hardcoded Constants (not configurable)

These are baked into the contracts and cannot be changed at deployment. Listed for reference.

| Constant | Value | Location | Description |
|----------|-------|----------|-------------|
| ODDS_SCALE | `100` | MatchingModule, RulesModule, OracleModule | 1.91 odds = 191 ticks. Minimum riskAmount granularity = 100 (0.0001 USDC) |
| MIN_ODDS | `101` | MatchingModule | Minimum valid odds tick (1.01x) |
| LINK_DIVISIBILITY | `10**18` | OracleModule | LINK base unit; linkDenominator must be <= this |
| EIP-712 Domain (Matching) | name="Ospex", version="1" | MatchingModule | Commitment signature domain. chainId and verifyingContract auto-set |
| EIP-712 Domain (Oracle) | name="OspexOracle", version="1" | OracleModule | Script approval signature domain. chainId and verifyingContract auto-set |

## Post-Finalize Setup (not constructor params)

These are runtime operations done after deployment, not baked into constructors.

| Step | Anvil | Amoy | Mainnet | Notes |
|------|-------|------|---------|-------|
| Add OracleModule as Chainlink consumer | N/A (mock) | Subscription 416 | Add new OracleModule to subscription 191 (existing R3 sub, reused) | Done via Chainlink Functions dashboard |
| Fund caller wallet with LINK | Mock mint in script | Faucet or transfer | Purchase and transfer | Caller = whoever calls createContest/scoreContest |
| Approve OracleModule for LINK spending | Done in script | Manual or script | Manual | `LINK.approve(oracleModule, amount)` from caller wallet |
| Upload encrypted secrets | N/A (mock) | Chainlink Functions dashboard | Chainlink Functions dashboard | API keys for ESPN/JSONOdds |
| Sign script approvals | `vm.sign(SIGNER_PK, ...)` | Sign with deployer EOA | Sign with deployer EOA | EIP-712 ScriptApproval for each JS source (verify, market update, score) |
| Update downstream services | N/A | ospex-fdb, agent-server, lovable | ospex-fdb, agent-server, lovable | New contract addresses in config |
