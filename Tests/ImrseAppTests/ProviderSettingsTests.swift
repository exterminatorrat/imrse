#if os(macOS)
import ImrseCore
import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class ProviderSettingsTests: XCTestCase {
    func testProviderBrowserSeparatesChatGPTAccountFromAPIKeyBilling() {
        let endpoint = URL(string: "https://api.openai.com/v1")!
        let apiKeyProvider = provider(kind: .openAI, endpoint: endpoint)
        let accountProvider = provider(kind: .openAIChatGPT, endpoint: endpoint)

        XCTAssertEqual(ModelProviderSection.forProvider(apiKeyProvider), .openAIAPI)
        XCTAssertEqual(ModelProviderSection.forProvider(accountProvider), .chatGPTAccount)
        XCTAssertEqual(apiKeyProvider.endpoint, accountProvider.endpoint)
        XCTAssertNotEqual(apiKeyProvider.kind, accountProvider.kind)
    }

    func testProviderBrowserKeepsCustomAndLegacyEndpointsInAdvancedSection() {
        let legacyOpenAI = provider(kind: .openAI, endpoint: URL(string: "https://legacy.example/v1")!)
        let legacyOpenRouter = provider(kind: .openRouter, endpoint: URL(string: "https://legacy-router.example/v1")!)
        let compatible = provider(kind: .compatible, endpoint: URL(string: "https://private.example/v1")!)

        XCTAssertEqual(ModelProviderSection.forProvider(legacyOpenAI), .custom)
        XCTAssertEqual(ModelProviderSection.forProvider(legacyOpenRouter), .custom)
        XCTAssertEqual(ModelProviderSection.forProvider(compatible), .custom)
    }

    func testAccountRecommendationsOnlyIncludeModelsAdvertisedByAccount() {
        let recommendations = CuratedModelCatalog.recommendations(for: .openAIChatGPT)
        XCTAssertFalse(recommendations.isEmpty)
        XCTAssertEqual(
            CuratedModelCatalog.accountRecommendations(availableIDs: [recommendations[0].id]),
            [recommendations[0]]
        )
        XCTAssertTrue(CuratedModelCatalog.accountRecommendations(availableIDs: []).isEmpty)
    }

    func testProviderBrowserKeepsEndpointsDistinctByProviderType() {
        XCTAssertEqual(ModelProviderSection.local.endpoint, URL(string: "imrse-local://models"))
        XCTAssertEqual(ModelProviderSection.chatGPTAccount.endpoint, URL(string: "https://api.openai.com/v1"))
        XCTAssertEqual(ModelProviderSection.openAIAPI.endpoint, URL(string: "https://api.openai.com/v1"))
        XCTAssertEqual(ModelProviderSection.openRouter.endpoint, URL(string: "https://openrouter.ai/api/v1"))
        XCTAssertNotEqual(ModelProviderSection.chatGPTAccount.kind, ModelProviderSection.openAIAPI.kind)
    }

    func testGeneratedProviderIDSkipsExistingIDsWithoutReplacingTheirProviders() {
        let candidate = "imrse-chatgpt"
        let existing = [
            ProviderConfiguration(id: candidate, name: "Saved provider", kind: .compatible, endpoint: URL(string: "https://example.com/v1")!, model: "saved-model"),
            ProviderConfiguration(id: "\(candidate)-2", name: "Another saved provider", kind: .compatible, endpoint: URL(string: "https://another.example/v1")!, model: "another-model")
        ]

        XCTAssertEqual(AppModel.uniqueProviderID(candidate: candidate, existingProviders: existing), "\(candidate)-3")
        XCTAssertEqual(existing.map(\.id), [candidate, "\(candidate)-2"])
    }

    private func provider(kind: ProviderKind, endpoint: URL) -> ProviderConfiguration {
        ProviderConfiguration(
            id: "test-\(kind.rawValue)-\(UUID().uuidString)",
            name: "Test provider",
            kind: kind,
            endpoint: endpoint,
            model: "test-model"
        )
    }
}
#endif
