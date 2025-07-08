flowchart TD
    Start([User starts]) --> CompleteUnmatched[completeUnmatchedPair]
    
    %% Initial Parameters
    CompleteUnmatched --> |"Params: <br>speculationId, <br>oddsPairId, <br>maker, <br>amount, <br>positionType"| InitialValidations
    
    %% Initial Validations
    InitialValidations --> CheckSpecOpen[Check speculation is Open]
    InitialValidations --> CheckAutoCancel[Check auto-cancel not triggered]
    InitialValidations --> CheckAmount[Check amount validations]
    InitialValidations --> CheckClaimed[Check position not claimed]
    
    %% Amount Validations
    CheckAmount --> CheckMin[Check minimum amount]
    CheckAmount --> CheckMax[Check maximum amount]
    
    %% Maker Position Validation
    CheckSpecOpen & CheckAutoCancel & CheckMin & CheckMax & CheckClaimed --> ValidateMaker[Validate maker's position]
    ValidateMaker --> CheckUnmatched[Check maker has enough<br>unmatched amount]
    
    CheckUnmatched --> |"Insufficient"| RevertNoMatch[Revert: NoMatchingPosition]
    CheckUnmatched --> |"Sufficient"| CheckPartialFill[Check if partial fill<br>is allowed]
    
    CheckPartialFill --> |"Not allowed & partial"| RevertPartial[Revert: PartialFillNotAccepted]
    CheckPartialFill --> |"Allowed or full"| TransferUSDC[Transfer USDC from user to contract]
    
    %% USDC Transfer
    TransferUSDC --> |"Failure"| RevertTransfer[Revert: TransferFailed]
    TransferUSDC --> |"Success"| UpdateMaker[Update maker position:<br>+matched, -unmatched]
    
    %% Position Updates
    UpdateMaker --> CheckExisting{Existing taker<br>position?}
    CheckExisting --> |"Yes"| CheckType{Same position<br>type?}
    
    CheckType --> |"Yes"| CombinePosition[Add to existing position:<br>+matched amount]
    CheckType --> |"No"| CreateNew[Create new position]
    
    CheckExisting --> |"No"| CreateNew
    
    CreateNew --> StorePosition[Store new position]
    
    %% Event Emission
    CombinePosition & StorePosition --> EmitCompleted[Emit UnmatchedPairCompleted event]
    
    %% Style Definitions
    classDef function fill:#bbf,stroke:#333,stroke-width:2px
    classDef event fill:#bfb,stroke:#333,stroke-width:2px
    classDef error fill:#fbb,stroke:#333,stroke-width:2px
    classDef validation fill:#ddd,stroke:#333,stroke-width:2px
    classDef decision fill:#ffd,stroke:#333,stroke-width:2px
    
    class CompleteUnmatched,UpdateMaker,CombinePosition,CreateNew function
    class EmitCompleted event
    class RevertNoMatch,RevertTransfer,RevertPartial error
    class CheckSpecOpen,CheckAutoCancel,CheckAmount,CheckMin,CheckMax,CheckUnmatched,CheckPartialFill,CheckClaimed,ValidateMaker validation
    class CheckExisting,CheckType decision