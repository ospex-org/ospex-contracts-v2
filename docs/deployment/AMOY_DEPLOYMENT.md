# Amoy Deployment — 2026-04-19 (Zero-Admin)

## Network

| Field | Value |
|-------|-------|
| Network | Polygon Amoy Testnet |
| Chain ID | 80002 |
| RPC | `https://polygon-amoy.g.alchemy.com/v2/...` |
| Block | 36943420 |
| Deployer | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` |
| Total Gas | 19,959,545 |
| Total Cost | 0.5988 POL |

## Contract Addresses

| Contract | Address |
|----------|---------|
| **OspexCore** | `0x44fEDE66279D0609d43061Ac40D43704dDb392D7` |
| ContestModule | `0x0b4B56fD4cb7848f804204B052A3e72d90213B52` |
| SpeculationModule | `0x6f32665DD97482e6C89D8B9bf025d483184F5553` |
| PositionModule | `0xf769BEC6960Ed367320549FdD5A30f7C687DB2ee` |
| MatchingModule | `0x15a3Cac2fBb1e0Ed376a26e4F15385162cC9d8b9` |
| OracleModule | `0x08d1F10572071271983CE800ad63663f71A71512` |
| TreasuryModule | `0xC30C74edeEB3cbF2460D8a4a6BaddEBEe9D3ab1e` |
| LeaderboardModule | `0xbcCe7e2E61bC614d6e58C3327e893d177545Ef37` |
| RulesModule | `0x657804cEcBC4c16c0eC4A8Bc384dd515EA2D462C` |
| SecondaryMarketModule | `0x0e7b7C218db7f0e34521833e98f0Af261D204aED` |
| MoneylineScorerModule | `0x4CDf8cc2b0DcAe9bFFF34846E2bCB3A88675EdEC` |
| SpreadScorerModule | `0x36F3f4A6757cB2E822A1AfCea0b3092fFcaE6c30` |
| TotalScorerModule | `0xB814f3779A79c6470a904f8A12670D1B13874fDE` |

**Token:** Mock USDC `0xB1D1c0A8Cc8BB165b34735972E798f64A785eaF8` (6 decimals)

## Constructor Parameters

| Parameter | Value |
|-----------|-------|
| Protocol Receiver | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` (deployer) |
| Void Cooldown | 1 day (86400s) |
| Contest Creation Fee | 1.00 USDC (1000000) |
| Speculation Creation Fee | 0.50 USDC (500000) — split between maker/taker |
| Leaderboard Creation Fee | 0.50 USDC (500000) |
| LINK Denominator | 250 (0.004 LINK per oracle call) |
| DON ID | `fun-polygon-amoy-1` |
| Approved Signer | `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3` (deployer EOA) |

## Chainlink Functions

| Field | Value |
|-------|-------|
| Subscription ID | 416 |
| LINK Token | `0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904` |
| Functions Router | `0xC22a79eBA640940ABB6dF0f7982cc119578E11De` |
| OracleModule consumer | Added to subscription 416 |

## Script Approvals (EIP-712)

All signed by `0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3`. All approvals expire 2026-07-19 (90 days).

### Verify (contestCreation.js) — Purpose 0

| Field | Value |
|-------|-------|
| scriptHash | `0x01c48e15068b68b7d5986d5013edd83a243ac31a761567e9db0e57b513c26c01` |
| purpose | 0 (VERIFY) |
| leagueId | 0 (Unknown — all leagues) |
| version | 1 |
| validUntil | 1784435872 (2026-07-19T04:37:52Z) |
| signature | `0x1c5c2a40b19a56ed5c7ed0b5f3cd999232018de58b657ef168db9bf4badf820f7dc21fc4feba4c08ec8a4a0f4b8ccdd4685057ca12af049cc9d48084556c846b1c` |

### Market Update (contestMarketsUpdate.js) — Purpose 1

| Field | Value |
|-------|-------|
| scriptHash | `0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4` |
| purpose | 1 (MARKET_UPDATE) |
| leagueId | 0 (Unknown — all leagues) |
| version | 1 |
| validUntil | 1784436310 (2026-07-19T04:45:10Z) |
| signature | `0x12f15b125eae373d76fb154ef6e42b60a8c93c4c99dc82c0c22d566b9ff7376041e3e096018ffbd3f6095d8c3cd0deab4d71b109ae29e29dceb1532371cef86d1c` |

### Score (contestScoring.js) — Purpose 2

| Field | Value |
|-------|-------|
| scriptHash | `0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd` |
| purpose | 2 (SCORE) |
| leagueId | 0 (Unknown — all leagues) |
| version | 1 |
| validUntil | 1784437583 (2026-07-19T05:06:23Z) |
| signature | `0x860e0611a506988a66a686558f2bf3818decbfd8f22c507d122473ef9699ae175477ee99c648cdda7dff7c37b3483f606f1f0458b90436471bb314943a5e43041b` |

## Transaction Hashes

| Transaction | Hash |
|-------------|------|
| OspexCore deploy | `0x9cc5ec12f5f40c49d5b3f037e59412a494131f1ca62812eed70a1ee0e4f24ada` |
| ContestModule deploy | `0xfdcb0c7635e509756b3b13fc0d54f4fc7a010ccb59a9ae799f9a82fd94f1e136` |
| SpeculationModule deploy | `0x52639cb1baf5d56043799e4e3e728ef41abc65bc111008b41591b0ab8490c40d` |
| PositionModule deploy | `0x7c94b08349d3b1f7cfa0c4668f12c50198a20c105998918130270e02dd01ca4c` |
| MatchingModule deploy | `0xde7d0828b43833cad62771bff52c2980b26079bd967a55dcb755906569ec3c5d` |
| OracleModule deploy | `0x279c6a3f895790f8f1536414426cb95a6dc935a61b24779c4e505f76d78f6c5d` |
| TreasuryModule deploy | `0xd6e76ab1ff51a7e7e098e624188f24ab87a7c890a1bb7d51d66188914d444011` |
| LeaderboardModule deploy | `0xcab783152a8b21b70e414d6731e45bbe25bb6284e34e8ac10f659799a59f26dd` |
| RulesModule deploy | `0xe44c9905d3a9cea8c4afcce0bd7904a0eca8576b6aaab4d58a9fd9b6a416bcce` |
| SecondaryMarketModule deploy | `0x0f6cda7d0c5a82ee5cf7648fdbaba7ec22989f9a3495ff0c237900d49c135b32` |
| MoneylineScorerModule deploy | `0x0f1fd5d6d9cb36fbd43bc7a1d3461a7cb5376adde2ec2bcd41d52256de7ff8c1` |
| SpreadScorerModule deploy | `0x53d0bf05472913baf9af220954a0969fd83c97f00bec70de4060ef5e3c00bfb3` |
| TotalScorerModule deploy | `0x8ccae7aa7a8ac40cf4051c48860c55719312384c562f8859f5c64a6bad5d3d9e` |
| bootstrapModules | `0xf358a833a33203cef4df76a718f0e7c50ff11931303cc8fabaf111af243e83a4` |
| finalize | `0x0f6cda7d0c5a82ee5cf7648fdbaba7ec22989f9a3495ff0c237900d49c135b32` |

## Post-Deploy Checklist

- [x] All 12 modules deployed
- [x] `bootstrapModules()` — ModulesBootstrapped(12) emitted
- [x] `finalize()` — Finalized() emitted, `s_finalized` = true
- [x] All `isApprovedScorer()` checks pass
- [x] `isSecondaryMarket()` check passes
- [x] `isRegisteredModule()` checks pass for PositionModule and MatchingModule
- [x] OracleModule added as consumer on Chainlink subscription 416
- [x] Secrets encrypted and configured in ospex-api-server
- [x] Script approvals signed (3/3)
- [ ] Update ospex-fdb with new contract addresses
- [ ] Update ospex-agent-server with new contract addresses
- [ ] Update ospex-lovable with new contract addresses and ABI
- [ ] End-to-end smoke test: contest creation → scoring
