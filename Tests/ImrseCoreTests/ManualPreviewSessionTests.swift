import Foundation
import XCTest
@testable import ImrseCore

private actor ManualProvider: TextProvider {
    var requests: [TransformationRequest] = []
    let fragments: [String]
    let failure: ImrseError?
    var gate: CheckedContinuation<Void, Never>?
    let blocked: Bool
    init(_ fragments: [String] = ["result"], failure: ImrseError? = nil, blocked: Bool = false) {
        self.fragments = fragments; self.failure = failure; self.blocked = blocked
    }
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        if blocked { await withCheckedContinuation { gate = $0 } }
        let parts = fragments, error = failure
        return AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            continuation.finish(throwing: error)
        }
    }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
final class ManualPreviewSessionTests: XCTestCase {
    private var configuration: ProviderConfiguration {
        .init(id: "local", name: "Fixture", kind: .managedLocal, endpoint: URL(string: "http://127.0.0.1")!, model: "fixture", requiresCredential: false)
    }
    private func settled(_ session: ManualPreviewSession) async {
        for _ in 0..<200 where session.isBusy { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(session.isBusy)
    }
    private func entered(_ provider: ManualProvider) async {
        for _ in 0..<200 { if await provider.requests.count > 0 { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTFail("provider did not enter")
    }
    func testExplicitTextPreviewAndExportHaveNoAppliedOrCopiedState() async throws {
        let provider = ManualProvider(["e\u{301}", "\n\tresult"]), session = ManualPreviewSession(provider: provider)
        XCTAssertTrue(session.generate(source: "copied text", instruction: "rewrite", configuration: configuration, localOnly: true))
        await settled(session)
        XCTAssertEqual(session.state, .preview)
        let preview = try XCTUnwrap(session.preview)
        XCTAssertEqual(preview.source, "copied text")
        XCTAssertEqual(preview.result, "e\u{301}\n\tresult")
        XCTAssertEqual(session.resultForExplicitCopy(previewID: preview.id), preview.result)
        XCTAssertNil(session.resultForExplicitCopy(previewID: UUID()))
        let recorded = await provider.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.text, "copied text"); XCTAssertTrue(request.localOnly)
        XCTAssertNil(request.fallbackProvider); XCTAssertNil(request.reportProvider); XCTAssertNil(request.reportResponseMetadata)
        session.dismiss(); XCTAssertNil(session.preview); XCTAssertNil(session.resultForExplicitCopy(previewID: preview.id))
    }
    func testProviderChoiceAndExplicitFallbackArePreserved() async throws {
        let provider = ManualProvider(), session = ManualPreviewSession(provider: provider)
        var remote = configuration; remote.id = "remote"; remote.kind = .compatible
        XCTAssertTrue(session.generate(source: "text", instruction: "", configuration: configuration, localOnly: true, fallbackProvider: remote))
        await settled(session)
        let recorded = await provider.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.provider, configuration); XCTAssertEqual(request.fallbackProvider, remote); XCTAssertTrue(request.localOnly)
    }
    func testInvalidInputsNeverReachProvider() async {
        let provider = ManualProvider(), session = ManualPreviewSession(provider: provider)
        XCTAssertFalse(session.generate(source: "", instruction: "", configuration: configuration))
        XCTAssertFalse(session.generate(source: String(repeating: "é", count: 524_289), instruction: "", configuration: configuration))
        XCTAssertEqual(session.state, .failed(.selectionTooLarge))
        XCTAssertFalse(session.generate(source: "x", instruction: String(repeating: "é", count: 32_769), configuration: configuration))
        XCTAssertEqual(session.state, .failed(.instructionTooLarge))
        var invalid = configuration; invalid.model = " "
        XCTAssertFalse(session.generate(source: "x", instruction: "", configuration: invalid))
        XCTAssertEqual(session.state, .failed(.missingModel)); let calls = await provider.requests.count; XCTAssertEqual(calls, 0)
    }
    func testFailureDiscardsPartialOutputAndNeverExports() async {
        for error in [ImrseError.authentication, .network, .cancelled] {
            let provider = ManualProvider(["partial"], failure: error), session = ManualPreviewSession(provider: provider)
            session.generate(source: "x", instruction: "", configuration: configuration); await settled(session)
            XCTAssertEqual(session.state, .failed(error)); XCTAssertNil(session.preview)
        }
    }
    func testEmptyAndOversizedOutputRefuse() async {
        for (parts, error) in [([], ImrseError.emptyOutput), ([String(repeating: "x", count: 1_048_576), "é"], .outputTooLarge)] {
            let session = ManualPreviewSession(provider: ManualProvider(parts))
            session.generate(source: "x", instruction: "", configuration: configuration); await settled(session)
            XCTAssertEqual(session.state, .failed(error)); XCTAssertNil(session.preview)
        }
    }
    func testCancellationRetainsAdmissionUntilUncooperativeRequestReturns() async {
        let provider = ManualProvider(blocked: true), session = ManualPreviewSession(provider: provider)
        session.generate(source: "original", instruction: "", configuration: configuration); await entered(provider)
        session.cancel(); XCTAssertEqual(session.state, .cancelling); XCTAssertTrue(session.isBusy)
        XCTAssertFalse(session.generate(source: "second", instruction: "", configuration: configuration))
        await provider.release(); await settled(session)
        XCTAssertEqual(session.state, .failed(.cancelled)); XCTAssertNil(session.preview)
        let calls = await provider.requests.count; XCTAssertEqual(calls, 1)
    }
    func testDismissDuringRequestDiscardsLateResult() async {
        let provider = ManualProvider(blocked: true), session = ManualPreviewSession(provider: provider)
        session.generate(source: "original", instruction: "", configuration: configuration); await entered(provider)
        session.dismiss(); await provider.release(); await settled(session)
        XCTAssertEqual(session.state, .idle); XCTAssertNil(session.preview)
    }
    func testTimeoutRevokesResultButDoesNotPretendProviderStopped() async {
        let provider = ManualProvider(blocked: true)
        let session = ManualPreviewSession(provider: provider, generationTimeout: .milliseconds(10), previewLifetime: .seconds(1))
        session.generate(source: "x", instruction: "", configuration: configuration); await entered(provider)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.state, .cancelling); XCTAssertTrue(session.isBusy)
        await provider.release(); await settled(session)
        XCTAssertEqual(session.state, .failed(.timeout)); XCTAssertNil(session.preview)
    }
    func testPreviewExpiresAndOldExportIDCannotReadNewResult() async throws {
        let session = ManualPreviewSession(provider: ManualProvider(), generationTimeout: .seconds(1), previewLifetime: .milliseconds(20))
        session.generate(source: "x", instruction: "", configuration: configuration); await settled(session)
        let id = try XCTUnwrap(session.preview?.id)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(session.preview); XCTAssertNil(session.resultForExplicitCopy(previewID: id)); XCTAssertEqual(session.state, .idle)
        session.generate(source: "next", instruction: "", configuration: configuration); await settled(session)
        XCTAssertNil(session.resultForExplicitCopy(previewID: id)); XCTAssertEqual(session.preview?.source, "next")
    }
    func testIdenticalOutputIsOnlyAnUnchangedPreview() async {
        let session = ManualPreviewSession(provider: ManualProvider(["same"]))
        session.generate(source: "same", instruction: "", configuration: configuration); await settled(session)
        XCTAssertEqual(session.state, .preview); XCTAssertEqual(session.preview?.unchanged, true)
    }
}

extension ManualPreviewSessionTests {
    func testOverdueCompletionRefusesBeforeSleepingTimerRuns() async {
        var clock = ContinuousClock.now
        let provider = ManualProvider(blocked: true)
        let session = ManualPreviewSession(provider: provider, generationTimeout: .seconds(90), previewLifetime: .seconds(180), now: { clock })
        session.generate(source: "x", instruction: "", configuration: configuration); await entered(provider)
        clock = clock.advanced(by: .seconds(91))
        await provider.release(); await settled(session)
        XCTAssertEqual(session.state, .failed(.timeout)); XCTAssertNil(session.preview)
    }
    func testExpiredPreviewCannotExportBeforeSleepingTimerRuns() async throws {
        var clock = ContinuousClock.now
        let session = ManualPreviewSession(provider: ManualProvider(), generationTimeout: .seconds(90), previewLifetime: .seconds(180), now: { clock })
        session.generate(source: "x", instruction: "", configuration: configuration); await settled(session)
        let id = try XCTUnwrap(session.preview?.id)
        clock = clock.advanced(by: .seconds(180))
        XCTAssertNil(session.resultForExplicitCopy(previewID: id)); XCTAssertNil(session.preview); XCTAssertEqual(session.state, .idle)
    }
}

extension ManualPreviewSessionTests {
    func testExactOutputBoundaryAndInvalidSubmissionRevokePriorExport() async throws {
        let part = String(repeating: "é", count: 262_144)
        let session = ManualPreviewSession(provider: ManualProvider([part, part]))
        session.generate(source: "x", instruction: "", configuration: configuration); await settled(session)
        let preview = try XCTUnwrap(session.preview)
        XCTAssertEqual(preview.result.utf8.count, 1_048_576)
        XCTAssertFalse(session.generate(source: "", instruction: "", configuration: configuration))
        XCTAssertNil(session.preview); XCTAssertNil(session.resultForExplicitCopy(previewID: preview.id))
    }
    func testReentrantCancellationOnGeneratingNotificationCannotPublish() async {
        let provider = ManualProvider(), session = ManualPreviewSession(provider: provider)
        session.onChange = { [weak session] state in if state == .generating { session?.cancel() } }
        session.generate(source: "x", instruction: "", configuration: configuration); await settled(session)
        XCTAssertEqual(session.state, .failed(.cancelled)); XCTAssertNil(session.preview)
        let calls = await provider.requests.count; XCTAssertEqual(calls, 0)
    }
}

extension ManualPreviewSessionTests {
    func testOverdueQueuedRequestNeverStartsProvider() async {
        var clock = ContinuousClock.now
        let provider = ManualProvider()
        let session = ManualPreviewSession(provider: provider, generationTimeout: .seconds(90), previewLifetime: .seconds(180), now: { clock })
        session.generate(source: "x", instruction: "", configuration: configuration)
        clock = clock.advanced(by: .seconds(91)) // no actor yield: deadline passes before queued Task starts
        await settled(session)
        let calls = await provider.requests.count
        XCTAssertEqual(calls, 0); XCTAssertEqual(session.state, .failed(.timeout)); XCTAssertNil(session.preview)
    }
}
