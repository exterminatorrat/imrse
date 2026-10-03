import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProviderModelCatalogClientTests: XCTestCase {
    func testOpenRouterUsesListedEffortsAndAdvertisedDefault() async throws {
        let endpoint = URL(string: "https://openrouter.ai/api/v1")!
        let credentials = CatalogCredentials()
        let transport = CatalogTransport(json: #"{"data":[{"id":"openai/gpt-6.1-sol","reasoning":{"enabled":true,"mandatory":true,"supported_efforts":["max","xhigh","high","medium","low"],"default_effort":"medium"}}]}"#)
        let client = ProviderModelCatalogClient(credentials: credentials, transport: transport)
        let provider = provider(kind: .openRouter, endpoint: endpoint, model: "openai/gpt-6.1-sol")

        let capabilities = try await client.reasoningEffortCapabilities(for: provider)

        XCTAssertEqual(capabilities?.endpoint, endpoint)
        XCTAssertEqual(capabilities?.model, provider.model)
        XCTAssertEqual(capabilities?.supportedEfforts, ["max", "xhigh", "high", "medium", "low"])
        XCTAssertEqual(capabilities?.defaultEffort, "medium")
        XCTAssertEqual(capabilities?.mandatory, true)
        XCTAssertEqual(capabilities?.requestFormat, .chatCompletionsObject)
        let capturedValue = await transport.captured()
        let captured = try XCTUnwrap(capturedValue)
        XCTAssertEqual(captured.request.url?.path, "/api/v1/models")
        XCTAssertNil(captured.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(captured.localOnly)
        let credentialReadCount = await credentials.readCount()
        XCTAssertEqual(credentialReadCount, 0)
    }

    func testOpenRouterOmittedEffortsDoesNotCreateASelector() async throws {
        let client = catalogClient(json: #"{"data":[{"id":"reasoning-model","supported_reasoning_levels":["high"],"reasoning":{"enabled":true,"mandatory":true,"default_effort":"medium"}}]}"#)

        let capabilities = try await client.reasoningEffortCapabilities(for: provider(kind: .openRouter, model: "reasoning-model"))

        XCTAssertNil(capabilities)
    }

    func testOpenRouterNullEffortsMeansGatewayChoicesAndMandatoryExcludesNone() async throws {
        let client = catalogClient(json: #"{"data":[{"id":"optional","reasoning":{"supported_efforts":null,"mandatory":false}},{"id":"required","reasoning":{"supported_efforts":null,"mandatory":true}}]}"#)

        let optional = try await client.reasoningEffortCapabilities(for: provider(kind: .openRouter, model: "optional"))
        let required = try await client.reasoningEffortCapabilities(for: provider(kind: .openRouter, model: "required"))

        XCTAssertEqual(optional?.supportedEfforts, ["max", "xhigh", "high", "medium", "low", "minimal", "none"])
        XCTAssertEqual(required?.supportedEfforts, ["max", "xhigh", "high", "medium", "low", "minimal"])
    }

    func testCompatibleCatalogReadsOnlyAdvertisedReasoningLevels() async throws {
        let client = catalogClient(json: #"{"data":[{"id":"chosen","supported_reasoning_levels":["high",{"effort":"low"}]},{"id":"ordinary","reasoning":{"enabled":true}}]}"#)

        let capabilities = try await client.reasoningEffortCapabilities(for: provider(kind: .compatible, model: "chosen"))
        let ordinary = try await client.reasoningEffortCapabilities(for: provider(kind: .compatible, model: "ordinary"))
        let differentModel = try await client.reasoningEffortCapabilities(for: provider(kind: .compatible, model: "unlisted"))

        XCTAssertEqual(capabilities?.supportedEfforts, ["high", "low"])
        XCTAssertEqual(capabilities?.requestFormat, .chatCompletionsField)
        XCTAssertNil(ordinary)
        XCTAssertNil(differentModel)
    }

    func testLoopbackCatalogRequestUsesLocalNetworkPolicy() async throws {
        let transport = CatalogTransport(json: #"{"data":[{"id":"local","supported_reasoning_levels":["high"]}]}"#)
        let client = ProviderModelCatalogClient(credentials: CatalogCredentials(), transport: transport)
        let provider = provider(
            kind: .compatible,
            endpoint: URL(string: "http://127.0.0.1:1234/v1")!,
            model: "local",
            requiresCredential: false
        )

        _ = try await client.reasoningEffortCapabilities(for: provider)

        let captured = await transport.captured()
        XCTAssertTrue(try XCTUnwrap(captured).localOnly)
    }

    private func catalogClient(json: String) -> ProviderModelCatalogClient {
        ProviderModelCatalogClient(
            credentials: CatalogCredentials(),
            transport: CatalogTransport(json: json)
        )
    }

    private func provider(
        kind: ProviderKind,
        endpoint: URL = URL(string: "https://custom.example/v1")!,
        model: String,
        requiresCredential: Bool = false
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            id: "catalog-test",
            name: "Catalog test",
            kind: kind,
            endpoint: endpoint,
            model: model,
            requiresCredential: requiresCredential
        )
    }
}

private actor CatalogCredentials: CredentialStore {
    private var reads = 0

    func credential(for providerID: String) async throws -> String? {
        reads += 1
        return nil
    }

    func setCredential(_ value: String?, for providerID: String) async throws {}

    func readCount() -> Int { reads }
}

private actor CatalogTransport: StreamingHTTPTransport {
    struct Captured: Sendable {
        let request: URLRequest
        let localOnly: Bool
    }

    private let body: Data
    private var lastRequest: Captured?

    init(json: String) {
        body = Data(json.utf8)
    }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        lastRequest = Captured(request: request, localOnly: localOnly)
        return HTTPExchange(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            }
        )
    }

    func captured() -> Captured? { lastRequest }
}
