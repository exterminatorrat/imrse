import Foundation
import XCTest
@testable import ImrseCore

final class CaptureFocusDiagnosticTests: XCTestCase {
    func testCaptureEvidenceAttachesForCaptureFailureWithClosedFieldsOnly() throws {
        var metadata = DiagnosticMetadata()
        metadata.error = .noSelection
        metadata.selectionFailureReason = .focusedElementUnavailable
        metadata.attachNativeRefusal(.init(captureFocus: .init(firstRead: .attributeUnsupported,
            lastRead: .noValue, attempts: 3, retryBudgetEnded: true)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DiagnosticReport.render(metadata).utf8)) as? [String: Any])
        let native = try XCTUnwrap(object["nativeRefusal"] as? [String: Any])
        let capture = try XCTUnwrap(native["captureFocus"] as? [String: Any])
        XCTAssertEqual(Set(capture.keys), ["firstRead", "lastRead", "attempts", "retryBudgetEnded"])
        XCTAssertEqual(capture["attempts"] as? Int, 3)
        XCTAssertEqual(capture["firstRead"] as? String, "attributeUnsupported")
        XCTAssertEqual(capture["lastRead"] as? String, "noValue")
    }

    func testUnrelatedAndSuccessfulReportsDropCaptureEvidence() {
        let diagnostic = NativeRefusalDiagnostic(captureFocus: .init(firstRead: .noValue,
            lastRead: .noValue, attempts: 1, retryBudgetEnded: true))
        var metadata = DiagnosticMetadata()
        metadata.selectionFailureReason = .focusedElementUnavailable
        metadata.attachNativeRefusal(diagnostic)
        XCTAssertNil(metadata.nativeRefusalDiagnostic)
        metadata.error = .replacementFailed
        metadata.selectionFailureReason = .replacementEvidenceMismatch
        metadata.attachNativeRefusal(diagnostic)
        XCTAssertNil(metadata.nativeRefusalDiagnostic)
    }

    func testSerializerRefusesOutOfRangeAttemptCount() {
        for count in [0, -1, 129, Int.max] {
            var metadata = DiagnosticMetadata()
            metadata.nativeRefusalDiagnostic = .init(captureFocus: .init(firstRead: .noValue,
                lastRead: .noValue, attempts: count, retryBudgetEnded: true))
            XCTAssertFalse(DiagnosticReport.render(metadata).contains("captureFocus"))
        }
    }
}
