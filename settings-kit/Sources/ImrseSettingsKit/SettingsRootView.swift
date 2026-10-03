#if canImport(SwiftUI)
import SwiftUI

public struct ImrseSettingsView: View {
    @Binding private var state: ImrseSettingsState
    private let diagnostics: DiagnosticsSnapshot
    private let actions: ImrseSettingsActions
    private let version: String

    @State private var navigation = SettingsNavigation()

    public init(
        state: Binding<ImrseSettingsState>,
        diagnostics: DiagnosticsSnapshot = .preview,
        version: String = "0.1.0",
        actions: ImrseSettingsActions = .noop
    ) {
        _state = state
        self.diagnostics = diagnostics
        self.version = version
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: $navigation)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            width: ImrseSettingsMetrics.windowWidth,
            height: ImrseSettingsMetrics.windowHeight
        )
        .background(SettingsWindowBackground())
        .background(ImrseSettingsWindowConfigurator())
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsScreen(settings: $state.general)
        case .models:
            ModelsSettingsScreen(state: $state, actions: actions)
        case .presets:
            switch navigation.detail {
            case .presetEditor(let id):
                PresetEditorScreen(
                    state: $state,
                    presetID: id,
                    isNew: false,
                    actions: actions,
                    onClose: { navigation.closeDetail() }
                )
            case .newPreset:
                PresetEditorScreen(
                    state: $state,
                    presetID: nil,
                    isNew: true,
                    actions: actions,
                    onClose: { navigation.closeDetail() }
                )
            case nil:
                PresetsSettingsScreen(
                    presets: state.presets,
                    onSelect: { navigation.openPresetEditor(id: $0) },
                    onCreate: { navigation.openNewPresetEditor() }
                )
            }
        case .shortcuts:
            ShortcutsSettingsScreen(
                state: state,
                actions: actions
            )
        case .advanced:
            AdvancedSettingsScreen(
                state: $state,
                diagnostics: diagnostics,
                actions: actions
            )
        case .about:
            AboutSettingsScreen(version: version, actions: actions)
        }
    }
}

private struct SettingsWindowBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ImrseSettingsPalette.window(scheme)
    }
}
#endif
