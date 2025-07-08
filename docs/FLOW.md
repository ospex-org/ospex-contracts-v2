flowchart TD
    User[Sports Bettor] --> Choice{Ospex Matched Pair System<br>What do you want to do?}
    
    Choice --> Take[Complete Unmatched Pair<br>Take Best Available Odds]
    Choice --> Create[Create Unmatched Pair<br>Create New Bet]
    Choice --> Sell[Sell Matched Pair<br>User Sells Position]
    
    Take --> ViewOdds[View Current Odds<br>e.g. Chiefs @1.80]
    ViewOdds --> MatchNow[Match Existing Position<br>Guaranteed Odds]
    MatchNow --> Matched[Position Matched<br>Odds Locked In]
    
    Create --> SetOdds[Set Desired Odds<br>e.g. Chiefs @1.90]
    SetOdds --> |"Optional:<br>Make Contribution<br>for Priority Listing"| Wait[Wait for Match<br>or Cancel/Adjust]
    Wait -->|Someone Matches| Matched
    Wait --> |No Match| Awaiting{Cancel, Adjust,<br>or Wait}
    Awaiting -->|Adjust Odds| SetOdds
    Awaiting -->|Cancel| Return[Get Tokens Back]
    Awaiting -->|Auto-Cancel at Game Start<br>Defaults to True| AutoReturn[Get Tokens Back at Game Start]
    
    Sell --> ListPosition[List Position for Sale]
    ListPosition --> |"Optional:<br>Make Contribution<br>for Priority Listing"| SaleWait{Waiting for Buyer}
    SaleWait -->|Full Sale| FullSold[Position Fully Sold]
    SaleWait -->|Partial Sale| PartialSold[Position Partially Sold]
    SaleWait -->|Not Sold| ManageListing{Manage Listing}
    ManageListing -->|Update Price| ListPosition
    ManageListing -->|Cancel| Keep[Keep Position]
    FullSold & PartialSold --> ClaimProceeds[Claim Sale Proceeds]

    style User fill:#9bf,stroke:#333,stroke-width:4px
    style Matched fill:#9f9,stroke:#333,stroke-width:2px
    style ClaimProceeds fill:#9f9,stroke:#333,stroke-width:2px
    style Return fill:#ff9,stroke:#333,stroke-width:2px
    style AutoReturn fill:#ff9,stroke:#333,stroke-width:2px
    style Awaiting fill:#c98,stroke:#333,stroke-width:2px