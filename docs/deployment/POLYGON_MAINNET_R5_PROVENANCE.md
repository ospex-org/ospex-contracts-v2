# Ospex Round 5 — Registry Provenance (Polygon Mainnet)

> **Record date:** 2026-07-05 · **Chain:** Polygon mainnet (137) · **OspexCore:** [`0x40047BAFcdEd16C938058b7b67186299a2893561`](https://polygonscan.com/address/0x40047BAFcdEd16C938058b7b67186299a2893561)
> Machine-readable version: [`polygon-mainnet-r5-provenance.json`](./polygon-mainnet-r5-provenance.json)

**The claim this record proves:** the set of addresses holding registered-module powers on OspexCore is **exactly** the 12 modules in the R5 address table — no more, no less — permanently.

**Why chain history is needed:** `finalize()` proves on-chain that *at least* the 12 required module types are registered, but `bootstrapModules()` accepts arbitrary type identifiers pre-finalize, and a mapping cannot be enumerated from current state — so *exactly-12* is only provable from the bootstrap transactions themselves (see [TRUST_MODEL.md → Verification](../TRUST_MODEL.md#verification)). The registry is written by exactly one function, only by the deployer, only before `finalize()` — so its complete history is the transactions below, and the answer can never change.

## Evidence

**Registry writes — the complete history.** A log query for `ModulesBootstrapped(uint256)` on OspexCore from its deploy block (89322650) to latest returns **exactly one event**:

| | |
|---|---|
| Transaction | [`0xa773f7d8e770419bbf271b06299a7384b4d4c80fcc9835b2573ae9ccec7a22bd`](https://polygonscan.com/tx/0xa773f7d8e770419bbf271b06299a7384b4d4c80fcc9835b2573ae9ccec7a22bd) |
| Block | 89322675 |
| Sender | `0x53AF7B1BB308abD6F106231B75a241fB3e9eeA5C` (the OspexCore deployer) |
| Event data (module count) | `12` |
| Event topic0 | `0xbf6b41cb85aa0914079ea81fcdac49445c89ea24071a5cbb04173ed51a05e610` |

**Decoded calldata of that transaction** (`bootstrapModules(bytes32[],address[])`) — all 12 registrations, in call order. Every type hash matches the keccak256 of its expected name, and every address matches the [R5 address table](./POLYGON_MAINNET_R5.md):

| # | Module type | keccak256(type) | Registered address |
|---|-------------|-----------------|--------------------|
| 1 | `CONTEST_MODULE` | `0xb853e7f1ca7c39b3d60a4a01169293d298c5bac9d91781182e553e486b426238` | `0x0f838AF735E95625905c6acFB887a2E9f4DB9216` |
| 2 | `SPECULATION_MODULE` | `0xcf4380c3644cbbdee3cb3ab0bc7d20abb63598788869c8d34407ba532c2f95a6` | `0xEA21b58E91eDcA41d0c42A8655234F8A64fa31bc` |
| 3 | `POSITION_MODULE` | `0x182d49e8f1ba343facbac18b56a4a0f869e2f54f3165879cb5d067f4ff67ee19` | `0x3C71fdB8ABF41487a512440e5ce6490158C26e56` |
| 4 | `MATCHING_MODULE` | `0xa1326d0c5166785cdcae1676162883d8566a23dc474bf97158b09dc4ed64d7d9` | `0x46Af20B6307Aa0Ec13de10EF58a02c5F1b5C9559` |
| 5 | `CRE_ORACLE_RECEIVER` | `0xcb7addc43a311a61006d73f0dc185403269a7adcead775aaf85cdedb16a3c3f4` | `0x06e3470012039797119Ae30e1236169304F9220C` |
| 6 | `TREASURY_MODULE` | `0x0c1f3a2fb8d5cb85f06f67a78424b420c7a88acd1df03770d5da98ff6a648202` | `0x07f357e67cc9B48D029b1E4C9B7F45569a2eB85C` |
| 7 | `LEADERBOARD_MODULE` | `0x135db7d1e2a894eabefefde819385a5f056f9cb71309038a80d5dedc9f34a6c9` | `0x02228F4bAB35d9631296C47C2103789474aD72ee` |
| 8 | `RULES_MODULE` | `0x02e535fc21bfb82c317d4b9b99a239b99fa71e2bea1572ff170afdcd61f78a34` | `0x5a5662C8246Ed3dC2422Cc8f773564fA41b34723` |
| 9 | `SECONDARY_MARKET_MODULE` | `0x86b5238312c77f984fd459a72ebd4fbba99f6fdedf2f6a6f8acf9e987b6aca7b` | `0xf779d82E9a11234767921A73913dAd429F140aFB` |
| 10 | `MONEYLINE_SCORER_MODULE` | `0x8b02a8694c7973cae76e0aaa43157a85760a36598bbbf596247b460b7c9db24e` | `0x59555106D4B5f1A797f3552f60ac418Eb6B6f6BD` |
| 11 | `SPREAD_SCORER_MODULE` | `0x9958b1c66847463b48b605316a4f9b35bed8bcfef3f9eccb785e95e85e3dc7ca` | `0x8f293da716164d5A32dc087A85e5164D929ae9D4` |
| 12 | `TOTAL_SCORER_MODULE` | `0x72d978bbccb9ddac4961558836670726471e174959bebeca601d2f0f5e6a697a` | `0xB4B1E2A2a75C34e9E4C5D3BB8A432aff973DaDa0` |

**The freeze.** A single `Finalized()` event, 136 blocks (~4.5 minutes) after bootstrap, and no registry write is possible afterward:

| | |
|---|---|
| Transaction | [`0xcb71bbef269f139ca02f1988934b8fdd88e77a995bd356cd50c4ef0db6d44c80`](https://polygonscan.com/tx/0xcb71bbef269f139ca02f1988934b8fdd88e77a995bd356cd50c4ef0db6d44c80) |
| Block | 89322811 |
| Sender | `0x53AF7B1BB308abD6F106231B75a241fB3e9eeA5C` (same deployer) |
| Event topic0 | `0x6823b073d48d6e3a7d385eeb601452d680e74bb46afe3255a7d778f3a9b17681` |
| `s_finalized()` live read | `true` (checked 2026-07-05) |

**Verdict:** one bootstrap call, twelve registrations, the exact documented set, then finalized. No other address has ever held — or can ever hold — registered-module powers on OspexCore.

## Reproduce it yourself

Any Polygon RPC works (`$RPC` below). A contract's logs cannot precede its creation, so starting at the deploy block is complete by construction.

```bash
CORE=0x40047BAFcdEd16C938058b7b67186299a2893561

# 1. Every registry write ever (expect exactly ONE event, count = 12)
cast logs --rpc-url $RPC --from-block 89322650 --to-block latest \
  --address $CORE "ModulesBootstrapped(uint256)"

# 2. Decode that transaction's calldata (the registered types + addresses)
cast decode-calldata "bootstrapModules(bytes32[],address[])" \
  $(cast tx 0xa773f7d8e770419bbf271b06299a7384b4d4c80fcc9835b2573ae9ccec7a22bd input --rpc-url $RPC)

# 3. Confirm the freeze
cast logs --rpc-url $RPC --from-block 89322650 --to-block latest --address $CORE "Finalized()"
cast call --rpc-url $RPC $CORE "s_finalized()(bool)"

# 4. Map each type hash to its name (repeat for all 12 names in the table above)
cast keccak "CONTEST_MODULE"
```

Cross-checks if you want belt-and-braces: run step 1 against a second RPC provider (log completeness is a node property), or eyeball the same two events in [Polygonscan's event view for OspexCore](https://polygonscan.com/address/0x40047BAFcdEd16C938058b7b67186299a2893561#events). Source-level grounding: `bootstrapModules` is the only writer of `s_moduleRegistry`/`s_isModuleRegistered`, is deployer-only, rejects duplicate types, and is permanently disabled by `finalize()` — see `src/core/OspexCore.sol`.

## Scope

This record proves registry membership only. It does not attest to the modules' code (see Polygonscan source verification and [RISKS.md](../RISKS.md)) or the oracle trust model (see [TRUST_MODEL.md](../TRUST_MODEL.md)). The deployer address above retains no on-chain privileges — its only two powers were consumed by this bootstrap/finalize sequence.
