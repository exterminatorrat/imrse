import Foundation
import Testing
@testable import ImrseCore

struct DocumentBindingDiagnosticReportTests {
    @Test func observationIsAbsentByDefault() throws {
        let metadata = DiagnosticMetadata()
        #expect(metadata.documentBindingDiagnostic == nil)
        #expect(try fields(metadata)["documentBinding"] == nil)
    }

    @Test func observationRequiresTheMatchingEmptyDocumentRefusal() throws {
        let cases: [(SelectionFailureReason?, DocumentContextFailure?)] = [
            (nil, nil),
            (.axReadFailure, .emptyValue),
            (.documentContextChanged, .emptyValue),
            (.documentContextUnavailable, nil),
            (.documentContextUnavailable, .missingValue),
            (.documentContextUnavailable, .attributeUnsupported),
            (.documentContextUnavailable, .unexpectedValueType),
            (.documentContextUnavailable, .unexpectedNoValuePayload),
            (.documentContextUnavailable, .valueTooLong)
        ]
        for (reason, detail) in cases {
            var metadata = DiagnosticMetadata()
            metadata.selectionFailureReason = reason
            metadata.documentContextFailure = detail
            metadata.documentBindingDiagnostic = observation()
            #expect(try fields(metadata)["documentBinding"] == nil)
        }
    }

    @Test func reportContainsOnlyClosedValuesAndEqualityBooleans() throws {
        var metadata = matchingMetadata()
        metadata.documentBindingDiagnostic = observation(comparison: .init(
            windowUnchanged: true,
            editorUnchanged: false,
            webAreaUnchanged: true,
            urlUnchanged: false
        ))
        let report = try fields(metadata)
        let binding = try #require(report["documentBinding"] as? [String: Any])
        #expect(Set(binding.keys) == Set([
            "ancestorResult", "candidateDepth", "candidateURLRead", "comparison"
        ]))
        #expect(binding["ancestorResult"] as? String == "foundWebArea")
        #expect(binding["candidateDepth"] as? Int == 2)
        #expect(binding["candidateURLRead"] as? String == "nonemptyURL")
        let comparison = try #require(binding["comparison"] as? [String: Bool])
        #expect(comparison == [
            "windowUnchanged": true,
            "editorUnchanged": false,
            "webAreaUnchanged": true,
            "urlUnchanged": false
        ])
        #expect(Set(report.keys) == Set([
            "accessibilityGranted", "eventMonitoringActive", "generation", "replacement",
            "selectionFailureReason", "documentContextFailure", "documentBinding"
        ]))
    }

    @Test func missingCandidateDoesNotInventDepthValueOrComparison() throws {
        var metadata = matchingMetadata()
        metadata.documentBindingDiagnostic = .init(ancestorResult: .notFound)
        let binding = try #require(try fields(metadata)["documentBinding"] as? [String: Any])
        #expect(Set(binding.keys) == Set(["ancestorResult"]))
        #expect(binding["ancestorResult"] as? String == "notFound")
    }

    @Test func unknownIdentityComparisonsAreOmittedRatherThanReportedEqual() throws {
        var metadata = matchingMetadata()
        metadata.documentBindingDiagnostic = observation(comparison: .init(
            windowUnchanged: true,
            editorUnchanged: true,
            webAreaUnchanged: nil,
            urlUnchanged: nil
        ))
        let binding = try #require(try fields(metadata)["documentBinding"] as? [String: Any])
        let comparison = try #require(binding["comparison"] as? [String: Bool])
        #expect(comparison == ["windowUnchanged": true, "editorUnchanged": true])
    }

    @Test(arguments: [-1, 0, DocumentBindingDiagnostic.maximumAncestorDepth,
                      DocumentBindingDiagnostic.maximumAncestorDepth + 1])
    func reportBoundsCandidateDepth(_ depth: Int) throws {
        var metadata = matchingMetadata()
        metadata.documentBindingDiagnostic = .init(ancestorResult: .foundWebArea, candidateDepth: depth)
        let binding = try #require(try fields(metadata)["documentBinding"] as? [String: Any])
        if (0...DocumentBindingDiagnostic.maximumAncestorDepth).contains(depth) {
            #expect(binding["candidateDepth"] as? Int == depth)
        } else {
            #expect(binding["candidateDepth"] == nil)
        }
    }

    private func matchingMetadata() -> DiagnosticMetadata {
        var metadata = DiagnosticMetadata()
        metadata.selectionFailureReason = .documentContextUnavailable
        metadata.documentContextFailure = .emptyValue
        return metadata
    }

    private func observation(
        comparison: DocumentBindingDiagnostic.Comparison? = nil
    ) -> DocumentBindingDiagnostic {
        .init(
            ancestorResult: .foundWebArea,
            candidateDepth: 2,
            candidateURLRead: .nonemptyURL,
            comparison: comparison
        )
    }

    private func fields(_ metadata: DiagnosticMetadata) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(
            with: Data(DiagnosticReport.render(metadata).utf8)
        ) as? [String: Any])
    }
}
