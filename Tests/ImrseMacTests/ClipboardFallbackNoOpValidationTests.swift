import ImrseCore
import XCTest
@testable import ImrseMac

final class ClipboardFallbackNoOpValidationTests: XCTestCase {
    func testAllowsExplicitlyEnabledExactUnchangedSelectionAndValue() {
        XCTAssertTrue(permits())
    }

    func testRejectsWhenClipboardFallbackIsDisabled() {
        XCTAssertFalse(permits(enabled: false))
    }

    func testRejectsEmptyAndWhitespaceSelections() {
        XCTAssertFalse(permits(
            range: TextRange(location: 7, length: 0),
            beforeText: "",
            afterRange: TextRange(location: 7, length: 0),
            afterText: "",
            beforeValue: "prefix suffix",
            afterValue: "prefix suffix"
        ))
        XCTAssertFalse(permits(
            range: TextRange(location: 1, length: 2),
            beforeText: " \t",
            afterRange: TextRange(location: 1, length: 2),
            afterText: " \t",
            beforeValue: "a \tb",
            afterValue: "a \tb"
        ))
    }

    func testRejectsUnavailableReadbacks() {
        XCTAssertFalse(permits(beforeValue: nil))
        XCTAssertFalse(permits(afterValue: nil))
        XCTAssertFalse(permits(afterRange: nil))
        XCTAssertFalse(permits(afterText: nil))
    }

    func testUnavailableOrMismatchedValueReadbackDisablesFallback() {
        let range = ImrseCore.TextRange(location: 7, length: 3)
        let missingBaseline = ClipboardFallbackNoOpValidation.baseline(
            value: nil,
            range: range,
            selectedText: "old"
        )
        let mismatchedBaseline = ClipboardFallbackNoOpValidation.baseline(
            value: "prefix new suffix",
            range: range,
            selectedText: "old"
        )

        XCTAssertNil(missingBaseline)
        XCTAssertNil(mismatchedBaseline)
        XCTAssertFalse(permits(beforeValue: missingBaseline))
        XCTAssertFalse(permits(beforeValue: mismatchedBaseline))
    }

    func testNativeSelectedSpanConfirmationDoesNotRequireWholeValueReadback() {
        let range = ImrseCore.TextRange(location: 7, length: 3)

        XCTAssertTrue(SelectedTextReplacementValidation.confirms(
            afterValue: nil,
            expectedValue: nil,
            afterRange: range,
            afterText: "new",
            replacementRange: range,
            replacement: "new"
        ))
    }

    func testRejectsChangedSelectionRangeTextOrWholeValue() {
        XCTAssertFalse(permits(afterRange: TextRange(location: 8, length: 2)))
        XCTAssertFalse(permits(afterText: "new"))
        XCTAssertFalse(permits(afterValue: "prefix new suffix"))
        XCTAssertFalse(permits(beforeValue: "prefix new suffix"))
    }

    func testRejectsUnsafeOrUnfocusedTarget() {
        XCTAssertFalse(permits(targetIsSafeAndFocused: false))
    }

    private func permits(
        enabled: Bool = true,
        targetIsSafeAndFocused: Bool = true,
        range: ImrseCore.TextRange = ImrseCore.TextRange(location: 7, length: 3),
        beforeText: String = "old",
        afterRange: ImrseCore.TextRange? = ImrseCore.TextRange(location: 7, length: 3),
        afterText: String? = "old",
        beforeValue: String? = "prefix old suffix",
        afterValue: String? = "prefix old suffix"
    ) -> Bool {
        ClipboardFallbackNoOpValidation.permits(
            enabled: enabled,
            targetIsSafeAndFocused: targetIsSafeAndFocused,
            range: range,
            beforeText: beforeText,
            afterRange: afterRange,
            afterText: afterText,
            beforeValue: beforeValue,
            afterValue: afterValue
        )
    }
}
