import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore

final class ProviderRouterTests: XCTestCase {
    func testPresetProviderAndModelOverrideWithExplicitFallback() throws {
        let router = ProviderRouter(configuration: configuration())
        let preset = Preset(
            id: "polish",
            name: "Polish",
            instruction: "Polish",
            providerID: "router",
            model: "router-model-2",
            fallbackProviderID: "local"
        )

        let route = try router.resolve(preset: preset)
        XCTAssertEqual(route.primary.id, "router")
        XCTAssertEqual(route.primary.model, "router-model-2")
        XCTAssertEqual(route.fallback?.id, "local")
        XCTAssertFalse(route.localOnly)
        let request = route.makeRequest(text: "selected", instruction: "polish")
        XCTAssertEqual(request.provider, route.primary)
        XCTAssertEqual(request.fallbackProvider, route.fallback)
    }

    func testPresetModelOverrideCannotReuseSavedReasoningEffort() throws {
        let endpoint = URL(string: "https://openrouter.ai/api/v1")!
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: "model-1",
            supportedEfforts: ["high", "none"],
            requestFormat: .chatCompletionsObject,
            mandatory: true
        )
        let provider = ProviderConfiguration(
            id: "router",
            name: "Router",
            kind: .openRouter,
            endpoint: endpoint,
            model: "model-1",
            reasoningEffort: "high",
            reasoningEffortCapabilities: capabilities
        )
        let configuration = AppConfiguration(providers: [provider], selectedProviderID: provider.id)
        let route = try ProviderRouter(configuration: configuration).resolve(preset: Preset(
            id: "override-model",
            name: "Override model",
            instruction: "Rewrite",
            providerID: provider.id,
            model: "model-2"
        ))

        XCTAssertEqual(route.primary.model, "model-2")
        XCTAssertNil(route.primary.activeReasoningEffort)
    }

    func testProviderDefaultUnadvertisedEffortAndMandatoryNoneDoNotOverrideDefault() throws {
        let endpoint = URL(string: "https://openrouter.ai/api/v1")!
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: "model-1",
            supportedEfforts: ["high", "none"],
            requestFormat: .chatCompletionsObject,
            mandatory: true
        )

        let defaultProvider = ProviderConfiguration(
            id: "default",
            name: "Default",
            kind: .openRouter,
            endpoint: endpoint,
            model: "model-1",
            reasoningEffortCapabilities: capabilities
        )
        XCTAssertNil(defaultProvider.activeReasoningEffort)

        var unsupportedProvider = defaultProvider
        unsupportedProvider.reasoningEffort = "xhigh"
        XCTAssertNil(unsupportedProvider.activeReasoningEffort)

        var mandatoryProvider = defaultProvider
        mandatoryProvider.reasoningEffort = "none"
        XCTAssertNil(mandatoryProvider.activeReasoningEffort)
    }

    func testReasoningCapabilitiesMustMatchProviderFormat() {
        let endpoint = URL(string: "https://openrouter.ai/api/v1")!
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: "model-1",
            supportedEfforts: ["high"],
            requestFormat: .chatCompletionsField
        )
        let provider = ProviderConfiguration(
            id: "router",
            name: "Router",
            kind: .openRouter,
            endpoint: endpoint,
            model: "model-1",
            reasoningEffort: "high",
            reasoningEffortCapabilities: capabilities
        )

        XCTAssertFalse(capabilities.applies(to: endpoint, model: "model-1", providerKind: .openRouter))
        XCTAssertNil(provider.activeReasoningEffort)
        XCTAssertTrue(capabilities.applies(to: endpoint, model: "model-1", providerKind: .compatible))
    }

    func testLocalOnlyRouteRequiresLocalPrimaryAndSuppressesRemoteFallback() throws {
        let router = ProviderRouter(configuration: configuration())
        XCTAssertThrowsError(try router.resolve(preset: Preset(
            id: "remote",
            name: "Remote",
            instruction: "Rewrite",
            localOnly: true
        ))) {
            XCTAssertEqual($0 as? ImrseError, .localModelUnavailable)
        }
        let route = try router.resolve(preset: Preset(
            id: "unsafe-fallback",
            name: "Unsafe fallback",
            instruction: "Rewrite",
            providerID: "local",
            localOnly: true,
            fallbackProviderID: "router"
        ))
        XCTAssertEqual(route.primary.id, "local")
        XCTAssertNil(route.fallback)
        XCTAssertTrue(route.localOnly)
    }

    func testLoopbackHostsAreStrictlyRecognized() {
        XCTAssertTrue(ProviderRouter.isLoopback(URL(string: "http://localhost:1234/v1")!))
        XCTAssertTrue(ProviderRouter.isLoopback(URL(string: "http://127.12.34.56:1234/v1")!))
        XCTAssertTrue(ProviderRouter.isLoopback(URL(string: "http://[::1]:1234/v1")!))
        XCTAssertFalse(ProviderRouter.isLoopback(URL(string: "http://localhost.example:1234/v1")!))
        XCTAssertFalse(ProviderRouter.isLoopback(URL(string: "http://127.0.0.1.nip.io:1234/v1")!))
        XCTAssertFalse(ProviderRouter.isLoopback(URL(string: "https://api.example.com/v1")!))
    }

    func testEndpointValidationRejectsEmbeddedCredentialsQueriesFragmentsAndRemoteHTTP() {
        for endpoint in [
            "https://user:secret@example.com/v1",
            "https://example.com/v1?token=secret",
            "https://example.com/v1#fragment",
            "http://example.com/v1"
        ] {
            var invalid = configuration()
            invalid.providers[0].endpoint = URL(string: endpoint)!
            XCTAssertThrowsError(try ProviderRouter(configuration: invalid).resolve()) {
                XCTAssertEqual($0 as? ImrseError, .invalidConfiguration)
            }
        }
    }

    func testMissingPrimaryAndUnknownFallbackAreActionable() throws {
        XCTAssertThrowsError(try ProviderRouter(configuration: AppConfiguration()).resolve()) {
            XCTAssertEqual($0 as? ImrseError, .providerUnavailable)
        }

        XCTAssertThrowsError(try ProviderRouter(configuration: configuration()).resolve(preset: Preset(
            id: "missing-fallback",
            name: "Missing fallback",
            instruction: "Rewrite",
            fallbackProviderID: "no-such-provider"
        ))) {
            XCTAssertEqual($0 as? ImrseError, .invalidPreset)
        }
    }

    private func configuration() -> AppConfiguration {
        AppConfiguration(
            providers: [
                ProviderConfiguration(id: "openai", name: "OpenAI", kind: .openAI, endpoint: URL(string: "https://api.openai.com/v1")!, model: "gpt-1"),
                ProviderConfiguration(id: "router", name: "Router", kind: .openRouter, endpoint: URL(string: "https://openrouter.ai/api/v1")!, model: "route-1"),
                ProviderConfiguration(id: "local", name: "Local", kind: .compatible, endpoint: URL(string: "http://127.0.0.1:11434/v1")!, model: "local-1", requiresCredential: false)
            ],
            selectedProviderID: "openai"
        )
    }
}
