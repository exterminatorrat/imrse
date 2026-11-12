import Foundation
import XCTest
@testable import ImrseCore

@MainActor
final class TransformationEngineLifecycleRegressionTests: XCTestCase {
    func testReentrantCancelFromPrepareReplacementAbortsBeforeWritingAndKeepsPriorUndo() async {
        let access = LifecycleSelectionAccess(target: snapshot(text: "first source"))
        let metadata = ResponseMetadata(detectedModel: "reported-model", totalTokens: 3)
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: LifecycleImmediateProvider(fragments: ["first result"], metadata: metadata)
        )
        let firstTargetID = access.target.id
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        XCTAssertEqual(engine.responseMetadata, metadata)
        XCTAssertTrue(engine.canUndo)

        engine.dismiss()
        XCTAssertNil(engine.responseMetadata)
        XCTAssertTrue(engine.canUndo)

        let secondTarget = snapshot(text: "second source")
        access.target = secondTarget
        engine.onPrepareReplacement = { engine.cancel() }
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)

        await waitForState(engine, .failed(.cancelled))

        XCTAssertEqual(engine.diagnostics.generation, "cancelled")
        XCTAssertEqual(engine.diagnostics.replacement, "idle")
        XCTAssertNil(engine.responseMetadata)
        XCTAssertEqual(access.replacedText, ["first result"])
        XCTAssertTrue(access.discarded.contains(secondTarget.id))
        XCTAssertTrue(engine.canUndo)

        var stableAfterCancel = true
        for _ in 0..<50 {
            guard engine.state == .failed(.cancelled), access.replacedText == ["first result"] else {
                stableAfterCancel = false
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(stableAfterCancel, "Cancelled operation committed after the prepare hook returned")

        await engine.undo()

        XCTAssertEqual(engine.state, .succeeded(unchanged: false))
        XCTAssertEqual(engine.diagnostics.replacement, "undone")
        XCTAssertEqual(access.undoCount, 1)
        XCTAssertEqual(access.undoReceipts.last?.target.id, firstTargetID)
        XCTAssertTrue(access.discarded.contains(firstTargetID))
    }

    func testDuplicateUndoWhileFirstUndoIsSuspendedRunsOnceAndKeepsReceiptOwnership() async {
        let access = LifecycleSelectionAccess(target: snapshot(text: "original"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: LifecycleImmediateProvider(fragments: ["rewritten"])
        )
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))
        XCTAssertTrue(engine.canUndo)

        access.holdUndo = true
        defer { access.completeUndo() }
        let firstUndo = Task { await engine.undo() }
        guard await access.waitUntilUndoHeld() else {
            XCTFail("Undo never reached the selection access")
            return
        }

        XCTAssertEqual(engine.state, .undoing)
        XCTAssertFalse(engine.canUndo)

        await engine.undo()
        engine.dismiss()
        engine.cancel()

        XCTAssertEqual(engine.state, .undoing)
        XCTAssertEqual(access.undoCount, 1)
        XCTAssertEqual(access.undoReceipts.count, 1)

        access.completeUndo()
        await waitForState(engine, .succeeded(unchanged: false))
        await firstUndo.value

        XCTAssertEqual(engine.diagnostics.replacement, "undone")
        XCTAssertFalse(engine.canUndo)
        XCTAssertEqual(access.undoCount, 1)

        await engine.undo()

        XCTAssertEqual(engine.state, .failed(.undoUnavailable))
        XCTAssertEqual(access.undoCount, 1)
        XCTAssertEqual(access.undoReceipts.count, 1)
    }

    func testLateProviderReturnAfterDismissAndReinvocationCannotCommitOrReplaceNewReceipt() async {
        let access = LifecycleSelectionAccess(target: snapshot(text: "first source"))
        let provider = LifecycleDeferredReturnProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        let firstTargetID = access.target.id
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)

        guard await provider.waitUntilFirstCallEntered() else {
            _ = await provider.releaseFirstCall()
            XCTFail("First provider call never started")
            return
        }
        XCTAssertEqual(engine.state, .generating)

        engine.dismiss()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(access.discarded, [firstTargetID])

        let secondTarget = snapshot(text: "second source")
        access.target = secondTarget
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(access.replacedText, ["second result"])
        XCTAssertEqual(engine.diagnostics.replacement, "replaced")
        XCTAssertEqual(access.discarded, [firstTargetID])

        let released = await provider.releaseFirstCall()
        XCTAssertTrue(released)

        var stableAfterLateReturn = true
        for _ in 0..<200 {
            guard engine.state == .succeeded(unchanged: false),
                  engine.diagnostics.replacement == "replaced",
                  access.replacedText == ["second result"],
                  access.discarded == [firstTargetID]
            else {
                stableAfterLateReturn = false
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(stableAfterLateReturn, "Late provider return disturbed the committed operation")
        XCTAssertNil(engine.diagnostics.error)
        XCTAssertTrue(engine.canUndo)

        await engine.undo()

        XCTAssertEqual(engine.state, .succeeded(unchanged: false))
        XCTAssertEqual(access.undoCount, 1)
        XCTAssertEqual(access.undoReceipts.last?.target.id, secondTarget.id)
        XCTAssertEqual(access.discarded, [firstTargetID, secondTarget.id])
    }

    private var providerConfiguration: ProviderConfiguration {
        ProviderConfiguration(
            id: "provider-id", name: "Provider", kind: .compatible,
            endpoint: URL(string: "https://example.invalid") ?? URL(fileURLWithPath: "/invalid"),
            model: "model-id"
        )
    }

    private func snapshot(text: String) -> SelectionSnapshot {
        SelectionSnapshot(applicationID: "test.app", processID: 1, role: "textField", text: text)
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

private func lifecycleStream(_ fragments: [String]) -> AsyncThrowingStream<String, any Error> {
    AsyncThrowingStream { continuation in
        for fragment in fragments { continuation.yield(fragment) }
        continuation.finish()
    }
}

private actor LifecycleImmediateProvider: TextProvider {
    private let fragments: [String]
    private let metadata: ResponseMetadata?

    init(fragments: [String] = [], metadata: ResponseMetadata? = nil) {
        self.fragments = fragments
        self.metadata = metadata
    }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        if let metadata { await request.reportResponseMetadata?(metadata) }
        return lifecycleStream(fragments)
    }
}

private actor LifecycleDeferredReturnProvider: TextProvider {
    private var firstReturnContinuation: CheckedContinuation<AsyncThrowingStream<String, any Error>, any Error>?
    private(set) var callCount = 0

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        callCount += 1
        if callCount == 1 {
            return try await withCheckedThrowingContinuation { firstReturnContinuation = $0 }
        }
        return lifecycleStream(["second result"])
    }

    func waitUntilFirstCallEntered(maxYields: Int = 10_000) async -> Bool {
        for _ in 0..<maxYields {
            if callCount > 0 { return true }
            await Task.yield()
        }
        return false
    }

    func releaseFirstCall() -> Bool {
        guard let continuation = firstReturnContinuation else { return false }
        firstReturnContinuation = nil
        continuation.resume(returning: lifecycleStream(["late first result"]))
        return true
    }
}

@MainActor
private final class LifecycleSelectionAccess: SelectionAccess {
    var target: SelectionSnapshot
    var holdUndo = false
    private var undoContinuation: CheckedContinuation<Void, Never>?
    private(set) var replacedText: [String] = []
    private(set) var discarded: [UUID] = []
    private(set) var undoCount = 0
    private(set) var undoReceipts: [ReplacementReceipt] = []

    init(target: SelectionSnapshot) {
        self.target = target
    }

    func capture() throws -> SelectionSnapshot {
        target
    }

    func validate(_ target: SelectionSnapshot) throws {
        guard target.id == self.target.id else { throw ImrseError.targetLost }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        replacedText.append(text)
        return ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        undoCount += 1
        undoReceipts.append(receipt)
        guard holdUndo else { return }
        await withCheckedContinuation { continuation in
            undoContinuation = continuation
        }
    }

    func discard(_ target: SelectionSnapshot) {
        discarded.append(target.id)
    }

    func waitUntilUndoHeld(maxYields: Int = 10_000) async -> Bool {
        for _ in 0..<maxYields {
            if undoContinuation != nil { return true }
            await Task.yield()
        }
        return false
    }

    func completeUndo() {
        undoContinuation?.resume()
        undoContinuation = nil
    }
}
