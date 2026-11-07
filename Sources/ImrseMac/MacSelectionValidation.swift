#if os(macOS)
import ApplicationServices
import CoreFoundation
import Foundation
import ImrseCore

#if DEBUG
@MainActor
@_spi(SyntheticCaptureDiagnostics)
public struct SyntheticCaptureIdentity {
    public let processIdentifier: Int32
    public let processLaunchDate: Date
    public let bundleIdentifier: String
    public let documentURL: URL
    public let documentRoot: AXUIElement
    public let focusedField: AXUIElement

    public init(
        processIdentifier: Int32,
        processLaunchDate: Date,
        bundleIdentifier: String,
        documentURL: URL,
        documentRoot: AXUIElement,
        focusedField: AXUIElement
    ) {
        self.processIdentifier = processIdentifier
        self.processLaunchDate = processLaunchDate
        self.bundleIdentifier = bundleIdentifier
        self.documentURL = documentURL
        self.documentRoot = documentRoot
        self.focusedField = focusedField
    }
}

@_spi(SyntheticCaptureDiagnostics)
public enum SyntheticCaptureSessionState: Equatable {
    case armed
    case capturing
    case consumed
    case failed
    case cancelled
}

@MainActor
@_spi(SyntheticCaptureDiagnostics)
public final class SyntheticCaptureSession {
    public static let maximumLifetime: Duration = .seconds(30)

    public private(set) var state: SyntheticCaptureSessionState
    private var identity: SyntheticCaptureIdentity?
    private let deadline: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant
    private var attemptsRemaining = 1

    public var retainsNativeIdentity: Bool { identity != nil }

    public convenience init(
        identity: SyntheticCaptureIdentity,
        lifetime: Duration = .seconds(30)
    ) {
        self.init(identity: identity, lifetime: lifetime, now: { ContinuousClock().now })
    }

    public init(
        identity: SyntheticCaptureIdentity,
        lifetime: Duration,
        now: @escaping () -> ContinuousClock.Instant
    ) {
        self.now = now
        guard Self.valid(identity), lifetime > .zero, lifetime <= Self.maximumLifetime else {
            self.identity = nil
            self.deadline = nil
            self.state = .failed
            return
        }
        self.identity = identity
        self.deadline = now().advanced(by: lifetime)
        self.state = .armed
    }

    func beginCapture(intent: SelectionEditIntent) throws -> SyntheticCaptureIdentity {
        guard state == .armed, attemptsRemaining == 1, let identity else {
            if state == .capturing { fail() }
            throw ImrseError.targetLost
        }
        guard isBeforeDeadline else {
            fail()
            throw ImrseError.targetLost
        }
        guard intent == .insertAtCaret else {
            fail()
            throw ImrseError.insertionUnavailable
        }
        attemptsRemaining = 0
        state = .capturing
        return identity
    }

    func isCaptureActive() -> Bool {
        guard state == .capturing, isBeforeDeadline else {
            if state == .capturing || state == .armed { fail() }
            return false
        }
        return identity != nil
    }

    @discardableResult
    func finishCapture(succeeded: Bool) -> Bool {
        guard state == .capturing else { return false }
        guard isBeforeDeadline else {
            fail()
            return false
        }
        state = succeeded ? .consumed : .failed
        identity = nil
        return succeeded
    }

    func fail() {
        guard state == .armed || state == .capturing else { return }
        state = .failed
        identity = nil
    }

    @_spi(SyntheticCaptureDiagnostics)
    public func cancel() {
        guard state == .armed || state == .capturing else { return }
        state = .cancelled
        identity = nil
    }

    private var isBeforeDeadline: Bool {
        guard let deadline else { return false }
        return now() < deadline
    }

    private static func valid(_ identity: SyntheticCaptureIdentity) -> Bool {
        identity.processIdentifier > 0
            && identity.processLaunchDate.timeIntervalSince1970.isFinite
            && identity.processLaunchDate.timeIntervalSince1970 > 0
            && !identity.bundleIdentifier.isEmpty
            && identity.documentURL.isFileURL
            && !identity.documentURL.absoluteString.isEmpty
    }
}

enum SyntheticCaptureMetadataValidation {
    static func processMatches(
        expectedProcessIdentifier: Int32,
        expectedLaunchDate: Date,
        expectedBundleIdentifier: String,
        actualProcessIdentifier: Int32,
        actualLaunchDate: Date?,
        actualBundleIdentifier: String?
    ) -> Bool {
        expectedProcessIdentifier > 0
            && expectedLaunchDate.timeIntervalSince1970.isFinite
            && expectedLaunchDate.timeIntervalSince1970 > 0
            && actualProcessIdentifier > 0
            && expectedProcessIdentifier == actualProcessIdentifier
            && actualLaunchDate == expectedLaunchDate
            && actualBundleIdentifier == expectedBundleIdentifier
    }

    @MainActor
    static func documentRootIsValid<Element>(
        expectedRoot: Element,
        expectedDocumentURL: URL,
        application: Element,
        expectedProcessIdentifier: Int32,
        readFocusedRoot: @MainActor () throws -> Element?,
        readRootParent: @MainActor () throws -> Element?,
        readRootRole: @MainActor () throws -> String?,
        readApplicationProcessIdentifier: @MainActor () -> Int32?,
        readRootProcessIdentifier: @MainActor () -> Int32?,
        readDocumentURL: @MainActor () throws -> URL?,
        sameElement: @MainActor (Element, Element) -> Bool
    ) throws -> Bool {
        guard expectedProcessIdentifier > 0,
              let focusedRoot = try readFocusedRoot(),
              sameElement(focusedRoot, expectedRoot),
              let rootParent = try readRootParent(),
              sameElement(rootParent, application),
              try readRootRole() == (kAXWindowRole as String),
              readApplicationProcessIdentifier() == expectedProcessIdentifier,
              readRootProcessIdentifier() == expectedProcessIdentifier,
              documentURLMatches(expected: expectedDocumentURL, actual: try readDocumentURL())
        else { return false }
        return true
    }

    static func documentURLMatches(expected: URL, actual: URL?) -> Bool {
        guard expected.isFileURL, let actual, actual.isFileURL else { return false }
        return expected.absoluteString == actual.absoluteString
    }

    @MainActor
    static func focusedFieldIsValid<Element>(
        expectedField: Element,
        acquiredField: Element,
        expectedRoot: Element,
        expectedProcessIdentifier: Int32,
        readFieldProcessIdentifier: @MainActor () -> Int32?,
        readCurrentFocusedField: @MainActor () throws -> Element?,
        readFieldWindow: @MainActor () throws -> Element?,
        readWindowProcessIdentifier: @MainActor (Element) -> Int32?,
        sameElement: @MainActor (Element, Element) -> Bool
    ) throws -> Bool {
        guard expectedProcessIdentifier > 0,
              sameElement(acquiredField, expectedField),
              readFieldProcessIdentifier() == expectedProcessIdentifier,
              let currentFocusedField = try readCurrentFocusedField(),
              sameElement(currentFocusedField, expectedField),
              let fieldWindow = try readFieldWindow(),
              readWindowProcessIdentifier(fieldWindow) == expectedProcessIdentifier,
              sameElement(fieldWindow, expectedRoot)
        else { return false }
        return true
    }
}
#endif

enum ObservedCaptureNotification {
    static func failureReason(for notification: CFString) -> SelectionFailureReason {
        if CFEqual(notification, kAXFocusedUIElementChangedNotification as CFString) {
            return .captureObservedFocusChange
        }
        if CFEqual(notification, kAXSelectedTextChangedNotification as CFString) {
            return .captureObservedSelectionChange
        }
        if CFEqual(notification, kAXValueChangedNotification as CFString) {
            return .captureObservedValueChange
        }
        return .captureInvalidated
    }
}

@MainActor
enum ObservedFocusValidation {
    static func preservesCapture<Element>(
        observedTargetID: UUID,
        currentTargetID: UUID,
        capturedElement: Element,
        readFocusedElement: () throws -> Element?,
        sameElement: (Element, Element) -> Bool
    ) -> Bool {
        guard observedTargetID == currentTargetID else { return false }
        do {
            guard let focusedElement = try readFocusedElement() else { return false }
            return sameElement(focusedElement, capturedElement)
        } catch {
            return false
        }
    }
}

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

enum CaretCompositionState: Equatable {
    case unmarked
    case marked
    case unavailable

    static func read(advertised: Bool, status: AXError, hasValue: Bool) -> Self {
        guard advertised else { return .unavailable }
        guard status == .success || status == .noValue else { return .unavailable }
        return hasValue ? .marked : .unmarked
    }
}

struct CaretInsertionProof {
    static let maximumWholeValueUTF16Length = 65_536

    let value: String
    let range: ImrseCore.TextRange

    init?(
        value: String?,
        range: ImrseCore.TextRange,
        selectedText: String?,
        permitsPlainTextValueWrite: Bool,
        composition: CaretCompositionState
    ) {
        guard permitsPlainTextValueWrite,
              composition == .unmarked,
              let value,
              value.utf16.count <= Self.maximumWholeValueUTF16Length,
              selectedText?.isEmpty == true,
              range.length == 0,
              UTF16SelectionRange.substring(value, range: range) != nil
        else { return nil }
        self.value = value
        self.range = range
    }

    func matches(value: String?, range: ImrseCore.TextRange, selectedText: String) -> Bool {
        guard let value else { return false }
        return self.range == range && selectedText.isEmpty && self.value.utf16.elementsEqual(value.utf16)
    }

    func inserting(_ text: String) -> String? {
        guard !text.isEmpty,
              let result = UTF16SelectionRange.replacing(value, range: range, with: text),
              result.utf16.count <= Self.maximumWholeValueUTF16Length
        else { return nil }
        return result
    }

    func confirmsApplied(value: String?, inserting text: String) -> Bool {
        guard let value, let expected = inserting(text) else { return false }
        return expected.utf16.elementsEqual(value.utf16)
    }
}

enum SelectionReadValidation {
    static func rangeFailure(_ range: ImrseCore.TextRange?, allowingEmpty: Bool) -> SelectionFailureReason? {
        guard let range else { return .selectedRangeUnavailable }
        guard UTF16SelectionRange.isValid(range) else { return .invalidSelectedRange }
        guard allowingEmpty || range.length > 0 else { return .emptySelection }
        return nil
    }

    static func textFailure(_ text: String?, range: ImrseCore.TextRange, allowingEmpty: Bool) -> SelectionFailureReason? {
        guard let text else { return .selectedTextUnavailable }
        guard allowingEmpty || !text.isEmpty else { return .emptySelection }
        guard text.utf16.count == range.length else { return .selectedTextLengthMismatch }
        return nil
    }
}

enum AccessibilityFocusAcquisition {
    static func acquire<Element>(
        readApplicationRole: () throws -> Void = {},
        requestManualAccessibility: () throws -> Void,
        hasTimeForRetry: () -> Bool,
        readFocusedElement: () throws -> Element?,
        validate: (Element) throws -> Void,
        waitBeforeRetry: () -> Void
    ) throws -> Element? {
        _ = try? readApplicationRole()
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
        onTextLengthMismatch: () -> Void = {},
        readStringForRange: () throws -> String?
    ) throws -> String? {
        guard UTF16SelectionRange.isValid(range), range.length > 0 else { throw failure }
        if let directText, !directText.isEmpty {
            guard directText.utf16.count == range.length else {
                onTextLengthMismatch()
                throw failure
            }
            return directText
        }
        guard UTF16SelectionRange.isWithinSupportedRange(range) else { throw failure }
        guard let rangeText = try readStringForRange() else { return nil }
        guard rangeText.utf16.count == range.length else {
            onTextLengthMismatch()
            throw failure
        }
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

enum ClipboardDirectStaticTextValidation {
    static func permits<Element>(
        root: Element,
        readRole: (Element) throws -> String,
        readChildren: (Element) throws -> [Element],
        sameElement: (Element, Element) -> Bool
    ) -> Bool {
        do {
            let children = try readChildren(root)
            guard try readRole(root) == "AXTextArea",
                  children.count == 1,
                  let leaf = children.first,
                  !sameElement(root, leaf),
                  try readRole(leaf) == "AXStaticText",
                  try readChildren(leaf).isEmpty
            else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}

@MainActor
enum VerifiedAction {
    static func perform<Output>(
        verify: () throws -> Void,
        action: () throws -> Output
    ) throws -> Output {
        try verify()
        return try action()
    }
}

#endif
