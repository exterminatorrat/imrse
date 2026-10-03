#if os(macOS)
import ImrseCore
import SwiftUI

struct ShortcutsSettingsPane: View {
    @ObservedObject var model: AppModel
    let onEditPreset: (String) -> Void
    let onCreatePreset: () -> Void
    @State private var feedback: String?

    var body: some View {
        let retryAction: (() -> Void)? = model.shouldShowKeyboardMonitoringRetry
            ? { model.retryKeyboardMonitoring() } : nil

        SettingsPage(
            title: "Shortcuts",
            subtitle: "Choose how to open the imrse pill and launch saved presets.",
            symbol: "keyboard"
        ) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(
                    title: "Global activation",
                    symbol: "keyboard",
                    detail: "Opens the pill from any app."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ShortcutRecorder(
                            title: "Keyboard shortcut",
                            shortcut: globalShortcutBinding,
                            issue: $feedback,
                            isEnabled: model.canChangeSettings,
                            model: model
                        )

                        Text("Use Command, Option, or Control with a key; conflicts with system and other apps aren't detected.")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)

                        if let issue = model.shortcutIssue ?? feedback {
                            Text(issue)
                                .font(.imrseCaption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                SettingsSection(title: "Permissions", symbol: "lock.shield") {
                    VStack(spacing: 0) {
                        ShortcutPermissionRow(
                            symbol: "keyboard",
                            title: "Input Monitoring",
                            detail: "Listens for the global shortcut while imrse is in the background.",
                            status: model.eventMonitoringStatus,
                            settingsTitle: "Input Monitoring Settings",
                            settingsURL: Self.inputMonitoringSettingsURL,
                            isPreviewMode: model.isPreviewMode,
                            canRetry: model.canRetryKeyboardMonitoring,
                            onRetry: retryAction
                        )

                        ImrseDivider()

                        ShortcutPermissionRow(
                            symbol: "text.cursor",
                            title: "Accessibility",
                            detail: "Reads and replaces the text you select.",
                            status: model.accessibilityStatus,
                            settingsTitle: "Accessibility Settings",
                            settingsURL: Self.accessibilitySettingsURL,
                            isPreviewMode: model.isPreviewMode
                        )
                    }
                }

                SettingsSection(
                    title: "Preset shortcuts",
                    symbol: "square.grid.2x2",
                    detail: "Each preset saves its own shortcut."
                ) {
                    if model.presets.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No presets yet")
                                .font(.imrseBody)
                            Text("Create a preset to assign it a shortcut.")
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 46)

                        ImrsePrimaryButton(title: "Create Preset", action: onCreatePreset)
                            .disabled(!model.canChangeSettings)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.presets.enumerated()), id: \.element.id) { index, preset in
                                HStack(spacing: 12) {
                                    Text(preset.name)
                                        .font(.imrseBody)
                                    Spacer()
                                    ShortcutKeycaps(shortcut: preset.shortcut)
                                    ImrseSecondaryButton(title: "Change…") { onEditPreset(preset.id) }
                                }
                                .padding(.horizontal, 13)
                                .frame(height: 46)

                                if index < model.presets.count - 1 {
                                    ImrseDivider()
                                        .padding(.leading, 13)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var globalShortcutBinding: Binding<ShortcutBinding?> {
        Binding(
            get: { model.configuration.invocation.shortcut },
            set: { shortcut in
                guard model.canChangeSettings else { return }
                var updated = model.configuration
                updated.invocation.shortcut = shortcut
                do {
                    try model.saveConfiguration(updated)
                    feedback = nil
                } catch {
                    feedback = AppModel.userMessage(for: error)
                }
            }
        )
    }

    private static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}

private struct ShortcutPermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: String
    let settingsTitle: String
    let settingsURL: URL
    let isPreviewMode: Bool
    var canRetry = false
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(symbol: symbol, size: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.imrseBodyStrong)
                    Spacer(minLength: 8)
                    statusBadge
                }

                Text(detail)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    Link(settingsTitle, destination: settingsURL)
                        .font(.imrseCaption)
                        .disabled(isPreviewMode)

                    if let onRetry {
                        ImrseSecondaryButton(title: "Retry Keyboard Monitoring", action: onRetry)
                            .disabled(isPreviewMode || !canRetry)
                    }
                }
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case "Allowed", "Active":
            SettingsStatusBadge(title: status, symbol: "checkmark.circle.fill", tone: .positive)
        case "Required", "Inactive":
            SettingsStatusBadge(title: status, symbol: "exclamationmark.circle.fill", tone: .warning)
        case "Paused while recording":
            SettingsStatusBadge(title: status, symbol: "pause.circle", tone: .neutral)
        case "Not queried in preview":
            SettingsStatusBadge(title: status, symbol: "questionmark.circle", tone: .neutral)
        default:
            SettingsStatusBadge(title: status, symbol: "circle", tone: .neutral)
        }
    }
}
#endif
