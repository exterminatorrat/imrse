#if os(macOS) && DEBUG
import AppKit
import ImrseCore
import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class SettingsAppearanceTests: XCTestCase {
    func testAppearanceOverridesHostAndTracksPreferenceAndSystemChanges() throws {
        let application = NSApplication.shared
        let previousAppearance: NSAppearance? = application.appearance
        let previousActivationPolicy = application.activationPolicy()
        let systemDarkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let systemLightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        application.appearance = systemDarkAppearance

        let configurationRoot = FileManager.default.temporaryDirectory
            .appending(path: "imrse-settings-appearance-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ConfigurationStore(root: configurationRoot)
        try store.bootstrap()
        let configuration = AppConfiguration(showInMenuBar: false, appearance: .light)
        try store.save(configuration)
        let model = AppModel(
            testEngine: TransformationEngine(
                selectionAccess: SettingsAppearanceSelectionAccess(),
                textProvider: SettingsAppearanceTextProvider()
            ),
            configuration: configuration,
            configurationStore: store
        )
        let coordinator = AppCoordinator(model: model)
        coordinator.openSettings()
        let window = try XCTUnwrap(application.windows.first { $0.title == "Settings" && $0.isVisible })
        defer {
            window.orderOut(nil)
            window.close()
            application.setActivationPolicy(previousActivationPolicy)
            application.appearance = previousAppearance
            try? FileManager.default.removeItem(at: configurationRoot)
        }

        waitForAppearance(.aqua, in: window)

        window.appearance = systemDarkAppearance
        var updated = model.configuration
        updated.appearance = .system
        try model.saveConfiguration(updated)
        waitForAppearance(.darkAqua, in: window)

        window.appearance = systemDarkAppearance
        updated.appearance = .light
        try model.saveConfiguration(updated)
        waitForAppearance(.aqua, in: window)

        window.appearance = systemLightAppearance
        updated.appearance = .dark
        try model.saveConfiguration(updated)
        waitForAppearance(.darkAqua, in: window)

        window.appearance = systemDarkAppearance
        updated.appearance = .system
        application.appearance = systemDarkAppearance
        try model.saveConfiguration(updated)
        waitForAppearance(.darkAqua, in: window)

        application.appearance = systemLightAppearance
        waitForAppearance(.aqua, in: window)
    }

    private func waitForAppearance(
        _ expected: NSAppearance.Name,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<20 {
            if window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected { return }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected, file: file, line: line)
    }

}

@MainActor
private final class SettingsAppearanceSelectionAccess: SelectionAccess {
    func capture() throws -> SelectionSnapshot {
        SelectionSnapshot(applicationID: "test", processID: 1, role: "textField", text: "selected")
    }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {}

    func discard(_ target: SelectionSnapshot) {}
}

private struct SettingsAppearanceTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
#endif
