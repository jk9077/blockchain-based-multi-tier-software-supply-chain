pragma solidity ^0.8.28;

contract DeliveryRegistry {
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
        // Supplier depth from the customer, not chronological delivery order.
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

    address public immutable admin;

    mapping(address => bool) public registeredCompanies;
    mapping(uint256 => mapping(address => bool)) public projectMembers;
    mapping(uint256 => mapping(address => address)) public parentCompanies;
    // Customer depth is 0; its direct suppliers have depth 1.
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

    mapping(uint256 => mapping(uint256 => uint256)) public stageDeliveryCounts;

    mapping(uint256 => uint256[]) private previousDeliveryIds;

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
        address receiver
    );

    event DeliveryReviewed(
        uint256 indexed deliveryId,
        uint256 indexed projectId,
        uint256 stage,
        uint256 stageDeliveryNumber,
        address indexed reviewer,
        Status status
    );

    event DeliveryResubmitted(
        uint256 indexed originalDeliveryId,
        uint256 indexed newDeliveryId,
        address indexed supplier
    );

    constructor() {
        admin = msg.sender;
    }

    function registerCompany(address company) external {
        require(msg.sender == admin, "Only admin");
        require(company != address(0), "Invalid address");
        require(!registeredCompanies[company], "Company already registered");
        registeredCompanies[company] = true;
        emit CompanyRegistered(company);
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

    function addSupplier(
        uint256 projectId,
        address supplier
    ) external {
        _requireProject(projectId);
        require(projectMembers[projectId][msg.sender], "Not a project member");
        require(registeredCompanies[supplier], "Company not registered");
        require(
            supplier != msg.sender,
            "Supplier and receiver cannot be the same"
        );
        // Adding only new members prevents cycles and multiple parents.
        require(!projectMembers[projectId][supplier], "Company already in project");
        address receiver = msg.sender;
        uint256 stage = companyDepths[projectId][receiver] + 1;
        projectMembers[projectId][supplier] = true;
        parentCompanies[projectId][supplier] = receiver;
        companyDepths[projectId][supplier] = stage;

        allowedRoutes[projectId][supplier][receiver] = true;
        routeStages[projectId][supplier][receiver] = stage;

        emit RouteAllowed(projectId, supplier, receiver, stage);
    }

    function submitDelivery(
        uint256 projectId,
        address receiver,
        string memory productName,
        string memory version,
        bytes32 sbomHash,
        bytes32 fileHash,
        uint256[] calldata previousIds
    ) public returns (uint256) {
        _requireProject(projectId);

        require(
            allowedRoutes[projectId][msg.sender][receiver],
            "Route not allowed"
        );

        require(bytes(productName).length > 0, "Product name required");
        require(bytes(version).length > 0, "Version required");
        require(sbomHash != bytes32(0), "SBOM hash required");
        require(fileHash != bytes32(0), "File hash required");

        _validatePreviousDeliveries(
            projectId,
            routeStages[projectId][msg.sender][receiver],
            previousIds
        );

        deliveryCount++;

        uint256 deliveryId = deliveryCount;

        Delivery storage delivery = deliveries[deliveryId];

        delivery.projectId = projectId;
        delivery.stage = routeStages[projectId][msg.sender][receiver];

        projectDeliveryCounts[projectId]++;
        stageDeliveryCounts[projectId][delivery.stage]++;

        delivery.stageDeliveryNumber = stageDeliveryCounts[projectId][
            delivery.stage
        ];

        delivery.supplier = msg.sender;
        delivery.receiver = receiver;
        delivery.productName = productName;
        delivery.version = version;
        delivery.sbomHash = sbomHash;
        delivery.fileHash = fileHash;
        delivery.status = Status.Pending;
        delivery.submittedAt = block.timestamp;
        delivery.reviewedAt = 0;

        _finishSubmission(deliveryId, previousIds);

        return deliveryId;
    }

    function reviewDelivery(uint256 deliveryId, Status status) external {
        _requireDelivery(deliveryId);

        Delivery storage delivery = deliveries[deliveryId];

        require(msg.sender == delivery.receiver, "Only receiver can review");

        require(delivery.status == Status.Pending, "Delivery already reviewed");

        require(
            status == Status.Approved || status == Status.Rejected,
            "Invalid review status"
        );

        delivery.status = status;
        delivery.reviewedAt = block.timestamp;

        emit DeliveryReviewed(
            deliveryId,
            delivery.projectId,
            delivery.stage,
            delivery.stageDeliveryNumber,
            msg.sender,
            status
        );
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

        deliveryIdsByProject[delivery.projectId][delivery.stage][
            delivery.stageDeliveryNumber
        ] = deliveryId;

        emit DeliverySubmitted(
            deliveryId,
            delivery.projectId,
            delivery.stage,
            delivery.stageDeliveryNumber,
            delivery.supplier,
            delivery.receiver
        );
    }
    function resubmitDelivery(
        uint256 originalDeliveryId,
        string calldata version,
        bytes32 sbomHash,
        bytes32 fileHash,
        uint256[] calldata previousIds
    ) external returns (uint256) {
        _requireDelivery(originalDeliveryId);

        Delivery storage original = deliveries[originalDeliveryId];

        require(
            msg.sender == original.supplier,
            "Only original supplier can resubmit"
        );

        require(
            original.status == Status.Rejected,
            "Only rejected delivery can be resubmitted"
        );

        require(
            resubmittedDeliveryIds[originalDeliveryId] == 0,
            "Delivery already resubmitted"
        );

        uint256 newDeliveryId = submitDelivery(
            original.projectId,
            original.receiver,
            original.productName,
            version,
            sbomHash,
            fileHash,
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
