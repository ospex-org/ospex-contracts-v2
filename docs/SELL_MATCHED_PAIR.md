flowchart TD
    Start([User starts]) --> SellPosition[listPositionForSale]
    
    %% Initial Parameters
    SellPosition --> |"Params: <br>speculationId, <br>positionType, <br>price, <br>riskAmount, <br>profitAmount"| InitialValidations
    
    %% Combined Initial Validations
    InitialValidations --> Validations[Check all validations:<br>speculation is Open<br>position has risk amount<br>position not claimed<br>price > 0<br>amounts within position]
    
    %% Handle Validation Results
    Validations --> |"All validations pass"| CreateListing
    Validations --> |"Any validation fails"| RevertValidation[Revert: Various]
    
    %% Listing Creation
    CreateListing --> StoreListing[Store listing details<br>with listing hash]
    StoreListing --> EmitListed[Emit PositionListed event<br>includes listingHash]
    
    %% Wait for Purchase or Management
    EmitListed --> ListingOptions{What happens<br>to listing?}
    
    %% Path 1: Wait for Purchase
    ListingOptions --> |"Wait"| AwaitBuyer[Position remains listed]
    
    %% Path 2: Cancel Listing
    ListingOptions --> |"Cancel"| CancelListing[cancelListing]
    CancelListing --> CheckListing1[Verify:<br>caller owns position<br>listing exists & active<br>position not claimed]
    CheckListing1 --> |"Not found/inactive"| RevertNoListing[Revert: ListingNotActive]
    CheckListing1 --> |"Valid"| DeactivateListing[Delete listing]
    DeactivateListing --> EmitCancelled[Emit ListingCancelled]
    
    %% Path 3: Update Listing
    ListingOptions --> |"Update"| UpdateListing[updateListing]
    UpdateListing --> CheckListing2[Verify: speculation Open,<br>listing exists & active,<br>position not claimed]
    CheckListing2 --> |"Not found/inactive"| RevertUpdateInvalid[Revert: ListingNotActive]
    CheckListing2 --> |"Valid"| ValidateNewAmount[Validate new amounts<br>against position]
    
    ValidateNewAmount --> |"Invalid"| RevertUpdateAmount[Revert: AmountAboveMaximum]
    ValidateNewAmount --> |"Valid"| UpdateListingDetails[Update price, risk,<br>and profit amounts]
    UpdateListingDetails --> EmitUpdated[Emit ListingUpdated<br>includes new listingHash]
    
    %% Path 4: Someone Buys
    ListingOptions --> |"Buy"| BuyPosition[buyPosition]
    BuyPosition --> CheckBuy[Verify: speculation Open,<br>listing active, not own listing,<br>expectedHash matches current,<br>position not claimed]
    CheckBuy --> |"Hash mismatch"| RevertHash[Revert: ListingStateChanged]
    CheckBuy --> |"Valid"| ProcessBuy[Calculate proportional<br>profitAmount and price]
    ProcessBuy --> TransferUSDC[Transfer USDC from buyer<br>to contract]
    TransferUSDC --> TransferPosition[Transfer position via<br>PositionModule.transferPosition]
    TransferPosition --> UpdateOrDelete{Full or<br>partial buy?}
    UpdateOrDelete --> |"Full"| DeleteListing[Delete listing]
    UpdateOrDelete --> |"Partial"| ReduceListing[Reduce listing amounts<br>and price proportionally]
    DeleteListing & ReduceListing --> EmitSold[Emit PositionSold]
    
    %% Claim Proceeds
    EmitSold --> ClaimFlow[Seller calls claimSaleProceeds]
    ClaimFlow --> TransferProceeds[Transfer accumulated<br>USDC to seller]
    
    %% Style Definitions
    classDef function fill:#bbf,stroke:#333,stroke-width:2px
    classDef event fill:#bfb,stroke:#333,stroke-width:2px
    classDef error fill:#fbb,stroke:#333,stroke-width:2px
    classDef validation fill:#ddd,stroke:#333,stroke-width:2px
    classDef decision fill:#ffd,stroke:#333,stroke-width:2px
    
    class SellPosition,CancelListing,UpdateListing,BuyPosition,DeactivateListing,UpdateListingDetails,ProcessBuy,TransferUSDC,TransferPosition,ClaimFlow,TransferProceeds function
    class EmitListed,EmitCancelled,EmitUpdated,EmitSold event
    class RevertValidation,RevertNoListing,RevertUpdateInvalid,RevertUpdateAmount,RevertHash error
    class Validations,CheckListing1,CheckListing2,ValidateNewAmount,CheckBuy validation
    class ListingOptions,UpdateOrDelete decision
