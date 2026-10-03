import XCTest
@testable import ImrseCore

final class ShortcutRecognizerTests: XCTestCase {
    func testModifierKeyCodesCannotBeBindingsButFunctionKeysCan() throws {
        for keyCode: UInt16 in 54...63 {
            let binding = ShortcutBinding(keyCode: keyCode, command: true)
            XCTAssertThrowsError(try ShortcutValidator.validate(binding))
            var recognizer = ShortcutRecognizer(
                configuration: InvocationConfiguration(doubleControlEnabled: false, shortcut: binding),
                presets: []
            )
            XCTAssertNil(recognizer.consume(ShortcutEvent(kind: .keyDown, keyCode: keyCode, timestamp: 1, command: true)))
        }

        let functionKey = ShortcutBinding(keyCode: 122, command: true)
        XCTAssertNoThrow(try ShortcutValidator.validate(functionKey))
        var recognizer = ShortcutRecognizer(
            configuration: InvocationConfiguration(doubleControlEnabled: false, shortcut: functionKey),
            presets: []
        )
        XCTAssertEqual(recognizer.consume(ShortcutEvent(kind: .keyDown, keyCode: 122, timestamp: 1, command: true)), .invoke)
    }

    func testOtherModifierChangesInterruptPendingControlTaps() {
        for keyCode: UInt16 in [57, 63] {
            var recognizer = ShortcutRecognizer(configuration: .init(), presets: [])
            XCTAssertNil(recognizer.consume(controlDown(at: 1.0)))
            XCTAssertNil(recognizer.consume(controlUp(at: 1.04)))
            XCTAssertNil(recognizer.consume(ShortcutEvent(kind: .flagsChanged, keyCode: keyCode, timestamp: 1.06)))
            XCTAssertNil(recognizer.consume(controlDown(at: 1.1)))
            XCTAssertNil(recognizer.consume(controlUp(at: 1.12)))
        }
    }

    func testDoubleControlInvokesOnlyAfterTwoReleasedControlTaps() {
        var recognizer = ShortcutRecognizer(configuration: .init(), presets: [])

        XCTAssertNil(recognizer.consume(controlDown(at: 1.0)))
        XCTAssertNil(recognizer.consume(controlUp(at: 1.04)))
        XCTAssertNil(recognizer.consume(controlDown(at: 1.18)))
        XCTAssertEqual(recognizer.consume(controlUp(at: 1.20)), .invoke)
    }

    func testDoubleControlRejectsChordRepeatInterveningKeyAndSlowSecondTap() {
        var chord = ShortcutRecognizer(configuration: .init(), presets: [])
        XCTAssertNil(chord.consume(controlDown(at: 1.0)))
        XCTAssertNil(chord.consume(controlUp(at: 1.02)))
        XCTAssertNil(chord.consume(controlDown(at: 1.10)))
        XCTAssertNil(chord.consume(ShortcutEvent(kind: .keyDown, keyCode: 8, timestamp: 1.11, control: true)))
        XCTAssertNil(chord.consume(ShortcutEvent(kind: .keyUp, keyCode: 8, timestamp: 1.12, control: true)))
        XCTAssertNil(chord.consume(controlUp(at: 1.13)))
        XCTAssertNil(chord.consume(controlDown(at: 1.14)))

        var interveningKey = ShortcutRecognizer(configuration: .init(), presets: [])
        XCTAssertNil(interveningKey.consume(controlDown(at: 2.0)))
        XCTAssertNil(interveningKey.consume(controlUp(at: 2.02)))
        XCTAssertNil(interveningKey.consume(ShortcutEvent(kind: .keyDown, keyCode: 0, timestamp: 2.05)))
        XCTAssertNil(interveningKey.consume(ShortcutEvent(kind: .keyUp, keyCode: 0, timestamp: 2.08)))
        XCTAssertNil(interveningKey.consume(controlDown(at: 2.10)))

        var repeated = ShortcutRecognizer(configuration: .init(), presets: [])
        XCTAssertNil(repeated.consume(controlDown(at: 3.0)))
        XCTAssertNil(repeated.consume(controlUp(at: 3.02)))
        XCTAssertNil(repeated.consume(ShortcutEvent(kind: .keyRepeat, keyCode: 59, timestamp: 3.05, control: true)))
        XCTAssertNil(repeated.consume(controlDown(at: 3.10)))

        var slow = ShortcutRecognizer(configuration: .init(), presets: [])
        XCTAssertNil(slow.consume(controlDown(at: 4.0)))
        XCTAssertNil(slow.consume(controlUp(at: 4.02)))
        XCTAssertNil(slow.consume(controlDown(at: 4.1)))
        XCTAssertNil(slow.consume(controlUp(at: 4.5)))

        var controlChord = ShortcutRecognizer(configuration: .init(), presets: [])
        XCTAssertNil(controlChord.consume(controlDown(at: 5.0)))
        XCTAssertNil(controlChord.consume(controlUp(at: 5.02)))
        XCTAssertNil(controlChord.consume(controlDown(at: 5.1)))
        XCTAssertNil(controlChord.consume(ShortcutEvent(kind: .keyDown, keyCode: 8, timestamp: 5.11, control: true)))
        XCTAssertNil(controlChord.consume(controlUp(at: 5.12)))
    }

    func testConfiguredAndPresetShortcutsEmitTheirDistinctActions() {
        let configuration = InvocationConfiguration(
            doubleControlEnabled: false,
            shortcut: ShortcutBinding(keyCode: 0, command: true)
        )
        let preset = Preset(
            id: "formal-tone", name: "Formal tone", instruction: "Use a formal tone",
            shortcut: ShortcutBinding(keyCode: 12, option: true, shift: true)
        )
        var recognizer = ShortcutRecognizer(configuration: configuration, presets: [preset])

        XCTAssertNil(recognizer.consume(ShortcutEvent(kind: .keyDown, keyCode: 0, timestamp: 1)))
        XCTAssertEqual(
            recognizer.consume(ShortcutEvent(kind: .keyDown, keyCode: 0, timestamp: 2, command: true)),
            .invoke
        )
        XCTAssertEqual(
            recognizer.consume(ShortcutEvent(kind: .keyDown, keyCode: 12, timestamp: 3, option: true, shift: true)),
            .preset(id: "formal-tone")
        )
        XCTAssertNil(recognizer.consume(ShortcutEvent(kind: .keyRepeat, keyCode: 12, timestamp: 3.1, option: true, shift: true)))

        var shiftOnly = ShortcutRecognizer(
            configuration: InvocationConfiguration(doubleControlEnabled: false, shortcut: ShortcutBinding(keyCode: 12, shift: true)),
            presets: []
        )
        XCTAssertNil(shiftOnly.consume(ShortcutEvent(kind: .keyDown, keyCode: 12, timestamp: 4, shift: true)))
    }

    func testShortcutValidationRequiresModifiersAndRejectsOnlyExactConflicts() throws {
        let noModifiers = ShortcutBinding(keyCode: 12)
        XCTAssertThrowsError(try ShortcutValidator.validate(noModifiers))
        XCTAssertThrowsError(try ShortcutValidator.validate(ShortcutBinding(keyCode: 12, shift: true)))

        let invalidKeyCode = ShortcutBinding(keyCode: .max, command: true)
        XCTAssertThrowsError(try ShortcutValidator.validate(invalidKeyCode))

        let shortcut = ShortcutBinding(keyCode: 12, command: true)
        let conflicting = ShortcutBinding(keyCode: 12, command: true)
        let distinct = ShortcutBinding(keyCode: 12, command: true, shift: true)
        try ShortcutValidator.validate(shortcut)
        XCTAssertThrowsError(try ShortcutValidator.validate(shortcut, against: [conflicting]))
        XCTAssertNoThrow(try ShortcutValidator.validate(shortcut, against: [distinct]))
    }

    private func controlDown(at timestamp: TimeInterval) -> ShortcutEvent {
        ShortcutEvent(kind: .flagsChanged, keyCode: 59, timestamp: timestamp, control: true)
    }

    private func controlUp(at timestamp: TimeInterval) -> ShortcutEvent {
        ShortcutEvent(kind: .flagsChanged, keyCode: 59, timestamp: timestamp)
    }
}
