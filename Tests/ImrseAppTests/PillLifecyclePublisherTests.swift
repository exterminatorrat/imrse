#if os(macOS)
import Combine
import Foundation
import ImrsePillCore
import ImrsePillUI
import XCTest

@MainActor
final class PillLifecyclePublisherTests: XCTestCase {
    func testStopIsTypedSingleUseAndCannotStopAProposalOrApplyingRequest() throws {
        var requests: [UUID] = []
        var stopped: [UUID] = []
        let model = PillModel(onSubmit: { requests.append($0.id) })
        model.onCancel = { [weak model] id in
            stopped.append(id)
            model?.failed(id, message: "cancelled fixture", kind: .cancelled)
        }
        model.present()
        model.submit()
        let oldRequest = try XCTUnwrap(requests.last)
        model.stopGeneration()
        XCTAssertEqual(stopped, [oldRequest])
        XCTAssertEqual(model.phase, .failure(oldRequest, "cancelled fixture"))
        XCTAssertEqual(model.failureKind, .cancelled)
        model.stopGeneration()
        model.stopGeneration(oldRequest)
        XCTAssertEqual(stopped, [oldRequest])
        model.dismiss()
        model.present()
        model.submit()
        let current = try XCTUnwrap(requests.last)
        model.stopGeneration(oldRequest)
        XCTAssertEqual(model.phase, .processing(current))
        XCTAssertNil(model.failureKind)
        let proposal = PillProposal(id: UUID(), requestID: current, targetID: UUID(), text: "proposal")
        model.showProposal(proposal)
        model.stopGeneration()
        XCTAssertEqual(model.phase, .proposal(current))
        model.onReplace = { _ in }
        model.replaceProposal()
        model.stopGeneration()
        model.stopGeneration(current)
        XCTAssertEqual(model.phase, .applying(current))
        XCTAssertEqual(stopped, [oldRequest])
    }

    func testProposalPreviewAndReplaceIdentityAreSingleUse() throws {
        var requestID: UUID?
        var replaced: [UUID] = []
        let model = PillModel(onSubmit: { requestID = $0.id })
        model.successDismissDelay = nil
        model.onReplace = { replaced.append($0) }
        model.present()
        model.submit()
        let request = try XCTUnwrap(requestID)
        let proposal = PillProposal(id: UUID(), requestID: request, targetID: UUID(), text: "Preview only")
        model.showProposal(proposal)
        XCTAssertEqual(model.phase, .proposal(request))
        XCTAssertEqual(model.proposal, proposal)
        XCTAssertEqual(model.previewText, proposal.text)
        XCTAssertFalse(model.canUndo)
        model.replaceProposal()
        model.replaceProposal()
        XCTAssertEqual(replaced, [proposal.id])
        XCTAssertEqual(model.phase, .applying(request))
        XCTAssertNil(model.proposal)
        XCTAssertEqual(model.previewText, "")
        model.applied(request, undoAvailable: false)
        XCTAssertEqual(model.phase, .success(request))
        XCTAssertNil(model.failureKind)
    }

    func testTypedCancellationAndStaleFailureDoNotLeakIntoNewProposal() throws {
        var requests: [UUID] = []
        let model = PillModel(onSubmit: { requests.append($0.id) })
        model.present()
        model.submit()
        let oldRequest = try XCTUnwrap(requests.last)
        model.failed(oldRequest, message: "fixture message", kind: .cancelled)
        XCTAssertEqual(model.failureKind, .cancelled)
        model.dismiss()
        XCTAssertNil(model.failureKind)
        model.present()
        model.submit()
        let request = try XCTUnwrap(requests.last)
        model.failed(oldRequest, message: "late failure", kind: .clipboardPending)
        XCTAssertEqual(model.phase, .processing(request))
        XCTAssertNil(model.failureKind)
        let stale = PillProposal(id: UUID(), requestID: oldRequest, targetID: UUID(), text: "stale")
        model.showProposal(stale)
        XCTAssertNil(model.proposal)
        let proposal = PillProposal(id: UUID(), requestID: request, targetID: UUID(), text: "current")
        model.showProposal(proposal)
        XCTAssertEqual(model.previewText, "current")
        XCTAssertNil(model.failureKind)
        model.dismiss()
        XCTAssertNil(model.proposal)
        XCTAssertNil(model.failureKind)
    }

    func testExplicitDiscardCallbackCannotRepeatOrReturnProposalText() throws {
        var requestID: UUID?
        var discarded: [UUID] = []
        let model = PillModel(onSubmit: { requestID = $0.id })
        model.onDiscard = { discarded.append($0) }
        model.present()
        model.submit()
        let proposal = PillProposal(id: UUID(), requestID: try XCTUnwrap(requestID), targetID: UUID(), text: "discard me")
        model.showProposal(proposal)
        model.discardProposal()
        model.discardProposal()
        XCTAssertEqual(discarded, [proposal.id])
        XCTAssertNil(model.proposal)
        XCTAssertEqual(model.previewText, "")
        model.dismiss()
        XCTAssertEqual(discarded, [proposal.id])
    }

    func testLifecycleChangesPublishOnlyAfterModelStoresEachPhase() throws {
        var submittedIDs: [UUID] = []
        let model = PillModel(onSubmit: { submittedIDs.append($0.id) })
        model.successDismissDelay = nil

        var emittedPhases: [PillPhase] = []
        let subscription = model.lifecycleChanges.sink { lifecycle in
            emittedPhases.append(lifecycle.phase)
            XCTAssertEqual(lifecycle.phase, model.phase)
        }
        defer { subscription.cancel() }

        XCTAssertTrue(emittedPhases.isEmpty)

        model.present()
        model.submit()
        let successID = try XCTUnwrap(submittedIDs.first)
        model.generated(successID)
        model.applied(successID, undoAvailable: false)
        model.dismiss()

        model.present()
        model.submit()
        let failureID = try XCTUnwrap(submittedIDs.last)
        model.failed(failureID, message: "fixture failure")
        model.dismiss()

        XCTAssertEqual(emittedPhases, [
            .input,
            .processing(successID),
            .applying(successID),
            .success(successID),
            .hidden,
            .input,
            .processing(failureID),
            .failure(failureID, "fixture failure"),
            .hidden
        ])
    }
}
#endif
