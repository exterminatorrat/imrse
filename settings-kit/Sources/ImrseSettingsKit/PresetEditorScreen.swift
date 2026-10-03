#if canImport(SwiftUI)
import SwiftUI

struct PresetEditorScreen: View {
    @Binding var state: ImrseSettingsState
    let presetID: UUID?
    let isNew: Bool
    let actions: ImrseSettingsActions
    let onClose: () -> Void

    @State private var draft: TransformPreset

    init(
        state: Binding<ImrseSettingsState>,
        presetID: UUID?,
        isNew: Bool,
        actions: ImrseSettingsActions,
        onClose: @escaping () -> Void
    ) {
        _state = state
        self.presetID = presetID
        self.isNew = isNew
        self.actions = actions
        self.onClose = onClose

        if let presetID, let existing = state.wrappedValue.presets.first(where: { $0.id == presetID }) {
            _draft = State(initialValue: existing)
        } else {
            _draft = State(initialValue: TransformPreset(name: "", instruction: ""))
        }
    }

    var body: some View {
        SettingsPage(title: isNew ? "New Preset" : "Edit Preset") {
            VStack(spacing: 20) {
                ImrseLabeledRow("Name") {
                    ImrseTextField(placeholder: "Preset name", text: $draft.name, width: 300)
                }

                ImrseLabeledRow("Instruction") {
                    ImrseTextEditor(text: $draft.instruction)
                        .frame(width: 300)
                }

                ImrseLabeledRow("Model") {
                    Menu {
                        Button("Use Default") { draft.model = "Use Default" }
                        ForEach(state.providers) { provider in
                            Button(provider.defaultModel.isEmpty ? provider.name : provider.defaultModel) {
                                draft.model = provider.defaultModel.isEmpty ? provider.name : provider.defaultModel
                            }
                        }
                    } label: {
                        ImrseMenuLabel(draft.model)
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                }

                ImrseLabeledRow("Shortcut") {
                    Button {
                        actions.onChangePresetShortcut(draft.id)
                    } label: {
                        HStack {
                            Text(draft.shortcut.isEmpty ? "None" : draft.shortcut)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .font(.imrseBody)
                        .padding(.horizontal, 12)
                        .frame(width: 190, height: ImrseSettingsMetrics.controlHeight)
                        .background(ImrseControlBackground())
                    }
                    .buttonStyle(.plain)
                }

                ImrseLabeledRow("Local only", subtitle: "Never send this preset to a cloud provider.") {
                    Toggle("", isOn: $draft.localOnly)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.primary)
                }

                ImrseDivider()

                HStack {
                    if !isNew {
                        ImrseDestructiveButton(title: "Delete") {
                            state.deletePreset(id: draft.id)
                            onClose()
                        }
                    }

                    Spacer()

                    ImrseSecondaryButton(title: "Cancel", action: onClose)
                    ImrsePrimaryButton(title: "Save") {
                        if isNew {
                            state.addPreset(draft)
                        } else {
                            state.updatePreset(draft)
                        }
                        onClose()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                }
            }
        }
    }
}
#endif
