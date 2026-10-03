#if os(macOS)
import XCTest
@testable import ImrseApp

final class DoubleControlIntervalInputTests: XCTestCase {
    func testAcceptsWholeMillisecondsWithinInclusiveRange() {
        XCTAssertEqual(DoubleControlIntervalDraft.milliseconds(from: "100"), 100)
        XCTAssertEqual(DoubleControlIntervalDraft.milliseconds(from: "237"), 237)
        XCTAssertEqual(DoubleControlIntervalDraft.milliseconds(from: "800"), 800)
    }

    func testRejectsNonIntegerAndOutOfRangeValues() {
        for draft in ["", "99", "801", "100.0", "+100", " 100", "100 ", "1e2"] {
            XCTAssertNil(DoubleControlIntervalDraft.milliseconds(from: draft), "\(draft) should be rejected")
        }
    }
}
#endif
