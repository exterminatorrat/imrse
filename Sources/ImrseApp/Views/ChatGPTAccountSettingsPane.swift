#if os(macOS)
import ImrseCore
import ImrseServices
import SwiftUI

struct ChatGPTAccountSettingsPane: View {
    @ObservedObject var model: AppModel
    private let initialProviderID: String?
    @State private var selectedModelID: String
    @State private var feedback: String?
    @State private var showDisconnectConfirmation = false

    private var existingProvider: ProviderConfiguration? {
        let providerID = initialProviderID ?? model.chatGPTProviderID
        return model.configuration.providers.first {
            $0.kind == .openAIChatGPT && $0.id == providerID
        }
    }

    private var choices: [CuratedModelChoice] {
        guard !isUnsupportedAccount else { return [] }
        return model.isPreviewMode
            ? CuratedModelCatalog.recommendations(for: .openAIChatGPT)
            : model.chatGPTRecommendations
    }

    private var isUnsupportedAccount: Bool {
        Self.isUnsupportedProviderIdentity(
            providerID: initialProviderID,
            managedProviderID: model.chatGPTProviderID
        )
    }

    private var isSelectedDefault: Bool {
        !selectedModelID.isEmpty
            && existingProvider?.id == model.configuration.selectedProviderID
            && existingProvider?.model == selectedModelID
    }

    private var accountModelAccessReady: Bool {
        !isUnsupportedAccount
            && model.chatGPTStatus?.isConnected == true
            && model.chatGPTStatus?.canUseChatGPTPlan == true
    }

    private var configuredModelChoice: CuratedModelChoice? {
        guard !model.isPreviewMode,
              accountModelAccessReady,
              !model.isRefreshingChatGPTAccount,
              model.chatGPTIssue == nil,
              let existingProvider,
              !choices.contains(where: { $0.id == existingProvider.model })
        else { return nil }
        let copy = CuratedModelChoicesPresentation.chatGPTAccount.copy(isPreview: false, hasConfiguredModel: true)
        return CuratedModelChoice(
            id: existingProvider.model,
            name: existingProvider.model,
            detail: copy.configuredModelDetail
        )
    }

    private var savedModelStatus: String? {
        guard !model.isPreviewMode,
              let existingProvider,
              !choices.contains(where: { $0.id == existingProvider.model }),
              configuredModelChoice == nil
        else { return nil }
        if model.isRefreshingChatGPTAccount {
            return "Saved model ID \(existingProvider.model) remains configured while the account model list is checked."
        }
        if model.chatGPTIssue != nil {
            return "Saved model ID \(existingProvider.model) remains configured. The model list couldn't be loaded, so its status is unknown."
        }
        return "Saved model ID \(existingProvider.model) remains configured. This connection hasn't returned a model list."
    }

    private var selectableChoiceIDs: [String] {
        choices.map(\.id) + (existingProvider.map { [$0.model] } ?? [])
    }

    init(model: AppModel, providerID: String? = nil) {
        self.model = model
        self.initialProviderID = providerID
        let managedProviderID = model.chatGPTProviderID
        let existing = model.configuration.providers.first {
            $0.kind == .openAIChatGPT && $0.id == (providerID ?? managedProviderID)
        }
        let isUnsupportedAccount = Self.isUnsupportedProviderIdentity(
            providerID: providerID,
            managedProviderID: managedProviderID
        )
        let initialSelection: String
        if isUnsupportedAccount {
            initialSelection = ""
        } else if model.isPreviewMode {
            initialSelection = existing?.model
                ?? CuratedModelCatalog.recommendations(for: .openAIChatGPT).first?.id
                ?? ""
        } else {
            initialSelection = existing?.model ?? ""
        }
        _selectedModelID = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModelProviderHeader(
                title: "OpenAI ChatGPT account",
                detail: model.isPreviewMode
                    ? "Preview only. Example model IDs aren't checked against an account."
                    : "Choose a model ID reported by your ChatGPT account. This provider is separate from OpenAI API-key billing.",
                symbol: ModelProviderSection.chatGPTAccount.symbolName
            )

            if isUnsupportedAccount {
                SettingsHint(
                    title: "Account actions unavailable",
                    detail: "This saved ChatGPT provider isn't managed by this app's account identity. Its status, sign-in, disconnect and model-catalog actions are read-only here.",
                    symbol: "exclamationmark.triangle"
                )
            } else {
                SettingsSection(
                    title: "Account",
                    symbol: "person.crop.circle",
                    detail: "Connection status and model IDs come from your ChatGPT account."
                ) {
                    accountStatus
                }

                if let savedModelStatus {
                    SettingsHint(
                        title: "Saved model",
                        detail: savedModelStatus,
                        symbol: "info.circle"
                    )
                }

                if accountModelAccessReady || model.isPreviewMode {
                    if model.isPreviewMode {
                        CuratedModelChoicesView(
                            choices: choices,
                            selection: $selectedModelID,
                            isPreview: true,
                            presentation: .chatGPTAccount
                        )
                        .disabled(!model.canChangeSettings || choices.isEmpty)
                    } else if model.isRefreshingChatGPTAccount {
                        SettingsHint(
                            title: "Loading account models",
                            detail: "Reading model IDs reported by your ChatGPT account.",
                            symbol: "arrow.clockwise"
                        )
                    } else if model.chatGPTIssue == nil && choices.isEmpty && configuredModelChoice == nil {
                        let copy = CuratedModelChoicesPresentation.chatGPTAccount.copy(
                            isPreview: false,
                            hasConfiguredModel: false
                        )
                        SettingsHint(
                            title: copy.emptyStateTitle,
                            detail: copy.emptyStateDetail,
                            symbol: "info.circle"
                        )
                    } else if model.chatGPTIssue == nil {
                        CuratedModelChoicesView(
                            choices: choices,
                            selection: $selectedModelID,
                            configuredModel: configuredModelChoice,
                            presentation: .chatGPTAccount
                        )
                        .disabled(!model.canChangeSettings || (choices.isEmpty && configuredModelChoice == nil))
                        HStack(spacing: 10) {
                            if isSelectedDefault {
                                SettingsStatusBadge(
                                    title: "Default model",
                                    symbol: "checkmark.circle.fill",
                                    tone: .positive
                                )
                            } else {
                                ImrsePrimaryButton(title: "Use model as default", action: saveSelection)
                                    .disabled(!model.canChangeSettings || selectedModelID.isEmpty)
                            }
                        }
                    }

                    if model.isPreviewMode {
                        SettingsHint(
                            title: "No API billing fallback",
                            detail: "Preview only. Account availability isn't checked and no sign-in is started.",
                            symbol: "info.circle"
                        )
                    }
                }

                if !model.isPreviewMode {
                    SettingsHint(
                        title: "No API billing fallback",
                        detail: "ChatGPT account requests won't switch to OpenAI API-key billing.",
                        symbol: "info.circle"
                    )
                }
            }

            if !isUnsupportedAccount, let feedback {
                Text(feedback)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(feedback)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: isUnsupportedAccount ? [] : selectableChoiceIDs) { _, identifiers in
            guard !isUnsupportedAccount, !identifiers.contains(selectedModelID) else { return }
            selectedModelID = ""
        }
        .confirmationDialog(
            "Disconnect this ChatGPT account?",
            isPresented: Binding(
                get: { showDisconnectConfirmation && !isUnsupportedAccount },
                set: { if !$0 { showDisconnectConfirmation = false } }
            ),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                guard !isUnsupportedAccount else { return }
                model.disconnectChatGPTAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out of the connected ChatGPT account. OpenAI API keys and its token-free registration are unchanged.")
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        if model.isPreviewMode {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(title: "Preview · not connected", symbol: "eye")
                ImrsePrimaryButton(title: "Continue with ChatGPT") {}
                    .disabled(true)
            }
            .accessibilityElement(children: .contain)
        } else if model.isConnectingChatGPT {
                if model.chatGPTStatus?.isConnected == true {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsStatusBadge(title: "Account connected", symbol: "checkmark.circle.fill", tone: .positive)
                        Text(model.chatGPTStatus?.canUseChatGPTPlan == true
                             ? "Loading model IDs from your ChatGPT account…"
                             : "This connection doesn't grant direct model-list access.")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    SettingsStatusBadge(title: "Connecting", symbol: "ellipsis.circle")
                    Text("Continue in your browser to connect ChatGPT.")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    ImrseSecondaryButton(title: "Cancel", action: model.cancelChatGPTSignIn)
                        .disabled(model.isTerminating)
                }
            }
        } else if model.isDisconnectingChatGPT {
            SettingsStatusBadge(title: "Disconnecting", symbol: "ellipsis.circle")
        } else if let status = model.chatGPTStatus, status.isConnected {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(
                    title: status.canUseChatGPTPlan ? "Direct account access ready" : "Direct account access unavailable",
                    symbol: status.canUseChatGPTPlan ? "checkmark.circle.fill" : "exclamationmark.triangle",
                    tone: status.canUseChatGPTPlan ? .positive : .warning
                )
                Text(status.accountLabel.map { "Connected · \($0)" } ?? "Connected to ChatGPT")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityLabel(status.accountLabel.map { "Connected to ChatGPT, \($0)" } ?? "Connected to ChatGPT")
                if let issue = model.chatGPTIssue {
                    Text(issue)
                        .font(.imrseCaption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(issue)
                    ImrseSecondaryButton(title: "Retry") {
                        Task { await model.refreshChatGPTAccount() }
                    }
                    .disabled(!model.canChangeSettings || model.isRefreshingChatGPTAccount)
                } else if model.isRefreshingChatGPTAccount {
                    Text("Checking model IDs from your ChatGPT account…")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if status.canUseChatGPTPlan {
                        Text("Model IDs are read from your account response.")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("This connection can't list account models. Disconnect and reconnect to request direct access.")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ImrseDestructiveButton(title: "Disconnect") {
                        guard !isUnsupportedAccount else { return }
                        showDisconnectConfirmation = true
                    }
                    .disabled(!model.canChangeSettings)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(
                    title: model.chatGPTStatus == nil ? "Checking account" : "Not connected",
                    symbol: model.chatGPTStatus == nil ? "ellipsis.circle" : "person.crop.circle"
                )
                if let issue = model.chatGPTIssue {
                    Text(issue)
                        .font(.imrseCaption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(issue)
                    ImrseSecondaryButton(title: "Retry") {
                        Task { await model.refreshChatGPTAccount() }
                    }
                    .disabled(!model.canChangeSettings || model.isRefreshingChatGPTAccount)
                } else if model.chatGPTStatus == nil {
                    Text("Checking account status…")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                }
                if model.chatGPTIssue == nil {
                    ImrsePrimaryButton(title: "Continue with ChatGPT", action: model.connectChatGPTAccount)
                        .disabled(!model.canChangeSettings)
                }
            }
        }
    }

    private func saveSelection() {
        let selectedModelIsReported = model.chatGPTModels.contains { $0.slug == selectedModelID }
        let selectedModelIsAlreadyConfigured = existingProvider?.model == selectedModelID
        guard accountModelAccessReady, model.canChangeSettings,
              !selectedModelID.isEmpty,
              selectedModelIsReported || selectedModelIsAlreadyConfigured
        else { return }
        let provider = ProviderConfiguration(
            id: existingProvider?.id ?? model.chatGPTProviderID,
            name: existingProvider?.name ?? "OpenAI ChatGPT account",
            kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: selectedModelID,
            requiresCredential: true
        )
        do {
            try model.saveProvider(provider)
            feedback = "Default ChatGPT model saved."
        } catch {
            feedback = AppModel.userMessage(for: error)
        }
    }

    static func isUnsupportedProviderIdentity(providerID: String?, managedProviderID: String) -> Bool {
        guard let providerID else { return false }
        return providerID != managedProviderID
    }
}
#endif
