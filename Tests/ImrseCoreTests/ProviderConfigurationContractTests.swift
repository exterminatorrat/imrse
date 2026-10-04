import Foundation
import XCTest
@testable import ImrseCore

final class ProviderConfigurationContractTests: XCTestCase {
    func testProviderKindsRoundTripWithStableCodableValues() throws {
        let kinds: [ProviderKind] = [
            .openAI, .openAIChatGPT, .openRouter, .managedLocal, .compatible,
            .anthropic, .openRouterAccount, .huggingFaceAccount, .githubCopilot
        ]

        for kind in kinds {
            let encoded = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(ProviderKind.self, from: encoded), kind)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(kind.rawValue)\"")
        }
        XCTAssertEqual(Set(ProviderKind.allCases.map(\.rawValue)), Set(kinds.map(\.rawValue)))
    }

    func testOAuthClientIDIsOptionalAndCodableWithoutBreakingVersionOneProviderFiles() throws {
        let legacy = Data(#"{"id":"account","name":"Account","kind":"huggingFaceAccount","endpoint":"https://router.huggingface.co/v1","model":"custom-model","requiresCredential":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: legacy)
        XCTAssertNil(decoded.oauthClientID)

        var configured = decoded
        configured.oauthClientID = "public-client-id"
        let encoded = try JSONEncoder().encode(configured)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["oauthClientID"] as? String, "public-client-id")
        XCTAssertEqual(try JSONDecoder().decode(ProviderConfiguration.self, from: encoded), configured)
    }
}
