import Foundation
import Testing
@testable import ImrseCore

@MainActor
struct TransformationEngineReplacementOutcomeTests {
    @Test func sameErrorNamePreservesThePriorReceiptWhenNotWrittenAndConsumesItWhenUnconfirmed() async {
        let preserved = await engineFailingAfterOneSuccess(with: .notWritten(.replacementFailed, invalidatesPriorUndo: false))
        #expect(preserved.engine.canUndo)
        #expect(preserved.engine.state == .failed(.replacementFailed))
        #expect(preserved.engine.diagnostics.replacementOutcome == .notWritten)
        #expect(!preserved.access.discarded.contains(preserved.firstTarget.id))

        let consumed = await engineFailingAfterOneSuccess(with: .unconfirmed(.replacementFailed))
        #expect(!consumed.engine.canUndo)
        #expect(consumed.engine.state == .failed(.replacementFailed))
        #expect(consumed.engine.diagnostics.replacementOutcome == .unconfirmed)
        #expect(consumed.access.discarded.contains(consumed.firstTarget.id))
    }

    @Test func notWrittenInvalidatesThePriorReceiptOnlyWhenTheAdapterReportsBlockedRecovery() async {
        let independent = await engineFailingAfterOneSuccess(
            with: .notWritten(.providerUnavailable, invalidatesPriorUndo: true)
        )
        #expect(independent.engine.state == .failed(.replacementFailed))
        #expect(independent.engine.diagnostics.replacementOutcome == .notWritten)
        #expect(!independent.engine.canUndo)
        #expect(independent.access.discarded.contains(independent.firstTarget.id))

        let plain = await engineFailingAfterOneSuccess(
            with: .notWritten(.providerUnavailable, invalidatesPriorUndo: false)
        )
        #expect(plain.engine.state == .failed(.replacementFailed))
        #expect(plain.engine.canUndo)
        #expect(!plain.access.discarded.contains(plain.firstTarget.id))
    }

    @Test func mismatchedAppliedReceiptIsReportedAsUnconfirmedAndDropsThePriorReceipt() async {
        let firstTarget = snapshot("first source")
        let access = ScriptedSelectionAccess(target: firstTarget)
        let engine = TransformationEngine(selectionAccess: access, textProvider: FixedTextProvider(output: "rewritten"))
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .succeeded(unchanged: false))
        #expect(engine.canUndo)

        engine.dismiss()
        let secondTarget = snapshot("second source")
        access.target = secondTarget
        access.outcomes = [
            .applied(ReplacementReceipt(target: secondTarget, replacement: "different output", strategy: .selectedText))
        ]
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .failed(.replacementFailed))

        #expect(engine.diagnostics.replacementOutcome == .unconfirmed)
        #expect(engine.diagnostics.targetValid == false)
        #expect(!engine.canUndo)
        #expect(access.discarded.contains(firstTarget.id))
    }

    @Test func unconfirmedStaleSelectionNeverReportsThatNothingWasReplaced() async {
        let access = ScriptedSelectionAccess(target: snapshot("original"))
        access.outcomes = [.unconfirmed(.staleSelection)]
        let engine = TransformationEngine(selectionAccess: access, textProvider: FixedTextProvider(output: "rewritten"))
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .failed(.replacementFailed))

        #expect(engine.state == .failed(.replacementFailed))
        #expect(engine.diagnostics.error == .replacementFailed)
        #expect(engine.diagnostics.replacementOutcome == .unconfirmed)
        #expect(ImrseError.replacementFailed.message != ImrseError.staleSelection.message)
    }

    @Test func unchangedOutputNeverCallsReplaceOrClaimsAnAppliedOutcome() async {
        let access = ScriptedSelectionAccess(target: snapshot("same text"))
        let engine = TransformationEngine(selectionAccess: access, textProvider: FixedTextProvider(output: "same text"))
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .succeeded(unchanged: true))

        #expect(access.replaceCount == 0)
        #expect(engine.diagnostics.replacementOutcome == nil)
        #expect(!engine.canUndo)
    }

    @Test func adapterFailureReasonSurvivesTheTargetDiscard() async {
        let access = ScriptedSelectionAccess(target: snapshot("original"))
        access.replacementReason = .replacementVerificationFailed
        access.outcomes = [.unconfirmed(.replacementFailed)]
        let engine = TransformationEngine(selectionAccess: access, textProvider: FixedTextProvider(output: "rewritten"))
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .failed(.replacementFailed))

        #expect(engine.diagnostics.selectionFailureReason == .replacementVerificationFailed)
        #expect(engine.diagnostics.targetValid == false)
        #expect(access.discardCount > 0)
    }

    @Test func newInvocationAndUndoResetTheRecordedOutcome() async {
        let access = ScriptedSelectionAccess(target: snapshot("original"))
        access.outcomes = [.unconfirmed(.replacementFailed)]
        let engine = TransformationEngine(selectionAccess: access, textProvider: FixedTextProvider(output: "rewritten"))
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .failed(.replacementFailed))
        #expect(engine.diagnostics.replacementOutcome == .unconfirmed)

        engine.dismiss()
        engine.invoke()
        #expect(engine.state == .ready)
        #expect(engine.diagnostics.replacementOutcome == nil)

        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .succeeded(unchanged: false))
        #expect(engine.diagnostics.replacementOutcome == .applied)

        await engine.undo()
        #expect(engine.state == .succeeded(unchanged: false))
        #expect(engine.diagnostics.replacementOutcome == nil)
    }

    @Test(arguments: [
        ReplacementOutcome.Status.applied,
        .notWritten,
        .unconfirmed
    ])
    func everyOutcomeStatusRendersItsClosedName(_ status: ReplacementOutcome.Status) {
        var metadata = DiagnosticMetadata()
        metadata.replacementOutcome = status
        let report = DiagnosticReport.render(metadata)

        #expect(report.contains("\"replacementOutcome\":\"\(status.rawValue)\""))
        #expect(["applied", "notWritten", "unconfirmed"].contains(status.rawValue))
    }

    @Test func outcomeSerializationStaysClosedAndOmitsSelectionText() async {
        let access = ScriptedSelectionAccess(target: snapshot("original-secret-text"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: FixedTextProvider(output: "rewritten-secret-text")
        )
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .succeeded(unchanged: false))

        let report = DiagnosticReport.render(engine.diagnostics)
        #expect(report.contains("\"replacementOutcome\":\"applied\""))
        #expect(!report.contains("secret"))
    }

    private func engineFailingAfterOneSuccess(
        with outcome: ReplacementOutcome
    ) async -> (engine: TransformationEngine, access: ScriptedSelectionAccess, firstTarget: SelectionSnapshot) {
        let firstTarget = snapshot("first source")
        let access = ScriptedSelectionAccess(target: firstTarget)
        let engine = TransformationEngine(selectionAccess: access, textProvider: FixedTextProvider(output: "rewritten"))
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .succeeded(unchanged: false))

        engine.dismiss()
        access.target = snapshot("second source")
        access.outcomes = [outcome]
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitForState(engine, .failed(.replacementFailed))

        return (engine, access, firstTarget)
    }

    private var configuration: ProviderConfiguration {
        ProviderConfiguration(
            id: "provider-id",
            name: "Provider",
            kind: .compatible,
            endpoint: URL(string: "https://example.invalid") ?? URL(fileURLWithPath: "/invalid"),
            model: "model-id"
        )
    }

    private func snapshot(_ text: String) -> SelectionSnapshot {
        SelectionSnapshot(
            applicationID: "test.app",
            processID: 1,
            role: "textField",
            text: text,
            range: TextRange(location: 0, length: text.utf16.count)
        )
    }

    private func waitForState(_ engine: TransformationEngine, _ expected: TransformationState) async {
        for _ in 0..<10_000 {
            if engine.state == expected { return }
            await Task.yield()
        }
        Issue.record("Expected state \(expected), got \(engine.state)")
    }
}

private struct FixedTextProvider: TextProvider {
    let output: String

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

@MainActor
private final class ScriptedSelectionAccess: SelectionAccess {
    var target: SelectionSnapshot
    var outcomes: [ReplacementOutcome] = []
    var replacementReason: SelectionFailureReason?
    private(set) var lastFailureReason: SelectionFailureReason?
    private(set) var replaceCount = 0
    private(set) var discardCount = 0
    private(set) var discarded: [UUID] = []

    init(target: SelectionSnapshot) {
        self.target = target
    }

    func capture() throws -> SelectionSnapshot {
        lastFailureReason = nil
        return target
    }

    func validate(_ target: SelectionSnapshot) throws {
        lastFailureReason = nil
        guard target.id == self.target.id else { throw ImrseError.targetLost }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async -> ReplacementOutcome {
        replaceCount += 1
        lastFailureReason = replacementReason
        guard !outcomes.isEmpty else {
            return .applied(ReplacementReceipt(target: target, replacement: text, strategy: .selectedText))
        }
        return outcomes.removeFirst()
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        lastFailureReason = nil
    }

    func discard(_ target: SelectionSnapshot) {
        discardCount += 1
        discarded.append(target.id)
        lastFailureReason = nil
    }
}
