import Foundation
import ImrseCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OfficialAccountAuthorizationStart: Equatable, Sendable {
    case browser(authorizationURL: URL, callbackURL: URL, attemptID: UUID)
    case deviceCode(userCode: String, verificationURL: URL, expiresAt: Date, attemptID: UUID)
}

public struct OfficialAccountConnectionStatus: Equatable, Sendable {
    public let isConnected: Bool
    public let accountLabel: String?

    public init(isConnected: Bool, accountLabel: String?) {
        self.isConnected = isConnected
        self.accountLabel = accountLabel
    }
}

public struct OfficialAccountAccessToken: Equatable, Sendable {
    public let token: String
    public let expiresAt: Date?

    public init(token: String, expiresAt: Date?) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct OfficialAccountModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum OfficialAccountClientError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case invalidConfiguration
    case missingClientID
    case invalidCallback
    case stateMismatch
    case authorizationDenied
    case requiredScopeMissing
    case expiredAttempt
    case notConnected
    case reauthorizationRequired
    case clientMismatch
    case invalidStoredSession
    case cryptographyUnavailable
    case unsupportedOperation
    case requestFailed
    case networkFailure
    case responseTooLarge
    case malformedResponse
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Account sign-in was cancelled."
        case .invalidConfiguration: "Account provider configuration is invalid."
        case .missingClientID: "Add the registered public OAuth client ID to continue."
        case .invalidCallback, .stateMismatch, .expiredAttempt:
            "Account sign-in could not be verified. Start a new sign-in."
        case .authorizationDenied: "Account sign-in was not authorized."
        case .requiredScopeMissing: "The account did not grant a required permission. Reconnect to continue."
        case .notConnected: "Connect this account before using its models."
        case .reauthorizationRequired: "Reconnect this account to continue."
        case .clientMismatch: "This account was connected with a different OAuth client. Reconnect to continue."
        case .invalidStoredSession: "The saved account session is invalid. Reconnect this account."
        case .cryptographyUnavailable: "Secure account sign-in is unavailable on this platform."
        case .unsupportedOperation: "This operation is not supported for the selected account."
        case .requestFailed: "The account provider rejected a request."
        case .networkFailure: "The account provider could not be reached."
        case .responseTooLarge: "The account provider returned an oversized response."
        case .malformedResponse: "The account provider returned an invalid response."
        case .storageUnavailable: "Account credentials could not be read or saved securely."
        }
    }
}

public actor OfficialAccountClient {
    private static let openRouterAuthorizationURL = URL(string: "https://openrouter.ai/auth")!
    private static let openRouterKeyURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    private static let openRouterModelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private static let huggingFaceAuthorizationURL = URL(string: "https://huggingface.co/oauth/authorize")!
    private static let huggingFaceTokenURL = URL(string: "https://huggingface.co/oauth/token")!
    private static let huggingFaceUserInfoURL = URL(string: "https://huggingface.co/oauth/userinfo")!
    private static let huggingFaceModelsURL = URL(string: "https://router.huggingface.co/v1/models")!
    private static let githubDeviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let githubTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let githubUserURL = URL(string: "https://api.github.com/user")!
    private static let requiredHuggingFaceScopes: Set<String> = ["inference-api", "openid", "profile"]
    private static let maximumStoredBytes = 65_536
    private static let maximumOAuthResponseBytes = 65_536
    private static let maximumModelResponseBytes = 1_048_576

    private let credentials: any CredentialStore
    private let transport: any StreamingHTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var pending: [String: PendingAuthorization] = [:]
    private var operations: [String: (attemptID: UUID, task: Task<OfficialAccountConnectionStatus, any Error>)] = [:]
    private var refreshOperations: [RefreshTaskKey: Task<AccountSession, any Error>] = [:]
    private var activeAccessTokenCalls: [RefreshTaskKey: Int] = [:]
    private var generations: [String: UInt64] = [:]
    private var storageLocked = false
    private var storageWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
        now = { Date() }
        sleep = Self.defaultSleep
    }

    init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    public func beginAuthorization(
        for provider: ProviderConfiguration,
        redirectURI: URL? = nil
    ) async throws -> OfficialAccountAuthorizationStart {
        let context = try Self.context(for: provider)
        let generation = advanceGeneration(for: context.identifier)
        pending.removeValue(forKey: context.identifier)
        operations.removeValue(forKey: context.identifier)?.task.cancel()
        let attemptID = UUID()

        switch context.kind {
        case .openRouterAccount, .huggingFaceAccount:
            guard let redirectURI, Self.isLoopbackCallback(redirectURI) else {
                throw OfficialAccountClientError.invalidConfiguration
            }
            let state = try Self.randomURLToken()
            let verifier = try Self.randomURLToken()
            let challenge = try Self.codeChallenge(for: verifier)
            let authorizationURL = try Self.authorizationURL(
                for: context.kind,
                provider: provider,
                redirectURI: redirectURI,
                state: state,
                challenge: challenge
            )
            pending[context.identifier] = PendingAuthorization(
                attemptID: attemptID,
                generation: generation,
                providerID: provider.id,
                kind: context.kind,
                clientID: context.clientID,
                redirectURI: redirectURI,
                state: state,
                verifier: verifier,
                deviceCode: nil,
                expiresAt: nil,
                pollInterval: nil
            )
            return .browser(authorizationURL: authorizationURL, callbackURL: redirectURI, attemptID: attemptID)

        case .githubCopilot:
            let placeholder = PendingAuthorization(
                attemptID: attemptID,
                generation: generation,
                providerID: provider.id,
                kind: context.kind,
                clientID: context.clientID,
                redirectURI: nil,
                state: nil,
                verifier: nil,
                deviceCode: nil,
                expiresAt: nil,
                pollInterval: nil
            )
            pending[context.identifier] = placeholder
            var shouldKeepPending = false
            defer {
                if !shouldKeepPending { clearAttempt(context.identifier, attemptID: attemptID) }
            }
            let response = try await Self.send(
                Self.formRequest(
                    url: Self.githubDeviceCodeURL,
                    fields: [("client_id", try Self.requiredClientID(context.clientID)), ("scope", "read:user")]
                ),
                using: transport,
                maximumResponseBytes: Self.maximumOAuthResponseBytes
            )
            try checkGeneration(context.identifier, generation: generation)
            let device = try Self.decode(response, as: GitHubDeviceResponse.self)
            guard Self.isSafeCredential(device.deviceCode),
                  Self.isSafeDisplayText(device.userCode),
                  device.verificationURI == Self.githubDeviceVerificationURL,
                  (1...3_600).contains(device.expiresIn),
                  (1...60).contains(device.interval)
            else { throw OfficialAccountClientError.malformedResponse }
            let expiresAt = now().addingTimeInterval(TimeInterval(device.expiresIn))
            pending[context.identifier] = PendingAuthorization(
                attemptID: attemptID,
                generation: generation,
                providerID: provider.id,
                kind: context.kind,
                clientID: context.clientID,
                redirectURI: nil,
                state: nil,
                verifier: nil,
                deviceCode: device.deviceCode,
                expiresAt: expiresAt,
                pollInterval: TimeInterval(device.interval)
            )
            shouldKeepPending = true
            return .deviceCode(
                userCode: device.userCode,
                verificationURL: device.verificationURI,
                expiresAt: expiresAt,
                attemptID: attemptID
            )

        default:
            throw OfficialAccountClientError.unsupportedOperation
        }
    }

    public func completeAuthorization(
        for provider: ProviderConfiguration,
        callbackURL: URL
    ) async throws -> OfficialAccountConnectionStatus {
        let context = try Self.context(for: provider)
        guard context.kind != .githubCopilot,
              let attempt = pending[context.identifier],
              attempt.kind == context.kind,
              attempt.providerID == provider.id,
              attempt.clientID == context.clientID,
              let expectedRedirectURI = attempt.redirectURI,
              let expectedState = attempt.state,
              attempt.expiresAt.map({ $0 > now() }) ?? true
        else { throw OfficialAccountClientError.cancelled }
        guard Self.matchesCallback(callbackURL, redirectURI: expectedRedirectURI) else {
            throw OfficialAccountClientError.invalidCallback
        }
        let parameters = try Self.callbackParameters(callbackURL)
        guard parameters["state"] == expectedState else { throw OfficialAccountClientError.stateMismatch }
        if parameters["error"] != nil {
            clearAttempt(context.identifier, attemptID: attempt.attemptID)
            throw OfficialAccountClientError.authorizationDenied
        }
        guard let code = parameters["code"], Self.isSafeCredential(code) else {
            throw OfficialAccountClientError.invalidCallback
        }

        if let operation = operations[context.identifier], operation.attemptID == attempt.attemptID {
            return try await operation.task.value
        }
        let task = Task {
            try await self.exchangeBrowserCode(code, provider: provider, context: context, attempt: attempt)
        }
        operations[context.identifier] = (attempt.attemptID, task)
        return try await awaitAuthorizationTask(task, context: context, attemptID: attempt.attemptID)
    }

    public func completeDeviceAuthorization(
        for provider: ProviderConfiguration,
        attemptID: UUID
    ) async throws -> OfficialAccountConnectionStatus {
        let context = try Self.context(for: provider)
        guard context.kind == .githubCopilot,
              let attempt = pending[context.identifier],
              attempt.attemptID == attemptID,
              attempt.providerID == provider.id,
              attempt.clientID == context.clientID,
              attempt.kind == context.kind,
              attempt.expiresAt.map({ $0 > now() }) == true,
              attempt.deviceCode != nil,
              attempt.pollInterval != nil
        else { throw OfficialAccountClientError.cancelled }

        if let operation = operations[context.identifier], operation.attemptID == attemptID {
            return try await operation.task.value
        }
        let task = Task {
            try await self.pollGitHubDeviceCode(provider: provider, context: context, attempt: attempt)
        }
        operations[context.identifier] = (attemptID, task)
        return try await awaitAuthorizationTask(task, context: context, attemptID: attemptID)
    }

    public func cancelAuthorization(for provider: ProviderConfiguration, attemptID: UUID? = nil) {
        guard let context = try? Self.context(for: provider) else { return }
        cancelAuthorization(forIdentifier: context.identifier, attemptID: attemptID)
    }

    public func connectionStatus(for provider: ProviderConfiguration) async throws -> OfficialAccountConnectionStatus {
        let context = try Self.context(for: provider)
        let generation = generations[context.identifier, default: 0]
        guard let (session, _) = try await storedSession(for: provider, context: context) else {
            try checkGeneration(context.identifier, generation: generation)
            return OfficialAccountConnectionStatus(isConnected: false, accountLabel: nil)
        }
        try checkGeneration(context.identifier, generation: generation)
        if let expiresAt = session.expiresAt, expiresAt <= now(), session.refreshToken == nil {
            return OfficialAccountConnectionStatus(isConnected: false, accountLabel: nil)
        }
        return OfficialAccountConnectionStatus(isConnected: true, accountLabel: session.accountLabel)
    }

    public func availableModels(for provider: ProviderConfiguration) async throws -> [OfficialAccountModel] {
        let context = try Self.context(for: provider)
        let url: URL
        switch context.kind {
        case .openRouterAccount:
            guard provider.endpoint == URL(string: "https://openrouter.ai/api/v1")! else {
                throw OfficialAccountClientError.invalidConfiguration
            }
            url = Self.openRouterModelsURL
        case .huggingFaceAccount:
            guard provider.endpoint == URL(string: "https://router.huggingface.co/v1")! else {
                throw OfficialAccountClientError.invalidConfiguration
            }
            url = Self.huggingFaceModelsURL
        case .githubCopilot:
            throw OfficialAccountClientError.unsupportedOperation

        default:
            throw OfficialAccountClientError.unsupportedOperation
        }
        let credential = try await accessToken(for: provider)
        var request = Self.getRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let response = try await Self.send(request, using: transport, maximumResponseBytes: Self.maximumModelResponseBytes)
        let catalog = try Self.decode(response, as: ModelCatalogResponse.self)
        guard catalog.data.count <= 10_000,
              Set(catalog.data.map(\.id)).count == catalog.data.count,
              catalog.data.allSatisfy({
                  Self.isValidModelID($0.id)
                      && ($0.name.map(Self.isSafeDisplayText) ?? true)
              })
        else { throw OfficialAccountClientError.malformedResponse }
        return catalog.data.map { OfficialAccountModel(id: $0.id, displayName: $0.name ?? $0.id) }
    }

    public func accessToken(for provider: ProviderConfiguration) async throws -> OfficialAccountAccessToken {
        let context = try Self.context(for: provider)
        let generation = generations[context.identifier, default: 0]
        let refreshKey = RefreshTaskKey(
            identifier: context.identifier,
            clientID: context.clientID,
            generation: generation
        )
        activeAccessTokenCalls[refreshKey, default: 0] += 1
        defer { finishAccessTokenCall(for: refreshKey) }
        guard let (session, raw) = try await storedSession(for: provider, context: context) else {
            throw OfficialAccountClientError.notConnected
        }
        try checkGeneration(context.identifier, generation: generation)
        guard Self.isSafeCredential(session.accessToken) else { throw OfficialAccountClientError.invalidStoredSession }
        if let expiresAt = session.expiresAt, expiresAt <= now().addingTimeInterval(30) {
            guard context.kind == .huggingFaceAccount, let refreshToken = session.refreshToken else {
                throw OfficialAccountClientError.reauthorizationRequired
            }
            let task: Task<AccountSession, any Error>
            if let existing = refreshOperations[refreshKey] {
                task = existing
            } else {
                task = Task {
                    try await self.refreshHuggingFaceSession(
                        session,
                        raw: raw,
                        refreshToken: refreshToken,
                        provider: provider,
                        context: context,
                        generation: generation
                    )
                }
                refreshOperations[refreshKey] = task
            }
            let refreshed: AccountSession
            do {
                refreshed = try await task.value
            } catch is CancellationError {
                throw OfficialAccountClientError.cancelled
            }
            try checkGeneration(context.identifier, generation: generation)
            return OfficialAccountAccessToken(token: refreshed.accessToken, expiresAt: refreshed.expiresAt)
        }
        return OfficialAccountAccessToken(token: session.accessToken, expiresAt: session.expiresAt)
    }

    public func disconnect(for provider: ProviderConfiguration) async throws {
        let context = try Self.context(for: provider)
        _ = advanceGeneration(for: context.identifier)
        pending.removeValue(forKey: context.identifier)
        operations.removeValue(forKey: context.identifier)?.task.cancel()
        await acquireStorageLock()
        defer { releaseStorageLock() }
        do {
            try await credentials.setCredential(nil, for: Self.credentialKey(context))
        } catch {
            throw OfficialAccountClientError.storageUnavailable
        }
    }

    private func exchangeBrowserCode(
        _ code: String,
        provider: ProviderConfiguration,
        context: ProviderContext,
        attempt: PendingAuthorization
    ) async throws -> OfficialAccountConnectionStatus {
        defer { clearAttempt(context.identifier, attemptID: attempt.attemptID) }
        try checkAttempt(context.identifier, attempt: attempt)
        let session: AccountSession

        switch context.kind {
        case .openRouterAccount:
            guard let verifier = attempt.verifier else { throw OfficialAccountClientError.cancelled }
            let body = try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": verifier,
                "code_challenge_method": "S256"
            ])
            var request = Self.postRequest(url: Self.openRouterKeyURL)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let response = try await Self.send(request, using: transport, maximumResponseBytes: Self.maximumOAuthResponseBytes)
            try checkAttempt(context.identifier, attempt: attempt)
            let key = try Self.decode(response, as: OpenRouterKeyResponse.self).key
            guard Self.isSafeCredential(key) else { throw OfficialAccountClientError.malformedResponse }
            session = AccountSession(
                providerID: provider.id,
                kind: context.kind.rawValue,
                clientID: context.clientID,
                accessToken: key,
                refreshToken: nil,
                expiresAt: nil,
                accountLabel: nil,
                scopes: []
            )

        case .huggingFaceAccount:
            guard let verifier = attempt.verifier,
                  let redirectURI = attempt.redirectURI,
                  let clientID = context.clientID
            else { throw OfficialAccountClientError.cancelled }
            let response = try await Self.send(
                Self.formRequest(url: Self.huggingFaceTokenURL, fields: [
                    ("grant_type", "authorization_code"),
                    ("client_id", clientID),
                    ("code", code),
                    ("redirect_uri", redirectURI.absoluteString),
                    ("code_verifier", verifier)
                ]),
                using: transport,
                maximumResponseBytes: Self.maximumOAuthResponseBytes
            )
            try checkAttempt(context.identifier, attempt: attempt)
            let token = try Self.decode(response, as: OAuthTokenResponse.self)
            let validated = try Self.validateHuggingFaceToken(token, now: now(), existingScopes: nil, existingRefreshToken: nil)
            let accountLabel = try await huggingFaceAccountLabel(accessToken: validated.accessToken)
            try checkAttempt(context.identifier, attempt: attempt)
            session = AccountSession(
                providerID: provider.id,
                kind: context.kind.rawValue,
                clientID: context.clientID,
                accessToken: validated.accessToken,
                refreshToken: validated.refreshToken,
                expiresAt: validated.expiresAt,
                accountLabel: accountLabel,
                scopes: validated.scopes.sorted()
            )

        case .githubCopilot:
            throw OfficialAccountClientError.unsupportedOperation

        default:
            throw OfficialAccountClientError.unsupportedOperation
        }

        try await saveSession(session, for: context, generation: attempt.generation, attemptID: attempt.attemptID)
        return OfficialAccountConnectionStatus(isConnected: true, accountLabel: session.accountLabel)
    }

    private func pollGitHubDeviceCode(
        provider: ProviderConfiguration,
        context: ProviderContext,
        attempt: PendingAuthorization
    ) async throws -> OfficialAccountConnectionStatus {
        defer { clearAttempt(context.identifier, attemptID: attempt.attemptID) }
        guard let deviceCode = attempt.deviceCode,
              let expiresAt = attempt.expiresAt,
              var interval = attempt.pollInterval,
              let clientID = context.clientID
        else { throw OfficialAccountClientError.cancelled }
        let maximumAttempts = min(3_600, max(1, Int(expiresAt.timeIntervalSince(now()) / interval) + 1))

        for _ in 0..<maximumAttempts {
            try checkAttempt(context.identifier, attempt: attempt)
            guard expiresAt > now() else { throw OfficialAccountClientError.expiredAttempt }
            try await sleep(interval)
            try checkAttempt(context.identifier, attempt: attempt)
            let response = try await Self.send(
                Self.formRequest(url: Self.githubTokenURL, fields: [
                    ("client_id", clientID),
                    ("device_code", deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
                ]),
                using: transport,
                maximumResponseBytes: Self.maximumOAuthResponseBytes
            )
            try checkAttempt(context.identifier, attempt: attempt)
            let token = try Self.decode(response, as: GitHubDeviceTokenResponse.self)
            if let error = token.error {
                switch error {
                case "authorization_pending": continue
                case "slow_down":
                    interval = max(interval + 5, token.interval.map(TimeInterval.init) ?? 0)
                    continue
                case "access_denied": throw OfficialAccountClientError.authorizationDenied
                case "expired_token", "token_expired": throw OfficialAccountClientError.expiredAttempt
                default: throw OfficialAccountClientError.requestFailed
                }
            }

            guard let accessToken = token.accessToken,
                  let tokenType = token.tokenType,
                  tokenType.caseInsensitiveCompare("bearer") == .orderedSame,
                  Self.isSafeCredential(accessToken)
            else { throw OfficialAccountClientError.malformedResponse }
            let scopes = Self.scopeSet(token.scope ?? "")
            guard scopes.contains("read:user") || scopes.contains("user") else {
                throw OfficialAccountClientError.requiredScopeMissing
            }
            let accountLabel = try await githubAccountLabel(accessToken: accessToken)
            try checkAttempt(context.identifier, attempt: attempt)
            let expiresAt: Date?
            if let expiresIn = token.expiresIn {
                guard (1...31_536_000).contains(expiresIn) else { throw OfficialAccountClientError.malformedResponse }
                expiresAt = now().addingTimeInterval(TimeInterval(expiresIn))
            } else {
                expiresAt = nil
            }
            let session = AccountSession(
                providerID: provider.id,
                kind: context.kind.rawValue,
                clientID: context.clientID,
                accessToken: accessToken,
                refreshToken: token.refreshToken.flatMap { Self.isSafeCredential($0) ? $0 : nil },
                expiresAt: expiresAt,
                accountLabel: accountLabel,
                scopes: scopes.sorted()
            )
            try await saveSession(session, for: context, generation: attempt.generation, attemptID: attempt.attemptID)
            return OfficialAccountConnectionStatus(isConnected: true, accountLabel: accountLabel)
        }
        throw OfficialAccountClientError.expiredAttempt
    }

    private func refreshHuggingFaceSession(
        _ session: AccountSession,
        raw: String,
        refreshToken: String,
        provider: ProviderConfiguration,
        context: ProviderContext,
        generation: UInt64
    ) async throws -> AccountSession {
        guard let clientID = context.clientID else { throw OfficialAccountClientError.clientMismatch }
        let response = try await Self.send(
            Self.formRequest(url: Self.huggingFaceTokenURL, fields: [
                ("grant_type", "refresh_token"),
                ("client_id", clientID),
                ("refresh_token", refreshToken)
            ]),
            using: transport,
            maximumResponseBytes: Self.maximumOAuthResponseBytes
        )
        try checkGeneration(context.identifier, generation: generation)
        let token = try Self.decode(response, as: OAuthTokenResponse.self)
        let refreshed = try Self.validateHuggingFaceToken(
            token,
            now: now(),
            existingScopes: Set(session.scopes),
            existingRefreshToken: refreshToken
        )
        let replacement = AccountSession(
            providerID: provider.id,
            kind: context.kind.rawValue,
            clientID: context.clientID,
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            expiresAt: refreshed.expiresAt,
            accountLabel: session.accountLabel,
            scopes: refreshed.scopes.sorted()
        )
        try await saveSession(replacement, for: context, generation: generation, expectedRaw: raw)
        return replacement
    }

    private func huggingFaceAccountLabel(accessToken: String) async throws -> String {
        var request = Self.getRequest(url: Self.huggingFaceUserInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await Self.send(request, using: transport, maximumResponseBytes: Self.maximumOAuthResponseBytes)
        let user = try Self.decode(response, as: UserInfoResponse.self)
        guard let label = user.preferredUsername ?? user.name,
              Self.isSafeDisplayText(label)
        else { throw OfficialAccountClientError.malformedResponse }
        return label
    }

    private func githubAccountLabel(accessToken: String) async throws -> String {
        var request = Self.getRequest(url: Self.githubUserURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let response = try await Self.send(request, using: transport, maximumResponseBytes: Self.maximumOAuthResponseBytes)
        let user = try Self.decode(response, as: GitHubUserResponse.self)
        guard Self.isSafeDisplayText(user.login) else { throw OfficialAccountClientError.malformedResponse }
        return user.login
    }

    private func storedSession(
        for provider: ProviderConfiguration,
        context: ProviderContext
    ) async throws -> (AccountSession, String)? {
        let raw = try await readCredential(for: Self.credentialKey(context))
        guard let raw else { return nil }
        guard raw.utf8.count <= Self.maximumStoredBytes,
              let session = try? JSONDecoder().decode(AccountSession.self, from: Data(raw.utf8)),
              session.providerID == provider.id,
              session.kind == context.kind.rawValue
        else { throw OfficialAccountClientError.invalidStoredSession }
        guard session.clientID == context.clientID else { throw OfficialAccountClientError.clientMismatch }
        guard Self.isSafeCredential(session.accessToken),
              session.refreshToken.map(Self.isSafeCredential) ?? true,
              session.accountLabel.map(Self.isSafeDisplayText) ?? true
        else { throw OfficialAccountClientError.invalidStoredSession }
        switch context.kind {
        case .huggingFaceAccount:
            guard Self.requiredHuggingFaceScopes.isSubset(of: Set(session.scopes)) else {
                throw OfficialAccountClientError.invalidStoredSession
            }
        case .githubCopilot:
            let scopes = Set(session.scopes)
            guard scopes.contains("read:user") || scopes.contains("user") else {
                throw OfficialAccountClientError.invalidStoredSession
            }
        case .openRouterAccount:
            guard session.scopes.isEmpty else { throw OfficialAccountClientError.invalidStoredSession }
        default:
            throw OfficialAccountClientError.invalidStoredSession
        }
        return (session, raw)
    }

    private func saveSession(
        _ session: AccountSession,
        for context: ProviderContext,
        generation: UInt64,
        attemptID: UUID? = nil,
        expectedRaw: String? = nil
    ) async throws {
        let key = Self.credentialKey(context)
        let encoded: String
        do {
            let data = try JSONEncoder().encode(session)
            guard data.count <= Self.maximumStoredBytes,
                  let value = String(data: data, encoding: .utf8)
            else { throw OfficialAccountClientError.invalidStoredSession }
            encoded = value
        } catch let error as OfficialAccountClientError {
            throw error
        } catch {
            throw OfficialAccountClientError.invalidStoredSession
        }

        await acquireStorageLock()
        defer { releaseStorageLock() }
        try checkGeneration(context.identifier, generation: generation)
        if let attemptID, pending[context.identifier]?.attemptID != attemptID {
            throw OfficialAccountClientError.cancelled
        }
        let previous: String?
        do {
            previous = try await credentials.credential(for: key)
        } catch is CancellationError {
            throw OfficialAccountClientError.cancelled
        } catch {
            throw OfficialAccountClientError.storageUnavailable
        }
        if let expectedRaw, previous != expectedRaw { throw OfficialAccountClientError.cancelled }
        do {
            try await credentials.setCredential(encoded, for: key)
        } catch is CancellationError {
            try? await credentials.setCredential(previous, for: key)
            throw OfficialAccountClientError.cancelled
        } catch {
            try? await credentials.setCredential(previous, for: key)
            throw OfficialAccountClientError.storageUnavailable
        }
        if generations[context.identifier, default: 0] != generation
            || (attemptID.map { pending[context.identifier]?.attemptID != $0 } ?? false)
        {
            try? await credentials.setCredential(previous, for: key)
            throw OfficialAccountClientError.cancelled
        }
    }

    private func readCredential(for key: String) async throws -> String? {
        await acquireStorageLock()
        defer { releaseStorageLock() }
        do {
            return try await credentials.credential(for: key)
        } catch is CancellationError {
            throw OfficialAccountClientError.cancelled
        } catch {
            throw OfficialAccountClientError.storageUnavailable
        }
    }

    private func awaitAuthorizationTask(
        _ task: Task<OfficialAccountConnectionStatus, any Error>,
        context: ProviderContext,
        attemptID: UUID
    ) async throws -> OfficialAccountConnectionStatus {
        try await withTaskCancellationHandler {
            defer {
                if operations[context.identifier]?.attemptID == attemptID {
                    operations.removeValue(forKey: context.identifier)
                }
            }
            do {
                return try await task.value
            } catch is CancellationError {
                throw OfficialAccountClientError.cancelled
            }
        } onCancel: {
            Task { await self.cancelAuthorization(forIdentifier: context.identifier, attemptID: attemptID) }
        }
    }

    private func cancelAuthorization(forIdentifier identifier: String, attemptID: UUID?) {
        guard let active = pending[identifier], attemptID == nil || active.attemptID == attemptID else { return }
        _ = advanceGeneration(for: identifier)
        pending.removeValue(forKey: identifier)
        if operations[identifier]?.attemptID == active.attemptID {
            operations.removeValue(forKey: identifier)?.task.cancel()
        }
    }

    private func checkAttempt(_ identifier: String, attempt: PendingAuthorization) throws {
        try checkGeneration(identifier, generation: attempt.generation)
        guard !Task.isCancelled, pending[identifier]?.attemptID == attempt.attemptID else {
            throw OfficialAccountClientError.cancelled
        }
        if let expiresAt = attempt.expiresAt, expiresAt <= now() {
            throw OfficialAccountClientError.expiredAttempt
        }
    }

    private func checkGeneration(_ identifier: String, generation: UInt64) throws {
        guard generations[identifier, default: 0] == generation, !Task.isCancelled else {
            throw OfficialAccountClientError.cancelled
        }
    }

    private func clearAttempt(_ identifier: String, attemptID: UUID) {
        if pending[identifier]?.attemptID == attemptID { pending.removeValue(forKey: identifier) }
        if operations[identifier]?.attemptID == attemptID { operations.removeValue(forKey: identifier) }
    }

    private func advanceGeneration(for identifier: String) -> UInt64 {
        let next = generations[identifier, default: 0] &+ 1
        generations[identifier] = next
        for key in refreshOperations.keys.filter({ $0.identifier == identifier }) {
            refreshOperations.removeValue(forKey: key)?.cancel()
        }
        return next
    }

    private func finishAccessTokenCall(for key: RefreshTaskKey) {
        guard let count = activeAccessTokenCalls[key] else { return }
        guard count > 1 else {
            activeAccessTokenCalls.removeValue(forKey: key)
            refreshOperations.removeValue(forKey: key)
            return
        }
        activeAccessTokenCalls[key] = count - 1
    }

    private func acquireStorageLock() async {
        if !storageLocked {
            storageLocked = true
            return
        }
        await withCheckedContinuation { storageWaiters.append($0) }
    }

    private func releaseStorageLock() {
        guard !storageWaiters.isEmpty else {
            storageLocked = false
            return
        }
        storageWaiters.removeFirst().resume()
    }

    private static func context(for provider: ProviderConfiguration) throws -> ProviderContext {
        guard ProviderValidation.isValidIdentifier(provider.id), provider.requiresCredential else {
            throw OfficialAccountClientError.invalidConfiguration
        }
        let clientID: String?
        switch provider.kind {
        case .openRouterAccount:
            guard provider.oauthClientID == nil else { throw OfficialAccountClientError.invalidConfiguration }
            clientID = nil
        case .huggingFaceAccount, .githubCopilot:
            guard let configured = provider.oauthClientID,
                  let value = Self.normalizedClientID(configured)
            else { throw OfficialAccountClientError.missingClientID }
            clientID = value
        default:
            throw OfficialAccountClientError.unsupportedOperation
        }
        return ProviderContext(providerID: provider.id, kind: provider.kind, clientID: clientID)
    }

    private static func normalizedClientID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { return nil }
        return value
    }

    private static func requiredClientID(_ value: String?) throws -> String {
        guard let value, normalizedClientID(value) != nil else { throw OfficialAccountClientError.missingClientID }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func credentialKey(_ context: ProviderContext) -> String {
        "oauth:\(context.kind.rawValue):\(context.providerID)"
    }

    private static func authorizationURL(
        for kind: ProviderKind,
        provider: ProviderConfiguration,
        redirectURI: URL,
        state: String,
        challenge: String
    ) throws -> URL {
        let endpoint: URL
        let items: [URLQueryItem]
        switch kind {
        case .openRouterAccount:
            endpoint = openRouterAuthorizationURL
            items = [
                URLQueryItem(name: "callback_url", value: redirectURI.absoluteString),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
        case .huggingFaceAccount:
            endpoint = huggingFaceAuthorizationURL
            items = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: try requiredClientID(provider.oauthClientID)),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "scope", value: "openid profile inference-api"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
        default:
            throw OfficialAccountClientError.unsupportedOperation
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = items
        guard let url = components?.url else { throw OfficialAccountClientError.invalidConfiguration }
        return url
    }

    private static func randomURLToken() throws -> String {
        #if canImport(CryptoKit)
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        throw OfficialAccountClientError.cryptographyUnavailable
        #endif
    }

    private static func codeChallenge(for verifier: String) throws -> String {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        throw OfficialAccountClientError.cryptographyUnavailable
        #endif
    }

    private static func isLoopbackCallback(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              let port = components.port, (1...65_535).contains(port),
              url.absoluteString.utf8.count <= 4_096,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/")
        else { return false }
        return true
    }

    private static func matchesCallback(_ callback: URL, redirectURI: URL) -> Bool {
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              actual.scheme?.lowercased() == expected.scheme?.lowercased(),
              actual.host?.lowercased() == expected.host?.lowercased(),
              actual.port == expected.port,
              actual.percentEncodedPath == expected.percentEncodedPath,
              actual.user == nil, actual.password == nil, actual.fragment == nil,
              expected.user == nil, expected.password == nil, expected.query == nil, expected.fragment == nil
        else { return false }
        return true
    }

    private static func callbackParameters(_ url: URL) throws -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else { throw OfficialAccountClientError.invalidCallback }
        var parameters: [String: String] = [:]
        for item in queryItems {
            guard parameters[item.name] == nil, let value = item.value, Self.isSafeCredential(value) else {
                throw OfficialAccountClientError.invalidCallback
            }
            parameters[item.name] = value
        }
        return parameters
    }

    private static func validateHuggingFaceToken(
        _ response: OAuthTokenResponse,
        now: Date,
        existingScopes: Set<String>?,
        existingRefreshToken: String?
    ) throws -> ValidatedHuggingFaceToken {
        guard let accessToken = response.accessToken,
              Self.isSafeCredential(accessToken),
              response.tokenType?.caseInsensitiveCompare("bearer") == .orderedSame,
              let expiresIn = response.expiresIn,
              (1...31_536_000).contains(expiresIn)
        else { throw OfficialAccountClientError.malformedResponse }
        let scopes = response.scope.map(Self.scopeSet) ?? existingScopes ?? []
        guard Self.requiredHuggingFaceScopes.isSubset(of: scopes) else {
            throw OfficialAccountClientError.requiredScopeMissing
        }
        let refreshToken: String?
        if let replacement = response.refreshToken {
            guard Self.isSafeCredential(replacement) else { throw OfficialAccountClientError.malformedResponse }
            refreshToken = replacement
        } else {
            refreshToken = existingRefreshToken
        }
        return ValidatedHuggingFaceToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            scopes: scopes
        )
    }

    private static func scopeSet(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
    }

    private static func isSafeCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096
            && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    private static func isSafeDisplayText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 256
            && !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func isValidModelID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,511}$", options: .regularExpression) != nil
    }

    private static func formRequest(url: URL, fields: [(String, String)]) throws -> URLRequest {
        let body = fields.map { "\(formEncoded($0.0))=\(formEncoded($0.1))" }.joined(separator: "&")
        guard body.utf8.count <= maximumOAuthResponseBytes else { throw OfficialAccountClientError.invalidConfiguration }
        var request = postRequest(url: url)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    private static func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? ""
    }

    private static func postRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func getRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func send(
        _ request: URLRequest,
        using transport: any StreamingHTTPTransport,
        maximumResponseBytes: Int
    ) async throws -> Data {
        do {
            return try await OpenAIHTTP.send(
                request,
                using: transport,
                maximumResponseBytes: maximumResponseBytes
            ).body
        } catch let error as OpenAIAccountClientError {
            switch error {
            case .cancelled: throw OfficialAccountClientError.cancelled
            case .invalidGrant, .reauthorizationRequired:
                throw OfficialAccountClientError.reauthorizationRequired
            case .invalidClientConfiguration, .invalidConfiguration:
                throw OfficialAccountClientError.invalidConfiguration
            case .requestFailed(401), .requestFailed(403):
                throw OfficialAccountClientError.reauthorizationRequired
            case .responseTooLarge: throw OfficialAccountClientError.responseTooLarge
            case .networkFailure: throw OfficialAccountClientError.networkFailure
            default: throw OfficialAccountClientError.requestFailed
            }
        } catch {
            throw OfficialAccountClientError.networkFailure
        }
    }

    private static func decode<Value: Decodable>(_ data: Data, as type: Value.Type) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw OfficialAccountClientError.malformedResponse }
    }

    private static func defaultSleep(_ interval: TimeInterval) async throws {
        let bounded = min(max(interval, 0), 3_600)
        try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
    }
}

private struct RefreshTaskKey: Hashable {
    let identifier: String
    let clientID: String?
    let generation: UInt64
}

private struct ProviderContext: Sendable {
    let providerID: String
    let kind: ProviderKind
    let clientID: String?
    var identifier: String { "\(kind.rawValue):\(providerID)" }

    init(providerID: String, kind: ProviderKind, clientID: String?) {
        self.providerID = providerID
        self.kind = kind
        self.clientID = clientID
    }
}

private struct PendingAuthorization: Sendable {
    let attemptID: UUID
    let generation: UInt64
    let providerID: String
    let kind: ProviderKind
    let clientID: String?
    let redirectURI: URL?
    let state: String?
    let verifier: String?
    let deviceCode: String?
    let expiresAt: Date?
    let pollInterval: TimeInterval?
}

private struct AccountSession: Codable, Sendable {
    let providerID: String
    let kind: String
    let clientID: String?
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let accountLabel: String?
    let scopes: [String]
}

private struct ValidatedHuggingFaceToken {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scopes: Set<String>
}

private struct OpenRouterKeyResponse: Decodable {
    let key: String
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct UserInfoResponse: Decodable {
    let preferredUsername: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case preferredUsername = "preferred_username"
        case name
    }
}

private struct GitHubDeviceResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct GitHubDeviceTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let scope: String?
    let error: String?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case error
        case interval
    }
}

private struct GitHubUserResponse: Decodable {
    let login: String
}

private struct ModelCatalogResponse: Decodable {
    let data: [ModelEntry]
}

private struct ModelEntry: Decodable {
    let id: String
    let name: String?
}

private extension OfficialAccountClient {
    static let githubDeviceVerificationURL = URL(string: "https://github.com/login/device")!
}
