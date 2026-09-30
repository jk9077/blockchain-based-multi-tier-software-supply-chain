// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeliveryRegistry} from "../contracts/DeliveryRegistry.sol";

contract OtherCaller {
    function allowRoute(
        DeliveryRegistry registry,
        uint256 projectId,
        address supplier,
        address receiver,
        uint256 stage
    ) external {
        registry.allowRoute(projectId, supplier, receiver, stage);
    }
}

contract DeliverySupplier {
    function submit(
        DeliveryRegistry registry,
        uint256 projectId,
        address receiver,
        string calldata productName,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash,
        uint256[] calldata previousIds
    ) external returns (uint256) {
        return
            registry.submitDelivery(
                projectId,
                receiver,
                productName,
                version,
                sbomHash,
                fileHash,
                previousIds
            );
    }
}

contract DeliveryReceiver is DeliverySupplier {
    function review(
        DeliveryRegistry registry,
        uint256 deliveryId,
        DeliveryRegistry.Status status
    ) external {
        registry.reviewDelivery(deliveryId, status);
    }
}

contract DeliveryRegistryTest {
    function test_AdminCanAllowRoute() public {
        DeliveryRegistry registry = new DeliveryRegistry();

        uint256 projectId = registry.createProject("Project A");

        address supplier = address(0x1001);
        address receiver = address(0x1002);

        registry.allowRoute(projectId, supplier, receiver, 1);

        require(registry.admin() == address(this), "Wrong admin");
        require(projectId == 1, "Project ID should be 1");
        require(registry.projectCount() == 1, "Wrong project count");

        require(
            registry.allowedRoutes(projectId, supplier, receiver),
            "Admin should be able to register route"
        );

        require(
            registry.routeStages(projectId, supplier, receiver) == 1,
            "Wrong route stage"
        );
    }

    function test_NonAdminCannotAllowRoute() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        OtherCaller other = new OtherCaller();

        uint256 projectId = registry.createProject("Project A");

        address supplier = address(0x1001);
        address receiver = address(0x1002);

        bool blocked = false;

        try other.allowRoute(registry, projectId, supplier, receiver, 1) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(reason, "Only admin");
        }

        require(blocked, "Non-admin should be blocked");

        require(
            !registry.allowedRoutes(projectId, supplier, receiver),
            "Unauthorized route should not be registered"
        );

        require(
            registry.routeStages(projectId, supplier, receiver) == 0,
            "Unauthorized stage should not be registered"
        );
    }

    function test_AllowedSupplierCanSubmitDelivery() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();

        uint256 projectId = registry.createProject("Project A");
        address receiver = address(0x2001);

        bytes32 sbomHash = keccak256(bytes("sample SBOM"));
        bytes32 fileHash = keccak256(bytes("sample artifact"));

        registry.allowRoute(projectId, address(supplier), receiver, 1);

        uint256 deliveryId = supplier.submit(
            registry,
            projectId,
            receiver,
            "Payment Module",
            "1.0.0",
            sbomHash,
            fileHash,
            new uint256[](0)
        );

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryId
        );

        require(deliveryId == 1, "Delivery ID should be 1");
        require(registry.deliveryCount() == 1, "Wrong delivery count");
        require(saved.projectId == projectId, "Wrong project");
        require(saved.stage == 1, "Wrong stage");
        require(saved.stageDeliveryNumber == 1, "Wrong stage sequence");
        require(saved.supplier == address(supplier), "Wrong supplier");
        require(saved.receiver == receiver, "Wrong receiver");

        require(
            _same(saved.productName, "Payment Module"),
            "Wrong product name"
        );

        require(_same(saved.version, "1.0.0"), "Wrong version");
        require(saved.sbomHash == sbomHash, "Wrong SBOM hash");
        require(saved.fileHash == fileHash, "Wrong file hash");

        require(
            saved.status == DeliveryRegistry.Status.Pending,
            "Wrong status"
        );

        require(saved.submittedAt == block.timestamp, "Wrong submission time");
        require(saved.reviewedAt == 0, "Should not be reviewed yet");

        require(
            registry.projectDeliveryCounts(projectId) == 1,
            "Wrong project delivery count"
        );

        require(
            registry.stageDeliveryCounts(projectId, 1) == 1,
            "Wrong stage delivery count"
        );

        require(
            registry.getDeliveryId(projectId, 1, 1) == deliveryId,
            "Wrong delivery lookup"
        );

        require(
            registry.getPreviousDeliveryIds(deliveryId).length == 0,
            "Previous deliveries should be empty"
        );
    }

    function test_UnregisteredSupplierCannotSubmit() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();

        uint256 projectId = registry.createProject("Project A");
        bool blocked = false;

        try
            supplier.submit(
                registry,
                projectId,
                address(0x2001),
                "Payment Module",
                "1.0.0",
                keccak256(bytes("sample SBOM")),
                keccak256(bytes("sample artifact")),
                new uint256[](0)
            )
        returns (uint256) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(reason, "Route not allowed");
        }

        require(blocked, "Unregistered supplier should be blocked");
        require(
            registry.deliveryCount() == 0,
            "Delivery count should remain 0"
        );

        require(
            registry.projectDeliveryCounts(projectId) == 0,
            "Project delivery count should remain 0"
        );
    }

    function test_NonexistentDeliveryCannotBeRead() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        bool blocked = false;

        try registry.getDelivery(1) returns (DeliveryRegistry.Delivery memory) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(reason, "Delivery not found");
        }

        require(blocked, "Nonexistent delivery should not be readable");
    }

    function test_ReceiverCanReviewDelivery() public {
        (
            DeliveryRegistry registry,
            DeliveryReceiver receiver,
            uint256 deliveryId
        ) = _reviewSetup();

        receiver.review(registry, deliveryId, DeliveryRegistry.Status.Approved);

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryId
        );

        require(
            saved.status == DeliveryRegistry.Status.Approved,
            "Delivery should be approved"
        );

        require(saved.reviewedAt == block.timestamp, "Wrong review time");
    }

    function test_ReceiverCanRejectDelivery() public {
        (
            DeliveryRegistry registry,
            DeliveryReceiver receiver,
            uint256 deliveryId
        ) = _reviewSetup();

        receiver.review(registry, deliveryId, DeliveryRegistry.Status.Rejected);

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryId
        );

        require(
            saved.status == DeliveryRegistry.Status.Rejected,
            "Delivery should be rejected"
        );

        require(saved.reviewedAt == block.timestamp, "Wrong review time");
    }

    function test_OtherCompanyCannotReviewDelivery() public {
        (
            DeliveryRegistry registry,
            DeliveryReceiver receiver,
            uint256 deliveryId
        ) = _reviewSetup();

        DeliveryReceiver other = new DeliveryReceiver();
        bool blocked = false;

        try
            other.review(registry, deliveryId, DeliveryRegistry.Status.Approved)
        {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(reason, "Only receiver can review");
        }

        require(blocked, "Other company should not review");

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryId
        );

        require(
            saved.receiver == address(receiver),
            "Receiver should not change"
        );

        require(
            saved.status == DeliveryRegistry.Status.Pending,
            "Status should remain pending"
        );

        require(saved.reviewedAt == 0, "Review time should remain 0");
    }

    function test_ReviewedDeliveryCannotBeReviewedAgain() public {
        (
            DeliveryRegistry registry,
            DeliveryReceiver receiver,
            uint256 deliveryId
        ) = _reviewSetup();

        receiver.review(registry, deliveryId, DeliveryRegistry.Status.Approved);

        uint256 reviewedAt = registry.getDelivery(deliveryId).reviewedAt;
        bool blocked = false;

        try
            receiver.review(
                registry,
                deliveryId,
                DeliveryRegistry.Status.Rejected
            )
        {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(reason, "Delivery already reviewed");
        }

        require(blocked, "Repeated review should be blocked");

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryId
        );

        require(
            saved.status == DeliveryRegistry.Status.Approved,
            "Approved status should remain"
        );

        require(
            saved.reviewedAt == reviewedAt,
            "Review time should not change"
        );
    }

    function test_StageNumbersAndPreviousDeliveries() public {
        DeliveryRegistry registry = new DeliveryRegistry();

        uint256 projectId = registry.createProject("Project A");

        DeliverySupplier supplierD = new DeliverySupplier();
        DeliverySupplier supplierE = new DeliverySupplier();
        DeliveryReceiver companyC = new DeliveryReceiver();
        DeliveryReceiver companyB = new DeliveryReceiver();

        registry.allowRoute(
            projectId,
            address(supplierD),
            address(companyC),
            1
        );

        registry.allowRoute(
            projectId,
            address(supplierE),
            address(companyC),
            1
        );

        registry.allowRoute(projectId, address(companyC), address(companyB), 2);

        uint256 deliveryD = _submit(
            registry,
            supplierD,
            projectId,
            address(companyC),
            new uint256[](0)
        );

        uint256 deliveryE = _submit(
            registry,
            supplierE,
            projectId,
            address(companyC),
            new uint256[](0)
        );

        companyC.review(registry, deliveryD, DeliveryRegistry.Status.Approved);

        companyC.review(registry, deliveryE, DeliveryRegistry.Status.Approved);

        uint256[] memory previousIds = new uint256[](2);
        previousIds[0] = deliveryD;
        previousIds[1] = deliveryE;

        uint256 deliveryC = _submit(
            registry,
            companyC,
            projectId,
            address(companyB),
            previousIds
        );

        DeliveryRegistry.Delivery memory saved = registry.getDelivery(
            deliveryC
        );

        require(saved.stage == 2, "Wrong stage");
        require(saved.stageDeliveryNumber == 1, "Stage 2 should start at 1");

        require(
            registry.getDeliveryId(projectId, 1, 1) == deliveryD,
            "Wrong P001-1-01 mapping"
        );

        require(
            registry.getDeliveryId(projectId, 1, 2) == deliveryE,
            "Wrong P001-1-02 mapping"
        );

        require(
            registry.getDeliveryId(projectId, 2, 1) == deliveryC,
            "Wrong P001-2-01 mapping"
        );

        uint256[] memory savedIds = registry.getPreviousDeliveryIds(deliveryC);

        require(savedIds.length == 2, "Wrong previous delivery count");
        require(savedIds[0] == deliveryD, "Wrong first previous delivery");
        require(savedIds[1] == deliveryE, "Wrong second previous delivery");

        require(
            registry.projectDeliveryCounts(projectId) == 3,
            "Wrong project delivery count"
        );

        require(
            registry.stageDeliveryCounts(projectId, 1) == 2,
            "Wrong stage 1 count"
        );

        require(
            registry.stageDeliveryCounts(projectId, 2) == 1,
            "Wrong stage 2 count"
        );
    }

    function test_ProjectsHaveSeparateRoutesAndNumbers() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();

        uint256 projectA = registry.createProject("Project A");
        uint256 projectB = registry.createProject("Project B");

        address receiver = address(0x2001);

        registry.allowRoute(projectA, address(supplier), receiver, 1);

        uint256 deliveryA = _submit(
            registry,
            supplier,
            projectA,
            receiver,
            new uint256[](0)
        );

        bool blocked = false;

        try
            supplier.submit(
                registry,
                projectB,
                receiver,
                "Payment Module",
                "1.0.0",
                keccak256(bytes("sample SBOM")),
                keccak256(bytes("sample artifact")),
                new uint256[](0)
            )
        returns (uint256) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(reason, "Route not allowed");
        }

        require(blocked, "Project A route must not authorize project B");

        registry.allowRoute(projectB, address(supplier), receiver, 1);

        uint256 deliveryB = _submit(
            registry,
            supplier,
            projectB,
            receiver,
            new uint256[](0)
        );

        require(deliveryA != deliveryB, "Global IDs must be different");
        require(registry.deliveryCount() == 2, "Wrong global delivery count");

        require(
            registry.getDeliveryId(projectA, 1, 1) == deliveryA,
            "Wrong project A lookup"
        );

        require(
            registry.getDeliveryId(projectB, 1, 1) == deliveryB,
            "Wrong project B lookup"
        );

        require(
            registry.stageDeliveryCounts(projectA, 1) == 1,
            "Wrong project A sequence"
        );

        require(
            registry.stageDeliveryCounts(projectB, 1) == 1,
            "Wrong project B sequence"
        );
    }

    function test_PreviousDeliveryFromAnotherProjectCannotBeLinked() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();
        DeliveryReceiver companyC = new DeliveryReceiver();

        uint256 projectA = registry.createProject("Project A");
        uint256 projectB = registry.createProject("Project B");

        address receiver = address(0x3001);

        registry.allowRoute(projectA, address(supplier), address(companyC), 1);

        registry.allowRoute(projectB, address(companyC), receiver, 2);

        uint256 previousId = _submit(
            registry,
            supplier,
            projectA,
            address(companyC),
            new uint256[](0)
        );

        companyC.review(registry, previousId, DeliveryRegistry.Status.Approved);

        uint256[] memory previousIds = new uint256[](1);
        previousIds[0] = previousId;

        bool blocked = false;

        try
            companyC.submit(
                registry,
                projectB,
                receiver,
                "Integrated Module",
                "1.0.0",
                keccak256(bytes("integrated SBOM")),
                keccak256(bytes("integrated artifact")),
                previousIds
            )
        returns (uint256) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(
                reason,
                "Previous delivery belongs to another project"
            );
        }

        require(blocked, "Cross-project link should be blocked");
        require(
            registry.deliveryCount() == 1,
            "No new delivery should be saved"
        );

        require(
            registry.stageDeliveryCounts(projectB, 2) == 0,
            "Failed submission should not consume sequence"
        );
    }

    function test_PreviousDeliveryFromSameStageCannotBeLinked() public {
        DeliveryRegistry registry = new DeliveryRegistry();
        DeliverySupplier supplier = new DeliverySupplier();
        DeliveryReceiver companyC = new DeliveryReceiver();

        uint256 projectId = registry.createProject("Project A");
        address receiver = address(0x3001);

        registry.allowRoute(projectId, address(supplier), address(companyC), 1);

        registry.allowRoute(projectId, address(companyC), receiver, 1);

        uint256 previousId = _submit(
            registry,
            supplier,
            projectId,
            address(companyC),
            new uint256[](0)
        );

        companyC.review(registry, previousId, DeliveryRegistry.Status.Approved);

        uint256[] memory previousIds = new uint256[](1);
        previousIds[0] = previousId;

        bool blocked = false;

        try
            companyC.submit(
                registry,
                projectId,
                receiver,
                "Integrated Module",
                "1.0.0",
                keccak256(bytes("integrated SBOM")),
                keccak256(bytes("integrated artifact")),
                previousIds
            )
        returns (uint256) {
            blocked = false;
        } catch Error(string memory reason) {
            blocked = _same(
                reason,
                "Previous delivery must be from an earlier stage"
            );
        }

        require(blocked, "Same-stage link should be blocked");
        require(
            registry.deliveryCount() == 1,
            "No new delivery should be saved"
        );

        require(
            registry.stageDeliveryCounts(projectId, 1) == 1,
            "Failed submission should not consume sequence"
        );
    }

    function _reviewSetup()
        private
        returns (
            DeliveryRegistry registry,
            DeliveryReceiver receiver,
            uint256 deliveryId
        )
    {
        registry = new DeliveryRegistry();

        DeliverySupplier supplier = new DeliverySupplier();
        receiver = new DeliveryReceiver();

        uint256 projectId = registry.createProject("Project A");

        registry.allowRoute(projectId, address(supplier), address(receiver), 1);

        deliveryId = _submit(
            registry,
            supplier,
            projectId,
            address(receiver),
            new uint256[](0)
        );
    }

    function _submit(
        DeliveryRegistry registry,
        DeliverySupplier supplier,
        uint256 projectId,
        address receiver,
        uint256[] memory previousIds
    ) private returns (uint256) {
        return
            supplier.submit(
                registry,
                projectId,
                receiver,
                "Payment Module",
                "1.0.0",
                keccak256(bytes("sample SBOM")),
                keccak256(bytes("sample artifact")),
                previousIds
            );
    }

    function _same(
        string memory left,
        string memory right
    ) private pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
