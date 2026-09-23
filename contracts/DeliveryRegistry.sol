// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract DeliveryRegistry {
    enum Status {
        Pending,
        Approved,
        Rejected
    }

    struct Delivery {
        address supplier;
        address receiver;
        string productName;
        string version;
        bytes32 sbomHash;
        bytes32 fileHash;
        Status status;
        uint256 submittedAt;
        uint256 reviewedAt;
    }

    address public immutable admin;
    uint256 public deliveryCount;

    mapping(uint256 => Delivery) public deliveries;
    mapping(address => mapping(address => bool)) public allowedRoutes;

    event RouteAllowed(address indexed supplier, address indexed receiver);

    event DeliverySubmitted(
        uint256 indexed deliveryId,
        address indexed supplier,
        address indexed receiver
    );

    event DeliverReviewed(
        uint256 indexed deliveryId,
        address indexed reviewer,
        Status status
    );

    constructor() {
        admin = msg.sender;
    }

    function allowRoute(address supplier, address receiver) external {
        require(msg.sender == admin, "Only admin");
        require(
            supplier != address(0) && receiver != address(0),
            "Invalid address"
        );
        require(
            supplier != receiver,
            "Supplier and receiver cannot be the same"
        );
        require(!allowedRoutes[supplier][receiver], "Route already allowed");
        allowedRoutes[supplier][receiver] = true;

        emit RouteAllowed(supplier, receiver);
    }

    function submitDelivery(
        address receiver,
        string calldata productName,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash
    ) external returns (uint256) {
        require(allowedRoutes[msg.sender][receiver], "Route not allowed");
        require(bytes(productName).length > 0, "Product name required");
        require(bytes(version).length > 0, "Version required");
        require(sbomHash != bytes32(0), "SBOM hash required");
        require(fileHash != bytes32(0), "File hash required");

        deliveryCount++;
        uint256 deliveryId = deliveryCount;

        deliveries[deliveryId] = Delivery({
            supplier: msg.sender,
            receiver: receiver,
            productName: productName,
            version: version,
            sbomHash: sbomHash,
            fileHash: fileHash,
            status: Status.Pending,
            submittedAt: block.timestamp,
            reviewedAt: 0
        });

        emit DeliverySubmitted(deliveryId, msg.sender, receiver);

        return deliveryId;
    }
}
