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

    public let undo: Undo?
    public let focus: FocusOutcome?

    public init(undo: Undo? = nil, focus: FocusOutcome? = nil) {
        self.undo = undo
        self.focus = focus
    }
}
