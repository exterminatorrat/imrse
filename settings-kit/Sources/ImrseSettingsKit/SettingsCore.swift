import Foundation

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case models = "Models"
    case presets = "Presets"
    case shortcuts = "Shortcuts"
    case advanced = "Advanced"
    case about = "About"

    public var id: String { rawValue }

    public static let primarySidebar: [SettingsSection] = [
        .general, .models, .presets, .shortcuts, .advanced
    ]

    public static let bottomSidebar: [SettingsSection] = [.about]
}

public enum SettingsDetail: Equatable, Sendable {
    case presetEditor(UUID)
    case newPreset
}

public struct SettingsNavigation: Equatable, Sendable {
    public var section: SettingsSection
    public var detail: SettingsDetail?

    public init(section: SettingsSection = .general, detail: SettingsDetail? = nil) {
        self.section = section
        self.detail = detail
    }

    public mutating func select(_ section: SettingsSection) {
        self.section = section
        detail = nil
    }

    public mutating func openPresetEditor(id: UUID) {
        section = .presets
        detail = .presetEditor(id)
    }

    public mutating func openNewPresetEditor() {
        section = .presets
        detail = .newPreset
    }

    public mutating func closeDetail() {
        detail = nil
    }
}

public enum InvocationMethod: Equatable, Sendable {
    case doubleControl
    case keyboardShortcut(String)

    public var displayName: String {
        switch self {
        case .doubleControl: "Double Control"
        case .keyboardShortcut(let value): value
        }
    }
}

public enum AnimationMode: String, CaseIterable, Equatable, Sendable {
    case instant = "Instant"
    case quick = "Quick"
    case smooth = "Smooth"
}

public enum AppearanceMode: String, CaseIterable, Equatable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

public struct GeneralSettings: Equatable, Sendable {
    public var invocation: InvocationMethod
    public var animation: AnimationMode
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var appearance: AppearanceMode

    public init(
        invocation: InvocationMethod = .doubleControl,
        animation: AnimationMode = .quick,
        launchAtLogin: Bool = false,
        showInMenuBar: Bool = false,
        appearance: AppearanceMode = .system
    ) {
        self.invocation = invocation
        self.animation = animation
        self.launchAtLogin = launchAtLogin
        self.showInMenuBar = showInMenuBar
        self.appearance = appearance
    }

    public static let defaults = GeneralSettings()
}

public enum ProviderType: String, CaseIterable, Equatable, Sendable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case anthropic = "Anthropic"
    case google = "Google"
    case openAICompatible = "OpenAI Compatible"
}

public struct ProviderConfiguration: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ProviderType
    public var baseURL: String
    public var defaultModel: String
    public var credentialStored: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProviderType,
        baseURL: String = "",
        defaultModel: String = "",
        credentialStored: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.credentialStored = credentialStored
    }
}

public struct TransformPreset: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var instruction: String
    public var model: String
    public var shortcut: String
    public var localOnly: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        instruction: String,
        model: String = "Use Default",
        shortcut: String = "",
        localOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.model = model
        self.shortcut = shortcut
        self.localOnly = localOnly
    }
}

public enum PermissionState: String, Sendable {
    case granted = "Granted"
    case missing = "Missing"
    case unknown = "Unknown"
}

public enum ActivityState: String, Sendable {
    case active = "Active"
    case inactive = "Inactive"
    case unknown = "Unknown"
}

public struct DiagnosticsSnapshot: Equatable, Sendable {
    public var accessibility: PermissionState
    public var globalShortcut: ActivityState
    public var frontmostApp: String
    public var selectionLength: Int?
    public var provider: String
    public var state: String
    public var lastError: String?

    public init(
        accessibility: PermissionState,
        globalShortcut: ActivityState,
        frontmostApp: String,
        selectionLength: Int?,
        provider: String,
        state: String,
        lastError: String?
    ) {
        self.accessibility = accessibility
        self.globalShortcut = globalShortcut
        self.frontmostApp = frontmostApp
        self.selectionLength = selectionLength
        self.provider = provider
        self.state = state
        self.lastError = lastError
    }

    public func redactedReport(secretValues: [String] = []) -> String {
        var report = [
            "imrse diagnostics",
            "Accessibility: \(accessibility.rawValue)",
            "Global Shortcut: \(globalShortcut.rawValue)",
            "Frontmost App: \(frontmostApp)",
            selectionLength.map { "Selection: Available (\($0) chars)" } ?? "Selection: Unavailable",
            "Provider: \(provider)",
            "State: \(state)",
            "Last Error: \(lastError ?? "None")"
        ].joined(separator: "\n")

        for secret in secretValues where !secret.isEmpty {
            report = report.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return report
    }

    public static let preview = DiagnosticsSnapshot(
        accessibility: .granted,
        globalShortcut: .active,
        frontmostApp: "com.apple.TextEdit",
        selectionLength: 124,
        provider: "OpenAI (gpt-4o)",
        state: "Idle",
        lastError: nil
    )
}

public struct ImrseSettingsState: Equatable, Sendable {
    public var general: GeneralSettings
    public var providers: [ProviderConfiguration]
    public var presets: [TransformPreset]
    public var developerOptionsEnabled: Bool

    public init(
        general: GeneralSettings = .defaults,
        providers: [ProviderConfiguration] = [],
        presets: [TransformPreset] = [],
        developerOptionsEnabled: Bool = false
    ) {
        self.general = general
        self.providers = providers
        self.presets = presets
        self.developerOptionsEnabled = developerOptionsEnabled
    }

    public static let empty = ImrseSettingsState()

    public mutating func addProvider(_ provider: ProviderConfiguration) {
        providers.append(provider)
    }

    public mutating func updateProvider(_ provider: ProviderConfiguration) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    public mutating func deleteProvider(id: UUID) {
        providers.removeAll { $0.id == id }
    }

    public mutating func addPreset(_ preset: TransformPreset) {
        presets.append(preset)
    }

    public mutating func updatePreset(_ preset: TransformPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    public mutating func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
    }

    public mutating func resetGeneralToDefaults() {
        general = .defaults
        developerOptionsEnabled = false
    }

    public static let preview = ImrseSettingsState(
        providers: [
            ProviderConfiguration(name: "OpenAI", type: .openAI, defaultModel: "gpt-4o", credentialStored: true),
            ProviderConfiguration(name: "Anthropic", type: .anthropic, defaultModel: "claude-3.5-sonnet", credentialStored: true),
            ProviderConfiguration(name: "Google", type: .google, defaultModel: "gemini-1.5-pro", credentialStored: true),
            ProviderConfiguration(name: "Local", type: .openAICompatible, baseURL: "http://localhost:11434", defaultModel: "llama3.1")
        ],
        presets: [
            TransformPreset(name: "Expand", instruction: "Expand this while preserving the original meaning.", shortcut: "⌘1"),
            TransformPreset(name: "Make Concise", instruction: "Make this more concise without losing important information.", shortcut: "⌘2"),
            TransformPreset(name: "Improve Writing", instruction: "Improve clarity, grammar, and structure while preserving my tone and meaning.", shortcut: "⌘3"),
            TransformPreset(name: "Fix Grammar", instruction: "Correct grammar and punctuation without changing meaning.", shortcut: "⌘4"),
            TransformPreset(name: "Custom Prompt", instruction: "", shortcut: "⌘5")
        ]
    )
}
