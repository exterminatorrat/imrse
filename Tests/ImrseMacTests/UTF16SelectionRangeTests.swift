import Foundation
import ImrseCore
import XCTest
@testable import ImrseMac

final class UTF16SelectionRangeTests: XCTestCase {
    func testRejectsOverflowAndRangesOutsideText() {
        XCTAssertFalse(UTF16SelectionRange.isValid(TextRange(location: Int.max, length: 1)))
        XCTAssertNil(UTF16SelectionRange.substring("text", range: TextRange(location: Int.max, length: 1)))
        XCTAssertNil(UTF16SelectionRange.substring("text", range: TextRange(location: 5, length: 0)))
        XCTAssertNil(UTF16SelectionRange.make(at: Int.max, length: 1))
    }

    func testAcceptsScalarAlignedUTF16BoundariesAndReplacements() {
        let text = "A😀B"

        XCTAssertEqual(UTF16SelectionRange.substring(text, range: TextRange(location: 1, length: 2)), "😀")
        XCTAssertEqual(UTF16SelectionRange.substring(text, range: TextRange(location: 3, length: 1)), "B")
        XCTAssertNil(UTF16SelectionRange.substring(text, range: TextRange(location: 1, length: 1)))
        XCTAssertNil(UTF16SelectionRange.substring(text, range: TextRange(location: 2, length: 1)))
        XCTAssertEqual(
            UTF16SelectionRange.replacing(text, range: TextRange(location: 1, length: 2), with: "✨"),
            "A✨B"
        )
    }

    func testRecognizesOnlyCollapsedCaretAtReplacementEnd() {
        let replacementRange = TextRange(location: 0, length: 40)

        XCTAssertTrue(UTF16SelectionRange.isCollapsedCaret(
            TextRange(location: 40, length: 0),
            selectedText: "",
            atEndOf: replacementRange
        ))
        XCTAssertFalse(UTF16SelectionRange.isCollapsedCaret(
            TextRange(location: 39, length: 0),
            selectedText: "",
            atEndOf: replacementRange
        ))
        XCTAssertFalse(UTF16SelectionRange.isCollapsedCaret(
            TextRange(location: 40, length: 1),
            selectedText: "x",
            atEndOf: replacementRange
        ))
        XCTAssertFalse(UTF16SelectionRange.isCollapsedCaret(
            TextRange(location: 40, length: 0),
            selectedText: "x",
            atEndOf: replacementRange
        ))
    }

    func testExpandedReplacementRangeCannotExceedVerificationLimit() {
        XCTAssertTrue(UTF16SelectionRange.isWithinSupportedRange(TextRange(location: 999_990, length: 10)))
        XCTAssertFalse(UTF16SelectionRange.isWithinSupportedRange(TextRange(location: 999_990, length: 40)))
        XCTAssertFalse(UTF16SelectionRange.isWithinSupportedRange(TextRange(location: Int.max, length: 1)))
    }
}
