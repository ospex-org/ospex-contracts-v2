// Simple script to encrypt Chainlink Functions Secrets URL
const { SecretsManager } = require("@chainlink/functions-toolkit");
const { ethers } = require("ethers");
const readline = require('readline');

// Configuration
const secretsUrl = "https://green-considerable-whitefish-752.mypinata.cloud/ipfs/QmStrMPyzjsaeZC5at9nRjznGFGdjkandWZhB8LkEgshRL";
const donId = "fun-polygon-amoy-1";
const routerAddress = "0xA9d587a00A31A52Ed70D6026794a8FC5E2F5dCb0"; // Polygon Amoy
const rpcUrl = "https://rpc-amoy.polygon.technology";

// Create readline interface for secure input
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

// Securely prompt for private key
rl.question('Enter your private key (will not be stored): ', async (privateKey) => {
  try {
    console.log("\nEncrypting secrets URL...");
    
    // Setup provider and wallet
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey);
    const signer = wallet.connect(provider);
    
    // Initialize secrets manager
    const secretsManager = new SecretsManager({
      signer,
      functionsRouterAddress: routerAddress,
      donId,
    });
    
    await secretsManager.initialize();
    
    // Encrypt the URL
    const encryptedSecretsUrls = await secretsManager.encryptSecretsUrls([secretsUrl]);
    
    // Output the result in Solidity-ready format
    console.log("\n✅ Successfully encrypted!");
    console.log("\nFor your Solidity script:");
    console.log(`bytes memory encryptedSecretsUrls = hex"${encryptedSecretsUrls.slice(2)}";`);
    
    // Clear console history (attempt to remove private key from terminal history)
    console.clear();
    console.log("✅ Encrypted URL for Solidity script:");
    console.log(`bytes memory encryptedSecretsUrls = hex"${encryptedSecretsUrls.slice(2)}";`);
    
  } catch (error) {
    console.error("\n❌ Error encrypting URL:", error.message);
    if (error.message.includes("invalid address")) {
      console.log("\nTip: Make sure you entered a valid private key");
    }
  } finally {
    // Always close readline and exit
    rl.close();
    // Clear private key from memory
    privateKey = "";
  }
}); 