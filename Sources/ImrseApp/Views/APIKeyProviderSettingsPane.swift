#if os(macOS)
import ImrseCore
import ImrseServices
import SwiftUI

struct APIKeyProviderSettingsPane: View {
    @ObservedObject var model: AppModel
    let section: ModelProviderSection
    private let initialProviderID: String?
    @State private var selectedModelID: String
    @State private var selectedReasoningEffort: String?
    @State private var reasoningCapabilities: ReasoningEffortCapabilities?
    @State private var didResolveReasoningCapabilities = false
    @State private var reasoningStatus: String?
    @State private var isRefreshingReasoningCapabilities = false
    @State private var reasoningQueryID = UUID()
    @State private var providerID: String
    @State private var credential = ""
    @State private var hasSavedCredential = false
    @State private var isSaving = false
    @State private var feedback: String?
    @State private var credentialQueryID = UUID()
    @State private var operationSessionID: UUID?

    private var kind: ProviderKind { section.kind ?? .compatible }
    private var endpoint: URL { section.endpoint ?? URL(fileURLWithPath: "/") }
    private var choices: [CuratedModelChoice] {
        section.usesExplicitModelID ? [] : CuratedModelCatalog.recommendations(for: kind)
    }

    private var configuredProvider: ProviderConfiguration? {
        if let initialProviderID {
            return model.configuration.providers.first { $0.id == initialProviderID }
        }
        return model.configuration.providers.first { $0.kind == kind && $0.endpoint == endpoint }
    }

    private var isSelectedDefault: Bool {
        configuredProvider?.id == model.configuration.selectedProviderID
            && configuredProvider?.model == selectedModelID
            && configuredProvider?.reasoningEffort == selectedReasoningEffortForProvider
            && configuredProvider?.reasoningEffortCapabilities == selectedReasoningCapabilitiesForProvider
    }

    init(model: AppModel, section: ModelProviderSection, providerID: String? = nil) {
        self.model = model
        self.section = section
        let kind = section.kind ?? .compatible
        let endpoint = section.endpoint ?? URL(fileURLWithPath: "/")
        let existing = providerID.flatMap { identifier in
            model.configuration.providers.first { $0.id == identifier && $0.kind == kind && $0.endpoint == endpoint }
        } ?? (providerID == nil ? model.configuration.providers.first { $0.kind == kind && $0.endpoint == endpoint } : nil)
        self.initialProviderID = existing?.id
        let recommendation = section.usesExplicitModelID ? "" : CuratedModelCatalog.recommendations(for: kind).first?.id ?? ""
        _selectedModelID = State(initialValue: existing?.model ?? recommendation)
        _selectedReasoningEffort = State(initialValue: existing?.reasoningEffort)
        _providerID = State(initialValue: Self.providerID(for: section, existing: existing, configuration: model.configuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModelProviderHeader(
                title: section.title,
                detail: billingDetail,
                symbol: section.symbolName
            )

            if section.usesExplicitModelID {
                SettingsSection(
                    title: "Model ID",
                    symbol: "number",
                    detail: "Enter the exact model ID listed by the provider."
                ) {
                    TextField("Model ID", text: $selectedModelID)
                        .disabled(!model.canChangeSettings || isSaving)
                }
            } else {
                CuratedModelChoicesView(choices: choices, selection: $selectedModelID)
                    .disabled(!model.canChangeSettings || isSaving || choices.isEmpty)
            }

            if let capabilities = selectedReasoningCapabilitiesForProvider {
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

            if !section.usesExplicitModelID,
               let configuredProvider,
               !choices.contains(where: { $0.id == configuredProvider.model }) {
                Text("Your saved model ID is \(configuredProvider.model). Change it under Custom advanced; it will stay unchanged unless you choose a model here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(
                title: "API key",
                symbol: "key.horizontal",
                detail: "The key stays in Keychain. \(billingDetail)"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("Paste API key", text: $credential)
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
                    Text("Model selection never downloads a model or changes providers.")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isSelectedDefault && credential.isEmpty {
                        SettingsStatusBadge(
                            title: "Default model",
                            symbol: "checkmark.circle.fill",
                            tone: .positive
                        )
                    } else {
                        ImrsePrimaryButton(title: primaryActionTitle, action: saveSelection)
                            .disabled(!model.canChangeSettings || isSaving || isRefreshingReasoningCapabilities || selectedModelID.isEmpty || (!hasSavedCredential && credential.isEmpty))
                    }

                    if !hasSavedCredential && credential.isEmpty {
                        Text("Enter an API key above to save this provider as the default.")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let feedback {
                Text(feedback)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(feedback)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: model.configuration.providers) { _, _ in
            if let configuredProvider {
                providerID = configuredProvider.id
                Task { await refreshCredentialStatus(for: configuredProvider.id) }
            }
        }
        .onChange(of: selectedModelID) { _, _ in
            selectedReasoningEffort = nil
            reasoningCapabilities = nil
            didResolveReasoningCapabilities = false
            reasoningStatus = nil
        }
        .task(id: providerID) { await refreshCredentialStatus(for: providerID) }
        .task(id: reasoningCapabilityQueryKey) { await refreshReasoningCapabilities() }
    }

    private var billingDetail: String {
        switch section {
        case .openAIAPI: "Use an OpenAI API key. Requests are billed by OpenAI API usage."
        case .openRouter: "Use an OpenRouter API key. Requests are billed through OpenRouter."
        default: section.listDescription
        }
    }

    private var primaryActionTitle: String {
        if isSaving { return "Saving…" }
        return credential.isEmpty ? "Use model as default" : "Save key & use model"
    }

    private var credentialStatus: String {
        if model.isPreviewMode { return "Keychain isn't queried in preview mode." }
        if hasSavedCredential { return "A key is saved in Keychain." }
        return "No key is saved for this provider."
    }

    private var reasoningCapabilityQueryKey: String {
        "\(providerID)|\(kind.rawValue)|\(endpoint.absoluteString)|\(selectedModelID)|\(hasSavedCredential)|\(isAuthenticatedReasoningDestinationSaved)"
    }

    private var isAuthenticatedReasoningDestinationSaved: Bool {
        if kind == .openRouter,
           URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.host?.lowercased() == "openrouter.ai"
        {
            return true
        }
        guard let provider = configuredProvider else { return false }
        return provider.id == providerID
            && provider.endpoint == endpoint
            && provider.kind == kind
            && provider.requiresCredential
    }

    private var selectedReasoningCapabilitiesForProvider: ReasoningEffortCapabilities? {
        if let reasoningCapabilities,
           reasoningCapabilities.applies(to: endpoint, model: selectedModelID, providerKind: kind)
        {
            return reasoningCapabilities
        }
        guard !didResolveReasoningCapabilities,
              let saved = configuredProvider?.reasoningEffortCapabilities,
              saved.applies(to: endpoint, model: selectedModelID, providerKind: kind)
        else { return nil }
        return saved
    }

    private var selectedReasoningEffortForProvider: String? {
        guard let selectedReasoningEffort,
              selectedReasoningCapabilitiesForProvider?.supportedEfforts.contains(selectedReasoningEffort) == true
        else { return nil }
        return selectedReasoningEffort
    }

    private func saveSelection() {
        guard model.canChangeSettings,
              !selectedModelID.isEmpty,
              hasSavedCredential || !credential.isEmpty
        else { return }
        let provider = ProviderConfiguration(
            id: configuredProvider?.id ?? providerID,
            name: configuredProvider?.name ?? section.defaultProviderName,
            kind: kind,
            endpoint: endpoint,
            model: selectedModelID,
            requiresCredential: true,
            reasoningEffort: selectedReasoningEffortForProvider,
            reasoningEffortCapabilities: selectedReasoningCapabilitiesForProvider
        )
        let submittedCredential = credential
        let sessionID = UUID()
        operationSessionID = sessionID
        isSaving = true
        feedback = nil
        Task {
            var providerSaved = false
            do {
                try model.saveProvider(provider)
                providerSaved = true
                if !submittedCredential.isEmpty {
                    try await model.saveCredential(submittedCredential, for: provider.id)
                    credential = ""
                }
                guard operationSessionID == sessionID else { return }
                feedback = submittedCredential.isEmpty
                    ? "Default model saved."
                    : "Default model saved. The key stays in Keychain."
            } catch {
                guard operationSessionID == sessionID else { return }
                let message = AppModel.userMessage(for: error)
                feedback = providerSaved ? "Model saved, but \(message)" : message
            }
            guard operationSessionID == sessionID else { return }
            isSaving = false
            await refreshCredentialStatus(for: provider.id)
        }
    }

    private func removeCredential() {
        guard let providerID = configuredProvider?.id ?? (hasSavedCredential ? self.providerID : nil) else { return }
        let sessionID = UUID()
        operationSessionID = sessionID
        isSaving = true
        Task {
            do {
                try await model.removeCredential(for: providerID)
                guard operationSessionID == sessionID else { return }
                hasSavedCredential = false
                credential = ""
                feedback = "The Keychain entry was removed."
            } catch {
                guard operationSessionID == sessionID else { return }
                feedback = AppModel.userMessage(for: error)
            }
            guard operationSessionID == sessionID else { return }
            isSaving = false
        }
    }

    private func refreshCredentialStatus(for identifier: String) async {
        let queryID = UUID()
        credentialQueryID = queryID
        guard !model.isPreviewMode, configuredProvider?.id == identifier else { return }
        do {
            let saved = try await model.hasCredential(for: identifier)
            guard !Task.isCancelled, credentialQueryID == queryID, providerID == identifier else { return }
            hasSavedCredential = saved
        } catch {
            guard !Task.isCancelled, credentialQueryID == queryID, providerID == identifier else { return }
            feedback = AppModel.userMessage(for: error)
        }
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
        guard !selectedModelID.isEmpty else {
            reasoningStatus = "Choose a model to check for advertised reasoning effort choices."
            return
        }
        isRefreshingReasoningCapabilities = true
        reasoningStatus = "Checking endpoint-advertised reasoning effort choices…"
        defer {
            if reasoningQueryID == queryID { isRefreshingReasoningCapabilities = false }
        }
        let requestKey = reasoningCapabilityQueryKey
        let provider = ProviderConfiguration(
            id: configuredProvider?.id ?? providerID,
            name: configuredProvider?.name ?? section.defaultProviderName,
            kind: kind,
            endpoint: endpoint,
            model: selectedModelID,
            requiresCredential: true
        )
        do {
            let capabilities = try await model.providerReasoningEffortCapabilities(for: provider)
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningCapabilities = capabilities
            didResolveReasoningCapabilities = true
            if selectedReasoningEffortForProvider == nil { selectedReasoningEffort = nil }
            reasoningStatus = capabilities == nil
                ? "This endpoint doesn't advertise supported reasoning effort choices. The provider default will be used."
                : nil
        } catch let error as ImrseError where error == .missingCredentials {
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningStatus = selectedReasoningCapabilitiesForProvider == nil
                ? "Save an API key to check advertised reasoning effort choices. The provider default will be used."
                : "Save an API key to refresh the advertised choices. Saved choices remain available."
        } catch AppModelProviderModelCatalogError.unsavedAuthenticatedDestination {
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningStatus = "Save this provider before checking its endpoint for advertised reasoning choices. The provider default will be used."
        } catch {
            guard !Task.isCancelled, reasoningQueryID == queryID, reasoningCapabilityQueryKey == requestKey else { return }
            reasoningStatus = selectedReasoningCapabilitiesForProvider == nil
                ? "Couldn't verify reasoning effort choices. The provider default will be used."
                : "Couldn't refresh the advertised choices. Saved choices remain available."
        }
    }

    private static func providerID(
        for section: ModelProviderSection,
        existing: ProviderConfiguration?,
        configuration: AppConfiguration
    ) -> String {
        if let existing { return existing.id }
        let candidate = "imrse-\(section.rawValue)"
        return AppModel.uniqueProviderID(candidate: candidate, existingProviders: configuration.providers)
    }
}
#endif
