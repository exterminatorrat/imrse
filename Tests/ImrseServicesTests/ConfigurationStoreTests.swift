import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore

final class ConfigurationStoreTests: XCTestCase {
    func testMainAndPresetShortcutChangesAndClearingPreserveOtherSettings() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        var configuration = AppConfiguration(
            providers: [provider(id: "one")],
            selectedProviderID: "one",
            invocation: InvocationConfiguration(shortcut: ShortcutBinding(keyCode: 49, command: true, option: true))
        )
        try store.save(configuration)
        var preset = Preset(
            id: "polish", name: "Polish", instruction: "Preserve this instruction.",
            providerID: "one", model: "custom-model", motion: .instant
        )
        preset.shortcut = ShortcutBinding(keyCode: 35, control: true, shift: true)
        try store.savePreset(preset)

        var conflicting = configuration
        conflicting.invocation.shortcut = preset.shortcut
        XCTAssertThrowsError(try store.save(conflicting)) {
            XCTAssertEqual($0 as? ImrseError, .shortcutConflict)
        }
        XCTAssertEqual(try store.load(), configuration)

        configuration.invocation.shortcut = ShortcutBinding(keyCode: 122, command: true)
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)

        configuration.invocation.shortcut = nil
        configuration.invocation.doubleControlEnabled = false
        preset.shortcut = nil
        try store.save(configuration)
        try store.savePreset(preset)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try store.loadPresets(), [preset])
    }

    func testUnknownConfigurationKeysAreRejectedInsteadOfIgnored() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        try store.bootstrap()
        let url = directory.url.appending(path: "config.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["localOnly"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
        }
    }

    func testUnknownPrivacyKeysCannotSilentlyDisableLocalOnly() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        try store.bootstrap()
        let preset = "---\n{\"id\":\"private\",\"name\":\"Private\",\"local_only\":true}\n---\nRewrite this.\n"
        try Data(preset.utf8).write(to: directory.url.appending(path: "presets/private.md"))
        XCTAssertThrowsError(try store.loadPresets()) {
            XCTAssertEqual($0 as? ImrseError, .invalidPreset)
        }
    }

    func testBootstrapCreatesDefaultsAndNeverOverwritesUserFiles() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        try store.bootstrap()

        let configuration = AppConfiguration(
            providers: [provider(id: "one")],
            selectedProviderID: "one"
        )
        try store.save(configuration)
        try store.saveDefaultInstruction("Keep my custom instruction.")
        let preset = Preset(id: "rewrite", name: "Rewrite", instruction: "Rewrite this.")
        try store.savePreset(preset)

        let configurationBefore = try Data(contentsOf: directory.url.appending(path: "config.json"))
        let defaultBefore = try Data(contentsOf: directory.url.appending(path: "default.md"))
        let presetBefore = try Data(contentsOf: directory.url.appending(path: "presets/rewrite.md"))

        try store.bootstrap()

        XCTAssertEqual(try Data(contentsOf: directory.url.appending(path: "config.json")), configurationBefore)
        XCTAssertEqual(try Data(contentsOf: directory.url.appending(path: "default.md")), defaultBefore)
        XCTAssertEqual(try Data(contentsOf: directory.url.appending(path: "presets/rewrite.md")), presetBefore)
    }

    func testMissingAndBlankDefaultInstructionRecoverBuiltInText() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        XCTAssertFalse(try store.loadDefaultInstruction().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try Data(" \n\t".utf8).write(to: directory.url.appending(path: "default.md"))
        let recovered = try store.loadDefaultInstruction()
        XCTAssertEqual(recovered, ConfigurationStore.builtInDefaultInstruction)
        XCTAssertTrue(recovered.contains("grammar"))
        XCTAssertTrue(recovered.contains("technical terminology"))
        XCTAssertTrue(recovered.contains("Do not invent facts"))
        XCTAssertTrue(recovered.contains("formatting"))
    }

    func testConfigurationAndPresetRoundTrip() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        let configuration = AppConfiguration(
            providers: [provider(id: "one")],
            selectedProviderID: "one",
            invocation: InvocationConfiguration(shortcut: ShortcutBinding(keyCode: 0, command: true))
        )
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)

        let preset = Preset(
            id: "polish",
            name: "Polish",
            instruction: "Improve clarity and preserve meaning.\n\nKeep the voice.",
            providerID: "one",
            model: "model-2",
            fallbackProviderID: "two",
            shortcut: ShortcutBinding(keyCode: 1, control: true),
            motion: .instant
        )
        try store.savePreset(preset)
        XCTAssertEqual(try store.loadPresets(), [preset])

        let markdown = try String(contentsOf: directory.url.appending(path: "presets/polish.md"), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\n{"))
        XCTAssertTrue(markdown.contains("Improve clarity and preserve meaning."))
    }

    func testInvalidConfigurationAndPresetFieldsAreRejected() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)

        XCTAssertThrowsError(try store.save(AppConfiguration(providers: [provider(id: "one", model: " ")])) ) {
            XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
        }
        XCTAssertThrowsError(try store.savePreset(Preset(id: "../outside", name: "Bad", instruction: "Do something"))) {
            XCTAssertEqual($0 as? ImrseError, .invalidPreset)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.deletingLastPathComponent().appending(path: "outside.md").path))
    }

    func testShortcutRequirementsAndConflictsAreEnforcedAcrossFiles() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigurationStore(root: directory.url)
        XCTAssertThrowsError(try store.save(AppConfiguration(invocation: InvocationConfiguration(shortcut: ShortcutBinding(keyCode: 12))))) {
            XCTAssertEqual($0 as? ImrseError, .shortcutConflict)
        }
        try store.save(AppConfiguration(invocation: InvocationConfiguration(shortcut: ShortcutBinding(keyCode: 12, command: true))))
        XCTAssertThrowsError(try store.savePreset(Preset(
            id: "same-key",
            name: "Same key",
            instruction: "Rewrite",
            shortcut: ShortcutBinding(keyCode: 12, command: true)
        ))) {
            XCTAssertEqual($0 as? ImrseError, .shortcutConflict)
        }
    }

    func testMalformedConfigurationDoesNotSilentlyReset() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try Data("{not-json}".utf8).write(to: directory.url.appending(path: "config.json"))
        let store = ConfigurationStore(root: directory.url)

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
        }
    }

    func testOversizedAndSymbolicLinkConfigurationFilesAreRejected() throws {
        let directory = try TemporaryDirectory()
        try Data(repeating: 0x61, count: 65_537).write(to: directory.url.appending(path: "default.md"))
        let store = ConfigurationStore(root: directory.url)
        XCTAssertThrowsError(try store.loadDefaultInstruction()) {
            XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
        }

        let external = directory.url.appending(path: "external.json")
        try Data("{}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: "config.json"), withDestinationURL: external)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
        }
    }

    func testPresetDirectorySymbolicLinkIsRejected() throws {
        let directory = try TemporaryDirectory()
        let external = directory.url.appending(path: "external-presets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let root = directory.url.appending(path: "config-root", directoryHint: .isDirectory)
        let presets = root.appending(path: "presets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: presets, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: presets)
        try FileManager.default.createSymbolicLink(at: presets, withDestinationURL: external)
        let store = ConfigurationStore(root: root)

        XCTAssertThrowsError(try store.loadPresets()) {
            XCTAssertEqual($0 as? ImrseError, .invalidPreset)
        }
    }
}

private func provider(id: String, model: String = "model-1") -> ProviderConfiguration {
    ProviderConfiguration(
        id: id,
        name: id,
        kind: .compatible,
        endpoint: URL(string: "https://example.com/v1")!,
        model: model
    )
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "imrse-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
