public struct NativeRefusalDiagnostic: Equatable, Sendable {
    public enum UndoRoute: String, Equatable, Sendable {
        case generic
        case uniform
        case structured
    }

    public enum UndoStage: String, Equatable, Sendable {
        case preflight
        case pasteEntry
        case stage
        case verify
    }

    public enum StyleState: String, Equatable, Sendable {
        case rootIneligible
        case attributedUnavailable
        case structuredUnavailable
        case projectionMismatch
        case styleMismatch
    }

    public enum FocusOutcome: String, Equatable, Sendable {
        case missingFocusedElement
        case readFailed
        case differentAnchor
    }

    public enum FocusRead: String, Equatable, Sendable {
        case resolved
        case noValue
        case attributeUnsupported
        case successWithoutElement
        case unexpectedValueType
        case readFailed

        public var isReadFailure: Bool {
            switch self {
            case .resolved, .noValue, .attributeUnsupported: false
            case .successWithoutElement, .unexpectedValueType, .readFailed: true
            }
        }
    }

    public enum ForegroundRelation: String, Equatable, Sendable {
        case target
        case own
        case other
        case unavailable
    }

    public enum PanelPhase: String, Equatable, Sendable {
        case unavailable
        case presentationRequested
        case presentationReturned
        case hideRequested
        case hideReturned
        case handoffHideRequested
        case handoffHideReturned
    }

    public enum PresentationStage: String, Equatable, Sendable {
        case unavailable
        case hidden
        case input
        case processing
        case applying
        case success
        case failure
    }

    public struct Undo: Equatable, Sendable {
        public let route: UndoRoute
        public let stage: UndoStage
        public let style: StyleState?

        public init(route: UndoRoute, stage: UndoStage, style: StyleState? = nil) {
            self.route = route
            self.stage = stage
            self.style = style
        }
    }

    public struct CaptureFocus: Equatable, Sendable {
        public let firstRead: FocusRead
        public let lastRead: FocusRead
        public let attempts: Int
        public let retryBudgetEnded: Bool
        public init(firstRead: FocusRead, lastRead: FocusRead, attempts: Int,
                    retryBudgetEnded: Bool) {
            self.firstRead = firstRead; self.lastRead = lastRead; self.attempts = attempts
            self.retryBudgetEnded = retryBudgetEnded
        }
    }

    public let captureFocus: CaptureFocus?
    public let undo: Undo?
    public let focus: FocusOutcome?
    public let focusRead: FocusRead?
    public let foreground: ForegroundRelation?
    public let panelPhase: PanelPhase?
    public let presentationStage: PresentationStage?

    public init(
        captureFocus: CaptureFocus? = nil,
        undo: Undo? = nil,
        focus: FocusOutcome? = nil,
        focusRead: FocusRead? = nil,
        foreground: ForegroundRelation? = nil,
        panelPhase: PanelPhase? = nil,
        presentationStage: PresentationStage? = nil
    ) {
        self.captureFocus = captureFocus
        self.undo = undo
        self.focus = focus
        self.focusRead = focusRead
        self.foreground = foreground
        self.panelPhase = panelPhase
        self.presentationStage = presentationStage
    }
}
