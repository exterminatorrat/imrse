#if !canImport(Security)
import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAIIDTokenValidatorPlatformTests: XCTestCase, @unchecked Sendable {
    func testIdentityValidationFailsClosedWithoutSecurityCrypto() throws {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "linux-fixture"])
        let payload = Data("{}".utf8)
        let modulus = Data(repeating: 0x01, count: 256)
        let exponent = Data([0x01, 0x00, 0x01])
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA",
            "kid": "linux-fixture",
            "use": "sig",
            "alg": "RS256",
            "n": base64URL(modulus),
            "e": base64URL(exponent)
        ]]])
        let token = [base64URL(header), base64URL(payload), base64URL(Data("fixture-signature".utf8))].joined(separator: ".")

        XCTAssertThrowsError(try OpenAIIDTokenValidator.validate(
            token,
            expectedClientID: "oaiapp_fixture",
            expectedNonce: "nonce-fixture",
            jwks: jwks,
            now: Date()
        )) { error in
            XCTAssertEqual(error as? OpenAIAccountClientError, .cryptographyUnavailable)
        }
    }

    func testSignInFailsBeforeNetworkOrCredentialMutationWithoutSecurityCrypto() async throws {
        let credentials = LinuxCredentialStore()
        let transport = LinuxCountingTransport()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        let redirectURI = URL(string: "http://127.0.0.1:41111/auth/callback")!

        do {
            _ = try await client.prepareSignIn(for: "account", redirectURI: redirectURI)
            XCTFail("Expected cryptographic verification to fail closed")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .cryptographyUnavailable)
        }

        let requests = await transport.requestCount()
        let hostID = try await credentials.credential(for: OpenAIAccountClient.hostIDCredentialKey)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(hostID)
    }
}

private actor LinuxCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    func credential(for providerID: String) async throws -> String? { values[providerID] }
    func setCredential(_ value: String?, for providerID: String) async throws { values[providerID] = value }
}

private actor LinuxCountingTransport: StreamingHTTPTransport {
    private var requests = 0

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        requests += 1
        return HTTPExchange(statusCode: 200, body: AsyncThrowingStream { $0.finish() })
    }

    func requestCount() -> Int { requests }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
#endif
