flowchart TD
    Start([User starts]) --> SellPosition[listPositionForSale]
    
    %% Initial Parameters
    SellPosition --> |"Params: <br>speculationId, <br>oddsPairId, <br>saleOdds, <br>price, <br>amount, <br>contributionAmount"| InitialValidations
    
    %% Combined Initial Validations
    InitialValidations --> Validations[Check all validations:<br>speculation is Active<br>position has matched amount<br>position not claimed<br>price > 0<br>auto-cancel not active]
    
    %% Handle Validation Results
    Validations --> |"All validations pass"| ValidateAmount
    Validations --> |"Any validation fails"| RevertValidation[Revert: Various]
    
    %% Amount Validation
    ValidateAmount --> |"amount = 0"| UseFullAmount[Use full matched amount]
    ValidateAmount --> |"amount > 0"| CheckAmount[Validate against<br>matched amount<br>and minimum sale]
    
    CheckAmount --> |"Invalid"| RevertAmount[Revert: AmountInvalid]
    CheckAmount --> |"Valid"| HandleContribution{contributionAmount > 0?}
    UseFullAmount --> HandleContribution
    
    %% Contribution Processing
    HandleContribution --> |"Yes"| ProcessContribution[Process contribution]
    ProcessContribution --> |"Success"| EmitContribution[Emit SecondaryContributionMade]
    ProcessContribution --> |"Failure"| RevertContribution[Revert: TransferFailed]
    
    HandleContribution --> |"No"| CreateListing
    EmitContribution --> CreateListing
    
    %% Listing Creation
    CreateListing --> StoreListing[Store listing details]
    StoreListing --> EmitListed[Emit PositionListed event]
    
    %% Wait for Purchase or Management
    EmitListed --> ListingOptions{What happens<br>to listing?}
    
    %% Path 1: Wait for Purchase
    ListingOptions --> |"Wait"| AwaitBuyer[Position remains listed]
    
    %% Path 2: Cancel Listing
    ListingOptions --> |"Cancel"| CancelListing[cancelSaleListing]
    CancelListing --> CheckListing1[Verify:<br>caller owns position<br>listing exists & active]
    CheckListing1 --> |"Not found/inactive"| RevertNoListing[Revert: ListingNotActive]
    CheckListing1 --> |"Valid"| DeactivateListing[Delete listing]
    DeactivateListing --> EmitCancelled[Emit ListingCancelled]
    
    %% Path 3: Update Listing
    ListingOptions --> |"Update"| UpdateListing[updateSaleListing]
    UpdateListing --> CheckListing2[Verify: caller owns position, listing exists, is active and unclaimed]
    CheckListing2 --> |"Not found/inactive"| RevertUpdateInvalid[Revert: ListingNotActive]
    CheckListing2 --> |"Valid"| ValidateNewAmount[Validate new amount]
    
    ValidateNewAmount --> |"Invalid"| RevertUpdateAmount[Revert: AmountInvalid]
    ValidateNewAmount --> |"Valid"| UpdateListingDetails[Update price and amount]
    UpdateListingDetails --> EmitUpdated[Emit ListingUpdated]
    
    %% Style Definitions
    classDef function fill:#bbf,stroke:#333,stroke-width:2px
    classDef event fill:#bfb,stroke:#333,stroke-width:2px
    classDef error fill:#fbb,stroke:#333,stroke-width:2px
    classDef validation fill:#ddd,stroke:#333,stroke-width:2px
    classDef decision fill:#ffd,stroke:#333,stroke-width:2px
    
    class SellPosition,ProcessContribution,CreateListing,CancelListing,UpdateListing,DeactivateListing,UpdateListingDetails function
    class EmitListed,EmitContribution,EmitCancelled,EmitUpdated event
    class RevertValidation,RevertContribution,RevertAmount,RevertNoListing,RevertUpdateInvalid,RevertUpdateAmount error
    class Validations,CheckAmount,CheckOwner1,CheckOwner2,CheckListingExists,ValidateUpdate,ValidateNewAmount validation
    class HandleContribution,ValidateAmount,ListingOptions decision