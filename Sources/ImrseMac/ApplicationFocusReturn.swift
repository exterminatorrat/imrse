#if os(macOS)
import AppKit
import ImrseCore

@MainActor
public final class ApplicationFocusReturn: NSObject {
    struct Identity: Equatable {
        let processID: Int32
        let launchDate: Date

        init?(application: NSRunningApplication) {
            guard let launchDate = application.launchDate else { return nil }
            self.init(processID: application.processIdentifier, launchDate: launchDate)
        }

        init(processID: Int32, launchDate: Date) {
            self.processID = processID
            self.launchDate = launchDate
        }
    }

    private let original: Identity?
    private let ownProcessID: Int32
    private let originalIsAlive: () -> Bool
    private let foreground: () -> Identity?
    private let activateOriginal: () -> Bool
    private(set) var lastFailureReason: SelectionFailureReason?
    private var isValid = true
    private var activationRequested = false
    private var notificationCenter: NotificationCenter?

    convenience init(application: NSRunningApplication) {
        let identity = Identity(application: application)
        self.init(
            original: identity,
            ownProcessID: ProcessInfo.processInfo.processIdentifier,
            originalIsAlive: {
                !application.isTerminated && identity != nil && Identity(application: application) == identity
            },
            foreground: {
                NSWorkspace.shared.frontmostApplication.flatMap { Identity(application: $0) }
            },
            activateOriginal: { application.activate(options: []) }
        )
        let center = NSWorkspace.shared.notificationCenter
        notificationCenter = center
        center.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    init(
        original: Identity?,
        ownProcessID: Int32,
        originalIsAlive: @escaping () -> Bool,
        foreground: @escaping () -> Identity?,
        activateOriginal: @escaping () -> Bool
    ) {
        self.original = original
        self.ownProcessID = ownProcessID
        self.originalIsAlive = originalIsAlive
        self.foreground = foreground
        self.activateOriginal = activateOriginal
        super.init()
    }

    public func invalidate() {
        isValid = false
        notificationCenter?.removeObserver(self)
        notificationCenter = nil
    }

    public func finishPresentation() {
        defer { invalidate() }
        try? requestReturn()
    }

    func isOriginalFrontmost() throws -> Bool {
        guard isValid, let original, originalIsAlive() else {
            lastFailureReason = lastFailureReason ?? .focusReturnInvalid
            throw ImrseError.targetLost
        }
        guard let current = foreground() else {
            lastFailureReason = .focusReturnForegroundMissing
            invalidate()
            throw ImrseError.targetLost
        }
        if current == original { return true }
        guard current.processID == ownProcessID else {
            lastFailureReason = .focusReturnOtherApplication
            invalidate()
            throw ImrseError.staleSelection
        }
        return false
    }

    func requestReturn() throws {
        if try isOriginalFrontmost() { return }
        guard !activationRequested else { return }
        activationRequested = true
        guard activateOriginal() else {
            lastFailureReason = .focusReturnActivationRejected
            invalidate()
            throw ImrseError.targetLost
        }
    }

    func restoreForReplacement(checkCapture: () throws -> Void) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while true {
            try Task.checkCancellation()
            try checkCapture()
            guard clock.now < deadline else {
                lastFailureReason = .focusReturnTimedOut
                throw ImrseError.targetLost
            }
            if try isOriginalFrontmost() { return }
            try requestReturn()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func didActivate(_ identity: Identity?) {
        guard let identity, identity == original || identity.processID == ownProcessID else {
            lastFailureReason = identity == nil ? .focusReturnForegroundMissing : .focusReturnOtherApplication
            invalidate()
            return
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        didActivate(application.flatMap { Identity(application: $0) })
    }
}
#endif
