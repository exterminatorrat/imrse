import Foundation
import Testing
@testable import ImrseCore

@MainActor
struct TransformationEngineRetainedOutputTests {
    @Test func notWrittenRetainsExactCompleteOutputWithoutRetryOrUndo() async {
        let access = RetentionSelectionAccess()
        let engine = makeEngine(access, output: "rewritten\nexact 👩🏽‍💻")
        await run(engine)
        let result = engine.retainedGeneratedOutput
        #expect(result?.result == "rewritten\nexact 👩🏽‍💻")
        #expect(result.flatMap { engine.resultForExplicitCopy(outputID: $0.id) } == result?.result)
        #expect(engine.resultForExplicitCopy(outputID: UUID()) == nil)
        #expect(engine.state == .failed(.replacementFailed))
        #expect(access.replaceCount == 1)
        #expect(!engine.canUndo)
        #expect(access.discardCount == 1)
        #expect(!DiagnosticReport.render(engine.diagnostics).contains("rewritten"))
    }

    @Test func unconfirmedWriteRetainsResultButDoesNotClaimSuccessfulPaste() async {
        let access = RetentionSelectionAccess()
        access.outcome = .unconfirmed(.clipboardPending)
        let engine = makeEngine(access)
        await run(engine)
        #expect(engine.retainedGeneratedOutput?.result == "rewritten")
        #expect(engine.state == .failed(.clipboardPending))
        #expect(engine.diagnostics.replacementOutcome == .unconfirmed)
        #expect(access.replaceCount == 1)
        #expect(!engine.canUndo)
    }

    @Test func invalidAppliedReceiptRetainsResultWithoutUndo() async {
        let access = RetentionSelectionAccess()
        access.outcome = .applied(ReplacementReceipt(target: access.target, replacement: "wrong", strategy: .selectedText))
        let engine = makeEngine(access)
        await run(engine)
        #expect(engine.retainedGeneratedOutput?.result == "rewritten")
        #expect(engine.diagnostics.replacementOutcome == .unconfirmed)
        #expect(!engine.canUndo)
    }

    @Test(arguments: [ImrseError.targetLost, .staleSelection])
    func completedGenerationSurvivesPreparationOrValidationRefusal(_ failure: ImrseError) async {
        let access = RetentionSelectionAccess()
        if failure == .targetLost { access.preparationError = failure }
        else { access.validationError = failure }
        let engine = makeEngine(access)
        await run(engine)
        #expect(engine.retainedGeneratedOutput?.result == "rewritten")
        #expect(engine.state == .failed(failure))
        #expect(access.replaceCount == 0)
    }

    @Test func successfulOrUnchangedOutputDoesNotCreateRecoveryResult() async {
        for unchanged in [false, true] {
            let access = RetentionSelectionAccess()
            let output = unchanged ? access.target.text : "rewritten"
            access.outcome = .applied(ReplacementReceipt(target: access.target, replacement: output, strategy: .selectedText))
            let engine = makeEngine(access, output: output)
            await run(engine)
            #expect(engine.state == .succeeded(unchanged: unchanged))
            #expect(engine.retainedGeneratedOutput == nil)
        }
    }

    @Test func dismissAndCancelClearFailureResultAndInvalidateExportID() async {
        for cancel in [false, true] {
            let engine = makeEngine(RetentionSelectionAccess())
            await run(engine)
            let id = engine.retainedGeneratedOutput!.id
            if cancel { engine.cancel() } else { engine.dismiss() }
            #expect(engine.retainedGeneratedOutput == nil)
            #expect(engine.resultForExplicitCopy(outputID: id) == nil)
        }
    }

    @Test func newInvocationCannotExportPreviousFailureOrPartialGeneration() async {
        let engine = makeEngine(RetentionSelectionAccess())
        await run(engine)
        let old = engine.retainedGeneratedOutput!.id
        engine.dismiss()
        engine.invoke()
        #expect(engine.state == .ready)
        #expect(engine.retainedGeneratedOutput == nil)
        #expect(engine.resultForExplicitCopy(outputID: old) == nil)
        engine.cancel()
    }

    @Test func newerFailureGetsNewIDAndOldIDCannotExportIt() async {
        let engine = makeEngine(RetentionSelectionAccess())
        await run(engine)
        let old = engine.retainedGeneratedOutput!.id
        engine.dismiss()
        await run(engine)
        let newer = engine.retainedGeneratedOutput!.id
        #expect(old != newer)
        #expect(engine.resultForExplicitCopy(outputID: old) == nil)
        #expect(engine.resultForExplicitCopy(outputID: newer) == "rewritten")
    }

    @Test func cancelledPreparationDoesNotRetainCompletedOutput() async {
        let access = RetentionSelectionAccess()
        access.suspendPreparation = true
        let engine = makeEngine(access)
        engine.invoke(); engine.submit(instruction: "rewrite", provider: configuration)
        await waitUntil { access.preparation != nil }
        engine.cancel()
        access.completePreparation()
        await waitUntil { access.preparationReturned }
        #expect(engine.retainedGeneratedOutput == nil)
        #expect(engine.state == .failed(.cancelled))
        #expect(access.replaceCount == 0)
    }

    @Test func stalePreparationCannotPublishIntoNewInvocation() async {
        let access = RetentionSelectionAccess()
        access.suspendPreparation = true
        let engine = makeEngine(access)
        engine.invoke(); engine.submit(instruction: "rewrite", provider: configuration)
        await waitUntil { access.preparation != nil }
        engine.dismiss(); engine.invoke()
        access.completePreparation()
        await waitUntil { access.preparationReturned }
        #expect(engine.state == .ready)
        #expect(engine.retainedGeneratedOutput == nil)
        #expect(access.replaceCount == 0)
        engine.dismiss()
    }

    @Test func providerPartialFailureAndLateCancelledOutputAreNeverRetained() async {
        for cancel in [false, true] {
            let pair = AsyncThrowingStream<String, any Error>.makeStream()
            let access = RetentionSelectionAccess()
            let engine = TransformationEngine(selectionAccess: access, textProvider: RetentionTextProvider(streamValue: pair.stream))
            engine.invoke(); engine.submit(instruction: "rewrite", provider: configuration)
            pair.continuation.yield("partial private output")
            if cancel {
                engine.cancel(); engine.dismiss(); engine.invoke()
                pair.continuation.yield("late old completion")
                pair.continuation.finish()
                for _ in 0..<100 { await Task.yield() }
                #expect(engine.state == .ready)
            } else {
                pair.continuation.finish(throwing: ImrseError.network)
                await waitUntil { engine.state == .failed(.network) }
            }
            #expect(engine.retainedGeneratedOutput == nil)
            #expect(access.replaceCount == 0)
            engine.dismiss()
        }
    }

    @Test(arguments: [0, 1, 2])
    func invalidOrOversizedOutputIsNeverRetained(_ kind: Int) async {
        let output = kind == 0 ? "" : kind == 1 ? "\u{1}" : String(repeating: "x", count: TransformationEngine.maximumOutputUTF8Bytes + 1)
        let engine = makeEngine(RetentionSelectionAccess(), output: output)
        await run(engine)
        #expect(engine.retainedGeneratedOutput == nil)
    }

    @Test func exactOutputBoundMayBeRetained() async {
        let output = String(repeating: "x", count: TransformationEngine.maximumOutputUTF8Bytes)
        let engine = makeEngine(RetentionSelectionAccess(), output: output)
        await run(engine)
        #expect(engine.retainedGeneratedOutput?.result.utf8.count == TransformationEngine.maximumOutputUTF8Bytes)
        engine.dismiss()
    }

    @Test func expiredGetterAndExplicitExportFailClosed() async {
        let clock = RetentionClock()
        let engine = TransformationEngine(selectionAccess: RetentionSelectionAccess(), textProvider: provider("rewritten"),
            retainedOutputLifetime: .seconds(180), now: { clock.now })
        await run(engine)
        let id = engine.retainedGeneratedOutput!.id
        clock.now = clock.now.advanced(by: .seconds(181))
        #expect(engine.resultForExplicitCopy(outputID: id) == nil)
        #expect(engine.retainedGeneratedOutput == nil)
        #expect(engine.state == .failed(.replacementFailed))
    }

    @Test func backgroundExpiryClearsWithoutExportAndKeepsFailureTruth() async {
        let engine = TransformationEngine(selectionAccess: RetentionSelectionAccess(), textProvider: provider("rewritten"),
            retainedOutputLifetime: .milliseconds(20), now: { ContinuousClock.now })
        var expiryNotice = false
        engine.onChange = { state in
            if case .failed = state, engine.retainedGeneratedOutput == nil { expiryNotice = true }
        }
        await run(engine)
        for _ in 0..<100 {
            if expiryNotice { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(expiryNotice)
        #expect(engine.retainedGeneratedOutput == nil)
        #expect(engine.state == .failed(.replacementFailed))
        engine.onChange = nil
    }

    @Test(arguments: [false, true])
    func expiredSourceNeverStartsProvider(_ expireAfterSubmit: Bool) async {
        let clock = RetentionClock(), access = RetentionSelectionAccess(), provider = CountingRetentionProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider,
            retainedOutputLifetime: .seconds(180), now: { clock.now })
        engine.invoke()
        if expireAfterSubmit { engine.submit(instruction: "rewrite", provider: configuration) }
        clock.now = clock.now.advanced(by: .seconds(181))
        if !expireAfterSubmit {
            engine.submit(instruction: "rewrite", provider: configuration)
            #expect(engine.state == .failed(.timeout))
        }
        await waitUntil { if case .failed = engine.state { true } else { false } }
        #expect(await provider.calls == 0)
        #expect(engine.state == .failed(.timeout))
        #expect(access.replaceCount == 0)
        #expect(engine.retainedGeneratedOutput == nil)
    }

    private func makeEngine(_ access: RetentionSelectionAccess, output: String = "rewritten") -> TransformationEngine {
        TransformationEngine(selectionAccess: access, textProvider: provider(output))
    }
    private func provider(_ output: String) -> RetentionTextProvider {
        RetentionTextProvider(output: output)
    }
    private var configuration: ProviderConfiguration {
        ProviderConfiguration(id: "test", name: "Test", kind: .compatible, endpoint: URL(fileURLWithPath: "/invalid"), model: "test")
    }
    private func run(_ engine: TransformationEngine) async {
        engine.invoke(); engine.submit(instruction: "rewrite", provider: configuration)
        await waitUntil { switch engine.state { case .failed, .succeeded: true; default: false } }
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        Issue.record("Expected retention checkpoint was not reached")
    }
}

@MainActor private final class RetentionClock { var now = ContinuousClock.now }
private struct RetentionTextProvider: TextProvider {
    let streamValue: AsyncThrowingStream<String, any Error>?
    let output: String?
    init(streamValue: AsyncThrowingStream<String, any Error>) { self.streamValue = streamValue; output = nil }
    init(output: String) { self.output = output; streamValue = nil }
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        if let output { return AsyncThrowingStream { continuation in continuation.yield(output); continuation.finish() } }
        return streamValue!
    }
}
@MainActor private final class RetentionSelectionAccess: SelectionAccess {
    let target = SelectionSnapshot(applicationID: "test.app", processID: 1, role: "textField", text: "source", range: TextRange(location: 0, length: 6))
    var outcome: ReplacementOutcome = .notWritten(.replacementFailed, invalidatesPriorUndo: false)
    var preparationError: ImrseError?, validationError: ImrseError?
    var replaceCount = 0, discardCount = 0
    var suspendPreparation = false, preparationReturned = false
    var preparation: CheckedContinuation<Void, Never>?
    func capture() throws -> SelectionSnapshot { target }
    func prepareForReplacement(_ target: SelectionSnapshot) async throws {
        if suspendPreparation { await withCheckedContinuation { preparation = $0 }; preparationReturned = true }
        if let preparationError { throw preparationError }
    }
    func completePreparation() { let saved = preparation; preparation = nil; saved?.resume() }
    func validate(_ target: SelectionSnapshot) throws { if let validationError { throw validationError } }
    func replace(_ target: SelectionSnapshot, with text: String) async -> ReplacementOutcome { replaceCount += 1; return outcome }
    func undo(_ receipt: ReplacementReceipt) async throws {}
    func discard(_ target: SelectionSnapshot) { discardCount += 1 }
}

private actor CountingRetentionProvider: TextProvider {
    private(set) var calls = 0
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        calls += 1
        return AsyncThrowingStream { $0.yield("rewritten"); $0.finish() }
    }
}
