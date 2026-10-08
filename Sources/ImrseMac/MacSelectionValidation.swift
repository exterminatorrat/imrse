#if os(macOS)
import Foundation
import ImrseCore

enum UTF16SelectionRange {
    static func isValid(_ range: ImrseCore.TextRange) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        let (_, overflow) = range.location.addingReportingOverflow(range.length)
        return !overflow
    }

    static func make(at location: Int, length: Int) -> ImrseCore.TextRange? {
        let range = ImrseCore.TextRange(location: location, length: length)
        return isValid(range) ? range : nil
    }

    static func isWithinSupportedRange(_ range: ImrseCore.TextRange) -> Bool {
        guard isValid(range) else { return false }
        return range.location + range.length <= PlainTextUndoValidation.maximumWholeValueUTF16Length
    }

    static func isCollapsedCaret(
        _ selection: ImrseCore.TextRange,
        selectedText: String,
        atEndOf range: ImrseCore.TextRange
    ) -> Bool {
        guard isValid(selection), isValid(range), selection.length == 0, selectedText.isEmpty else {
            return false
        }
        return selection.location == range.location + range.length
    }

    static func substring(_ value: String, range: ImrseCore.TextRange) -> String? {
        guard isValid(range) else { return nil }
        let string = value as NSString
        guard range.location <= string.length,
              range.length <= string.length - range.location
        else {
            return nil
        }
        let end = range.location + range.length
        guard isScalarBoundary(in: string, at: range.location),
              isScalarBoundary(in: string, at: end)
        else {
            return nil
        }
        return string.substring(with: NSRange(location: range.location, length: range.length))
    }

    static func replacing(_ value: String, range: ImrseCore.TextRange, with replacement: String) -> String? {
        guard substring(value, range: range) != nil,
              !range.location.addingReportingOverflow(replacement.utf16.count).overflow
        else {
            return nil
        }
        return (value as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
    }

    private static func isScalarBoundary(in value: NSString, at offset: Int) -> Bool {
        guard offset > 0, offset < value.length else { return true }
        let previous = value.character(at: offset - 1)
        let next = value.character(at: offset)
        return !(0xD800...0xDBFF).contains(previous) || !(0xDC00...0xDFFF).contains(next)
    }
}

enum AccessibilityFocusAcquisition {
    static func acquire<Element>(
        requestManualAccessibility: () throws -> Void,
        hasTimeForRetry: () -> Bool,
        readFocusedElement: () throws -> Element?,
        validate: (Element) throws -> Void,
        waitBeforeRetry: () -> Void
    ) throws -> Element? {
        _ = try? requestManualAccessibility()
        while true {
            guard let element = try readFocusedElement() else {
                guard hasTimeForRetry() else { return nil }
                waitBeforeRetry()
                guard hasTimeForRetry() else { return nil }
                continue
            }
            try validate(element)
            return element
        }
    }
}

enum SelectedTextRangeFallback {
    static func resolve(
        directText: String?,
        range: ImrseCore.TextRange,
        failure: ImrseError,
        readStringForRange: () throws -> String?
    ) throws -> String? {
        guard UTF16SelectionRange.isValid(range), range.length > 0 else { throw failure }
        if let directText, !directText.isEmpty {
            guard directText.utf16.count == range.length else { throw failure }
            return directText
        }
        guard UTF16SelectionRange.isWithinSupportedRange(range) else { throw failure }
        guard let rangeText = try readStringForRange() else { return nil }
        guard rangeText.utf16.count == range.length else { throw failure }
        return rangeText
    }
}

struct UndoSelectionProof {
    let text: String
    let range: ImrseCore.TextRange
}

enum PlainTextUndoValidation {
    static let maximumWholeValueUTF16Length = 1_000_000

    static func restoredValue(
        currentValue: String,
        receipt: ReplacementReceipt,
        replacementRange: ImrseCore.TextRange,
        currentSelection: UndoSelectionProof,
        receiptSelection: UndoSelectionProof
    ) -> String? {
        guard currentValue.utf16.count <= maximumWholeValueUTF16Length,
              currentSelection.range == receiptSelection.range,
              currentSelection.text.utf16.elementsEqual(receiptSelection.text.utf16),
              let originalRange = receipt.target.range,
              UTF16SelectionRange.make(
                at: originalRange.location,
                length: receipt.target.text.utf16.count
              ) == originalRange,
              originalRange.length == receipt.target.text.utf16.count,
              UTF16SelectionRange.make(
                at: originalRange.location,
                length: receipt.replacement.utf16.count
              ) == replacementRange,
              let currentReplacement = UTF16SelectionRange.substring(currentValue, range: replacementRange),
              currentReplacement.utf16.elementsEqual(receipt.replacement.utf16)
        else {
            return nil
        }
        guard let restoredValue = UTF16SelectionRange.replacing(
            currentValue,
            range: replacementRange,
            with: receipt.target.text
        ), restoredValue.utf16.count <= maximumWholeValueUTF16Length else { return nil }
        return restoredValue
    }
}

@MainActor
enum UndoSelectionConsistencyValidation {
    static let maximumAttempts = 6

    static func firstMatching(
        expected: UndoSelectionProof,
        read: () throws -> UndoSelectionProof?,
        wait: () async -> Void
    ) async throws -> UndoSelectionProof? {
        for attempt in 0..<maximumAttempts {
            if let value = try read(),
               value.range == expected.range,
               value.text.utf16.elementsEqual(expected.text.utf16) {
                return value
            }
            if attempt + 1 < maximumAttempts { await wait() }
        }
        return nil
    }
}

enum ClipboardFallbackNoOpValidation {
    static func baseline(
        value: String?,
        range: ImrseCore.TextRange,
        selectedText: String
    ) -> String? {
        guard let value,
              range.length > 0,
              range.length == selectedText.utf16.count,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let valueText = UTF16SelectionRange.substring(value, range: range),
              valueText.utf16.elementsEqual(selectedText.utf16)
        else {
            return nil
        }
        return value
    }

    static func permits(
        enabled: Bool,
        targetIsSafeAndFocused: Bool,
        range: ImrseCore.TextRange,
        beforeText: String,
        afterRange: ImrseCore.TextRange?,
        afterText: String?,
        beforeValue: String?,
        afterValue: String?
    ) -> Bool {
        guard enabled,
              targetIsSafeAndFocused,
              range.length > 0,
              range.length == beforeText.utf16.count,
              !beforeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              afterRange == range,
              let afterText,
              beforeText.utf16.elementsEqual(afterText.utf16),
              let beforeValue,
              let afterValue,
              beforeValue.utf16.elementsEqual(afterValue.utf16),
              let selectedText = UTF16SelectionRange.substring(beforeValue, range: range),
              selectedText.utf16.elementsEqual(beforeText.utf16)
        else {
            return false
        }
        return true
    }
}

enum SelectedTextReplacementValidation {
    static func confirms(
        afterValue: String?,
        expectedValue: String?,
        afterRange: ImrseCore.TextRange,
        afterText: String,
        replacementRange: ImrseCore.TextRange,
        replacement: String
    ) -> Bool {
        if let afterValue, let expectedValue,
           afterValue.utf16.elementsEqual(expectedValue.utf16) {
            return true
        }
        return afterRange == replacementRange
            && afterText.utf16.elementsEqual(replacement.utf16)
    }
}

enum ClipboardTargetStructureValidation {
    static let maximumNodes = 8

    static func permits<Element>(
        root: Element,
        readRole: (Element) throws -> String,
        readChildren: (Element) throws -> [Element],
        sameElement: (Element, Element) -> Bool
    ) -> Bool {
        do {
            let rootRole = try readRole(root)
            guard rootRole == "AXTextField" || rootRole == "AXTextArea" else { return false }
            let rootChildren = try readChildren(root)
            guard rootChildren.count <= 1 else { return false }
            guard var element = rootChildren.first else { return true }

            var visited = [root]
            var hasGroup = false
            while visited.count < maximumNodes {
                guard !visited.contains(where: { sameElement($0, element) }) else { return false }
                visited.append(element)
                let role = try readRole(element)
                if role == "AXStaticText" {
                    guard hasGroup else { return false }
                    return try readChildren(element).isEmpty
                }
                guard role == "AXGroup" else { return false }
                let children = try readChildren(element)
                guard children.count == 1, let child = children.first else { return false }
                hasGroup = true
                element = child
            }
        } catch {
            return false
        }
        return false
    }
}
#endif
