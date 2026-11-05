import Foundation
import XCTest
@testable import ImrseCore

@MainActor
final class SelectionEditIntentTests: XCTestCase {
    func testDefaultInvokeRemainsReplacementAndRefusesEmptySelection() {
        let access = LegacySelectionAccess(target: snapshot(text: ""))
        let engine = TransformationEngine(selectionAccess: access, textProvider: ImmediateTextProvider())

        engine.invoke()

        XCTAssertEqual(access.captureCount, 1)
        XCTAssertEqual(engine.state, .failed(.noSelection))
        XCTAssertTrue(access.discarded.contains(access.target))
    }

    func testLegacySelectionAccessDefaultCaptureSupportsOnlyReplacement() throws {
        let target = snapshot(text: "selected")
        let access = LegacySelectionAccess(target: target)

        let captured = try access.capture(intent: .replaceSelection)

        XCTAssertEqual(captured, target)
        do {
            _ = try access.capture(intent: .insertAtCaret)
            XCTFail("Expected insertion capture to be unavailable")
        } catch {
            XCTAssertEqual(error as? ImrseError, .insertionUnavailable)
        }
        XCTAssertEqual(access.captureCount, 1)
    }

    func testInvokeCapturesRequestedIntentAndRefusesMismatchedSnapshot() {
        let target = snapshot(text: "", range: TextRange(location: 4, length: 0), intent: .insertAtCaret)
        let access = IntentSelectionAccess(target: target)
        let engine = TransformationEngine(selectionAccess: access, textProvider: ImmediateTextProvider())

        engine.invoke(intent: .insertAtCaret)

        XCTAssertEqual(access.capturedIntents, [.insertAtCaret])
        XCTAssertEqual(engine.state, .ready)

        engine.dismiss()
        access.captureSnapshot = snapshot(text: "selected")
        engine.invoke(intent: .insertAtCaret)

        XCTAssertEqual(access.capturedIntents, [.insertAtCaret, .insertAtCaret])
        XCTAssertEqual(engine.state, .failed(.insertionUnavailable))

        engine.dismiss()
        access.captureSnapshot = snapshot(
            text: "",
            range: TextRange(location: 4, length: 0),
            intent: .insertAtCaret
        )
        engine.invoke()

        XCTAssertEqual(access.capturedIntents, [.insertAtCaret, .insertAtCaret, .replaceSelection])
        XCTAssertEqual(engine.state, .failed(.insertionUnavailable))
    }

    func testInsertionCaptureRefusalPreservesCaretDiagnosticReason() {
        for reason in [
            SelectionFailureReason.caretProofUnavailable,
            .markedTextActive,
            .compositionStateUnavailable
        ] {
            let access = IntentSelectionAccess(target: snapshot(
                text: "",
                range: TextRange(location: 2, length: 0),
                intent: .insertAtCaret
            ))
            access.captureError = .insertionUnavailable
            access.captureFailureReason = reason
            let engine = TransformationEngine(selectionAccess: access, textProvider: ImmediateTextProvider())

            engine.invoke(intent: .insertAtCaret)

            XCTAssertEqual(engine.state, .failed(.insertionUnavailable))
            XCTAssertEqual(engine.diagnostics.selectionFailureReason, reason)
        }
    }

    func testInsertionRequiresMatchingEmptyTextAndValidCollapsedRange() {
        let invalidTargets = [
            snapshot(text: "selected", range: TextRange(location: 4, length: 8), intent: .insertAtCaret),
            snapshot(text: "selected", range: TextRange(location: 4, length: 0), intent: .insertAtCaret),
            snapshot(text: "", intent: .insertAtCaret),
            snapshot(text: "", range: TextRange(location: 4, length: 1), intent: .insertAtCaret),
            snapshot(text: "", range: TextRange(location: 4, length: -1), intent: .insertAtCaret),
            snapshot(text: "", range: TextRange(location: -1, length: 0), intent: .insertAtCaret)
        ]

        for target in invalidTargets {
            let access = IntentSelectionAccess(target: target)
            let engine = TransformationEngine(selectionAccess: access, textProvider: ImmediateTextProvider())

            engine.invoke(intent: .insertAtCaret)

            XCTAssertEqual(engine.state, .failed(.insertionUnavailable))
            XCTAssertTrue(access.discarded.contains(target))
        }

        let secureTarget = snapshot(
            text: "",
            range: TextRange(location: 4, length: 0),
            isSecure: true,
            intent: .insertAtCaret
        )
        let secureAccess = IntentSelectionAccess(target: secureTarget)
        let secureEngine = TransformationEngine(selectionAccess: secureAccess, textProvider: ImmediateTextProvider())

        secureEngine.invoke(intent: .insertAtCaret)

        XCTAssertEqual(secureEngine.state, .failed(.secureInput))
        XCTAssertTrue(secureAccess.discarded.contains(secureTarget))
    }

    func testInsertionUsesEmptyContextFreeRequestsAtStartMiddleAndEndAndPreservesUnicodeOutput() async {
        let output = "👩🏽‍💻 café\u{301} 東京\nمرحبا"

        for location in [0, 5, 12] {
            let target = snapshot(
                text: "",
                range: TextRange(location: location, length: 0),
                intent: .insertAtCaret
            )
            let access = IntentSelectionAccess(target: target)
            let provider = ImmediateTextProvider(fragments: ["👩🏽‍💻 café\u{301} ", "東京\nمرحبا"])
            let engine = TransformationEngine(selectionAccess: access, textProvider: provider)

            engine.invoke(intent: .insertAtCaret)
            engine.submit(instruction: "Insert this text", provider: providerConfiguration)
            await waitForState(engine, .succeeded(unchanged: false))

            let requests = await provider.requests
            XCTAssertEqual(requests.first?.text, "")
            XCTAssertEqual(requests.first?.instruction, "Insert this text")
            XCTAssertEqual(access.replacedText, [output])
            XCTAssertEqual(access.replacedTargets, [target])
            XCTAssertEqual(access.capturedIntents, [.insertAtCaret])
        }
    }

    func testInsertionRequiresNonblankInstructionWithoutChangingReplacementDefaults() async {
        for instruction in ["", " \n\t "] {
            let access = IntentSelectionAccess(target: snapshot(
                text: "",
                range: TextRange(location: 2, length: 0),
                intent: .insertAtCaret
            ))
            let provider = ImmediateTextProvider(fragments: ["inserted"])
            let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
            engine.invoke(intent: .insertAtCaret)

            engine.submit(instruction: instruction, provider: providerConfiguration)

            XCTAssertEqual(engine.state, .failed(.missingInstruction))
            XCTAssertFalse(engine.diagnostics.error?.message.isEmpty ?? true)
            XCTAssertTrue(access.replacedText.isEmpty)
            let requests = await provider.requests
            XCTAssertTrue(requests.isEmpty)
        }

        let replacementAccess = LegacySelectionAccess(target: snapshot(text: "selected"))
        let replacementProvider = ImmediateTextProvider(fragments: ["rewritten"])
        let replacementEngine = TransformationEngine(selectionAccess: replacementAccess, textProvider: replacementProvider)
        replacementEngine.invoke()
        replacementEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(replacementEngine, .succeeded(unchanged: false))
        XCTAssertEqual(replacementAccess.replacedText, ["rewritten"])
    }

    func testReceiptMustMatchExactSnapshotIncludingIntent() async {
        let target = snapshot(
            text: "",
            range: TextRange(location: 6, length: 0),
            intent: .insertAtCaret
        )
        let wrongIntentTarget = SelectionSnapshot(
            id: target.id,
            applicationID: target.applicationID,
            processID: target.processID,
            role: target.role,
            text: target.text,
            range: target.range,
            isSecure: target.isSecure,
            intent: .replaceSelection
        )
        let access = IntentSelectionAccess(target: target)
        access.receiptTarget = wrongIntentTarget
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ImmediateTextProvider(fragments: ["inserted"])
        )
        engine.invoke(intent: .insertAtCaret)
        engine.submit(instruction: "Insert", provider: providerConfiguration)

        await waitForState(engine, .failed(.replacementFailed))

        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(access.discarded.contains(target))
    }

    func testReceiptRejectsCanonicallyEqualButUTF16DifferentTargetText() async {
        let targetText = "a\u{301}\u{323}"
        let reorderedText = "a\u{323}\u{301}"
        XCTAssertEqual(targetText, reorderedText)
        XCTAssertEqual(targetText.utf16.count, reorderedText.utf16.count)
        XCTAssertFalse(targetText.utf16.elementsEqual(reorderedText.utf16))

        let target = snapshot(
            text: targetText,
            range: TextRange(location: 4, length: targetText.utf16.count)
        )
        let mismatchedTarget = SelectionSnapshot(
            id: target.id,
            applicationID: target.applicationID,
            processID: target.processID,
            role: target.role,
            text: reorderedText,
            range: target.range,
            isSecure: target.isSecure,
            intent: target.intent
        )
        let access = IntentSelectionAccess(target: target)
        access.receiptTarget = mismatchedTarget
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ImmediateTextProvider(fragments: ["rewritten"])
        )
        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)

        await waitForState(engine, .failed(.replacementFailed))

        XCTAssertFalse(engine.canUndo)
    }

    func testReceiptRequiresExactUTF16ReplacementText() async {
        let output = "a\u{301}\u{323}"
        let reorderedOutput = "a\u{323}\u{301}"
        XCTAssertEqual(output, reorderedOutput)
        XCTAssertEqual(output.utf16.count, reorderedOutput.utf16.count)
        XCTAssertFalse(output.utf16.elementsEqual(reorderedOutput.utf16))

        let access = IntentSelectionAccess(target: snapshot(text: "source"))
        access.receiptReplacement = reorderedOutput
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ImmediateTextProvider(fragments: [output])
        )
        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)

        await waitForState(engine, .failed(.replacementFailed))

        XCTAssertFalse(engine.canUndo)
    }

    func testReceiptRejectsMismatchedNontextSnapshotFields() async {
        let target = snapshot(text: "source", range: TextRange(location: 4, length: 6))
        let mismatchedTarget = SelectionSnapshot(
            id: target.id,
            applicationID: "other.app",
            processID: target.processID,
            role: target.role,
            text: target.text,
            range: target.range,
            isSecure: target.isSecure,
            intent: target.intent
        )
        let access = IntentSelectionAccess(target: target)
        access.receiptTarget = mismatchedTarget
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ImmediateTextProvider(fragments: ["rewritten"])
        )
        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)

        await waitForState(engine, .failed(.replacementFailed))

        XCTAssertFalse(engine.canUndo)
    }

    func testCancelRejectsLateInsertionCompletion() async {
        let target = snapshot(
            text: "",
            range: TextRange(location: 3, length: 0),
            intent: .insertAtCaret
        )
        let access = IntentSelectionAccess(target: target)
        let provider = DeferredTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke(intent: .insertAtCaret)
        engine.submit(instruction: "Insert", provider: providerConfiguration)
        await provider.waitUntilRequested()

        engine.cancel()
        await provider.resolve(fragments: ["late insertion"])
        await Task.yield()

        XCTAssertEqual(engine.state, .failed(.cancelled))
        XCTAssertTrue(access.replacedText.isEmpty)
        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(access.discarded.contains(target))
        let requests = await provider.requests
        XCTAssertEqual(requests.first?.text, "")
    }

    func testUndoReceiptRetainsInsertionIntent() async {
        let target = snapshot(
            text: "",
            range: TextRange(location: 3, length: 0),
            intent: .insertAtCaret
        )
        let access = IntentSelectionAccess(target: target)
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ImmediateTextProvider(fragments: ["inserted"])
        )
        engine.invoke(intent: .insertAtCaret)
        engine.submit(instruction: "Insert", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        await engine.undo()

        XCTAssertEqual(access.undoReceipts.last?.target, target)
        XCTAssertEqual(access.undoReceipts.last?.target.intent, .insertAtCaret)
        XCTAssertFalse(engine.canUndo)
    }

    private var providerConfiguration: ProviderConfiguration {
        ProviderConfiguration(
            id: "provider-id",
            name: "Provider",
            kind: .compatible,
            endpoint: URL(string: "https://example.invalid") ?? URL(fileURLWithPath: "/invalid"),
            model: "model-id"
        )
    }

    private func snapshot(
        text: String,
        range: ImrseCore.TextRange? = nil,
        isSecure: Bool = false,
        intent: SelectionEditIntent = .replaceSelection
    ) -> SelectionSnapshot {
        SelectionSnapshot(
            applicationID: "test.app",
            processID: 1,
            role: "textField",
            text: text,
            range: range,
            isSecure: isSecure,
            intent: intent
        )
    }

    private func waitForState(
        _ engine: TransformationEngine,
        _ state: TransformationState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if engine.state == state { return }
            await Task.yield()
        }
        XCTFail("Expected state \(state), got \(engine.state)", file: file, line: line)
    }
}

@MainActor
private final class LegacySelectionAccess: SelectionAccess {
    var target: SelectionSnapshot
    private(set) var captureCount = 0
    private(set) var replacedText: [String] = []
    private(set) var discarded: [SelectionSnapshot] = []
    private(set) var undoReceipts: [ReplacementReceipt] = []

    init(target: SelectionSnapshot) {
        self.target = target
    }

    func capture() throws -> SelectionSnapshot {
        captureCount += 1
        return target
    }

    func validate(_ target: SelectionSnapshot) throws {
        guard target.id == self.target.id else { throw ImrseError.targetLost }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        replacedText.append(text)
        return ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        undoReceipts.append(receipt)
    }

    func discard(_ target: SelectionSnapshot) {
        discarded.append(target)
    }
}

@MainActor
private final class IntentSelectionAccess: SelectionAccess {
    var target: SelectionSnapshot
    var captureSnapshot: SelectionSnapshot?
    var captureError: ImrseError?
    var captureFailureReason: SelectionFailureReason?
    var receiptTarget: SelectionSnapshot?
    var receiptReplacement: String?
    private(set) var capturedIntents: [SelectionEditIntent] = []
    private(set) var replacedText: [String] = []
    private(set) var replacedTargets: [SelectionSnapshot] = []
    private(set) var discarded: [SelectionSnapshot] = []
    private(set) var undoReceipts: [ReplacementReceipt] = []

    var lastFailureReason: SelectionFailureReason? { captureFailureReason }

    init(target: SelectionSnapshot) {
        self.target = target
    }

    func capture() throws -> SelectionSnapshot {
        if let captureError { throw captureError }
        return target
    }

    func capture(intent: SelectionEditIntent) throws -> SelectionSnapshot {
        capturedIntents.append(intent)
        if let captureError { throw captureError }
        return captureSnapshot ?? target
    }

    func validate(_ target: SelectionSnapshot) throws {
        guard target.id == self.target.id else { throw ImrseError.targetLost }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        replacedTargets.append(target)
        replacedText.append(text)
        return ReplacementReceipt(
            target: receiptTarget ?? target,
            replacement: receiptReplacement ?? text,
            strategy: .selectedText
        )
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        undoReceipts.append(receipt)
    }

    func discard(_ target: SelectionSnapshot) {
        discarded.append(target)
    }
}

private actor ImmediateTextProvider: TextProvider {
    private let fragments: [String]
    private(set) var requests: [TransformationRequest] = []

    init(fragments: [String] = []) {
        self.fragments = fragments
    }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        requests.append(request)
        return makeStream(fragments: fragments)
    }
}

private actor DeferredTextProvider: TextProvider {
    private var streamContinuation: CheckedContinuation<AsyncThrowingStream<String, any Error>, any Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false
    private(set) var requests: [TransformationRequest] = []

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        requests.append(request)
        requested = true
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
        return try await withCheckedThrowingContinuation { streamContinuation = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resolve(fragments: [String]) {
        streamContinuation?.resume(returning: makeStream(fragments: fragments))
        streamContinuation = nil
    }
}

private func makeStream(fragments: [String]) -> AsyncThrowingStream<String, any Error> {
    AsyncThrowingStream { continuation in
        for fragment in fragments { continuation.yield(fragment) }
        continuation.finish()
    }
}
