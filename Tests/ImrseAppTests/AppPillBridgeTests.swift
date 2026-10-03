#if os(macOS)
import AppKit
import Combine
import ImrseCore
import ImrsePillCore
import ImrsePillUI
import ImrseServices
import SwiftUI
import Vision
import XCTest
@testable import ImrseApp

@MainActor
final class AppPillBridgeTests: XCTestCase {
    func testPillGeometryTokensMatchSharedContract() {
        XCTAssertEqual(PillTokens.width, 360)
        XCTAssertEqual(PillTokens.height, 52)
        XCTAssertEqual(PillTokens.radius, 26)
        XCTAssertEqual(PillTokens.horizontalPadding, 20)
        XCTAssertEqual(PillTokens.fontSize, 13)
        XCTAssertEqual(PillTokens.actionFontSize, 11)
        XCTAssertEqual(PillTokens.loaderSize, 24)

        let requestID = UUID()
        let phaseWidths: [CGFloat] = [
            PillTokens.width(for: .input),
            PillTokens.width(for: .processing(requestID)),
            PillTokens.width(for: .applying(requestID)),
            PillTokens.width(for: .success(requestID)),
            PillTokens.width(for: .failure(requestID, "Failure"))
        ]
        XCTAssertEqual(PillTokens.width(for: .hidden), 0)
        XCTAssertEqual(phaseWidths, [360, 240, 220, 180, 300])
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for width in phaseWidths {
            let panelFrame = PillPanelController.frame(width: width, visibleFrame: visibleFrame)
            XCTAssertEqual(panelFrame.width, width + 2 * PillTokens.shadowPadding)
            XCTAssertEqual(panelFrame.height, PillTokens.height + 2 * PillTokens.shadowPadding)
            XCTAssertEqual(panelFrame.midX, visibleFrame.midX)
            XCTAssertEqual(panelFrame.minY, visibleFrame.minY + PillTokens.bottomInset - PillTokens.shadowPadding)
        }
    }

    func testPillMotionDurationsDistinguishCurrentPreferencesAndPreserveLegacyValues() {
        XCTAssertEqual(PillMotion.quick.duration, 0.16, accuracy: 0.000_001)
        XCTAssertEqual(PillMotion.balanced.duration, 0.24, accuracy: 0.000_001)
        XCTAssertEqual(PillMotion.slow.duration, 0.36, accuracy: 0.000_001)
        XCTAssertEqual(PillMotion.instant.duration, 0, accuracy: 0.000_001)
        XCTAssertEqual(PillMotion.smooth.duration, 0.24, accuracy: 0.000_001)
    }

    func testBridgeMapsGlobalAndPresetMotionPreferences() {
        let mappings: [(MotionPreference, PillMotion)] = [
            (.instant, .instant),
            (.quick, .quick),
            (.balanced, .balanced),
            (.slow, .slow),
            (.smooth, .smooth)
        ]

        for (preference, expectedMotion) in mappings {
            let configuration = AppConfiguration(motion: preference)
            let (_, pill) = makeBridge(
                selection: RecordingSelectionAccess(),
                provider: RecordingTextProvider(output: "updated"),
                configuration: configuration
            )
            XCTAssertEqual(pill.motion, expectedMotion)
        }

        let configuration = AppConfiguration(motion: .balanced)
        let presets = [
            Preset(id: "instant", name: "Instant", instruction: "", motion: .instant),
            Preset(id: "quick", name: "Quick", instruction: "", motion: .quick),
            Preset(id: "balanced", name: "Balanced", instruction: "", motion: .balanced),
            Preset(id: "slow", name: "Slow", instruction: "", motion: .slow),
            Preset(id: "smooth", name: "Smooth", instruction: "", motion: .smooth),
            Preset(id: "inherited", name: "Inherited", instruction: "")
        ]
        let (_, pill) = makeBridge(
            selection: RecordingSelectionAccess(),
            provider: RecordingTextProvider(output: "updated"),
            configuration: configuration,
            presets: presets
        )

        XCTAssertEqual(pill.motion, .balanced)
        XCTAssertEqual(pill.presets.map(\.motion), [
            .instant, .quick, .balanced, .slow, .smooth, .balanced
        ])
    }

    func testCaptureCompletesBeforePillPresentationAndNoProviderStartsYet() {
        let selection = RecordingSelectionAccess()
        let provider = RecordingTextProvider(output: "updated")
        let (bridge, _) = makeBridge(selection: selection, provider: provider)
        var events: [String] = []
        bridge.onPresent = { _ in
            events.append("present")
            XCTAssertEqual(selection.captureCount, 1)
        }

        XCTAssertTrue(events.isEmpty)
        bridge.invoke()

        XCTAssertEqual(events, ["present"])
        XCTAssertEqual(selection.events, ["capture"])
        XCTAssertEqual(bridge.pill.phase, .input)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testCaptureFailureShowsWithoutSubmittingOrCallingProvider() {
        let selection = RecordingSelectionAccess(captureError: .permissionRequired)
        let provider = RecordingTextProvider(output: "updated")
        let (bridge, _) = makeBridge(selection: selection, provider: provider)
        var presented = 0
        bridge.onPresent = { _ in presented += 1 }

        bridge.invoke()

        guard case .failure(_, let message) = bridge.pill.phase else {
            return XCTFail("Expected a capture failure state")
        }
        XCTAssertEqual(message, ImrseError.permissionRequired.message)
        XCTAssertEqual(presented, 1)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(selection.events, ["capture"])
    }

    func testGeneratedOutputWaitsForConfirmedReplacementBeforeShowingUpdated() async {
        let selection = RecordingSelectionAccess(holdReplacement: true)
        let provider = RecordingTextProvider(output: "updated")
        let (bridge, _) = makeBridge(selection: selection, provider: provider)

        bridge.invoke()
        bridge.pill.submit()
        await waitUntil { bridge.engine.state == .replacing }

        guard case .applying = bridge.pill.phase else {
            return XCTFail("The pill should show applying until replacement finishes")
        }
        XCTAssertEqual(selection.replaceCount, 1)

        selection.finishReplacement()
        await waitUntil { bridge.engine.state == .succeeded(unchanged: false) }

        guard case .success = bridge.pill.phase else {
            return XCTFail("The pill should show success only after confirmed replacement")
        }
        XCTAssertTrue(bridge.pill.canUndo)
    }

#if DEBUG
    func testReplacementFailurePublishesFailureAndResizesHostedPanel() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let selection = RecordingSelectionAccess(
            replacementError: .replacementFailed,
            holdReplacement: true
        )
        let provider = RecordingTextProvider(output: "updated")
        let configuration = AppConfiguration(
            providers: [providerConfiguration("default", model: "default-model")],
            selectedProviderID: "default"
        )
        let engine = TransformationEngine(selectionAccess: selection, textProvider: provider)
        let model = AppModel(testEngine: engine, configuration: configuration)
        let controller = PillPanelController(model: model)
        let existingWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
        var hostedPanel: NSPanel?
        model.onPresentPill = { _ in
            controller.present(afterCapturingTargetOn: screen)
            hostedPanel = NSApp.windows.first {
                !existingWindowNumbers.contains($0.windowNumber)
            } as? NSPanel
        }
        var publishedPhases: [PillPhase] = []
        let lifecycleSubscription = model.pillModel.$lifecycle.sink {
            publishedPhases.append($0.phase)
        }
        defer {
            lifecycleSubscription.cancel()
            selection.finishReplacement()
            model.pillModel.dismiss()
            hostedPanel?.close()
        }

        model.invoke()
        guard let hostedPanel else { return XCTFail("Expected the hosted pill panel to be presented") }
        let contentView = try XCTUnwrap(hostedPanel.contentView)
        let hostingView = try XCTUnwrap(contentView as? any HostingViewSizingOptionsProviding)
        XCTAssertTrue(hostingView.sizingOptions.isEmpty)
        model.pillModel.submit()
        await waitUntil { engine.state == .replacing }

        guard case .applying(let requestID) = model.pillModel.phase else {
            return XCTFail("Expected the pill to remain applying while replacement is pending")
        }
        XCTAssertEqual(selection.replaceCount, 1)
        contentView.layoutSubtreeIfNeeded()
        await waitUntil {
            guard let text = try? renderedText(in: contentView) else { return false }
            return containsRenderedLabel("Updating selection…", in: text)
        }
        let applyingRenderedText = try renderedText(in: contentView)
        XCTAssertTrue(
            containsRenderedLabel("Updating selection…", in: applyingRenderedText),
            "Expected rendered applying label; OCR observed \(applyingRenderedText)"
        )
        let applyingFrame = hostedPanel.frame
        let applyingContentFrame = contentView.frame
        let applyingIntrinsicSize = contentView.intrinsicContentSize
        let applyingFittingSize = contentView.fittingSize
        XCTAssertEqual(
            applyingFrame,
            PillPanelController.frame(
                width: PillTokens.width(for: model.pillModel.phase),
                visibleFrame: screen.visibleFrame
            )
        )
        selection.finishReplacement()

        await waitUntil { engine.state == .failed(.replacementFailed) }
        await waitUntil {
            guard let text = try? renderedText(in: contentView) else { return false }
            return containsRenderedLabel(ImrseError.replacementFailed.message, in: text)
        }

        let failureRenderedText = try renderedText(in: contentView)
        let failurePhaseWidth = PillTokens.width(for: model.pillModel.phase)
        let failureFrame = PillPanelController.frame(
            width: failurePhaseWidth,
            visibleFrame: screen.visibleFrame
        )
        let attachment = XCTAttachment(string: """
        engineState=\(engine.state)
        modelPhase=\(model.pillModel.phase)
        publishedPhases=\(publishedPhases)
        applyingRenderedText=\(applyingRenderedText)
        failureRenderedText=\(failureRenderedText)
        sizingOptionsRawValue=\(hostingView.sizingOptions.rawValue)
        intrinsicContentSizeEnabled=\(hostingView.sizingOptions.contains(.intrinsicContentSize))
        preferredContentSizeEnabled=\(hostingView.sizingOptions.contains(.preferredContentSize))
        windowContentConstraints=\(contentView.superview?.constraints.count ?? 0)
        hostConstraints=\(contentView.constraints.count)
        hostTranslatesAutoresizingMaskIntoConstraints=\(contentView.translatesAutoresizingMaskIntoConstraints)
        applyingPanelFrame=\(applyingFrame)
        applyingContentFrame=\(applyingContentFrame)
        applyingIntrinsicSize=\(applyingIntrinsicSize)
        applyingFittingSize=\(applyingFittingSize)
        failurePanelFrame=\(hostedPanel.frame)
        expectedFailureFrame=\(failureFrame)
        failureContentFrame=\(contentView.frame)
        failureIntrinsicSize=\(contentView.intrinsicContentSize)
        failureFittingSize=\(contentView.fittingSize)
        """)
        attachment.name = "Hosted pill failure rendering and sizing"
        XCTContext.runActivity(named: "Hosted pill failure rendering and sizing") { $0.add(attachment) }

        guard case .failure(let failureID, let message) = model.pillModel.phase else {
            return XCTFail("""
            Expected replacement failure. engine=\(engine.state), phase=\(model.pillModel.phase),
            lifecycle=\(publishedPhases), renderedText=\(failureRenderedText), panelFrame=\(hostedPanel.frame),
            sizingOptions=\(hostingView.sizingOptions.rawValue), contentFrame=\(contentView.frame),
            intrinsic=\(contentView.intrinsicContentSize), fitting=\(contentView.fittingSize)
            """)
        }
        XCTAssertEqual(failureID, requestID)
        XCTAssertEqual(message, ImrseError.replacementFailed.message)
        XCTAssertTrue(publishedPhases.contains(.applying(requestID)))
        XCTAssertTrue(publishedPhases.contains(.failure(failureID, message)))
        XCTAssertTrue(
            containsRenderedLabel(message, in: failureRenderedText),
            "Expected rendered error \(message); OCR observed \(failureRenderedText)"
        )

        let expectedFrame = PillPanelController.frame(
            width: PillTokens.width(for: model.pillModel.phase),
            visibleFrame: screen.visibleFrame
        )
        XCTAssertEqual(expectedFrame.width, 356)
        XCTAssertEqual(
            hostedPanel.frame,
            expectedFrame,
            "sizingOptions=\(hostingView.sizingOptions.rawValue), contentFrame=\(contentView.frame), intrinsic=\(contentView.intrinsicContentSize), fitting=\(contentView.fittingSize)"
        )
    }
#endif

    func testDismissDuringReplacementDoesNotCancelCommitOrStartAnotherCapture() async {
        let selection = RecordingSelectionAccess(holdReplacement: true)
        let provider = RecordingTextProvider(output: "updated")
        let (bridge, _) = makeBridge(selection: selection, provider: provider)

        bridge.invoke()
        bridge.pill.submit()
        await waitUntil { bridge.engine.state == .replacing }
        bridge.pill.dismiss()
        bridge.invoke()

        XCTAssertEqual(bridge.pill.phase, .hidden)
        XCTAssertEqual(selection.captureCount, 1)
        XCTAssertEqual(selection.replaceCount, 1)
        XCTAssertEqual(bridge.engine.state, .replacing)

        selection.finishReplacement()
        await waitUntil { bridge.engine.state == .succeeded(unchanged: false) }

        XCTAssertEqual(bridge.pill.phase, .hidden)
        XCTAssertTrue(bridge.engine.canUndo)
        XCTAssertEqual(selection.captureCount, 1)
    }

    #if DEBUG
    func testTerminationDuringReplacementWaitsWithoutCancellingCommit() async {
        let selection = RecordingSelectionAccess(holdReplacement: true)
        let provider = RecordingTextProvider(output: "updated")
        let engine = TransformationEngine(selectionAccess: selection, textProvider: provider)
        let model = AppModel(testEngine: engine)
        engine.invoke()
        engine.submit(
            instruction: "Replace selected text",
            provider: providerConfiguration("default", model: "default-model")
        )
        await waitUntil { engine.state == .replacing }

        var replies: [NSApplication.TerminateReply] = []
        XCTAssertEqual(model.requestTermination { replies.append($0) }, .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(engine.state, .replacing)
        XCTAssertEqual(selection.replaceCount, 1)

        selection.finishReplacement()
        await waitUntil { replies == [.terminateNow] }

        XCTAssertEqual(selection.replaceCount, 1)
        XCTAssertEqual(replies, [.terminateNow])
        XCTAssertEqual(engine.state, .idle)
    }

    func testQueuedUndoBlocksNewActionsAndDefersTerminationUntilUndoSettles() async {
        let selection = RecordingSelectionAccess(holdUndo: true)
        let provider = RecordingTextProvider(output: "updated")
        let engine = TransformationEngine(selectionAccess: selection, textProvider: provider)
        let model = AppModel(testEngine: engine)
        engine.invoke()
        engine.submit(
            instruction: "Replace selected text",
            provider: providerConfiguration("default", model: "default-model")
        )
        await waitUntil { engine.state == .succeeded(unchanged: false) }

        XCTAssertTrue(engine.canUndo)
        XCTAssertFalse(model.isProcessing)
        XCTAssertTrue(model.canOpenSettings)
        XCTAssertTrue(model.canChangeSettings)
        let captureCount = selection.captureCount
        model.undo()

        XCTAssertTrue(model.isProcessing)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canOpenSettings)
        XCTAssertFalse(model.canChangeSettings)
        XCTAssertEqual(engine.state, .succeeded(unchanged: false))

        model.invoke()
        model.prepareForSettings()
        XCTAssertEqual(selection.captureCount, captureCount)
        XCTAssertEqual(engine.state, .succeeded(unchanged: false))
        XCTAssertThrowsError(try model.saveConfiguration(model.configuration))

        var replies: [NSApplication.TerminateReply] = []
        XCTAssertEqual(model.requestTermination { replies.append($0) }, .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(engine.state, .succeeded(unchanged: false))

        await waitUntil { engine.state == .undoing }
        XCTAssertEqual(selection.undoCount, 1)
        XCTAssertTrue(replies.isEmpty)

        selection.finishUndo()
        await waitUntil { replies == [.terminateNow] }

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(replies, [.terminateNow])
    }
    #endif

    func testCancellationIgnoresLateProviderCompletionAfterANewInvocation() async {
        let selection = RecordingSelectionAccess()
        let provider = RecordingTextProvider(output: "updated")
        provider.holdNextResponse()
        let (bridge, _) = makeBridge(selection: selection, provider: provider)

        bridge.invoke()
        bridge.pill.submit()
        await waitUntil { provider.requests.count == 1 }
        bridge.pill.dismiss()
        XCTAssertEqual(bridge.engine.state, .failed(.cancelled))

        bridge.invoke()
        bridge.pill.submit()
        await waitUntil { bridge.engine.state == .succeeded(unchanged: false) }
        let newPhase = bridge.pill.phase
        provider.finishResponse(at: 0, with: "stale output")
        await Task.yield()

        XCTAssertEqual(bridge.pill.phase, newPhase)
        XCTAssertEqual(selection.captureCount, 2)
        XCTAssertEqual(selection.replaceCount, 1)
    }

    func testDismissingRoutingFailureRetainsEngineFailure() {
        let selection = RecordingSelectionAccess()
        let provider = RecordingTextProvider(output: "updated")
        let (bridge, _) = makeBridge(selection: selection, provider: provider, configuration: AppConfiguration())

        bridge.invoke()
        bridge.pill.submit()

        guard case .failure = bridge.pill.phase else {
            return XCTFail("Expected a routing failure")
        }
        XCTAssertEqual(bridge.engine.state, .failed(.providerUnavailable))
        XCTAssertEqual(bridge.engine.diagnostics.error, .providerUnavailable)

        bridge.pill.dismiss()

        XCTAssertEqual(bridge.engine.state, .failed(.providerUnavailable))
        XCTAssertEqual(bridge.engine.diagnostics.error, .providerUnavailable)
        XCTAssertEqual(selection.captureCount, 1)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testBlankSubmissionUsesDefaultInstructionResolver() async {
        let selection = RecordingSelectionAccess()
        let provider = RecordingTextProvider(output: "original text")
        let (bridge, _) = makeBridge(
            selection: selection,
            provider: provider,
            defaultInstruction: "Read default.md"
        )

        bridge.invoke()
        bridge.pill.submit()
        await waitUntil { bridge.engine.state == .succeeded(unchanged: true) }

        XCTAssertEqual(provider.requests.first?.instruction, "Read default.md")
        XCTAssertEqual(bridge.pill.phase, .hidden)
        XCTAssertEqual(selection.replaceCount, 0)
    }

    func testFocusedPresetFillsDraftAndKeepsPresetRoutingAfterEdits() async {
        let selection = RecordingSelectionAccess()
        let provider = RecordingTextProvider(output: "original text")
        let configured = AppConfiguration(
            providers: [
                providerConfiguration("default", model: "default-model"),
                providerConfiguration("preset", model: "preset-base"),
                providerConfiguration("fallback", model: "fallback-model")
            ],
            selectedProviderID: "default"
        )
        let preset = Preset(
            id: "profile",
            name: "Profile",
            instruction: "Original profile instruction",
            providerID: "preset",
            model: "profile-model",
            fallbackProviderID: "fallback",
            motion: .smooth
        )
        let (bridge, _) = makeBridge(selection: selection, provider: provider, configuration: configured, presets: [preset])

        bridge.invoke()
        bridge.pill.instruction = "Custom instruction"
        bridge.pill.setInputFocused(false)
        bridge.selectPreset(at: 0)
        XCTAssertEqual(bridge.pill.instruction, "Custom instruction")

        bridge.pill.setInputFocused(true)
        bridge.selectPreset(at: 0)
        XCTAssertEqual(bridge.pill.instruction, preset.instruction)
        bridge.pill.instruction = "Edited profile instruction"
        XCTAssertEqual(bridge.pill.selectedPresetID, preset.id)
        XCTAssertEqual(bridge.pill.motion, .smooth)
        bridge.pill.setInputFocused(false)
        bridge.invoke(presetID: preset.id)
        XCTAssertEqual(bridge.pill.instruction, "Edited profile instruction")
        XCTAssertEqual(selection.captureCount, 1)

        bridge.pill.submit()
        await waitUntil { bridge.engine.state == .succeeded(unchanged: true) }

        let request = provider.requests.first
        XCTAssertEqual(request?.instruction, "Edited profile instruction")
        XCTAssertEqual(request?.provider.id, "preset")
        XCTAssertEqual(request?.provider.model, "profile-model")
        XCTAssertEqual(request?.fallbackProvider?.id, "fallback")
        XCTAssertFalse(request?.localOnly ?? true)
        XCTAssertNil(configured.invocation.shortcut)
    }

    func testUnmappedPresetSelectionIsNotConsumed() {
        let selection = RecordingSelectionAccess()
        let provider = RecordingTextProvider(output: "updated")
        let preset = Preset(id: "profile", name: "Profile", instruction: "Profile instruction")
        let (bridge, _) = makeBridge(selection: selection, provider: provider, presets: [preset])

        bridge.invoke()
        bridge.pill.setInputFocused(true)

        XCTAssertFalse(bridge.selectPreset(at: 1))
        XCTAssertEqual(bridge.pill.instruction, "")
        XCTAssertTrue(bridge.selectPreset(at: 0))
        XCTAssertEqual(bridge.pill.instruction, preset.instruction)
    }

    #if DEBUG
    func testDebugPreviewsKeepAllActionsAwayFromTheEngineAndSystemState() {
        let previewStates: [AppPreviewState] = [.hidden, .ready, .generating, .replacing, .success, .error, .settings]
        XCTAssertEqual(AppPreviewState.from(arguments: ["imrse", "--preview-state", "hidden"]), .hidden)

        for tab in [SettingsTab.general, .models, .presets, .advanced] {
            XCTAssertEqual(
                AppPreviewState.settingsTab(
                    from: ["imrse", "--preview-settings-pane", tab.rawValue],
                    previewState: .settings,
                    isPreviewMode: true
                ),
                tab
            )
        }
        XCTAssertEqual(
            AppPreviewState.settingsTab(from: ["imrse"], previewState: .settings, isPreviewMode: true),
            .general
        )
        XCTAssertEqual(
            AppPreviewState.settingsTab(
                from: ["imrse", "--preview-settings-pane", "models"],
                previewState: .hidden,
                isPreviewMode: true
            ),
            .general
        )
        XCTAssertEqual(
            AppPreviewState.settingsTab(
                from: ["imrse", "--preview-settings-pane", "models"],
                previewState: .settings,
                isPreviewMode: false
            ),
            .general
        )

        for previewState in previewStates {
            let model = AppModel(previewState: previewState)
            model.presentPreviewState()

            XCTAssertTrue(model.isPreviewMode)
            XCTAssertEqual(model.engine.state, .idle)
            XCTAssertFalse(model.shortcutMonitor.isMonitoring)
            XCTAssertEqual(model.accessibilityStatus, "Not queried in preview")
            XCTAssertEqual(model.eventMonitoringStatus, "Not queried in preview")
            if previewState == .ready { XCTAssertEqual(model.pillModel.phase, .input) }
            if previewState == .hidden { XCTAssertEqual(model.pillModel.phase, .hidden) }

            model.invoke()
            model.pillModel.submit()
            model.undo()

            XCTAssertEqual(model.engine.state, .idle)
            XCTAssertFalse(model.copyDiagnostics())
        }
    }

    func testDebugPreviewSettingsBlockPersistenceAndKeychainAccess() async {
        let model = AppModel(previewState: .settings)

        XCTAssertFalse(model.canChangeSettings)
        XCTAssertNotNil(model.reloadConfiguration())
        XCTAssertFalse(model.copyDiagnostics())
        XCTAssertThrowsError(try model.saveConfiguration(model.configuration))
        XCTAssertThrowsError(try model.saveDefaultInstruction("preview-only"))

        do {
            try await model.saveCredential("preview-only", for: "preview-provider")
            XCTFail("Preview mode must not save credentials")
        } catch {}

        do {
            _ = try await model.hasCredential(for: "preview-provider")
            XCTFail("Preview mode must not query Keychain")
        } catch {}

        do {
            try await model.removeCredential(for: "preview-provider")
            XCTFail("Preview mode must not remove credentials")
        } catch {}
    }
    #endif

    private func makeBridge(
        selection: RecordingSelectionAccess,
        provider: RecordingTextProvider,
        configuration: AppConfiguration? = nil,
        defaultInstruction: String = "Default instruction",
        presets: [Preset] = []
    ) -> (AppPillBridge, PillModel) {
        let configuration = configuration ?? AppConfiguration(
            providers: [providerConfiguration("default", model: "default-model")],
            selectedProviderID: "default"
        )
        let pill = PillModel(onSubmit: { _ in })
        let engine = TransformationEngine(selectionAccess: selection, textProvider: provider)
        let bridge = AppPillBridge(
            engine: engine,
            pill: pill,
            configuration: configuration,
            defaultInstruction: defaultInstruction,
            presets: presets,
            screenAfterCapture: { nil },
            fallbackScreen: { nil }
        )
        return (bridge, pill)
    }

    private func providerConfiguration(_ id: String, model: String) -> ProviderConfiguration {
        ProviderConfiguration(
            id: id,
            name: id,
            kind: .compatible,
            endpoint: URL(string: "https://\(id).example.test/v1")!,
            model: model,
            requiresCredential: false
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for bridge state", file: file, line: line)
    }

    private func renderedText(in view: NSView) throws -> [String] {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "Unable to create a cached bitmap for the hosted pill content view"
        )
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage, "The hosted pill bitmap has no CGImage")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    private func containsRenderedLabel(_ label: String, in recognizedText: [String]) -> Bool {
        func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "...", with: "…")
                .replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "’", with: "'")
        }
        return normalize(recognizedText.joined(separator: " "))
            .localizedCaseInsensitiveContains(normalize(label))
    }
}

@MainActor
private final class RecordingSelectionAccess: SelectionAccess {
    let snapshot = SelectionSnapshot(
        applicationID: "test.application",
        processID: 123,
        role: "text field",
        text: "original text",
        range: TextRange(location: 0, length: "original text".utf16.count)
    )
    let captureError: ImrseError?
    let replacementError: ImrseError?
    var holdReplacement: Bool
    var holdUndo: Bool
    var captureCount = 0
    var replaceCount = 0
    var undoCount = 0
    var events: [String] = []
    private var replacementContinuation: CheckedContinuation<Void, Never>?
    private var undoContinuation: CheckedContinuation<Void, Never>?

    init(
        captureError: ImrseError? = nil,
        replacementError: ImrseError? = nil,
        holdReplacement: Bool = false,
        holdUndo: Bool = false
    ) {
        self.captureError = captureError
        self.replacementError = replacementError
        self.holdReplacement = holdReplacement
        self.holdUndo = holdUndo
    }

    func capture() throws -> SelectionSnapshot {
        captureCount += 1
        events.append("capture")
        if let captureError { throw captureError }
        return snapshot
    }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        replaceCount += 1
        if holdReplacement {
            await withCheckedContinuation { replacementContinuation = $0 }
        }
        if let replacementError { throw replacementError }
        return ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        undoCount += 1
        if holdUndo {
            await withCheckedContinuation { undoContinuation = $0 }
        }
    }

    func discard(_ target: SelectionSnapshot) {}

    func finishReplacement() {
        let continuation = replacementContinuation
        replacementContinuation = nil
        continuation?.resume()
    }

    func finishUndo() {
        let continuation = undoContinuation
        undoContinuation = nil
        continuation?.resume()
    }
}

private final class RecordingTextProvider: TextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let output: String
    private var shouldHoldNext = false
    private var pending: [AsyncThrowingStream<String, Error>.Continuation] = []
    private var recordedRequests: [TransformationRequest] = []

    init(output: String) { self.output = output }

    var requests: [TransformationRequest] { lock.withLock { recordedRequests } }

    func holdNextResponse() {
        lock.withLock { shouldHoldNext = true }
    }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        let hold = lock.withLock {
            recordedRequests.append(request)
            defer { shouldHoldNext = false }
            return shouldHoldNext
        }
        return AsyncThrowingStream { continuation in
            if hold {
                self.lock.withLock { self.pending.append(continuation) }
            } else {
                continuation.yield(output)
                continuation.finish()
            }
        }
    }

    func finishResponse(at index: Int, with text: String) {
        let continuation = lock.withLock { pending.indices.contains(index) ? pending[index] : nil }
        continuation?.yield(text)
        continuation?.finish()
    }
}

@MainActor
private protocol HostingViewSizingOptionsProviding {
    var sizingOptions: NSHostingSizingOptions { get }
}

extension NSHostingView: HostingViewSizingOptionsProviding {}
#endif
