pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeliveryRegistry} from "../contracts/DeliveryRegistry.sol";

contract DeliveryRegistryTest is Test {
    DeliveryRegistry registry;
    mapping(bytes32 => uint256) defaultRequirements;
    address a = address(0xA);
    address b = address(0xB);
    address c = address(0xC);
    address d = address(0xD);
    address e = address(0xE);
    address outsider = address(0xF);
    uint256 project;
    bytes32 sbom = keccak256("SBOM");
    bytes32 artifact = keccak256("artifact");

    event CompanyRegistered(address indexed company);
    event ProjectCreated(uint256 indexed projectId, string name, address indexed customer);
    event RouteAllowed(uint256 indexed projectId, address indexed supplier, address indexed receiver, uint256 stage);

    function setUp() public {
        registry = new DeliveryRegistry();
        vm.prank(a);
        registry.registerCompany();
        vm.prank(a);
        project = registry.createProject("Project A");
        _add(a, b, project);
        _add(b, c, project);
        _add(c, d, project);
        _add(c, e, project);
    }

    function test_RootCompanyRegistersItselfWithoutAdministrator() public {
        assertFalse(registry.registeredCompanies(outsider));
        assertFalse(registry.registeredCompanies(address(this)));
        vm.expectEmit(true, false, false, true);
        emit CompanyRegistered(outsider);
        vm.prank(outsider);
        registry.registerCompany();
        assertTrue(registry.registeredCompanies(outsider));
        assertFalse(registry.registeredCompanies(address(this)));
        vm.prank(outsider);
        vm.expectRevert(bytes("Company already registered"));
        registry.registerCompany();
        vm.prank(outsider);
        uint256 ownProject = registry.createProject("Root project");
        assertTrue(registry.projectMembers(ownProject, outsider));
        assertFalse(registry.projectMembers(project, outsider));
    }

    function test_ParentRegistersSupplierAndSupplierCanRegisterNextCompany() public {
        assertFalse(registry.registeredCompanies(outsider));
        vm.prank(outsider);
        vm.expectRevert(bytes("Not a project member"));
        registry.addSupplier(project, address(99));
        vm.expectRevert(bytes("Not a project member"));
        registry.addSupplier(project, outsider);
        _add(d, outsider, project);
        assertTrue(registry.registeredCompanies(outsider));
        assertTrue(registry.projectMembers(project, outsider));
        assertEq(registry.parentCompanies(project, outsider), d);
        assertEq(registry.companyDepths(project, outsider), 4);
        _add(outsider, address(99), project);
        assertTrue(registry.registeredCompanies(address(99)));
        assertEq(registry.parentCompanies(project, address(99)), outsider);
        assertEq(registry.companyDepths(project, address(99)), 5);
    }

    function test_RegisteredCompanyCreatesProjectAsCustomer() public {
        vm.expectEmit(true, true, false, true);
        emit ProjectCreated(2, "Project B", b);
        vm.prank(b);
        uint256 id = registry.createProject("Project B");
        (string memory name, address customer, uint256 createdAt) = registry.projects(id);
        assertEq(name, "Project B");
        assertEq(customer, b);
        assertEq(createdAt, block.timestamp);
        assertTrue(registry.projectMembers(id, b));
        assertEq(registry.companyDepths(id, b), 0);
        assertEq(registry.parentCompanies(id, b), address(0));
    }

    function test_ProjectCreationRejectsUnknownCompanyAndEmptyName() public {
        vm.expectRevert(bytes("Company not registered"));
        registry.createProject("Unregistered account");
        vm.prank(a);
        vm.expectRevert(bytes("Project name required"));
        registry.createProject("");
        assertEq(registry.projectCount(), 1);
    }

    function test_DelegatedTreeHasAutomaticDepthAndFixedReceiver() public view {
        assertEq(registry.parentCompanies(project, b), a);
        assertEq(registry.parentCompanies(project, c), b);
        assertEq(registry.parentCompanies(project, d), c);
        assertEq(registry.parentCompanies(project, e), c);
        assertEq(registry.companyDepths(project, a), 0);
        assertEq(registry.companyDepths(project, b), 1);
        assertEq(registry.companyDepths(project, c), 2);
        assertEq(registry.companyDepths(project, d), 3);
        assertEq(registry.routeStages(project, d, c), 3);
        assertTrue(registry.allowedRoutes(project, d, c));
        assertFalse(registry.allowedRoutes(project, d, b));
    }

    function test_AddSupplierEmitsRouteAndPreservesExistingDepths() public {
        vm.expectEmit(true, true, true, true);
        emit RouteAllowed(project, outsider, d, 4);
        _add(d, outsider, project);
        assertEq(registry.companyDepths(project, outsider), 4);
        assertEq(registry.companyDepths(project, b), 1);
        assertEq(registry.companyDepths(project, d), 3);
    }

    function test_NonmemberAndDeployerCannotSetProjectRoutes() public {
        vm.prank(outsider);
        vm.expectRevert(bytes("Not a project member"));
        registry.addSupplier(project, address(99));
        vm.expectRevert(bytes("Not a project member"));
        registry.addSupplier(project, outsider);
    }

    function test_RejectsUnknownProjectAndSupplier() public {
        vm.prank(a);
        vm.expectRevert(bytes("Project not found"));
        registry.addSupplier(0, outsider);
        vm.prank(a);
        vm.expectRevert(bytes("Project not found"));
        registry.addSupplier(2, outsider);
        vm.prank(a);
        vm.expectRevert(bytes("Invalid address"));
        registry.addSupplier(project, address(0));
    }

    function test_RejectsSelfDuplicateMultipleParentsAndCycles() public {
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.SupplierCannotBeReceiver.selector);
        registry.addSupplier(project, c);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.CompanyAlreadyInProject.selector);
        registry.addSupplier(project, d);
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.CompanyAlreadyInProject.selector);
        registry.addSupplier(project, d);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.CompanyAlreadyInProject.selector);
        registry.addSupplier(project, a);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.CompanyAlreadyInProject.selector);
        registry.addSupplier(project, b);
        assertEq(registry.parentCompanies(project, d), c);
    }

    function test_ProjectsHaveSeparateMembershipRoutesAndNumbers() public {
        vm.prank(e);
        uint256 second = registry.createProject("Project B");
        vm.prank(a);
        vm.expectRevert(bytes("Not a project member"));
        registry.addSupplier(second, b);
        _add(e, d, second);
        assertEq(registry.parentCompanies(second, d), e);
        assertEq(registry.parentCompanies(project, d), c);
        uint256 firstId = _submit(d, c, project, new uint256[](0));
        uint256 secondId = _submit(d, e, second, new uint256[](0));
        assertEq(registry.getDeliveryId(project, 3, 1), firstId);
        assertEq(registry.getDeliveryId(second, 1, 1), secondId);
        assertEq(registry.projectDeliveryCounts(project), 1);
        assertEq(registry.projectDeliveryCounts(second), 1);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
        registry.createRequirement(second, d, "Product", _components());
    }

    function test_ProjectQueryShowsCompositeNumbersAndMergedPath() public {
        uint256 did = _submit(d, c, project, new uint256[](0));
        uint256 eid = _submit(e, c, project, new uint256[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _review(c, eid, DeliveryRegistry.Status.Approved);
        uint256[] memory sources = new uint256[](2);
        sources[0] = did;
        sources[1] = eid;
        uint256 cid = _submit(c, b, project, sources);
        _review(b, cid, DeliveryRegistry.Status.Approved);
        uint256 bid = _submit(b, a, project, _one(cid));
        (DeliveryRegistry.Project memory info, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(project, 0, 20);
        assertEq(info.name, "Project A");
        assertEq(info.customer, a);
        assertEq(info.createdAt, block.timestamp);
        assertEq(total, 4);
        assertEq(items.length, 4);
        assertEq(items[0].deliveryNumber, "1-3-1");
        assertEq(items[1].deliveryNumber, "1-3-2");
        assertEq(items[2].deliveryNumber, "1-2-1");
        assertEq(items[3].deliveryNumber, "1-1-1");
        assertEq(items[0].previousDeliveryNumbers.length, 0);
        assertEq(items[2].previousDeliveryNumbers.length, 2);
        assertEq(items[2].previousDeliveryNumbers[0], "1-3-1");
        assertEq(items[2].previousDeliveryNumbers[1], "1-3-2");
        assertEq(items[3].previousDeliveryNumbers[0], "1-2-1");
        assertEq(items[3].deliveryId, bid);
        assertEq(items[3].supplier, b);
        assertEq(items[3].receiver, a);
        assertEq(uint256(items[3].status), uint256(DeliveryRegistry.Status.Pending));
        _review(a, bid, DeliveryRegistry.Status.Approved);
        (, items, total) = registry.getProject(project, 3, 1);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryNumber, "1-1-1");
        assertEq(items[0].previousDeliveryNumbers[0], "1-2-1");
        assertEq(uint256(items[0].status), uint256(DeliveryRegistry.Status.Approved));
        assertEq(total, 4);
    }

    function test_ProjectQueryPaginatesInterleavedProjectsAndKeepsResubmissions() public {
        uint256 original = _submit(d, c, project, new uint256[](0));
        vm.prank(e);
        uint256 second = registry.createProject("Second");
        _add(e, d, second);
        uint256 other = _submit(d, e, second, new uint256[](0));
        _review(c, original, DeliveryRegistry.Status.Rejected);
        vm.prank(d);
        uint256 revised = registry.resubmitDelivery(original, "2", sbom, artifact, _components(), new uint256[](0));
        (, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(project, 0, 1);
        assertEq(total, 2);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, original);
        assertEq(items[0].deliveryNumber, "1-3-1");
        assertEq(uint256(items[0].status), uint256(DeliveryRegistry.Status.Rejected));
        (, items, total) = registry.getProject(project, 1, 100);
        assertEq(total, 2);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, revised);
        assertEq(items[0].deliveryNumber, "1-3-2");
        assertEq(uint256(items[0].status), uint256(DeliveryRegistry.Status.Pending));
        (, items, total) = registry.getProject(second, 0, 100);
        assertEq(total, 1);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, other);
        assertEq(items[0].deliveryNumber, "2-1-1");
    }

    function test_ProjectQueryHandlesEmptyPagesAndRejectsInvalidQueries() public {
        (, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(project, 0, 10);
        assertEq(items.length, 0);
        assertEq(total, 0);
        _submit(d, c, project, new uint256[](0));
        (, items, total) = registry.getProject(project, 1, 10);
        assertEq(items.length, 0);
        assertEq(total, 1);
        (, items, total) = registry.getProject(project, type(uint256).max, 10);
        assertEq(items.length, 0);
        assertEq(total, 1);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        registry.getProject(project, 0, 0);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        registry.getProject(project, 0, 101);
        vm.expectRevert(bytes("Project not found"));
        registry.getProject(0, 0, 10);
        vm.expectRevert(bytes("Project not found"));
        registry.getProject(2, 0, 10);
    }

    function test_ProjectQueryFormatsMultiDigitProjectStageAndSequence() public {
        uint256 target;
        for (uint256 i = 0; i < 9; i++) {
            vm.prank(a);
            target = registry.createProject("Multi digit");
        }
        address parent = a;
        for (uint256 i = 1; i <= 10; i++) {
            address child = address(uint160(100 + i));
            _add(parent, child, target);
            parent = child;
        }
        for (uint256 i = 0; i < 10; i++) {
            _submit(address(110), address(109), target, new uint256[](0));
        }
        (, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(target, 9, 1);
        assertEq(total, 10);
        assertEq(items[0].deliveryNumber, "10-10-10");
    }

    function test_FullSupplyChainAndProjectNumbering() public {
        uint256 did = _submit(d, c, project, new uint256[](0));
        uint256 eid = _submit(e, c, project, new uint256[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _review(c, eid, DeliveryRegistry.Status.Approved);
        uint256[] memory sources = new uint256[](2);
        sources[0] = did;
        sources[1] = eid;
        uint256 cid = _submit(c, b, project, sources);
        _review(b, cid, DeliveryRegistry.Status.Approved);
        uint256 bid = _submit(b, a, project, _one(cid));
        _review(a, bid, DeliveryRegistry.Status.Approved);
        assertEq(registry.getPreviousDeliveryIds(cid), sources);
        assertEq(registry.getPreviousDeliveryIds(bid), _one(cid));
        assertEq(registry.getDeliveryId(project, 3, 1), did);
        assertEq(registry.getDeliveryId(project, 3, 2), eid);
        assertEq(registry.getDeliveryId(project, 2, 1), cid);
        assertEq(registry.getDeliveryId(project, 1, 1), bid);
        assertEq(registry.projectDeliveryCounts(project), 4);
        DeliveryRegistry.Delivery memory saved = registry.getDelivery(did);
        assertEq(saved.supplier, d);
        assertEq(saved.receiver, c);
        assertEq(saved.projectId, project);
        assertEq(saved.productName, "Product");
        assertEq(saved.version, "1");
        assertEq(saved.sbomHash, sbom);
        assertEq(saved.fileHash, artifact);
        assertEq(saved.submittedAt, block.timestamp);
        assertEq(uint256(saved.status), uint256(DeliveryRegistry.Status.Approved));
    }

    function test_OnlyDesignatedSupplierCanSubmit() public {
        uint256 requestId = _request(c, b, project);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyRequiredSupplierCanSubmit.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), new uint256[](0));
        vm.prank(outsider);
        vm.expectRevert(DeliveryRegistry.OnlyRequiredSupplierCanSubmit.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), new uint256[](0));
        assertEq(registry.deliveryCount(), 0);
    }

    function test_DeployerAndCustomerCannotReviewOthersDeliveries() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved, "");
        vm.prank(a);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved, "");
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved, "");
        assertEq(uint256(registry.getDelivery(id).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(registry.getDelivery(id).reviewedAt, 0);
        vm.warp(block.timestamp + 10);
        _review(c, id, DeliveryRegistry.Status.Rejected);
        assertEq(registry.getDelivery(id).reviewedAt, block.timestamp);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.DeliveryAlreadyReviewed.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved, "");
    }

    function test_InvalidReviewStatusIsBlocked() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.InvalidReviewStatus.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Pending, "");
    }

    function test_PendingRejectedAndDuplicateLinksAreBlocked() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        _expectBadLink(_one(id), "Previous delivery not approved");
        _review(c, id, DeliveryRegistry.Status.Rejected);
        _expectBadLink(_one(id), "Previous delivery not approved");
        uint256 approved = _submit(e, c, project, new uint256[](0));
        _review(c, approved, DeliveryRegistry.Status.Approved);
        uint256[] memory ids = new uint256[](2);
        ids[0] = approved;
        ids[1] = approved;
        _expectBadLink(ids, "Duplicate previous delivery");
        assertEq(registry.deliveryCount(), 2);
        assertEq(registry.stageDeliveryCounts(project, 2), 0);
    }

    function test_CrossProjectAndUnreceivedLinksAreBlocked() public {
        vm.prank(c);
        uint256 second = registry.createProject("Other");
        _add(c, d, second);
        uint256 id = _submit(d, c, second, new uint256[](0));
        _review(c, id, DeliveryRegistry.Status.Approved);
        _expectBadLink(_one(id), "Previous delivery belongs to another project");
        id = _submit(b, a, project, new uint256[](0));
        _review(a, id, DeliveryRegistry.Status.Approved);
        _expectBadLink(_one(id), "Previous delivery was not received by supplier");
        _expectBadLink(_one(999), "Delivery not found");
    }

    function test_ResubmissionPreservesOriginalAndCanRepeatAfterRejection() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        _review(c, id, DeliveryRegistry.Status.Rejected);
        bytes32 original = keccak256(abi.encode(registry.getDelivery(id)));
        vm.prank(d);
        uint256 revised = registry.resubmitDelivery(id, "2", keccak256("new SBOM"), keccak256("new artifact"), _components(), new uint256[](0));
        assertEq(keccak256(abi.encode(registry.getDelivery(id))), original);
        assertEq(registry.replacesDeliveryIds(revised), id);
        assertEq(registry.resubmittedDeliveryIds(id), revised);
        DeliveryRegistry.Delivery memory saved = registry.getDelivery(revised);
        assertEq(saved.version, "2");
        assertEq(saved.sbomHash, keccak256("new SBOM"));
        assertEq(saved.fileHash, keccak256("new artifact"));
        assertEq(saved.supplier, d);
        assertEq(saved.receiver, c);
        assertEq(saved.projectId, project);
        assertEq(saved.stage, 3);
        assertEq(saved.stageDeliveryNumber, 2);
        assertEq(uint256(saved.status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(saved.reviewedAt, 0);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.DeliveryAlreadyResubmitted.selector);
        registry.resubmitDelivery(id, "3", sbom, artifact, _components(), new uint256[](0));
        _review(c, revised, DeliveryRegistry.Status.Rejected);
        vm.prank(d);
        uint256 third = registry.resubmitDelivery(revised, "3", sbom, artifact, _components(), new uint256[](0));
        _review(c, third, DeliveryRegistry.Status.Approved);
        assertEq(registry.replacesDeliveryIds(third), revised);
        assertEq(registry.resubmittedDeliveryIds(revised), third);
    }

    function test_ResubmissionRequiresOriginalSupplierAndRejection() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyRejectedDeliveryCanBeResubmitted.selector);
        registry.resubmitDelivery(id, "2", sbom, artifact, _components(), new uint256[](0));
        _review(c, id, DeliveryRegistry.Status.Approved);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyRejectedDeliveryCanBeResubmitted.selector);
        registry.resubmitDelivery(id, "2", sbom, artifact, _components(), new uint256[](0));
        uint256 rejected = _submit(d, c, project, new uint256[](0));
        _review(c, rejected, DeliveryRegistry.Status.Rejected);
        vm.prank(e);
        vm.expectRevert(DeliveryRegistry.OnlyOriginalSupplierCanResubmit.selector);
        registry.resubmitDelivery(rejected, "2", sbom, artifact, _components(), new uint256[](0));
        assertEq(registry.resubmittedDeliveryIds(rejected), 0);
    }

    function test_NonexistentRecordsAreRejected() public {
        vm.expectRevert(bytes("Delivery not found"));
        registry.getDelivery(0);
        vm.expectRevert(bytes("Delivery not found"));
        registry.getPreviousDeliveryIds(1);
        vm.expectRevert(bytes("Delivery not found"));
        registry.getDeliveryId(project, 1, 1);
    }

    function test_EmptySubmissionFieldsAreRejected() public {
        uint256 requestId = _request(d, c, project);
        vm.startPrank(d);
        vm.expectRevert(bytes("Version required"));
        registry.submitDelivery(requestId, "", sbom, artifact, _components(), new uint256[](0));
        vm.expectRevert(bytes("SBOM hash required"));
        registry.submitDelivery(requestId, "1", bytes32(0), artifact, _components(), new uint256[](0));
        vm.expectRevert(bytes("File hash required"));
        registry.submitDelivery(requestId, "1", sbom, bytes32(0), _components(), new uint256[](0));
        vm.stopPrank();
        assertEq(registry.deliveryCount(), 0);
    }

    function _add(address receiver, address supplier, uint256 id) private {
        vm.prank(receiver);
        registry.addSupplier(id, supplier);
    }

    function _components() private pure returns (string[] memory names) {
        names = new string[](1);
        names[0] = "Core";
    }

    function _request(address supplier, address receiver, uint256 id) private returns (uint256) {
        bytes32 key = keccak256(abi.encode(id, supplier, receiver));
        if (defaultRequirements[key] == 0) {
            vm.prank(receiver);
            defaultRequirements[key] = registry.createRequirement(id, supplier, "Product", _components());
        }
        return defaultRequirements[key];
    }

    function _submit(address supplier, address receiver, uint256 id, uint256[] memory previous) private returns (uint256) {
        uint256 requestId = _request(supplier, receiver, id);
        vm.prank(supplier);
        return registry.submitDelivery(requestId, "1", sbom, artifact, _components(), previous);
    }

    function _review(address receiver, uint256 id, DeliveryRegistry.Status status) private {
        vm.prank(receiver);
        registry.reviewDelivery(id, status, status == DeliveryRegistry.Status.Rejected ? "SBOM needs correction" : "");
    }

    event DeliveryLinked(uint256 indexed previousDeliveryId, uint256 indexed nextDeliveryId);

    function test_TraceBranchesAndMergeToFinalDelivery() public {
        uint256 input = _submit(d, c, project, new uint256[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        _request(c, b, project);
        vm.expectEmit(true, true, false, true);
        emit DeliveryLinked(input, input + 1);
        uint256 left = _submit(c, b, project, _one(input));
        uint256 right = _submit(c, b, project, _one(input));
        _review(b, left, DeliveryRegistry.Status.Approved);
        _review(b, right, DeliveryRegistry.Status.Approved);
        uint256[] memory branches = new uint256[](2);
        branches[0] = left;
        branches[1] = right;
        uint256 finalId = _submit(b, a, project, branches);
        _review(a, finalId, DeliveryRegistry.Status.Approved);
        (uint256[] memory next, uint256 total) = registry.getNextDeliveryIds(input, 0, 100);
        assertEq(total, 2);
        assertEq(next, branches);
        (next, total) = registry.getNextDeliveryIds(left, 0, 100);
        assertEq(next, _one(finalId));
        (next, total) = registry.getNextDeliveryIds(right, 0, 100);
        assertEq(next, _one(finalId));
        (next, total) = registry.getNextDeliveryIds(finalId, 0, 100);
        assertEq(total, 0);
        assertEq(next.length, 0);
        assertEq(registry.getPreviousDeliveryIds(finalId), branches);
        assertEq(registry.getPreviousDeliveryIds(left), _one(input));
        assertEq(_traceDescendantCount(input), 3);
    }

    function _traceDescendantCount(uint256 root) private view returns (uint256) {
        uint256[] memory queue = new uint256[](registry.deliveryCount());
        bool[] memory visited = new bool[](registry.deliveryCount() + 1);
        uint256 head;
        uint256 tail = 1;
        queue[0] = root;
        visited[root] = true;
        while (head < tail) {
            uint256 current = queue[head++];
            uint256 offset;
            while (true) {
                (uint256[] memory ids, uint256 total) = registry.getNextDeliveryIds(current, offset, 1);
                for (uint256 i = 0; i < ids.length; i++) {
                    if (!visited[ids[i]]) {
                        visited[ids[i]] = true;
                        queue[tail++] = ids[i];
                    }
                }
                offset += ids.length;
                if (offset >= total) break;
            }
        }
        return tail - 1;
    }

    function test_TracePreservesRejectedConsumersAndUsesRevisedInputs() public {
        uint256 first = _submit(d, c, project, new uint256[](0));
        uint256 second = _submit(e, c, project, new uint256[](0));
        _review(c, first, DeliveryRegistry.Status.Approved);
        _review(c, second, DeliveryRegistry.Status.Approved);
        uint256 original = _submit(c, b, project, _one(first));
        (uint256[] memory ids,) = registry.getNextDeliveryIds(first, 0, 10);
        assertEq(ids, _one(original));
        assertEq(uint256(registry.getDelivery(original).status), uint256(DeliveryRegistry.Status.Pending));
        _review(b, original, DeliveryRegistry.Status.Rejected);
        vm.prank(c);
        uint256 revised = registry.resubmitDelivery(original, "2", sbom, artifact, _components(), _one(second));
        (ids,) = registry.getNextDeliveryIds(first, 0, 10);
        assertEq(ids, _one(original));
        (ids,) = registry.getNextDeliveryIds(second, 0, 10);
        assertEq(ids, _one(revised));
        (ids,) = registry.getNextDeliveryIds(original, 0, 10);
        assertEq(ids.length, 0);
        assertEq(registry.resubmittedDeliveryIds(original), revised);
        assertEq(uint256(registry.getDelivery(original).status), uint256(DeliveryRegistry.Status.Rejected));
    }

    function test_FailedSubmissionsNeverCreateTraceEdges() public {
        uint256 input = _submit(d, c, project, new uint256[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        uint256[] memory duplicate = new uint256[](2);
        duplicate[0] = input;
        duplicate[1] = input;
        _expectBadLink(duplicate, "Duplicate previous delivery");
        uint256 requestId = _request(c, b, project);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _strings("Other"), _one(input));
        assertEq(registry.deliveryRequirementIds(2), 0);
        vm.expectRevert(bytes("Delivery not found"));
        registry.getDeliverySubmission(2);
        (uint256[] memory ids, uint256 total) = registry.getNextDeliveryIds(input, 0, 10);
        assertEq(total, 0);
        assertEq(ids.length, 0);
        assertEq(registry.deliveryCount(), 1);
    }

    function test_TraceRejectsInvalidQueriesAndIsolatesProjects() public {
        uint256 input = _submit(d, c, project, new uint256[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        vm.expectRevert(bytes("Delivery not found"));
        registry.getNextDeliveryIds(0, 0, 10);
        vm.expectRevert(bytes("Delivery not found"));
        registry.getNextDeliveryIds(999, 0, 10);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        registry.getNextDeliveryIds(input, 0, 0);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        registry.getNextDeliveryIds(input, 0, 101);
        vm.prank(b);
        uint256 second = registry.createProject("Other");
        _add(b, c, second);
        uint256 requestId = _request(c, b, second);
        vm.prank(c);
        vm.expectRevert(bytes("Previous delivery belongs to another project"));
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), _one(input));
        (uint256[] memory ids, uint256 total) = registry.getNextDeliveryIds(input, type(uint256).max, 100);
        assertEq(ids.length, 0);
        assertEq(total, 0);
    }

    function testFuzz_TracePaginationHasNoMissingOrDuplicateEntries(uint8 rawCount, uint8 rawLimit) public {
        uint256 count = uint256(rawCount) % 8 + 1;
        uint256 limit = uint256(rawLimit) % 4 + 1;
        uint256 input = _submit(d, c, project, new uint256[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        uint256[] memory expected = new uint256[](count);
        for (uint256 i = 0; i < count; i++) expected[i] = _submit(c, b, project, _one(input));
        uint256 offset;
        while (offset < count) {
            (uint256[] memory ids, uint256 total) = registry.getNextDeliveryIds(input, offset, limit);
            assertEq(total, count);
            assertTrue(ids.length > 0 && ids.length <= limit);
            for (uint256 i = 0; i < ids.length; i++) assertEq(ids[i], expected[offset + i]);
            offset += ids.length;
        }
        assertEq(offset, count);
        (uint256[] memory endIds,) = registry.getNextDeliveryIds(input, count, limit);
        assertEq(endIds.length, 0);
        (endIds,) = registry.getNextDeliveryIds(input, type(uint256).max, limit);
        assertEq(endIds.length, 0);
    }

    event DeliveryReviewed(uint256 indexed deliveryId, uint256 indexed projectId,
        uint256 stage, uint256 stageDeliveryNumber, address indexed reviewer,
        DeliveryRegistry.Status status, string note);

    function test_RejectionRequiresReasonWithoutChangingStateOnFailure() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.startPrank(c);
        vm.expectRevert(DeliveryRegistry.RejectionReasonRequired.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, "");
        vm.expectRevert(DeliveryRegistry.RejectionReasonRequired.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, " \t\r\n ");
        vm.stopPrank();
        assertEq(uint256(registry.getDelivery(id).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(registry.getDelivery(id).reviewedAt, 0);
        assertEq(registry.reviewNotes(id), "");
    }

    function test_RejectionReasonIsStoredEmittedAndPreservedAfterResubmission() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        string memory reason = unicode"SBOM에 모듈 버전이 빠져 있습니다.";
        vm.expectEmit(true, true, true, true);
        emit DeliveryReviewed(id, project, 3, 1, c, DeliveryRegistry.Status.Rejected, reason);
        vm.prank(c);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, reason);
        assertEq(registry.reviewNotes(id), reason);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.DeliveryAlreadyReviewed.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, "Changed reason");
        vm.prank(d);
        uint256 revised = registry.resubmitDelivery(id, "2", sbom, artifact, _components(), new uint256[](0));
        assertEq(registry.reviewNotes(revised), "");
        vm.prank(c);
        registry.reviewDelivery(revised, DeliveryRegistry.Status.Approved, "Version verified");
        assertEq(registry.reviewNotes(id), reason);
        assertEq(registry.reviewNotes(revised), "Version verified");
    }

    function test_ReviewNoteLengthLimitAndOptionalApprovalNote() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        uint256 limit = registry.MAX_REVIEW_NOTE_BYTES();
        bytes memory note = new bytes(limit + 1);
        for (uint256 i = 0; i < note.length; i++) note[i] = 0x61;
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ReviewNoteTooLong.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, string(note));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ReviewNoteTooLong.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved, string(note));
        bytes memory boundary = new bytes(limit);
        for (uint256 i = 0; i < boundary.length; i++) boundary[i] = 0x61;
        vm.prank(c);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, string(boundary));
        assertEq(bytes(registry.reviewNotes(id)).length, limit);
        uint256 other = _submit(e, c, project, new uint256[](0));
        _review(c, other, DeliveryRegistry.Status.Approved);
        assertEq(registry.reviewNotes(other), "");
    }

    function test_NonReceiverCannotStoreRejectionReason() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(id, DeliveryRegistry.Status.Rejected, "Unauthorized reason");
        assertEq(registry.reviewNotes(id), "");
        assertEq(uint256(registry.getDelivery(id).status), uint256(DeliveryRegistry.Status.Pending));
    }

    function _one(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _expectBadLink(uint256[] memory ids, string memory reason) private {
        uint256 requestId = _request(c, b, project);
        vm.prank(c);
        vm.expectRevert(bytes(reason));
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), ids);
    }

    function _strings(string memory name) private pure returns (string[] memory names) {
        names = new string[](1);
        names[0] = name;
    }

    function _pair(string memory first, string memory second) private pure returns (string[] memory names) {
        names = new string[](2);
        names[0] = first;
        names[1] = second;
    }

    function _newRequirement(string[] memory names) private returns (uint256) {
        vm.prank(b);
        return registry.createRequirement(project, c, unicode"쇼핑몰", names);
    }

    function _declare(uint256 requestId, string[] memory names) private returns (uint256) {
        vm.prank(c);
        return registry.submitDelivery(requestId, "1", sbom, artifact, names, new uint256[](0));
    }

    event RequirementCreated(uint256 indexed requirementId, uint256 indexed projectId,
        address indexed supplier, address receiver, string productName, string[] requiredComponents);
    event DeliverySubmitted(uint256 indexed deliveryId, uint256 indexed projectId, uint256 stage,
        uint256 stageDeliveryNumber, address indexed supplier, address receiver, uint256 requirementId);

    function test_RequirementStoresReceiverRequestAndEmitsEvent() public {
        string[] memory names = _pair(unicode"로그인", unicode"결제");
        vm.expectEmit(true, true, true, true);
        emit RequirementCreated(1, project, c, b, unicode"쇼핑몰", names);
        uint256 requestId = _newRequirement(names);
        DeliveryRegistry.Requirement memory item = registry.getRequirement(requestId);
        assertEq(requestId, 1);
        assertEq(registry.requirementCount(), 1);
        assertEq(item.projectId, project);
        assertEq(item.supplier, c);
        assertEq(item.receiver, b);
        assertEq(item.productName, unicode"쇼핑몰");
        assertEq(item.createdAt, block.timestamp);
        assertEq(keccak256(abi.encode(item.requiredComponents)), keccak256(abi.encode(names)));
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        registry.getRequirement(0);
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        registry.getRequirement(2);
    }

    function test_OnlyDirectReceiverCreatesRequirement() public {
        address[5] memory callers = [a, c, d, outsider, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
            registry.createRequirement(project, c, "Product", _components());
        }
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
        registry.createRequirement(project, d, "Product", _components());
        vm.prank(b);
        vm.expectRevert(bytes("Project not found"));
        registry.createRequirement(999, c, "Product", _components());
        assertEq(registry.requirementCount(), 0);
        _newRequirement(_components());
        vm.prank(c);
        uint256 lowerRequest = registry.createRequirement(project, d, "Library", _components());
        assertEq(registry.getRequirement(lowerRequest).receiver, c);
    }

    function _invalidNameInEveryPosition(string memory name) private {
        uint256 requestId = _request(c, b, project);
        uint256 beforeCount = registry.requirementCount();
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        registry.createRequirement(project, c, name, _components());
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        registry.createRequirement(project, c, "Product", _strings(name));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _strings(name), new uint256[](0));
        assertEq(registry.requirementCount(), beforeCount);
        assertEq(registry.deliveryCount(), 0);
    }

    function test_EmptyAndASCIIAndUnicodeWhitespaceNamesAreRejected() public {
        _invalidNameInEveryPosition("");
        _invalidNameInEveryPosition(" ");
        _invalidNameInEveryPosition(string(hex"090a0d0b0c"));
        _invalidNameInEveryPosition(string(hex"c2a0"));
        _invalidNameInEveryPosition(string(hex"e38080"));
        _invalidNameInEveryPosition(string(hex"20c2a009e380800a20"));
    }

    function _names(uint256 count) private pure returns (string[] memory names) {
        names = new string[](count);
        for (uint256 i = 0; i < count; i++) names[i] = string(abi.encodePacked("Component", bytes1(uint8(65 + i))));
    }

    function _longName(uint256 length) private pure returns (string memory) {
        bytes memory value = new bytes(length);
        for (uint256 i = 0; i < length; i++) value[i] = 0x61;
        return string(value);
    }

    function test_ComponentCountLimitsAndDuplicatesApplyToBothLists() public {
        uint256 requestId = _newRequirement(_components());
        string[][] memory bad = new string[][](3);
        bad[0] = new string[](0);
        bad[1] = _names(33);
        bad[2] = _pair("Core", "Core");
        for (uint256 i = 0; i < bad.length; i++) {
            bytes4 expected = i == 2 ? DeliveryRegistry.DuplicateComponent.selector : DeliveryRegistry.InvalidComponentCount.selector;
            vm.prank(b);
            vm.expectRevert(expected);
            registry.createRequirement(project, c, "Product", bad[i]);
            vm.prank(c);
            vm.expectRevert(expected);
            registry.submitDelivery(requestId, "1", sbom, artifact, bad[i], new uint256[](0));
        }
        assertEq(registry.requirementCount(), 1);
        assertEq(registry.deliveryCount(), 0);
        string[] memory boundary = _names(32);
        uint256 maxRequest = _newRequirement(boundary);
        uint256 id = _declare(maxRequest, boundary);
        (, string[] memory saved) = registry.getDeliverySubmission(id);
        assertEq(saved.length, 32);
    }

    function test_NameLengthLimitUsesBytesAndAcceptsBoundary() public {
        _invalidNameInEveryPosition(_longName(129));
        _invalidNameInEveryPosition(string(abi.encodePacked(_longName(126), unicode"가")));
        string memory boundary = string(abi.encodePacked(_longName(125), unicode"가"));
        assertEq(bytes(boundary).length, 128);
        vm.prank(b);
        uint256 requestId = registry.createRequirement(project, c, boundary, _strings(boundary));
        uint256 id = _declare(requestId, _strings(boundary));
        assertEq(registry.getDelivery(id).productName, boundary);
        (, string[] memory saved) = registry.getDeliverySubmission(id);
        assertEq(saved[0], boundary);
    }

    function test_SubmissionStoresDeclarationAndRequirementWithoutLowerDelivery() public {
        uint256 requestId = _newRequirement(_pair(unicode"로그인", unicode"결제"));
        string[] memory declaration = new string[](3);
        declaration[0] = unicode"결제";
        declaration[1] = " Extra ";
        declaration[2] = unicode"로그인";
        vm.expectEmit(true, true, true, true);
        emit DeliverySubmitted(1, project, 2, 1, c, b, requestId);
        uint256 id = _declare(requestId, declaration);
        DeliveryRegistry.Delivery memory delivery = registry.getDelivery(id);
        assertEq(delivery.projectId, project);
        assertEq(delivery.supplier, c);
        assertEq(delivery.receiver, b);
        assertEq(delivery.productName, unicode"쇼핑몰");
        assertEq(uint256(delivery.status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(delivery.sbomHash, sbom);
        assertEq(delivery.fileHash, artifact);
        assertEq(delivery.submittedAt, block.timestamp);
        assertEq(registry.getPreviousDeliveryIds(id).length, 0);
        (uint256 linked, string[] memory saved) = registry.getDeliverySubmission(id);
        assertEq(linked, requestId);
        assertEq(keccak256(abi.encode(saved)), keccak256(abi.encode(declaration)));
    }

    function test_MissingAndDifferentCaseComponentsCannotSatisfyRequest() public {
        uint256 requestId = _newRequirement(_pair("Login", "Payment"));
        string[][] memory bad = new string[][](4);
        bad[0] = _strings("Login");
        bad[1] = _pair("Login", "Other");
        bad[2] = _pair("login", "Payment");
        bad[3] = _pair("Login ", "Payment");
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(c);
            vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
            registry.submitDelivery(requestId, "1", sbom, artifact, bad[i], new uint256[](0));
        }
        assertEq(registry.deliveryCount(), 0);
        assertEq(registry.projectDeliveryCounts(project), 0);
        assertEq(registry.stageDeliveryCounts(project, 2), 0);
        assertEq(registry.deliveryRequirementIds(1), 0);
        _declare(requestId, _pair("Payment", "Login"));
    }

    function test_NamesAreNotTrimmedOrUnicodeNormalized() public {
        string memory padded = string(abi.encodePacked(hex"c2a0", "Login", hex"e38080"));
        uint256 requestId = _newRequirement(_pair(padded, unicode"é"));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _pair("Login", unicode"é"), new uint256[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _pair(padded, string(hex"65cc81")), new uint256[](0));
        uint256 id = _declare(requestId, _pair(padded, unicode"é"));
        (, string[] memory saved) = registry.getDeliverySubmission(id);
        assertEq(saved[0], padded);
        uint256 distinct = _newRequirement(_pair("Login", "login"));
        _declare(distinct, _pair("login", "Login"));
    }

    function test_RequestsWithSameProductAreIndependentAndReusable() public {
        uint256 first = _newRequirement(_strings("Login"));
        bytes32 originalRequest = keccak256(abi.encode(registry.getRequirement(first)));
        uint256 second = _newRequirement(_strings("Payment"));
        uint256 firstDelivery = _declare(first, _strings("Login"));
        uint256 repeated = _declare(first, _strings("Login"));
        assertTrue(firstDelivery != repeated);
        assertEq(registry.deliveryRequirementIds(repeated), first);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(second, "1", sbom, artifact, _strings("Login"), new uint256[](0));
        uint256 secondDelivery = _declare(second, _strings("Payment"));
        assertEq(registry.deliveryRequirementIds(secondDelivery), second);
        assertEq(keccak256(abi.encode(registry.getRequirement(first))), originalRequest);
        assertEq(registry.replacesDeliveryIds(repeated), 0);
    }

    function test_NonexistentRequirementCannotBeSubmitted() public {
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        registry.submitDelivery(0, "1", sbom, artifact, _components(), new uint256[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        registry.submitDelivery(999, "1", sbom, artifact, _components(), new uint256[](0));
    }

    function test_ResubmissionKeepsRequestAndOriginalDeclarationAndReview() public {
        uint256 requestId = _newRequirement(_pair("Login", "Payment"));
        uint256 id = _declare(requestId, _pair("Payment", "Login"));
        _review(b, id, DeliveryRegistry.Status.Rejected);
        bytes32 original = keccak256(abi.encode(registry.getDelivery(id)));
        _newRequirement(_strings("Login"));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.resubmitDelivery(id, "2", sbom, artifact, _strings("Login"), new uint256[](0));
        assertEq(registry.resubmittedDeliveryIds(id), 0);
        assertEq(registry.deliveryCount(), 1);
        string[] memory declaration = new string[](3);
        declaration[0] = "Login";
        declaration[1] = "Payment";
        declaration[2] = "Search";
        vm.prank(c);
        uint256 revised = registry.resubmitDelivery(id, "2", keccak256("changed SBOM"), keccak256("changed file"), declaration, new uint256[](0));
        assertEq(registry.deliveryRequirementIds(revised), requestId);
        assertEq(registry.deliveryRequirementIds(id), requestId);
        assertEq(keccak256(abi.encode(registry.getDelivery(id))), original);
        assertEq(registry.reviewNotes(id), "SBOM needs correction");
        (, string[] memory savedOriginal) = registry.getDeliverySubmission(id);
        assertEq(savedOriginal[0], "Payment");
        assertEq(savedOriginal[1], "Login");
        (, string[] memory savedRevised) = registry.getDeliverySubmission(revised);
        assertEq(keccak256(abi.encode(savedRevised)), keccak256(abi.encode(declaration)));
        assertEq(registry.reviewNotes(revised), "");
        assertEq(registry.getDelivery(revised).reviewedAt, 0);
        assertEq(uint256(registry.getDelivery(revised).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(registry.replacesDeliveryIds(revised), id);
        assertEq(registry.resubmittedDeliveryIds(id), revised);
    }
}
