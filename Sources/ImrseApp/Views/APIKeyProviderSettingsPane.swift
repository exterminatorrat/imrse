#if os(macOS)
import ImrseCore
import ImrseServices
import SwiftUI

struct APIKeyProviderSettingsPane: View {
    @ObservedObject var model: AppModel
    let section: ModelProviderSection
    private let initialProviderID: String?
    @State private var selectedModelID: String
    @State private var providerID: String
    @State private var credential = ""
    @State private var hasSavedCredential = false
    @State private var isSaving = false
    @State private var feedback: String?
    @State private var credentialQueryID = UUID()
    @State private var operationSessionID: UUID?

    private var kind: ProviderKind { section.kind ?? .compatible }
    private var endpoint: URL { section.endpoint ?? URL(fileURLWithPath: "/") }
    private var choices: [CuratedModelChoice] { CuratedModelCatalog.recommendations(for: kind) }

    private var configuredProvider: ProviderConfiguration? {
        if let initialProviderID {
            return model.configuration.providers.first { $0.id == initialProviderID }
        }
        return model.configuration.providers.first { $0.kind == kind && $0.endpoint == endpoint }
    }

    private var isSelectedDefault: Bool {
        configuredProvider?.id == model.configuration.selectedProviderID
            && configuredProvider?.model == selectedModelID
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
        let recommendation = CuratedModelCatalog.recommendations(for: kind).first?.id ?? ""
        _selectedModelID = State(initialValue: existing?.model ?? recommendation)
        _providerID = State(initialValue: Self.providerID(for: section, existing: existing, configuration: model.configuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModelProviderHeader(
                title: section.title,
                detail: billingDetail,
                symbol: section.symbolName
            )

            CuratedModelChoicesView(choices: choices, selection: $selectedModelID)
                .disabled(!model.canChangeSettings || isSaving || choices.isEmpty)

            if let configuredProvider,
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
                            .disabled(!model.canChangeSettings || isSaving || selectedModelID.isEmpty || (!hasSavedCredential && credential.isEmpty))
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
            if let configuredProvider { providerID = configuredProvider.id }
        }
        .task(id: providerID) { await refreshCredentialStatus(for: providerID) }
    }

    private var billingDetail: String {
        section == .openAIAPI
            ? "Use an OpenAI API key. Requests are billed by OpenAI API usage."
            : "Use an OpenRouter API key. Requests are billed through OpenRouter."
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
            requiresCredential: true
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
