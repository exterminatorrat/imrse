import Foundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderModelCatalogClient: Sendable {
    private static let openRouterGatewayEfforts = ["max", "xhigh", "high", "medium", "low", "minimal", "none"]
    private let credentials: any CredentialStore
    private let transport: any StreamingHTTPTransport

    public init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func reasoningEffortCapabilities(for provider: ProviderConfiguration) async throws -> ReasoningEffortCapabilities? {
        guard [.openAI, .openRouter, .compatible].contains(provider.kind) else { return nil }
        try ProviderValidation.validate(provider)
        guard let url = Self.modelsURL(for: provider.endpoint) else { throw ImrseError.invalidConfiguration }

        let isPublicOpenRouterCatalog = provider.kind == .openRouter
            && URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false)?.host?.lowercased() == "openrouter.ai"
        var request = OpenAIHTTP.getRequest(url: url)
        if provider.requiresCredential, !isPublicOpenRouterCatalog {
            guard let credential = try await credentials.credential(for: provider.id),
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ImrseError.missingCredentials }
            let normalizedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedCredential.utf8.count <= 4_096,
                  normalizedCredential.utf8.allSatisfy({ (33...126).contains($0) })
            else { throw ImrseError.authentication }
            request.setValue("Bearer \(normalizedCredential)", forHTTPHeaderField: "Authorization")
        }

        let response = try await OpenAIHTTP.send(
            request,
            using: transport,
            localOnly: ProviderValidation.isLoopback(provider.endpoint)
        )
        guard let catalog = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let models = catalog["data"] as? [[String: Any]],
              let model = models.first(where: { $0["id"] as? String == provider.model })
        else { return nil }

        if provider.kind == .openRouter {
            guard let reasoning = model["reasoning"] as? [String: Any],
                  reasoning.keys.contains("supported_efforts")
            else { return nil }
            let mandatory = reasoning["mandatory"] as? Bool
            let efforts: [String]
            if reasoning["supported_efforts"] is NSNull {
                efforts = Self.openRouterGatewayEfforts.filter { $0 != "none" || mandatory != true }
            } else if let supportedEfforts = Self.efforts(reasoning["supported_efforts"]) {
                efforts = supportedEfforts.filter { $0 != "none" || mandatory != true }
            } else {
                return nil
            }
            guard !efforts.isEmpty else { return nil }
            return ReasoningEffortCapabilities(
                endpoint: provider.endpoint,
                model: provider.model,
                supportedEfforts: efforts,
                requestFormat: .chatCompletionsObject,
                defaultEffort: Self.effort(reasoning["default_effort"]),
                mandatory: mandatory
            )
        }

        if let reasoning = model["reasoning"] as? [String: Any],
           reasoning.keys.contains("supported_efforts")
        {
            guard let efforts = Self.efforts(reasoning["supported_efforts"]) else { return nil }
            return ReasoningEffortCapabilities(
                endpoint: provider.endpoint,
                model: provider.model,
                supportedEfforts: efforts,
                requestFormat: .chatCompletionsObject,
                defaultEffort: Self.effort(reasoning["default_effort"]),
                mandatory: reasoning["mandatory"] as? Bool
            )
        }

        if let efforts = Self.efforts(model["supported_reasoning_levels"]) {
            return ReasoningEffortCapabilities(
                endpoint: provider.endpoint,
                model: provider.model,
                supportedEfforts: efforts,
                requestFormat: .chatCompletionsField
            )
        }
        return nil
    }

    private static func efforts(_ value: Any?) -> [String]? {
        guard let values = value as? [Any], !values.isEmpty, values.count <= 32 else { return nil }
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            if value is NSNull { continue }
            let effort: String?
            if let value = value as? String {
                effort = value
            } else if let value = value as? [String: Any] {
                effort = value["effort"] as? String
            } else {
                return nil
            }
            guard let effort, Self.isValidEffort(effort) else { return nil }
            if seen.insert(effort).inserted { result.append(effort) }
        }
        return result.isEmpty ? nil : result
    }

    private static func effort(_ value: Any?) -> String? {
        guard let effort = value as? String, Self.isValidEffort(effort) else { return nil }
        return effort
    }

    private static func isValidEffort(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }

    private static func modelsURL(for endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/models") {
            components.path = path
        } else if path == "/" || path.isEmpty {
            components.path = "/v1/models"
        } else {
            components.path = path + "/models"
        }
        return components.url
    }
}
