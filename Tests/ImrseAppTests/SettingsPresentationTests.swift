#if os(macOS)
import ImrseCore
import SwiftUI
import XCTest
@testable import ImrseApp

final class SettingsPresentationTests: XCTestCase {
    func testPrimarySidebarMatchesApprovedOrder() {
        XCTAssertEqual(SettingsTab.primarySidebar, [
            .general, .models, .presets, .shortcuts, .advanced
        ])
    }

    func testAboutIsPinnedAtBottomInTheSameNavigation() {
        XCTAssertEqual(SettingsTab.bottomSidebar, [.about])
        XCTAssertFalse(SettingsTab.primarySidebar.contains(.about))
        XCTAssertEqual(SettingsTab(rawValue: "about"), .about)
    }

    func testDiagnosticsIsNotASidebarDestination() {
        XCTAssertEqual(SettingsTab.allCases, [
            .general, .models, .presets, .shortcuts, .advanced, .about
        ])
        XCTAssertFalse(SettingsTab.allCases.contains { $0.rawValue == "diagnostics" })
    }

    func testPreviewNavigationValuesIncludeShortcutsAndAbout() {
        XCTAssertEqual(SettingsTab(rawValue: "shortcuts"), .shortcuts)
        XCTAssertEqual(SettingsTab(rawValue: "about"), .about)
    }

    func testAppearancePreferenceMapsToTheSettingsColorScheme() {
        XCTAssertNil(AppearancePreference.system.settingsColorScheme)
        XCTAssertEqual(AppearancePreference.light.settingsColorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.settingsColorScheme, .dark)
    }

    func testPresetDraftDoesNotMutateSavedPresetAndRetainsAllRoutingOptions() throws {
        let original = Preset(
            id: "existing-preset",
            name: "Translate",
            instruction: "Translate the selection.",
            providerID: "primary-provider",
            model: "custom-model",
            localOnly: true,
            fallbackProviderID: "fallback-provider",
            shortcut: ShortcutBinding(keyCode: 17, command: true),
            motion: .smooth,
            context: .selection
        )
        var draft = PresetDraft(preset: original)
        draft.name = "Unsaved edit"

        XCTAssertEqual(original.name, "Translate")

        let edited = try XCTUnwrap(draft.preset)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.name, "Unsaved edit")
        XCTAssertEqual(edited.instruction, original.instruction)
        XCTAssertEqual(edited.providerID, original.providerID)
        XCTAssertEqual(edited.model, original.model)
        XCTAssertEqual(edited.localOnly, original.localOnly)
        XCTAssertEqual(edited.fallbackProviderID, original.fallbackProviderID)
        XCTAssertEqual(edited.shortcut, original.shortcut)
        XCTAssertEqual(edited.motion, original.motion)
        XCTAssertEqual(edited.context, original.context)
    }
}
#endif
