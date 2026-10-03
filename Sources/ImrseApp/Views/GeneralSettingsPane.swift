#if os(macOS)
import AppKit
import ImrseCore
import ImrseMac
import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject var model: AppModel
    let onChangeGlobalShortcut: () -> Void
    @State private var loginStatus: MainAppLoginItemStatus?
    @State private var feedback: String?

    init(model: AppModel, onChangeGlobalShortcut: @escaping () -> Void = {}) {
        self.model = model
        self.onChangeGlobalShortcut = onChangeGlobalShortcut
    }

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Set how imrse opens and behaves on this Mac.",
            symbol: "gearshape"
        ) {
            VStack(alignment: .leading, spacing: ImrseSettingsMetrics.sectionSpacing) {
                SettingsSection(
                    title: "Activation",
                    symbol: "command"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ImrseLabeledRow("Invocation", subtitle: activationHint) {
                            invocationMenu
                        }

                        ImrseDivider()

                        ImrseLabeledRow("Show in menu bar", subtitle: "Keep imrse within easy reach.") {
                            Toggle("", isOn: showInMenuBarBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(.primary)
                                .disabled(!model.canChangeSettings)
                        }
                    }
                }

                SettingsSection(
                    title: "Preferences",
                    symbol: "slider.horizontal.3"
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        ImrseLabeledRow("Animation", subtitle: "Control transition speed.") {
                            ImrseMenuControl(
                                selection: motionBinding,
                                options: [.quick, .balanced, .slow],
                                title: { $0.settingsTitle },
                                accessibilityLabel: "Animation"
                            )
                            .disabled(!model.canChangeSettings)
                        }

                        ImrseDivider()

                        ImrseLabeledRow("Launch at login", subtitle: "Open imrse when you sign in.", alignment: .center) {
                            loginControl
                        }

                        if !model.isPreviewMode && loginStatus == .requiresApproval {
                            SettingsHint(
                                title: "Approval required",
                                detail: "macOS requires your approval before imrse can open at login.",
                                symbol: "exclamationmark.circle"
                            )
                                .padding(.vertical, 8)
                        }

                        if !model.isPreviewMode && loginStatus == .notFound {
                            SettingsHint(
                                title: "Launch at login unavailable",
                                detail: "macOS reports no login service for this app. Choose Enable… to ask macOS to register imrse.",
                                symbol: "minus.circle"
                            )
                                .padding(.vertical, 8)
                        }

                        ImrseDivider()

                        ImrseLabeledRow("Appearance", subtitle: "Follow macOS, light or dark.") {
                            ImrseMenuControl(
                                selection: appearanceBinding,
                                options: [.system, .light, .dark],
                                title: { $0.settingsTitle },
                                accessibilityLabel: "Appearance"
                            )
                            .disabled(!model.canChangeSettings)
                        }
                    }
                }

                if let feedback {
                    SettingsHint(title: "Settings", detail: feedback, symbol: "info.circle")
                }

                if let issue = model.configurationIssue {
                    SettingsHint(title: "Configuration issue", detail: issue, symbol: "exclamationmark.triangle")
                }
            }
        }
        .onAppear(perform: loadLoginStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loadLoginStatus()
        }
    }

    private var activationHint: String {
        if model.configuration.invocation.doubleControlEnabled {
            return "Double-press Control to open imrse from the keyboard."
        }
        if let shortcut = model.configuration.invocation.shortcut {
            return "Press \(ShortcutFormatter.label(for: shortcut)) to open imrse."
        }
        return "Open Shortcuts to set a keyboard shortcut."
    }

    private var invocationMenu: some View {
        ImrseNativeMenuButton(
            title: invocationTitle,
            accessibilityLabel: "Invocation",
            items: [
                ImrseNativeMenuItem(
                    title: "Double Control",
                    state: model.configuration.invocation.doubleControlEnabled ? .on : .off,
                    isEnabled: model.canChangeSettings
                ) {
                    doubleControlBinding.wrappedValue.toggle()
                },
                ImrseNativeMenuItem(
                    title: model.configuration.invocation.shortcut.map {
                        "Change \(ShortcutFormatter.label(for: $0)) in Shortcuts…"
                    } ?? "Set keyboard shortcut in Shortcuts…",
                    state: .off,
                    isEnabled: true,
                    action: onChangeGlobalShortcut
                )
            ]
        )
        .frame(width: ImrseSettingsMetrics.controlWidth, height: ImrseSettingsMetrics.controlHeight)
        .background(ImrseControlBackground())
        .contentShape(Rectangle())
    }

    private var invocationTitle: String {
        let invocation = model.configuration.invocation
        let shortcut = invocation.shortcut.map(ShortcutFormatter.label(for:))
        return switch (invocation.doubleControlEnabled, shortcut) {
        case (true, let shortcut?): "Double Control + \(shortcut)"
        case (true, nil): "Double Control"
        case (false, let shortcut?): shortcut
        case (false, nil): "Not set"
        }
    }

    @ViewBuilder
    private var loginControl: some View {
        if model.isPreviewMode {
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.primary)
                .disabled(true)
                .help("Preview fixture; launch-at-login status is not queried.")
                .accessibilityLabel("Launch at login preview fixture; status not queried")
        } else if loginStatus == nil {
            Text("Checking…")
                .font(.imrseCaption)
                .foregroundStyle(.secondary)
        } else if loginStatus == .requiresApproval {
            HStack(spacing: 8) {
                SettingsStatusBadge(title: "Approval required", symbol: "exclamationmark.circle", tone: .warning)
                ImrseSecondaryButton(title: "Open Settings…", action: openLoginItemsSettings)
                    .help("Open System Settings → General → Login Items.")
            }
        } else if loginStatus == .notFound {
            HStack(spacing: 8) {
                SettingsStatusBadge(title: "Unavailable", symbol: "minus.circle", tone: .neutral)
                ImrseSecondaryButton(title: "Enable…", action: enableLoginItemFromNotFound)
                    .disabled(!model.canChangeSettings)
                    .help("Ask macOS to register imrse at login.")
            }
        } else if loginStatus == .enabled || loginStatus == .notRegistered {
            Toggle("", isOn: Binding(
                get: { loginStatus == .enabled },
                set: { enabled in setLoginItemEnabled(enabled) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.primary)
            .disabled(!model.canChangeSettings)
            .accessibilityLabel("Launch at login")
        } else {
            SettingsStatusBadge(title: "Unknown", symbol: "questionmark.circle", tone: .neutral)
        }
    }

    private var doubleControlBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.invocation.doubleControlEnabled },
            set: { enabled in
                var updated = model.configuration
                updated.invocation.doubleControlEnabled = enabled
                save(updated)
            }
        )
    }

    private var motionBinding: Binding<MotionPreference> {
        Binding(
            get: { model.configuration.motion },
            set: { preference in
                var updated = model.configuration
                updated.motion = preference
                save(updated)
            }
        )
    }

    private var showInMenuBarBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.showInMenuBar },
            set: { visible in
                var updated = model.configuration
                updated.showInMenuBar = visible
                save(updated)
            }
        )
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { model.configuration.appearance },
            set: { appearance in
                var updated = model.configuration
                updated.appearance = appearance
                save(updated)
            }
        )
    }

    private func save(_ configuration: AppConfiguration) {
        guard model.canChangeSettings else { return }
        do {
            try model.saveConfiguration(configuration)
            feedback = nil
        } catch {
            feedback = AppModel.userMessage(for: error)
        }
    }

    private func loadLoginStatus() {
        guard !model.isPreviewMode else { return }
        let status = MainAppLoginItemService.status
        if loginStatus != status { feedback = nil }
        loginStatus = status
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        guard model.canChangeSettings, !model.isPreviewMode else { return }
        do {
            let status = try MainAppLoginItemService.setEnabled(enabled)
            loginStatus = status
            feedback = loginItemFeedback(requesting: enabled, observed: status)
        } catch {
            loginStatus = MainAppLoginItemService.status
            feedback = "Couldn't change Launch at login: \(error.localizedDescription)"
        }
    }

    private func openLoginItemsSettings() {
        guard !model.isPreviewMode, loginStatus == .requiresApproval else { return }
        MainAppLoginItemService.openSystemSettingsLoginItems()
    }

    private func enableLoginItemFromNotFound() {
        guard model.canChangeSettings, !model.isPreviewMode, loginStatus == .notFound else { return }
        do {
            let status = try MainAppLoginItemService.recoverFromNotFound()
            loginStatus = status
            feedback = loginItemFeedback(requesting: true, observed: status)
        } catch {
            loginStatus = MainAppLoginItemService.status
            feedback = "Couldn't enable Launch at login: \(error.localizedDescription)"
        }
    }

    private func loginItemFeedback(
        requesting enabled: Bool,
        observed status: MainAppLoginItemStatus
    ) -> String {
        switch status {
        case .enabled:
            enabled ? "imrse will open at login." : "macOS still reports imrse enabled at login."
        case .notRegistered:
            enabled ? "macOS hasn't enabled imrse at login." : "imrse won't open at login."
        case .requiresApproval:
            "Approve imrse in System Settings → General → Login Items."
        case .notFound:
            "macOS couldn't find a login service for this app."
        case .unknown:
            "macOS returned an unknown Launch at login status."
        }
    }
}
#endif
