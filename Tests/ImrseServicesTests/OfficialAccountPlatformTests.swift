#if !canImport(CryptoKit) || !canImport(Security)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImrseCore
@testable import ImrseServices
import XCTest

final class OfficialAccountPlatformTests: XCTestCase {
    func testAuthorizationFailsClosedWithoutRequiredCryptography() async throws {
        let transport = UnusedAccountTransport()
        let client = OfficialAccountClient(credentials: EmptyAccountCredentials(), transport: transport)
        let provider = ProviderConfiguration(
            id: "openrouter-account",
            name: "OpenRouter account",
            kind: .openRouterAccount,
            endpoint: URL(string: "https://openrouter.ai/api/v1")!,
            model: "manual-model"
        )
        do {
            _ = try await client.beginAuthorization(
                for: provider,
                redirectURI: URL(string: "http://127.0.0.1:48321/auth/callback")!
            )
            XCTFail("Authorization requires the cryptographic implementation")
        } catch {
            XCTAssertEqual(error as? OfficialAccountClientError, .cryptographyUnavailable)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests, 0)
    }
}

private actor UnusedAccountTransport: StreamingHTTPTransport {
    private(set) var requests = 0

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        requests += 1
        throw OfficialAccountClientError.networkFailure
    }
}

private struct EmptyAccountCredentials: CredentialStore {
    func credential(for providerID: String) async throws -> String? { nil }
    func setCredential(_ value: String?, for providerID: String) async throws {}
}
#endif
