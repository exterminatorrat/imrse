import ApplicationServices
import XCTest
@testable import ImrseMac
import ImrseCore

@MainActor
final class ClipboardConfirmationEvidenceTests: XCTestCase {
    func testExistingStatusAndAttributeClassificationsDoNotRetainNamesOrValues() {
        let pairs: [(AXError, ClipboardConfirmationDiagnostic.Status)] = [(.cannotComplete, .cannotComplete), (.invalidUIElement, .invalidElement), (.apiDisabled, .apiDisabled), (.attributeUnsupported, .unsupported), (.noValue, .noValue), (.notImplemented, .notImplemented), (.success, .successMissingValue), (.failure, .other)]
        for (status, expected) in pairs { XCTAssertEqual(ClipboardConfirmationEvidence.status(status), expected) }
        XCTAssertEqual(ClipboardConfirmationEvidence.status(.success, invalidValue: true), .successInvalidValue)
        XCTAssertEqual(ClipboardConfirmationEvidence.attribute("private-attribute-or-URL"), .other)
        XCTAssertEqual(ClipboardConfirmationEvidence.attribute(kAXSelectedTextAttribute), .selectedText)
    }
    func testSampleAndPhaseResetPreventStaleReadAttribution() {
        let evidence = ClipboardConfirmationEvidence()
        evidence.beginSample(); evidence.phase(.selection)
        evidence.failedRead(status: .cannotComplete, attribute: kAXSelectedTextAttribute)
        XCTAssertEqual(evidence.diagnostic.failedRead?.status, .cannotComplete)
        evidence.beginSample()
        XCTAssertNil(evidence.diagnostic.failedRead); XCTAssertEqual(evidence.diagnostic.sampleCount, 2)
        evidence.failedRead(status: .apiDisabled, attribute: kAXRoleAttribute)
        evidence.phase(.wholeValue)
        XCTAssertNil(evidence.diagnostic.failedRead)
        evidence.failedRead(status: .invalidUIElement, attribute: kAXValueAttribute)
        evidence.clearFailedRead(); XCTAssertNil(evidence.diagnostic.failedRead)
    }
    func testRecorderDoesNotChangePollingExceptionOrReadCount() async {
        let evidence = ClipboardConfirmationEvidence()
        let now = ContinuousClock.now
        var reads = 0, waits = 0
        do {
            let _: String? = try await ClipboardWriteConfirmation.wait(deadline: now.advanced(by: .milliseconds(500)), now: { now }, sample: {
                evidence.beginSample(); evidence.phase(.targetValidation)
                reads += 1; evidence.failedRead(status: .apiDisabled, attribute: kAXFocusedUIElementAttribute)
                throw ImrseError.permissionRequired
            }, waitForUpdate: { waits += 1 })
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? ImrseError, .permissionRequired) }
        let diagnostic = evidence.finish(.threw)
        XCTAssertEqual(reads, 1); XCTAssertEqual(waits, 0); XCTAssertEqual(diagnostic.sampleCount, 1)
        XCTAssertEqual(diagnostic.phase, .targetValidation); XCTAssertEqual(diagnostic.failedRead?.status, .apiDisabled)
    }
}
