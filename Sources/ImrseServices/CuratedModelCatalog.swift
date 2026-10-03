import Foundation
import ImrseCore

public struct CuratedModelChoice: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String

    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

public enum CuratedModelCatalog {
    public static func recommendations(for kind: ProviderKind) -> [CuratedModelChoice] {
        switch kind {
        case .openAI:
            return [
                CuratedModelChoice(id: "gpt-4.1-mini", name: "GPT-4.1 mini", detail: "Everyday edits and concise rewrites"),
                CuratedModelChoice(id: "gpt-4.1", name: "GPT-4.1", detail: "Detailed instructions and structured text")
            ]
        case .openAIChatGPT:
            return [
                CuratedModelChoice(id: "gpt-6-luna", name: "GPT-6 Luna", detail: "Everyday text transformations"),
                CuratedModelChoice(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", detail: "Complex instructions and careful rewriting")
            ]
        case .openRouter:
            return [
                CuratedModelChoice(id: "openai/gpt-6-luna", name: "GPT-6 Luna", detail: "Everyday text transformations"),
                CuratedModelChoice(id: "anthropic/claude-sonnet-4.6", name: "Claude Sonnet 4.6", detail: "Writing, tone and longer instructions")
            ]
        case .managedLocal, .compatible:
            return []
        }
    }

    public static func accountRecommendations(availableIDs: Set<String>) -> [CuratedModelChoice] {
        recommendations(for: .openAIChatGPT).filter { availableIDs.contains($0.id) }
    }
}
