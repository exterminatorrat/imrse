#if os(macOS)
import XCTest
import ImrseCore
@testable import ImrseMac

@MainActor
final class ClipboardUndoConfigurationTests: XCTestCase {
    private func receipt(_ strategy: ReplacementStrategy) -> ReplacementReceipt {
        ReplacementReceipt(target: SelectionSnapshot(applicationID: "test.app", processID: 1,
            role: "AXTextArea", text: "before", range: TextRange(location: 0, length: 6)),
            replacement: "after", strategy: strategy)
    }

    func testOptOutIsReceiptSpecific() {
        let access = MacSelectionAccess(clipboardFallbackEnabled: false)
        XCTAssertTrue(access.isClipboardUndoDisabled(receipt(.clipboard)))
        XCTAssertFalse(access.isClipboardUndoDisabled(receipt(.selectedText)))
        XCTAssertFalse(access.isClipboardUndoDisabled(receipt(.valueRange)))
        access.clipboardFallbackEnabled = true
        XCTAssertFalse(access.isClipboardUndoDisabled(receipt(.clipboard)))
    }

    func testDirectAdapterCallRefusesBeforeTargetOrClipboardAccess() async {
        let access = MacSelectionAccess(clipboardFallbackEnabled: false)
        do {
            try await access.undo(receipt(.clipboard))
            XCTFail("Expected configuration refusal before target access")
        } catch {
            XCTAssertEqual(error as? ImrseError, .clipboardUndoDisabled)
        }
        XCTAssertNil(access.lastWriteAttempt)
        XCTAssertNil(access.lastFailureReason)
    }
}
#endif
