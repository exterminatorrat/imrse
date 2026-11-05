import Foundation
import Testing
@testable import ImrseLocal

struct ManagedLocalGenerationSessionTests {
    @Test
    func successWaitsForProducerAfterStreamFinishes() async throws {
        let probe = LifecycleProbe()
        let producerStarted = Signal()
        let producerRelease = Signal()
        let producerFinished = Signal()
        let producerCancelled = Signal()
        let consumerFinished = Signal()

        let task = launchSession(
            probe: probe,
            start: {
                let (stream, continuation) = AsyncStream<Int>.makeStream()
                continuation.finish()
                let producer = makeProducer(
                    probe: probe,
                    started: producerStarted,
                    release: producerRelease,
                    finished: producerFinished,
                    cancelled: producerCancelled
                )
                return (stream, producer)
            },
            consume: { stream in
                for await _ in stream {}
                await consumerFinished.signal()
                return 42
            }
        )

        await producerStarted.wait()
        await consumerFinished.wait()

        let beforeProducerRelease = probe.snapshot()
        #expect(beforeProducerRelease.cacheReleaseCount == 0)
        #expect(!beforeProducerRelease.producerFinished)
        #expect(!beforeProducerRelease.runReturned)

        await producerRelease.signal()

        let output = try await task.value
        #expect(output == 42)
        expectJoinedBeforeCacheRelease(probe, producerWasCancelled: false)
    }

    @Test
    func consumerErrorCancelsAndJoinsProducerBeforeCleanup() async {
        let probe = LifecycleProbe()
        let producerStarted = Signal()
        let producerRelease = Signal()
        let producerFinished = Signal()
        let producerCancelled = Signal()

        let task = launchSession(
            probe: probe,
            start: {
                let stream = AsyncStream<Int> { $0.finish() }
                let producer = makeProducer(
                    probe: probe,
                    started: producerStarted,
                    release: producerRelease,
                    finished: producerFinished,
                    cancelled: producerCancelled
                )
                return (stream, producer)
            },
            consume: { _ in
                await producerStarted.wait()
                throw SessionFailure.consumer
            }
        )

        await producerCancelled.wait()
        await producerRelease.signal()
        await producerFinished.wait()
        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("Expected the consumer error to propagate")
            return
        }

        #expect((error as? SessionFailure) == SessionFailure.consumer)
        expectJoinedBeforeCacheRelease(probe, producerWasCancelled: true)
    }

    @Test
    func consumerCancellationCancelsAndJoinsProducerBeforeCleanup() async {
        let probe = LifecycleProbe()
        let producerStarted = Signal()
        let producerRelease = Signal()
        let producerFinished = Signal()
        let producerCancelled = Signal()
        let consumerStarted = Signal()
        let consumerRelease = Signal()

        let task = launchSession(
            probe: probe,
            start: {
                let stream = AsyncStream<Int> { $0.finish() }
                let producer = makeProducer(
                    probe: probe,
                    started: producerStarted,
                    release: producerRelease,
                    finished: producerFinished,
                    cancelled: producerCancelled
                )
                return (stream, producer)
            },
            consume: { _ in
                await producerStarted.wait()
                await consumerStarted.signal()
                return try await withTaskCancellationHandler {
                    await consumerRelease.wait()
                    try Task.checkCancellation()
                    return 1
                } onCancel: {
                    Task { await consumerRelease.signal() }
                }
            }
        )

        await consumerStarted.wait()
        task.cancel()
        if probe.snapshot().producerWasCancelled {
            await producerCancelled.wait()
        } else {
            await producerRelease.signal()
        }
        await producerRelease.signal()
        await producerFinished.wait()

        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("Expected consumer cancellation to propagate")
            return
        }

        #expect(error is CancellationError)
        expectJoinedBeforeCacheRelease(probe, producerWasCancelled: true)
    }

    @Test
    func cancellationAfterConsumerFinishesCancelsAndJoinsProducer() async {
        let probe = LifecycleProbe()
        let producerStarted = Signal()
        let producerRelease = Signal()
        let producerFinished = Signal()
        let producerCancelled = Signal()
        let consumerFinished = Signal()

        let task = launchSession(
            probe: probe,
            start: {
                let (stream, continuation) = AsyncStream<Int>.makeStream()
                continuation.finish()
                let producer = makeProducer(
                    probe: probe,
                    started: producerStarted,
                    release: producerRelease,
                    finished: producerFinished,
                    cancelled: producerCancelled
                )
                return (stream, producer)
            },
            consume: { stream in
                for await _ in stream {}
                await consumerFinished.signal()
                return 7
            }
        )

        await producerStarted.wait()
        await consumerFinished.wait()
        #expect(!probe.snapshot().producerFinished)

        task.cancel()
        if probe.snapshot().producerWasCancelled {
            await producerCancelled.wait()
        } else {
            await producerRelease.signal()
        }
        await producerRelease.signal()
        await producerFinished.wait()

        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("Expected cancellation after consumption to propagate")
            return
        }

        #expect(error is CancellationError)
        expectJoinedBeforeCacheRelease(probe, producerWasCancelled: true)
    }

    @Test
    func startFailureStillReleasesCacheOnceAndPreservesError() async {
        let probe = LifecycleProbe()
        let task = launchSession(
            probe: probe,
            start: { throw SessionFailure.start },
            consume: { _ in 0 }
        )

        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("Expected the start error to propagate")
            return
        }

        #expect((error as? SessionFailure) == SessionFailure.start)

        let snapshot = probe.snapshot()
        #expect(snapshot.cacheReleaseCount == 1)
        #expect(snapshot.cacheReleaseSawProducerFinished == false)
        #expect(snapshot.cacheReleaseSawResourceDeallocated == false)
        #expect(snapshot.runReturned)
    }
}

private enum SessionFailure: Error, Equatable {
    case start
    case consumer
}

private actor Signal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }
}

private final class LifecycleProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        let cacheReleaseCount: Int
        let producerFinished: Bool
        let producerWasCancelled: Bool
        let resourceDeallocated: Bool
        let cacheReleaseSawProducerFinished: Bool?
        let cacheReleaseSawResourceDeallocated: Bool?
        let runReturned: Bool
    }

    private let lock = NSLock()
    private var cacheReleaseCount = 0
    private var producerFinished = false
    private var producerWasCancelled = false
    private var resourceDeallocated = false
    private var cacheReleaseSawProducerFinished: Bool?
    private var cacheReleaseSawResourceDeallocated: Bool?
    private var runReturned = false

    func releaseCache() {
        lock.lock()
        cacheReleaseCount += 1
        if cacheReleaseCount == 1 {
            cacheReleaseSawProducerFinished = producerFinished
            cacheReleaseSawResourceDeallocated = resourceDeallocated
        }
        lock.unlock()
    }

    func recordProducerCancellation() {
        lock.lock()
        producerWasCancelled = true
        lock.unlock()
    }

    func recordProducerFinished() {
        lock.lock()
        producerFinished = true
        lock.unlock()
    }

    func recordResourceDeallocation() {
        lock.lock()
        resourceDeallocated = true
        lock.unlock()
    }

    func recordRunReturned() {
        lock.lock()
        runReturned = true
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            cacheReleaseCount: cacheReleaseCount,
            producerFinished: producerFinished,
            producerWasCancelled: producerWasCancelled,
            resourceDeallocated: resourceDeallocated,
            cacheReleaseSawProducerFinished: cacheReleaseSawProducerFinished,
            cacheReleaseSawResourceDeallocated: cacheReleaseSawResourceDeallocated,
            runReturned: runReturned
        )
    }
}

private final class ProducerResource: Sendable {
    private let probe: LifecycleProbe

    init(probe: LifecycleProbe) {
        self.probe = probe
    }

    deinit {
        probe.recordResourceDeallocation()
    }
}

private actor ProducerResourceOwner {
    private var resource: ProducerResource?

    init(probe: LifecycleProbe) {
        resource = ProducerResource(probe: probe)
    }

    func release() {
        resource = nil
    }
}

private func makeProducer(
    probe: LifecycleProbe,
    started: Signal,
    release: Signal,
    finished: Signal,
    cancelled: Signal
) -> Task<Void, Never> {
    let resources = ProducerResourceOwner(probe: probe)
    return Task {
        await started.signal()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            probe.recordProducerCancellation()
            Task { await cancelled.signal() }
        }
        await resources.release()
        probe.recordProducerFinished()
        await finished.signal()
    }
}

private func launchSession(
    probe: LifecycleProbe,
    start: @escaping @Sendable () async throws -> (AsyncStream<Int>, Task<Void, Never>),
    consume: @escaping @Sendable (AsyncStream<Int>) async throws -> Int
) -> Task<Int, any Error> {
    Task {
        defer { probe.recordRunReturned() }
        return try await ManagedLocalGenerationSession.run(
            start: start,
            consume: consume,
            releaseCache: { probe.releaseCache() }
        )
    }
}

private func expectJoinedBeforeCacheRelease(
    _ probe: LifecycleProbe,
    producerWasCancelled: Bool
) {
    let snapshot = probe.snapshot()
    #expect(snapshot.cacheReleaseCount == 1)
    #expect(snapshot.producerFinished)
    #expect(snapshot.producerWasCancelled == producerWasCancelled)
    #expect(snapshot.resourceDeallocated)
    #expect(snapshot.cacheReleaseSawProducerFinished == true)
    #expect(snapshot.cacheReleaseSawResourceDeallocated == true)
    #expect(snapshot.runReturned)
}
