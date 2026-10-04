#if os(macOS)
import ImrseCore
import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class OfficialProviderSettingsTests: XCTestCase {
    func testProviderTypeGroupsPreserveExistingRoutes() {
        XCTAssertEqual(ModelProviderChoiceGroup.allCases.map(\.title), ["Local", "Accounts", "API keys", "Custom"])
        XCTAssertEqual(ModelProviderChoiceGroup.local.sections, [.local])
        XCTAssertEqual(
            ModelProviderChoiceGroup.accounts.sections,
            [.chatGPTAccount, .openRouterAccount, .huggingFaceAccount, .githubCopilot]
        )
        XCTAssertEqual(
            ModelProviderChoiceGroup.apiKeys.sections,
            [.openAIAPI, .openRouter, .anthropicAPI, .deepSeekAPI, .geminiAPI, .xAIAPI, .mistralAPI, .togetherAPI, .fireworksAPI, .cerebrasAPI]
        )
        XCTAssertEqual(ModelProviderChoiceGroup.custom.sections, [.custom])
        XCTAssertEqual(ModelProviderChoiceGroup.allCases.flatMap(\.sections), ModelProviderSection.allCases)
    }

    func testNamedAPIChoicesUsePinnedCatalogDestinationsAndExplicitModelIDs() throws {
        let providers: [(ModelProviderSection, String)] = [
            (.deepSeekAPI, "deepseek"),
            (.geminiAPI, "gemini"),
            (.xAIAPI, "xai"),
            (.mistralAPI, "mistral"),
            (.togetherAPI, "together"),
            (.fireworksAPI, "fireworks"),
            (.cerebrasAPI, "cerebras")
        ]

        XCTAssertTrue(ModelProviderSection.anthropicAPI.usesExplicitModelID)
        XCTAssertEqual(ModelProviderSection.anthropicAPI.kind, .anthropic)
        XCTAssertEqual(ModelProviderSection.anthropicAPI.endpoint, URL(string: "https://api.anthropic.com/v1"))
        for (section, id) in providers {
            let descriptor = try XCTUnwrap(OfficialAPIProviderCatalog.descriptors.first { $0.id == id })
            XCTAssertEqual(section.kind, descriptor.kind)
            XCTAssertEqual(section.endpoint, descriptor.endpoint)
            XCTAssertEqual(section.title, section == .xAIAPI ? "Grok / xAI" : descriptor.title)
            XCTAssertEqual(section.listDescription, descriptor.billingDescription)
            XCTAssertTrue(section.usesExplicitModelID)
        }
        XCTAssertFalse(OfficialAPIProviderCatalog.descriptors.contains { $0.id.localizedCaseInsensitiveContains("groq") })
    }
}
#endif
