#if os(macOS)
import Combine
import Foundation
import ImrsePillCore
import ImrsePillUI
import XCTest

@MainActor
final class PillLifecyclePublisherTests: XCTestCase {
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
