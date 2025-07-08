flowchart TD
    Start([User starts]) --> CreateUnmatched[createUnmatchedPair]
    
    %% Initial Parameters
    CreateUnmatched --> |"Params: <br>speculationId, <br>amount, <br>odds, <br>positionType, <br>autoCancelAtStart, <br>acceptPartialFill, <br>contributionAmount"| InitialValidations
    
    %% All Initial Validations
    InitialValidations --> Validations[Check all validations:<br>speculation is Open<br>minimum amount<br>maximum amount<br>position doesn't exist<br>or is not claimed]
    
    %% Handle Validation Results
    Validations --> |"All validations pass"| TransferUSDC[Transfer USDC from user to contract]
    Validations --> |"Any validation fails"| RevertValidation[Revert: Various]
    
    %% USDC Transfer
    TransferUSDC --> |"Failure"| RevertTransfer[Revert: TransferFailed]
    TransferUSDC --> |"Success"| ValidateOdds[Validate odds range]
    
    %% Odds Validation and Pair Creation
    ValidateOdds --> |"Invalid"| RevertOdds[Revert: OddsOutOfRange]
    ValidateOdds --> |"1.01 to 101.00"| CheckExisting[Check existing odds pair]
    
    %% Check Existing Odds Pair
    CheckExisting --> |"Exists"| ReturnExisting[Return existing oddsPairId]
    CheckExisting --> |"Doesn't exist"| CalculateOdds[Calculate reciprocal odds<br>for opposite position]
    CalculateOdds --> CreatePair[Create new odds pair]
    
    %% Handle Contribution
    ReturnExisting & CreatePair --> HandleContribution{contributionAmount > 0?}
    
    HandleContribution --> |"Yes"| ProcessContribution[Process contribution]
    ProcessContribution --> |"Success"| EmitContribution[Emit ContributionMade]
    ProcessContribution --> |"Failure"| RevertContribution[Revert: TransferFailed]
    
    HandleContribution --> |"No"| CheckExistingPosition
    EmitContribution --> CheckExistingPosition
    
    %% Check Existing Position
    CheckExistingPosition{Existing position<br>with same type?} --> |"Yes"| RevertExists[Revert: PositionAlreadyExists]
    CheckExistingPosition --> |"No"| CreatePosition[Create new position]
    
    CreatePosition --> EmitCreated[Emit UnmatchedPairCreated]
    
    %% Position Management Options
    EmitCreated --> WaitForMatch{What next?}
    WaitForMatch --> |"Wait for match"| AwaitMatch[Position remains unmatched]
    WaitForMatch --> |"Adjust position"| AdjustFlow[adjustUnmatchedPair]
    
    %% Adjustment Flow Start
    AdjustFlow --> CheckUnmatchedAmount[Check speculation is open, position has unmatched amount and is unclaimed]
    CheckUnmatchedAmount --> |"No amount"| RevertNoUnmatched[Revert: Various]
    
    %% Auto-cancel check first
    CheckUnmatchedAmount --> |"Has amount, speculation is open"| CheckAutoCancel{Game started &<br>auto-cancel active?}
    CheckAutoCancel --> |"Yes"| WithdrawAll[Withdraw entire amount]
    WithdrawAll --> EmitAutoCancel[Emit UnmatchedPairAmountAdjusted]
    EmitAutoCancel --> Done([Done])
    
    %% If not auto-cancelled, proceed with changes
    CheckAutoCancel --> |"No"| AdjustUnmatched{What changes<br>to make?}
    
    %% Path 1: Flags Only
    AdjustUnmatched --> |"Flags only"| UpdateFlags[Update autoCancelAtStart<br>and/or acceptPartialFill]
    UpdateFlags --> EmitFlags[Emit PositionFlagsUpdated]
    EmitFlags --> Done
    
    %% Path 2: Amount Only
    AdjustUnmatched --> |"Amount only"| ProcessAmount[Process amount changes]
    
    %% Path 3: Both Flags and Amount
    AdjustUnmatched --> |"Both flags<br>and amount"| UpdateFlags2[Update autoCancelAtStart<br>and/or acceptPartialFill]
    UpdateFlags2 --> EmitFlags2[Emit PositionFlagsUpdated]
    EmitFlags2 --> ProcessAmount
    
    ProcessAmount --> |"amount > 0"| Deposit[Transfer USDC from user]
    ProcessAmount --> |"amount < 0"| ValidateAmount[Validate withdrawal amount]
    
    Deposit --> TransferIn[Add to position]
    ValidateAmount --> |"amount > unmatched"| RevertTooMuch[Revert: AmountAboveMaximum]
    ValidateAmount --> |"amount <= unmatched"| UpdatePosition[Reduce unmatched amount]
    UpdatePosition --> TransferOut[Transfer USDC to user]
    
    TransferIn & TransferOut --> EmitAmount[Emit UnmatchedPairAmountAdjusted]
    EmitAmount --> Done
    
    %% Style Definitions
    classDef function fill:#bbf,stroke:#333,stroke-width:2px
    classDef event fill:#bfb,stroke:#333,stroke-width:2px
    classDef error fill:#fbb,stroke:#333,stroke-width:2px
    classDef validation fill:#ddd,stroke:#333,stroke-width:2px
    classDef decision fill:#ffd,stroke:#333,stroke-width:2px
    
    class CreateUnmatched,ProcessContribution,TransferUSDC,CalculateOdds,CreatePair,UpdatePosition,CreatePosition,WithdrawAll,UpdateFlags,Deposit,Withdraw function
    class EmitCreated,EmitContribution,EmitFlags,EmitAmount,EmitAutoCancel,EmitFlags2 event
    class RevertTransfer,RevertOdds,RevertContribution,RevertNoUnmatched,RevertTooMuch,RevertValidation,RevertExists error
    class Validations,ValidateOdds,CheckUnmatchedAmount,ValidateAmount validation
    class HandleContribution,WaitForMatch,CheckAutoCancel,AdjustUnmatched,CheckExistingPosition decision