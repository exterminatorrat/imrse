import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAIAccountClientTests: XCTestCase, @unchecked Sendable {
    func testPrepareSignInUsesDynamicRegistrationAndBindsFreshStateNonceAndPKCE() async throws {
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: ScriptedTransport())
        let redirectURI = URL(string: "http://127.0.0.1:1455/auth/callback")!

        let first = try await client.prepareSignIn(for: "chatgpt-account", redirectURI: redirectURI)
        let firstParameters = try authorizationParameters(first.authorizationURL)
        XCTAssertEqual(firstParameters["client_id"], "dynamic_agent_client")
        XCTAssertEqual(firstParameters["agent_name_hint"], "Imrse")
        XCTAssertEqual(firstParameters["redirect_uri"], redirectURI.absoluteString)
        XCTAssertEqual(firstParameters["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(firstParameters["code_challenge_method"], "S256")
        XCTAssertEqual(Set((firstParameters["scope"] ?? "").split(separator: " ").map(String.init)), [
            "openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"
        ])
        XCTAssertFalse(try XCTUnwrap(firstParameters["state"]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(firstParameters["nonce"]).isEmpty)
        XCTAssertNotNil(firstParameters["code_challenge"])

        let initialHostID = await credentials.value(for: OpenAIAccountClient.hostIDCredentialKey)
        let hostID = try XCTUnwrap(initialHostID)
        await client.cancelSignIn(for: "chatgpt-account")
        let second = try await client.prepareSignIn(for: "chatgpt-account", redirectURI: redirectURI)
        let secondParameters = try authorizationParameters(second.authorizationURL)
        let reusedHostID = await credentials.value(for: OpenAIAccountClient.hostIDCredentialKey)
        XCTAssertEqual(try XCTUnwrap(reusedHostID), hostID)
        XCTAssertNotEqual(firstParameters["state"], secondParameters["state"])
        XCTAssertNotEqual(firstParameters["nonce"], secondParameters["nonce"])
        XCTAssertNotEqual(firstParameters["code_challenge"], secondParameters["code_challenge"])
    }

    func testCodeExchangeValidatesIdentityAndStoresOAuthJSONUnderProviderID() async throws {
        let keys = try FixtureKeys()
        let transport = ScriptedTransport(responses: [
            "/.well-known/jwks.json": .text(200, String(decoding: keys.jwks, as: UTF8.self)),
            "/api/accounts/oauth/token": .json(200, ["unused": "fixture"])
        ])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await credentials.setCredential("synthetic-api-key", for: "chatgpt-account")
        let redirectURI = URL(string: "http://127.0.0.1:43123/auth/callback")!
        let authorization = try await client.prepareSignIn(for: "chatgpt-account", redirectURI: redirectURI)
        let parameters = try authorizationParameters(authorization.authorizationURL)
        let authorizationCode = "opaque+code&with=equals value"
        let issuedClientID = "oaiapp_fixture"
        let idToken = try keys.idToken(clientID: issuedClientID, nonce: XCTUnwrap(parameters["nonce"]))
        await transport.setResponse(.json(200, [
            "access_token": "synthetic-access-secret",
            "refresh_token": "synthetic-refresh-secret",
            "id_token": idToken,
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        ]), forPath: "/api/accounts/oauth/token")
        let callback = try callbackURL(
            redirectURI: redirectURI,
            items: [
                URLQueryItem(name: "code", value: authorizationCode),
                URLQueryItem(name: "state", value: parameters["state"]),
                URLQueryItem(name: "client_id", value: issuedClientID)
            ]
        )

        let status = try await client.completeSignIn(for: "chatgpt-account", callbackURL: callback)

        XCTAssertTrue(status.isConnected)
        XCTAssertTrue(status.canUseChatGPTPlan)
        XCTAssertEqual(status.accountLabel, "user@example.invalid")
        let storedValue = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        let stored = try XCTUnwrap(storedValue)
        XCTAssertTrue(stored.contains("oaiapp_fixture"))
        XCTAssertTrue(stored.contains("synthetic-access-secret"))
        XCTAssertTrue(stored.contains("synthetic-refresh-secret"))
        let apiKeyRecord = await credentials.value(for: "chatgpt-account")
        XCTAssertEqual(apiKeyRecord, "synthetic-api-key")

        let requests = await transport.requests()
        let exchange = try XCTUnwrap(requests.first { $0.url?.path == "/api/accounts/oauth/token" })
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = try formParameters(exchange)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["client_id"], issuedClientID)
        XCTAssertEqual(form["code"], authorizationCode)
        let formBody = String(decoding: try XCTUnwrap(exchange.httpBody), as: UTF8.self)
        XCTAssertTrue(formBody.contains("code=opaque%2Bcode%26with%3Dequals+value"))
        XCTAssertEqual(form["redirect_uri"], redirectURI.absoluteString)
        XCTAssertEqual(form["resource"], "https://api.openai.com/v1")
        let verifier = try XCTUnwrap(form["code_verifier"])
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        XCTAssertEqual(challenge, parameters["code_challenge"])
    }

    func testCancelledSignInCannotExchangeOrPersistCallbackCredentials() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        let redirectURI = URL(string: "http://127.0.0.1:45678/auth/callback")!
        let authorization = try await client.prepareSignIn(for: "account", redirectURI: redirectURI)
        let parameters = try authorizationParameters(authorization.authorizationURL)
        await client.cancelSignIn(for: "account")
        let callback = try callbackURL(redirectURI: redirectURI, items: [
            URLQueryItem(name: "code", value: "synthetic-code"),
            URLQueryItem(name: "state", value: parameters["state"]),
            URLQueryItem(name: "client_id", value: "oaiapp_fixture")
        ])

        do {
            _ = try await client.completeSignIn(for: "account", callbackURL: callback)
            XCTFail("Expected cancelled sign-in")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }
        let stored = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "account"))
        let requests = await transport.requests()
        XCTAssertNil(stored)
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellingOlderAttemptDoesNotCancelNewerSignIn() async throws {
        let keys = try FixtureKeys()
        let transport = ScriptedTransport(responses: [
            "/.well-known/jwks.json": .text(200, String(decoding: keys.jwks, as: UTF8.self))
        ])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        let redirectURI = URL(string: "http://127.0.0.1:45680/auth/callback")!
        let oldAttempt = try await client.prepareSignIn(for: "account", redirectURI: redirectURI)
        let newAttempt = try await client.prepareSignIn(for: "account", redirectURI: redirectURI)

        XCTAssertNotEqual(oldAttempt.attemptID, newAttempt.attemptID)
        await client.cancelSignIn(for: "account", attemptID: oldAttempt.attemptID)

        let parameters = try authorizationParameters(newAttempt.authorizationURL)
        let clientID = "oaiapp_fixture"
        await transport.setResponse(.json(200, [
            "access_token": "synthetic-access",
            "refresh_token": "synthetic-refresh",
            "id_token": try keys.idToken(clientID: clientID, nonce: XCTUnwrap(parameters["nonce"])),
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        ]), forPath: "/api/accounts/oauth/token")
        let callback = try callbackURL(redirectURI: redirectURI, items: [
            URLQueryItem(name: "code", value: "synthetic-code"),
            URLQueryItem(name: "state", value: parameters["state"]),
            URLQueryItem(name: "client_id", value: clientID)
        ])

        let status = try await client.completeSignIn(for: "account", callbackURL: callback)

        XCTAssertTrue(status.isConnected)
        let stored = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "account"))
        XCTAssertNotNil(stored)
    }

    func testStateMismatchDoesNotExchangeAuthorizationCode() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        let redirectURI = URL(string: "http://127.0.0.1:45679/auth/callback")!
        _ = try await client.prepareSignIn(for: "account", redirectURI: redirectURI)
        let callback = try callbackURL(redirectURI: redirectURI, items: [
            URLQueryItem(name: "code", value: "synthetic-code"),
            URLQueryItem(name: "state", value: "wrong-state"),
            URLQueryItem(name: "client_id", value: "oaiapp_fixture")
        ])

        do {
            _ = try await client.completeSignIn(for: "account", callbackURL: callback)
            XCTFail("Expected state mismatch")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .stateMismatch)
        }
        let requests = await transport.requests()
        let stored = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "account"))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(stored)
    }

    func testIDTokenSignatureAndAllIdentityClaimsMustValidate() throws {
        let keys = try FixtureKeys()
        let nonce = "nonce-fixture"
        let valid = try keys.idToken(clientID: "oaiapp_fixture", nonce: nonce)
        XCTAssertEqual(
            try OpenAIIDTokenValidator.validate(
                valid,
                expectedClientID: "oaiapp_fixture",
                expectedNonce: nonce,
                jwks: keys.jwks,
                now: Date(timeIntervalSince1970: 2_000_000_000)
            ).subject,
            "subject-fixture"
        )

        let invalidTokens = [
            try keys.idToken(clientID: "oaiapp_fixture", nonce: nonce, issuer: "https://attacker.invalid"),
            try keys.idToken(clientID: "another-client", nonce: nonce),
            try keys.idToken(clientID: "oaiapp_fixture", nonce: "another-nonce"),
            try keys.idToken(clientID: "oaiapp_fixture", nonce: nonce, subject: ""),
            try keys.idToken(clientID: "oaiapp_fixture", nonce: nonce, expiry: Date(timeIntervalSince1970: 1)),
            try keys.tamperedSignature(clientID: "oaiapp_fixture", nonce: nonce)
        ]
        for token in invalidTokens {
            XCTAssertThrowsError(try OpenAIIDTokenValidator.validate(
                token,
                expectedClientID: "oaiapp_fixture",
                expectedNonce: nonce,
                jwks: keys.jwks,
                now: Date(timeIntervalSince1970: 2_000_000_000)
            ))
        }
    }

    func testAccountModelCatalogUsesBearerAndPreservesVisibleOrder() async throws {
        let keys = try FixtureKeys()
        let transport = ScriptedTransport(responses: [
            "/v1/models": .json(200, ["models": [
                ["slug": "model-b", "display_name": "Model B", "visibility": "list"],
                ["slug": "hidden", "display_name": "Hidden", "visibility": "private"],
                ["slug": "model-a", "display_name": "Model A", "visibility": "list"]
            ]])
        ])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys)

        let models = try await client.availableModels(for: "chatgpt-account")

        XCTAssertEqual(models.map(\.slug), ["model-b", "model-a"])
        XCTAssertEqual(models.map(\.displayName), ["Model B", "Model A"])
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
    }

    func testAccountModelCatalogAcceptsStandardDataResponseAndUsesIDsAsNames() async throws {
        let keys = try FixtureKeys()
        let transport = ScriptedTransport(responses: [
            "/v1/models": .json(200, ["data": [
                ["id": "model-b", "object": "model", "created": 1, "owned_by": "openai"],
                ["id": "model-a", "object": "model", "created": 2, "owned_by": "openai"]
            ]])
        ])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys)

        let models = try await client.availableModels(for: "chatgpt-account")

        XCTAssertEqual(models.map(\.slug), ["model-b", "model-a"])
        XCTAssertEqual(models.map(\.displayName), ["model-b", "model-a"])
    }

    func testAccountModelCatalogRejectsUnsafeIDsNamesAndDuplicateIDs() async throws {
        let keys = try FixtureKeys()
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys)
        let invalidCatalogs: [[String: Any]] = [
            ["models": [["slug": "bad/id", "display_name": "Model", "visibility": "list"]]],
            ["models": [["slug": "safe-id", "display_name": "Bad\nName", "visibility": "list"]]],
            ["data": [["id": "duplicate-id"], ["id": "duplicate-id"]]],
            ["data": [["id": "safe-id", "display_name": "Bad\u{0001}Name"]]]
        ]

        for catalog in invalidCatalogs {
            await transport.setResponse(.json(200, catalog), forPath: "/v1/models")
            do {
                _ = try await client.availableModels(for: "chatgpt-account")
                XCTFail("Expected malformed model catalog")
            } catch let error as OpenAIAccountClientError {
                XCTAssertEqual(error, .malformedResponse)
            }
        }
    }

    func testAccountModelCatalogKeepsResponseSizeLimit() async throws {
        let keys = try FixtureKeys()
        let response = ScriptedResponse(
            statusCode: 200,
            data: Data(repeating: 0x20, count: OpenAIHTTP.maximumResponseBytes + 1)
        )
        let transport = ScriptedTransport(responses: ["/v1/models": response])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys)

        do {
            _ = try await client.availableModels(for: "chatgpt-account")
            XCTFail("Expected oversized model catalog to be rejected")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testModelCatalogErrorsDoNotEchoResponseSecrets() async throws {
        let keys = try FixtureKeys()
        let transport = ScriptedTransport(responses: [
            "/v1/models": .text(503, "synthetic-response-secret")
        ])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys)

        do {
            _ = try await client.availableModels(for: "chatgpt-account")
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("synthetic-response-secret"))
        }
    }

    func testPlanScopeFailureDoesNotReadOrOverwriteTheAPIKeyCredential() async throws {
        let transport = ScriptedTransport()
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport)
        try await credentials.setCredential("synthetic-api-key", for: "chatgpt-account")
        try await credentials.setCredential(#"{"clientID":"oaiapp_fixture","hostID":"urn:uuid:00000000-0000-0000-0000-000000000001","subject":"subject-fixture","email":null,"idToken":"synthetic-id-token","accessToken":null,"refreshToken":null,"tokenType":null,"expiresAt":null,"scopes":["openid"]}"#, for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))

        do {
            _ = try await client.freshAccessToken(for: "chatgpt-account")
            XCTFail("Expected plan authorization failure")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .planUsageNotAuthorized)
        }
        let apiKey = await credentials.value(for: "chatgpt-account")
        let requests = await transport.requests()
        XCTAssertEqual(apiKey, "synthetic-api-key")
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidRefreshGrantClearsOnlyUnusableTokensAndKeepsRegistration() async throws {
        let keys = try FixtureKeys()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let transport = ScriptedTransport(responses: [
            "/api/accounts/oauth/token": .json(400, ["error": "invalid_grant", "error_description": "synthetic-secret"])
        ])
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport, now: { now })
        try await credentials.setCredential("synthetic-api-key", for: "chatgpt-account")
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys, expiresAt: Date(timeIntervalSince1970: 1))

        do {
            _ = try await client.freshAccessToken(for: "chatgpt-account")
            XCTFail("Expected reauthorization after an invalid refresh grant")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .reauthorizationRequired)
            XCTAssertFalse(String(describing: error).contains("synthetic-secret"))
        }
        let stored = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        let reauthorization = try JSONDecoder().decode(OpenAIAccountSession.self, from: Data(try XCTUnwrap(stored).utf8))
        XCTAssertEqual(reauthorization.clientID, "oaiapp_fixture")
        XCTAssertEqual(reauthorization.subject, "subject-fixture")
        XCTAssertNotNil(reauthorization.idToken)
        XCTAssertNil(reauthorization.accessToken)
        XCTAssertNil(reauthorization.refreshToken)
        let apiKey = await credentials.value(for: "chatgpt-account")
        XCTAssertEqual(apiKey, "synthetic-api-key")
    }

    func testConcurrentTokenRefreshesShareOneRotatingExchange() async throws {
        let keys = try FixtureKeys()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let transport = ManualRefreshTransport()
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport, now: { now })
        let refreshToken = "opaque+refresh&part=one value"
        try await saveSession(
            in: credentials,
            providerID: "chatgpt-account",
            keys: keys,
            expiresAt: now,
            refreshToken: refreshToken
        )

        let first = Task { try await client.freshAccessToken(for: "chatgpt-account") }
        await transport.waitUntilRefreshStarts()
        let second = Task { try await client.freshAccessToken(for: "chatgpt-account") }
        try await Task.sleep(for: .milliseconds(30))
        await transport.releaseRefresh()

        let firstToken = try await first.value
        let secondToken = try await second.value
        let refreshCount = await transport.refreshRequestCount()
        XCTAssertEqual(firstToken, "rotated-access")
        XCTAssertEqual(secondToken, "rotated-access")
        XCTAssertEqual(refreshCount, 1)
        let refreshRequests = await transport.capturedRequests()
        let refreshRequest = try XCTUnwrap(refreshRequests.first)
        XCTAssertEqual(try formParameters(refreshRequest)["refresh_token"], refreshToken)
        XCTAssertTrue(String(decoding: try XCTUnwrap(refreshRequest.httpBody), as: UTF8.self)
            .contains("refresh_token=opaque%2Brefresh%26part%3Done+value"))
        let storedValue = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        let refreshed = try JSONDecoder().decode(OpenAIAccountSession.self, from: Data(try XCTUnwrap(storedValue).utf8))
        XCTAssertEqual(refreshed.refreshToken, "rotated-refresh")
        XCTAssertEqual(refreshed.accessToken, "rotated-access")
    }

    func testDisconnectInvalidatesAnInFlightRefreshAndClearsItsSession() async throws {
        let keys = try FixtureKeys()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let transport = ManualRefreshTransport()
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: transport, now: { now })
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys, expiresAt: now)

        let refresh = Task { try await client.freshAccessToken(for: "chatgpt-account") }
        await transport.waitUntilRefreshStarts()
        try await client.disconnect(for: "chatgpt-account")
        await transport.releaseRefresh()

        do {
            _ = try await refresh.value
            XCTFail("A disconnected account must not return a refreshed token")
        } catch { }
        let stored = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        let signedOut = try JSONDecoder().decode(OpenAIAccountSession.self, from: Data(try XCTUnwrap(stored).utf8))
        XCTAssertEqual(signedOut.clientID, "oaiapp_fixture")
        XCTAssertNil(signedOut.idToken)
        XCTAssertNil(signedOut.accessToken)
        XCTAssertNil(signedOut.refreshToken)
        XCTAssertTrue(signedOut.scopes.isEmpty)
    }

    func testDisconnectWaitsForCancelledSignInWriteAndPersistsNewerRecord() async throws {
        let keys = try FixtureKeys()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let hostID = "urn:uuid:00000000-0000-0000-0000-000000000001"
        let transport = ScriptedTransport(responses: [
            "/.well-known/jwks.json": .text(200, String(decoding: keys.jwks, as: UTF8.self)),
            "/.well-known/openid-configuration": .json(200, [
                "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"
            ]),
            "/api/accounts/oauth/revoke": .json(200, [:])
        ])
        let credentials = PausingCredentials()
        let credentialKey = OpenAIAccountClient.credentialKey(for: "chatgpt-account")
        let client = OpenAIAccountClient(credentials: credentials, transport: transport, now: { now })
        try await credentials.setCredential(hostID, for: OpenAIAccountClient.hostIDCredentialKey)
        try await credentials.setCredential("synthetic-api-key", for: "chatgpt-account")
        try await saveSession(in: credentials, providerID: "chatgpt-account", keys: keys, expiresAt: now)
        let originalRecordValue = await credentials.value(for: credentialKey)
        let originalRecord = try XCTUnwrap(originalRecordValue)
        await credentials.pauseNextWrite(for: credentialKey)
        await transport.pauseResponse(forPath: "/api/accounts/oauth/revoke")

        let redirectURI = URL(string: "http://127.0.0.1:43124/auth/callback")!
        let signIn = try await client.prepareSignIn(for: "chatgpt-account", redirectURI: redirectURI)
        let parameters = try authorizationParameters(signIn.authorizationURL)
        await transport.setResponse(.json(200, [
            "access_token": "rotated-access",
            "refresh_token": "rotated-refresh",
            "id_token": try keys.idToken(clientID: "oaiapp_fixture", nonce: XCTUnwrap(parameters["nonce"])),
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        ]), forPath: "/api/accounts/oauth/token")
        let callback = try callbackURL(redirectURI: redirectURI, items: [
            URLQueryItem(name: "code", value: "synthetic-code"),
            URLQueryItem(name: "state", value: parameters["state"]),
            URLQueryItem(name: "client_id", value: "oaiapp_fixture")
        ])

        let completion = Task { try await client.completeSignIn(for: "chatgpt-account", callbackURL: callback) }
        var disconnect: Task<Void, any Error>?
        do {
            try await waitForTestCondition("the session write to pause") { await credentials.isWritePaused() }
            await client.cancelSignIn(for: "chatgpt-account", attemptID: signIn.attemptID)
            disconnect = Task { try await client.disconnect(for: "chatgpt-account") }
            try await waitForTestCondition("disconnect to acquire the account generation") {
                await client.isDisconnectingForTesting("chatgpt-account")
            }
            await credentials.releasePausedWrite()
            try await waitForTestCondition("revocation to pause") { await transport.isResponsePaused() }
            try await waitForTestCondition("rollback to restore the original session") {
                await credentials.value(for: credentialKey) == originalRecord
            }
            await transport.releasePausedResponse()
        } catch {
            await client.cancelSignIn(for: "chatgpt-account", attemptID: signIn.attemptID)
            await credentials.releasePausedWrite()
            await transport.releasePausedResponse()
            _ = try? await completion.value
            if let disconnect { _ = try? await disconnect.value }
            throw error
        }

        do {
            _ = try await completion.value
            XCTFail("Expected the cancelled sign-in to fail")
        } catch let error as OpenAIAccountClientError {
            XCTAssertEqual(error, .cancelled)
        }
        try await disconnect?.value

        let stored = await credentials.value(for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        let signedOut = try JSONDecoder().decode(OpenAIAccountSession.self, from: Data(try XCTUnwrap(stored).utf8))
        XCTAssertEqual(signedOut.clientID, "oaiapp_fixture")
        XCTAssertNil(signedOut.idToken)
        XCTAssertNil(signedOut.accessToken)
        XCTAssertNil(signedOut.refreshToken)
        XCTAssertTrue(signedOut.scopes.isEmpty)
        let apiKey = await credentials.value(for: "chatgpt-account")
        XCTAssertEqual(apiKey, "synthetic-api-key")
        let requests = await transport.requests()
        let revoke = try XCTUnwrap(requests.first { $0.url?.path == "/api/accounts/oauth/revoke" })
        XCTAssertEqual(try formParameters(revoke)["token"], "fixture-refresh")
    }
}

private func authorizationParameters(_ url: URL) throws -> [String: String] {
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    return Dictionary(uniqueKeysWithValues: try items.map { item in
        guard let value = item.value else { throw OpenAIAccountClientError.invalidCallback }
        return (item.name, value)
    })
}

private func callbackURL(redirectURI: URL, items: [URLQueryItem]) throws -> URL {
    var components = try XCTUnwrap(URLComponents(url: redirectURI, resolvingAgainstBaseURL: false))
    components.queryItems = items
    return try XCTUnwrap(components.url)
}

private func formParameters(_ request: URLRequest) throws -> [String: String] {
    let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: try body.split(separator: "&", omittingEmptySubsequences: false).map { pair in
        let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              let name = String(fields[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
              let value = String(fields[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        else { throw OpenAIAccountClientError.invalidCallback }
        return (name, value)
    })
}

private func saveSession(
    in credentials: any CredentialStore,
    providerID: String,
    keys: FixtureKeys,
    expiresAt: Date = Date(timeIntervalSinceNow: 3600),
    refreshToken: String = "fixture-refresh"
) async throws {
    let session = OpenAIAccountSession(
        clientID: "oaiapp_fixture",
        hostID: "urn:uuid:00000000-0000-0000-0000-000000000001",
        subject: "subject-fixture",
        email: "user@example.invalid",
        idToken: try keys.idToken(clientID: "oaiapp_fixture", nonce: "nonce-fixture"),
        accessToken: "fixture-access",
        refreshToken: refreshToken,
        tokenType: "Bearer",
        expiresAt: expiresAt.timeIntervalSince1970,
        scopes: ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    )
    let data = try JSONEncoder().encode(session)
        try await credentials.setCredential(
            String(decoding: data, as: UTF8.self),
            for: OpenAIAccountClient.credentialKey(for: providerID)
        )
}

private actor MemoryCredentials: CredentialStore {
    private var values: [String: String] = [:]
    func credential(for providerID: String) async throws -> String? { values[providerID] }
    func setCredential(_ value: String?, for providerID: String) async throws { values[providerID] = value }
    func value(for providerID: String) -> String? { values[providerID] }
}

private actor PausingCredentials: CredentialStore {
    private var values: [String: String] = [:]
    private var keyToPause: String?
    private var pausedWrite: CheckedContinuation<Void, Never>?

    func credential(for providerID: String) async throws -> String? { values[providerID] }

    func setCredential(_ value: String?, for providerID: String) async throws {
        values[providerID] = value
        guard keyToPause == providerID else { return }
        keyToPause = nil
        await withCheckedContinuation { continuation in
            pausedWrite = continuation
        }
    }

    func pauseNextWrite(for key: String) { keyToPause = key }

    func releasePausedWrite() {
        let continuation = pausedWrite
        pausedWrite = nil
        keyToPause = nil
        continuation?.resume()
    }

    func isWritePaused() -> Bool { pausedWrite != nil }
    func value(for providerID: String) -> String? { values[providerID] }
}

private struct ScriptedResponse: Sendable {
    let statusCode: Int
    let data: Data
    init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
    static func json(_ statusCode: Int, _ object: Any) -> ScriptedResponse {
        ScriptedResponse(statusCode: statusCode, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
    static func text(_ statusCode: Int, _ value: String) -> ScriptedResponse {
        ScriptedResponse(statusCode: statusCode, data: Data(value.utf8))
    }
}

private actor ScriptedTransport: StreamingHTTPTransport {
    private var responses: [String: ScriptedResponse]
    private var captured: [URLRequest] = []
    private var pathToPause: String?
    private var pausedResponse: CheckedContinuation<HTTPExchange, Never>?
    private var pausedResponseValue: ScriptedResponse?

    init(responses: [String: ScriptedResponse] = [:]) { self.responses = responses }
    func setResponse(_ response: ScriptedResponse, forPath path: String) { responses[path] = response }
    func requests() -> [URLRequest] { captured }

    func pauseResponse(forPath path: String) { pathToPause = path }
    func isResponsePaused() -> Bool { pausedResponse != nil }

    func releasePausedResponse() {
        let continuation = pausedResponse
        pausedResponse = nil
        pathToPause = nil
        let response = pausedResponseValue ?? .text(404, "not found")
        pausedResponseValue = nil
        guard let continuation else { return }
        continuation.resume(returning: HTTPExchange(
            statusCode: response.statusCode,
            headers: ["content-type": "application/json"],
            body: AsyncThrowingStream { continuation in
                if !response.data.isEmpty { continuation.yield(response.data) }
                continuation.finish()
            }
        ))
    }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        captured.append(request)
        let path = request.url?.path ?? ""
        let response = responses[path] ?? .text(404, "not found")
        if path == pathToPause {
            pathToPause = nil
            pausedResponseValue = response
            return await withCheckedContinuation { continuation in
                pausedResponse = continuation
            }
        }
        return HTTPExchange(
            statusCode: response.statusCode,
            headers: ["content-type": "application/json"],
            body: AsyncThrowingStream { continuation in
                if !response.data.isEmpty { continuation.yield(response.data) }
                continuation.finish()
            }
        )
    }
}

private func waitForTestCondition(
    timeout: Duration = .seconds(2),
    _ description: String,
    _ condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestGateTimeout(description: description)
}

private struct TestGateTimeout: LocalizedError {
    let description: String
    var errorDescription: String? { "Timed out waiting for \(description)." }
}

private actor ManualRefreshTransport: StreamingHTTPTransport {
    private var requests: [URLRequest] = []
    private var refreshContinuation: CheckedContinuation<HTTPExchange, Never>?
    private var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshStarted = false

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        requests.append(request)
        if request.url?.path == "/api/accounts/oauth/token",
           let form = try? formParameters(request), form["grant_type"] == "refresh_token" {
            refreshStarted = true
            refreshStartWaiters.forEach { $0.resume() }
            refreshStartWaiters.removeAll()
            return await withCheckedContinuation { refreshContinuation = $0 }
        }
        if request.url?.path == "/.well-known/openid-configuration" {
            return response(200, ["revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"])
        }
        if request.url?.path == "/api/accounts/oauth/revoke" {
            return response(200, [:])
        }
        return response(404, [:])
    }

    func waitUntilRefreshStarts() async {
        if refreshStarted { return }
        await withCheckedContinuation { refreshStartWaiters.append($0) }
    }

    func releaseRefresh() {
        refreshContinuation?.resume(returning: response(200, [
            "access_token": "rotated-access",
            "refresh_token": "rotated-refresh",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        ]))
        refreshContinuation = nil
    }

    func refreshRequestCount() -> Int {
        requests.filter { request in
            request.url?.path == "/api/accounts/oauth/token" && ((try? formParameters(request)["grant_type"]) == "refresh_token")
        }.count
    }

    func capturedRequests() -> [URLRequest] { requests }

    private func response(_ status: Int, _ object: Any) -> HTTPExchange {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPExchange(statusCode: status, body: AsyncThrowingStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
        })
    }
}

private final class FixtureKeys: @unchecked Sendable {
    private let privateKey: SecKey
    let jwks: Data
    private let modulus: Data
    private let exponent: Data

    init() throws {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw error?.takeRetainedValue() ?? OpenAIAccountClientError.invalidIdentityToken }
        self.privateKey = privateKey
        var offset = 0
        let sequence = try readDERElement(external, offset: &offset, tag: 0x30)
        offset = 0
        modulus = try readDERElement(sequence, offset: &offset, tag: 0x02).droppingLeadingZeroes
        exponent = try readDERElement(sequence, offset: &offset, tag: 0x02).droppingLeadingZeroes
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA", "kid": "fixture-rsa-key", "use": "sig", "alg": "RS256",
            "n": modulus.base64URL, "e": exponent.base64URL
        ]]])
    }

    func idToken(
        clientID: String,
        nonce: String,
        issuer: String = "https://auth.openai.com",
        subject: String = "subject-fixture",
        expiry: Date = Date(timeIntervalSince1970: 2_000_000_300)
    ) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture-rsa-key", "typ": "JWT"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "iss": issuer, "aud": clientID, "exp": expiry.timeIntervalSince1970,
            "nonce": nonce, "sub": subject, "email": "user@example.invalid"
        ])
        let signingInput = "\(header.base64URL).\(payload.base64URL)"
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data? else { throw error?.takeRetainedValue() ?? OpenAIAccountClientError.invalidIdentityToken }
        return "\(signingInput).\(signature.base64URL)"
    }

    func tamperedSignature(clientID: String, nonce: String) throws -> String {
        let token = try idToken(clientID: clientID, nonce: nonce)
        var parts = token.split(separator: ".").map(String.init)
        parts[2] = Data("synthetic-invalid-signature".utf8).base64URL
        return parts.joined(separator: ".")
    }
}

private func readDERElement(_ data: Data, offset: inout Int, tag: UInt8) throws -> Data {
    guard offset + 2 <= data.count, data[offset] == tag else { throw OpenAIAccountClientError.invalidIdentityToken }
    offset += 1
    let firstLength = Int(data[offset])
    offset += 1
    let length: Int
    if firstLength & 0x80 == 0 {
        length = firstLength
    } else {
        let lengthBytes = firstLength & 0x7f
        guard lengthBytes > 0, lengthBytes <= MemoryLayout<Int>.size, offset + lengthBytes <= data.count else {
            throw OpenAIAccountClientError.invalidIdentityToken
        }
        length = data[offset..<(offset + lengthBytes)].reduce(0) { ($0 << 8) | Int($1) }
        offset += lengthBytes
    }
    guard length >= 0, offset + length <= data.count else { throw OpenAIAccountClientError.invalidIdentityToken }
    defer { offset += length }
    return data.subdata(in: offset..<(offset + length))
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var droppingLeadingZeroes: Data {
        drop(while: { $0 == 0 }).isEmpty ? Data([0]) : Data(drop(while: { $0 == 0 }))
    }
}
#endif
