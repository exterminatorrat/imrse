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

    public enum FocusSite: String, Equatable, Sendable {
        case observer
        case targetAnchor
        case editableHost
    }

    /// Own-app state only, sampled when the refusal occurs; no target metadata.
    public struct PanelOwnership: Equatable, Sendable {
        public let isKey: Bool
        public let ownAppActive: Bool
        public let activationRequested: Bool
        public init(isKey: Bool, ownAppActive: Bool, activationRequested: Bool) {
            self.isKey = isKey
            self.ownAppActive = ownAppActive
            self.activationRequested = activationRequested
        }
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

    public let focusSite: FocusSite?
    public let panelOwnership: PanelOwnership?
    public let captureFocus: CaptureFocus?
    public let undo: Undo?
    public let focus: FocusOutcome?
    public let focusRead: FocusRead?
    public let foreground: ForegroundRelation?
    public let panelPhase: PanelPhase?
    public let presentationStage: PresentationStage?

    public init(
        focusSite: FocusSite? = nil,
        panelOwnership: PanelOwnership? = nil,
        captureFocus: CaptureFocus? = nil,
        undo: Undo? = nil,
        focus: FocusOutcome? = nil,
        focusRead: FocusRead? = nil,
        foreground: ForegroundRelation? = nil,
        panelPhase: PanelPhase? = nil,
        presentationStage: PresentationStage? = nil
    ) {
        self.focusSite = focusSite
        self.panelOwnership = panelOwnership
        self.captureFocus = captureFocus
        self.undo = undo
        self.focus = focus
        self.focusRead = focusRead
        self.foreground = foreground
        self.panelPhase = panelPhase
        self.presentationStage = presentationStage
    }
}

/// Historical observer evidence for the latest capture, not a current operation error.
/// Constructed only for an actual focus invalidation observation; no text or identity.
public struct CaptureFocusObservation: Equatable, Sendable {
    public let evidence: NativeRefusalDiagnostic

    public init?(_ event: NativeRefusalDiagnostic) {
        guard event.focusSite == .observer, let focus = event.focus else { return nil }
        evidence = .init(focusSite: .observer, panelOwnership: event.panelOwnership,
            focus: focus, focusRead: event.focusRead, foreground: event.foreground,
            panelPhase: event.panelPhase, presentationStage: event.presentationStage)
    }
}
