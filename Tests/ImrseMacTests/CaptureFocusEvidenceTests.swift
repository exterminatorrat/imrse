import XCTest
import ImrseCore
@testable import ImrseMac

final class CaptureFocusEvidenceTests: XCTestCase {
    func testRecorderDoesNotInventReadsAndCapsCount() throws {
        var evidence = CaptureFocusEvidence()
        XCTAssertNil(evidence.diagnostic())
        evidence.record(.attributeUnsupported)
        for _ in 0..<200 { evidence.record(.noValue) }
        evidence.retryBudgetEnded = true
        let diagnostic = try XCTUnwrap(evidence.diagnostic())
        XCTAssertEqual(diagnostic.firstRead, .attributeUnsupported)
        XCTAssertEqual(diagnostic.lastRead, .noValue)
        XCTAssertEqual(diagnostic.attempts, 128)
        XCTAssertTrue(diagnostic.retryBudgetEnded)
    }

    func testAcquisitionStillUsesOriginalReadRetrySequence() throws {
        var evidence = CaptureFocusEvidence()
        var calls: [String] = []
        var reads = 0
        let result: Int? = try AccessibilityFocusAcquisition.acquire(
            readApplicationRole: { calls.append("role") },
            requestManualAccessibility: { calls.append("manual") },
            hasTimeForRetry: { calls.append("budget"); return true },
            readFocusedElement: {
                calls.append("read"); reads += 1
                evidence.record(reads == 1 ? .noValue : .resolved)
                return reads == 1 ? nil : 42
            }, validate: { _ in calls.append("validate") },
            waitBeforeRetry: { calls.append("wait") })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, ["role", "manual", "read", "budget", "wait", "budget", "read", "validate"])
        XCTAssertEqual(evidence.attempts, 2)
        XCTAssertEqual(evidence.firstRead, .noValue)
        XCTAssertEqual(evidence.lastRead, .resolved)
    }

    func testProductionWrapperPreservesFailureThenClearsNextCaptureEvidence() throws {
        var published: NativeRefusalDiagnostic.CaptureFocus?
        var reads = 0
        let missing: Int? = try CaptureFocusEvidence.acquire(
            readApplicationRole: {}, requestManualAccessibility: {}, hasTimeForRetry: { false },
            readFocusedElement: { record in reads += 1; record(.noValue); return nil },
            validate: { _ in }, waitBeforeRetry: { XCTFail("No retry budget") },
            publish: { published = $0 })
        XCTAssertNil(missing)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(published?.attempts, 1)
        XCTAssertEqual(published?.lastRead, .noValue)
        XCTAssertEqual(published?.retryBudgetEnded, true)
        var metadata = DiagnosticMetadata()
        metadata.error = .noSelection
        metadata.selectionFailureReason = .focusedElementUnavailable
        metadata.attachNativeRefusal(.init(captureFocus: published))
        XCTAssertTrue(DiagnosticReport.render(metadata).contains("captureFocus"))
        let resolved: Int? = try CaptureFocusEvidence.acquire(
            readApplicationRole: {}, requestManualAccessibility: {}, hasTimeForRetry: { false },
            readFocusedElement: { record in reads += 1; record(.resolved); return 42 },
            validate: { _ in }, waitBeforeRetry: { XCTFail("No retry required") },
            publish: { published = $0 })
        XCTAssertEqual(resolved, 42)
        XCTAssertEqual(reads, 2)
        XCTAssertNil(published)
        metadata.error = nil
        metadata.attachNativeRefusal(published.map { .init(captureFocus: $0) })
        XCTAssertFalse(DiagnosticReport.render(metadata).contains("captureFocus"))
    }

    func testReadFailureDoesNotBecomeRetryOrFallback() {
        var evidence = CaptureFocusEvidence()
        var waits = 0
        do {
            let _: Int? = try AccessibilityFocusAcquisition.acquire(
                requestManualAccessibility: {}, hasTimeForRetry: { true },
                readFocusedElement: { evidence.record(.readFailed); throw ImrseError.applicationUnreachable },
                validate: { _ in }, waitBeforeRetry: { waits += 1 })
            XCTFail("Expected original read error")
        } catch { XCTAssertEqual(error as? ImrseError, .applicationUnreachable) }
        XCTAssertEqual(evidence.attempts, 1)
        XCTAssertEqual(evidence.lastRead, .readFailed)
        XCTAssertEqual(waits, 0)
    }
}
