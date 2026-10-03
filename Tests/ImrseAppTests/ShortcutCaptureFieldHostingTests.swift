#if os(macOS) && DEBUG
import AppKit
import Carbon.HIToolbox
import ImrseCore
import ImrseServices
import SwiftUI
import XCTest
@testable import ImrseApp

@MainActor
final class ShortcutCaptureFieldHostingTests: XCTestCase {
    func testHostedCaptureFieldReceivesFirstResponderKeyDown() throws {
        let fixture = try ShortcutCaptureFieldFixture()
        defer { fixture.tearDown() }

        let field = try fixture.startRecording()
        XCTAssertTrue(fixture.window.firstResponder === field)

        field.keyDown(with: fixture.keyEvent(keyCode: UInt16(kVK_ANSI_L), characters: "l", modifiers: .option))

        XCTAssertEqual(fixture.shortcut, ShortcutBinding(keyCode: UInt16(kVK_ANSI_L), option: true))
        XCTAssertFalse(fixture.model.isRecordingShortcut)
    }

    func testHostedCaptureFieldCancelsOnWindowDeliveredEscape() throws {
        let fixture = try ShortcutCaptureFieldFixture()
        defer { fixture.tearDown() }

        let field = try fixture.startRecording()
        XCTAssertTrue(fixture.window.firstResponder === field)

        fixture.window.sendEvent(fixture.keyEvent(keyCode: UInt16(kVK_Escape), characters: "\u{1b}"))

        XCTAssertNil(fixture.shortcut)
        XCTAssertFalse(fixture.model.isRecordingShortcut)
    }
}

@MainActor
private final class ShortcutCaptureFieldFixture {
    let scratchRoot = FileManager.default.temporaryDirectory
        .appending(path: "imrse-shortcut-capture-field-\(UUID().uuidString)")
    let model: AppModel
    let sessionID: UUID
    let state = ShortcutCaptureFieldState()
    let window: NSWindow
    let hostingView: NSHostingView<HostedShortcutCaptureField>

    var shortcut: ShortcutBinding? { state.shortcut }

    init() throws {
        model = makeShortcutRecorderModel(configurationRoot: scratchRoot)
        sessionID = try XCTUnwrap(model.beginShortcutRecording())
        let state = self.state
        hostingView = NSHostingView(rootView: HostedShortcutCaptureField(
            model: model,
            sessionID: sessionID,
            shortcut: Binding(get: { state.shortcut }, set: { state.shortcut = $0 })
        ))
        window = makeRecorderWindow()
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
    }

    func startRecording() throws -> ShortcutCaptureTextField {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
        return try XCTUnwrap(findView(in: hostingView) { $0 is ShortcutCaptureTextField } as? ShortcutCaptureTextField)
    }

    func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        recorderKeyEvent(window: window, keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    func tearDown() {
        window.contentView = nil
        window.close()
        if model.isRecordingShortcut { model.endShortcutRecording(sessionID) }
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    private func findView(in view: NSView, where predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for subview in view.subviews {
            if let match = findView(in: subview, where: predicate) { return match }
        }
        return nil
    }
}

@MainActor
private struct HostedShortcutCaptureField: View {
    @ObservedObject var model: AppModel
    let sessionID: UUID
    @Binding var shortcut: ShortcutBinding?

    var body: some View {
        ShortcutCaptureField(
            isRecording: model.isRecordingShortcut,
            onAction: { action in
                switch action {
                case .ignored:
                    break
                case .cancelled:
                    model.endShortcutRecording(sessionID)
                case .captured(let shortcut):
                    self.shortcut = shortcut
                    model.endShortcutRecording(sessionID)
                }
            },
            onFocusLost: { model.endShortcutRecording(sessionID) },
            onUnmount: { model.endShortcutRecording(sessionID) }
        )
        .frame(width: 170)
    }
}

@MainActor
private final class ShortcutCaptureFieldState {
    var shortcut: ShortcutBinding?
}

@MainActor
private func makeShortcutRecorderModel(configurationRoot: URL) -> AppModel {
    AppModel(
        testEngine: TransformationEngine(
            selectionAccess: ShortcutRecorderSelectionAccess(),
            textProvider: ShortcutRecorderTextProvider()
        ),
        configurationStore: ConfigurationStore(root: configurationRoot)
    )
}

@MainActor
private func makeRecorderWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 220),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    window.title = "Shortcut Recorder Test"
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    return window
}

@MainActor
private func recorderKeyEvent(
    window: NSWindow,
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private final class ShortcutRecorderSelectionAccess: SelectionAccess {
    func capture() throws -> SelectionSnapshot {
        SelectionSnapshot(applicationID: "test", processID: 1, role: "textField", text: "selected")
    }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {}

    func discard(_ target: SelectionSnapshot) {}
}

private struct ShortcutRecorderTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
#endif
