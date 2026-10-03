import Foundation
import ImrseCore
import XCTest
@testable import ImrseServices

final class SettingsPresentationConfigurationTests: XCTestCase {
    func testExistingConfigurationDefaultsPresentationWithoutChangingRouting() throws {
        let directory = try SettingsPresentationTestDirectory()
        let store = ConfigurationStore(root: directory.url)
        let provider = ProviderConfiguration(
            id: "local", name: "Local", kind: .managedLocal,
            endpoint: URL(string: "imrse-local://models")!,
            model: "mlx-community/Qwen3-1.7B-4bit", requiresCredential: false
        )
        let configuration = AppConfiguration(providers: [provider], selectedProviderID: provider.id)
        try store.save(configuration)
        let url = directory.url.appending(path: "config.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "showInMenuBar")
        object.removeValue(forKey: "appearance")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        XCTAssertEqual(try store.load(), configuration)
        XCTAssertTrue(try store.load().showInMenuBar)
        XCTAssertEqual(try store.load().appearance, .system)
    }

    func testPresentationPreferencesRoundTripWithOtherSettingsUnchanged() throws {
        let directory = try SettingsPresentationTestDirectory()
        let store = ConfigurationStore(root: directory.url)
        let configuration = AppConfiguration(
            invocation: InvocationConfiguration(shortcut: ShortcutBinding(keyCode: 49, option: true)),
            motion: .smooth, clipboardFallbackEnabled: true,
            showInMenuBar: false, appearance: .dark
        )
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
    }

    func testInvalidPresentationValuesAreRejected() throws {
        let directory = try SettingsPresentationTestDirectory()
        let store = ConfigurationStore(root: directory.url)
        try store.bootstrap()
        let url = directory.url.appending(path: "config.json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for (key, value) in [("showInMenuBar", "yes"), ("appearance", "sepia")] {
            var object = original
            object[key] = value
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
            }
        }
    }
}

private final class SettingsPresentationTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "imrse-settings-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
