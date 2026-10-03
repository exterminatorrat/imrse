#if os(macOS)
import ImrseCore
import XCTest
@testable import ImrseApp

@MainActor
final class ProviderSettingsPresentationTests: XCTestCase {
    func testAddProviderOptionsIncludeEverySupportedContext() {
        XCTAssertEqual(
            ModelProviderSection.allCases,
            [.local, .chatGPTAccount, .openAIAPI, .openRouter, .custom]
        )
    }

    func testEditorAndListKeepTheActualProviderStringID() {
        let provider = ProviderConfiguration(
            id: "saved-api-provider",
            name: "OpenAI",
            kind: .openAI,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-test"
        )

        XCTAssertEqual(ProviderListPresentation(provider: provider).id, provider.id)
        XCTAssertEqual(ProviderEditorMode.edit(provider.id).id, "provider:\(provider.id)")
    }

    func testChatGPTSettingsRejectAnotherStoredAccountIdentity() {
        XCTAssertFalse(ChatGPTAccountSettingsPane.isUnsupportedProviderIdentity(
            providerID: nil,
            managedProviderID: "managed-chatgpt"
        ))
        XCTAssertFalse(ChatGPTAccountSettingsPane.isUnsupportedProviderIdentity(
            providerID: "managed-chatgpt",
            managedProviderID: "managed-chatgpt"
        ))
        XCTAssertTrue(ChatGPTAccountSettingsPane.isUnsupportedProviderIdentity(
            providerID: "second-chatgpt-account",
            managedProviderID: "managed-chatgpt"
        ))
    }

    func testLocalDefaultRequiresTheSelectedProviderIdentity() {
        let provider = ProviderConfiguration(
            id: "local-two",
            name: "Local second",
            kind: .managedLocal,
            endpoint: URL(string: "imrse-local://models")!,
            model: "same-model",
            requiresCredential: false
        )

        XCTAssertFalse(LocalModelSettingsPane.isDefaultProvider(
            selectedProviderID: "local-one",
            configuredProvider: provider,
            selectedModelID: "same-model"
        ))
        XCTAssertTrue(LocalModelSettingsPane.isDefaultProvider(
            selectedProviderID: provider.id,
            configuredProvider: provider,
            selectedModelID: "same-model"
        ))
    }

    func testProviderSummariesKeepChatGPTAndAPIKeyBillingDistinct() {
        let endpoint = URL(string: "https://api.openai.com/v1")!
        let chatGPT = ProviderConfiguration(
            id: "chatgpt-account",
            name: "ChatGPT account",
            kind: .openAIChatGPT,
            endpoint: endpoint,
            model: "chatgpt-model"
        )
        let apiKey = ProviderConfiguration(
            id: "openai-api-key",
            name: "OpenAI API",
            kind: .openAI,
            endpoint: endpoint,
            model: "api-model"
        )

        let chatGPTDetail = ProviderListPresentation(provider: chatGPT).detail
        let apiKeyDetail = ProviderListPresentation(provider: apiKey).detail

        XCTAssertTrue(chatGPTDetail.contains("Plan billing"))
        XCTAssertTrue(chatGPTDetail.contains("separate from OpenAI API"))
        XCTAssertTrue(apiKeyDetail.contains("Billed by OpenAI API usage"))
        XCTAssertNotEqual(chatGPTDetail, apiKeyDetail)
    }

    func testCustomProviderSummaryShowsHostWithoutEndpointQuery() {
        let provider = ProviderConfiguration(
            id: "custom-provider",
            name: "Private endpoint",
            kind: .compatible,
            endpoint: URL(string: "https://custom.example/v1?token=fixture-value")!,
            model: "custom-model"
        )

        let detail = ProviderListPresentation(provider: provider).detail

        XCTAssertTrue(detail.contains("custom.example"))
        XCTAssertFalse(detail.contains("fixture-value"))
    }
}
#endif
