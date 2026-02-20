# Deployment

## Mainnet Contract Addresses (Polygon, Chain ID 137)

| Contract | Address |
|----------|---------|
| OspexCore | [`0x8016b2C5f161e84940E25Bb99479aAca19D982aD`](https://polygonscan.com/address/0x8016b2C5f161e84940E25Bb99479aAca19D982aD) |
| PositionModule | [`0xF717aa8fe4BEDcA345B027D065DA0E1a31465B1A`](https://polygonscan.com/address/0xF717aa8fe4BEDcA345B027D065DA0E1a31465B1A) |
| SpeculationModule | [`0x599FFd7A5A00525DD54BD247f136f99aF6108513`](https://polygonscan.com/address/0x599FFd7A5A00525DD54BD247f136f99aF6108513) |
| ContestModule | [`0x9E56311029F8CC5e2708C4951011697b9Bb40A09`](https://polygonscan.com/address/0x9E56311029F8CC5e2708C4951011697b9Bb40A09) |
| OracleModule | [`0x5105b835365dB92e493B430635e374E16f3C8249`](https://polygonscan.com/address/0x5105b835365dB92e493B430635e374E16f3C8249) |
| LeaderboardModule | [`0xEA6FF671Bc70e1926af9915aEF9D38AD2548066b`](https://polygonscan.com/address/0xEA6FF671Bc70e1926af9915aEF9D38AD2548066b) |
| RulesModule | [`0xEfDf69ef9f3657d6571bb9c979D2Ce3D7Afb6891`](https://polygonscan.com/address/0xEfDf69ef9f3657d6571bb9c979D2Ce3D7Afb6891) |
| TreasuryModule | [`0x48Fe67B7b866Ce87eA4B6f45BF7Bcc3cf868ccD0`](https://polygonscan.com/address/0x48Fe67B7b866Ce87eA4B6f45BF7Bcc3cf868ccD0) |
| SecondaryMarketModule | [`0x85E25F3BC29fAD936824ED44624f1A6200F3816E`](https://polygonscan.com/address/0x85E25F3BC29fAD936824ED44624f1A6200F3816E) |
| ContributionModule | [`0x384e356422E530c1AAF934CA48c178B19CA5C4F8`](https://polygonscan.com/address/0x384e356422E530c1AAF934CA48c178B19CA5C4F8) |
| MoneylineScorerModule | [`0x82c93AAf547fC809646A7bEd5D8A9D4B72Db3045`](https://polygonscan.com/address/0x82c93AAf547fC809646A7bEd5D8A9D4B72Db3045) |
| SpreadScorerModule | [`0x4377A09760b3587dAf1717F094bf7bd455daD4af`](https://polygonscan.com/address/0x4377A09760b3587dAf1717F094bf7bd455daD4af) |
| TotalScorerModule | [`0xD7b35DE1bbFD03625a17F38472d3FBa7b77cBeCf`](https://polygonscan.com/address/0xD7b35DE1bbFD03625a17F38472d3FBa7b77cBeCf) |

**Token:** Native USDC ([`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`](https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)), 6 decimals

---

## Network Configuration

| Parameter | Mainnet (Polygon) | Testnet (Amoy) |
|-----------|-------------------|----------------|
| Chain ID | 137 | 80002 |
| Chainlink Router | `0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10` | `0xA9d587a00A31A52Ed70D6026794a8FC5E2F5dCb0` |
| Chainlink DON ID | `fun-polygon-mainnet-1` | `fun-polygon-amoy-1` |
| Chainlink Subscription | [191](https://functions.chain.link/polygon/191) | [416](https://functions.chain.link/polygon-amoy/416) |
| Token | Native USDC (6 decimals) | Mock USDC (6 decimals) |

---

## Local Deployment

### Prerequisites

1. [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
2. Submodules initialized:
   ```bash
   git submodule update --init --recursive
   ```

### Start Anvil

```bash
anvil
```

### Deploy

```bash
forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --interactive \
  -vvvv
```

The script deploys mock tokens (ERC20, LINK, Chainlink Functions router), OspexCore, all modules, and registers everything automatically.

---

## Testnet Deployment (Polygon Amoy)

```bash
forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url https://rpc-amoy.polygon.technology \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  -vvvv
```

Requirements:
- POL for gas ([Polygon Faucet](https://faucet.polygon.technology/))
- LINK for Chainlink subscription

---

## Mainnet Deployment (Polygon)

```bash
forge script script/DeployPolygon.s.sol:DeployPolygon \
  --rpc-url https://polygon-rpc.com \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --interactive \
  -vvvv
```

### Pre-Deployment Checklist

- [ ] Deployer wallet funded with POL
- [ ] Chainlink subscription created and funded with LINK
- [ ] Fee receiver address configured
- [ ] All module addresses documented after deployment

### Post-Deployment

1. Save all deployed contract addresses
2. Modules are auto-registered with OspexCore by the deploy script
3. Configure Chainlink subscription with OracleModule address as consumer
4. Set contest creation and scoring source hashes on ContestModule

---

## Deployment Order

The deploy scripts create contracts in this order:

1. **OspexCore** — central registry
2. **ContributionModule**
3. **LeaderboardModule**
4. **RulesModule**
5. **MoneylineScorerModule**, **SpreadScorerModule**, **TotalScorerModule**
6. **TreasuryModule**
7. **SpeculationModule**
8. **PositionModule**
9. **SecondaryMarketModule**
10. **ContestModule**
11. **OracleModule**

All modules are registered with OspexCore during deployment. See [ADMIN_PRIVILEGES.md](ADMIN_PRIVILEGES.md) for the full trust model and role assignments.
