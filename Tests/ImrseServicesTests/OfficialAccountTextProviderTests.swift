#if canImport(CryptoKit) && canImport(Security)
import Foundation
import ImrseCore
import XCTest
@testable import ImrseServices

final class OfficialAccountTextProviderTests: XCTestCase {
    func testOpenRouterAccountTokenIsSentOnlyToPinnedDestination() async throws {
        let transport = RecordingTransport()
        let accountClient = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        let provider = accountProvider(kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1")
        let redirectURI = URL(string: "http://127.0.0.1:48324/callback")!
        let start = try await accountClient.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        await transport.enqueue(.json(200, ["key": "synthetic-openrouter-key"]))
        _ = try await accountClient.completeAuthorization(
            for: provider,
            callbackURL: callbackURL(redirectURI, state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
        )
        await transport.enqueue(.text(200, """
        data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}

        data: [DONE]

        """))
        let metadata = await MainActor.run { AccountResponseMetadataRecorder() }

        let output = try await collect(
            OfficialAccountTextProvider(accountClient: accountClient, transport: transport),
            request: TransformationRequest(
                text: "selection",
                instruction: "rewrite",
                provider: provider,
                reportResponseMetadata: { metadata.value = $0 }
            )
        )

        XCTAssertEqual(output, "Done")
        let receivedMetadata = await MainActor.run { metadata.value }
        XCTAssertEqual(receivedMetadata?.totalTokens, 6)
        let requests = await transport.requests()
        let inference = try XCTUnwrap(requests.last)
        XCTAssertEqual(inference.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(inference.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-openrouter-key")
    }

    func testHuggingFaceAccountTokenIsSentOnlyToPinnedDestination() async throws {
        let transport = RecordingTransport()
        let accountClient = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        var provider = accountProvider(kind: .huggingFaceAccount, endpoint: "https://router.huggingface.co/v1")
        provider.oauthClientID = "hf-public-client"
        let redirectURI = URL(string: "http://127.0.0.1:48325/callback")!
        let start = try await accountClient.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        await transport.enqueue(.json(200, [
            "access_token": "synthetic-hf-token",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile inference-api"
        ]))
        await transport.enqueue(.json(200, ["preferred_username": "synthetic-user"]))
        _ = try await accountClient.completeAuthorization(
            for: provider,
            callbackURL: callbackURL(redirectURI, state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
        )
        await transport.enqueue(.text(200, """
        data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}

        data: [DONE]

        """))

        let output = try await collect(
            OfficialAccountTextProvider(accountClient: accountClient, transport: transport),
            request: TransformationRequest(text: "selection", instruction: "rewrite", provider: provider)
        )

        XCTAssertEqual(output, "Done")
        let requests = await transport.requests()
        let inference = try XCTUnwrap(requests.last)
        XCTAssertEqual(inference.url?.absoluteString, "https://router.huggingface.co/v1/chat/completions")
        XCTAssertEqual(inference.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-hf-token")
    }

    func testAccountTextProviderRejectsLocalOnlyAndUnpinnedEndpointsBeforeTokenLookup() async throws {
        let transport = RecordingTransport()
        let accountClient = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        let invalidProvider = accountProvider(kind: .openRouterAccount, endpoint: "https://router.huggingface.co/v1")
        let textProvider = OfficialAccountTextProvider(accountClient: accountClient, transport: transport)

        do {
            _ = try await textProvider.stream(
                TransformationRequest(text: "selection", instruction: "rewrite", provider: invalidProvider)
            )
            XCTFail("Expected a destination validation failure")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .invalidConfiguration)
        }

        let localProvider = accountProvider(kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1")
        do {
            _ = try await textProvider.stream(
                TransformationRequest(text: "selection", instruction: "rewrite", provider: localProvider, localOnly: true)
            )
            XCTFail("Expected local-only rejection")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .providerUnavailable)
        }

        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testAccountTextProviderMapsMissingCredentialsAndClientConfigurationErrors() async throws {
        let transport = RecordingTransport()
        let requestProvider = accountProvider(kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1")
        let missingCredentialsClient = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        let missingCredentialsProvider = OfficialAccountTextProvider(accountClient: missingCredentialsClient, transport: transport)
        await assertStreamError(
            .accountNotConnected,
            provider: missingCredentialsProvider,
            request: TransformationRequest(text: "selection", instruction: "rewrite", provider: requestProvider)
        )

        let missingClientProviderConfiguration = accountProvider(
            kind: .huggingFaceAccount,
            endpoint: "https://router.huggingface.co/v1"
        )
        let missingClient = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        await assertStreamError(
            .invalidConfiguration,
            provider: OfficialAccountTextProvider(accountClient: missingClient, transport: transport),
            request: TransformationRequest(text: "selection", instruction: "rewrite", provider: missingClientProviderConfiguration)
        )
    }

    func testAccountTextProviderMapsExpiredSessionsAndClientMismatchToAuthentication() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let openRouter = accountProvider(kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1")
        let expiredCredentials = MemoryCredentials()
        try await storeSession(
            for: openRouter,
            clientID: nil,
            refreshToken: nil,
            expiresAt: now.addingTimeInterval(-1),
            in: expiredCredentials
        )
        let expiredClient = OfficialAccountClient(
            credentials: expiredCredentials,
            transport: RecordingTransport(),
            now: { now },
            sleep: { _ in }
        )
        await assertStreamError(
            .accountAuthentication,
            provider: OfficialAccountTextProvider(accountClient: expiredClient),
            request: TransformationRequest(text: "selection", instruction: "rewrite", provider: openRouter)
        )

        var huggingFace = accountProvider(kind: .huggingFaceAccount, endpoint: "https://router.huggingface.co/v1")
        huggingFace.oauthClientID = "hf-public-client"
        let mismatchedCredentials = MemoryCredentials()
        try await storeSession(
            for: huggingFace,
            clientID: "another-public-client",
            refreshToken: "synthetic-refresh",
            expiresAt: now.addingTimeInterval(3_600),
            in: mismatchedCredentials
        )
        let mismatchedClient = OfficialAccountClient(credentials: mismatchedCredentials, transport: RecordingTransport())
        await assertStreamError(
            .accountAuthentication,
            provider: OfficialAccountTextProvider(accountClient: mismatchedClient),
            request: TransformationRequest(text: "selection", instruction: "rewrite", provider: huggingFace)
        )
    }

    func testAccountTextProviderMapsMalformedOversizedNetworkAndCancelledRefreshFailures() async throws {
        let malformed = try await huggingFaceRefreshError(.reply(.text(200, "not-json")))
        XCTAssertEqual(malformed, .malformedResponse)

        let missingScope = try await huggingFaceRefreshError(.reply(.json(200, [
            "access_token": "synthetic-refreshed-token",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile"
        ])))
        XCTAssertEqual(missingScope, .accountAuthentication)

        let oversized = try await huggingFaceRefreshError(.reply(.text(200, String(repeating: "x", count: 65_537))))
        XCTAssertEqual(oversized, .outputTooLarge)

        let network = try await huggingFaceRefreshError(.network)
        XCTAssertEqual(network, .network)

        let cancelled = try await huggingFaceRefreshError(.cancelled)
        XCTAssertEqual(cancelled, .cancelled)

        let invalidGrant = try await huggingFaceRefreshError(.reply(.json(400, ["error": "invalid_grant"])))
        XCTAssertEqual(invalidGrant, .accountAuthentication)

        let invalidClient = try await huggingFaceRefreshError(.reply(.json(400, ["error": "invalid_client"])))
        XCTAssertEqual(invalidClient, .invalidConfiguration)

        let requestFailed = try await huggingFaceRefreshError(.reply(.json(500, ["error": "server_error"])))
        XCTAssertEqual(requestFailed, .server)
    }

    func testAccountTextProviderProcessesTrailingErrorAfterStopBeforeDone() async throws {
        let transport = RecordingTransport()
        let accountClient = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        let provider = accountProvider(kind: .openRouterAccount, endpoint: "https://openrouter.ai/api/v1")
        let redirectURI = URL(string: "http://127.0.0.1:48326/callback")!
        let start = try await accountClient.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        await transport.enqueue(.json(200, ["key": "synthetic-openrouter-key"]))
        _ = try await accountClient.completeAuthorization(
            for: provider,
            callbackURL: callbackURL(redirectURI, state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
        )
        await transport.enqueue(.text(200, """
        data: {"choices":[{"delta":{"content":"Partial"},"finish_reason":"stop"}]}

        data: {"error":{"code":"late_error"}}

        data: [DONE]

        """))

        do {
            _ = try await collect(
                OfficialAccountTextProvider(accountClient: accountClient, transport: transport),
                request: TransformationRequest(text: "selection", instruction: "rewrite", provider: provider)
            )
            XCTFail("Expected trailing stream error")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .server)
        }
    }
}

private func accountProvider(kind: ProviderKind, endpoint: String) -> ProviderConfiguration {
    ProviderConfiguration(
        id: "openrouter-test",
        name: "OpenRouter account",
        kind: kind,
        endpoint: URL(string: endpoint)!,
        model: "fixture/model"
    )
}

private func callbackURL(_ redirectURI: URL, state: String) -> URL {
    var components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"), URLQueryItem(name: "state", value: state)]
    return components.url!
}

private func queryParameters(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private actor MemoryCredentials: CredentialStore {
    private var values: [String: String] = [:]
    func credential(for providerID: String) async throws -> String? { values[providerID] }
    func setCredential(_ value: String?, for providerID: String) async throws { values[providerID] = value }
}

@MainActor
private final class AccountResponseMetadataRecorder {
    var value: ResponseMetadata?
}

private struct AccountSessionFixture: Codable {
    let providerID: String
    let kind: String
    let clientID: String?
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let accountLabel: String?
    let scopes: [String]
}

private enum RefreshTransportResult {
    case reply(Reply)
    case network
    case cancelled
}

private func storeSession(
    for provider: ProviderConfiguration,
    clientID: String?,
    refreshToken: String?,
    expiresAt: Date?,
    in credentials: MemoryCredentials
) async throws {
    let session = AccountSessionFixture(
        providerID: provider.id,
        kind: provider.kind.rawValue,
        clientID: clientID,
        accessToken: "synthetic-access-token",
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        accountLabel: "synthetic-user",
        scopes: provider.kind == .huggingFaceAccount ? ["inference-api", "openid", "profile"] : []
    )
    let data = try JSONEncoder().encode(session)
    try await credentials.setCredential(
        String(decoding: data, as: UTF8.self),
        for: "oauth:\(provider.kind.rawValue):\(provider.id)"
    )
}

private func huggingFaceRefreshError(_ result: RefreshTransportResult) async throws -> ImrseError? {
    let now = Date(timeIntervalSince1970: 1_000)
    var provider = accountProvider(kind: .huggingFaceAccount, endpoint: "https://router.huggingface.co/v1")
    provider.oauthClientID = "hf-public-client"
    let credentials = MemoryCredentials()
    try await storeSession(
        for: provider,
        clientID: provider.oauthClientID,
        refreshToken: "synthetic-refresh-token",
        expiresAt: now.addingTimeInterval(-1),
        in: credentials
    )

    let transport: any StreamingHTTPTransport
    switch result {
    case let .reply(reply):
        let recording = RecordingTransport()
        await recording.enqueue(reply)
        transport = recording
    case .network:
        transport = FailureTransport(cancelled: false)
    case .cancelled:
        transport = FailureTransport(cancelled: true)
    }
    let client = OfficialAccountClient(credentials: credentials, transport: transport, now: { now }, sleep: { _ in })
    let textProvider = OfficialAccountTextProvider(accountClient: client, transport: transport)
    do {
        _ = try await textProvider.stream(
            TransformationRequest(text: "selection", instruction: "rewrite", provider: provider)
        )
        return nil
    } catch let error as ImrseError {
        return error
    } catch {
        return nil
    }
}

private func assertStreamError(
    _ expected: ImrseError,
    provider: OfficialAccountTextProvider,
    request: TransformationRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await provider.stream(request)
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ImrseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private struct Reply: Sendable {
    let status: Int
    let body: Data
    let contentType: String

    static func json(_ status: Int, _ object: [String: Any]) -> Self {
        Self(status: status, body: try! JSONSerialization.data(withJSONObject: object), contentType: "application/json")
    }

    static func text(_ status: Int, _ value: String) -> Self {
        Self(status: status, body: Data(value.utf8), contentType: "text/event-stream")
    }

    var exchange: HTTPExchange {
        HTTPExchange(
            statusCode: status,
            headers: ["content-type": contentType],
            body: AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            }
        )
    }
}

private actor RecordingTransport: StreamingHTTPTransport {
    private var replies: [Reply] = []
    private var capturedRequests: [URLRequest] = []
    func enqueue(_ reply: Reply) { replies.append(reply) }
    func requests() -> [URLRequest] { capturedRequests }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        capturedRequests.append(request)
        guard !replies.isEmpty else { throw CancellationError() }
        return replies.removeFirst().exchange
    }
}

private struct FailureTransport: StreamingHTTPTransport {
    let cancelled: Bool

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        if cancelled { throw CancellationError() }
        throw URLError(.notConnectedToInternet)
    }
}

private func collect(_ provider: OfficialAccountTextProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var output = ""
    for try await piece in stream { output += piece }
    return output
}
#endif
