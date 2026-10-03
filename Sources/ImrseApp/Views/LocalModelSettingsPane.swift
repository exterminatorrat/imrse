#if os(macOS)
import Foundation
import ImrseCore
import ImrseLocal
import SwiftUI

struct LocalModelSettingsPane: View {
    @ObservedObject var model: AppModel
    private let initialProviderID: String?
    @State private var selectedModelID: String
    @State private var modelPendingRemoval: ManagedLocalModelDescriptor?
    @State private var feedback: String?

    private var descriptors: [ManagedLocalModelDescriptor] { ManagedLocalModelCatalog.models }

    private var selectedSnapshot: ManagedLocalModelSnapshot? {
        model.managedLocalModelSnapshots.first { $0.descriptor.id == selectedModelID }
    }

    private var configuredProvider: ProviderConfiguration? {
        guard let providerID = initialProviderID ?? model.configuration.selectedProviderID else { return nil }
        return model.configuration.providers.first { $0.id == providerID && $0.kind == .managedLocal }
    }

    private var selectedModelIsInstalled: Bool {
        guard let selectedSnapshot else { return false }
        if case .installed = selectedSnapshot.state { return true }
        return false
    }

    private var isSelectedDefault: Bool {
        Self.isDefaultProvider(
            selectedProviderID: model.configuration.selectedProviderID,
            configuredProvider: configuredProvider,
            selectedModelID: selectedModelID
        )
    }

    private var runtimeIsAvailable: Bool {
        ManagedLocalModelCatalog.runtimeAvailability == .available
    }

    init(model: AppModel, providerID: String? = nil) {
        self.model = model
        self.initialProviderID = providerID
        let configuredModelID = providerID.flatMap { identifier in
            model.configuration.providers.first(where: { $0.id == identifier && $0.kind == .managedLocal })?.model
        } ?? (providerID == nil ? model.configuration.selectedProviderID.flatMap { selectedProviderID in
            model.configuration.providers.first(where: { $0.id == selectedProviderID && $0.kind == .managedLocal })?.model
        } : nil)
        let firstInstalled = model.managedLocalModelSnapshots.first {
            if case .installed = $0.state { return true }
            return false
        }?.descriptor.id
        let firstModel = ManagedLocalModelCatalog.models.first?.id ?? ""
        _selectedModelID = State(initialValue: configuredModelID ?? firstInstalled ?? firstModel)
    }

    static func isDefaultProvider(
        selectedProviderID: String?,
        configuredProvider: ProviderConfiguration?,
        selectedModelID: String
    ) -> Bool {
        guard let selectedProviderID, let configuredProvider else { return false }
        return configuredProvider.id == selectedProviderID && configuredProvider.model == selectedModelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModelProviderHeader(
                title: "Local on this Mac",
                detail: "Inference stays on this Mac. Choose Download to install a model; selecting one never downloads it.",
                symbol: ModelProviderSection.local.symbolName
            )

            if model.isPreviewMode {
                Text("Preview only. Installed state isn't queried; model actions are disabled.")
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
            }
            if let issue = model.managedLocalModelIssue {
                Text(issue)
                    .font(.imrseCaption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(issue)
            }

            if !runtimeIsAvailable {
                SettingsHint(
                    title: "Local inference unavailable",
                    detail: "Managed local inference requires Apple silicon.",
                    symbol: "exclamationmark.triangle"
                )
            } else if descriptors.isEmpty {
                SettingsHint(
                    title: "No models available",
                    detail: "No managed models are available for this Mac right now.",
                    symbol: "info.circle"
                )
            } else {
                SettingsSection(
                    title: "Default model",
                    symbol: "checkmark.circle",
                    detail: "Choose an installed model to make it the default."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Model", selection: $selectedModelID) {
                            ForEach(descriptors) { descriptor in
                                Text(descriptor.title).tag(descriptor.id)
                            }
                        }
                        .disabled(!model.canChangeSettings || descriptors.isEmpty)

                        if configuredProvider?.model == selectedModelID,
                           !descriptors.contains(where: { $0.id == selectedModelID }) {
                            Text("The saved model ID \(selectedModelID) isn't in the managed model catalog. It remains unchanged.")
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let selectedSnapshot, case .installed = selectedSnapshot.state, !isSelectedDefault {
                            ImrsePrimaryButton(title: "Use selected model as default", action: selectModelAsDefault)
                                .disabled(!model.canChangeSettings)
                        } else if selectedSnapshot == nil && !model.isPreviewMode {
                            Text("Checking installed models…")
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                        } else if isSelectedDefault {
                            Text(selectedModelIsInstalled
                                ? "This local model is the default."
                                : "This model is the saved default, but it isn't downloaded.")
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Download a model before making it the default. Choosing it here never downloads it.")
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let feedback {
                            Text(feedback)
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsSection(
                    title: "Available models",
                    symbol: "cpu",
                    detail: "Downloads are opt-in; choosing a model above never installs it."
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
                            ManagedModelSettingsRow(
                                descriptor: descriptor,
                                snapshot: model.managedLocalModelSnapshots.first { $0.descriptor.id == descriptor.id },
                                progress: model.managedLocalModelProgress?.modelID == descriptor.id ? model.managedLocalModelProgress : nil,
                                isDownloading: model.managedLocalModelDownloadID == descriptor.id,
                                isTerminating: model.isTerminating,
                                isPreview: model.isPreviewMode,
                                isDefault: isDefaultModel(descriptor.id),
                                isInUse: model.managedLocalModelIsInUse(descriptor.id),
                                isEnabled: model.canChangeSettings && !model.isChangingManagedLocalModel,
                                onDownload: { model.downloadManagedModel(descriptor.id) },
                                onRepair: { model.repairManagedModel(descriptor.id) },
                                onCancel: { model.cancelManagedModelDownload(descriptor.id) },
                                onRemove: { modelPendingRemoval = descriptor }
                            )
                            if index != descriptors.count - 1 {
                                ImrseDivider()
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .onChange(of: model.managedLocalModelSnapshots.map(\.descriptor.id)) { _, identifiers in
            if selectedModelID.isEmpty {
                selectedModelID = identifiers.first ?? descriptors.first?.id ?? ""
            }
        }
        .confirmationDialog(
            "Remove \(modelPendingRemoval?.title ?? "local model")?",
            isPresented: Binding(
                get: { modelPendingRemoval != nil },
                set: { if !$0 { modelPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let descriptor = modelPendingRemoval {
                Button("Remove model", role: .destructive) {
                    model.removeManagedModel(descriptor.id)
                    modelPendingRemoval = nil
                }
                .disabled(!model.canChangeSettings || model.isChangingManagedLocalModel || model.managedLocalModelIsInUse(descriptor.id))
            }
            Button("Cancel", role: .cancel) { modelPendingRemoval = nil }
        } message: {
            Text("The installed model files will be removed from imrse.")
        }
    }

    private func isDefaultModel(_ identifier: String) -> Bool {
        guard let providerID = model.configuration.selectedProviderID,
              let provider = model.configuration.providers.first(where: { $0.id == providerID })
        else { return false }
        return provider.kind == .managedLocal && provider.model == identifier
    }

    private func selectModelAsDefault() {
        guard selectedModelIsInstalled, runtimeIsAvailable else { return }
        let existing = initialProviderID.flatMap { identifier in
            model.configuration.providers.first { $0.id == identifier && $0.kind == .managedLocal }
        } ?? (initialProviderID == nil ? model.configuration.providers.first { $0.kind == .managedLocal } : nil)
        let provider = ProviderConfiguration(
            id: existing?.id ?? AppModel.uniqueProviderID(
                candidate: "imrse-local-model",
                existingProviders: model.configuration.providers
            ),
            name: existing?.name ?? "Local model",
            kind: .managedLocal,
            endpoint: URL(string: "imrse-local://models")!,
            model: selectedModelID,
            requiresCredential: false
        )
        do {
            try model.saveProvider(provider)
            feedback = "Local model saved as the default."
        } catch {
            feedback = AppModel.userMessage(for: error)
        }
    }
}

private struct ManagedModelSettingsRow: View {
    @State private var showsModelDetails = false

    let descriptor: ManagedLocalModelDescriptor
    let snapshot: ManagedLocalModelSnapshot?
    let progress: ManagedLocalModelProgress?
    let isDownloading: Bool
    let isTerminating: Bool
    let isPreview: Bool
    let isDefault: Bool
    let isInUse: Bool
    let isEnabled: Bool
    let onDownload: () -> Void
    let onRepair: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    private var snapshotDownloadBytes: Int64? {
        guard let snapshot, case .downloading(let receivedBytes) = snapshot.state else { return nil }
        return receivedBytes
    }

    private var downloadIsActive: Bool {
        isDownloading || snapshotDownloadBytes != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.title)
                        .font(.imrseBodyStrong)
                        .foregroundStyle(.primary)
                    Text(descriptor.detail)
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingsStatusBadge(
                    title: stateLabel,
                    symbol: stateSymbol,
                    tone: stateTone
                )
            }

            if downloadIsActive {
                let receivedBytes = progress?.completedBytes ?? snapshotDownloadBytes ?? 0
                let totalBytes = progress?.totalBytes ?? descriptor.downloadBytes
                ProgressView(value: min(Double(receivedBytes), Double(totalBytes)), total: Double(totalBytes))
                    .accessibilityLabel("Downloading \(descriptor.title)")
                HStack(spacing: 8) {
                    Text("\(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)) of \(downloadSize)")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    ImrseSecondaryButton(title: "Cancel download", action: onCancel)
                        .disabled(isPreview || isTerminating)
                }
            } else {
                HStack(spacing: 10) {
                    stateAction
                    if case .some(.installed) = snapshot?.state, !isInUse {
                        ImrseDestructiveButton(title: "Remove…", action: onRemove)
                            .disabled(!isEnabled || isPreview)
                    } else if isInUse, !isDefault {
                        Text("Used by a preset")
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
            }

            Button {
                showsModelDetails.toggle()
            } label: {
                HStack {
                    Text("Model details")
                    Spacer()
                    Image(systemName: showsModelDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.imrseCaption)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsModelDetails ? "Expanded" : "Collapsed")
            .accessibilityHint(showsModelDetails ? "Hide model details" : "Show model details")

            if showsModelDetails {
                Text(metadata)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
    }

    private var selectedModelIsInstalled: Bool {
        guard let snapshot, case .installed = snapshot.state else { return false }
        return true
    }

    @ViewBuilder
    private var stateAction: some View {
        if isPreview {
            ImrsePrimaryButton(title: "Download · \(downloadSize)", action: onDownload)
                .disabled(true)
        } else if let snapshot {
            switch snapshot.state {
            case .notInstalled:
                ImrsePrimaryButton(title: "Download · \(downloadSize)", action: onDownload)
                    .disabled(!isEnabled)
            case .downloading:
                EmptyView()
            case .installed:
                ImrsePrimaryButton(title: "Repair", action: onRepair)
                    .disabled(!isEnabled)
            }
        } else {
            Text("Checking installed state…")
                .font(.imrseCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateLabel: String {
        if isPreview { return "Preview fixture" }
        if downloadIsActive { return "Downloading" }
        guard let snapshot else { return "Checking installed state" }
        return switch snapshot.state {
        case .notInstalled: isDefault ? "Default · not downloaded" : "Not downloaded"
        case .downloading: "Downloading"
        case .installed: isDefault ? "Default · installed" : "Installed on this Mac"
        }
    }

    private var stateSymbol: String {
        if isPreview { return "eye" }
        if downloadIsActive { return "arrow.down.circle" }
        guard let snapshot else { return "ellipsis.circle" }
        return switch snapshot.state {
        case .notInstalled: "arrow.down.circle"
        case .downloading: "arrow.down.circle"
        case .installed: "checkmark.circle.fill"
        }
    }

    private var stateTone: SettingsStatusTone {
        if isDefault && selectedModelIsInstalled { return .positive }
        return .neutral
    }

    private var metadata: String {
        var values = ["Download \(downloadSize)", descriptor.license]
        if let minimumMemoryBytes = descriptor.minimumMemoryBytes {
            values.append("Minimum memory \(ByteCountFormatter.string(fromByteCount: minimumMemoryBytes, countStyle: .memory))")
        }
        return values.joined(separator: " · ")
    }

    private var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: descriptor.downloadBytes, countStyle: .file)
    }
}
#endif
