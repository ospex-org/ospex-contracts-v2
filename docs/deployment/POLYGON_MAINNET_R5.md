# Ospex Round 5 — Polygon Mainnet

**Deploy date:** 2026-06-28
**Round:** R5 (CRE oracle migration — the Chainlink Functions `OracleModule` is replaced by `CreOracleReceiver` in the `CRE_ORACLE_RECEIVER` slot)
**Deploy script:** `script/DeployPolygonCre.s.sol:DeployPolygonCre`
**Repo commit (from broadcast):** `d2be2cb`
**Network:** Polygon Mainnet (chain id 137)
**Deployer:** `0x53AF7B1BB308abD6F106231B75a241fB3e9eeA5C` (one-time deployer EOA)
**Deploy block (first tx):** **89322650**
**First TX hash:** `0x6021d5de6d0db72088966ecf25ba857b98d3f195418222fcae546f4242daff1e` (OspexCore CREATE)
**Compiler:** Solidity 0.8.26 (`--via-ir --optimize`)
**Polygonscan verification:** all 13 contracts verified

## Deployed addresses

| Contract | Address |
|----------|---------|
| OspexCore | [`0x40047BAFcdEd16C938058b7b67186299a2893561`](https://polygonscan.com/address/0x40047BAFcdEd16C938058b7b67186299a2893561) |
| ContestModule | [`0x0f838AF735E95625905c6acFB887a2E9f4DB9216`](https://polygonscan.com/address/0x0f838AF735E95625905c6acFB887a2E9f4DB9216) |
| SpeculationModule | [`0xEA21b58E91eDcA41d0c42A8655234F8A64fa31bc`](https://polygonscan.com/address/0xEA21b58E91eDcA41d0c42A8655234F8A64fa31bc) |
| PositionModule | [`0x3C71fdB8ABF41487a512440e5ce6490158C26e56`](https://polygonscan.com/address/0x3C71fdB8ABF41487a512440e5ce6490158C26e56) |
| MatchingModule | [`0x46Af20B6307Aa0Ec13de10EF58a02c5F1b5C9559`](https://polygonscan.com/address/0x46Af20B6307Aa0Ec13de10EF58a02c5F1b5C9559) |
| CreOracleReceiver (`CRE_ORACLE_RECEIVER`) | [`0x06e3470012039797119Ae30e1236169304F9220C`](https://polygonscan.com/address/0x06e3470012039797119Ae30e1236169304F9220C) |
| TreasuryModule | [`0x07f357e67cc9B48D029b1E4C9B7F45569a2eB85C`](https://polygonscan.com/address/0x07f357e67cc9B48D029b1E4C9B7F45569a2eB85C) |
| LeaderboardModule | [`0x02228F4bAB35d9631296C47C2103789474aD72ee`](https://polygonscan.com/address/0x02228F4bAB35d9631296C47C2103789474aD72ee) |
| RulesModule | [`0x5a5662C8246Ed3dC2422Cc8f773564fA41b34723`](https://polygonscan.com/address/0x5a5662C8246Ed3dC2422Cc8f773564fA41b34723) |
| SecondaryMarketModule | [`0xf779d82E9a11234767921A73913dAd429F140aFB`](https://polygonscan.com/address/0xf779d82E9a11234767921A73913dAd429F140aFB) |
| MoneylineScorerModule | [`0x59555106D4B5f1A797f3552f60ac418Eb6B6f6BD`](https://polygonscan.com/address/0x59555106D4B5f1A797f3552f60ac418Eb6B6f6BD) |
| SpreadScorerModule | [`0x8f293da716164d5A32dc087A85e5164D929ae9D4`](https://polygonscan.com/address/0x8f293da716164d5A32dc087A85e5164D929ae9D4) |
| TotalScorerModule | [`0xB4B1E2A2a75C34e9E4C5D3BB8A432aff973DaDa0`](https://polygonscan.com/address/0xB4B1E2A2a75C34e9E4C5D3BB8A432aff973DaDa0) |
| USDC (native) | [`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359) |

Addresses cross-checked three ways: the broadcast artifact `contractAddress` values, this repo's `docs/DEPLOYMENT.md` table, and the `.ospex-r5-deploy` run log all agree; OspexCore, MatchingModule, and PositionModule are additionally verified-by-name on Polygonscan.

## CRE oracle & governance (Ethereum mainnet, chain id 1)

R5 replaces Chainlink Functions with a Chainlink CRE workflow reporting into `CreOracleReceiver`. The receiver's workflow owner / governance is the `OspexCreTimelock` on **Ethereum mainnet** (where the CRE WorkflowRegistry 2.0.0 lives) — a per-action timelock with a 7-day delay (1-second fast lane for the `allowlistRequest` key-rotation op), self-administered, deployer renounced. CRE execution is funded off-chain; there is no on-chain LINK subscription.

| Contract | Chain | Address |
|----------|-------|---------|
| OspexCreTimelock (workflow owner / governance) | Ethereum mainnet | [`0x40047BAFcdEd16C938058b7b67186299a2893561`](https://etherscan.io/address/0x40047BAFcdEd16C938058b7b67186299a2893561) |

CRE workflow: `osverify` (workflow id `0097efdade80ff0a9557d927a1c07075a453bba9cd0fae7e22519c613ec47805`).

> **Same-address note:** the Ethereum-mainnet `OspexCreTimelock` shares the identical string `0x40047BAFcdEd16C938058b7b67186299a2893561` with the Polygon `OspexCore` above. Both were the first contract (nonce 0) deployed by the same one-time deployer, and a CREATE address depends only on `(deployer, nonce)`, not the chain — so the address collides across chains. They are distinct contracts on distinct chains.

## Notes

- Bootstrap + finalize pattern used (`bootstrapModules()` then `finalize()`). The registry is finalized — no admin key remains.
- The in-script `finalize()` transient-reverted during the broadcast and was re-sent standalone (via `cast send`), so the confirming `finalize()` tx and its block are **not** in this deploy's `run-latest.json` broadcast artifact. The registry is finalized on-chain.
- Protocol parameters (fee receiver, void cooldown, USDC), the CRE receiver env values, and the full per-network parameter set: see [`../DEPLOYMENT.md`](../DEPLOYMENT.md) and [`DEPLOYMENT_PARAMETERS.md`](DEPLOYMENT_PARAMETERS.md).

## Artifacts

- Broadcast log: [`../../broadcast/DeployPolygonCre.s.sol/137/run-latest.json`](../../broadcast/DeployPolygonCre.s.sol/137/run-latest.json) — every CREATE tx with constructor args, gas, and block confirmations.
