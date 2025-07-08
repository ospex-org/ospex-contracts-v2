// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PositionModule} from "../../src/modules/PositionModule.sol";
import {PositionType} from "../../src/core/OspexTypes.sol";

contract MockMarket {
    PositionModule public immutable positionModule;
    
    event PositionListed(
        uint256 speculationId,
        address indexed seller,
        uint128 oddsPairId,
        PositionType positionType,
        uint8 repeatIndex,
        uint256 amount,
        uint64 saleOdds,
        uint256 price,
        uint256 timestamp
    );

    constructor(address _positionModule) {
        positionModule = PositionModule(_positionModule);
    }

    function transferPosition(
        uint256 speculationId,
        address from,
        uint128 oddsPairId,
        PositionType positionType,
        address to,
        uint256 amount
    ) external {
        positionModule.transferPosition(
            speculationId,
            from,
            oddsPairId,
            positionType,
            to,
            amount
        );
    }
    
    function listPositionForSale(
        uint256 speculationId,
        uint128 oddsPairId,
        PositionType positionType,
        uint8 repeatIndex,
        uint64 saleOdds,
        uint256 price,
        uint256 amount,
        uint256 
    ) external {
        positionModule.getPosition(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType
        );
        emit PositionListed(
            speculationId,
            msg.sender,
            oddsPairId,
            positionType,
            repeatIndex,
            amount,
            saleOdds,
            price,
            block.timestamp
        );
    }
} 