// Simple script to encrypt Chainlink Functions secrets URL
// Run with: npx -y @chainlink/functions-toolkit@0.2.8 ethers@5.7.2 -- node encrypt.js

const { SecretsManager } = require('@chainlink/functions-toolkit');
const { ethers } = require('ethers');
const readline = require('readline');

// Create readline interface
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

// Main function
async function encryptUrl(privateKey) {
  try {
    console.log('\nEncrypting secrets URL...');
    
    // Setup provider and wallet
    const provider = new ethers.providers.JsonRpcProvider('https://rpc-amoy.polygon.technology');
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);
    
    // Initialize secrets manager
    const secretsManager = new SecretsManager({
      signer,
      functionsRouterAddress: '0xA9d587a00A31A52Ed70D6026794a8FC5E2F5dCb0',
      donId: 'fun-polygon-amoy-1'
    });
    
    await secretsManager.initialize();
    
    // Your secrets URL
    const secretsUrl = 'https://green-considerable-whitefish-752.mypinata.cloud/ipfs/QmStrMPyzjsaeZC5at9nRjznGFGdjkandWZhB8LkEgshRL';
    
    // Encrypt the URL
    const encryptedSecretsUrls = await secretsManager.encryptSecretsUrls([secretsUrl]);
    
    // Output the result
    console.log('\n✅ SUCCESS! Copy this into your Solidity script:');
    console.log(`\nbytes memory encryptedSecretsUrls = hex"${encryptedSecretsUrls.slice(2)}";\n`);
    
  } catch (error) {
    console.error('\n❌ Error:', error.message);
  }
}

// Prompt for private key
rl.question('Enter your private key: ', (privateKey) => {
  encryptUrl(privateKey).finally(() => rl.close());
}); 