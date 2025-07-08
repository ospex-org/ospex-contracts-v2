# Ospex Protocol: Contest & Speculation Scoring Flow

## 1. Contest Scoring Flow

```
[Anyone]
   |
   v
[OracleModule] --(only this module can call)--> [ContestModule.setScores()]
   |
   v
[ContestModule] --(updates scores, emits events, sets status to Scored)-->
   |
   v
[OspexCore.emitCoreEvent()]
```

- **Who can initiate?** Anyone can call the OracleModule to start contest scoring.
- **Where is the function?** The scoring entry point is in `OracleModule` (e.g., `scoreContestFromOracle` or similar).
- **Who can actually set scores?** Only the OracleModule can call `ContestModule.setScores()`, enforced by `onlyOracleModule` modifier.
- **Manual override:** If the OracleModule fails, a user with `SCORE_MANAGER_ROLE` (set in OspexCore) can call `ContestModule.scoreContestManually()` after a wait period.

### Contest Scoring Permissions

- **OracleModule**: The only contract allowed to set scores directly.
- **SCORE_MANAGER_ROLE**: Can set scores manually after a wait period (for emergencies or oracle failure). This role should only be assigned to a trusted wallet or multisig.
- **Role assignment:** `SCORE_MANAGER_ROLE` is managed by `OspexCore` via `grantRole`.

---

## 2. Speculation Scoring Flow

```
[Anyone]
   |
   v
[SpeculationModule.settleSpeculation()]
   |
   v
[SpeculationModule]
   |
   |--(gets contest status from ContestModule)
   |
   |--(gets scorer address from speculationScorer field)
   |
   v
[ScorerModule (Moneyline/Spread/Total)]
   |
   |--(onlySpeculationModule: checks msg.sender == registered SpeculationModule in OspexCore)
   |
   v
[ScorerModule.determineWinSide()]
   |
   v
[SpeculationModule updates winSide, emits events]
```

- **Who can initiate?** Anyone can call `SpeculationModule.settleSpeculation()`.
- **How is the scorer chosen?** Each speculation stores its scorer address (`speculationScorer`), which points to the correct scorer module (Moneyline, Spread, or Total).
- **Who can actually run determineWinSide?** Only the registered SpeculationModule contract (as tracked by OspexCore) can call `determineWinSide` on a scorer module. No wallet or SCORE_MANAGER_ROLE can call this function.
- **What does SpeculationModule do?** It calls `scorer.determineWinSide(s.contestId, s.theNumber)` and updates the speculation's result.

### Speculation Scoring Permissions

- **Anyone** can initiate settlement, but:
- **ScorerModule.determineWinSide** can only be called by the registered SpeculationModule contract (checked via OspexCore module registry).
- **No wallet or SCORE_MANAGER_ROLE can call determineWinSide.**

---

## 3. Role Management: SCORE_MANAGER_ROLE and SpeculationModule Access

- **SCORE_MANAGER_ROLE**
  - **Purpose:** Only for manual contest scoring in ContestModule (after a wait period).
  - **Who should have it?** A trusted wallet or multisig, not a contract.
  - **How is it granted?** By calling `OspexCore.grantRole(SCORE_MANAGER_ROLE, <address>)`.
- **SpeculationModule Access to ScorerModules**
  - **Purpose:** Only the registered SpeculationModule contract (as tracked by OspexCore) can call `determineWinSide` in scorer modules.
  - **How is it enforced?** Scorer modules use a modifier that checks `msg.sender == i_ospexCore.getModule(keccak256("SPECULATION_MODULE"))`.

---

## 4. Key Code/Contract Relationships

- **ContestModule**: Only OracleModule (or SCORE_MANAGER_ROLE for manual) can set scores.
- **SpeculationModule**: Anyone can initiate settlement, but only the registered SpeculationModule can call scorer modules.
- **ScorerModule (Moneyline/Spread/Total)**: Only the registered SpeculationModule can call `determineWinSide` (checked via OspexCore module registry).
- **OspexCore**: Central registry for roles and modules.

---

## 5. Example: How determineWinSide is Routed and Restricted

Suppose a speculation is a moneyline bet:

- `speculationScorer` is set to the address of MoneylineScorerModule.
- When settling, SpeculationModule does:
  ```solidity
  IScorerModule scorer = IScorerModule(s.speculationScorer);
  s.winSide = scorer.determineWinSide(s.contestId, s.theNumber);
  ```
- In MoneylineScorerModule:
  ```solidity
  modifier onlySpeculationModule() {
      if (msg.sender != i_ospexCore.getModule(keccak256("SPECULATION_MODULE"))) {
          revert MoneylineScorerModule__NotSpeculationModule(msg.sender);
      }
      _;
  }
  function determineWinSide(...) external view override onlySpeculationModule returns (WinSide) { ... }
  ```
- Only the registered SpeculationModule can call this function. No wallet or SCORE_MANAGER_ROLE can call it.

---

## 6. ASCII Summary

### Contest Scoring

```
[User/Anyone]
   |
   v
[OracleModule] --(onlyOracleModule)--> [ContestModule.setScores()]
   |
   v
[OspexCore.emitCoreEvent()]
```
- Manual: [SCORE_MANAGER_ROLE] --> [ContestModule.scoreContestManually()]

### Speculation Scoring

```
[User/Anyone]
   |
   v
[SpeculationModule.settleSpeculation()]
   |
   v
[ScorerModule.determineWinSide()]  <-- only registered SpeculationModule (checked via OspexCore)
   |
   v
[SpeculationModule updates winSide]
```

---

## 7. FAQ

**Q: Who should have SCORE_MANAGER_ROLE?**  
A: Only a trusted wallet or multisig, for manual contest scoring in emergencies.

**Q: Can any wallet or SCORE_MANAGER_ROLE call determineWinSide?**  
A: No. Only the registered SpeculationModule contract (as tracked by OspexCore) can call determineWinSide in scorer modules.

**Q: How does the system know which scorer to use?**  
A: Each speculation stores its scorer address (`speculationScorer`), set at creation.

**Q: What if the OracleModule fails?**  
A: Manual scoring is possible via SCORE_MANAGER_ROLE after a wait period.

**Q: How is the SpeculationModule registered?**  
A: By calling `OspexCore.registerModule(keccak256("SPECULATION_MODULE"), speculationModuleAddress)` during deployment or upgrade.

---

## 8. References

- [OspexCore.sol](../src/core/OspexCore.sol)
- [ContestModule.sol](../src/modules/ContestModule.sol)
- [SpeculationModule.sol](../src/modules/SpeculationModule.sol)
- [MoneylineScorerModule.sol](../src/modules/MoneylineScorerModule.sol)
- [SpreadScorerModule.sol](../src/modules/SpreadScorerModule.sol)
- [TotalScorerModule.sol](../src/modules/TotalScorerModule.sol)

---

**This document should clarify the scoring flows, role assignments, and contract interactions for both contests and speculations in Ospex, reflecting the latest security improvements.** 