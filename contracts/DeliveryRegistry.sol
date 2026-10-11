//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract DeliveryRegistry {
    error CompanyAlreadyInProject();
    error DeliveryAlreadyResubmitted();
    error SupplierCannotBeReceiver();
    error OnlyRejectedDeliveryCanBeResubmitted();
    error OnlyOriginalSupplierCanResubmit();
    error InvalidPageSize();
    error OnlyReceiverCanReview();
    error DeliveryAlreadyReviewed();
    error InvalidReviewStatus();
    error RejectionReasonRequired();
    error ReviewNoteTooLong();
    error RequirementNotFound();
    error OnlyReceiverCanCreateRequirement();
    error OnlyRequiredSupplierCanSubmit();
    error InvalidComponentCount();
    error InvalidName();
    error DuplicateComponent();
    error RequiredComponentMissing();

    uint256 public constant MAX_TRACE_PAGE_SIZE = 100;
    uint256 public constant MAX_REVIEW_NOTE_BYTES = 1024;
    uint256 public constant MAX_COMPONENTS = 32;
    uint256 public constant MAX_NAME_BYTES = 128;
    uint256 public requirementCount;

    struct Requirement {
        uint256 projectId;
        address supplier;
        address receiver;
        string productName;
        string[] requiredComponents;
        uint256 createdAt;
    }

    mapping(uint256 => Requirement) private requirements;
    mapping(uint256 => uint256) public deliveryRequirementIds;
    mapping(uint256 => string[]) private deliveryComponents;
    mapping(uint256 => string) public reviewNotes;

    event RequirementCreated(
        uint256 indexed requirementId,
        uint256 indexed projectId,
        address indexed supplier,
        address receiver,
        string productName,
        string[] requiredComponents
    );

    function createRequirement(
        uint256 projectId,
        address supplier,
        string calldata productName,
        string[] calldata requiredComponents
    ) external returns (uint256 requirementId) {
        _requireProject(projectId);
        if (!allowedRoutes[projectId][supplier][msg.sender])
            revert OnlyReceiverCanCreateRequirement();
        _validateName(productName);
        _validateComponents(requiredComponents);
        requirementId = ++requirementCount;
        Requirement storage item = requirements[requirementId];
        item.projectId = projectId;
        item.supplier = supplier;
        item.receiver = msg.sender;
        item.productName = productName;
        item.createdAt = block.timestamp;
        for (uint256 i = 0; i < requiredComponents.length; i++) {
            item.requiredComponents.push(requiredComponents[i]);
        }
        emit RequirementCreated(
            requirementId,
            projectId,
            supplier,
            msg.sender,
            productName,
            requiredComponents
        );
    }

    function getRequirement(
        uint256 requirementId
    ) external view returns (Requirement memory) {
        _requireRequirement(requirementId);
        return requirements[requirementId];
    }

    function getDeliverySubmission(
        uint256 deliveryId
    )
        external
        view
        returns (uint256 requirementId, string[] memory submittedComponents)
    {
        _requireDelivery(deliveryId);
        return (
            deliveryRequirementIds[deliveryId],
            deliveryComponents[deliveryId]
        );
    }

    function _requireRequirement(uint256 requirementId) private view {
        if (requirementId == 0 || requirementId > requirementCount)
            revert RequirementNotFound();
    }

    function _validateName(string memory name) private pure {
        bytes memory value = bytes(name);
        if (value.length == 0 || value.length > MAX_NAME_BYTES)
            revert InvalidName();
        uint256 i;
        while (i < value.length) {
            uint8 current = uint8(value[i]);
            if (current <= 32) {
                i++;
            } else if (
                current == 0xc2 && i + 1 < value.length && value[i + 1] == 0xa0
            ) {
                i += 2;
            } else if (
                current == 0xe3 &&
                i + 2 < value.length &&
                value[i + 1] == 0x80 &&
                value[i + 2] == 0x80
            ) {
                i += 3;
            } else {
                return;
            }
        }
        revert InvalidName();
    }

    function _validateComponents(string[] calldata components) private pure {
        if (components.length == 0 || components.length > MAX_COMPONENTS)
            revert InvalidComponentCount();
        for (uint256 i = 0; i < components.length; i++) {
            _validateName(components[i]);
            for (uint256 j = 0; j < i; j++) {
                if (
                    keccak256(bytes(components[i])) ==
                    keccak256(bytes(components[j]))
                ) revert DuplicateComponent();
            }
        }
    }

    function _validateRequiredComponents(
        Requirement storage item,
        string[] calldata components
    ) private view {
        _validateComponents(components);
        for (uint256 i = 0; i < item.requiredComponents.length; i++) {
            bool found;
            for (uint256 j = 0; j < components.length; j++) {
                if (
                    keccak256(bytes(item.requiredComponents[i])) ==
                    keccak256(bytes(components[j]))
                ) {
                    found = true;
                    break;
                }
            }
            if (!found) revert RequiredComponentMissing();
        }
    }

    enum Status {
        Pending,
        Approved,
        Rejected
    }

    struct Project {
        string name;
        address customer;
        uint256 createdAt;
    }

    struct Delivery {
        uint256 projectId;
        uint256 stage;
        uint256 stageDeliveryNumber;
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

    struct ProjectDelivery {
        uint256 deliveryId;
        string deliveryNumber;
        address supplier;
        address receiver;
        Status status;
        string[] previousDeliveryNumbers;
    }

    mapping(address => bool) public registeredCompanies;
    mapping(uint256 => mapping(address => bool)) public projectMembers;
    mapping(uint256 => mapping(address => address)) public parentCompanies;
    mapping(uint256 => mapping(address => uint256)) public companyDepths;

    uint256 public projectCount;
    uint256 public deliveryCount;

    mapping(uint256 => Project) public projects;
    mapping(uint256 => Delivery) public deliveries;

    mapping(uint256 => mapping(address => mapping(address => bool)))
        public allowedRoutes;

    mapping(uint256 => mapping(address => mapping(address => uint256)))
        public routeStages;

    mapping(uint256 => uint256) public projectDeliveryCounts;
    mapping(uint256 => uint256[]) private projectDeliveryIds;

    mapping(uint256 => mapping(uint256 => uint256)) public stageDeliveryCounts;

    mapping(uint256 => uint256[]) private previousDeliveryIds;
    mapping(uint256 => uint256[]) private nextDeliveryIds;
    event DeliveryLinked(
        uint256 indexed previousDeliveryId,
        uint256 indexed nextDeliveryId
    );

    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))
        private deliveryIdsByProject;

    mapping(uint256 => uint256) public replacesDeliveryIds;
    mapping(uint256 => uint256) public resubmittedDeliveryIds;

    event CompanyRegistered(address indexed company);
    event ProjectCreated(
        uint256 indexed projectId,
        string name,
        address indexed customer
    );

    event RouteAllowed(
        uint256 indexed projectId,
        address indexed supplier,
        address indexed receiver,
        uint256 stage
    );

    event DeliverySubmitted(
        uint256 indexed deliveryId,
        uint256 indexed projectId,
        uint256 stage,
        uint256 stageDeliveryNumber,
        address indexed supplier,
        address receiver,
        uint256 requirementId
    );

    event DeliveryReviewed(
        uint256 indexed deliveryId,
        uint256 indexed projectId,
        uint256 stage,
        uint256 stageDeliveryNumber,
        address indexed reviewer,
        Status status,
        string note
    );

    event DeliveryResubmitted(
        uint256 indexed originalDeliveryId,
        uint256 indexed newDeliveryId,
        address indexed supplier
    );

    function registerCompany() external {
        require(!registeredCompanies[msg.sender], "Company already registered");
        registeredCompanies[msg.sender] = true;
        emit CompanyRegistered(msg.sender);
    }

    function createProject(string calldata name) external returns (uint256) {
        require(registeredCompanies[msg.sender], "Company not registered");
        require(bytes(name).length > 0, "Project name required");

        projectCount++;

        uint256 projectId = projectCount;

        projects[projectId] = Project({
            name: name,
            customer: msg.sender,
            createdAt: block.timestamp
        });
        projectMembers[projectId][msg.sender] = true;

        emit ProjectCreated(projectId, name, msg.sender);

        return projectId;
    }

    function addSupplier(uint256 projectId, address supplier) external {
        _requireProject(projectId);
        require(projectMembers[projectId][msg.sender], "Not a project member");
        require(supplier != address(0), "Invalid address");
        if (!(supplier != msg.sender)) revert SupplierCannotBeReceiver();
        if (!(!projectMembers[projectId][supplier]))
            revert CompanyAlreadyInProject();
        address receiver = msg.sender;
        uint256 stage = companyDepths[projectId][receiver] + 1;
        projectMembers[projectId][supplier] = true;
        parentCompanies[projectId][supplier] = receiver;
        companyDepths[projectId][supplier] = stage;

        allowedRoutes[projectId][supplier][receiver] = true;
        routeStages[projectId][supplier][receiver] = stage;

        if (!registeredCompanies[supplier]) {
            registeredCompanies[supplier] = true;
            emit CompanyRegistered(supplier);
        }

        emit RouteAllowed(projectId, supplier, receiver, stage);
    }

    function submitDelivery(
        uint256 requirementId,
        string memory version,
        bytes32 sbomHash,
        bytes32 fileHash,
        string[] calldata submittedComponents,
        uint256[] calldata previousIds
    ) public returns (uint256 deliveryId) {
        _requireRequirement(requirementId);
        Requirement storage item = requirements[requirementId];
        if (msg.sender != item.supplier) revert OnlyRequiredSupplierCanSubmit();
        require(
            allowedRoutes[item.projectId][msg.sender][item.receiver],
            "Route not allowed"
        );
        require(bytes(version).length > 0, "Version required");
        require(sbomHash != bytes32(0), "SBOM hash required");
        require(fileHash != bytes32(0), "File hash required");
        _validateRequiredComponents(item, submittedComponents);
        _validatePreviousDeliveries(
            item.projectId,
            routeStages[item.projectId][msg.sender][item.receiver],
            previousIds
        );

        deliveryId = ++deliveryCount;
        Delivery storage delivery = deliveries[deliveryId];
        delivery.projectId = item.projectId;
        delivery.stage = routeStages[item.projectId][msg.sender][item.receiver];
        projectDeliveryCounts[item.projectId]++;
        delivery.stageDeliveryNumber = ++stageDeliveryCounts[item.projectId][
            delivery.stage
        ];
        delivery.supplier = msg.sender;
        delivery.receiver = item.receiver;
        delivery.productName = item.productName;
        delivery.version = version;
        delivery.sbomHash = sbomHash;
        delivery.fileHash = fileHash;
        delivery.status = Status.Pending;
        delivery.submittedAt = block.timestamp;
        deliveryRequirementIds[deliveryId] = requirementId;
        for (uint256 i = 0; i < submittedComponents.length; i++) {
            deliveryComponents[deliveryId].push(submittedComponents[i]);
        }
        _finishSubmission(deliveryId, previousIds);
    }

    function reviewDelivery(
        uint256 deliveryId,
        Status status,
        string calldata note
    ) external {
        _requireDelivery(deliveryId);

        Delivery storage delivery = deliveries[deliveryId];

        if (!(msg.sender == delivery.receiver)) revert OnlyReceiverCanReview();

        if (!(delivery.status == Status.Pending))
            revert DeliveryAlreadyReviewed();

        if (!(status == Status.Approved || status == Status.Rejected))
            revert InvalidReviewStatus();

        bytes memory noteBytes = bytes(note);
        if (noteBytes.length > MAX_REVIEW_NOTE_BYTES)
            revert ReviewNoteTooLong();
        if (status == Status.Rejected) {
            bool hasContent;
            for (uint256 i = 0; i < noteBytes.length; i++) {
                if (uint8(noteBytes[i]) > 32) {
                    hasContent = true;
                    break;
                }
            }
            if (!hasContent) revert RejectionReasonRequired();
        }
        reviewNotes[deliveryId] = note;
        delivery.status = status;
        delivery.reviewedAt = block.timestamp;

        emit DeliveryReviewed(
            deliveryId,
            delivery.projectId,
            delivery.stage,
            delivery.stageDeliveryNumber,
            msg.sender,
            status,
            note
        );
    }

    function getProject(
        uint256 projectId,
        uint256 offset,
        uint256 limit
    ) external view returns (Project memory info, ProjectDelivery[] memory items, uint256 total) {
        _requireProject(projectId);
        if (limit == 0 || limit > MAX_TRACE_PAGE_SIZE) revert InvalidPageSize();
        info = projects[projectId];
        uint256[] storage ids = projectDeliveryIds[projectId];
        total = ids.length;
        uint256 count;
        if (offset < total) {
            count = total - offset;
            if (count > limit) count = limit;
        }
        items = new ProjectDelivery[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 id = ids[offset + i];
            Delivery storage delivery = deliveries[id];
            uint256[] storage previous = previousDeliveryIds[id];
            string[] memory numbers = new string[](previous.length);
            for (uint256 j = 0; j < previous.length; j++) {
                numbers[j] = _deliveryNumber(previous[j]);
            }
            items[i] = ProjectDelivery({
                deliveryId: id,
                deliveryNumber: _deliveryNumber(id),
                supplier: delivery.supplier,
                receiver: delivery.receiver,
                status: delivery.status,
                previousDeliveryNumbers: numbers
            });
        }
    }

    function _deliveryNumber(uint256 deliveryId) private view returns (string memory) {
        Delivery storage delivery = deliveries[deliveryId];
        return string.concat(
            _decimal(delivery.projectId), "-",
            _decimal(delivery.stage), "-",
            _decimal(delivery.stageDeliveryNumber)
        );
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        uint256 length = 1;
        for (uint256 remaining = value; remaining >= 10; remaining /= 10) {
            length++;
        }
        bytes memory result = new bytes(length);
        do {
            result[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        } while (length > 0);
        return string(result);
    }

    function getDelivery(
        uint256 deliveryId
    ) external view returns (Delivery memory) {
        _requireDelivery(deliveryId);

        return deliveries[deliveryId];
    }

    function getPreviousDeliveryIds(
        uint256 deliveryId
    ) external view returns (uint256[] memory) {
        _requireDelivery(deliveryId);

        return previousDeliveryIds[deliveryId];
    }
    function getNextDeliveryIds(
        uint256 deliveryId,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 total) {
        _requireDelivery(deliveryId);
        if (limit == 0 || limit > MAX_TRACE_PAGE_SIZE) revert InvalidPageSize();
        uint256[] storage next = nextDeliveryIds[deliveryId];
        total = next.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 count = total - offset;
        if (count > limit) count = limit;
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) ids[i] = next[offset + i];
    }

    function getDeliveryId(
        uint256 projectId,
        uint256 stage,
        uint256 sequence
    ) external view returns (uint256) {
        _requireProject(projectId);

        uint256 deliveryId = deliveryIdsByProject[projectId][stage][sequence];

        require(deliveryId != 0, "Delivery not found");

        return deliveryId;
    }

    function _validatePreviousDeliveries(
        uint256 projectId,
        uint256 stage,
        uint256[] calldata previousIds
    ) private view {
        for (uint256 i = 0; i < previousIds.length; i++) {
            uint256 previousId = previousIds[i];

            _requireDelivery(previousId);

            Delivery storage previous = deliveries[previousId];

            require(
                previous.projectId == projectId,
                "Previous delivery belongs to another project"
            );

            require(
                previous.receiver == msg.sender,
                "Previous delivery was not received by supplier"
            );

            require(
                previous.status == Status.Approved,
                "Previous delivery not approved"
            );

            require(
                previous.stage == stage + 1,
                "Previous delivery must be from a direct supplier"
            );

            for (uint256 j = 0; j < i; j++) {
                require(
                    previousIds[j] != previousId,
                    "Duplicate previous delivery"
                );
            }
        }
    }

    function _finishSubmission(
        uint256 deliveryId,
        uint256[] calldata previousIds
    ) private {
        Delivery storage delivery = deliveries[deliveryId];

        previousDeliveryIds[deliveryId] = previousIds;
        projectDeliveryIds[delivery.projectId].push(deliveryId);
        for (uint256 i = 0; i < previousIds.length; i++) {
            nextDeliveryIds[previousIds[i]].push(deliveryId);
            emit DeliveryLinked(previousIds[i], deliveryId);
        }

        deliveryIdsByProject[delivery.projectId][delivery.stage][
            delivery.stageDeliveryNumber
        ] = deliveryId;

        emit DeliverySubmitted(
            deliveryId,
            delivery.projectId,
            delivery.stage,
            delivery.stageDeliveryNumber,
            delivery.supplier,
            delivery.receiver,
            deliveryRequirementIds[deliveryId]
        );
    }
    function resubmitDelivery(
        uint256 originalDeliveryId,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash,
        string[] calldata submittedComponents,
        uint256[] calldata previousIds
    ) external returns (uint256) {
        _requireDelivery(originalDeliveryId);

        Delivery storage original = deliveries[originalDeliveryId];

        if (!(msg.sender == original.supplier))
            revert OnlyOriginalSupplierCanResubmit();

        if (!(original.status == Status.Rejected))
            revert OnlyRejectedDeliveryCanBeResubmitted();

        if (!(resubmittedDeliveryIds[originalDeliveryId] == 0))
            revert DeliveryAlreadyResubmitted();

        uint256 newDeliveryId = submitDelivery(
            deliveryRequirementIds[originalDeliveryId],
            version,
            sbomHash,
            fileHash,
            submittedComponents,
            previousIds
        );

        replacesDeliveryIds[newDeliveryId] = originalDeliveryId;
        resubmittedDeliveryIds[originalDeliveryId] = newDeliveryId;

        emit DeliveryResubmitted(originalDeliveryId, newDeliveryId, msg.sender);

        return newDeliveryId;
    }

    function _requireProject(uint256 projectId) private view {
        require(
            projectId > 0 && projectId <= projectCount,
            "Project not found"
        );
    }

    function _requireDelivery(uint256 deliveryId) private view {
        require(
            deliveryId > 0 && deliveryId <= deliveryCount,
            "Delivery not found"
        );
    }
}
