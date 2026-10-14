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
        string requirementId;
        uint256 projectId;
        uint256 stage;
        uint256 sequence;
        address supplier;
        address receiver;
        string productName;
        string[] requiredComponents;
        uint256 createdAt;
    }

    mapping(string => Requirement) private requirements;
    mapping(uint256 => mapping(uint256 => uint256)) private requirementSequences;
    mapping(string => string[]) private deliveryComponents;
    mapping(string => string) private _reviewNotes;

    event RequirementCreated(
        string requirementId,
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
    ) external returns (string memory requirementId) {
        _requireProject(projectId);
        if (!_allowedRoutes[projectId][supplier][msg.sender])
            revert OnlyReceiverCanCreateRequirement();
        _validateName(productName);
        _validateComponents(requiredComponents);
        requirementCount++;
        uint256 stage = _routeStages[projectId][supplier][msg.sender];
        uint256 sequence = ++requirementSequences[projectId][stage];
        requirementId = _formatId(projectId, stage, sequence);
        Requirement storage item = requirements[requirementId];
        item.requirementId = requirementId;
        item.stage = stage;
        item.sequence = sequence;
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
        uint256 projectId,
        uint256 stage,
        uint256 sequence
    ) external view returns (Requirement memory) {
        _requireProjectMember(projectId);
        string memory requirementId = _formatId(projectId, stage, sequence);
        _requireRequirement(requirementId);
        return requirements[requirementId];
    }

    function getDeliverySubmission(
        uint256 projectId,
        uint256 stage,
        uint256 sequence
    )
        external
        view
        returns (string memory requirementId, string[] memory submittedComponents)
    {
        string memory deliveryId = _readDeliveryId(projectId, stage, sequence);
        return (
            _deliveries[deliveryId].requirementId,
            deliveryComponents[deliveryId]
        );
    }

    function _requireRequirement(string memory requirementId) private view {
        if (requirements[requirementId].projectId == 0)
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
        string deliveryId;
        string requirementId;
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
        string deliveryId;
        string requirementId;
        address supplier;
        address receiver;
        Status status;
        string[] previousDeliveryIds;
    }

    mapping(address => bool) public registeredCompanies;
    mapping(uint256 => mapping(address => bool)) private _projectMembers;
    mapping(uint256 => mapping(address => address)) private _parentCompanies;
    mapping(uint256 => mapping(address => uint256)) private _companyDepths;

    uint256 public projectCount;
    uint256 public deliveryCount;

    mapping(uint256 => Project) private _projects;
    mapping(string => Delivery) private _deliveries;

    mapping(uint256 => mapping(address => mapping(address => bool)))
        private _allowedRoutes;

    mapping(uint256 => mapping(address => mapping(address => uint256)))
        private _routeStages;

    mapping(uint256 => uint256) private _projectDeliveryCounts;
    mapping(uint256 => string[]) private projectDeliveryIds;

    mapping(uint256 => mapping(uint256 => uint256)) private _stageDeliveryCounts;

    mapping(string => string[]) private previousDeliveryIds;
    mapping(string => string[]) private nextDeliveryIds;
    event DeliveryLinked(
        string previousDeliveryId,
        string nextDeliveryId
    );

    mapping(string => string) private _replacesDeliveryIds;
    mapping(string => string) private _resubmittedDeliveryIds;

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
        string deliveryId,
        uint256 indexed projectId,
        uint256 stage,
        uint256 stageDeliveryNumber,
        address indexed supplier,
        address receiver,
        string requirementId
    );

    event DeliveryReviewed(
        string deliveryId,
        uint256 indexed projectId,
        uint256 stage,
        uint256 stageDeliveryNumber,
        address indexed reviewer,
        Status status,
        string note
    );

    event DeliveryResubmitted(
        string originalDeliveryId,
        string newDeliveryId,
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

        _projects[projectId] = Project({
            name: name,
            customer: msg.sender,
            createdAt: block.timestamp
        });
        _projectMembers[projectId][msg.sender] = true;

        emit ProjectCreated(projectId, name, msg.sender);

        return projectId;
    }

    function addSupplier(uint256 projectId, address supplier) external {
        _requireProject(projectId);
        require(_projectMembers[projectId][msg.sender], "Not a project member");
        require(supplier != address(0), "Invalid address");
        if (!(supplier != msg.sender)) revert SupplierCannotBeReceiver();
        if (!(!_projectMembers[projectId][supplier]))
            revert CompanyAlreadyInProject();
        address receiver = msg.sender;
        uint256 stage = _companyDepths[projectId][receiver] + 1;
        _projectMembers[projectId][supplier] = true;
        _parentCompanies[projectId][supplier] = receiver;
        _companyDepths[projectId][supplier] = stage;

        _allowedRoutes[projectId][supplier][receiver] = true;
        _routeStages[projectId][supplier][receiver] = stage;

        if (!registeredCompanies[supplier]) {
            registeredCompanies[supplier] = true;
            emit CompanyRegistered(supplier);
        }

        emit RouteAllowed(projectId, supplier, receiver, stage);
    }

    function submitDelivery(
        string memory requirementId,
        string memory version,
        bytes32 sbomHash,
        bytes32 fileHash,
        string[] calldata submittedComponents,
        string[] calldata previousIds
    ) public returns (string memory deliveryId) {
        _requireRequirement(requirementId);
        Requirement storage item = requirements[requirementId];
        if (msg.sender != item.supplier) revert OnlyRequiredSupplierCanSubmit();
        require(
            _allowedRoutes[item.projectId][msg.sender][item.receiver],
            "Route not allowed"
        );
        require(bytes(version).length > 0, "Version required");
        require(sbomHash != bytes32(0), "SBOM hash required");
        require(fileHash != bytes32(0), "File hash required");
        _validateRequiredComponents(item, submittedComponents);
        _validatePreviousDeliveries(
            item.projectId,
            _routeStages[item.projectId][msg.sender][item.receiver],
            previousIds
        );

        deliveryCount++;
        uint256 stage = _routeStages[item.projectId][msg.sender][item.receiver];
        uint256 sequence = ++_stageDeliveryCounts[item.projectId][stage];
        deliveryId = _formatId(item.projectId, stage, sequence);
        Delivery storage delivery = _deliveries[deliveryId];
        delivery.deliveryId = deliveryId;
        delivery.projectId = item.projectId;
        delivery.stage = stage;
        _projectDeliveryCounts[item.projectId]++;
        delivery.stageDeliveryNumber = sequence;
        delivery.supplier = msg.sender;
        delivery.receiver = item.receiver;
        delivery.productName = item.productName;
        delivery.version = version;
        delivery.sbomHash = sbomHash;
        delivery.fileHash = fileHash;
        delivery.status = Status.Pending;
        delivery.submittedAt = block.timestamp;
        _deliveries[deliveryId].requirementId = requirementId;
        for (uint256 i = 0; i < submittedComponents.length; i++) {
            deliveryComponents[deliveryId].push(submittedComponents[i]);
        }
        _finishSubmission(deliveryId, previousIds);
    }

    function reviewDelivery(
        uint256 projectId,
        uint256 stage,
        uint256 sequence,
        Status status,
        string calldata note
    ) external {
        string memory deliveryId = _resolveDeliveryId(projectId, stage, sequence);

        Delivery storage delivery = _deliveries[deliveryId];

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
        _reviewNotes[deliveryId] = note;
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
        _requireProjectMember(projectId);
        if (limit == 0 || limit > MAX_TRACE_PAGE_SIZE) revert InvalidPageSize();
        info = _projects[projectId];
        string[] storage ids = projectDeliveryIds[projectId];
        total = ids.length;
        uint256 count;
        if (offset < total) {
            count = total - offset;
            if (count > limit) count = limit;
        }
        items = new ProjectDelivery[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory id = ids[offset + i];
            Delivery storage delivery = _deliveries[id];
            items[i] = ProjectDelivery({
                deliveryId: id,
                requirementId: delivery.requirementId,
                supplier: delivery.supplier,
                receiver: delivery.receiver,
                status: delivery.status,
                previousDeliveryIds: previousDeliveryIds[id]
            });
        }
    }

    function _formatId(uint256 projectId, uint256 stage, uint256 sequence) private pure returns (string memory) {
        return string.concat(_decimal(projectId), "-", _decimal(stage), "-", _decimal(sequence));
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
        uint256 projectId,
        uint256 stage,
        uint256 sequence
    ) external view returns (Delivery memory) {
        string memory deliveryId = _readDeliveryId(projectId, stage, sequence);

        return _deliveries[deliveryId];
    }

    function getPreviousDeliveryIds(
        uint256 projectId,
        uint256 stage,
        uint256 sequence
    ) external view returns (string[] memory) {
        string memory deliveryId = _readDeliveryId(projectId, stage, sequence);

        return previousDeliveryIds[deliveryId];
    }
    function getNextDeliveryIds(
        uint256 projectId,
        uint256 stage,
        uint256 sequence,
        uint256 offset,
        uint256 limit
    ) external view returns (string[] memory ids, uint256 total) {
        string memory deliveryId = _readDeliveryId(projectId, stage, sequence);
        if (limit == 0 || limit > MAX_TRACE_PAGE_SIZE) revert InvalidPageSize();
        string[] storage next = nextDeliveryIds[deliveryId];
        total = next.length;
        if (offset >= total) return (new string[](0), total);
        uint256 count = total - offset;
        if (count > limit) count = limit;
        ids = new string[](count);
        for (uint256 i = 0; i < count; i++) ids[i] = next[offset + i];
    }

    function getDeliveryId(
        uint256 projectId,
        uint256 stage,
        uint256 sequence
    ) external view returns (string memory) {
        return _readDeliveryId(projectId, stage, sequence);
    }

    function _readDeliveryId(uint256 projectId, uint256 stage, uint256 sequence) private view returns (string memory) {
        _requireProjectMember(projectId);
        return _resolveDeliveryId(projectId, stage, sequence);
    }

    function _resolveDeliveryId(uint256 projectId, uint256 stage, uint256 sequence) private view returns (string memory) {
        _requireProject(projectId);

        string memory deliveryId = _formatId(projectId, stage, sequence);

        _requireDelivery(deliveryId);

        return deliveryId;
    }

    function _validatePreviousDeliveries(
        uint256 projectId,
        uint256 stage,
        string[] calldata previousIds
    ) private view {
        for (uint256 i = 0; i < previousIds.length; i++) {
            string memory previousId = previousIds[i];

            _requireDelivery(previousId);

            Delivery storage previous = _deliveries[previousId];

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
                    keccak256(bytes(previousIds[j])) != keccak256(bytes(previousId)),
                    "Duplicate previous delivery"
                );
            }
        }
    }

    function _finishSubmission(
        string memory deliveryId,
        string[] calldata previousIds
    ) private {
        Delivery storage delivery = _deliveries[deliveryId];

        projectDeliveryIds[delivery.projectId].push(deliveryId);
        for (uint256 i = 0; i < previousIds.length; i++) {
            previousDeliveryIds[deliveryId].push(previousIds[i]);
            nextDeliveryIds[previousIds[i]].push(deliveryId);
            emit DeliveryLinked(previousIds[i], deliveryId);
        }

        emit DeliverySubmitted(
            deliveryId,
            delivery.projectId,
            delivery.stage,
            delivery.stageDeliveryNumber,
            delivery.supplier,
            delivery.receiver,
            _deliveries[deliveryId].requirementId
        );
    }
    function resubmitDelivery(
        uint256 projectId,
        uint256 stage,
        uint256 sequence,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash,
        string[] calldata submittedComponents,
        string[] calldata previousIds
    ) external returns (string memory) {
        return _resubmitDelivery(
            _resolveDeliveryId(projectId, stage, sequence),
            version, sbomHash, fileHash, submittedComponents, previousIds
        );
    }

    function _resubmitDelivery(
        string memory originalDeliveryId,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash,
        string[] calldata submittedComponents,
        string[] calldata previousIds
    ) private returns (string memory) {

        Delivery storage original = _deliveries[originalDeliveryId];

        if (!(msg.sender == original.supplier))
            revert OnlyOriginalSupplierCanResubmit();

        if (!(original.status == Status.Rejected))
            revert OnlyRejectedDeliveryCanBeResubmitted();

        if (!(bytes(_resubmittedDeliveryIds[originalDeliveryId]).length == 0))
            revert DeliveryAlreadyResubmitted();

        string memory newDeliveryId = submitDelivery(
            original.requirementId,
            version,
            sbomHash,
            fileHash,
            submittedComponents,
            previousIds
        );

        _replacesDeliveryIds[newDeliveryId] = originalDeliveryId;
        _resubmittedDeliveryIds[originalDeliveryId] = newDeliveryId;

        emit DeliveryResubmitted(originalDeliveryId, newDeliveryId, msg.sender);

        return newDeliveryId;
    }

    function projects(uint256 projectId) external view returns (string memory name, address customer, uint256 createdAt) {
        _requireProjectMember(projectId);
        Project storage item = _projects[projectId];
        return (item.name, item.customer, item.createdAt);
    }

    function projectMembers(uint256 projectId, address company) external view returns (bool) {
        _requireProjectMember(projectId);
        return _projectMembers[projectId][company];
    }

    function parentCompanies(uint256 projectId, address company) external view returns (address) {
        _requireProjectMember(projectId);
        return _parentCompanies[projectId][company];
    }

    function companyDepths(uint256 projectId, address company) external view returns (uint256) {
        _requireProjectMember(projectId);
        return _companyDepths[projectId][company];
    }

    function allowedRoutes(uint256 projectId, address supplier, address receiver) external view returns (bool) {
        _requireProjectMember(projectId);
        return _allowedRoutes[projectId][supplier][receiver];
    }

    function routeStages(uint256 projectId, address supplier, address receiver) external view returns (uint256) {
        _requireProjectMember(projectId);
        return _routeStages[projectId][supplier][receiver];
    }

    function projectDeliveryCounts(uint256 projectId) external view returns (uint256) {
        _requireProjectMember(projectId);
        return _projectDeliveryCounts[projectId];
    }

    function stageDeliveryCounts(uint256 projectId, uint256 stage) external view returns (uint256) {
        _requireProjectMember(projectId);
        return _stageDeliveryCounts[projectId][stage];
    }

    function deliveryRequirementIds(uint256 projectId, uint256 stage, uint256 sequence) external view returns (string memory) {
        return _deliveries[_readDeliveryId(projectId, stage, sequence)].requirementId;
    }

    function reviewNotes(uint256 projectId, uint256 stage, uint256 sequence) external view returns (string memory) {
        return _reviewNotes[_readDeliveryId(projectId, stage, sequence)];
    }

    function replacesDeliveryIds(uint256 projectId, uint256 stage, uint256 sequence) external view returns (string memory) {
        return _replacesDeliveryIds[_readDeliveryId(projectId, stage, sequence)];
    }

    function resubmittedDeliveryIds(uint256 projectId, uint256 stage, uint256 sequence) external view returns (string memory) {
        return _resubmittedDeliveryIds[_readDeliveryId(projectId, stage, sequence)];
    }

    function _requireProjectMember(uint256 projectId) private view {
        _requireProject(projectId);
        require(_projectMembers[projectId][msg.sender], "Not a project member");
    }

    function _requireProject(uint256 projectId) private view {
        require(
            projectId > 0 && projectId <= projectCount,
            "Project not found"
        );
    }

    function _requireDelivery(string memory deliveryId) private view {
        require(
            _deliveries[deliveryId].projectId != 0,
            "Delivery not found"
        );
    }
}
