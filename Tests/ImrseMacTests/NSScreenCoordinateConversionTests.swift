import AppKit
import XCTest
@testable import ImrseMac

final class NSScreenCoordinateConversionTests: XCTestCase {
    func testConvertsRetinaQuartzTopOriginBoundsToCocoaPoints() {
        let result = NSScreenCoordinateConversion.cocoaRect(
            from: CGRect(x: 200, y: 100, width: 400, height: 200),
            displayBounds: CGRect(x: 0, y: 0, width: 2_880, height: 1_800),
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(result, CGRect(x: 100, y: 750, width: 200, height: 100))
    }

    func testPreservesSecondaryDisplayCocoaOrigin() {
        let result = NSScreenCoordinateConversion.cocoaRect(
            from: CGRect(x: 1_540, y: 50, width: 200, height: 100),
            displayBounds: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            screenFrame: CGRect(x: 1_440, y: -300, width: 1_920, height: 1_080)
        )

        XCTAssertEqual(result, CGRect(x: 1_540, y: 630, width: 200, height: 100))
    }

    func testRejectsUnavailableCoordinateTransforms() {
        XCTAssertNil(NSScreenCoordinateConversion.cocoaRect(
            from: CGRect(x: 0, y: 0, width: 1, height: 1),
            displayBounds: .zero,
            screenFrame: CGRect(x: 0, y: 0, width: 1, height: 1)
        ))
        XCTAssertNil(NSScreenCoordinateConversion.cocoaRect(
            from: CGRect(
                x: CGFloat.greatestFiniteMagnitude,
                y: 0,
                width: CGFloat.greatestFiniteMagnitude,
                height: 1
            ),
            displayBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            screenFrame: CGRect(x: 0, y: 0, width: 1, height: 1)
        ))
    }
}
