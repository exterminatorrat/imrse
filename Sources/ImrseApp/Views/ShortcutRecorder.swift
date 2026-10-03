#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ImrseCore
import SwiftUI

struct ShortcutRecorder: View {
    let title: String
    @Binding var shortcut: ShortcutBinding?
    @Binding var issue: String?
    let isEnabled: Bool
    let model: AppModel

    @State private var recordingSessionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.imrseBodyStrong)
                    ShortcutKeycaps(shortcut: shortcut)
                }

                Spacer(minLength: 8)

                if let recordingSessionID {
                    ShortcutCaptureField(
                        isRecording: true,
                        onAction: { action in handle(action, sessionID: recordingSessionID) },
                        onFocusLost: { finishRecording(recordingSessionID) },
                        onUnmount: { finishRecording(recordingSessionID) }
                    )
                    .frame(width: 170)
                    ImrseSecondaryButton(title: "Cancel") { finishRecording(recordingSessionID) }
                } else {
                    if shortcut == nil {
                        ImrsePrimaryButton(title: "Record…", action: startRecording)
                            .disabled(!isEnabled)
                    } else {
                        ImrseSecondaryButton(title: "Change", action: startRecording)
                            .disabled(!isEnabled)
                        ImrseDestructiveButton(title: "Clear", action: clearShortcut)
                            .disabled(!isEnabled || shortcut == nil)
                    }
                }
            }

            if recordingSessionID != nil {
                SettingsHint(
                    title: "Recording shortcut",
                    detail: "Press the shortcut to record it; Escape cancels.",
                    symbol: "keyboard"
                )
            }

            if let issue {
                Text(issue)
                    .font(.imrseCaption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { cancelRecording() }
        }
        .onDisappear(perform: cancelRecording)
    }

    private func startRecording() {
        guard isEnabled, let sessionID = model.beginShortcutRecording() else { return }
        issue = nil
        recordingSessionID = sessionID
    }

    private func handle(_ action: ShortcutCaptureField.CaptureAction, sessionID: UUID) {
        guard recordingSessionID == sessionID else { return }
        switch action {
        case .ignored:
            break
        case .cancelled:
            finishRecording(sessionID)
        case .captured(let shortcut):
            self.shortcut = shortcut
            finishRecording(sessionID)
        }
    }

    private func clearShortcut() {
        issue = nil
        shortcut = nil
    }

    private func cancelRecording() {
        guard let recordingSessionID else { return }
        finishRecording(recordingSessionID)
    }

    private func finishRecording(_ sessionID: UUID) {
        guard recordingSessionID == sessionID else { return }
        model.endShortcutRecording(sessionID)
        recordingSessionID = nil
    }
}

struct ShortcutKeycaps: View {
    let shortcut: ShortcutBinding?

    var body: some View {
        Group {
            if let shortcut {
                HStack(spacing: 4) {
                    if shortcut.control { SettingsKeycap(value: "⌃") }
                    if shortcut.option { SettingsKeycap(value: "⌥") }
                    if shortcut.shift { SettingsKeycap(value: "⇧") }
                    if shortcut.command { SettingsKeycap(value: "⌘") }
                    SettingsKeycap(value: keyName(for: shortcut))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ShortcutFormatter.accessibilityLabel(for: shortcut))
            } else {
                Text("No shortcut assigned")
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ShortcutFormatter.accessibilityLabel(for: nil))
            }
        }
    }

    private func keyName(for shortcut: ShortcutBinding) -> String {
        let modifierCount = [shortcut.control, shortcut.option, shortcut.shift, shortcut.command].filter { $0 }.count
        return String(ShortcutFormatter.label(for: shortcut).dropFirst(modifierCount))
    }
}

struct ShortcutCaptureField: NSViewRepresentable {
    enum CaptureAction: Equatable {
        case ignored
        case cancelled
        case captured(ShortcutBinding)
    }

    let isRecording: Bool
    let onAction: (CaptureAction) -> Void
    let onFocusLost: () -> Void
    let onUnmount: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction, onFocusLost: onFocusLost, onUnmount: onUnmount)
    }

    func makeNSView(context: Context) -> ShortcutCaptureTextField {
        let field = ShortcutCaptureTextField(frame: .zero)
        field.isRecording = isRecording
        field.coordinator = context.coordinator
        field.placeholderString = "Press a shortcut"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .secondaryLabelColor
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .controlBackgroundColor
        field.setAccessibilityLabel("Shortcut recorder")
        field.setAccessibilityHelp("Press a modifier and a key. Plain Escape cancels.")
        return field
    }

    func updateNSView(_ nsView: ShortcutCaptureTextField, context: Context) {
        context.coordinator.onAction = onAction
        context.coordinator.onFocusLost = onFocusLost
        context.coordinator.onUnmount = onUnmount
        nsView.coordinator = context.coordinator
        let shouldRecord = isRecording && !nsView.hasLostFocus
        let beganRecording = shouldRecord && !nsView.isRecording
        nsView.isRecording = shouldRecord
        if beganRecording { nsView.requestCaptureFocus() }
    }

    static func dismantleNSView(_ nsView: ShortcutCaptureTextField, coordinator: Coordinator) {
        nsView.stopObservingWindow()
        nsView.isRecording = false
        nsView.coordinator = nil
        coordinator.onUnmount()
    }

    static func captureAction(
        for event: NSEvent,
        isRecording: Bool,
        isFocused: Bool
    ) -> CaptureAction {
        guard isRecording, isFocused, event.type == .keyDown else { return .ignored }
        guard !event.isARepeat else { return .ignored }
        let flags = event.modifierFlags
        let hasModifier = flags.contains(.command) || flags.contains(.option)
            || flags.contains(.control) || flags.contains(.shift)
        if event.keyCode == UInt16(kVK_Escape), !hasModifier { return .cancelled }

        let shortcut = ShortcutBinding(
            keyCode: event.keyCode,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
        guard (try? ShortcutValidator.validate(shortcut)) != nil else { return .ignored }
        return .captured(shortcut)
    }

    static func interceptsKeyEquivalent(
        _ event: NSEvent,
        isRecording: Bool,
        isFocused: Bool
    ) -> Bool {
        isRecording && isFocused && event.type == .keyDown
    }

    @MainActor
    final class Coordinator {
        var onAction: (CaptureAction) -> Void
        var onFocusLost: () -> Void
        var onUnmount: () -> Void

        init(
            onAction: @escaping (CaptureAction) -> Void,
            onFocusLost: @escaping () -> Void,
            onUnmount: @escaping () -> Void
        ) {
            self.onAction = onAction
            self.onFocusLost = onFocusLost
            self.onUnmount = onUnmount
        }
    }
}

@MainActor
final class ShortcutCaptureTextField: NSTextField {
    weak var coordinator: ShortcutCaptureField.Coordinator?
    var isRecording = false
    private(set) var hasLostFocus = false
    private var keyWindowObserver: NSObjectProtocol?
    private var didRequestCaptureFocus = false

    override var acceptsFirstResponder: Bool { isRecording }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        guard let window else { return }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForFocusLoss() }
        }
        requestCaptureFocus()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, isFocused else { return }
        coordinator?.onAction(ShortcutCaptureField.captureAction(for: event, isRecording: true, isFocused: true))
    }

    override func flagsChanged(with event: NSEvent) {
        guard !(isRecording && isFocused) else { return }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ShortcutCaptureField.interceptsKeyEquivalent(event, isRecording: isRecording, isFocused: isFocused) else {
            return super.performKeyEquivalent(with: event)
        }
        coordinator?.onAction(ShortcutCaptureField.captureAction(for: event, isRecording: true, isFocused: true))
        return true
    }

    override func resignFirstResponder() -> Bool {
        let wasRecording = isRecording
        let didResign = super.resignFirstResponder()
        if wasRecording && didResign { stopForFocusLoss() }
        return didResign
    }

    func requestCaptureFocus() {
        guard isRecording, !didRequestCaptureFocus, let window else { return }
        didRequestCaptureFocus = true
        if window.firstResponder !== self, !window.makeFirstResponder(self) { stopForFocusLoss() }
    }

    func stopObservingWindow() {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
    }

    private var isFocused: Bool {
        window?.firstResponder === self
    }

    private func stopForFocusLoss() {
        guard isRecording else { return }
        isRecording = false
        hasLostFocus = true
        Task { @MainActor [weak self] in self?.coordinator?.onFocusLost() }
    }
}

enum ShortcutFormatter {
    static func label(for shortcut: ShortcutBinding?) -> String {
        guard let shortcut else { return "Not set" }
        let modifiers = [
            shortcut.control ? "⌃" : "",
            shortcut.option ? "⌥" : "",
            shortcut.shift ? "⇧" : "",
            shortcut.command ? "⌘" : ""
        ].joined()
        return modifiers + keyName(for: shortcut.keyCode)
    }

    static func accessibilityLabel(for shortcut: ShortcutBinding?) -> String {
        guard let shortcut else { return "Not assigned" }
        let modifiers = [
            shortcut.control ? "Control" : nil,
            shortcut.option ? "Option" : nil,
            shortcut.shift ? "Shift" : nil,
            shortcut.command ? "Command" : nil
        ].compactMap { $0 }
        return (modifiers + [keyName(for: shortcut.keyCode)]).joined(separator: " + ")
    }

    private static func keyName(for keyCode: UInt16) -> String {
        specialKeyNames[keyCode] ?? keyboardLayoutName(for: keyCode) ?? "Physical key \(keyCode)"
    }

    private static func keyboardLayoutName(for keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let name = String(utf16CodeUnits: characters, count: Int(length))
            guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return name.uppercased()
        }
    }

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_ISO_Section): "Section", UInt16(kVK_JIS_Yen): "Yen",
        UInt16(kVK_JIS_Underscore): "Underscore", UInt16(kVK_JIS_KeypadComma): "Keypad Comma",
        UInt16(kVK_JIS_Eisu): "Eisu", UInt16(kVK_JIS_Kana): "Kana",
        UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_Escape): "Escape",
        UInt16(kVK_ForwardDelete): "Forward Delete", UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End", UInt16(kVK_PageUp): "Page Up", UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_LeftArrow): "Left Arrow", UInt16(kVK_RightArrow): "Right Arrow",
        UInt16(kVK_DownArrow): "Down Arrow", UInt16(kVK_UpArrow): "Up Arrow",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        UInt16(kVK_ANSI_Keypad0): "Keypad 0", UInt16(kVK_ANSI_Keypad1): "Keypad 1",
        UInt16(kVK_ANSI_Keypad2): "Keypad 2", UInt16(kVK_ANSI_Keypad3): "Keypad 3",
        UInt16(kVK_ANSI_Keypad4): "Keypad 4", UInt16(kVK_ANSI_Keypad5): "Keypad 5",
        UInt16(kVK_ANSI_Keypad6): "Keypad 6", UInt16(kVK_ANSI_Keypad7): "Keypad 7",
        UInt16(kVK_ANSI_Keypad8): "Keypad 8", UInt16(kVK_ANSI_Keypad9): "Keypad 9",
        UInt16(kVK_ANSI_KeypadDecimal): "Keypad Decimal",
        UInt16(kVK_ANSI_KeypadMultiply): "Keypad Multiply",
        UInt16(kVK_ANSI_KeypadPlus): "Keypad Plus", UInt16(kVK_ANSI_KeypadClear): "Keypad Clear",
        UInt16(kVK_ANSI_KeypadDivide): "Keypad Divide", UInt16(kVK_ANSI_KeypadEnter): "Keypad Enter",
        UInt16(kVK_ANSI_KeypadMinus): "Keypad Minus", UInt16(kVK_ANSI_KeypadEquals): "Keypad Equals",
        UInt16(kVK_Help): "Help"
    ]
}
#endif
