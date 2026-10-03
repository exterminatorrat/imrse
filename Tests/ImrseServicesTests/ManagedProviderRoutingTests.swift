import Foundation
import ImrseCore
import XCTest
@testable import ImrseServices

final class ManagedProviderRoutingTests: XCTestCase {
    func testManagedLocalSupportsLocalOnlyAndDropsCloudFallback() throws {
        let local = managedLocal()
        let cloud = account()
        let route = try ProviderRouter(configuration: AppConfiguration(
            providers: [local, cloud], selectedProviderID: local.id
        )).resolve(preset: Preset(
            id: "private", name: "Private", instruction: "Rewrite", localOnly: true,
            fallbackProviderID: cloud.id
        ))
        XCTAssertEqual(route.primary, local)
        XCTAssertNil(route.fallback)
        XCTAssertTrue(route.localOnly)
    }

    func testAccountAndManagedTransportDestinationsCannotBeRedirectedByConfiguration() {
        for original in [account(), managedLocal()] {
            var changed = original
            changed.endpoint = URL(string: "https://other.example/v1")!
            XCTAssertThrowsError(try ProviderRouter(configuration: AppConfiguration(
                providers: [changed], selectedProviderID: changed.id
            )).resolve()) { XCTAssertEqual($0 as? ImrseError, .invalidConfiguration) }
            changed = original
            changed.requiresCredential.toggle()
            XCTAssertThrowsError(try ProviderRouter(configuration: AppConfiguration(
                providers: [changed], selectedProviderID: changed.id
            )).resolve()) { XCTAssertEqual($0 as? ImrseError, .invalidConfiguration) }
        }
    }

    func testLocalRequestsNeverReachCompatibleTransportAndNoMissingRuntimeFallback() async throws {
        let compatible = RecordingTransportProvider()
        let dispatcher = ProviderDispatchProvider(compatible: compatible)
        do {
            _ = try await dispatcher.stream(TransformationRequest(text: "test", instruction: "Rewrite", provider: managedLocal()))
            XCTFail("A missing native runtime must not use HTTP")
        } catch {
            XCTAssertEqual(error as? ImrseError, .localModelUnavailable)
        }
        let calls = await compatible.calls
        XCTAssertEqual(calls, 0)
    }

    func testNativeAndAccountProvidersAreDispatchedSeparately() async throws {
        let compatible = RecordingTransportProvider()
        let native = RecordingTransportProvider()
        let authenticated = RecordingTransportProvider()
        let dispatcher = ProviderDispatchProvider(compatible: compatible, account: authenticated, local: native)
        for provider in [managedLocal(), account()] {
            let stream = try await dispatcher.stream(TransformationRequest(text: "test", instruction: "Rewrite", provider: provider))
            for try await _ in stream {}
        }
        let compatibleCalls = await compatible.calls
        let nativeCalls = await native.calls
        let accountCalls = await authenticated.calls
        XCTAssertEqual(compatibleCalls, 0)
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(accountCalls, 1)
    }

    func testAccountRecommendationsRequireActualAccountAvailability() {
        XCTAssertTrue(CuratedModelCatalog.accountRecommendations(availableIDs: []).isEmpty)
        XCTAssertEqual(CuratedModelCatalog.accountRecommendations(availableIDs: ["gpt-6-luna"]).map(\.id), ["gpt-6-luna"])
        for kind in ProviderKind.allCases {
            let choices = CuratedModelCatalog.recommendations(for: kind)
            XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
        }
    }

    func testChatGPTPlanFailureCannotSwitchToRemoteAPIKeyBilling() async throws {
        let chatGPT = account()
        let paid = ProviderConfiguration(id: "paid", name: "API", kind: .openRouter,
                                         endpoint: URL(string: "https://openrouter.ai/api/v1")!, model: "model")
        let route = try ProviderRouter(configuration: AppConfiguration(
            providers: [chatGPT, paid], selectedProviderID: chatGPT.id
        )).resolve(preset: Preset(id: "test", name: "Test", instruction: "Rewrite", fallbackProviderID: paid.id))
        XCTAssertNil(route.fallback)

        let primary = RecordingTransportProvider(error: .network)
        let routed = RoutedTextProvider(primary: primary)
        do {
            let stream = try await routed.stream(TransformationRequest(
                text: "test", instruction: "Rewrite", provider: chatGPT, fallbackProvider: paid
            ))
            for try await _ in stream {}
            XCTFail("The failed plan request must remain a failure")
        } catch {
            XCTAssertEqual(error as? ImrseError, .network)
        }
        let calls = await primary.calls
        XCTAssertEqual(calls, 1)
    }

    private func managedLocal() -> ProviderConfiguration {
        ProviderConfiguration(id: "native", name: "On this Mac", kind: .managedLocal,
                              endpoint: URL(string: "imrse-local://models")!, model: "compact", requiresCredential: false)
    }

    private func account() -> ProviderConfiguration {
        ProviderConfiguration(id: "account", name: "ChatGPT", kind: .openAIChatGPT,
                              endpoint: URL(string: "https://api.openai.com/v1")!, model: "gpt-6-luna")
    }
}

private actor RecordingTransportProvider: TextProvider {
    private(set) var calls = 0
    private let error: ImrseError?

    init(error: ImrseError? = nil) { self.error = error }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        calls += 1
        if let error { throw error }
        return AsyncThrowingStream { $0.yield("result"); $0.finish() }
    }
}
