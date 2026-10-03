#if os(macOS)
import Foundation
import ImrseCore

enum ModelProviderSection: String, CaseIterable, Identifiable {
    case local
    case chatGPTAccount
    case openAIAPI
    case openRouter
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "Local on this Mac"
        case .chatGPTAccount: "ChatGPT account"
        case .openAIAPI: "OpenAI API key"
        case .openRouter: "OpenRouter"
        case .custom: "Custom advanced"
        }
    }

    var kind: ProviderKind? {
        switch self {
        case .local: .managedLocal
        case .chatGPTAccount: .openAIChatGPT
        case .openAIAPI: .openAI
        case .openRouter: .openRouter
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
        case .custom:
            nil
        }
    }

    var defaultProviderName: String {
        switch self {
        case .local: "Local model"
        case .chatGPTAccount: "OpenAI ChatGPT account"
        case .openAIAPI: "OpenAI API"
        case .openRouter: "OpenRouter"
        case .custom: "Custom endpoint"
        }
    }

    var listDescription: String {
        switch self {
        case .local: "Inference stays on this Mac · downloads are opt-in"
        case .chatGPTAccount: "Plan billing · separate from OpenAI API"
        case .openAIAPI: "Billed by OpenAI API usage"
        case .openRouter: "API usage is billed through OpenRouter"
        case .custom: "Routing and billing depend on the endpoint"
        }
    }

    var symbolName: String {
        switch self {
        case .local: "laptopcomputer"
        case .chatGPTAccount: "person.crop.circle"
        case .openAIAPI: "key.horizontal"
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
        case .openAI, .openRouter, .compatible: .custom
        }
    }
}
#endif
