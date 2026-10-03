import XCTest
@testable import ImrseSettingsKit

final class SettingsNavigationTests: XCTestCase {
    func testPrimarySidebarSectionsMatchApprovedSettingsNavigation() {
        XCTAssertEqual(SettingsSection.primarySidebar, [
            .general, .models, .presets, .shortcuts, .advanced
        ])
    }

    func testAboutIsPinnedSeparatelyAtBottom() {
        XCTAssertEqual(SettingsSection.bottomSidebar, [.about])
        XCTAssertFalse(SettingsSection.primarySidebar.contains(.about))
    }

    func testDiagnosticsIsNotAStandaloneSidebarDestination() {
        XCTAssertFalse(SettingsSection.allCases.contains { $0.rawValue == "Diagnostics" })
    }

    func testPresetEditorCancelReturnsToPresetList() {
        var navigation = SettingsNavigation(section: .presets)
        let presetID = UUID()
        navigation.openPresetEditor(id: presetID)
        XCTAssertEqual(navigation.detail, .presetEditor(presetID))
        navigation.closeDetail()
        XCTAssertNil(navigation.detail)
        XCTAssertEqual(navigation.section, .presets)
    }

    func testNewPresetEditorKeepsPresetsSelected() {
        var navigation = SettingsNavigation(section: .general)
        navigation.openNewPresetEditor()
        XCTAssertEqual(navigation.section, .presets)
        XCTAssertEqual(navigation.detail, .newPreset)
    }

    func testAboutRemainsASectionInSameSettingsWindow() {
        var navigation = SettingsNavigation(section: .general)
        navigation.select(.about)
        XCTAssertEqual(navigation.section, .about)
        XCTAssertNil(navigation.detail)
    }
}
