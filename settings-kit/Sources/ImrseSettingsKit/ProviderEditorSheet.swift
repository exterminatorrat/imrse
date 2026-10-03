#if canImport(SwiftUI)
import SwiftUI

struct ProviderEditorSheet: View {
    let mode: ProviderSheet
    let actions: ImrseSettingsActions
    let onSave: (ProviderConfiguration) -> Void
    let onDelete: (UUID) -> Void
    let onCancel: () -> Void

    @State private var provider: ProviderConfiguration
    @State private var apiKey = ""
    @State private var showAdvanced = false

    init(
        mode: ProviderSheet,
        actions: ImrseSettingsActions,
        onSave: @escaping (ProviderConfiguration) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.actions = actions
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel

        let initial: ProviderConfiguration
        switch mode {
        case .add:
            initial = ProviderConfiguration(name: "", type: .openAICompatible)
        case .edit(let existing):
            initial = existing
        }
        _provider = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Provider" : "Add Provider")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)

            VStack(spacing: 14) {
                SheetFieldRow(label: "Name") {
                    ImrseTextField(placeholder: "e.g. Local LLM", text: $provider.name, width: 255)
                }

                SheetFieldRow(label: "Type") {
                    ImrseMenuControl(selection: $provider.type, options: ProviderType.allCases, width: 255)
                }

                SheetFieldRow(label: "Base URL") {
                    ImrseTextField(placeholder: "https://", text: $provider.baseURL, width: 255)
                }

                SheetFieldRow(label: "API Key") {
                    ImrseSecureField(placeholder: provider.credentialStored ? "Stored in Keychain" : "sk-…", text: $apiKey, width: 255)
                }

                if isEditing {
                    SheetFieldRow(label: "Default Model") {
                        ImrseTextField(placeholder: "model", text: $provider.defaultModel, width: 255)
                    }
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(spacing: 10) {
                        SheetFieldRow(label: "Local only") {
                            Text("Configured by preset")
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Advanced")
                        .font(.imrseBody)
                }
                .disclosureGroupStyle(.automatic)
            }

            ImrseDivider()
                .padding(.vertical, 22)

            HStack {
                if isEditing {
                    ImrseDestructiveButton(title: "Delete") {
                        onDelete(provider.id)
                    }
                }

                Spacer()

                ImrseSecondaryButton(title: "Cancel", action: onCancel)
                ImrsePrimaryButton(title: isEditing ? "Save" : "Add") {
                    if !apiKey.isEmpty {
                        provider.credentialStored = true
                        actions.onStoreCredential(provider.id, apiKey)
                    }
                    onSave(provider)
                }
                .disabled(provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }
}

private struct SheetFieldRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(.imrseCaption)
                .frame(width: 92, alignment: .leading)
            content
        }
    }
}
#endif
