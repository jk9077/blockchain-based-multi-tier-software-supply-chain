pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeliveryRegistry} from "../contracts/DeliveryRegistry.sol";

contract DeliveryRegistryTest is Test {
    DeliveryRegistry registry;
    mapping(bytes32 => string) defaultRequirements;
    mapping(string => DeliveryKey) requirementKeys;
    mapping(uint256 => mapping(uint256 => uint256)) requirementSequences;
    struct DeliveryKey { uint256 projectId; uint256 stage; uint256 sequence; }
    mapping(string => DeliveryKey) keys;
    mapping(uint256 => mapping(address => uint256)) depths;
    mapping(uint256 => mapping(uint256 => uint256)) sequences;
    mapping(uint256 => address) readers;
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
        readers[project] = a;
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
        readers[ownProject] = outsider;
        vm.prank(_reader(ownProject));
        assertTrue(registry.projectMembers(ownProject, outsider));
        vm.prank(_reader(project));
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
        vm.prank(_reader(project));
        assertTrue(registry.projectMembers(project, outsider));
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, outsider), d);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, outsider), 4);
        _add(outsider, address(99), project);
        assertTrue(registry.registeredCompanies(address(99)));
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, address(99)), outsider);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, address(99)), 5);
    }

    function test_RegisteredCompanyCreatesProjectAsCustomer() public {
        vm.expectEmit(true, true, false, true);
        emit ProjectCreated(2, "Project B", b);
        vm.prank(b);
        uint256 id = registry.createProject("Project B");
        readers[id] = b;
        vm.prank(_reader(id));
        (string memory name, address customer, uint256 createdAt) = registry.projects(id);
        assertEq(name, "Project B");
        assertEq(customer, b);
        assertEq(createdAt, block.timestamp);
        vm.prank(_reader(id));
        assertTrue(registry.projectMembers(id, b));
        vm.prank(_reader(id));
        assertEq(registry.companyDepths(id, b), 0);
        vm.prank(_reader(id));
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

    function test_DelegatedTreeHasAutomaticDepthAndFixedReceiver() public {
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, b), a);
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, c), b);
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, d), c);
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, e), c);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, a), 0);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, b), 1);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, c), 2);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, d), 3);
        vm.prank(_reader(project));
        assertEq(registry.routeStages(project, d, c), 3);
        vm.prank(_reader(project));
        assertTrue(registry.allowedRoutes(project, d, c));
        vm.prank(_reader(project));
        assertFalse(registry.allowedRoutes(project, d, b));
    }

    function test_AddSupplierEmitsRouteAndPreservesExistingDepths() public {
        vm.expectEmit(true, true, true, true);
        emit RouteAllowed(project, outsider, d, 4);
        _add(d, outsider, project);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, outsider), 4);
        vm.prank(_reader(project));
        assertEq(registry.companyDepths(project, b), 1);
        vm.prank(_reader(project));
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
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, d), c);
    }

    function test_ProjectsHaveSeparateMembershipRoutesAndNumbers() public {
        vm.prank(e);
        uint256 second = registry.createProject("Project B");
        readers[second] = e;
        vm.prank(a);
        vm.expectRevert(bytes("Not a project member"));
        registry.addSupplier(second, b);
        _add(e, d, second);
        vm.prank(_reader(second));
        assertEq(registry.parentCompanies(second, d), e);
        vm.prank(_reader(project));
        assertEq(registry.parentCompanies(project, d), c);
        string memory firstId = _submit(d, c, project, new string[](0));
        string memory secondId = _submit(d, e, second, new string[](0));
        vm.prank(_reader(project));
        assertEq(registry.getDeliveryId(project, 3, 1), firstId);
        vm.prank(_reader(second));
        assertEq(registry.getDeliveryId(second, 1, 1), secondId);
        vm.prank(_reader(project));
        assertEq(registry.projectDeliveryCounts(project), 1);
        vm.prank(_reader(second));
        assertEq(registry.projectDeliveryCounts(second), 1);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
        _createRequirement(second, d, "Product", _components());
    }

    function test_ProjectQueryShowsCompositeNumbersAndMergedPath() public {
        string memory did = _submit(d, c, project, new string[](0));
        string memory eid = _submit(e, c, project, new string[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _review(c, eid, DeliveryRegistry.Status.Approved);
        string[] memory sources = new string[](2);
        sources[0] = did;
        sources[1] = eid;
        string memory cid = _submit(c, b, project, sources);
        _review(b, cid, DeliveryRegistry.Status.Approved);
        string memory bid = _submit(b, a, project, _one(cid));
        vm.prank(_reader(project));
        (DeliveryRegistry.Project memory info, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(project, 0, 20);
        assertEq(info.name, "Project A");
        assertEq(info.customer, a);
        assertEq(info.createdAt, block.timestamp);
        assertEq(total, 4);
        assertEq(items.length, 4);
        assertEq(items[0].deliveryId, "1-3-1");
        assertEq(items[1].deliveryId, "1-3-2");
        assertEq(items[2].deliveryId, "1-2-1");
        assertEq(items[3].deliveryId, "1-1-1");
        assertEq(items[0].previousDeliveryIds.length, 0);
        assertEq(items[2].previousDeliveryIds.length, 2);
        assertEq(items[2].previousDeliveryIds[0], "1-3-1");
        assertEq(items[2].previousDeliveryIds[1], "1-3-2");
        assertEq(items[3].previousDeliveryIds[0], "1-2-1");
        assertEq(items[3].deliveryId, bid);
        assertEq(items[3].supplier, b);
        assertEq(items[3].receiver, a);
        assertEq(uint256(items[3].status), uint256(DeliveryRegistry.Status.Pending));
        _review(a, bid, DeliveryRegistry.Status.Approved);
        vm.prank(_reader(project));
        (, items, total) = registry.getProject(project, 3, 1);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, "1-1-1");
        assertEq(items[0].previousDeliveryIds[0], "1-2-1");
        assertEq(uint256(items[0].status), uint256(DeliveryRegistry.Status.Approved));
        assertEq(total, 4);
    }

    function test_ProjectQueryPaginatesInterleavedProjectsAndKeepsResubmissions() public {
        string memory original = _submit(d, c, project, new string[](0));
        vm.prank(e);
        uint256 second = registry.createProject("Second");
        readers[second] = e;
        _add(e, d, second);
        string memory other = _submit(d, e, second, new string[](0));
        _review(c, original, DeliveryRegistry.Status.Rejected);
        vm.prank(d);
        string memory revised = _resubmit(original, "2", sbom, artifact, _components(), new string[](0));
        vm.prank(_reader(project));
        (, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(project, 0, 1);
        assertEq(total, 2);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, original);
        assertEq(items[0].deliveryId, "1-3-1");
        assertEq(uint256(items[0].status), uint256(DeliveryRegistry.Status.Rejected));
        vm.prank(_reader(project));
        (, items, total) = registry.getProject(project, 1, 100);
        assertEq(total, 2);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, revised);
        assertEq(items[0].deliveryId, "1-3-2");
        assertEq(uint256(items[0].status), uint256(DeliveryRegistry.Status.Pending));
        vm.prank(_reader(second));
        (, items, total) = registry.getProject(second, 0, 100);
        assertEq(total, 1);
        assertEq(items.length, 1);
        assertEq(items[0].deliveryId, other);
        assertEq(items[0].deliveryId, "2-1-1");
    }

    function test_ProjectQueryHandlesEmptyPagesAndRejectsInvalidQueries() public {
        vm.prank(_reader(project));
        (, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(project, 0, 10);
        assertEq(items.length, 0);
        assertEq(total, 0);
        _submit(d, c, project, new string[](0));
        vm.prank(_reader(project));
        (, items, total) = registry.getProject(project, 1, 10);
        assertEq(items.length, 0);
        assertEq(total, 1);
        vm.prank(_reader(project));
        (, items, total) = registry.getProject(project, type(uint256).max, 10);
        assertEq(items.length, 0);
        assertEq(total, 1);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        vm.prank(_reader(project));
        registry.getProject(project, 0, 0);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        vm.prank(_reader(project));
        registry.getProject(project, 0, 101);
        vm.expectRevert(bytes("Project not found"));
        vm.prank(_reader(0));
        registry.getProject(0, 0, 10);
        vm.expectRevert(bytes("Project not found"));
        vm.prank(_reader(2));
        registry.getProject(2, 0, 10);
    }

    function test_ProjectQueryFormatsMultiDigitProjectStageAndSequence() public {
        uint256 target;
        for (uint256 i = 0; i < 9; i++) {
            vm.prank(a);
            target = registry.createProject("Multi digit");
            readers[target] = a;
        }
        address parent = a;
        for (uint256 i = 1; i <= 10; i++) {
            address child = address(uint160(100 + i));
            _add(parent, child, target);
            parent = child;
        }
        for (uint256 i = 0; i < 10; i++) {
            _submit(address(110), address(109), target, new string[](0));
        }
        vm.prank(_reader(target));
        (, DeliveryRegistry.ProjectDelivery[] memory items, uint256 total) = registry.getProject(target, 9, 1);
        assertEq(total, 10);
        assertEq(items[0].deliveryId, "10-10-10");
    }

    function test_FullSupplyChainAndProjectNumbering() public {
        string memory did = _submit(d, c, project, new string[](0));
        string memory eid = _submit(e, c, project, new string[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _review(c, eid, DeliveryRegistry.Status.Approved);
        string[] memory sources = new string[](2);
        sources[0] = did;
        sources[1] = eid;
        string memory cid = _submit(c, b, project, sources);
        _review(b, cid, DeliveryRegistry.Status.Approved);
        string memory bid = _submit(b, a, project, _one(cid));
        _review(a, bid, DeliveryRegistry.Status.Approved);
        vm.prank(_reader(keys[cid].projectId));
        assertEq(registry.getPreviousDeliveryIds(keys[cid].projectId, keys[cid].stage, keys[cid].sequence), sources);
        vm.prank(_reader(keys[bid].projectId));
        assertEq(registry.getPreviousDeliveryIds(keys[bid].projectId, keys[bid].stage, keys[bid].sequence), _one(cid));
        vm.prank(_reader(project));
        assertEq(registry.getDeliveryId(project, 3, 1), did);
        vm.prank(_reader(project));
        assertEq(registry.getDeliveryId(project, 3, 2), eid);
        vm.prank(_reader(project));
        assertEq(registry.getDeliveryId(project, 2, 1), cid);
        vm.prank(_reader(project));
        assertEq(registry.getDeliveryId(project, 1, 1), bid);
        vm.prank(_reader(project));
        assertEq(registry.projectDeliveryCounts(project), 4);
        vm.prank(_reader(keys[did].projectId));
        DeliveryRegistry.Delivery memory saved = registry.getDelivery(keys[did].projectId, keys[did].stage, keys[did].sequence);
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
        string memory requestId = _request(c, b, project);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyRequiredSupplierCanSubmit.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), new string[](0));
        vm.prank(outsider);
        vm.expectRevert(DeliveryRegistry.OnlyRequiredSupplierCanSubmit.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), new string[](0));
        assertEq(registry.deliveryCount(), 0);
    }

    function test_DeployerAndCustomerCannotReviewOthersDeliveries() public {
        string memory id = _submit(d, c, project, new string[](0));
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Approved, "");
        vm.prank(a);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Approved, "");
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Approved, "");
        vm.prank(_reader(keys[id].projectId));
        assertEq(uint256(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).status), uint256(DeliveryRegistry.Status.Pending));
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).reviewedAt, 0);
        vm.warp(block.timestamp + 10);
        _review(c, id, DeliveryRegistry.Status.Rejected);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).reviewedAt, block.timestamp);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.DeliveryAlreadyReviewed.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Approved, "");
    }

    function test_InvalidReviewStatusIsBlocked() public {
        string memory id = _submit(d, c, project, new string[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.InvalidReviewStatus.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Pending, "");
    }

    function test_PendingRejectedAndDuplicateLinksAreBlocked() public {
        string memory id = _submit(d, c, project, new string[](0));
        _expectBadLink(_one(id), "Previous delivery not approved");
        _review(c, id, DeliveryRegistry.Status.Rejected);
        _expectBadLink(_one(id), "Previous delivery not approved");
        string memory approved = _submit(e, c, project, new string[](0));
        _review(c, approved, DeliveryRegistry.Status.Approved);
        string[] memory ids = new string[](2);
        ids[0] = approved;
        ids[1] = approved;
        _expectBadLink(ids, "Duplicate previous delivery");
        assertEq(registry.deliveryCount(), 2);
        vm.prank(_reader(project));
        assertEq(registry.stageDeliveryCounts(project, 2), 0);
    }

    function test_CrossProjectAndUnreceivedLinksAreBlocked() public {
        vm.prank(c);
        uint256 second = registry.createProject("Other");
        readers[second] = c;
        _add(c, d, second);
        string memory id = _submit(d, c, second, new string[](0));
        _review(c, id, DeliveryRegistry.Status.Approved);
        _expectBadLink(_one(id), "Previous delivery belongs to another project");
        id = _submit(b, a, project, new string[](0));
        _review(a, id, DeliveryRegistry.Status.Approved);
        _expectBadLink(_one(id), "Previous delivery was not received by supplier");
        _expectBadLink(_one("999"), "Delivery not found");
    }

    function test_ResubmissionPreservesOriginalAndCanRepeatAfterRejection() public {
        string memory id = _submit(d, c, project, new string[](0));
        _review(c, id, DeliveryRegistry.Status.Rejected);
        vm.prank(_reader(keys[id].projectId));
        bytes32 original = keccak256(abi.encode(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence)));
        vm.prank(d);
        string memory revised = _resubmit(id, "2", keccak256("new SBOM"), keccak256("new artifact"), _components(), new string[](0));
        vm.prank(_reader(keys[id].projectId));
        assertEq(keccak256(abi.encode(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence))), original);
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.replacesDeliveryIds(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), id);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.resubmittedDeliveryIds(keys[id].projectId, keys[id].stage, keys[id].sequence), revised);
        vm.prank(_reader(keys[revised].projectId));
        DeliveryRegistry.Delivery memory saved = registry.getDelivery(keys[revised].projectId, keys[revised].stage, keys[revised].sequence);
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
        _resubmit(id, "3", sbom, artifact, _components(), new string[](0));
        _review(c, revised, DeliveryRegistry.Status.Rejected);
        vm.prank(d);
        string memory third = _resubmit(revised, "3", sbom, artifact, _components(), new string[](0));
        _review(c, third, DeliveryRegistry.Status.Approved);
        vm.prank(_reader(keys[third].projectId));
        assertEq(registry.replacesDeliveryIds(keys[third].projectId, keys[third].stage, keys[third].sequence), revised);
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.resubmittedDeliveryIds(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), third);
    }

    function test_ResubmissionRequiresOriginalSupplierAndRejection() public {
        string memory id = _submit(d, c, project, new string[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyRejectedDeliveryCanBeResubmitted.selector);
        _resubmit(id, "2", sbom, artifact, _components(), new string[](0));
        _review(c, id, DeliveryRegistry.Status.Approved);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyRejectedDeliveryCanBeResubmitted.selector);
        _resubmit(id, "2", sbom, artifact, _components(), new string[](0));
        string memory rejected = _submit(d, c, project, new string[](0));
        _review(c, rejected, DeliveryRegistry.Status.Rejected);
        vm.prank(e);
        vm.expectRevert(DeliveryRegistry.OnlyOriginalSupplierCanResubmit.selector);
        _resubmit(rejected, "2", sbom, artifact, _components(), new string[](0));
        vm.prank(_reader(keys[rejected].projectId));
        assertEq(registry.resubmittedDeliveryIds(keys[rejected].projectId, keys[rejected].stage, keys[rejected].sequence), "");
    }

    function test_NonexistentRecordsAreRejected() public {
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.getDelivery(project, 1, 0);
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.getPreviousDeliveryIds(project, 1, 1);
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.getDeliveryId(project, 1, 1);
    }

    function test_EmptySubmissionFieldsAreRejected() public {
        string memory requestId = _request(d, c, project);
        vm.startPrank(d);
        vm.expectRevert(bytes("Version required"));
        registry.submitDelivery(requestId, "", sbom, artifact, _components(), new string[](0));
        vm.expectRevert(bytes("SBOM hash required"));
        registry.submitDelivery(requestId, "1", bytes32(0), artifact, _components(), new string[](0));
        vm.expectRevert(bytes("File hash required"));
        registry.submitDelivery(requestId, "1", sbom, bytes32(0), _components(), new string[](0));
        vm.stopPrank();
        assertEq(registry.deliveryCount(), 0);
    }

    function _add(address receiver, address supplier, uint256 id) private {
        vm.prank(receiver);
        registry.addSupplier(id, supplier);
        depths[id][supplier] = depths[id][receiver] + 1;
    }

    function _components() private pure returns (string[] memory names) {
        names = new string[](1);
        names[0] = "Core";
    }

    function _request(address supplier, address receiver, uint256 id) private returns (string memory) {
        bytes32 key = keccak256(abi.encode(id, supplier, receiver));
        if (bytes(defaultRequirements[key]).length == 0) {
            vm.prank(receiver);
            defaultRequirements[key] = _createRequirement(id, supplier, "Product", _components());
        }
        return defaultRequirements[key];
    }

    function _submit(address supplier, address receiver, uint256 id, string[] memory previous) private returns (string memory) {
        string memory requestId = _request(supplier, receiver, id);
        vm.prank(supplier);
        string memory deliveryId = registry.submitDelivery(requestId, "1", sbom, artifact, _components(), previous);
        _record(deliveryId, id, depths[id][supplier]);
        return deliveryId;
    }

    function _review(address receiver, string memory id, DeliveryRegistry.Status status) private {
        vm.prank(receiver);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, status, status == DeliveryRegistry.Status.Rejected ? "SBOM needs correction" : "");
    }

    event DeliveryLinked(string previousDeliveryId, string nextDeliveryId);

    function test_TraceBranchesAndMergeToFinalDelivery() public {
        string memory input = _submit(d, c, project, new string[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        _request(c, b, project);
        vm.expectEmit(false, false, false, true);
        emit DeliveryLinked(input, "1-2-1");
        string memory left = _submit(c, b, project, _one(input));
        string memory right = _submit(c, b, project, _one(input));
        _review(b, left, DeliveryRegistry.Status.Approved);
        _review(b, right, DeliveryRegistry.Status.Approved);
        string[] memory branches = new string[](2);
        branches[0] = left;
        branches[1] = right;
        string memory finalId = _submit(b, a, project, branches);
        _review(a, finalId, DeliveryRegistry.Status.Approved);
        vm.prank(_reader(keys[input].projectId));
        (string[] memory next, uint256 total) = registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, 0, 100);
        assertEq(total, 2);
        assertEq(next, branches);
        vm.prank(_reader(keys[left].projectId));
        (next, total) = registry.getNextDeliveryIds(keys[left].projectId, keys[left].stage, keys[left].sequence, 0, 100);
        assertEq(next, _one(finalId));
        vm.prank(_reader(keys[right].projectId));
        (next, total) = registry.getNextDeliveryIds(keys[right].projectId, keys[right].stage, keys[right].sequence, 0, 100);
        assertEq(next, _one(finalId));
        vm.prank(_reader(keys[finalId].projectId));
        (next, total) = registry.getNextDeliveryIds(keys[finalId].projectId, keys[finalId].stage, keys[finalId].sequence, 0, 100);
        assertEq(total, 0);
        assertEq(next.length, 0);
        vm.prank(_reader(keys[finalId].projectId));
        assertEq(registry.getPreviousDeliveryIds(keys[finalId].projectId, keys[finalId].stage, keys[finalId].sequence), branches);
        vm.prank(_reader(keys[left].projectId));
        assertEq(registry.getPreviousDeliveryIds(keys[left].projectId, keys[left].stage, keys[left].sequence), _one(input));
        assertEq(_traceDescendantCount(input), 3);
    }

    function _traceDescendantCount(string memory root) private returns (uint256) {
        string[] memory queue = new string[](registry.deliveryCount());
        uint256 head;
        uint256 tail = 1;
        queue[0] = root;
        while (head < tail) {
            string memory current = queue[head++];
            uint256 offset;
            while (true) {
                vm.prank(_reader(keys[current].projectId));
                (string[] memory ids, uint256 total) = registry.getNextDeliveryIds(keys[current].projectId, keys[current].stage, keys[current].sequence, offset, 1);
                for (uint256 i = 0; i < ids.length; i++) {
                    bool seen;
                    for (uint256 j = 0; j < tail; j++) {
                        if (keccak256(bytes(queue[j])) == keccak256(bytes(ids[i]))) seen = true;
                    }
                    if (!seen) queue[tail++] = ids[i];
                }
                offset += ids.length;
                if (offset >= total) break;
            }
        }
        return tail - 1;
    }

    function test_TracePreservesRejectedConsumersAndUsesRevisedInputs() public {
        string memory first = _submit(d, c, project, new string[](0));
        string memory second = _submit(e, c, project, new string[](0));
        _review(c, first, DeliveryRegistry.Status.Approved);
        _review(c, second, DeliveryRegistry.Status.Approved);
        string memory original = _submit(c, b, project, _one(first));
        vm.prank(_reader(keys[first].projectId));
        (string[] memory ids,) = registry.getNextDeliveryIds(keys[first].projectId, keys[first].stage, keys[first].sequence, 0, 10);
        assertEq(ids, _one(original));
        vm.prank(_reader(keys[original].projectId));
        assertEq(uint256(registry.getDelivery(keys[original].projectId, keys[original].stage, keys[original].sequence).status), uint256(DeliveryRegistry.Status.Pending));
        _review(b, original, DeliveryRegistry.Status.Rejected);
        vm.prank(c);
        string memory revised = _resubmit(original, "2", sbom, artifact, _components(), _one(second));
        vm.prank(_reader(keys[first].projectId));
        (ids,) = registry.getNextDeliveryIds(keys[first].projectId, keys[first].stage, keys[first].sequence, 0, 10);
        assertEq(ids, _one(original));
        vm.prank(_reader(keys[second].projectId));
        (ids,) = registry.getNextDeliveryIds(keys[second].projectId, keys[second].stage, keys[second].sequence, 0, 10);
        assertEq(ids, _one(revised));
        vm.prank(_reader(keys[original].projectId));
        (ids,) = registry.getNextDeliveryIds(keys[original].projectId, keys[original].stage, keys[original].sequence, 0, 10);
        assertEq(ids.length, 0);
        vm.prank(_reader(keys[original].projectId));
        assertEq(registry.resubmittedDeliveryIds(keys[original].projectId, keys[original].stage, keys[original].sequence), revised);
        vm.prank(_reader(keys[original].projectId));
        assertEq(uint256(registry.getDelivery(keys[original].projectId, keys[original].stage, keys[original].sequence).status), uint256(DeliveryRegistry.Status.Rejected));
    }

    function test_FailedSubmissionsNeverCreateTraceEdges() public {
        string memory input = _submit(d, c, project, new string[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        string[] memory duplicate = new string[](2);
        duplicate[0] = input;
        duplicate[1] = input;
        _expectBadLink(duplicate, "Duplicate previous delivery");
        string memory requestId = _request(c, b, project);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _strings("Other"), _one(input));
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.deliveryRequirementIds(project, 2, 1);
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.getDeliverySubmission(project, 1, 2);
        vm.prank(_reader(keys[input].projectId));
        (string[] memory ids, uint256 total) = registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, 0, 10);
        assertEq(total, 0);
        assertEq(ids.length, 0);
        assertEq(registry.deliveryCount(), 1);
    }

    function test_TraceRejectsInvalidQueriesAndIsolatesProjects() public {
        string memory input = _submit(d, c, project, new string[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.getNextDeliveryIds(project, 1, 0, 0, 10);
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.getNextDeliveryIds(project, 1, 999, 0, 10);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        vm.prank(_reader(keys[input].projectId));
        registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, 0, 0);
        vm.expectRevert(DeliveryRegistry.InvalidPageSize.selector);
        vm.prank(_reader(keys[input].projectId));
        registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, 0, 101);
        vm.prank(b);
        uint256 second = registry.createProject("Other");
        readers[second] = b;
        _add(b, c, second);
        string memory requestId = _request(c, b, second);
        vm.prank(c);
        vm.expectRevert(bytes("Previous delivery belongs to another project"));
        registry.submitDelivery(requestId, "1", sbom, artifact, _components(), _one(input));
        vm.prank(_reader(keys[input].projectId));
        (string[] memory ids, uint256 total) = registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, type(uint256).max, 100);
        assertEq(ids.length, 0);
        assertEq(total, 0);
    }

    function testFuzz_TracePaginationHasNoMissingOrDuplicateEntries(uint8 rawCount, uint8 rawLimit) public {
        uint256 count = uint256(rawCount) % 8 + 1;
        uint256 limit = uint256(rawLimit) % 4 + 1;
        string memory input = _submit(d, c, project, new string[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        string[] memory expected = new string[](count);
        for (uint256 i = 0; i < count; i++) expected[i] = _submit(c, b, project, _one(input));
        uint256 offset;
        while (offset < count) {
            vm.prank(_reader(keys[input].projectId));
            (string[] memory ids, uint256 total) = registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, offset, limit);
            assertEq(total, count);
            assertTrue(ids.length > 0 && ids.length <= limit);
            for (uint256 i = 0; i < ids.length; i++) assertEq(ids[i], expected[offset + i]);
            offset += ids.length;
        }
        assertEq(offset, count);
        vm.prank(_reader(keys[input].projectId));
        (string[] memory endIds,) = registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, count, limit);
        assertEq(endIds.length, 0);
        vm.prank(_reader(keys[input].projectId));
        (endIds,) = registry.getNextDeliveryIds(keys[input].projectId, keys[input].stage, keys[input].sequence, type(uint256).max, limit);
        assertEq(endIds.length, 0);
    }

    event DeliveryReviewed(string deliveryId, uint256 indexed projectId,
        uint256 stage, uint256 stageDeliveryNumber, address indexed reviewer,
        DeliveryRegistry.Status status, string note);

    function test_RejectionRequiresReasonWithoutChangingStateOnFailure() public {
        string memory id = _submit(d, c, project, new string[](0));
        vm.startPrank(c);
        vm.expectRevert(DeliveryRegistry.RejectionReasonRequired.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, "");
        vm.expectRevert(DeliveryRegistry.RejectionReasonRequired.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, " \t\r\n ");
        vm.stopPrank();
        vm.prank(_reader(keys[id].projectId));
        assertEq(uint256(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).status), uint256(DeliveryRegistry.Status.Pending));
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).reviewedAt, 0);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.reviewNotes(keys[id].projectId, keys[id].stage, keys[id].sequence), "");
    }

    function test_RejectionReasonIsStoredEmittedAndPreservedAfterResubmission() public {
        string memory id = _submit(d, c, project, new string[](0));
        string memory reason = unicode"SBOM에 모듈 버전이 빠져 있습니다.";
        vm.expectEmit(true, true, false, true);
        emit DeliveryReviewed(id, project, 3, 1, c, DeliveryRegistry.Status.Rejected, reason);
        vm.prank(c);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, reason);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.reviewNotes(keys[id].projectId, keys[id].stage, keys[id].sequence), reason);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.DeliveryAlreadyReviewed.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, "Changed reason");
        vm.prank(d);
        string memory revised = _resubmit(id, "2", sbom, artifact, _components(), new string[](0));
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.reviewNotes(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), "");
        vm.prank(c);
        registry.reviewDelivery(keys[revised].projectId, keys[revised].stage, keys[revised].sequence, DeliveryRegistry.Status.Approved, "Version verified");
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.reviewNotes(keys[id].projectId, keys[id].stage, keys[id].sequence), reason);
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.reviewNotes(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), "Version verified");
    }

    function test_ReviewNoteLengthLimitAndOptionalApprovalNote() public {
        string memory id = _submit(d, c, project, new string[](0));
        uint256 limit = registry.MAX_REVIEW_NOTE_BYTES();
        bytes memory note = new bytes(limit + 1);
        for (uint256 i = 0; i < note.length; i++) note[i] = 0x61;
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ReviewNoteTooLong.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, string(note));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ReviewNoteTooLong.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Approved, string(note));
        bytes memory boundary = new bytes(limit);
        for (uint256 i = 0; i < boundary.length; i++) boundary[i] = 0x61;
        vm.prank(c);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, string(boundary));
        vm.prank(_reader(keys[id].projectId));
        assertEq(bytes(registry.reviewNotes(keys[id].projectId, keys[id].stage, keys[id].sequence)).length, limit);
        string memory other = _submit(e, c, project, new string[](0));
        _review(c, other, DeliveryRegistry.Status.Approved);
        vm.prank(_reader(keys[other].projectId));
        assertEq(registry.reviewNotes(keys[other].projectId, keys[other].stage, keys[other].sequence), "");
    }

    function test_NonReceiverCannotStoreRejectionReason() public {
        string memory id = _submit(d, c, project, new string[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanReview.selector);
        registry.reviewDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence, DeliveryRegistry.Status.Rejected, "Unauthorized reason");
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.reviewNotes(keys[id].projectId, keys[id].stage, keys[id].sequence), "");
        vm.prank(_reader(keys[id].projectId));
        assertEq(uint256(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).status), uint256(DeliveryRegistry.Status.Pending));
    }

    function _one(string memory id) private pure returns (string[] memory ids) {
        ids = new string[](1);
        ids[0] = id;
    }

    function _expectBadLink(string[] memory ids, string memory reason) private {
        string memory requestId = _request(c, b, project);
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

    function _newRequirement(string[] memory names) private returns (string memory) {
        vm.prank(b);
        return _createRequirement(project, c, unicode"쇼핑몰", names);
    }

    function _declare(string memory requestId, string[] memory names) private returns (string memory) {
        vm.prank(c);
        string memory deliveryId = registry.submitDelivery(requestId, "1", sbom, artifact, names, new string[](0));
        _record(deliveryId, project, 2);
        return deliveryId;
    }

    event RequirementCreated(string requirementId, uint256 indexed projectId,
        address indexed supplier, address receiver, string productName, string[] requiredComponents);
    event DeliverySubmitted(string deliveryId, uint256 indexed projectId, uint256 stage,
        uint256 stageDeliveryNumber, address indexed supplier, address receiver, string requirementId);

    function test_RequirementStoresReceiverRequestAndEmitsEvent() public {
        string[] memory names = _pair(unicode"로그인", unicode"결제");
        vm.expectEmit(true, true, false, true);
        emit RequirementCreated("1-2-1", project, c, b, unicode"쇼핑몰", names);
        string memory requestId = _newRequirement(names);
        vm.prank(_reader(project));
        DeliveryRegistry.Requirement memory item = registry.getRequirement(requirementKeys[requestId].projectId, requirementKeys[requestId].stage, requirementKeys[requestId].sequence);
        assertEq(requestId, "1-2-1");
        assertEq(registry.requirementCount(), 1);
        assertEq(item.projectId, project);
        assertEq(item.supplier, c);
        assertEq(item.receiver, b);
        assertEq(item.productName, unicode"쇼핑몰");
        assertEq(item.createdAt, block.timestamp);
        assertEq(keccak256(abi.encode(item.requiredComponents)), keccak256(abi.encode(names)));
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        vm.prank(_reader(project));
        registry.getRequirement(project, 2, 0);
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        vm.prank(_reader(project));
        registry.getRequirement(project, 2, 2);
    }

    function test_OnlyDirectReceiverCreatesRequirement() public {
        address[5] memory callers = [a, c, d, outsider, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
            _createRequirement(project, c, "Product", _components());
        }
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
        _createRequirement(project, d, "Product", _components());
        vm.prank(b);
        vm.expectRevert(bytes("Project not found"));
        _createRequirement(999, c, "Product", _components());
        assertEq(registry.requirementCount(), 0);
        _newRequirement(_components());
        vm.prank(c);
        string memory lowerRequest = _createRequirement(project, d, "Library", _components());
        vm.prank(_reader(project));
        assertEq(registry.getRequirement(requirementKeys[lowerRequest].projectId, requirementKeys[lowerRequest].stage, requirementKeys[lowerRequest].sequence).receiver, c);
    }

    function _invalidNameInEveryPosition(string memory name) private {
        string memory requestId = _request(c, b, project);
        uint256 beforeCount = registry.requirementCount();
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        _createRequirement(project, c, name, _components());
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        _createRequirement(project, c, "Product", _strings(name));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _strings(name), new string[](0));
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
        string memory requestId = _newRequirement(_components());
        string[][] memory bad = new string[][](3);
        bad[0] = new string[](0);
        bad[1] = _names(33);
        bad[2] = _pair("Core", "Core");
        for (uint256 i = 0; i < bad.length; i++) {
            bytes4 expected = i == 2 ? DeliveryRegistry.DuplicateComponent.selector : DeliveryRegistry.InvalidComponentCount.selector;
            vm.prank(b);
            vm.expectRevert(expected);
            _createRequirement(project, c, "Product", bad[i]);
            vm.prank(c);
            vm.expectRevert(expected);
            registry.submitDelivery(requestId, "1", sbom, artifact, bad[i], new string[](0));
        }
        assertEq(registry.requirementCount(), 1);
        assertEq(registry.deliveryCount(), 0);
        string[] memory boundary = _names(32);
        string memory maxRequest = _newRequirement(boundary);
        string memory id = _declare(maxRequest, boundary);
        vm.prank(_reader(keys[id].projectId));
        (, string[] memory saved) = registry.getDeliverySubmission(keys[id].projectId, keys[id].stage, keys[id].sequence);
        assertEq(saved.length, 32);
    }

    function test_NameLengthLimitUsesBytesAndAcceptsBoundary() public {
        _invalidNameInEveryPosition(_longName(129));
        _invalidNameInEveryPosition(string(abi.encodePacked(_longName(126), unicode"가")));
        string memory boundary = string(abi.encodePacked(_longName(125), unicode"가"));
        assertEq(bytes(boundary).length, 128);
        vm.prank(b);
        string memory requestId = _createRequirement(project, c, boundary, _strings(boundary));
        string memory id = _declare(requestId, _strings(boundary));
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence).productName, boundary);
        vm.prank(_reader(keys[id].projectId));
        (, string[] memory saved) = registry.getDeliverySubmission(keys[id].projectId, keys[id].stage, keys[id].sequence);
        assertEq(saved[0], boundary);
    }

    function test_SubmissionStoresDeclarationAndRequirementWithoutLowerDelivery() public {
        string memory requestId = _newRequirement(_pair(unicode"로그인", unicode"결제"));
        string[] memory declaration = new string[](3);
        declaration[0] = unicode"결제";
        declaration[1] = " Extra ";
        declaration[2] = unicode"로그인";
        vm.expectEmit(true, true, false, true);
        emit DeliverySubmitted("1-2-1", project, 2, 1, c, b, requestId);
        string memory id = _declare(requestId, declaration);
        vm.prank(_reader(keys[id].projectId));
        DeliveryRegistry.Delivery memory delivery = registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence);
        assertEq(delivery.projectId, project);
        assertEq(delivery.supplier, c);
        assertEq(delivery.receiver, b);
        assertEq(delivery.productName, unicode"쇼핑몰");
        assertEq(uint256(delivery.status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(delivery.sbomHash, sbom);
        assertEq(delivery.fileHash, artifact);
        assertEq(delivery.submittedAt, block.timestamp);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.getPreviousDeliveryIds(keys[id].projectId, keys[id].stage, keys[id].sequence).length, 0);
        vm.prank(_reader(keys[id].projectId));
        (string memory linked, string[] memory saved) = registry.getDeliverySubmission(keys[id].projectId, keys[id].stage, keys[id].sequence);
        assertEq(linked, requestId);
        assertEq(keccak256(abi.encode(saved)), keccak256(abi.encode(declaration)));
    }

    function test_MissingAndDifferentCaseComponentsCannotSatisfyRequest() public {
        string memory requestId = _newRequirement(_pair("Login", "Payment"));
        string[][] memory bad = new string[][](4);
        bad[0] = _strings("Login");
        bad[1] = _pair("Login", "Other");
        bad[2] = _pair("login", "Payment");
        bad[3] = _pair("Login ", "Payment");
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(c);
            vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
            registry.submitDelivery(requestId, "1", sbom, artifact, bad[i], new string[](0));
        }
        assertEq(registry.deliveryCount(), 0);
        vm.prank(_reader(project));
        assertEq(registry.projectDeliveryCounts(project), 0);
        vm.prank(_reader(project));
        assertEq(registry.stageDeliveryCounts(project, 2), 0);
        vm.expectRevert(bytes("Delivery not found"));
        vm.prank(_reader(project));
        registry.deliveryRequirementIds(project, 2, 1);
        _declare(requestId, _pair("Payment", "Login"));
    }

    function test_NamesAreNotTrimmedOrUnicodeNormalized() public {
        string memory padded = string(abi.encodePacked(hex"c2a0", "Login", hex"e38080"));
        string memory requestId = _newRequirement(_pair(padded, unicode"é"));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _pair("Login", unicode"é"), new string[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(requestId, "1", sbom, artifact, _pair(padded, string(hex"65cc81")), new string[](0));
        string memory id = _declare(requestId, _pair(padded, unicode"é"));
        vm.prank(_reader(keys[id].projectId));
        (, string[] memory saved) = registry.getDeliverySubmission(keys[id].projectId, keys[id].stage, keys[id].sequence);
        assertEq(saved[0], padded);
        string memory distinct = _newRequirement(_pair("Login", "login"));
        _declare(distinct, _pair("login", "Login"));
    }

    function test_RequestsWithSameProductAreIndependentAndReusable() public {
        string memory first = _newRequirement(_strings("Login"));
        vm.prank(_reader(project));
        bytes32 originalRequest = keccak256(abi.encode(registry.getRequirement(requirementKeys[first].projectId, requirementKeys[first].stage, requirementKeys[first].sequence)));
        string memory second = _newRequirement(_strings("Payment"));
        string memory firstDelivery = _declare(first, _strings("Login"));
        string memory repeated = _declare(first, _strings("Login"));
        assertNotEq(firstDelivery, repeated);
        vm.prank(_reader(keys[repeated].projectId));
        assertEq(registry.deliveryRequirementIds(keys[repeated].projectId, keys[repeated].stage, keys[repeated].sequence), first);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery(second, "1", sbom, artifact, _strings("Login"), new string[](0));
        string memory secondDelivery = _declare(second, _strings("Payment"));
        vm.prank(_reader(keys[secondDelivery].projectId));
        assertEq(registry.deliveryRequirementIds(keys[secondDelivery].projectId, keys[secondDelivery].stage, keys[secondDelivery].sequence), second);
        vm.prank(_reader(project));
        assertEq(keccak256(abi.encode(registry.getRequirement(requirementKeys[first].projectId, requirementKeys[first].stage, requirementKeys[first].sequence))), originalRequest);
        vm.prank(_reader(keys[repeated].projectId));
        assertEq(registry.replacesDeliveryIds(keys[repeated].projectId, keys[repeated].stage, keys[repeated].sequence), "");
    }

    function test_NonexistentRequirementCannotBeSubmitted() public {
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        registry.submitDelivery("", "1", sbom, artifact, _components(), new string[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
        registry.submitDelivery("999", "1", sbom, artifact, _components(), new string[](0));
    }

    function test_ResubmissionKeepsRequestAndOriginalDeclarationAndReview() public {
        string memory requestId = _newRequirement(_pair("Login", "Payment"));
        string memory id = _declare(requestId, _pair("Payment", "Login"));
        _review(b, id, DeliveryRegistry.Status.Rejected);
        vm.prank(_reader(keys[id].projectId));
        bytes32 original = keccak256(abi.encode(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence)));
        _newRequirement(_strings("Login"));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        _resubmit(id, "2", sbom, artifact, _strings("Login"), new string[](0));
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.resubmittedDeliveryIds(keys[id].projectId, keys[id].stage, keys[id].sequence), "");
        assertEq(registry.deliveryCount(), 1);
        string[] memory declaration = new string[](3);
        declaration[0] = "Login";
        declaration[1] = "Payment";
        declaration[2] = "Search";
        vm.prank(c);
        string memory revised = _resubmit(id, "2", keccak256("changed SBOM"), keccak256("changed file"), declaration, new string[](0));
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.deliveryRequirementIds(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), requestId);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.deliveryRequirementIds(keys[id].projectId, keys[id].stage, keys[id].sequence), requestId);
        vm.prank(_reader(keys[id].projectId));
        assertEq(keccak256(abi.encode(registry.getDelivery(keys[id].projectId, keys[id].stage, keys[id].sequence))), original);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.reviewNotes(keys[id].projectId, keys[id].stage, keys[id].sequence), "SBOM needs correction");
        vm.prank(_reader(keys[id].projectId));
        (, string[] memory savedOriginal) = registry.getDeliverySubmission(keys[id].projectId, keys[id].stage, keys[id].sequence);
        assertEq(savedOriginal[0], "Payment");
        assertEq(savedOriginal[1], "Login");
        vm.prank(_reader(keys[revised].projectId));
        (, string[] memory savedRevised) = registry.getDeliverySubmission(keys[revised].projectId, keys[revised].stage, keys[revised].sequence);
        assertEq(keccak256(abi.encode(savedRevised)), keccak256(abi.encode(declaration)));
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.reviewNotes(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), "");
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.getDelivery(keys[revised].projectId, keys[revised].stage, keys[revised].sequence).reviewedAt, 0);
        vm.prank(_reader(keys[revised].projectId));
        assertEq(uint256(registry.getDelivery(keys[revised].projectId, keys[revised].stage, keys[revised].sequence).status), uint256(DeliveryRegistry.Status.Pending));
        vm.prank(_reader(keys[revised].projectId));
        assertEq(registry.replacesDeliveryIds(keys[revised].projectId, keys[revised].stage, keys[revised].sequence), id);
        vm.prank(_reader(keys[id].projectId));
        assertEq(registry.resubmittedDeliveryIds(keys[id].projectId, keys[id].stage, keys[id].sequence), revised);
    }

    function _readCases() private returns (bytes[] memory calls) {
        string memory input = _submit(d, c, project, new string[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        string memory original = _submit(c, b, project, _one(input));
        _review(b, original, DeliveryRegistry.Status.Rejected);
        vm.prank(c);
        _resubmit(original, "2", sbom, artifact, _components(), _one(input));
        string memory requestId = _request(c, b, project);
        calls = new bytes[](19);
        calls[0] = abi.encodeCall(registry.projects, (project));
        calls[1] = abi.encodeCall(registry.projectMembers, (project, a));
        calls[2] = abi.encodeCall(registry.parentCompanies, (project, c));
        calls[3] = abi.encodeCall(registry.companyDepths, (project, c));
        calls[4] = abi.encodeCall(registry.allowedRoutes, (project, c, b));
        calls[5] = abi.encodeCall(registry.routeStages, (project, c, b));
        calls[6] = abi.encodeCall(registry.projectDeliveryCounts, (project));
        calls[7] = abi.encodeCall(registry.stageDeliveryCounts, (project, 2));
        calls[8] = abi.encodeCall(registry.getProject, (project, 0, 100));
        calls[9] = abi.encodeCall(registry.getRequirement, (requirementKeys[requestId].projectId, requirementKeys[requestId].stage, requirementKeys[requestId].sequence));
        calls[10] = abi.encodeCall(registry.getDelivery, (project, 2, 1));
        calls[11] = abi.encodeCall(registry.getDeliveryId, (project, 2, 1));
        calls[12] = abi.encodeCall(registry.getPreviousDeliveryIds, (project, 2, 1));
        calls[13] = abi.encodeCall(registry.getNextDeliveryIds, (project, 3, 1, 0, 100));
        calls[14] = abi.encodeCall(registry.getDeliverySubmission, (project, 2, 1));
        calls[15] = abi.encodeCall(registry.deliveryRequirementIds, (project, 2, 1));
        calls[16] = abi.encodeCall(registry.reviewNotes, (project, 2, 1));
        calls[17] = abi.encodeCall(registry.replacesDeliveryIds, (project, 2, 2));
        calls[18] = abi.encodeCall(registry.resubmittedDeliveryIds, (project, 2, 1));
    }

    function _assertReadAccess(bytes[] memory calls, address caller, bool permitted) private {
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(caller);
            (bool success, bytes memory result) = address(registry).staticcall(calls[i]);
            assertEq(success, permitted, string.concat("Read access case ", vm.toString(i)));
            if (permitted) {
                vm.prank(a);
                (bool ownerSuccess, bytes memory ownerResult) = address(registry).staticcall(calls[i]);
                assertTrue(ownerSuccess);
                assertEq(result, ownerResult);
            } else {
                assertEq(result, abi.encodeWithSignature("Error(string)", "Not a project member"));
            }
        }
    }

    function test_ProjectCreatorAndAllParticipantsCanReadEveryProjectView() public {
        bytes[] memory calls = _readCases();
        address[5] memory participants = [a, b, c, d, e];
        for (uint256 i = 0; i < participants.length; i++) {
            _assertReadAccess(calls, participants[i], true);
        }
    }

    function test_OutsiderAndDeployerCannotReadAnyProjectView() public {
        bytes[] memory calls = _readCases();
        _assertReadAccess(calls, outsider, false);
        _assertReadAccess(calls, address(this), false);
        vm.prank(outsider);
        registry.registerCompany();
        _assertReadAccess(calls, outsider, false);
    }

    function test_OtherProjectCreatorAndParticipantCannotReadTargetProject() public {
        bytes[] memory calls = _readCases();
        vm.prank(outsider);
        registry.registerCompany();
        vm.prank(outsider);
        uint256 second = registry.createProject("Separate project");
        address otherSupplier = address(0x1234);
        _add(outsider, otherSupplier, second);
        _assertReadAccess(calls, outsider, false);
        _assertReadAccess(calls, otherSupplier, false);
        vm.prank(outsider);
        assertTrue(registry.projectMembers(second, outsider));
        vm.prank(otherSupplier);
        assertTrue(registry.projectMembers(second, otherSupplier));
        vm.prank(a);
        vm.expectRevert(bytes("Not a project member"));
        registry.getProject(second, 0, 10);
    }

    function test_ReadAccessBeginsWhenCompanyJoinsProject() public {
        bytes[] memory calls = _readCases();
        _assertReadAccess(calls, outsider, false);
        _add(d, outsider, project);
        _assertReadAccess(calls, outsider, true);
    }

    function test_CompositeNumbersSelectExactProjectStageAndSequence() public {
        string memory first = _submit(b, a, project, new string[](0));
        string memory next = _submit(b, a, project, new string[](0));
        string memory lower = _submit(c, b, project, new string[](0));
        vm.prank(a);
        uint256 second = registry.createProject("Same numbers, different project");
        _add(a, b, second);
        string memory other = _submit(b, a, second, new string[](0));
        vm.prank(a);
        registry.reviewDelivery(second, 1, 1, DeliveryRegistry.Status.Rejected, "Fix version");
        vm.prank(b);
        string memory revised = registry.resubmitDelivery(second, 1, 1, "2", sbom, artifact, _components(), new string[](0));
        vm.startPrank(a);
        assertEq(registry.getDeliveryId(project, 1, 1), first);
        assertEq(registry.getDeliveryId(project, 1, 2), next);
        assertEq(registry.getDeliveryId(project, 2, 1), lower);
        assertEq(registry.getDeliveryId(second, 1, 1), other);
        assertEq(registry.getDeliveryId(second, 1, 2), revised);
        assertEq(uint256(registry.getDelivery(project, 1, 1).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(uint256(registry.getDelivery(project, 1, 2).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(uint256(registry.getDelivery(project, 2, 1).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(registry.resubmittedDeliveryIds(project, 1, 1), "");
        assertEq(registry.resubmittedDeliveryIds(second, 1, 1), revised);
        assertEq(registry.replacesDeliveryIds(second, 1, 2), other);
        assertEq(registry.getDelivery(second, 1, 2).version, "2");
        registry.reviewDelivery(project, 1, 2, DeliveryRegistry.Status.Approved, "Checked");
        assertEq(uint256(registry.getDelivery(project, 1, 1).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(uint256(registry.getDelivery(project, 1, 2).status), uint256(DeliveryRegistry.Status.Approved));
        vm.stopPrank();
    }

    function test_CompositeWritesRejectMissingProjectStageOrSequence() public {
        _submit(b, a, project, new string[](0));
        uint256[3][5] memory missing = [[uint256(0), 1, 1], [uint256(999), 1, 1],
            [project, uint256(0), 1], [project, uint256(2), 1], [project, uint256(1), 2]];
        for (uint256 i = 0; i < missing.length; i++) {
            bytes memory reason = i < 2 ? bytes("Project not found") : bytes("Delivery not found");
            vm.prank(a);
            vm.expectRevert(reason);
            registry.reviewDelivery(missing[i][0], missing[i][1], missing[i][2], DeliveryRegistry.Status.Approved, "");
            vm.prank(b);
            vm.expectRevert(reason);
            registry.resubmitDelivery(missing[i][0], missing[i][1], missing[i][2], "2", sbom, artifact, _components(), new string[](0));
        }
        assertEq(registry.deliveryCount(), 1);
    }

    function test_OldSingleIdGettersCannotBypassReadPermissions() public {
        _readCases();
        string[8] memory signatures = ["deliveries(uint256)", "deliveryRequirementIds(uint256)",
            "reviewNotes(uint256)", "replacesDeliveryIds(uint256)", "resubmittedDeliveryIds(uint256)",
            "getDelivery(uint256)", "getPreviousDeliveryIds(uint256)", "getDeliverySubmission(uint256)"];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(outsider);
            (bool success,) = address(registry).staticcall(abi.encodeWithSignature(signatures[i], uint256(1)));
            assertFalse(success);
        }
        vm.prank(outsider);
        (bool nextSuccess,) = address(registry).staticcall(abi.encodeWithSignature("getNextDeliveryIds(uint256,uint256,uint256)", uint256(1), uint256(0), uint256(10)));
        assertFalse(nextSuccess);
    }

    function test_CompactDemoUsesOnlyCompositeDeliveryIds() public {
        vm.prank(b);
        string memory moduleRequest = _createRequirement(project, c, "Module", _pair("Core", "Login"));
        vm.prank(a);
        string memory finalRequest = _createRequirement(project, b, "FinalProduct", _pair("Core", "Login"));
        assertEq(moduleRequest, "1-2-1");
        assertEq(finalRequest, "1-1-1");
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredComponentMissing.selector);
        registry.submitDelivery("1-2-1", "1.0", sbom, artifact, _strings("Core"), new string[](0));
        vm.prank(c);
        string memory moduleId = registry.submitDelivery("1-2-1", "1.0", sbom, artifact, _pair("Core", "Login"), new string[](0));
        assertEq(moduleId, "1-2-1");
        vm.prank(c);
        assertEq(registry.getDelivery(1, 2, 1).deliveryId, moduleId);
        vm.prank(b);
        registry.reviewDelivery(1, 2, 1, DeliveryRegistry.Status.Approved, "Accepted");
        vm.prank(b);
        string memory finalId = registry.submitDelivery("1-1-1", "1.0", sbom, artifact, _pair("Core", "Login"), _one("1-2-1"));
        assertEq(finalId, "1-1-1");
        vm.startPrank(a);
        assertEq(registry.getPreviousDeliveryIds(1, 1, 1), _one("1-2-1"));
        (string[] memory next, uint256 count) = registry.getNextDeliveryIds(1, 2, 1, 0, 10);
        assertEq(next, _one("1-1-1"));
        assertEq(count, 1);
        (, DeliveryRegistry.ProjectDelivery[] memory items,) = registry.getProject(1, 0, 10);
        assertEq(items[0].deliveryId, "1-2-1");
        assertEq(items[1].deliveryId, "1-1-1");
        assertEq(items[1].previousDeliveryIds, _one("1-2-1"));
        vm.stopPrank();
    }

    function test_LinksRequireExactExistingCompositeId() public {
        string memory input = _submit(d, c, project, new string[](0));
        _review(c, input, DeliveryRegistry.Status.Approved);
        string[7] memory invalidIds = ["1", "01-3-1", "1-03-1", "1-3-01", "1-3-1 ", "", "1-3-999"];
        for (uint256 i = 0; i < invalidIds.length; i++) {
            _expectBadLink(_one(invalidIds[i]), "Delivery not found");
        }
        assertEq(_submit(c, b, project, _one(input)), "1-2-1");
        assertEq(registry.deliveryCount(), 2);
    }

    event DeliveryResubmitted(string originalDeliveryId, string newDeliveryId, address indexed supplier);

    function test_ResubmissionEventAndRelationsUseCompositeIds() public {
        string memory original = _submit(c, b, project, new string[](0));
        _review(b, original, DeliveryRegistry.Status.Rejected);
        vm.expectEmit(true, false, false, true);
        emit DeliveryResubmitted("1-2-1", "1-2-2", c);
        vm.prank(c);
        string memory revised = registry.resubmitDelivery(1, 2, 1, "2", sbom, artifact, _components(), new string[](0));
        assertEq(revised, "1-2-2");
        vm.startPrank(a);
        assertEq(registry.resubmittedDeliveryIds(1, 2, 1), "1-2-2");
        assertEq(registry.replacesDeliveryIds(1, 2, 2), "1-2-1");
        assertEq(registry.replacesDeliveryIds(1, 2, 1), "");
        assertEq(registry.resubmittedDeliveryIds(1, 2, 2), "");
        vm.stopPrank();
    }

    function test_RequirementAndDeliveryIdsAreIndependentAndExplicitlyLinked() public {
        string memory first = _newRequirement(_strings("Login"));
        string memory second = _newRequirement(_strings("Payment"));
        assertEq(first, "1-2-1");
        assertEq(second, "1-2-2");
        assertEq(_declare(second, _strings("Payment")), "1-2-1");
        assertEq(_declare(second, _strings("Payment")), "1-2-2");
        vm.startPrank(a);
        DeliveryRegistry.Requirement memory request = registry.getRequirement(1, 2, 1);
        assertEq(request.requirementId, "1-2-1");
        assertEq(request.receiver, b);
        assertEq(request.supplier, c);
        assertEq(request.stage, 2);
        assertEq(request.sequence, 1);
        DeliveryRegistry.Delivery memory delivery = registry.getDelivery(1, 2, 1);
        assertEq(delivery.deliveryId, "1-2-1");
        assertEq(delivery.requirementId, "1-2-2");
        assertEq(registry.deliveryRequirementIds(1, 2, 1), "1-2-2");
        (string memory linked,) = registry.getDeliverySubmission(1, 2, 1);
        assertEq(linked, "1-2-2");
        (, DeliveryRegistry.ProjectDelivery[] memory items,) = registry.getProject(1, 0, 10);
        assertEq(items[0].deliveryId, "1-2-1");
        assertEq(items[0].requirementId, "1-2-2");
        assertEq(items[1].requirementId, "1-2-2");
        vm.stopPrank();
    }

    function test_RequirementNumberingIsScopedToProjectAndStage() public {
        assertEq(_request(c, b, project), "1-2-1");
        assertEq(_request(d, c, project), "1-3-1");
        assertEq(_request(e, c, project), "1-3-2");
        vm.prank(b);
        uint256 second = registry.createProject("Other requirements");
        _add(b, c, second);
        assertEq(_request(c, b, second), "2-1-1");
        vm.startPrank(b);
        assertEq(registry.getRequirement(1, 3, 2).supplier, e);
        assertEq(registry.getRequirement(1, 3, 2).receiver, c);
        assertEq(registry.getRequirement(2, 1, 1).supplier, c);
        assertEq(registry.getRequirement(2, 1, 1).receiver, b);
        vm.stopPrank();
        assertEq(registry.requirementCount(), 4);
    }

    function test_InvalidRequirementCreationDoesNotConsumeSequence() public {
        vm.prank(b);
        vm.expectRevert(DeliveryRegistry.InvalidName.selector);
        registry.createRequirement(project, c, "", _components());
        assertEq(_newRequirement(_components()), "1-2-1");
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.OnlyReceiverCanCreateRequirement.selector);
        registry.createRequirement(project, c, "Product", _components());
        assertEq(_newRequirement(_components()), "1-2-2");
    }

    function test_SubmissionRequiresExactExistingRequirementId() public {
        _newRequirement(_components());
        string[6] memory invalidIds = ["1", "01-2-1", "1-02-1", "1-2-01", "1-2-1 ", "1-2-999"];
        for (uint256 i = 0; i < invalidIds.length; i++) {
            vm.prank(c);
            vm.expectRevert(DeliveryRegistry.RequirementNotFound.selector);
            registry.submitDelivery(invalidIds[i], "1", sbom, artifact, _components(), new string[](0));
        }
        assertEq(registry.deliveryCount(), 0);
        vm.prank(c);
        assertEq(registry.submitDelivery("1-2-1", "1", sbom, artifact, _components(), new string[](0)), "1-2-1");
    }

    function _createRequirement(uint256 projectId, address supplier, string memory productName, string[] memory components) private returns (string memory) {
        string memory id = registry.createRequirement(projectId, supplier, productName, components);
        if (bytes(id).length != 0) {
            uint256 stage = depths[projectId][supplier];
            requirementKeys[id] = DeliveryKey(projectId, stage, ++requirementSequences[projectId][stage]);
        }
        return id;
    }

    function _reader(uint256 projectId) private view returns (address) {
        return readers[projectId] == address(0) ? a : readers[projectId];
    }

    function _record(string memory id, uint256 projectId, uint256 stage) private {
        if (bytes(id).length != 0) keys[id] = DeliveryKey(projectId, stage, ++sequences[projectId][stage]);
    }

    function _resubmit(string memory id, string memory version, bytes32 sbomHash, bytes32 fileHash,
        string[] memory components, string[] memory previous) private returns (string memory) {
        DeliveryKey memory key = keys[id];
        string memory revised = registry.resubmitDelivery(key.projectId, key.stage, key.sequence,
            version, sbomHash, fileHash, components, previous);
        _record(revised, key.projectId, key.stage);
        return revised;
    }
}
