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
    @State private var selectedReasoningEffort: String?
    @State private var reasoningCapabilities: ReasoningEffortCapabilities?
    @State private var didResolveReasoningCapabilities = false
    @State private var reasoningStatus: String?
    @State private var isRefreshingReasoningCapabilities = false
    @State private var reasoningQueryID = UUID()
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

                    if let capabilities = selectedReasoningCapabilitiesForDraft {
                        ReasoningEffortControl(effort: $selectedReasoningEffort, capabilities: capabilities)
                            .disabled(!model.canChangeSettings || isSaving || isRefreshingReasoningCapabilities)
                        if let reasoningStatus {
                            Text(reasoningStatus)
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let reasoningStatus {
                        Text(reasoningStatus)
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
                    .disabled(!model.canChangeSettings || isSaving || isRefreshingReasoningCapabilities || !draft.isValid)
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
        .onChange(of: draft.model) { _, _ in resetReasoningCapabilities() }
        .onChange(of: draft.endpoint) { _, _ in resetReasoningCapabilities() }
        .onChange(of: draft.kind) { _, _ in resetReasoningCapabilities() }
        .task(id: draft.id) { await refreshCredentialStatus(for: draft.id) }
        .task(id: reasoningCapabilityQueryKey) { await refreshReasoningCapabilities() }
    }

    private var credentialStatus: String {
        if model.isPreviewMode { return "Keychain isn't queried in preview mode." }
        if hasSavedCredential { return "A key is saved in Keychain." }
        return "No key is saved for this provider."
    }

    private var providerIsInUse: Bool {
        model.presets.contains { $0.providerID == editingProviderID || $0.fallbackProviderID == editingProviderID }
    }

    private var reasoningCapabilityQueryKey: String {
        "\(draft.id)|\(draft.kind.rawValue)|\(draft.endpoint)|\(draft.model)|\(draft.requiresCredential)|\(hasSavedCredential)|\(isAuthenticatedReasoningDestinationSaved)"
    }

    private var isAuthenticatedReasoningDestinationSaved: Bool {
        guard let provider = draft.provider,
              provider.requiresCredential,
              !(provider.kind == .openRouter && URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false)?.host?.lowercased() == "openrouter.ai")
        else { return true }
        return model.configuration.providers.contains { savedProvider in
            savedProvider.id == provider.id
                && savedProvider.endpoint == provider.endpoint
                && savedProvider.kind == provider.kind
                && savedProvider.requiresCredential == provider.requiresCredential
        }
    }

    private var selectedReasoningCapabilitiesForDraft: ReasoningEffortCapabilities? {
        guard let provider = draft.provider else { return nil }
        if let reasoningCapabilities,
           reasoningCapabilities.applies(to: provider.endpoint, model: provider.model, providerKind: provider.kind)
        {
            return reasoningCapabilities
        }
        guard !didResolveReasoningCapabilities,
              let saved = draft.reasoningEffortCapabilities,
              saved.applies(to: provider.endpoint, model: provider.model, providerKind: provider.kind)
        else { return nil }
        return saved
    }

    private var selectedReasoningEffortForDraft: String? {
        guard let selectedReasoningEffort,
              selectedReasoningCapabilitiesForDraft?.supportedEfforts.contains(selectedReasoningEffort) == true
        else { return nil }
        return selectedReasoningEffort
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
        reasoningCapabilities = nil
        didResolveReasoningCapabilities = false
        reasoningStatus = nil
        selectedReasoningEffort = nil
        guard let provider = providers.first(where: { $0.id == identifier }) else {
            draft = CustomProviderDraft()
            hasSavedCredential = false
            return
        }
        draft = CustomProviderDraft(provider: provider)
        selectedReasoningEffort = provider.reasoningEffort
    }

    private func saveProvider() {
        guard let provider = draft.makeProvider(
            reasoningEffort: selectedReasoningEffortForDraft,
            reasoningEffortCapabilities: selectedReasoningCapabilitiesForDraft
        ) else {
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

    private func resetReasoningCapabilities() {
        reasoningCapabilities = nil
        didResolveReasoningCapabilities = false
        reasoningStatus = nil
    }

    private func refreshReasoningCapabilities() async {
        let queryID = UUID()
        reasoningQueryID = queryID
        reasoningCapabilities = nil
        didResolveReasoningCapabilities = false
        isRefreshingReasoningCapabilities = false
        guard !model.isPreviewMode else {
            reasoningStatus = "Preview doesn't query provider capability metadata."
            return
        }
        guard let provider = draft.provider else {
            reasoningStatus = "Enter a model ID and endpoint to check advertised reasoning effort choices."
            return
        }
        isRefreshingReasoningCapabilities = true
        reasoningStatus = "Checking endpoint-advertised reasoning effort choices…"
        defer {
            if reasoningQueryID == queryID { isRefreshingReasoningCapabilities = false }
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, reasoningQueryID == queryID else { return }
        let requestKey = reasoningCapabilityQueryKey
        do {
            let capabilities = try await model.providerReasoningEffortCapabilities(for: provider)
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningCapabilities = capabilities
            didResolveReasoningCapabilities = true
            if selectedReasoningEffortForDraft == nil { selectedReasoningEffort = nil }
            reasoningStatus = capabilities == nil
                ? "This endpoint doesn't advertise supported reasoning effort choices. The provider default will be used."
                : nil
        } catch let error as ImrseError where error == .missingCredentials {
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningStatus = selectedReasoningCapabilitiesForDraft == nil
                ? "Save an API key to check advertised reasoning effort choices. The provider default will be used."
                : "Save an API key to refresh the advertised choices. Saved choices remain available."
        } catch AppModelProviderModelCatalogError.unsavedAuthenticatedDestination {
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningStatus = "Save this provider before checking its endpoint for advertised reasoning choices. The provider default will be used."
        } catch {
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningStatus = selectedReasoningCapabilitiesForDraft == nil
                ? "Couldn't verify reasoning effort choices. The provider default will be used."
                : "Couldn't refresh the advertised choices. Saved choices remain available."
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
    var reasoningEffort: String?
    var reasoningEffortCapabilities: ReasoningEffortCapabilities?

    init(provider: ProviderConfiguration? = nil) {
        guard let provider else { return }
        id = provider.id
        name = provider.name
        kind = provider.kind
        endpoint = provider.endpoint.absoluteString
        model = provider.model
        requiresCredential = provider.requiresCredential
        reasoningEffort = provider.reasoningEffort
        reasoningEffortCapabilities = provider.reasoningEffortCapabilities
    }

    var provider: ProviderConfiguration? {
        makeProvider(reasoningEffort: reasoningEffort, reasoningEffortCapabilities: reasoningEffortCapabilities)
    }

    func makeProvider(
        reasoningEffort: String? = nil,
        reasoningEffortCapabilities: ReasoningEffortCapabilities? = nil
    ) -> ProviderConfiguration? {
        guard let endpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ProviderConfiguration(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            endpoint: endpoint,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            requiresCredential: requiresCredential,
            reasoningEffort: reasoningEffort,
            reasoningEffortCapabilities: reasoningEffortCapabilities
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
        case .openRouterAccount: "OpenRouter account"
        case .huggingFaceAccount: "Hugging Face account"
        case .githubCopilot: "GitHub Copilot account"
        case .anthropic: "Anthropic"
        case .managedLocal: "Local on this Mac"
        case .compatible: "Compatible endpoint"
        }
    }
}
#endif
