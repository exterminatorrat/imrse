#if os(macOS)
import ImrseCore
import SwiftUI

struct CustomProviderSettingsPane: View {
    @ObservedObject var model: AppModel
    private let initialProviderID: String?
    private let startsNewProvider: Bool
    private let allowsProviderSwitching: Bool
    private let showsRemoveProviderAction: Bool
    private let onProviderRemoved: ((String) -> Void)?
    @State private var editingProviderID = ""
    @State private var draft = CustomProviderDraft()
    @State private var credential = ""
    @State private var hasSavedCredential = false
    @State private var isSaving = false
    @State private var feedback: String?
    @State private var credentialQueryID = UUID()
    @State private var saveSessionID: UUID?

    private var providers: [ProviderConfiguration] {
        model.configuration.providers.filter { [.openAI, .openRouter, .compatible].contains($0.kind) }
    }

    init(
        model: AppModel,
        providerID: String? = nil,
        startsNewProvider: Bool = false,
        allowsProviderSwitching: Bool = true,
        showsRemoveProviderAction: Bool = true,
        onProviderRemoved: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.initialProviderID = providerID
        self.startsNewProvider = startsNewProvider
        self.allowsProviderSwitching = allowsProviderSwitching
        self.showsRemoveProviderAction = showsRemoveProviderAction
        self.onProviderRemoved = onProviderRemoved
        _editingProviderID = State(initialValue: providerID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModelProviderHeader(
                title: "Custom advanced",
                detail: "Requests go to this endpoint; data handling and billing depend on its service.",
                symbol: ModelProviderSection.custom.symbolName
            )

            SettingsSection(
                title: "Endpoint",
                symbol: "server.rack",
                detail: "Existing values stay unchanged until you save."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if allowsProviderSwitching {
                        Picker("Provider", selection: $editingProviderID) {
                            Text("New provider").tag("")
                            ForEach(providers) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                        .disabled(!model.canChangeSettings || isSaving)
                        .onChange(of: editingProviderID) { _, identifier in loadProvider(identifier) }
                    }

                    TextField("Provider name", text: $draft.name)
                        .disabled(!model.canChangeSettings || isSaving)

                    Picker("Provider type", selection: $draft.kind) {
                        ForEach([ProviderKind.compatible, .openAI, .openRouter], id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .disabled(!model.canChangeSettings || isSaving)

                    TextField("Endpoint URL", text: $draft.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canChangeSettings || isSaving)

                    SettingsHint(
                        title: "Connection security",
                        detail: "Use HTTPS for remote endpoints. HTTP is accepted only for loopback.",
                        symbol: "lock.shield"
                    )

                    TextField("Model ID", text: $draft.model)
                        .disabled(!model.canChangeSettings || isSaving)

                    Toggle("Provider requires an API key", isOn: $draft.requiresCredential)
                        .disabled(!model.canChangeSettings || isSaving)
                }
            }

            if draft.requiresCredential || hasSavedCredential {
                SettingsSection(
                    title: "API key",
                    symbol: "key.horizontal",
                    detail: "Keys are stored in Keychain, not in configuration files."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("API key", text: $credential)
                            .disabled(!model.canChangeSettings || isSaving)
                        HStack(spacing: 8) {
                            Text(credentialStatus)
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if hasSavedCredential {
                                ImrseDestructiveButton(title: "Remove key", action: removeCredential)
                                    .disabled(!model.canChangeSettings || isSaving)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                ImrsePrimaryButton(title: isSaving ? "Saving…" : "Save provider", action: saveProvider)
                    .disabled(!model.canChangeSettings || isSaving || !draft.isValid)
                if showsRemoveProviderAction && !editingProviderID.isEmpty {
                    ImrseDestructiveButton(title: "Remove provider", action: removeProvider)
                        .disabled(!model.canChangeSettings || isSaving || providerIsInUse)
                }
            }

            if providerIsInUse {
                Text("A preset uses this provider. Change the preset before removing it.")
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
            }
            if let feedback {
                Text(feedback)
                    .font(.imrseCaption)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(feedback)
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: loadSettings)
        .task(id: draft.id) { await refreshCredentialStatus(for: draft.id) }
    }

    private var credentialStatus: String {
        if model.isPreviewMode { return "Keychain isn't queried in preview mode." }
        if hasSavedCredential { return "A key is saved in Keychain." }
        return "No key is saved for this provider."
    }

    private var providerIsInUse: Bool {
        model.presets.contains { $0.providerID == editingProviderID || $0.fallbackProviderID == editingProviderID }
    }

    private func loadSettings() {
        if startsNewProvider {
            editingProviderID = ""
            loadProvider("")
            return
        }
        if let initialProviderID {
            let identifier = providers.contains(where: { $0.id == initialProviderID }) ? initialProviderID : ""
            editingProviderID = identifier
            loadProvider(identifier)
            return
        }
        let identifier = model.configuration.selectedProviderID.flatMap { selectedID in
            providers.first { $0.id == selectedID }?.id
        } ?? providers.first?.id ?? ""
        editingProviderID = identifier
        loadProvider(identifier)
    }

    private func loadProvider(_ identifier: String) {
        credential = ""
        feedback = nil
        guard let provider = providers.first(where: { $0.id == identifier }) else {
            draft = CustomProviderDraft()
            hasSavedCredential = false
            return
        }
        draft = CustomProviderDraft(provider: provider)
    }

    private func saveProvider() {
        guard let provider = draft.provider else {
            feedback = "Enter a valid endpoint URL, provider name and model ID."
            return
        }
        let sessionID = UUID()
        saveSessionID = sessionID
        let submittedCredential = credential
        isSaving = true
        Task {
            var providerSaved = false
            do {
                try model.saveProvider(provider)
                providerSaved = true
                editingProviderID = provider.id
                if !submittedCredential.isEmpty {
                    try await model.saveCredential(submittedCredential, for: provider.id)
                    credential = ""
                }
                guard saveSessionID == sessionID else { return }
                feedback = submittedCredential.isEmpty
                    ? "Provider saved."
                    : "Provider saved. Credentials stay in Keychain."
            } catch {
                guard saveSessionID == sessionID else { return }
                let message = AppModel.userMessage(for: error)
                feedback = providerSaved ? "Provider saved, but \(message)" : message
            }
            guard saveSessionID == sessionID else { return }
            isSaving = false
            await refreshCredentialStatus(for: provider.id)
        }
    }

    private func removeCredential() {
        guard !editingProviderID.isEmpty else { return }
        let identifier = editingProviderID
        let sessionID = UUID()
        saveSessionID = sessionID
        isSaving = true
        Task {
            do {
                try await model.removeCredential(for: identifier)
                guard saveSessionID == sessionID else { return }
                hasSavedCredential = false
                credential = ""
                feedback = "The Keychain entry was removed."
            } catch {
                guard saveSessionID == sessionID else { return }
                feedback = AppModel.userMessage(for: error)
            }
            guard saveSessionID == sessionID else { return }
            isSaving = false
        }
    }

    private func removeProvider() {
        let identifier = editingProviderID
        guard !identifier.isEmpty else { return }
        let sessionID = UUID()
        saveSessionID = sessionID
        isSaving = true
        Task {
            do {
                try await model.deleteProvider(id: identifier)
                guard saveSessionID == sessionID else { return }
                editingProviderID = ""
                loadProvider("")
                let message = "Provider and its Keychain entry were removed."
                feedback = message
                onProviderRemoved?(message)
            } catch {
                guard saveSessionID == sessionID else { return }
                if !model.configuration.providers.contains(where: { $0.id == identifier }) {
                    editingProviderID = ""
                    loadProvider("")
                    let message = "Provider removed, but \(AppModel.userMessage(for: error))"
                    feedback = message
                    onProviderRemoved?(message)
                } else {
                    feedback = AppModel.userMessage(for: error)
                }
            }
            guard saveSessionID == sessionID else { return }
            isSaving = false
        }
    }

    private func refreshCredentialStatus(for identifier: String) async {
        let queryID = UUID()
        credentialQueryID = queryID
        guard !model.isPreviewMode, providers.contains(where: { $0.id == identifier }) else { return }
        do {
            let saved = try await model.hasCredential(for: identifier)
            guard !Task.isCancelled, credentialQueryID == queryID, draft.id == identifier else { return }
            hasSavedCredential = saved
        } catch {
            guard !Task.isCancelled, credentialQueryID == queryID, draft.id == identifier else { return }
            feedback = AppModel.userMessage(for: error)
        }
    }
}

private struct CustomProviderDraft {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var kind: ProviderKind = .compatible
    var endpoint = ""
    var model = ""
    var requiresCredential = true

    init(provider: ProviderConfiguration? = nil) {
        guard let provider else { return }
        id = provider.id
        name = provider.name
        kind = provider.kind
        endpoint = provider.endpoint.absoluteString
        model = provider.model
        requiresCredential = provider.requiresCredential
    }

    var provider: ProviderConfiguration? {
        guard let endpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ProviderConfiguration(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            endpoint: endpoint,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            requiresCredential: requiresCredential
        )
    }

    var isValid: Bool {
        guard let provider else { return false }
        return !provider.name.isEmpty && !provider.model.isEmpty
    }
}

private extension ProviderKind {
    var displayName: String {
        switch self {
        case .openAI: "OpenAI-compatible"
        case .openAIChatGPT: "OpenAI ChatGPT account"
        case .openRouter: "OpenRouter"
        case .managedLocal: "Local on this Mac"
        case .compatible: "Compatible endpoint"
        }
    }
}
#endif
