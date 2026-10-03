#if os(macOS) && DEBUG
import SwiftUI
import XCTest
@testable import ImrseApp

final class AppModelPreviewSelectionTests: XCTestCase {
    func testSettingsPreviewCanSelectEverySidebarPane() {
        for pane in ["general", "models", "presets", "shortcuts", "advanced", "about"] {
            let arguments = ["imrse", "--preview-state", "settings", "--preview-settings-pane", pane]
            XCTAssertEqual(AppPreviewState.settingsTab(
                from: arguments, previewState: .settings, isPreviewMode: true
            ).rawValue, pane)
            XCTAssertEqual(AppPreviewState.settingsTab(
                from: ["imrse", "--preview-state=settings", "--preview-settings-pane=\(pane)"],
                previewState: .settings,
                isPreviewMode: true
            ).rawValue, pane)
        }
        XCTAssertEqual(AppPreviewState.settingsTab(
            from: ["imrse", "--preview-state", "settings", "--preview-settings-pane", "unknown"],
            previewState: .settings,
            isPreviewMode: true
        ), .general)
    }

    func testSettingsPreviewAppearanceIsFixtureOnly() {
        XCTAssertEqual(AppPreviewState.colorScheme(
            from: ["imrse", "--preview-appearance", "light"],
            previewState: .settings,
            isPreviewMode: true
        ), .light)
        XCTAssertEqual(AppPreviewState.colorScheme(
            from: ["imrse", "--preview-appearance=dark"],
            previewState: .settings,
            isPreviewMode: true
        ), .dark)
        XCTAssertNil(AppPreviewState.colorScheme(
            from: ["imrse", "--preview-appearance", "dark"],
            previewState: .ready,
            isPreviewMode: true
        ))
        XCTAssertNil(AppPreviewState.colorScheme(
            from: ["imrse", "--preview-appearance", "dark"],
            previewState: .settings,
            isPreviewMode: false
        ))
        XCTAssertNil(AppPreviewState.colorScheme(
            from: ["imrse", "--preview-appearance", "system"],
            previewState: .settings,
            isPreviewMode: true
        ))
    }

    func testProviderSelectionOnlyAppliesToExplicitModelsPreview() {
        for section in ModelProviderSection.allCases {
            let arguments = ["imrse", "--preview-settings-pane", "models", "--preview-model-provider", section.rawValue]
            XCTAssertEqual(AppPreviewState.modelProviderSection(
                from: arguments, previewState: .settings, isPreviewMode: true
            ), section)
            XCTAssertNil(AppPreviewState.modelProviderSection(
                from: arguments, previewState: .settings, isPreviewMode: false
            ))
            XCTAssertNil(AppPreviewState.modelProviderSection(
                from: arguments, previewState: .ready, isPreviewMode: true
            ))
        }
        for arguments in [
            ["imrse"],
            ["imrse", "--preview-settings-pane", "general", "--preview-model-provider", "local"],
            ["imrse", "--preview-settings-pane", "models", "--preview-model-provider"],
            ["imrse", "--preview-settings-pane", "models", "--preview-model-provider", "unknown"]
        ] {
            XCTAssertNil(AppPreviewState.modelProviderSection(
                from: arguments, previewState: .settings, isPreviewMode: true
            ))
        }
    }
}
#endif
