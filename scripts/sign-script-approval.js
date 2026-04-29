/**
 * Signs an EIP-712 ScriptApproval for Ospex OracleModule.
 *
 * Usage:
 *   node sign-script-approval.js <purpose> [--expiry-days N]
 *
 *   purpose: "verify" | "market-update" | "score"
 *   --expiry-days: optional, default 90. Use 0 for permanent.
 *
 * Examples:
 *   node sign-script-approval.js verify --expiry-days 90
 *   node sign-script-approval.js score --expiry-days 0
 *
 * The script fetches the JS source from raw.githubusercontent.com,
 * computes the keccak256 hash, and signs the EIP-712 struct.
 */

const { ethers } = require("ethers");
const readline = require("readline");

// === CONFIG ===

const ORACLE_MODULE_ADDRESS = "0x7e1397eD5b4c9f606DCF2EB0281485B2296E29Bb"; // Polygon mainnet R4 (deployed 2026-04-28). Amoy R4 was: 0x0508D9147D1f4C34866550A6f5877Bb3aA57A33e
const CHAIN_ID = 137; // Polygon mainnet

const SCRIPTS = {
  verify: {
    url: "https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestCreation.js",
    purpose: 0, // ScriptPurpose.VERIFY
    label: "Contest Verification (contestCreation.js)",
  },
  "market-update": {
    url: "https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestMarketsUpdate.js",
    purpose: 1, // ScriptPurpose.MARKET_UPDATE
    label: "Market Update (contestMarketsUpdate.js)",
  },
  score: {
    url: "https://raw.githubusercontent.com/ospex-org/ospex-source-files-and-other/master/src/contestScoring.js",
    purpose: 2, // ScriptPurpose.SCORE
    label: "Contest Scoring (contestScoring.js)",
  },
};

// EIP-712 domain — must match OracleModule constructor
const EIP712_DOMAIN = {
  name: "OspexOracle",
  version: "1",
  chainId: CHAIN_ID,
  verifyingContract: ORACLE_MODULE_ADDRESS,
};

const EIP712_TYPES = {
  ScriptApproval: [
    { name: "scriptHash", type: "bytes32" },
    { name: "purpose", type: "uint8" },
    { name: "leagueId", type: "uint8" },
    { name: "version", type: "uint16" },
    { name: "validUntil", type: "uint64" },
  ],
};

async function main() {
  const args = process.argv.slice(2);
  const purposeArg = args[0];

  if (!purposeArg || !SCRIPTS[purposeArg]) {
    console.error("Usage: node sign-script-approval.js <verify|market-update|score> [--expiry-days N]");
    process.exit(1);
  }

  // Parse expiry days
  let expiryDays = 90; // default
  const expiryIdx = args.indexOf("--expiry-days");
  if (expiryIdx !== -1 && args[expiryIdx + 1] !== undefined) {
    expiryDays = parseInt(args[expiryIdx + 1], 10);
    if (isNaN(expiryDays) || expiryDays < 0) {
      console.error("--expiry-days must be a non-negative integer");
      process.exit(1);
    }
  }

  const scriptConfig = SCRIPTS[purposeArg];
  const validUntil = expiryDays === 0
    ? 0
    : Math.floor(Date.now() / 1000) + (expiryDays * 24 * 60 * 60);

  console.log("=== Ospex Script Approval Signer ===\n");
  console.log("Script:", scriptConfig.label);
  console.log("Purpose:", purposeArg, `(enum ${scriptConfig.purpose})`);
  console.log("Expiry:", expiryDays === 0 ? "PERMANENT" : `${expiryDays} days (${new Date(validUntil * 1000).toISOString()})`);
  console.log("Chain:", CHAIN_ID, "(Polygon Mainnet)");
  console.log("OracleModule:", ORACLE_MODULE_ADDRESS);
  console.log("");

  // Step 1: Fetch the JS source
  console.log("Fetching source from GitHub...");
  console.log("URL:", scriptConfig.url);

  const response = await fetch(scriptConfig.url);
  if (!response.ok) {
    console.error(`Failed to fetch: ${response.status} ${response.statusText}`);
    process.exit(1);
  }

  const sourceCode = await response.text();

  console.log("\n--- Source Diagnostics ---");
  console.log("Length:", sourceCode.length, "characters");
  console.log("First 80 chars:", JSON.stringify(sourceCode.slice(0, 80)));
  console.log("Last 40 chars:", JSON.stringify(sourceCode.slice(-40)));
  console.log("Ends with newline:", sourceCode.endsWith("\n"));
  console.log("Contains \\r:", sourceCode.includes("\r"));

  // Step 2: Compute hash
  const sourceBytes = ethers.utils.toUtf8Bytes(sourceCode);
  const scriptHash = ethers.utils.keccak256(sourceBytes);

  console.log("\n--- Hash ---");
  console.log("scriptHash:", scriptHash);
  console.log("(keccak256 of", sourceBytes.length, "bytes)");

  // Step 3: Build the approval struct
  const approval = {
    scriptHash: scriptHash,
    purpose: scriptConfig.purpose,
    leagueId: 0, // Unknown = wildcard (all leagues)
    version: 1,
    validUntil: validUntil,
  };

  console.log("\n--- Approval Struct ---");
  console.log(JSON.stringify(approval, null, 2));

  // Step 4: Prompt for private key and sign
  const rl = readline.createInterface({ input: process.stdin, output: process.stderr });

  const privateKey = await new Promise((resolve) => {
    rl.question("\nEnter approved signer private key: ", (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });

  if (!privateKey) {
    console.error("No private key provided.");
    process.exit(1);
  }

  const wallet = new ethers.Wallet(privateKey);
  console.log("\nSigner address:", wallet.address);

  if (wallet.address.toLowerCase() !== "0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886".toLowerCase()) {
    console.warn("WARNING: Signer address does not match the Polygon mainnet approved signer!");
    console.warn("Expected: 0xfd6C7Fc1F182de53AA636584f1c6B80d9D885886");
    console.warn("Got:", wallet.address);
  }

  // Sign EIP-712 typed data
  const signature = await wallet._signTypedData(EIP712_DOMAIN, EIP712_TYPES, approval);

  console.log("\n=== SIGNED APPROVAL ===\n");
  console.log("scriptHash:", approval.scriptHash);
  console.log("purpose:", approval.purpose, `(${purposeArg})`);
  console.log("leagueId:", approval.leagueId, "(Unknown = all leagues)");
  console.log("version:", approval.version);
  console.log("validUntil:", approval.validUntil, approval.validUntil === 0 ? "(permanent)" : `(${new Date(approval.validUntil * 1000).toISOString()})`);
  console.log("signature:", signature);
  console.log("signer:", wallet.address);

  // Verify the signature recovers correctly
  const recovered = ethers.utils.verifyTypedData(EIP712_DOMAIN, EIP712_TYPES, approval, signature);
  console.log("\n--- Verification ---");
  console.log("Recovered signer:", recovered);
  console.log("Match:", recovered.toLowerCase() === wallet.address.toLowerCase() ? "YES" : "NO - MISMATCH!");

  // Output in a format ready for use
  console.log("\n=== FOR DOWNSTREAM USE ===\n");
  console.log(`SCRIPT_HASH=${approval.scriptHash}`);
  console.log(`PURPOSE=${approval.purpose}`);
  console.log(`LEAGUE_ID=${approval.leagueId}`);
  console.log(`VERSION=${approval.version}`);
  console.log(`VALID_UNTIL=${approval.validUntil}`);
  console.log(`SIGNATURE=${signature}`);
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
