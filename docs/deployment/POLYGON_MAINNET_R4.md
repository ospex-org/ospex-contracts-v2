# Ospex Round 4 — Polygon Mainnet

**Deploy date:** 2026-04-28
**Commit:** `a1bc189` (foundry main, post PR #11 merge)
**Network:** Polygon Mainnet (chain id 137)
**Deployer:** `0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886`
**Deploy block (first tx):** **86135682** (broadcast spans 30 blocks via `--slow`; finalize at block 86135712)
**First TX hash:** `0x091d6cd5c04582a94b1b879a1859f32198a4c94871a43dc8b51df5ca5c820e1e`
**Tests at deploy:** 563 passed, 0 failed (`forge test --via-ir --optimize`)
**Polygonscan verification:** All 13 contracts verified inline via `--verify`

## Deployed addresses

| Contract | Address |
|----------|---------|
| OspexCore | [`0xECD12Af197FBF4C9F706B5Eb11a19c40Cfd643db`](https://polygonscan.com/address/0xECD12Af197FBF4C9F706B5Eb11a19c40Cfd643db) |
| ContestModule | [`0x1Eb0048650380369C6F4239dE070114463626102`](https://polygonscan.com/address/0x1Eb0048650380369C6F4239dE070114463626102) |
| SpeculationModule | [`0xd757387893E779AC35451CeA639a408A537b9a1B`](https://polygonscan.com/address/0xd757387893E779AC35451CeA639a408A537b9a1B) |
| PositionModule | [`0x0DCd42f8609cd7884ddBa3481b03a78dfc88366c`](https://polygonscan.com/address/0x0DCd42f8609cd7884ddBa3481b03a78dfc88366c) |
| MatchingModule | [`0x1B93579B044f0eE3c4C8a9F479A323DeF7770712`](https://polygonscan.com/address/0x1B93579B044f0eE3c4C8a9F479A323DeF7770712) |
| OracleModule | [`0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb`](https://polygonscan.com/address/0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb) |
| TreasuryModule | [`0xCB56CD2c509301e888965DD3A2E5C486Fe03a56e`](https://polygonscan.com/address/0xCB56CD2c509301e888965DD3A2E5C486Fe03a56e) |
| LeaderboardModule | [`0x63f76D5796296FFB94132C6f70d3ff9c3c5a0DEF`](https://polygonscan.com/address/0x63f76D5796296FFB94132C6f70d3ff9c3c5a0DEF) |
| RulesModule | [`0x05aF3d55F44CfaFA59c3B152A1547b5219d90f93`](https://polygonscan.com/address/0x05aF3d55F44CfaFA59c3B152A1547b5219d90f93) |
| SecondaryMarketModule | [`0xaD2B4437296B46a1b107Bb2dB7AC4082182b6059`](https://polygonscan.com/address/0xaD2B4437296B46a1b107Bb2dB7AC4082182b6059) |
| MoneylineScorerModule | [`0xd846B7FdbD8C9F67d1580B2C6a8Bd7Fdcb15390b`](https://polygonscan.com/address/0xd846B7FdbD8C9F67d1580B2C6a8Bd7Fdcb15390b) |
| SpreadScorerModule | [`0x99c5fF5131F269cA178e2Ea78f2a2A222a3a7d5e`](https://polygonscan.com/address/0x99c5fF5131F269cA178e2Ea78f2a2A222a3a7d5e) |
| TotalScorerModule | [`0xC141679f09413EDe38E3Cd36a3e4aDE423827972`](https://polygonscan.com/address/0xC141679f09413EDe38E3Cd36a3e4aDE423827972) |
| USDC (native) | [`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359) |

## Chainlink Functions

| Field | Value |
|-------|-------|
| Subscription | [191](https://functions.chain.link/polygon/191) |
| Router | `0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10` |
| DON | `fun-polygon-mainnet-1` |
| LINK token | `0xb0897686c545045aFc77CF20eC7A532E3120E0F1` |
| OracleModule consumer | Pending — added post-deploy |

## Protocol parameters

- Void cooldown: 7 days (604800s)
- Contest creation fee: 1.00 USDC
- Speculation creation fee: 0.50 USDC (split between maker/taker)
- Leaderboard creation fee: 0.50 USDC
- LINK denominator: 200 (0.005 LINK per oracle call)
- Approved signer: `0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886` (deployer EOA)
- Protocol fee receiver: `0xdaC630aE52b868FF0A180458eFb9ac88e7425114`

Bootstrap+finalize pattern used. Protocol is finalized — no admin key remains.

## Artifacts

- [`POLYGON_MAINNET_R4_broadcast.json`](POLYGON_MAINNET_R4_broadcast.json) — Foundry broadcast log (every CREATE tx with constructor args, gas, and block confirmations)
- [`POLYGON_MAINNET_R4_output.txt`](POLYGON_MAINNET_R4_output.txt) — deploy console scrollback (script execution + Polygonscan verification submissions)
