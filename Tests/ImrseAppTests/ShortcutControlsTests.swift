#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ImrseCore
import XCTest
@testable import ImrseApp

@MainActor
final class ShortcutControlsTests: XCTestCase {
    func testCapturesModifiedPhysicalKeysIncludingFunctionKeys() {
        let letter = keyEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .option, .shift])
        XCTAssertEqual(
            ShortcutCaptureField.captureAction(for: letter, isRecording: true, isFocused: true),
            .captured(ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), command: true, option: true, shift: true))
        )

        let functionKey = keyEvent(keyCode: UInt16(kVK_F1), modifiers: .option)
        XCTAssertEqual(
            ShortcutCaptureField.captureAction(for: functionKey, isRecording: true, isFocused: true),
            .captured(ShortcutBinding(keyCode: UInt16(kVK_F1), option: true))
        )
    }

    func testIgnoresUnfocusedUnmodifiedRepeatedAndModifierOnlyEvents() {
        let commandKey = keyEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: .command)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: commandKey, isRecording: false, isFocused: true), .ignored)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: commandKey, isRecording: true, isFocused: false), .ignored)

        let unmodified = keyEvent(keyCode: UInt16(kVK_ANSI_K))
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: unmodified, isRecording: true, isFocused: true), .ignored)

        let shiftOnly = keyEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: .shift)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: shiftOnly, isRecording: true, isFocused: true), .ignored)

        let repeated = keyEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: .command, isRepeat: true)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: repeated, isRecording: true, isFocused: true), .ignored)

        let keyUp = keyEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: .command, type: .keyUp)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: keyUp, isRecording: true, isFocused: true), .ignored)

        let modifier = keyEvent(keyCode: UInt16(kVK_RightCommand), modifiers: .command)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: modifier, isRecording: true, isFocused: true), .ignored)

        let unsupported = keyEvent(keyCode: 128, modifiers: .command)
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: unsupported, isRecording: true, isFocused: true), .ignored)
    }

    func testPlainEscapeCancelsAndModifiedEscapeCanBeCaptured() {
        let escape = keyEvent(keyCode: UInt16(kVK_Escape))
        XCTAssertEqual(ShortcutCaptureField.captureAction(for: escape, isRecording: true, isFocused: true), .cancelled)

        let modifiedEscape = keyEvent(keyCode: UInt16(kVK_Escape), modifiers: .command)
        XCTAssertEqual(
            ShortcutCaptureField.captureAction(for: modifiedEscape, isRecording: true, isFocused: true),
            .captured(ShortcutBinding(keyCode: UInt16(kVK_Escape), command: true))
        )

        let commandQ = keyEvent(keyCode: UInt16(kVK_ANSI_Q), modifiers: .command)
        XCTAssertTrue(ShortcutCaptureField.interceptsKeyEquivalent(commandQ, isRecording: true, isFocused: true))
        XCTAssertFalse(ShortcutCaptureField.interceptsKeyEquivalent(commandQ, isRecording: false, isFocused: true))
        XCTAssertFalse(ShortcutCaptureField.interceptsKeyEquivalent(commandQ, isRecording: true, isFocused: false))
    }

    func testShortcutLabelsAreReadableAndNilMeansUnassigned() {
        let shortcut = ShortcutBinding(keyCode: UInt16(kVK_F1), command: true, option: true, control: true, shift: true)
        XCTAssertEqual(ShortcutFormatter.label(for: shortcut), "⌃⌥⇧⌘F1")
        XCTAssertEqual(ShortcutFormatter.accessibilityLabel(for: shortcut), "Control + Option + Shift + Command + F1")
        XCTAssertEqual(ShortcutFormatter.label(for: nil), "Not set")
        XCTAssertEqual(ShortcutFormatter.accessibilityLabel(for: nil), "Not assigned")
    }

    #if DEBUG
    func testRecordingBlocksInvokeAndDiscardsQueuedMonitorCallbacks() throws {
        let selection = ShortcutTestSelectionAccess()
        let engine = TransformationEngine(selectionAccess: selection, textProvider: ShortcutTestTextProvider())
        let model = AppModel(testEngine: engine)
        let queuedEpoch = model.shortcutMonitorActivationEpoch
        let sessionID = try XCTUnwrap(model.beginShortcutRecording())

        model.handleShortcutMonitorCallback(presetID: nil, activationEpoch: queuedEpoch)
        model.invoke()

        XCTAssertTrue(model.isRecordingShortcut)
        XCTAssertEqual(selection.captureCount, 0)

        model.endShortcutRecording(sessionID)
        model.handleShortcutMonitorCallback(presetID: nil, activationEpoch: queuedEpoch)

        XCTAssertFalse(model.isRecordingShortcut)
        XCTAssertEqual(selection.captureCount, 0)
        XCTAssertFalse(model.shortcutMonitor.isMonitoring)
    }

    func testStaleUnmountCannotEndLaterRecordingSession() throws {
        let engine = TransformationEngine(selectionAccess: ShortcutTestSelectionAccess(), textProvider: ShortcutTestTextProvider())
        let model = AppModel(testEngine: engine)
        let firstSession = try XCTUnwrap(model.beginShortcutRecording())
        model.endShortcutRecording(firstSession)

        let secondSession = try XCTUnwrap(model.beginShortcutRecording())
        model.endShortcutRecording(firstSession)

        XCTAssertTrue(model.isRecordingShortcut)
        model.endShortcutRecording(secondSession)
        XCTAssertFalse(model.isRecordingShortcut)
        XCTAssertFalse(model.shortcutMonitor.isMonitoring)
    }

    func testPreviewLeavesControlsDisabledAndDoesNotStartMonitoring() {
        let model = AppModel(previewState: .settings)

        XCTAssertFalse(model.canChangeSettings)
        XCTAssertNil(model.beginShortcutRecording())
        XCTAssertEqual(model.eventMonitoringStatus, "Not queried in preview")
        XCTAssertFalse(model.shortcutMonitor.isMonitoring)
    }
    #endif

    func testClearingPresetDraftLeavesOtherSettingsAndIdentityUnchanged() throws {
        let original = Preset(
            id: "existing-preset",
            name: "Translate",
            instruction: "Translate the selection.",
            providerID: "selected-provider",
            model: "special-model",
            localOnly: true,
            fallbackProviderID: "fallback-provider",
            shortcut: ShortcutBinding(keyCode: UInt16(kVK_ANSI_T), command: true),
            motion: .instant
        )
        var draft = PresetDraft(preset: original)
        draft.shortcut = nil

        let updated = try XCTUnwrap(draft.preset)
        XCTAssertNil(updated.shortcut)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.providerID, original.providerID)
        XCTAssertEqual(updated.model, original.model)
        XCTAssertEqual(updated.localOnly, original.localOnly)
        XCTAssertEqual(updated.fallbackProviderID, original.fallbackProviderID)
        XCTAssertEqual(updated.motion, original.motion)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: isRepeat,
            keyCode: keyCode
        )!
    }
}

@MainActor
private final class ShortcutTestSelectionAccess: SelectionAccess {
    private(set) var captureCount = 0

    func capture() throws -> SelectionSnapshot {
        captureCount += 1
        return SelectionSnapshot(applicationID: "test", processID: 1, role: "textField", text: "selected")
    }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {}

    func discard(_ target: SelectionSnapshot) {}
}

private struct ShortcutTestTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
#endif
