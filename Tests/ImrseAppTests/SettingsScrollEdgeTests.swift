#if os(macOS) && DEBUG
import XCTest
@testable import ImrseApp

final class SettingsScrollEdgeTests: XCTestCase {
    func testSubtleCueFadeIsSmoothAndBounded() {
        XCTAssertEqual(SettingsScrollEdgeCue.height, 16)
        XCTAssertEqual(SettingsScrollEdgeCue.fadeDistance, 18)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: 4), 0)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: 0), 0)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -4.5), 0.15625, accuracy: 0.0001)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -9), 0.5)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -13.5), 0.84375, accuracy: 0.0001)
        XCTAssertEqual(SettingsScrollEdgeCue.opacity(for: -18), 1)
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
