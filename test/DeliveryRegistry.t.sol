// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeliveryRegistry} from "../contracts/DeliveryRegistry.sol";

contract DeliveryRegistryTest is Test {
    DeliveryRegistry registry;
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
        registry.registerCompany(a);
        registry.registerCompany(b);
        registry.registerCompany(c);
        registry.registerCompany(d);
        registry.registerCompany(e);
        registry.registerCompany(outsider);
        vm.prank(a);
        project = registry.createProject("Project A");
        _add(a, b, project);
        _add(b, c, project);
        _add(c, d, project);
        _add(c, e, project);
    }

    function test_OnlyAdminRegistersCompanies() public {
        vm.prank(a);
        vm.expectRevert(bytes("Only admin"));
        registry.registerCompany(address(99));
        vm.expectRevert(bytes("Invalid address"));
        registry.registerCompany(address(0));
        vm.expectRevert(bytes("Company already registered"));
        registry.registerCompany(a);
        vm.expectEmit(true, false, false, true);
        emit CompanyRegistered(address(99));
        registry.registerCompany(address(99));
        assertTrue(registry.registeredCompanies(address(99)));
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
        registry.createProject("Unregistered admin");
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

    function test_NonmemberAndAdminCannotSetProjectRoutes() public {
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
        vm.expectRevert(bytes("Company not registered"));
        registry.addSupplier(project, address(99));
        vm.prank(a);
        vm.expectRevert(bytes("Company not registered"));
        registry.addSupplier(project, address(0));
    }

    function test_RejectsSelfDuplicateMultipleParentsAndCycles() public {
        vm.prank(c);
        vm.expectRevert(bytes("Supplier and receiver cannot be the same"));
        registry.addSupplier(project, c);
        vm.prank(c);
        vm.expectRevert(bytes("Company already in project"));
        registry.addSupplier(project, d);
        vm.prank(b);
        vm.expectRevert(bytes("Company already in project"));
        registry.addSupplier(project, d);
        vm.prank(d);
        vm.expectRevert(bytes("Company already in project"));
        registry.addSupplier(project, a);
        vm.prank(d);
        vm.expectRevert(bytes("Company already in project"));
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
        vm.prank(d);
        vm.expectRevert(bytes("Route not allowed"));
        registry.submitDelivery(second, c, "Product", "1", sbom, artifact, new uint256[](0));
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

    function test_OnlyDirectSupplierCanSubmit() public {
        vm.prank(d);
        vm.expectRevert(bytes("Route not allowed"));
        registry.submitDelivery(project, b, "Product", "1", sbom, artifact, new uint256[](0));
        vm.prank(outsider);
        vm.expectRevert(bytes("Route not allowed"));
        registry.submitDelivery(project, c, "Product", "1", sbom, artifact, new uint256[](0));
        assertEq(registry.deliveryCount(), 0);
    }

    function test_AdminAndCustomerCannotReviewOthersDeliveries() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.expectRevert(bytes("Only receiver can review"));
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved);
        vm.prank(a);
        vm.expectRevert(bytes("Only receiver can review"));
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved);
        vm.prank(d);
        vm.expectRevert(bytes("Only receiver can review"));
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved);
        assertEq(uint256(registry.getDelivery(id).status), uint256(DeliveryRegistry.Status.Pending));
        assertEq(registry.getDelivery(id).reviewedAt, 0);
        vm.warp(block.timestamp + 10);
        _review(c, id, DeliveryRegistry.Status.Rejected);
        assertEq(registry.getDelivery(id).reviewedAt, block.timestamp);
        vm.prank(c);
        vm.expectRevert(bytes("Delivery already reviewed"));
        registry.reviewDelivery(id, DeliveryRegistry.Status.Approved);
    }

    function test_InvalidReviewStatusIsBlocked() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.prank(c);
        vm.expectRevert(bytes("Invalid review status"));
        registry.reviewDelivery(id, DeliveryRegistry.Status.Pending);
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
        uint256 revised = registry.resubmitDelivery(id, "2", keccak256("new SBOM"), keccak256("new artifact"), new uint256[](0));
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
        vm.expectRevert(bytes("Delivery already resubmitted"));
        registry.resubmitDelivery(id, "3", sbom, artifact, new uint256[](0));
        _review(c, revised, DeliveryRegistry.Status.Rejected);
        vm.prank(d);
        uint256 third = registry.resubmitDelivery(revised, "3", sbom, artifact, new uint256[](0));
        _review(c, third, DeliveryRegistry.Status.Approved);
        assertEq(registry.replacesDeliveryIds(third), revised);
        assertEq(registry.resubmittedDeliveryIds(revised), third);
    }

    function test_ResubmissionRequiresOriginalSupplierAndRejection() public {
        uint256 id = _submit(d, c, project, new uint256[](0));
        vm.prank(d);
        vm.expectRevert(bytes("Only rejected delivery can be resubmitted"));
        registry.resubmitDelivery(id, "2", sbom, artifact, new uint256[](0));
        _review(c, id, DeliveryRegistry.Status.Approved);
        vm.prank(d);
        vm.expectRevert(bytes("Only rejected delivery can be resubmitted"));
        registry.resubmitDelivery(id, "2", sbom, artifact, new uint256[](0));
        uint256 rejected = _submit(d, c, project, new uint256[](0));
        _review(c, rejected, DeliveryRegistry.Status.Rejected);
        vm.prank(e);
        vm.expectRevert(bytes("Only original supplier can resubmit"));
        registry.resubmitDelivery(rejected, "2", sbom, artifact, new uint256[](0));
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
        vm.startPrank(d);
        vm.expectRevert(bytes("Product name required"));
        registry.submitDelivery(project, c, "", "1", sbom, artifact, new uint256[](0));
        vm.expectRevert(bytes("Version required"));
        registry.submitDelivery(project, c, "Product", "", sbom, artifact, new uint256[](0));
        vm.expectRevert(bytes("SBOM hash required"));
        registry.submitDelivery(project, c, "Product", "1", bytes32(0), artifact, new uint256[](0));
        vm.expectRevert(bytes("File hash required"));
        registry.submitDelivery(project, c, "Product", "1", sbom, bytes32(0), new uint256[](0));
        vm.stopPrank();
        assertEq(registry.deliveryCount(), 0);
    }

    function _add(address receiver, address supplier, uint256 id) private {
        vm.prank(receiver);
        registry.addSupplier(id, supplier);
    }

    function _submit(address supplier, address receiver, uint256 id, uint256[] memory previous) private returns (uint256) {
        vm.prank(supplier);
        return registry.submitDelivery(id, receiver, "Product", "1", sbom, artifact, previous);
    }

    function _review(address receiver, uint256 id, DeliveryRegistry.Status status) private {
        vm.prank(receiver);
        registry.reviewDelivery(id, status);
    }

    function _one(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _expectBadLink(uint256[] memory ids, string memory reason) private {
        vm.prank(c);
        vm.expectRevert(bytes(reason));
        registry.submitDelivery(project, b, "Product", "1", sbom, artifact, ids);
    }
}
