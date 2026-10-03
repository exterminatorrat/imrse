#if canImport(SwiftUI)
import SwiftUI

struct AdvancedSettingsScreen: View {
    @Binding var state: ImrseSettingsState
    let diagnostics: DiagnosticsSnapshot
    let actions: ImrseSettingsActions

    @State private var showingDiagnostics = false

    var body: some View {
        SettingsPage(title: "Advanced") {
            VStack(spacing: 24) {
                ImrseLabeledRow("Config Location", subtitle: "Plain-text imrse configuration.") {
                    HStack(spacing: 8) {
                        ImrseControlShell(width: 300) {
                            Text("~/Library/Application Support/imrse")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ImrseSecondaryButton(title: "Open…") {
                            actions.onOpenConfigLocation()
                        }
                    }
                }

                ImrseLabeledRow("Logs", subtitle: "Open local diagnostic logs.") {
                    ImrseSecondaryButton(title: "Open Logs") {
                        actions.onOpenLogs()
                    }
                }

                ImrseLabeledRow("Diagnostics", subtitle: "Inspect permissions and runtime state without exposing your text.") {
                    ImrseSecondaryButton(title: "View…") {
                        showingDiagnostics = true
                    }
                }

                ImrseLabeledRow("Reset to Defaults", subtitle: "Reset General preferences only.") {
                    ImrseSecondaryButton(title: "Reset") {
                        state.resetGeneralToDefaults()
                    }
                }

                ImrseDivider()

                ImrseLabeledRow("Developer Options") {
                    Toggle("", isOn: $state.developerOptionsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.primary)
                }
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsSheet(
                snapshot: diagnostics,
                onCopy: {
                    actions.onCopyDiagnostics(diagnostics.redactedReport())
                },
                onClose: { showingDiagnostics = false }
            )
        }
    }
}
#endif
