public struct DocumentBindingDiagnostic: Equatable, Sendable {
    public static let maximumAncestorDepth = 16

    public enum AncestorResult: String, Equatable, Sendable {
        case foundWebArea
        case notFound
        case readFailed
        case inconsistentProcess
        case inconsistentWindow
        case cycleDetected
        case depthLimitReached
        case timeLimitReached
    }

    public enum URLRead: String, Equatable, Sendable {
        case nonemptyString
        case emptyString
        case nonemptyURL
        case emptyURL
        case missingValue
        case noValue
        case unsupported
        case unexpectedType
        case unexpectedNoValuePayload
        case valueTooLong
        case readFailed
    }

    public struct Comparison: Equatable, Sendable {
        public let windowUnchanged: Bool
        public let editorUnchanged: Bool
        public let webAreaUnchanged: Bool?
        public let urlUnchanged: Bool?

        public init(
            windowUnchanged: Bool,
            editorUnchanged: Bool,
            webAreaUnchanged: Bool?,
            urlUnchanged: Bool?
        ) {
            self.windowUnchanged = windowUnchanged
            self.editorUnchanged = editorUnchanged
            self.webAreaUnchanged = webAreaUnchanged
            self.urlUnchanged = urlUnchanged
        }
    }

    public let ancestorResult: AncestorResult
    public let candidateDepth: Int?
    public let candidateURLRead: URLRead?
    public let comparison: Comparison?

    public init(
        ancestorResult: AncestorResult,
        candidateDepth: Int? = nil,
        candidateURLRead: URLRead? = nil,
        comparison: Comparison? = nil
    ) {
        self.ancestorResult = ancestorResult
        self.candidateDepth = candidateDepth
        self.candidateURLRead = candidateURLRead
        self.comparison = comparison
    }
}
