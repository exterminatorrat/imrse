#if os(macOS)
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImrseCore

public enum ShortcutMonitorError: Error, LocalizedError {
    case inputMonitoringPermissionRequired
    case eventTapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .inputMonitoringPermissionRequired:
            "Input Monitoring permission is required for global keyboard shortcuts. Enable imrse in System Settings → Privacy & Security → Input Monitoring, then retry."
        case .eventTapCreationFailed:
            "Keyboard monitoring couldn't start. Check Input Monitoring in System Settings, then retry."
        }
    }
}

@MainActor
public final class ShortcutMonitor {
    private final class TapContext: @unchecked Sendable {
        weak var owner: ShortcutMonitor?

        init(owner: ShortcutMonitor) {
            self.owner = owner
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapContext: TapContext?
    private var secureInputTimer: DispatchSourceTimer?
    private var configuration: InvocationConfiguration?
    private var presets: [Preset] = []
    private var recognizer: ShortcutRecognizer?
    private var onInvoke: (@MainActor (String?) -> Void)?

    public static var eventMonitoringPermissionGranted: Bool {
        CGPreflightListenEventAccess()
    }

    public var isMonitoring: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    public init() {}

    public func start(
        configuration: InvocationConfiguration,
        presets: [Preset],
        onInvoke: @escaping @MainActor (String?) -> Void
    ) throws {
        guard Self.eventMonitoringPermissionGranted else { throw ShortcutMonitorError.inputMonitoringPermissionRequired }
        try Self.validateBindings(configuration: configuration, presets: presets)

        let context = TapContext(owner: self)
        let eventMask = Self.eventMask
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            throw ShortcutMonitorError.eventTapCreationFailed
        }

        stop()
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        tapContext = context
        self.configuration = configuration
        self.presets = presets
        recognizer = ShortcutRecognizer(configuration: configuration, presets: presets)
        self.onInvoke = onInvoke
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        startSecureInputGuard()
    }

    public func stop() {
        secureInputTimer?.cancel()
        secureInputTimer = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        tapContext = nil
        configuration = nil
        presets = []
        recognizer = nil
        onInvoke = nil
    }

    private static let eventMask: CGEventMask =
        (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                context.owner?.reenableEventTap()
            }
            return Unmanaged.passUnretained(event)
        }

        let kind: ShortcutEvent.Kind
        switch type {
        case .keyDown:
            kind = event.getIntegerValueField(.keyboardEventAutorepeat) == 0 ? .keyDown : .keyRepeat
        case .keyUp:
            kind = .keyUp
        case .flagsChanged:
            kind = .flagsChanged
        default:
            return Unmanaged.passUnretained(event)
        }
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let keyCode = UInt16(exactly: rawKeyCode) else { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        let shortcutEvent = ShortcutEvent(
            kind: kind,
            keyCode: keyCode,
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000,
            command: flags.contains(.maskCommand),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl),
            shift: flags.contains(.maskShift)
        )
        MainActor.assumeIsolated {
            context.owner?.consume(shortcutEvent)
        }
        return Unmanaged.passUnretained(event)
    }

    private static func validateBindings(configuration: InvocationConfiguration, presets: [Preset]) throws {
        var assigned: [ShortcutBinding] = []
        if let shortcut = configuration.shortcut {
            try ShortcutValidator.validate(shortcut, against: assigned)
            assigned.append(shortcut)
        }
        for preset in presets {
            guard let shortcut = preset.shortcut else { continue }
            try ShortcutValidator.validate(shortcut, against: assigned)
            assigned.append(shortcut)
        }
    }

    private func consume(_ event: ShortcutEvent) {
        guard !IsSecureEventInputEnabled() else {
            resetRecognizer()
            return
        }
        guard var recognizer else { return }
        let action = recognizer.consume(event)
        self.recognizer = recognizer
        switch action {
        case .invoke:
            onInvoke?(nil)
        case .preset(let id):
            onInvoke?(id)
        case nil:
            break
        }
    }

    private func startSecureInputGuard() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if IsSecureEventInputEnabled() { self.resetRecognizer() }
            }
        }
        secureInputTimer = timer
        timer.resume()
    }

    private func resetRecognizer() {
        guard let configuration else { return }
        recognizer = ShortcutRecognizer(configuration: configuration, presets: presets)
    }

    private func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}
#endif
