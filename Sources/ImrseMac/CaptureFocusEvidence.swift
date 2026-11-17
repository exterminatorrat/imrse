import ImrseCore

/// Bounded, content-free evidence. The recorder never performs an AX read.
struct CaptureFocusEvidence {
    private(set) var firstRead: NativeRefusalDiagnostic.FocusRead?
    private(set) var lastRead: NativeRefusalDiagnostic.FocusRead?
    private(set) var attempts = 0
    var retryBudgetEnded = false

    mutating func record(_ read: NativeRefusalDiagnostic.FocusRead) {
        if firstRead == nil { firstRead = read }
        lastRead = read
        attempts = min(attempts + 1, 128)
    }

    func diagnostic() -> NativeRefusalDiagnostic.CaptureFocus? {
        guard let firstRead, let lastRead, attempts > 0 else { return nil }
        return .init(firstRead: firstRead, lastRead: lastRead, attempts: attempts,
            retryBudgetEnded: retryBudgetEnded)
    }

    /// The actual capture wrapper: preserves acquisition semantics and resets
    /// evidence for each operation, including a successful next invocation.
    static func acquire<Element>(
        readApplicationRole: () throws -> Void,
        requestManualAccessibility: () throws -> Void,
        hasTimeForRetry: () -> Bool,
        readFocusedElement: (_ record: (NativeRefusalDiagnostic.FocusRead) -> Void) throws -> Element?,
        validate: (Element) throws -> Void,
        waitBeforeRetry: () -> Void,
        publish: (NativeRefusalDiagnostic.CaptureFocus?) -> Void
    ) throws -> Element? {
        var evidence = Self()
        var acquired = false
        publish(nil)
        defer { if !acquired { publish(evidence.diagnostic()) } }
        let element = try AccessibilityFocusAcquisition.acquire(
            readApplicationRole: readApplicationRole,
            requestManualAccessibility: requestManualAccessibility,
            hasTimeForRetry: {
                let available = hasTimeForRetry()
                if !available { evidence.retryBudgetEnded = true }
                return available
            },
            readFocusedElement: { try readFocusedElement { evidence.record($0) } },
            validate: validate,
            waitBeforeRetry: waitBeforeRetry)
        acquired = element != nil
        return element
    }
}
