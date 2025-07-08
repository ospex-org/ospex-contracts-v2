# Ospex Protocol Deployment Guide

This guide explains how to deploy the Ospex protocol to a local Anvil chain for testing and development.

## Prerequisites

1. **Foundry installed** - Follow [Foundry installation guide](https://book.getfoundry.sh/getting-started/installation)
2. **Git and dependencies** - Ensure all submodules are initialized:
   ```bash
   git submodule update --init --recursive
   ```

## Local Deployment Setup

### 1. Start Local Anvil Chain

In a separate terminal, start Anvil:

```bash
anvil
```

This starts a local Ethereum node on `http://127.0.0.1:8545` with several pre-funded accounts.

### 2. Deploy Contracts (Interactive Method)

Run the deployment script with the interactive flag to use your wallet keystore:

```bash
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8545 --broadcast --interactive --gas-report -vvvv
```

**Flags explained:**
- `--rpc-url http://127.0.0.1:8545`: Connect to local Anvil chain
- `--broadcast`: Actually deploy the contracts (not just simulate)
- `--interactive`: Prompt for wallet credentials (keystore method)
- `--gas-report`: Show detailed gas usage report
- `-vvvv`: Very verbose output for debugging

### Alternative: Using Private Key (Less Secure)

If you prefer to use a private key instead:

1. Create a `.env` file:
   ```bash
   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
   ```

2. Modify the script to load the private key from environment

**Note:** Only use test private keys for local development!

### 3. Wallet Setup for Interactive Mode

When using `--interactive`, you'll be prompted for:
- **Keystore path**: Path to your wallet keystore file
- **Password**: Password for the keystore

For local testing, you can create a test keystore:

```bash
# Create a test keystore (use a simple password for testing)
cast wallet new-mnemonic --words 12
cast wallet import test-wallet --interactive
```

Then use the generated keystore with the deployment script.

## What Gets Deployed

The deployment script deploys the following contracts in order:

### Mock Contracts (for testing)
1. **MockERC20** - Test token (USDC-like with 6 decimals)
2. **MockLinkToken** - Mock LINK token for Chainlink Functions
3. **MockFunctionsRouter** - Mock Chainlink Functions router

### Core Protocol
4. **OspexCore** - Main registry and access control contract

### Modules
5. **ContributionModule** - Handles contribution logic
6. **LeaderboardModule** - Manages leaderboards and scoring
7. **RulesModule** - Enforces leaderboard rules
8. **MoneylineScorerModule** - Scores moneyline bets
9. **SpreadScorerModule** - Scores spread bets
10. **TotalScorerModule** - Scores over/under bets
11. **TreasuryModule** - Handles fees and prize pools
12. **SpeculationModule** - Manages speculation lifecycle
13. **PositionModule** - Handles user positions
14. **SecondaryMarketModule** - Enables position trading
15. **ContestModule** - Manages contests
16. **OracleModule** - Handles oracle interactions

All modules are automatically registered with the core contract.

## Deployment Configuration

The script uses these default configurations for local testing:

- **Token Decimals**: 6 (USDC-like)
- **Min Sale Amount**: 1 USDC
- **Max Sale Amount**: 100,000 USDC
- **Protocol Receiver**: Deployer address
- **Create Contest Source Hash**: Test hash
- **DON ID**: Test DON ID

## Expected Gas Usage

Total deployment gas usage is approximately:
- **~15-20 million gas** for all contracts
- At 1 gwei gas price: ~0.015-0.020 ETH
- At current gas prices (20 gwei): ~0.3-0.4 ETH

## Cost Estimates for Different Networks

Based on typical gas prices:

| Network | Gas Price | Estimated Cost |
|---------|-----------|----------------|
| Anvil (Local) | 1 gwei | ~0.02 ETH |
| Polygon | 30 gwei | ~0.5 MATIC |
| Arbitrum | 0.1 gwei | ~0.002 ETH |
| Optimism | 0.001 gwei | ~0.00002 ETH |
| Ethereum Mainnet | 20 gwei | ~0.3-0.4 ETH |

## Wallet Management

### Using Existing Keystore

If you already have a keystore file:

```bash
forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --keystore /path/to/your/keystore \
  --gas-report -vvvv
```

### Creating a New Test Keystore

For local testing, create a test keystore:

```bash
# Generate new wallet
cast wallet new-mnemonic --words 12

# Import to keystore
cast wallet import test-wallet --interactive

# The keystore will be saved to ~/.foundry/keystores/
```

## Testing the Deployment

After deployment, you can verify everything works by:

1. **Running the test suite**:
   ```bash
   forge test --gas-report
   ```

2. **Checking deployed addresses**: The script prints all deployed contract addresses

3. **Interacting with contracts**: Use `cast` commands or write integration tests

## Troubleshooting

### Common Issues

1. **"out of gas" errors**: Increase gas limit in foundry.toml or use `--gas-limit` flag
2. **"insufficient funds"**: Ensure the deployer account has enough ETH
3. **"nonce too low"**: Restart Anvil or use `--reset` flag
4. **"keystore not found"**: Check the keystore path or create a new one

### Debug Commands

```bash
# Check deployer balance (replace with your address)
cast balance <YOUR_ADDRESS> --rpc-url http://127.0.0.1:8545

# Get nonce
cast nonce <YOUR_ADDRESS> --rpc-url http://127.0.0.1:8545

# Check contract bytecode
cast code <CONTRACT_ADDRESS> --rpc-url http://127.0.0.1:8545

# List available keystores
ls ~/.foundry/keystores/
```

## Funding Your Wallet on Anvil

If using a custom wallet with Anvil, you'll need to fund it. Use one of the pre-funded Anvil accounts:

```bash
# Transfer ETH from Anvil account #0 to your wallet
cast send <YOUR_ADDRESS> --value 10ether \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## Next Steps

After successful deployment:

1. **Save the deployment addresses** from the console output
2. **Fund mock tokens** to test accounts for testing
3. **Create test contests and speculations**
4. **Run integration tests** to verify the full system works

## Testnet Deployment

For testnet deployment, modify the script to:
1. Use real token addresses (e.g., USDC on Polygon)
2. Use real Chainlink router and LINK token addresses
3. Update DON ID and source hashes for the target network
4. Set appropriate gas prices and limits
5. Use secure wallet management practices

Never use test keystores or private keys for testnet or mainnet deployments! 