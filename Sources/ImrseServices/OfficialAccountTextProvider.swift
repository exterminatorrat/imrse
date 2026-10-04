import Foundation
import ImrseCore

public struct OfficialAccountTextProvider: TextProvider, Sendable {
    private let accountClient: OfficialAccountClient
    private let transport: any StreamingHTTPTransport

    public init(
        accountClient: OfficialAccountClient,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport()
    ) {
        self.accountClient = accountClient
        self.transport = transport
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        guard !request.localOnly else { throw ImrseError.providerUnavailable }
        let provider = request.provider
        let expectedEndpoint: URL
        switch provider.kind {
        case .openRouterAccount:
            expectedEndpoint = URL(string: "https://openrouter.ai/api/v1")!
        case .huggingFaceAccount:
            expectedEndpoint = URL(string: "https://router.huggingface.co/v1")!
        default:
            throw ImrseError.invalidConfiguration
        }
        guard provider.endpoint == expectedEndpoint, provider.requiresCredential else {
            throw ImrseError.invalidConfiguration
        }
        let token: OfficialAccountAccessToken
        do {
            token = try await accountClient.accessToken(for: provider)
        } catch let error as OfficialAccountClientError {
            throw Self.map(error)
        }
        let credentials = ScopedAccountCredentialStore(providerID: provider.id, token: token.token)
        var transportProvider = provider
        transportProvider.kind = provider.kind == .openRouterAccount ? .openRouter : .compatible
        transportProvider.oauthClientID = nil
        let transportRequest = TransformationRequest(
            text: request.text,
            instruction: request.instruction,
            provider: transportProvider,
            reportProvider: request.reportProvider,
            reportResponseMetadata: request.reportResponseMetadata
        )
        return try await OpenAICompatibleProvider(
            credentials: credentials,
            transport: transport,
            requireSuccessfulStreamTerminator: true
        ).stream(transportRequest)
    }

    private static func map(_ error: OfficialAccountClientError) -> ImrseError {
        switch error {
        case .notConnected: .accountNotConnected
        case .cancelled: .cancelled
        case .invalidConfiguration, .missingClientID, .cryptographyUnavailable, .unsupportedOperation:
            .invalidConfiguration
        case .authorizationDenied, .invalidCallback, .stateMismatch, .requiredScopeMissing,
             .expiredAttempt, .reauthorizationRequired, .clientMismatch, .invalidStoredSession:
            .accountAuthentication
        case .malformedResponse: .malformedResponse
        case .responseTooLarge: .outputTooLarge
        case .networkFailure: .network
        case .requestFailed, .storageUnavailable: .server
        }
    }
}

private struct ScopedAccountCredentialStore: CredentialStore {
    let providerID: String
    let token: String

    func credential(for providerID: String) async throws -> String? {
        providerID == self.providerID ? token : nil
    }

    func setCredential(_ value: String?, for providerID: String) async throws {
        throw OfficialAccountClientError.storageUnavailable
    }
}
