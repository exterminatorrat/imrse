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
    private static let allowedKeys: Set<NSAttributedString.Key> = [fontKey, foregroundColorKey, backgroundColorKey]
    private static let maximumFontDictionaryEntries = 32
    private static let maximumFontDictionaryKeyUTF16Length = 128
    private static let maximumStyleStringUTF16Length = 1_024

    let originalValue: NSAttributedString
    let expectedValue: NSAttributedString

    init?(
        originalValue: NSAttributedString,
        selectionRange: ImrseCore.TextRange,
        selectedText: String,
        replacement: String
    ) {
        guard !selectedText.isEmpty,
              !replacement.isEmpty,
              originalValue.length > 0,
              originalValue.length <= Self.maximumWholeValueUTF16Length
        else {
            return nil
        }
        let input = NSAttributedString(attributedString: originalValue)
        let originalString = input.string
        let originalLength = originalString.utf16.count
        guard originalLength > 0,
              originalLength <= Self.maximumWholeValueUTF16Length,
              input.length == originalLength,
              UTF16SelectionRange.isValid(selectionRange),
              selectionRange.length > 0,
              let context = UTF16SelectionRange.substring(originalString, range: selectionRange),
              context.utf16.elementsEqual(selectedText.utf16)
        else {
            return nil
        }

        var originalRun = NSRange(location: 0, length: 0)
        let inputAttributes = input.attributes(at: 0, effectiveRange: &originalRun)
        guard originalRun == NSRange(location: 0, length: input.length),
              let attributes = Self.immutableStyleAttributes(inputAttributes)
        else {
            return nil
        }

        let remainingLength = originalLength - selectionRange.length
        let (expectedLength, overflow) = remainingLength.addingReportingOverflow(replacement.utf16.count)
        guard !overflow, expectedLength <= Self.maximumWholeValueUTF16Length else { return nil }
        let expectedString = (originalString as NSString).replacingCharacters(
            in: NSRange(location: selectionRange.location, length: selectionRange.length),
            with: replacement
        )
        guard expectedString.utf16.count == expectedLength else { return nil }

        self.originalValue = NSAttributedString(string: originalString, attributes: attributes)
        self.expectedValue = NSAttributedString(string: expectedString, attributes: attributes)
    }

    func confirmsApplied(_ actual: NSAttributedString) -> Bool {
        Self.confirms(actual, matches: expectedValue)
    }

    func confirmsOriginal(_ actual: NSAttributedString) -> Bool {
        Self.confirms(actual, matches: originalValue)
    }

    private static func confirms(_ actual: NSAttributedString, matches expected: NSAttributedString) -> Bool {
        guard let actual = immutableUniformValue(actual),
              actual.string.utf16.elementsEqual(expected.string.utf16)
        else {
            return false
        }

        var actualRun = NSRange(location: 0, length: 0)
        var expectedRun = NSRange(location: 0, length: 0)
        let actualAttributes = actual.attributes(at: 0, effectiveRange: &actualRun)
        let expectedAttributes = expected.attributes(at: 0, effectiveRange: &expectedRun)
        return actualRun == NSRange(location: 0, length: actual.length)
            && expectedRun == NSRange(location: 0, length: expected.length)
            && attributesEqual(actualAttributes, expectedAttributes)
    }

    private static func immutableUniformValue(_ value: NSAttributedString) -> NSAttributedString? {
        guard value.length > 0, value.length <= maximumWholeValueUTF16Length else { return nil }
        let input = NSAttributedString(attributedString: value)
        let length = input.string.utf16.count
        guard length > 0,
              length <= maximumWholeValueUTF16Length,
              input.length == length
        else {
            return nil
        }

        var run = NSRange(location: 0, length: 0)
        let inputAttributes = input.attributes(at: 0, effectiveRange: &run)
        guard run == NSRange(location: 0, length: input.length),
              let attributes = immutableStyleAttributes(inputAttributes)
        else {
            return nil
        }
        return NSAttributedString(string: input.string, attributes: attributes)
    }

    private static func immutableStyleAttributes(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any]? {
        guard attributes.keys.allSatisfy(allowedKeys.contains),
              attributes[fontKey] != nil,
              attributes[foregroundColorKey] != nil,
              attributes.count == 2 || attributes.count == 3
        else {
            return nil
        }

        var frozen: [NSAttributedString.Key: Any] = [:]
        for (key, value) in attributes {
            guard let copiedValue = immutableStyleValue(value, for: key) else { return nil }
            frozen[key] = copiedValue
        }
        return frozen
    }

    private static func immutableStyleValue(_ value: Any, for key: NSAttributedString.Key) -> Any? {
        if key == fontKey {
            if let value = immutableStyleString(value) { return value }
            guard let dictionary = value as? NSDictionary else {
                return nil
            }
            let count = dictionary.count
            guard count > 0, count <= maximumFontDictionaryEntries else { return nil }

            var copied: [String: Any] = [:]
            copied.reserveCapacity(count)
            for (rawKey, rawValue) in dictionary {
                guard let key = rawKey as? NSString,
                      key.length <= maximumFontDictionaryKeyUTF16Length,
                      let item = immutableFontDictionaryValue(rawValue)
                else {
                    return nil
                }
                copied[key as String] = item
            }
            return NSDictionary(dictionary: copied)
        }

        guard key == foregroundColorKey || key == backgroundColorKey else { return nil }
        if let value = immutableStyleString(value) { return value }
        return immutableColor(value)
    }

    private static func immutableFontDictionaryValue(_ value: Any) -> Any? {
        if let value = immutableStyleString(value) { return value }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.copy() as? NSNumber
    }

    private static func immutableStyleString(_ value: Any) -> NSString? {
        guard let string = value as? NSString,
              string.length <= maximumStyleStringUTF16Length
        else {
            return nil
        }
        return string.copy() as? NSString
    }

    private static func immutableColor(_ value: Any) -> CGColor? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CGColorGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(cfValue, to: CGColor.self)
    }

    private static func attributesEqual(
        _ lhs: [NSAttributedString.Key: Any],
        _ rhs: [NSAttributedString.Key: Any]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { key, value in
            guard let other = rhs[key] else { return false }
            if key == foregroundColorKey || key == backgroundColorKey {
                let lhsColor = immutableColor(value)
                let rhsColor = immutableColor(other)
                if lhsColor != nil || rhsColor != nil {
                    guard let lhsColor, let rhsColor else { return false }
                    return CGColorEqualToColor(lhsColor, rhsColor)
                }
            }
            guard let lhsObject = value as? NSObject,
                  let rhsObject = other as? NSObject
            else {
                return false
            }
            return lhsObject.isEqual(rhsObject)
        }
    }
}
#endif
