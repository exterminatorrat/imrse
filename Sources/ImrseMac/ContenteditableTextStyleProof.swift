#if os(macOS)
import CoreFoundation
import CoreGraphics
import Foundation
import ImrseCore

struct ContenteditableTextStyleProof {
    static let maximumWholeValueUTF16Length = 65_536

    private static let fontKey = NSAttributedString.Key("AXFont")
    private static let foregroundColorKey = NSAttributedString.Key("AXForegroundColor")
    private static let backgroundColorKey = NSAttributedString.Key("AXBackgroundColor")
    private static let markedMisspelledKey = NSAttributedString.Key("AXMarkedMisspelled")
    private static let allowedKeys: Set<NSAttributedString.Key> = [fontKey, foregroundColorKey, backgroundColorKey]
    private static let maximumFontDictionaryEntries = 32
    private static let maximumFontDictionaryKeyUTF16Length = 128
    private static let maximumStyleStringUTF16Length = 1_024

    private let originalTextUTF16: [UInt16]
    private let expectedTextUTF16: [UInt16]
    private let style: StyleSnapshot

    var originalText: String { String(decoding: originalTextUTF16, as: UTF16.self) }
    var expectedText: String { String(decoding: expectedTextUTF16, as: UTF16.self) }
    var originalValue: NSAttributedString { style.attributedString(textUTF16: originalTextUTF16) }
    var expectedValue: NSAttributedString { style.attributedString(textUTF16: expectedTextUTF16) }

    init?(
        originalValue: NSAttributedString,
        selectionRange: ImrseCore.TextRange,
        selectedText: String,
        replacement: String
    ) {
        guard originalValue.length > 0,
              originalValue.length <= Self.maximumWholeValueUTF16Length
        else {
            return nil
        }

        let originalString = originalValue.string
        let originalUTF16 = Array(originalString.utf16)
        guard originalUTF16.count == originalValue.length else { return nil }

        guard let style = Self.uniformStyle(in: originalValue) else { return nil }

        self.init(
            originalTextUTF16: originalUTF16,
            style: style,
            selectionRange: selectionRange,
            selectedText: selectedText,
            replacement: replacement
        )
    }

    func confirmsApplied(_ actual: NSAttributedString) -> Bool {
        Self.confirms(actual, textUTF16: expectedTextUTF16, style: style)
    }

    func confirmsOriginal(_ actual: NSAttributedString) -> Bool {
        Self.confirms(actual, textUTF16: originalTextUTF16, style: style)
    }

    func inverse(
        selectionRange: ImrseCore.TextRange,
        selectedText: String,
        replacement: String
    ) -> Self? {
        guard let inverse = Self(
            originalTextUTF16: expectedTextUTF16,
            style: style,
            selectionRange: selectionRange,
            selectedText: selectedText,
            replacement: replacement
        ),
        inverse.expectedTextUTF16.elementsEqual(originalTextUTF16)
        else {
            return nil
        }
        return inverse
    }

    private init?(
        originalTextUTF16: [UInt16],
        style: StyleSnapshot,
        selectionRange: ImrseCore.TextRange,
        selectedText: String,
        replacement: String
    ) {
        guard !selectedText.isEmpty,
              !replacement.isEmpty,
              !originalTextUTF16.isEmpty,
              originalTextUTF16.count <= Self.maximumWholeValueUTF16Length,
              UTF16SelectionRange.isValid(selectionRange),
              selectionRange.length > 0
        else {
            return nil
        }

        let originalString = String(decoding: originalTextUTF16, as: UTF16.self)
        guard let context = UTF16SelectionRange.substring(originalString, range: selectionRange),
              context.utf16.elementsEqual(selectedText.utf16)
        else {
            return nil
        }

        let retainedLength = originalTextUTF16.count - selectionRange.length
        let replacementLength = replacement.utf16.count
        guard replacementLength <= Self.maximumWholeValueUTF16Length - retainedLength else { return nil }
        let replacementUTF16 = Array(replacement.utf16)
        let expectedLength = retainedLength + replacementLength
        let lowerBound = selectionRange.location
        let upperBound = lowerBound + selectionRange.length
        var expectedUTF16: [UInt16] = []
        expectedUTF16.reserveCapacity(expectedLength)
        expectedUTF16.append(contentsOf: originalTextUTF16[..<lowerBound])
        expectedUTF16.append(contentsOf: replacementUTF16)
        expectedUTF16.append(contentsOf: originalTextUTF16[upperBound...])

        self.originalTextUTF16 = originalTextUTF16
        self.expectedTextUTF16 = expectedUTF16
        self.style = style
    }

    private static func confirms(
        _ actual: NSAttributedString,
        textUTF16: [UInt16],
        style: StyleSnapshot
    ) -> Bool {
        guard actual.length > 0,
              actual.length <= maximumWholeValueUTF16Length,
              actual.length == textUTF16.count,
              textUTF16.elementsEqual(actual.string.utf16)
        else {
            return false
        }

        guard let actualStyle = uniformStyle(in: actual) else { return false }
        return style.matches(actualStyle)
    }

    private static func uniformStyle(in value: NSAttributedString) -> StyleSnapshot? {
        guard value.length > 0,
              value.length <= maximumWholeValueUTF16Length,
              let style = StyleSnapshot(attributes: value.attributes(at: 0, effectiveRange: nil))
        else { return nil }

        var index = 0
        while index < value.length {
            var run = NSRange(location: 0, length: 0)
            let attributes = value.attributes(at: index, effectiveRange: &run)
            guard run.location >= 0,
                  run.location <= index,
                  run.length > 0,
                  run.length <= value.length - run.location,
                  index < run.location + run.length,
                  style.matches(attributes: attributes)
            else { return nil }
            index = run.location + run.length
        }
        return style
    }

    private static func frozenString(_ value: Any, maximumUTF16Length: Int) -> FrozenString? {
        let codeUnits: [UInt16]
        if Swift.type(of: value) == String.self {
            guard let string = value as? String,
                  string.utf16.count <= maximumUTF16Length
            else {
                return nil
            }
            codeUnits = Array(string.utf16)
        } else {
            guard let string = value as? NSString,
                  string.length <= maximumUTF16Length
            else {
                return nil
            }
            var copied = [UInt16](repeating: 0, count: string.length)
            if !copied.isEmpty {
                copied.withUnsafeMutableBufferPointer { buffer in
                    string.getCharacters(
                        buffer.baseAddress!,
                        range: NSRange(location: 0, length: buffer.count)
                    )
                }
            }
            codeUnits = copied
        }

        guard String(decoding: codeUnits, as: UTF16.self).utf16.elementsEqual(codeUnits) else { return nil }
        return FrozenString(utf16: codeUnits)
    }

    private static func frozenColor(_ value: Any) -> FrozenColor? {
        if Swift.type(of: value) == String.self {
            guard let string = frozenString(value, maximumUTF16Length: maximumStyleStringUTF16Length) else {
                return nil
            }
            return .string(string)
        }
        if let stringValue = value as? NSString {
            guard stringValue.length <= maximumStyleStringUTF16Length,
                  let string = frozenString(value, maximumUTF16Length: maximumStyleStringUTF16Length)
            else {
                return nil
            }
            return .string(string)
        }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CGColor.typeID
        else {
            return nil
        }
        return .color(unsafeDowncast(cfValue, to: CGColor.self))
    }

    private static func frozenNumber(_ value: Any) -> FrozenNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return FrozenNumber(number)
    }

    private struct FrozenString: Equatable {
        let utf16: [UInt16]

        var string: String { String(decoding: utf16, as: UTF16.self) }

        func matches(_ value: String) -> Bool {
            utf16.elementsEqual(value.utf16)
        }
    }

    private struct FrozenNumber {
        let decimal: Decimal

        init?(_ number: NSNumber) {
            let decimal = number.decimalValue
            guard !decimal.isNaN,
                  NSDecimalNumber(decimal: decimal).compare(number) == .orderedSame
            else {
                return nil
            }
            self.decimal = decimal
        }

        func matches(_ other: FrozenNumber) -> Bool { decimal == other.decimal }

        var number: NSNumber { NSDecimalNumber(decimal: decimal) }
    }

    private enum FontDictionaryValue {
        case string(FrozenString)
        case number(FrozenNumber)

        init?(value: Any) {
            if let string = ContenteditableTextStyleProof.frozenString(
                value,
                maximumUTF16Length: ContenteditableTextStyleProof.maximumStyleStringUTF16Length
            ) {
                self = .string(string)
            } else if let number = ContenteditableTextStyleProof.frozenNumber(value) {
                self = .number(number)
            } else {
                return nil
            }
        }

        func matches(_ other: FontDictionaryValue) -> Bool {
            switch (self, other) {
            case let (.string(lhs), .string(rhs)):
                return lhs == rhs
            case let (.number(lhs), .number(rhs)):
                return lhs.matches(rhs)
            default:
                return false
            }
        }

        var foundationValue: Any {
            switch self {
            case .string(let value): return value.string as NSString
            case .number(let value): return value.number
            }
        }
    }

    private struct FontDictionaryEntry {
        let key: FrozenString
        let value: FontDictionaryValue
    }

    private enum FontValue {
        case string(FrozenString)
        case dictionary([FontDictionaryEntry])

        init?(value: Any) {
            if let string = ContenteditableTextStyleProof.frozenString(
                value,
                maximumUTF16Length: ContenteditableTextStyleProof.maximumStyleStringUTF16Length
            ) {
                self = .string(string)
                return
            }

            guard let dictionary = value as? NSDictionary else { return nil }
            let count = dictionary.count
            guard count > 0,
                  count <= ContenteditableTextStyleProof.maximumFontDictionaryEntries
            else {
                return nil
            }

            var entries: [FontDictionaryEntry] = []
            entries.reserveCapacity(count)
            for (rawKey, rawValue) in dictionary {
                guard entries.count < count,
                      entries.count < ContenteditableTextStyleProof.maximumFontDictionaryEntries,
                      let key = ContenteditableTextStyleProof.frozenString(
                        rawKey,
                        maximumUTF16Length: ContenteditableTextStyleProof.maximumFontDictionaryKeyUTF16Length
                      ),
                      let value = FontDictionaryValue(value: rawValue)
                else {
                    return nil
                }
                entries.append(FontDictionaryEntry(key: key, value: value))
            }
            guard entries.count == count else { return nil }
            self = .dictionary(entries)
        }

        func matches(_ other: FontValue) -> Bool {
            switch (self, other) {
            case let (.string(lhs), .string(rhs)):
                return lhs == rhs
            case let (.dictionary(lhs), .dictionary(rhs)):
                guard lhs.count == rhs.count else { return false }
                return lhs.allSatisfy { entry in
                    rhs.contains { entry.key == $0.key && entry.value.matches($0.value) }
                }
            default:
                return false
            }
        }

        var foundationValue: Any {
            switch self {
            case .string(let value):
                return value.string as NSString
            case .dictionary(let entries):
                let dictionary = NSMutableDictionary(capacity: entries.count)
                for entry in entries {
                    dictionary.setObject(entry.value.foundationValue, forKey: entry.key.string as NSString)
                }
                return dictionary.copy() as! NSDictionary
            }
        }
    }

    private enum FrozenColor {
        case string(FrozenString)
        case color(CGColor)

        func matches(_ other: FrozenColor) -> Bool {
            switch (self, other) {
            case let (.string(lhs), .string(rhs)):
                return lhs == rhs
            case let (.color(lhs), .color(rhs)):
                return lhs == rhs
            default:
                return false
            }
        }

        var foundationValue: Any {
            switch self {
            case .string(let value): return value.string as NSString
            case .color(let value): return value
            }
        }
    }

    private struct StyleSnapshot {
        let font: FontValue
        let foregroundColor: FrozenColor
        let backgroundColor: FrozenColor?

        init?(attributes: [NSAttributedString.Key: Any]) {
            var attributes = attributes
            if let annotation = attributes.removeValue(forKey: ContenteditableTextStyleProof.markedMisspelledKey) {
                guard CFGetTypeID(annotation as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            }
            guard attributes.keys.allSatisfy(ContenteditableTextStyleProof.allowedKeys.contains),
                  attributes.count == 2 || attributes.count == 3,
                  let fontValue = attributes[ContenteditableTextStyleProof.fontKey],
                  let font = FontValue(value: fontValue),
                  let foregroundValue = attributes[ContenteditableTextStyleProof.foregroundColorKey],
                  let foregroundColor = ContenteditableTextStyleProof.frozenColor(foregroundValue)
            else {
                return nil
            }

            let backgroundColor: FrozenColor?
            if let value = attributes[ContenteditableTextStyleProof.backgroundColorKey] {
                guard let frozen = ContenteditableTextStyleProof.frozenColor(value) else { return nil }
                backgroundColor = frozen
            } else {
                backgroundColor = nil
            }

            self.font = font
            self.foregroundColor = foregroundColor
            self.backgroundColor = backgroundColor
        }

        func matches(attributes: [NSAttributedString.Key: Any]) -> Bool {
            guard let other = StyleSnapshot(attributes: attributes) else { return false }
            return matches(other)
        }

        func matches(_ other: StyleSnapshot) -> Bool {
            guard font.matches(other.font),
                  foregroundColor.matches(other.foregroundColor)
            else {
                return false
            }
            switch (backgroundColor, other.backgroundColor) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return lhs.matches(rhs)
            default: return false
            }
        }

        func attributedString(textUTF16: [UInt16]) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [
                ContenteditableTextStyleProof.fontKey: font.foundationValue,
                ContenteditableTextStyleProof.foregroundColorKey: foregroundColor.foundationValue
            ]
            if let backgroundColor {
                attributes[ContenteditableTextStyleProof.backgroundColorKey] = backgroundColor.foundationValue
            }
            return NSAttributedString(
                string: String(decoding: textUTF16, as: UTF16.self),
                attributes: attributes
            )
        }
    }
}
#endif
