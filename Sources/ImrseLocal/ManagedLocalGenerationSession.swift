import Foundation

enum ManagedLocalGenerationSession {
    static func run<Event: Sendable, Output: Sendable>(
        start: @Sendable () async throws -> (AsyncStream<Event>, Task<Void, Never>),
        consume: @Sendable (AsyncStream<Event>) async throws -> Output,
        releaseCache: @Sendable () -> Void
    ) async throws -> Output {
        defer { releaseCache() }
        return try await consumeUntilStopped()

        func consumeUntilStopped() async throws -> Output {
            try Task.checkCancellation()
            let (stream, producer) = try await start()
            return try await withTaskCancellationHandler {
                do {
                    let output = try await consume(stream)
                    await producer.value
                    try Task.checkCancellation()
                    return output
                } catch {
                    producer.cancel()
                    await producer.value
                    throw error
                }
            } onCancel: {
                producer.cancel()
            }
        }
    }
}
