import XCTest
@testable import ImrseSettingsKit

final class SettingsCoreTests: XCTestCase {
    func testAddingProviderPersistsIt() {
        var state = ImrseSettingsState.empty
        let provider = ProviderConfiguration(
            name: "Local",
            type: .openAICompatible,
            baseURL: "http://localhost:11434",
            defaultModel: "llama3.1"
        )
        state.addProvider(provider)
        XCTAssertEqual(state.providers, [provider])
    }

    func testEditingProviderPreservesIdentifier() {
        let original = ProviderConfiguration(name: "Local", type: .openAICompatible)
        var state = ImrseSettingsState.empty
        state.addProvider(original)
        var edited = original
        edited.name = "Local Ollama"
        state.updateProvider(edited)
        XCTAssertEqual(state.providers.first?.id, original.id)
        XCTAssertEqual(state.providers.first?.name, "Local Ollama")
    }

    func testDeletingPresetRemovesOnlySelectedPreset() {
        let one = TransformPreset(name: "Expand", instruction: "Expand")
        let two = TransformPreset(name: "Concise", instruction: "Shorten")
        var state = ImrseSettingsState.empty
        state.presets = [one, two]
        state.deletePreset(id: one.id)
        XCTAssertEqual(state.presets, [two])
    }

    func testDiagnosticsReportNeverContainsSelectedTextOrSecret() {
        let diagnostics = DiagnosticsSnapshot(
            accessibility: .granted,
            globalShortcut: .active,
            frontmostApp: "com.apple.TextEdit",
            selectionLength: 124,
            provider: "OpenAI (gpt-4o)",
            state: "Idle",
            lastError: nil
        )
        let report = diagnostics.redactedReport(secretValues: ["sk-secret", "PRIVATE TEXT"])
        XCTAssertFalse(report.contains("sk-secret"))
        XCTAssertFalse(report.contains("PRIVATE TEXT"))
        XCTAssertTrue(report.contains("Selection: Available (124 chars)"))
    }

    func testResetRestoresGeneralDefaultsWithoutDeletingProvidersOrPresets() {
        var state = ImrseSettingsState.preview
        let providerCount = state.providers.count
        let presetCount = state.presets.count
        state.general.invocation = .keyboardShortcut("⌥Space")
        state.general.animation = .smooth
        state.resetGeneralToDefaults()
        XCTAssertEqual(state.general, .defaults)
        XCTAssertEqual(state.providers.count, providerCount)
        XCTAssertEqual(state.presets.count, presetCount)
    }
}
