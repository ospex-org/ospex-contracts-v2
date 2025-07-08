# Testing Strategy for Minimal Core + Plug-in Modules (Ospex)

## Overview
This document outlines a practical, incremental testing strategy for the Ospex protocol refactor using the Minimal Core + Plug-in Modules pattern. The goal is to ensure high-quality, maintainable tests and comprehensive coverage (as measured by Foundry) throughout the development process, rather than waiting until all contracts are complete.

---

## 1. General Principles
- **Test as you go:** Write tests for each contract/module as soon as it is implemented.
- **Incremental coverage:** Ensure each new contract or feature is covered by tests before moving on.
- **Keep Foundry coverage green:** Use `forge coverage` to check that all lines, functions, and branches are covered for the code that exists at each stage.
- **Refactor tests as needed:** As contracts evolve, update tests to match new interfaces and behaviors.
- **Use mocks and stubs:** Where dependencies are not yet implemented, use mock contracts or interfaces to simulate interactions.
- **Organize tests by contract/module:** Mirror the production contract structure in your test directory for clarity and maintainability.
- **Follow project variable naming conventions:**
  - Use `s_` for all storage variables (including public)
  - Use `i_` for all immutables
  - Use ALL_CAPS_WITH_UNDERSCORES for constants
  - Structs, enums, events: CapWords
  - Functions/modifiers: mixedCase
  - All speculation amounts (min, max, user input) are normalized to the token's decimals, set via `i_tokenDecimals` in `SpeculationModule`, for compatibility with both 6- and 18-decimal tokens. See the architecture doc for details.
  - See [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html#naming-conventions) and the main architecture doc for details.

---

## 2. Testing the Core Contract in Isolation
### What to Test
- **Deployment:** Ensure the core contract deploys correctly and initializes roles as expected.
- **Access control:** Test that only authorized accounts can register modules, change admin, etc.
- **Module registry:** Test registering, updating, and retrieving module addresses.
- **Event emission:** Test that events (e.g., `ModuleRegistered`, `AdminChanged`) are emitted correctly.
- **Edge cases:** Test invalid addresses, double registration, and permission errors.

### How to Test Without Modules
- Use dummy/mock addresses for module registration.
- Use Foundry's cheatcodes to simulate different callers/roles.
- Test all revert conditions and require statements.
- No need for real module contracts at this stage—focus on the core's logic and state.

### Example Test File Structure
```
test/core/OspexCore.t.sol
```

---

## 3. Adding and Testing Modules Incrementally
### As Each Module is Added
- **Write interface and stub/mock implementation first.**
- **Test module registration and retrieval via the core.**
- **Test module-specific logic in isolation:**
  - Use mocks for dependencies (e.g., if `PositionModule` needs `SpeculationModule`, mock the interface).
  - Test all public/external functions, including edge cases and reverts.
- **Test integration with the core:**
  - Register the module with the core and test access control.
  - Test that only registered modules can call core-restricted functions (if applicable).

### Example Test File Structure
```
test/modules/ContestModule.t.sol
test/modules/PositionModule.t.sol
```

---

## 4. Using Interfaces and Mocks
- **Interfaces:** Use Solidity interfaces for all cross-module calls.
- **Mocks:** Use Foundry's `forge-std` or custom mock contracts to simulate module behavior before the real implementation exists.
- **Replace mocks with real modules as they are implemented.**
- **Test both positive and negative paths:** Ensure that modules handle both successful and failed calls to other modules.

---

## 5. Ensuring and Tracking Coverage
- **Run `forge coverage` after each major change.**
- **Aim for 100% coverage for all implemented contracts.**
- **If coverage drops, add tests before proceeding.**
- **Use coverage reports to identify untested lines, branches, and functions.**
- **Do not worry about coverage for unimplemented modules—focus on what exists.**

---

## 6. Test File Organization
- **Mirror the contract structure:**
  - `src/core/OspexCore.sol` → `test/core/OspexCore.t.sol`
  - `src/modules/ContestModule.sol` → `test/modules/ContestModule.t.sol`
  - etc.
- **Use descriptive test names:**
  - `testRegisterModule_RevertsIfNotAdmin()`
  - `testSetAdmin_EmitsEvent()`
- **Group related tests in the same file.**

---

## 7. Example Test Progression
1. **Start with OspexCore:**
   - Write and cover all core logic.
2. **Add ContestModule:**
   - Write interface, stub, and tests for registration and basic logic.
3. **Add SpeculationModule, PositionModule, etc.:**
   - Repeat the process, using mocks for dependencies.
4. **As modules are implemented:**
   - Replace mocks with real contracts and add integration tests.
5. **Add end-to-end tests:**
   - Once several modules are complete, write tests that simulate full workflows (e.g., contest creation → speculation → position → claim).

---

## 8. Best Practices
- **Test for reverts and edge cases, not just happy paths.**
- **Use `vm.expectRevert` and `vm.prank` for access control and error testing.**
- **Document test intent with comments.**
- **Keep tests fast and focused.**
- **Refactor and clean up tests as contracts evolve.**
- **Follow the variable naming conventions:** Use `s_` for storage, `i_` for immutables, ALL_CAPS for constants, CapWords for types/events, mixedCase for functions/modifiers.

---

## 9. Final Coverage Pass Before Audit
- **Once all modules are implemented, do a comprehensive coverage review.**
- **Add missing tests for uncovered lines/branches.**
- **Consider fuzzing and invariant tests for critical logic.**

---

## 10. Summary Table
| Stage                | What to Test                        | How to Test                |
|----------------------|-------------------------------------|----------------------------|
| Core only            | Registry, access, events, reverts   | In isolation, with mocks   |
| Module added         | Module logic, registration, access  | With core, using mocks     |
| Multiple modules     | Integration, cross-module calls     | Replace mocks as needed    |
| Full system          | End-to-end flows, edge cases        | Real modules, full tests   |

---

## 11. References
- [Foundry Book: Writing Tests](https://book.getfoundry.sh/forge/writing-tests)
- [Foundry Coverage](https://book.getfoundry.sh/forge/coverage)
- [Minimal Core + Plug-in Modules Pattern](see refactoring prompt response)

---

## 12. Running Tests and Coverage

### Project Structure Clarification
- **Current refactor:**
  - Contracts: `src/` (main folder for new contracts)
  - Tests: `test/` (main folder for new tests)
- **v2 (legacy, for reference only):**
  - Contracts: `reference/v2/`
  - Tests: `reference/v2/`
- **Goal:** Only run, compile, and check coverage for current contracts and tests. Ignore v2 (legacy) code unless specifically testing legacy behavior.

### How to Exclude v2 (Legacy) from Foundry
- By default, Foundry will compile and test everything in `src/` and `test/`.
- To avoid compiling/testing v2, use the `--match-path` flag to target only main test files.
- **Example directory structure:**
  - `src/core/OspexCore.sol`
  - `test/core/OspexCore.t.sol`
  - `src/modules/ContestModule.sol`
  - `test/modules/ContestModule.t.sol`

### Common Foundry Commands

#### Run all main tests:
```bash
forge test --match-path 'test/**/*.t.sol'
```

#### Run a specific test file (example):
```bash
forge test --match-path 'test/core/OspexCore.t.sol'
```

#### Run coverage for all main tests:
```bash
forge coverage --match-path 'test/**/*.t.sol'
```

#### (Optional) Compile only main contracts:
```bash
forge build --match-path 'src/**/*.sol'
```

#### (Optional) Clean build artifacts:
```bash
forge clean
```

### Tips
- If you add new modules, keep them in the `src/` and `test/` folders.
- If you want to run all tests except those in v2, you can use `--no-match-path 'reference/v2/**/*.t.sol'` (but using `--match-path` is safer).
- You can add a `.gitignore` or `.foundryignore` file to further exclude legacy code if needed.

---

**By following this structure and using the above commands, you will ensure that only your current contracts and tests are compiled, run, and checked for coverage, keeping your workflow clean and focused.**

**By following this strategy, you will maintain high-quality, comprehensive tests and coverage throughout your refactor, making the final audit and deployment process much smoother.**

---

## 13. Event Emission Testing: Hybrid Pattern

### Pattern
Ospex uses a hybrid event emission pattern:
- **Module-local events**: Emitted by each module for detailed, granular tracking (e.g., `PositionCreated`, `SpeculationSettled`).
- **Core events**: Emitted via `OspexCore.emitCoreEvent` for protocol-wide actions (e.g., `POSITION_CREATED`, `CONTEST_SCORES_SET`).

### Testing Guidance
- **Test both event types**: In module tests, assert that both the local event and the core event are emitted for major actions.
- **Use Foundry's `expectEmit` and `expectEvent`**: Assert on event topics and data for both module and core events.
- **Indexing**: Off-chain indexers should listen to both module and core events, but can prioritize core events for protocol-wide analytics.

### Example (Foundry)
```solidity
// Expect local event
vm.expectEmit(true, true, true, true);
// ... call function ...
// Expect core event
vm.expectEmit(true, true, true, true, address(ospexCore));
// ... call function ...
```

### Best Practices
- Always emit both event types for user-facing actions.
- Document which events are core vs. module-local.
- In integration tests, check that both events are emitted in the correct order.

## [IMPORTANT] Token Decimals and Test Amounts
- All test amounts (min, max, user input, etc.) **must use the token's decimals** as set in the contract (e.g., 6 decimals for USDC, 18 for ETH-style tokens).
- For USDC-style tokens (6 decimals), **1 USDC = 1_000_000**.
- If you use 18-decimal values (e.g., 1 ether = 1e18) with a 6-decimal token, tests will fail with `InvalidAmount` errors.
- Always check the token decimals and adjust all test values accordingly.
- Odds should always use 1e7 precision (e.g., 1.80 = 18_000_000). 