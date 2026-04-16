// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/core/OspexCore.sol";
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
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockLinkToken.sol";
import "../test/mocks/MockFunctionsRouter.sol";

/**
 * @title DeployAnvilFull
 * @notice Deploys the full Ospex protocol to local Anvil, writes addresses.json
 * @dev Usage: forge script script/DeployAnvilFull.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv
 */
contract DeployAnvilFull is Script {
    // Anvil deterministic keys
    uint256 constant DEPLOYER_PK  = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant ALICE_PK     = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant BOB_PK       = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant CHARLIE_PK   = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant SIGNER_PK    = 0xA11CE;

    function run() external {
        address deployer = vm.addr(DEPLOYER_PK);
        address alice    = vm.addr(ALICE_PK);
        address bob      = vm.addr(BOB_PK);
        address charlie  = vm.addr(CHARLIE_PK);
        address signer   = vm.addr(SIGNER_PK);

        console.log("Deployer:", deployer);
        console.log("Alice:   ", alice);
        console.log("Bob:     ", bob);
        console.log("Charlie: ", charlie);
        console.log("Signer:  ", signer);

        vm.startBroadcast(DEPLOYER_PK);

        // ── Mock tokens ──
        MockERC20 usdc = new MockERC20();
        MockLinkToken link = new MockLinkToken();
        MockFunctionsRouter router = new MockFunctionsRouter(address(link));

        // ── Core ──
        OspexCore core = new OspexCore();

        // ── Modules (core-only deps) ──
        ContestModule contestModule = new ContestModule(address(core));
        LeaderboardModule leaderboardModule = new LeaderboardModule(address(core));
        RulesModule rulesModule = new RulesModule(address(core));
        MoneylineScorerModule moneylineScorer = new MoneylineScorerModule(address(core));
        SpreadScorerModule spreadScorer = new SpreadScorerModule(address(core));
        TotalScorerModule totalScorer = new TotalScorerModule(address(core));
        MatchingModule matchingModule = new MatchingModule(address(core));

        // ── Modules (additional deps) ──
        TreasuryModule treasuryModule = new TreasuryModule(
            address(core),
            address(usdc),
            deployer,          // protocolReceiver
            1_000_000,         // contestCreationFee (1 USDC)
            500_000,           // speculationCreationFee (0.50 USDC split)
            250_000            // leaderboardCreationFee (0.25 USDC)
        );

        SpeculationModule speculationModule = new SpeculationModule(address(core), 3 days);

        PositionModule positionModule = new PositionModule(address(core), address(usdc));
        SecondaryMarketModule secondaryMarketModule = new SecondaryMarketModule(address(core), address(usdc));

        OracleModule oracleModule = new OracleModule(
            address(core),
            address(router),
            address(link),
            bytes32("test_don_id"),
            10,                // linkDenominator: payment = 1e18/10 = 0.1 LINK per request
            signer             // approvedSigner for EIP-712 script approvals
        );

        // ── Bootstrap + Finalize ──
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();           addrs[0]  = address(contestModule);
        types[1]  = core.SPECULATION_MODULE();        addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();           addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();           addrs[3]  = address(matchingModule);
        types[4]  = core.ORACLE_MODULE();             addrs[4]  = address(oracleModule);
        types[5]  = core.TREASURY_MODULE();           addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();        addrs[6]  = address(leaderboardModule);
        types[7]  = core.RULES_MODULE();              addrs[7]  = address(rulesModule);
        types[8]  = core.SECONDARY_MARKET_MODULE();   addrs[8]  = address(secondaryMarketModule);
        types[9]  = core.MONEYLINE_SCORER_MODULE();   addrs[9]  = address(moneylineScorer);
        types[10] = core.SPREAD_SCORER_MODULE();      addrs[10] = address(spreadScorer);
        types[11] = core.TOTAL_SCORER_MODULE();       addrs[11] = address(totalScorer);

        core.bootstrapModules(types, addrs);
        core.finalize();
        console.log("Protocol finalized. All 12 modules registered.");

        // ── Mint USDC to test accounts ──
        usdc.mint(alice,   1_000_000_000); // 1000 USDC
        usdc.mint(bob,     1_000_000_000);
        usdc.mint(charlie, 1_000_000_000);
        usdc.mint(deployer, 1_000_000_000);

        // ── Mint LINK to deployer (for oracle calls) ──
        link.mint(deployer, 100 ether);

        vm.stopBroadcast();

        // ── Approve contracts from each test account ──
        _approveAll(ALICE_PK, address(usdc), address(treasuryModule), address(positionModule), address(secondaryMarketModule));
        _approveAll(BOB_PK, address(usdc), address(treasuryModule), address(positionModule), address(secondaryMarketModule));
        _approveAll(CHARLIE_PK, address(usdc), address(treasuryModule), address(positionModule), address(secondaryMarketModule));

        vm.startBroadcast(DEPLOYER_PK);
        usdc.approve(address(treasuryModule), type(uint256).max);
        link.approve(address(oracleModule), type(uint256).max);
        vm.stopBroadcast();

        // ── Write addresses.json ──
        string memory json = "addresses";
        vm.serializeAddress(json, "ospexCore", address(core));
        vm.serializeAddress(json, "mockUSDC", address(usdc));
        vm.serializeAddress(json, "mockLINK", address(link));
        vm.serializeAddress(json, "mockRouter", address(router));
        vm.serializeAddress(json, "contestModule", address(contestModule));
        vm.serializeAddress(json, "speculationModule", address(speculationModule));
        vm.serializeAddress(json, "positionModule", address(positionModule));
        vm.serializeAddress(json, "matchingModule", address(matchingModule));
        vm.serializeAddress(json, "oracleModule", address(oracleModule));
        vm.serializeAddress(json, "treasuryModule", address(treasuryModule));
        vm.serializeAddress(json, "leaderboardModule", address(leaderboardModule));
        vm.serializeAddress(json, "rulesModule", address(rulesModule));
        vm.serializeAddress(json, "secondaryMarketModule", address(secondaryMarketModule));
        vm.serializeAddress(json, "moneylineScorerModule", address(moneylineScorer));
        vm.serializeAddress(json, "spreadScorerModule", address(spreadScorer));
        vm.serializeAddress(json, "totalScorerModule", address(totalScorer));
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeAddress(json, "alice", alice);
        vm.serializeAddress(json, "bob", bob);
        vm.serializeAddress(json, "charlie", charlie);
        string memory finalJson = vm.serializeAddress(json, "signer", signer);

        vm.writeJson(finalJson, "./addresses.json");
        console.log("\nAddresses written to addresses.json");

        // ── Summary ──
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("OspexCore:              ", address(core));
        console.log("MockUSDC:               ", address(usdc));
        console.log("MockLINK:               ", address(link));
        console.log("MockRouter:             ", address(router));
        console.log("OracleModule:           ", address(oracleModule));
        console.log("ContestModule:          ", address(contestModule));
        console.log("SpeculationModule:      ", address(speculationModule));
        console.log("PositionModule:         ", address(positionModule));
        console.log("MatchingModule:         ", address(matchingModule));
        console.log("TreasuryModule:         ", address(treasuryModule));
        console.log("LeaderboardModule:      ", address(leaderboardModule));
        console.log("RulesModule:            ", address(rulesModule));
        console.log("SecondaryMarketModule:  ", address(secondaryMarketModule));
        console.log("MoneylineScorerModule:  ", address(moneylineScorer));
        console.log("SpreadScorerModule:     ", address(spreadScorer));
        console.log("TotalScorerModule:      ", address(totalScorer));
        console.log("Signer (approvedSigner):", signer);
    }

    function _approveAll(
        uint256 pk,
        address token,
        address treasury,
        address position,
        address secondary
    ) internal {
        vm.startBroadcast(pk);
        MockERC20(token).approve(treasury, type(uint256).max);
        MockERC20(token).approve(position, type(uint256).max);
        MockERC20(token).approve(secondary, type(uint256).max);
        vm.stopBroadcast();
    }
}
