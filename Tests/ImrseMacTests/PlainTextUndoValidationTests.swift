import ImrseCore
import XCTest
@testable import ImrseMac

final class PlainTextUndoValidationTests: XCTestCase {
    @MainActor
    func testWaitsForExactRangeAndTextBeforeAcceptingUndoSelection() async throws {
        let expected = UndoSelectionProof(text: "newer", range: TextRange(location: 15, length: 5))
        let staleRange = UndoSelectionProof(text: "newer", range: TextRange(location: 14, length: 5))
        let staleText = UndoSelectionProof(text: "older", range: expected.range)
        let observations = [staleRange, staleText, expected]
        var reads = 0
        var waits = 0

        let selected = try await UndoSelectionConsistencyValidation.firstMatching(
            expected: expected,
            read: {
                defer { reads += 1 }
                return observations[reads]
            },
            wait: { waits += 1 }
        )

        XCTAssertEqual(selected?.range, expected.range)
        XCTAssertTrue(selected?.text.utf16.elementsEqual(expected.text.utf16) == true)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(waits, 2)
    }

    @MainActor
    func testStopsAfterBoundedSelectionConfirmationAttempts() async throws {
        let expected = UndoSelectionProof(text: "newer", range: TextRange(location: 15, length: 5))
        let stale = UndoSelectionProof(text: "older", range: expected.range)
        var reads = 0
        var waits = 0

        let selected = try await UndoSelectionConsistencyValidation.firstMatching(
            expected: expected,
            read: {
                reads += 1
                return stale
            },
            wait: { waits += 1 }
        )

        XCTAssertNil(selected)
        XCTAssertEqual(reads, UndoSelectionConsistencyValidation.maximumAttempts)
        XCTAssertEqual(waits, UndoSelectionConsistencyValidation.maximumAttempts - 1)
    }

    @MainActor
    func testDoesNotRetrySelectionReadErrors() async {
        var reads = 0
        var waits = 0

        do {
            _ = try await UndoSelectionConsistencyValidation.firstMatching(
                expected: UndoSelectionProof(text: "newer", range: TextRange(location: 15, length: 5)),
                read: {
                    reads += 1
                    throw SelectionReadError.focusLost
                },
                wait: { waits += 1 }
            )
            XCTFail("expected the selection read error to propagate")
        } catch SelectionReadError.focusLost {
        } catch {
            XCTFail("unexpected read error: \(error)")
        }

        XCTAssertEqual(reads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testRestoresReceiptSpanWithCollapsedCaretAndPreservesOtherText() {
        let receipt = makeReceipt()
        let caret = UndoSelectionProof(text: "", range: TextRange(location: 20, length: 0))

        let restored = PlainTextUndoValidation.restoredValue(
            currentValue: "edited leading newer changed trailing",
            receipt: receipt,
            replacementRange: TextRange(location: 15, length: 5),
            currentSelection: caret,
            receiptSelection: caret
        )

        XCTAssertEqual(restored, "edited leading old changed trailing")
    }

    func testRejectsCollapsedCaretDifferentFromReceiptSelection() {
        let receipt = makeReceipt()

        let restored = PlainTextUndoValidation.restoredValue(
            currentValue: "edited leading newer changed trailing",
            receipt: receipt,
            replacementRange: TextRange(location: 15, length: 5),
            currentSelection: UndoSelectionProof(text: "", range: TextRange(location: 19, length: 0)),
            receiptSelection: UndoSelectionProof(text: "", range: TextRange(location: 20, length: 0))
        )

        XCTAssertNil(restored)
    }

    func testRejectsChangedReplacementContent() {
        let receipt = makeReceipt()
        let caret = UndoSelectionProof(text: "", range: TextRange(location: 20, length: 0))

        let restored = PlainTextUndoValidation.restoredValue(
            currentValue: "edited leading other changed trailing",
            receipt: receipt,
            replacementRange: TextRange(location: 15, length: 5),
            currentSelection: caret,
            receiptSelection: caret
        )

        XCTAssertNil(restored)
    }

    private func makeReceipt() -> ReplacementReceipt {
        let target = SelectionSnapshot(
            applicationID: "test",
            processID: 1,
            role: "AXTextField",
            text: "old",
            range: TextRange(location: 15, length: 3)
        )
        return ReplacementReceipt(target: target, replacement: "newer", strategy: .valueRange)
    }

    private enum SelectionReadError: Error {
        case focusLost
    }
}
