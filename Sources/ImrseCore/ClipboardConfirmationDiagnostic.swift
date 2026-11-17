/// Closed, content-free evidence from existing post-paste reads. Never includes
/// text, attribute values, application identities, window titles or document URLs.
public struct ClipboardConfirmationDiagnostic: Equatable, Sendable {
    public enum Phase: String, Sendable { case identity, foreground, targetValidation, selection, wholeValue, selectionRecheck }
    public enum Outcome: String, Sendable { case confirmed, noProofBeforeDeadline, threw }
    public enum ReadOperation: String, Sendable { case attribute, parameterizedAttribute, attributeNames }
    public enum Attribute: String, Sendable {
        case focusedElement, role, subrole, roleDescription, window, document, value, selectedText, selectedRange
        case domClasses, children, parent, protectedContent, enabled, focused, stringForRange, attributedStringForRange, other
    }
    public enum Status: String, Sendable {
        case cannotComplete, invalidElement, apiDisabled, unsupported, noValue, notImplemented, other
        case successMissingValue, successInvalidValue
    }
    public struct FailedRead: Equatable, Sendable {
        public let operation: ReadOperation
        public let attribute: Attribute
        public let status: Status
        public init(operation: ReadOperation, attribute: Attribute, status: Status) {
            self.operation = operation; self.attribute = attribute; self.status = status
        }
    }
    public var phase: Phase = .identity
    public var outcome: Outcome?
    public var failedRead: FailedRead?
    public private(set) var sampleCount = 0
    public private(set) var elapsedMilliseconds = 0
    public init() {}
    public mutating func beginSample() {
        sampleCount = min(sampleCount + 1, 64)
        phase = .identity
        failedRead = nil
    }
    public mutating func finish(_ outcome: Outcome, elapsedMilliseconds: Int) {
        self.outcome = outcome
        self.elapsedMilliseconds = min(max(elapsedMilliseconds, 0), 10_000)
    }
}
