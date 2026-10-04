#if os(macOS)
import Foundation
import ImrseCore
import ImrseServices
import SwiftUI

enum ModelProviderSection: String, CaseIterable, Identifiable {
    case local
    case chatGPTAccount
    case openRouterAccount
    case huggingFaceAccount
    case githubCopilot
    case openAIAPI
    case openRouter
    case anthropicAPI
    case deepSeekAPI
    case geminiAPI
    case xAIAPI
    case mistralAPI
    case togetherAPI
    case fireworksAPI
    case cerebrasAPI
    case custom

    var id: Self { self }

    var choiceGroup: ModelProviderChoiceGroup {
        switch self {
        case .local: .local
        case .chatGPTAccount, .openRouterAccount, .huggingFaceAccount, .githubCopilot: .accounts
        case .openAIAPI, .openRouter, .anthropicAPI, .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI: .apiKeys
        case .custom: .custom
        }
    }

    var usesExplicitModelID: Bool {
        switch self {
        case .anthropicAPI, .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI:
            true
        default:
            false
        }
    }

    var officialAPIProviderDescriptor: OfficialAPIProviderDescriptor? {
        guard let id = officialAPIProviderID else { return nil }
        return OfficialAPIProviderCatalog.descriptors.first { $0.id == id }
    }

    private var officialAPIProviderID: String? {
        switch self {
        case .deepSeekAPI: "deepseek"
        case .geminiAPI: "gemini"
        case .xAIAPI: "xai"
        case .mistralAPI: "mistral"
        case .togetherAPI: "together"
        case .fireworksAPI: "fireworks"
        case .cerebrasAPI: "cerebras"
        default: nil
        }
    }

    var title: String {
        switch self {
        case .local: "Local on this Mac"
        case .chatGPTAccount: "ChatGPT account"
        case .openRouterAccount: "OpenRouter account"
        case .huggingFaceAccount: "Hugging Face account"
        case .githubCopilot: "GitHub Copilot account"
        case .openAIAPI: "OpenAI API key"
        case .openRouter: "OpenRouter"
        case .anthropicAPI: "Anthropic API key"
        case .xAIAPI: "Grok / xAI"
        case .deepSeekAPI, .geminiAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI:
            officialAPIProviderDescriptor?.title ?? officialAPIProviderID ?? "Official API"
        case .custom: "Custom advanced"
        }
    }

    var kind: ProviderKind? {
        switch self {
        case .local: .managedLocal
        case .chatGPTAccount: .openAIChatGPT
        case .openRouterAccount: .openRouterAccount
        case .huggingFaceAccount: .huggingFaceAccount
        case .githubCopilot: .githubCopilot
        case .openAIAPI: .openAI
        case .openRouter: .openRouter
        case .anthropicAPI: .anthropic
        case .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI:
            officialAPIProviderDescriptor?.kind
        case .custom: nil
        }
    }

    var endpoint: URL? {
        switch self {
        case .local:
            URL(string: "imrse-local://models")
        case .chatGPTAccount, .openAIAPI:
            URL(string: "https://api.openai.com/v1")
        case .openRouter:
            URL(string: "https://openrouter.ai/api/v1")
        case .openRouterAccount:
            URL(string: "https://openrouter.ai/api/v1")
        case .huggingFaceAccount:
            URL(string: "https://router.huggingface.co/v1")
        case .githubCopilot:
            URL(string: "https://api.githubcopilot.com")
        case .anthropicAPI:
            URL(string: "https://api.anthropic.com/v1")
        case .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI:
            officialAPIProviderDescriptor?.endpoint
        case .custom:
            nil
        }
    }

    var defaultProviderName: String {
        switch self {
        case .local: "Local model"
        case .chatGPTAccount: "OpenAI ChatGPT account"
        case .openRouterAccount: "OpenRouter account"
        case .huggingFaceAccount: "Hugging Face account"
        case .githubCopilot: "GitHub Copilot account"
        case .openAIAPI: "OpenAI API"
        case .openRouter: "OpenRouter"
        case .anthropicAPI, .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI:
            title
        case .custom: "Custom endpoint"
        }
    }

    var listDescription: String {
        if let officialAPIProviderDescriptor { return officialAPIProviderDescriptor.billingDescription }
        return switch self {
        case .local: "Inference stays on this Mac · downloads are opt-in"
        case .chatGPTAccount: "Plan billing · separate from OpenAI API"
        case .openRouterAccount: "Connect your account · usage is billed through OpenRouter"
        case .huggingFaceAccount: "Use Hugging Face Inference Providers · billing depends on your account"
        case .githubCopilot: "Use Copilot access · availability depends on your plan"
        case .openAIAPI: "Billed by OpenAI API usage"
        case .openRouter: "API usage is billed through OpenRouter"
        case .anthropicAPI: "API key billing · requests are billed by Anthropic"
        case .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI:
            "API key billing · requests are billed by \(title)"
        case .custom: "Routing and billing depend on the endpoint"
        }
    }

    var symbolName: String {
        switch self {
        case .local: "laptopcomputer"
        case .chatGPTAccount, .openRouterAccount, .huggingFaceAccount, .githubCopilot: "person.crop.circle"
        case .openAIAPI, .anthropicAPI, .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI: "key.horizontal"
        case .openRouter: "network"
        case .custom: "server.rack"
        }
    }

    static func forProvider(_ provider: ProviderConfiguration?) -> Self? {
        guard let provider else { return nil }
        return switch provider.kind {
        case .managedLocal: .local
        case .openAIChatGPT: .chatGPTAccount
        case .openAI where provider.endpoint == URL(string: "https://api.openai.com/v1"): .openAIAPI
        case .openRouter where provider.endpoint == URL(string: "https://openrouter.ai/api/v1"): .openRouter
        case .openRouterAccount: .openRouterAccount
        case .huggingFaceAccount: .huggingFaceAccount
        case .githubCopilot: .githubCopilot
        case .anthropic where provider.endpoint == URL(string: "https://api.anthropic.com/v1"): .anthropicAPI
        case .compatible:
            OfficialAPIProviderCatalog.descriptors.first { $0.endpoint == provider.endpoint }
                .flatMap { section(forOfficialAPIProviderID: $0.id) } ?? .custom
        case .openAI, .openRouter, .anthropic: .custom
        }
    }

    private static func section(forOfficialAPIProviderID id: String) -> Self? {
        switch id {
        case "deepseek": .deepSeekAPI
        case "gemini": .geminiAPI
        case "xai": .xAIAPI
        case "mistral": .mistralAPI
        case "together": .togetherAPI
        case "fireworks": .fireworksAPI
        case "cerebras": .cerebrasAPI
        default: nil
        }
    }
}

enum ModelProviderChoiceGroup: String, CaseIterable, Identifiable {
    case local
    case accounts
    case apiKeys
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "Local"
        case .accounts: "Accounts"
        case .apiKeys: "API keys"
        case .custom: "Custom"
        }
    }

    var sections: [ModelProviderSection] {
        ModelProviderSection.allCases.filter { $0.choiceGroup == self }
    }
}

struct ReasoningEffortControl: View {
    private enum Selection: Hashable {
        case providerDefault
        case effort(String)
    }

    @Binding var effort: String?
    let capabilities: ReasoningEffortCapabilities

    var body: some View {
        ImrseLabeledRow(
            "Reasoning effort",
            subtitle: "Choose an effort reported by this endpoint."
        ) {
            ImrseMenuControl(
                selection: selection,
                options: [.providerDefault] + capabilities.supportedEfforts.map(Selection.effort),
                title: title,
                accessibilityLabel: "Reasoning effort"
            )
        }
    }

    private var selection: Binding<Selection> {
        Binding(
            get: {
                guard let effort, capabilities.supportedEfforts.contains(effort) else { return .providerDefault }
                return .effort(effort)
            },
            set: { selection in
                effort = switch selection {
                case .providerDefault: nil
                case .effort(let value): value
                }
            }
        )
    }

    private func title(_ selection: Selection) -> String {
        switch selection {
        case .providerDefault:
            capabilities.defaultEffort.map { "Provider default (\($0))" } ?? "Provider default"
        case .effort("none"):
            "None (disable reasoning)"
        case .effort(let value): value
        }
    }
}
#endif
