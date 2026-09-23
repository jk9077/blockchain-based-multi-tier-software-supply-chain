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

contract DeliveryRegistryTest {
    function test_AdminCanAllowRoute() public {
        DeliveryRegistry registry = new DeliveryRegistry();

        address supplier = address(0x1001);
        address receiver = address(0x1002);

        registry.allowRoute(supplier, receiver);

        require(
            registry.allowedRoutes(supplier, receiver),
            "Admin should be able to register route"
        );
    }

    function test_NonAdminCannotAllowRoute() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        OtherCaller other = new OtherCaller();

        address supplier = address(0x1001);
        address receiver = address(0x1002);
        bool blocked = false;

        try other.allowRoute(registry, supplier, receiver) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked =
                keccak256(bytes(reason)) == keccak256(bytes("Only admin"));
        }

        require(blocked, "Non-admin should be blocked");

        require(
            !registry.allowedRoutes(supplier, receiver),
            "Unauthorized route should not be registered"
        );
    }
}
