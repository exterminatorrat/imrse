#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Foundation
import ImrseCore
@testable import ImrseServices
import XCTest

final class OfficialAccountClientTests: XCTestCase {
    func testOpenRouterPKCEStoresIssuedKeyOnlyInNamespacedCredentialAndDisconnects() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OfficialAccountClient(credentials: credentials, transport: transport)
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let redirectURI = URL(string: "http://127.0.0.1:48321/oauth/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, returnedRedirectURI, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        let authorization = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(uniqueKeysWithValues: (authorization.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(authorization.host, "openrouter.ai")
        XCTAssertEqual(authorization.path, "/auth")
        XCTAssertEqual(returnedRedirectURI, redirectURI)
        XCTAssertEqual(parameters["callback_url"], redirectURI.absoluteString)
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
        XCTAssertEqual(parameters["state"]?.count, 43)

        await transport.enqueue(.json(200, ["key": "synthetic-openrouter-key"]))
        let status = try await client.completeAuthorization(
            for: provider,
            callbackURL: callbackURL(redirectURI, code: "synthetic-code", state: try XCTUnwrap(parameters["state"]))
        )

        XCTAssertTrue(status.isConnected)
        XCTAssertNil(status.accountLabel)
        let requests = await transport.requests()
        let exchange = try XCTUnwrap(requests.first)
        XCTAssertEqual(exchange.url?.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
        let exchangeBody = try XCTUnwrap(exchange.httpBody)
        let exchangeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: exchangeBody) as? [String: String])
        XCTAssertEqual(exchangeJSON["code"], "synthetic-code")
        XCTAssertEqual(exchangeJSON["code_challenge_method"], "S256")
        let verifier = try XCTUnwrap(exchangeJSON["code_verifier"])
        let digest = SHA256.hash(data: Data(verifier.utf8))
        XCTAssertEqual(parameters["code_challenge"], Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
        let accessToken = try await client.accessToken(for: provider)
        XCTAssertEqual(accessToken.token, "synthetic-openrouter-key")
        XCTAssertNil(accessToken.expiresAt)
        let ordinaryCredential = try await credentials.credential(for: provider.id)
        let namespacedCredential = try await credentials.credential(for: "oauth:openRouterAccount:openrouter")
        XCTAssertNil(ordinaryCredential)
        XCTAssertNotNil(namespacedCredential)

        try await client.disconnect(for: provider)

        let deletedCredential = try await credentials.credential(for: "oauth:openRouterAccount:openrouter")
        let disconnected = try await client.connectionStatus(for: provider)
        XCTAssertNil(deletedCredential)
        XCTAssertFalse(disconnected.isConnected)
    }

    func testCallbackMustMatchLoopbackPortPathAndStateBeforeExchangingCode() async throws {
        let transport = ScriptedTransport()
        let client = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let redirectURI = URL(string: "http://localhost:48110/account/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        let state = try XCTUnwrap(queryParameters(authorizationURL)["state"])

        do {
            _ = try await client.completeAuthorization(
                for: provider,
                callbackURL: callbackURL(URL(string: "http://localhost:48111/account/callback")!, code: "code", state: state)
            )
            XCTFail("Expected callback port mismatch")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .invalidCallback)
        }

        do {
            _ = try await client.completeAuthorization(
                for: provider,
                callbackURL: callbackURL(redirectURI, code: "code", state: "wrong-state")
            )
            XCTFail("Expected state mismatch")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .stateMismatch)
        }

        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testHuggingFaceRequestsMinimalInferenceScopesRefreshesRotatedTokenAndLoadsIdentity() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let client = OfficialAccountClient(
            credentials: credentials,
            transport: transport,
            now: { fixedNow },
            sleep: { _ in }
        )
        let provider = accountProvider(.huggingFaceAccount, id: "hf", clientID: "hf-public-client")
        let redirectURI = URL(string: "http://127.0.0.1:49231/oauth/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        let authorization = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(uniqueKeysWithValues: (authorization.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(authorization.host, "huggingface.co")
        XCTAssertEqual(authorization.path, "/oauth/authorize")
        XCTAssertEqual(parameters["client_id"], "hf-public-client")
        XCTAssertEqual(Set(parameters["scope", default: ""].split(separator: " ").map(String.init)), ["inference-api", "openid", "profile"])
        XCTAssertEqual(parameters["code_challenge_method"], "S256")

        await transport.enqueue(.json(200, [
            "access_token": "synthetic-hf-expired-token",
            "refresh_token": "synthetic-hf-refresh",
            "token_type": "Bearer",
            "expires_in": 1,
            "scope": "openid profile inference-api"
        ]))
        await transport.enqueue(.json(200, ["preferred_username": "synthetic-user", "name": "Synthetic User"]))
        let status = try await client.completeAuthorization(
            for: provider,
            callbackURL: callbackURL(redirectURI, code: "hf-code", state: try XCTUnwrap(parameters["state"]))
        )

        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.accountLabel, "synthetic-user")
        await transport.enqueue(.json(200, [
            "access_token": "synthetic-hf-refreshed-token",
            "refresh_token": "synthetic-hf-rotated-refresh",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile inference-api"
        ]))

        let accessToken = try await client.accessToken(for: provider)

        XCTAssertEqual(accessToken.token, "synthetic-hf-refreshed-token")
        XCTAssertEqual(accessToken.expiresAt, Date(timeIntervalSince1970: 4_600))
        let requests = await transport.requests()
        let tokenRequests = requests.filter { $0.url?.path == "/oauth/token" }
        XCTAssertEqual(tokenRequests.count, 2)
        let refreshBody = String(decoding: try XCTUnwrap(tokenRequests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(refreshBody.contains("grant_type=refresh_token"))
        XCTAssertTrue(refreshBody.contains("client_id=hf-public-client"))
        XCTAssertTrue(refreshBody.contains("refresh_token=synthetic-hf-refresh"))
        let storedValue = try await credentials.credential(for: "oauth:huggingFaceAccount:hf")
        let stored = try XCTUnwrap(storedValue)
        XCTAssertTrue(stored.contains("synthetic-hf-rotated-refresh"))
        XCTAssertFalse(stored.contains("synthetic-hf-refresh\""))
    }

    func testConcurrentHuggingFaceRefreshSharesRotatedCredentialForBothCallers() async throws {
        let transport = GatedTransport()
        let credentials = MemoryCredentials()
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = accountProvider(.huggingFaceAccount, id: "hf", clientID: "hf-public-client")
        let session = AccountSessionFixture(
            providerID: provider.id,
            kind: provider.kind.rawValue,
            clientID: provider.oauthClientID,
            accessToken: "synthetic-expired-access",
            refreshToken: "synthetic-shared-refresh",
            expiresAt: now.addingTimeInterval(-1),
            accountLabel: "synthetic-user",
            scopes: ["inference-api", "openid", "profile"]
        )
        let data = try JSONEncoder().encode(session)
        try await credentials.setCredential(
            String(decoding: data, as: UTF8.self),
            for: "oauth:huggingFaceAccount:hf"
        )
        let client = OfficialAccountClient(
            credentials: credentials,
            transport: transport,
            now: { now },
            sleep: { _ in }
        )

        async let first = client.accessToken(for: provider)
        async let second = client.accessToken(for: provider)
        await credentials.waitForCredentialReads(2)
        await transport.waitForRequestCount(1)
        await transport.open(with: .json(200, [
            "access_token": "synthetic-rotated-access",
            "refresh_token": "synthetic-rotated-refresh",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile inference-api"
        ]))

        let tokens = try await [first, second]

        XCTAssertEqual(tokens.map(\.token), ["synthetic-rotated-access", "synthetic-rotated-access"])
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("refresh_token=synthetic-shared-refresh"))
    }

    func testDisconnectCancelsHuggingFaceRefreshWithoutRestoringCredential() async throws {
        let transport = GatedTransport()
        let credentials = MemoryCredentials()
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = accountProvider(.huggingFaceAccount, id: "hf", clientID: "hf-public-client")
        let session = AccountSessionFixture(
            providerID: provider.id,
            kind: provider.kind.rawValue,
            clientID: provider.oauthClientID,
            accessToken: "synthetic-expired-access",
            refreshToken: "synthetic-shared-refresh",
            expiresAt: now.addingTimeInterval(-1),
            accountLabel: "synthetic-user",
            scopes: ["inference-api", "openid", "profile"]
        )
        let data = try JSONEncoder().encode(session)
        try await credentials.setCredential(
            String(decoding: data, as: UTF8.self),
            for: "oauth:huggingFaceAccount:hf"
        )
        let client = OfficialAccountClient(
            credentials: credentials,
            transport: transport,
            now: { now },
            sleep: { _ in }
        )
        let refresh = Task { try await client.accessToken(for: provider) }
        await credentials.waitForCredentialReads(1)
        await transport.waitForRequestCount(1)

        try await client.disconnect(for: provider)
        await transport.open(with: .json(200, [
            "access_token": "synthetic-rotated-access",
            "refresh_token": "synthetic-rotated-refresh",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile inference-api"
        ]))

        do {
            _ = try await refresh.value
            XCTFail("Expected refresh cancellation after disconnect")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }
        let stored = try await credentials.credential(for: "oauth:huggingFaceAccount:hf")
        XCTAssertNil(stored)
    }

    func testHuggingFaceRequiresPublicClientIDAndRejectsMissingInferenceScope() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OfficialAccountClient(credentials: credentials, transport: transport)
        let providerWithoutClientID = accountProvider(.huggingFaceAccount, id: "hf")

        do {
            _ = try await client.beginAuthorization(
                for: providerWithoutClientID,
                redirectURI: URL(string: "http://127.0.0.1:49000/callback")!
            )
            XCTFail("Expected missing public client ID")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .missingClientID)
        }

        let provider = accountProvider(.huggingFaceAccount, id: "hf", clientID: "hf-public-client")
        let redirectURI = URL(string: "http://127.0.0.1:49001/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        let state = try XCTUnwrap(queryParameters(authorizationURL)["state"])
        await transport.enqueue(.json(200, [
            "access_token": "synthetic-under-scoped-token",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile"
        ]))

        do {
            _ = try await client.completeAuthorization(
                for: provider,
                callbackURL: callbackURL(redirectURI, code: "hf-code", state: state)
            )
            XCTFail("Expected required inference scope")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .requiredScopeMissing)
        }

        let storedCredential = try await credentials.credential(for: "oauth:huggingFaceAccount:hf")
        let requests = await transport.requests()
        XCTAssertNil(storedCredential)
        XCTAssertEqual(requests.count, 1)
    }

    func testGitHubDeviceFlowHonorsPollingIntervalSlowDownAndUsesExplicitIdentityToken() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let sleepRecorder = SleepRecorder()
        let fixedNow = Date(timeIntervalSince1970: 2_000)
        let client = OfficialAccountClient(
            credentials: credentials,
            transport: transport,
            now: { fixedNow },
            sleep: { interval in await sleepRecorder.record(interval) }
        )
        let provider = accountProvider(.githubCopilot, id: "copilot", clientID: "github-public-client")
        await transport.enqueue(.json(200, [
            "device_code": "synthetic-device-code",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 1
        ]))

        let start = try await client.beginAuthorization(for: provider)

        guard case let .deviceCode(userCode, verificationURL, expiresAt, attemptID) = start else {
            return XCTFail("Expected GitHub device authorization")
        }
        XCTAssertEqual(userCode, "ABCD-EFGH")
        XCTAssertEqual(verificationURL, URL(string: "https://github.com/login/device"))
        XCTAssertEqual(expiresAt, Date(timeIntervalSince1970: 2_900))
        await transport.enqueue(.json(200, ["error": "authorization_pending"]))
        await transport.enqueue(.json(200, ["error": "slow_down"]))
        await transport.enqueue(.json(200, ["error": "authorization_pending"]))
        await transport.enqueue(.json(200, [
            "access_token": "synthetic-github-token",
            "token_type": "bearer",
            "scope": "read:user"
        ]))
        await transport.enqueue(.json(200, ["login": "synthetic-login"]))

        let status = try await client.completeDeviceAuthorization(for: provider, attemptID: attemptID)

        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.accountLabel, "synthetic-login")
        let intervals = await sleepRecorder.values()
        XCTAssertEqual(intervals, [1, 1, 6, 6])
        let accessToken = try await client.accessToken(for: provider)
        XCTAssertEqual(accessToken.token, "synthetic-github-token")
        XCTAssertNil(accessToken.expiresAt)

        let requests = await transport.requests()
        let begin = try XCTUnwrap(requests.first)
        XCTAssertEqual(begin.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertTrue(String(decoding: try XCTUnwrap(begin.httpBody), as: UTF8.self).contains("scope=read%3Auser"))
        let identityRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(identityRequest.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(identityRequest.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-github-token")
        let ordinaryCredential = try await credentials.credential(for: provider.id)
        let namespacedCredential = try await credentials.credential(for: "oauth:githubCopilot:copilot")
        XCTAssertNil(ordinaryCredential)
        XCTAssertNotNil(namespacedCredential)
    }

    func testCancelledCallbackExchangeCannotPersistCredentials() async throws {
        let transport = HeldTransport()
        let credentials = MemoryCredentials()
        let client = OfficialAccountClient(credentials: credentials, transport: transport)
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let redirectURI = URL(string: "http://127.0.0.1:48322/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, attemptID) = start else {
            return XCTFail("Expected browser authorization")
        }
        let callback = callbackURL(redirectURI, code: "synthetic-code", state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
        let completion = Task { try await client.completeAuthorization(for: provider, callbackURL: callback) }
        await transport.waitForRequest()
        await client.cancelAuthorization(for: provider, attemptID: attemptID)
        await transport.resume(.json(200, ["key": "synthetic-cancelled-key"]))

        do {
            _ = try await completion.value
            XCTFail("Expected cancelled callback")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }

        let storedCredential = try await credentials.credential(for: "oauth:openRouterAccount:openrouter")
        XCTAssertNil(storedCredential)
    }

    func testCancellationDuringCredentialWriteRollsBackSession() async throws {
        let transport = ScriptedTransport()
        let credentials = BlockingCredentials()
        let client = OfficialAccountClient(credentials: credentials, transport: transport)
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let redirectURI = URL(string: "http://127.0.0.1:48326/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, attemptID) = start else {
            return XCTFail("Expected browser authorization")
        }
        await transport.enqueue(.json(200, ["key": "synthetic-racing-key"]))
        let completion = Task {
            try await client.completeAuthorization(
                for: provider,
                callbackURL: callbackURL(redirectURI, code: "synthetic-code", state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
            )
        }
        await credentials.waitForWrite()
        await client.cancelAuthorization(for: provider, attemptID: attemptID)
        await credentials.releaseWrite()

        do {
            _ = try await completion.value
            XCTFail("Expected cancelled callback")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }

        let storedCredential = try await credentials.credential(for: "oauth:openRouterAccount:openrouter")
        XCTAssertNil(storedCredential)
    }

    func testDisconnectDuringCallbackExchangeCannotRestoreCredential() async throws {
        let transport = HeldTransport()
        let credentials = MemoryCredentials()
        let client = OfficialAccountClient(credentials: credentials, transport: transport)
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let redirectURI = URL(string: "http://127.0.0.1:48327/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        let completion = Task {
            try await client.completeAuthorization(
                for: provider,
                callbackURL: callbackURL(redirectURI, code: "synthetic-code", state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
            )
        }
        await transport.waitForRequest()
        try await client.disconnect(for: provider)
        await transport.resume(.json(200, ["key": "synthetic-disconnected-key"]))

        do {
            _ = try await completion.value
            XCTFail("Expected disconnected callback")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }

        let storedCredential = try await credentials.credential(for: "oauth:openRouterAccount:openrouter")
        XCTAssertNil(storedCredential)
    }

    func testCancellingGitHubDeviceStartWhileRequestIsInFlightDoesNotReturnAttempt() async throws {
        let transport = HeldTransport()
        let client = OfficialAccountClient(credentials: MemoryCredentials(), transport: transport)
        let provider = accountProvider(.githubCopilot, id: "copilot", clientID: "github-public-client")
        let beginning = Task { try await client.beginAuthorization(for: provider) }
        await transport.waitForRequest()
        await client.cancelAuthorization(for: provider)
        await transport.resume(.json(200, [
            "device_code": "synthetic-device-code",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 1
        ]))

        do {
            _ = try await beginning.value
            XCTFail("Expected cancelled device authorization")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testMalformedOpenRouterResponseDoesNotPersistCredential() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OfficialAccountClient(credentials: credentials, transport: transport)
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let redirectURI = URL(string: "http://127.0.0.1:48323/callback")!
        let start = try await client.beginAuthorization(for: provider, redirectURI: redirectURI)
        guard case let .browser(authorizationURL, _, _) = start else {
            return XCTFail("Expected browser authorization")
        }
        await transport.enqueue(.text(200, "not-json"))

        do {
            _ = try await client.completeAuthorization(
                for: provider,
                callbackURL: callbackURL(redirectURI, code: "synthetic-code", state: try XCTUnwrap(queryParameters(authorizationURL)["state"]))
            )
            XCTFail("Expected malformed response")
        } catch let error as OfficialAccountClientError {
            XCTAssertEqual(error, .malformedResponse)
        }

        let storedCredential = try await credentials.credential(for: "oauth:openRouterAccount:openrouter")
        XCTAssertNil(storedCredential)
    }
}

private func accountProvider(
    _ kind: ProviderKind,
    id: String,
    clientID: String? = nil
) -> ProviderConfiguration {
    let endpoint: URL
    switch kind {
    case .openRouterAccount:
        endpoint = URL(string: "https://openrouter.ai/api/v1")!
    case .huggingFaceAccount:
        endpoint = URL(string: "https://router.huggingface.co/v1")!
    default:
        endpoint = URL(string: "https://github.com")!
    }
    var provider = ProviderConfiguration(id: id, name: "Account", kind: kind, endpoint: endpoint, model: "fixture/model")
    provider.oauthClientID = clientID
    return provider
}

private func callbackURL(_ redirectURI: URL, code: String, state: String) -> URL {
    var components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
    return components.url!
}

private func queryParameters(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private actor MemoryCredentials: CredentialStore {
    private var values: [String: String] = [:]
    private var readCount = 0
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func credential(for providerID: String) async throws -> String? {
        readCount += 1
        let ready = readWaiters.filter { readCount >= $0.count }
        readWaiters.removeAll { readCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return values[providerID]
    }

    func setCredential(_ value: String?, for providerID: String) async throws { values[providerID] = value }

    func waitForCredentialReads(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }
}

private actor BlockingCredentials: CredentialStore {
    private var values: [String: String] = [:]
    private var heldFirstWrite = true
    private var writeStarted = false
    private var writeStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func credential(for providerID: String) async throws -> String? { values[providerID] }

    func setCredential(_ value: String?, for providerID: String) async throws {
        if value != nil, heldFirstWrite {
            heldFirstWrite = false
            writeStarted = true
            writeStartedContinuation?.resume()
            writeStartedContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        values[providerID] = value
    }

    func waitForWrite() async {
        guard !writeStarted else { return }
        await withCheckedContinuation { writeStartedContinuation = $0 }
    }

    func releaseWrite() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct Reply: Sendable {
    let status: Int
    let body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> Self {
        Self(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    static func text(_ status: Int, _ value: String) -> Self {
        Self(status: status, body: Data(value.utf8))
    }

    var exchange: HTTPExchange {
        HTTPExchange(
            statusCode: status,
            headers: ["content-type": "application/json"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            }
        )
    }
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

private actor ScriptedTransport: StreamingHTTPTransport {
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

private actor HeldTransport: StreamingHTTPTransport {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<HTTPExchange, Never>?
    private var requested = false

    func waitForRequest() async {
        guard !requested else { return }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func resume(_ reply: Reply) {
        responseContinuation?.resume(returning: reply.exchange)
        responseContinuation = nil
    }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        requested = true
        requestContinuation?.resume()
        requestContinuation = nil
        return await withCheckedContinuation { responseContinuation = $0 }
    }
}

private actor GatedTransport: StreamingHTTPTransport {
    private var capturedRequests: [URLRequest] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var responseContinuations: [CheckedContinuation<HTTPExchange, Never>] = []
    private var openedReply: Reply?

    func requests() -> [URLRequest] { capturedRequests }

    func waitForRequestCount(_ count: Int) async {
        guard capturedRequests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func open(with reply: Reply) {
        openedReply = reply
        let continuations = responseContinuations
        responseContinuations.removeAll()
        continuations.forEach { $0.resume(returning: reply.exchange) }
    }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        capturedRequests.append(request)
        let ready = requestWaiters.filter { capturedRequests.count >= $0.count }
        requestWaiters.removeAll { capturedRequests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if let openedReply { return openedReply.exchange }
        return await withCheckedContinuation { responseContinuations.append($0) }
    }
}

private actor SleepRecorder {
    private var intervals: [TimeInterval] = []
    func record(_ interval: TimeInterval) { intervals.append(interval) }
    func values() -> [TimeInterval] { intervals }
}
#endif
