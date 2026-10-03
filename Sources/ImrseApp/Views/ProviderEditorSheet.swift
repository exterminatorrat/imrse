#if os(macOS)
import ImrseCore
import SwiftUI

enum ProviderEditorMode: Identifiable, Equatable {
    case add
    case edit(String)
    case preview(ModelProviderSection)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let providerID): "provider:\(providerID)"
        case .preview(let section): "preview:\(section.rawValue)"
        }
    }
}

struct ProviderEditorSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: ModelProviderSection?
    @State private var providerRemovalFeedback: String?
    @State private var providerRemovalError: String?
    @State private var isConfirmingProviderRemoval = false
    @State private var isRemovingProvider = false
    let mode: ProviderEditorMode

    init(model: AppModel, mode: ProviderEditorMode) {
        self.model = model
        self.mode = mode
        let initialSection: ModelProviderSection? = switch mode {
        case .add: nil
        case .edit(let providerID):
            model.configuration.providers.first(where: { $0.id == providerID }).flatMap {
                ModelProviderSection.forProvider($0)
            }
        case .preview(let section): section
        }
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if isAddingFromTypeList {
                    Button {
                        selectedSection = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.imrseBody)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to provider types")
                }

                SettingsIcon(symbol: selectedSection?.symbolName ?? "square.stack.3d.up", size: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    if isAddTypeSelection {
                        Text("Choose how imrse handles model requests.")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)
            }

            if isAddTypeSelection {
                SettingsSection(
                    title: "Provider type",
                    symbol: "square.stack.3d.up",
                    detail: "Choose how model requests are handled."
                ) {
                    ProviderAddChoiceList { selectedSection = $0 }
                }
            } else if let providerRemovalFeedback {
                SettingsHint(
                    title: "Provider removed",
                    detail: providerRemovalFeedback,
                    symbol: "checkmark.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if isEditingMissingProvider {
                SettingsHint(
                    title: "Provider unavailable",
                    detail: "This provider is no longer configured.",
                    symbol: "exclamationmark.triangle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let selectedSection {
                SettingsScrollView {
                    providerSettings(for: selectedSection)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
                .scrollIndicators(.hidden)
            }

            if let providerRemovalError {
                Text(providerRemovalError)
                    .font(.imrseCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(providerRemovalError)
            }

            Spacer(minLength: 0)
            ImrseDivider()
            if canShowRemoveProvider && providerIsInUse {
                Text("A preset uses this provider. Change the preset before removing it.")
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
            }
            if canShowRemoveProvider, let providerRemovalRestriction {
                Text(providerRemovalRestriction)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if canShowRemoveProvider {
                    ImrseDestructiveButton(title: providerRemovalActionTitle) {
                        isConfirmingProviderRemoval = true
                    }
                    .disabled(!canRemoveProvider)
                }
                Spacer()
                ImrseSecondaryButton(title: "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 700, height: 580)
        .background(ImrseSettingsPalette.window(colorScheme))
        .confirmationDialog(
            providerRemovalConfirmationTitle,
            isPresented: $isConfirmingProviderRemoval,
            titleVisibility: .visible
        ) {
            Button(providerRemovalActionTitle, role: .destructive, action: removeSavedProvider)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(providerRemovalConfirmation)
        }
    }

    private var title: String {
        if providerRemovalFeedback != nil { return "Provider removed" }
        switch mode {
        case .add:
            guard let selectedSection else { return "Add Provider" }
            return activeProvider.map { "Edit \($0.name)" } ?? "Add \(selectedSection.title)"
        case .edit:
            return activeProvider.map { "Edit \($0.name)" } ?? "Edit Provider"
        case .preview:
            return activeProvider == nil ? "Add Provider" : "Edit Provider"
        }
    }

    private var isAddingFromTypeList: Bool {
        if case .add = mode { return selectedSection != nil }
        return false
    }

    private var isAddTypeSelection: Bool {
        if case .add = mode { return selectedSection == nil }
        return false
    }

    private var isEditingMissingProvider: Bool {
        guard case .edit(let providerID) = mode else { return false }
        return !model.configuration.providers.contains { $0.id == providerID }
    }

    private var canShowRemoveProvider: Bool {
        guard case .edit = mode,
              !model.isPreviewMode,
              activeProvider != nil
        else { return false }
        return true
    }

    private var isChatGPTAccountProvider: Bool {
        activeProvider?.kind == .openAIChatGPT
    }

    private var hasUnsupportedChatGPTIdentity: Bool {
        guard let activeProvider, activeProvider.kind == .openAIChatGPT else { return false }
        return activeProvider.id != model.chatGPTProviderID
    }

    private var isChatGPTAccountOperationBusy: Bool {
        isChatGPTAccountProvider && (model.isConnectingChatGPT || model.isDisconnectingChatGPT)
    }

    private var providerRemovalActionTitle: String {
        isChatGPTAccountProvider ? "Disconnect & Remove" : "Remove Provider"
    }

    private var providerRemovalConfirmationTitle: String {
        if isChatGPTAccountProvider {
            return "Disconnect and remove \(activeProvider?.name ?? "ChatGPT account")?"
        }
        return "Remove \(activeProvider?.name ?? "provider")?"
    }

    private var providerRemovalRestriction: String? {
        if hasUnsupportedChatGPTIdentity {
            return "This saved ChatGPT provider isn't managed by this app's account identity and can't be disconnected here."
        }
        if isChatGPTAccountOperationBusy {
            return "Wait for ChatGPT sign-in or disconnect to finish before removing this provider."
        }
        return nil
    }

    private var providerRemovalConfirmation: String {
        if hasUnsupportedChatGPTIdentity {
            return "This saved ChatGPT provider isn't managed by this app's account identity and can't be disconnected or removed here."
        }
        if isChatGPTAccountProvider {
            return "This signs out of the connected ChatGPT account and removes its provider configuration. OpenAI API keys and the token-free registration remain unchanged."
        }
        return "This removes the provider from settings and clears its saved credential. Downloaded local model files remain unchanged."
    }

    private var providerIsInUse: Bool {
        guard let providerID = activeProvider?.id else { return false }
        return model.presets.contains { $0.providerID == providerID || $0.fallbackProviderID == providerID }
    }

    private var canRemoveProvider: Bool {
        canShowRemoveProvider
            && model.canChangeSettings
            && !isRemovingProvider
            && !providerIsInUse
            && !hasUnsupportedChatGPTIdentity
            && !isChatGPTAccountOperationBusy
    }

    private var activeProvider: ProviderConfiguration? {
        let providerID: String?
        switch mode {
        case .add:
            guard let selectedSection, selectedSection != .custom else { return nil }
            providerID = model.configuration.providers.first(where: {
                ModelProviderSection.forProvider($0) == selectedSection
            })?.id
        case .edit(let identifier):
            providerID = identifier
        case .preview(let section):
            providerID = model.configuration.providers.first(where: {
                ModelProviderSection.forProvider($0) == section
            })?.id
        }
        return providerID.flatMap { identifier in
            model.configuration.providers.first { $0.id == identifier }
        }
    }

    private var isCreatingCustomProvider: Bool {
        guard selectedSection == .custom else { return false }
        if case .add = mode { return true }
        return false
    }

    @ViewBuilder
    private func providerSettings(for section: ModelProviderSection) -> some View {
        switch section {
        case .local:
            LocalModelSettingsPane(model: model, providerID: activeProvider?.id)
        case .chatGPTAccount:
            ChatGPTAccountSettingsPane(model: model, providerID: activeProvider?.id)
        case .openAIAPI, .openRouter:
            APIKeyProviderSettingsPane(model: model, section: section, providerID: activeProvider?.id)
        case .custom:
            CustomProviderSettingsPane(
                model: model,
                providerID: activeProvider?.id,
                startsNewProvider: isCreatingCustomProvider,
                allowsProviderSwitching: false,
                showsRemoveProviderAction: false,
                onProviderRemoved: { providerRemovalFeedback = $0 }
            )
        }
    }

    private func removeSavedProvider() {
        guard canRemoveProvider, let provider = activeProvider else { return }
        isRemovingProvider = true
        providerRemovalError = nil
        Task {
            do {
                try await model.deleteProvider(id: provider.id)
                switch provider.kind {
                case .managedLocal:
                    providerRemovalFeedback = "Provider removed. Downloaded local model files were left unchanged."
                case .openAIChatGPT:
                    providerRemovalFeedback = "ChatGPT account signed out and its provider configuration removed. OpenAI API keys and the token-free registration remain unchanged."
                default:
                    providerRemovalFeedback = "Provider and its saved credential were removed."
                }
            } catch {
                let message = AppModel.userMessage(for: error)
                if !model.configuration.providers.contains(where: { $0.id == provider.id }) {
                    providerRemovalFeedback = "Provider removed, but \(message)"
                } else {
                    providerRemovalError = message
                }
            }
            isRemovingProvider = false
        }
    }
}
#endif
