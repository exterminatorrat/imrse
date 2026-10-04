#if os(macOS)
import Foundation
import ImrseCore

public struct CopilotRuntimeRequest: Sendable {
    public let model: String
    public let instruction: String
    public let text: String

    public init(model: String, instruction: String, text: String) {
        self.model = model
        self.instruction = instruction
        self.text = text
    }
}

public enum CopilotRuntimeAuthentication: Sendable {
    case staticToken(accessToken: String, login: String)
}

public protocol CopilotRuntime: Sendable {
    func complete(
        _ request: CopilotRuntimeRequest,
        authentication: CopilotRuntimeAuthentication
    ) async throws -> String
}

public enum CopilotRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case runtimeUnavailable
    case incompatibleRuntime
    case invalidConfiguration
    case authenticationFailed
    case tokenLifetimeInsufficient
    case permissionDenied
    case toolRequestDenied
    case timeout
    case cancelled
    case outputTooLarge
    case malformedResponse
    case interrupted
    case emptyOutput
    case runtimeFailed

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "Select an installed GitHub Copilot runtime to use Copilot models."
        case .incompatibleRuntime:
            "The selected GitHub Copilot runtime uses an unsupported protocol version."
        case .invalidConfiguration:
            "GitHub Copilot runtime configuration is invalid."
        case .authenticationFailed:
            "Connect a GitHub account with Copilot access before using this model."
        case .tokenLifetimeInsufficient:
            "Reconnect the GitHub account to refresh its Copilot access token."
        case .permissionDenied:
            "GitHub Copilot requested a permission that this integration denies."
        case .toolRequestDenied:
            "GitHub Copilot requested a tool that this integration does not provide."
        case .timeout:
            "GitHub Copilot took too long to respond."
        case .cancelled:
            "GitHub Copilot request was cancelled."
        case .outputTooLarge:
            "GitHub Copilot returned an oversized response."
        case .malformedResponse:
            "GitHub Copilot returned an invalid response."
        case .interrupted:
            "GitHub Copilot stopped before completing its response."
        case .emptyOutput:
            "GitHub Copilot did not return a final text response."
        case .runtimeFailed:
            "GitHub Copilot could not complete the request."
        }
    }
}

public struct CopilotTextProvider: TextProvider, Sendable {
    public static let endpoint = URL(string: "https://api.githubcopilot.com")!
    private static let maximumInputBytes = 1_048_576
    private static let maximumInstructionBytes = 8_192
    private static let absoluteMaximumOutputBytes = 4_194_304

    private let accountClient: OfficialAccountClient
    private let runtime: any CopilotRuntime
    private let maximumOutputBytes: Int
    private let now: @Sendable () -> Date

    public init(
        accountClient: OfficialAccountClient,
        runtime: any CopilotRuntime,
        maximumOutputBytes: Int = 1_048_576,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountClient = accountClient
        self.runtime = runtime
        self.maximumOutputBytes = min(max(maximumOutputBytes, 1), Self.absoluteMaximumOutputBytes)
        self.now = now
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        guard !request.localOnly else { throw ImrseError.providerUnavailable }
        try ProviderValidation.validate(request.provider)
        guard request.provider.kind == .githubCopilot,
              request.provider.endpoint == Self.endpoint,
              request.text.utf8.count <= Self.maximumInputBytes,
              request.instruction.utf8.count <= Self.maximumInstructionBytes,
              ProviderValidation.isValidInstruction(request.instruction),
              !request.text.isEmpty
        else { throw ImrseError.invalidConfiguration }

        let runtimeRequest = CopilotRuntimeRequest(
            model: request.provider.model,
            instruction: request.instruction,
            text: request.text
        )
        let runtime = self.runtime
        let provider = self
        let providerConfiguration = request.provider
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let accountToken: OfficialAccountAccessToken
                    do {
                        accountToken = try await provider.accountClient.accessToken(for: providerConfiguration)
                    } catch {
                        throw CopilotRuntimeError.authenticationFailed
                    }
                    guard !accountToken.token.isEmpty, accountToken.token.utf8.count <= 8_192 else {
                        throw CopilotRuntimeError.authenticationFailed
                    }

                    if let expiration = accountToken.expiresAt {
                        let remainingLifetime = expiration.timeIntervalSince(provider.now())
                        guard remainingLifetime.isFinite,
                              remainingLifetime > 3_600,
                              remainingLifetime < Double(Int.max)
                        else { throw CopilotRuntimeError.tokenLifetimeInsufficient }
                    }

                    let status: OfficialAccountConnectionStatus
                    do {
                        status = try await provider.accountClient.connectionStatus(for: providerConfiguration)
                    } catch {
                        throw CopilotRuntimeError.authenticationFailed
                    }
                    guard status.isConnected,
                          let login = status.accountLabel,
                          !login.isEmpty,
                          login.utf8.count <= 256
                    else { throw CopilotRuntimeError.authenticationFailed }

                    let authentication = CopilotRuntimeAuthentication.staticToken(
                        accessToken: accountToken.token,
                        login: login
                    )
                    let output = try await runtime.complete(runtimeRequest, authentication: authentication)
                    try Task.checkCancellation()
                    guard output.utf8.count <= provider.maximumOutputBytes else {
                        throw CopilotRuntimeError.outputTooLarge
                    }
                    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CopilotRuntimeError.emptyOutput
                    }
                    if case .terminated = continuation.yield(output) {
                        throw CopilotRuntimeError.cancelled
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ImrseError.cancelled)
                } catch let error as ImrseError {
                    continuation.finish(throwing: error)
                } catch let error as CopilotRuntimeError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: ImrseError.server)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    private static func map(_ error: CopilotRuntimeError) -> ImrseError {
        switch error {
        case .runtimeUnavailable:
            .copilotRuntimeUnavailable
        case .incompatibleRuntime:
            .copilotRuntimeIncompatible
        case .invalidConfiguration:
            .invalidConfiguration
        case .authenticationFailed, .tokenLifetimeInsufficient:
            .copilotAuthentication
        case .permissionDenied:
            .copilotPermissionDenied
        case .toolRequestDenied:
            .copilotToolDenied
        case .timeout:
            .timeout
        case .cancelled:
            .cancelled
        case .outputTooLarge:
            .outputTooLarge
        case .malformedResponse:
            .malformedResponse
        case .interrupted:
            .interruptedStream
        case .emptyOutput:
            .emptyOutput
        case .runtimeFailed:
            .server
        }
    }
}
#endif
