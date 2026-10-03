import Foundation
import XCTest
@testable import ImrseCore

@MainActor
final class TransformationEngineTests: XCTestCase {
    func testFailedNewCaptureDoesNotReportPreviousTargetOrProviderMetadata() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let engine = TransformationEngine(selectionAccess: access, textProvider: ScriptedTextProvider(callFailure: .timeout))
        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)
        await waitForState(engine, .failed(.timeout))
        engine.dismiss()
        access.captureError = .noSelection
        engine.invoke()
        XCTAssertEqual(engine.state, .failed(.noSelection))
        XCTAssertNil(engine.diagnostics.applicationID)
        XCTAssertNil(engine.diagnostics.role)
        XCTAssertNil(engine.diagnostics.selectionLength)
        XCTAssertNil(engine.diagnostics.providerName)
        XCTAssertNil(engine.diagnostics.model)
    }

    func testRejectedSubmissionReleasesTargetAndRecordsRoutingFailure() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = ScriptedTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.rejectSubmission(.localModelUnavailable)
        XCTAssertEqual(engine.state, .failed(.localModelUnavailable))
        XCTAssertEqual(engine.diagnostics.error, .localModelUnavailable)
        XCTAssertEqual(access.discarded, [access.target.id])
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectedSubmissionCannotInterruptAnExistingGeneration() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)
        await provider.waitUntilRequested()
        engine.rejectSubmission(.providerUnavailable)
        XCTAssertEqual(engine.state, .generating)
        XCTAssertTrue(access.discarded.isEmpty)
        engine.cancel()
    }

    func testDismissRetainsLastFailureForDiagnosticsUntilNextInvocation() async {
        let engine = TransformationEngine(
            selectionAccess: StubSelectionAccess(target: snapshot(text: "original")),
            textProvider: ScriptedTextProvider(callFailure: .timeout)
        )
        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)
        await waitForState(engine, .failed(.timeout))
        engine.dismiss()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.diagnostics.error, .timeout)
        engine.invoke()
        XCTAssertEqual(engine.state, .ready)
        XCTAssertNil(engine.diagnostics.error)
    }

    func testUnicodeFormatCharactersArePreservedInCompletedOutput() async {
        let output = "👩🏽‍💻 cafe\u{301} 東京\n\u{200F}مرحبا\u{200C} بالعالم"
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let engine = TransformationEngine(selectionAccess: access, textProvider: ScriptedTextProvider(fragments: [output]))
        engine.invoke()
        engine.submit(instruction: "Preserve Unicode", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))
        XCTAssertEqual(access.replacedText, [output])
    }

    func testInvokeCapturesBeforeNotifyingAndKeepsCapturedTarget() async throws {
        let selected = snapshot(text: "original", range: ImrseCore.TextRange(location: 12, length: 8))
        let access = StubSelectionAccess(target: selected)
        let provider = ScriptedTextProvider(fragments: ["rewritten"])
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        var capturePrecededNotification = false
        engine.onChange = { state in
            if state == .ready {
                capturePrecededNotification = access.captureCount == 1
            }
        }

        engine.invoke()
        let fallback = ProviderConfiguration(
            id: "fallback", name: "Fallback", kind: .compatible,
            endpoint: endpoint("http://127.0.0.1:11434"), model: "local-model"
        )
        engine.submit(instruction: "polish", provider: providerConfiguration, localOnly: true, fallbackProvider: fallback)
        await waitForState(engine, .succeeded(unchanged: false))

        XCTAssertTrue(capturePrecededNotification)
        XCTAssertEqual(access.captureCount, 1)
        XCTAssertEqual(access.replacedText, ["rewritten"])
        let requests = await provider.requests
        XCTAssertEqual(requests.first?.text, "original")
        XCTAssertEqual(requests.first?.instruction, "polish")
        XCTAssertTrue(requests.first?.localOnly == true)
        XCTAssertEqual(requests.first?.fallbackProvider, fallback)
        XCTAssertTrue(engine.canUndo)
    }

    func testInvokeIgnoresDuplicateReadyInvocationInsteadOfRecapturingPanel() {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let engine = TransformationEngine(selectionAccess: access, textProvider: ScriptedTextProvider())

        engine.invoke()
        engine.invoke()

        XCTAssertEqual(access.captureCount, 1)
        XCTAssertEqual(engine.state, .ready)
    }

    func testSecureEmptyOversizedAndInvalidUTF16SelectionsFailClosed() {
        let secureAccess = StubSelectionAccess(target: snapshot(text: "secret", isSecure: true))
        let secureEngine = TransformationEngine(selectionAccess: secureAccess, textProvider: ScriptedTextProvider())
        secureEngine.invoke()
        XCTAssertEqual(secureEngine.state, .failed(.secureInput))
        XCTAssertTrue(secureAccess.discarded.contains(secureAccess.target.id))

        let emptyAccess = StubSelectionAccess(target: snapshot(text: ""))
        let emptyEngine = TransformationEngine(selectionAccess: emptyAccess, textProvider: ScriptedTextProvider())
        emptyEngine.invoke()
        XCTAssertEqual(emptyEngine.state, .failed(.noSelection))

        let whitespaceAccess = StubSelectionAccess(target: snapshot(text: " \n\t"))
        let whitespaceEngine = TransformationEngine(selectionAccess: whitespaceAccess, textProvider: ScriptedTextProvider())
        whitespaceEngine.invoke()
        XCTAssertEqual(whitespaceEngine.state, .failed(.noSelection))

        let tooLong = String(repeating: "😀", count: TransformationEngine.maximumSelectionUTF8Bytes / 4 + 1)
        let longAccess = StubSelectionAccess(target: snapshot(text: tooLong))
        let longEngine = TransformationEngine(selectionAccess: longAccess, textProvider: ScriptedTextProvider())
        longEngine.invoke()
        XCTAssertEqual(longEngine.state, .failed(.selectionTooLarge))

        let wrongLength = StubSelectionAccess(target: snapshot(text: "😀", range: ImrseCore.TextRange(location: 4, length: 1)))
        let wrongLengthEngine = TransformationEngine(selectionAccess: wrongLength, textProvider: ScriptedTextProvider())
        wrongLengthEngine.invoke()
        XCTAssertEqual(wrongLengthEngine.state, .failed(.noSelection))

        let overflowingRange = StubSelectionAccess(target: snapshot(text: "a", range: ImrseCore.TextRange(location: .max, length: 1)))
        let overflowingRangeEngine = TransformationEngine(selectionAccess: overflowingRange, textProvider: ScriptedTextProvider())
        overflowingRangeEngine.invoke()
        XCTAssertEqual(overflowingRangeEngine.state, .failed(.noSelection))
    }

    func testInstructionAndGeneratedOutputUseUTF8ByteLimits() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = ScriptedTextProvider(fragments: ["done"])
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()

        engine.submit(
            instruction: String(repeating: "i", count: TransformationEngine.maximumInstructionUTF8Bytes + 1),
            provider: providerConfiguration
        )
        XCTAssertEqual(engine.state, .failed(.instructionTooLarge))
        XCTAssertTrue(access.replacedText.isEmpty)

        engine.dismiss()
        engine.invoke()
        let oversizedProvider = ScriptedTextProvider(fragments: [String(repeating: "x", count: TransformationEngine.maximumOutputUTF8Bytes + 1)])
        let oversizedEngine = TransformationEngine(selectionAccess: access, textProvider: oversizedProvider)
        oversizedEngine.invoke()
        oversizedEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(oversizedEngine, .failed(.outputTooLarge))
        XCTAssertTrue(access.replacedText.isEmpty)
    }

    func testExactUTF8ByteLimitsAreAcceptedWhileAXRangeStaysUTF16Based() async {
        let selectedText = String(repeating: "é", count: TransformationEngine.maximumSelectionUTF8Bytes / 2)
        let selectionAccess = StubSelectionAccess(target: snapshot(
            text: selectedText,
            range: ImrseCore.TextRange(location: 3, length: selectedText.utf16.count)
        ))
        let selectionEngine = TransformationEngine(selectionAccess: selectionAccess, textProvider: ScriptedTextProvider())
        selectionEngine.invoke()
        XCTAssertEqual(selectionEngine.state, .ready)
        XCTAssertEqual(selectionEngine.diagnostics.selectionLength, selectedText.utf16.count)

        let instruction = String(repeating: "é", count: TransformationEngine.maximumInstructionUTF8Bytes / 2)
        let instructionProvider = ScriptedTextProvider(fragments: ["done"])
        let instructionEngine = TransformationEngine(
            selectionAccess: StubSelectionAccess(target: snapshot(text: "original")),
            textProvider: instructionProvider
        )
        instructionEngine.invoke()
        instructionEngine.submit(instruction: instruction, provider: providerConfiguration)
        await waitForState(instructionEngine, .succeeded(unchanged: false))
        let instructionRequests = await instructionProvider.requests
        XCTAssertEqual(instructionRequests.first?.instruction.utf8.count, TransformationEngine.maximumInstructionUTF8Bytes)

        let output = String(repeating: "é", count: TransformationEngine.maximumOutputUTF8Bytes / 2)
        let outputAccess = StubSelectionAccess(target: snapshot(text: "original"))
        let outputEngine = TransformationEngine(
            selectionAccess: outputAccess,
            textProvider: ScriptedTextProvider(fragments: [output])
        )
        outputEngine.invoke()
        outputEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(outputEngine, .succeeded(unchanged: false))
        XCTAssertEqual(outputAccess.replacedText.first?.utf8.count, TransformationEngine.maximumOutputUTF8Bytes)
    }

    func testOneCharacterAndUnicodeStructuredSelectionArePassedVerbatim() async {
        let oneCharacter = snapshot(text: "x", range: ImrseCore.TextRange(location: 6, length: 1))
        let oneCharacterProvider = ScriptedTextProvider(fragments: ["y"])
        let oneCharacterEngine = TransformationEngine(
            selectionAccess: StubSelectionAccess(target: oneCharacter),
            textProvider: oneCharacterProvider
        )
        oneCharacterEngine.invoke()
        oneCharacterEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(oneCharacterEngine, .succeeded(unchanged: false))
        let oneCharacterRequests = await oneCharacterProvider.requests
        XCTAssertEqual(oneCharacterRequests.first?.text, "x")

        let text = "e\u{301} 😀 中文 مرحبا\n# Markdown\n`let value = 1`\n{\"key\":\"值\"}\nlast line"
        let target = snapshot(text: text, range: ImrseCore.TextRange(location: 21, length: text.utf16.count))
        let provider = ScriptedTextProvider(fragments: ["formatted result"])
        let engine = TransformationEngine(selectionAccess: StubSelectionAccess(target: target), textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))
        let requests = await provider.requests
        XCTAssertEqual(requests.first?.text, text)
        XCTAssertEqual(requests.first?.text.utf16.count, target.range?.length)
    }

    func testUnchangedOutputIsSuccessfulNoOpAndDoesNotReplaceOrReplaceUndo() async {
        let access = StubSelectionAccess(target: snapshot(text: "same"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ScriptedTextProvider(fragments: ["sa", "me"])
        )
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)

        await waitForState(engine, .succeeded(unchanged: true))

        XCTAssertTrue(access.replacedText.isEmpty)
        XCTAssertEqual(engine.diagnostics.replacement, "unchanged")
        XCTAssertNil(engine.diagnostics.error)
    }

    func testEmptyDeltasDoNotChangeACompletedResponse() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = ScriptedTextProvider(fragments: Array(repeating: "", count: 2_000) + ["rewritten"])
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)

        await waitForState(engine, .succeeded(unchanged: false))

        XCTAssertEqual(access.replacedText, ["rewritten"])
    }

    func testWhitespaceOnlyAndCorruptControlOutputAreRejectedWithoutTrimmingUsefulFormatting() async {
        let whitespaceAccess = StubSelectionAccess(target: snapshot(text: "original"))
        let whitespaceEngine = TransformationEngine(
            selectionAccess: whitespaceAccess,
            textProvider: ScriptedTextProvider(fragments: [" \n\t "])
        )
        whitespaceEngine.invoke()
        whitespaceEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(whitespaceEngine, .failed(.emptyOutput))
        XCTAssertTrue(whitespaceAccess.replacedText.isEmpty)

        let corruptAccess = StubSelectionAccess(target: snapshot(text: "original"))
        let corruptEngine = TransformationEngine(
            selectionAccess: corruptAccess,
            textProvider: ScriptedTextProvider(fragments: ["valid\u{0000}invalid"])
        )
        corruptEngine.invoke()
        corruptEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(corruptEngine, .failed(.malformedResponse))
        XCTAssertTrue(corruptAccess.replacedText.isEmpty)

        let formattingAccess = StubSelectionAccess(target: snapshot(text: "same"))
        let formattingEngine = TransformationEngine(
            selectionAccess: formattingAccess,
            textProvider: ScriptedTextProvider(fragments: ["same\n"])
        )
        formattingEngine.invoke()
        formattingEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(formattingEngine, .succeeded(unchanged: false))
        XCTAssertEqual(formattingAccess.replacedText, ["same\n"])
    }

    func testStaleTargetAndInterruptedStreamNeverCommit() async {
        let staleAccess = StubSelectionAccess(target: snapshot(text: "original"))
        staleAccess.validationError = ImrseError.staleSelection
        let staleEngine = TransformationEngine(
            selectionAccess: staleAccess,
            textProvider: ScriptedTextProvider(fragments: ["rewritten"])
        )
        staleEngine.invoke()
        staleEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(staleEngine, .failed(.staleSelection))
        XCTAssertTrue(staleAccess.replacedText.isEmpty)

        let interruptedAccess = StubSelectionAccess(target: snapshot(text: "original"))
        let interruptedEngine = TransformationEngine(
            selectionAccess: interruptedAccess,
            textProvider: ScriptedTextProvider(fragments: ["partial"], streamFailure: .interrupted)
        )
        interruptedEngine.invoke()
        interruptedEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(interruptedEngine, .failed(.interruptedStream))
        XCTAssertTrue(interruptedAccess.replacedText.isEmpty)
    }

    func testProviderTimeoutAndUnexpectedErrorsMapToSafeCategories() async {
        let timeoutEngine = TransformationEngine(
            selectionAccess: StubSelectionAccess(target: snapshot(text: "original")),
            textProvider: ScriptedTextProvider(callFailure: .timeout)
        )
        timeoutEngine.invoke()
        timeoutEngine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(timeoutEngine, .failed(.timeout))

        let serverEngine = TransformationEngine(
            selectionAccess: StubSelectionAccess(target: snapshot(text: "selection-secret")),
            textProvider: ScriptedTextProvider(fragments: ["generated-secret"], streamFailure: .unknown)
        )
        serverEngine.invoke()
        serverEngine.submit(instruction: "", provider: ProviderConfiguration(
            id: "safe-id", name: "Safe name", kind: .compatible,
            endpoint: endpoint("https://example.invalid"), model: "safe-model"
        ))
        await waitForState(serverEngine, .failed(.server))

        XCTAssertEqual(serverEngine.diagnostics.providerName, "Safe name")
        XCTAssertEqual(serverEngine.diagnostics.model, "safe-model")
        let diagnostics = String(describing: serverEngine.diagnostics)
        XCTAssertFalse(diagnostics.contains("selection-secret"))
        XCTAssertFalse(diagnostics.contains("generated-secret"))
        XCTAssertFalse(diagnostics.contains("credential-secret"))
        let report = DiagnosticReport.render(serverEngine.diagnostics)
        XCTAssertFalse(report.contains("selection-secret"))
        XCTAssertFalse(report.contains("generated-secret"))
        XCTAssertFalse(report.contains("credential-secret"))
    }

    func testDuplicateSubmitIsIgnoredWhileGenerationOwnsTheTarget() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "first", provider: providerConfiguration)
        await provider.waitUntilRequested()

        engine.submit(instruction: "second", provider: providerConfiguration)

        XCTAssertEqual(engine.state, .generating)
        XCTAssertFalse(engine.canUndo)
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 1)
        await provider.yield("rewritten")
        await provider.finish()
        await waitForState(engine, .succeeded(unchanged: false))
        let requests = await provider.requests
        XCTAssertEqual(requests.first?.instruction, "first")
        XCTAssertEqual(access.replacedText, ["rewritten"])
    }

    func testReinvocationCancelsGenerationAndLateStreamCannotCommit() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await provider.waitUntilRequested()

        engine.invoke()
        XCTAssertEqual(engine.state, .failed(.cancelled))
        XCTAssertEqual(access.captureCount, 1)

        await provider.yield("late result")
        await provider.finish()
        await Task.yield()

        XCTAssertTrue(access.replacedText.isEmpty)
        XCTAssertEqual(engine.state, .failed(.cancelled))
    }

    func testDelayedProviderReturnAfterCancelCannotCommit() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = DeferredTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await provider.waitUntilRequested()

        engine.cancel()
        XCTAssertEqual(engine.state, .failed(.cancelled))
        await provider.resolve(fragments: ["late result"])
        await Task.yield()

        XCTAssertTrue(access.replacedText.isEmpty)
    }

    func testResponseMetadataPublishesOnlyAfterValidatedCompletionAndKeepsConfiguredModel() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        let metadata = ResponseMetadata(
            detectedModel: "actual-model-2026-10-02",
            inputTokens: 12,
            outputTokens: 5,
            totalTokens: 17
        )

        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)
        await provider.waitUntilRequested()
        await provider.reportResponseMetadata(metadata, through: 0)
        XCTAssertNil(engine.responseMetadata)

        await provider.yield("rewritten")
        await provider.finish()
        await waitForState(engine, .succeeded(unchanged: false))

        XCTAssertEqual(engine.responseMetadata, metadata)
        XCTAssertEqual(engine.diagnostics.model, providerConfiguration.model)
        engine.dismiss()
        XCTAssertNil(engine.responseMetadata)
        engine.invoke()
        XCTAssertNil(engine.responseMetadata)
    }

    func testLateResponseMetadataCannotRepublishAfterCancellation() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        let metadata = ResponseMetadata(detectedModel: "late-model", totalTokens: 1)

        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration)
        await provider.waitUntilRequested()
        engine.cancel()
        await provider.reportResponseMetadata(metadata, through: 0)

        XCTAssertNil(engine.responseMetadata)
        XCTAssertEqual(engine.state, .failed(.cancelled))
    }

    func testFallbackClearsPrimaryResponseMetadataBeforeReturningFallbackOutput() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = PrimaryMetadataThenFallbackProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        let fallback = ProviderConfiguration(
            id: "fallback-id", name: "Fallback", kind: .compatible,
            endpoint: endpoint("https://fallback.example.invalid/v1"), model: "fallback-configured-model"
        )

        engine.invoke()
        engine.submit(instruction: "Rewrite", provider: providerConfiguration, fallbackProvider: fallback)
        await waitForState(engine, .succeeded(unchanged: false))

        XCTAssertNil(engine.responseMetadata)
        XCTAssertEqual(engine.diagnostics.model, fallback.model)
        XCTAssertEqual(access.replacedText, ["rewritten"])
    }

    func testLateProviderReportCannotOverwriteCurrentOperationMetadata() async {
        let access = StubSelectionAccess(target: snapshot(text: "first"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        let firstProvider = providerConfiguration
        engine.invoke()
        engine.submit(instruction: "", provider: firstProvider)
        await provider.waitUntilRequested()

        engine.cancel()
        engine.dismiss()
        access.target = snapshot(text: "second")
        engine.invoke()
        let secondProvider = ProviderConfiguration(
            id: "current", name: "Current provider", kind: .compatible,
            endpoint: endpoint("https://example.invalid"), model: "current-model"
        )
        engine.submit(instruction: "", provider: secondProvider)
        await provider.waitUntilRequested(2)

        let currentFallback = ProviderConfiguration(
            id: "current-local", name: "Current local fallback", kind: .compatible,
            endpoint: endpoint("http://127.0.0.1:11434"), model: "current-local-model"
        )
        await provider.report(currentFallback, through: 1)
        XCTAssertEqual(engine.diagnostics.providerName, "Current local fallback")
        XCTAssertEqual(engine.diagnostics.model, "current-local-model")

        let staleFallback = ProviderConfiguration(
            id: "stale", name: "Stale provider", kind: .compatible,
            endpoint: endpoint("https://example.invalid"), model: "stale-model"
        )
        await provider.report(staleFallback, through: 0)
        XCTAssertEqual(engine.diagnostics.providerName, "Current local fallback")
        XCTAssertEqual(engine.diagnostics.model, "current-local-model")

        let currentMetadata = ResponseMetadata(detectedModel: "current-reported-model", totalTokens: 10)
        await provider.reportResponseMetadata(currentMetadata, through: 1)
        await provider.reportResponseMetadata(ResponseMetadata(detectedModel: "stale-reported-model"), through: 0)
        await provider.yield("rewritten")
        await provider.finish()
        await waitForState(engine, .succeeded(unchanged: false))
        XCTAssertEqual(engine.responseMetadata, currentMetadata)
        XCTAssertEqual(engine.diagnostics.model, "current-local-model")
    }

    func testImmediateCancellationBeforeProviderStartsInvalidatesOwnership() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let provider = HeldTextProvider()
        let engine = TransformationEngine(selectionAccess: access, textProvider: provider)
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        engine.cancel()
        await Task.yield()

        XCTAssertEqual(engine.state, .failed(.cancelled))
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(access.replacedText.isEmpty)
    }

    func testCancelAfterCommitBeginsCannotInterruptReplacement() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        access.holdReplacement = true
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ScriptedTextProvider(fragments: ["rewritten"])
        )
        engine.invoke()
        engine.onChange = { state in
            if state == .replacing { engine.cancel() }
        }
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .replacing)

        engine.dismiss()
        XCTAssertEqual(engine.state, .replacing)
        access.completeReplacement()
        await waitForState(engine, .succeeded(unchanged: false))
        XCTAssertEqual(access.replacedText, ["rewritten"])
    }

    func testUndoStaleTargetFailsClosedAndConsumesStaleReceipt() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ScriptedTextProvider(fragments: ["rewritten"])
        )
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))
        access.undoError = ImrseError.staleSelection

        await engine.undo()

        XCTAssertEqual(engine.state, .failed(.undoUnavailable))
        XCTAssertEqual(access.undoCount, 1)
        await engine.undo()
        XCTAssertEqual(engine.state, .failed(.undoUnavailable))
        XCTAssertEqual(access.undoCount, 1)
    }

    func testUndoSucceedsOnceAndMissingReceiptIsActionable() async {
        let access = StubSelectionAccess(target: snapshot(text: "original"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ScriptedTextProvider(fragments: ["rewritten"])
        )
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        await engine.undo()
        XCTAssertEqual(engine.state, .succeeded(unchanged: false))
        XCTAssertEqual(engine.diagnostics.replacement, "undone")
        XCTAssertEqual(access.undoCount, 1)
        XCTAssertFalse(engine.canUndo)

        await engine.undo()
        XCTAssertEqual(engine.state, .failed(.undoUnavailable))
        XCTAssertEqual(access.undoCount, 1)
    }

    func testLatestReceiptDiscardsItsPredecessorAndOwnsUndo() async {
        let access = StubSelectionAccess(target: snapshot(text: "first source"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ScriptedTextProvider(fragments: ["first result"])
        )
        let firstTargetID = access.target.id
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        engine.dismiss()
        let secondTarget = snapshot(text: "second source")
        access.target = secondTarget
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        XCTAssertTrue(access.discarded.contains(firstTargetID))
        XCTAssertFalse(access.discarded.contains(secondTarget.id))
        await engine.undo()
        XCTAssertEqual(access.undoReceipts.last?.target.id, secondTarget.id)
        XCTAssertTrue(access.discarded.contains(secondTarget.id))
    }

    func testUndoFromReadyDiscardsCurrentCaptureBeforeUndoingPreviousReceipt() async {
        let access = StubSelectionAccess(target: snapshot(text: "old source"))
        let engine = TransformationEngine(
            selectionAccess: access,
            textProvider: ScriptedTextProvider(fragments: ["old result"])
        )
        engine.invoke()
        engine.submit(instruction: "", provider: providerConfiguration)
        await waitForState(engine, .succeeded(unchanged: false))

        engine.dismiss()
        let readyTarget = snapshot(text: "current selection")
        access.target = readyTarget
        engine.invoke()
        XCTAssertEqual(engine.state, .ready)

        await engine.undo()

        XCTAssertEqual(engine.state, .succeeded(unchanged: false))
        XCTAssertTrue(access.discarded.contains(readyTarget.id))
        XCTAssertEqual(access.undoReceipts.last?.target.text, "old source")
    }

    private var providerConfiguration: ProviderConfiguration {
        ProviderConfiguration(
            id: "provider-id", name: "Provider", kind: .compatible,
            endpoint: endpoint("https://example.invalid"), model: "model-id"
        )
    }

    private func endpoint(_ address: String) -> URL {
        URL(string: address) ?? URL(fileURLWithPath: "/invalid")
    }

    private func snapshot(
        text: String,
        range: ImrseCore.TextRange? = nil,
        isSecure: Bool = false
    ) -> SelectionSnapshot {
        SelectionSnapshot(
            applicationID: "test.app", processID: 1, role: "textField",
            text: text, range: range, isSecure: isSecure
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

private enum ScriptFailure: Sendable {
    case timeout
    case interrupted
    case unknown

    var error: any Error {
        switch self {
        case .timeout: URLError(.timedOut)
        case .interrupted: ImrseError.interruptedStream
        case .unknown: TestProviderError()
        }
    }
}

private struct TestProviderError: Error, CustomStringConvertible, Sendable {
    var description: String { "provider detail generated-secret credential-secret" }
}

private typealias ProviderReporter = @MainActor @Sendable (ProviderConfiguration) -> Void
private typealias ResponseMetadataReporter = @MainActor @Sendable (ResponseMetadata) -> Void

private actor ScriptedTextProvider: TextProvider {
    private let fragments: [String]
    private let callFailure: ScriptFailure?
    private let streamFailure: ScriptFailure?
    private(set) var requests: [TransformationRequest] = []

    init(
        fragments: [String] = [],
        callFailure: ScriptFailure? = nil,
        streamFailure: ScriptFailure? = nil
    ) {
        self.fragments = fragments
        self.callFailure = callFailure
        self.streamFailure = streamFailure
    }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        requests.append(request)
        if let callFailure { throw callFailure.error }
        return makeStream(fragments: fragments, failure: streamFailure)
    }
}

private actor HeldTextProvider: TextProvider {
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0
    private(set) var requests: [TransformationRequest] = []
    private(set) var reportCallbacks: [ProviderReporter] = []
    private(set) var responseMetadataCallbacks: [ResponseMetadataReporter] = []

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        let pair = AsyncThrowingStream<String, any Error>.makeStream()
        requests.append(request)
        requestCount += 1
        if let reportProvider = request.reportProvider { reportCallbacks.append(reportProvider) }
        if let reportResponseMetadata = request.reportResponseMetadata { responseMetadataCallbacks.append(reportResponseMetadata) }
        continuation = pair.continuation
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
        return pair.stream
    }

    func waitUntilRequested(_ expectedCount: Int = 1) async {
        while requestCount < expectedCount {
            await withCheckedContinuation { requestWaiters.append($0) }
        }
    }

    func yield(_ fragment: String) {
        continuation?.yield(fragment)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func report(_ provider: ProviderConfiguration, through index: Int) async {
        guard reportCallbacks.indices.contains(index) else { return }
        await reportCallbacks[index](provider)
    }

    func reportResponseMetadata(_ metadata: ResponseMetadata, through index: Int) async {
        guard responseMetadataCallbacks.indices.contains(index) else { return }
        await responseMetadataCallbacks[index](metadata)
    }
}

private actor PrimaryMetadataThenFallbackProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        await request.reportResponseMetadata?(ResponseMetadata(detectedModel: "uncommitted-primary-model"))
        if let fallback = request.fallbackProvider { await request.reportProvider?(fallback) }
        return makeStream(fragments: ["rewritten"], failure: nil)
    }
}

private actor DeferredTextProvider: TextProvider {
    private var requestContinuation: CheckedContinuation<AsyncThrowingStream<String, any Error>, any Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var requested = false

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        requested = true
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
        return try await withCheckedThrowingContinuation { requestContinuation = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resolve(fragments: [String]) {
        requestContinuation?.resume(returning: makeStream(fragments: fragments, failure: nil))
        requestContinuation = nil
    }
}

@MainActor
private final class StubSelectionAccess: SelectionAccess {
    var target: SelectionSnapshot
    var captureError: ImrseError?
    var validationError: ImrseError?
    var replacementError: ImrseError?
    var undoError: ImrseError?
    var holdReplacement = false
    private var replacementContinuation: CheckedContinuation<ReplacementReceipt, any Error>?
    private(set) var captureCount = 0
    private(set) var replacedText: [String] = []
    private(set) var discarded: [UUID] = []
    private(set) var undoCount = 0
    private(set) var undoReceipts: [ReplacementReceipt] = []

    init(target: SelectionSnapshot) {
        self.target = target
    }

    func capture() throws -> SelectionSnapshot {
        captureCount += 1
        if let captureError { throw captureError }
        return target
    }

    func validate(_ target: SelectionSnapshot) throws {
        if let validationError { throw validationError }
        guard target.id == self.target.id else { throw ImrseError.targetLost }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        replacedText.append(text)
        if let replacementError { throw replacementError }
        let receipt = ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
        guard holdReplacement else { return receipt }
        return try await withCheckedThrowingContinuation { replacementContinuation = $0 }
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        undoCount += 1
        undoReceipts.append(receipt)
        if let undoError { throw undoError }
    }

    func discard(_ target: SelectionSnapshot) {
        discarded.append(target.id)
    }

    func completeReplacement() {
        let receipt = ReplacementReceipt(target: target, replacement: replacedText.last ?? "", strategy: .selectedText)
        replacementContinuation?.resume(returning: receipt)
        replacementContinuation = nil
    }
}

private func makeStream(
    fragments: [String],
    failure: ScriptFailure?
) -> AsyncThrowingStream<String, any Error> {
    AsyncThrowingStream { continuation in
        for fragment in fragments { continuation.yield(fragment) }
        if let failure { continuation.finish(throwing: failure.error) }
        else { continuation.finish() }
    }
}
