#if os(macOS)
import ImrseCore
import SwiftUI

struct PresetsSettingsPane: View {
    @ObservedObject var model: AppModel
    @Binding private var requestedPresetID: String?
    @State private var isEditing = false
    @State private var showingOptionalSettings = false
    @State private var draft = PresetDraft()
    @State private var feedback: String?

    init(model: AppModel, requestedPresetID: Binding<String?> = .constant(nil)) {
        self.model = model
        _requestedPresetID = requestedPresetID
    }

    var body: some View {
        SettingsPage(title: pageTitle, subtitle: pageSubtitle, symbol: pageSymbol) {
            if isEditing {
                presetEditor
            } else {
                presetList
            }
        }
        .onAppear(perform: loadRequestedPreset)
        .onChange(of: requestedPresetID) { _, _ in loadRequestedPreset() }
    }

    private var pageTitle: String {
        guard isEditing else { return "Presets" }
        return model.presets.contains(where: { $0.id == draft.id }) ? "Edit Preset" : "New Preset"
    }

    private var pageSubtitle: String {
        isEditing
            ? "Create a reusable instruction and add an optional shortcut."
            : "Save instructions for selected text with optional keyboard shortcuts."
    }

    private var pageSymbol: String {
        guard isEditing else { return "text.quote" }
        return isExistingPreset ? "square.and.pencil" : "plus.square"
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: ImrseSettingsMetrics.sectionSpacing) {
            if model.presets.isEmpty {
                SettingsSection(title: "No presets yet", symbol: "text.badge.plus") {
                    HStack(spacing: 14) {
                        SettingsIcon(symbol: "text.quote", size: 30)

                        Text("Create a reusable instruction for selected text.")
                            .font(.imrseBody)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 12)

                        ImrsePrimaryButton(title: "New Preset", action: newPreset)
                            .disabled(!model.canOpenSettings)
                    }
                    .frame(minHeight: 46)
                }
            } else {
                SettingsSection(
                    title: "Saved presets",
                    symbol: "text.alignleft",
                    detail: "Select a preset to edit it. Instruction text stays hidden here."
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.presets.enumerated()), id: \.element.id) { index, preset in
                            Button { edit(preset) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "text.alignleft")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)

                                    Text(preset.name)
                                        .font(.imrseBody)
                                        .lineLimit(1)

                                    Spacer(minLength: 8)

                                    if let shortcut = preset.shortcut {
                                        SettingsKeycap(value: ShortcutFormatter.label(for: shortcut))
                                    } else {
                                        Text("No shortcut")
                                            .font(.imrseCaption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canOpenSettings)

                            if index < model.presets.count - 1 {
                                ImrseDivider()
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    ImrsePrimaryButton(title: "New Preset", action: newPreset)
                        .disabled(!model.canOpenSettings)
                }
            }

            if let issue = model.configurationIssue {
                SettingsHint(title: "Configuration needs attention", detail: issue, symbol: "exclamationmark.triangle")
            }
            if let feedback {
                SettingsHint(title: "Preset status", detail: feedback, symbol: "info.circle")
            }
        }
    }

    private var presetEditor: some View {
        VStack(alignment: .leading, spacing: ImrseSettingsMetrics.sectionSpacing) {
            SettingsSection(
                title: "Instruction",
                symbol: "text.alignleft"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.imrseBody)
                        ImrseTextField(placeholder: "Preset name", text: $draft.name)
                            .disabled(!model.canChangeSettings)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instruction")
                            .font(.imrseBody)
                        ImrseTextEditor(text: $draft.instruction)
                            .frame(height: 92)
                            .disabled(!model.canChangeSettings)
                    }

                    ShortcutRecorder(
                        title: "Shortcut",
                        shortcut: $draft.shortcut,
                        issue: $feedback,
                        isEnabled: model.canChangeSettings,
                        model: model
                    )
                }
            }

            SettingsSection(
                title: "Routing and behavior",
                symbol: "slider.horizontal.3"
            ) {
                Button {
                    showingOptionalSettings.toggle()
                } label: {
                    HStack {
                        Text(showingOptionalSettings ? "Hide optional settings" : "Show optional settings")
                        Spacer()
                        Image(systemName: showingOptionalSettings ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.imrseBody)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Optional settings")
                .accessibilityValue(showingOptionalSettings ? "Expanded" : "Collapsed")
                .accessibilityHint(showingOptionalSettings ? "Hide optional settings" : "Show optional settings")

                if showingOptionalSettings {
                    VStack(spacing: 14) {
                        ImrseLabeledRow("Provider") {
                            ImrseMenuControl(
                                selection: $draft.providerID,
                                options: [Optional<String>.none] + model.configuration.providers.map { Optional($0.id) },
                                title: providerTitle
                            )
                            .disabled(!model.canChangeSettings)
                        }

                        ImrseLabeledRow("Model override") {
                            ImrseTextField(placeholder: "Optional model ID", text: $draft.model)
                                .disabled(!model.canChangeSettings)
                        }

                        ImrseLabeledRow("Local only", subtitle: "Never send this preset to a cloud provider.") {
                            Toggle("", isOn: $draft.localOnly)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(.primary)
                                .disabled(!model.canChangeSettings)
                        }

                        if draft.localOnly {
                            SettingsHint(
                                title: "Fallback disabled",
                                detail: "Fallback stays unavailable while this preset is local-only.",
                                symbol: "lock.shield"
                            )
                        }

                        ImrseLabeledRow("Fallback provider") {
                            ImrseMenuControl(
                                selection: $draft.fallbackProviderID,
                                options: [Optional<String>.none] + model.configuration.providers.map { Optional($0.id) },
                                title: fallbackProviderTitle
                            )
                            .disabled(!model.canChangeSettings || draft.localOnly)
                        }

                        ImrseLabeledRow("Context") {
                            Text(draft.context == .selection ? "Selected text" : draft.context.rawValue)
                                .font(.imrseBody)
                                .foregroundStyle(.secondary)
                        }

                        ImrseLabeledRow("Motion") {
                            motionMenu
                        }
                    }
                    .padding(.top, 8)
                }
            }

            if let issue = model.configurationIssue {
                SettingsHint(title: "Configuration needs attention", detail: issue, symbol: "exclamationmark.triangle")
            }

            HStack {
                if isExistingPreset {
                    ImrseDestructiveButton(title: "Delete", action: deletePreset)
                        .disabled(!model.canChangeSettings)
                }

                Spacer()

                ImrseSecondaryButton(title: "Cancel", action: cancelEditing)
                ImrsePrimaryButton(title: "Save Preset", action: savePreset)
                    .disabled(!model.canChangeSettings || !draft.isValid)
            }

            if let feedback {
                SettingsHint(title: "Preset status", detail: feedback, symbol: "info.circle")
            }
        }
    }

    private var isExistingPreset: Bool {
        model.presets.contains(where: { $0.id == draft.id })
    }

    private var motionMenu: some View {
        var options: [MotionPreference?] = [nil, .quick, .balanced, .slow]
        if let motion = draft.motion, motion == .instant || motion == .smooth {
            options.append(motion)
        }

        return ImrseMenuControl(
            selection: $draft.motion,
            options: options,
            title: { $0?.settingsTitle ?? "Use General setting" },
            accessibilityLabel: "Motion"
        )
        .disabled(!model.canChangeSettings)
    }

    private func providerTitle(_ providerID: String?) -> String {
        guard let providerID else { return "Use default provider" }
        return model.configuration.providers.first(where: { $0.id == providerID })?.name ?? "Unavailable provider"
    }

    private func fallbackProviderTitle(_ providerID: String?) -> String {
        guard let providerID else { return "No fallback" }
        return model.configuration.providers.first(where: { $0.id == providerID })?.name ?? "Unavailable provider"
    }

    private func loadRequestedPreset() {
        guard let requestedPresetID else { return }
        self.requestedPresetID = nil
        guard let preset = model.presets.first(where: { $0.id == requestedPresetID }) else {
            feedback = "This preset is no longer available."
            return
        }
        edit(preset)
    }

    private func newPreset() {
        draft = PresetDraft()
        showingOptionalSettings = false
        isEditing = true
        feedback = nil
    }

    private func edit(_ preset: Preset) {
        draft = PresetDraft(preset: preset)
        showingOptionalSettings = preset.providerID != nil
            || preset.model != nil
            || preset.localOnly
            || preset.fallbackProviderID != nil
            || preset.motion != nil
            || preset.context != .selection
        isEditing = true
        feedback = nil
    }

    private func cancelEditing() {
        isEditing = false
        draft = PresetDraft()
        showingOptionalSettings = false
        feedback = nil
    }

    private func savePreset() {
        guard model.canChangeSettings else { return }
        guard let preset = draft.preset else {
            feedback = "Add a name and instruction before saving."
            return
        }
        do {
            try model.savePreset(preset)
            isEditing = false
            feedback = "Preset saved."
        } catch {
            feedback = AppModel.userMessage(for: error)
        }
    }

    private func deletePreset() {
        guard model.canChangeSettings else { return }
        do {
            try model.deletePreset(id: draft.id)
            isEditing = false
            draft = PresetDraft()
            showingOptionalSettings = false
            feedback = "Preset deleted."
        } catch {
            feedback = AppModel.userMessage(for: error)
        }
    }

}

struct PresetDraft {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var instruction = ""
    var providerID: String?
    var model = ""
    var localOnly = false
    var fallbackProviderID: String?
    var shortcut: ShortcutBinding?
    var motion: MotionPreference?
    var context = ContextScope.selection

    init(preset: Preset? = nil) {
        guard let preset else { return }
        id = preset.id
        name = preset.name
        instruction = preset.instruction
        providerID = preset.providerID
        model = preset.model ?? ""
        localOnly = preset.localOnly
        fallbackProviderID = preset.fallbackProviderID
        shortcut = preset.shortcut
        motion = preset.motion
        context = preset.context
    }

    var preset: Preset? {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return Preset(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            instruction: instruction,
            providerID: providerID,
            model: normalizedModel.isEmpty ? nil : normalizedModel,
            localOnly: localOnly,
            fallbackProviderID: fallbackProviderID,
            shortcut: shortcut,
            motion: motion,
            context: context
        )
    }

    var isValid: Bool {
        guard let preset else { return false }
        return !preset.name.isEmpty && !preset.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
