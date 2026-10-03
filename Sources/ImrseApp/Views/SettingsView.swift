#if os(macOS)
import ImrseCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case models
    case presets
    case shortcuts
    case advanced
    case about

    static let primarySidebar: [SettingsTab] = [
        .general, .models, .presets, .shortcuts, .advanced
    ]

    static let bottomSidebar: [SettingsTab] = [.about]

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .presets: "Presets"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .models: "cube"
        case .presets: "line.3.horizontal.decrease"
        case .shortcuts: "keyboard"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var selectedTab: SettingsTab
    @State private var requestedPresetID: String?
    private let initialModelProvider: ModelProviderSection?

    init(model: AppModel, initialTab: SettingsTab = .general, initialModelProvider: ModelProviderSection? = nil) {
        self.model = model
        self.initialModelProvider = initialModelProvider
        _selectedTab = State(initialValue: initialTab)
        _requestedPresetID = State(initialValue: nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedTab)

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: ImrseSettingsMetrics.windowWidth, height: ImrseSettingsMetrics.windowHeight)
        .ignoresSafeArea()
        .background(ImrseSettingsPalette.window(effectiveColorScheme))
        .clipped()
        .tint(.primary)
        .preferredColorScheme(model.configuration.appearance.settingsColorScheme)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsPane(model: model) {
                selectedTab = .shortcuts
            }
        case .models:
            ModelsSettingsPane(model: model, initialSection: initialModelProvider)
        case .presets:
            PresetsSettingsPane(model: model, requestedPresetID: $requestedPresetID)
        case .shortcuts:
            ShortcutsSettingsPane(
                model: model,
                onEditPreset: { presetID in
                    requestedPresetID = presetID
                    selectedTab = .presets
                },
                onCreatePreset: { selectedTab = .presets }
            )
        case .advanced:
            AdvancedSettingsPane(model: model)
        case .about:
            AboutSettingsPane(model: model)
        }
    }

    private var effectiveColorScheme: ColorScheme {
        model.configuration.appearance.settingsColorScheme ?? systemColorScheme
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("imrse")
                .font(.system(size: 22, weight: .regular, design: .default))
                .tracking(-0.5)
                .padding(.top, 36)
                .padding(.horizontal, 20)
                .padding(.bottom, 22)

            VStack(spacing: 5) {
                ForEach(SettingsTab.primarySidebar, id: \.self) { tab in
                    SettingsSidebarRow(tab: tab, isSelected: selection == tab) {
                        selection = tab
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 24)

            ImrseDivider()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            ForEach(SettingsTab.bottomSidebar, id: \.self) { tab in
                SettingsSidebarRow(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
        .frame(width: ImrseSettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(ImrseSettingsPalette.sidebar(scheme))
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 19)
                Text(tab.title)
                    .font(.system(size: 13.5, weight: .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: ImrseSettingsMetrics.selectionCornerRadius, style: .continuous)
                    .fill(isSelected ? ImrseSettingsPalette.selection(scheme) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-sidebar-\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
