import Foundation

public enum DiagnosticReport {
    private static let generationStages: Set<String> = ["idle", "running", "complete", "failed", "cancelled"]
    private static let replacementStages: Set<String> = ["idle", "running", "replaced", "unchanged", "undoing", "undone", "failed"]

    public static func render(_ metadata: DiagnosticMetadata) -> String {
        var fields: [String: Any] = [
            "accessibilityGranted": metadata.accessibilityGranted,
            "eventMonitoringActive": metadata.eventMonitoringActive,
            "generation": generationStages.contains(metadata.generation) ? metadata.generation : "unknown",
            "replacement": replacementStages.contains(metadata.replacement) ? metadata.replacement : "unknown"
        ]
        if let applicationID = metadata.applicationID {
            fields["applicationID"] = safeString(applicationID, maximumScalars: 128)
        }
        if let role = metadata.role {
            fields["role"] = safeString(role, maximumScalars: 80)
        }
        if let selectionLength = metadata.selectionLength, selectionLength >= 0 {
            fields["selectionLength"] = selectionLength
        }
        if let selectionFailureReason = metadata.selectionFailureReason {
            fields["selectionFailureReason"] = selectionFailureReason.rawValue
        }
        if metadata.selectionFailureReason == .documentContextUnavailable,
           let documentContextFailure = metadata.documentContextFailure {
            fields["documentContextFailure"] = documentContextFailure.rawValue
            if documentContextFailure == .emptyValue,
               let diagnostic = metadata.documentBindingDiagnostic {
                var binding: [String: Any] = ["ancestorResult": diagnostic.ancestorResult.rawValue]
                if let depth = diagnostic.candidateDepth,
                   (0...DocumentBindingDiagnostic.maximumAncestorDepth).contains(depth) {
                    binding["candidateDepth"] = depth
                }
                if let read = diagnostic.candidateURLRead {
                    binding["candidateURLRead"] = read.rawValue
                }
                if let comparison = diagnostic.comparison {
                    var equality: [String: Any] = [
                        "windowUnchanged": comparison.windowUnchanged,
                        "editorUnchanged": comparison.editorUnchanged
                    ]
                    if let unchanged = comparison.webAreaUnchanged {
                        equality["webAreaUnchanged"] = unchanged
                    }
                    if let unchanged = comparison.urlUnchanged {
                        equality["urlUnchanged"] = unchanged
                    }
                    binding["comparison"] = equality
                }
                fields["documentBinding"] = binding
            }
        }
        if let targetValid = metadata.targetValid { fields["targetValid"] = targetValid }
        if let strategy = metadata.strategy { fields["strategy"] = strategy.rawValue }
        if let providerName = metadata.providerName {
            fields["providerName"] = safeString(providerName, maximumScalars: 128)
        }
        if let model = metadata.model {
            fields["model"] = safeString(model, maximumScalars: 256)
        }
        if let error = metadata.error { fields["error"] = error.rawValue }

        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func safeString(_ value: String, maximumScalars: Int) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maximumScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
