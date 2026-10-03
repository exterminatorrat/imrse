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
