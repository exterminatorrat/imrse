import XCTest
@testable import ImrseCore

final class WriteAttemptDiagnosticTests: XCTestCase {
    func testFailureDiagnosticDoesNotRequireReceipt() {
        var metadata = DiagnosticMetadata()
        metadata.error = .replacementFailed
        var attempt = WriteAttemptDiagnostic(strategy: .selectedText)
        attempt.setterStatus = .accepted
        attempt.readback = .original
        metadata.writeAttempt = attempt
        let report = DiagnosticReport.render(metadata)
        XCTAssertTrue(report.contains("writeAttempt"))
        XCTAssertTrue(report.contains("accepted"))
        XCTAssertTrue(report.contains("original"))
        XCTAssertNil(metadata.strategy)
    }
}
