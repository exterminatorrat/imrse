// SOURCE-ONLY DIAGNOSTIC. Running requires explicit owner approval.
// No target editor access, clipboard, model, network, or app activation request.
import AppKit
import Foundation

final class ProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ProbeField: NSTextField {
    var onEscape: (() -> Void)?
    override var needsPanelToBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var panel: ProbePanel?
    private var field: ProbeField?
    private var timer: Timer?
    private var samples = 0
    private var emittedRecords = 0
    private var finished = false
    private var responderRequestAccepted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = ProbePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 105),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "IMRSE SYNTHETIC PANEL PROBE"
        panel.identifier = NSUserInterfaceItemIdentifier("imrse.qa.nativePanel")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 105))
        let label = NSTextField(labelWithString: "Synthetic keyboard probe. Type qa, then Escape.")
        label.frame = NSRect(x: 15, y: 70, width: 390, height: 20)
        let field = ProbeField(frame: NSRect(x: 15, y: 25, width: 390, height: 30))
        field.identifier = NSUserInterfaceItemIdentifier("imrse.qa.nativeInput")
        field.placeholderString = "Synthetic input only"
        field.delegate = self
        field.onEscape = { [weak self] in self?.finish("escape") }
        content.addSubview(label)
        content.addSubview(field)
        panel.contentView = content
        panel.initialFirstResponder = field
        self.panel = panel
        self.field = field
        panel.center()
        // Deliberately no NSApp.activate() and no other application's focus action.
        panel.makeKeyAndOrderFront(nil)
        if field.acceptsFirstResponder {
            responderRequestAccepted = panel.makeFirstResponder(field)
        }
        emit("presented")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.samples += 1
                self.emit("sample")
                if self.samples >= 60 { self.finish("deadline") }
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) { emit("ownFieldChanged") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === field, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finish("escape")
        return true
    }

    private func emit(_ event: String) {
        guard !finished, emittedRecords < 128, let panel, let field else { return }
        emittedRecords += 1
        let editor = field.currentEditor()
        let values: [String: Any] = [
            "event": event,
            "sample": min(samples, 60),
            "ownAppActive": NSApp.isActive,
            "ownAppForeground": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "ownPanelKey": panel.isKeyWindow,
            "fieldAcceptsFirstResponder": field.acceptsFirstResponder,
            "responderRequestAccepted": responderRequestAccepted,
            "actualFieldEditorIsFirstResponder": editor != nil && panel.firstResponder === editor,
            "matchesSyntheticQA": field.stringValue == "qa"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
        fflush(stdout)
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        emit(reason)
        finished = true
        timer?.invalidate()
        panel?.orderOut(nil)
        NSApp.terminate(nil)
    }
}

@main
struct Entry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Probe()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
