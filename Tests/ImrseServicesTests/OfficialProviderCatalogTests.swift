import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OfficialProviderCatalogTests: XCTestCase {
    func testOfficialAPICatalogUsesDocumentedEndpointsAndAPIKeyBillingCopy() {
        let expected: [(String, String, String)] = [
            ("deepseek", "DeepSeek", "https://api.deepseek.com"),
            ("gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
            ("xai", "xAI", "https://api.x.ai/v1"),
            ("mistral", "Mistral", "https://api.mistral.ai/v1"),
            ("together", "Together AI", "https://api.together.ai/v1"),
            ("fireworks", "Fireworks AI", "https://api.fireworks.ai/inference/v1"),
            ("cerebras", "Cerebras", "https://api.cerebras.ai/v1")
        ]

        XCTAssertEqual(OfficialAPIProviderCatalog.descriptors.map(\.id), expected.map { $0.0 })
        for (descriptor, value) in zip(OfficialAPIProviderCatalog.descriptors, expected) {
            XCTAssertEqual(descriptor.title, value.1)
            XCTAssertEqual(descriptor.endpoint, URL(string: value.2))
            XCTAssertEqual(descriptor.kind, .compatible)
            XCTAssertTrue(descriptor.billingDescription.localizedCaseInsensitiveContains("API key"))
            XCTAssertFalse(descriptor.billingDescription.localizedCaseInsensitiveContains("subscription included"))
        }
        XCTAssertFalse(OfficialAPIProviderCatalog.descriptors.contains { $0.id.localizedCaseInsensitiveContains("groq") })
    }

    func testManualModelIDsRemainValidForNamedCompatibleEndpoints() throws {
        let descriptor = try XCTUnwrap(OfficialAPIProviderCatalog.descriptors.first { $0.id == "deepseek" })
        let provider = ProviderConfiguration(
            id: descriptor.id,
            name: descriptor.title,
            kind: descriptor.kind,
            endpoint: descriptor.endpoint,
            model: "user-selected/model-id"
        )

        XCTAssertNoThrow(try ProviderValidation.validate(provider))
        XCTAssertTrue(CuratedModelCatalog.recommendations(for: descriptor.kind).isEmpty)
    }

    func testNamedAPIProvidersUseTheirPinnedChatCompletionsEndpoints() async throws {
        let expectedURLs = [
            "https://api.deepseek.com/chat/completions",
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            "https://api.x.ai/v1/chat/completions",
            "https://api.mistral.ai/v1/chat/completions",
            "https://api.together.ai/v1/chat/completions",
            "https://api.fireworks.ai/inference/v1/chat/completions",
            "https://api.cerebras.ai/v1/chat/completions"
        ]
        for (descriptor, expectedURL) in zip(OfficialAPIProviderCatalog.descriptors, expectedURLs) {
            let transport = URLCaptureTransport()
            let provider = OpenAICompatibleProvider(credentials: CountingCredentials(), transport: transport)
            let request = TransformationRequest(
                text: "selected",
                instruction: "rewrite",
                provider: ProviderConfiguration(
                    id: descriptor.id,
                    name: descriptor.title,
                    kind: descriptor.kind,
                    endpoint: descriptor.endpoint,
                    model: "user-selected/model-id"
                )
            )

            _ = try await collect(provider, request: request)
            let url = await transport.url()
            XCTAssertEqual(url?.absoluteString, expectedURL)
        }
    }

    func testOfficialAndAccountProviderDestinationsArePinned() {
        let validProviders: [ProviderConfiguration] = [
            provider(id: "anthropic", kind: .anthropic, endpoint: "https://api.anthropic.com/v1"),
            provider(id: "openrouter-account", kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1"),
            provider(id: "hf-account", kind: .huggingFaceAccount, endpoint: "https://router.huggingface.co/v1", oauthClientID: "hf-public-client"),
            provider(id: "copilot", kind: .githubCopilot, endpoint: "https://api.githubcopilot.com", oauthClientID: "github-public-client")
        ]
        for provider in validProviders {
            XCTAssertNoThrow(try ProviderValidation.validate(provider), "\(provider.kind)")
        }

        let invalidProviders: [ProviderConfiguration] = [
            provider(id: "anthropic", kind: .anthropic, endpoint: "https://custom.example/v1"),
            provider(id: "openrouter-account", kind: .openRouterAccount, endpoint: "https://custom.example/v1"),
            provider(id: "hf-account", kind: .huggingFaceAccount, endpoint: "https://custom.example/v1"),
            provider(id: "copilot", kind: .githubCopilot, endpoint: "https://api.githubcopilot.com/v1"),
            provider(id: "openrouter-account", kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1", oauthClientID: "not-supported"),
            provider(id: "compatible", kind: .compatible, endpoint: "https://api.example.com/v1", oauthClientID: "not-an-api-key")
        ]
        for provider in invalidProviders {
            XCTAssertThrowsError(try ProviderValidation.validate(provider), "\(provider.kind)") {
                XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
            }
        }
    }

    func testOptionalClientIDUsesARestrictedPlaintextIdentifierField() {
        for clientID in ["", "contains space ", "line\nbreak", String(repeating: "a", count: 257)] {
            let provider = self.provider(
                id: "hf-account",
                kind: .huggingFaceAccount,
                endpoint: "https://router.huggingface.co/v1",
                oauthClientID: clientID
            )
            XCTAssertThrowsError(try ProviderValidation.validate(provider)) {
                XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
            }
        }
    }

    func testAPIKeyTransportRejectsAccountKindsBeforeReadingCredentials() async {
        let credentials = CountingCredentials()
        let provider = OpenAICompatibleProvider(credentials: credentials, transport: UnusedTransport())
        let request = TransformationRequest(
            text: "selected",
            instruction: "rewrite",
            provider: ProviderConfiguration(
                id: "hf-account",
                name: "Hugging Face account",
                kind: .huggingFaceAccount,
                endpoint: URL(string: "https://router.huggingface.co/v1")!,
                model: "manual-model-id"
            )
        )

        do {
            _ = try await provider.stream(request)
            XCTFail("Account credentials must not pass through the API-key transport")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .invalidConfiguration)
        } catch {
            XCTFail("Expected invalid configuration, received \(error)")
        }
        let calls = await credentials.calls()
        XCTAssertEqual(calls, 0)
    }

    func testModelCatalogDoesNotReadOAuthAccountCredentials() async throws {
        let credentials = CountingCredentials()
        let transport = URLCaptureTransport()
        let client = ProviderModelCatalogClient(credentials: credentials, transport: transport)
        for provider in [
            provider(id: "hf-account", kind: .huggingFaceAccount, endpoint: "https://router.huggingface.co/v1"),
            provider(id: "copilot", kind: .githubCopilot, endpoint: "https://api.githubcopilot.com")
        ] {
            let capabilities = try await client.reasoningEffortCapabilities(for: provider)
            XCTAssertNil(capabilities)
        }
        let credentialReads = await credentials.calls()
        let requestedURL = await transport.url()
        XCTAssertEqual(credentialReads, 0)
        XCTAssertNil(requestedURL)
    }

    func testOfficialModelCatalogUsesDeepSeekPathAndSkipsUndocumentedGeminiListing() async throws {
        let deepSeek = try XCTUnwrap(OfficialAPIProviderCatalog.descriptors.first { $0.id == "deepseek" })
        let deepSeekTransport = URLCaptureTransport()
        let deepSeekClient = ProviderModelCatalogClient(credentials: CountingCredentials(), transport: deepSeekTransport)
        let deepSeekProvider = ProviderConfiguration(
            id: deepSeek.id,
            name: deepSeek.title,
            kind: deepSeek.kind,
            endpoint: deepSeek.endpoint,
            model: "user-selected/model-id"
        )
        _ = try await deepSeekClient.reasoningEffortCapabilities(for: deepSeekProvider)
        let deepSeekURL = await deepSeekTransport.url()
        XCTAssertEqual(deepSeekURL?.absoluteString, "https://api.deepseek.com/models")

        let gemini = try XCTUnwrap(OfficialAPIProviderCatalog.descriptors.first { $0.id == "gemini" })
        let credentials = CountingCredentials()
        let geminiTransport = URLCaptureTransport()
        let geminiClient = ProviderModelCatalogClient(credentials: credentials, transport: geminiTransport)
        let geminiProvider = ProviderConfiguration(
            id: gemini.id,
            name: gemini.title,
            kind: gemini.kind,
            endpoint: gemini.endpoint,
            model: "user-selected/model-id"
        )
        let capabilities = try await geminiClient.reasoningEffortCapabilities(for: geminiProvider)
        let credentialReads = await credentials.calls()
        let geminiURL = await geminiTransport.url()
        XCTAssertNil(capabilities)
        XCTAssertEqual(credentialReads, 0)
        XCTAssertNil(geminiURL)
    }

    func testConfigurationStoreAllowsTokenFreeClientIDAndRejectsUnknownCredentialFields() throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(root: directory.url)
        let account = provider(
            id: "hf-account",
            kind: .huggingFaceAccount,
            endpoint: "https://router.huggingface.co/v1",
            oauthClientID: "public-client-id"
        )
        try store.save(AppConfiguration(providers: [account], selectedProviderID: account.id))
        XCTAssertEqual(try store.load().providers, [account])

        let file = directory.url.appending(path: "config.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertEqual(providers[0]["oauthClientID"] as? String, "public-client-id")
        providers[0]["oauthAccessToken"] = "must-not-be-stored-here"
        object["providers"] = providers
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
        }
    }

    private func provider(
        id: String,
        kind: ProviderKind,
        endpoint: String,
        oauthClientID: String? = nil
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            id: id,
            name: id,
            kind: kind,
            endpoint: URL(string: endpoint)!,
            model: "manual-model-id",
            oauthClientID: oauthClientID
        )
    }
}

private actor CountingCredentials: CredentialStore {
    private var readCount = 0
    func credential(for providerID: String) async throws -> String? {
        readCount += 1
        return "unexpected"
    }
    func setCredential(_ value: String?, for providerID: String) async throws {}
    func calls() -> Int { readCount }
}

private struct UnusedTransport: StreamingHTTPTransport {
    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        throw ImrseError.network
    }
}

private struct URLCaptureTransport: StreamingHTTPTransport {
    private let capturedURL = CapturedURL()
    private let body = Data(#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#.appending("\n\n").utf8)

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        await capturedURL.set(request.url)
        return HTTPExchange(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(body)
            continuation.finish()
        })
    }

    func url() async -> URL? { await capturedURL.get() }
}

private actor CapturedURL {
    private var value: URL?
    func set(_ url: URL?) { value = url }
    func get() -> URL? { value }
}

private func collect(_ provider: any TextProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var output = ""
    for try await delta in stream { output += delta }
    return output
}

private struct TestDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
