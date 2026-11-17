import Foundation
import Testing
@testable import ImrseCore

@MainActor
struct TransformationEngineFocusHandoffTests {
    @Test func hidesThenAwaitsPreparationThenValidatesAndReplaces() async {
        let access = HandoffSelectionAccess()
        let engine = makeEngine(access)
        engine.onPrepareReplacement = { access.events.append("hide") }
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { access.preparation != nil }
        #expect(access.events == ["capture", "hide", "prepare"])
        access.completePreparation()
        await waitUntil { engine.state == .succeeded(unchanged: false) }
        #expect(access.events == ["capture", "hide", "prepare", "validate", "replace"])
        #expect(engine.canUndo)
    }

    @Test func cancellationDuringPreparationPreventsValidationAndReplacement() async {
        let access = HandoffSelectionAccess()
        let engine = makeEngine(access)
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { access.preparation != nil }
        engine.cancel()
        access.completePreparation()
        await waitUntil { access.preparationReturned }
        #expect(engine.state == .failed(.cancelled))
        #expect(!access.events.contains("validate"))
        #expect(!access.events.contains("replace"))
    }

    @Test func oldPreparationCannotWriteIntoANewerInvocation() async {
        let access = HandoffSelectionAccess()
        let engine = makeEngine(access)
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { access.preparation != nil }
        engine.dismiss()
        access.target = access.snapshot("new source")
        engine.invoke()
        access.completePreparation()
        await waitUntil { access.preparationReturned }
        #expect(engine.state == .ready)
        #expect(!access.events.contains("validate"))
        #expect(!access.events.contains("replace"))
    }

    @Test func handoffRefusalNeverValidatesOrReplaces() async {
        let access = HandoffSelectionAccess()
        let engine = makeEngine(access)
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { access.preparation != nil }
        access.completePreparation(throwing: ImrseError.targetLost)
        await waitUntil { engine.state == .failed(.targetLost) }
        #expect(!access.events.contains("validate"))
        #expect(!access.events.contains("replace"))
        #expect(engine.diagnostics.replacementOutcome == nil)
    }

    @Test func successfulHandoffDoesNotBypassStaleSelectionValidation() async {
        let access = HandoffSelectionAccess()
        access.validationError = .staleSelection
        let engine = makeEngine(access)
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { access.preparation != nil }
        access.completePreparation()
        await waitUntil { engine.state == .failed(.staleSelection) }
        #expect(access.events.contains("validate"))
        #expect(!access.events.contains("replace"))
    }

    @Test func cancellationErrorFromPreparationIsClassifiedAsCancellation() async {
        let access = HandoffSelectionAccess()
        let engine = makeEngine(access)
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { access.preparation != nil }
        access.completePreparation(throwing: CancellationError())
        await waitUntil { engine.state == .failed(.cancelled) }
        #expect(!access.events.contains("validate"))
        #expect(!access.events.contains("replace"))
    }

    @Test func unchangedOutputDoesNotPrepareOrClaimAWrite() async {
        let access = HandoffSelectionAccess()
        let engine = makeEngine(access, output: access.target.text)
        engine.invoke()
        engine.submit(instruction: "", provider: configuration)
        await waitUntil { engine.state == .succeeded(unchanged: true) }
        #expect(access.preparation == nil)
        #expect(!access.events.contains("validate"))
        #expect(!access.events.contains("replace"))
        #expect(engine.diagnostics.replacementOutcome == nil)
    }

    private func makeEngine(_ access: HandoffSelectionAccess, output: String = "updated") -> TransformationEngine {
        TransformationEngine(selectionAccess: access, textProvider: HandoffTextProvider(output: output))
    }

    private var configuration: ProviderConfiguration {
        ProviderConfiguration(
            id: "test", name: "Test", kind: .compatible,
            endpoint: URL(fileURLWithPath: "/invalid"), model: "test"
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Expected handoff checkpoint was not reached")
    }
}

@MainActor
private final class HandoffSelectionAccess: SelectionAccess {
    var target: SelectionSnapshot
    var events: [String] = []
    var preparation: CheckedContinuation<Void, any Error>?
    var preparationReturned = false
    var validationError: ImrseError?

    init() {
        target = SelectionSnapshot(
            applicationID: "test.app", processID: 1, role: "textField", text: "source",
            range: TextRange(location: 0, length: 6)
        )
    }

    func snapshot(_ text: String) -> SelectionSnapshot {
        SelectionSnapshot(
            applicationID: "test.app", processID: 1, role: "textField", text: text,
            range: TextRange(location: 0, length: text.utf16.count)
        )
    }

    func capture() throws -> SelectionSnapshot {
        events.append("capture")
        return target
    }

    func prepareForReplacement(_ target: SelectionSnapshot) async throws {
        events.append("prepare")
        defer { preparationReturned = true }
        try await withCheckedThrowingContinuation { preparation = $0 }
    }

    func completePreparation(throwing error: (any Error)? = nil) {
        let continuation = preparation
        preparation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    func validate(_ target: SelectionSnapshot) throws {
        events.append("validate")
        if let validationError { throw validationError }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async -> ReplacementOutcome {
        events.append("replace")
        return .applied(ReplacementReceipt(target: target, replacement: text, strategy: .selectedText))
    }

    func undo(_ receipt: ReplacementReceipt) async throws {}
    func discard(_ target: SelectionSnapshot) {}
}

private struct HandoffTextProvider: TextProvider {
    let output: String

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
