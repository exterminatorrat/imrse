import Foundation
import ImrseCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIAccountStatus: Equatable, Sendable {
    public let isConnected: Bool
    public let canUseChatGPTPlan: Bool
    public let accountLabel: String?

    public init(isConnected: Bool, canUseChatGPTPlan: Bool, accountLabel: String?) {
        self.isConnected = isConnected
        self.canUseChatGPTPlan = canUseChatGPTPlan
        self.accountLabel = accountLabel
    }
}

public struct OpenAIAccountModel: Equatable, Identifiable, Sendable {
    public let slug: String
    public let displayName: String
    public var id: String { slug }
}

public struct OpenAISignInRequest: Sendable {
    public let attemptID: UUID
    public let authorizationURL: URL
}

public enum OpenAIAccountClientError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case invalidConfiguration
    case invalidCallback
    case stateMismatch
    case authorizationDenied
    case registrationIncomplete
    case clientMismatch
    case invalidIdentityToken
    case cryptographyUnavailable
    case accountMismatch
    case planUsageNotAuthorized
    case notConnected
    case invalidGrant
    case invalidClientConfiguration
    case reauthorizationRequired
    case invalidStoredSession
    case storageUnavailable
    case requestFailed(Int)
    case networkFailure
    case responseTooLarge
    case malformedResponse
    case revocationUnconfirmed
    case expiredAttempt

    public var errorDescription: String? {
        switch self {
        case .cancelled: "OpenAI sign-in was cancelled."
        case .invalidConfiguration: "OpenAI account configuration is invalid."
        case .invalidCallback, .stateMismatch, .clientMismatch, .expiredAttempt:
            "OpenAI sign-in could not be verified. Start a new sign-in."
        case .authorizationDenied: "OpenAI sign-in was not authorized."
        case .registrationIncomplete: "OpenAI registration did not complete. Start a new sign-in."
        case .invalidIdentityToken: "OpenAI sign-in could not be verified."
        case .cryptographyUnavailable: "OpenAI sign-in verification is unavailable on this platform."
        case .accountMismatch: "The selected OpenAI account did not match the verified account."
        case .planUsageNotAuthorized: "ChatGPT plan usage is not authorized for this account."
        case .notConnected: "Connect a ChatGPT account before using its models."
        case .invalidGrant, .reauthorizationRequired: "Sign in to this ChatGPT account again."
        case .invalidClientConfiguration: "OpenAI rejected the registered client configuration."
        case .invalidStoredSession: "The saved OpenAI account session is invalid. Sign in again."
        case .storageUnavailable: "OpenAI account credentials could not be read or saved securely."
        case .requestFailed(let status): "OpenAI request failed (HTTP \(status))."
        case .networkFailure: "OpenAI could not be reached."
        case .responseTooLarge: "OpenAI returned an oversized response."
        case .malformedResponse: "OpenAI returned an invalid response."
        case .revocationUnconfirmed: "Signed out locally, but OpenAI session revocation was not confirmed."
        }
    }
}

public actor OpenAIAccountClient {
    public static let hostIDCredentialKey = "oauth:host"
    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    private static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    private static let revocationURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    private static let resource = "https://api.openai.com/v1"
    private static let requestedScopes = [
        "openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"
    ]
    private static let directScope = "chatgpt.tokens.use.direct"
    private static let maximumStoredSessionBytes = 65_536
    private let credentials: any CredentialStore
    private let transport: any StreamingHTTPTransport
    private let now: @Sendable () -> Date
    private var pendingSignIns: [String: PendingSignIn] = [:]
    private var activeSignIns: [String: UUID] = [:]
    private var signInTasks: [String: (id: UUID, task: Task<OpenAIAccountStatus, any Error>)] = [:]
    private var refreshTasks: [String: (id: UUID, task: Task<OpenAIAccountSession, any Error>)] = [:]
    private var generations: [String: UInt64] = [:]
    private var disconnecting = Set<String>()
    private var storageLocked = false
    private var storageWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
        now = Date.init
    }

    init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport,
        now: @escaping @Sendable () -> Date
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public static func credentialKey(for providerID: String) -> String {
        "oauth:\(providerID)"
    }

    public func connectionStatus(for providerID: String) async throws -> OpenAIAccountStatus {
        try validateProviderID(providerID)
        guard let stored = try await storedSession(for: providerID) else {
            return OpenAIAccountStatus(isConnected: false, canUseChatGPTPlan: false, accountLabel: nil)
        }
        return status(for: stored.session)
    }

    public func prepareSignIn(for providerID: String, redirectURI: URL) async throws -> OpenAISignInRequest {
#if canImport(Security)
        guard !Task.isCancelled else { throw OpenAIAccountClientError.cancelled }
        try validateProviderID(providerID)
        guard isCallbackURI(redirectURI), !disconnecting.contains(providerID) else {
            throw OpenAIAccountClientError.invalidConfiguration
        }

        let attemptID = UUID()
        let previousAttempt = activeSignIns[providerID]
            ?? pendingSignIns[providerID]?.attemptID
            ?? signInTasks[providerID]?.id
        if let previousAttempt { cancelSignIn(for: providerID, attemptID: previousAttempt) }
        let generation = advanceGeneration(for: providerID)
        refreshTasks.removeValue(forKey: providerID)?.task.cancel()
        activeSignIns[providerID] = attemptID

        return try await withTaskCancellationHandler {
            do {
                return try await makeSignInRequest(
                    providerID: providerID,
                    redirectURI: redirectURI,
                    attemptID: attemptID,
                    generation: generation
                )
            } catch is CancellationError {
                cancelSignIn(for: providerID, attemptID: attemptID)
                throw OpenAIAccountClientError.cancelled
            } catch {
                cancelSignIn(for: providerID, attemptID: attemptID)
                throw error
            }
        } onCancel: {
            Task { await self.cancelSignIn(for: providerID, attemptID: attemptID) }
        }
#else
        throw OpenAIAccountClientError.cryptographyUnavailable
#endif
    }

    private func makeSignInRequest(
        providerID: String,
        redirectURI: URL,
        attemptID: UUID,
        generation: UInt64
    ) async throws -> OpenAISignInRequest {
        try validateSignInAttempt(attemptID, generation: generation, providerID: providerID)
        let stored = try await storedSession(for: providerID)
        try validateSignInAttempt(attemptID, generation: generation, providerID: providerID)
        let hostID = try await stableHostID()
        try validateSignInAttempt(attemptID, generation: generation, providerID: providerID)
        if let stored, stored.session.hostID != hostID { throw OpenAIAccountClientError.invalidStoredSession }

        let state = try Self.randomValue()
        let nonce = try Self.randomValue()
        let verifier = try Self.randomValue()
        let challenge = try Self.codeChallenge(verifier)
        var query = [
            URLQueryItem(name: "client_id", value: stored?.session.clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.requestedScopes.joined(separator: " ")),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        if let stored {
            if let idToken = stored.session.idToken { query.append(URLQueryItem(name: "id_token_hint", value: idToken)) }
            if let email = stored.session.email { query.append(URLQueryItem(name: "login_hint", value: email)) }
        } else {
            query.append(URLQueryItem(name: "agent_name_hint", value: "Imrse"))
        }
        guard var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw OpenAIAccountClientError.invalidConfiguration
        }
        components.queryItems = query
        guard let authorizationURL = components.url else { throw OpenAIAccountClientError.invalidConfiguration }
        try validateSignInAttempt(attemptID, generation: generation, providerID: providerID)
        pendingSignIns[providerID] = PendingSignIn(
            attemptID: attemptID,
            generation: generation,
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            verifier: verifier,
            hostID: hostID,
            originalSession: stored?.session,
            originalRecord: stored?.raw,
            expiresAt: now().addingTimeInterval(600).timeIntervalSince1970
        )
        return OpenAISignInRequest(attemptID: attemptID, authorizationURL: authorizationURL)
    }

    public func completeSignIn(for providerID: String, callbackURL: URL) async throws -> OpenAIAccountStatus {
        try validateProviderID(providerID)
        guard let pending = pendingSignIns[providerID] else { throw OpenAIAccountClientError.cancelled }
        guard pending.expiresAt > now().timeIntervalSince1970 else {
            pendingSignIns.removeValue(forKey: providerID)
            activeSignIns.removeValue(forKey: providerID)
            throw OpenAIAccountClientError.expiredAttempt
        }
        guard callbackMatches(callbackURL, redirectURI: pending.redirectURI) else {
            throw OpenAIAccountClientError.invalidCallback
        }
        let query = try callbackParameters(callbackURL)
        guard query["state"] == pending.state else { throw OpenAIAccountClientError.stateMismatch }
        pendingSignIns.removeValue(forKey: providerID)
        if query["error"] != nil {
            activeSignIns.removeValue(forKey: providerID)
            throw OpenAIAccountClientError.authorizationDenied
        }
        guard let code = query["code"], isSafeFormValue(code, maximumBytes: 4_096) else {
            activeSignIns.removeValue(forKey: providerID)
            throw OpenAIAccountClientError.invalidCallback
        }
        let clientID: String
        if let existing = pending.originalSession {
            clientID = existing.clientID
            if let returnedClientID = query["client_id"], returnedClientID != clientID {
                activeSignIns.removeValue(forKey: providerID)
                throw OpenAIAccountClientError.clientMismatch
            }
        } else {
            guard let issuedClientID = query["client_id"], isValidClientID(issuedClientID),
                  issuedClientID != "dynamic_agent_client"
            else {
                activeSignIns.removeValue(forKey: providerID)
                throw OpenAIAccountClientError.registrationIncomplete
            }
            clientID = issuedClientID
        }

        let task = Task { try await self.exchangeAndStore(
            code: code,
            clientID: clientID,
            providerID: providerID,
            pending: pending
        ) }
        signInTasks[providerID] = (pending.attemptID, task)
        return try await withTaskCancellationHandler {
            defer {
                if signInTasks[providerID]?.id == pending.attemptID { signInTasks.removeValue(forKey: providerID) }
                if activeSignIns[providerID] == pending.attemptID { activeSignIns.removeValue(forKey: providerID) }
            }
            do {
                return try await task.value
            } catch is CancellationError {
                throw OpenAIAccountClientError.cancelled
            }
        } onCancel: {
            Task { await self.cancelSignIn(for: providerID, attemptID: pending.attemptID) }
        }
    }

    public func cancelSignIn(for providerID: String) {
        guard let attemptID = activeSignIns[providerID]
                ?? pendingSignIns[providerID]?.attemptID
                ?? signInTasks[providerID]?.id
        else { return }
        cancelSignIn(for: providerID, attemptID: attemptID)
    }

    public func cancelSignIn(for providerID: String, attemptID: UUID) {
        guard activeSignIns[providerID] == attemptID
                || pendingSignIns[providerID]?.attemptID == attemptID
                || signInTasks[providerID]?.id == attemptID
        else { return }
        _ = advanceGeneration(for: providerID)
        if pendingSignIns[providerID]?.attemptID == attemptID { pendingSignIns.removeValue(forKey: providerID) }
        if activeSignIns[providerID] == attemptID { activeSignIns.removeValue(forKey: providerID) }
        if signInTasks[providerID]?.id == attemptID { signInTasks.removeValue(forKey: providerID)?.task.cancel() }
    }

    public func disconnect(for providerID: String) async throws {
        try validateProviderID(providerID)
        guard !disconnecting.contains(providerID) else { throw OpenAIAccountClientError.cancelled }
        disconnecting.insert(providerID)
        defer { disconnecting.remove(providerID) }
        let generation = advanceGeneration(for: providerID)
        pendingSignIns.removeValue(forKey: providerID)
        activeSignIns.removeValue(forKey: providerID)
        let signInTask = signInTasks.removeValue(forKey: providerID)?.task
        let refreshTask = refreshTasks.removeValue(forKey: providerID)?.task
        signInTask?.cancel()
        refreshTask?.cancel()
        guard let stored = try await storedSession(for: providerID) else { return }
        var revocationConfirmed = true
        if let refreshToken = stored.session.refreshToken {
            do {
                try await revoke(refreshToken: refreshToken, clientID: stored.session.clientID)
            } catch {
                revocationConfirmed = false
            }
        }
        var signedOut = stored.session
        signedOut.idToken = nil
        signedOut.accessToken = nil
        signedOut.refreshToken = nil
        signedOut.tokenType = nil
        signedOut.expiresAt = nil
        signedOut.scopes = []
        try await saveSession(
            signedOut,
            providerID: providerID,
            expectedRecord: stored.raw,
            generation: generation
        )
        if !revocationConfirmed { throw OpenAIAccountClientError.revocationUnconfirmed }
    }

    func isDisconnectingForTesting(_ providerID: String) -> Bool {
        disconnecting.contains(providerID)
    }

    public func availableModels(for providerID: String) async throws -> [OpenAIAccountModel] {
        let token = try await freshAccessToken(for: providerID)
        let response = try await OpenAIHTTP.send(OpenAIHTTP.getRequest(url: Self.modelsURL, bearerToken: token), using: transport)
        let catalog: ModelCatalogResponse
        do {
            catalog = try JSONDecoder().decode(ModelCatalogResponse.self, from: response.body)
        } catch {
            throw OpenAIAccountClientError.malformedResponse
        }
        let identifiers = catalog.models.map(\.slug)
        guard Set(identifiers).count == identifiers.count,
              catalog.models.allSatisfy({
                  $0.slug.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$", options: .regularExpression) != nil
                      && isSafeDisplayName($0.displayName)
              })
        else { throw OpenAIAccountClientError.malformedResponse }
        return catalog.models.map { OpenAIAccountModel(slug: $0.slug, displayName: $0.displayName) }
    }

    public func freshAccessToken(for providerID: String) async throws -> String {
        try validateProviderID(providerID)
        guard !disconnecting.contains(providerID),
              let stored = try await storedSession(for: providerID)
        else { throw OpenAIAccountClientError.notConnected }
        guard stored.session.idToken != nil else { throw OpenAIAccountClientError.notConnected }
        guard stored.session.scopes.contains(Self.directScope) else {
            throw OpenAIAccountClientError.planUsageNotAuthorized
        }
        guard stored.session.canUseChatGPTPlan else { throw OpenAIAccountClientError.reauthorizationRequired }
        guard let accessToken = stored.session.accessToken,
              let expiresAt = stored.session.expiresAt,
              isSafeValue(accessToken, maximumBytes: 4_096)
        else { throw OpenAIAccountClientError.invalidStoredSession }
        guard expiresAt <= now().timeIntervalSince1970 + 60 else { return accessToken }
        return try await refreshedAccessToken(
            for: providerID,
            session: stored.session,
            record: stored.raw,
            generation: generations[providerID, default: 0]
        )
    }

    private func exchangeAndStore(
        code: String,
        clientID: String,
        providerID: String,
        pending: PendingSignIn
    ) async throws -> OpenAIAccountStatus {
        guard isCurrent(pending.generation, for: providerID), activeSignIns[providerID] == pending.attemptID else {
            throw OpenAIAccountClientError.cancelled
        }
        let request = OpenAIHTTP.formRequest(url: Self.tokenURL, values: [
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", pending.verifier),
            ("redirect_uri", pending.redirectURI.absoluteString),
            ("resource", Self.resource)
        ])
        let response = try await OpenAIHTTP.send(request, using: transport)
        try Task.checkCancellation()
        let tokens = try decodeTokenResponse(response.body)
        guard let idToken = tokens.idToken, isSafeValue(idToken, maximumBytes: 65_536) else {
            throw OpenAIAccountClientError.malformedResponse
        }
        let jwks = try await OpenAIHTTP.send(OpenAIHTTP.getRequest(url: Self.jwksURL), using: transport)
        try Task.checkCancellation()
        let identity = try OpenAIIDTokenValidator.validate(
            idToken,
            expectedClientID: clientID,
            expectedNonce: pending.nonce,
            jwks: jwks.body,
            now: now()
        )
        if let previous = pending.originalSession, identity.subject != previous.subject {
            throw OpenAIAccountClientError.accountMismatch
        }
        guard isCurrent(pending.generation, for: providerID), activeSignIns[providerID] == pending.attemptID else {
            throw OpenAIAccountClientError.cancelled
        }
        let scopes = try parseScopes(tokens.scope)
        let hasDirectPermission = scopes.contains(Self.directScope)
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: TimeInterval?
        let tokenType: String?
        if hasDirectPermission {
            guard let access = tokens.accessToken, isSafeValue(access, maximumBytes: 4_096),
                  let refresh = tokens.refreshToken, isSafeFormValue(refresh, maximumBytes: 4_096),
                  let type = tokens.tokenType, type.caseInsensitiveCompare("Bearer") == .orderedSame,
                  let expiresIn = tokens.expiresIn, expiresIn.isFinite, (1...31_536_000).contains(expiresIn)
            else { throw OpenAIAccountClientError.malformedResponse }
            accessToken = access
            refreshToken = refresh
            expiresAt = now().timeIntervalSince1970 + expiresIn
            tokenType = "Bearer"
        } else {
            accessToken = nil
            refreshToken = nil
            expiresAt = nil
            tokenType = nil
        }
        let session = OpenAIAccountSession(
            clientID: clientID,
            hostID: pending.hostID,
            subject: identity.subject,
            email: identity.email ?? pending.originalSession?.email,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiresAt,
            scopes: scopes.sorted()
        )
        try await saveSession(
            session,
            providerID: providerID,
            expectedRecord: pending.originalRecord,
            generation: pending.generation
        )
        return status(for: session)
    }

    private func refreshedAccessToken(
        for providerID: String,
        session: OpenAIAccountSession,
        record: String,
        generation: UInt64
    ) async throws -> String {
        if let flight = refreshTasks[providerID] {
            do {
                let replacement = try await flight.task.value
                return try await commitRefresh(
                    replacement,
                    source: session,
                    providerID: providerID,
                    generation: generation
                )
            } catch {
                try await normalizeRefreshFailure(
                    error,
                    source: session,
                    providerID: providerID,
                    generation: generation
                )
            }
        }
        guard session.refreshToken != nil else { throw OpenAIAccountClientError.notConnected }
        let taskID = UUID()
        let task = Task { try await self.requestRefresh(session: session, providerID: providerID) }
        refreshTasks[providerID] = (taskID, task)
        defer {
            if refreshTasks[providerID]?.id == taskID { refreshTasks.removeValue(forKey: providerID) }
        }
        do {
            let replacement = try await task.value
            try Task.checkCancellation()
            guard isCurrent(generation, for: providerID), !disconnecting.contains(providerID) else {
                throw OpenAIAccountClientError.cancelled
            }
            let result = try await commitRefresh(
                replacement,
                source: session,
                providerID: providerID,
                generation: generation,
                expectedRecord: record
            )
            return result
        } catch {
            try await normalizeRefreshFailure(
                error,
                source: session,
                providerID: providerID,
                generation: generation
            )
        }
    }

    private func normalizeRefreshFailure(
        _ error: any Error,
        source: OpenAIAccountSession,
        providerID: String,
        generation: UInt64
    ) async throws -> Never {
        if error is CancellationError {
            throw OpenAIAccountClientError.cancelled
        }
        guard let clientError = error as? OpenAIAccountClientError else { throw error }
        if clientError == .invalidGrant {
            try await clearUnusableGrant(source: source, providerID: providerID, generation: generation)
            throw OpenAIAccountClientError.reauthorizationRequired
        }
        throw clientError
    }

    private func clearUnusableGrant(
        source: OpenAIAccountSession,
        providerID: String,
        generation: UInt64
    ) async throws {
        guard isCurrent(generation, for: providerID), !disconnecting.contains(providerID),
              let current = try await storedSession(for: providerID),
              current.session.clientID == source.clientID,
              current.session.subject == source.subject,
              current.session.refreshToken == source.refreshToken
        else { return }
        var reauthorization = current.session
        reauthorization.accessToken = nil
        reauthorization.refreshToken = nil
        reauthorization.tokenType = nil
        reauthorization.expiresAt = nil
        try await saveSession(
            reauthorization,
            providerID: providerID,
            expectedRecord: current.raw,
            generation: generation
        )
    }

    private func requestRefresh(session: OpenAIAccountSession, providerID: String) async throws -> OpenAIAccountSession {
        guard let refreshToken = session.refreshToken else { throw OpenAIAccountClientError.notConnected }
        let request = OpenAIHTTP.formRequest(url: Self.tokenURL, values: [
            ("grant_type", "refresh_token"),
            ("client_id", session.clientID),
            ("refresh_token", refreshToken),
            ("resource", Self.resource)
        ])
        let response = try await OpenAIHTTP.send(request, using: transport)
        let tokens = try decodeTokenResponse(response.body)
        guard let accessToken = tokens.accessToken, isSafeValue(accessToken, maximumBytes: 4_096),
              let expiresIn = tokens.expiresIn, expiresIn.isFinite, (1...31_536_000).contains(expiresIn),
              let tokenType = tokens.tokenType, tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              tokens.refreshToken == nil || tokens.refreshToken.map({ isSafeFormValue($0, maximumBytes: 4_096) }) == true
        else { throw OpenAIAccountClientError.malformedResponse }
        let scopes: [String]
        if let scope = tokens.scope { scopes = try parseScopes(scope) }
        else { scopes = session.scopes }
        guard scopes.contains(Self.directScope) else { throw OpenAIAccountClientError.planUsageNotAuthorized }
        return OpenAIAccountSession(
            clientID: session.clientID,
            hostID: session.hostID,
            subject: session.subject,
            email: session.email,
            idToken: session.idToken,
            accessToken: accessToken,
            refreshToken: tokens.refreshToken ?? refreshToken,
            tokenType: "Bearer",
            expiresAt: now().timeIntervalSince1970 + expiresIn,
            scopes: scopes.sorted()
        )
    }

    private func commitRefresh(
        _ replacement: OpenAIAccountSession,
        source: OpenAIAccountSession,
        providerID: String,
        generation: UInt64,
        expectedRecord: String? = nil
    ) async throws -> String {
        guard isCurrent(generation, for: providerID), !disconnecting.contains(providerID) else {
            throw OpenAIAccountClientError.cancelled
        }
        guard let current = try await storedSession(for: providerID),
              current.session.clientID == source.clientID,
              current.session.subject == source.subject
        else { throw OpenAIAccountClientError.cancelled }
        guard let accessToken = replacement.accessToken else { throw OpenAIAccountClientError.malformedResponse }
        if current.session == replacement { return accessToken }
        if let expectedRecord, current.raw != expectedRecord {
            throw OpenAIAccountClientError.cancelled
        }
        do {
            try await saveSession(
                replacement,
                providerID: providerID,
                expectedRecord: current.raw,
                generation: generation
            )
        } catch OpenAIAccountClientError.cancelled {
            guard isCurrent(generation, for: providerID), !disconnecting.contains(providerID),
                  let committed = try await storedSession(for: providerID),
                  committed.session == replacement
            else { throw OpenAIAccountClientError.cancelled }
        }
        return accessToken
    }

    private func revoke(refreshToken: String, clientID: String) async throws {
        for attempt in 0...1 {
            do {
                let discovery = try await OpenAIHTTP.send(OpenAIHTTP.getRequest(url: Self.discoveryURL), using: transport)
                let document: DiscoveryDocument
                do {
                    document = try JSONDecoder().decode(DiscoveryDocument.self, from: discovery.body)
                } catch {
                    throw OpenAIAccountClientError.malformedResponse
                }
                guard document.revocationEndpoint == Self.revocationURL.absoluteString else {
                    throw OpenAIAccountClientError.invalidConfiguration
                }
                let request = OpenAIHTTP.formRequest(url: Self.revocationURL, values: [
                    ("token", refreshToken),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", clientID)
                ])
                _ = try await OpenAIHTTP.send(request, using: transport)
                return
            } catch let error as OpenAIAccountClientError {
                guard attempt == 0, error.isRetryable else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                throw OpenAIAccountClientError.cancelled
            } catch {
                guard attempt == 0 else { throw OpenAIAccountClientError.networkFailure }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func storedSession(for providerID: String) async throws -> (session: OpenAIAccountSession, raw: String)? {
        let key = Self.credentialKey(for: providerID)
        let raw: String?
        do {
            raw = try await withStorageLock { try await credentials.credential(for: key) }
        } catch is CancellationError {
            throw OpenAIAccountClientError.cancelled
        } catch let error as OpenAIAccountClientError {
            throw error
        } catch {
            throw OpenAIAccountClientError.storageUnavailable
        }
        guard let raw else { return nil }
        guard raw.utf8.count <= Self.maximumStoredSessionBytes,
              let session = try? JSONDecoder().decode(OpenAIAccountSession.self, from: Data(raw.utf8)),
              session.isValid
        else { throw OpenAIAccountClientError.invalidStoredSession }
        return (session, raw)
    }

    private func stableHostID() async throws -> String {
        do {
            return try await withStorageLock {
                if let value = try await credentials.credential(for: Self.hostIDCredentialKey) {
                    guard value.hasPrefix("urn:uuid:"), UUID(uuidString: String(value.dropFirst("urn:uuid:".count))) != nil else {
                        throw OpenAIAccountClientError.invalidStoredSession
                    }
                    return value
                }
                let value = "urn:uuid:\(UUID().uuidString.lowercased())"
                try await credentials.setCredential(value, for: Self.hostIDCredentialKey)
                return value
            }
        } catch is CancellationError {
            throw OpenAIAccountClientError.cancelled
        } catch let error as OpenAIAccountClientError {
            throw error
        } catch {
            throw OpenAIAccountClientError.storageUnavailable
        }
    }

    private func saveSession(
        _ session: OpenAIAccountSession,
        providerID: String,
        expectedRecord: String?,
        generation: UInt64
    ) async throws {
        guard isCurrent(generation, for: providerID) else { throw OpenAIAccountClientError.cancelled }
        guard session.isValid else { throw OpenAIAccountClientError.invalidStoredSession }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(session)
        } catch {
            throw OpenAIAccountClientError.storageUnavailable
        }
        guard data.count <= Self.maximumStoredSessionBytes else { throw OpenAIAccountClientError.storageUnavailable }
        let key = Self.credentialKey(for: providerID)
        let value = String(decoding: data, as: UTF8.self)
        let committed: Bool
        do {
            committed = try await withStorageLock {
                guard isCurrent(generation, for: providerID) else { throw OpenAIAccountClientError.cancelled }
                let current = try await credentials.credential(for: key)
                guard current == expectedRecord else { throw OpenAIAccountClientError.cancelled }
                try await credentials.setCredential(value, for: key)
                guard isCurrent(generation, for: providerID), !Task.isCancelled else {
                    if try await credentials.credential(for: key) == value {
                        try await credentials.setCredential(expectedRecord, for: key)
                    }
                    return false
                }
                return true
            }
        } catch is CancellationError {
            throw OpenAIAccountClientError.cancelled
        } catch let error as OpenAIAccountClientError {
            throw error
        } catch {
            throw OpenAIAccountClientError.storageUnavailable
        }
        guard committed else { throw OpenAIAccountClientError.cancelled }
    }

    private func withStorageLock<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        if storageLocked {
            await withCheckedContinuation { storageWaiters.append($0) }
        } else {
            storageLocked = true
        }
        defer {
            if storageWaiters.isEmpty {
                storageLocked = false
            } else {
                storageWaiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func advanceGeneration(for providerID: String) -> UInt64 {
        let generation = generations[providerID, default: 0] &+ 1
        generations[providerID] = generation
        return generation
    }

    private func isCurrent(_ generation: UInt64, for providerID: String) -> Bool {
        generations[providerID, default: 0] == generation
    }

    private func validateSignInAttempt(_ attemptID: UUID, generation: UInt64, providerID: String) throws {
        guard !Task.isCancelled,
              activeSignIns[providerID] == attemptID,
              isCurrent(generation, for: providerID)
        else { throw OpenAIAccountClientError.cancelled }
    }

    private func status(for session: OpenAIAccountSession) -> OpenAIAccountStatus {
        OpenAIAccountStatus(
            isConnected: session.idToken != nil,
            canUseChatGPTPlan: session.canUseChatGPTPlan,
            accountLabel: session.email
        )
    }

    private func decodeTokenResponse(_ data: Data) throws -> TokenResponse {
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw OpenAIAccountClientError.malformedResponse }
    }

    private func parseScopes(_ scope: String?) throws -> [String] {
        guard let scope else { return [] }
        guard scope.utf8.count <= 8_192,
              !scope.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw OpenAIAccountClientError.malformedResponse }
        let scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
        guard scopes.count <= 64, scopes.allSatisfy({ isSafeValue($0, maximumBytes: 128) }) else {
            throw OpenAIAccountClientError.malformedResponse
        }
        return scopes
    }

    private func callbackParameters(_ url: URL) throws -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.url != nil else {
            throw OpenAIAccountClientError.invalidCallback
        }
        let items = components.queryItems ?? []
        guard items.count <= 16 else { throw OpenAIAccountClientError.invalidCallback }
        var values: [String: String] = [:]
        for item in items {
            guard ["state", "code", "client_id", "scope", "error", "error_description", "iss"].contains(item.name),
                  let value = item.value,
                  values[item.name] == nil,
                  value.utf8.count <= 8_192,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw OpenAIAccountClientError.invalidCallback }
            values[item.name] = value
        }
        if let issuer = values["iss"], issuer != "https://auth.openai.com" {
            throw OpenAIAccountClientError.invalidCallback
        }
        return values
    }

    private func callbackMatches(_ callbackURL: URL, redirectURI: URL) -> Bool {
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        else { return false }
        return callback.scheme == redirect.scheme
            && callback.host == "127.0.0.1"
            && callback.host == redirect.host
            && callback.port == redirect.port
            && callback.path == "/auth/callback"
            && callback.path == redirect.path
            && callback.user == nil
            && callback.password == nil
            && callback.fragment == nil
    }

    private func isCallbackURI(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "http"
            && components.host == "127.0.0.1"
            && components.port.map { (1...65_535).contains($0) } == true
            && components.path == "/auth/callback"
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private func validateProviderID(_ providerID: String) throws {
        guard providerID != "host",
              providerID.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
        else {
            throw OpenAIAccountClientError.invalidConfiguration
        }
    }

    private func isSafeValue(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7e
            }
    }

    private func isSafeFormValue(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value <= 0x7e
            }
    }

    private func isValidClientID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{1,256}$", options: .regularExpression) != nil
    }

    private func isSafeDisplayName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func randomValue() throws -> String {
#if canImport(CryptoKit)
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URL
#else
        throw OpenAIAccountClientError.cryptographyUnavailable
#endif
    }

    private static func codeChallenge(_ verifier: String) throws -> String {
#if canImport(CryptoKit)
        return Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
#else
        throw OpenAIAccountClientError.cryptographyUnavailable
#endif
    }
}

struct OpenAIAccountSession: Codable, Equatable, Sendable {
    let clientID: String
    let hostID: String
    var subject: String
    var email: String?
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var tokenType: String?
    var expiresAt: TimeInterval?
    var scopes: [String]

    var canUseChatGPTPlan: Bool {
        scopes.contains("chatgpt.tokens.use.direct")
            && accessToken != nil
            && refreshToken != nil
            && tokenType?.caseInsensitiveCompare("Bearer") == .orderedSame
            && expiresAt != nil
    }

    var isValid: Bool {
        clientID.range(of: "^[A-Za-z0-9._-]{1,256}$", options: .regularExpression) != nil
            && hostID.hasPrefix("urn:uuid:")
            && UUID(uuidString: String(hostID.dropFirst("urn:uuid:".count))) != nil
            && !subject.isEmpty && subject.utf8.count <= 1_024
            && !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && (email?.utf8.count ?? 0) <= 320
            && (email?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true)
            && (idToken.map { isValidToken($0, maximumBytes: 65_536) } ?? true)
            && (accessToken.map { isValidToken($0, maximumBytes: 4_096) } ?? true)
            && (refreshToken.map { isValidFormToken($0, maximumBytes: 4_096) } ?? true)
            && (tokenType == nil || tokenType?.caseInsensitiveCompare("Bearer") == .orderedSame)
            && (expiresAt.map { $0.isFinite && $0 > 0 } ?? true)
            && scopes.count <= 64
            && scopes.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 && $0.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e } }
            && (hasAnyGrantFields == false || canUseChatGPTPlan)
    }

    private var hasAnyGrantFields: Bool {
        accessToken != nil || refreshToken != nil || tokenType != nil || expiresAt != nil
    }

    private func isValidToken(_ token: String, maximumBytes: Int) -> Bool {
        !token.isEmpty && token.utf8.count <= maximumBytes
            && token.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    private func isValidFormToken(_ token: String, maximumBytes: Int) -> Bool {
        !token.isEmpty && token.utf8.count <= maximumBytes
            && token.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e }
    }
}

private struct PendingSignIn: Sendable {
    let attemptID: UUID
    let generation: UInt64
    let redirectURI: URL
    let state: String
    let nonce: String
    let verifier: String
    let hostID: String
    let originalSession: OpenAIAccountSession?
    let originalRecord: String?
    let expiresAt: TimeInterval
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: TimeInterval?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct ModelCatalogResponse: Decodable {
    let models: [ModelCatalogEntry]

    enum CodingKeys: String, CodingKey {
        case models
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.models) {
            models = try container.decode([LegacyModelCatalogEntry].self, forKey: .models)
                .filter { $0.visibility == "list" }
                .map { ModelCatalogEntry(slug: $0.slug, displayName: $0.displayName) }
        } else {
            models = try container.decode([StandardModelCatalogEntry].self, forKey: .data)
                .map { ModelCatalogEntry(slug: $0.id, displayName: $0.displayName ?? $0.id) }
        }
    }
}

private struct ModelCatalogEntry {
    let slug: String
    let displayName: String
}

private struct LegacyModelCatalogEntry: Decodable {
    let slug: String
    let displayName: String
    let visibility: String

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case visibility
    }
}

private struct StandardModelCatalogEntry: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct DiscoveryDocument: Decodable {
    let revocationEndpoint: String
    enum CodingKeys: String, CodingKey { case revocationEndpoint = "revocation_endpoint" }
}

private extension OpenAIAccountClientError {
    var isRetryable: Bool {
        switch self {
        case .networkFailure: true
        case .requestFailed(let status): (500..<600).contains(status)
        default: false
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
