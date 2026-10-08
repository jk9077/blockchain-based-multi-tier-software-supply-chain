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
        if (registry.getChecklist(id, supplier, "Product").revision == 0) {
            _finalizeList(id, supplier, "Product", new DeliveryRegistry.Requirement[](0));
        }
        vm.prank(supplier);
        return registry.submitDelivery(id, receiver, "Product", "1", sbom, artifact, previous);
    }

    function _review(address receiver, uint256 id, DeliveryRegistry.Status status) private {
        vm.prank(receiver);
        registry.reviewDelivery(id, status, status == DeliveryRegistry.Status.Rejected ? "SBOM needs correction" : "");
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
        uint256 revised = registry.resubmitDelivery(id, "2", sbom, artifact, new uint256[](0));
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
        vm.prank(c);
        vm.expectRevert(bytes(reason));
        registry.submitDelivery(project, b, "Product", "1", sbom, artifact, ids);
    }

    function _finalizeList(uint256 id, address supplier, string memory productName,
        DeliveryRegistry.Requirement[] memory items) private
    {
        vm.prank(supplier);
        registry.proposeChecklist(id, productName, items);
        uint256 revision = registry.getChecklist(id, supplier, productName).revision;
        vm.prank(supplier);
        registry.finalizeChecklist(id, productName, revision);
    }

    function _requirements() private view returns (DeliveryRegistry.Requirement[] memory items) {
        items = new DeliveryRegistry.Requirement[](2);
        items[0] = DeliveryRegistry.Requirement(d, "Product");
        items[1] = DeliveryRegistry.Requirement(e, "Product");
    }

    function test_SupplierFinalizesOwnChecklistWithoutReceiverApproval() public {
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.ChecklistNotFinalized.selector);
        registry.submitDelivery(project, c, "Product", "1", sbom, artifact, new uint256[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.ChecklistNotProposed.selector);
        registry.finalizeChecklist(project, "Product", 1);
        vm.prank(d);
        registry.proposeChecklist(project, "Product", new DeliveryRegistry.Requirement[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.ChecklistNotFinalized.selector);
        registry.submitDelivery(project, c, "Product", "1", sbom, artifact, new uint256[](0));
        // C cannot target D's checklist: finalization is always scoped to the caller.
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ChecklistNotProposed.selector);
        registry.finalizeChecklist(project, "Product", 1);
        vm.prank(a);
        vm.expectRevert(DeliveryRegistry.NoUpstreamReceiver.selector);
        registry.finalizeChecklist(project, "Product", 1);
        vm.expectRevert(DeliveryRegistry.NoUpstreamReceiver.selector);
        registry.finalizeChecklist(project, "Product", 1);
        vm.prank(d);
        registry.finalizeChecklist(project, "Product", 1);
        uint256 id = _submit(d, c, project, new uint256[](0));
        assertEq(registry.deliveryChecklistRevisions(id), 1);
    }

    function test_RevisionsArePreservedAndStaleFinalizationIsBlocked() public {
        vm.prank(c);
        registry.proposeChecklist(project, "Product", _requirements());
        vm.prank(c);
        registry.proposeChecklist(project, "Product", new DeliveryRegistry.Requirement[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ChecklistRevisionChanged.selector);
        registry.finalizeChecklist(project, "Product", 1);
        vm.prank(c);
        registry.finalizeChecklist(project, "Product", 2);
        DeliveryRegistry.Checklist memory list = registry.getChecklist(project, c, "Product");
        assertTrue(list.finalized);
        assertEq(list.revision, 2);
        assertEq(list.requirements.length, 0);
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ChecklistAlreadyFinalized.selector);
        registry.finalizeChecklist(project, "Product", 2);
        list = registry.getChecklistRevision(project, c, "Product", 1);
        assertFalse(list.finalized);
        assertEq(list.requirements.length, 2);
        assertEq(list.requirements[0].supplier, d);
        vm.expectRevert(DeliveryRegistry.ChecklistRevisionNotFound.selector);
        registry.getChecklistRevision(project, c, "Product", 0);
        vm.expectRevert(DeliveryRegistry.ChecklistRevisionNotFound.selector);
        registry.getChecklistRevision(project, c, "Product", 3);
    }

    function test_DeliveryKeepsHistoricalChecklistWhenNewRevisionIsUsed() public {
        _finalizeList(project, c, "Product", _requirements());
        uint256 did = _submit(d, c, project, new uint256[](0));
        uint256 eid = _submit(e, c, project, new uint256[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _review(c, eid, DeliveryRegistry.Status.Approved);
        uint256[] memory ids = new uint256[](2);
        ids[0] = did;
        ids[1] = eid;
        uint256 original = _submit(c, b, project, ids);
        _review(b, original, DeliveryRegistry.Status.Rejected);
        bytes32 originalList = keccak256(abi.encode(registry.getChecklistRevision(project, c, "Product", 1)));
        vm.prank(c);
        registry.proposeChecklist(project, "Product", new DeliveryRegistry.Requirement[](0));
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.ChecklistNotFinalized.selector);
        registry.resubmitDelivery(original, "2", sbom, artifact, new uint256[](0));
        assertEq(registry.resubmittedDeliveryIds(original), 0);
        vm.prank(c);
        registry.finalizeChecklist(project, "Product", 2);
        vm.prank(c);
        uint256 revised = registry.resubmitDelivery(original, "2", sbom, artifact, new uint256[](0));
        assertEq(registry.deliveryChecklistRevisions(original), 1);
        assertEq(registry.deliveryChecklistRevisions(revised), 2);
        assertEq(keccak256(abi.encode(registry.getChecklistRevision(project, c, "Product", 1))), originalList);
        assertEq(registry.getPreviousDeliveryIds(original), ids);
        assertEq(registry.getPreviousDeliveryIds(revised).length, 0);
        assertEq(registry.replacesDeliveryIds(revised), original);
        _review(b, revised, DeliveryRegistry.Status.Approved);
    }

    function test_InvalidChecklistItemsAndProposersAreBlocked() public {
        vm.prank(outsider);
        vm.expectRevert(DeliveryRegistry.NoUpstreamReceiver.selector);
        registry.proposeChecklist(project, "Product", _requirements());
        vm.prank(a);
        vm.expectRevert(DeliveryRegistry.NoUpstreamReceiver.selector);
        registry.proposeChecklist(project, "Product", _requirements());
        vm.prank(c);
        vm.expectRevert(bytes("Project not found"));
        registry.proposeChecklist(999, "Product", _requirements());
        vm.prank(c);
        vm.expectRevert(bytes("Product name required"));
        registry.proposeChecklist(project, "", _requirements());
        DeliveryRegistry.Requirement[] memory items = _requirements();
        items[0].supplier = b;
        vm.prank(c);
        vm.expectRevert(bytes("Requirement must be a direct supplier"));
        registry.proposeChecklist(project, "Product", items);
        items[0] = DeliveryRegistry.Requirement(d, "");
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.RequiredProductNameMissing.selector);
        registry.proposeChecklist(project, "Product", items);
        items[0] = DeliveryRegistry.Requirement(e, "Product");
        vm.prank(c);
        vm.expectRevert(DeliveryRegistry.DuplicateRequirement.selector);
        registry.proposeChecklist(project, "Product", items);
        assertEq(registry.getChecklist(project, c, "Product").revision, 0);
    }

    function test_RequiredDeliveriesCannotBeOmittedAndFailuresPreserveCounters() public {
        _finalizeList(project, c, "Product", _requirements());
        uint256 did = _submit(d, c, project, new uint256[](0));
        uint256 eid = _submit(e, c, project, new uint256[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _expectBadLink(new uint256[](0), "Required delivery missing");
        _expectBadLink(_one(did), "Required delivery missing");
        uint256[] memory ids = new uint256[](2);
        ids[0] = did;
        ids[1] = eid;
        _expectBadLink(ids, "Previous delivery not approved");
        _review(c, eid, DeliveryRegistry.Status.Rejected);
        _expectBadLink(ids, "Previous delivery not approved");
        vm.prank(e);
        uint256 revised = registry.resubmitDelivery(eid, "2", sbom, artifact, new uint256[](0));
        _review(c, revised, DeliveryRegistry.Status.Approved);
        ids[1] = revised;
        assertEq(registry.stageDeliveryCounts(project, 2), 0);
        uint256 cid = _submit(c, b, project, ids);
        assertEq(registry.getDelivery(cid).stageDeliveryNumber, 1);
        assertEq(registry.getPreviousDeliveryIds(cid), ids);
        _review(b, cid, DeliveryRegistry.Status.Approved);
        DeliveryRegistry.Requirement[] memory top = new DeliveryRegistry.Requirement[](1);
        top[0] = DeliveryRegistry.Requirement(c, "Product");
        _finalizeList(project, b, "Product", top);
        uint256 bid = _submit(b, a, project, _one(cid));
        _review(a, bid, DeliveryRegistry.Status.Approved);
    }

    function test_WrongProductFromCorrectSupplierCannotSatisfyRequirement() public {
        DeliveryRegistry.Requirement[] memory items = new DeliveryRegistry.Requirement[](1);
        items[0] = DeliveryRegistry.Requirement(d, "Library");
        _finalizeList(project, c, "Product", items);
        uint256 wrong = _submit(d, c, project, new uint256[](0));
        _review(c, wrong, DeliveryRegistry.Status.Approved);
        _expectBadLink(_one(wrong), "Required delivery missing");
        _finalizeList(project, d, "Library", new DeliveryRegistry.Requirement[](0));
        vm.prank(d);
        uint256 correct = registry.submitDelivery(project, c, "Library", "1", sbom, artifact, new uint256[](0));
        _review(c, correct, DeliveryRegistry.Status.Approved);
        _submit(c, b, project, _one(correct));
    }

    function test_OneSupplierCanSupplyMultipleDistinctRequiredProducts() public {
        DeliveryRegistry.Requirement[] memory items = new DeliveryRegistry.Requirement[](2);
        items[0] = DeliveryRegistry.Requirement(d, "Product");
        items[1] = DeliveryRegistry.Requirement(d, "Library");
        _finalizeList(project, c, "Product", items);
        uint256 first = _submit(d, c, project, new uint256[](0));
        _review(c, first, DeliveryRegistry.Status.Approved);
        _expectBadLink(_one(first), "Required delivery missing");
        _finalizeList(project, d, "Library", new DeliveryRegistry.Requirement[](0));
        vm.prank(d);
        uint256 second = registry.submitDelivery(project, c, "Library", "1", sbom, artifact, new uint256[](0));
        _review(c, second, DeliveryRegistry.Status.Approved);
        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        _submit(c, b, project, ids);
    }

    function test_ChecklistsAreIsolatedByProjectSupplierAndProduct() public {
        _finalizeList(project, d, "Product", new DeliveryRegistry.Requirement[](0));
        vm.prank(e);
        vm.expectRevert(DeliveryRegistry.ChecklistNotFinalized.selector);
        registry.submitDelivery(project, c, "Product", "1", sbom, artifact, new uint256[](0));
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.ChecklistNotFinalized.selector);
        registry.submitDelivery(project, c, "Renamed", "1", sbom, artifact, new uint256[](0));
        vm.prank(c);
        uint256 second = registry.createProject("Other");
        _add(c, d, second);
        vm.prank(d);
        vm.expectRevert(DeliveryRegistry.ChecklistNotFinalized.selector);
        registry.submitDelivery(second, c, "Product", "1", sbom, artifact, new uint256[](0));
    }

    function test_ResubmissionStillRequiresAllChecklistItems() public {
        _finalizeList(project, c, "Product", _requirements());
        uint256 did = _submit(d, c, project, new uint256[](0));
        uint256 eid = _submit(e, c, project, new uint256[](0));
        _review(c, did, DeliveryRegistry.Status.Approved);
        _review(c, eid, DeliveryRegistry.Status.Approved);
        uint256[] memory ids = new uint256[](2);
        ids[0] = did;
        ids[1] = eid;
        uint256 cid = _submit(c, b, project, ids);
        _review(b, cid, DeliveryRegistry.Status.Rejected);
        vm.prank(c);
        vm.expectRevert(bytes("Required delivery missing"));
        registry.resubmitDelivery(cid, "2", sbom, artifact, _one(did));
        assertEq(registry.resubmittedDeliveryIds(cid), 0);
        vm.prank(c);
        uint256 revised = registry.resubmitDelivery(cid, "2", sbom, artifact, ids);
        assertEq(registry.replacesDeliveryIds(revised), cid);
        assertEq(registry.getPreviousDeliveryIds(revised), ids);
        assertEq(uint256(registry.getDelivery(cid).status), uint256(DeliveryRegistry.Status.Rejected));
    }
}
