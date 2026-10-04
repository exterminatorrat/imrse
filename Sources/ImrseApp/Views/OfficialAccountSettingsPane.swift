#if os(macOS)
import ImrseCore
import ImrseServices
import SwiftUI

struct OfficialAccountSettingsPane: View {
    @ObservedObject var model: AppModel
    let section: ModelProviderSection
    @State private var providerID: String
    @State private var publicClientID: String
    @State private var selectedModelID: String
    @State private var feedback: String?
    @State private var showDisconnectConfirmation = false

    private var kind: ProviderKind { section.kind ?? .compatible }
    private var endpoint: URL { section.endpoint ?? URL(fileURLWithPath: "/") }
    private var existingProvider: ProviderConfiguration? {
        model.configuration.providers.first { $0.id == providerID && $0.kind == kind }
    }
    private var connectionStatus: OfficialAccountConnectionStatus? {
        guard let existingProvider else { return nil }
        return model.officialAccountStatus(for: existingProvider)
    }
    private var availableModels: [OfficialAccountModel] {
        guard let existingProvider else { return [] }
        return model.officialAccountModels(for: existingProvider)
    }
    private var accountIssue: String? {
        model.officialAccountIssue(for: existingProvider ?? providerConfiguration())
    }
    private var requiresPublicClientID: Bool {
        kind == .huggingFaceAccount || kind == .githubCopilot
    }
    private var isConnecting: Bool { model.isConnectingOfficialAccount(for: providerID) }
    private var isDisconnecting: Bool { model.isDisconnectingOfficialAccount(for: providerID) }
    private var isRefreshing: Bool { model.officialAccountRefreshingProviderID == providerID }
    private var isConnected: Bool { connectionStatus?.isConnected == true }
    private var modelChoices: [OfficialAccountModel] {
        guard let existingProvider,
              existingProvider.model != AppModel.unselectedOfficialAccountModelID,
              !availableModels.contains(where: { $0.id == existingProvider.model })
        else { return availableModels }
        return [OfficialAccountModel(id: existingProvider.model, displayName: existingProvider.model)] + availableModels
    }
    private var isSelectedDefault: Bool {
        guard !selectedModelID.isEmpty,
              let existingProvider
        else { return false }
        return existingProvider.id == model.configuration.selectedProviderID
            && existingProvider.model == selectedModelID
    }
    private var canConnect: Bool {
        model.canChangeSettings
            && !isConnecting
            && !isDisconnecting
            && !isRefreshing
            && (!requiresPublicClientID || !trimmedPublicClientID.isEmpty)
    }
    private var trimmedPublicClientID: String {
        publicClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(model: AppModel, section: ModelProviderSection, providerID: String? = nil) {
        self.model = model
        self.section = section
        let kind = section.kind ?? .compatible
        let endpoint = section.endpoint ?? URL(fileURLWithPath: "/")
        let existing = providerID.flatMap { identifier in
            model.configuration.providers.first { $0.id == identifier && $0.kind == kind }
        } ?? (providerID == nil ? model.configuration.providers.first { $0.kind == kind && $0.endpoint == endpoint } : nil)
        let identifier = existing?.id ?? providerID ?? AppModel.uniqueProviderID(
            candidate: "imrse-\(section.rawValue)",
            existingProviders: model.configuration.providers
        )
        self._providerID = State(initialValue: identifier)
        self._publicClientID = State(initialValue: existing?.oauthClientID ?? "")
        self._selectedModelID = State(initialValue: existing?.model == AppModel.unselectedOfficialAccountModelID ? "" : existing?.model ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModelProviderHeader(
                title: section.title,
                detail: section.listDescription,
                symbol: section.symbolName
            )

            if requiresPublicClientID {
                SettingsSection(
                    title: "Public client ID",
                    symbol: "person.badge.key",
                    detail: "Enter the public client ID required for this provider account. imrse stores this ID in settings and never stores a client secret."
                ) {
                    TextField("Public client ID", text: $publicClientID)
                        .disabled(!model.canChangeSettings || isConnecting || isConnected || isDisconnecting || isRefreshing)
                }
            }

            SettingsSection(
                title: "Account",
                symbol: "person.crop.circle",
                detail: "Account authentication is separate from API keys. Remote alternatives must be selected directly; this account never silently switches remote billing."
            ) {
                accountStatus
            }

            if kind == .githubCopilot && !model.isPreviewMode && !model.copilotRuntimeIsAvailable {
                SettingsHint(
                    title: "Copilot runtime required",
                    detail: "No executable was found in the standard Copilot CLI locations. Install an official runtime separately; imrse never downloads it or reuses its cached login.",
                    symbol: "exclamationmark.triangle"
                )
            }

            if isConnected || model.isPreviewMode {
                modelSelection
            }

            if !model.isPreviewMode {
                SettingsHint(
                    title: "Account credentials stay separate",
                    detail: "This account's requests use its OAuth session. An API provider is used only when selected directly or configured as a preset fallback.",
                    symbol: "info.circle"
                )
            }

            if let feedback {
                Text(feedback)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(feedback)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: model.configuration.providers) { _, providers in
            if let provider = providers.first(where: { $0.id == providerID && $0.kind == kind }) {
                publicClientID = provider.oauthClientID ?? ""
                if provider.model != AppModel.unselectedOfficialAccountModelID,
                   selectedModelID.isEmpty
                {
                    selectedModelID = provider.model
                }
            }
        }
        .onChange(of: availableModels) { _, models in
            guard selectedModelID.isEmpty,
                  let first = models.first
            else { return }
            selectedModelID = first.id
        }
        .task(id: providerID) {
            guard let existingProvider else { return }
            model.refreshOfficialAccount(for: existingProvider)
        }
        .onDisappear {
            model.cancelOfficialAccountSignIn(for: providerID)
            model.cancelOfficialAccountStatusRefresh(for: providerID)
        }
        .confirmationDialog(
            "Disconnect \(section.title)?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                model.disconnectOfficialAccount(for: providerID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the account session from Keychain. Your provider registration and unrelated API keys are unchanged.")
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        if model.isPreviewMode {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(title: "Preview · not connected", symbol: "eye")
                ImrsePrimaryButton(title: "Connect \(section.title)") {}
                    .disabled(true)
                Text("Preview does not check Keychain, open a browser, or contact a provider.")
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
            }
        } else if isConnecting {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(title: "Connecting", symbol: "ellipsis.circle")
                if let code = model.officialAccountDeviceCode,
                   model.officialAccountSigningInProviderID == providerID,
                   let verificationURL = model.officialAccountDeviceVerificationURL
                {
                    Text("Enter this code at \(verificationURL.absoluteString): \(code)")
                        .font(.imrseCaption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let expiresAt = model.officialAccountDeviceCodeExpiresAt {
                        Text("Code expires at \(expiresAt.formatted(date: .omitted, time: .shortened)).")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Continue in the browser to connect your account.")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                }
                ImrseSecondaryButton(title: "Cancel") {
                    model.cancelOfficialAccountSignIn(for: providerID)
                }
                .disabled(model.isTerminating)
            }
        } else if isDisconnecting {
            SettingsStatusBadge(title: "Disconnecting", symbol: "ellipsis.circle")
        } else if let connectionStatus, connectionStatus.isConnected {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(title: "Account connected", symbol: "checkmark.circle.fill", tone: .positive)
                Text(connectionStatus.accountLabel.map { "Connected · \($0)" } ?? "Connected")
                    .font(.system(size: 13, weight: .medium))
                if let accountIssue {
                    Text(accountIssue)
                        .font(.imrseCaption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(accountIssue)
                    ImrseSecondaryButton(title: "Retry") {
                        model.refreshOfficialAccount(for: existingProvider ?? providerConfiguration())
                    }
                    .disabled(!model.canChangeSettings || isRefreshing)
                } else if isRefreshing {
                    Text("Checking account models…")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer(minLength: 8)
                    ImrseDestructiveButton(title: "Disconnect") { showDisconnectConfirmation = true }
                        .disabled(!model.canChangeSettings || isConnecting || isDisconnecting)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusBadge(
                    title: isRefreshing ? "Checking account" : "Not connected",
                    symbol: isRefreshing ? "ellipsis.circle" : "person.crop.circle"
                )
                if let accountIssue {
                    Text(accountIssue)
                        .font(.imrseCaption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(accountIssue)
                    ImrseSecondaryButton(title: "Retry") {
                        model.refreshOfficialAccount(for: existingProvider ?? providerConfiguration())
                    }
                    .disabled(!model.canChangeSettings || isRefreshing)
                }
                ImrsePrimaryButton(title: "Connect \(section.title)") {
                    model.connectOfficialAccount(providerConfiguration())
                }
                .disabled(!canConnect)
            }
        }
    }

    private var modelSelection: some View {
        SettingsSection(
            title: "Model ID",
            symbol: "number",
            detail: kind == .githubCopilot
                ? "Enter a model ID supported by your Copilot plan; the runtime doesn't publish an account model list."
                : "Choose a model reported by your account or enter its exact model ID."
        ) {
            if model.isPreviewMode {
                TextField("Model ID", text: $selectedModelID)
                    .disabled(true)
                SettingsHint(
                    title: "Preview only",
                    detail: "Example values aren't checked against an account.",
                    symbol: "info.circle"
                )
            } else {
                if kind != .githubCopilot, !modelChoices.isEmpty {
                    Picker("Available account models", selection: $selectedModelID) {
                        Text("Choose a model…").tag("")
                        ForEach(modelChoices) { availableModel in
                            Text(availableModel.displayName).tag(availableModel.id)
                        }
                    }
                    .pickerStyle(.menu)
                } else if kind != .githubCopilot, availableModels.isEmpty {
                    SettingsHint(
                        title: "No account model IDs returned",
                        detail: "Enter the exact model ID published by this provider.",
                        symbol: "info.circle"
                    )
                }

                TextField("Exact model ID", text: $selectedModelID)
                    .disabled(!model.canChangeSettings || !isConnected || isConnecting || isDisconnecting || isRefreshing)

                if isSelectedDefault {
                    SettingsStatusBadge(title: "Default model", symbol: "checkmark.circle.fill", tone: .positive)
                } else {
                    ImrsePrimaryButton(title: "Save model as default", action: saveModel)
                        .disabled(!model.canChangeSettings || !isConnected || isRefreshing || selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func providerConfiguration(modelID: String? = nil) -> ProviderConfiguration {
        let selectedModel = (modelID ?? selectedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = requiresPublicClientID ? trimmedPublicClientID : ""
        return ProviderConfiguration(
            id: providerID,
            name: existingProvider?.name ?? section.defaultProviderName,
            kind: kind,
            endpoint: endpoint,
            model: selectedModel.isEmpty
                ? existingProvider?.model ?? AppModel.unselectedOfficialAccountModelID
                : selectedModel,
            requiresCredential: true,
            oauthClientID: clientID.isEmpty ? nil : clientID
        )
    }

    private func saveModel() {
        let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.canChangeSettings, isConnected, !modelID.isEmpty else { return }
        do {
            try model.saveProvider(providerConfiguration(modelID: modelID))
            feedback = "Default \(section.title) model saved."
        } catch {
            feedback = AppModel.userMessage(for: error)
        }
    }
}
#endif
