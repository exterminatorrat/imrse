#if os(macOS)
import AppKit
import ImrseCore
import SwiftUI
import XCTest
@testable import ImrseApp

@MainActor
final class SettingsControlsPolishTests: XCTestCase {
    func testRowAlignmentCanCenterLoginWithoutChangingSubtitleDefaults() {
        let centered = ImrseLabeledRow("Launch at login", subtitle: "Open imrse when you sign in.", alignment: .center) {
            Text("Control")
        }
        let defaultSubtitle = ImrseLabeledRow("Another setting", subtitle: "Context") {
            Text("Control")
        }
        let defaultPlain = ImrseLabeledRow("Another setting") {
            Text("Control")
        }

        XCTAssertEqual(centered.alignment, .center)
        XCTAssertEqual(defaultSubtitle.alignment, .top)
        XCTAssertEqual(defaultPlain.alignment, .center)
    }

    func testNativeMenuItemsReflectSelectionAndDispatchEnabledActions() throws {
        _ = NSApplication.shared
        var appearance = AppearancePreference.system
        let appearanceControl = ImrseMenuControl(
            selection: Binding(get: { appearance }, set: { appearance = $0 }),
            options: [.system, .light, .dark],
            title: { $0.settingsTitle }
        )
        XCTAssertEqual(appearanceControl.options.map(appearanceControl.title), ["System", "Light", "Dark"])
        XCTAssertEqual(appearanceControl.$selection.wrappedValue, .system)

        let coordinator = ImrseNativeMenuButton.Coordinator()
        let menu = ImrseNativeMenuButton.makeMenu(
            title: "System",
            items: appearanceControl.menuItems(isEnabled: true),
            coordinator: coordinator
        )
        XCTAssertEqual(menu.items.map(\.title), ["System", "System", "Light", "Dark"])
        XCTAssertNil(menu.items.first?.action)
        XCTAssertEqual(menu.items.dropFirst().map(\.state), [.on, .off, .off])
        let lightItem = try XCTUnwrap(menu.item(at: 2))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(lightItem.action), to: lightItem.target, from: lightItem))
        XCTAssertEqual(appearance, .light)

        XCTAssertEqual(appearanceControl.menuItems(isEnabled: true).map(\.state), [.off, .on, .off])
        let disabledMenu = ImrseNativeMenuButton.makeMenu(
            title: "Light",
            items: appearanceControl.menuItems(isEnabled: false),
            coordinator: coordinator
        )
        XCTAssertTrue(disabledMenu.items.dropFirst().allSatisfy { !$0.isEnabled })
        coordinator.activate(try XCTUnwrap(disabledMenu.item(at: 1)))
        XCTAssertEqual(appearance, .light)

        let motionControl = ImrseMenuControl(
            selection: .constant(MotionPreference.quick),
            options: [.quick, .balanced, .slow],
            title: { $0.settingsTitle }
        )

        XCTAssertEqual(motionControl.options.map(motionControl.title), ["Quick", "Balanced", "Slow"])
    }
}
#endif
