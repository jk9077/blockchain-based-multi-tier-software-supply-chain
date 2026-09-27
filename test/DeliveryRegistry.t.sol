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

contract DeliverySupplier {
    function submit(
        DeliveryRegistry registry,
        address receiver,
        string calldata productName,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash
    ) external returns (uint256) {
        return
            registry.submitDelivery(
                receiver,
                productName,
                version,
                sbomHash,
                fileHash
            );
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
    function test_AllowedSupplierCanSubmitDelivery() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();
        address receiver = address(0x2001);

        bytes32 sbomHash = keccak256("sample SBOM");
        bytes32 fileHash = keccak256("sample artifact");

        registry.allowRoute(address(supplier), receiver);

        uint256 deliveryId = supplier.submit(
            registry,
            receiver,
            "Payment Module",
            "1.0.0",
            sbomHash,
            fileHash
        );

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryId
        );

        require(deliveryId == 1, "Delivery Id should be 1");
        require(registry.deliveryCount() == 1, "Delivery count should be 1");
        require(saved.supplier == address(supplier), "Wrong supplier");
        require(saved.receiver == receiver, "Wrong receiver");

        require(
            keccak256(bytes(saved.productName)) ==
                keccak256(bytes("Payment Module")),
            "Wrong product name"
        );

        require(
            keccak256(bytes(saved.version)) == keccak256(bytes("1.0.0")),
            "Wrong version"
        );

        require(saved.sbomHash == sbomHash, "Wrong SBOM hash");
        require(saved.fileHash == fileHash, "Wrong file hash");
        require(
            saved.status == DeliveryRegistry.Status.Pending,
            "Wrong status"
        );
        require(saved.submittedAt == block.timestamp, "Wrong submission time");
        require(saved.reviewedAt == 0, "Should not be reviewed yet");
    }

    function test_UnregisteredSupplierCannotSubmit() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();
        bool blocked = false;

        try
            supplier.submit(
                registry,
                address(0x2001),
                "Payment Module",
                "1.0.0",
                sha256(bytes("sample SBOM")),
                sha256(bytes("sample artifact"))
            )
        returns (uint256) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked =
                keccak256(bytes(reason)) ==
                keccak256(bytes("Route not allowed"));
        }
        require(blocked, "Unregistered supplier should be blocked");
        require(
            registry.deliveryCount() == 0,
            "Delivery count should remain 0"
        );
    }

    function test_NoexistentDeliveryCannotBeRead() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        bool blocked = false;

        try registry.getDelivery(1) returns (DeliveryRegistry.Delivery memory) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked =
                keccak256(bytes(reason)) ==
                keccak256(bytes("Delivery not found"));
        }

        require(
            blocked,
            "Should not be able to retrieve non-existent delivery"
        );
    }
}
