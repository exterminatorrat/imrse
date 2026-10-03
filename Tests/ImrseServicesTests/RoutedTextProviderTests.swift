import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore

final class RoutedTextProviderTests: XCTestCase {
    func testPartialPrimaryOutputPreventsFallbackAndIsNotConcatenated() async throws {
        let primary = ScriptedProvider(plans: [
            .partial(["discarded"], .network),
            .complete(["fallback"])
        ])
        let routed = RoutedTextProvider(primary: primary)
        let request = request()
        let stream = try await routed.stream(request)
        var output = ""
        do {
            for try await delta in stream { output += delta }
            XCTFail("An emitted primary delta must prevent fallback")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .network)
        }
        XCTAssertEqual(output, "discarded")
        let ids = await primary.providerIDs()
        XCTAssertEqual(ids, ["primary"])
    }

    func testExplicitTransientFallbackWorksBeforeAnyOutput() async throws {
        let primary = ScriptedProvider(plans: [
            .fail(.network),
            .complete(["fallback", " output"])
        ])
        let routed = RoutedTextProvider(primary: primary)

        let output = try await collect(routed, request: request())
        XCTAssertEqual(output, "fallback output")
        let ids = await primary.providerIDs()
        XCTAssertEqual(ids, ["primary", "fallback"])
    }

    func testAuthenticationFailureDoesNotUseConfiguredFallback() async throws {
        let primary = ScriptedProvider(plans: [
            .fail(.authentication),
            .complete(["must not be used"])
        ])
        let routed = RoutedTextProvider(primary: primary)
        await assertError(.authentication) {
            _ = try await collect(routed, request: request())
        }
        let ids = await primary.providerIDs()
        XCTAssertEqual(ids, ["primary"])
    }

    @MainActor
    func testProviderCallbackReportsPrimaryThenActualFallback() async throws {
        let primary = ScriptedProvider(plans: [.fail(.network), .complete(["fallback"])])
        let routed = RoutedTextProvider(primary: primary)
        let reports = ProviderReports()
        let report: @MainActor @Sendable (ProviderConfiguration) -> Void = { reports.ids.append($0.id) }

        let output = try await collect(routed, request: request(reportProvider: report))
        XCTAssertEqual(output, "fallback")
        XCTAssertEqual(reports.ids, ["primary", "fallback"])
    }

    @MainActor
    func testResponseMetadataCallbackIsMirroredToPrimaryAndFallbackRequests() async throws {
        let primary = ScriptedProvider(plans: [.fail(.network), .complete(["fallback"])])
        let routed = RoutedTextProvider(primary: primary)
        let reports = ProviderReports()
        let report: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.metadata.append($0) }

        let output = try await collect(routed, request: request(reportResponseMetadata: report))

        XCTAssertEqual(output, "fallback")
        let metadataCallbackCount = await primary.metadataCallbackCount()
        XCTAssertEqual(metadataCallbackCount, 2)
        let metadata = ResponseMetadata(detectedModel: "fallback-model", totalTokens: 11)
        await primary.reportResponseMetadata(metadata, through: 1)
        XCTAssertEqual(reports.metadata, [metadata])
    }

    @MainActor
    func testLatePrimaryMetadataCannotOverwritePausedFallbackMetadata() async throws {
        let primary = PausedFallbackProvider()
        let routed = RoutedTextProvider(primary: primary)
        let reports = ProviderReports()
        let report: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.metadata.append($0) }
        let stream = try await routed.stream(request(reportResponseMetadata: report))
        let consumer = Task { try await collect(stream) }

        await primary.waitForFallbackStart()
        await primary.reportResponseMetadata(ResponseMetadata(detectedModel: "late-primary"), through: 0)
        XCTAssertTrue(reports.metadata.isEmpty)

        let fallbackMetadata = ResponseMetadata(detectedModel: "fallback-model", totalTokens: 11)
        await primary.reportResponseMetadata(fallbackMetadata, through: 1)
        XCTAssertEqual(reports.metadata, [fallbackMetadata])
        await primary.yieldFallback("fallback")
        await primary.finishFallback()
        let output = try await consumer.value
        XCTAssertEqual(output, "fallback")
    }

    func testLocalOnlyRejectsCloudFallbackBeforeStartingProvider() async {
        let primary = ScriptedProvider(plans: [.complete(["local"])])
        let routed = RoutedTextProvider(primary: primary)
        await assertError(.localModelUnavailable) {
            _ = try await collect(routed, request: request(localOnly: true))
        }
        let ids = await primary.providerIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    private func request(
        localOnly: Bool = false,
        reportProvider: (@MainActor @Sendable (ProviderConfiguration) -> Void)? = nil,
        reportResponseMetadata: (@MainActor @Sendable (ResponseMetadata) -> Void)? = nil
    ) -> TransformationRequest {
        TransformationRequest(
            text: "selected",
            instruction: "rewrite",
            provider: provider(id: "primary", host: "primary.example.com"),
            localOnly: localOnly,
            fallbackProvider: provider(id: "fallback", host: "fallback.example.com"),
            reportProvider: reportProvider,
            reportResponseMetadata: reportResponseMetadata
        )
    }
}

private enum ProviderPlan: Sendable {
    case complete([String])
    case fail(ImrseError)
    case partial([String], ImrseError)
}

private actor ScriptedProvider: TextProvider {
    private var plans: [ProviderPlan]
    private var usedProviderIDs: [String] = []
    private var responseMetadataCallbacks: [@MainActor @Sendable (ResponseMetadata) -> Void] = []

    init(plans: [ProviderPlan]) { self.plans = plans }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        usedProviderIDs.append(request.provider.id)
        if let callback = request.reportResponseMetadata { responseMetadataCallbacks.append(callback) }
        let plan = plans.removeFirst()
        switch plan {
        case .fail(let error): throw error
        case .complete(let chunks):
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        case .partial(let chunks, let error):
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish(throwing: error)
            }
        }
    }

    func providerIDs() -> [String] { usedProviderIDs }
    func metadataCallbackCount() -> Int { responseMetadataCallbacks.count }

    func reportResponseMetadata(_ metadata: ResponseMetadata, through index: Int) async {
        guard responseMetadataCallbacks.indices.contains(index) else { return }
        await responseMetadataCallbacks[index](metadata)
    }
}

private actor PausedFallbackProvider: TextProvider {
    private var calls = 0
    private var callbacks: [(@MainActor @Sendable (ResponseMetadata) -> Void)?] = []
    private var fallbackContinuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var fallbackWaiters: [CheckedContinuation<Void, Never>] = []

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        calls += 1
        callbacks.append(request.reportResponseMetadata)
        if calls == 1 { throw ImrseError.network }

        let pair = AsyncThrowingStream<String, any Error>.makeStream()
        fallbackContinuation = pair.continuation
        for waiter in fallbackWaiters { waiter.resume() }
        fallbackWaiters.removeAll()
        return pair.stream
    }

    func waitForFallbackStart() async {
        while calls < 2 {
            await withCheckedContinuation { fallbackWaiters.append($0) }
        }
    }

    func reportResponseMetadata(_ metadata: ResponseMetadata, through index: Int) async {
        guard callbacks.indices.contains(index), let callback = callbacks[index] else { return }
        await callback(metadata)
    }

    func yieldFallback(_ value: String) {
        fallbackContinuation?.yield(value)
    }

    func finishFallback() {
        fallbackContinuation?.finish()
        fallbackContinuation = nil
    }
}

@MainActor
private final class ProviderReports {
    var ids: [String] = []
    var metadata: [ResponseMetadata] = []
}

private func provider(id: String, host: String) -> ProviderConfiguration {
    ProviderConfiguration(
        id: id,
        name: id,
        kind: .compatible,
        endpoint: URL(string: "https://\(host)/v1")!,
        model: "model-1"
    )
}

private func collect(_ provider: RoutedTextProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    return try await collect(stream)
}

private func collect(_ stream: AsyncThrowingStream<String, any Error>) async throws -> String {
    var output = ""
    for try await delta in stream { output += delta }
    return output
}

private func assertError(
    _ expected: ImrseError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ImrseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), received \(error)", file: file, line: line)
    }
}
