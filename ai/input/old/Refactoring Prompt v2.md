# Solidity Dapp Refactoring Task

## Context
I have a Solidity sports betting dapp (Ospex) with a peer-to-peer orderbook structure that is exceeding the EVM byte compile size limit. I need to refactor the entire project to reduce its size while maintaining functionality.

## Current Architecture
The current architecture consists of:

1. **src/core folder**:
   - **OspexContestManager.sol**: Responsible for contest management (games, top level of the hierarchy)
   - **OspexSpeculationManager.sol**: Manages speculations (individual things users can bet on, such as team A beating team B, moneyline bets, total points over/under)
   - **OspexPositionManager.sol**: Handles position management (creating unmatched pairs, matching positions, claiming)
   - **OspexBulkPositionManagement.sol**: Manages bulk position actions (matching multiple positions, combining positions)
   - **OspexTypes.sol**: Contains reusable types (Speculation struct, Position struct, etc.)

2. **src/interfaces folder**: Contains appropriate interface files

3. **src/market folder**:
   - **OspexSecondaryMarket.sol**: Manages functions for selling matched positions on the secondary market

4. **src/scoring folder**: Contains three files which manage different bet types:
   - Spread bets
   - Moneyline bets
   - Total bets

## Pain Points & Requirements
- The main issue is hitting EVM byte size limits
- The codebase works but is disorganized due to moving code around to make it compile
- Some bloat and redundancy where multiple contracts need the same internal functions
- Most processing and matching should occur on the front end to save gas, but contracts should allow direct interaction

## External Dependencies
- Chainlink Functions and the Decentralized Oracle Network (code related to these can be moved and/or modularized if it's the best option)
- OpenZeppelin imports

## Additional Clarifications
- **Interfaces vs. Abstract Contracts**: Prefer using interfaces over abstract contracts, but abstract contracts can be recommended if they're the best solution for the architecture
- **Front-End Processing**: Simple modularization is preferred, only restricting functionality for security reasons
- **Redundancy and Internal Functions**: Focus on general patterns for deduplication and modularity
- **Upgradeability**: Very low priority - strongly against proxy patterns and upgradable contracts due to security concerns and user trust issues
- **Cross-Chain Extensibility**: Simply note where cross-chain support could be added in the future

## Requirements
- Suggest a refactored architecture using interfaces (not libraries or proxy patterns)
- Create a modular, clean, and elegant design
- Organize functions, mappings, and variables logically across multiple files
- Follow established patterns similar to DeFi protocols where appropriate
- Provide thorough documentation for each component
- Follow the Solidity style guide (https://docs.soliditylang.org/en/latest/style-guide.html)
- Maintain the current naming conventions where appropriate
- Prioritize security throughout the design
- Focus on EVM-compatible chains (cross-chain extensibility is a low priority)

## Output Format
Please provide THREE distinct architectural approaches for refactoring this project. For each approach:

1. **Overview**: Explain the architectural pattern and its benefits for this specific use case
2. **File Structure**: List all necessary files with their paths
3. **Component Breakdown**: For each file, specify:
   - Purpose/responsibility in the system
   - Required variables
   - Required mappings
   - Required functions (names only, no implementations)
   - Interfaces to implement or extend
4. **Data Flow**: Explain how the components interact during key operations (contest creation, bet placement, matching, claiming, etc.)

Present your analysis in the following markdown format for each file:

```
## {file_path}

### Purpose
[Brief explanation of this component's role]

### Variables
- variableName: [brief purpose]
- ...

### Mappings
- mappingName: [brief purpose]
- ...

### Functions
- functionName: [brief purpose]
- ...

### Interfaces
- interfaceName: [brief purpose]
- ...
```

## Analysis Guidance
- Focus on clean separation of concerns
- Place related functionality together
- Consider gas optimization in your design
- Prioritize maintainability, security, and readability
- Keep each contract's responsibility narrow and focused
- Use events appropriately for off-chain indexing
- Determine which functions, mappings, and variables should be moved to which contracts to optimize for EVM byte size
- Identify where code duplication can be eliminated through better architecture
- Consider how to modularize Chainlink-related code without changing its functionality
- Explicitly avoid upgrade patterns that could raise security concerns among users
- Pay special attention to breaking up large contracts into smaller, more focused ones to address byte size limits

Please output your response to: ai\chat