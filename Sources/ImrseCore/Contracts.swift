import Foundation

public enum MotionPreference: String, Codable, CaseIterable, Sendable { case instant, quick, smooth, balanced, slow }
public enum AppearancePreference: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum ContextScope: String, Codable, Sendable { case selection }
public enum ProviderKind: String, Codable, CaseIterable, Sendable { case openAI, openAIChatGPT, openRouter, managedLocal, compatible }
public enum ReplacementStrategy: String, Codable, Sendable { case selectedText, valueRange, clipboard }
public enum ReasoningEffortRequestFormat: String, Codable, Sendable {
    case chatCompletionsField
    case chatCompletionsObject
    case responsesObject
}

public struct ReasoningEffortCapabilities: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var model: String
    public var supportedEfforts: [String]
    public var requestFormat: ReasoningEffortRequestFormat
    public var defaultEffort: String?
    public var mandatory: Bool?

    public init(
        endpoint: URL,
        model: String,
        supportedEfforts: [String],
        requestFormat: ReasoningEffortRequestFormat,
        defaultEffort: String? = nil,
        mandatory: Bool? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.supportedEfforts = supportedEfforts
        self.requestFormat = requestFormat
        self.defaultEffort = defaultEffort
        self.mandatory = mandatory
    }

    public func applies(to endpoint: URL, model: String, providerKind: ProviderKind) -> Bool {
        guard self.endpoint == endpoint, self.model == model else { return false }
        switch providerKind {
        case .openAIChatGPT:
            return requestFormat == .responsesObject
        case .openRouter:
            return requestFormat == .chatCompletionsObject
        case .openAI, .compatible:
            return requestFormat != .responsesObject
        case .managedLocal:
            return false
        }
    }
}

public struct TextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public struct SelectionSnapshot: Equatable, Sendable {
    public let id: UUID
    public let applicationID: String
    public let processID: Int32
    public let role: String
    public let text: String
    public let range: TextRange?
    public let isSecure: Bool
    public init(id: UUID = UUID(), applicationID: String, processID: Int32, role: String, text: String, range: TextRange? = nil, isSecure: Bool = false) {
        self.id = id; self.applicationID = applicationID; self.processID = processID
        self.role = role; self.text = text; self.range = range; self.isSecure = isSecure
    }
}

public struct ReplacementReceipt: Equatable, Sendable {
    public let target: SelectionSnapshot
    public let replacement: String
    public let strategy: ReplacementStrategy
    public init(target: SelectionSnapshot, replacement: String, strategy: ReplacementStrategy) {
        self.target = target; self.replacement = replacement; self.strategy = strategy
    }
}

@MainActor public protocol SelectionAccess: AnyObject {
    func capture() throws -> SelectionSnapshot
    func validate(_ target: SelectionSnapshot) throws
    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt
    func undo(_ receipt: ReplacementReceipt) async throws
    func discard(_ target: SelectionSnapshot)
}

public struct ProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var endpoint: URL
    public var model: String
    public var requiresCredential: Bool
    public var reasoningEffort: String?
    public var reasoningEffortCapabilities: ReasoningEffortCapabilities?
    public init(
        id: String,
        name: String,
        kind: ProviderKind,
        endpoint: URL,
        model: String,
        requiresCredential: Bool = true,
        reasoningEffort: String? = nil,
        reasoningEffortCapabilities: ReasoningEffortCapabilities? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind; self.endpoint = endpoint
        self.model = model; self.requiresCredential = requiresCredential
        self.reasoningEffort = reasoningEffort
        self.reasoningEffortCapabilities = reasoningEffortCapabilities
    }

    public var activeReasoningEffort: (effort: String, format: ReasoningEffortRequestFormat)? {
        guard let reasoningEffort,
              let capabilities = reasoningEffortCapabilities,
              capabilities.applies(to: endpoint, model: model, providerKind: kind),
              capabilities.supportedEfforts.contains(reasoningEffort),
              capabilities.mandatory != true || reasoningEffort != "none"
        else { return nil }
        return (reasoningEffort, capabilities.requestFormat)
    }
}

public struct ResponseMetadata: Equatable, Sendable {
    public var detectedModel: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?

    public init(
        detectedModel: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.detectedModel = detectedModel
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

public struct ShortcutBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    public init(keyCode: UInt16, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode; self.command = command; self.option = option
        self.control = control; self.shift = shift
    }
}

public struct InvocationConfiguration: Codable, Equatable, Sendable {
    public var doubleControlEnabled: Bool
    public var doubleControlInterval: Double
    public var shortcut: ShortcutBinding?
    public init(doubleControlEnabled: Bool = true, doubleControlInterval: Double = 0.32, shortcut: ShortcutBinding? = nil) {
        self.doubleControlEnabled = doubleControlEnabled; self.doubleControlInterval = doubleControlInterval; self.shortcut = shortcut
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var providers: [ProviderConfiguration]
    public var selectedProviderID: String?
    public var invocation: InvocationConfiguration
    public var motion: MotionPreference
    public var clipboardFallbackEnabled: Bool
    public var showInMenuBar: Bool
    public var appearance: AppearancePreference
    public init(version: Int = 1, providers: [ProviderConfiguration] = [], selectedProviderID: String? = nil, invocation: InvocationConfiguration = .init(), motion: MotionPreference = .quick, clipboardFallbackEnabled: Bool = false, showInMenuBar: Bool = true, appearance: AppearancePreference = .system) {
        self.version = version; self.providers = providers; self.selectedProviderID = selectedProviderID
        self.invocation = invocation; self.motion = motion; self.clipboardFallbackEnabled = clipboardFallbackEnabled
        self.showInMenuBar = showInMenuBar; self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case version, providers, selectedProviderID, invocation, motion, clipboardFallbackEnabled
        case showInMenuBar, appearance
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        providers = try values.decode([ProviderConfiguration].self, forKey: .providers)
        selectedProviderID = try values.decodeIfPresent(String.self, forKey: .selectedProviderID)
        invocation = try values.decode(InvocationConfiguration.self, forKey: .invocation)
        motion = try values.decode(MotionPreference.self, forKey: .motion)
        clipboardFallbackEnabled = try values.decode(Bool.self, forKey: .clipboardFallbackEnabled)
        showInMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        appearance = try values.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    }
}

public struct Preset: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var instruction: String
    public var providerID: String?
    public var model: String?
    public var localOnly: Bool
    public var fallbackProviderID: String?
    public var shortcut: ShortcutBinding?
    public var motion: MotionPreference?
    public var context: ContextScope
    public init(id: String, name: String, instruction: String, providerID: String? = nil, model: String? = nil, localOnly: Bool = false, fallbackProviderID: String? = nil, shortcut: ShortcutBinding? = nil, motion: MotionPreference? = nil, context: ContextScope = .selection) {
        self.id = id; self.name = name; self.instruction = instruction; self.providerID = providerID
        self.model = model; self.localOnly = localOnly; self.fallbackProviderID = fallbackProviderID
        self.shortcut = shortcut; self.motion = motion; self.context = context
    }
}

public struct TransformationRequest: Sendable {
    public let text: String
    public let instruction: String
    public let provider: ProviderConfiguration
    public let localOnly: Bool
    public let fallbackProvider: ProviderConfiguration?
    public let reportProvider: (@MainActor @Sendable (ProviderConfiguration) -> Void)?
    public let reportResponseMetadata: (@MainActor @Sendable (ResponseMetadata) -> Void)?
    public init(
        text: String,
        instruction: String,
        provider: ProviderConfiguration,
        localOnly: Bool = false,
        fallbackProvider: ProviderConfiguration? = nil,
        reportProvider: (@MainActor @Sendable (ProviderConfiguration) -> Void)? = nil,
        reportResponseMetadata: (@MainActor @Sendable (ResponseMetadata) -> Void)? = nil
    ) {
        self.text = text; self.instruction = instruction; self.provider = provider; self.localOnly = localOnly
        self.fallbackProvider = fallbackProvider
        self.reportProvider = reportProvider
        self.reportResponseMetadata = reportResponseMetadata
    }
}

public protocol TextProvider: Sendable {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error>
}

public protocol CredentialStore: Sendable {
    func credential(for providerID: String) async throws -> String?
    func setCredential(_ value: String?, for providerID: String) async throws
}

public enum ImrseError: String, Error, Codable, CaseIterable, Sendable {
    case noSelection, secureInput, selectionTooLarge, instructionTooLarge
    case targetLost, staleSelection, replacementFailed, clipboardFailed, undoUnavailable
    case providerUnavailable, localModelUnavailable, authentication, missingCredentials
    case rateLimited, timeout, network, server, malformedResponse, interruptedStream
    case emptyOutput, outputTooLarge, invalidConfiguration, missingModel, invalidPreset
    case permissionRequired, shortcutConflict, cancelled

    public var message: String {
        switch self {
        case .noSelection: "Select some text first"
        case .secureInput: "Secure fields stay private"
        case .selectionTooLarge: "The selection is too long"
        case .instructionTooLarge: "The instruction is too long"
        case .targetLost: "The original text field is unavailable"
        case .staleSelection: "The selection changed. Nothing was replaced"
        case .replacementFailed: "Couldn't replace the selection"
        case .clipboardFailed: "Couldn't paste safely"
        case .undoUnavailable: "The text changed. Undo isn't safe"
        case .providerUnavailable: "Choose a model in Settings"
        case .localModelUnavailable: "The local model is unavailable"
        case .authentication: "Check this provider's API key"
        case .missingCredentials: "Add an API key in Settings"
        case .rateLimited: "The provider is busy. Try again shortly"
        case .timeout: "The model took too long. Try again"
        case .network: "Couldn't reach the model"
        case .server: "The provider couldn't complete the request"
        case .malformedResponse: "The model returned an invalid response"
        case .interruptedStream: "The response was interrupted. Nothing was replaced"
        case .emptyOutput: "The model returned no text"
        case .outputTooLarge: "The response is too long to replace safely"
        case .invalidConfiguration: "Check the configuration file"
        case .missingModel: "Choose a model in Settings"
        case .invalidPreset: "Check this preset's format"
        case .permissionRequired: "Allow Accessibility in System Settings"
        case .shortcutConflict: "This shortcut is already assigned"
        case .cancelled: "Cancelled"
        }
    }
}

public struct DiagnosticMetadata: Equatable, Sendable {
    public var accessibilityGranted = false
    public var eventMonitoringActive = false
    public var applicationID: String?
    public var role: String?
    public var selectionLength: Int?
    public var targetValid: Bool?
    public var strategy: ReplacementStrategy?
    public var providerName: String?
    public var model: String?
    public var generation = "idle"
    public var replacement = "idle"
    public var error: ImrseError?
    public init() {}
}
