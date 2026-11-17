import Foundation
import Testing
@testable import ImrseCore

@MainActor
struct TransformationEngineExplicitSourceTests {
    @Test func preparationMustFinishBeforeReadyAndNeverStartsProvider() async {
        let access = ExplicitSourceAccess()
        let provider = ExplicitSourceProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invokeWithExplicitSourceCopy()
        #expect(engine.state == .capturing)
        engine.submit(instruction: "test", provider: config)
        await waitUntil { access.pending.count == 1 }
        #expect(await provider.calls == 0)
        access.pending[0].resume()
        await waitUntil { engine.state == .ready }
        #expect(await provider.calls == 0)
        engine.dismiss()
        #expect(access.discards == 1)
    }

    @Test func failureDiscardsExactlyOnceWithoutProvider() async {
        let access = ExplicitSourceAccess()
        let provider = ExplicitSourceProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invokeWithExplicitSourceCopy()
        await waitUntil { access.pending.count == 1 }
        access.pending[0].resume(throwing: ImrseError.clipboardFailed)
        await waitUntil { engine.state == .failed(.clipboardFailed) }
        engine.dismiss()
        #expect(access.discards == 1)
        #expect(await provider.calls == 0)
    }

    @Test func cancelledOrDismissedCompletionCannotReviveNewCapture() async {
        for cancel in [true, false] {
            let access = ExplicitSourceAccess()
            let provider = ExplicitSourceProvider()
            let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
            engine.invokeWithExplicitSourceCopy()
            await waitUntil { access.pending.count == 1 }
            if cancel { engine.cancel() } else { engine.dismiss() }
            engine.dismiss()
            #expect(engine.isPreparingSourceCopy)
            engine.invokeWithExplicitSourceCopy()
            engine.invoke()
            for _ in 0..<20 { await Task.yield() }
            #expect(access.pending.count == 1)
            #expect(engine.state == .idle)
            access.pending[0].resume()
            await waitUntil { !engine.isPreparingSourceCopy }
            #expect(engine.state == .idle)
            #expect(access.discards == 1)
            #expect(await provider.calls == 0)
            engine.invokeWithExplicitSourceCopy()
            await waitUntil { access.pending.count == 2 }
            access.pending[1].resume()
            await waitUntil { engine.state == .ready }
            engine.dismiss()
            #expect(access.discards == 2)
        }
    }

    @Test func pendingRecoveryRefusalClearsAttemptMetadataButPreservesAdapterEvidence() async {
        let access = ExplicitSourceAccess()
        access.lastWriteAttempt = WriteAttemptDiagnostic(strategy: .clipboard)
        let provider = ExplicitSourceProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "rewrite", provider: config)
        await waitUntil { engine.state == .failed(.replacementFailed) }
        #expect(engine.diagnostics.applicationID == "synthetic")
        #expect(engine.diagnostics.writeAttempt != nil)
        #expect(engine.responseMetadata?.detectedModel == "synthetic-model")
        engine.dismiss()
        access.hasPendingSourceCopyRecovery = true
        engine.invokeWithExplicitSourceCopy()
        #expect(engine.state == .failed(.clipboardPending))
        #expect(engine.diagnostics.applicationID == nil)
        #expect(engine.diagnostics.role == nil)
        #expect(engine.diagnostics.selectionLength == nil)
        #expect(engine.diagnostics.writeAttempt == nil)
        #expect(engine.diagnostics.replacementOutcome == nil)
        #expect(engine.diagnostics.providerName == nil)
        #expect(engine.responseMetadata == nil)
        #expect(engine.retainedGeneratedOutput == nil)
        #expect(access.hasPendingSourceCopyRecovery)
        #expect(access.lastWriteAttempt != nil)
        #expect(access.captureCount == 1)
        #expect(await provider.calls == 1)
        #expect(access.pending.isEmpty)
    }

    @Test func settledBackupBlocksNewCaptureWithoutHangingTask() async {
        let access = ExplicitSourceAccess()
        let engine = TransformationEngine(selectionAccess: access, textProvider: ExplicitSourceProvider())
        engine.invokeWithExplicitSourceCopy()
        await waitUntil { access.pending.count == 1 }
        engine.dismiss()
        access.hasPendingSourceCopyRecovery = true
        access.pending[0].resume(throwing: ImrseError.clipboardPending)
        await waitUntil { !engine.isPreparingSourceCopy }
        #expect(engine.hasPendingSourceCopyRecovery)
        engine.invokeWithExplicitSourceCopy()
        #expect(engine.state == .failed(.clipboardPending))
        engine.dismiss()
        engine.invoke()
        #expect(engine.state == .failed(.clipboardPending))
        #expect(access.pending.count == 1)
        #expect(access.captureCount == 1)
    }

    @Test func legacyInvokeStillSynchronousAndRepeatedCaptureCancels() async {
        let access = ExplicitSourceAccess()
        let engine = TransformationEngine(selectionAccess: access, textProvider: ExplicitSourceProvider())
        engine.invoke()
        #expect(engine.state == .ready)
        #expect(access.pending.isEmpty)
        engine.dismiss()
        engine.invokeWithExplicitSourceCopy()
        engine.invokeWithExplicitSourceCopy()
        #expect(engine.state == .failed(.cancelled))
        await waitUntil { !engine.isPreparingSourceCopy }
        #expect(access.pending.isEmpty)
        #expect(access.discards == 2)
    }

    private var config: ProviderConfiguration {
        ProviderConfiguration(id: "test", name: "test", kind: .compatible,
                              endpoint: URL(fileURLWithPath: "/invalid"), model: "test")
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        Issue.record("Capture checkpoint not reached")
    }
}

@MainActor private final class ExplicitSourceAccess: SelectionAccess {
    var supportsExplicitSourceCopy: Bool { true }
    var hasPendingSourceCopyRecovery = false
    var pending: [CheckedContinuation<Void, any Error>] = []
    var discards = 0
    var captureCount = 0
    var lastWriteAttempt: WriteAttemptDiagnostic?
    func capture() throws -> SelectionSnapshot {
        captureCount += 1
        return SelectionSnapshot(applicationID: "synthetic", processID: 1, role: "textField", text: "source",
                          range: TextRange(location: 0, length: 6))
    }
    func prepareExplicitSourceCopy(_ target: SelectionSnapshot) async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func validate(_ target: SelectionSnapshot) throws {}
    func replace(_ target: SelectionSnapshot, with text: String) async -> ReplacementOutcome {
        .notWritten(.replacementFailed, invalidatesPriorUndo: false)
    }
    func undo(_ receipt: ReplacementReceipt) async throws {}
    func discard(_ target: SelectionSnapshot) { discards += 1 }
}
private actor ExplicitSourceProvider: TextProvider {
    var calls = 0
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        calls += 1
        await request.reportResponseMetadata?(ResponseMetadata(detectedModel: "synthetic-model"))
        return AsyncThrowingStream { $0.yield("updated"); $0.finish() }
    }
}
