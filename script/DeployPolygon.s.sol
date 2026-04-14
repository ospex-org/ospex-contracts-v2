// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core contracts
import "../src/core/OspexCore.sol";

// Modules
import "../src/modules/TreasuryModule.sol";
import "../src/modules/OracleModule.sol";
import "../src/modules/SpeculationModule.sol";
import "../src/modules/PositionModule.sol";
import "../src/modules/SecondaryMarketModule.sol";
import "../src/modules/ContestModule.sol";
import "../src/modules/LeaderboardModule.sol";
import "../src/modules/RulesModule.sol";
import "../src/modules/MoneylineScorerModule.sol";
import "../src/modules/SpreadScorerModule.sol";
import "../src/modules/TotalScorerModule.sol";
import "../src/modules/MatchingModule.sol";

/**
 * @title DeployPolygon
 * @notice Deployment script for Ospex protocol on Polygon Mainnet
 * @dev Uses bootstrap+finalize pattern — no admin key after deployment.
 */
contract DeployPolygon is Script {
    // Polygon mainnet addresses
    address constant LINK_ADDRESS = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address constant FUNCTIONS_ROUTER = 0xdc2AAF042Aeff2E68B3e8E33F19e4B9fA7C73F10;
    address constant USDC_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant FEE_RECEIVER = 0xdaC630aE52b868FF0A180458eFb9ac88e7425114;
    bytes32 constant DON_ID = bytes32("fun-polygon-mainnet-1");
    uint256 constant LINK_DENOMINATOR = 10**18;

    struct DeploymentConfig {
        uint8 tokenDecimals;
        uint32 voidCooldown;
        uint256 minSpeculationAmount;
        uint256 contestCreationFee;
        uint256 speculationCreationFee;
        uint256 leaderboardCreationFee;
        address protocolReceiver;
    }

    struct DeployedContracts {
        address ospexCore;
        address usdc;
        address treasuryModule;
        address oracleModule;
        address speculationModule;
        address positionModule;
        address secondaryMarketModule;
        address contestModule;
        address leaderboardModule;
        address rulesModule;
        address moneylineScorerModule;
        address spreadScorerModule;
        address totalScorerModule;
        address matchingModule;
    }

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== Ospex Polygon Mainnet Deployment (Zero-Admin) ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        require(deployer.balance > 0, "Deployer has zero balance");

        DeploymentConfig memory config = DeploymentConfig({
            tokenDecimals: 6,
            voidCooldown: 3 days,
            minSpeculationAmount: 1 * 10**6,
            contestCreationFee: 1_000_000, // 1.00 USDC
            speculationCreationFee: 500_000, // 0.50 USDC (split between maker and taker)
            leaderboardCreationFee: 250_000, // 0.25 USDC
            protocolReceiver: FEE_RECEIVER
        });

        vm.startBroadcast(deployer);

        DeployedContracts memory contracts = _deployContracts(config);
        _bootstrapAndFinalize(contracts);
        _verifyDeployment(contracts);
        _printSummary(contracts, deployer);

        vm.stopBroadcast();
    }

    function _deployContracts(
        DeploymentConfig memory config
    ) internal returns (DeployedContracts memory c) {
        c.usdc = USDC_ADDRESS;

        c.ospexCore = address(new OspexCore());
        console.log("OspexCore:", c.ospexCore);

        c.contestModule = address(new ContestModule(c.ospexCore));
        c.leaderboardModule = address(new LeaderboardModule(c.ospexCore));
        c.rulesModule = address(new RulesModule(c.ospexCore));
        c.moneylineScorerModule = address(new MoneylineScorerModule(c.ospexCore));
        c.spreadScorerModule = address(new SpreadScorerModule(c.ospexCore));
        c.totalScorerModule = address(new TotalScorerModule(c.ospexCore));
        c.matchingModule = address(new MatchingModule(c.ospexCore));

        c.treasuryModule = address(new TreasuryModule(
            c.ospexCore, c.usdc, config.protocolReceiver,
            config.contestCreationFee, config.speculationCreationFee, config.leaderboardCreationFee
        ));
        c.speculationModule = address(new SpeculationModule(
            c.ospexCore, config.tokenDecimals, config.voidCooldown, config.minSpeculationAmount
        ));
        c.positionModule = address(new PositionModule(c.ospexCore, c.usdc));
        c.secondaryMarketModule = address(new SecondaryMarketModule(c.ospexCore, c.usdc));
        c.oracleModule = address(new OracleModule(
            c.ospexCore, FUNCTIONS_ROUTER, LINK_ADDRESS, DON_ID, LINK_DENOMINATOR
        ));

        console.log("All 12 modules deployed.");
        return c;
    }

    function _bootstrapAndFinalize(DeployedContracts memory c) internal {
        OspexCore core = OspexCore(c.ospexCore);

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = c.contestModule;
        types[1] = core.SPECULATION_MODULE();        addrs[1] = c.speculationModule;
        types[2] = core.POSITION_MODULE();           addrs[2] = c.positionModule;
        types[3] = core.MATCHING_MODULE();           addrs[3] = c.matchingModule;
        types[4] = core.ORACLE_MODULE();             addrs[4] = c.oracleModule;
        types[5] = core.TREASURY_MODULE();           addrs[5] = c.treasuryModule;
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = c.leaderboardModule;
        types[7] = core.RULES_MODULE();              addrs[7] = c.rulesModule;
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = c.secondaryMarketModule;
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = c.moneylineScorerModule;
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = c.spreadScorerModule;
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = c.totalScorerModule;

        core.bootstrapModules(types, addrs);
        core.finalize();
        console.log("Protocol FINALIZED.");
    }

    function _verifyDeployment(DeployedContracts memory c) internal view {
        OspexCore core = OspexCore(c.ospexCore);
        require(core.s_finalized(), "Not finalized!");
        require(core.isApprovedScorer(c.moneylineScorerModule), "MoneylineScorer check failed");
        require(core.isApprovedScorer(c.spreadScorerModule), "SpreadScorer check failed");
        require(core.isApprovedScorer(c.totalScorerModule), "TotalScorer check failed");
        require(core.isSecondaryMarket(c.secondaryMarketModule), "SecondaryMarket check failed");
        console.log("Verification PASSED.");
    }

    function _printSummary(DeployedContracts memory c, address deployer) internal pure {
        console.log("\n============================================================");
        console.log("  POLYGON MAINNET DEPLOYMENT (Zero-Admin, Immutable)");
        console.log("============================================================");
        console.log("Deployer:", deployer);
        console.log("USDC:", c.usdc);
        console.log("OspexCore:", c.ospexCore);
        console.log("\nModules (12):");
        console.log("  ContestModule:", c.contestModule);
        console.log("  SpeculationModule:", c.speculationModule);
        console.log("  PositionModule:", c.positionModule);
        console.log("  MatchingModule:", c.matchingModule);
        console.log("  OracleModule:", c.oracleModule);
        console.log("  TreasuryModule:", c.treasuryModule);
        console.log("  LeaderboardModule:", c.leaderboardModule);
        console.log("  RulesModule:", c.rulesModule);
        console.log("  SecondaryMarketModule:", c.secondaryMarketModule);
        console.log("  MoneylineScorerModule:", c.moneylineScorerModule);
        console.log("  SpreadScorerModule:", c.spreadScorerModule);
        console.log("  TotalScorerModule:", c.totalScorerModule);
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Add OracleModule as consumer on Chainlink subscription 191");
        console.log("2. Update all dependent services with new addresses");
        console.log("3. Test with small positions before going live");
    }
}
