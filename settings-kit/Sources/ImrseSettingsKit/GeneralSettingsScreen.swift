#if canImport(SwiftUI)
import SwiftUI

struct GeneralSettingsScreen: View {
    @Binding var settings: GeneralSettings

    var body: some View {
        SettingsPage(title: "General") {
            VStack(spacing: 28) {
                ImrseLabeledRow("Invocation", subtitle: "Shortcut to show imrse.") {
                    Menu {
                        Button("Double Control") { settings.invocation = .doubleControl }
                        Button("⌥ Space") { settings.invocation = .keyboardShortcut("⌥ Space") }
                        Button("⌃ Space") { settings.invocation = .keyboardShortcut("⌃ Space") }
                    } label: {
                        ImrseMenuLabel(settings.invocation.displayName)
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                }

                ImrseLabeledRow("Animation", subtitle: "Controls the feel of the experience.") {
                    ImrseMenuControl(selection: $settings.animation, options: AnimationMode.allCases, width: 190)
                }

                ImrseLabeledRow("Launch at login", subtitle: "Start imrse automatically when you log in.") {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.primary)
                }

                ImrseLabeledRow("Show in menu bar", subtitle: "Keep a small status item in your menu bar.") {
                    Toggle("", isOn: $settings.showInMenuBar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.primary)
                }

                ImrseDivider()

                ImrseLabeledRow("Appearance", subtitle: "Follows your system settings.") {
                    ImrseMenuControl(selection: $settings.appearance, options: AppearanceMode.allCases, width: 190)
                }
            }
        }
    }
}

struct ImrseMenuLabel: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(value)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .font(.imrseBody)
        .padding(.horizontal, 12)
        .frame(width: 190, height: ImrseSettingsMetrics.controlHeight)
        .background(ImrseControlBackground())
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)

                ImrseDivider()

                content
            }
            .padding(.top, ImrseSettingsMetrics.contentTopPadding)
            .padding(.horizontal, ImrseSettingsMetrics.contentHorizontalPadding)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}
#endif
