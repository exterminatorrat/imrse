import Foundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RoutedTextProvider: TextProvider, Sendable {
    private static let maximumOutputBytes = 8 * 1_024 * 1_024
    private let primary: any TextProvider

    public init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport(),
        timeout: TimeInterval = 60,
        maximumOutputBytes: Int = 1_000_000
    ) {
        primary = OpenAICompatibleProvider(
            credentials: credentials,
            transport: transport,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    public init(primary: any TextProvider) {
        self.primary = primary
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        try ProviderValidation.validate(request.provider)
        var safeFallback = request.fallbackProvider
        if let fallback = safeFallback {
            try ProviderValidation.validate(fallback)
            guard fallback.id != request.provider.id else { throw ImrseError.invalidConfiguration }
        }
        if request.localOnly {
            guard ProviderValidation.isLocal(request.provider) else { throw ImrseError.localModelUnavailable }
            if safeFallback.map({ !ProviderValidation.isLocal($0) }) == true { safeFallback = nil }
        }
        if ProviderValidation.isAccount(request.provider), let candidate = safeFallback, !ProviderValidation.isLocal(candidate) {
            safeFallback = nil
        }

        let routedRequest = TransformationRequest(
            text: request.text,
            instruction: request.instruction,
            provider: request.provider,
            localOnly: request.localOnly,
            fallbackProvider: safeFallback,
            reportProvider: request.reportProvider,
            reportResponseMetadata: request.reportResponseMetadata
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(routedRequest, continuation: continuation)
                    continuation.finish()
                } catch let failure as StreamFailure {
                    continuation.finish(throwing: Self.normalized(failure.underlying))
                } catch {
                    continuation.finish(throwing: Self.normalized(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: TransformationRequest,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let metadataCallbackGate = ResponseMetadataCallbackGate()
        let primaryAttemptID = UUID()
        await metadataCallbackGate.activate(primaryAttemptID)
        let primaryMetadataCallback = await metadataCallbackGate.callback(
            for: primaryAttemptID,
            report: request.reportResponseMetadata
        )
        let primaryRequest = TransformationRequest(
            text: request.text,
            instruction: request.instruction,
            provider: request.provider,
            localOnly: request.localOnly,
            reportProvider: request.reportProvider,
            reportResponseMetadata: primaryMetadataCallback
        )
        do {
            await request.reportProvider?(request.provider)
            try Task.checkCancellation()
            let stream = try await primary.stream(primaryRequest)
            try await forward(stream, continuation: continuation)
        } catch {
            let failure = error as? StreamFailure
            let underlying = failure?.underlying ?? error
            guard failure?.emittedOutput != true,
                  !Task.isCancelled,
                  let fallback = request.fallbackProvider,
                  Self.isEligibleFallback(underlying)
            else { throw underlying }

            let fallbackAttemptID = UUID()
            await metadataCallbackGate.activate(fallbackAttemptID)
            let fallbackMetadataCallback = await metadataCallbackGate.callback(
                for: fallbackAttemptID,
                report: request.reportResponseMetadata
            )
            let fallbackRequest = TransformationRequest(
                text: request.text,
                instruction: request.instruction,
                provider: fallback,
                localOnly: request.localOnly,
                reportProvider: request.reportProvider,
                reportResponseMetadata: fallbackMetadataCallback
            )
            await fallbackRequest.reportProvider?(fallback)
            try Task.checkCancellation()
            let fallbackStream = try await primary.stream(fallbackRequest)
            try await forward(fallbackStream, continuation: continuation)
        }
    }

    private func forward(
        _ stream: AsyncThrowingStream<String, any Error>,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        var emittedOutput = false
        var outputBytes = 0
        do {
            for try await delta in stream {
                try Task.checkCancellation()
                outputBytes += delta.utf8.count
                guard outputBytes <= Self.maximumOutputBytes else { throw ImrseError.outputTooLarge }
                guard !delta.isEmpty else { continue }
                if case .terminated = continuation.yield(delta) { throw CancellationError() }
                emittedOutput = true
            }
        } catch {
            throw StreamFailure(underlying: error, emittedOutput: emittedOutput)
        }
    }

    private static func isEligibleFallback(_ error: any Error) -> Bool {
        if let error = error as? ImrseError {
            return error == .network || error == .timeout || error == .rateLimited || error == .server
        }
        guard let error = error as? URLError else { return false }
        return [
            URLError.Code.timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed
        ].contains(error.code)
    }

    private static func normalized(_ error: any Error) -> ImrseError {
        if let failure = error as? StreamFailure { return normalized(failure.underlying) }
        if let error = error as? ImrseError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if error.code == .timedOut { return .timeout }
        }
        return .network
    }

    private struct StreamFailure: Error {
        let underlying: any Error
        let emittedOutput: Bool
    }
}

@MainActor
private final class ResponseMetadataCallbackGate {
    private var activeAttemptID: UUID?

    func activate(_ attemptID: UUID) {
        activeAttemptID = attemptID
    }

    func callback(
        for attemptID: UUID,
        report: (@MainActor @Sendable (ResponseMetadata) -> Void)?
    ) -> (@MainActor @Sendable (ResponseMetadata) -> Void)? {
        guard let report else { return nil }
        return { [self] metadata in
            guard activeAttemptID == attemptID else { return }
            report(metadata)
        }
    }
}
