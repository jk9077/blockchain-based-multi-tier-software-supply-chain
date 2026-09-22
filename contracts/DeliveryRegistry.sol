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
}
