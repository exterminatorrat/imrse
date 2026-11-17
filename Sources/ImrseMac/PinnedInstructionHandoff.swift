#if os(macOS)
import Foundation
import ImrseCore

/// A bounded, explicitly pinned-destination session, not uninterrupted-focus proof.
/// No AX lookup, focus mutation, clipboard access or write authority lives here.
struct PinnedInstructionHandoff {
    enum Phase { case instruction, presenting, returning, invalid }
    let captureID: UUID
    let panelID: UUID
    let baseline: String
    private(set) var phase: Phase = .instruction
    private let expires: ContinuousClock.Instant
    private(set) var returnDeadline: ContinuousClock.Instant?

    init(captureID: UUID, panelID: UUID, baseline: String, now: ContinuousClock.Instant) {
        self.captureID = captureID; self.panelID = panelID; self.baseline = baseline
        expires = now.advanced(by: .seconds(180))
    }
    func isLive(captureID: UUID, now: ContinuousClock.Instant) -> Bool {
        self.captureID == captureID && phase != .invalid && now < expires
    }
    func permitsOwnFocusAbsence(captureID: UUID, panelID: UUID, panelIsKey: Bool,
                               now: ContinuousClock.Instant) -> Bool {
        isLive(captureID: captureID, now: now) && self.panelID == panelID
            && phase == .instruction && panelIsKey
    }
    func permitsFocusObservation(captureID: UUID, outcome: NativeRefusalDiagnostic.FocusOutcome,
                                 read: NativeRefusalDiagnostic.FocusRead?,
                                 foreground: NativeRefusalDiagnostic.ForegroundRelation,
                                 panelIsKey: Bool, now: ContinuousClock.Instant) -> Bool {
        guard outcome == .missingFocusedElement, read == .noValue,
              foreground == .target || foreground == .own else { return false }
        if isLive(captureID: captureID, now: now), phase == .presenting { return true }
        return permitsOwnFocusAbsence(captureID: captureID, panelID: panelID,
                    panelIsKey: panelIsKey, now: now)
            || mayWaitForOriginalFocus(captureID: captureID, panelIsKey: panelIsKey, now: now)
    }
    mutating func beginPresentation(panelID: UUID, now: ContinuousClock.Instant) {
        guard self.panelID == panelID, phase == .instruction, now < expires else { invalidate(); return }
        phase = .presenting
    }
    mutating func endPresentation(panelID: UUID, panelIsKey: Bool, now: ContinuousClock.Instant) {
        guard self.panelID == panelID, phase == .presenting, panelIsKey, now < expires else { invalidate(); return }
        phase = .instruction
    }
    mutating func beginReturn(panelID: UUID, now: ContinuousClock.Instant) {
        if self.panelID == panelID, phase == .returning { return } // No deadline renewal on a repeated hide.
        guard self.panelID == panelID, phase == .instruction, now < expires else {
            invalidate(); return
        }
        phase = .returning
        returnDeadline = min(expires, now.advanced(by: .milliseconds(500)))
    }
    func mayWaitForOriginalFocus(captureID: UUID, panelIsKey: Bool,
                                now: ContinuousClock.Instant) -> Bool {
        isLive(captureID: captureID, now: now) && phase == .returning && !panelIsKey
            && returnDeadline.map { now < $0 } == true
    }
    /// Shared production sequencing seam. Only the adapter can classify a fresh noValue as temporary.
    @MainActor static func awaitOriginal(
        validateSession: () throws -> Void,
        probeExactOriginal: () throws -> Bool,
        mayWaitForAbsence: () -> Bool,
        wait: () async throws -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            try validateSession()
            if try probeExactOriginal() {
                try Task.checkCancellation()
                try validateSession()
                return
            }
            guard mayWaitForAbsence() else { throw ImrseError.targetLost }
            try await wait()
        }
    }
    mutating func invalidate() { phase = .invalid }
}
#endif
