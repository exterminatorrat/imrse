import Foundation

public struct ShortcutEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyDown
        case keyUp
        case flagsChanged
        case keyRepeat
    }

    public let kind: Kind
    public let keyCode: UInt16
    public let timestamp: TimeInterval
    public let command: Bool
    public let option: Bool
    public let control: Bool
    public let shift: Bool

    public init(
        kind: Kind,
        keyCode: UInt16,
        timestamp: TimeInterval,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.timestamp = timestamp
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }
}

public enum ShortcutAction: Equatable, Sendable {
    case invoke
    case preset(id: String)
}

public enum ShortcutValidator {
    public static func validate(_ binding: ShortcutBinding, against assigned: [ShortcutBinding] = []) throws {
        guard isValidBinding(binding) else {
            throw ImrseError.shortcutConflict
        }
        guard !assigned.contains(where: { sameBinding($0, binding) }) else {
            throw ImrseError.shortcutConflict
        }
    }

    static func isValidBinding(_ binding: ShortcutBinding) -> Bool {
        binding.keyCode < 128 && !(54...63).contains(binding.keyCode)
            && (binding.command || binding.option || binding.control)
    }

    private static func sameBinding(_ lhs: ShortcutBinding, _ rhs: ShortcutBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.command == rhs.command && lhs.option == rhs.option &&
        lhs.control == rhs.control && lhs.shift == rhs.shift
    }
}

public struct ShortcutRecognizer: Sendable {
    private struct ControlTap: Sendable {
        var pressedAt: TimeInterval
        var releasedAt: TimeInterval?
        var secondPressedAt: TimeInterval?
        var secondKeyCode: UInt16?
    }

    private let configuration: InvocationConfiguration
    private let presets: [Preset]
    private let doubleControlInterval: TimeInterval?
    private var controlKeysDown: Set<UInt16> = []
    private var otherKeysDown: Set<UInt16> = []
    private var controlTap: ControlTap?
    private var lastTimestamp: TimeInterval?

    public init(configuration: InvocationConfiguration, presets: [Preset]) {
        self.configuration = configuration
        self.presets = presets
        let interval = configuration.doubleControlInterval
        doubleControlInterval = interval.isFinite && interval > 0 ? interval : nil
    }

    public mutating func consume(_ event: ShortcutEvent) -> ShortcutAction? {
        guard event.timestamp.isFinite, event.timestamp >= 0 else {
            resetSequence()
            lastTimestamp = nil
            return nil
        }
        if let lastTimestamp, event.timestamp < lastTimestamp {
            resetSequence()
            self.lastTimestamp = event.timestamp
            return nil
        }
        lastTimestamp = event.timestamp

        if event.kind == .keyRepeat {
            controlTap = nil
            if !Self.isControlKey(event.keyCode) { otherKeysDown.insert(event.keyCode) }
            return nil
        }

        if Self.isControlKey(event.keyCode) {
            return consumeControlEvent(event) ? .invoke : nil
        }

        switch event.kind {
        case .keyDown:
            otherKeysDown.insert(event.keyCode)
            controlTap = nil
            return configuredAction(for: event)
        case .keyUp:
            otherKeysDown.remove(event.keyCode)
            return nil
        case .flagsChanged:
            controlTap = nil
            return nil
        case .keyRepeat:
            return nil
        }
    }

    private mutating func consumeControlEvent(_ event: ShortcutEvent) -> Bool {
        guard configuration.doubleControlEnabled, let doubleControlInterval else {
            controlTap = nil
            return false
        }
        let wasDown = controlKeysDown.contains(event.keyCode)
        let isDown: Bool
        switch event.kind {
        case .keyDown:
            isDown = true
        case .keyUp:
            isDown = false
        case .flagsChanged:
            isDown = !wasDown
        case .keyRepeat:
            controlTap = nil
            return false
        }

        guard isDown != wasDown else {
            controlTap = nil
            return false
        }

        if isDown {
            let anotherControlIsDown = !controlKeysDown.isEmpty
            controlKeysDown.insert(event.keyCode)
            guard !anotherControlIsDown,
                  event.control,
                  !event.command, !event.option, !event.shift,
                  otherKeysDown.isEmpty else {
                controlTap = nil
                return false
            }

            if var controlTap, let releasedAt = controlTap.releasedAt {
                guard event.timestamp >= controlTap.pressedAt,
                      event.timestamp - controlTap.pressedAt <= doubleControlInterval,
                      event.timestamp >= releasedAt else {
                    self.controlTap = ControlTap(pressedAt: event.timestamp, releasedAt: nil, secondPressedAt: nil, secondKeyCode: nil)
                    return false
                }
                controlTap.secondPressedAt = event.timestamp
                controlTap.secondKeyCode = event.keyCode
                self.controlTap = controlTap
                return false
            }
            self.controlTap = ControlTap(pressedAt: event.timestamp, releasedAt: nil, secondPressedAt: nil, secondKeyCode: nil)
            return false
        }

        controlKeysDown.remove(event.keyCode)
        guard controlKeysDown.isEmpty,
              !event.control,
              !event.command, !event.option, !event.shift,
              otherKeysDown.isEmpty,
              var controlTap else {
            self.controlTap = nil
            return false
        }
        if let secondPressedAt = controlTap.secondPressedAt {
            guard controlTap.secondKeyCode == event.keyCode,
                  event.timestamp >= secondPressedAt,
                  event.timestamp - secondPressedAt <= doubleControlInterval else {
                self.controlTap = nil
                return false
            }
            self.controlTap = nil
            return true
        }
        guard controlTap.releasedAt == nil,
              event.timestamp >= controlTap.pressedAt,
              event.timestamp - controlTap.pressedAt <= doubleControlInterval else {
            self.controlTap = nil
            return false
        }
        controlTap.releasedAt = event.timestamp
        self.controlTap = controlTap
        return false
    }

    private func configuredAction(for event: ShortcutEvent) -> ShortcutAction? {
        guard event.kind == .keyDown else { return nil }
        if let binding = configuration.shortcut, ShortcutValidator.isValidBinding(binding), Self.matches(binding, event) { return .invoke }
        for preset in presets {
            guard !preset.id.isEmpty, let binding = preset.shortcut,
                  ShortcutValidator.isValidBinding(binding), Self.matches(binding, event) else { continue }
            return .preset(id: preset.id)
        }
        return nil
    }

    private mutating func resetSequence() {
        controlTap = nil
        controlKeysDown.removeAll()
        otherKeysDown.removeAll()
    }

    private static func isControlKey(_ keyCode: UInt16) -> Bool {
        keyCode == 59 || keyCode == 62
    }

    private static func matches(_ binding: ShortcutBinding, _ event: ShortcutEvent) -> Bool {
        binding.keyCode == event.keyCode && binding.command == event.command &&
        binding.option == event.option && binding.control == event.control && binding.shift == event.shift
    }

}
