import Foundation
import XCTest
@testable import ImrseCore

final class DiagnosticReportTests: XCTestCase {
    func testReportRendersOnlySafeAllowlistedMetadata() throws {
        var metadata = DiagnosticMetadata()
        metadata.accessibilityGranted = true
        metadata.eventMonitoringActive = true
        metadata.applicationID = "com.example.editor"
        metadata.role = "textField"
        metadata.selectionLength = 42
        metadata.targetValid = false
        metadata.strategy = .valueRange
        metadata.providerName = "Example provider"
        metadata.model = "example-model"
        metadata.generation = "selection-secret\n"
        metadata.replacement = "generated-secret\n"
        metadata.error = .authentication

        let report = DiagnosticReport.render(metadata)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])

        XCTAssertEqual(fields["accessibilityGranted"] as? Bool, true)
        XCTAssertEqual(fields["eventMonitoringActive"] as? Bool, true)
        XCTAssertEqual(fields["applicationID"] as? String, "com.example.editor")
        XCTAssertEqual(fields["role"] as? String, "textField")
        XCTAssertEqual(fields["selectionLength"] as? Int, 42)
        XCTAssertEqual(fields["targetValid"] as? Bool, false)
        XCTAssertEqual(fields["strategy"] as? String, "valueRange")
        XCTAssertEqual(fields["providerName"] as? String, "Example provider")
        XCTAssertEqual(fields["model"] as? String, "example-model")
        XCTAssertEqual(fields["generation"] as? String, "unknown")
        XCTAssertEqual(fields["replacement"] as? String, "unknown")
        XCTAssertEqual(fields["error"] as? String, ImrseError.authentication.rawValue)
        XCTAssertFalse(report.contains("selection-secret"))
        XCTAssertFalse(report.contains("generated-secret"))
        XCTAssertFalse(report.contains("credential-secret"))
        XCTAssertFalse(report.contains(ImrseError.authentication.message))
    }

    func testReportBoundsMetadataStringsAndFiltersControlCharacters() throws {
        var metadata = DiagnosticMetadata()
        metadata.applicationID = String(repeating: "a", count: 200)
        metadata.role = "text\nfield"
        metadata.providerName = String(repeating: "p", count: 300)
        metadata.model = String(repeating: "m", count: 400)

        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DiagnosticReport.render(metadata).utf8)) as? [String: Any])

        XCTAssertEqual((fields["applicationID"] as? String)?.unicodeScalars.count, 128)
        XCTAssertEqual(fields["role"] as? String, "textfield")
        XCTAssertEqual((fields["providerName"] as? String)?.unicodeScalars.count, 128)
        XCTAssertEqual((fields["model"] as? String)?.unicodeScalars.count, 256)
    }
}
