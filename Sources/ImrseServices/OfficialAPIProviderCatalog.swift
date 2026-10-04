import Foundation
import ImrseCore

public struct OfficialAPIProviderDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let endpoint: URL
    public let kind: ProviderKind
    public let billingDescription: String

    public init(id: String, title: String, endpoint: URL, kind: ProviderKind, billingDescription: String) {
        self.id = id
        self.title = title
        self.endpoint = endpoint
        self.kind = kind
        self.billingDescription = billingDescription
    }
}

public enum OfficialAPIProviderCatalog {
    public static let descriptors: [OfficialAPIProviderDescriptor] = [
        descriptor("deepseek", "DeepSeek", "https://api.deepseek.com", "API usage is billed by DeepSeek through your API key; no consumer subscription is included."),
        descriptor("gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "API usage is billed through Google AI Studio by your API key; consumer subscriptions are separate."),
        descriptor("xai", "xAI", "https://api.x.ai/v1", "API usage is billed by xAI through your API key; no consumer subscription is included."),
        descriptor("mistral", "Mistral", "https://api.mistral.ai/v1", "API usage is billed by Mistral through your API key; no consumer subscription is included."),
        descriptor("together", "Together AI", "https://api.together.ai/v1", "API usage is billed by Together AI through your API key; no consumer subscription is included."),
        descriptor("fireworks", "Fireworks AI", "https://api.fireworks.ai/inference/v1", "API usage is billed by Fireworks AI through your API key; no consumer subscription is included."),
        descriptor("cerebras", "Cerebras", "https://api.cerebras.ai/v1", "API usage is billed by Cerebras through your API key; no consumer subscription is included.")
    ]

    private static func descriptor(_ id: String, _ title: String, _ endpoint: String, _ billingDescription: String) -> OfficialAPIProviderDescriptor {
        OfficialAPIProviderDescriptor(
            id: id,
            title: title,
            endpoint: URL(string: endpoint)!,
            kind: .compatible,
            billingDescription: billingDescription
        )
    }
}
