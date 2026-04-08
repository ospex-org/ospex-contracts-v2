// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PositionModule} from "../../src/modules/PositionModule.sol";
import {PositionType} from "../../src/core/OspexTypes.sol";

contract MockMarket {
    PositionModule public immutable positionModule;

    constructor(address _positionModule) {
        positionModule = PositionModule(_positionModule);
    }

    function transferPosition(
        uint256 speculationId,
        address from,
        PositionType positionType,
        address to,
        uint256 riskAmount,
        uint256 profitAmount
    ) external {
        positionModule.transferPosition(
            speculationId,
            from,
            positionType,
            to,
            riskAmount,
            profitAmount
        );
    }
}
