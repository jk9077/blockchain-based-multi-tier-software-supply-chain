// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeliveryRegistry} from "../contracts/DeliveryRegistry.sol";

contract OtherCaller {
    function allowRoute(
        DeliveryRegistry registry,
        address supplier,
        address receiver
    ) external {
        registry.allowRoute(supplier, receiver);
    }
}
