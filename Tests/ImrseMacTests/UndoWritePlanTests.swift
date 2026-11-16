import XCTest
import ImrseCore
@testable import ImrseMac

@MainActor
final class UndoWritePlanTests: XCTestCase {
    private enum Refusal: Error { case preflight, ambiguous }

    func testReceiptDispatchesOnlyItsTransport() async throws {
        for route in [ReplacementStrategy.selectedText, .valueRange, .clipboard] {
            var calls: [ReplacementStrategy] = []
            try await UndoWritePlan(strategy: route).perform(
                selectedText: { calls.append(.selectedText) },
                valueRange: { calls.append(.valueRange) },
                clipboard: { calls.append(.clipboard) })
            XCTAssertEqual(calls, [route])
        }
    }

    func testRefusalOrAmbiguousMutationNeverTriesAnotherRoute() async {
        for route in [ReplacementStrategy.selectedText, .valueRange, .clipboard] {
            for failure in [Refusal.preflight, .ambiguous] {
                var calls: [ReplacementStrategy] = []
                do {
                    try await UndoWritePlan(strategy: route).perform(
                        selectedText: { calls.append(.selectedText); throw failure },
                        valueRange: { calls.append(.valueRange); throw failure },
                        clipboard: { calls.append(.clipboard); throw failure })
                    XCTFail("Expected terminal refusal")
                } catch { }
                XCTAssertEqual(calls, [route])
            }
        }
    }

    func testCancelledInverseDoesNotCallAnyTransport() async {
        var calls = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await UndoWritePlan(strategy: .clipboard).perform(
                    selectedText: { calls += 1 }, valueRange: { calls += 1 }, clipboard: { calls += 1 })
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        XCTAssertEqual(calls, 0)
    }

    func testFinalGateRejectsLateClipboardOptOutButDoesNotBlockNative() throws {
        XCTAssertThrowsError(try SelectionMutationGate.requireAllowed(strategy: .clipboard, clipboardEnabled: false))
        try SelectionMutationGate.requireAllowed(strategy: .selectedText, clipboardEnabled: false)
        try SelectionMutationGate.requireAllowed(strategy: .valueRange, clipboardEnabled: false)
        try SelectionMutationGate.requireAllowed(strategy: .clipboard, clipboardEnabled: true)
    }

    func testCancellationAfterPreparationBlocksEveryTextTransport() async {
        for route in [ReplacementStrategy.selectedText, .valueRange, .clipboard] {
            let task = Task { @MainActor in
                var mutations = 0
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    try SelectionMutationGate.requireAllowed(strategy: route, clipboardEnabled: true)
                    mutations += 1
                } catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(mutations, 0)
            }
            await task.value
        }
    }

    func testWholeValueProofRejectsOutsideEditsAndUnicodeNormalizationChanges() {
        let proof = UndoValueProof(original: "prefix 👩🏽‍💻 café suffix", applied: "prefix 👩🏽‍💻 CAFÉ suffix")
        XCTAssertTrue(proof.confirmsApplied("prefix 👩🏽‍💻 CAFÉ suffix"))
        XCTAssertFalse(proof.confirmsApplied("changed 👩🏽‍💻 CAFÉ suffix"))
        XCTAssertFalse(proof.confirmsApplied("prefix 👩🏽‍💻 CAFE\u{301} suffix"))
        XCTAssertFalse(proof.confirmsApplied(nil))
        XCTAssertNil(UndoValueProof.make(original: nil, applied: "x"))
        XCTAssertNil(UndoValueProof.make(original: "x", applied: nil))
    }
}
