#if os(macOS) && DEBUG
import XCTest
@testable import ImrseApp

final class SettingsScrollEdgeTests: XCTestCase {
    func testMaterialCueFadeIsContinuousAndBounded() {
        XCTAssertEqual(SettingsScrollEdgeCue.height, 24)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: 4), 0)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: 0), 0)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -0.1), 0.1 / 12, accuracy: 0.0001)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -6), 0.5)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -12), 1)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -100), 1)
    }

    func testOpaqueAccessibilityFallbackDoesNotFadeThroughContent() {
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: 0, usesOpaqueFallback: true), 0)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -0.9, usesOpaqueFallback: true), 0)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -1.1, usesOpaqueFallback: true), 1)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -12, usesOpaqueFallback: true), 1)
    }
}
#endif
