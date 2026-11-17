import Foundation
import XCTest
import ImrseCore
@testable import ImrseMac

final class PinnedInstructionHandoffTests: XCTestCase {
    func testOwnPanelAbsenceRequiresExactLiveSessionAndKeyboardOwnership() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        let ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        XCTAssertTrue(ticket.permitsOwnFocusAbsence(captureID: capture, panelID: panel, panelIsKey: true, now: now))
        XCTAssertFalse(ticket.permitsOwnFocusAbsence(captureID: UUID(), panelID: panel, panelIsKey: true, now: now))
        XCTAssertFalse(ticket.permitsOwnFocusAbsence(captureID: capture, panelID: UUID(), panelIsKey: true, now: now))
        XCTAssertFalse(ticket.permitsOwnFocusAbsence(captureID: capture, panelID: panel, panelIsKey: false, now: now))
        XCTAssertFalse(ticket.isLive(captureID: capture, now: now.advanced(by: .seconds(180))))
    }
    func testOnlyExpectedAbsenceCanBeSuspendedNeverDifferentAnchorOrReadError() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        let ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        XCTAssertTrue(ticket.permitsFocusObservation(captureID: capture, outcome: .missingFocusedElement,
            read: .noValue, foreground: .target, panelIsKey: true, now: now))
        for outcome in [NativeRefusalDiagnostic.FocusOutcome.differentAnchor, .readFailed] {
            XCTAssertFalse(ticket.permitsFocusObservation(captureID: capture, outcome: outcome,
                read: .noValue, foreground: .target, panelIsKey: true, now: now))
        }
        XCTAssertFalse(ticket.permitsFocusObservation(captureID: capture, outcome: .missingFocusedElement,
            read: nil, foreground: .target, panelIsKey: true, now: now))
        XCTAssertFalse(ticket.permitsFocusObservation(captureID: capture, outcome: .missingFocusedElement,
            read: .noValue, foreground: .other, panelIsKey: true, now: now))
        XCTAssertFalse(ticket.permitsFocusObservation(captureID: capture, outcome: .missingFocusedElement,
            read: .noValue, foreground: .unavailable, panelIsKey: true, now: now))
    }
    func testSynchronousActivationGapAndMissingKeyAtEnd() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        var ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        ticket.beginPresentation(panelID: panel, now: now)
        XCTAssertTrue(ticket.permitsFocusObservation(captureID: capture, outcome: .missingFocusedElement,
            read: .noValue, foreground: .own, panelIsKey: false, now: now))
        XCTAssertFalse(ticket.permitsFocusObservation(captureID: capture, outcome: .differentAnchor,
            read: nil, foreground: .own, panelIsKey: false, now: now))
        ticket.endPresentation(panelID: panel, panelIsKey: false, now: now)
        XCTAssertFalse(ticket.isLive(captureID: capture, now: now))
    }
    func testSuccessfulFinalProofIsNotAnAbsenceRetryAfterBudget() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        var ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        ticket.beginReturn(panelID: panel, now: now)
        let later = now.advanced(by: .seconds(1))
        XCTAssertFalse(ticket.mayWaitForOriginalFocus(captureID: capture, panelIsKey: false, now: later))
        XCTAssertTrue(ticket.isLive(captureID: capture, now: later)) // Final exact proof still required by adapter.
    }
    func testReturnIsBoundedAndNeverPermitsAnInputLeaseAgain() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        var ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        ticket.beginReturn(panelID: panel, now: now)
        XCTAssertFalse(ticket.permitsOwnFocusAbsence(captureID: capture, panelID: panel, panelIsKey: true, now: now))
        XCTAssertTrue(ticket.mayWaitForOriginalFocus(captureID: capture, panelIsKey: false, now: now))
        XCTAssertFalse(ticket.mayWaitForOriginalFocus(captureID: capture, panelIsKey: true, now: now))
        XCTAssertFalse(ticket.mayWaitForOriginalFocus(captureID: capture, panelIsKey: false, now: now.advanced(by: .milliseconds(500))))
    }
    func testObservedExternalDriftCannotBeRevivedByReturningToSameState() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        var ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        ticket.invalidate()
        ticket.beginReturn(panelID: panel, now: now)
        XCTAssertFalse(ticket.isLive(captureID: capture, now: now))
        XCTAssertFalse(ticket.mayWaitForOriginalFocus(captureID: capture, panelIsKey: false, now: now))
    }
    @MainActor func testProductionReturnSequenceWaitsOnlyOnAbsenceAndRevalidatesAfterWait() async throws {
        var probes = 0, validations = 0, waits = 0
        try await PinnedInstructionHandoff.awaitOriginal(validateSession: { validations += 1 },
            probeExactOriginal: { probes += 1; return probes == 2 },
            mayWaitForAbsence: { true }, wait: { waits += 1 })
        XCTAssertEqual(probes, 2); XCTAssertEqual(waits, 1); XCTAssertEqual(validations, 3)
    }
    @MainActor func testProductionReturnSequenceNeverRetriesDifferentTargetOrBaseline() async {
        var probes = 0, waits = 0
        do {
            try await PinnedInstructionHandoff.awaitOriginal(validateSession: {},
                probeExactOriginal: { probes += 1; throw ImrseError.staleSelection },
                mayWaitForAbsence: { true }, wait: { waits += 1 })
            XCTFail("must refuse")
        } catch { XCTAssertEqual(error as? ImrseError, .staleSelection) }
        XCTAssertEqual(probes, 1); XCTAssertEqual(waits, 0)
    }
    @MainActor func testProductionReturnSequenceRevocationDuringWaitPreventsFurtherProbe() async {
        var live = true, probes = 0
        do {
            try await PinnedInstructionHandoff.awaitOriginal(validateSession: {
                if !live { throw ImrseError.targetLost }
            }, probeExactOriginal: { probes += 1; return false },
            mayWaitForAbsence: { true }, wait: { live = false })
            XCTFail("must refuse")
        } catch { XCTAssertEqual(error as? ImrseError, .targetLost) }
        XCTAssertEqual(probes, 1)
    }
    @MainActor func testProductionReturnSequenceRevalidatesAfterExactRead() async {
        var live = true
        do {
            try await PinnedInstructionHandoff.awaitOriginal(validateSession: {
                if !live { throw ImrseError.targetLost }
            }, probeExactOriginal: { live = false; return true },
            mayWaitForAbsence: { false }, wait: { XCTFail("no wait") })
            XCTFail("must refuse")
        } catch { XCTAssertEqual(error as? ImrseError, .targetLost) }
    }
    func testRepeatedHideDoesNotInvalidateOrRenewReturnBudget() {
        let now = ContinuousClock().now, capture = UUID(), panel = UUID()
        var ticket = PinnedInstructionHandoff(captureID: capture, panelID: panel, baseline: "original", now: now)
        ticket.beginReturn(panelID: panel, now: now)
        let deadline = ticket.returnDeadline
        ticket.beginReturn(panelID: panel, now: now.advanced(by: .seconds(1)))
        XCTAssertEqual(ticket.returnDeadline, deadline)
        XCTAssertTrue(ticket.isLive(captureID: capture, now: now.advanced(by: .seconds(1))))
    }

}
