import Foundation
import XCTest
@testable import ImrseCore

final class ClipboardConfirmationDiagnosticTests: XCTestCase {
    func testReportContainsOnlyClosedReadEvidenceAndBoundedCounters() throws {
        var evidence = ClipboardConfirmationDiagnostic()
        for _ in 0..<100 { evidence.beginSample() }
        evidence.phase = .selection
        evidence.failedRead = .init(operation: .attribute, attribute: .selectedText, status: .cannotComplete)
        evidence.finish(.threw, elapsedMilliseconds: Int.max)
        var attempt = WriteAttemptDiagnostic(strategy: .clipboard); attempt.clipboardConfirmation = evidence
        var metadata = DiagnosticMetadata(); metadata.writeAttempt = attempt
        let report = DiagnosticReport.render(metadata)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        let write = try XCTUnwrap(object["writeAttempt"] as? [String: Any])
        let fields = try XCTUnwrap(write["clipboardConfirmation"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["phase", "outcome", "sampleCount", "elapsedMilliseconds", "failedRead"]))
        XCTAssertEqual(fields["sampleCount"] as? Int, 64); XCTAssertEqual(fields["elapsedMilliseconds"] as? Int, 10_000)
        let read = try XCTUnwrap(fields["failedRead"] as? [String: String])
        XCTAssertEqual(read, ["operation": "attribute", "attribute": "selectedText", "status": "cannotComplete"])
        XCTAssertFalse(report.contains("file:")); XCTAssertFalse(report.contains("textValue"))
    }
    func testFreshAttemptOmitsPreviousConfirmationAndNextSampleClearsFailure() throws {
        var evidence = ClipboardConfirmationDiagnostic()
        evidence.failedRead = .init(operation: .attribute, attribute: .document, status: .invalidElement)
        evidence.beginSample(); XCTAssertNil(evidence.failedRead)
        evidence.finish(.noProofBeforeDeadline, elapsedMilliseconds: -10); XCTAssertEqual(evidence.elapsedMilliseconds, 0)
        var metadata = DiagnosticMetadata(); metadata.writeAttempt = WriteAttemptDiagnostic(strategy: .clipboard)
        XCTAssertFalse(DiagnosticReport.render(metadata).contains("clipboardConfirmation"))
    }
}
