#if os(macOS)
import AppKit
import ImrseCore
import SwiftUI

struct AdvancedSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var defaultInstruction = ""
    @State private var controlIntervalDraft = ""
    @State private var controlFeedback: String?
    @State private var controlValidationFeedback: String?
    @State private var reloadFeedback: String?
    @State private var instructionFeedback: String?
    @State private var showingDiagnostics = false

    var body: some View {
        SettingsPage(
            title: "Advanced",
            subtitle: "Safety controls, local configuration, and diagnostics.",
            symbol: "slider.horizontal.3"
        ) {
            VStack(alignment: .leading, spacing: ImrseSettingsMetrics.sectionSpacing) {
                SettingsSection(
                    title: "Input and replacement",
                    symbol: "keyboard",
                    detail: "Control activation timing and selected-text replacement."
                ) {
                    VStack(spacing: 12) {
                        ImrseLabeledRow("Allow clipboard fallback") {
                            Toggle("", isOn: clipboardFallbackBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(.primary)
                                .disabled(!model.canChangeSettings)
                        }

                        SettingsHint(
                            title: "Clipboard fallback",
                            detail: "Uses the clipboard only when Accessibility can't replace selected text.",
                            symbol: "clipboard"
                        )

                        ImrseDivider()

                        ImrseLabeledRow(
                            "Double Control interval",
                            subtitle: "Time allowed between the two Control taps."
                        ) {
                            HStack(spacing: 8) {
                                ImrseTextField(placeholder: "Milliseconds", text: $controlIntervalDraft, width: 68)
                                    .accessibilityLabel("Double Control interval in milliseconds")
                                    .accessibilityValue(controlIntervalDraft)
                                    .accessibilityHint("Enter a whole number from 100 to 800.")
                                    .disabled(!canEditControlInterval)
                                    .onSubmit(commitControlInterval)
                                    .onChange(of: controlIntervalDraft) { _, draft in
                                        if DoubleControlIntervalDraft.milliseconds(from: draft) != nil {
                                            controlValidationFeedback = nil
                                        }
                                    }

                                Text("ms")
                                    .font(.imrseBody)
                                    .foregroundStyle(.secondary)

                                Stepper(
                                    "Adjust interval",
                                    value: controlIntervalDraftBinding,
                                    in: 100...800,
                                    step: 20
                                )
                                .labelsHidden()
                                .accessibilityLabel("Adjust Double Control interval")
                                .disabled(!canEditControlInterval || DoubleControlIntervalDraft.milliseconds(from: controlIntervalDraft) == nil)

                                ImrsePrimaryButton(title: "Apply", action: commitControlInterval)
                                    .disabled(!canEditControlInterval)
                            }
                        }

                        if let controlValidationFeedback {
                            SettingsHint(
                                title: "Invalid interval",
                                detail: controlValidationFeedback,
                                symbol: "exclamationmark.triangle"
                            )
                        }

                        if let controlFeedback {
                            SettingsHint(title: "Settings not saved", detail: controlFeedback, symbol: "exclamationmark.triangle")
                        }
                    }
                }

                SettingsSection(
                    title: "Configuration and diagnostics",
                    symbol: "wrench.and.screwdriver",
                    detail: "Open local files, macOS Console, or a redacted report."
                ) {
                    VStack(spacing: 0) {
                        ImrseLabeledRow("Configuration files") {
                            HStack(spacing: 8) {
                                ImrseSecondaryButton(title: "Reload from Disk", action: reloadConfiguration)
                                    .disabled(!model.canChangeSettings)
                                ImrseSecondaryButton(title: "Open…", action: openConfigurationFolder)
                                    .disabled(model.isPreviewMode)
                            }
                        }

                        if let issue = model.configurationIssue {
                            SettingsHint(
                                title: "Configuration needs attention",
                                detail: issue,
                                symbol: "exclamationmark.triangle"
                            )
                            .padding(.vertical, 8)
                        } else if let reloadFeedback {
                            SettingsHint(title: "Configuration status", detail: reloadFeedback, symbol: "info.circle")
                                .padding(.vertical, 8)
                        }

                        ImrseDivider()

                        ImrseLabeledRow("System logs") {
                            ImrseSecondaryButton(title: "Open Console", action: openConsole)
                                .disabled(model.isPreviewMode)
                        }

                        ImrseDivider()

                        ImrseLabeledRow("Diagnostics") {
                            ImrseSecondaryButton(title: "View…") { showingDiagnostics = true }
                        }
                    }
                }

                SettingsSection(
                    title: "Default instruction",
                    symbol: "text.quote",
                    detail: "Used when you submit without an instruction."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ImrseTextEditor(text: $defaultInstruction)
                            .frame(height: 130)
                            .disabled(!model.canChangeSettings)

                        ImrsePrimaryButton(title: "Save default instruction", action: saveDefaultInstruction)
                            .disabled(!model.canChangeSettings)

                        if let instructionFeedback {
                            SettingsHint(title: "Default instruction", detail: instructionFeedback, symbol: "info.circle")
                        }
                    }
                }
            }
        }
        .onAppear {
            defaultInstruction = model.defaultInstruction
            controlIntervalDraft = DoubleControlIntervalDraft.text(
                for: model.configuration.invocation.doubleControlInterval
            )
        }
        .onChange(of: model.defaultInstruction) { _, instruction in defaultInstruction = instruction }
        .onChange(of: model.configuration.invocation.doubleControlInterval) { _, interval in
            controlIntervalDraft = DoubleControlIntervalDraft.text(for: interval)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsSheet(model: model)
        }
    }

    private var clipboardFallbackBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.clipboardFallbackEnabled },
            set: { enabled in
                var updated = model.configuration
                updated.clipboardFallbackEnabled = enabled
                save(updated)
            }
        )
    }

    private var canEditControlInterval: Bool {
        model.canChangeSettings && model.configuration.invocation.doubleControlEnabled
    }

    private var controlIntervalDraftBinding: Binding<Int> {
        Binding(
            get: {
                DoubleControlIntervalDraft.milliseconds(from: controlIntervalDraft)
                    ?? Int((model.configuration.invocation.doubleControlInterval * 1_000).rounded())
            },
            set: { milliseconds in
                guard canEditControlInterval, (100...800).contains(milliseconds) else { return }
                controlIntervalDraft = String(milliseconds)
            }
        )
    }

    private func commitControlInterval() {
        guard canEditControlInterval else { return }
        guard let milliseconds = DoubleControlIntervalDraft.milliseconds(from: controlIntervalDraft) else {
            controlValidationFeedback = "Enter a whole number from 100 to 800 milliseconds."
            return
        }

        var updated = model.configuration
        updated.invocation.doubleControlInterval = Double(milliseconds) / 1_000
        save(updated)
    }

    private func save(_ configuration: AppConfiguration) {
        guard model.canChangeSettings else { return }
        do {
            try model.saveConfiguration(configuration)
            controlFeedback = nil
        } catch {
            controlFeedback = AppModel.userMessage(for: error)
        }
    }

    private func saveDefaultInstruction() {
        guard model.canChangeSettings else { return }
        do {
            try model.saveDefaultInstruction(defaultInstruction)
            instructionFeedback = "Default instruction saved."
        } catch {
            instructionFeedback = AppModel.userMessage(for: error)
        }
    }

    private func reloadConfiguration() {
        guard model.canChangeSettings else { return }
        reloadFeedback = model.reloadConfiguration() ?? "Configuration reloaded."
        defaultInstruction = model.defaultInstruction
    }

    private func openConfigurationFolder() {
        guard !model.isPreviewMode else { return }
        model.revealConfigurationFolder()
    }

    private func openConsole() {
        guard !model.isPreviewMode else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }
}

enum DoubleControlIntervalDraft {
    static func milliseconds(from draft: String) -> Int? {
        guard !draft.isEmpty,
              draft.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let milliseconds = Int(draft),
              (100...800).contains(milliseconds)
        else { return nil }
        return milliseconds
    }

    static func text(for interval: Double) -> String {
        String(Int((interval * 1_000).rounded()))
    }
}

private struct DiagnosticsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: "doc.text.magnifyingglass", size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Runtime status for troubleshooting.")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close diagnostics")
            }

            SettingsHint(
                title: "Redacted report",
                detail: "Status and metadata only; never selected or generated text, credentials, or clipboard data.",
                symbol: "lock.shield"
            )

            SettingsScrollView {
                Text(model.isPreviewMode ? "Diagnostics are not queried in preview." : model.redactedDiagnosticsReport)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(ImrseControlBackground())
            }

            if let message = model.diagnosticsCopiedMessage {
                SettingsHint(title: "Copy status", detail: message, symbol: "info.circle")
            }

            HStack {
                Spacer()
                ImrseSecondaryButton(title: "Copy Redacted Diagnostics") {
                    _ = model.copyDiagnostics()
                }
                .disabled(model.isPreviewMode)
                ImrsePrimaryButton(title: "Done") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 500, height: 360)
    }
}
#endif
