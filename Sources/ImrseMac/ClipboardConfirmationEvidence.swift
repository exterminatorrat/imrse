import Foundation
import ApplicationServices
import ImrseCore

@MainActor
final class ClipboardConfirmationEvidence {
    private(set) var diagnostic = ClipboardConfirmationDiagnostic()
    private let start = ContinuousClock.now
    func beginSample() { diagnostic.beginSample() }
    func phase(_ phase: ClipboardConfirmationDiagnostic.Phase) { diagnostic.phase = phase; diagnostic.failedRead = nil }
    func clearFailedRead() { diagnostic.failedRead = nil }
    func failedRead(status: AXError, attribute: String, operation: ClipboardConfirmationDiagnostic.ReadOperation = .attribute,
                    invalidValue: Bool = false) {
        diagnostic.failedRead = .init(operation: operation, attribute: Self.attribute(attribute),
            status: Self.status(status, invalidValue: invalidValue))
    }
    func finish(_ outcome: ClipboardConfirmationDiagnostic.Outcome) -> ClipboardConfirmationDiagnostic {
        let parts = start.duration(to: .now).components
        let milliseconds = parts.seconds >= 10 ? 10_000 : Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        diagnostic.finish(outcome, elapsedMilliseconds: milliseconds)
        return diagnostic
    }
    static func status(_ status: AXError, invalidValue: Bool = false) -> ClipboardConfirmationDiagnostic.Status {
        switch status {
        case .success: invalidValue ? .successInvalidValue : .successMissingValue
        case .cannotComplete: .cannotComplete
        case .invalidUIElement: .invalidElement
        case .apiDisabled: .apiDisabled
        case .attributeUnsupported, .parameterizedAttributeUnsupported: .unsupported
        case .noValue: .noValue
        case .notImplemented: .notImplemented
        default: .other
        }
    }
    static func attribute(_ name: String) -> ClipboardConfirmationDiagnostic.Attribute {
        switch name {
        case kAXFocusedUIElementAttribute: .focusedElement
        case kAXRoleAttribute: .role
        case kAXSubroleAttribute: .subrole
        case kAXRoleDescriptionAttribute: .roleDescription
        case kAXWindowAttribute: .window
        case kAXDocumentAttribute: .document
        case kAXValueAttribute: .value
        case kAXSelectedTextAttribute: .selectedText
        case kAXSelectedTextRangeAttribute: .selectedRange
        case "AXDOMClassList": .domClasses
        case kAXChildrenAttribute: .children
        case kAXParentAttribute: .parent
        case "AXProtectedContent": .protectedContent
        case kAXEnabledAttribute: .enabled
        case kAXFocusedAttribute: .focused
        case kAXStringForRangeParameterizedAttribute: .stringForRange
        case kAXAttributedStringForRangeParameterizedAttribute: .attributedStringForRange
        default: .other
        }
    }
}
